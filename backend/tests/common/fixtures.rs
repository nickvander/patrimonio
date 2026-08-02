//! Shared integration-test harness + seed fixtures.
//!
//! Extracted from the former 10.5k-line `tests/dashboard_endpoints.rs` when it
//! was split into one file per API surface (accounts, loans, subscriptions,
//! fx-transfers, institutions-sync, imports-upload, projections-defaults,
//! dashboard). Every helper any of those files uses lives here so the split
//! files never re-duplicate fixtures (duplicated seed helpers were exactly how
//! the historical FX bugs drifted apart).
//!
//! This module is compiled into EVERY `tests/*.rs` binary via `mod common;`,
//! and each binary uses only a subset of the helpers — hence the
//! `#[allow(dead_code)]` on the `pub mod fixtures;` declaration in
//! `common/mod.rs`.

use std::sync::Arc;

use axum::middleware::from_fn_with_state;
use sqlx::postgres::PgPoolOptions;

use patrimonio::config::AppConfig;
use patrimonio::AppState;

use super::TestLockGuard;

// Re-exports: the split test files start with `use common::fixtures::*;` and
// get the whole HTTP-test vocabulary (types + traits) in one glob, so a moved
// test compiles byte-identically without its own import preamble.
pub use axum::body::{to_bytes, Body};
pub use axum::http::{header, HeaderValue, Method, Request, StatusCode};
pub use axum::Router;
pub use rust_decimal::Decimal;
pub use serde_json::Value;
pub use sqlx::PgPool;
pub use sqlx::Row;
pub use std::str::FromStr;
pub use tower::ServiceExt;

pub const TEST_DB_VAR: &str = "PATRIMONIO_TEST_DATABASE_URL";
pub const SESSION_COOKIE: &str = "patrimonio_session";

/// Build the full protected + public router so the tests exercise the
/// same middleware stack as production (CSRF outer layer, auth inner
/// layer). The plaid creds + webhook URL are caller-tunable so we
/// can cover the 503/400/200 branches of `update-webhook`.
pub async fn try_setup(
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

pub fn skip_if_no_db<T>(result: Option<T>) -> Option<T> {
    if result.is_none() {
        eprintln!(
            "(skipping: set {TEST_DB_VAR}=postgres://user:pass@host/db to enable dashboard integration tests)"
        );
    }
    result
}

pub async fn body_json(body: Body) -> Value {
    let bytes = to_bytes(body, 1024 * 256).await.expect("read body");
    if bytes.is_empty() {
        return Value::Null;
    }
    serde_json::from_slice(&bytes).expect("json body")
}

pub fn set_cookie_value(headers: &axum::http::HeaderMap) -> Option<String> {
    for cookie in headers.get_all(header::SET_COOKIE).iter() {
        let raw = cookie.to_str().ok()?;
        let pair = raw.split(';').next()?.trim();
        if let Some(rest) = pair.strip_prefix(&format!("{SESSION_COOKIE}=")) {
            return Some(rest.to_string());
        }
    }
    None
}

pub fn cookie_header(token: &str) -> HeaderValue {
    HeaderValue::from_str(&format!("{SESSION_COOKIE}={token}")).expect("valid cookie header")
}

/// Build a request with the right cookie + CSRF header + JSON body.
/// The CSRF middleware short-circuits mutating requests without
/// `X-Requested-With`, so every POST/PATCH/PUT/DELETE we send needs
/// the header — bake it in by default to avoid forgetting in
/// individual tests.
pub fn req(method: Method, uri: &str, body: Option<&Value>, cookie: Option<&str>) -> Request<Body> {
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
pub async fn bootstrap(app: &Router, pool: &PgPool) -> (String, uuid::Uuid) {
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
pub async fn seed_account(pool: &PgPool, user_id: uuid::Uuid) -> (uuid::Uuid, uuid::Uuid) {
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
pub async fn seed_tx(
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

/// Read a single transaction's category straight from the DB. Cleaner
/// than round-tripping a list endpoint just to assert one column.
pub async fn tx_category(pool: &PgPool, tx_id: uuid::Uuid) -> Option<String> {
    sqlx::query_scalar("SELECT user_category FROM transactions WHERE id = $1")
        .bind(tx_id)
        .fetch_one(pool)
        .await
        .expect("read tx category")
}

pub async fn tx_account(pool: &PgPool, tx_id: uuid::Uuid) -> uuid::Uuid {
    sqlx::query_scalar("SELECT account_id FROM transactions WHERE id = $1")
        .bind(tx_id)
        .fetch_one(pool)
        .await
        .expect("read tx account")
}

/// JSON body for the manual-edit PUT — same field set the create path
/// takes (the frontend reopens the add dialog and resubmits).
pub fn manual_edit_body(account: uuid::Uuid) -> Value {
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

/// True if a transaction row still exists (any owner).
pub async fn tx_exists(pool: &PgPool, tx_id: uuid::Uuid) -> bool {
    sqlx::query_scalar::<_, i64>("SELECT COUNT(*) FROM transactions WHERE id = $1")
        .bind(tx_id)
        .fetch_one(pool)
        .await
        .expect("count tx")
        > 0
}

/// Insert one transaction dated `days_ago` days back, so ordering
/// assertions don't depend on `created_at` insertion-order tiebreaks.
pub async fn seed_tx_days_ago(
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
pub async fn account_tx_descriptions(app: &Router, token: &str, uri: &str) -> Vec<String> {
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

/// Insert a transaction whose `created_at` (what the summary counts by,
/// as opposed to the bank's `date`) sits `hours_ago` in the past.
pub async fn seed_tx_created_hours_ago(
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

pub async fn since_last_login_body(app: &Router, token: &str) -> Value {
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

pub async fn seed_owner(pool: &PgPool, username: &str) -> (uuid::Uuid, String) {
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

/// Seed a transaction with an explicit date + amount + description.
/// Amount sign convention: negative = outflow, positive = inflow.
pub async fn seed_tx_dated(
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
pub async fn seed_tx_dated_cat(
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
pub async fn create_loan(app: &Router, token: &str, body: &Value) -> uuid::Uuid {
    let res = app
        .clone()
        .oneshot(req(Method::POST, "/api/loans", Some(body), Some(token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED, "create_loan should 201");
    let b = body_json(res.into_body()).await;
    uuid::Uuid::parse_str(b["id"].as_str().unwrap()).unwrap()
}

// Insert an expense with an explicit PFC category at a date relative to
// CURRENT_DATE (so the test is independent of the wall clock). `months_ago`
// counts whole calendar months back from today.
pub async fn seed_categorized_expense(
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

/// Set an app_settings key for the bootstrap user (used to drive the
/// reminder lead-days from the test).
pub async fn set_setting(pool: &PgPool, user_id: uuid::Uuid, key: &str, value: Value) {
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

/// Newest-first is not the order these assertions want; fetch the schedule
/// as the API returns it and index by installment.
pub async fn loan_payment_rows(app: &Router, token: &str, loan_id: uuid::Uuid) -> Vec<Value> {
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

/// Helper: GET a loan's payments list, returning the JSON array.
pub async fn loan_payments(app: &Router, token: &str, loan_id: uuid::Uuid) -> Value {
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

/// Insert a statement-imported transaction: `balance_after` + `import_file`
/// set, so it qualifies for the continuity report's balance-chaining scan.
pub async fn seed_imported_tx(
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

/// Read a (non-JSON) body as UTF-8 text — for the CSV exporters.
pub async fn body_text(body: Body) -> String {
    let bytes = to_bytes(body, 1024 * 1024).await.expect("read body");
    String::from_utf8(bytes.to_vec()).expect("utf-8 body")
}

/// Seed an investment-ish account under an existing institution.
pub async fn seed_typed_account(
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
pub async fn seed_holding(
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
pub async fn seed_close(pool: &PgPool, symbol: &str, days_ago: i32, close: &str) {
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

/// Seed one dated, categorized transaction (for the C-D payment matcher).
pub async fn seed_dividend_tx(
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

/// Seed a (holding, disposal) pair in an account; returns nothing. P&L and
/// dates are caller-chosen so tests can pin taxable vs advantaged sums.
pub async fn seed_disposal(
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

/// Seed the soft-delete lifecycle portfolio: NVDA (lot + two disposals across
/// two years) and VTI (one disposal), fresh closes for both plus the S&P so
/// no endpoint reaches for Yahoo. Returns (brokerage_id, nvda_holding_id).
pub async fn seed_soft_delete_portfolio(
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

/// Insert an institution + account with an explicit currency; returns the
/// account id.
pub async fn seed_account_currency(
    pool: &PgPool,
    user_id: uuid::Uuid,
    currency: &str,
) -> uuid::Uuid {
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
pub async fn seed_tx_currency(
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

/// Extract the `id` array from a `/dashboard/transactions` response body.
pub fn tx_ids(body: Value) -> Vec<String> {
    body.as_array()
        .unwrap()
        .iter()
        .filter_map(|r| r["id"].as_str().map(String::from))
        .collect()
}

/// Insert a transaction with an explicit currency dated `days_ago` days back.
/// Needed by the projection-defaults tests, which must place MXN cash flow in
/// two different months under two different stored FX rates.
pub async fn seed_tx_currency_days_ago(
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
pub async fn seed_fx_rate_days_ago(pool: &PgPool, rate: &str, days_ago: i32) {
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
pub fn assert_two_dp(v: f64, field: &str) {
    let scaled = v * 100.0;
    assert!(
        (scaled - scaled.round()).abs() < 1e-6,
        "{field} = {v} has more than 2 decimal places"
    );
}

/// Seed one institution of a given integration type + sync status. Returns
/// its id. Used by the async-sync tests below.
pub async fn seed_inst(
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

pub async fn sync_status_of(pool: &PgPool, id: uuid::Uuid) -> String {
    sqlx::query_scalar("SELECT sync_status FROM institutions WHERE id = $1")
        .bind(id)
        .fetch_one(pool)
        .await
        .expect("read sync_status")
}
