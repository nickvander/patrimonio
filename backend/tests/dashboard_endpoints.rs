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
//! CASCADE`. The tests share a single Postgres so they MUST run
//! serially — run the suite with `cargo test -- --test-threads=1`.
//! Parallel execution leads to one test's TRUNCATE wiping another's
//! data mid-flight and surfaces as random 500s on bootstrap.
//!
//! Easiest invocation from the repo root:
//!
//!     ./scripts/test.sh
//!
//! That wrapper handles the dockerised toolchain, ensures the test
//! DB exists, sets the env var, and threads `--test-threads=1`.

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

mod common;
use common::TestLockGuard;

const TEST_DB_VAR: &str = "PATRIMONIO_TEST_DATABASE_URL";
const SESSION_COOKIE: &str = "patrimonio_session";

/// Build the full protected + public router so the tests exercise the
/// same middleware stack as production (CSRF outer layer, auth inner
/// layer). The plaid creds + webhook URL are caller-tunable so we
/// can cover the 503/400/200 branches of `update-webhook`.
async fn try_setup(
    plaid_creds: bool,
    plaid_webhook_url: Option<&str>,
) -> Option<(Router, PgPool, TestLockGuard)> {
    let database_url = std::env::var(TEST_DB_VAR).ok()?;
    // Cross-binary serialisation: block here until no other test
    // (in any binary) is mid-flight against the shared test DB.
    // The lock holds until the returned guard drops at end of test.
    // See tests/common/mod.rs for the rationale.
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

    // Clean slate — every table the dashboard / split / subscriptions
    // surfaces touch. CASCADE handles balance_snapshots, transactions,
    // accounts via the institutions foreign keys.
    sqlx::query(
        "TRUNCATE \
         loan_payments, loans, people, \
         cash_fx_transfers, ignored_subscription_merchants, \
         exchange_rates, lot_disposals, holding_lots, holdings, \
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
        hibp_api_base: String::new(),
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
        realtime: patrimonio::services::realtime::Realtime::new(),
    };

    // Mirror main.rs's mounting so middleware order matches prod.
    let public = Router::new()
        .nest("/api/auth", patrimonio::api::session::public_router())
        .nest("/api/setup", patrimonio::api::setup::router());

    // Two-tier protected router mirroring main.rs's split:
    // `business` routes get `require_owner`, `account_mgmt`
    // (auth/session) routes don't. Without this split the
    // require_owner role gate isn't exercised by the test suite.
    let business = Router::new()
        .nest("/api/accounts", patrimonio::api::accounts::router())
        .nest("/api/institutions", patrimonio::api::institutions::router())
        .nest("/api/dashboard", patrimonio::api::dashboard::router())
        .nest("/api/imports", patrimonio::api::imports::router())
        .nest("/api/loans", patrimonio::api::loans::router())
        .layer(axum::middleware::from_fn(
            patrimonio::api::session::require_owner,
        ));
    let account_mgmt =
        Router::new().nest("/api/auth", patrimonio::api::session::protected_router());
    let protected = business
        .merge(account_mgmt)
        .layer(from_fn_with_state(
            state.clone(),
            patrimonio::api::session::require_auth,
        ))
        .layer(axum::middleware::from_fn(
            patrimonio::api::session::require_csrf_header,
        ));

    let app = public.merge(protected).with_state(state);

    Some((app, pool, lock))
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
#[serial_test::serial]
async fn update_webhook_503_when_plaid_creds_missing() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
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
#[serial_test::serial]
async fn update_webhook_400_when_url_missing() {
    // Plaid creds set, but PLAID_WEBHOOK_URL is None → 400.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(true, None).await) else {
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
#[serial_test::serial]
async fn update_webhook_200_with_zero_when_no_items_linked() {
    // Plaid creds + URL set, but user has no Plaid items → 200 with
    // updated=0, failed=0 (no Plaid API call attempted).
    let Some((app, pool, _lock)) =
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
#[serial_test::serial]
async fn update_webhook_unauthenticated_is_401() {
    let Some((app, _pool, _lock)) = skip_if_no_db(try_setup(true, Some("https://example.com")).await)
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
#[serial_test::serial]
async fn update_webhook_without_csrf_header_is_403() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(true, Some("https://example.com")).await)
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
// /api/imports/upload — CSRF gate + auth gate + empty-body shape
// =====================================================================
// These tests exist because the frontend `uploadStatements` silently
// 403-ed for a week — the multipart helper bypassed `_withCsrf` so
// PDFs never reached the handler. The gate-level tests below catch
// that class of regression even without a real PDF fixture.

#[tokio::test]
#[serial_test::serial]
async fn upload_unauthenticated_is_401() {
    let Some((app, _pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    // With CSRF but no session cookie. Should hit require_auth → 401.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/imports/upload")
                .header("X-Requested-With", "patrimonio-test")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
#[serial_test::serial]
async fn upload_without_csrf_is_403() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    // No X-Requested-With → CSRF middleware short-circuits with 403
    // BEFORE the handler runs. This is the exact failure mode the
    // frontend was hitting silently.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/imports/upload")
                .header(header::COOKIE, cookie_header(&token))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
#[serial_test::serial]
async fn upload_with_no_files_is_400() {
    // CSRF + auth pass; multipart parses zero files → 400 "No files
    // were found in the upload request." Single-shot JSON response
    // (not NDJSON) because we never reach the spawn point.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/imports/upload")
                .header(header::COOKIE, cookie_header(&token))
                .header("X-Requested-With", "patrimonio-test")
                // Valid (empty) multipart body — boundary declared,
                // zero parts. Axum's multipart parser accepts the
                // empty body and the handler returns 400 on the
                // post-parse "no files" check.
                .header(
                    header::CONTENT_TYPE,
                    "multipart/form-data; boundary=----testboundary",
                )
                .body(Body::from("------testboundary--\r\n"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["status"], "error");
    assert!(body["message"]
        .as_str()
        .unwrap_or("")
        .contains("No files"));
}

// =====================================================================
// /api/accounts/transactions/{id}/splits — split + unsplit + edit-split
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn split_creates_children_and_hides_parent_in_listing() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
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
#[serial_test::serial]
async fn split_rejects_total_mismatch() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
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
#[serial_test::serial]
async fn split_rejects_sign_mismatch() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
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
#[serial_test::serial]
async fn split_already_split_returns_422() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
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
#[serial_test::serial]
async fn put_replace_splits_atomic() {
    // The new PUT endpoint replaces children atomically — no window
    // where the parent appears un-split to a concurrent reader.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let parent = seed_tx(&pool, user_id, account, "Atomic edit", "100.00").await;

    // Initial split.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "A", "amount": "50.00"},
                    {"description": "B", "amount": "50.00"}
                ]
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Replace via PUT — no unsplit step needed.
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "X", "amount": "30.00"},
                    {"description": "Y", "amount": "30.00"},
                    {"description": "Z", "amount": "40.00"}
                ]
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["removed"], 2);
    assert_eq!(body["inserted"], 3);

    let amounts: Vec<Decimal> = sqlx::query_scalar(
        "SELECT amount FROM transactions WHERE parent_id = $1 ORDER BY amount DESC",
    )
    .bind(parent)
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(amounts.len(), 3);
    assert_eq!(amounts[0], Decimal::from_str("40.00").unwrap());
    assert_eq!(amounts[1], Decimal::from_str("30.00").unwrap());
    assert_eq!(amounts[2], Decimal::from_str("30.00").unwrap());
}

#[tokio::test]
#[serial_test::serial]
async fn put_replace_splits_rejects_total_mismatch() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let parent = seed_tx(&pool, user_id, account, "Bad replace", "100.00").await;

    // Pre-existing split.
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "A", "amount": "60.00"},
                    {"description": "B", "amount": "40.00"}
                ]
            })),
            Some(&token),
        ))
        .await
        .unwrap();

    // Replace with totals that don't match — must 422, and crucially
    // must NOT delete the existing children before failing
    // (transactional rollback).
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "X", "amount": "10.00"},
                    {"description": "Y", "amount": "20.00"}
                ]
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNPROCESSABLE_ENTITY);

    // Original children should still be there. The validation runs
    // before the BEGIN ... DELETE ... INSERT block.
    let count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM transactions WHERE parent_id = $1",
    )
    .bind(parent)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(count, 2);
}

#[tokio::test]
#[serial_test::serial]
async fn edit_split_via_unsplit_then_resplit() {
    // This mirrors what the frontend does for the "Edit split" button:
    // DELETE the children, then re-POST a new split set.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
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
#[serial_test::serial]
async fn unsplit_nonexistent_parent_is_404() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
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
#[serial_test::serial]
async fn split_cross_user_is_404() {
    // User A's parent transaction should be invisible to user B.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
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
#[serial_test::serial]
async fn since_last_login_empty_when_no_previous_login() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
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
#[serial_test::serial]
async fn since_last_login_counts_new_transactions() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
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
#[serial_test::serial]
async fn subscription_ignore_then_unignore_roundtrip() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
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
#[serial_test::serial]
async fn subscription_ignore_rejects_empty_key() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
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
#[serial_test::serial]
async fn fx_transfers_listing_empty() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
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

/// When a transfer exists and there's an `exchange_rates` row near the
/// source date, the endpoint should populate `spot_fx_rate` so the
/// frontend can render "Wise gave you 19.40, market was 19.62"
/// without a separate FX lookup per row. Locks in the per-date
/// subquery rewrite added for the cross-currency cash-flow card.
#[tokio::test]
#[serial_test::serial]
async fn fx_transfers_listing_populates_spot_rate() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;

    // Two transactions on the same day: USD outflow + MXN inflow.
    let src_id = seed_tx(&pool, user_id, account, "WISE transfer", "-1000.00").await;
    let dst_id = seed_tx(&pool, user_id, account, "Nu Bank deposit", "19500.00").await;

    // Spot rate two days ahead of source-date: 19.62 USD→MXN.
    // (Within the ±7d window the endpoint searches.)
    sqlx::query(
        "INSERT INTO exchange_rates (base_currency, target_currency, rate, recorded_at) \
         VALUES ('USD', 'MXN', 19.62, NOW() + INTERVAL '2 days')",
    )
    .execute(&pool)
    .await
    .expect("seed spot rate");

    // Link the pair at the implied (Wise) rate of 19.50.
    sqlx::query(
        "INSERT INTO cash_fx_transfers (user_id, source_tx_id, dest_tx_id, \
         source_amount, source_currency, dest_amount, dest_currency, \
         implied_fx_rate, detection_confidence, user_confirmed, matched_keyword) \
         VALUES ($1, $2, $3, 1000.00, 'USD', 19500.00, 'MXN', 19.50, 90, true, 'WISE')",
    )
    .bind(user_id)
    .bind(src_id)
    .bind(dst_id)
    .execute(&pool)
    .await
    .expect("seed fx transfer");

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
    let arr = body.as_array().unwrap();
    assert_eq!(arr.len(), 1, "exactly one linked transfer expected");
    let entry = &arr[0];
    let implied = entry["implied_fx_rate"].as_f64().unwrap();
    let spot = entry["spot_fx_rate"].as_f64();
    assert!((implied - 19.5).abs() < 0.001, "implied 19.50 expected, got {implied}");
    assert!(
        spot.is_some() && (spot.unwrap() - 19.62).abs() < 0.001,
        "spot rate 19.62 expected, got {spot:?}"
    );
}

// =====================================================================
// /api/dashboard/net-worth-history (the SQL-rewritten endpoint)
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn net_worth_history_aggregates_per_date_and_institution() {
    // Seed snapshots across two institutions on two dates so we can
    // check the per-institution map. This exercises the SQL rewrite
    // (jsonb_object_agg) directly.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
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
#[serial_test::serial]
async fn net_worth_history_handles_liabilities() {
    // A credit-card liability should show up as a NEGATIVE in
    // by_institution AND reduce net_worth. Tests the is_liability
    // classifier wired into the new CTE.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
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

// =====================================================================
// Multi-user roles — require_owner middleware
// =====================================================================
// The `require_owner` middleware sits on every business sub-router
// in `main.rs` and 403's mutating requests from read-only users
// while leaving GETs untouched.

#[tokio::test]
#[serial_test::serial]
async fn read_only_user_can_get_but_not_mutate() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    // Bootstrap the owner first (bootstrap path always creates an
    // owner; the role split kicks in for invited users).
    let (_owner_token, _owner_id) = bootstrap(&app, &pool).await;
    // Hand-roll a read-only user.
    let ro_user_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, email, password_hash, role) \
         VALUES ('viewer', 'viewer@example.com', 'doesnt-matter', 'read_only') \
         RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .expect("seed read-only user");
    let ro_token = patrimonio::services::sessions::create_session(&pool, ro_user_id, None, None)
        .await
        .expect("create read-only session")
        .token;

    // GET passes — read-only is allowed to read their own data.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/transactions",
            None,
            Some(&ro_token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    // POST on a business route is rejected with 403.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/dashboard/subscriptions/ignore",
            Some(&serde_json::json!({"merchant": "test"})),
            Some(&ro_token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);
    let body = body_json(res.into_body()).await;
    assert!(body["error"]
        .as_str()
        .unwrap_or("")
        .contains("read-only"));
}

#[tokio::test]
#[serial_test::serial]
async fn read_only_user_can_still_log_out() {
    // require_owner does NOT apply to /api/auth/* — a read-only user
    // must be able to manage their own session (logout, change
    // password, manage their own passkeys).
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (_owner_token, _owner_id) = bootstrap(&app, &pool).await;
    let ro_user_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, email, password_hash, role) \
         VALUES ('viewer2', 'viewer2@example.com', 'doesnt-matter', 'read_only') \
         RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .expect("seed read-only user");
    let ro_token = patrimonio::services::sessions::create_session(&pool, ro_user_id, None, None)
        .await
        .expect("create read-only session")
        .token;

    let res = app
        .clone()
        .oneshot(req(Method::POST, "/api/auth/logout", None, Some(&ro_token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
#[serial_test::serial]
async fn owner_role_passes_require_owner() {
    // Sanity check: the default owner role goes through every gate
    // for a mutating request just like before role landed.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _owner_id) = bootstrap(&app, &pool).await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/dashboard/subscriptions/ignore",
            Some(&serde_json::json!({"merchant": "ok-path"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
}

// =====================================================================
// Cross-tenant isolation
// =====================================================================
// The multi-user data model wires `user_id` predicates through ~60
// queries. This block creates two users (owner Alice + owner Bob),
// seeds account + transaction + ignored-subscription rows for each,
// then asserts every read endpoint returns ONLY the caller's data.
// Belt-and-suspenders for the predicate threading; catches any
// future query that forgets the user_id filter.

async fn seed_owner(
    pool: &PgPool,
    username: &str,
) -> (uuid::Uuid, String) {
    let user_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, email, password_hash, role) \
         VALUES ($1, $2, 'doesnt-matter', 'owner') RETURNING id",
    )
    .bind(username)
    .bind(format!("{username}@example.com"))
    .fetch_one(pool)
    .await
    .expect("seed owner");
    let token = patrimonio::services::sessions::create_session(pool, user_id, None, None)
        .await
        .expect("create owner session")
        .token;
    (user_id, token)
}

#[tokio::test]
#[serial_test::serial]
async fn cross_tenant_isolation_dashboard() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    // Bootstrap so the first-user slot is filled, then hand-roll
    // two independent owners.
    let _ = bootstrap(&app, &pool).await;
    let (alice_id, alice_token) = seed_owner(&pool, "alice").await;
    let (bob_id, bob_token) = seed_owner(&pool, "bob").await;

    // Seed one account + one transaction per user.
    let (_a_inst, a_acct) = seed_account(&pool, alice_id).await;
    let a_tx = seed_tx(&pool, alice_id, a_acct, "Alice-only payee", "-42.00").await;
    let (_b_inst, b_acct) = seed_account(&pool, bob_id).await;
    let b_tx = seed_tx(&pool, bob_id, b_acct, "Bob-only payee", "-77.00").await;

    // /dashboard/transactions
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/transactions?limit=200",
            None,
            Some(&alice_token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let ids: Vec<String> = body
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|r| r["id"].as_str().map(String::from))
        .collect();
    assert!(ids.contains(&a_tx.to_string()), "Alice should see her own tx");
    assert!(
        !ids.contains(&b_tx.to_string()),
        "Alice MUST NOT see Bob's tx — predicate leak"
    );

    // /accounts
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/accounts", None, Some(&bob_token)))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let acct_ids: Vec<String> = body
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|r| r["id"].as_str().map(String::from))
        .collect();
    assert!(acct_ids.contains(&b_acct.to_string()), "Bob sees own account");
    assert!(
        !acct_ids.contains(&a_acct.to_string()),
        "Bob MUST NOT see Alice's account"
    );

    // /dashboard/overview — totals must reflect only the caller's
    // accounts. Each owner has one account with current_balance =
    // 1000.00 (per seed_account); cross-tenant leakage would
    // double that.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/overview",
            None,
            Some(&alice_token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let accounts_in_overview = body["accounts"].as_array().unwrap();
    assert_eq!(
        accounts_in_overview.len(),
        1,
        "Alice's overview should show exactly 1 account, got {}",
        accounts_in_overview.len()
    );
    assert!(
        accounts_in_overview
            .iter()
            .all(|a| a["id"].as_str().unwrap() != b_acct.to_string()),
        "Alice's overview leaked Bob's account"
    );

    // Mutating endpoint: Bob tries to PATCH Alice's account balance
    // → 404 (predicate filter excludes foreign rows).
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/accounts/{a_acct}/balance"),
            Some(&serde_json::json!({"current_balance": 999.99})),
            Some(&bob_token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_FOUND,
        "Bob MUST NOT be able to PATCH Alice's account"
    );

    // Seed an ignored subscription for Alice; Bob's /ignored list
    // must NOT include it.
    sqlx::query(
        "INSERT INTO ignored_subscription_merchants (user_id, merchant_key) \
         VALUES ($1, 'alice-private')",
    )
    .bind(alice_id)
    .execute(&pool)
    .await
    .expect("seed alice's ignored sub");
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/subscriptions/ignored",
            None,
            Some(&bob_token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let merchants: Vec<String> = body
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|r| r["merchant_key"].as_str().map(String::from))
        .collect();
    assert!(
        !merchants.contains(&"alice-private".to_string()),
        "Bob MUST NOT see Alice's ignored subscriptions"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn cross_tenant_isolation_sessions_list() {
    // /api/auth/sessions must return only the caller's own sessions —
    // an obvious place where a missing predicate would leak every
    // user's sessions to anyone authenticated.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let _ = bootstrap(&app, &pool).await;
    let (alice_id, alice_token) = seed_owner(&pool, "alice2").await;
    let (_bob_id, bob_token) = seed_owner(&pool, "bob2").await;

    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/auth/sessions", None, Some(&alice_token)))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let arr = body.as_array().unwrap();
    assert_eq!(arr.len(), 1, "Alice should see exactly her one session");

    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/auth/sessions", None, Some(&bob_token)))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let arr = body.as_array().unwrap();
    assert_eq!(arr.len(), 1, "Bob should see exactly his one session");

    // And /me returns only the caller's view.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/auth/me", None, Some(&alice_token)))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert_eq!(body["id"].as_str().unwrap(), alice_id.to_string());
    assert_eq!(body["username"].as_str().unwrap(), "alice2");
    assert_eq!(body["role"].as_str().unwrap(), "owner");
}

// =====================================================================
// /api/loans — personal lending MVP
// =====================================================================

/// Seed a transaction with an explicit date + amount + description.
/// Amount sign convention: negative = outflow, positive = inflow.
async fn seed_tx_dated(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    description: &str,
    amount: &str,
    date: &str,
) -> uuid::Uuid {
    sqlx::query_scalar(
        "INSERT INTO transactions (account_id, date, description, amount, currency, source, user_id) \
         VALUES ($1, $2::date, $3, $4, 'USD', 'manual', $5) RETURNING id",
    )
    .bind(account_id)
    .bind(date)
    .bind(description)
    .bind(Decimal::from_str(amount).unwrap())
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed dated tx")
}

/// Create a loan via the API, returning its id.
async fn create_loan(app: &Router, token: &str, body: &Value) -> uuid::Uuid {
    let res = app
        .clone()
        .oneshot(req(Method::POST, "/api/loans", Some(body), Some(token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED, "create_loan should 201");
    let b = body_json(res.into_body()).await;
    uuid::Uuid::parse_str(b["id"].as_str().unwrap()).unwrap()
}

#[tokio::test]
#[serial_test::serial]
async fn loan_create_list_summary_roundtrip() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose Ramirez",
            "principal": 5000.0,
            "currency": "USD",
            "origination_date": "2026-01-15"
        }),
    )
    .await;

    // List shows it with outstanding = principal (no repayments yet).
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans", None, Some(&token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let arr = body_json(res.into_body()).await;
    let loans = arr.as_array().unwrap();
    assert_eq!(loans.len(), 1);
    assert_eq!(loans[0]["borrower_name"], "Jose Ramirez");
    assert!((loans[0]["outstanding"].as_f64().unwrap() - 5000.0).abs() < 0.01);

    // A person row was auto-created.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans/people", None, Some(&token)))
        .await
        .unwrap();
    let people = body_json(res.into_body()).await;
    assert_eq!(people.as_array().unwrap().len(), 1);
    assert_eq!(people[0]["name"], "Jose Ramirez");

    // Summary math.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans/summary", None, Some(&token)))
        .await
        .unwrap();
    let s = body_json(res.into_body()).await;
    assert_eq!(s["loan_count"].as_i64().unwrap(), 1);
    assert!((s["total_lent"].as_f64().unwrap() - 5000.0).abs() < 0.01);
    assert!((s["total_outstanding"].as_f64().unwrap() - 5000.0).abs() < 0.01);

    let _ = loan_id;
}

#[tokio::test]
#[serial_test::serial]
async fn loan_record_payment_reduces_outstanding_and_is_idempotent() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose Ramirez",
            "principal": 1000.0,
            "currency": "USD",
            "origination_date": "2026-01-15"
        }),
    )
    .await;

    // An incoming repayment of 400.
    let repay_tx = seed_tx_dated(&pool, user_id, acct, "Zelle from Jose", "400.00", "2026-02-15").await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay_tx.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Outstanding is now 600.
    let res = app
        .clone()
        .oneshot(req(Method::GET, &format!("/api/loans/{loan_id}"), None, Some(&token)))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!((l["outstanding"].as_f64().unwrap() - 600.0).abs() < 0.01,
        "expected 600 outstanding, got {}", l["outstanding"]);
    assert!((l["total_repaid"].as_f64().unwrap() - 400.0).abs() < 0.01);

    // Linking the SAME transaction again is rejected (409) — a
    // repayment can only apply to one installment.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay_tx.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CONFLICT, "double-link must 409");
}

#[tokio::test]
#[serial_test::serial]
async fn loan_cash_payment_without_transaction() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Cash Friend",
            "principal": 1000.0,
            "currency": "USD",
            "origination_date": "2026-01-15"
        }),
    )
    .await;

    // Record a cash repayment of 250 with NO transaction_id.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"amount": 250.0, "paid_date": "2026-02-01"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED, "cash payment must succeed");

    // Outstanding drops to 750.
    let res = app
        .clone()
        .oneshot(req(Method::GET, &format!("/api/loans/{loan_id}"), None, Some(&token)))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!((l["outstanding"].as_f64().unwrap() - 750.0).abs() < 0.01,
        "expected 750 outstanding after cash payment, got {}", l["outstanding"]);
    assert!((l["total_repaid"].as_f64().unwrap() - 250.0).abs() < 0.01);

    // A cash payment with no amount is rejected (400).
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST,
        "a cash payment with no amount must 400");
}

#[tokio::test]
#[serial_test::serial]
async fn loan_disbursement_and_repayment_excluded_from_cash_flow() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // The disbursement outflow + a normal expense in the same month.
    let disb_tx = seed_tx_dated(&pool, user_id, acct, "Wire to Jose", "-1000.00", "2026-03-10").await;
    let _grocery = seed_tx_dated(&pool, user_id, acct, "Supermarket", "-200.00", "2026-03-11").await;
    // A repayment inflow + a normal paycheck inflow in another month.
    let repay_tx = seed_tx_dated(&pool, user_id, acct, "Zelle from Jose", "500.00", "2026-04-10").await;
    let _paycheck = seed_tx_dated(&pool, user_id, acct, "ACME Payroll", "3000.00", "2026-04-15").await;

    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose",
            "principal": 1000.0,
            "currency": "USD",
            "origination_date": "2026-03-10"
        }),
    )
    .await;

    // Baseline cash flow BEFORE linking: March spending includes the
    // 1000 disbursement + 200 grocery = 1200; April income includes
    // 500 + 3000 = 3500.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/dashboard/trends", None, Some(&token)))
        .await
        .unwrap();
    let trends = body_json(res.into_body()).await;
    let march = trends.as_array().unwrap().iter()
        .find(|p| p["month"] == "2026-03").cloned().unwrap();
    assert!((march["spending"].as_f64().unwrap() - 1200.0).abs() < 0.01,
        "pre-link March spending should be 1200, got {}", march["spending"]);

    // Link disbursement + record repayment.
    let res = app.clone().oneshot(req(
        Method::POST,
        &format!("/api/loans/{loan_id}/disbursement"),
        Some(&serde_json::json!({"transaction_id": disb_tx.to_string()})),
        Some(&token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let res = app.clone().oneshot(req(
        Method::POST,
        &format!("/api/loans/{loan_id}/payments"),
        Some(&serde_json::json!({"transaction_id": repay_tx.to_string()})),
        Some(&token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // AFTER linking: the disbursement drops out of March spending
    // (1200 → 200) and the repayment drops out of April income
    // (3500 → 3000).
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/dashboard/trends", None, Some(&token)))
        .await
        .unwrap();
    let trends = body_json(res.into_body()).await;
    let arr = trends.as_array().unwrap();
    let march = arr.iter().find(|p| p["month"] == "2026-03").cloned().unwrap();
    let april = arr.iter().find(|p| p["month"] == "2026-04").cloned().unwrap();
    assert!((march["spending"].as_f64().unwrap() - 200.0).abs() < 0.01,
        "post-link March spending should exclude the disbursement (200), got {}", march["spending"]);
    assert!((april["income"].as_f64().unwrap() - 3000.0).abs() < 0.01,
        "post-link April income should exclude the repayment (3000), got {}", april["income"]);
}

#[tokio::test]
#[serial_test::serial]
async fn loan_suggest_disbursement_matches_and_rejects() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // Case 1 (TP): exact -5000 on origination date, name in description.
    let good = seed_tx_dated(&pool, user_id, acct, "ZELLE TO JOSE RAMIREZ", "-5000.00", "2026-01-15").await;
    // Case 4 (TN): wrong amount, same day.
    let _wrong_amount = seed_tx_dated(&pool, user_id, acct, "Coffee", "-250.00", "2026-01-15").await;
    // Case 8 (TN): right amount, far date (59 days out → outside ±7).
    let _far = seed_tx_dated(&pool, user_id, acct, "Other", "-5000.00", "2026-03-15").await;
    // Case 9 (TN): an INFLOW of the right magnitude can't be a disbursement.
    let _inflow = seed_tx_dated(&pool, user_id, acct, "Deposit", "5000.00", "2026-01-15").await;

    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose Ramirez",
            "principal": 5000.0,
            "currency": "USD",
            "origination_date": "2026-01-15"
        }),
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}/suggestions/disbursement"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let suggestions = body_json(res.into_body()).await;
    let arr = suggestions.as_array().unwrap();
    // Only the exact-amount same-day outflow should be suggested.
    assert_eq!(arr.len(), 1, "exactly one disbursement suggestion expected, got {arr:?}");
    assert_eq!(arr[0]["transaction_id"].as_str().unwrap(), good.to_string());
    assert!(arr[0]["confidence"].as_i64().unwrap() >= 80, "exact+name should be high confidence");
    assert_eq!(arr[0]["name_matched"], true);
}

#[tokio::test]
#[serial_test::serial]
async fn loan_suggest_excludes_already_linked_disbursement() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;
    let tx = seed_tx_dated(&pool, user_id, acct, "Wire to Jose", "-5000.00", "2026-01-15").await;

    // Loan A links the tx as its disbursement.
    let loan_a = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose", "principal": 5000.0, "currency": "USD", "origination_date": "2026-01-15"
    })).await;
    let res = app.clone().oneshot(req(
        Method::POST, &format!("/api/loans/{loan_a}/disbursement"),
        Some(&serde_json::json!({"transaction_id": tx.to_string()})), Some(&token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    // Loan B (same borrower/amount) must NOT see that tx suggested —
    // it's already linked (Case 7 / Case 19 disambiguation).
    let loan_b = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose", "principal": 5000.0, "currency": "USD", "origination_date": "2026-01-15"
    })).await;
    let res = app.clone().oneshot(req(
        Method::GET, &format!("/api/loans/{loan_b}/suggestions/disbursement"), None, Some(&token),
    )).await.unwrap();
    let suggestions = body_json(res.into_body()).await;
    assert_eq!(suggestions.as_array().unwrap().len(), 0,
        "an already-linked disbursement must not be suggested for another loan");
}

#[tokio::test]
#[serial_test::serial]
async fn loan_cross_tenant_isolation() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (alice_token, _alice) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(&app, &alice_token, &serde_json::json!({
        "borrower_name": "Alice Friend", "principal": 2000.0, "currency": "USD", "origination_date": "2026-01-01"
    })).await;

    // Bob, a second hand-rolled owner.
    let (_bob_id, bob_token) = seed_owner(&pool, "bob").await;

    // Bob cannot GET Alice's loan.
    let res = app.clone().oneshot(req(
        Method::GET, &format!("/api/loans/{loan_id}"), None, Some(&bob_token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND, "Bob must not read Alice's loan");

    // Bob cannot DELETE Alice's loan.
    let res = app.clone().oneshot(req(
        Method::DELETE, &format!("/api/loans/{loan_id}"), None, Some(&bob_token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND, "Bob must not delete Alice's loan");

    // Bob's own loan list is empty.
    let res = app.clone().oneshot(req(
        Method::GET, "/api/loans", None, Some(&bob_token),
    )).await.unwrap();
    let arr = body_json(res.into_body()).await;
    assert_eq!(arr.as_array().unwrap().len(), 0, "Bob sees none of Alice's loans");
}

// =====================================================================
// /api/loans Phase 2 — schedules, status, reminders
// =====================================================================

/// Set an app_settings key for the bootstrap user (used to drive the
/// reminder lead-days from the test).
async fn set_setting(pool: &PgPool, user_id: uuid::Uuid, key: &str, value: Value) {
    sqlx::query(
        "INSERT INTO app_settings (user_id, key, value, updated_at) \
         VALUES ($1, $2, $3, NOW()) \
         ON CONFLICT (user_id, key) DO UPDATE SET value = EXCLUDED.value",
    )
    .bind(user_id)
    .bind(key)
    .bind(value)
    .execute(pool)
    .await
    .expect("set setting");
}

#[tokio::test]
#[serial_test::serial]
async fn loan_schedule_generates_and_sums_to_principal() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
        "origination_date": "2026-01-15", "interest_type": "simple",
        "interest_rate": 0.06, "term_months": 12, "payment_frequency": "monthly"
    })).await;

    // Generate the schedule.
    let res = app.clone().oneshot(req(
        Method::POST, &format!("/api/loans/{loan_id}/schedule"), Some(&serde_json::json!({})), Some(&token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["installments"].as_i64().unwrap(), 12);

    // Payments list shows 12 rows; scheduled_principal sums to 1200.
    let res = app.clone().oneshot(req(
        Method::GET, &format!("/api/loans/{loan_id}/payments"), None, Some(&token),
    )).await.unwrap();
    let payments = body_json(res.into_body()).await;
    let rows = payments.as_array().unwrap();
    assert_eq!(rows.len(), 12);
    let sum_principal: f64 = rows.iter()
        .map(|r| r["scheduled_principal"].as_f64().unwrap()).sum();
    assert!((sum_principal - 1200.0).abs() < 0.001,
        "scheduled principal must sum to 1200, got {sum_principal}");
    // Simple 6% → total interest 72.
    let sum_interest: f64 = rows.iter()
        .map(|r| r["scheduled_interest"].as_f64().unwrap()).sum();
    assert!((sum_interest - 72.0).abs() < 0.01, "interest should be 72, got {sum_interest}");
}

#[tokio::test]
#[serial_test::serial]
async fn loan_schedule_regen_refused_when_payment_reconciled() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;
    let loan_id = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
        "origination_date": "2026-01-15", "interest_type": "none",
        "term_months": 12, "payment_frequency": "monthly"
    })).await;
    // Generate, then reconcile a repayment.
    let _ = app.clone().oneshot(req(
        Method::POST, &format!("/api/loans/{loan_id}/schedule"), Some(&serde_json::json!({})), Some(&token),
    )).await.unwrap();
    let repay = seed_tx_dated(&pool, user_id, acct, "Zelle from Jose", "100.00", "2026-02-15").await;
    let res = app.clone().oneshot(req(
        Method::POST, &format!("/api/loans/{loan_id}/payments"),
        Some(&serde_json::json!({"transaction_id": repay.to_string()})), Some(&token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Regen must now be refused with 409.
    let res = app.clone().oneshot(req(
        Method::POST, &format!("/api/loans/{loan_id}/schedule"), Some(&serde_json::json!({})), Some(&token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::CONFLICT, "regen with a reconciled payment must 409");
}

#[tokio::test]
#[serial_test::serial]
async fn loan_schedule_open_ended_rejected() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    // No term_months / payment_frequency → open-ended.
    let loan_id = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose", "principal": 500.0, "currency": "USD",
        "origination_date": "2026-01-15"
    })).await;
    let res = app.clone().oneshot(req(
        Method::POST, &format!("/api/loans/{loan_id}/schedule"), Some(&serde_json::json!({})), Some(&token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
#[serial_test::serial]
async fn loan_write_off_zeroes_outstanding_default_keeps_it() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose", "principal": 1000.0, "currency": "USD",
        "origination_date": "2026-01-15"
    })).await;

    // Default keeps outstanding.
    let res = app.clone().oneshot(req(
        Method::PATCH, &format!("/api/loans/{loan_id}"),
        Some(&serde_json::json!({"status": "defaulted"})), Some(&token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let res = app.clone().oneshot(req(
        Method::GET, &format!("/api/loans/{loan_id}"), None, Some(&token),
    )).await.unwrap();
    let l = body_json(res.into_body()).await;
    assert!((l["outstanding"].as_f64().unwrap() - 1000.0).abs() < 0.01,
        "defaulted keeps outstanding, got {}", l["outstanding"]);

    // Write-off zeroes it.
    let res = app.clone().oneshot(req(
        Method::PATCH, &format!("/api/loans/{loan_id}"),
        Some(&serde_json::json!({"status": "written_off"})), Some(&token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let res = app.clone().oneshot(req(
        Method::GET, &format!("/api/loans/{loan_id}"), None, Some(&token),
    )).await.unwrap();
    let l = body_json(res.into_body()).await;
    assert!(l["outstanding"].as_f64().unwrap().abs() < 0.01,
        "written_off zeroes outstanding, got {}", l["outstanding"]);
}

#[tokio::test]
#[serial_test::serial]
async fn loan_reminders_upcoming_overdue_and_exclusions() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose", "principal": 300.0, "currency": "USD",
        "origination_date": "2026-01-15", "interest_type": "none",
        "term_months": 3, "payment_frequency": "monthly"
    })).await;

    // Hand-place three installments with controlled due dates relative
    // to CURRENT_DATE: one in 3 days (upcoming), one in 40 days (outside
    // default lead 7 → excluded), one 2 days ago (overdue).
    sqlx::query("DELETE FROM loan_payments WHERE loan_id = $1").bind(loan_id).execute(&pool).await.unwrap();
    for (n, offset) in [(1i32, 3i64), (2, 40), (3, -2)] {
        sqlx::query(
            "INSERT INTO loan_payments (user_id, loan_id, installment_number, due_date, \
             scheduled_amount, scheduled_principal, status) \
             VALUES ($1, $2, $3, CURRENT_DATE + ($4)::int, 100.00, 100.00, 'scheduled')",
        )
        .bind(user_id).bind(loan_id).bind(n).bind(offset as i32)
        .execute(&pool).await.unwrap();
    }

    // Default lead 7: expect installment 1 (upcoming) + installment 3
    // (overdue); installment 2 (40d out) excluded.
    let res = app.clone().oneshot(req(
        Method::GET, "/api/loans/reminders", None, Some(&token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let reminders = body_json(res.into_body()).await;
    let arr = reminders.as_array().unwrap();
    assert_eq!(arr.len(), 2, "expected upcoming + overdue, got {arr:?}");
    let has_upcoming = arr.iter().any(|r| r["days_until"].as_i64().unwrap() > 0);
    let has_overdue = arr.iter().any(|r| r["days_overdue"].as_i64().unwrap() > 0);
    assert!(has_upcoming && has_overdue, "both an upcoming and an overdue reminder");

    // Widen lead to 60 → installment 2 now appears too (3 total).
    set_setting(&pool, user_id, "lending_reminder_lead_days", serde_json::json!(60)).await;
    let res = app.clone().oneshot(req(
        Method::GET, "/api/loans/reminders", None, Some(&token),
    )).await.unwrap();
    let reminders = body_json(res.into_body()).await;
    assert_eq!(reminders.as_array().unwrap().len(), 3, "lead 60 surfaces the 40-day-out installment");

    // Write off the loan → no reminders (loan not active).
    let _ = app.clone().oneshot(req(
        Method::PATCH, &format!("/api/loans/{loan_id}"),
        Some(&serde_json::json!({"status": "written_off"})), Some(&token),
    )).await.unwrap();
    let res = app.clone().oneshot(req(
        Method::GET, "/api/loans/reminders", None, Some(&token),
    )).await.unwrap();
    let reminders = body_json(res.into_body()).await;
    assert_eq!(reminders.as_array().unwrap().len(), 0, "written-off loan yields no reminders");
}

#[tokio::test]
#[serial_test::serial]
async fn loan_reminders_cross_tenant_isolated() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let _ = bootstrap(&app, &pool).await;
    let (alice_id, alice_token) = seed_owner(&pool, "alice").await;
    let (_bob_id, bob_token) = seed_owner(&pool, "bob").await;

    // Alice has a loan + an overdue installment.
    let loan_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO loans (user_id, borrower_name, principal, currency, origination_date, status) \
         VALUES ($1, 'Friend', 500.00, 'USD', CURRENT_DATE - 60, 'active') RETURNING id",
    ).bind(alice_id).fetch_one(&pool).await.unwrap();
    sqlx::query(
        "INSERT INTO loan_payments (user_id, loan_id, installment_number, due_date, \
         scheduled_amount, scheduled_principal, status) \
         VALUES ($1, $2, 1, CURRENT_DATE - 2, 100.00, 100.00, 'scheduled')",
    ).bind(alice_id).bind(loan_id).execute(&pool).await.unwrap();

    // Alice sees 1 reminder; Bob sees none.
    let res = app.clone().oneshot(req(Method::GET, "/api/loans/reminders", None, Some(&alice_token))).await.unwrap();
    assert_eq!(body_json(res.into_body()).await.as_array().unwrap().len(), 1);
    let res = app.clone().oneshot(req(Method::GET, "/api/loans/reminders", None, Some(&bob_token))).await.unwrap();
    assert_eq!(body_json(res.into_body()).await.as_array().unwrap().len(), 0,
        "Bob must not see Alice's reminders");
}

#[tokio::test]
#[serial_test::serial]
async fn loan_list_collection_path_contract() {
    // Regression guard for the "couldn't load loans" bug: axum 0.8's
    // nest("/api/loans") + inner "/" route matches /api/loans but
    // 404s /api/loans/ (trailing slash). The frontend MUST call the
    // no-slash form — this pins that contract so a future client
    // change back to the slash form is caught here.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    // The path the frontend uses → must be 200.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans", None, Some(&token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "GET /api/loans must be 200");
    // POST collection (createLoan) → must be 201.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/loans",
            Some(&serde_json::json!({
                "borrower_name": "Slash Test", "principal": 100.0,
                "currency": "USD", "origination_date": "2026-01-01"
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED, "POST /api/loans must 201");
    // Documented axum behavior: the trailing-slash form does NOT match.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans/", None, Some(&token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND,
        "trailing-slash /api/loans/ 404s under axum nest — clients use the no-slash form");
}

#[tokio::test]
#[serial_test::serial]
async fn loan_interest_only_and_monthly_rate_schedule() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    // 1% per MONTH, interest-only, 6 months on $10,000.
    let loan_id = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose", "principal": 10000.0, "currency": "USD",
        "origination_date": "2026-01-15", "interest_type": "interest_only",
        "interest_rate": 0.01, "rate_period": "monthly",
        "term_months": 6, "payment_frequency": "monthly"
    })).await;

    let res = app.clone().oneshot(req(
        Method::POST, &format!("/api/loans/{loan_id}/schedule"), Some(&serde_json::json!({})), Some(&token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let res = app.clone().oneshot(req(
        Method::GET, &format!("/api/loans/{loan_id}/payments"), None, Some(&token),
    )).await.unwrap();
    let rows = body_json(res.into_body()).await;
    let arr = rows.as_array().unwrap();
    assert_eq!(arr.len(), 6);
    // First five rows: interest only, $100 each (1% of 10k), no principal.
    for r in &arr[..5] {
        assert!((r["scheduled_interest"].as_f64().unwrap() - 100.0).abs() < 0.01);
        assert!(r["scheduled_principal"].as_f64().unwrap().abs() < 0.01);
    }
    // Final row: full principal balloon.
    assert!((arr[5]["scheduled_principal"].as_f64().unwrap() - 10000.0).abs() < 0.01,
        "interest-only balloon should return full principal, got {}", arr[5]["scheduled_principal"]);

    // The loan echoes back rate_period for the UI.
    let res = app.clone().oneshot(req(
        Method::GET, &format!("/api/loans/{loan_id}"), None, Some(&token),
    )).await.unwrap();
    let l = body_json(res.into_body()).await;
    assert_eq!(l["rate_period"], "monthly");
    assert_eq!(l["interest_type"], "interest_only");
}

// =====================================================================
// Interest income (cash basis) — principal/interest split + report
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn loan_scheduled_repayment_records_interest_split() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // Interest-only loan: $10,000 @ 1%/month, 6 months. Each scheduled
    // installment's interest is $100; principal balloons at the end.
    let loan_id = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose", "principal": 10000.0, "currency": "USD",
        "origination_date": "2026-01-15", "interest_type": "interest_only",
        "interest_rate": 0.01, "rate_period": "monthly",
        "term_months": 6, "payment_frequency": "monthly"
    })).await;
    let _ = app.clone().oneshot(req(
        Method::POST, &format!("/api/loans/{loan_id}/schedule"), Some(&serde_json::json!({})), Some(&token),
    )).await.unwrap();

    // Reconcile a $100 inflow against the first installment → it's all
    // interest (interest-only), no principal.
    let repay = seed_tx_dated(&pool, user_id, acct, "Zelle from Jose", "100.00", "2026-02-15").await;
    let res = app.clone().oneshot(req(
        Method::POST, &format!("/api/loans/{loan_id}/payments"),
        Some(&serde_json::json!({"transaction_id": repay.to_string()})), Some(&token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // The loan's interest_earned reflects the $100.
    let res = app.clone().oneshot(req(
        Method::GET, &format!("/api/loans/{loan_id}"), None, Some(&token),
    )).await.unwrap();
    let l = body_json(res.into_body()).await;
    assert!((l["interest_earned"].as_f64().unwrap() - 100.0).abs() < 0.01,
        "interest-only first payment is all interest, got {}", l["interest_earned"]);

    // Interest-income report: $100 interest, $0 principal this year.
    let res = app.clone().oneshot(req(
        Method::GET, "/api/loans/interest-income?year=2026", None, Some(&token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let report = body_json(res.into_body()).await;
    assert!((report["total_interest"].as_f64().unwrap() - 100.0).abs() < 0.01);
    assert!(report["total_principal"].as_f64().unwrap().abs() < 0.01);
    assert_eq!(report["by_loan"].as_array().unwrap().len(), 1);
    // Per-month series has the Feb bucket.
    let months = report["by_month"].as_array().unwrap();
    assert!(months.iter().any(|m| m["month"] == "2026-02"));
}

#[tokio::test]
#[serial_test::serial]
async fn loan_open_ended_us_rule_interest_first() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // Open-ended (no schedule) loan: $1,000 @ 12%/year simple. A
    // repayment one year later accrues ~$120 interest; US Rule applies
    // it interest-first.
    let loan_id = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose", "principal": 1000.0, "currency": "USD",
        "origination_date": "2026-01-15", "interest_type": "simple",
        "interest_rate": 0.12, "rate_period": "annual"
    })).await;

    // A $300 inflow ~365 days after origination.
    let repay = seed_tx_dated(&pool, user_id, acct, "Zelle from Jose", "300.00", "2027-01-15").await;
    let res = app.clone().oneshot(req(
        Method::POST, &format!("/api/loans/{loan_id}/payments"),
        Some(&serde_json::json!({"transaction_id": repay.to_string()})), Some(&token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // ~$120 interest accrued (1000 * 0.12 * 1yr), allocated first; the
    // rest (~$180) is principal.
    let res = app.clone().oneshot(req(
        Method::GET, &format!("/api/loans/{loan_id}"), None, Some(&token),
    )).await.unwrap();
    let l = body_json(res.into_body()).await;
    let earned = l["interest_earned"].as_f64().unwrap();
    assert!((earned - 120.0).abs() < 1.0, "US-rule interest-first ~120, got {earned}");
    // Outstanding dropped by the principal portion (~180), not the full 300.
    let outstanding = l["outstanding"].as_f64().unwrap();
    assert!((outstanding - 820.0).abs() < 1.5,
        "outstanding should drop by principal portion only (~820), got {outstanding}");
}

#[tokio::test]
#[serial_test::serial]
async fn loan_zero_interest_repayment_is_all_principal() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;
    let loan_id = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose", "principal": 500.0, "currency": "USD",
        "origination_date": "2026-01-15"
    })).await; // interest_type defaults to none
    let repay = seed_tx_dated(&pool, user_id, acct, "Zelle from Jose", "200.00", "2026-03-15").await;
    let _ = app.clone().oneshot(req(
        Method::POST, &format!("/api/loans/{loan_id}/payments"),
        Some(&serde_json::json!({"transaction_id": repay.to_string()})), Some(&token),
    )).await.unwrap();
    let res = app.clone().oneshot(req(
        Method::GET, "/api/loans/interest-income", None, Some(&token),
    )).await.unwrap();
    let report = body_json(res.into_body()).await;
    assert!(report["total_interest"].as_f64().unwrap().abs() < 0.01,
        "0% loan generates no interest income");
    assert!((report["total_principal"].as_f64().unwrap() - 200.0).abs() < 0.01);
}

#[tokio::test]
#[serial_test::serial]
async fn loan_interest_income_csv_export() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;
    let loan_id = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose Ramirez", "principal": 1000.0, "currency": "USD",
        "origination_date": "2026-01-15", "interest_type": "simple",
        "interest_rate": 0.12, "rate_period": "annual"
    })).await;
    let repay = seed_tx_dated(&pool, user_id, acct, "Zelle", "300.00", "2026-07-15").await;
    let _ = app.clone().oneshot(req(
        Method::POST, &format!("/api/loans/{loan_id}/payments"),
        Some(&serde_json::json!({"transaction_id": repay.to_string()})), Some(&token),
    )).await.unwrap();

    let res = app.clone().oneshot(req(
        Method::GET, "/api/loans/interest-income/export?year=2026", None, Some(&token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let ct = res.headers().get("content-type").unwrap().to_str().unwrap().to_string();
    assert!(ct.contains("text/csv"), "expected CSV content-type, got {ct}");
    let bytes = axum::body::to_bytes(res.into_body(), 1024 * 64).await.unwrap();
    let csv = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(csv.starts_with("date,borrower,currency,payment_amount,principal_portion,interest_portion,balance_after"));
    assert!(csv.contains("Jose Ramirez"), "borrower row present");
    assert!(csv.contains("300.00"), "payment amount present");
}

#[tokio::test]
#[serial_test::serial]
async fn loan_interest_income_cross_tenant_isolated() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let _ = bootstrap(&app, &pool).await;
    let (alice_id, alice_token) = seed_owner(&pool, "alice").await;
    let (_bob_id, bob_token) = seed_owner(&pool, "bob").await;
    // Alice: a loan + a reconciled interest-bearing payment row.
    let loan_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO loans (user_id, borrower_name, principal, currency, origination_date, status, interest_type, interest_rate) \
         VALUES ($1, 'Friend', 1000.00, 'USD', '2026-01-01', 'active', 'simple', 0.10) RETURNING id",
    ).bind(alice_id).fetch_one(&pool).await.unwrap();
    sqlx::query(
        "INSERT INTO loan_payments (user_id, loan_id, installment_number, paid_amount, paid_date, \
         principal_portion, interest_portion, balance_after, status) \
         VALUES ($1, $2, 1, 200.00, '2026-06-01', 150.00, 50.00, 850.00, 'paid')",
    ).bind(alice_id).bind(loan_id).execute(&pool).await.unwrap();

    let res = app.clone().oneshot(req(Method::GET, "/api/loans/interest-income", None, Some(&alice_token))).await.unwrap();
    let r = body_json(res.into_body()).await;
    assert!((r["total_interest"].as_f64().unwrap() - 50.0).abs() < 0.01);
    // Bob sees nothing.
    let res = app.clone().oneshot(req(Method::GET, "/api/loans/interest-income", None, Some(&bob_token))).await.unwrap();
    let r = body_json(res.into_body()).await;
    assert!(r["total_interest"].as_f64().unwrap().abs() < 0.01, "Bob must not see Alice's interest income");
}

// =====================================================================
// Phase 3 completion — compound, accrued, summary CSV, agreement, flag
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn loan_compound_single_balloon_schedule() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose", "principal": 1000.0, "currency": "USD",
        "origination_date": "2026-01-15", "interest_type": "compound",
        "interest_rate": 0.10, "rate_period": "annual",
        "term_months": 24, "payment_frequency": "monthly"
    })).await;
    let res = app.clone().oneshot(req(
        Method::POST, &format!("/api/loans/{loan_id}/schedule"), Some(&serde_json::json!({})), Some(&token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let res = app.clone().oneshot(req(
        Method::GET, &format!("/api/loans/{loan_id}/payments"), None, Some(&token),
    )).await.unwrap();
    let rows = body_json(res.into_body()).await;
    let arr = rows.as_array().unwrap();
    assert_eq!(arr.len(), 1, "compound is a single balloon");
    // ~$220 compound interest over 2y monthly-compounded at 10%.
    assert!((arr[0]["scheduled_interest"].as_f64().unwrap() - 220.0).abs() < 2.0);
    assert!((arr[0]["scheduled_principal"].as_f64().unwrap() - 1000.0).abs() < 0.01);
}

#[tokio::test]
#[serial_test::serial]
async fn loan_interest_accrued_is_informational() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    // 12% annual simple, open-ended, originated ~today minus enough to
    // accrue. Use a clearly-past origination so accrual is non-trivial.
    let loan_id = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose", "principal": 1000.0, "currency": "USD",
        "origination_date": "2026-01-01", "interest_type": "simple",
        "interest_rate": 0.12, "rate_period": "annual"
    })).await;
    let res = app.clone().oneshot(req(
        Method::GET, &format!("/api/loans/{loan_id}"), None, Some(&token),
    )).await.unwrap();
    let l = body_json(res.into_body()).await;
    // interest_accrued is present and >= 0 (exact value depends on
    // today's date relative to origination).
    assert!(l["interest_accrued"].as_f64().unwrap() >= 0.0);
    // A 0% loan accrues nothing.
    let zero = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Ana", "principal": 500.0, "currency": "USD",
        "origination_date": "2026-01-01"
    })).await;
    let res = app.clone().oneshot(req(
        Method::GET, &format!("/api/loans/{zero}"), None, Some(&token),
    )).await.unwrap();
    let l = body_json(res.into_body()).await;
    assert!(l["interest_accrued"].as_f64().unwrap().abs() < 0.01);
}

#[tokio::test]
#[serial_test::serial]
async fn loan_below_market_flag_over_threshold() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    // 0% loan over the $10k de-minimis → flagged.
    let _big = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "BigFriend", "principal": 25000.0, "currency": "USD",
        "origination_date": "2026-01-01"
    })).await;
    // 0% loan under the threshold → not flagged.
    let _small = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "SmallFriend", "principal": 500.0, "currency": "USD",
        "origination_date": "2026-01-01"
    })).await;
    let res = app.clone().oneshot(req(
        Method::GET, "/api/loans/interest-income", None, Some(&token),
    )).await.unwrap();
    let report = body_json(res.into_body()).await;
    let flagged = report["below_market_loans"].as_array().unwrap();
    assert_eq!(flagged.len(), 1, "only the >$10k 0% loan is flagged");
    assert_eq!(flagged[0]["borrower_name"], "BigFriend");
}

#[tokio::test]
#[serial_test::serial]
async fn loan_interest_summary_csv_by_borrower_year() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    // Seed a loan + a reconciled interest-bearing payment directly.
    let loan_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO loans (user_id, borrower_name, principal, currency, origination_date, status, interest_type, interest_rate) \
         VALUES ($1, 'Jose Ramirez', 1000.00, 'USD', '2026-01-01', 'active', 'simple', 0.10) RETURNING id",
    ).bind(user_id).fetch_one(&pool).await.unwrap();
    sqlx::query(
        "INSERT INTO loan_payments (user_id, loan_id, installment_number, paid_amount, paid_date, \
         principal_portion, interest_portion, balance_after, status) \
         VALUES ($1, $2, 1, 200.00, '2026-06-01', 150.00, 50.00, 850.00, 'paid')",
    ).bind(user_id).bind(loan_id).execute(&pool).await.unwrap();

    let res = app.clone().oneshot(req(
        Method::GET, "/api/loans/interest-income/summary", None, Some(&token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let ct = res.headers().get("content-type").unwrap().to_str().unwrap().to_string();
    assert!(ct.contains("text/csv"));
    let bytes = axum::body::to_bytes(res.into_body(), 1024 * 64).await.unwrap();
    let csv = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(csv.starts_with("year,borrower,currency,interest_received,principal_received"));
    assert!(csv.contains("2026"));
    assert!(csv.contains("Jose Ramirez"));
    assert!(csv.contains("50.00"));
}

#[tokio::test]
#[serial_test::serial]
async fn loan_agreement_html_renders_and_is_scoped() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose Ramirez", "principal": 5000.0, "currency": "USD",
        "origination_date": "2026-01-15", "interest_type": "simple",
        "interest_rate": 0.06, "rate_period": "annual",
        "term_months": 12, "payment_frequency": "monthly"
    })).await;
    let res = app.clone().oneshot(req(
        Method::GET, &format!("/api/loans/{loan_id}/agreement"), None, Some(&token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let ct = res.headers().get("content-type").unwrap().to_str().unwrap().to_string();
    assert!(ct.contains("text/html"), "agreement is HTML, got {ct}");
    let bytes = axum::body::to_bytes(res.into_body(), 1024 * 64).await.unwrap();
    let html = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(html.contains("Promissory Note"));
    assert!(html.contains("Jose Ramirez"));

    // Cross-tenant: a different owner can't fetch it.
    let (_bob, bob_token) = seed_owner(&pool, "bob").await;
    let res = app.clone().oneshot(req(
        Method::GET, &format!("/api/loans/{loan_id}/agreement"), None, Some(&bob_token),
    )).await.unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND, "agreement must be owner-scoped");
}
