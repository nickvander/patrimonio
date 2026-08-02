//! HTTP-level integration tests for the invite lifecycle — the ONLY path new
//! users arrive by after bootstrap: minting (`POST /api/auth/invites`),
//! listing, revoking (creator-scoped), and public redemption via
//! `POST /api/auth/register`, including expiry, atomic one-time consumption,
//! and role inheritance (a `read_only` invite yields a user whom
//! `require_owner` 403s on mutations; an `owner` invite yields a full owner).
//!
//! Like the sibling suites, these need a real Postgres reachable via
//! `PATRIMONIO_TEST_DATABASE_URL`; when unset they print a skip note and
//! return (set-but-unreachable PANICS — see tests/common/mod.rs).

use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{header, HeaderValue, Method, Request, StatusCode};
use axum::middleware::from_fn_with_state;
use axum::Router;
use serde_json::{json, Value};
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use tower::ServiceExt;

use patrimonio::config::AppConfig;
use patrimonio::AppState;

mod common;
use common::TestLockGuard;

const TEST_DB_VAR: &str = "PATRIMONIO_TEST_DATABASE_URL";
const SESSION_COOKIE: &str = "patrimonio_session";

/// Build the production middleware stack (CSRF outer, auth inner,
/// require_owner on the business routes) around the invite router, mirroring
/// main.rs's mounting: invite minting is a BUSINESS route (creating an
/// invite materialises a new user), registration + bootstrap are public.
async fn try_setup() -> Option<(Router, PgPool, TestLockGuard)> {
    let database_url = std::env::var(TEST_DB_VAR).ok()?;
    let lock = TestLockGuard::acquire(&database_url).await?;
    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect(&database_url)
        .await
        .expect("connect to test DB");

    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .expect("apply migrations to test DB");

    sqlx::query(
        "TRUNCATE \
         invite_tokens, auth_audit, user_sessions, app_settings, \
         users RESTART IDENTITY CASCADE",
    )
    .execute(&pool)
    .await
    .expect("truncate invite tables");

    let config = AppConfig {
        database_url: database_url.clone(),
        database_max_connections: 2,
        redis_url: "redis://127.0.0.1:6379".to_string(),
        port: 0,
        plaid_client_id: None,
        plaid_secret: None,
        plaid_env: "sandbox".to_string(),
        exchange_rate_api_key: None,
        encryption_key: Some("a".repeat(32)),
        coinbase_client_id: None,
        coinbase_client_secret: None,
        coinbase_redirect_uri: "http://localhost/api/auth/coinbase/callback".to_string(),
        frontend_base_url: "http://localhost:3000".to_string(),
        plaid_redirect_uri: None,
        plaid_android_package_name: None,
        plaid_webhook_url: None,
        allowed_origins: vec!["http://localhost:3000".to_string()],
        cookie_secure: false,
        trusted_proxy_cidrs: vec![],
        hibp_api_base: String::new(),
        android_apk_cert_sha256: vec![],
        android_package_name: "com.patrimonio.patrimonio".to_string(),
    };

    let redis = redis::Client::open(config.redis_url.clone()).expect("redis client");
    let webauthn = Arc::new(
        patrimonio::api::passkeys::build_webauthn(
            &config.frontend_base_url,
            &config.android_apk_cert_sha256,
        )
        .expect("webauthn builder"),
    );
    let state = AppState {
        db: pool.clone(),
        redis,
        config: Arc::new(config),
        webauthn,
        realtime: patrimonio::services::realtime::Realtime::new(),
    };

    let public = Router::new().nest("/api/auth", patrimonio::api::session::public_router());

    let business = Router::new()
        .nest("/api/auth/invites", patrimonio::api::invites::router())
        .layer(axum::middleware::from_fn(
            patrimonio::api::middleware::require_owner,
        ));
    let account_mgmt =
        Router::new().nest("/api/auth", patrimonio::api::session::protected_router());
    let protected = business
        .merge(account_mgmt)
        .layer(from_fn_with_state(
            state.clone(),
            patrimonio::api::middleware::require_auth,
        ))
        .layer(axum::middleware::from_fn(
            patrimonio::api::middleware::require_csrf_header,
        ));

    let app = public.merge(protected).with_state(state);
    Some((app, pool, lock))
}

fn skip_if_no_db<T>(result: Option<T>) -> Option<T> {
    if result.is_none() {
        eprintln!(
            "(skipping: set {TEST_DB_VAR}=postgres://user:pass@host/db to enable invite integration tests)"
        );
    }
    result
}

async fn body_json(body: Body) -> Value {
    let bytes = to_bytes(body, 1024 * 256).await.expect("read body");
    if bytes.is_empty() {
        return Value::Null;
    }
    serde_json::from_slice(&bytes).expect("json body")
}

fn set_cookie_value(headers: &axum::http::HeaderMap) -> Option<String> {
    for cookie in headers.get_all(header::SET_COOKIE).iter() {
        let raw = cookie.to_str().ok()?;
        let pair = raw.split(';').next()?.trim();
        if let Some(rest) = pair.strip_prefix(&format!("{SESSION_COOKIE}=")) {
            return Some(rest.to_string());
        }
    }
    None
}

/// Build a request with cookie + CSRF header + JSON body (CSRF baked in on
/// mutating methods so a test can't forget it).
fn req(method: Method, uri: &str, body: Option<&Value>, cookie: Option<&str>) -> Request<Body> {
    let needs_csrf = matches!(
        method,
        Method::POST | Method::PATCH | Method::DELETE | Method::PUT,
    );
    let mut builder = Request::builder().method(method).uri(uri);
    if needs_csrf {
        builder = builder.header("X-Requested-With", "patrimonio");
    }
    if let Some(token) = cookie {
        builder = builder.header(
            header::COOKIE,
            HeaderValue::from_str(&format!("{SESSION_COOKIE}={token}")).unwrap(),
        );
    }
    if let Some(b) = body {
        builder = builder.header(header::CONTENT_TYPE, "application/json");
        builder
            .body(Body::from(serde_json::to_vec(b).unwrap()))
            .unwrap()
    } else {
        builder.body(Body::empty()).unwrap()
    }
}

/// Bootstrap the first (owner) user; returns (cookie, user_id).
async fn bootstrap(app: &Router, pool: &PgPool) -> (String, uuid::Uuid) {
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/auth/bootstrap",
            Some(&json!({
                "username": "owner",
                "email": "owner@example.com",
                "password": "correcthorsebatterystaple"
            })),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "bootstrap should succeed");
    let token = set_cookie_value(res.headers()).expect("bootstrap sets cookie");
    let user_id: uuid::Uuid = sqlx::query_scalar("SELECT id FROM users LIMIT 1")
        .fetch_one(pool)
        .await
        .expect("user row exists after bootstrap");
    (token, user_id)
}

/// Mint an invite through the real endpoint; returns (invite_id, token).
async fn mint_invite(app: &Router, cookie: &str, body: Value) -> (String, String) {
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/auth/invites",
            Some(&body),
            Some(cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "invite mint should succeed");
    let json = body_json(res.into_body()).await;
    let id = json["id"].as_str().expect("invite id").to_string();
    let token = json["token"].as_str().expect("invite token").to_string();
    (id, token)
}

/// Redeem an invite token through the public register endpoint; returns the
/// response so callers can assert success or failure shapes.
async fn register(
    app: &Router,
    token: &str,
    username: &str,
) -> axum::http::Response<axum::body::Body> {
    app.clone()
        .oneshot(req(
            Method::POST,
            "/api/auth/register",
            Some(&json!({
                "token": token,
                "username": username,
                "password": "correcthorsebatterystaple"
            })),
            None,
        ))
        .await
        .unwrap()
}

async fn user_count(pool: &PgPool) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM users")
        .fetch_one(pool)
        .await
        .unwrap()
}

// ---------------------------------------------------------------------------

#[tokio::test]
#[serial_test::serial]
async fn invite_create_list_revoke_roundtrip() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, _uid) = bootstrap(&app, &pool).await;

    // Mint: response carries the one-time plaintext token (32 random bytes,
    // URL-safe base64 → 43 chars) and a share URL embedding it.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/auth/invites",
            Some(&json!({"note": "for my accountant"})),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    let token = json["token"].as_str().expect("plaintext token");
    assert_eq!(token.len(), 43, "32 bytes URL-safe-base64 unpadded");
    let url = json["url"].as_str().expect("share url");
    assert!(
        url.contains(&format!("?invite={token}")),
        "share URL embeds the token: {url}"
    );
    let invite_id = json["id"].as_str().expect("invite id").to_string();

    // Only the SHA-256 hash is stored — the plaintext must not be in the DB.
    let stored_hash: Vec<u8> = sqlx::query_scalar("SELECT token_hash FROM invite_tokens LIMIT 1")
        .fetch_one(&pool)
        .await
        .expect("invite row");
    assert_eq!(stored_hash.len(), 32, "SHA-256 hash stored, not plaintext");
    assert_ne!(stored_hash, token.as_bytes().to_vec());

    // List: shows the pending invite with role defaulted to 'owner'.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/auth/invites", None, Some(&cookie)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let list = body_json(res.into_body()).await;
    let invites = list.as_array().expect("list is an array");
    assert_eq!(invites.len(), 1);
    assert_eq!(invites[0]["id"], invite_id.as_str());
    assert_eq!(invites[0]["used"], false);
    assert_eq!(invites[0]["role"], "owner", "default role is owner");
    assert_eq!(invites[0]["note"], "for my accountant");

    // Revoke: 204, then the row is gone and a second revoke is a 404.
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/auth/invites/{invite_id}"),
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM invite_tokens")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 0, "revoke deletes the live invite row");
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/auth/invites/{invite_id}"),
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_FOUND,
        "revoke is not idempotent-silent"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn invite_mint_rejects_unknown_role() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, _uid) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/auth/invites",
            Some(&json!({"role": "admin"})),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST, "typo role must 400");
    let json = body_json(res.into_body()).await;
    assert!(
        json["error"].as_str().unwrap_or("").contains("role"),
        "error envelope names the bad field: {json}"
    );
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM invite_tokens")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 0, "rejected role must not persist an invite");
}

#[tokio::test]
#[serial_test::serial]
async fn register_with_valid_invite_creates_signed_in_user_and_burns_invite() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (owner_cookie, _uid) = bootstrap(&app, &pool).await;
    let (invite_id, token) = mint_invite(&app, &owner_cookie, json!({})).await;

    let res = register(&app, &token, "alice").await;
    assert_eq!(res.status(), StatusCode::OK, "valid invite must register");
    let alice_cookie = set_cookie_value(res.headers()).expect("register signs the user in");
    let json = body_json(res.into_body()).await;
    assert_eq!(json["user"]["username"], "alice");
    assert_eq!(
        json["user"]["role"], "owner",
        "default invite role is owner"
    );
    assert!(
        !json["recovery_codes"].as_array().unwrap().is_empty(),
        "one batch of recovery codes is returned at registration"
    );

    // The session cookie works: /me reflects the new user.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/auth/me", None, Some(&alice_cookie)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let me = body_json(res.into_body()).await;
    assert_eq!(me["username"], "alice");

    // The invite is stamped used (kept as an audit record, not deleted) …
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/auth/invites",
            None,
            Some(&owner_cookie),
        ))
        .await
        .unwrap();
    let list = body_json(res.into_body()).await;
    assert_eq!(list[0]["used"], true);
    assert!(list[0]["used_at"].is_string(), "used_at recorded: {list}");

    // … and a used invite can no longer be revoked (the DELETE filters to
    // live rows so the join record survives).
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/auth/invites/{invite_id}"),
            None,
            Some(&owner_cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM invite_tokens")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 1, "redeemed invite row is kept as a record");
}

#[tokio::test]
#[serial_test::serial]
async fn register_with_expired_invite_is_rejected_and_leaves_no_user() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (owner_cookie, _uid) = bootstrap(&app, &pool).await;
    let (_id, token) = mint_invite(&app, &owner_cookie, json!({})).await;

    // Age the invite past its expiry (the endpoint clamps expires_in_hours
    // to >= 1, so an already-expired invite can only be simulated in SQL).
    sqlx::query("UPDATE invite_tokens SET expires_at = NOW() - INTERVAL '1 hour'")
        .execute(&pool)
        .await
        .expect("expire the invite");

    let res = register(&app, &token, "latecomer").await;
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    let json = body_json(res.into_body()).await;
    assert!(
        json["error"]
            .as_str()
            .unwrap_or("")
            .contains("Invalid, expired, or already-used"),
        "error envelope explains the rejection: {json}"
    );
    // The register handler creates the user BEFORE consuming the invite and
    // must roll it back on failure — no user-shaped artifact may remain.
    assert_eq!(
        user_count(&pool).await,
        1,
        "only the bootstrap owner exists"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn invite_is_consumed_atomically_exactly_once() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (owner_cookie, _uid) = bootstrap(&app, &pool).await;
    let (_id, token) = mint_invite(&app, &owner_cookie, json!({})).await;

    // First redemption wins…
    let res = register(&app, &token, "first").await;
    assert_eq!(res.status(), StatusCode::OK);

    // …the second redemption of the SAME code must lose (the atomic
    // `UPDATE … WHERE used_at IS NULL RETURNING` in consume_invite) and must
    // not leave the second user behind.
    let res = register(&app, &token, "second").await;
    assert_eq!(res.status(), StatusCode::BAD_REQUEST, "one-time use only");
    let json = body_json(res.into_body()).await;
    assert!(json["error"].is_string(), "error envelope shape: {json}");
    assert_eq!(
        user_count(&pool).await,
        2,
        "owner + first only; second rolled back"
    );
    let second_exists: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM users WHERE username = 'second')")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(!second_exists, "failed redemption must not create a user");

    // A garbage token is the same 400, not a 500.
    let res = register(&app, "definitely-not-a-token", "third").await;
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
#[serial_test::serial]
async fn duplicate_username_conflicts_without_burning_the_invite() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (owner_cookie, _uid) = bootstrap(&app, &pool).await;
    let (_id, token) = mint_invite(&app, &owner_cookie, json!({})).await;

    // 'owner' is taken by the bootstrap user → 409, and because the user
    // insert fails BEFORE the invite is consumed, the invite stays live.
    let res = register(&app, &token, "owner").await;
    assert_eq!(res.status(), StatusCode::CONFLICT);
    let unused: bool =
        sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM invite_tokens WHERE used_at IS NULL)")
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(unused, "a username conflict must not burn the invite");

    // The same invite still redeems for a fresh username.
    let res = register(&app, &token, "fresh-name").await;
    assert_eq!(res.status(), StatusCode::OK);
}

#[tokio::test]
#[serial_test::serial]
async fn revoke_is_scoped_to_the_creator() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (owner_cookie, _uid) = bootstrap(&app, &pool).await;

    // The owner holds a pending invite…
    let (kept_id, _kept_token) = mint_invite(&app, &owner_cookie, json!({})).await;
    // …and a second OWNER-role user joins via a separate invite (owner role,
    // so require_owner is not what stops them — creator scoping is).
    let (_id2, token2) = mint_invite(&app, &owner_cookie, json!({"role": "owner"})).await;
    let res = register(&app, &token2, "bob").await;
    assert_eq!(res.status(), StatusCode::OK);
    let bob_cookie = set_cookie_value(res.headers()).expect("bob signed in");

    // Bob cannot see the owner's invites…
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/auth/invites",
            None,
            Some(&bob_cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let list = body_json(res.into_body()).await;
    assert_eq!(
        list.as_array().map(Vec::len),
        Some(0),
        "another creator's invites must not leak: {list}"
    );

    // …and cannot revoke them: 404 (not found within HIS scope), and the
    // row must still exist afterwards.
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/auth/invites/{kept_id}"),
            None,
            Some(&bob_cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
    let survived: bool = sqlx::query_scalar(
        "SELECT EXISTS(SELECT 1 FROM invite_tokens WHERE id = $1::uuid AND used_at IS NULL)",
    )
    .bind(uuid::Uuid::parse_str(&kept_id).unwrap())
    .fetch_one(&pool)
    .await
    .unwrap();
    assert!(survived, "cross-user revoke must not delete the invite");
}

#[tokio::test]
#[serial_test::serial]
async fn invite_role_is_inherited_and_enforced_by_require_owner() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (owner_cookie, _uid) = bootstrap(&app, &pool).await;

    // read_only invite → read_only user.
    let (_id, ro_token) = mint_invite(&app, &owner_cookie, json!({"role": "read_only"})).await;
    let res = register(&app, &ro_token, "viewer").await;
    assert_eq!(res.status(), StatusCode::OK);
    let viewer_cookie = set_cookie_value(res.headers()).expect("viewer signed in");
    let json = body_json(res.into_body()).await;
    assert_eq!(
        json["user"]["role"], "read_only",
        "role copied off the invite"
    );
    let db_role: String = sqlx::query_scalar("SELECT role FROM users WHERE username = 'viewer'")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(db_role, "read_only");

    // require_owner blocks the read_only user on a mutating business route
    // (minting an invite is the cheapest one mounted here — and the one that
    // matters most: a read-only user must not mint themselves owners).
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/auth/invites",
            Some(&json!({})),
            Some(&viewer_cookie),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::FORBIDDEN,
        "read_only mutation → 403"
    );
    let json = body_json(res.into_body()).await;
    assert!(
        json["error"].as_str().unwrap_or("").contains("read-only"),
        "403 envelope explains the role gate: {json}"
    );
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM invite_tokens WHERE used_at IS NULL")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 0, "the 403 must not have minted anything");

    // But GETs pass require_owner: a read_only user can still read.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/auth/invites",
            None,
            Some(&viewer_cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "read_only can read own data");

    // An owner-role invite yields a user who PASSES require_owner.
    let (_id2, owner_token) = mint_invite(&app, &owner_cookie, json!({"role": "owner"})).await;
    let res = register(&app, &owner_token, "second-owner").await;
    assert_eq!(res.status(), StatusCode::OK);
    let second_owner_cookie = set_cookie_value(res.headers()).expect("second owner signed in");
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/auth/invites",
            Some(&json!({})),
            Some(&second_owner_cookie),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::OK,
        "owner-role invitee can mutate"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn invite_endpoints_require_authentication() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    // Bootstrap so the app is out of setup mode, then call with no cookie.
    let (_cookie, _uid) = bootstrap(&app, &pool).await;

    for (method, uri) in [
        (Method::POST, "/api/auth/invites"),
        (Method::GET, "/api/auth/invites"),
    ] {
        let res = app
            .clone()
            .oneshot(req(method.clone(), uri, Some(&json!({})), None))
            .await
            .unwrap();
        assert_eq!(
            res.status(),
            StatusCode::UNAUTHORIZED,
            "{method} {uri} must require a session"
        );
    }
}
