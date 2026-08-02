//! Passkey listing / removal integration tests.
//!
//! Motivated by a real report: a user enrolled one security key (showed
//! fine), then a second — the UI said "success" but the new passkey never
//! appeared in the list, and re-adding it errored. The list endpoint and
//! the multi-credential storage are what these tests pin down: a user can
//! hold MORE THAN ONE passkey and `GET /api/auth/passkeys` returns all of
//! them. (The full WebAuthn ceremony needs a software authenticator and is
//! covered by the frontend; here we exercise the storage + list + delete
//! layer directly by seeding rows.)

use axum::body::{to_bytes, Body};
use axum::http::{header, HeaderValue, Method, Request, StatusCode};
use axum::middleware::from_fn_with_state;
use axum::Router;
use serde_json::Value;
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use std::sync::Arc;
use tower::ServiceExt;
use uuid::Uuid;

use patrimonio::config::AppConfig;
use patrimonio::AppState;

mod common;
use common::TestLockGuard;

const TEST_DB_VAR: &str = "PATRIMONIO_TEST_DATABASE_URL";
const SESSION_COOKIE: &str = "patrimonio_session";
/// The prod APK signing cert digest (lowercase no-colon hex, as
/// config::parse_cert_sha256_list normalizes). Configured on the shared
/// harness so EVERY ceremony test in this file also runs against a
/// Webauthn built with the android origin appended — proving the extra
/// origin never breaks the browser flows.
const TEST_APK_CERT_HEX: &str = "e1ef2549ade55b49a678772fd274a8a08a546247146a388462cb47026fc5028d";

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
        "TRUNCATE passkey_credentials, auth_audit, user_sessions, users \
         RESTART IDENTITY CASCADE",
    )
    .execute(&pool)
    .await
    .expect("truncate");

    let config = AppConfig {
        database_url: database_url.clone(),
        database_max_connections: 2,
        redis_url: "redis://127.0.0.1:6379".to_string(),
        port: 0,
        plaid_client_id: None,
        plaid_secret: None,
        plaid_env: "sandbox".to_string(),
        exchange_rate_api_key: None,
        encryption_key: None,
        coinbase_client_id: None,
        coinbase_client_secret: None,
        coinbase_redirect_uri: "http://localhost/api/auth/coinbase/callback".to_string(),
        frontend_base_url: "http://localhost:3000".to_string(),
        plaid_redirect_uri: None,
        plaid_android_package_name: None,
        plaid_webhook_url: None,
        trusted_proxy_cidrs: vec![],
        allowed_origins: vec!["http://localhost:3000".to_string()],
        cookie_secure: false,
        hibp_api_base: String::new(),
        android_apk_cert_sha256: vec![TEST_APK_CERT_HEX.to_string()],
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

    // Mirror main.rs: bootstrap lives on the public session router; the
    // passkeys management routes sit behind require_auth (NOT require_owner —
    // a read-only user manages their own credentials).
    let public = Router::new()
        .nest("/api/auth", patrimonio::api::session::public_router())
        // Digital Asset Links route, mounted exactly as main.rs does.
        .route(
            "/.well-known/assetlinks.json",
            axum::routing::get(patrimonio::api::passkeys::assetlinks),
        );

    let protected = Router::new()
        .nest(
            "/api/auth/passkeys",
            patrimonio::api::passkeys::protected_router(),
        )
        // Step-up + passkey-gated set-password, mounted exactly as
        // main.rs does (under /api/auth, behind require_auth).
        .nest(
            "/api/auth",
            patrimonio::api::passkeys::reauth_protected_router(),
        )
        // Plus the session protected router so tests can exercise
        // login/change-password side effects (session revocation).
        .nest("/api/auth", patrimonio::api::session::protected_router())
        .layer(from_fn_with_state(
            state.clone(),
            patrimonio::api::middleware::require_auth,
        ));

    let app = public.merge(protected).with_state(state);
    Some((app, pool, lock))
}

fn skip_if_no_db<T>(result: Option<T>) -> Option<T> {
    if result.is_none() {
        eprintln!("(skipping: set {TEST_DB_VAR} to enable passkey integration tests)");
    }
    result
}

async fn body_json(body: Body) -> Value {
    let bytes = to_bytes(body, 1024 * 64).await.expect("read body");
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

fn cookie_header(token: &str) -> HeaderValue {
    HeaderValue::from_str(&format!("{SESSION_COOKIE}={token}")).expect("cookie header")
}

fn get_request(uri: &str, cookie: &str) -> Request<Body> {
    Request::builder()
        .method(Method::GET)
        .uri(uri)
        .header(header::COOKIE, cookie_header(cookie))
        .body(Body::empty())
        .unwrap()
}

async fn bootstrap_owner(app: &Router) -> String {
    let req = Request::builder()
        .method(Method::POST)
        .uri("/api/auth/bootstrap")
        .header(header::CONTENT_TYPE, "application/json")
        .body(Body::from(
            serde_json::to_vec(&serde_json::json!({
                "username": "owner",
                "email": "owner@example.com",
                "password": "correcthorsebatterystaple"
            }))
            .unwrap(),
        ))
        .unwrap();
    let res = app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK, "bootstrap should succeed");
    set_cookie_value(res.headers()).expect("session cookie on bootstrap")
}

/// Seed a passkey row directly (the list endpoint never deserialises
/// `passkey_json`, so an empty object is enough to satisfy the NOT NULL).
async fn seed_passkey(pool: &PgPool, user_id: Uuid, cred_id: &[u8], nickname: &str) {
    sqlx::query(
        "INSERT INTO passkey_credentials (user_id, credential_id, passkey_json, nickname) \
         VALUES ($1, $2, $3, $4)",
    )
    .bind(user_id)
    .bind(cred_id)
    .bind(serde_json::json!({}))
    .bind(nickname)
    .execute(pool)
    .await
    .expect("seed passkey row");
}

#[tokio::test]
#[serial_test::serial]
async fn lists_every_passkey_a_user_holds() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let cookie = bootstrap_owner(&app).await;
    let user_id: Uuid = sqlx::query_scalar("SELECT id FROM users WHERE username = 'owner'")
        .fetch_one(&pool)
        .await
        .unwrap();

    // One key enrolled → list shows exactly it.
    seed_passkey(&pool, user_id, b"credential-id-AAAA", "Key A").await;
    let res = app
        .clone()
        .oneshot(get_request("/api/auth/passkeys", &cookie))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let one = body_json(res.into_body()).await;
    assert_eq!(one.as_array().unwrap().len(), 1, "first key must list");

    // Second DISTINCT key → BOTH must list. This is the regression the
    // user hit: the second passkey not appearing.
    seed_passkey(&pool, user_id, b"credential-id-BBBB", "Key B").await;
    let res = app
        .clone()
        .oneshot(get_request("/api/auth/passkeys", &cookie))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let both = body_json(res.into_body()).await;
    let arr = both.as_array().unwrap();
    assert_eq!(arr.len(), 2, "BOTH passkeys must appear in the list");
    let nicknames: Vec<&str> = arr
        .iter()
        .map(|p| p["nickname"].as_str().unwrap())
        .collect();
    assert!(nicknames.contains(&"Key A"));
    assert!(nicknames.contains(&"Key B"));

    // Removing one leaves the other — delete is scoped to the row id.
    let victim = arr.iter().find(|p| p["nickname"] == "Key A").unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::DELETE)
                .uri(format!("/api/auth/passkeys/{victim}"))
                .header(header::COOKIE, cookie_header(&cookie))
                .header("X-Requested-With", "fetch")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);

    let res = app
        .clone()
        .oneshot(get_request("/api/auth/passkeys", &cookie))
        .await
        .unwrap();
    let after = body_json(res.into_body()).await;
    let arr = after.as_array().unwrap();
    assert_eq!(arr.len(), 1, "only the removed key should be gone");
    assert_eq!(arr[0]["nickname"], "Key B");
}

#[tokio::test]
#[serial_test::serial]
async fn duplicate_credential_id_is_rejected_not_silently_upserted() {
    // The DB's UNIQUE(credential_id) is what backs the register_finish
    // 409: a credential we already hold cannot be inserted a second time.
    // This guards the storage invariant the 409 path relies on.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let _cookie = bootstrap_owner(&app).await;
    let user_id: Uuid = sqlx::query_scalar("SELECT id FROM users WHERE username = 'owner'")
        .fetch_one(&pool)
        .await
        .unwrap();
    seed_passkey(&pool, user_id, b"same-credential", "Original").await;
    let dup = sqlx::query(
        "INSERT INTO passkey_credentials (user_id, credential_id, passkey_json) \
         VALUES ($1, $2, $3)",
    )
    .bind(user_id)
    .bind(b"same-credential".as_slice())
    .bind(serde_json::json!({}))
    .execute(&pool)
    .await;
    assert!(
        dup.is_err(),
        "a duplicate credential_id must violate UNIQUE, not silently insert"
    );
}

// ---------------------------------------------------------------------------
// Passkey-gated set-password (step-up).
//
// The full WebAuthn assertion can't be forged without a software
// authenticator, so these tests pin down the GATES around it:
//   - reauth/start refuses when the user has no passkey (400)
//   - set-password rejects a missing / garbage / already-consumed nonce
//     (401) and leaves the password hash untouched
//   - a weak new_password is rejected by the policy (400) BEFORE the
//     nonce is consumed
//   - set-password requires auth (401 without a session cookie)
// The successful assertion path (verify → set hash → revoke sessions →
// audit row) is covered by the same finish_passkey_authentication used
// by the passkey LOGIN tests / frontend e2e; it can't be exercised here
// without a real authenticator.
// ---------------------------------------------------------------------------

fn post_json(uri: &str, cookie: Option<&str>, body: Value) -> Request<Body> {
    let mut builder = Request::builder()
        .method(Method::POST)
        .uri(uri)
        .header(header::CONTENT_TYPE, "application/json");
    if let Some(c) = cookie {
        builder = builder.header(header::COOKIE, cookie_header(c));
    }
    builder
        .body(Body::from(serde_json::to_vec(&body).unwrap()))
        .unwrap()
}

async fn password_hash(pool: &PgPool, user_id: Uuid) -> String {
    sqlx::query_scalar("SELECT password_hash FROM users WHERE id = $1")
        .bind(user_id)
        .fetch_one(pool)
        .await
        .unwrap()
}

#[tokio::test]
#[serial_test::serial]
async fn reauth_start_rejects_user_with_no_passkey() {
    let Some((app, _pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let cookie = bootstrap_owner(&app).await;
    // No passkey seeded → reauth/start must 400, never mint a challenge.
    let res = app
        .clone()
        .oneshot(post_json(
            "/api/auth/reauth/passkey/start",
            Some(&cookie),
            serde_json::json!({}),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
#[serial_test::serial]
async fn reauth_start_requires_authentication() {
    let Some((app, _pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let _ = bootstrap_owner(&app).await;
    // No cookie → require_auth rejects before the handler runs.
    let res = app
        .clone()
        .oneshot(post_json(
            "/api/auth/reauth/passkey/start",
            None,
            serde_json::json!({}),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
#[serial_test::serial]
async fn set_password_requires_authentication() {
    let Some((app, _pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let _ = bootstrap_owner(&app).await;
    let res = app
        .clone()
        .oneshot(post_json(
            "/api/auth/set-password",
            None,
            serde_json::json!({
                "nonce": "whatever",
                "credential": fake_assertion_credential(),
                "new_password": "correct-horse-battery-staple-9"
            }),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
#[serial_test::serial]
async fn set_password_with_unknown_nonce_is_rejected_and_password_unchanged() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let cookie = bootstrap_owner(&app).await;
    let user_id: Uuid = sqlx::query_scalar("SELECT id FROM users WHERE username = 'owner'")
        .fetch_one(&pool)
        .await
        .unwrap();
    // User even HAS a passkey — the missing pending state is what fails.
    seed_passkey(&pool, user_id, b"credential-id-XYZ", "Key").await;
    let before = password_hash(&pool, user_id).await;

    let res = app
        .clone()
        .oneshot(post_json(
            "/api/auth/set-password",
            Some(&cookie),
            serde_json::json!({
                "nonce": "this-nonce-was-never-issued",
                "credential": fake_assertion_credential(),
                "new_password": "correct-horse-battery-staple-9"
            }),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::UNAUTHORIZED,
        "an unknown/expired nonce must be 401, never let a password through"
    );

    let after = password_hash(&pool, user_id).await;
    assert_eq!(before, after, "password hash must be untouched on failure");

    // No success audit row should exist.
    let success_rows: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM auth_audit WHERE event = 'set_password_via_passkey' AND success = true",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(
        success_rows, 0,
        "no successful set-password audit on a rejected attempt"
    );

    // Sessions must NOT have been revoked — the original cookie still works.
    let res = app
        .clone()
        .oneshot(get_request("/api/auth/passkeys", &cookie))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::OK,
        "session must survive a failed set-password"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn set_password_rejects_weak_password_before_consuming_nonce() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let cookie = bootstrap_owner(&app).await;
    let user_id: Uuid = sqlx::query_scalar("SELECT id FROM users WHERE username = 'owner'")
        .fetch_one(&pool)
        .await
        .unwrap();
    let before = password_hash(&pool, user_id).await;

    // "password" is short + on the embedded breach list → policy rejects
    // with 400 (NOT 401), and the hash is unchanged.
    let res = app
        .clone()
        .oneshot(post_json(
            "/api/auth/set-password",
            Some(&cookie),
            serde_json::json!({
                "nonce": "irrelevant",
                "credential": fake_assertion_credential(),
                "new_password": "password"
            }),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::BAD_REQUEST,
        "weak password must be rejected by the policy with 400"
    );
    let after = password_hash(&pool, user_id).await;
    assert_eq!(before, after, "password hash must be untouched");
}

/// A spec-shaped but bogus assertion credential. It's enough to let the
/// JSON deserialize into `PublicKeyCredential`; the request is rejected
/// long before the assertion is verified (no pending state / bad
/// password), so the contents never need to be cryptographically valid.
fn fake_assertion_credential() -> Value {
    serde_json::json!({
        "id": "AAAAAAAAAAAAAAAAAAAAAA",
        "rawId": "AAAAAAAAAAAAAAAAAAAAAA",
        "type": "public-key",
        "response": {
            "authenticatorData": "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
            "clientDataJSON": "e30",
            "signature": "AAAA"
        },
        "extensions": {}
    })
}

// ---------------------------------------------------------------------------
// /.well-known/assetlinks.json — native Android passkey support.
// ---------------------------------------------------------------------------

/// With ANDROID_APK_CERT_SHA256 configured, the DAL statement must carry
/// the package name and the UPPERCASE COLON-SEPARATED form of the same
/// digest — the exact format Google's verifier compares against
/// `apksigner`'s output. A formatting drift here silently disables
/// native passkeys on every device.
#[tokio::test]
#[serial_test::serial]
async fn assetlinks_serves_cert_fingerprint_in_dal_format() {
    let Some((app, _pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let req = Request::builder()
        .method(Method::GET)
        .uri("/.well-known/assetlinks.json")
        .body(Body::empty())
        .unwrap();
    let res = app.clone().oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK, "assetlinks should serve");
    let body = body_json(res.into_body()).await;
    let stmt = &body[0];
    assert_eq!(stmt["target"]["namespace"], "android_app");
    assert_eq!(stmt["target"]["package_name"], "com.patrimonio.patrimonio");
    assert_eq!(
        stmt["target"]["sha256_cert_fingerprints"][0],
        "E1:EF:25:49:AD:E5:5B:49:A6:78:77:2F:D2:74:A8:A0:8A:54:62:47:14:6A:38:84:62:CB:47:02:6F:C5:02:8D"
    );
    let relations = stmt["relation"].as_array().expect("relation array");
    assert!(
        relations
            .iter()
            .any(|r| r == "delegate_permission/common.get_login_creds"),
        "passkey credential-sharing relation must be present"
    );
}

/// No configured cert → 404, not an empty statement list. An empty `[]`
/// would make Google's verifier cache "this app is NOT authorized" for
/// the domain, which is worse than unreachable.
#[tokio::test]
#[serial_test::serial]
async fn assetlinks_404s_when_unconfigured() {
    let Some((_app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let config = AppConfig {
        database_url: std::env::var(TEST_DB_VAR).unwrap(),
        database_max_connections: 2,
        redis_url: "redis://127.0.0.1:6379".to_string(),
        port: 0,
        plaid_client_id: None,
        plaid_secret: None,
        plaid_env: "sandbox".to_string(),
        exchange_rate_api_key: None,
        encryption_key: None,
        coinbase_client_id: None,
        coinbase_client_secret: None,
        coinbase_redirect_uri: "http://localhost/api/auth/coinbase/callback".to_string(),
        frontend_base_url: "http://localhost:3000".to_string(),
        plaid_redirect_uri: None,
        plaid_android_package_name: None,
        plaid_webhook_url: None,
        trusted_proxy_cidrs: vec![],
        allowed_origins: vec!["http://localhost:3000".to_string()],
        cookie_secure: false,
        hibp_api_base: String::new(),
        android_apk_cert_sha256: vec![], // <- the unconfigured case
        android_package_name: "com.patrimonio.patrimonio".to_string(),
    };
    let state = AppState {
        db: pool.clone(),
        redis: redis::Client::open(config.redis_url.clone()).expect("redis client"),
        config: Arc::new(config),
        webauthn: Arc::new(
            patrimonio::api::passkeys::build_webauthn("http://localhost:3000", &[])
                .expect("webauthn builder"),
        ),
        realtime: patrimonio::services::realtime::Realtime::new(),
    };
    let app = Router::new()
        .route(
            "/.well-known/assetlinks.json",
            axum::routing::get(patrimonio::api::passkeys::assetlinks),
        )
        .with_state(state);
    let req = Request::builder()
        .method(Method::GET)
        .uri("/.well-known/assetlinks.json")
        .body(Body::empty())
        .unwrap();
    let res = app.oneshot(req).await.unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
}
