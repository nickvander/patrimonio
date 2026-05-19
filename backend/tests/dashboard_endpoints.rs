//! HTTP-level integration tests for dashboard + institutions endpoints
//! that landed in the recent sprints (since-last-login, subscriptions
//! ignore/unignore, transaction splits + edit-split flow, the
//! `/api/institutions/update-webhook` one-shot, and the SQL-rewritten
//! `/api/dashboard/net-worth-history`).
//!
//! Like `auth_endpoints.rs`, these need a real Postgres reachable via
//! `PATRIMONIO_TEST_DATABASE_URL`. When the env var is unset the
//! tests print a skip note and return Ok so `cargo test` stays green
//! for contributors without a DB on hand.
//!
//! Schema is reset between tests via `TRUNCATE ... RESTART IDENTITY
//! CASCADE` so they can run in any order against the same DB.

use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{header, HeaderValue, Method, Request, StatusCode};
use axum::middleware::from_fn_with_state;
use axum::Router;
use rust_decimal::Decimal;
use serde_json::Value;
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use std::str::FromStr;
use tower::ServiceExt;

use patrimonio::config::AppConfig;
use patrimonio::AppState;

const TEST_DB_VAR: &str = "PATRIMONIO_TEST_DATABASE_URL";
const SESSION_COOKIE: &str = "patrimonio_session";

/// Build the full protected + public router so the tests exercise the
/// same middleware stack as production (CSRF outer layer, auth inner
/// layer). The plaid creds + webhook URL are caller-tunable so we
/// can cover the 503/400/200 branches of `update-webhook`.
async fn try_setup(
    plaid_creds: bool,
    plaid_webhook_url: Option<&str>,
) -> Option<(Router, PgPool)> {
    let database_url = std::env::var(TEST_DB_VAR).ok()?;
    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect(&database_url)
        .await
        .expect("connect to test DB");

    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .expect("apply migrations to test DB");

    // Clean slate — every table the dashboard / split / subscriptions
    // surfaces touch. CASCADE handles balance_snapshots, transactions,
    // accounts via the institutions foreign keys.
    sqlx::query(
        "TRUNCATE \
         cash_fx_transfers, ignored_subscription_merchants, \
         auth_audit, user_sessions, app_settings, \
         transactions, balance_snapshots, accounts, institutions, \
         users RESTART IDENTITY CASCADE",
    )
    .execute(&pool)
    .await
    .expect("truncate dashboard tables");

    let config = AppConfig {
        database_url: database_url.clone(),
        database_max_connections: 2,
        redis_url: "redis://127.0.0.1:6379".to_string(),
        port: 0,
        plaid_client_id: plaid_creds.then(|| "test-client".to_string()),
        plaid_secret: plaid_creds.then(|| "test-secret".to_string()),
        plaid_env: "sandbox".to_string(),
        exchange_rate_api_key: None,
        // The update-webhook endpoint needs an encryption key configured
        // even when there are no items to update, because it short-
        // circuits on its absence with 500. Always provide a dummy.
        encryption_key: Some("a".repeat(32)),
        coinbase_client_id: None,
        coinbase_client_secret: None,
        coinbase_redirect_uri: "http://localhost/api/auth/coinbase/callback".to_string(),
        frontend_base_url: "http://localhost:3000".to_string(),
        plaid_redirect_uri: None,
        plaid_webhook_url: plaid_webhook_url.map(str::to_string),
        allowed_origins: vec!["http://localhost:3000".to_string()],
        cookie_secure: false,
        trusted_proxy_cidrs: vec![],
    };

    let redis = redis::Client::open(config.redis_url.clone()).expect("redis client");
    let webauthn = std::sync::Arc::new(
        patrimonio::api::passkeys::build_webauthn(&config.frontend_base_url)
            .expect("webauthn builder"),
    );
    let state = AppState {
        db: pool.clone(),
        redis,
        config: Arc::new(config),
        webauthn,
    };

    // Mirror main.rs's mounting so middleware order matches prod.
    let public = Router::new()
        .nest("/api/auth", patrimonio::api::session::public_router())
        .nest("/api/setup", patrimonio::api::setup::router());

    let protected = Router::new()
        .nest("/api/accounts", patrimonio::api::accounts::router())
        .nest("/api/institutions", patrimonio::api::institutions::router())
        .nest("/api/dashboard", patrimonio::api::dashboard::router())
        .nest("/api/auth", patrimonio::api::session::protected_router())
        .layer(from_fn_with_state(
            state.clone(),
            patrimonio::api::session::require_auth,
        ))
        .layer(axum::middleware::from_fn(
            patrimonio::api::session::require_csrf_header,
        ));

    let app = public.merge(protected).with_state(state);

    Some((app, pool))
}

fn skip_if_no_db<T>(result: Option<T>) -> Option<T> {
    if result.is_none() {
        eprintln!(
            "(skipping: set {TEST_DB_VAR}=postgres://user:pass@host/db to enable dashboard integration tests)"
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

fn cookie_header(token: &str) -> HeaderValue {
    HeaderValue::from_str(&format!("{SESSION_COOKIE}={token}"))
        .expect("valid cookie header")
}

/// Build a request with the right cookie + CSRF header + JSON body.
/// The CSRF middleware short-circuits mutating requests without
/// `X-Requested-With`, so every POST/PATCH/PUT/DELETE we send needs
/// the header — bake it in by default to avoid forgetting in
/// individual tests.
fn req(
    method: Method,
    uri: &str,
    body: Option<&Value>,
    cookie: Option<&str>,
) -> Request<Body> {
    let needs_csrf = matches!(
        method,
        Method::POST | Method::PATCH | Method::DELETE | Method::PUT,
    );
    let mut builder = Request::builder().method(method).uri(uri);
    if needs_csrf {
        builder = builder.header("X-Requested-With", "patrimonio");
    }
    if let Some(token) = cookie {
        builder = builder.header(header::COOKIE, cookie_header(token));
    }
    if let Some(b) = body {
        builder = builder.header(header::CONTENT_TYPE, "application/json");
        builder.body(Body::from(serde_json::to_vec(b).unwrap())).unwrap()
    } else {
        builder.body(Body::empty()).unwrap()
    }
}

/// Bootstrap the first user + return their session cookie + UUID. The
/// integration suite starts from a fresh DB every test, so the
/// bootstrap path is reusable as the "create a real authenticated
/// user" primitive.
async fn bootstrap(app: &Router, pool: &PgPool) -> (String, uuid::Uuid) {
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/auth/bootstrap",
            Some(&serde_json::json!({
                "username": "owner",
                "email": "owner@example.com",
                "password": "correcthorsebatterystaple"
            })),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "bootstrap should succeed");
    let token = set_cookie_value(res.headers()).expect("bootstrap should set cookie");
    let user_id: uuid::Uuid = sqlx::query_scalar("SELECT id FROM users LIMIT 1")
        .fetch_one(pool)
        .await
        .expect("user row exists after bootstrap");
    (token, user_id)
}

/// Seed one institution + one account for the given user. Returns
/// `(institution_id, account_id)`. Account is a USD checking with a
/// $1000 balance so the dashboard widgets have something to render.
async fn seed_account(pool: &PgPool, user_id: uuid::Uuid) -> (uuid::Uuid, uuid::Uuid) {
    let inst_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ('Test Bank', 'bank', 'US', 'manual', 'ok', $1) RETURNING id",
    )
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed institution");
    let acct_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Checking', 'depository', 'USD', 1000.00, $2) RETURNING id",
    )
    .bind(inst_id)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed account");
    (inst_id, acct_id)
}

/// Insert one transaction. Returns its id.
async fn seed_tx(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    description: &str,
    amount: &str,
) -> uuid::Uuid {
    sqlx::query_scalar(
        "INSERT INTO transactions (account_id, date, description, amount, currency, source, user_id) \
         VALUES ($1, CURRENT_DATE, $2, $3, 'USD', 'manual', $4) RETURNING id",
    )
    .bind(account_id)
    .bind(description)
    .bind(Decimal::from_str(amount).unwrap())
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed tx")
}

// =====================================================================
// /api/institutions/update-webhook
// =====================================================================

#[tokio::test]
async fn update_webhook_503_when_plaid_creds_missing() {
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/institutions/update-webhook",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["error"], "Plaid is not configured");
}

#[tokio::test]
async fn update_webhook_400_when_url_missing() {
    // Plaid creds set, but PLAID_WEBHOOK_URL is None → 400.
    let Some((app, pool)) = skip_if_no_db(try_setup(true, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/institutions/update-webhook",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["error"], "PLAID_WEBHOOK_URL is not set");
}

#[tokio::test]
async fn update_webhook_200_with_zero_when_no_items_linked() {
    // Plaid creds + URL set, but user has no Plaid items → 200 with
    // updated=0, failed=0 (no Plaid API call attempted).
    let Some((app, pool)) =
        skip_if_no_db(try_setup(true, Some("https://example.com/api/institutions/webhook")).await)
    else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/institutions/update-webhook",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["updated"], 0);
    assert_eq!(body["failed"], 0);
    assert_eq!(
        body["webhook_url"],
        "https://example.com/api/institutions/webhook"
    );
    assert!(body["results"].as_array().unwrap().is_empty());
}

#[tokio::test]
async fn update_webhook_unauthenticated_is_401() {
    let Some((app, _pool)) = skip_if_no_db(try_setup(true, Some("https://example.com")).await)
    else {
        return;
    };
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/institutions/update-webhook",
            None,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
async fn update_webhook_without_csrf_header_is_403() {
    let Some((app, pool)) = skip_if_no_db(try_setup(true, Some("https://example.com")).await)
    else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    // Same request as above but missing X-Requested-With. CSRF
    // middleware sits OUTSIDE auth, so this is 403 (not 401).
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/institutions/update-webhook")
                .header(header::COOKIE, cookie_header(&token))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);
}

// =====================================================================
// /api/accounts/transactions/{id}/splits — split + unsplit + edit-split
// =====================================================================

#[tokio::test]
async fn split_creates_children_and_hides_parent_in_listing() {
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let parent = seed_tx(&pool, user_id, account, "Costco run", "200.00").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "Groceries", "amount": "120.00"},
                    {"description": "Household", "amount": "80.00"}
                ]
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Listing hides the parent now (NOT EXISTS-children filter), but
    // both children should appear with parent_id set.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/transactions?limit=100",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().unwrap();
    let parent_visible = rows
        .iter()
        .any(|r| r["id"].as_str().unwrap_or_default() == parent.to_string());
    assert!(!parent_visible, "parent should be hidden once it has children");
    let child_count = rows
        .iter()
        .filter(|r| r["parent_id"].as_str().unwrap_or_default() == parent.to_string())
        .count();
    assert_eq!(child_count, 2, "both children should appear");
}

#[tokio::test]
async fn split_rejects_total_mismatch() {
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let parent = seed_tx(&pool, user_id, account, "Off-by-one", "100.00").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "A", "amount": "60.00"},
                    {"description": "B", "amount": "30.00"}
                ]
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
async fn split_rejects_sign_mismatch() {
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let parent = seed_tx(&pool, user_id, account, "Sign mix", "100.00").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "A", "amount": "150.00"},
                    {"description": "B", "amount": "-50.00"}
                ]
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
async fn split_already_split_returns_422() {
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let parent = seed_tx(&pool, user_id, account, "Already split", "100.00").await;

    let payload = serde_json::json!({
        "splits": [
            {"description": "A", "amount": "60.00"},
            {"description": "B", "amount": "40.00"}
        ]
    });
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&payload),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Second attempt without unsplit first.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&payload),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNPROCESSABLE_ENTITY);
    let body = body_json(res.into_body()).await;
    assert!(
        body["error"]
            .as_str()
            .unwrap_or("")
            .contains("already split"),
        "expected 'already split' error, got: {:?}",
        body
    );
}

#[tokio::test]
async fn edit_split_via_unsplit_then_resplit() {
    // This mirrors what the frontend does for the "Edit split" button:
    // DELETE the children, then re-POST a new split set.
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let parent = seed_tx(&pool, user_id, account, "Roundtrip", "100.00").await;

    // First split.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "A1", "amount": "50.00"},
                    {"description": "B1", "amount": "50.00"}
                ]
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Unsplit returns 200 with `{"removed": N}` on success.
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/accounts/transactions/{parent}/splits"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["removed"], 2);

    // Children should be gone, parent visible again.
    let children: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM transactions WHERE parent_id = $1",
    )
    .bind(parent)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(children, 0);

    // Re-split with new amounts (60/40 instead of 50/50).
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "A2", "amount": "60.00"},
                    {"description": "B2", "amount": "40.00"}
                ]
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let amounts: Vec<Decimal> = sqlx::query_scalar(
        "SELECT amount FROM transactions WHERE parent_id = $1 ORDER BY amount DESC",
    )
    .bind(parent)
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(amounts.len(), 2);
    assert_eq!(amounts[0], Decimal::from_str("60.00").unwrap());
    assert_eq!(amounts[1], Decimal::from_str("40.00").unwrap());
}

#[tokio::test]
async fn unsplit_nonexistent_parent_is_404() {
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            "/api/accounts/transactions/00000000-0000-0000-0000-000000000000/splits",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
async fn split_cross_user_is_404() {
    // User A's parent transaction should be invisible to user B.
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token_a, user_a) = bootstrap(&app, &pool).await;
    let (_inst, account_a) = seed_account(&pool, user_a).await;
    let parent = seed_tx(&pool, user_a, account_a, "A's tx", "100.00").await;

    // Hand-roll user B (the bootstrap path is owner-only; a second
    // user comes from an invite). We bypass the invite mint for
    // brevity by inserting directly.
    let user_b: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, email, password_hash) \
         VALUES ('bob', 'bob@example.com', 'doesnt-matter-for-this-test') RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .expect("seed user b");
    // Use the production session helper so the SHA-256 of the
    // raw token + the BYTEA encoding match exactly what
    // require_auth expects.
    let token_b = patrimonio::services::sessions::create_session(&pool, user_b, None, None)
        .await
        .expect("create user b session")
        .token;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "A", "amount": "50"},
                    {"description": "B", "amount": "50"}
                ]
            })),
            Some(&token_b),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
    // And token_a should still be able to split its own row.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "A", "amount": "50"},
                    {"description": "B", "amount": "50"}
                ]
            })),
            Some(&token_a),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
}

// =====================================================================
// /api/dashboard/since-last-login
// =====================================================================

#[tokio::test]
async fn since_last_login_empty_when_no_previous_login() {
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/since-last-login",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    // Fresh bootstrap leaves previous_login_at NULL, so we get a
    // no-op envelope with new_transactions=0.
    assert_eq!(body["new_transactions"], 0);
    assert!(body["previous_login_at"].is_null() || body["previous_login_at"] == Value::Null);
}

#[tokio::test]
async fn since_last_login_counts_new_transactions() {
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;

    // Fake a previous login 24h ago.
    sqlx::query(
        "UPDATE users SET previous_login_at = NOW() - INTERVAL '24 hours' WHERE id = $1",
    )
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();
    // Seed two transactions — both created_at NOW(), so after the anchor.
    seed_tx(&pool, user_id, account, "After anchor 1", "10.00").await;
    seed_tx(&pool, user_id, account, "After anchor 2", "20.00").await;
    // Plus one split parent + its children, which should NOT count (parents are excluded).
    let parent = seed_tx(&pool, user_id, account, "Will be split", "30.00").await;
    sqlx::query(
        "INSERT INTO transactions (account_id, parent_id, date, description, amount, currency, source, user_id) \
         VALUES ($1, $2, CURRENT_DATE, 'child1', 15.00, 'USD', 'split', $3), \
                ($1, $2, CURRENT_DATE, 'child2', 15.00, 'USD', 'split', $3)",
    )
    .bind(account)
    .bind(parent)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/since-last-login",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    // 2 non-split + 2 children = 4. (The parent row is now hidden by
    // the NOT EXISTS-children filter — that's the contract.)
    assert_eq!(body["new_transactions"], 4);
    assert!(body["previous_login_at"].as_str().is_some());
}

// =====================================================================
// /api/dashboard/subscriptions/ignore + /ignored
// =====================================================================

#[tokio::test]
async fn subscription_ignore_then_unignore_roundtrip() {
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    // Ignore (POST). Backend lowercases + trims the key.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/dashboard/subscriptions/ignore",
            Some(&serde_json::json!({"merchant": "  Interest Earned  "})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);

    // List should include the lowercased + trimmed key.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/subscriptions/ignored",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["merchant_key"], "interest earned");

    // Idempotent re-ignore (POST again) is still 204, no duplicate row.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/dashboard/subscriptions/ignore",
            Some(&serde_json::json!({"merchant": "interest earned"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    let count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM ignored_subscription_merchants WHERE merchant_key = 'interest earned'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(count, 1);

    // Unignore (DELETE).
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            "/api/dashboard/subscriptions/ignored/interest%20earned",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/subscriptions/ignored",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert_eq!(body.as_array().unwrap().len(), 0);
}

#[tokio::test]
async fn subscription_ignore_rejects_empty_key() {
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/dashboard/subscriptions/ignore",
            Some(&serde_json::json!({"merchant": "   "})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
}

// =====================================================================
// /api/dashboard/fx-transfers
// =====================================================================

#[tokio::test]
async fn fx_transfers_listing_empty() {
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/fx-transfers",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert!(body.as_array().unwrap().is_empty());
}

// =====================================================================
// /api/dashboard/net-worth-history (the SQL-rewritten endpoint)
// =====================================================================

#[tokio::test]
async fn net_worth_history_aggregates_per_date_and_institution() {
    // Seed snapshots across two institutions on two dates so we can
    // check the per-institution map. This exercises the SQL rewrite
    // (jsonb_object_agg) directly.
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst1, account1) = seed_account(&pool, user_id).await;
    // Second institution with a different name.
    let inst2: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ('Brokerage', 'brokerage', 'US', 'manual', 'ok', $1) RETURNING id",
    )
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    let account2: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'IRA', 'investment', 'USD', 5000.00, $2) RETURNING id",
    )
    .bind(inst2)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();

    // Snapshots on two days for both accounts.
    let insert_snap = |acct: uuid::Uuid, balance: &'static str, day: &'static str| {
        let pool = pool.clone();
        async move {
            sqlx::query(
                "INSERT INTO balance_snapshots (account_id, balance, balance_usd, as_of_date, currency, user_id) \
                 VALUES ($1, $2::numeric, $2::numeric, $3::date, 'USD', $4)",
            )
            .bind(acct)
            .bind(balance)
            .bind(day)
            .bind(user_id)
            .execute(&pool)
            .await
            .unwrap();
        }
    };
    insert_snap(account1, "1000.00", "2026-05-01").await;
    insert_snap(account2, "5000.00", "2026-05-01").await;
    insert_snap(account1, "1100.00", "2026-05-02").await;
    insert_snap(account2, "5200.00", "2026-05-02").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/net-worth-history",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().unwrap();
    assert_eq!(rows.len(), 2, "two distinct as_of_dates");
    // Rows are ascending by date.
    assert_eq!(rows[0]["date"], "2026-05-01");
    assert_eq!(rows[1]["date"], "2026-05-02");
    // Day 1 net worth = 1000 + 5000.
    assert!((rows[0]["net_worth"].as_f64().unwrap() - 6000.0).abs() < 0.01);
    // Day 2 net worth = 1100 + 5200.
    assert!((rows[1]["net_worth"].as_f64().unwrap() - 6300.0).abs() < 0.01);
    // Per-institution map is populated.
    let by_inst = rows[1]["by_institution"].as_object().unwrap();
    assert!((by_inst["Test Bank"].as_f64().unwrap() - 1100.0).abs() < 0.01);
    assert!((by_inst["Brokerage"].as_f64().unwrap() - 5200.0).abs() < 0.01);
}

#[tokio::test]
async fn net_worth_history_handles_liabilities() {
    // A credit-card liability should show up as a NEGATIVE in
    // by_institution AND reduce net_worth. Tests the is_liability
    // classifier wired into the new CTE.
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let inst: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ('Plastic Co', 'bank', 'US', 'manual', 'ok', $1) RETURNING id",
    )
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    let card: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Visa', 'credit', 'USD', 500.00, $2) RETURNING id",
    )
    .bind(inst)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO balance_snapshots (account_id, balance, balance_usd, as_of_date, currency, user_id) \
         VALUES ($1, 500.00, 500.00, '2026-05-01'::date, 'USD', $2)",
    )
    .bind(card)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/net-worth-history",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let row = &body.as_array().unwrap()[0];
    assert!((row["total_liabilities"].as_f64().unwrap() - 500.0).abs() < 0.01);
    assert!((row["total_assets"].as_f64().unwrap() - 0.0).abs() < 0.01);
    assert!((row["net_worth"].as_f64().unwrap() - -500.0).abs() < 0.01);
    let by_inst = row["by_institution"].as_object().unwrap();
    assert!((by_inst["Plastic Co"].as_f64().unwrap() - -500.0).abs() < 0.01);
}
