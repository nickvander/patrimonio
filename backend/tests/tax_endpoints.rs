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
// T14 follow-up — CETES interest itemizes as interest_income; ISR
// withholding is excluded from income and totalled in isr_withheld_*.
// These mirror exactly what the cetesdirecto parsers now stamp through the
// statement-import path: a yield credit tagged
// (category='INCOME', category_detailed='INCOME_INTEREST_EARNED'), and an
// ISR retention tagged (category='GOVERNMENT_AND_NON_PROFIT',
// category_detailed='TAX_ISR_WITHHELD') on a negative (outflow) amount.
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn cetes_interest_lands_in_interest_income_not_wages() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let acct = seed_typed_account(&pool, user_id, "depository").await;
    seed_usd_mxn_rate(&pool, "2026-01-01", "20.0").await;

    // A CETES yield credit as the parser now stamps it (MXN, positive inflow).
    seed_categorized_tx_in(
        &pool, user_id, acct, "2026-06-01", "PREMIO CETES 260601", "2000.00", "MXN",
        Some("INCOME"), Some("INCOME_INTEREST_EARNED"), None,
    )
    .await;
    // A plain payroll row so wage_income is non-zero and the split is visible.
    seed_categorized_tx_in(
        &pool, user_id, acct, "2026-06-02", "ACME PAYROLL", "5000.00", "USD",
        Some("INCOME"), Some("INCOME_WAGES"), None,
    )
    .await;

    let body = fetch_summary(&app, &token).await;

    // 2,000 MXN / 20 = 100 USD of interest; it must land in interest_income,
    // NOT in the wage residual.
    assert!(
        (body["interest_income"].as_f64().unwrap() - 100.0).abs() < 0.01,
        "interest_income: {} (want 100)",
        body["interest_income"]
    );
    assert!(
        (body["wage_income"].as_f64().unwrap() - 5000.0).abs() < 0.01,
        "wage_income: {} (want 5000, CETES yield must not leak here)",
        body["wage_income"]
    );
    // Decomposition still re-sums to ordinary_income (100 + 5000).
    assert!((body["ordinary_income"].as_f64().unwrap() - 5100.0).abs() < 0.01);
    assert!((body["dividend_income"].as_f64().unwrap()).abs() < 0.01);
}

#[tokio::test]
#[serial_test::serial]
async fn isr_withholding_excluded_from_income_and_totalled() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let acct = seed_typed_account(&pool, user_id, "depository").await;
    seed_usd_mxn_rate(&pool, "2026-01-01", "20.0").await;

    // CETES yield (income) + the ISR the broker retained on it (an outflow,
    // tagged TAX_ISR_WITHHELD with a NON-income category).
    seed_categorized_tx_in(
        &pool, user_id, acct, "2026-06-01", "PREMIO CETES 260601", "2000.00", "MXN",
        Some("INCOME"), Some("INCOME_INTEREST_EARNED"), None,
    )
    .await;
    seed_categorized_tx_in(
        &pool, user_id, acct, "2026-06-01", "RETENCION ISR CETES", "-200.00", "MXN",
        Some("GOVERNMENT_AND_NON_PROFIT"), Some("TAX_ISR_WITHHELD"), None,
    )
    .await;

    let body = fetch_summary(&app, &token).await;

    // Income is ONLY the 2,000 MXN yield (100 USD). The −200 ISR is excluded:
    // its category is not INCOME and its detail does not start with INCOME_.
    assert!(
        (body["ordinary_income"].as_f64().unwrap() - 100.0).abs() < 0.01,
        "ordinary_income: {} (ISR must not count as income)",
        body["ordinary_income"]
    );
    assert!((body["interest_income"].as_f64().unwrap() - 100.0).abs() < 0.01);

    // Withheld total = |−200 MXN| in both bases: 200 MXN, 10 USD (÷ 20).
    assert!(
        (body["isr_withheld_mxn"].as_f64().unwrap() - 200.0).abs() < 0.01,
        "isr_withheld_mxn: {} (want 200)",
        body["isr_withheld_mxn"]
    );
    assert!(
        (body["isr_withheld_usd"].as_f64().unwrap() - 10.0).abs() < 0.01,
        "isr_withheld_usd: {} (want 10)",
        body["isr_withheld_usd"]
    );

    // It is informational only — the MX liability is NOT reduced by it. With
    // 100 USD = 2,000 MXN of income (well under the lowest tarifa step that
    // produces a cuota), the liability is whatever the tarifa yields, and the
    // withheld total is reported alongside, never subtracted in.
    assert!(body["estimated_liability_mx_mxn"].as_f64().is_some());
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
    // The label contains a comma, so the CSV writer (correctly, per RFC 4180)
    // quotes the field.
    assert!(
        csv.contains("\"Tax-advantaged gains, excluded (USD)\",7000.00"),
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

// =====================================================================
// T7 — realized disposals as JSON via GET /tax/disposals
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn tax_disposals_endpoint_returns_rows_newest_first_with_advantaged_flag() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;

    let brokerage = seed_typed_account(&pool, user_id, "brokerage").await;
    let k401 = seed_typed_account(&pool, user_id, "401k").await;

    // Two taxable disposals on different sell dates (to assert ordering) plus
    // one inside a 401k wrapper — the endpoint returns ALL of them, flagged.
    seed_disposal_dated(
        &pool, user_id, brokerage, "VTI", "2026-01-01", "2026-03-01", "early", "500",
    )
    .await;
    seed_disposal_dated(
        &pool, user_id, brokerage, "VXUS", "2022-01-01", "2026-09-01", "late", "3000",
    )
    .await;
    seed_disposal_dated(
        &pool, user_id, k401, "RETF", "2022-01-01", "2026-05-01", "wrap", "7000",
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/tax/disposals?year=2026",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let status = res.status();
    let body = body_json(res.into_body()).await;
    assert_eq!(status, StatusCode::OK, "disposals body: {body}");
    let rows = body.as_array().expect("array of disposals");
    assert_eq!(rows.len(), 3, "all disposals returned, taxable + wrapper: {body}");

    // Newest sell_date first.
    let dates: Vec<&str> = rows.iter().map(|r| r["sell_date"].as_str().unwrap()).collect();
    assert_eq!(dates, vec!["2026-09-01", "2026-05-01", "2026-03-01"], "{body}");

    // Field shape the frontend depends on, checked on the first (VXUS, LT)
    // taxable row: symbol, dates, term, proceeds/basis/signed gain (USD),
    // flags. Proceeds = 10×100 = 1000, basis = 10×60 = 600 (seed_disposal).
    let vxus = rows.iter().find(|r| r["symbol"] == "VXUS").expect("VXUS row");
    assert_eq!(vxus["acquired_date"], serde_json::json!("2022-01-01"));
    assert_eq!(vxus["sell_date"], serde_json::json!("2026-09-01"));
    assert_eq!(vxus["long_term"], serde_json::json!(true), "VXUS is long-term");
    assert!((vxus["proceeds_usd"].as_f64().unwrap() - 1000.0).abs() < 0.01, "{body}");
    assert!((vxus["cost_usd"].as_f64().unwrap() - 600.0).abs() < 0.01, "{body}");
    assert!((vxus["gain_usd"].as_f64().unwrap() - 3000.0).abs() < 0.01, "{body}");
    assert_eq!(vxus["tax_advantaged"], serde_json::json!(false));
    assert_eq!(vxus["from_lots"], serde_json::json!(true));

    let vti = rows.iter().find(|r| r["symbol"] == "VTI").expect("VTI row");
    assert_eq!(vti["long_term"], serde_json::json!(false), "VTI is short-term");

    // The wrapper disposal is present but flagged tax_advantaged + carries its
    // account type, so the screen can separate it — consistent with the
    // summary, which excludes it from taxable gains.
    let retf = rows.iter().find(|r| r["symbol"] == "RETF").expect("RETF row");
    assert_eq!(retf["tax_advantaged"], serde_json::json!(true), "{body}");
    assert_eq!(retf["account_type"], serde_json::json!("401k"), "{body}");

    // Reconcile with the summary: taxable ST=500, LT=3000; the 7000 wrapper
    // gain sits in tax_advantaged_gains, NOT capital_gains — exactly the split
    // the disposals' flags express.
    let summary = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/tax/summary?year=2026&status=Single",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let summary = body_json(summary.into_body()).await;
    let taxable_gain: f64 = rows
        .iter()
        .filter(|r| !r["tax_advantaged"].as_bool().unwrap())
        .map(|r| r["gain_usd"].as_f64().unwrap())
        .sum();
    assert!(
        (taxable_gain - summary["capital_gains"].as_f64().unwrap()).abs() < 0.01,
        "taxable disposal gains must reconcile with summary capital_gains"
    );
    let adv_gain: f64 = rows
        .iter()
        .filter(|r| r["tax_advantaged"].as_bool().unwrap())
        .map(|r| r["gain_usd"].as_f64().unwrap())
        .sum();
    assert!(
        (adv_gain - summary["tax_advantaged_gains"].as_f64().unwrap()).abs() < 0.01,
        "wrapper disposal gains must reconcile with summary tax_advantaged_gains"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn tax_disposals_endpoint_empty_when_no_lots() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, _user_id) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/tax/disposals?year=2026",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body.as_array().expect("array").len(), 0, "no disposals: {body}");
}

// =====================================================================
// T9 — filing-status default read from the persisted setting
// =====================================================================

/// Persist the filing status the way the frontend's `setSetting` would — a
/// JSON string under the `tax_filing_status` key, scoped to the user (mirrors
/// settings.rs's INSERT ... ON CONFLICT).
async fn seed_filing_status_setting(pool: &PgPool, user_id: uuid::Uuid, status: &str) {
    sqlx::query(
        "INSERT INTO app_settings (user_id, key, value, updated_at) \
         VALUES ($1, 'tax_filing_status', $2, NOW()) \
         ON CONFLICT (user_id, key) DO UPDATE SET value = EXCLUDED.value, updated_at = NOW()",
    )
    .bind(user_id)
    .bind(serde_json::Value::String(status.to_string()))
    .execute(pool)
    .await
    .expect("seed filing-status setting");
}

#[tokio::test]
#[serial_test::serial]
async fn tax_summary_defaults_filing_status_from_persisted_setting() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let acct = seed_typed_account(&pool, user_id, "depository").await;

    // $50,000 wages. Single vs. Married diverge through the standard
    // deduction AND the bracket widths, so the resolved status is observable
    // in estimated_liability_us.
    seed_categorized_tx(
        &pool, user_id, acct, "2026-02-13", "ACME CORP PAYROLL", "50000.00",
        Some("INCOME"), Some("INCOME_WAGES"), None,
    )
    .await;

    // Persist "Married".
    seed_filing_status_setting(&pool, user_id, "Married").await;

    // No status query param → must pick up the persisted "Married".
    // 2026 Married (UNVERIFIED): 50,000 − 32,200 deduction = 17,800 taxable;
    // all under the 24,800 10% bracket → 1,780.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/tax/summary?year=2026", None, Some(&token)))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert!(
        (body["standard_deduction_used"].as_f64().unwrap() - 32200.0).abs() < 0.01,
        "persisted Married deduction expected, got {body}"
    );
    assert!(
        (body["estimated_liability_us"].as_f64().unwrap() - 1780.0).abs() < 0.01,
        "persisted Married liability expected, got {body}"
    );

    // An explicit query param still WINS over the persisted setting.
    // Single 2026: 50,000 − 16,100 = 33,900 → 12,400×10% + 21,500×12% = 3,820.
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
    let body = body_json(res.into_body()).await;
    assert!(
        (body["standard_deduction_used"].as_f64().unwrap() - 16100.0).abs() < 0.01,
        "query param Single must override persisted Married, got {body}"
    );
    assert!(
        (body["estimated_liability_us"].as_f64().unwrap() - 3820.0).abs() < 0.01,
        "query param Single liability expected, got {body}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn tax_summary_falls_back_to_single_with_no_setting() {
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

    // Neither a query param NOR a persisted setting → hardcoded Single default.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/tax/summary?year=2026", None, Some(&token)))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert!(
        (body["standard_deduction_used"].as_f64().unwrap() - 16100.0).abs() < 0.01,
        "absent setting must fall back to Single, got {body}"
    );
    assert!(
        (body["estimated_liability_us"].as_f64().unwrap() - 3820.0).abs() < 0.01,
        "Single fallback liability expected, got {body}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn tax_csv_export_honors_persisted_filing_status() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;

    // A direct CSV link carries no status param; the persisted setting must
    // still flow into the "Filing status" header line.
    seed_filing_status_setting(&pool, user_id, "Head of Household").await;

    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/tax/export?year=2026", None, Some(&token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let bytes = to_bytes(res.into_body(), 1024 * 256).await.unwrap();
    let csv = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(
        csv.contains("Filing status,Head of Household"),
        "CSV should reflect persisted status, csv:\n{csv}"
    );
}

// =====================================================================
// T11 — unrealized per-lot view, days-to-long-term, harvest candidates
// =====================================================================

/// Seed a holding with a current per-unit `price` and ONE owned lot (qty > 0)
/// acquired on `acquired_at` at `cost_per_unit` (USD). Returns the holding id
/// so a "recent buy" lot can be added to the same holding for wash-sale tests.
#[allow(clippy::too_many_arguments)]
async fn seed_unrealized_lot(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    symbol: &str,
    acquired_at: &str,
    qty: &str,
    cost_per_unit: &str,
    current_price: &str,
) -> uuid::Uuid {
    let holding_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, quantity, price, currency, user_id) \
         VALUES ($1, $2, 'Fund', $3, $4, 'USD', $5) RETURNING id",
    )
    .bind(account_id)
    .bind(symbol)
    .bind(Decimal::from_str(qty).unwrap())
    .bind(Decimal::from_str(current_price).unwrap())
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed unrealized holding");
    sqlx::query(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1,$2,$3,$4::date,$5,$6,'USD',1.0,$7)",
    )
    .bind(holding_id)
    .bind(account_id)
    .bind(user_id)
    .bind(acquired_at)
    .bind(Decimal::from_str(qty).unwrap())
    .bind(Decimal::from_str(cost_per_unit).unwrap())
    .bind(format!("lot-{symbol}"))
    .execute(pool)
    .await
    .expect("seed unrealized lot");
    holding_id
}

/// Add another owned lot to an EXISTING holding acquired on `acquired_at` —
/// used to plant a "recent buy" inside the wash-sale window.
async fn seed_extra_lot(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    holding_id: uuid::Uuid,
    acquired_at: &str,
) {
    sqlx::query(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1,$2,$3,$4::date,1,50,'USD',1.0,$5)",
    )
    .bind(holding_id)
    .bind(account_id)
    .bind(user_id)
    .bind(acquired_at)
    .bind(format!("rebuy-{}", uuid::Uuid::new_v4()))
    .execute(pool)
    .await
    .expect("seed extra lot");
}

/// Fetch /api/tax/unrealized as JSON.
async fn fetch_unrealized(app: &Router, token: &str) -> Value {
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/tax/unrealized?status=Single",
            None,
            Some(token),
        ))
        .await
        .unwrap();
    let status = res.status();
    let body = body_json(res.into_body()).await;
    assert_eq!(status, StatusCode::OK, "unrealized body: {body}");
    body
}

#[tokio::test]
#[serial_test::serial]
async fn tax_unrealized_signs_terms_excludes_tax_advantaged_and_flags_harvest() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let today = chrono::Utc::now().naive_utc().date();

    let brokerage = seed_typed_account(&pool, user_id, "brokerage").await;
    let k401 = seed_typed_account(&pool, user_id, "401k").await;

    // GAIN lot, long-term (acquired well over a year ago): qty 10, cost 50,
    // price 80 → cost 500, value 800, +300, LT.
    let acq_lt = (today - chrono::Duration::days(800)).to_string();
    seed_unrealized_lot(&pool, user_id, brokerage, "GAINLT", &acq_lt, "10", "50", "80").await;

    // LOSS lot, short-term (acquired 100 days ago): qty 10, cost 100,
    // price 70 → cost 1000, value 700, −300, ST. No recent buy → harvestable.
    let acq_st = (today - chrono::Duration::days(100)).to_string();
    seed_unrealized_lot(&pool, user_id, brokerage, "LOSSST", &acq_st, "10", "100", "70").await;

    // LOSS lot inside a 401k wrapper — must be EXCLUDED from the view entirely.
    seed_unrealized_lot(&pool, user_id, k401, "WRAP", &acq_st, "10", "100", "70").await;

    let body = fetch_unrealized(&app, &token).await;
    let lots = body["lots"].as_array().expect("array of lots");
    // Wrapper lot excluded → exactly the two taxable lots.
    assert_eq!(lots.len(), 2, "tax-advantaged lot must be excluded: {body}");
    assert!(
        !lots.iter().any(|l| l["symbol"] == "WRAP"),
        "401k lot leaked into the taxable view: {body}"
    );

    let gain = lots.iter().find(|l| l["symbol"] == "GAINLT").expect("gain lot");
    assert!((gain["cost_basis_usd"].as_f64().unwrap() - 500.0).abs() < 0.01, "{body}");
    assert!((gain["current_value_usd"].as_f64().unwrap() - 800.0).abs() < 0.01, "{body}");
    assert!((gain["unrealized_gain_usd"].as_f64().unwrap() - 300.0).abs() < 0.01, "{body}");
    assert_eq!(gain["long_term"], serde_json::json!(true), "{body}");
    // Already long-term → no days_until / savings / wash fields.
    assert!(gain["days_until_long_term"].is_null(), "{body}");
    assert!(gain["estimated_tax_savings_usd"].is_null(), "gains aren't harvest candidates: {body}");
    assert_eq!(gain["wash_sale_risk"], serde_json::json!(false));

    let loss = lots.iter().find(|l| l["symbol"] == "LOSSST").expect("loss lot");
    assert!((loss["unrealized_gain_usd"].as_f64().unwrap() + 300.0).abs() < 0.01, "signed loss: {body}");
    assert_eq!(loss["long_term"], serde_json::json!(false), "{body}");
    // Short lot reports days_until_long_term + the flip date. Acquired 100
    // days ago → ~266 days left (1yr + 1 day − 100). Allow slack for the
    // calendar-month arithmetic.
    let days = loss["days_until_long_term"].as_i64().expect("days present");
    assert!((260..=270).contains(&days), "days_until_long_term={days}: {body}");
    assert!(loss["long_term_date"].as_str().is_some(), "flip date present: {body}");
    // Harvest candidate: |−300| × the Single marginal ordinary rate. With no
    // ordinary income, taxable ordinary is 0 → lowest bracket (10%) → $30.
    // It rides the unverified tables, so just assert it's the loss × that rate.
    let rate = body["ordinary_marginal_rate"].as_f64().unwrap();
    let savings = loss["estimated_tax_savings_usd"].as_f64().expect("savings present");
    assert!((savings - 300.0 * rate).abs() < 0.01, "savings {savings} != 300×{rate}: {body}");
    // No recent same-holding buy → not a wash-sale risk.
    assert_eq!(loss["wash_sale_risk"], serde_json::json!(false), "{body}");

    // Subtotals + the verification gate ride through.
    assert!((body["long_term_gain"].as_f64().unwrap() - 300.0).abs() < 0.01, "{body}");
    assert!((body["short_term_gain"].as_f64().unwrap() + 300.0).abs() < 0.01, "{body}");
    assert_eq!(body["constants_verified"], serde_json::json!(false), "{body}");
}

#[tokio::test]
#[serial_test::serial]
async fn tax_unrealized_loss_with_recent_buy_flags_wash_sale_risk() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let today = chrono::Utc::now().naive_utc().date();
    let brokerage = seed_typed_account(&pool, user_id, "brokerage").await;

    // LOSS lot acquired 200 days ago; plus a SECOND buy of the SAME holding
    // 10 days ago — inside the ±30-day window around a contemplated sale
    // today → harvesting now is a wash-sale risk.
    let acq = (today - chrono::Duration::days(200)).to_string();
    let recent = (today - chrono::Duration::days(10)).to_string();
    let hid =
        seed_unrealized_lot(&pool, user_id, brokerage, "WASHME", &acq, "10", "100", "70").await;
    seed_extra_lot(&pool, user_id, brokerage, hid, &recent).await;

    let body = fetch_unrealized(&app, &token).await;
    let lots = body["lots"].as_array().expect("array");
    let washme = lots.iter().find(|l| l["symbol"] == "WASHME").expect("loss lot");
    assert_eq!(washme["wash_sale_risk"], serde_json::json!(true), "{body}");
    // safe_after = today + 31 days.
    let expected_safe = (today + chrono::Duration::days(31)).to_string();
    assert_eq!(
        washme["wash_sale_safe_after"].as_str().unwrap(),
        expected_safe,
        "{body}"
    );
    // Still a harvest candidate (savings present) — the flag is a warning, not
    // a removal.
    assert!(washme["estimated_tax_savings_usd"].as_f64().is_some(), "{body}");
}

// =====================================================================
// T12 — wash-sale detection on realized disposals
// =====================================================================

/// Seed a loss disposal of `symbol` sold on `sell_date`, and OPTIONALLY plant
/// a same-holding buy at `rebuy_at` (inside or outside the window). Returns the
/// holding id. Built on the existing disposal seeder, then adds the rebuy lot.
#[allow(clippy::too_many_arguments)]
async fn seed_loss_disposal_with_optional_rebuy(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    symbol: &str,
    acquired_at: &str,
    sell_date: &str,
    pnl: &str,
    rebuy_at: Option<&str>,
) {
    seed_disposal_dated(
        pool, user_id, account_id, symbol, acquired_at, sell_date, symbol, pnl,
    )
    .await;
    if let Some(rebuy) = rebuy_at {
        // The disposal seeder made a holding named 'Fund' with this symbol;
        // find it and attach a fresh buy lot.
        let hid: uuid::Uuid =
            sqlx::query_scalar("SELECT id FROM holdings WHERE symbol = $1 AND user_id = $2")
                .bind(symbol)
                .bind(user_id)
                .fetch_one(pool)
                .await
                .expect("find holding for rebuy");
        seed_extra_lot(pool, user_id, account_id, hid, rebuy).await;
    }
}

#[tokio::test]
#[serial_test::serial]
async fn tax_wash_sale_excludes_disallowed_loss_from_liability() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let depo = seed_typed_account(&pool, user_id, "depository").await;
    let brokerage = seed_typed_account(&pool, user_id, "brokerage").await;

    // Baseline ordinary income so a loss has something to offset.
    seed_categorized_tx(
        &pool, user_id, depo, "2026-02-13", "ACME CORP PAYROLL", "50000.00",
        Some("INCOME"), Some("INCOME_WAGES"), None,
    )
    .await;

    // WASH loss: −4,000 sold 2026-06-15 with a same-holding buy on 2026-06-20
    // (5 days later, inside the ±30-day window) → disallowed, must NOT reduce
    // the liability.
    seed_loss_disposal_with_optional_rebuy(
        &pool, user_id, brokerage, "WASH", "2026-01-02", "2026-06-15", "-4000",
        Some("2026-06-20"),
    )
    .await;

    let body = fetch_summary(&app, &token).await;
    // The disallowed loss is reported but kept out of the ST bucket: the only
    // ST contributor is wash → short_term_gains is 0, not −4,000.
    assert!(
        (body["short_term_gains"].as_f64().unwrap()).abs() < 0.01,
        "wash loss must be excluded from short_term_gains: {body}"
    );
    assert!(
        (body["wash_sale_disallowed_loss"].as_f64().unwrap() + 4000.0).abs() < 0.01,
        "disallowed loss reported (signed): {body}"
    );
    // Liability is the no-loss baseline: 50,000 − 16,100 = 33,900 →
    // 12,400×10% + 21,500×12% = 3,820 (unverified 2026 Single tables).
    assert!(
        (body["estimated_liability_us"].as_f64().unwrap() - 3820.0).abs() < 0.01,
        "wash loss must not reduce the liability: {body}"
    );
    assert!(
        (body["capital_loss_carryforward"].as_f64().unwrap()).abs() < 0.01,
        "a disallowed loss does not become a carryforward here: {body}"
    );

    // The disposal endpoint flags the row + gives the safe-after date.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/tax/disposals?year=2026", None, Some(&token)))
        .await
        .unwrap();
    let disp = body_json(res.into_body()).await;
    let row = disp.as_array().unwrap().iter().find(|r| r["symbol"] == "WASH").expect("WASH row");
    assert_eq!(row["wash_sale"], serde_json::json!(true), "{disp}");
    // safe-after = sell_date + 31: a buy on sell_date+30 is still inside the
    // inclusive window, so the first clear acquisition date is +31.
    assert_eq!(row["wash_sale_safe_after"], serde_json::json!("2026-07-16"), "{disp}");

    // The CSV 8949 section carries the wash-sale columns and the summary line.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/tax/export?year=2026&status=Single", None, Some(&token)))
        .await
        .unwrap();
    let bytes = to_bytes(res.into_body(), 1024 * 256).await.unwrap();
    let csv = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(csv.contains("Wash sale"), "wash-sale column header: \n{csv}");
    assert!(csv.contains("Safe to rebuy after"), "safe-after column header: \n{csv}");
    // Comma in the label → the CSV writer quotes the field (RFC 4180).
    assert!(
        csv.contains("\"Wash-sale disallowed loss (USD, excluded from liability)\",-4000.00"),
        "summary wash line: \n{csv}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn tax_non_wash_loss_reduces_liability_normally() {
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

    // The SAME −4,000 loss but with NO nearby buy (rebuy far outside the
    // window, in a different month) → allowed: 3,000 offsets ordinary income.
    seed_loss_disposal_with_optional_rebuy(
        &pool, user_id, brokerage, "CLEAN", "2026-01-02", "2026-06-15", "-4000",
        Some("2026-09-30"),
    )
    .await;

    let body = fetch_summary(&app, &token).await;
    assert!(
        (body["short_term_gains"].as_f64().unwrap() + 4000.0).abs() < 0.01,
        "clean loss stays in the ST bucket: {body}"
    );
    assert!(
        (body["wash_sale_disallowed_loss"].as_f64().unwrap()).abs() < 0.01,
        "no disallowed loss: {body}"
    );
    // 3,000 of the loss offsets ordinary income (capped): 50,000 − 3,000 −
    // 16,100 = 30,900 → 12,400×10% + 18,500×12% = 3,460; 1,000 carries forward.
    assert!(
        (body["estimated_liability_us"].as_f64().unwrap() - 3460.0).abs() < 0.01,
        "clean loss must reduce the liability: {body}"
    );
    assert!(
        (body["capital_loss_carryforward"].as_f64().unwrap() - 1000.0).abs() < 0.01,
        "{body}"
    );
}

// =====================================================================
// T13 — FBAR/FATCA threshold monitor
// =====================================================================

/// Seed an institution (with a country) + one account (with a currency),
/// returning the account id. Lets the FBAR foreign-account signal be exercised
/// in both directions (non-US country, and MXN currency under a US country).
async fn seed_account_with_country_currency(
    pool: &PgPool,
    user_id: uuid::Uuid,
    inst_name: &str,
    country: &str,
    acct_name: &str,
    currency: &str,
) -> uuid::Uuid {
    let inst_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ($1, 'bank', $2, 'manual', 'ok', $3) RETURNING id",
    )
    .bind(inst_name)
    .bind(country)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed institution");
    sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, $2, 'depository', $3, 0, $4) RETURNING id",
    )
    .bind(inst_id)
    .bind(acct_name)
    .bind(currency)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed account")
}

/// Seed a daily balance snapshot (with its USD value) for an account.
async fn seed_snapshot(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    as_of: &str,
    currency: &str,
    balance_usd: &str,
) {
    sqlx::query(
        "INSERT INTO balance_snapshots (account_id, balance, as_of_date, currency, balance_usd, user_id) \
         VALUES ($1, $2, $3::date, $4, $5, $6)",
    )
    .bind(account_id)
    .bind(Decimal::from_str(balance_usd).unwrap())
    .bind(as_of)
    .bind(currency)
    .bind(Decimal::from_str(balance_usd).unwrap())
    .bind(user_id)
    .execute(pool)
    .await
    .expect("seed snapshot");
}

#[tokio::test]
#[serial_test::serial]
async fn fbar_flags_aggregate_foreign_balance_crossing_10k() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;

    // Two foreign accounts: one by institution country (MX), one by MXN
    // currency under a US-country institution. Plus a US/USD account that must
    // NOT count toward the aggregate.
    let mx_bank = seed_account_with_country_currency(
        &pool, user_id, "Banamex", "MX", "Cuenta MXN", "MXN",
    )
    .await;
    let mxn_under_us = seed_account_with_country_currency(
        &pool, user_id, "Frontier US-MX", "US", "USD-labeled MXN", "MXN",
    )
    .await;
    let domestic = seed_account_with_country_currency(
        &pool, user_id, "Chase", "US", "Checking", "USD",
    )
    .await;

    // On 2026-03-10 the two foreign accounts sum to 6,000 + 5,000 = 11,000 USD
    // (> 10k). On other days they're lower. The domestic 50k must be ignored.
    seed_snapshot(&pool, user_id, mx_bank, "2026-03-10", "MXN", "6000").await;
    seed_snapshot(&pool, user_id, mxn_under_us, "2026-03-10", "MXN", "5000").await;
    seed_snapshot(&pool, user_id, mx_bank, "2026-02-01", "MXN", "4000").await;
    seed_snapshot(&pool, user_id, domestic, "2026-03-10", "USD", "50000").await;

    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/tax/fbar?year=2026", None, Some(&token)))
        .await
        .unwrap();
    let status = res.status();
    let body = body_json(res.into_body()).await;
    assert_eq!(status, StatusCode::OK, "fbar body: {body}");

    assert_eq!(body["exceeded"], serde_json::json!(true), "{body}");
    assert!(
        (body["peak_aggregate_usd"].as_f64().unwrap() - 11000.0).abs() < 0.01,
        "peak should be the 11,000 aggregate, not include the 50k domestic: {body}"
    );
    assert_eq!(body["peak_date"], serde_json::json!("2026-03-10"), "{body}");
    assert!((body["threshold_usd"].as_f64().unwrap() - 10000.0).abs() < 0.01);
    assert_eq!(body["constants_verified"], serde_json::json!(false));
    // Exactly the two foreign accounts, domestic excluded.
    let accts = body["foreign_accounts"].as_array().expect("array");
    assert_eq!(accts.len(), 2, "{body}");
    let names: Vec<&str> = accts
        .iter()
        .map(|a| a["name"].as_str().unwrap())
        .collect();
    assert!(names.contains(&"Cuenta MXN"));
    assert!(names.contains(&"USD-labeled MXN"));
    assert!(!names.contains(&"Checking"));
}

#[tokio::test]
#[serial_test::serial]
async fn fbar_below_threshold_and_empty_case() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;

    // No foreign accounts/snapshots yet → graceful empty case.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/tax/fbar?year=2026", None, Some(&token)))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert_eq!(body["exceeded"], serde_json::json!(false), "{body}");
    assert!((body["peak_aggregate_usd"].as_f64().unwrap()).abs() < 0.01);
    assert_eq!(body["peak_date"], Value::Null);
    assert!(body["foreign_accounts"].as_array().unwrap().is_empty());

    // One foreign account peaking at 8,000 (< 10k) → not exceeded.
    let mx_bank = seed_account_with_country_currency(
        &pool, user_id, "BBVA MX", "MX", "Cuenta", "MXN",
    )
    .await;
    seed_snapshot(&pool, user_id, mx_bank, "2026-05-01", "MXN", "8000").await;
    seed_snapshot(&pool, user_id, mx_bank, "2026-06-01", "MXN", "3000").await;

    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/tax/fbar?year=2026", None, Some(&token)))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert_eq!(body["exceeded"], serde_json::json!(false), "{body}");
    assert!(
        (body["peak_aggregate_usd"].as_f64().unwrap() - 8000.0).abs() < 0.01,
        "{body}"
    );
    assert_eq!(body["peak_date"], serde_json::json!("2026-05-01"));
    let accts = body["foreign_accounts"].as_array().unwrap();
    assert_eq!(accts.len(), 1);
    assert!((accts[0]["ytd_max_usd"].as_f64().unwrap() - 8000.0).abs() < 0.01);
}

// =====================================================================
// T15 — retirement-contribution tracking vs annual limits
// =====================================================================

/// Seed one lot buy (a contribution inflow) into `account_id`.
async fn seed_lot_buy(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    symbol: &str,
    acquired_at: &str,
    qty: &str,
    cost_per_unit: &str,
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
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1,$2,$3,$4::date,$5,$6,'USD',1.0,$7)",
    )
    .bind(holding_id)
    .bind(account_id)
    .bind(user_id)
    .bind(acquired_at)
    .bind(Decimal::from_str(qty).unwrap())
    .bind(Decimal::from_str(cost_per_unit).unwrap())
    .bind(format!("buy-{symbol}"))
    .execute(pool)
    .await
    .unwrap();
}

#[tokio::test]
#[serial_test::serial]
async fn retirement_contributions_sum_per_group_with_room_and_deadline() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;

    let k401 = seed_typed_account(&pool, user_id, "401k").await;
    let ira = seed_typed_account(&pool, user_id, "ira").await;
    let roth = seed_typed_account(&pool, user_id, "roth").await;
    let brokerage = seed_typed_account(&pool, user_id, "brokerage").await;

    // 401k: 100 units @ $50 = $5,000 contributed in 2026.
    seed_lot_buy(&pool, user_id, k401, "TDF", "2026-02-01", "100", "50").await;
    // IRA group is traditional + Roth aggregated: $2,000 + $1,500 = $3,500.
    seed_lot_buy(&pool, user_id, ira, "VTI", "2026-03-01", "20", "100").await;
    seed_lot_buy(&pool, user_id, roth, "VXUS", "2026-04-01", "30", "50").await;
    // A taxable brokerage buy must NOT count toward any retirement group.
    seed_lot_buy(&pool, user_id, brokerage, "AAPL", "2026-05-01", "10", "200").await;
    // A prior-year lot must not count toward 2026.
    seed_lot_buy(&pool, user_id, k401, "OLD", "2025-12-01", "100", "10").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/tax/contributions?year=2026",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let status = res.status();
    let body = body_json(res.into_body()).await;
    assert_eq!(status, StatusCode::OK, "contributions body: {body}");
    assert_eq!(body["constants_verified"], serde_json::json!(false));
    assert_eq!(body["limit_year_used"], serde_json::json!(2026));

    let groups = body["groups"].as_array().expect("groups array");
    let by_key = |k: &str| groups.iter().find(|g| g["group"] == k).expect("group present");

    let k = by_key("401k");
    assert!(
        (k["ytd_contributions_usd"].as_f64().unwrap() - 5000.0).abs() < 0.01,
        "401k YTD (2025 lot excluded): {k}"
    );
    // 2026 (unverified) base 24,500 → remaining 19,500.
    assert!((k["limit_base_usd"].as_f64().unwrap() - 24500.0).abs() < 0.01, "{k}");
    assert!((k["remaining_room_usd"].as_f64().unwrap() - 19500.0).abs() < 0.01, "{k}");
    assert!((k["catch_up_usd"].as_f64().unwrap() - 8000.0).abs() < 0.01, "{k}");
    // 401k deadline is the calendar-year end, not the prior-year window.
    assert_eq!(k["deadline"], serde_json::json!("2026-12-31"), "{k}");
    assert_eq!(k["prior_year_window"], serde_json::json!(false), "{k}");
    // Any contribution → match/rollover can't be ruled out.
    assert_eq!(k["match_rollover_caveat"], serde_json::json!(true), "{k}");

    let i = by_key("ira");
    assert!(
        (i["ytd_contributions_usd"].as_f64().unwrap() - 3500.0).abs() < 0.01,
        "IRA aggregates traditional + Roth: {i}"
    );
    // IRA uses the prior-year window → Apr 15 of the following year.
    assert_eq!(i["deadline"], serde_json::json!("2027-04-15"), "{i}");
    assert_eq!(i["prior_year_window"], serde_json::json!(true), "{i}");

    let h = by_key("hsa");
    // No HSA contributions → zero, full room, no caveat.
    assert!((h["ytd_contributions_usd"].as_f64().unwrap()).abs() < 0.01, "{h}");
    assert_eq!(h["match_rollover_caveat"], serde_json::json!(false), "{h}");
    assert_eq!(h["prior_year_window"], serde_json::json!(true), "{h}");
}

/// Detection rewrite: HSA contributions come from labeled CASH transactions
/// (HealthEquity has no tax-lots), reinvested dividends are NETTED out of
/// brokerage 401k/IRA contributions, and the response carries the new
/// §415(c)-overall / mega-backdoor / backdoor-Roth fields.
#[tokio::test]
#[serial_test::serial]
async fn retirement_detects_hsa_cash_nets_dividends_and_flags_backdoor_megabackdoor() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;

    // HSA: contributions are cash transactions, employer + employee both count.
    let hsa = seed_typed_account(&pool, user_id, "hsa").await;
    seed_categorized_tx_in(&pool, user_id, hsa, "2026-01-02", "Employee Contribution for 2026", "1000", "USD", None, None, None).await;
    seed_categorized_tx_in(&pool, user_id, hsa, "2026-01-02", "Employer Contribution for 2026", "500", "USD", None, None, None).await;
    // Noise that must NOT count as a contribution:
    seed_categorized_tx_in(&pool, user_id, hsa, "2026-01-31", "Interest for 1/1-1/31", "5", "USD", Some("INCOME"), Some("INCOME_INTEREST_EARNED"), None).await;
    seed_categorized_tx_in(&pool, user_id, hsa, "2026-01-02", "Investment: VFIFX", "-800", "USD", None, None, None).await;

    // Roth IRA: a $2,000 contribution lot + a $50 reinvested dividend to net out.
    // No Traditional IRA lots → looks like a backdoor Roth.
    let roth = seed_typed_account(&pool, user_id, "roth").await;
    seed_lot_buy(&pool, user_id, roth, "VXUS", "2026-03-01", "20", "100").await;
    seed_categorized_tx_in(&pool, user_id, roth, "2026-03-15", "Dividend", "50", "USD", Some("INCOME"), Some("INCOME_DIVIDENDS"), None).await;

    let res = app.clone().oneshot(req(Method::GET, "/api/tax/contributions?year=2026", None, Some(&token))).await.unwrap();
    let status = res.status();
    let body = body_json(res.into_body()).await;
    assert_eq!(status, StatusCode::OK, "contributions body: {body}");
    let groups = body["groups"].as_array().expect("groups");
    let by_key = |k: &str| groups.iter().find(|g| g["group"] == k).expect("group");

    // HSA: $1,000 + $500 from cash; interest + the internal investment move excluded.
    let h = by_key("hsa");
    assert!((h["ytd_contributions_usd"].as_f64().unwrap() - 1500.0).abs() < 0.01, "hsa from cash: {h}");
    assert!((h["employer_usd"].as_f64().unwrap() - 500.0).abs() < 0.01, "hsa employer split: {h}");
    assert!(h["overall_limit_usd"].as_f64().unwrap() > h["limit_base_usd"].as_f64().unwrap(), "hsa family>self: {h}");

    // IRA: $2,000 lot minus the $50 reinvested dividend = $1,950; flagged backdoor.
    let i = by_key("ira");
    assert!((i["ytd_contributions_usd"].as_f64().unwrap() - 1950.0).abs() < 0.01, "ira nets reinvested dividend: {i}");
    assert_eq!(i["backdoor"], serde_json::json!(true), "backdoor (roth funded, traditional empty): {i}");

    // 401k: §415(c) overall ($72k 2026) exceeds the elective base → mega-backdoor.
    let k = by_key("401k");
    assert!((k["overall_limit_usd"].as_f64().unwrap() - 72000.0).abs() < 0.01, "401k §415c overall: {k}");
    assert_eq!(k["mega_backdoor"], serde_json::json!(true), "mega-backdoor flag: {k}");
}
