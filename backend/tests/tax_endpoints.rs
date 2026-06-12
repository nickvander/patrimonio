//! HTTP-level integration tests for the tax endpoints (T1–T5 of the tax
//! backlog): income predicates matching the stored category taxonomy
//! (sync.rs PFC `'INCOME'`/`'INCOME_*'`, categorize.rs `'INCOME'`,
//! `user_category` overrides in both directions), exclusion of
//! tax-advantaged-account disposals from taxable capital gains, per-row FX
//! normalization of mixed-currency income into separate USD and MXN bases
//! before bracket math, year-keyed bracket tables + standard deduction with
//! the `constants_verified` gate (T4), and ST/LT capital-loss netting with
//! the capped ordinary offset, carryforward, and unknown-term-as-short-term
//! classification (T5), and persistence of Plaid cash dividends / brokerage
//! interest at sync with the dividends/interest/wages decomposition of
//! ordinary income (T6).
//!
//! Like the sibling suites, these need a real Postgres reachable via
//! `PATRIMONIO_TEST_DATABASE_URL`. When the env var is unset the tests
//! print a skip note and return so `cargo test` stays green without a DB.
//!
//! Schema is reset between tests via `TRUNCATE ... RESTART IDENTITY
//! CASCADE`; cross-binary serialisation is handled by the advisory lock
//! in tests/common/mod.rs.

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

/// Build the protected router exactly like dashboard_endpoints.rs does so
/// the tests run through the production middleware stack.
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
         loan_payments, loans, people, \
         cash_fx_transfers, ignored_subscription_merchants, \
         exchange_rates, benchmark_prices, lot_disposals, holding_lots, holdings, \
         auth_audit, user_sessions, app_settings, \
         transactions, balance_snapshots, accounts, institutions, \
         users RESTART IDENTITY CASCADE",
    )
    .execute(&pool)
    .await
    .expect("truncate tax-test tables");

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
        plaid_webhook_url: None,
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

    let public = Router::new()
        .nest("/api/auth", patrimonio::api::session::public_router())
        .nest("/api/setup", patrimonio::api::setup::router());

    let business = Router::new()
        .nest("/api/tax", patrimonio::api::tax::router())
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
            "(skipping: set {TEST_DB_VAR}=postgres://user:pass@host/db to enable tax integration tests)"
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

/// Seed one institution + one account of the given `account_type`. The type
/// string is stored verbatim so case-insensitivity of the advantaged-subtype
/// match can be exercised (the migration normalizes to lowercase, but the
/// predicate must not depend on that).
async fn seed_typed_account(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_type: &str,
) -> uuid::Uuid {
    let inst_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ('Test Bank', 'bank', 'US', 'manual', 'ok', $1) RETURNING id",
    )
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed institution");
    sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, $2, $3, 'USD', 1000.00, $4) RETURNING id",
    )
    .bind(inst_id)
    .bind(format!("{account_type} account"))
    .bind(account_type)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed account")
}

/// Insert one categorized transaction with the full taxonomy triple
/// (category, category_detailed, user_category) in the given currency.
#[allow(clippy::too_many_arguments)]
async fn seed_categorized_tx_in(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    date: &str,
    description: &str,
    amount: &str,
    currency: &str,
    category: Option<&str>,
    category_detailed: Option<&str>,
    user_category: Option<&str>,
) {
    sqlx::query(
        "INSERT INTO transactions \
         (account_id, date, description, amount, currency, category, category_detailed, user_category, source, user_id) \
         VALUES ($1, $2::date, $3, $4, $5, $6, $7, $8, 'manual', $9)",
    )
    .bind(account_id)
    .bind(date)
    .bind(description)
    .bind(Decimal::from_str(amount).unwrap())
    .bind(currency)
    .bind(category)
    .bind(category_detailed)
    .bind(user_category)
    .bind(user_id)
    .execute(pool)
    .await
    .expect("seed categorized tx");
}

/// USD-denominated shorthand for [`seed_categorized_tx_in`].
#[allow(clippy::too_many_arguments)]
async fn seed_categorized_tx(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    date: &str,
    description: &str,
    amount: &str,
    category: Option<&str>,
    category_detailed: Option<&str>,
    user_category: Option<&str>,
) {
    seed_categorized_tx_in(
        pool, user_id, account_id, date, description, amount, "USD", category,
        category_detailed, user_category,
    )
    .await;
}

/// Store one USD→MXN rate effective at midnight UTC of `recorded_on`.
async fn seed_usd_mxn_rate(pool: &PgPool, recorded_on: &str, rate: &str) {
    sqlx::query(
        "INSERT INTO exchange_rates (base_currency, target_currency, rate, recorded_at) \
         VALUES ('USD', 'MXN', $1, $2::date::timestamptz)",
    )
    .bind(Decimal::from_str(rate).unwrap())
    .bind(recorded_on)
    .execute(pool)
    .await
    .expect("seed usd/mxn rate");
}

/// Seed holding + lot + one disposal sold on 2026-06-01 with the given
/// realized P&L in the given account. Returns nothing — the summary/CSV
/// assertions read the aggregates.
async fn seed_disposal(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    symbol: &str,
    acquired_at: &str,
    source_tag: &str,
    pnl: &str,
) {
    seed_disposal_dated(
        pool, user_id, account_id, symbol, acquired_at, "2026-06-01", source_tag, pnl,
    )
    .await;
}

/// [`seed_disposal`] with an explicit sell date (for term-boundary tests).
#[allow(clippy::too_many_arguments)]
async fn seed_disposal_dated(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    symbol: &str,
    acquired_at: &str,
    sell_date: &str,
    source_tag: &str,
    pnl: &str,
) {
    // Name deliberately differs from the symbol so CSV occurrence-count
    // assertions on the symbol stay meaningful.
    let holding_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, user_id) \
         VALUES ($1, $2, 'Fund', 'USD', $3) RETURNING id",
    )
    .bind(account_id)
    .bind(symbol)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .unwrap();
    let lot_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1,$2,$3,$4::date,10,60,'USD',1.0,$5) RETURNING id",
    )
    .bind(holding_id)
    .bind(account_id)
    .bind(user_id)
    .bind(acquired_at)
    .bind(source_tag)
    .fetch_one(pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO lot_disposals \
         (user_id, holding_id, account_id, lot_id, sell_source_id, qty_sold, sell_price_per_unit, \
          sell_currency, sell_fx_rate, sell_date, cost_per_unit, cost_fx_rate, realized_pnl_usd) \
         VALUES ($1,$2,$3,$4,$5,10,100,'USD',1.0,$6::date,60,1.0,$7)",
    )
    .bind(user_id)
    .bind(holding_id)
    .bind(account_id)
    .bind(lot_id)
    .bind(format!("sell-{source_tag}"))
    .bind(sell_date)
    .bind(Decimal::from_str(pnl).unwrap())
    .execute(pool)
    .await
    .unwrap();
}

/// Seed a disposal whose source lot is GONE (`lot_id` NULL — the column is
/// `ON DELETE SET NULL`, so this is what a deleted lot leaves behind): the
/// acquisition date, and therefore the holding period, is unknown.
async fn seed_unknown_term_disposal(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    symbol: &str,
    pnl: &str,
) {
    let holding_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, user_id) \
         VALUES ($1, $2, 'Fund', 'USD', $3) RETURNING id",
    )
    .bind(account_id)
    .bind(symbol)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO lot_disposals \
         (user_id, holding_id, account_id, lot_id, sell_source_id, qty_sold, sell_price_per_unit, \
          sell_currency, sell_fx_rate, sell_date, cost_per_unit, cost_fx_rate, realized_pnl_usd) \
         VALUES ($1,$2,$3,NULL,$4,10,100,'USD',1.0,'2026-06-01',60,1.0,$5)",
    )
    .bind(user_id)
    .bind(holding_id)
    .bind(account_id)
    .bind(format!("sell-{symbol}"))
    .bind(Decimal::from_str(pnl).unwrap())
    .execute(pool)
    .await
    .unwrap();
}

// =====================================================================
// T1 — income predicates match the stored taxonomy + user overrides
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn tax_summary_and_transactions_match_stored_income_taxonomy() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let acct = seed_typed_account(&pool, user_id, "depository").await;

    // sync.rs-shaped: Plaid PFC primary + detailed.
    seed_categorized_tx(
        &pool, user_id, acct, "2026-02-13", "ACME CORP PAYROLL", "5000.00",
        Some("INCOME"), Some("INCOME_WAGES"), None,
    )
    .await;
    // categorize.rs-shaped: statement import, primary only.
    seed_categorized_tx(
        &pool, user_id, acct, "2026-03-15", "ABONO NOMINA QUINCENA 1", "1000.00",
        Some("INCOME"), None, None,
    )
    .await;
    // user override opting IN: auto-category is not income, user said Income.
    seed_categorized_tx(
        &pool, user_id, acct, "2026-04-01", "SIDE GIG TRANSFER", "250.00",
        Some("TRANSFER_IN"), None, Some("Income"),
    )
    .await;
    // user override opting OUT: sync said wages, user reclassified.
    seed_categorized_tx(
        &pool, user_id, acct, "2026-05-20", "REIMBURSED EXPENSE", "9999.00",
        Some("INCOME"), Some("INCOME_WAGES"), Some("TRANSFER_IN"),
    )
    .await;
    // noise: ordinary spending must not count.
    seed_categorized_tx(
        &pool, user_id, acct, "2026-05-21", "GROCERIES REFUND", "40.00",
        Some("FOOD_AND_DRINK"), Some("FOOD_AND_DRINK_GROCERIES"), None,
    )
    .await;

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

    // 5000 + 1000 + 250 (opt-in), NOT the 9999 opt-out or the groceries.
    assert!(
        (body["ordinary_income"].as_f64().unwrap() - 6250.0).abs() < 0.01,
        "ordinary_income: {}",
        body["ordinary_income"]
    );
    // No lot disposals and no phantom 'Investment Sale' fallback: zero gains.
    assert_eq!(body["gains_from_lots"], serde_json::json!(false));
    assert!((body["capital_gains"].as_f64().unwrap()).abs() < 0.01);
    assert!((body["tax_advantaged_gains"].as_f64().unwrap()).abs() < 0.01);
    // T4 expectation update: this used to assert a positive liability because
    // the pre-T4 math taxed from dollar zero. $6,250 of income sits entirely
    // under the (unverified) 2026 single standard deduction → $0.
    assert!(
        (body["estimated_liability_us"].as_f64().unwrap()).abs() < 0.01,
        "income below the standard deduction should owe $0, got {}",
        body["estimated_liability_us"]
    );
    assert_eq!(body["bracket_year_used"], serde_json::json!(2026));
    assert_eq!(body["constants_verified"], serde_json::json!(false));

    // The taxable-transactions list returns exactly the three income rows.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/tax/transactions?year=2026",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().expect("array of transactions");
    let descriptions: Vec<&str> = rows
        .iter()
        .map(|r| r["description"].as_str().unwrap())
        .collect();
    assert_eq!(rows.len(), 3, "rows: {descriptions:?}");
    assert!(descriptions.contains(&"ACME CORP PAYROLL"));
    assert!(descriptions.contains(&"ABONO NOMINA QUINCENA 1"));
    assert!(descriptions.contains(&"SIDE GIG TRANSFER"));
    assert!(!descriptions.contains(&"REIMBURSED EXPENSE"));
}

// =====================================================================
// T2 — tax-advantaged accounts excluded from taxable capital gains
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn tax_summary_excludes_tax_advantaged_disposals() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;

    let brokerage = seed_typed_account(&pool, user_id, "brokerage").await;
    let k401 = seed_typed_account(&pool, user_id, "401k").await;
    // Uppercase on purpose: the match must be case-insensitive.
    let hsa = seed_typed_account(&pool, user_id, "HSA").await;

    // Taxable: one short-term (acquired 2026 → ≤1yr) and one long-term lot.
    seed_disposal(&pool, user_id, brokerage, "VTI", "2026-01-01", "st", "500").await;
    seed_disposal(&pool, user_id, brokerage, "VXUS", "2022-01-01", "lt", "3000").await;
    // Identical-shape disposals inside wrappers: must contribute zero.
    seed_disposal(&pool, user_id, k401, "RETF", "2022-01-01", "401k", "7000").await;
    seed_disposal(&pool, user_id, hsa, "HLTH", "2022-01-01", "hsa", "777").await;

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
    assert!(
        (body["short_term_gains"].as_f64().unwrap() - 500.0).abs() < 0.01,
        "short_term_gains: {}",
        body["short_term_gains"]
    );
    assert!(
        (body["long_term_gains"].as_f64().unwrap() - 3000.0).abs() < 0.01,
        "long_term_gains: {}",
        body["long_term_gains"]
    );
    assert!((body["capital_gains"].as_f64().unwrap() - 3500.0).abs() < 0.01);
    // The excluded activity is visible in its own field, not silently hidden.
    assert!(
        (body["tax_advantaged_gains"].as_f64().unwrap() - 7777.0).abs() < 0.01,
        "tax_advantaged_gains: {}",
        body["tax_advantaged_gains"]
    );
    // Liability is computed off the taxable 3,500 only — and T4's standard
    // deduction now absorbs the $500 ST gain entirely (pre-T4 this was ~$50
    // because brackets applied from dollar zero); the $3,000 LT gain sits in
    // the 0% LTCG band. The point of this test is unchanged: the 7,777 of
    // wrapper gains must not leak into the liability.
    assert!(
        (body["estimated_liability_us"].as_f64().unwrap()).abs() < 0.01,
        "expected $0 US liability, got {}",
        body["estimated_liability_us"]
    );
}

#[tokio::test]
#[serial_test::serial]
async fn tax_csv_separates_tax_advantaged_section_from_8949() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;

    let brokerage = seed_typed_account(&pool, user_id, "brokerage").await;
    let k401 = seed_typed_account(&pool, user_id, "401k").await;
    seed_disposal(&pool, user_id, brokerage, "VTI", "2022-01-01", "lt", "3000").await;
    seed_disposal(&pool, user_id, k401, "RETF", "2022-01-01", "401k", "7000").await;

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
    let bytes = to_bytes(res.into_body(), 1024 * 256).await.unwrap();
    let csv = String::from_utf8(bytes.to_vec()).unwrap();

    let taxable_at = csv
        .find("Realized capital gains (lot disposals)")
        .expect("8949 section present");
    let advantaged_at = csv
        .find("Tax-advantaged account disposals (excluded from taxable gains)")
        .expect("advantaged section present");
    assert!(taxable_at < advantaged_at, "8949 section comes first");

    // The 401k disposal appears ONLY in the advantaged section; the brokerage
    // one ONLY in the 8949 section.
    let retf_at = csv.find("RETF").expect("RETF row present");
    assert!(
        retf_at > advantaged_at,
        "RETF must not appear in the 8949 section:\n{csv}"
    );
    assert_eq!(csv.matches("RETF").count(), 1, "csv:\n{csv}");
    let vti_at = csv.find("VTI").expect("VTI row present");
    assert!(vti_at < advantaged_at, "VTI belongs to the 8949 section");
    assert_eq!(csv.matches("VTI").count(), 1, "csv:\n{csv}");
    // The advantaged section labels the wrapper type.
    assert!(csv.contains("401k"), "account type column populated");

    // Summary block: taxable LT only + the labeled excluded figure.
    assert!(csv.contains("Long-term gains (USD),3000.00"), "csv:\n{csv}");
    assert!(csv.contains("Total capital gains (USD),3000.00"), "csv:\n{csv}");
    assert!(
        csv.contains("Tax-advantaged gains, excluded (USD),7000.00"),
        "csv:\n{csv}"
    );
    assert!(csv.contains("Precise lot disposals"), "basis note kept");
}

// =====================================================================
// T3 — mixed-currency income is normalized per row before bracket math
// =====================================================================

/// Fetch /api/tax/summary as JSON.
async fn fetch_summary(app: &Router, token: &str) -> Value {
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/tax/summary?year=2026&status=Single",
            None,
            Some(token),
        ))
        .await
        .unwrap();
    let status = res.status();
    let body = body_json(res.into_body()).await;
    assert_eq!(status, StatusCode::OK, "tax summary body: {body}");
    body
}

/// Assert no money field in the summary is the raw mixed-currency blend —
/// the pre-T3 bug summed MXN and USD amounts as bare numbers.
fn assert_no_raw_blend(body: &Value, blend: f64) {
    for field in [
        "ordinary_income",
        "ordinary_income_mxn",
        "total_taxable",
        "total_taxable_mxn",
        "estimated_liability_us",
        "estimated_liability_mx",
        "estimated_liability_mx_mxn",
    ] {
        let v = body[field].as_f64().unwrap_or_else(|| {
            panic!("field {field} missing from summary: {body}")
        });
        assert!(
            (v - blend).abs() > 1.0,
            "{field} = {v} equals the raw mixed-currency blend {blend}"
        );
    }
}

#[tokio::test]
#[serial_test::serial]
async fn tax_summary_normalizes_mixed_currency_income_per_row() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let acct = seed_typed_account(&pool, user_id, "depository").await;

    // One stored rate, in effect before both transactions.
    seed_usd_mxn_rate(&pool, "2026-01-10", "17.5").await;
    seed_categorized_tx_in(
        &pool, user_id, acct, "2026-02-01", "US CONSULTING WIRE", "5000.00", "USD",
        Some("INCOME"), Some("INCOME_WAGES"), None,
    )
    .await;
    seed_categorized_tx_in(
        &pool, user_id, acct, "2026-03-01", "ABONO NOMINA MXN", "50000.00", "MXN",
        Some("INCOME"), None, None,
    )
    .await;

    let body = fetch_summary(&app, &token).await;

    // USD base: 5,000 + 50,000 / 17.5 = 7,857.142857…
    let usd_base = 5000.0 + 50000.0 / 17.5;
    assert!(
        (body["ordinary_income"].as_f64().unwrap() - usd_base).abs() < 0.01,
        "ordinary_income: {} (want {usd_base})",
        body["ordinary_income"]
    );
    // MXN base: 50,000 + 5,000 × 17.5 = 137,500.
    let mxn_base = 50000.0 + 5000.0 * 17.5;
    assert!(
        (body["ordinary_income_mxn"].as_f64().unwrap() - mxn_base).abs() < 0.01,
        "ordinary_income_mxn: {} (want {mxn_base})",
        body["ordinary_income_mxn"]
    );
    // The old bug: SUM(amount) over mixed currencies = 55,000. Nowhere.
    assert_no_raw_blend(&body, 55000.0);

    // No gains: taxable totals equal the income bases.
    assert!((body["total_taxable"].as_f64().unwrap() - usd_base).abs() < 0.01);
    assert!((body["total_taxable_mxn"].as_f64().unwrap() - mxn_base).abs() < 0.01);
    // Year-level rate = the only stored rate.
    assert!((body["usd_mxn_rate_used"].as_f64().unwrap() - 17.5).abs() < 1e-6);

    // MX liability: tarifa over the MXN base. T4 replaced the unmatched
    // in-file tarifa with the (still UNVERIFIED) annual tarifa believed in
    // force since 2023: 137,500 lands in the 16% row (133,536.08–155,229.80,
    // cuota fija 10,723.55), then ÷ 17.5 for the USD mirror field.
    let mx_mxn = 10723.55 + (mxn_base - 133536.07) * 0.16;
    assert!(
        (body["estimated_liability_mx_mxn"].as_f64().unwrap() - mx_mxn).abs() < 0.5,
        "estimated_liability_mx_mxn: {} (want {mx_mxn})",
        body["estimated_liability_mx_mxn"]
    );
    assert!(
        (body["estimated_liability_mx"].as_f64().unwrap() - mx_mxn / 17.5).abs() < 0.5,
        "estimated_liability_mx: {}",
        body["estimated_liability_mx"]
    );

    // Per-row reconciliation: each /tax/transactions row carries amount_usd
    // at its own date's rate, and the rows sum to the USD headline.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/tax/transactions?year=2026",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().expect("array of transactions");
    assert_eq!(rows.len(), 2);
    let sum_usd: f64 = rows.iter().map(|r| r["amount_usd"].as_f64().unwrap()).sum();
    assert!((sum_usd - usd_base).abs() < 0.01, "rows sum {sum_usd} != headline {usd_base}");
    let mxn_row = rows
        .iter()
        .find(|r| r["currency"] == "MXN")
        .expect("MXN row present");
    assert!((mxn_row["amount"].as_f64().unwrap() - 50000.0).abs() < 0.01);
    assert!((mxn_row["amount_usd"].as_f64().unwrap() - 50000.0 / 17.5).abs() < 0.01);

    // CSV: per-row USD column + both bases + both MX liability units labeled.
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
    let bytes = to_bytes(res.into_body(), 1024 * 256).await.unwrap();
    let csv = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(csv.contains("Amount (USD)"), "csv:\n{csv}");
    assert!(csv.contains("Ordinary income (USD),7857.14"), "csv:\n{csv}");
    assert!(csv.contains("Ordinary income (MXN),137500.00"), "csv:\n{csv}");
    assert!(
        csv.contains("Estimated liability — MX SAT (MXN)"),
        "csv:\n{csv}"
    );
    assert!(
        csv.contains("USD/MXN rate used for year-level conversions,17.5"),
        "csv:\n{csv}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn tax_income_uses_each_rows_own_date_rate() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let acct = seed_typed_account(&pool, user_id, "depository").await;

    // The rate moves mid-year; each row must use the rate in effect on ITS
    // date (nearest stored rate on-or-before), not one blanket rate.
    seed_usd_mxn_rate(&pool, "2026-01-10", "17.5").await;
    seed_usd_mxn_rate(&pool, "2026-06-15", "20.0").await;
    // 17,500 MXN at 17.5 → 1,000 USD.
    seed_categorized_tx_in(
        &pool, user_id, acct, "2026-02-01", "NOMINA FEB", "17500.00", "MXN",
        Some("INCOME"), None, None,
    )
    .await;
    // 20,000 MXN at 20.0 → 1,000 USD.
    seed_categorized_tx_in(
        &pool, user_id, acct, "2026-07-01", "NOMINA JUL", "20000.00", "MXN",
        Some("INCOME"), None, None,
    )
    .await;

    let body = fetch_summary(&app, &token).await;
    assert!(
        (body["ordinary_income"].as_f64().unwrap() - 2000.0).abs() < 0.01,
        "each row should use its own date's rate; got {}",
        body["ordinary_income"]
    );
    assert!((body["ordinary_income_mxn"].as_f64().unwrap() - 37500.0).abs() < 0.01);
    // Year-level conversions use the latest on-or-before Dec 31 rate.
    assert!((body["usd_mxn_rate_used"].as_f64().unwrap() - 20.0).abs() < 1e-6);
}

#[tokio::test]
#[serial_test::serial]
async fn tax_income_missing_dated_rate_falls_back_to_latest_stored() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let acct = seed_typed_account(&pool, user_id, "depository").await;

    // The only stored rate postdates both transactions → no on-or-before
    // match; the lookup must fall back to the latest stored rate, never to
    // adding the raw amounts.
    seed_usd_mxn_rate(&pool, "2026-12-01", "18.0").await;
    seed_categorized_tx_in(
        &pool, user_id, acct, "2026-02-01", "US WIRE", "5000.00", "USD",
        Some("INCOME"), Some("INCOME_WAGES"), None,
    )
    .await;
    seed_categorized_tx_in(
        &pool, user_id, acct, "2026-02-02", "NOMINA MXN", "50000.00", "MXN",
        Some("INCOME"), None, None,
    )
    .await;

    let body = fetch_summary(&app, &token).await;
    let usd_base = 5000.0 + 50000.0 / 18.0;
    assert!(
        (body["ordinary_income"].as_f64().unwrap() - usd_base).abs() < 0.01,
        "ordinary_income: {} (want {usd_base})",
        body["ordinary_income"]
    );
    assert!(
        (body["ordinary_income_mxn"].as_f64().unwrap() - (50000.0 + 5000.0 * 18.0)).abs() < 0.01
    );
    assert_no_raw_blend(&body, 55000.0);
}

#[tokio::test]
#[serial_test::serial]
async fn tax_income_with_no_stored_rates_uses_ballpark_never_raw_sum() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let acct = seed_typed_account(&pool, user_id, "depository").await;

    // Empty exchange_rates: the documented hard fallback is the 20.0
    // ballpark (same constant sync.rs uses) — magnitudes stay sane and the
    // raw MXN+USD blend can never reappear.
    seed_categorized_tx_in(
        &pool, user_id, acct, "2026-02-01", "US WIRE", "5000.00", "USD",
        Some("INCOME"), Some("INCOME_WAGES"), None,
    )
    .await;
    seed_categorized_tx_in(
        &pool, user_id, acct, "2026-02-02", "NOMINA MXN", "50000.00", "MXN",
        Some("INCOME"), None, None,
    )
    .await;

    let body = fetch_summary(&app, &token).await;
    assert!(
        (body["ordinary_income"].as_f64().unwrap() - 7500.0).abs() < 0.01,
        "ordinary_income: {} (want 5,000 + 50,000/20)",
        body["ordinary_income"]
    );
    assert!((body["ordinary_income_mxn"].as_f64().unwrap() - 150000.0).abs() < 0.01);
    assert!((body["usd_mxn_rate_used"].as_f64().unwrap() - 20.0).abs() < 1e-6);
    assert_no_raw_blend(&body, 55000.0);
}

// =====================================================================
// T4 — standard deduction through the endpoint + verification gate
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn tax_summary_subtracts_standard_deduction_before_brackets() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let acct = seed_typed_account(&pool, user_id, "depository").await;

    seed_categorized_tx(
        &pool, user_id, acct, "2026-02-13", "ACME CORP PAYROLL", "50000.00",
        Some("INCOME"), Some("INCOME_WAGES"), None,
    )
    .await;

    let body = fetch_summary(&app, &token).await;
    // 2026 Single (UNVERIFIED tables): 50,000 − 16,100 deduction = 33,900
    // taxable → 12,400×10% + 21,500×12% = 1,240 + 2,580 = 3,820. The pre-T4
    // math taxed the full 50,000 from dollar zero.
    assert!(
        (body["estimated_liability_us"].as_f64().unwrap() - 3820.0).abs() < 0.01,
        "estimated_liability_us: {}",
        body["estimated_liability_us"]
    );
    assert!(
        (body["standard_deduction_used"].as_f64().unwrap() - 16100.0).abs() < 0.01,
        "standard_deduction_used: {}",
        body["standard_deduction_used"]
    );
    assert_eq!(body["bracket_year_used"], serde_json::json!(2026));
    assert_eq!(body["constants_verified"], serde_json::json!(false));
    assert!((body["capital_loss_carryforward"].as_f64().unwrap()).abs() < 0.01);
}

#[tokio::test]
#[serial_test::serial]
async fn tax_summary_unknown_year_reports_nearest_bracket_year() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, _user_id) = bootstrap(&app, &pool).await;

    // 2023 has no table: the response must say which year's tables were used
    // (nearest = 2025) instead of silently pretending 2023 constants exist.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/tax/summary?year=2023&status=Single",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let status = res.status();
    let body = body_json(res.into_body()).await;
    assert_eq!(status, StatusCode::OK, "tax summary body: {body}");
    assert_eq!(body["bracket_year_used"], serde_json::json!(2025));
    assert_eq!(body["constants_verified"], serde_json::json!(false));
}

// =====================================================================
// T5 — netting, capped offset + carryforward, unknown-term-as-short
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn tax_summary_nets_losses_caps_ordinary_offset_and_reports_carryforward() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let depo = seed_typed_account(&pool, user_id, "depository").await;
    let brokerage = seed_typed_account(&pool, user_id, "brokerage").await;

    seed_categorized_tx(
        &pool, user_id, depo, "2026-02-13", "ACME CORP PAYROLL", "50000.00",
        Some("INCOME"), Some("INCOME_WAGES"), None,
    )
    .await;
    // ST loss −5,000 (acquired Jan 2026, sold Jun 2026) + LT loss −2,000.
    seed_disposal(&pool, user_id, brokerage, "STL", "2026-01-02", "stl", "-5000").await;
    seed_disposal(&pool, user_id, brokerage, "LTL", "2022-01-01", "ltl", "-2000").await;

    let body = fetch_summary(&app, &token).await;
    // Raw buckets are reported un-netted.
    assert!((body["short_term_gains"].as_f64().unwrap() + 5000.0).abs() < 0.01);
    assert!((body["long_term_gains"].as_f64().unwrap() + 2000.0).abs() < 0.01);
    // Net capital loss 7,000 → 3,000 (capped) offsets ordinary income, the
    // pre-T5 code would have subtracted the whole 5,000 ST loss uncapped AND
    // dropped the LT loss. Liability: 50,000 − 3,000 − 16,100 = 30,900 →
    // 12,400×10% + 18,500×12% = 3,460 on the unverified 2026 tables.
    assert!(
        (body["estimated_liability_us"].as_f64().unwrap() - 3460.0).abs() < 0.01,
        "estimated_liability_us: {}",
        body["estimated_liability_us"]
    );
    // The other 4,000 of loss is the carryforward, not silently gone.
    assert!(
        (body["capital_loss_carryforward"].as_f64().unwrap() - 4000.0).abs() < 0.01,
        "capital_loss_carryforward: {}",
        body["capital_loss_carryforward"]
    );
}

#[tokio::test]
#[serial_test::serial]
async fn tax_summary_st_loss_offsets_lt_gain_through_endpoint() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let brokerage = seed_typed_account(&pool, user_id, "brokerage").await;

    seed_disposal(&pool, user_id, brokerage, "STL", "2026-01-02", "stl", "-20000").await;
    seed_disposal(&pool, user_id, brokerage, "LTG", "2022-01-01", "ltg", "80000").await;

    let body = fetch_summary(&app, &token).await;
    // Surviving LT gain = 60,000; taxable ordinary = 0 (no income), so the
    // gain stacks from 0: 49,450 in the 0% band, 10,550 at 15% = 1,582.50
    // (unverified 2026 single tables). The pre-T5 code would also have pushed
    // the raw −20,000 into ordinary income.
    assert!(
        (body["estimated_liability_us"].as_f64().unwrap() - 1582.50).abs() < 0.01,
        "estimated_liability_us: {}",
        body["estimated_liability_us"]
    );
    assert!((body["capital_loss_carryforward"].as_f64().unwrap()).abs() < 0.01);
}

#[tokio::test]
#[serial_test::serial]
async fn tax_unknown_acquisition_counts_short_term_but_exports_say_unknown() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let brokerage = seed_typed_account(&pool, user_id, "brokerage").await;

    seed_unknown_term_disposal(&pool, user_id, brokerage, "MYST", "1000").await;

    let body = fetch_summary(&app, &token).await;
    // Unknown holding period lands in the SHORT-term (higher-rate) bucket —
    // the pre-T5 code put it in long-term and called that "conservative".
    assert!(
        (body["short_term_gains"].as_f64().unwrap() - 1000.0).abs() < 0.01,
        "short_term_gains: {}",
        body["short_term_gains"]
    );
    assert!((body["long_term_gains"].as_f64().unwrap()).abs() < 0.01);

    // …while the CSV keeps the honest "Unknown" term label for the row.
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
    let bytes = to_bytes(res.into_body(), 1024 * 256).await.unwrap();
    let csv = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(csv.contains("MYST"), "csv:\n{csv}");
    assert!(csv.contains("Unknown"), "term label kept, csv:\n{csv}");
    assert!(csv.contains("Short-term gains (USD),1000.00"), "csv:\n{csv}");
    // T4/T5 summary lines.
    assert!(csv.contains("Capital-loss carryforward (USD),0.00"), "csv:\n{csv}");
    assert!(csv.contains("Bracket year used,2026"), "csv:\n{csv}");
    assert!(
        csv.contains("Tax constants verified,no - pending human verification"),
        "csv:\n{csv}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn tax_term_boundary_is_calendar_year_not_day_count() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let brokerage = seed_typed_account(&pool, user_id, "brokerage").await;

    // Exact anniversary across a leap day: 2023-06-01 → 2024-06-01 is 366
    // days, which the old `> 365 days` rule classified long-term. The
    // calendar rule says "more than one year" — sale ON the anniversary is
    // still short-term.
    seed_disposal_dated(
        &pool, user_id, brokerage, "ANNIV", "2023-06-01", "2024-06-01", "anniv", "700",
    )
    .await;
    // One day later: long-term.
    seed_disposal_dated(
        &pool, user_id, brokerage, "DAYAFTER", "2023-06-01", "2024-06-02", "after", "300",
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/tax/summary?year=2024&status=Single",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let status = res.status();
    let body = body_json(res.into_body()).await;
    assert_eq!(status, StatusCode::OK, "tax summary body: {body}");
    assert!(
        (body["short_term_gains"].as_f64().unwrap() - 700.0).abs() < 0.01,
        "short_term_gains: {}",
        body["short_term_gains"]
    );
    assert!(
        (body["long_term_gains"].as_f64().unwrap() - 300.0).abs() < 0.01,
        "long_term_gains: {}",
        body["long_term_gains"]
    );
    // 2024 has no bracket table; nearest is 2025 and the response says so.
    assert_eq!(body["bracket_year_used"], serde_json::json!(2025));
}

// =====================================================================
// T6 — Plaid cash dividends / interest persisted at sync + the
//      dividends/interest/wages decomposition of ordinary income
// =====================================================================

/// Stamp a Plaid-style external id onto a seeded account so the sync
/// engine's `account_id` lookup can find it.
async fn set_account_external_id(pool: &PgPool, account_id: uuid::Uuid, external_id: &str) {
    sqlx::query("UPDATE accounts SET external_id = $1 WHERE id = $2")
        .bind(external_id)
        .bind(account_id)
        .execute(pool)
        .await
        .expect("set account external_id");
}

#[tokio::test]
#[serial_test::serial]
async fn tax_summary_decomposes_dividend_and_interest_income() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let acct = seed_typed_account(&pool, user_id, "depository").await;

    seed_usd_mxn_rate(&pool, "2026-01-10", "20.0").await;
    // Wage row (sync.rs PFC shape).
    seed_categorized_tx(
        &pool, user_id, acct, "2026-02-13", "ACME CORP PAYROLL", "5000.00",
        Some("INCOME"), Some("INCOME_WAGES"), None,
    )
    .await;
    // USD dividend + MXN dividend (the decomposition must reuse the same
    // per-row LATERAL FX rule as the headline: 2,000 MXN / 20 = 100 USD).
    seed_categorized_tx(
        &pool, user_id, acct, "2026-03-15", "VTI DIVIDEND", "800.00",
        Some("INCOME"), Some("INCOME_DIVIDENDS"), None,
    )
    .await;
    seed_categorized_tx_in(
        &pool, user_id, acct, "2026-04-01", "DIVIDENDO FONDO MX", "2000.00", "MXN",
        Some("INCOME"), Some("INCOME_DIVIDENDS"), None,
    )
    .await;
    // Interest row.
    seed_categorized_tx(
        &pool, user_id, acct, "2026-05-01", "BROKERAGE INTEREST", "200.00",
        Some("INCOME"), Some("INCOME_INTEREST_EARNED"), None,
    )
    .await;
    // A dividend the user reclassified away must vanish from EVERY bucket
    // (the predicate excludes it before the decomposition CASEs run).
    seed_categorized_tx(
        &pool, user_id, acct, "2026-05-02", "RETURN OF CAPITAL", "999.00",
        Some("INCOME"), Some("INCOME_DIVIDENDS"), Some("TRANSFER_IN"),
    )
    .await;

    let body = fetch_summary(&app, &token).await;
    let f = |k: &str| body[k].as_f64().unwrap_or_else(|| panic!("{k} missing: {body}"));

    // Buckets: wages 5,000; dividends 800 + 100; interest 200.
    assert!((f("wage_income") - 5000.0).abs() < 0.01, "wage_income: {body}");
    assert!((f("dividend_income") - 900.0).abs() < 0.01, "dividend_income: {body}");
    assert!((f("interest_income") - 200.0).abs() < 0.01, "interest_income: {body}");
    // Decomposition is exact — the parts re-sum to the bracket input, so
    // nothing is double-counted (the 999 opt-out is in no bucket at all).
    assert!((f("ordinary_income") - 6100.0).abs() < 0.01, "ordinary_income: {body}");
    assert!(
        (f("wage_income") + f("dividend_income") + f("interest_income") - f("ordinary_income"))
            .abs()
            < 1e-9,
        "decomposition must re-sum to ordinary_income: {body}"
    );
    assert!((f("total_taxable") - 6100.0).abs() < 0.01);
    // Bracket math input unchanged: 6,100 sits under the 2026 single
    // standard deduction → $0 liability, same as an all-wages 6,100.
    assert!(f("estimated_liability_us").abs() < 0.01, "liability: {body}");

    // CSV shows the decomposition under the ordinary-income line.
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
    let bytes = to_bytes(res.into_body(), 1024 * 256).await.unwrap();
    let csv = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(csv.contains("Ordinary income (USD),6100.00"), "csv:\n{csv}");
    assert!(
        csv.contains("  of which wages & other income (USD),5000.00"),
        "csv:\n{csv}"
    );
    assert!(csv.contains("  of which dividends (USD),900.00"), "csv:\n{csv}");
    assert!(csv.contains("  of which interest (USD),200.00"), "csv:\n{csv}");
}

#[tokio::test]
#[serial_test::serial]
async fn plaid_investment_income_events_persist_idempotently() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let acct = seed_typed_account(&pool, user_id, "brokerage").await;
    set_account_external_id(&pool, acct, "plaid-brokerage-1").await;

    // Plaid investments sign convention: positive = cash OUT of the account,
    // so a received dividend / interest payment arrives negative.
    let dividend_ev = serde_json::json!({
        "investment_transaction_id": "ivt-div-1",
        "account_id": "plaid-brokerage-1",
        "security_id": "sec-vti",
        "type": "cash",
        "subtype": "dividend",
        "date": "2026-03-15",
        "name": "VTI CASH DIVIDEND",
        "amount": -125.50,
        "quantity": 0.0,
        "iso_currency_code": "USD"
    });
    // Interest events routinely carry NO security_id (cash sleeve) — the old
    // code's security-id guard silently dropped them.
    let interest_ev = serde_json::json!({
        "investment_transaction_id": "ivt-int-1",
        "account_id": "plaid-brokerage-1",
        "security_id": null,
        "type": "cash",
        "subtype": "interest",
        "date": "2026-04-02",
        "name": "CREDIT INTEREST",
        "amount": -30.25,
        "quantity": 0.0,
        "iso_currency_code": "USD"
    });
    // Must NOT become income rows: a fee, and a dividend reinvestment (the
    // latter is a share event that belongs to the lot path).
    let fee_ev = serde_json::json!({
        "investment_transaction_id": "ivt-fee-1",
        "account_id": "plaid-brokerage-1",
        "security_id": null,
        "type": "fee",
        "subtype": "management fee",
        "date": "2026-04-03",
        "name": "ADVISORY FEE",
        "amount": 12.00,
        "quantity": 0.0,
        "iso_currency_code": "USD"
    });
    let reinvest_ev = serde_json::json!({
        "investment_transaction_id": "ivt-drip-1",
        "account_id": "plaid-brokerage-1",
        "security_id": "sec-vti",
        "type": "cash",
        "subtype": "dividend reinvestment",
        "date": "2026-04-04",
        "name": "VTI DRIP",
        "amount": -50.00,
        "quantity": 0.2,
        "iso_currency_code": "USD"
    });

    // Process the whole window TWICE — the re-sync of the same payloads must
    // upsert in place, not duplicate.
    for _ in 0..2 {
        for ev in [&dividend_ev, &interest_ev, &fee_ev, &reinvest_ev] {
            patrimonio::services::sync::process_investment_event(&pool, ev, user_id)
                .await
                .expect("process investment event");
        }
    }

    let rows: Vec<(String, rust_decimal::Decimal, Option<String>, Option<String>, String)> =
        sqlx::query_as(
            "SELECT external_id, amount, category, category_detailed, source \
             FROM transactions WHERE user_id = $1 ORDER BY external_id",
        )
        .bind(user_id)
        .fetch_all(&pool)
        .await
        .expect("read transactions");

    // Exactly one row per income event; nothing for the fee or the DRIP.
    assert_eq!(
        rows.len(),
        2,
        "expected exactly the dividend + interest rows, got: {rows:?}"
    );
    let div = rows.iter().find(|r| r.0 == "ivt-div-1").expect("dividend row");
    let int = rows.iter().find(|r| r.0 == "ivt-int-1").expect("interest row");
    // Sign: Plaid −125.50 (cash in) → app +125.50 (inflow), so the income
    // predicate's `amount > 0` filter sees it.
    assert_eq!(div.1, Decimal::from_str("125.50").unwrap());
    assert_eq!(div.2.as_deref(), Some("INCOME"));
    assert_eq!(div.3.as_deref(), Some("INCOME_DIVIDENDS"));
    assert_eq!(div.4, "plaid");
    assert_eq!(int.1, Decimal::from_str("30.25").unwrap());
    assert_eq!(int.3.as_deref(), Some("INCOME_INTEREST_EARNED"));

    // A re-sync where Plaid amended the amount updates the same row.
    let mut amended = dividend_ev.clone();
    amended["amount"] = serde_json::json!(-130.00);
    patrimonio::services::sync::process_investment_event(&pool, &amended, user_id)
        .await
        .expect("process amended event");
    let (n, amount): (i64, rust_decimal::Decimal) = sqlx::query_as(
        "SELECT COUNT(*), MAX(amount) FROM transactions WHERE external_id = 'ivt-div-1'",
    )
    .fetch_one(&pool)
    .await
    .expect("recount dividend row");
    assert_eq!(n, 1, "amended re-sync must not duplicate");
    assert_eq!(amount, Decimal::from_str("130.00").unwrap());

    // End to end: the synced rows surface in the tax summary's new lines
    // (T1's INCOME predicate picks them up automatically) and inside the
    // ordinary-income total that feeds the brackets.
    let body = fetch_summary(&app, &token).await;
    assert!(
        (body["dividend_income"].as_f64().unwrap() - 130.00).abs() < 0.01,
        "dividend_income: {body}"
    );
    assert!(
        (body["interest_income"].as_f64().unwrap() - 30.25).abs() < 0.01,
        "interest_income: {body}"
    );
    assert!(
        (body["wage_income"].as_f64().unwrap()).abs() < 0.01,
        "wage_income: {body}"
    );
    assert!(
        (body["ordinary_income"].as_f64().unwrap() - 160.25).abs() < 0.01,
        "ordinary_income: {body}"
    );
}
