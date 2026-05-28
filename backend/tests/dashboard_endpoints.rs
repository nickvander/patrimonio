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
#[serial_test::serial]
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
#[serial_test::serial]
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
#[serial_test::serial]
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
#[serial_test::serial]
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
#[serial_test::serial]
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
// /api/imports/upload — CSRF gate + auth gate + empty-body shape
// =====================================================================
// These tests exist because the frontend `uploadStatements` silently
// 403-ed for a week — the multipart helper bypassed `_withCsrf` so
// PDFs never reached the handler. The gate-level tests below catch
// that class of regression even without a real PDF fixture.

#[tokio::test]
#[serial_test::serial]
async fn upload_unauthenticated_is_401() {
    let Some((app, _pool)) = skip_if_no_db(try_setup(false, None).await) else {
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
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
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
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
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
#[serial_test::serial]
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
#[serial_test::serial]
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
#[serial_test::serial]
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
#[serial_test::serial]
async fn put_replace_splits_atomic() {
    // The new PUT endpoint replaces children atomically — no window
    // where the parent appears un-split to a concurrent reader.
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
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
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
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
#[serial_test::serial]
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
#[serial_test::serial]
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
#[serial_test::serial]
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
#[serial_test::serial]
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
#[serial_test::serial]
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
#[serial_test::serial]
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
#[serial_test::serial]
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

/// When a transfer exists and there's an `exchange_rates` row near the
/// source date, the endpoint should populate `spot_fx_rate` so the
/// frontend can render "Wise gave you 19.40, market was 19.62"
/// without a separate FX lookup per row. Locks in the per-date
/// subquery rewrite added for the cross-currency cash-flow card.
#[tokio::test]
#[serial_test::serial]
async fn fx_transfers_listing_populates_spot_rate() {
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
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
#[serial_test::serial]
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

// =====================================================================
// Multi-user roles — require_owner middleware
// =====================================================================
// The `require_owner` middleware sits on every business sub-router
// in `main.rs` and 403's mutating requests from read-only users
// while leaving GETs untouched.

#[tokio::test]
#[serial_test::serial]
async fn read_only_user_can_get_but_not_mutate() {
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
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
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
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
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
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
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
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
    let Some((app, pool)) = skip_if_no_db(try_setup(false, None).await) else {
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
