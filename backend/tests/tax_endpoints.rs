//! HTTP-level integration tests for the tax endpoints (T1/T2 of the tax
//! backlog): income predicates matching the stored category taxonomy
//! (sync.rs PFC `'INCOME'`/`'INCOME_*'`, categorize.rs `'INCOME'`,
//! `user_category` overrides in both directions), and exclusion of
//! tax-advantaged-account disposals from taxable capital gains.
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
/// (category, category_detailed, user_category).
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
    sqlx::query(
        "INSERT INTO transactions \
         (account_id, date, description, amount, currency, category, category_detailed, user_category, source, user_id) \
         VALUES ($1, $2::date, $3, $4, 'USD', $5, $6, $7, 'manual', $8)",
    )
    .bind(account_id)
    .bind(date)
    .bind(description)
    .bind(Decimal::from_str(amount).unwrap())
    .bind(category)
    .bind(category_detailed)
    .bind(user_category)
    .bind(user_id)
    .execute(pool)
    .await
    .expect("seed categorized tx");
}

/// Seed holding + long-term lot + one disposal with the given realized P&L
/// in the given account. Returns nothing — the summary/CSV assertions read
/// the aggregates.
async fn seed_disposal(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    symbol: &str,
    acquired_at: &str,
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
         VALUES ($1,$2,$3,$4,$5,10,100,'USD',1.0,'2026-06-01',60,1.0,$6)",
    )
    .bind(user_id)
    .bind(holding_id)
    .bind(account_id)
    .bind(lot_id)
    .bind(format!("sell-{source_tag}"))
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
    assert!(body["estimated_liability_us"].as_f64().unwrap() > 0.0);

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
    // Liability is computed off the taxable 3,500 only: ST $500 at the 10%
    // bracket = $50, the $3,000 LT gain sits in the 0% LTCG band.
    assert!(
        (body["estimated_liability_us"].as_f64().unwrap() - 50.0).abs() < 0.5,
        "expected ~$50 US liability, got {}",
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
