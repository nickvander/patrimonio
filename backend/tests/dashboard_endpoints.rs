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
use sqlx::Row;
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
         exchange_rates, benchmark_prices, lot_disposals, holding_lots, holdings, \
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
        plaid_android_package_name: None,
        plaid_webhook_url: plaid_webhook_url.map(str::to_string),
        allowed_origins: vec!["http://localhost:3000".to_string()],
        cookie_secure: false,
        trusted_proxy_cidrs: vec![],
        hibp_api_base: String::new(),
        android_apk_cert_sha256: vec![],
        android_package_name: "com.patrimonio.patrimonio".to_string(),
    };

    let redis = redis::Client::open(config.redis_url.clone()).expect("redis client");
    let webauthn = std::sync::Arc::new(
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
        .nest("/api/projections", patrimonio::api::projections::router())
        .nest("/api/tax", patrimonio::api::tax::router())
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
    HeaderValue::from_str(&format!("{SESSION_COOKIE}={token}")).expect("valid cookie header")
}

/// Build a request with the right cookie + CSRF header + JSON body.
/// The CSRF middleware short-circuits mutating requests without
/// `X-Requested-With`, so every POST/PATCH/PUT/DELETE we send needs
/// the header — bake it in by default to avoid forgetting in
/// individual tests.
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
        builder = builder.header(header::COOKIE, cookie_header(token));
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
    let Some((app, _pool, _lock)) =
        skip_if_no_db(try_setup(true, Some("https://example.com")).await)
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
    let Some((app, pool, _lock)) =
        skip_if_no_db(try_setup(true, Some("https://example.com")).await)
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
    assert!(body["message"].as_str().unwrap_or("").contains("No files"));
}

// =====================================================================
// /api/dashboard/transactions — provenance (fix-3)
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn transactions_listing_includes_source_field() {
    // fix-3: the listing omitted `source`, so the frontend assumed
    // 'plaid' and stamped "Synced via Plaid" on hand-entered rows.
    // The field must be present on every row (explicitly null at
    // worst — provenance is never left to be guessed client-side).
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let manual = seed_tx(&pool, user_id, account, "CRITIC TEST coffee", "-4.50").await;

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
    let row = rows
        .iter()
        .find(|r| r["id"].as_str().unwrap_or_default() == manual.to_string())
        .expect("seeded manual tx should be listed");
    assert_eq!(
        row["source"], "manual",
        "listing must carry the row's provenance"
    );
    // Every row serializes the key, even if the column were null.
    for r in rows {
        assert!(
            r.as_object().unwrap().contains_key("source"),
            "source key must be present on every row"
        );
    }
}

#[tokio::test]
#[serial_test::serial]
async fn transactions_listing_includes_user_notes_and_user_category() {
    // manual-tx-edit QA fix: this feed powers the main Transactions tab,
    // whose "Edit transaction" dialog prefills notes/category from the
    // row. The SELECT omitted user_notes/user_category, so the dialog
    // prefilled null and the subsequent PUT wrote user_notes = NULL —
    // a saved note was silently wiped by editing an unrelated field.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let noted = seed_tx(&pool, user_id, account, "CRITIC TEST noted row", "-9.99").await;
    sqlx::query(
        "UPDATE transactions SET user_notes = 'note to keep', user_category = 'Coffee' \
         WHERE id = $1 AND user_id = $2",
    )
    .bind(noted)
    .bind(user_id)
    .execute(&pool)
    .await
    .expect("stamp overrides");

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
    let row = rows
        .iter()
        .find(|r| r["id"].as_str().unwrap_or_default() == noted.to_string())
        .expect("seeded manual tx should be listed");
    assert_eq!(
        row["user_notes"], "note to keep",
        "feed must carry the stored note — the edit dialog prefills from it"
    );
    assert_eq!(
        row["user_category"], "Coffee",
        "feed must carry the category override (user_category-first display)"
    );
    // Both keys serialize on every row (explicit null at worst), matching
    // the per-account feed's shape so both edit surfaces see one contract.
    for r in rows {
        let obj = r.as_object().unwrap();
        assert!(
            obj.contains_key("user_notes"),
            "user_notes key on every row"
        );
        assert!(
            obj.contains_key("user_category"),
            "user_category key on every row"
        );
    }
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
    assert!(
        !parent_visible,
        "parent should be hidden once it has children"
    );
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
        "expected 'already split' error, got: {body:?}"
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
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM transactions WHERE parent_id = $1")
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
    let children: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM transactions WHERE parent_id = $1")
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
// /api/accounts/transactions/batch — bulk category / account update
// =====================================================================

/// Read a single transaction's category straight from the DB. Cleaner
/// than round-tripping a list endpoint just to assert one column.
async fn tx_category(pool: &PgPool, tx_id: uuid::Uuid) -> Option<String> {
    sqlx::query_scalar("SELECT user_category FROM transactions WHERE id = $1")
        .bind(tx_id)
        .fetch_one(pool)
        .await
        .expect("read tx category")
}

async fn tx_account(pool: &PgPool, tx_id: uuid::Uuid) -> uuid::Uuid {
    sqlx::query_scalar("SELECT account_id FROM transactions WHERE id = $1")
        .bind(tx_id)
        .fetch_one(pool)
        .await
        .expect("read tx account")
}

#[tokio::test]
#[serial_test::serial]
async fn batch_set_category_on_many_txns() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let t1 = seed_tx(&pool, user_id, account, "Coffee", "4.50").await;
    let t2 = seed_tx(&pool, user_id, account, "Lunch", "12.00").await;
    let t3 = seed_tx(&pool, user_id, account, "Dinner", "30.00").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            "/api/accounts/transactions/batch",
            Some(&serde_json::json!({
                "ids": [t1.to_string(), t2.to_string(), t3.to_string()],
                "user_category": "Dining"
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["updated"], 3);

    for t in [t1, t2, t3] {
        assert_eq!(
            tx_category(&pool, t).await.as_deref(),
            Some("Dining"),
            "all three should be recategorized"
        );
    }
}

#[tokio::test]
#[serial_test::serial]
async fn batch_move_account_on_many_txns() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, src) = seed_account(&pool, user_id).await;
    // A second account under the same institution to move the txns into.
    let dest: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Savings', 'depository', 'USD', 0.00, $2) RETURNING id",
    )
    .bind(inst)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed dest account");

    let t1 = seed_tx(&pool, user_id, src, "A", "1.00").await;
    let t2 = seed_tx(&pool, user_id, src, "B", "2.00").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            "/api/accounts/transactions/batch",
            Some(&serde_json::json!({
                "ids": [t1.to_string(), t2.to_string()],
                "account_id": dest.to_string()
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["updated"], 2);

    assert_eq!(tx_account(&pool, t1).await, dest);
    assert_eq!(tx_account(&pool, t2).await, dest);
}

/// Regression: the single PATCH /transactions/{id} handler wrote a
/// nonexistent `updated_at` column, so every inline edit (rename /
/// recategorize / move account) 500'd. It must 200 and persist.
#[tokio::test]
#[serial_test::serial]
async fn single_update_transaction_sets_category_ok() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let t1 = seed_tx(&pool, user_id, account, "Coffee", "4.50").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/accounts/transactions/{t1}"),
            Some(&serde_json::json!({"user_category": "Dining"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::OK,
        "single inline edit must 200, not 500"
    );
    assert_eq!(tx_category(&pool, t1).await.as_deref(), Some("Dining"));
}

// =====================================================================
// PUT /api/accounts/transactions/{id} — full edit of a manual row
// =====================================================================

/// JSON body for the manual-edit PUT — same field set the create path
/// takes (the frontend reopens the add dialog and resubmits).
fn manual_edit_body(account: uuid::Uuid) -> Value {
    serde_json::json!({
        "account_id": account.to_string(),
        "date": "2026-01-15",
        "description": "Team dinner",
        "amount": "-62.75",
        "currency": "USD",
        "category": "Dining",
        "notes": "will be reimbursed"
    })
}

#[tokio::test]
#[serial_test::serial]
async fn put_manual_edit_updates_amount_date_direction_and_clears_overrides() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    // Seed an INFLOW so the edit also flips direction (sign), and give it
    // stale overrides to prove the full edit clears them (a leftover
    // user_category/user_description would keep masking the edited
    // category/description in every list view).
    let tx = seed_tx(&pool, user_id, account, "Coffee", "4.50").await;
    sqlx::query(
        "UPDATE transactions SET user_category = 'Old override', user_description = 'Renamed' \
         WHERE id = $1",
    )
    .bind(tx)
    .execute(&pool)
    .await
    .expect("stamp overrides");

    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            &format!("/api/accounts/transactions/{tx}"),
            Some(&manual_edit_body(account)),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "manual edit should succeed");

    let row = sqlx::query(
        "SELECT date, description, amount, currency, category, user_category, \
                user_description, user_notes, external_id \
         FROM transactions WHERE id = $1",
    )
    .bind(tx)
    .fetch_one(&pool)
    .await
    .expect("read edited row");
    assert_eq!(
        row.get::<chrono::NaiveDate, _>("date").to_string(),
        "2026-01-15"
    );
    assert_eq!(row.get::<String, _>("description"), "Team dinner");
    assert_eq!(
        row.get::<Decimal, _>("amount"),
        Decimal::from_str("-62.75").unwrap(),
        "amount + direction (sign) must be rewritten"
    );
    assert_eq!(row.get::<String, _>("currency"), "USD");
    assert_eq!(
        row.get::<Option<String>, _>("category").as_deref(),
        Some("Dining")
    );
    assert_eq!(
        row.get::<Option<String>, _>("user_notes").as_deref(),
        Some("will be reimbursed")
    );
    assert_eq!(
        row.get::<Option<String>, _>("user_category"),
        None,
        "stale user_category override must be cleared by a full edit"
    );
    assert_eq!(
        row.get::<Option<String>, _>("user_description"),
        None,
        "stale user_description override must be cleared by a full edit"
    );
    // The dedup signature follows the edited fields, exactly as the
    // create path would have computed it for these values.
    assert_eq!(
        row.get::<Option<String>, _>("external_id").as_deref(),
        Some("manual:2026-01-15:-62.75:team dinner"),
    );
}

#[tokio::test]
#[serial_test::serial]
async fn put_manual_edit_rejects_non_manual_source_with_403() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    // A Plaid-synced row: its facts are the bank's, not the user's.
    let tx: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO transactions (account_id, date, description, amount, currency, source, user_id) \
         VALUES ($1, CURRENT_DATE, 'Synced coffee', -4.50, 'USD', 'plaid', $2) RETURNING id",
    )
    .bind(account)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed plaid tx");

    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            &format!("/api/accounts/transactions/{tx}"),
            Some(&manual_edit_body(account)),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::FORBIDDEN,
        "synced rows must never be rewritable"
    );
    let desc: String = sqlx::query_scalar("SELECT description FROM transactions WHERE id = $1")
        .bind(tx)
        .fetch_one(&pool)
        .await
        .expect("row still there");
    assert_eq!(desc, "Synced coffee", "row must be untouched");
}

#[tokio::test]
#[serial_test::serial]
async fn put_manual_edit_cross_user_is_404() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let _ = bootstrap(&app, &pool).await;
    let (alice_id, _alice_token) = seed_owner(&pool, "alice").await;
    let (_bob_id, bob_token) = seed_owner(&pool, "bob").await;
    let (_a_inst, a_acct) = seed_account(&pool, alice_id).await;
    let a_tx = seed_tx(&pool, alice_id, a_acct, "Alice groceries", "-80.00").await;

    // Bob attacks Alice's manual row (even naming her account as target).
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            &format!("/api/accounts/transactions/{a_tx}"),
            Some(&manual_edit_body(a_acct)),
            Some(&bob_token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_FOUND,
        "foreign rows must look nonexistent, not forbidden"
    );
    let desc: String = sqlx::query_scalar("SELECT description FROM transactions WHERE id = $1")
        .bind(a_tx)
        .fetch_one(&pool)
        .await
        .expect("row still there");
    assert_eq!(desc, "Alice groceries", "Alice's row must be untouched");
}

#[tokio::test]
#[serial_test::serial]
async fn put_manual_edit_cannot_move_into_foreign_account() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let _ = bootstrap(&app, &pool).await;
    let (alice_id, alice_token) = seed_owner(&pool, "alice").await;
    let (bob_id, _bob_token) = seed_owner(&pool, "bob").await;
    let (_a_inst, a_acct) = seed_account(&pool, alice_id).await;
    let (_b_inst, b_acct) = seed_account(&pool, bob_id).await;
    let a_tx = seed_tx(&pool, alice_id, a_acct, "Alice cash", "-10.00").await;

    // Alice edits her own row but targets BOB's account — the destination
    // ownership guard must reject it (mirrors the PATCH move guard).
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            &format!("/api/accounts/transactions/{a_tx}"),
            Some(&manual_edit_body(b_acct)),
            Some(&alice_token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
    assert_eq!(
        tx_account(&pool, a_tx).await,
        a_acct,
        "row must stay on Alice's account"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn batch_empty_ids_is_400() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            "/api/accounts/transactions/batch",
            Some(&serde_json::json!({
                "ids": [],
                "user_category": "Dining"
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
#[serial_test::serial]
async fn batch_cross_tenant_cannot_touch_other_users_txns() {
    // User B's transactions must be untouchable from user A's session.
    // The `user_id` predicate filters them out → updated count excludes
    // them, and B's category stays unchanged.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let _ = bootstrap(&app, &pool).await;
    let (alice_id, alice_token) = seed_owner(&pool, "alice").await;
    let (bob_id, _bob_token) = seed_owner(&pool, "bob").await;

    let (_a_inst, a_acct) = seed_account(&pool, alice_id).await;
    let a_tx = seed_tx(&pool, alice_id, a_acct, "Alice tx", "10.00").await;
    let (_b_inst, b_acct) = seed_account(&pool, bob_id).await;
    let b_tx = seed_tx(&pool, bob_id, b_acct, "Bob tx", "20.00").await;

    // Alice tries to recategorize BOTH her tx and Bob's tx in one batch.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            "/api/accounts/transactions/batch",
            Some(&serde_json::json!({
                "ids": [a_tx.to_string(), b_tx.to_string()],
                "user_category": "Hijacked"
            })),
            Some(&alice_token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    // Only Alice's row matches the user_id filter.
    assert_eq!(body["updated"], 1, "Bob's tx must be filtered out");

    assert_eq!(tx_category(&pool, a_tx).await.as_deref(), Some("Hijacked"));
    assert_eq!(
        tx_category(&pool, b_tx).await,
        None,
        "Bob's tx must be unchanged — cross-tenant write blocked"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn batch_partial_owned_and_bogus_ids_updates_only_owned() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let owned = seed_tx(&pool, user_id, account, "Real", "5.00").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            "/api/accounts/transactions/batch",
            Some(&serde_json::json!({
                "ids": [
                    owned.to_string(),
                    "00000000-0000-0000-0000-000000000000",
                    "11111111-1111-1111-1111-111111111111"
                ],
                "user_category": "Mixed"
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["updated"], 1, "only the owned, existing id updates");
    assert_eq!(tx_category(&pool, owned).await.as_deref(), Some("Mixed"));
}

// =====================================================================
// /api/accounts/transactions/batch-delete — bulk delete
// =====================================================================

/// True if a transaction row still exists (any owner).
async fn tx_exists(pool: &PgPool, tx_id: uuid::Uuid) -> bool {
    sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM transactions WHERE id = $1")
        .bind(tx_id)
        .fetch_one(pool)
        .await
        .expect("count tx")
        > 0
}

#[tokio::test]
#[serial_test::serial]
async fn batch_delete_removes_many_txns() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let t1 = seed_tx(&pool, user_id, account, "Coffee", "4.50").await;
    let t2 = seed_tx(&pool, user_id, account, "Lunch", "12.00").await;
    let t3 = seed_tx(&pool, user_id, account, "Dinner", "30.00").await;
    // A fourth row that is NOT in the batch — must survive.
    let keep = seed_tx(&pool, user_id, account, "Keep", "1.00").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/accounts/transactions/batch-delete",
            Some(&serde_json::json!({
                "ids": [t1.to_string(), t2.to_string(), t3.to_string()]
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["deleted"], 3);

    for t in [t1, t2, t3] {
        assert!(!tx_exists(&pool, t).await, "deleted rows must be gone");
    }
    assert!(tx_exists(&pool, keep).await, "untouched row must survive");
}

#[tokio::test]
#[serial_test::serial]
async fn batch_delete_empty_ids_is_400() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/accounts/transactions/batch-delete",
            Some(&serde_json::json!({ "ids": [] })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
#[serial_test::serial]
async fn batch_delete_cannot_touch_other_users_txns() {
    // Rows belonging to another user must be untouchable: the `user_id`
    // predicate filters them out → they're excluded from the deleted
    // count AND still present afterward.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let _ = bootstrap(&app, &pool).await;
    let (alice_id, alice_token) = seed_owner(&pool, "alice").await;
    let (bob_id, _bob_token) = seed_owner(&pool, "bob").await;

    let (_a_inst, a_acct) = seed_account(&pool, alice_id).await;
    let a_tx = seed_tx(&pool, alice_id, a_acct, "Alice tx", "10.00").await;
    let (_b_inst, b_acct) = seed_account(&pool, bob_id).await;
    let b_tx = seed_tx(&pool, bob_id, b_acct, "Bob tx", "20.00").await;

    // Alice tries to delete BOTH her tx and Bob's tx in one batch.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/accounts/transactions/batch-delete",
            Some(&serde_json::json!({
                "ids": [a_tx.to_string(), b_tx.to_string()]
            })),
            Some(&alice_token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    // Only Alice's row matches the user_id filter.
    assert_eq!(body["deleted"], 1, "Bob's tx must be filtered out");

    assert!(!tx_exists(&pool, a_tx).await, "Alice's row deleted");
    assert!(
        tx_exists(&pool, b_tx).await,
        "Bob's tx must survive — cross-tenant delete blocked"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn batch_delete_parent_cascades_to_split_children() {
    // Deleting a split parent must remove its children too (parent_id FK
    // is ON DELETE CASCADE), matching the single delete. The returned
    // count reflects only the directly-matched parent row.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let parent = seed_tx(&pool, user_id, account, "ATM withdrawal", "-200.00").await;

    // Two split children pointing at the parent.
    let child_a: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO transactions (account_id, parent_id, date, description, amount, currency, source, user_id) \
         VALUES ($1, $2, CURRENT_DATE, 'Groceries', $3, 'USD', 'manual', $4) RETURNING id",
    )
    .bind(account)
    .bind(parent)
    .bind(Decimal::from_str("-120.00").unwrap())
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed split child a");
    let child_b: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO transactions (account_id, parent_id, date, description, amount, currency, source, user_id) \
         VALUES ($1, $2, CURRENT_DATE, 'Dinner', $3, 'USD', 'manual', $4) RETURNING id",
    )
    .bind(account)
    .bind(parent)
    .bind(Decimal::from_str("-80.00").unwrap())
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed split child b");

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/accounts/transactions/batch-delete",
            Some(&serde_json::json!({ "ids": [parent.to_string()] })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    // Only the parent is directly matched; children are cascade-deleted.
    assert_eq!(body["deleted"], 1);

    assert!(!tx_exists(&pool, parent).await, "parent deleted");
    assert!(!tx_exists(&pool, child_a).await, "child cascade-deleted");
    assert!(!tx_exists(&pool, child_b).await, "child cascade-deleted");
}

// =====================================================================
// /api/accounts/{id}/transactions — optional limit/offset paging
// =====================================================================

/// Insert one transaction dated `days_ago` days back, so ordering
/// assertions don't depend on `created_at` insertion-order tiebreaks.
async fn seed_tx_days_ago(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    description: &str,
    days_ago: i32,
) -> uuid::Uuid {
    sqlx::query_scalar(
        "INSERT INTO transactions (account_id, date, description, amount, currency, source, user_id) \
         VALUES ($1, CURRENT_DATE - $2::int, $3, 10.00, 'USD', 'manual', $4) RETURNING id",
    )
    .bind(account_id)
    .bind(days_ago)
    .bind(description)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed dated tx")
}

/// GET the per-account transaction list and return the description
/// column in response order (the endpoint sorts newest-first).
async fn account_tx_descriptions(app: &Router, token: &str, uri: &str) -> Vec<String> {
    let res = app
        .clone()
        .oneshot(req(Method::GET, uri, None, Some(token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "GET {uri} should be 200");
    let body = body_json(res.into_body()).await;
    body.as_array()
        .expect("array body")
        .iter()
        .map(|t| t["description"].as_str().unwrap_or_default().to_string())
        .collect()
}

#[tokio::test]
#[serial_test::serial]
async fn account_transactions_pages_with_limit_and_offset() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    // T0 newest … T4 oldest (distinct dates → deterministic order).
    for i in 0..5 {
        seed_tx_days_ago(&pool, user_id, account, &format!("T{i}"), i).await;
    }

    // No params → legacy behavior: the whole history, newest first.
    let all = account_tx_descriptions(
        &app,
        &token,
        &format!("/api/accounts/{account}/transactions"),
    )
    .await;
    assert_eq!(all, vec!["T0", "T1", "T2", "T3", "T4"]);

    // limit alone → first page, newest first.
    let page1 = account_tx_descriptions(
        &app,
        &token,
        &format!("/api/accounts/{account}/transactions?limit=2"),
    )
    .await;
    assert_eq!(page1, vec!["T0", "T1"]);

    // limit + offset → the next slice, no overlap, no gap.
    let page2 = account_tx_descriptions(
        &app,
        &token,
        &format!("/api/accounts/{account}/transactions?limit=2&offset=2"),
    )
    .await;
    assert_eq!(page2, vec!["T2", "T3"]);

    // Offset past the end → empty list, not an error.
    let past_end = account_tx_descriptions(
        &app,
        &token,
        &format!("/api/accounts/{account}/transactions?limit=2&offset=50"),
    )
    .await;
    assert!(past_end.is_empty());
}

#[tokio::test]
#[serial_test::serial]
async fn account_transactions_clamps_degenerate_limit_and_offset() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    for i in 0..3 {
        seed_tx_days_ago(&pool, user_id, account, &format!("T{i}"), i).await;
    }

    // limit=0 clamps up to 1 (mirrors the dashboard endpoint's
    // clamp(1, 500)) instead of 500-ing or returning everything.
    let clamped_low = account_tx_descriptions(
        &app,
        &token,
        &format!("/api/accounts/{account}/transactions?limit=0"),
    )
    .await;
    assert_eq!(clamped_low, vec!["T0"]);

    // Negative offset floors to 0 → identical to the first page.
    let negative_offset = account_tx_descriptions(
        &app,
        &token,
        &format!("/api/accounts/{account}/transactions?limit=2&offset=-7"),
    )
    .await;
    assert_eq!(negative_offset, vec!["T0", "T1"]);

    // An absurd limit is accepted (clamped server-side to 500) and the
    // small table comes back whole — the clamp must not error.
    let clamped_high = account_tx_descriptions(
        &app,
        &token,
        &format!("/api/accounts/{account}/transactions?limit=99999"),
    )
    .await;
    assert_eq!(clamped_high, vec!["T0", "T1", "T2"]);
}

#[tokio::test]
#[serial_test::serial]
async fn account_transactions_include_persisted_balance_after() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    // Newest row carries a statement-imported running balance; the older
    // one doesn't (Plaid-synced / manual rows leave the column NULL).
    let with_bal = seed_tx_days_ago(&pool, user_id, account, "WithBal", 0).await;
    seed_tx_days_ago(&pool, user_id, account, "NoBal", 1).await;
    sqlx::query("UPDATE transactions SET balance_after = 1234.56 WHERE id = $1")
        .bind(with_bal)
        .execute(&pool)
        .await
        .expect("persist balance_after");

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/accounts/{account}/transactions"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().expect("array body");
    assert_eq!(rows.len(), 2);

    // Newest-first: the statement-imported row surfaces its persisted
    // balance as a JSON number…
    assert_eq!(rows[0]["description"], "WithBal");
    assert_eq!(rows[0]["balance_after"].as_f64(), Some(1234.56));
    // …and a row without one omits the key entirely
    // (skip_serializing_if) rather than sending an explicit null.
    assert_eq!(rows[1]["description"], "NoBal");
    assert!(
        rows[1].get("balance_after").is_none(),
        "NULL balance_after must be omitted from the payload"
    );
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
    sqlx::query("UPDATE users SET previous_login_at = NOW() - INTERVAL '24 hours' WHERE id = $1")
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

/// Insert a transaction whose `created_at` (what the summary counts by,
/// as opposed to the bank's `date`) sits `hours_ago` in the past.
async fn seed_tx_created_hours_ago(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    description: &str,
    hours_ago: i32,
) {
    sqlx::query(
        "INSERT INTO transactions \
             (account_id, date, description, amount, currency, source, user_id, created_at) \
         VALUES ($1, CURRENT_DATE, $2, 10.00, 'USD', 'manual', $3, NOW() - $4 * INTERVAL '1 hour')",
    )
    .bind(account_id)
    .bind(description)
    .bind(user_id)
    .bind(hours_ago)
    .execute(pool)
    .await
    .expect("seed backdated tx");
}

async fn since_last_login_body(app: &Router, token: &str) -> Value {
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/since-last-login",
            None,
            Some(token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    body_json(res.into_body()).await
}

#[tokio::test]
#[serial_test::serial]
async fn since_last_login_anchors_on_the_last_visit_not_the_last_login() {
    // Regression guard for the reported bug: a session survives for weeks,
    // so anchoring on `previous_login_at` told a user who opens the app
    // every day "143 new transactions since your last visit · Jul 13".
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;

    // Signed in a month ago, last actually looked at the dashboard
    // yesterday — the shape of a phone that stays logged in.
    sqlx::query(
        "UPDATE users SET previous_login_at = NOW() - INTERVAL '30 days', \
                          last_visit_at = NOW() - INTERVAL '1 day' \
         WHERE id = $1",
    )
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    // Landed a week ago (before yesterday's visit — already seen) and an
    // hour ago (genuinely new).
    seed_tx_created_hours_ago(&pool, user_id, account, "seen last week", 24 * 7).await;
    seed_tx_created_hours_ago(&pool, user_id, account, "actually new", 1).await;

    let body = since_last_login_body(&app, &token).await;
    assert_eq!(
        body["new_transactions"], 1,
        "only what arrived since the last VISIT counts — anchoring on the \
         30-day-old login would have reported both: {body}"
    );
    let anchor = body["previous_login_at"].as_str().expect("anchor present");
    let anchor = chrono::DateTime::parse_from_rfc3339(anchor).expect("rfc3339 anchor");
    let age_hours = (chrono::Utc::now() - anchor.with_timezone(&chrono::Utc)).num_hours();
    assert!(
        (20..30).contains(&age_hours),
        "the anchor is yesterday's visit, not the month-old login: {age_hours}h"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn reloading_within_a_visit_does_not_move_the_anchor() {
    // The summary must not evaporate while the user is reading it: a
    // second dashboard load in the same sitting is the same visit.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;

    sqlx::query(
        "UPDATE users SET previous_login_at = NOW() - INTERVAL '30 days', \
                          last_visit_at = NOW() - INTERVAL '1 day' \
         WHERE id = $1",
    )
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();
    // Arrived 6h ago: new relative to yesterday's visit, but older than
    // the 5h-ago visit the anchor advances to at the end of this test.
    seed_tx_created_hours_ago(&pool, user_id, account, "actually new", 6).await;

    let first = since_last_login_body(&app, &token).await;
    let second = since_last_login_body(&app, &token).await;
    assert_eq!(
        first["previous_login_at"], second["previous_login_at"],
        "a refresh inside the visit window keeps the same anchor: \
         {first} vs {second}"
    );
    assert_eq!(
        second["new_transactions"], 1,
        "…and therefore still reports what's new: {second}"
    );

    // Only once the gap has passed does the anchor advance to the visit
    // that just ended.
    sqlx::query("UPDATE users SET last_visit_at = NOW() - INTERVAL '5 hours' WHERE id = $1")
        .bind(user_id)
        .execute(&pool)
        .await
        .unwrap();
    let third = since_last_login_body(&app, &token).await;
    assert_ne!(
        third["previous_login_at"], second["previous_login_at"],
        "a gap starts a new visit and moves the anchor: {third}"
    );
    assert_eq!(
        third["new_transactions"], 0,
        "nothing has arrived since that visit ended: {third}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn since_last_login_largest_move_carries_account_id() {
    // Additive-field regression (P1-2): largest_move now names the moved
    // account by id (uuid as text) so the client can scope its drill-down
    // to the account. account_name / delta_usd must be unchanged.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;

    // Anchor 24h ago, snapshots straddling it: $1,000.00 two days back,
    // $3,612.87 now → a +$2,612.87 move on this depository account.
    sqlx::query("UPDATE users SET previous_login_at = NOW() - INTERVAL '24 hours' WHERE id = $1")
        .bind(user_id)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO balance_snapshots \
             (account_id, balance, balance_usd, as_of_date, currency, user_id, created_at) \
         VALUES ($1, 1000.00, 1000.00, CURRENT_DATE - 2, 'USD', $2, NOW() - INTERVAL '48 hours'), \
                ($1, 3612.87, 3612.87, CURRENT_DATE, 'USD', $2, NOW())",
    )
    .bind(account)
    .bind(user_id)
    .execute(&pool)
    .await
    .expect("seed straddling snapshots");

    let body = since_last_login_body(&app, &token).await;
    let mv = &body["largest_move"];
    assert!(mv.is_object(), "largest_move present: {body}");
    assert_eq!(
        mv["account_id"],
        account.to_string(),
        "the additive account_id is the seeded account's uuid: {mv}"
    );
    // The pre-existing fields are untouched by the addition.
    assert_eq!(mv["account_name"], "Checking", "{mv}");
    let delta = mv["delta_usd"].as_f64().expect("delta_usd is a number");
    assert!(
        (delta - 2612.87).abs() < 0.01,
        "delta_usd unchanged by the additive field: {delta}"
    );
    // FIX-2: the additive institution_name disambiguates generic account
    // nicknames on the client ("Cards · SoFi"). seed_account files the
    // account under the "Test Bank" institution.
    assert_eq!(
        mv["institution_name"], "Test Bank",
        "largest_move carries the account's institution name: {mv}"
    );
    // The omission contract for accounts without an institution (None →
    // key absent, not null) can't be seeded through the DB — accounts.
    // institution_id is NOT NULL — so it's pinned by the serde unit test
    // `balance_move_omits_absent_institution_name` in api/dashboard.rs.
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
    assert!(
        (implied - 19.5).abs() < 0.001,
        "implied 19.50 expected, got {implied}"
    );
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
async fn net_worth_history_carries_infrequently_snapshotted_accounts_forward() {
    // The HealthEquity bug: an account that snapshots on day 1 but NOT day 2
    // (a weekly-syncing HSA next to daily-syncing Plaid accounts) must still
    // be valued on day 2 at its last-known balance — otherwise it vanishes
    // from that date's net worth AND by_institution, and the movers
    // attribution reads its full balance as "growth from zero".
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst1, account1) = seed_account(&pool, user_id).await; // "Test Bank"
    let inst2: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ('HealthEquity', 'brokerage', 'US', 'manual', 'ok', $1) RETURNING id",
    )
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    let account2: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'HSA', 'investment', 'USD', 48000.00, $2) RETURNING id",
    )
    .bind(inst2)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    let insert_snap = |acct: uuid::Uuid, balance: &'static str, day: &'static str| {
        let pool = pool.clone();
        async move {
            sqlx::query(
                "INSERT INTO balance_snapshots (account_id, balance, balance_usd, as_of_date, currency, user_id) \
                 VALUES ($1, $2::numeric, $2::numeric, $3::date, 'USD', $4)",
            )
            .bind(acct).bind(balance).bind(day).bind(user_id)
            .execute(&pool).await.unwrap();
        }
    };
    // account1 snapshots both days; the HSA only on day 1.
    insert_snap(account1, "1000.00", "2026-05-01").await;
    insert_snap(account2, "48000.00", "2026-05-01").await;
    insert_snap(account1, "1100.00", "2026-05-02").await;

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
    let rows = body.as_array().unwrap();
    assert_eq!(rows.len(), 2, "two distinct as_of_dates");
    // Day 2 must still include the HSA's carried-forward $48k:
    // 1100 + 48000 = 49100 (before the fix this was just 1100).
    assert!(
        (rows[1]["net_worth"].as_f64().unwrap() - 49100.0).abs() < 0.01,
        "day-2 net worth carries the HSA forward, got {}",
        rows[1]["net_worth"]
    );
    let by_inst = rows[1]["by_institution"].as_object().unwrap();
    assert!(
        (by_inst["HealthEquity"].as_f64().unwrap() - 48000.0).abs() < 0.01,
        "HealthEquity present on day 2 via carry-forward, not missing"
    );
    assert!((by_inst["Test Bank"].as_f64().unwrap() - 1100.0).abs() < 0.01);
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
    assert!(body["error"].as_str().unwrap_or("").contains("read-only"));
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

async fn seed_owner(pool: &PgPool, username: &str) -> (uuid::Uuid, String) {
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
    assert!(
        ids.contains(&a_tx.to_string()),
        "Alice should see her own tx"
    );
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
    assert!(
        acct_ids.contains(&b_acct.to_string()),
        "Bob sees own account"
    );
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
        .oneshot(req(
            Method::GET,
            "/api/auth/sessions",
            None,
            Some(&alice_token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let arr = body.as_array().unwrap();
    assert_eq!(arr.len(), 1, "Alice should see exactly her one session");

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/auth/sessions",
            None,
            Some(&bob_token),
        ))
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

/// Like `seed_tx_dated` but sets the raw `category` — needed to exercise the
/// cash-flow exclusions, which key off `t.category` (investment trades,
/// internal transfers) rather than the amount sign alone.
async fn seed_tx_dated_cat(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    description: &str,
    amount: &str,
    date: &str,
    category: &str,
) -> uuid::Uuid {
    sqlx::query_scalar(
        "INSERT INTO transactions (account_id, date, description, amount, currency, source, user_id, category) \
         VALUES ($1, $2::date, $3, $4, 'USD', 'manual', $5, $6) RETURNING id",
    )
    .bind(account_id)
    .bind(date)
    .bind(description)
    .bind(Decimal::from_str(amount).unwrap())
    .bind(user_id)
    .bind(category)
    .fetch_one(pool)
    .await
    .expect("seed dated tx with category")
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
    let repay_tx = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "400.00",
        "2026-02-15",
    )
    .await;
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
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(
        (l["outstanding"].as_f64().unwrap() - 600.0).abs() < 0.01,
        "expected 600 outstanding, got {}",
        l["outstanding"]
    );
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
    assert_eq!(
        res.status(),
        StatusCode::CREATED,
        "cash payment must succeed"
    );

    // Outstanding drops to 750.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(
        (l["outstanding"].as_f64().unwrap() - 750.0).abs() < 0.01,
        "expected 750 outstanding after cash payment, got {}",
        l["outstanding"]
    );
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
    assert_eq!(
        res.status(),
        StatusCode::BAD_REQUEST,
        "a cash payment with no amount must 400"
    );
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
    let disb_tx = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Wire to Jose",
        "-1000.00",
        "2026-03-10",
    )
    .await;
    let _grocery =
        seed_tx_dated(&pool, user_id, acct, "Supermarket", "-200.00", "2026-03-11").await;
    // A repayment inflow + a normal paycheck inflow in another month.
    let repay_tx = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "500.00",
        "2026-04-10",
    )
    .await;
    let _paycheck = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "ACME Payroll",
        "3000.00",
        "2026-04-15",
    )
    .await;

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
        .oneshot(req(
            Method::GET,
            "/api/dashboard/trends",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let trends = body_json(res.into_body()).await;
    let march = trends
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["month"] == "2026-03")
        .cloned()
        .unwrap();
    assert!(
        (march["spending"].as_f64().unwrap() - 1200.0).abs() < 0.01,
        "pre-link March spending should be 1200, got {}",
        march["spending"]
    );

    // Link disbursement + record repayment.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/disbursement"),
            Some(&serde_json::json!({"transaction_id": disb_tx.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
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

    // AFTER linking: the disbursement drops out of March spending
    // (1200 → 200) and the repayment drops out of April income
    // (3500 → 3000).
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/trends",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let trends = body_json(res.into_body()).await;
    let arr = trends.as_array().unwrap();
    let march = arr
        .iter()
        .find(|p| p["month"] == "2026-03")
        .cloned()
        .unwrap();
    let april = arr
        .iter()
        .find(|p| p["month"] == "2026-04")
        .cloned()
        .unwrap();
    assert!(
        (march["spending"].as_f64().unwrap() - 200.0).abs() < 0.01,
        "post-link March spending should exclude the disbursement (200), got {}",
        march["spending"]
    );
    assert!(
        (april["income"].as_f64().unwrap() - 3000.0).abs() < 0.01,
        "post-link April income should exclude the repayment (3000), got {}",
        april["income"]
    );
}

/// Cash flow must count genuine income/spending only — not securities trades
/// (category `Investment`) nor internal `Transfer`s between the user's own
/// accounts. Regression for the "Buy VOO shows as $3,326 expense / a $10k ACH
/// shows as income" bug, where `spending_by_category` said "no spending" while
/// the headline claimed thousands of expense.
#[tokio::test]
async fn cash_flow_excludes_investment_trades_and_transfers() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // In one month: a securities buy, an internal transfer in, a dividend, and
    // a real grocery expense. Only the dividend (income) and grocery (spending)
    // are household cash flow.
    seed_tx_dated_cat(
        &pool,
        user_id,
        acct,
        "Buy 5 VOO @ 665.20",
        "-3326.00",
        "2026-03-05",
        "Investment",
    )
    .await;
    seed_tx_dated_cat(
        &pool,
        user_id,
        acct,
        "ACH deposit from checking",
        "10000.00",
        "2026-03-06",
        "Transfer",
    )
    .await;
    seed_tx_dated_cat(
        &pool,
        user_id,
        acct,
        "Dividend received - AAPL",
        "46.80",
        "2026-03-07",
        "Income",
    )
    .await;
    seed_tx_dated_cat(
        &pool,
        user_id,
        acct,
        "Supermarket",
        "-200.00",
        "2026-03-08",
        "Food",
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/trends",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let trends = body_json(res.into_body()).await;
    let march = trends
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["month"] == "2026-03")
        .cloned()
        .unwrap();

    // Income = dividend only (transfer-in excluded); spending = grocery only
    // (investment buy excluded).
    assert!(
        (march["income"].as_f64().unwrap() - 46.80).abs() < 0.01,
        "March income should exclude the $10k transfer, leaving the $46.80 dividend, got {}",
        march["income"]
    );
    assert!(
        (march["spending"].as_f64().unwrap() - 200.0).abs() < 0.01,
        "March spending should exclude the $3,326 VOO buy, leaving the $200 grocery, got {}",
        march["spending"]
    );

    // The peeled-off money is still visible as context: the VOO buy shows as
    // net invested (+3326) and the ACH deposit as net transferred in (+10000).
    assert!(
        (march["invested"].as_f64().unwrap() - 3326.0).abs() < 0.01,
        "March invested should surface the VOO buy (3326), got {}",
        march["invested"]
    );
    assert!(
        (march["transferred"].as_f64().unwrap() - 10000.0).abs() < 0.01,
        "March transferred should surface the ACH deposit (10000), got {}",
        march["transferred"]
    );
}

/// A positive inflow into a credit-card (liability) account — a payment,
/// refund, or reward-redemption — is not household income. Its purchases
/// (negatives) still count as spending. Regression for CC "Payment Thank You"
/// legs, Bilt rent-card payments, and statement credits inflating income.
#[tokio::test]
async fn cash_flow_excludes_credit_card_inflows_from_income() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, checking) = seed_account(&pool, user_id).await;
    let card: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Visa', 'credit', 'USD', -500.00, $2) RETURNING id",
    )
    .bind(inst)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed credit account");

    // Real payroll into checking; a CC payment inflow + a card purchase on the card.
    seed_tx_dated(
        &pool,
        user_id,
        checking,
        "ACME Payroll",
        "3000.00",
        "2026-03-15",
    )
    .await;
    seed_tx_dated(
        &pool,
        user_id,
        card,
        "Payment Thank You-Mobile",
        "800.00",
        "2026-03-16",
    )
    .await;
    seed_tx_dated(
        &pool,
        user_id,
        card,
        "Grocery Store",
        "-120.00",
        "2026-03-17",
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/trends",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let trends = body_json(res.into_body()).await;
    let march = trends
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["month"] == "2026-03")
        .cloned()
        .unwrap();

    assert!(
        (march["income"].as_f64().unwrap() - 3000.0).abs() < 0.01,
        "CC payment inflow must not count as income (payroll only), got {}",
        march["income"]
    );
    assert!(
        (march["spending"].as_f64().unwrap() - 120.0).abs() < 0.01,
        "card purchase should still count as spending, got {}",
        march["spending"]
    );
}

/// A tax refund is a return of the user's own overpaid tax, not earned income,
/// so it must not inflate the cash-flow income line the month it lands.
#[tokio::test]
async fn cash_flow_excludes_tax_refund_from_income() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, checking) = seed_account(&pool, user_id).await;

    seed_tx_dated(
        &pool,
        user_id,
        checking,
        "ACME Payroll",
        "3000.00",
        "2026-03-15",
    )
    .await;
    // A federal tax refund as Plaid tags it: INCOME / INCOME_TAX_REFUND.
    sqlx::query(
        "INSERT INTO transactions (account_id, date, description, amount, currency, source, user_id, category, category_detailed) \
         VALUES ($1, '2026-03-20'::date, 'IRS TREAS 310 TAX REF', 5000.00, 'USD', 'manual', $2, 'INCOME', 'INCOME_TAX_REFUND')",
    )
    .bind(checking)
    .bind(user_id)
    .execute(&pool)
    .await
    .expect("seed tax refund");

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/trends",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let trends = body_json(res.into_body()).await;
    let march = trends
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["month"] == "2026-03")
        .cloned()
        .unwrap();

    assert!(
        (march["income"].as_f64().unwrap() - 3000.0).abs() < 0.01,
        "tax refund must not count as income (payroll only), got {}",
        march["income"]
    );
}

/// A user re-categorization (user_category) overrides the raw Plaid category in
/// the cash-flow exclusions, in BOTH directions — matching how labels and the
/// tax view already treat it. Re-tagging a row "Transfer" drops it from income;
/// re-tagging a TRANSFER_IN row "Income" brings it back in.
#[tokio::test]
async fn cash_flow_honors_user_category_override() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, checking) = seed_account(&pool, user_id).await;

    // Plain payroll baseline.
    seed_tx_dated(
        &pool,
        user_id,
        checking,
        "ACME Payroll",
        "1000.00",
        "2026-03-12",
    )
    .await;
    // (a) A raw INCOME row the user re-tagged as a Transfer → excluded from income.
    // (b) A raw TRANSFER_IN row the user re-tagged as Income → counted as income.
    for (amount, category, user_cat, day) in [
        ("500.00", "INCOME", "Transfer", "10"),
        ("700.00", "TRANSFER_IN", "Income", "11"),
    ] {
        sqlx::query(
            "INSERT INTO transactions (account_id, date, description, amount, currency, source, user_id, category, user_category) \
             VALUES ($1, ('2026-03-' || $6)::date, 'x', $2, 'USD', 'manual', $3, $4, $5)",
        )
        .bind(checking)
        .bind(Decimal::from_str(amount).unwrap())
        .bind(user_id)
        .bind(category)
        .bind(user_cat)
        .bind(day)
        .execute(&pool)
        .await
        .expect("seed override tx");
    }

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/trends",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let trends = body_json(res.into_body()).await;
    let march = trends
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["month"] == "2026-03")
        .cloned()
        .unwrap();

    // 1000 payroll + 700 (TRANSFER_IN re-tagged Income); the 500 re-tagged Transfer is excluded.
    assert!((march["income"].as_f64().unwrap() - 1700.0).abs() < 0.01,
        "user_category override should drop the re-tagged Transfer and keep the re-tagged Income, got {}", march["income"]);
}

// Insert an expense with an explicit PFC category at a date relative to
// CURRENT_DATE (so the test is independent of the wall clock). `months_ago`
// counts whole calendar months back from today.
async fn seed_categorized_expense(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    category: &str,
    amount: &str,
    months_ago: i32,
) {
    sqlx::query(
        "INSERT INTO transactions (account_id, date, description, amount, currency, category, source, user_id) \
         VALUES ($1, (CURRENT_DATE - make_interval(months => $2))::date, $3, $4, 'USD', $5, 'manual', $6)",
    )
    .bind(account_id)
    .bind(months_ago)
    .bind(format!("{category} spend"))
    .bind(Decimal::from_str(amount).unwrap())
    .bind(category)
    .bind(user_id)
    .execute(pool)
    .await
    .expect("seed categorized expense");
}

#[tokio::test]
#[serial_test::serial]
async fn spending_by_category_groups_and_excludes() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // This month: 200 + 100 food, 50 merchandise.
    seed_categorized_expense(&pool, user_id, acct, "FOOD_AND_DRINK", "-200.00", 0).await;
    seed_categorized_expense(&pool, user_id, acct, "FOOD_AND_DRINK", "-100.00", 0).await;
    seed_categorized_expense(&pool, user_id, acct, "GENERAL_MERCHANDISE", "-50.00", 0).await;
    // Last month: 150 food.
    seed_categorized_expense(&pool, user_id, acct, "FOOD_AND_DRINK", "-150.00", 1).await;
    // Noise that must be excluded: income (positive) and an internal transfer.
    seed_categorized_expense(&pool, user_id, acct, "TRANSFER_OUT", "-500.00", 0).await;
    sqlx::query(
        "INSERT INTO transactions (account_id, date, description, amount, currency, category, source, user_id) \
         VALUES ($1, CURRENT_DATE, 'paycheck', 3000.00, 'USD', 'INCOME', 'manual', $2)",
    )
    .bind(acct)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/spending-by-category?months=3&top=8",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    let cats = body["categories"].as_array().unwrap();
    let food = cats
        .iter()
        .find(|c| c["category"] == "FOOD_AND_DRINK")
        .expect("food category present");
    // 200 + 100 (this month) + 150 (last month) = 450, transfer/income excluded.
    assert!(
        (food["total"].as_f64().unwrap() - 450.0).abs() < 0.01,
        "food total should be 450, got {}",
        food["total"]
    );
    let merch = cats
        .iter()
        .find(|c| c["category"] == "GENERAL_MERCHANDISE")
        .expect("merchandise present");
    assert!((merch["total"].as_f64().unwrap() - 50.0).abs() < 0.01);

    // The internal transfer must not appear as a spending category.
    assert!(
        !cats.iter().any(|c| c["category"] == "TRANSFER_OUT"),
        "internal transfers must be excluded"
    );
    // Food ranks first (highest total).
    assert_eq!(cats[0]["category"], "FOOD_AND_DRINK");
    // Two distinct months present.
    assert_eq!(body["months"].as_array().unwrap().len(), 2);
}

#[tokio::test]
#[serial_test::serial]
async fn spending_insights_recent_vs_trailing_average() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // FOOD: $400 in the most recent complete month (1mo ago), $200 in each of
    // the three baseline months (2/3/4mo ago). recent=400, previous_avg=200
    // (+100%), trailing_avg = (400+600)/4 = 250.
    seed_categorized_expense(&pool, user_id, acct, "FOOD_AND_DRINK", "-400.00", 1).await;
    seed_categorized_expense(&pool, user_id, acct, "FOOD_AND_DRINK", "-200.00", 2).await;
    seed_categorized_expense(&pool, user_id, acct, "FOOD_AND_DRINK", "-200.00", 3).await;
    seed_categorized_expense(&pool, user_id, acct, "FOOD_AND_DRINK", "-200.00", 4).await;
    // Current (partial) month must be EXCLUDED from the comparison entirely.
    seed_categorized_expense(&pool, user_id, acct, "FOOD_AND_DRINK", "-999.00", 0).await;
    // A smaller category present only in a baseline month.
    seed_categorized_expense(&pool, user_id, acct, "GENERAL_MERCHANDISE", "-60.00", 2).await;
    // Noise: an internal transfer + income must never surface as spend.
    seed_categorized_expense(&pool, user_id, acct, "TRANSFER_OUT", "-500.00", 1).await;
    sqlx::query(
        "INSERT INTO transactions (account_id, date, description, amount, currency, category, source, user_id) \
         VALUES ($1, (CURRENT_DATE - make_interval(months => 1))::date, 'paycheck', 3000.00, 'USD', 'INCOME', 'manual', $2)",
    )
    .bind(acct)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/spending-insights?lookback=3",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    assert_eq!(body["lookback"], 3);
    // recent_month is the most recent *complete* calendar month (last month).
    let expected_recent: String = sqlx::query_scalar(
        "SELECT TO_CHAR(DATE_TRUNC('month', CURRENT_DATE) - interval '1 month', 'YYYY-MM')",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(body["recent_month"], expected_recent);

    let cats = body["categories"].as_array().unwrap();
    // FOOD has the largest trailing spend → ranked first.
    assert_eq!(cats[0]["category"], "FOOD_AND_DRINK");
    let food = &cats[0];
    assert!(
        (food["recent"].as_f64().unwrap() - 400.0).abs() < 0.01,
        "recent should be 400 (current month's 999 excluded), got {}",
        food["recent"]
    );
    assert!(
        (food["previous_avg"].as_f64().unwrap() - 200.0).abs() < 0.01,
        "previous_avg should be 200, got {}",
        food["previous_avg"]
    );
    assert!(
        (food["trailing_avg"].as_f64().unwrap() - 250.0).abs() < 0.01,
        "trailing_avg should be 250, got {}",
        food["trailing_avg"]
    );

    let merch = cats
        .iter()
        .find(|c| c["category"] == "GENERAL_MERCHANDISE")
        .expect("merchandise present");
    // Only a baseline month → recent 0, previous_avg = 60/3 = 20, trailing = 60/4 = 15.
    assert!((merch["recent"].as_f64().unwrap()).abs() < 0.01);
    assert!((merch["previous_avg"].as_f64().unwrap() - 20.0).abs() < 0.01);
    assert!((merch["trailing_avg"].as_f64().unwrap() - 15.0).abs() < 0.01);

    // Internal transfers and income are never spending categories.
    assert!(!cats.iter().any(|c| c["category"] == "TRANSFER_OUT"));
    assert!(!cats.iter().any(|c| c["category"] == "INCOME"));
}

#[tokio::test]
#[serial_test::serial]
async fn portfolio_value_history_sums_only_investment_accounts() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;

    // An investment account (it has a holding) and a cash account (none).
    let invest: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Brokerage', 'brokerage', 'USD', 6000.00, $2) RETURNING id",
    )
    .bind(inst)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO holdings (account_id, symbol, name, currency, holding_type, quantity, value, user_id) \
         VALUES ($1,'VTI','Vanguard','USD','equity',10,6000,$2)",
    )
    .bind(invest)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();
    let cash: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Checking', 'checking', 'USD', 2500.00, $2) RETURNING id",
    )
    .bind(inst)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();

    // Two snapshot dates for BOTH accounts; only the investment account's
    // value should be summed into the series.
    for (acct, d, usd) in [
        (invest, "2026-04-01", "5000"),
        (cash, "2026-04-01", "2000"),
        (invest, "2026-05-01", "6000"),
        (cash, "2026-05-01", "2500"),
    ] {
        sqlx::query(
            "INSERT INTO balance_snapshots (account_id, balance, balance_usd, as_of_date, currency, user_id) \
             VALUES ($1, $2, $2, $3::date, 'USD', $4)",
        )
        .bind(acct)
        .bind(Decimal::from_str(usd).unwrap())
        .bind(d)
        .bind(user_id)
        .execute(&pool)
        .await
        .unwrap();
    }

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/portfolio-value-history",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let pts = body.as_array().unwrap();
    assert_eq!(pts.len(), 2, "two snapshot dates, got {pts:#?}");
    assert_eq!(pts[0]["date"], "2026-04-01");
    assert!(
        (pts[0]["value_usd"].as_f64().unwrap() - 5000.0).abs() < 0.01,
        "Apr should be the investment account only (5000), got {}",
        pts[0]["value_usd"]
    );
    assert!(
        (pts[1]["value_usd"].as_f64().unwrap() - 6000.0).abs() < 0.01,
        "May should be 6000, got {}",
        pts[1]["value_usd"]
    );
}

/// Partial-sync regression: accounts snapshot on different days, so a date's
/// naive per-date SUM only covered the accounts that snapshotted that day —
/// the trailing point after a one-institution refresh read as ONE account's
/// balance (the performance headline showed $299k for a $380k portfolio).
/// The series must carry each account's last-known balance forward instead.
#[tokio::test]
#[serial_test::serial]
async fn portfolio_value_history_carries_unsynced_accounts_forward() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;

    // Two investment accounts (both hold something).
    let mut accounts = Vec::new();
    for (name, sym) in [("Brokerage A", "VTI"), ("Brokerage B", "AAPL")] {
        let id: uuid::Uuid = sqlx::query_scalar(
            "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
             VALUES ($1, $2, 'brokerage', 'USD', 1000.00, $3) RETURNING id",
        )
        .bind(inst)
        .bind(name)
        .bind(user_id)
        .fetch_one(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO holdings (account_id, symbol, name, currency, holding_type, quantity, value, user_id) \
             VALUES ($1,$2,$2,'USD','equity',10,1000,$3)",
        )
        .bind(id)
        .bind(sym)
        .bind(user_id)
        .execute(&pool)
        .await
        .unwrap();
        accounts.push(id);
    }
    let (a, b) = (accounts[0], accounts[1]);

    // Day 1: both accounts snapshot. Day 2: only account A resynced.
    for (acct, d, usd) in [
        (a, "2026-06-01", "298000"),
        (b, "2026-06-01", "81000"),
        (a, "2026-06-02", "298993.70"),
    ] {
        sqlx::query(
            "INSERT INTO balance_snapshots (account_id, balance, balance_usd, as_of_date, currency, user_id) \
             VALUES ($1, $2, $2, $3::date, 'USD', $4)",
        )
        .bind(acct)
        .bind(Decimal::from_str(usd).unwrap())
        .bind(d)
        .bind(user_id)
        .execute(&pool)
        .await
        .unwrap();
    }

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/portfolio-value-history",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let pts = body.as_array().unwrap();
    assert_eq!(pts.len(), 2, "two snapshot dates, got {pts:#?}");
    assert!(
        (pts[0]["value_usd"].as_f64().unwrap() - 379_000.0).abs() < 0.01,
        "day 1 sums both accounts, got {}",
        pts[0]["value_usd"]
    );
    // The trailing point must include B's carried-forward $81,000 — not
    // just A's fresh snapshot.
    assert!(
        (pts[1]["value_usd"].as_f64().unwrap() - 379_993.70).abs() < 0.01,
        "trailing point must carry account B forward, got {}",
        pts[1]["value_usd"]
    );
}

#[tokio::test]
#[serial_test::serial]
async fn allocation_merges_cash_holdings_with_cash_accounts() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, acct) = seed_account(&pool, user_id).await;

    // A money-market HOLDING stored with lower-case holding_type 'cash', plus
    // an 'equity' holding.
    sqlx::query(
        "INSERT INTO holdings (account_id, symbol, name, currency, holding_type, quantity, value, user_id) \
         VALUES ($1,'VMFXX','Vanguard MM','USD','cash',100,5000,$2), \
                ($1,'AAPL','Apple','USD','equity',10,1000,$2)",
    )
    .bind(acct)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();
    // A cash ACCOUNT (checking) → the union hard-codes Title-Case 'Cash'.
    sqlx::query(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Checking', 'checking', 'USD', 2000.00, $2)",
    )
    .bind(inst)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/allocation",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().unwrap();

    // Every category carries a human display label plus the canonical
    // asset_class key (contract C2): the 'cash' holding classifies as 'cash'
    // (merging with the checking account) and 'equity' as 'equity'.
    assert!(
        !rows
            .iter()
            .any(|r| r["category"] == "cash" || r["category"] == "equity"),
        "categories should be human display labels, got {rows:#?}"
    );
    // Both the money-market holding (VMFXX) and the checking account sit under a
    // single 'Cash' band — the classifier and the accounts-union agree on the
    // canonical 'cash' key.
    let cash_subs: Vec<&str> = rows
        .iter()
        .filter(|r| r["asset_class"] == "cash")
        .filter_map(|r| r["sub_category"].as_str())
        .collect();
    // VMFXX is a short all-caps symbol, so the endpoint surfaces it as the
    // symbol rather than the long fund name.
    assert!(
        cash_subs.contains(&"VMFXX"),
        "MM holding under Cash: {cash_subs:?}"
    );
    assert!(
        cash_subs.contains(&"Checking"),
        "checking under Cash: {cash_subs:?}"
    );
    assert!(rows
        .iter()
        .all(|r| r["asset_class"] != "cash" || r["category"] == "Cash"));
    // The equity holding lands under the canonical 'equity' key with its
    // human display label.
    let equity = rows
        .iter()
        .find(|r| r["asset_class"] == "equity")
        .expect("an equity band");
    assert_eq!(equity["category"], "Stocks & funds");
}

#[tokio::test]
#[serial_test::serial]
async fn benchmark_series_returns_stored_sp500() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user_id) = bootstrap(&app, &pool).await;

    // Seed recent S&P 500 closes so ensure_fresh treats the series as fresh
    // and never touches the network during the test.
    for (offset, close) in [(2, "5000.00"), (1, "5050.00"), (0, "5100.00")] {
        sqlx::query(
            "INSERT INTO benchmark_prices (symbol, price_date, close) \
             VALUES ('SP500', (CURRENT_DATE - make_interval(days => $1))::date, $2) \
             ON CONFLICT (symbol, price_date) DO UPDATE SET close = EXCLUDED.close",
        )
        .bind(offset)
        .bind(Decimal::from_str(close).unwrap())
        .execute(&pool)
        .await
        .unwrap();
    }

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/benchmark?from=2000-01-01",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    assert_eq!(body["symbol"], "SP500");
    let pts = body["points"].as_array().unwrap();
    assert_eq!(pts.len(), 3, "three seeded closes, got {pts:#?}");
    // Ascending by date → last point is today's 5100.00.
    assert!((pts[2]["close"].as_f64().unwrap() - 5100.0).abs() < 0.01);
    assert!((pts[0]["close"].as_f64().unwrap() - 5000.0).abs() < 0.01);
}

#[tokio::test]
#[serial_test::serial]
async fn emergency_fund_runway_from_cash_and_spend() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;

    // A checking account (counts as liquid cash) with $6,000.
    let cash_acct: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Checking', 'checking', 'USD', 6000.00, $2) RETURNING id",
    )
    .bind(inst)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();

    // Two months of spending: $1,000 + $1,000 over 2 distinct months → $1,000/mo.
    seed_categorized_expense(&pool, user_id, cash_acct, "FOOD_AND_DRINK", "-1000.00", 0).await;
    seed_categorized_expense(
        &pool,
        user_id,
        cash_acct,
        "GENERAL_MERCHANDISE",
        "-1000.00",
        1,
    )
    .await;
    // An income row + an internal transfer must NOT reduce the runway.
    sqlx::query(
        "INSERT INTO transactions (account_id, date, description, amount, currency, category, source, user_id) \
         VALUES ($1, CURRENT_DATE, 'pay', 5000.00, 'USD', 'INCOME', 'manual', $2)",
    )
    .bind(cash_acct)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();
    seed_categorized_expense(&pool, user_id, cash_acct, "TRANSFER_OUT", "-9999.00", 0).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/emergency-fund",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    // $6,000 cash, $1,000/mo spend → 6.0 months.
    assert!(
        (body["liquid_cash_usd"].as_f64().unwrap() - 6000.0).abs() < 0.01,
        "liquid cash should be 6000, got {}",
        body["liquid_cash_usd"]
    );
    assert!(
        (body["monthly_spend_usd"].as_f64().unwrap() - 1000.0).abs() < 0.01,
        "monthly spend should be 1000 (transfer/income excluded), got {}",
        body["monthly_spend_usd"]
    );
    assert!(
        (body["months_covered"].as_f64().unwrap() - 6.0).abs() < 0.05,
        "runway should be ~6 months, got {}",
        body["months_covered"]
    );
}

#[tokio::test]
#[serial_test::serial]
async fn benchmark_comparison_contribution_weighted() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // S&P at the acquisition date (5000) and today (6000) → factor 1.2.
    sqlx::query(
        "INSERT INTO benchmark_prices (symbol, price_date, close) VALUES \
         ('SP500','2026-01-01',5000),('SP500',CURRENT_DATE,6000) \
         ON CONFLICT (symbol, price_date) DO UPDATE SET close = EXCLUDED.close",
    )
    .execute(&pool)
    .await
    .unwrap();

    // A holding worth $2,400 (10 sh @ $240) with one lot bought at $100/sh.
    let holding_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, quantity, value, user_id) \
         VALUES ($1,'VTI','Vanguard','USD',10,2400,$2) RETURNING id",
    )
    .bind(acct)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1,$2,$3,'2026-01-01',10,100,'USD',1.0,'l1')",
    )
    .bind(holding_id).bind(acct).bind(user_id).execute(&pool).await.unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/benchmark-comparison",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    assert_eq!(body["lot_count"].as_i64().unwrap(), 1);
    assert!((body["invested_usd"].as_f64().unwrap() - 1000.0).abs() < 0.01);
    assert!((body["your_value_usd"].as_f64().unwrap() - 2400.0).abs() < 0.01);
    // $1,000 invested in the index (5000→6000 = +20%) → $1,200.
    assert!((body["benchmark_value_usd"].as_f64().unwrap() - 1200.0).abs() < 0.01);
}

/// The comparison itemizes WHAT it recorded: a per-symbol breakdown built
/// with the same per-lot math as the totals (so rows sum back to them),
/// plus the holdings it could NOT cover (value but zero counted lots) and
/// their total. Regression test for the "aggregates only — can't see what's
/// in or out" gap.
#[tokio::test]
#[serial_test::serial]
async fn benchmark_comparison_per_symbol_breakdown_and_untracked() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // S&P closes: 5000 (D-60), 5500 (D-30), 6000 (today). A today-dated
    // close keeps the series "fresh" so the test never reaches out to Yahoo.
    sqlx::query(
        "INSERT INTO benchmark_prices (symbol, price_date, close) VALUES \
         ('SP500', CURRENT_DATE - 60, 5000), \
         ('SP500', CURRENT_DATE - 30, 5500), \
         ('SP500', CURRENT_DATE,      6000) \
         ON CONFLICT (symbol, price_date) DO UPDATE SET close = EXCLUDED.close",
    )
    .execute(&pool)
    .await
    .unwrap();
    // Expected ISO dates straight from Postgres so the assertion can't
    // drift from CURRENT_DATE across a midnight/timezone boundary.
    let (d60, d30): (String, String) =
        sqlx::query_as("SELECT (CURRENT_DATE - 60)::text, (CURRENT_DATE - 30)::text")
            .fetch_one(&pool)
            .await
            .unwrap();

    // Tracked holding 1: VOO, worth $2,400 (10 sh), one lot of 10 @
    // $100.0033 on D-60 → invested 1000.033, which must be presented as
    // 1000.03 (2dp house rounding).
    let voo: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, quantity, value, user_id) \
         VALUES ($1,'VOO','Vanguard S&P 500','USD',10,2400,$2) RETURNING id",
    )
    .bind(acct)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1,$2,$3, CURRENT_DATE - 60, 10, 100.0033, 'USD', 1.0, 'voo1')",
    )
    .bind(voo).bind(acct).bind(user_id).execute(&pool).await.unwrap();

    // Tracked holding 2: AAPL, worth $550 (5 sh), two lots — 2 @ $50 on
    // D-60 (index 5000) and 3 @ $60 on D-30 (index 5500).
    let aapl: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, quantity, value, user_id) \
         VALUES ($1,'AAPL','Apple','USD',5,550,$2) RETURNING id",
    )
    .bind(acct)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) VALUES \
         ($1,$2,$3, CURRENT_DATE - 60, 2, 50, 'USD', 1.0, 'aapl1'), \
         ($1,$2,$3, CURRENT_DATE - 30, 3, 60, 'USD', 1.0, 'aapl2')",
    )
    .bind(aapl).bind(acct).bind(user_id).execute(&pool).await.unwrap();

    // Untracked holding: FXAIX worth $25,000, no lots at all.
    sqlx::query(
        "INSERT INTO holdings (account_id, symbol, name, currency, quantity, value, user_id) \
         VALUES ($1,'FXAIX','Fidelity 500','USD',100,25000,$2)",
    )
    .bind(acct)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();
    // Untracked holding: has a lot, but its cost is 0 → the lot is skipped,
    // so the holding contributed zero counted lots.
    let crypto: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, quantity, value, user_id) \
         VALUES ($1,'BTC','Bitcoin','USD',1,100,$2) RETURNING id",
    )
    .bind(acct)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1,$2,$3, CURRENT_DATE - 10, 1, 0, 'USD', 1.0, 'btc1')",
    )
    .bind(crypto).bind(acct).bind(user_id).execute(&pool).await.unwrap();
    // Zero-value lot-less holding and a soft-deleted holding: neither may
    // appear anywhere.
    sqlx::query(
        "INSERT INTO holdings (account_id, symbol, name, currency, quantity, value, user_id) \
         VALUES ($1,'EMPTY','Sold Out','USD',0,0,$2), \
                ($1,'GONE','Deleted','USD',3,999,$2)",
    )
    .bind(acct)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query("UPDATE holdings SET deleted_at = NOW() WHERE symbol = 'GONE' AND user_id = $1")
        .bind(user_id)
        .execute(&pool)
        .await
        .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/benchmark-comparison",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    // Totals: 1000.033 + 280 invested over 3 counted lots.
    assert_eq!(body["lot_count"].as_i64().unwrap(), 3);
    let total_invested = body["invested_usd"].as_f64().unwrap();
    let total_value = body["your_value_usd"].as_f64().unwrap();
    let total_bench = body["benchmark_value_usd"].as_f64().unwrap();
    assert!(
        (total_invested - 1280.033).abs() < 0.01,
        "invested total, got {total_invested}"
    );
    assert!(
        (total_value - 2950.0).abs() < 0.01,
        "value total, got {total_value}"
    );

    // Per-symbol rows: sorted by invested_usd DESC → VOO before AAPL.
    let symbols = body["symbols"].as_array().unwrap();
    assert_eq!(symbols.len(), 2, "two tracked symbols, got {symbols:#?}");
    let voo_row = &symbols[0];
    let aapl_row = &symbols[1];
    assert_eq!(voo_row["symbol"], "VOO");
    assert_eq!(aapl_row["symbol"], "AAPL");

    // VOO: exact 2dp presentation (1000.033 → 1000.03), 5000→6000 = ×1.2.
    assert_eq!(voo_row["lot_count"].as_i64().unwrap(), 1);
    assert!(
        (voo_row["invested_usd"].as_f64().unwrap() - 1000.03).abs() < 1e-9,
        "VOO invested must be rounded to exactly 1000.03, got {}",
        voo_row["invested_usd"]
    );
    assert!((voo_row["your_value_usd"].as_f64().unwrap() - 2400.0).abs() < 1e-9);
    assert!(
        (voo_row["benchmark_value_usd"].as_f64().unwrap() - 1200.04).abs() < 1e-9,
        "VOO benchmark: 1000.033 × 1.2 = 1200.0396 → 1200.04, got {}",
        voo_row["benchmark_value_usd"]
    );
    assert_eq!(voo_row["first_acquired"], d60.as_str());
    assert_eq!(voo_row["last_acquired"], d60.as_str());

    // AAPL: 2 lots; bench = 100×(6000/5000) + 180×(6000/5500) = 316.36.
    assert_eq!(aapl_row["lot_count"].as_i64().unwrap(), 2);
    assert!((aapl_row["invested_usd"].as_f64().unwrap() - 280.0).abs() < 1e-9);
    assert!((aapl_row["your_value_usd"].as_f64().unwrap() - 550.0).abs() < 1e-9);
    assert!(
        (aapl_row["benchmark_value_usd"].as_f64().unwrap() - 316.36).abs() < 1e-9,
        "AAPL benchmark, got {}",
        aapl_row["benchmark_value_usd"]
    );
    assert_eq!(aapl_row["first_acquired"], d60.as_str());
    assert_eq!(aapl_row["last_acquired"], d30.as_str());

    // The rows must reproduce the totals (modulo the per-row 2dp rounding).
    let sum = |field: &str| -> f64 { symbols.iter().map(|s| s[field].as_f64().unwrap()).sum() };
    assert!((sum("invested_usd") - total_invested).abs() < 0.01);
    assert!((sum("your_value_usd") - total_value).abs() < 0.01);
    assert!((sum("benchmark_value_usd") - total_bench).abs() < 0.01);

    // Untracked: FXAIX (no lots) then BTC (only a skipped zero-cost lot),
    // value DESC; the zero-value and soft-deleted holdings are absent.
    let untracked = body["untracked"].as_array().unwrap();
    assert_eq!(untracked.len(), 2, "untracked, got {untracked:#?}");
    assert_eq!(untracked[0]["symbol"], "FXAIX");
    assert!((untracked[0]["value_usd"].as_f64().unwrap() - 25000.0).abs() < 1e-9);
    assert_eq!(untracked[1]["symbol"], "BTC");
    assert!((untracked[1]["value_usd"].as_f64().unwrap() - 100.0).abs() < 1e-9);
    assert!((body["untracked_value_usd"].as_f64().unwrap() - 25100.0).abs() < 1e-9);
}

/// True time-weighted return divides out the contribution: a mid-window buy
/// must NOT inflate the return the way a naive (end-start)/start would. We
/// hand-build a price path where the honest TWR is +21% even though the
/// dollar value more than doubled (because most of the value came from the
/// contribution, not the market).
#[tokio::test]
#[serial_test::serial]
async fn portfolio_twr_divides_out_contributions() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // Quote path for AAPL: 100 (D-60) → 110 (D-30) → 121 (today), i.e. two
    // +10% legs = +21% compounded. S&P: 1000 (D-60) → 1100 (today) = +10%.
    // Dates are CURRENT_DATE-relative so the seeded series reads as "fresh"
    // and the freshness gate doesn't reach out to Yahoo during the test.
    sqlx::query(
        "INSERT INTO benchmark_prices (symbol, price_date, close) VALUES \
         ('AAPL', CURRENT_DATE - 60, 100), \
         ('AAPL', CURRENT_DATE - 30, 110), \
         ('AAPL', CURRENT_DATE,      121), \
         ('SP500', CURRENT_DATE - 60, 1000), \
         ('SP500', CURRENT_DATE,      1100) \
         ON CONFLICT (symbol, price_date) DO UPDATE SET close = EXCLUDED.close",
    )
    .execute(&pool)
    .await
    .unwrap();

    // Current position: 10 shares worth 10 × 121 = 1210.
    let holding_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, quantity, value, user_id) \
         VALUES ($1,'AAPL','Apple','USD',10,1210,$2) RETURNING id",
    )
    .bind(acct)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    // Opening lot of 6 @ 100 on D-60, then a contribution of 4 @ 110 on D-30.
    // 6 + 4 = the 10 shares held today.
    sqlx::query(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) VALUES \
         ($1,$2,$3, CURRENT_DATE - 60, 6, 100, 'USD', 1.0, 'open'), \
         ($1,$2,$3, CURRENT_DATE - 30, 4, 110, 'USD', 1.0, 'add')",
    )
    .bind(holding_id)
    .bind(acct)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/portfolio-twr",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    // Whole portfolio is the priceable AAPL position.
    assert!(
        (body["coverage_pct"].as_f64().unwrap() - 1.0).abs() < 0.001,
        "coverage should be 100%, got {}",
        body["coverage_pct"]
    );
    assert!((body["total_value_usd"].as_f64().unwrap() - 1210.0).abs() < 0.5);
    // The honest TWR is +21% — NOT the ~+102% a naive value change would show
    // (1210 vs the 600 opening value includes the 440 contribution).
    assert!(
        (body["your_twr"].as_f64().unwrap() - 0.21).abs() < 0.005,
        "TWR should be ~0.21 (contribution divided out), got {}",
        body["your_twr"]
    );
    assert!(
        (body["sp_twr"].as_f64().unwrap() - 0.10).abs() < 0.005,
        "S&P TWR should be ~0.10, got {}",
        body["sp_twr"]
    );
    // Daily growth index: starts at 1.0, ends at ~1.21 / ~1.10.
    let points = body["points"].as_array().unwrap();
    assert!(
        points.len() > 50,
        "expected a daily series, got {}",
        points.len()
    );
    let last = points.last().unwrap();
    assert!((last["twr"].as_f64().unwrap() - 1.21).abs() < 0.005);
    assert!((last["sp"].as_f64().unwrap() - 1.10).abs() < 0.005);
}

#[tokio::test]
#[serial_test::serial]
async fn tax_summary_splits_short_and_long_term_from_lots() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    let holding_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, user_id) \
         VALUES ($1, 'VTI', 'Vanguard', 'USD', $2) RETURNING id",
    )
    .bind(acct)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();

    // A short-term lot (acquired 2026-01, sold 2026-06 → < 1yr) and a long-term
    // lot (acquired 2022, sold 2026-06 → > 1yr).
    let st_lot: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1,$2,$3,'2026-01-01',10,60,'USD',1.0,'st') RETURNING id",
    )
    .bind(holding_id).bind(acct).bind(user_id).fetch_one(&pool).await.unwrap();
    let lt_lot: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1,$2,$3,'2022-01-01',10,40,'USD',1.0,'lt') RETURNING id",
    )
    .bind(holding_id).bind(acct).bind(user_id).fetch_one(&pool).await.unwrap();

    for (lot, src, pnl) in [(st_lot, "sell-st", "500"), (lt_lot, "sell-lt", "3000")] {
        sqlx::query(
            "INSERT INTO lot_disposals \
             (user_id, holding_id, account_id, lot_id, sell_source_id, qty_sold, sell_price_per_unit, \
              sell_currency, sell_fx_rate, sell_date, cost_per_unit, cost_fx_rate, realized_pnl_usd) \
             VALUES ($1,$2,$3,$4,$5,10,100,'USD',1.0,'2026-06-01',60,1.0,$6)",
        )
        .bind(user_id).bind(holding_id).bind(acct).bind(lot).bind(src)
        .bind(Decimal::from_str(pnl).unwrap())
        .execute(&pool).await.unwrap();
    }

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/tax/summary?year=2026&status=Single",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let status = res.status();
    let body = body_json(res.into_body()).await;
    assert_eq!(status, StatusCode::OK, "tax summary body: {body}");

    assert_eq!(body["gains_from_lots"], serde_json::json!(true));
    assert!((body["short_term_gains"].as_f64().unwrap() - 500.0).abs() < 0.01);
    assert!((body["long_term_gains"].as_f64().unwrap() - 3000.0).abs() < 0.01);
    assert!((body["capital_gains"].as_f64().unwrap() - 3500.0).abs() < 0.01);
    // T4 expectation update: this pinned ~$50 when brackets applied from
    // dollar zero. With the (unverified) standard deduction, the $500 ST gain
    // is fully absorbed and the $3,000 LT gain sits in the 0% LTCG band → $0.
    assert!(
        (body["estimated_liability_us"].as_f64().unwrap()).abs() < 0.01,
        "expected $0 US liability, got {}",
        body["estimated_liability_us"]
    );
}

#[tokio::test]
#[serial_test::serial]
async fn tax_csv_export_includes_realized_gains_and_st_lt_summary() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    let holding_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, user_id) \
         VALUES ($1, 'VTI', 'Vanguard', 'USD', $2) RETURNING id",
    )
    .bind(acct)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();

    // One short-term lot (held <1yr) and one long-term lot (held >1yr), both
    // sold in 2026.
    let st_lot: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1,$2,$3,'2026-01-01',10,60,'USD',1.0,'st') RETURNING id",
    )
    .bind(holding_id).bind(acct).bind(user_id).fetch_one(&pool).await.unwrap();
    let lt_lot: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1,$2,$3,'2022-01-01',10,40,'USD',1.0,'lt') RETURNING id",
    )
    .bind(holding_id).bind(acct).bind(user_id).fetch_one(&pool).await.unwrap();

    for (lot, src, pnl) in [(st_lot, "sell-st", "500"), (lt_lot, "sell-lt", "3000")] {
        sqlx::query(
            "INSERT INTO lot_disposals \
             (user_id, holding_id, account_id, lot_id, sell_source_id, qty_sold, sell_price_per_unit, \
              sell_currency, sell_fx_rate, sell_date, cost_per_unit, cost_fx_rate, realized_pnl_usd) \
             VALUES ($1,$2,$3,$4,$5,10,100,'USD',1.0,'2026-06-01',60,1.0,$6)",
        )
        .bind(user_id).bind(holding_id).bind(acct).bind(lot).bind(src)
        .bind(Decimal::from_str(pnl).unwrap())
        .execute(&pool).await.unwrap();
    }

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/tax/export?year=2026&status=Single",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(res.headers().get(header::CONTENT_TYPE).unwrap(), "text/csv");
    let bytes = to_bytes(res.into_body(), 1024 * 256).await.unwrap();
    let csv = String::from_utf8(bytes.to_vec()).unwrap();

    // The Form 8949-style section + per-disposal detail.
    assert!(
        csv.contains("Realized capital gains (lot disposals)"),
        "csv:\n{csv}"
    );
    assert!(csv.contains("Date acquired"), "header present");
    assert!(csv.contains("VTI"), "disposal symbol present");
    assert!(csv.contains("Short-term"), "ST term label present");
    assert!(csv.contains("Long-term"), "LT term label present");
    assert!(csv.contains("2022-01-01"), "LT acquisition date present");
    // Derived USD proceeds (10*100) and cost (10*60).
    assert!(csv.contains("1000.00"), "proceeds present");
    assert!(csv.contains("600.00"), "cost basis present");

    // The summary block with the ST/LT split.
    assert!(csv.contains("Short-term gains (USD),500.00"), "csv:\n{csv}");
    assert!(csv.contains("Long-term gains (USD),3000.00"), "csv:\n{csv}");
    assert!(csv.contains("Total capital gains (USD),3500.00"));
    assert!(csv.contains("Precise lot disposals"), "basis note present");

    // The PDF export still renders (200 + a non-empty application/pdf body).
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/tax/export/pdf?year=2026&status=Single",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(
        res.headers().get(header::CONTENT_TYPE).unwrap(),
        "application/pdf"
    );
    let pdf = to_bytes(res.into_body(), 1024 * 1024).await.unwrap();
    assert!(pdf.len() > 200, "pdf body should be non-trivial");
    assert_eq!(&pdf[0..4], b"%PDF", "starts with the PDF magic header");
}

#[tokio::test]
#[serial_test::serial]
async fn account_balance_history_returns_monthly_closing() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // Two months of statement rows with a running balance_after. The endpoint
    // should return the LAST balance in each month.
    let insert = |date: &'static str, amount: &'static str, bal: &'static str| {
        let pool = pool.clone();
        async move {
            sqlx::query(
                "INSERT INTO transactions (account_id, date, description, amount, currency, balance_after, source, user_id) \
                 VALUES ($1, $2::date, 'row', $3, 'USD', $4, 'manual', $5)",
            )
            .bind(acct)
            .bind(date)
            .bind(Decimal::from_str(amount).unwrap())
            .bind(Decimal::from_str(bal).unwrap())
            .bind(user_id)
            .execute(&pool)
            .await
            .unwrap();
        }
    };
    insert("2026-03-05", "-100.00", "900.00").await;
    insert("2026-03-20", "-50.00", "850.00").await; // latest in March
    insert("2026-04-10", "200.00", "1050.00").await; // latest in April
                                                     // A row with no balance_after must be ignored.
    seed_tx_dated(&pool, user_id, acct, "no balance", "-10.00", "2026-04-15").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/dashboard/account-balance-history?account_id={acct}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let arr = body.as_array().unwrap();
    assert_eq!(arr.len(), 2, "two months expected");
    assert_eq!(arr[0]["month"], "2026-03");
    assert!((arr[0]["balance"].as_f64().unwrap() - 850.0).abs() < 0.01);
    assert_eq!(arr[1]["month"], "2026-04");
    assert!((arr[1]["balance"].as_f64().unwrap() - 1050.0).abs() < 0.01);

    // Tenant isolation: a bogus account id yields an empty series, not data.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/account-balance-history?account_id=not-a-uuid",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert_eq!(body.as_array().unwrap().len(), 0);
}

/// An account with NO `balance_after` transactions but >=2 daily
/// `balance_snapshots` (the Plaid / manual case) now returns a
/// snapshot-derived monthly series — the latest snapshot in each month.
/// A statement account (with `balance_after`) is unaffected: its snapshots
/// are ignored so nothing double-counts.
#[tokio::test]
#[serial_test::serial]
async fn account_balance_history_falls_back_to_snapshots() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;

    // Account A: snapshot-only (no balance_after rows).
    let (_inst, snap_acct) = seed_account(&pool, user_id).await;
    let insert_snap = |acct: uuid::Uuid, date: &'static str, bal: &'static str| {
        let pool = pool.clone();
        async move {
            sqlx::query(
                "INSERT INTO balance_snapshots (account_id, balance, balance_usd, as_of_date, currency, user_id) \
                 VALUES ($1, $2, $2, $3::date, 'USD', $4)",
            )
            .bind(acct)
            .bind(Decimal::from_str(bal).unwrap())
            .bind(date)
            .bind(user_id)
            .execute(&pool)
            .await
            .unwrap();
        }
    };
    insert_snap(snap_acct, "2026-05-03", "500.00").await;
    insert_snap(snap_acct, "2026-05-28", "550.00").await; // latest in May
    insert_snap(snap_acct, "2026-06-15", "600.00").await; // latest in June

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/dashboard/account-balance-history?account_id={snap_acct}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let arr = body.as_array().unwrap();
    assert_eq!(arr.len(), 2, "two snapshot-derived months expected");
    assert_eq!(arr[0]["month"], "2026-05");
    assert!((arr[0]["balance"].as_f64().unwrap() - 550.0).abs() < 0.01);
    assert_eq!(arr[1]["month"], "2026-06");
    assert!((arr[1]["balance"].as_f64().unwrap() - 600.0).abs() < 0.01);

    // Account B: statement account WITH balance_after — snapshots must be
    // ignored (statement path wins, no double count / no regression).
    let (_inst2, stmt_acct) = seed_account(&pool, user_id).await;
    sqlx::query(
        "INSERT INTO transactions (account_id, date, description, amount, currency, balance_after, source, user_id) \
         VALUES ($1, '2026-05-10'::date, 'row', '-20.00', 'USD', '980.00', 'manual', $2)",
    )
    .bind(stmt_acct)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();
    // A stray snapshot on the same account that must NOT surface.
    insert_snap(stmt_acct, "2026-06-01", "1234.56").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/dashboard/account-balance-history?account_id={stmt_acct}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let arr = body.as_array().unwrap();
    assert_eq!(
        arr.len(),
        1,
        "statement account: only its balance_after month"
    );
    assert_eq!(arr[0]["month"], "2026-05");
    assert!((arr[0]["balance"].as_f64().unwrap() - 980.0).abs() < 0.01);
}

#[tokio::test]
#[serial_test::serial]
async fn realized_gains_summary_and_long_term_flag() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    let holding_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, user_id) \
         VALUES ($1, 'VTI', 'Vanguard Total Market', 'USD', $2) RETURNING id",
    )
    .bind(acct)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();

    let lot_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holding_lots \
         (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1, $2, $3, (CURRENT_DATE - INTERVAL '3 years')::date, 10, 60, 'USD', 1.0, 'lot-1') RETURNING id",
    )
    .bind(holding_id)
    .bind(acct)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();

    // This-year disposal: held ~3 years (long-term), +400 gain.
    sqlx::query(
        "INSERT INTO lot_disposals \
         (user_id, holding_id, account_id, lot_id, sell_source_id, qty_sold, sell_price_per_unit, \
          sell_currency, sell_fx_rate, sell_date, cost_per_unit, cost_fx_rate, realized_pnl_usd) \
         VALUES ($1, $2, $3, $4, 'sell-1', 10, 100, 'USD', 1.0, CURRENT_DATE, 60, 1.0, 400)",
    )
    .bind(user_id)
    .bind(holding_id)
    .bind(acct)
    .bind(lot_id)
    .execute(&pool)
    .await
    .unwrap();

    // Prior-year disposal: lot since deleted (lot_id NULL), -150 loss.
    sqlx::query(
        "INSERT INTO lot_disposals \
         (user_id, holding_id, account_id, lot_id, sell_source_id, qty_sold, sell_price_per_unit, \
          sell_currency, sell_fx_rate, sell_date, cost_per_unit, cost_fx_rate, realized_pnl_usd) \
         VALUES ($1, $2, $3, NULL, 'sell-2', 5, 50, 'USD', 1.0, (CURRENT_DATE - INTERVAL '2 years')::date, 80, 1.0, -150)",
    )
    .bind(user_id)
    .bind(holding_id)
    .bind(acct)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/realized-gains",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    // Summary: all-time = 400 - 150 = 250; YTD = 400 (this-year only).
    assert!((body["summary"]["total_realized_usd"].as_f64().unwrap() - 250.0).abs() < 0.01);
    assert!((body["summary"]["ytd_realized_usd"].as_f64().unwrap() - 400.0).abs() < 0.01);
    assert_eq!(body["summary"]["count"].as_i64().unwrap(), 2);
    assert_eq!(body["by_year"].as_array().unwrap().len(), 2);

    // Most recent disposal first: the long-term gain with USD proceeds/cost.
    let d0 = &body["disposals"][0];
    assert_eq!(d0["symbol"], "VTI");
    assert!((d0["realized_pnl_usd"].as_f64().unwrap() - 400.0).abs() < 0.01);
    assert!((d0["proceeds_usd"].as_f64().unwrap() - 1000.0).abs() < 0.01);
    assert!((d0["cost_usd"].as_f64().unwrap() - 600.0).abs() < 0.01);
    assert_eq!(d0["long_term"], serde_json::json!(true));
    assert!(d0["holding_days"].as_i64().unwrap() > 365);
    // The deleted-lot disposal has an unknown holding period.
    let d1 = &body["disposals"][1];
    assert!(d1["long_term"].is_null());

    // Year filter narrows the list to the current year only.
    let this_year = &d0["sell_date"].as_str().unwrap()[..4];
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/dashboard/realized-gains?year={this_year}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert_eq!(body["summary"]["count"].as_i64().unwrap(), 1);
    assert_eq!(body["disposals"].as_array().unwrap().len(), 1);
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
    let good = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "ZELLE TO JOSE RAMIREZ",
        "-5000.00",
        "2026-01-15",
    )
    .await;
    // Case 4 (TN): wrong amount, same day.
    let _wrong_amount =
        seed_tx_dated(&pool, user_id, acct, "Coffee", "-250.00", "2026-01-15").await;
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
    assert_eq!(
        arr.len(),
        1,
        "exactly one disbursement suggestion expected, got {arr:?}"
    );
    assert_eq!(arr[0]["transaction_id"].as_str().unwrap(), good.to_string());
    assert!(
        arr[0]["confidence"].as_i64().unwrap() >= 80,
        "exact+name should be high confidence"
    );
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
    let tx = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Wire to Jose",
        "-5000.00",
        "2026-01-15",
    )
    .await;

    // Loan A links the tx as its disbursement.
    let loan_a = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose", "principal": 5000.0, "currency": "USD", "origination_date": "2026-01-15"
    })).await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_a}/disbursement"),
            Some(&serde_json::json!({"transaction_id": tx.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    // Loan B (same borrower/amount) must NOT see that tx suggested —
    // it's already linked (Case 7 / Case 19 disambiguation).
    let loan_b = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose", "principal": 5000.0, "currency": "USD", "origination_date": "2026-01-15"
    })).await;
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_b}/suggestions/disbursement"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let suggestions = body_json(res.into_body()).await;
    assert_eq!(
        suggestions.as_array().unwrap().len(),
        0,
        "an already-linked disbursement must not be suggested for another loan"
    );
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
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&bob_token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_FOUND,
        "Bob must not read Alice's loan"
    );

    // Bob cannot DELETE Alice's loan.
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&bob_token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_FOUND,
        "Bob must not delete Alice's loan"
    );

    // Bob's own loan list is empty.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans", None, Some(&bob_token)))
        .await
        .unwrap();
    let arr = body_json(res.into_body()).await;
    assert_eq!(
        arr.as_array().unwrap().len(),
        0,
        "Bob sees none of Alice's loans"
    );
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

/// An installment paid EXACTLY must land as 'paid'.
///
/// `Decimal::from_f64_retain(1033.33)` keeps the full binary expansion
/// (`1033.3299999999999272…`), and the allocation loop compares that
/// unrounded value against the stored `scheduled_amount` (`1033.330000`) in
/// SQL — so an exact payoff evaluated `>=` as FALSE and the row stayed
/// 'partial' while `paid_amount` was written as exactly `scheduled_amount`.
/// A self-contradicting row, and `list_reminders` filters on
/// `status NOT IN ('paid','skipped')`, so the installment reminded forever
/// and `services::notifications` kept minting rows for it.
#[tokio::test]
#[serial_test::serial]
async fn loan_exact_installment_payment_is_marked_paid() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    // 12,400 / 12 = 1033.333… → installments of 1033.33 with the tail row
    // absorbing the residual. The repeating cent is the whole point.
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 12400.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let rows = loan_payment_rows(&app, &token, loan_id).await;
    let first_due = rows[0]["scheduled_amount"].as_f64().unwrap();
    assert!((first_due - 1033.33).abs() < 0.001, "got {first_due}");

    // Pay it to the cent.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"amount": first_due, "paid_date": "2026-02-15"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let rows = loan_payment_rows(&app, &token, loan_id).await;
    assert_eq!(
        rows[0]["status"].as_str(),
        Some("paid"),
        "an exactly-paid installment must not read as partial"
    );
    assert_eq!(rows.len(), 12, "no phantom installment appended");
}

/// Topping a partial payment up to the exact scheduled amount must close the
/// installment and NOT append a residual row: `533.33 - 533.32999999999992724`
/// leaves 1.1e-13 of f64 dust, and `if remaining > 0.0` treated that as real
/// money, inserting a 0.00 installment that then showed up in the plan table
/// and both exports.
#[tokio::test]
#[serial_test::serial]
async fn loan_partial_then_exact_topup_leaves_no_phantom_installment() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 12400.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    app.clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();

    for amount in [500.0, 533.33] {
        let res = app
            .clone()
            .oneshot(req(
                Method::POST,
                &format!("/api/loans/{loan_id}/payments"),
                Some(&serde_json::json!({"amount": amount, "paid_date": "2026-02-15"})),
                Some(&token),
            ))
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::CREATED, "payment of {amount}");
    }

    let rows = loan_payment_rows(&app, &token, loan_id).await;
    assert_eq!(
        rows.len(),
        12,
        "phantom 0.00 installment appended: {rows:#?}"
    );
    assert_eq!(rows[0]["status"].as_str(), Some("paid"));
    let paid = rows[0]["paid_amount"].as_f64().unwrap();
    assert!((paid - 1033.33).abs() < 0.001, "got {paid}");
}

/// Newest-first is not the order these assertions want; fetch the schedule
/// as the API returns it and index by installment.
async fn loan_payment_rows(app: &Router, token: &str, loan_id: uuid::Uuid) -> Vec<Value> {
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}/payments"),
            None,
            Some(token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let mut rows: Vec<Value> = body_json(res.into_body())
        .await
        .as_array()
        .expect("payments array")
        .clone();
    rows.sort_by_key(|r| r["installment_number"].as_i64().unwrap_or(0));
    rows
}

#[tokio::test]
#[serial_test::serial]
async fn loan_schedule_generates_and_sums_to_principal() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "simple",
            "interest_rate": 0.06, "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;

    // Generate the schedule.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["installments"].as_i64().unwrap(), 12);

    // Payments list shows 12 rows; scheduled_principal sums to 1200.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}/payments"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let payments = body_json(res.into_body()).await;
    let rows = payments.as_array().unwrap();
    assert_eq!(rows.len(), 12);
    let sum_principal: f64 = rows
        .iter()
        .map(|r| r["scheduled_principal"].as_f64().unwrap())
        .sum();
    assert!(
        (sum_principal - 1200.0).abs() < 0.001,
        "scheduled principal must sum to 1200, got {sum_principal}"
    );
    // Simple 6% → total interest 72.
    let sum_interest: f64 = rows
        .iter()
        .map(|r| r["scheduled_interest"].as_f64().unwrap())
        .sum();
    assert!(
        (sum_interest - 72.0).abs() < 0.01,
        "interest should be 72, got {sum_interest}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn loan_schedule_regen_refused_when_payment_reconciled() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    // Generate, then reconcile a repayment.
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    let repay = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "100.00",
        "2026-02-15",
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Regen must now be refused with 409.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::CONFLICT,
        "regen with a reconciled payment must 409"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn loan_schedule_open_ended_rejected() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    // No term_months / payment_frequency → open-ended.
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 500.0, "currency": "USD",
            "origination_date": "2026-01-15"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
#[serial_test::serial]
async fn loan_write_off_zeroes_outstanding_default_keeps_it() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1000.0, "currency": "USD",
            "origination_date": "2026-01-15"
        }),
    )
    .await;

    // Default keeps outstanding.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/loans/{loan_id}"),
            Some(&serde_json::json!({"status": "defaulted"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(
        (l["outstanding"].as_f64().unwrap() - 1000.0).abs() < 0.01,
        "defaulted keeps outstanding, got {}",
        l["outstanding"]
    );

    // Write-off zeroes it.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/loans/{loan_id}"),
            Some(&serde_json::json!({"status": "written_off"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(
        l["outstanding"].as_f64().unwrap().abs() < 0.01,
        "written_off zeroes outstanding, got {}",
        l["outstanding"]
    );
}

#[tokio::test]
#[serial_test::serial]
async fn loan_reminders_upcoming_overdue_and_exclusions() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 300.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 3, "payment_frequency": "monthly"
        }),
    )
    .await;

    // Hand-place three installments with controlled due dates relative
    // to CURRENT_DATE: one in 3 days (upcoming), one in 40 days (outside
    // default lead 7 → excluded), one 2 days ago (overdue).
    sqlx::query("DELETE FROM loan_payments WHERE loan_id = $1")
        .bind(loan_id)
        .execute(&pool)
        .await
        .unwrap();
    for (n, offset) in [(1i32, 3i64), (2, 40), (3, -2)] {
        sqlx::query(
            "INSERT INTO loan_payments (user_id, loan_id, installment_number, due_date, \
             scheduled_amount, scheduled_principal, status) \
             VALUES ($1, $2, $3, CURRENT_DATE + ($4)::int, 100.00, 100.00, 'scheduled')",
        )
        .bind(user_id)
        .bind(loan_id)
        .bind(n)
        .bind(offset as i32)
        .execute(&pool)
        .await
        .unwrap();
    }

    // Default lead 7: expect installment 1 (upcoming) + installment 3
    // (overdue); installment 2 (40d out) excluded.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans/reminders", None, Some(&token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let reminders = body_json(res.into_body()).await;
    let arr = reminders.as_array().unwrap();
    assert_eq!(arr.len(), 2, "expected upcoming + overdue, got {arr:?}");
    let has_upcoming = arr.iter().any(|r| r["days_until"].as_i64().unwrap() > 0);
    let has_overdue = arr.iter().any(|r| r["days_overdue"].as_i64().unwrap() > 0);
    assert!(
        has_upcoming && has_overdue,
        "both an upcoming and an overdue reminder"
    );

    // Widen lead to 60 → installment 2 now appears too (3 total).
    set_setting(
        &pool,
        user_id,
        "lending_reminder_lead_days",
        serde_json::json!(60),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans/reminders", None, Some(&token)))
        .await
        .unwrap();
    let reminders = body_json(res.into_body()).await;
    assert_eq!(
        reminders.as_array().unwrap().len(),
        3,
        "lead 60 surfaces the 40-day-out installment"
    );

    // Write off the loan → no reminders (loan not active).
    let _ = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/loans/{loan_id}"),
            Some(&serde_json::json!({"status": "written_off"})),
            Some(&token),
        ))
        .await
        .unwrap();
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans/reminders", None, Some(&token)))
        .await
        .unwrap();
    let reminders = body_json(res.into_body()).await;
    assert_eq!(
        reminders.as_array().unwrap().len(),
        0,
        "written-off loan yields no reminders"
    );
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
    )
    .bind(alice_id)
    .bind(loan_id)
    .execute(&pool)
    .await
    .unwrap();

    // Alice sees 1 reminder; Bob sees none.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/loans/reminders",
            None,
            Some(&alice_token),
        ))
        .await
        .unwrap();
    assert_eq!(
        body_json(res.into_body()).await.as_array().unwrap().len(),
        1
    );
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/loans/reminders",
            None,
            Some(&bob_token),
        ))
        .await
        .unwrap();
    assert_eq!(
        body_json(res.into_body()).await.as_array().unwrap().len(),
        0,
        "Bob must not see Alice's reminders"
    );
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
    assert_eq!(
        res.status(),
        StatusCode::CREATED,
        "POST /api/loans must 201"
    );
    // Documented axum behavior: the trailing-slash form does NOT match.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans/", None, Some(&token)))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_FOUND,
        "trailing-slash /api/loans/ 404s under axum nest — clients use the no-slash form"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn loan_interest_only_and_monthly_rate_schedule() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    // 1% per MONTH, interest-only, 6 months on $10,000.
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 10000.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "interest_only",
            "interest_rate": 0.01, "rate_period": "monthly",
            "term_months": 6, "payment_frequency": "monthly"
        }),
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}/payments"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let rows = body_json(res.into_body()).await;
    let arr = rows.as_array().unwrap();
    assert_eq!(arr.len(), 6);
    // First five rows: interest only, $100 each (1% of 10k), no principal.
    for r in &arr[..5] {
        assert!((r["scheduled_interest"].as_f64().unwrap() - 100.0).abs() < 0.01);
        assert!(r["scheduled_principal"].as_f64().unwrap().abs() < 0.01);
    }
    // Final row: full principal balloon.
    assert!(
        (arr[5]["scheduled_principal"].as_f64().unwrap() - 10000.0).abs() < 0.01,
        "interest-only balloon should return full principal, got {}",
        arr[5]["scheduled_principal"]
    );

    // The loan echoes back rate_period for the UI.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert_eq!(l["rate_period"], "monthly");
    assert_eq!(l["interest_type"], "interest_only");
}

// =====================================================================
// B1 — partial payment top-up stays on the same installment
// =====================================================================

/// A PARTIAL payment to installment 1, then the remainder, must fully
/// pay installment 1 (status='paid', paid_amount == scheduled total)
/// WITHOUT spilling into installment 2. Regression for the bug where the
/// next-installment selector keyed off `actual_tx_id IS NULL`, so the
/// remainder skipped the partial row and filled installment 2 instead.
#[tokio::test]
#[serial_test::serial]
async fn loan_partial_payment_tops_up_same_installment() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, _acct) = seed_account(&pool, user_id).await;

    // Interest-free loan: $1,200 over 12 months → $100 principal/month,
    // each installment's scheduled_amount is exactly 100.
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Partial: $40 against installment 1 (cash, no tx).
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"amount": 40.0, "paid_date": "2026-02-15"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // After the partial: installment 1 is 'partial' with paid_amount 40;
    // installment 2 untouched.
    let rows = loan_payments(&app, &token, loan_id).await;
    let i1 = &rows[0];
    let i2 = &rows[1];
    assert_eq!(i1["installment_number"].as_i64().unwrap(), 1);
    assert_eq!(
        i1["status"], "partial",
        "installment 1 should be partial after $40"
    );
    assert!((i1["paid_amount"].as_f64().unwrap() - 40.0).abs() < 0.01);
    assert!(
        i2["paid_amount"].is_null(),
        "installment 2 must be untouched by the partial"
    );

    // Remainder: $60 → fully covers installment 1's $100 schedule.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"amount": 60.0, "paid_date": "2026-02-20"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let rows = loan_payments(&app, &token, loan_id).await;
    let i1 = &rows[0];
    let i2 = &rows[1];
    // Installment 1 is now fully paid: status='paid', paid_amount == 100.
    assert_eq!(
        i1["status"], "paid",
        "installment 1 must be paid after the remainder"
    );
    assert!(
        (i1["paid_amount"].as_f64().unwrap() - 100.0).abs() < 0.01,
        "installment 1 paid_amount should equal the $100 schedule, got {}",
        i1["paid_amount"]
    );
    // CRITICAL: the remainder did NOT spill into installment 2.
    assert_eq!(i2["installment_number"].as_i64().unwrap(), 2);
    assert!(
        i2["paid_amount"].is_null(),
        "remainder must NOT spill into installment 2 — got paid_amount {}",
        i2["paid_amount"]
    );
    assert_eq!(
        i2["status"], "scheduled",
        "installment 2 must still be scheduled"
    );

    // Outstanding dropped by exactly $100 (1200 - 100).
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(
        (l["outstanding"].as_f64().unwrap() - 1100.0).abs() < 0.01,
        "outstanding should be 1100 after one full installment, got {}",
        l["outstanding"]
    );
    assert!((l["total_repaid"].as_f64().unwrap() - 100.0).abs() < 0.01);
}

/// Helper: GET a loan's payments list, returning the JSON array.
async fn loan_payments(app: &Router, token: &str, loan_id: uuid::Uuid) -> Value {
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}/payments"),
            None,
            Some(token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    body_json(res.into_body()).await
}

// =====================================================================
// B2 — update_loan regenerates the schedule + validates principal
// =====================================================================

/// Changing the principal of a scheduled loan (no reconciled payments)
/// must regenerate the schedule rows to the new principal — Σ
/// scheduled_principal == new principal — instead of leaving a stale
/// schedule.
#[tokio::test]
#[serial_test::serial]
async fn loan_update_principal_regenerates_schedule() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();

    // Bump the principal to $2,400.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/loans/{loan_id}"),
            Some(&serde_json::json!({"principal": 2400.0})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::OK,
        "update with valid principal must 200"
    );

    // Schedule regenerated: still 12 rows, Σ scheduled_principal == 2400.
    let rows = loan_payments(&app, &token, loan_id).await;
    let arr = rows.as_array().unwrap();
    assert_eq!(arr.len(), 12, "schedule still has 12 installments");
    let sum_principal: f64 = arr
        .iter()
        .map(|r| r["scheduled_principal"].as_f64().unwrap())
        .sum();
    assert!(
        (sum_principal - 2400.0).abs() < 0.01,
        "scheduled principal must sum to the new 2400, got {sum_principal}"
    );

    // The loan view's total_scheduled tracks the new principal too.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(
        (l["total_scheduled"].as_f64().unwrap() - 2400.0).abs() < 0.01,
        "total_scheduled should follow the regenerated schedule, got {}",
        l["total_scheduled"]
    );
}

/// update_loan with principal <= 0 returns 400 (not a 500 surfacing the
/// DB CHECK).
#[tokio::test]
#[serial_test::serial]
async fn loan_update_nonpositive_principal_is_400() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1000.0, "currency": "USD",
            "origination_date": "2026-01-15"
        }),
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/loans/{loan_id}"),
            Some(&serde_json::json!({"principal": 0.0})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::BAD_REQUEST,
        "principal 0 must 400, not 500"
    );

    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/loans/{loan_id}"),
            Some(&serde_json::json!({"principal": -50.0})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::BAD_REQUEST,
        "negative principal must 400"
    );
}

/// A schedule-affecting edit (principal) on a loan WITH a reconciled
/// payment is rejected with 409 — terms can't change after money has
/// been reconciled (chosen policy; unreconcile first).
#[tokio::test]
#[serial_test::serial]
async fn loan_update_terms_rejected_after_reconcile() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    // Reconcile a real repayment.
    let repay = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "100.00",
        "2026-02-15",
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Changing principal now must 409.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/loans/{loan_id}"),
            Some(&serde_json::json!({"principal": 5000.0})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::CONFLICT,
        "schedule-affecting edit after reconcile must 409"
    );

    // A non-schedule field (notes) is still editable on the same loan.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/loans/{loan_id}"),
            Some(&serde_json::json!({"notes": "called borrower"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::OK,
        "non-schedule edit stays allowed after reconcile"
    );
}

/// Regression for the spurious-409 bug: the edit dialog re-sends
/// principal/interest_rate/interest_type on EVERY save (pre-filled,
/// unchanged). Editing only the borrower name on a reconciled loan —
/// while the payload still carries the unchanged principal — must NOT be
/// treated as a term change, so it must 200, not 409. (Presence-based
/// detection would wrongly reject this and drop the legitimate edit.)
#[tokio::test]
#[serial_test::serial]
async fn loan_update_unchanged_principal_after_reconcile_ok() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    let repay = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "100.00",
        "2026-02-15",
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Edit ONLY the borrower name, but resend the unchanged principal /
    // interest_type exactly as the dialog does. Must succeed.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/loans/{loan_id}"),
            Some(&serde_json::json!({
                "borrower_name": "Jose Ramirez",
                "principal": 1200.0,
                "interest_type": "none"
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::OK,
        "resending an UNCHANGED principal must not 409 a reconciled loan"
    );

    // The name change actually persisted.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert_eq!(
        l["borrower_name"], "Jose Ramirez",
        "borrower rename must persist"
    );
}

/// B1, the real (tx-linked) bug path: a PARTIAL payment that is
/// reconciled against a bank transaction sets actual_tx_id on the row.
/// The old `actual_tx_id IS NULL` selector skipped such a row, so the
/// next payment stranded the remainder on installment 2. The remainder
/// must top up the SAME installment instead.
#[tokio::test]
#[serial_test::serial]
async fn loan_tx_linked_partial_tops_up_same_installment() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();

    // Partial of $40 reconciled against a real $40 transaction → the row
    // now carries a non-NULL actual_tx_id (the case the old selector
    // skipped).
    let tx40 = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "40.00",
        "2026-02-15",
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": tx40.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let rows = loan_payments(&app, &token, loan_id).await;
    assert_eq!(
        rows[0]["status"], "partial",
        "installment 1 should be partial after the $40 tx"
    );

    // Remainder $60 (cash). Must top up installment 1, not spill to 2.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"amount": 60.0, "paid_date": "2026-02-20"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let rows = loan_payments(&app, &token, loan_id).await;
    assert_eq!(
        rows[0]["status"], "paid",
        "installment 1 must be paid after the remainder"
    );
    assert!(
        (rows[0]["paid_amount"].as_f64().unwrap() - 100.0).abs() < 0.01,
        "installment 1 should total $100, got {}",
        rows[0]["paid_amount"]
    );
    assert!(
        rows[1]["paid_amount"].is_null(),
        "remainder must NOT spill into installment 2 — got {}",
        rows[1]["paid_amount"]
    );
}

/// POST /schedule on a loan id that doesn't exist (or isn't ours) must
/// 404, not 500 (the shared regenerate_schedule helper must distinguish
/// not-found from a real DB error).
#[tokio::test]
#[serial_test::serial]
async fn loan_generate_schedule_unknown_id_is_404() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let bogus = uuid::Uuid::new_v4();
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{bogus}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_FOUND,
        "schedule on an unknown loan must 404, not 500"
    );
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
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 10000.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "interest_only",
            "interest_rate": 0.01, "rate_period": "monthly",
            "term_months": 6, "payment_frequency": "monthly"
        }),
    )
    .await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();

    // Reconcile a $100 inflow against the first installment → it's all
    // interest (interest-only), no principal.
    let repay = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "100.00",
        "2026-02-15",
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // The loan's interest_earned reflects the $100.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(
        (l["interest_earned"].as_f64().unwrap() - 100.0).abs() < 0.01,
        "interest-only first payment is all interest, got {}",
        l["interest_earned"]
    );

    // Interest-income report: $100 interest, $0 principal this year.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/loans/interest-income?year=2026",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
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
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1000.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "simple",
            "interest_rate": 0.12, "rate_period": "annual"
        }),
    )
    .await;

    // A $300 inflow ~365 days after origination.
    let repay = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "300.00",
        "2027-01-15",
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // ~$120 interest accrued (1000 * 0.12 * 1yr), allocated first; the
    // rest (~$180) is principal.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    let earned = l["interest_earned"].as_f64().unwrap();
    assert!(
        (earned - 120.0).abs() < 1.0,
        "US-rule interest-first ~120, got {earned}"
    );
    // Outstanding dropped by the principal portion (~180), not the full 300.
    let outstanding = l["outstanding"].as_f64().unwrap();
    assert!(
        (outstanding - 820.0).abs() < 1.5,
        "outstanding should drop by principal portion only (~820), got {outstanding}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn loan_zero_interest_repayment_is_all_principal() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 500.0, "currency": "USD",
            "origination_date": "2026-01-15"
        }),
    )
    .await; // interest_type defaults to none
    let repay = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "200.00",
        "2026-03-15",
    )
    .await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/loans/interest-income",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let report = body_json(res.into_body()).await;
    assert!(
        report["total_interest"].as_f64().unwrap().abs() < 0.01,
        "0% loan generates no interest income"
    );
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
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose Ramirez", "principal": 1000.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "simple",
            "interest_rate": 0.12, "rate_period": "annual"
        }),
    )
    .await;
    let repay = seed_tx_dated(&pool, user_id, acct, "Zelle", "300.00", "2026-07-15").await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/loans/interest-income/export?year=2026",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let ct = res
        .headers()
        .get("content-type")
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert!(
        ct.contains("text/csv"),
        "expected CSV content-type, got {ct}"
    );
    let bytes = axum::body::to_bytes(res.into_body(), 1024 * 64)
        .await
        .unwrap();
    let csv = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(
        csv.starts_with("borrower,currency,date,amount_paid,principal,interest,running_balance")
    );
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
    )
    .bind(alice_id)
    .bind(loan_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/loans/interest-income",
            None,
            Some(&alice_token),
        ))
        .await
        .unwrap();
    let r = body_json(res.into_body()).await;
    assert!((r["total_interest"].as_f64().unwrap() - 50.0).abs() < 0.01);
    // Bob sees nothing.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/loans/interest-income",
            None,
            Some(&bob_token),
        ))
        .await
        .unwrap();
    let r = body_json(res.into_body()).await;
    assert!(
        r["total_interest"].as_f64().unwrap().abs() < 0.01,
        "Bob must not see Alice's interest income"
    );
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
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1000.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "compound",
            "interest_rate": 0.10, "rate_period": "annual",
            "term_months": 24, "payment_frequency": "monthly"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}/payments"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
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
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1000.0, "currency": "USD",
            "origination_date": "2026-01-01", "interest_type": "simple",
            "interest_rate": 0.12, "rate_period": "annual"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    // interest_accrued is present and >= 0 (exact value depends on
    // today's date relative to origination).
    assert!(l["interest_accrued"].as_f64().unwrap() >= 0.0);
    // A 0% loan accrues nothing.
    let zero = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Ana", "principal": 500.0, "currency": "USD",
            "origination_date": "2026-01-01"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{zero}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
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
    let _big = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "BigFriend", "principal": 25000.0, "currency": "USD",
            "origination_date": "2026-01-01"
        }),
    )
    .await;
    // 0% loan under the threshold → not flagged.
    let _small = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "SmallFriend", "principal": 500.0, "currency": "USD",
            "origination_date": "2026-01-01"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/loans/interest-income",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
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
    )
    .bind(user_id)
    .bind(loan_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/loans/interest-income/summary",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let ct = res
        .headers()
        .get("content-type")
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert!(ct.contains("text/csv"));
    let bytes = axum::body::to_bytes(res.into_body(), 1024 * 64)
        .await
        .unwrap();
    let csv = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(csv.starts_with("borrower,currency,year,interest_received,principal_received"));
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
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose Ramirez", "principal": 5000.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "simple",
            "interest_rate": 0.06, "rate_period": "annual",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}/agreement"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let ct = res
        .headers()
        .get("content-type")
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert!(ct.contains("text/html"), "agreement is HTML, got {ct}");
    let bytes = axum::body::to_bytes(res.into_body(), 1024 * 64)
        .await
        .unwrap();
    let html = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(html.contains("Promissory Note"));
    assert!(html.contains("Jose Ramirez"));
    // Sectioned layout (the output redesign).
    assert!(html.contains("<h2>Parties</h2>"), "Parties section present");
    assert!(
        html.contains("<h2>Loan terms</h2>"),
        "Loan terms section present"
    );
    assert!(html.contains("Status as of"), "Status section present");

    // Cross-tenant: a different owner can't fetch it.
    let (_bob, bob_token) = seed_owner(&pool, "bob").await;
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}/agreement"),
            None,
            Some(&bob_token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_FOUND,
        "agreement must be owner-scoped"
    );
}

/// Regression: the agreement printable double-counted interest in its
/// PAID/REMAINING figures. total_repaid (Σ paid_amount) already includes
/// each payment's interest portion, but loan_agreement added
/// interest_earned on top — so one $70 repayment on a $120 + $20
/// flat-interest loan rendered "PAID $80.00 / REMAINING $60.00" while the
/// app correctly showed $70 / $70. The document must match the loan view.
#[tokio::test]
#[serial_test::serial]
async fn loan_agreement_paid_matches_loan_view_with_interest() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    // $120 principal + $20 agreed flat interest, modeled as a custom
    // schedule (one $140 row; interest inferred as rows − principal).
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose Ramirez", "principal": 120.0, "currency": "USD",
            "origination_date": "2026-01-15"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule/custom"),
            Some(&serde_json::json!({ "rows": [{ "due_date": "2026-12-15", "amount": 140.0 }] })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::CREATED,
        "custom schedule should 201"
    );
    // One $70 cash repayment — carries a non-zero interest portion, which
    // is exactly what the old code double-counted.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({ "amount": 70.0, "paid_date": "2026-06-01" })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED, "cash payment should 201");

    // The app's source of truth: Repaid $70, owed $70.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!((l["total_repaid"].as_f64().unwrap() - 70.0).abs() < 0.01);
    assert!((l["total_owed"].as_f64().unwrap() - 70.0).abs() < 0.01);
    assert!(
        l["interest_earned"].as_f64().unwrap() > 0.0,
        "payment must carry an interest portion or this test can't catch the double-count"
    );

    // The agreement must show the SAME figures: PAID $70.00 / REMAINING
    // $70.00, "$70.00 of $140.00 paid · 50%" — not $80 / $60 / 57%.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}/agreement"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(res.into_body(), 1024 * 64)
        .await
        .unwrap();
    let html = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(
        html.contains(r#"<div class="k">Paid</div><div class="val">$70.00</div>"#),
        "agreement PAID must equal the loan view's total_repaid ($70.00)"
    );
    assert!(
        html.contains(r#"<div class="k">Remaining</div><div class="val">$70.00</div>"#),
        "agreement REMAINING must equal the loan view's total_owed ($70.00)"
    );
    assert!(
        html.contains("$70.00 of $140.00 paid · 50%"),
        "progress bar label must read $70.00 of $140.00 paid · 50%"
    );
}

// =====================================================================
// Overpay-spill — a payment exceeding one installment spills onto later
// installments (in installment_number order), inside one write tx.
// =====================================================================

/// A single $250 cash payment on a $1,200/12mo interest-free schedule
/// ($100/installment) must FULLY pay installments 1 & 2 and leave
/// installment 3 partial ($50), with 4-12 untouched. Outstanding drops by
/// exactly the principal applied; total_repaid == 250.
#[tokio::test]
#[serial_test::serial]
async fn loan_overpay_spills_across_installments() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, _acct) = seed_account(&pool, user_id).await;

    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // One $250 cash payment → spills 100 + 100 + 50.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"amount": 250.0, "paid_date": "2026-02-15"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let rows = loan_payments(&app, &token, loan_id).await;
    assert_eq!(rows[0]["status"], "paid", "installment 1 fully paid");
    assert!((rows[0]["paid_amount"].as_f64().unwrap() - 100.0).abs() < 0.01);
    assert_eq!(rows[1]["status"], "paid", "installment 2 fully paid");
    assert!((rows[1]["paid_amount"].as_f64().unwrap() - 100.0).abs() < 0.01);
    assert_eq!(rows[2]["status"], "partial", "installment 3 partial");
    assert!(
        (rows[2]["paid_amount"].as_f64().unwrap() - 50.0).abs() < 0.01,
        "installment 3 should hold the $50 remainder, got {}",
        rows[2]["paid_amount"]
    );
    // 4-12 untouched.
    for r in rows.as_array().unwrap().iter().skip(3) {
        assert!(
            r["paid_amount"].is_null(),
            "installment {} must be untouched, got {}",
            r["installment_number"],
            r["paid_amount"]
        );
        assert_eq!(r["status"], "scheduled");
    }

    // No double-count on paid_amount: every touched row's paid_amount is
    // bounded by its scheduled_amount (the spill never overfills a row).
    for r in rows.as_array().unwrap().iter() {
        if let Some(p) = r["paid_amount"].as_f64() {
            assert!(
                p <= r["scheduled_amount"].as_f64().unwrap() + 0.01,
                "paid_amount must never exceed scheduled_amount, row {}",
                r["installment_number"]
            );
        }
    }

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(
        (l["outstanding"].as_f64().unwrap() - 950.0).abs() < 0.01,
        "outstanding should be 950 after $250 spill, got {}",
        l["outstanding"]
    );
    assert!(
        (l["total_repaid"].as_f64().unwrap() - 250.0).abs() < 0.01,
        "total_repaid should be 250, got {}",
        l["total_repaid"]
    );
}

/// A tx-linked overpay: the bank tx attaches to the FIRST touched
/// installment only; spilled installments carry NULL actual_tx_id.
/// DELETE-ing that first row then unreconciles cleanly — only the
/// tx-bearing row is removed, the spilled cash-style top-up stays.
#[tokio::test]
#[serial_test::serial]
async fn loan_overpay_tx_attaches_to_first_row_and_unreconciles() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();

    // $250 inflow reconciled → spills 100 + 100 + 50.
    let tx = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "250.00",
        "2026-02-15",
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": tx.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let rows = loan_payments(&app, &token, loan_id).await;
    // First touched row carries the tx; rows 2 & 3 do not.
    assert_eq!(
        rows[0]["actual_tx_id"].as_str(),
        Some(tx.to_string().as_str()),
        "first installment must carry the bank tx"
    );
    assert!(
        rows[1]["actual_tx_id"].is_null(),
        "spilled installment 2 must have NULL actual_tx_id"
    );
    assert!(
        rows[2]["actual_tx_id"].is_null(),
        "spilled installment 3 must have NULL actual_tx_id"
    );
    let first_row_id = rows[0]["id"].as_str().unwrap().to_string();

    // Unreconcile: DELETE the first (tx-bearing) row. It removes exactly
    // that row's $100 principal; the spilled $150 stays recorded.
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/loans/payments/{first_row_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NO_CONTENT,
        "unreconcile deletes the row"
    );

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    // 250 repaid − 100 removed = 150 still repaid → outstanding 1050.
    assert!(
        (l["total_repaid"].as_f64().unwrap() - 150.0).abs() < 0.01,
        "after unreconcile total_repaid should be 150, got {}",
        l["total_repaid"]
    );
    assert!(
        (l["outstanding"].as_f64().unwrap() - 1050.0).abs() < 0.01,
        "after unreconcile outstanding should be 1050, got {}",
        l["outstanding"]
    );
}

/// Regression: an EXACT-FIT single payment ($100) still fully pays just
/// installment 1, and an UNDER-FILL ($30) still leaves it partial — the
/// spill loop must not change single-installment behaviour.
#[tokio::test]
#[serial_test::serial]
async fn loan_exact_fit_and_underfill_single_installment() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, _acct) = seed_account(&pool, user_id).await;

    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();

    // Exact fit: $100 → installment 1 paid, installment 2 untouched.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"amount": 100.0, "paid_date": "2026-02-15"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let rows = loan_payments(&app, &token, loan_id).await;
    assert_eq!(rows[0]["status"], "paid");
    assert!((rows[0]["paid_amount"].as_f64().unwrap() - 100.0).abs() < 0.01);
    assert!(rows[1]["paid_amount"].is_null(), "exact fit must not spill");

    // Under-fill: $30 → installment 2 partial, installment 3 untouched.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"amount": 30.0, "paid_date": "2026-03-15"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let rows = loan_payments(&app, &token, loan_id).await;
    assert_eq!(rows[1]["status"], "partial");
    assert!((rows[1]["paid_amount"].as_f64().unwrap() - 30.0).abs() < 0.01);
    assert!(
        rows[2]["paid_amount"].is_null(),
        "under-fill must not spill"
    );
}

/// Overpay BEYOND the whole schedule: $1,300 on a $1,200 schedule pays
/// all 12 installments and appends a manual 'paid' row for the $100
/// surplus. Outstanding hits 0 (principal fully repaid; the surplus is
/// all principal on an interest-free loan).
#[tokio::test]
#[serial_test::serial]
async fn loan_overpay_beyond_schedule_appends_surplus_row() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, _acct) = seed_account(&pool, user_id).await;

    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();

    // $1,300 → 12 × $100 + a $100 surplus row.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"amount": 1300.0, "paid_date": "2026-02-15"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let rows = loan_payments(&app, &token, loan_id).await;
    // All 12 scheduled installments paid.
    for r in rows.as_array().unwrap().iter().take(12) {
        assert_eq!(
            r["status"], "paid",
            "installment {} must be paid",
            r["installment_number"]
        );
        assert!((r["paid_amount"].as_f64().unwrap() - 100.0).abs() < 0.01);
    }
    // A 13th appended manual row holds the $100 surplus.
    assert_eq!(
        rows.as_array().unwrap().len(),
        13,
        "a surplus row is appended"
    );
    assert_eq!(rows[12]["status"], "paid");
    assert!(
        (rows[12]["paid_amount"].as_f64().unwrap() - 100.0).abs() < 0.01,
        "surplus row should hold $100, got {}",
        rows[12]["paid_amount"]
    );

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(
        l["outstanding"].as_f64().unwrap().abs() < 0.01,
        "outstanding must be 0 after over-payoff, got {}",
        l["outstanding"]
    );
    assert!(
        (l["total_repaid"].as_f64().unwrap() - 1300.0).abs() < 0.01,
        "total_repaid should be 1300, got {}",
        l["total_repaid"]
    );
}

// =====================================================================
// /api/imports/continuity — statement-continuity report
// =====================================================================

/// Insert a statement-imported transaction: `balance_after` + `import_file`
/// set, so it qualifies for the continuity report's balance-chaining scan.
async fn seed_imported_tx(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    date: &str,
    amount: &str,
    balance_after: &str,
    import_file: &str,
) {
    sqlx::query(
        "INSERT INTO transactions \
         (account_id, date, description, amount, currency, source, user_id, balance_after, import_file) \
         VALUES ($1, $2::date, 'Imported tx', $3, 'USD', 'import', $4, $5, $6)",
    )
    .bind(account_id)
    .bind(date)
    .bind(Decimal::from_str(amount).unwrap())
    .bind(user_id)
    .bind(Decimal::from_str(balance_after).unwrap())
    .bind(import_file)
    .execute(pool)
    .await
    .expect("seed imported tx");
}

/// Regression guard for the FBAR-class bug in `continuity_handler`: it
/// selected a nonexistent `a.institution_name`, so the query errored and
/// `.unwrap_or_default()` silently returned an EMPTY report (200, no rows) —
/// statement-continuity warnings never surfaced. Asserts the report is
/// POPULATED with the JOINED institution name for imported data, which the
/// broken (institutions-less) query could never satisfy.
#[tokio::test]
#[serial_test::serial]
async fn continuity_report_lists_imported_accounts_with_institution() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    seed_imported_tx(
        &pool,
        user_id,
        account,
        "2026-01-31",
        "100.00",
        "1100.00",
        "2026-01.pdf",
    )
    .await;
    seed_imported_tx(
        &pool,
        user_id,
        account,
        "2026-02-28",
        "50.00",
        "1150.00",
        "2026-02.pdf",
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/imports/continuity",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let status = res.status();
    let body = body_json(res.into_body()).await;
    assert_eq!(status, StatusCode::OK, "continuity body: {body}");

    let accounts = body["accounts"].as_array().expect("accounts array");
    // Broken query -> errored -> unwrap_or_default -> []. A populated row whose
    // institution_name came from the JOIN is the regression signal.
    assert_eq!(
        accounts.len(),
        1,
        "expected the one imported account, got: {body}"
    );
    assert_eq!(
        accounts[0]["institution_name"],
        serde_json::json!("Test Bank"),
        "{body}"
    );
    assert_eq!(
        accounts[0]["statement_count"],
        serde_json::json!(2),
        "{body}"
    );
}

// =====================================================================
// Round 2 — WS1: day change (C-B), instrument detail (C-A), dividend
// payments (C-D), realized-gains account context (C-C), CSV exports
// (C-E), unclassified allocation band (C-G).
// =====================================================================

/// Read a (non-JSON) body as UTF-8 text — for the CSV exporters.
async fn body_text(body: Body) -> String {
    let bytes = to_bytes(body, 1024 * 1024).await.expect("read body");
    String::from_utf8(bytes.to_vec()).expect("utf-8 body")
}

/// Seed an investment-ish account under an existing institution.
async fn seed_typed_account(
    pool: &PgPool,
    user_id: uuid::Uuid,
    inst: uuid::Uuid,
    name: &str,
    account_type: &str,
    balance: &str,
) -> uuid::Uuid {
    sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, $2, $3, 'USD', $4::numeric, $5) RETURNING id",
    )
    .bind(inst)
    .bind(name)
    .bind(account_type)
    .bind(balance)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed typed account")
}

/// Seed one holding row; returns its id.
// test seed helper: each holding column is a distinct arg by design
#[allow(clippy::too_many_arguments)]
async fn seed_holding(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    symbol: &str,
    name: &str,
    holding_type: &str,
    qty: &str,
    price: Option<&str>,
    value: &str,
    cost_basis: Option<&str>,
) -> uuid::Uuid {
    sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, holding_type, currency, quantity, price, value, cost_basis, user_id) \
         VALUES ($1, $2, $3, $4, 'USD', $5::numeric, $6::numeric, $7::numeric, $8::numeric, $9) RETURNING id",
    )
    .bind(account_id)
    .bind(symbol)
    .bind(name)
    .bind(holding_type)
    .bind(qty)
    .bind(price)
    .bind(value)
    .bind(cost_basis)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed holding")
}

/// Seed a benchmark close `days_ago` days back.
async fn seed_close(pool: &PgPool, symbol: &str, days_ago: i32, close: &str) {
    sqlx::query(
        "INSERT INTO benchmark_prices (symbol, price_date, close) \
         VALUES ($1, (CURRENT_DATE - make_interval(days => $2))::date, $3::numeric) \
         ON CONFLICT (symbol, price_date) DO UPDATE SET close = EXCLUDED.close",
    )
    .bind(symbol)
    .bind(days_ago)
    .bind(close)
    .execute(pool)
    .await
    .expect("seed close");
}

/// C-B: per-row day change comes from the last two STORED closes; cash
/// sleeves, single-close and stale-close symbols stay null and are excluded
/// from the totals + coverage numerator.
#[tokio::test]
#[serial_test::serial]
async fn holdings_day_change_from_stored_closes_and_coverage() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;
    let brok = seed_typed_account(&pool, user_id, inst, "Brokerage", "brokerage", "2090.00").await;

    // Covered: GOOG, two fresh closes 100 -> 102 (+2%).
    seed_holding(
        &pool,
        user_id,
        brok,
        "GOOG",
        "Alphabet",
        "equity",
        "10",
        Some("102"),
        "1020",
        Some("900"),
    )
    .await;
    seed_close(&pool, "GOOG", 1, "100").await;
    seed_close(&pool, "GOOG", 0, "102").await;
    // Null paths: 401k-trust style row (no closes at all)…
    seed_holding(
        &pool,
        user_id,
        brok,
        "VANG TARGET RET 2045",
        "Vanguard Target 2045 Trust",
        "",
        "47",
        None,
        "470",
        None,
    )
    .await;
    // …cash sleeve (fresh closes exist but the row is cash)…
    seed_holding(
        &pool,
        user_id,
        brok,
        "CUR:USD",
        "US Dollar",
        "cash",
        "200",
        Some("1"),
        "200",
        None,
    )
    .await;
    // …stale series (latest close 8 days old)…
    seed_holding(
        &pool,
        user_id,
        brok,
        "MSFT",
        "Microsoft",
        "equity",
        "1",
        Some("300"),
        "300",
        None,
    )
    .await;
    seed_close(&pool, "MSFT", 9, "290").await;
    seed_close(&pool, "MSFT", 8, "300").await;
    // …and a single-close symbol.
    seed_holding(
        &pool,
        user_id,
        brok,
        "NVDA",
        "NVIDIA",
        "equity",
        "1",
        Some("100"),
        "100",
        None,
    )
    .await;
    seed_close(&pool, "NVDA", 0, "100").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/holdings",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    let holdings = body["holdings"].as_array().unwrap();
    let by_symbol = |s: &str| holdings.iter().find(|h| h["symbol"] == s).unwrap();

    let goog = by_symbol("GOOG");
    assert!(
        (goog["day_change_pct"].as_f64().unwrap() - 2.0).abs() < 1e-6,
        "{goog}"
    );
    assert!(
        (goog["day_change_usd"].as_f64().unwrap() - 20.4).abs() < 1e-6,
        "{goog}"
    );
    let today = chrono::Utc::now().date_naive().to_string();
    assert_eq!(goog["price_as_of"].as_str().unwrap(), today);
    // Round-1 regression guard: asset_class untouched.
    assert_eq!(goog["asset_class"], "equity");

    for sym in ["VANG TARGET RET 2045", "CUR:USD", "MSFT", "NVDA"] {
        let h = by_symbol(sym);
        assert!(h["day_change_usd"].is_null(), "{sym} should be null: {h}");
        assert!(h["day_change_pct"].is_null(), "{sym} should be null: {h}");
        assert!(h["price_as_of"].is_null(), "{sym} should be null: {h}");
    }

    // Totals cover GOOG only: +20.4 on a prior value of 999.6.
    assert!((body["day_change_usd"].as_f64().unwrap() - 20.4).abs() < 1e-6);
    assert!((body["day_change_pct"].as_f64().unwrap() - (20.4 / 999.6 * 100.0)).abs() < 1e-6);
    // Coverage: 1020 covered of 2090 total.
    assert!(
        (body["day_change_coverage_pct"].as_f64().unwrap() - (1020.0 / 2090.0 * 100.0)).abs()
            < 1e-6,
        "coverage: {}",
        body["day_change_coverage_pct"]
    );
    assert_eq!(body["day_change_as_of"].as_str().unwrap(), today);
}

/// C-A: full contract for a held ticker (chart ranges honored), graceful
/// degradation for an opaque symbol, 404 for an unheld one.
#[tokio::test]
#[serial_test::serial]
async fn instrument_detail_contract_ranges_opaque_and_404() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;
    let brok = seed_typed_account(&pool, user_id, inst, "Robinhood", "brokerage", "5085.80").await;
    let k401 = seed_typed_account(&pool, user_id, inst, "Employer 401k", "401k", "12000.00").await;

    let nvda = seed_holding(
        &pool,
        user_id,
        brok,
        "NVDA",
        "NVIDIA Corp",
        "equity",
        "29.5",
        Some("172.40"),
        "5085.80",
        Some("3100"),
    )
    .await;
    seed_holding(
        &pool,
        user_id,
        k401,
        "VANG TARGET RET 2045",
        "Vanguard Target Retirement 2045 Trust",
        "",
        "100",
        None,
        "12000",
        None,
    )
    .await;
    sqlx::query(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1, $2, $3, '2024-03-01', 10, 88.10, 'USD', 1.0, 'lot-nvda')",
    )
    .bind(nvda)
    .bind(brok)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    // Four stored closes; latest is CURRENT_DATE so the freshness gate never
    // reaches for Yahoo during the test.
    seed_close(&pool, "NVDA", 100, "150").await;
    seed_close(&pool, "NVDA", 50, "160").await;
    seed_close(&pool, "NVDA", 10, "170").await;
    seed_close(&pool, "NVDA", 0, "171.7").await;

    // Case-insensitive match + default 1y range.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/instruments/nvda",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    assert_eq!(body["symbol"], "NVDA");
    assert_eq!(body["name"], "NVIDIA Corp");
    assert_eq!(body["currency"], "USD");
    assert_eq!(body["asset_class"], "equity");
    assert!((body["quantity"].as_f64().unwrap() - 29.5).abs() < 1e-9);
    assert!((body["price"].as_f64().unwrap() - 172.40).abs() < 1e-9);
    assert!((body["value_usd"].as_f64().unwrap() - 5085.80).abs() < 1e-9);
    // Lots-preferred basis: the single lot (881) outranks the flat 3100.
    assert!((body["cost_basis_usd"].as_f64().unwrap() - 881.0).abs() < 1e-9);
    assert!((body["gain_loss_usd"].as_f64().unwrap() - 4204.8).abs() < 1e-9);
    // Weight over the whole holdings portfolio (5085.80 + 12000).
    let want_weight = (5085.80f64 / 17085.80 * 100.0 * 100.0).round() / 100.0;
    assert!((body["portfolio_weight_pct"].as_f64().unwrap() - want_weight).abs() < 1e-9);
    // Day change from the last two closes: 170 -> 171.7 = +1%.
    assert!((body["day_change_pct"].as_f64().unwrap() - 1.0).abs() < 1e-9);
    assert!((body["day_change_usd"].as_f64().unwrap() - 50.86).abs() < 1e-9);
    let today = chrono::Utc::now().date_naive().to_string();
    assert_eq!(body["price_as_of"].as_str().unwrap(), today);
    let accounts = body["accounts"].as_array().unwrap();
    assert_eq!(accounts.len(), 1);
    assert_eq!(accounts[0]["account_name"], "Robinhood");
    assert_eq!(accounts[0]["account_type"], "brokerage");
    assert_eq!(accounts[0]["tax_advantaged"], false);
    let lots = body["lots"].as_array().unwrap();
    assert_eq!(lots.len(), 1);
    assert_eq!(lots[0]["acquired_at"], "2024-03-01");
    assert!((lots[0]["usd_cost"].as_f64().unwrap() - 881.0).abs() < 1e-9);
    assert_eq!(
        body["prices"].as_array().unwrap().len(),
        4,
        "1y default: all four closes"
    );

    // Ranges narrow the series.
    for (range, want_points) in [("1m", 2), ("3m", 3), ("max", 4)] {
        let res = app
            .clone()
            .oneshot(req(
                Method::GET,
                &format!("/api/dashboard/instruments/NVDA?range={range}"),
                None,
                Some(&token),
            ))
            .await
            .unwrap();
        let body = body_json(res.into_body()).await;
        assert_eq!(
            body["prices"].as_array().unwrap().len(),
            want_points,
            "range={range}"
        );
    }

    // Opaque symbol: 200 with empty prices + null day stats, accounts intact.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/instruments/VANG%20TARGET%20RET%202045",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["prices"], serde_json::json!([]));
    assert!(body["day_change_usd"].is_null());
    assert!(body["day_change_pct"].is_null());
    assert!(body["price_as_of"].is_null());
    assert!(body["price"].is_null());
    assert!(body["cost_basis_usd"].is_null());
    assert_eq!(body["accounts"][0]["account_type"], "401k");
    assert_eq!(body["accounts"][0]["tax_advantaged"], true);

    // Unheld symbol: 404 with the C-A error shape.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/instruments/TSLA",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["error"], "unknown symbol");
}

/// Seed one dated, categorized transaction (for the C-D payment matcher).
async fn seed_dividend_tx(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    description: &str,
    amount: &str,
    category_detailed: Option<&str>,
    days_ago: i32,
) {
    sqlx::query(
        "INSERT INTO transactions (account_id, date, description, amount, currency, category_detailed, source, user_id) \
         VALUES ($1, (CURRENT_DATE - make_interval(days => $2))::date, $3, $4::numeric, 'USD', $5, 'manual', $6)",
    )
    .bind(account_id)
    .bind(days_ago)
    .bind(description)
    .bind(amount)
    .bind(category_detailed)
    .bind(user_id)
    .execute(pool)
    .await
    .expect("seed dividend tx");
}

/// C-D: payments match conservatively — positive INCOME_DIVIDENDS (or
/// dividend-worded) rows naming the ticker as a whole word, in accounts
/// that hold the symbol; everything else stays out; regex-unsafe symbols
/// skip matching entirely.
#[tokio::test]
#[serial_test::serial]
async fn dividend_detail_payments_matched_conservatively() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;
    let holder = seed_typed_account(&pool, user_id, inst, "Fidelity HSA", "hsa", "1000.00").await;
    let other = seed_typed_account(
        &pool,
        user_id,
        inst,
        "Other Brokerage",
        "brokerage",
        "1000.00",
    )
    .await;

    // ZZTQ deliberately unresolvable on Yahoo — the live dividend fetch
    // degrades to none and the payments section still populates.
    seed_holding(
        &pool,
        user_id,
        holder,
        "ZZTQ",
        "ZZ Test Corp",
        "equity",
        "10",
        Some("100"),
        "1000",
        None,
    )
    .await;

    // Matches: positive + INCOME_DIVIDENDS + ticker as a whole word, in the
    // holding account.
    seed_dividend_tx(
        &pool,
        user_id,
        holder,
        "Dividend received: ZZTQ",
        "105.60",
        Some("INCOME_DIVIDENDS"),
        0,
    )
    .await;
    // Matches: no category, but the Spanish "dividendo" wording + ticker.
    seed_dividend_tx(
        &pool,
        user_id,
        holder,
        "Dividendo ZZTQ pagado",
        "33.00",
        None,
        30,
    )
    .await;
    // No match: ticker only as a substring (ZZTQX).
    seed_dividend_tx(
        &pool,
        user_id,
        holder,
        "ZZTQX distribution",
        "50.00",
        Some("INCOME_DIVIDENDS"),
        1,
    )
    .await;
    // No match: negative amount (a reversal).
    seed_dividend_tx(
        &pool,
        user_id,
        holder,
        "ZZTQ dividend reversal",
        "-105.60",
        Some("INCOME_DIVIDENDS"),
        2,
    )
    .await;
    // No match: right wording, WRONG account (doesn't hold ZZTQ).
    seed_dividend_tx(
        &pool,
        user_id,
        other,
        "ZZTQ dividend",
        "75.00",
        Some("INCOME_DIVIDENDS"),
        3,
    )
    .await;
    // No match: dividend wording without the ticker.
    seed_dividend_tx(
        &pool,
        user_id,
        holder,
        "Quarterly dividend payment",
        "12.00",
        None,
        4,
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/dividends/ZZTQ",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    let payments = body["payments"].as_array().expect("payments array");
    assert_eq!(
        payments.len(),
        2,
        "exactly the two conservative matches: {payments:#?}"
    );
    // Newest first.
    assert!((payments[0]["amount_usd"].as_f64().unwrap() - 105.60).abs() < 0.001);
    assert_eq!(payments[0]["account_name"], "Fidelity HSA");
    assert!((payments[1]["amount_usd"].as_f64().unwrap() - 33.0).abs() < 0.001);

    // Regex-unsafe symbol (':' outside [A-Za-z0-9.-]): matching is skipped
    // entirely — empty payments even with a would-be-matching row present.
    seed_holding(
        &pool,
        user_id,
        holder,
        "ZZ:WEIRD",
        "Weird Pseudo",
        "equity",
        "1",
        Some("1"),
        "1",
        None,
    )
    .await;
    seed_dividend_tx(
        &pool,
        user_id,
        holder,
        "ZZ:WEIRD dividend",
        "9.00",
        Some("INCOME_DIVIDENDS"),
        5,
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/dividends/ZZ%3AWEIRD",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["payments"], serde_json::json!([]));
}

/// Seed a (holding, disposal) pair in an account; returns nothing. P&L and
/// dates are caller-chosen so tests can pin taxable vs advantaged sums.
async fn seed_disposal(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    symbol: &str,
    pnl: &str,
    years_ago: i32,
    source_id: &str,
) {
    let holding_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, user_id) \
         VALUES ($1, $2, $2, 'USD', $3) RETURNING id",
    )
    .bind(account_id)
    .bind(symbol)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed disposal holding");
    sqlx::query(
        "INSERT INTO lot_disposals \
         (user_id, holding_id, account_id, lot_id, sell_source_id, qty_sold, sell_price_per_unit, \
          sell_currency, sell_fx_rate, sell_date, cost_per_unit, cost_fx_rate, realized_pnl_usd) \
         VALUES ($1, $2, $3, NULL, $4, 10, 100, 'USD', 1.0, \
                 (CURRENT_DATE - make_interval(years => $5))::date, 60, 1.0, $6::numeric)",
    )
    .bind(user_id)
    .bind(holding_id)
    .bind(account_id)
    .bind(source_id)
    .bind(years_ago)
    .bind(pnl)
    .execute(pool)
    .await
    .expect("seed disposal");
}

/// C-C: every disposal row carries its account context + advantaged flag,
/// and the summary's taxable subtotal covers the returned (year-filtered)
/// list's non-advantaged rows only.
#[tokio::test]
#[serial_test::serial]
async fn realized_gains_account_context_and_taxable_subtotal() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;
    let brok = seed_typed_account(&pool, user_id, inst, "Robinhood", "brokerage", "0").await;
    let roth = seed_typed_account(&pool, user_id, inst, "Roth IRA", "roth", "0").await;
    // Nickname outranks the bank name in the row context.
    sqlx::query("UPDATE accounts SET nickname = 'My Roth' WHERE id = $1")
        .bind(roth)
        .execute(&pool)
        .await
        .unwrap();

    seed_disposal(&pool, user_id, brok, "VTI", "1774.50", 0, "s1").await;
    seed_disposal(&pool, user_id, roth, "SCHD", "1195.00", 0, "s2").await;
    seed_disposal(&pool, user_id, brok, "VXUS", "4053.50", 1, "s3").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/realized-gains",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    let disposals = body["disposals"].as_array().unwrap();
    assert_eq!(disposals.len(), 3);
    let schd = disposals.iter().find(|d| d["symbol"] == "SCHD").unwrap();
    assert_eq!(schd["account_name"], "My Roth");
    assert_eq!(schd["account_type"], "roth");
    assert_eq!(schd["tax_advantaged"], true);
    let vti = disposals.iter().find(|d| d["symbol"] == "VTI").unwrap();
    assert_eq!(vti["account_name"], "Robinhood");
    assert_eq!(vti["tax_advantaged"], false);
    // All-history list: both brokerage disposals are taxable.
    assert!(
        (body["summary"]["taxable_realized_usd"].as_f64().unwrap() - 5828.0).abs() < 0.001,
        "taxable: {}",
        body["summary"]["taxable_realized_usd"]
    );

    // Year filter recomputes the taxable subtotal over that year's list.
    let this_year = chrono::Utc::now().format("%Y").to_string();
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/dashboard/realized-gains?year={this_year}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert_eq!(body["summary"]["count"].as_i64().unwrap(), 2);
    assert!(
        (body["summary"]["taxable_realized_usd"].as_f64().unwrap() - 1774.50).abs() < 0.001,
        "year-filtered taxable: {}",
        body["summary"]["taxable_realized_usd"]
    );
}

/// C-E: holdings + lots CSV exports — headers, filename, RFC-4180 quoting
/// of a name containing a comma AND quotes, and row counts matching the
/// JSON endpoint's data.
#[tokio::test]
#[serial_test::serial]
async fn holdings_and_lots_csv_exports() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;
    let brok =
        seed_typed_account(&pool, user_id, inst, "Main Brokerage", "brokerage", "1000").await;
    let acme = seed_holding(
        &pool,
        user_id,
        brok,
        "ACME",
        "Acme \"Widgets\", Inc",
        "equity",
        "10",
        Some("100"),
        "1000",
        Some("800"),
    )
    .await;
    sqlx::query(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1, $2, $3, '2024-01-15', 10, 80, 'USD', 1.0, 'lot-acme'), \
                ($1, $2, $3, '2024-02-15', 0, 90, 'USD', 1.0, 'depletion-marker')",
    )
    .bind(acme)
    .bind(brok)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/holdings/export",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert!(res
        .headers()
        .get(header::CONTENT_TYPE)
        .unwrap()
        .to_str()
        .unwrap()
        .starts_with("text/csv"));
    let dispo = res
        .headers()
        .get(header::CONTENT_DISPOSITION)
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert!(dispo.contains("attachment"), "{dispo}");
    assert!(dispo.contains("patrimonio_holdings_"), "{dispo}");
    let body = body_text(res.into_body()).await;
    let lines: Vec<&str> = body.trim_end().split('\n').collect();
    assert_eq!(lines[0], "symbol,name,account,institution,account_type,asset_class,quantity,price,currency,value,value_usd,cost_basis_usd,gain_loss_usd,gain_loss_pct");
    assert_eq!(lines.len(), 2, "header + one holding: {body}");
    // RFC-4180: embedded quotes doubled, whole field quoted, comma preserved.
    assert!(
        lines[1].contains("\"Acme \"\"Widgets\"\", Inc\""),
        "quoting: {}",
        lines[1]
    );
    // Lots-preferred basis (800) surfaces in the row — money fields are
    // serialized at 2dp so spreadsheets never see float noise like
    // `3679.9999999999995`.
    assert!(lines[1].contains(",800.00,"), "basis: {}", lines[1]);

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/holdings/lots/export",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let dispo = res
        .headers()
        .get(header::CONTENT_DISPOSITION)
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert!(dispo.contains("patrimonio_lots_"), "{dispo}");
    let body = body_text(res.into_body()).await;
    let lines: Vec<&str> = body.trim_end().split('\n').collect();
    assert_eq!(
        lines[0],
        "symbol,account,acquired_at,qty,cost_per_unit,currency,usd_cost"
    );
    // The qty-0 depletion marker is filtered — one active lot only.
    assert_eq!(lines.len(), 2, "header + one active lot: {body}");
    assert!(lines[1].contains("2024-01-15"), "{}", lines[1]);
    assert!(
        lines[1].ends_with(",800.00"),
        "usd_cost (2dp money): {}",
        lines[1]
    );
}

/// C-E: realized-gains CSV honors the year filter, carries the C-C account
/// context, and rejects unauthenticated callers like its siblings.
#[tokio::test]
#[serial_test::serial]
async fn realized_gains_csv_export_year_filter_and_auth() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;
    let brok = seed_typed_account(&pool, user_id, inst, "Robinhood", "brokerage", "0").await;
    let roth = seed_typed_account(&pool, user_id, inst, "Roth IRA", "roth", "0").await;

    seed_disposal(&pool, user_id, brok, "VTI", "1774.50", 0, "s1").await;
    seed_disposal(&pool, user_id, roth, "SCHD", "1195.00", 0, "s2").await;
    seed_disposal(&pool, user_id, brok, "VXUS", "4053.50", 1, "s3").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/realized-gains/export",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let dispo = res
        .headers()
        .get(header::CONTENT_DISPOSITION)
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert!(dispo.contains("patrimonio_realized_gains_"), "{dispo}");
    let body = body_text(res.into_body()).await;
    let lines: Vec<&str> = body.trim_end().split('\n').collect();
    assert_eq!(lines[0], "sell_date,symbol,name,account,account_type,tax_advantaged,qty_sold,proceeds_usd,cost_usd,realized_pnl_usd,holding_days,long_term");
    assert_eq!(lines.len(), 4, "header + all three disposals: {body}");
    let schd_line = lines.iter().find(|l| l.contains("SCHD")).unwrap();
    assert!(
        schd_line.contains("\"roth\",true"),
        "C-C context in CSV: {schd_line}"
    );

    // Year filter: only the prior-year row, and the year lands in the filename.
    let prior_year = chrono::Utc::now()
        .format("%Y")
        .to_string()
        .parse::<i32>()
        .unwrap()
        - 1;
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/dashboard/realized-gains/export?year={prior_year}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let dispo = res
        .headers()
        .get(header::CONTENT_DISPOSITION)
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert!(
        dispo.contains(&format!("patrimonio_realized_gains_{prior_year}_")),
        "{dispo}"
    );
    let body = body_text(res.into_body()).await;
    let lines: Vec<&str> = body.trim_end().split('\n').collect();
    assert_eq!(lines.len(), 2, "header + the one {prior_year} row: {body}");
    assert!(lines[1].contains("VXUS"), "{}", lines[1]);

    // Unauthenticated: same rejection as the transactions export.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/realized-gains/export",
            None,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

/// C-G: an active investment-category account with a balance but NO
/// holdings rows surfaces as an 'unclassified' allocation band; the same
/// category of account WITH holdings never double-counts.
#[tokio::test]
#[serial_test::serial]
async fn allocation_unclassified_band_for_holdingsless_investment_account() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;

    // Balance-only investment account (the CETES case).
    seed_typed_account(&pool, user_id, inst, "CETES", "investment", "12000.00").await;
    // Investment account WITH holdings — must NOT produce a band.
    let brok = seed_typed_account(&pool, user_id, inst, "Brokerage", "brokerage", "6000.00").await;
    seed_holding(
        &pool,
        user_id,
        brok,
        "VTI",
        "Vanguard Total Market",
        "equity",
        "10",
        Some("600"),
        "6000",
        None,
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/allocation",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().unwrap();

    let unclassified: Vec<_> = rows
        .iter()
        .filter(|r| r["asset_class"] == "unclassified")
        .collect();
    assert_eq!(unclassified.len(), 1, "exactly the CETES band: {rows:#?}");
    assert_eq!(unclassified[0]["category"], "Unclassified");
    assert_eq!(unclassified[0]["sub_category"], "CETES");
    assert!((unclassified[0]["value"].as_f64().unwrap() - 12000.0).abs() < 0.01);
    // The holdings-backed account still classifies through its holdings.
    assert!(rows
        .iter()
        .any(|r| r["asset_class"] == "equity" && r["sub_category"] == "VTI"));
}

/// fix-5: a balance-only account whose account_type IS an asset class
/// ('bonds' — the CETES Directo case: literally Mexican treasury bills)
/// lands in the Bonds band, not "Unclassified (account balance)"; ambiguous
/// types ('brokerage') still surface as unclassified. The MXN balance also
/// pins the FX swap: the allocation endpoint now goes through the shared
/// `latest_usd_mxn_rate` (manual-override precedence), not its old inline
/// newest-row query with a silent `.unwrap_or(20.0)` fallback.
#[tokio::test]
#[serial_test::serial]
async fn allocation_bonds_account_type_classifies_as_bonds() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;

    // Balance-only bonds account in MXN (CETES Directo).
    sqlx::query(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'CETES Directo', 'bonds', 'MXN', 180000.00, $2)",
    )
    .bind(inst)
    .bind(user_id)
    .execute(&pool)
    .await
    .expect("seed CETES account");
    // Balance-only AMBIGUOUS type — must stay unclassified.
    seed_typed_account(
        &pool,
        user_id,
        inst,
        "Mystery Brokerage",
        "brokerage",
        "5000.00",
    )
    .await;

    // A newer 'api' rate AND an older 'manual' override: the shared
    // latest_usd_mxn_rate picks the manual row (18.0); the old inline query
    // ordered by recorded_at alone and would have used 17.0.
    sqlx::query(
        "INSERT INTO exchange_rates (base_currency, target_currency, rate, recorded_at, source) \
         VALUES ('USD', 'MXN', 17.00, NOW(), 'api'), \
                ('USD', 'MXN', 18.00, NOW() - INTERVAL '1 hour', 'manual')",
    )
    .execute(&pool)
    .await
    .expect("seed fx rates");

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/allocation",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().unwrap();

    // CETES → Bonds, converted at the manual 18.0 rate: 180000 / 18 = 10000.
    let bonds: Vec<_> = rows
        .iter()
        .filter(|r| r["asset_class"] == "bonds")
        .collect();
    assert_eq!(bonds.len(), 1, "exactly the CETES band: {rows:#?}");
    assert_eq!(bonds[0]["category"], "Bonds");
    assert_eq!(bonds[0]["sub_category"], "CETES Directo");
    assert!(
        (bonds[0]["value"].as_f64().unwrap() - 10000.0).abs() < 0.01,
        "expected 180000 MXN / 18.0 manual rate = 10000 USD, got {}",
        bonds[0]["value"]
    );

    // The ambiguous brokerage balance is the ONLY unclassified band.
    let unclassified: Vec<_> = rows
        .iter()
        .filter(|r| r["asset_class"] == "unclassified")
        .collect();
    assert_eq!(unclassified.len(), 1, "only the brokerage band: {rows:#?}");
    assert_eq!(unclassified[0]["sub_category"], "Mystery Brokerage");
}

// =====================================================================
// Round 3 — C3-A asset-class overrides + C3-B soft delete / restore
// =====================================================================

/// C3-A: the PUT matrix (200 set / 200 clear / 422 bad class / 404 unheld)
/// and the read-side precedence — one override flips the holdings rows in
/// EVERY account, the allocation band, the CSV export, and the instrument
/// detail (with its `asset_class_source` flag); clearing reverts them all.
#[tokio::test]
#[serial_test::serial]
async fn asset_class_override_matrix_and_precedence_everywhere() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;
    let brok = seed_typed_account(&pool, user_id, inst, "Brokerage", "brokerage", "6000.00").await;
    let ira = seed_typed_account(&pool, user_id, inst, "IRA", "ira", "3000.00").await;

    // Same instrument in TWO accounts — one edit must cover both.
    seed_holding(
        &pool,
        user_id,
        brok,
        "VTI",
        "Vanguard Total Market",
        "etf",
        "10",
        Some("600"),
        "6000",
        None,
    )
    .await;
    seed_holding(
        &pool,
        user_id,
        ira,
        "VTI",
        "Vanguard Total Market",
        "etf",
        "5",
        Some("600"),
        "3000",
        None,
    )
    .await;
    // Fresh close so /instruments/VTI never reaches for Yahoo in the test.
    seed_close(&pool, "VTI", 0, "600").await;

    let alloc_total = |rows: &Value| -> f64 {
        rows.as_array()
            .unwrap()
            .iter()
            .map(|r| r["value"].as_f64().unwrap())
            .sum()
    };
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/allocation",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let total_before = alloc_total(&body_json(res.into_body()).await);

    // ---- SET: case-insensitive path, normalized symbol echoed back. ----
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/dashboard/instruments/vti/asset-class",
            Some(&serde_json::json!({"asset_class": "bonds"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(
        body,
        serde_json::json!({
            "symbol": "VTI",
            "asset_class": "bonds",
            "asset_class_source": "override"
        })
    );

    // Holdings: BOTH rows (brokerage + IRA) carry the override.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/holdings",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let vti_rows: Vec<_> = body["holdings"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|h| h["symbol"] == "VTI")
        .collect();
    assert_eq!(vti_rows.len(), 2);
    assert!(
        vti_rows.iter().all(|h| h["asset_class"] == "bonds"),
        "{vti_rows:?}"
    );

    // Allocation: the VTI band moved to bonds wholesale; total unchanged.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/allocation",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().unwrap();
    let vti_band = rows
        .iter()
        .find(|r| r["sub_category"] == "VTI")
        .expect("VTI band");
    assert_eq!(vti_band["asset_class"], "bonds");
    assert!((vti_band["value"].as_f64().unwrap() - 9000.0).abs() < 0.01);
    assert!(!rows
        .iter()
        .any(|r| r["asset_class"] == "equity" && r["sub_category"] == "VTI"));
    assert!(
        (alloc_total(&body) - total_before).abs() < 0.01,
        "dimension total unchanged"
    );

    // CSV export classifies with the same precedence.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/holdings/export",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let csv = body_text(res.into_body()).await;
    let vti_line = csv.lines().find(|l| l.contains("\"VTI\"")).unwrap();
    assert!(vti_line.contains("\"bonds\""), "csv: {vti_line}");

    // Instrument detail: override + source flag.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/instruments/VTI",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert_eq!(body["asset_class"], "bonds");
    assert_eq!(body["asset_class_source"], "override");
    // C3-A extension: the heuristic rides along so the sheet can label its
    // "Automatic — Equity" revert row while the override is active.
    assert_eq!(body["asset_class_heuristic"], "equity");

    // ---- CLEAR: null body reverts everything to the heuristic. ----
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/dashboard/instruments/VTI/asset-class",
            Some(&serde_json::json!({"asset_class": null})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(
        body,
        serde_json::json!({
            "symbol": "VTI",
            "asset_class": "equity",
            "asset_class_source": "heuristic"
        })
    );
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/holdings",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert!(body["holdings"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|h| h["symbol"] == "VTI")
        .all(|h| h["asset_class"] == "equity"));
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/instruments/VTI",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert_eq!(body["asset_class"], "equity");
    assert_eq!(body["asset_class_source"], "heuristic");
    assert_eq!(body["asset_class_heuristic"], "equity");

    // ---- 422: unknown class key. ----
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/dashboard/instruments/VTI/asset-class",
            Some(&serde_json::json!({"asset_class": "stonks"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNPROCESSABLE_ENTITY);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["error"], "invalid asset class");

    // ---- 404: symbol the caller doesn't hold. ----
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/dashboard/instruments/TSLA/asset-class",
            Some(&serde_json::json!({"asset_class": "bonds"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["error"], "unknown symbol");
}

/// Seed the soft-delete lifecycle portfolio: NVDA (lot + two disposals across
/// two years) and VTI (one disposal), fresh closes for both plus the S&P so
/// no endpoint reaches for Yahoo. Returns (brokerage_id, nvda_holding_id).
async fn seed_soft_delete_portfolio(
    pool: &PgPool,
    user_id: uuid::Uuid,
    inst: uuid::Uuid,
) -> (uuid::Uuid, uuid::Uuid) {
    let brok = seed_typed_account(pool, user_id, inst, "Brokerage", "brokerage", "1600.00").await;
    let nvda = seed_holding(
        pool,
        user_id,
        brok,
        "NVDA",
        "NVIDIA Corp",
        "equity",
        "10",
        Some("100"),
        "1000",
        Some("800"),
    )
    .await;
    seed_holding(
        pool,
        user_id,
        brok,
        "VTI",
        "Vanguard Total Market",
        "etf",
        "10",
        Some("60"),
        "600",
        Some("500"),
    )
    .await;

    let nvda_lot: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1, $2, $3, CURRENT_DATE - 60, 10, 80, 'USD', 1.0, 'nvda-lot') RETURNING id",
    )
    .bind(nvda)
    .bind(brok)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .unwrap();
    // This-year NVDA disposal (lot-linked, short-term) + a prior-year one so
    // by_year gains a band only NVDA feeds.
    sqlx::query(
        "INSERT INTO lot_disposals \
         (user_id, holding_id, account_id, lot_id, sell_source_id, qty_sold, sell_price_per_unit, \
          sell_currency, sell_fx_rate, sell_date, cost_per_unit, cost_fx_rate, realized_pnl_usd) \
         VALUES ($1, $2, $3, $4, 'nvda-s1', 5, 180, 'USD', 1.0, CURRENT_DATE - 30, 80, 1.0, 500), \
                ($1, $2, $3, NULL, 'nvda-s2', 2, 180, 'USD', 1.0, CURRENT_DATE - 400, 80, 1.0, 200)",
    )
    .bind(user_id)
    .bind(nvda)
    .bind(brok)
    .bind(nvda_lot)
    .execute(pool)
    .await
    .unwrap();
    // VTI keeps a this-year disposal so the surfaces stay non-empty while
    // NVDA sits in the undo window.
    let vti: uuid::Uuid =
        sqlx::query_scalar("SELECT id FROM holdings WHERE user_id = $1 AND symbol = 'VTI'")
            .bind(user_id)
            .fetch_one(pool)
            .await
            .unwrap();
    sqlx::query(
        "INSERT INTO lot_disposals \
         (user_id, holding_id, account_id, lot_id, sell_source_id, qty_sold, sell_price_per_unit, \
          sell_currency, sell_fx_rate, sell_date, cost_per_unit, cost_fx_rate, realized_pnl_usd) \
         VALUES ($1, $2, $3, NULL, 'vti-s1', 5, 60, 'USD', 1.0, CURRENT_DATE - 20, 0, 1.0, 300)",
    )
    .bind(user_id)
    .bind(vti)
    .bind(brok)
    .execute(pool)
    .await
    .unwrap();

    // Fresh closes: no endpoint reaches for Yahoo; TWR + day-change stay
    // deterministic across the delete → restore round-trip.
    seed_close(pool, "NVDA", 1, "98").await;
    seed_close(pool, "NVDA", 0, "100").await;
    seed_close(pool, "VTI", 1, "59").await;
    seed_close(pool, "VTI", 0, "60").await;
    seed_close(pool, "SP500", 60, "1000").await;
    seed_close(pool, "SP500", 0, "1100").await;
    (brok, nvda)
}

/// C3-B lifecycle: soft delete hides the holding AND its lots/tax history
/// from every surface (holdings, CSV/lots exports, allocation, realized
/// gains incl. by_year/ytd, instrument + dividend detail, tax summary, TWR,
/// account balance) while the row survives in the DB; restore brings every
/// figure back byte-identical.
#[tokio::test]
#[serial_test::serial]
async fn holding_soft_delete_excluded_everywhere_then_restore_byte_identical() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;
    let (brok, nvda) = seed_soft_delete_portfolio(&pool, user_id, inst).await;

    let this_year = chrono::Utc::now().format("%Y").to_string();
    let surfaces = [
        "/api/dashboard/holdings".to_string(),
        "/api/dashboard/allocation".to_string(),
        "/api/dashboard/realized-gains".to_string(),
        "/api/dashboard/portfolio-twr".to_string(),
        format!("/api/tax/summary?year={this_year}&status=Single"),
        format!("/api/accounts/{brok}/holdings"),
    ];
    async fn fetch_all(app: &Router, token: &str, surfaces: &[String]) -> Vec<Value> {
        let mut out = Vec::new();
        for uri in surfaces {
            let res = app
                .clone()
                .oneshot(req(Method::GET, uri, None, Some(token)))
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK, "{uri}");
            out.push(body_json(res.into_body()).await);
        }
        out
    }
    let before = fetch_all(&app, &token, &surfaces).await;
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/holdings/lots/export",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let lots_csv_before = body_text(res.into_body()).await;
    assert!(lots_csv_before.contains("NVDA"), "{lots_csv_before}");

    // ---- DELETE: same status as the old hard delete; row survives. ----
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/accounts/{brok}/holdings/{nvda}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    let deleted_at: Option<chrono::DateTime<chrono::Utc>> =
        sqlx::query_scalar("SELECT deleted_at FROM holdings WHERE id = $1")
            .bind(nvda)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(deleted_at.is_some(), "soft delete keeps the row");

    // Holdings: row gone, totals down to VTI only.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/holdings",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert!(!body["holdings"]
        .as_array()
        .unwrap()
        .iter()
        .any(|h| h["symbol"] == "NVDA"));
    assert!(
        (body["total_value_usd"].as_f64().unwrap() - 600.0).abs() < 0.01,
        "{}",
        body["total_value_usd"]
    );

    // Allocation: the NVDA equity band vanished; VTI (equity, still live)
    // remains, so no unclassified band appears for this account.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/allocation",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert!(!body
        .as_array()
        .unwrap()
        .iter()
        .any(|r| r["sub_category"] == "NVDA"));

    // Realized gains: NVDA's disposals (both years) hidden — the list, the
    // taxable subtotal, ytd, and by_year all shrink to VTI's 300.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/realized-gains",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert_eq!(body["summary"]["count"].as_i64().unwrap(), 1);
    assert!((body["summary"]["taxable_realized_usd"].as_f64().unwrap() - 300.0).abs() < 0.001);
    assert!((body["summary"]["ytd_realized_usd"].as_f64().unwrap() - 300.0).abs() < 0.001);
    assert!((body["summary"]["total_realized_usd"].as_f64().unwrap() - 300.0).abs() < 0.001);
    let by_year = body["by_year"].as_array().unwrap();
    assert_eq!(
        by_year.len(),
        1,
        "prior-year band was NVDA-only: {by_year:?}"
    );

    // Realized-gains CSV: no NVDA rows either.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/realized-gains/export",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let csv = body_text(res.into_body()).await;
    assert!(!csv.contains("NVDA"), "{csv}");
    // Lots CSV: the ghost's lot is invisible.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/holdings/lots/export",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let csv = body_text(res.into_body()).await;
    assert!(!csv.contains("NVDA"), "{csv}");

    // Instrument + dividend detail: the symbol is no longer held → 404.
    for uri in [
        "/api/dashboard/instruments/NVDA",
        "/api/dashboard/dividends/NVDA",
    ] {
        let res = app
            .clone()
            .oneshot(req(Method::GET, uri, None, Some(&token)))
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::NOT_FOUND, "{uri}");
    }

    // Tax summary: only VTI's 300 short-term survives the window.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/tax/summary?year={this_year}&status=Single"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert!(
        (body["short_term_gains"].as_f64().unwrap() - 300.0).abs() < 0.01,
        "{}",
        body["short_term_gains"]
    );

    // Account panel + balance: recomputed without the ghost.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/accounts/{brok}/holdings"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert!(!body
        .as_array()
        .unwrap()
        .iter()
        .any(|h| h["symbol"] == "NVDA"));
    let balance: Decimal = sqlx::query_scalar("SELECT current_balance FROM accounts WHERE id = $1")
        .bind(brok)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(balance, Decimal::from_str("600.00").unwrap());

    // ---- RESTORE: 200 with the HOLDING_COLS row shape. ----
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/{brok}/holdings/{nvda}/restore"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["id"].as_str().unwrap(), nvda.to_string());
    assert_eq!(body["symbol"], "NVDA");
    assert!((body["value"].as_f64().unwrap() - 1000.0).abs() < 0.01);

    // Every captured surface is byte-identical to its pre-delete snapshot.
    let after = fetch_all(&app, &token, &surfaces).await;
    for (i, (b, a)) in before.iter().zip(after.iter()).enumerate() {
        assert_eq!(
            b, a,
            "surface {} ({}) changed across delete→restore",
            i, surfaces[i]
        );
    }
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/holdings/lots/export",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(body_text(res.into_body()).await, lots_csv_before);
    let balance: Decimal = sqlx::query_scalar("SELECT current_balance FROM accounts WHERE id = $1")
        .bind(brok)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(balance, Decimal::from_str("1600.00").unwrap());
}

/// B4 purge rules: re-adding the same symbol hard-purges the soft-deleted
/// ghost (restore later must not resurrect a duplicate), and a ghost aged
/// past 24 h disappears on the next holdings write (lazy sweep — no cron).
#[tokio::test]
#[serial_test::serial]
async fn soft_delete_purge_on_readd_and_lazy_24h_sweep() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;
    let brok = seed_typed_account(&pool, user_id, inst, "Brokerage", "brokerage", "1000.00").await;
    let voo = seed_holding(
        &pool,
        user_id,
        brok,
        "VOO",
        "Vanguard S&P 500",
        "etf",
        "2",
        Some("500"),
        "1000",
        None,
    )
    .await;
    // Fresh close so create_holding's pricing path never reaches for Yahoo.
    seed_close(&pool, "VOO", 0, "500").await;
    seed_close(&pool, "ZZOLD", 0, "10").await;

    // Soft-delete VOO, then re-add the same symbol: the ghost is purged and
    // exactly ONE row (the new one) remains.
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/accounts/{brok}/holdings/{voo}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/{brok}/holdings"),
            Some(&serde_json::json!({"symbol": "VOO", "quantity": 3})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM holdings WHERE account_id = $1 AND symbol = 'VOO'",
    )
    .bind(brok)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(count, 1, "ghost purged on re-add");
    // The purged ghost can no longer be restored.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/{brok}/holdings/{voo}/restore"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);

    // Lazy sweep: a ghost older than 24 h is hard-deleted (cascade takes its
    // lots) by the NEXT holdings write for this user.
    let old = seed_holding(
        &pool,
        user_id,
        brok,
        "ZZOLD",
        "Old Ghost",
        "equity",
        "1",
        Some("10"),
        "10",
        None,
    )
    .await;
    sqlx::query("UPDATE holdings SET deleted_at = now() - interval '25 hours' WHERE id = $1")
        .bind(old)
        .execute(&pool)
        .await
        .unwrap();
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/{brok}/holdings"),
            Some(&serde_json::json!({"symbol": "MSFT", "quantity": 1})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let gone: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM holdings WHERE id = $1")
        .bind(old)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(gone, 0, "expired ghost swept on the next holdings write");
}

/// C3-B 404 paths: another user can't restore my holding, a second restore
/// is a no-op 404, and a never-existed id 404s — all with the contract's
/// error body.
#[tokio::test]
#[serial_test::serial]
async fn restore_holding_404s_for_wrong_user_and_double_restore() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token_a, user_a) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_a).await;
    let brok = seed_typed_account(&pool, user_a, inst, "Brokerage", "brokerage", "1000.00").await;
    let voo = seed_holding(
        &pool,
        user_a,
        brok,
        "VOO",
        "Vanguard S&P 500",
        "etf",
        "2",
        Some("500"),
        "1000",
        None,
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/accounts/{brok}/holdings/{voo}"),
            None,
            Some(&token_a),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);

    // Hand-rolled user B (same pattern as split_cross_user_is_404).
    let user_b: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, email, password_hash) \
         VALUES ('bob', 'bob@example.com', 'doesnt-matter-for-this-test') RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .expect("seed user b");
    let token_b = patrimonio::services::sessions::create_session(&pool, user_b, None, None)
        .await
        .expect("create user b session")
        .token;

    // B can't restore A's holding — and the ghost stays soft-deleted.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/{brok}/holdings/{voo}/restore"),
            None,
            Some(&token_b),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["error"], "nothing to restore");
    let still_deleted: bool =
        sqlx::query_scalar("SELECT deleted_at IS NOT NULL FROM holdings WHERE id = $1")
            .bind(voo)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(still_deleted);

    // Owner restores fine; the SECOND restore finds nothing.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/{brok}/holdings/{voo}/restore"),
            None,
            Some(&token_a),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/{brok}/holdings/{voo}/restore"),
            None,
            Some(&token_a),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["error"], "nothing to restore");

    // Never-existed id: same 404.
    let bogus = uuid::Uuid::new_v4();
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/{brok}/holdings/{bogus}/restore"),
            None,
            Some(&token_a),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
}

/// Regression: GET /api/accounts/summary must convert each balance to USD
/// before summing. A MXN balance was previously added to the USD total at its
/// raw peso value (the ~18x cross-currency overstatement class), so a $1,000
/// USD + MX$20,000 (≈$1,000) portfolio reported total_assets ≈ 21,000 instead
/// of ≈ 2,000. This pins the FX conversion.
#[tokio::test]
#[serial_test::serial]
async fn accounts_summary_converts_mxn_to_usd_not_raw_sum() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    // seed_account gives one USD depository account with 1000.00 balance.
    let (inst_id, _usd_acct) = seed_account(&pool, user_id).await;

    // A second account in pesos: MX$20,000. At 20 USD→MXN that is $1,000 USD.
    sqlx::query(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Nu MXN', 'depository', 'MXN', 20000.00, $2)",
    )
    .bind(inst_id)
    .bind(user_id)
    .execute(&pool)
    .await
    .expect("seed MXN account");

    // USD→MXN = 20.0 so the peso balance converts to exactly $1,000 USD.
    sqlx::query(
        "INSERT INTO exchange_rates (base_currency, target_currency, rate, recorded_at) \
         VALUES ('USD', 'MXN', 20.00, NOW())",
    )
    .execute(&pool)
    .await
    .expect("seed fx rate");

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/accounts/summary",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let total_assets = body["total_assets"].as_f64().expect("total_assets f64");
    // $1,000 USD + $1,000 USD-equivalent = ~$2,000, NOT the raw 21,000 sum.
    assert!(
        (total_assets - 2000.0).abs() < 0.5,
        "expected ~2000 USD, got {total_assets} (raw cross-currency sum would be ~21000)"
    );
    assert!(
        total_assets < 5000.0,
        "total_assets {total_assets} looks like an un-converted peso sum"
    );
    assert_eq!(body["account_count"], 2);
}

// =====================================================================
// /dashboard/transactions — currency / sign / q filters
//
// The loan-repayment picker used to pull one recent page and filter in
// the client, so a repayment older than the newest N — or in a foreign
// currency — was invisible. These filters push that scoping into SQL over
// the WHOLE table: the picker can now find any matching inflow.
// =====================================================================

/// Insert an institution + account with an explicit currency; returns the
/// account id.
async fn seed_account_currency(pool: &PgPool, user_id: uuid::Uuid, currency: &str) -> uuid::Uuid {
    let inst_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ('Bank', 'bank', 'MX', 'manual', 'ok', $1) RETURNING id",
    )
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed institution");
    sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Acct', 'depository', $2, 0.00, $3) RETURNING id",
    )
    .bind(inst_id)
    .bind(currency)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed account")
}

/// Insert a transaction with an explicit currency; returns its id.
async fn seed_tx_currency(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    description: &str,
    amount: &str,
    currency: &str,
) -> uuid::Uuid {
    sqlx::query_scalar(
        "INSERT INTO transactions (account_id, date, description, amount, currency, source, user_id) \
         VALUES ($1, CURRENT_DATE, $2, $3, $4, 'manual', $5) RETURNING id",
    )
    .bind(account_id)
    .bind(description)
    .bind(Decimal::from_str(amount).unwrap())
    .bind(currency)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed tx")
}

#[tokio::test]
#[serial_test::serial]
async fn transactions_currency_sign_and_search_filters() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let _ = bootstrap(&app, &pool).await;
    let (user_id, token) = seed_owner(&pool, "picker").await;

    let mxn = seed_account_currency(&pool, user_id, "MXN").await;
    let usd = seed_account_currency(&pool, user_id, "USD").await;

    // The repayment we want the picker to find.
    let repayment = seed_tx_currency(
        &pool,
        user_id,
        mxn,
        "SPEI RECIBIDO LUIS OJEDA",
        "3500.00",
        "MXN",
    )
    .await;
    // Same-currency inflow that does NOT match the search.
    let other_mxn_inflow =
        seed_tx_currency(&pool, user_id, mxn, "OXXO reembolso", "200.00", "MXN").await;
    // Wrong sign (MXN outflow) — must never appear as a repayment candidate.
    let mxn_outflow = seed_tx_currency(&pool, user_id, mxn, "CFE pago", "-1000.00", "MXN").await;
    // Right sign, wrong currency — reconciling it would 400, so it must be
    // filtered out before the user can pick it.
    let usd_inflow = seed_tx_currency(&pool, user_id, usd, "PAYCHECK LUIS", "500.00", "USD").await;

    // currency=MXN & sign=inflow → the two MXN inflows only.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/transactions?currency=MXN&sign=inflow&limit=200",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let ids = tx_ids(body_json(res.into_body()).await);
    assert!(
        ids.contains(&repayment.to_string()),
        "MXN inflow must be listed"
    );
    assert!(
        ids.contains(&other_mxn_inflow.to_string()),
        "other MXN inflow must be listed"
    );
    assert!(
        !ids.contains(&mxn_outflow.to_string()),
        "sign=inflow must exclude the MXN outflow"
    );
    assert!(
        !ids.contains(&usd_inflow.to_string()),
        "currency=MXN must exclude the USD inflow"
    );

    // Add a search term → only the SPEI Luis inflow survives, proving the
    // match is found in SQL rather than by scanning one client-side page.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/transactions?currency=MXN&sign=inflow&q=luis",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let ids = tx_ids(body_json(res.into_body()).await);
    assert_eq!(
        ids,
        vec![repayment.to_string()],
        "q=luis should return exactly the SPEI Luis repayment"
    );
}

/// Extract the `id` array from a `/dashboard/transactions` response body.
fn tx_ids(body: Value) -> Vec<String> {
    body.as_array()
        .unwrap()
        .iter()
        .filter_map(|r| r["id"].as_str().map(String::from))
        .collect()
}

#[tokio::test]
#[serial_test::serial]
async fn transactions_exclude_linked_hides_reconciled_repayment() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let _ = bootstrap(&app, &pool).await;
    let (user_id, token) = seed_owner(&pool, "linkpicker").await;

    let mxn = seed_account_currency(&pool, user_id, "MXN").await;
    let linked =
        seed_tx_currency(&pool, user_id, mxn, "SPEI RECIBIDO LUIS", "3500.00", "MXN").await;
    let free = seed_tx_currency(&pool, user_id, mxn, "SPEI RECIBIDO OTRO", "3500.00", "MXN").await;

    // Reconcile `linked` to a loan payment.
    let loan_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO loans (user_id, borrower_name, principal, currency, origination_date) \
         VALUES ($1, 'Luis', 3500, 'MXN', CURRENT_DATE) RETURNING id",
    )
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed loan");
    sqlx::query(
        "INSERT INTO loan_payments (user_id, loan_id, installment_number, actual_tx_id, paid_amount) \
         VALUES ($1, $2, 1, $3, 3500)",
    )
    .bind(user_id)
    .bind(loan_id)
    .bind(linked)
    .execute(&pool)
    .await
    .expect("seed loan payment");

    // Without the flag, both inflows show.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/transactions?sign=inflow&currency=MXN",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let ids = tx_ids(body_json(res.into_body()).await);
    assert!(ids.contains(&linked.to_string()) && ids.contains(&free.to_string()));

    // With exclude_linked, the reconciled one drops out; the free one stays.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/transactions?sign=inflow&currency=MXN&exclude_linked=true",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let ids = tx_ids(body_json(res.into_body()).await);
    assert!(
        !ids.contains(&linked.to_string()),
        "exclude_linked must hide the already-reconciled tx"
    );
    assert!(
        ids.contains(&free.to_string()),
        "exclude_linked must keep an unlinked tx"
    );
}

// =====================================================================
// /api/projections/defaults — per-row FX, 2dp rounding, loud errors
// =====================================================================

/// Insert a transaction with an explicit currency dated `days_ago` days back.
/// Needed by the projection-defaults tests, which must place MXN cash flow in
/// two different months under two different stored FX rates.
async fn seed_tx_currency_days_ago(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    description: &str,
    amount: &str,
    currency: &str,
    days_ago: i32,
) -> uuid::Uuid {
    sqlx::query_scalar(
        "INSERT INTO transactions (account_id, date, description, amount, currency, source, user_id) \
         VALUES ($1, CURRENT_DATE - $2::int, $3, $4, $5, 'manual', $6) RETURNING id",
    )
    .bind(account_id)
    .bind(days_ago)
    .bind(description)
    .bind(Decimal::from_str(amount).unwrap())
    .bind(currency)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed dated currency tx")
}

/// Insert a USD→MXN exchange rate recorded `days_ago` days back.
async fn seed_fx_rate_days_ago(pool: &PgPool, rate: &str, days_ago: i32) {
    sqlx::query(
        "INSERT INTO exchange_rates (base_currency, target_currency, rate, recorded_at) \
         VALUES ('USD', 'MXN', $1::numeric, NOW() - ($2::int || ' days')::interval)",
    )
    .bind(rate)
    .bind(days_ago)
    .execute(pool)
    .await
    .expect("seed fx rate");
}

/// `v` must be representable with at most 2 decimal places (the endpoint
/// rounds in Decimal before serializing — it used to ship raw f64 noise
/// like 1828.8000000000002).
fn assert_two_dp(v: f64, field: &str) {
    let scaled = v * 100.0;
    assert!(
        (scaled - scaled.round()).abs() < 1e-6,
        "{field} = {v} has more than 2 decimal places"
    );
}

/// Regression: /api/projections/defaults must convert each MXN transaction at
/// the FX rate in effect ON ITS OWN DATE (the shared services::tax
/// USD_MXN_ROW_RATE_SQL rule), not at the single latest rate. Rates move
/// several percent over a trailing year, so latest-rate conversion skews the
/// annualized income/spend whenever the peso has trended. Also pins:
/// 2dp-rounded outputs, and 401 for unauthenticated callers (the handler now
/// returns Result<_, ApiError> instead of fabricating zeros).
#[tokio::test]
#[serial_test::serial]
async fn projection_defaults_per_row_fx_and_errors() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };

    // Unauthenticated first: no cookie → 401, never a zeros body.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/projections/defaults", None, None))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::UNAUTHORIZED,
        "defaults without a session must 401"
    );

    let (token, user_id) = bootstrap(&app, &pool).await;
    let mxn_acct = seed_account_currency(&pool, user_id, "MXN").await;

    // Two rates in force in two different months:
    //   ~100 days ago: 20.00 MXN per USD
    //   ~40 days ago:  21.00 MXN per USD  (also the LATEST rate)
    seed_fx_rate_days_ago(&pool, "20.00", 100).await;
    seed_fx_rate_days_ago(&pool, "21.00", 40).await;

    // Month A (100 days ago, rate 20): +20,000 MXN → $1,000.00; −2,100 MXN → $105.00
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "salary A", "20000.00", "MXN", 100).await;
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent A", "-2100.00", "MXN", 100).await;
    // Month B (40 days ago, rate 21): +10,000 MXN → $476.190476…; −1,050 MXN → $50.00
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "salary B", "10000.00", "MXN", 40).await;
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent B", "-1050.00", "MXN", 40).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/projections/defaults",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    let income = body["annual_income"].as_f64().expect("annual_income f64");
    let expenses = body["annual_expenses"]
        .as_f64()
        .expect("annual_expenses f64");
    let contribution = body["monthly_contribution"]
        .as_f64()
        .expect("monthly_contribution f64");
    assert_eq!(body["months_of_data"].as_i64(), Some(2));

    // Per-row conversion, annualized over the 2 months of data:
    //   income  = (20000/20 + 10000/21) / 2 * 12 = 8857.142857… → 8857.14
    //   spend   = (2100/20  + 1050/21)  / 2 * 12 = 930.00
    //   monthly = (8857.14… − 930) / 12          = 660.595…    → 660.60
    // Latest-rate (21.0) conversion would instead give income = 8571.43 and
    // spend = 900.00 — the bug this test pins against.
    assert!(
        (income - 8857.14).abs() < 0.01,
        "annual_income {income}: expected per-row FX 8857.14 (latest-rate bug would give 8571.43)"
    );
    assert!(
        (expenses - 930.00).abs() < 0.01,
        "annual_expenses {expenses}: expected per-row FX 930.00 (latest-rate bug would give 900.00)"
    );
    assert!(
        (contribution - 660.60).abs() < 0.01,
        "monthly_contribution {contribution}: expected 660.60"
    );

    assert_two_dp(income, "annual_income");
    assert_two_dp(expenses, "annual_expenses");
    assert_two_dp(contribution, "monthly_contribution");
}

/// Regression: months_of_data counts DISTINCT calendar months with data, and
/// the annualization divides by that count — 2 months of history must not be
/// stretched as if it were a full year (a user with 2 months of imports would
/// otherwise be told they earn/spend a sixth of reality).
#[tokio::test]
#[serial_test::serial]
async fn projection_defaults_months_of_data_partial_months() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // Transactions in exactly two distinct months (100 and 40 days back are
    // always >31 days apart, hence different calendar months, and both are
    // inside the trailing-12-month window).
    seed_tx_currency_days_ago(&pool, user_id, acct, "pay 1", "3000.00", "USD", 100).await;
    seed_tx_currency_days_ago(&pool, user_id, acct, "pay 2", "3000.00", "USD", 40).await;
    seed_tx_currency_days_ago(&pool, user_id, acct, "groceries", "-600.00", "USD", 40).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/projections/defaults",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    assert_eq!(
        body["months_of_data"].as_i64(),
        Some(2),
        "two distinct months of transactions → months_of_data == 2"
    );
    // Annualization divides by 2 (the actual months), not 12:
    //   income  = 6000 / 2 * 12 = 36000
    //   spend   =  600 / 2 * 12 =  3600
    //   monthly = (36000 − 3600) / 12 = 2700
    let income = body["annual_income"].as_f64().unwrap();
    let expenses = body["annual_expenses"].as_f64().unwrap();
    let contribution = body["monthly_contribution"].as_f64().unwrap();
    assert!((income - 36000.0).abs() < 0.01, "annual_income {income}");
    assert!(
        (expenses - 3600.0).abs() < 0.01,
        "annual_expenses {expenses}"
    );
    assert!(
        (contribution - 2700.0).abs() < 0.01,
        "monthly_contribution {contribution}"
    );
}

// =====================================================================
// Dashboard trends / spending / emergency-fund — per-row historical FX
//
// Same bug class as /api/projections/defaults above: these endpoints used
// to convert MONTHS of historical MXN transactions at the single LATEST
// USD/MXN rate. Each test seeds flows in two months under two different
// stored rates and asserts the response matches per-row (on-or-before-date)
// conversion — and provably differs from what latest-rate conversion would
// produce.
//
// Shared fixture: rate 20.00 recorded ~100 days ago, rate 21.00 recorded
// ~40 days ago (also the latest). Month A (100d back) flows convert at 20;
// month B (40d back) flows convert at 21. 100d and 40d are always in
// different calendar months (60 days apart) and both inside every window
// these endpoints use.
// =====================================================================

/// Regression: /api/dashboard/trends must convert each month's MXN flows at
/// that month's rate, not restate the whole 12-month chart at today's rate.
#[tokio::test]
#[serial_test::serial]
async fn cash_flow_trends_converts_each_month_at_its_own_fx_rate() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let mxn_acct = seed_account_currency(&pool, user_id, "MXN").await;

    seed_fx_rate_days_ago(&pool, "20.00", 100).await;
    seed_fx_rate_days_ago(&pool, "21.00", 40).await;

    // Month A (rate 20): +20,000 → $1,000.00; −2,100 → $105.00
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "salary A", "20000.00", "MXN", 100).await;
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent A", "-2100.00", "MXN", 100).await;
    // Month B (rate 21): +10,000 → $476.190476…; −1,050 → $50.00
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "salary B", "10000.00", "MXN", 40).await;
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent B", "-1050.00", "MXN", 40).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/trends",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let points = body.as_array().expect("trends array");
    assert_eq!(points.len(), 2, "one point per seeded month: {body}");

    // Rows come back ORDER BY month ASC, so [0] = month A, [1] = month B.
    let inc_a = points[0]["income"].as_f64().unwrap();
    let sp_a = points[0]["spending"].as_f64().unwrap();
    let inc_b = points[1]["income"].as_f64().unwrap();
    let sp_b = points[1]["spending"].as_f64().unwrap();
    assert!(
        (inc_a - 1000.00).abs() < 0.01,
        "month A income {inc_a}: expected 1000.00 at its own rate 20 \
         (latest-rate bug would give 952.38)"
    );
    assert!(
        (sp_a - 105.00).abs() < 0.01,
        "month A spending {sp_a}: expected 105.00 at its own rate 20 \
         (latest-rate bug would give 100.00)"
    );
    assert!(
        (inc_b - 476.19).abs() < 0.01,
        "month B income {inc_b}: expected 476.19 at rate 21"
    );
    assert!(
        (sp_b - 50.00).abs() < 0.01,
        "month B spending {sp_b}: expected 50.00 at rate 21"
    );
}

/// Regression: /api/dashboard/emergency-fund's trailing-12-month spend
/// (the runway denominator) must convert per row. The liquid-cash numerator
/// deliberately stays at the LATEST rate — a current balance is a
/// present-day value — and this test pins that policy split.
#[tokio::test]
#[serial_test::serial]
async fn emergency_fund_spend_per_row_fx_cash_at_latest_rate() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;

    // A liquid (checking) MXN account holding 2,100 MXN today.
    let inst_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ('Banco', 'bank', 'MX', 'manual', 'ok', $1) RETURNING id",
    )
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed institution");
    let mxn_acct: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Cuenta', 'checking', 'MXN', 2100.00, $2) RETURNING id",
    )
    .bind(inst_id)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed checking account");

    seed_fx_rate_days_ago(&pool, "20.00", 100).await;
    seed_fx_rate_days_ago(&pool, "21.00", 40).await;

    // −2,100 MXN at rate 20 → $105.00; −1,050 MXN at rate 21 → $50.00.
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent A", "-2100.00", "MXN", 100).await;
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent B", "-1050.00", "MXN", 40).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/emergency-fund",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    // Current cash converts at the LATEST rate (21): 2100 / 21 = $100.00.
    let cash = body["liquid_cash_usd"].as_f64().unwrap();
    assert!(
        (cash - 100.00).abs() < 0.01,
        "liquid_cash_usd {cash}: current balances convert at the latest rate (2100/21 = 100)"
    );

    // Historical spend converts PER ROW: (105 + 50) / 2 months = $77.50.
    let spend = body["monthly_spend_usd"].as_f64().unwrap();
    assert!(
        (spend - 77.50).abs() < 0.01,
        "monthly_spend_usd {spend}: expected per-row FX 77.50 \
         (latest-rate bug would give 75.00)"
    );
    assert_eq!(body["months_of_data"].as_i64(), Some(2));
    let covered = body["months_covered"].as_f64().unwrap();
    assert!(
        (covered - 100.0 / 77.50).abs() < 0.001,
        "months_covered {covered}: expected 100 / 77.50"
    );
}

/// Regression: /api/dashboard/spending-by-category totals use per-row FX
/// (same converted-CTE shape as trends — one representative assertion).
#[tokio::test]
#[serial_test::serial]
async fn spending_by_category_per_row_fx() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let mxn_acct = seed_account_currency(&pool, user_id, "MXN").await;

    seed_fx_rate_days_ago(&pool, "20.00", 100).await;
    seed_fx_rate_days_ago(&pool, "21.00", 40).await;
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent A", "-2100.00", "MXN", 100).await;
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent B", "-1050.00", "MXN", 40).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/spending-by-category",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    let cats = body["categories"].as_array().expect("categories array");
    assert_eq!(cats.len(), 1, "one seeded category: {body}");
    assert_eq!(cats[0]["category"], "UNCATEGORIZED");
    let total = cats[0]["total"].as_f64().unwrap();
    // Per-row: 2100/20 + 1050/21 = 105 + 50 = 155. Latest-rate bug: 150.
    assert!(
        (total - 155.00).abs() < 0.01,
        "category total {total}: expected per-row FX 155.00 (latest-rate bug would give 150.00)"
    );
}

/// Regression: /api/dashboard/spending-insights averages use per-row FX
/// (same converted-CTE shape — one representative assertion on the
/// trailing average, which spans both rate regimes).
#[tokio::test]
#[serial_test::serial]
async fn spending_insights_per_row_fx() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let mxn_acct = seed_account_currency(&pool, user_id, "MXN").await;

    seed_fx_rate_days_ago(&pool, "20.00", 100).await;
    seed_fx_rate_days_ago(&pool, "21.00", 40).await;
    // Both dates are always inside the default window (lookback 3 → the 4
    // complete months before the current one): 40 days back is always before
    // the current month starts, 100 days back is always after the window
    // start (≥ ~120 days back).
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent A", "-2100.00", "MXN", 100).await;
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent B", "-1050.00", "MXN", 40).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/spending-insights",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    let cats = body["categories"].as_array().expect("categories array");
    assert_eq!(cats.len(), 1, "one seeded category group: {body}");
    let trailing = cats[0]["trailing_avg"].as_f64().unwrap();
    // Per-row: (2100/20 + 1050/21) / 4-month window = 155/4 = 38.75.
    // Latest-rate bug: 150/4 = 37.50.
    assert!(
        (trailing - 38.75).abs() < 0.01,
        "trailing_avg {trailing}: expected per-row FX 38.75 (latest-rate bug would give 37.50)"
    );
}

// =====================================================================
// Dashboard trends / spending / emergency-fund — errors are 500s, empty
// data is still a 200
//
// These four handlers used to swallow DB failures (`.unwrap_or_default()`
// / `.ok().flatten()`), rendering "the query blew up" as an empty chart /
// all-zeros runway. They now return Result<_, ApiError> and 500 loudly.
// The tests below pin the OTHER half of that contract: a user with
// genuinely no data must still get a 200 with the same empty-shaped body
// as before — only errors changed behavior. (A real DB error can't be
// simulated through the harness; the signature change + clippy guard it.)
// =====================================================================

/// A brand-new user with zero transactions gets 200 + `[]` from /trends,
/// not an error — "no data" is a legitimate empty state, not a failure.
#[tokio::test]
#[serial_test::serial]
async fn cash_flow_trends_no_data_is_200_empty_array() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user_id) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/trends",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::OK,
        "empty data must stay a 200, not a 500"
    );
    let body = body_json(res.into_body()).await;
    assert_eq!(
        body,
        serde_json::json!([]),
        "no transactions → empty array, same shape as before the error-handling change"
    );
}

/// A brand-new user with zero accounts/transactions gets 200 + an
/// all-zeros runway from /emergency-fund — the ungrouped aggregates
/// still decode as (0, 0) on genuinely empty data.
#[tokio::test]
#[serial_test::serial]
async fn emergency_fund_no_data_is_200_zero_runway() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user_id) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/emergency-fund",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::OK,
        "empty data must stay a 200, not a 500"
    );
    let body = body_json(res.into_body()).await;
    assert_eq!(
        body["liquid_cash_usd"].as_f64(),
        Some(0.0),
        "no accounts → $0 cash: {body}"
    );
    assert_eq!(
        body["monthly_spend_usd"].as_f64(),
        Some(0.0),
        "no spend → $0/mo: {body}"
    );
    assert_eq!(
        body["months_covered"].as_f64(),
        Some(0.0),
        "no spend signal → 0 months: {body}"
    );
    assert_eq!(
        body["months_of_data"].as_i64(),
        Some(0),
        "no history → 0 months of data: {body}"
    );
}

/// All four upgraded chart endpoints still require auth: unauthenticated
/// requests are 401, not empty-but-200 bodies.
#[tokio::test]
#[serial_test::serial]
async fn dashboard_chart_endpoints_unauthenticated_are_401() {
    let Some((app, _pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    for uri in [
        "/api/dashboard/trends",
        "/api/dashboard/spending-by-category",
        "/api/dashboard/spending-insights",
        "/api/dashboard/emergency-fund",
        "/api/dashboard/benchmark-comparison",
    ] {
        let res = app
            .clone()
            .oneshot(req(Method::GET, uri, None, None))
            .await
            .unwrap();
        assert_eq!(
            res.status(),
            StatusCode::UNAUTHORIZED,
            "{uri} without a session must 401"
        );
    }
}

/// Seed one institution of a given integration type + sync status. Returns
/// its id. Used by the async-sync tests below.
async fn seed_inst(
    pool: &PgPool,
    user_id: uuid::Uuid,
    integration_type: &str,
    status: &str,
) -> uuid::Uuid {
    sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ($1, 'bank', 'US', $2, $3, $4) RETURNING id",
    )
    .bind(format!("Inst {integration_type}"))
    .bind(integration_type)
    .bind(status)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed inst")
}

async fn sync_status_of(pool: &PgPool, id: uuid::Uuid) -> String {
    sqlx::query_scalar("SELECT sync_status FROM institutions WHERE id = $1")
        .bind(id)
        .fetch_one(pool)
        .await
        .expect("read sync_status")
}

/// The manual "Sync now" trigger must return immediately (202 Accepted) and
/// run the sync as a detached task — it no longer blocks the request on the
/// whole multi-institution sync. This is what keeps backgrounding the app
/// (which kills the socket) from cancelling the sync or surfacing a
/// "connection abort" error.
#[tokio::test]
async fn manual_sync_trigger_returns_202_immediately() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    // A manual-only institution: nothing to contact upstream, so the detached
    // task finishes trivially — but the endpoint contract (202 + accepted) is
    // the same regardless of what it kicks off.
    seed_inst(&pool, user_id, "manual", "ok").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/institutions/sync",
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    let status = res.status();
    let body = body_json(res.into_body()).await;
    assert_eq!(
        status,
        StatusCode::ACCEPTED,
        "sync trigger must return 202, not block on the sync"
    );
    assert_eq!(body["status"], "accepted");
}

/// Regression: "Sync now" on web 415'd. The browser stamps `text/plain`
/// on a body-less POST, and the old `Option<Json<SyncRequest>>` extractor
/// rejects any present-but-non-JSON Content-Type with 415 Unsupported
/// Media Type. The handler now reads raw bytes and treats an empty body —
/// whatever its Content-Type — as "sync everything", while a non-empty
/// body that isn't valid JSON gets a 400 (never a silent sync-all when
/// the client asked for a subset).
#[tokio::test]
async fn manual_sync_tolerates_empty_non_json_body() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    seed_inst(&pool, user_id, "manual", "ok").await;

    // Empty body with Content-Type: text/plain — what a browser sends for
    // the frontend's old body-less POST. Must be accepted, not 415.
    let plain_empty = Request::builder()
        .method(Method::POST)
        .uri("/api/institutions/sync")
        .header("X-Requested-With", "patrimonio")
        .header(header::CONTENT_TYPE, "text/plain")
        .header(header::COOKIE, cookie_header(&cookie))
        .body(Body::empty())
        .unwrap();
    let res = app.clone().oneshot(plain_empty).await.unwrap();
    let status = res.status();
    let body = body_json(res.into_body()).await;
    assert_eq!(
        status,
        StatusCode::ACCEPTED,
        "empty text/plain body must be treated as 'sync everything', not 415"
    );
    assert_eq!(body["status"], "accepted");

    // A non-empty body that isn't JSON is a malformed request — 400, so a
    // broken batch client can't accidentally fan out to every institution.
    let garbage = Request::builder()
        .method(Method::POST)
        .uri("/api/institutions/sync")
        .header("X-Requested-With", "patrimonio")
        .header(header::CONTENT_TYPE, "text/plain")
        .header(header::COOKIE, cookie_header(&cookie))
        .body(Body::from("definitely not json"))
        .unwrap();
    let res = app.clone().oneshot(garbage).await.unwrap();
    assert_eq!(
        res.status(),
        StatusCode::BAD_REQUEST,
        "non-empty non-JSON body must 400, not sync everything"
    );

    // The JSON contract is unchanged: `{"ids": [...]}` still narrows the
    // sync, and the new frontend's explicit `{}` body still means "all".
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/institutions/sync",
            Some(&serde_json::json!({})),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::ACCEPTED,
        "explicit empty-JSON body ('{{}}') must be accepted"
    );
}

/// `mark_syncable_syncing` is the synchronous pre-stamp the trigger runs
/// before spawning the detached task, so a client's `/sync-status` poll sees
/// the in-progress state the instant the trigger returns. It must mark only
/// the syncable integration types, only for the calling user, and (with
/// `only_ids`) only the requested subset.
#[tokio::test]
async fn mark_syncable_syncing_scopes_to_syncable_types_and_user() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (_cookie, user_a) = bootstrap(&app, &pool).await;
    let user_b: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, password_hash) VALUES ('other', 'x') RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .expect("seed second user");

    let plaid = seed_inst(&pool, user_a, "plaid", "synced").await;
    let coinbase = seed_inst(&pool, user_a, "coinbase", "error").await;
    let cbo = seed_inst(&pool, user_a, "coinbase_oauth", "reconnect_required").await;
    let bitso = seed_inst(&pool, user_a, "bitso", "synced").await;
    let manual = seed_inst(&pool, user_a, "manual", "manual").await;
    let csv = seed_inst(&pool, user_a, "csv", "manual").await;
    let b_plaid = seed_inst(&pool, user_b, "plaid", "synced").await;

    let marked = patrimonio::services::sync::mark_syncable_syncing(&pool, user_a, &None)
        .await
        .expect("mark syncable");
    assert_eq!(
        marked, 4,
        "only user A's 4 syncable institutions are marked"
    );

    for id in [plaid, coinbase, cbo, bitso] {
        assert_eq!(sync_status_of(&pool, id).await, "syncing");
    }
    // Manual/CSV are never contacted upstream — leave their status alone so
    // they don't get stuck showing "syncing" forever (the engine would never
    // flip them out of it).
    assert_eq!(sync_status_of(&pool, manual).await, "manual");
    assert_eq!(sync_status_of(&pool, csv).await, "manual");
    // Cross-tenant safety: another user's institution is never touched.
    assert_eq!(sync_status_of(&pool, b_plaid).await, "synced");

    // `only_ids` narrows the pre-stamp to the requested subset.
    let marked_one =
        patrimonio::services::sync::mark_syncable_syncing(&pool, user_a, &Some(vec![coinbase]))
            .await
            .expect("mark subset");
    assert_eq!(
        marked_one, 1,
        "only the one requested institution is marked"
    );
}
