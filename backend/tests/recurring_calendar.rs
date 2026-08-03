//! HTTP-level integration tests for `/api/recurring/calendar` — the bills
//! calendar + 1–90-day projected-balance feature: occurrence expansion,
//! expected↔posted matching states (paid / upcoming / late / missed /
//! pending_import), the per-currency projected cash curve (exact Decimal
//! assertions), the FX-transfer suggestion, the days clamp, and row-level
//! user scoping.
//!
//! Like the sibling suites, these need a real Postgres reachable via
//! `PATRIMONIO_TEST_DATABASE_URL`; when unset they print a skip note and
//! return (set-but-unreachable PANICS — see tests/common/mod.rs).

use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{header, HeaderValue, Method, Request, StatusCode};
use axum::middleware::from_fn_with_state;
use axum::Router;
use chrono::{Datelike, NaiveDate};
use serde_json::Value;
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
/// require_owner on business routes) around the recurring router,
/// mirroring main.rs's mounting.
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
         recurring_rules, loan_payments, loans, people, balance_snapshots, \
         transactions, accounts, institutions, exchange_rates, auth_audit, \
         user_sessions, app_settings, users RESTART IDENTITY CASCADE",
    )
    .execute(&pool)
    .await
    .expect("truncate calendar tables");

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

    let public = Router::new()
        .nest("/api/auth", patrimonio::api::session::public_router())
        .nest("/api/setup", patrimonio::api::setup::router());

    let business = Router::new()
        .nest("/api/recurring", patrimonio::api::recurring::router())
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
            "(skipping: set {TEST_DB_VAR}=postgres://user:pass@host/db to enable calendar integration tests)"
        );
    }
    result
}

async fn body_json(body: Body) -> Value {
    let bytes = to_bytes(body, 1024 * 512).await.expect("read body");
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

/// Build a request with cookie + CSRF header + JSON body (CSRF baked in
/// on mutating methods so a test can't forget it).
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

/// Bootstrap the first (owner) user; returns (cookie, user_id).
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

/// Seed one institution + one depository account. `integration_type`
/// distinguishes the synced ('plaid') vs statement-import ('manual') paths
/// the pending_import state hinges on.
async fn seed_account(
    pool: &PgPool,
    user_id: uuid::Uuid,
    name: &str,
    currency: &str,
    integration_type: &str,
) -> uuid::Uuid {
    let inst_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ($1, 'bank', 'US', $2, 'ok', $3) RETURNING id",
    )
    .bind(format!("{name} Bank"))
    .bind(integration_type)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed institution");
    sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, $2, 'checking', $3, 0, $4) RETURNING id",
    )
    .bind(inst_id)
    .bind(name)
    .bind(currency)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed account")
}

#[allow(clippy::too_many_arguments)] // fixture builder, mirrors loan_match's allow
async fn seed_rule(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    description: &str,
    amount: f64,
    currency: &str,
    cadence: &str,
    next_due: NaiveDate,
) {
    sqlx::query(
        "INSERT INTO recurring_rules \
         (user_id, account_id, description, amount, currency, cadence, anchor_day, next_due_date) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8)",
    )
    .bind(user_id)
    .bind(account_id)
    .bind(description)
    .bind(rust_decimal::Decimal::from_f64_retain(amount).unwrap())
    .bind(currency)
    .bind(cadence)
    .bind(next_due.day() as i16)
    .bind(next_due)
    .execute(pool)
    .await
    .expect("seed rule");
}

async fn seed_tx(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    date: NaiveDate,
    amount: f64,
    currency: &str,
    description: &str,
) -> uuid::Uuid {
    sqlx::query_scalar(
        "INSERT INTO transactions (account_id, user_id, date, description, amount, currency) \
         VALUES ($1, $2, $3, $4, $5, $6) RETURNING id",
    )
    .bind(account_id)
    .bind(user_id)
    .bind(date)
    .bind(description)
    .bind(rust_decimal::Decimal::from_f64_retain(amount).unwrap())
    .bind(currency)
    .fetch_one(pool)
    .await
    .expect("seed transaction")
}

async fn seed_snapshot(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    date: NaiveDate,
    balance: f64,
    currency: &str,
) {
    let dec = rust_decimal::Decimal::from_f64_retain(balance).unwrap();
    sqlx::query(
        "INSERT INTO balance_snapshots (account_id, user_id, balance, as_of_date, currency, balance_usd) \
         VALUES ($1, $2, $3, $4, $5, $3)",
    )
    .bind(account_id)
    .bind(user_id)
    .bind(dec)
    .bind(date)
    .bind(currency)
    .execute(pool)
    .await
    .expect("seed snapshot");
}

async fn get_calendar(app: &Router, cookie: &str, days: i64) -> Value {
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/recurring/calendar?days={days}"),
            None,
            Some(cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "calendar should 200");
    body_json(res.into_body()).await
}

/// Find the occurrence for `description` due on `date`, panicking with the
/// whole payload on a miss so failures are diagnosable.
fn occurrence<'a>(json: &'a Value, description: &str, date: &str) -> &'a Value {
    json["occurrences"]
        .as_array()
        .expect("occurrences array")
        .iter()
        .find(|o| o["description"] == description && o["due_date"] == date)
        .unwrap_or_else(|| panic!("no occurrence {description} @ {date} in {json}"))
}

#[tokio::test]
#[serial_test::serial]
async fn calendar_states_matching_and_exact_projection() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    let today = chrono::Utc::now().date_naive();
    let d = |offset: i64| today + chrono::Duration::days(offset);

    // Latest USD→MXN rate = 20 so per-row conversions are eyeball-able.
    sqlx::query(
        "INSERT INTO exchange_rates (base_currency, target_currency, rate, recorded_at, source) \
         VALUES ('USD', 'MXN', 20.0, NOW(), 'api')",
    )
    .execute(&pool)
    .await
    .expect("seed rate");

    // A Plaid-synced USD checking account and a manual statement-import
    // MXN account (the pending_import fixture).
    let plaid_usd = seed_account(&pool, user_id, "Chase", "USD", "plaid").await;
    let manual_mxn = seed_account(&pool, user_id, "BBVA", "MXN", "manual").await;

    // Starting balances via the LATEST snapshot per account (the older
    // plaid snapshot proves latest-wins carry-forward, not a sum).
    seed_snapshot(&pool, user_id, plaid_usd, d(-30), 500.0, "USD").await;
    seed_snapshot(&pool, user_id, plaid_usd, d(-1), 1000.0, "USD").await;
    seed_snapshot(&pool, user_id, manual_mxn, d(-2), 5000.0, "MXN").await;

    // Rules — yearly cadence everywhere so each contributes EXACTLY ONE
    // occurrence to the ±30-day window and the curve is deterministic
    // regardless of what today's calendar month looks like:
    //   Gym       −50 USD due d-10, matched by a posted −50 @ d-9 → paid
    //   Rent     −200 USD due d+1  → upcoming (flows into the curve)
    //   Insurance −75 USD due d-15, no match, synced account → missed
    //   CFE      −400 MXN due d-8 on the manual account whose newest
    //             imported data is d-20 → MUST be pending_import, not red
    seed_rule(
        &pool,
        user_id,
        plaid_usd,
        "Gym",
        -50.0,
        "USD",
        "yearly",
        d(-10),
    )
    .await;
    seed_rule(
        &pool,
        user_id,
        plaid_usd,
        "Rent",
        -200.0,
        "USD",
        "yearly",
        d(1),
    )
    .await;
    seed_rule(
        &pool,
        user_id,
        plaid_usd,
        "Insurance",
        -75.0,
        "USD",
        "yearly",
        d(-15),
    )
    .await;
    seed_rule(
        &pool,
        user_id,
        manual_mxn,
        "CFE",
        -400.0,
        "MXN",
        "yearly",
        d(-8),
    )
    .await;

    // Posted rows: the gym charge (matches: same account/currency/amount,
    // 1 day off, description token hit) and an unrelated manual-account
    // purchase dated d-20 — it sets the manual account's data coverage AND
    // must not match CFE (12 days off, amount way out of band).
    let gym_tx = seed_tx(
        &pool,
        user_id,
        plaid_usd,
        d(-9),
        -50.0,
        "USD",
        "GYM MEMBERSHIP",
    )
    .await;
    seed_tx(
        &pool,
        user_id,
        manual_mxn,
        d(-20),
        -123.45,
        "MXN",
        "SUPER OXXO",
    )
    .await;

    // A personal loan with one PAID installment (d-3) and one upcoming
    // (d+5, +100 USD expected inflow — it must flow into the USD curve).
    let loan_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO loans (user_id, borrower_name, principal, currency, origination_date) \
         VALUES ($1, 'Jose Ramirez', 1000, 'USD', $2) RETURNING id",
    )
    .bind(user_id)
    .bind(d(-60))
    .fetch_one(&pool)
    .await
    .expect("seed loan");
    sqlx::query(
        "INSERT INTO loan_payments \
         (user_id, loan_id, installment_number, due_date, scheduled_amount, paid_amount, paid_date, status) \
         VALUES ($1, $2, 1, $3, 100, 100, $3, 'paid'), \
                ($1, $2, 2, $4, 100, NULL, NULL, 'scheduled')",
    )
    .bind(user_id)
    .bind(loan_id)
    .bind(d(-3))
    .bind(d(5))
    .execute(&pool)
    .await
    .expect("seed loan payments");

    let json = get_calendar(&app, &cookie, 30).await;

    // --- Occurrence states -------------------------------------------------
    let gym = occurrence(&json, "Gym", &d(-10).to_string());
    assert_eq!(gym["state"], "paid", "matched posted row → paid: {json}");
    assert_eq!(
        gym["matched_tx_id"],
        gym_tx.to_string(),
        "paid occurrence carries the matched tx id"
    );

    let rent = occurrence(&json, "Rent", &d(1).to_string());
    assert_eq!(rent["state"], "upcoming", "{json}");

    let insurance = occurrence(&json, "Insurance", &d(-15).to_string());
    assert_eq!(
        insurance["state"], "missed",
        "overdue + unmatched on a SYNCED account, past the grace window → missed: {json}"
    );

    // THE hard requirement: the manual-import account's newest data (d-20)
    // predates the CFE due date (d-8), so the bill may simply not be
    // imported yet — pending_import, NEVER late/missed.
    let cfe = occurrence(&json, "CFE", &d(-8).to_string());
    assert_eq!(
        cfe["state"], "pending_import",
        "stale manual-import account must never show a false red: {json}"
    );
    // Per-row MXN→USD conversion rides every occurrence.
    assert_eq!(cfe["amount"].as_f64(), Some(-400.0), "{json}");
    assert_eq!(cfe["amount_usd"].as_f64(), Some(-20.0), "{json}");

    // Loan dues: the reconciled installment is paid, the future one
    // upcoming (an expected inflow).
    let loan_paid = occurrence(&json, "Jose Ramirez", &d(-3).to_string());
    assert_eq!(loan_paid["state"], "paid", "{json}");
    assert_eq!(loan_paid["source"], "loan");
    let loan_due = occurrence(&json, "Jose Ramirez", &d(5).to_string());
    assert_eq!(loan_due["state"], "upcoming", "{json}");
    assert_eq!(loan_due["amount"].as_f64(), Some(100.0), "{json}");

    // --- Projected-balance curve (exact Decimal values) ---------------------
    // Start: USD = 1000 (latest plaid snapshot; NOT 1500 — the older
    // snapshot must not double-count), MXN = 5000.
    // Upcoming flows only: Rent −200 @ d+1, loan +100 @ d+5. The missed
    // Insurance and pending_import CFE contribute NOTHING (unknowable
    // timing), and the paid Gym row is already inside the balance.
    let projection = json["projection"].as_array().expect("projection array");
    assert_eq!(projection.len(), 31, "one point per day, today..today+30");
    assert_eq!(projection[0]["date"], today.to_string());
    assert_eq!(projection[0]["usd"].as_f64(), Some(1000.0), "{json}");
    assert_eq!(projection[0]["mxn"].as_f64(), Some(5000.0), "{json}");
    assert_eq!(projection[1]["usd"].as_f64(), Some(800.0), "rent cleared");
    assert_eq!(projection[4]["usd"].as_f64(), Some(800.0));
    assert_eq!(projection[5]["usd"].as_f64(), Some(900.0), "loan inflow");
    assert_eq!(projection[30]["usd"].as_f64(), Some(900.0));
    for p in projection {
        assert_eq!(p["mxn"].as_f64(), Some(5000.0), "MXN curve is flat: {p}");
    }

    // Both curves stay positive → no FX-transfer suggestion.
    assert!(
        json.get("fx_transfer_suggestion").is_none() || json["fx_transfer_suggestion"].is_null(),
        "no crossing → no suggestion: {json}"
    );

    // --- User scoping --------------------------------------------------------
    let user_b: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, email, password_hash) \
         VALUES ('carol', 'carol@example.com', 'doesnt-matter-for-this-test') RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .expect("seed user b");
    let token_b = patrimonio::services::sessions::create_session(&pool, user_b, None, None)
        .await
        .expect("create user b session")
        .token;
    let json_b = get_calendar(&app, &token_b, 30).await;
    assert_eq!(
        json_b["occurrences"].as_array().map(Vec::len),
        Some(0),
        "user B must not see user A's calendar: {json_b}"
    );
    let projection_b = json_b["projection"].as_array().expect("projection");
    assert_eq!(projection_b[0]["usd"].as_f64(), Some(0.0));
    assert_eq!(projection_b[0]["mxn"].as_f64(), Some(0.0));
}

#[tokio::test]
#[serial_test::serial]
async fn calendar_fx_crossing_sets_transfer_suggestion() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    let today = chrono::Utc::now().date_naive();
    let d = |offset: i64| today + chrono::Duration::days(offset);

    // USD cash 100, MXN cash 10,000; a −500 USD bill due d+10 dips the USD
    // curve to −400 while MXN stays positive → suggest moving MXN→USD.
    let usd_acct = seed_account(&pool, user_id, "Chase", "USD", "plaid").await;
    let mxn_acct = seed_account(&pool, user_id, "BBVA", "MXN", "plaid").await;
    seed_snapshot(&pool, user_id, usd_acct, d(-1), 100.0, "USD").await;
    seed_snapshot(&pool, user_id, mxn_acct, d(-1), 10000.0, "MXN").await;
    seed_rule(
        &pool,
        user_id,
        usd_acct,
        "Tuition",
        -500.0,
        "USD",
        "yearly",
        d(10),
    )
    .await;

    let json = get_calendar(&app, &cookie, 30).await;
    let flag = &json["fx_transfer_suggestion"];
    assert!(flag.is_object(), "crossing must set the flag: {json}");
    assert_eq!(flag["deficit_currency"], "USD", "{json}");
    assert_eq!(flag["surplus_currency"], "MXN", "{json}");
    assert_eq!(flag["date"], d(10).to_string(), "first below-zero date");
    assert_eq!(
        flag["shortfall"].as_f64(),
        Some(400.0),
        "deepest projected shortfall, positive magnitude: {json}"
    );

    // Exact curve around the dip.
    let projection = json["projection"].as_array().expect("projection");
    assert_eq!(projection[9]["usd"].as_f64(), Some(100.0));
    assert_eq!(projection[10]["usd"].as_f64(), Some(-400.0));
    assert_eq!(projection[10]["mxn"].as_f64(), Some(10000.0));
}

#[tokio::test]
#[serial_test::serial]
async fn calendar_days_param_is_clamped_1_to_90() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, _user_id) = bootstrap(&app, &pool).await;

    // Oversized and undersized horizons clamp silently (staleness-threshold
    // policy) instead of erroring or expanding unboundedly.
    let json = get_calendar(&app, &cookie, 500).await;
    assert_eq!(json["days"].as_i64(), Some(90), "500 clamps to 90: {json}");
    assert_eq!(
        json["projection"].as_array().map(Vec::len),
        Some(91),
        "clamped horizon drives the curve length"
    );

    let json = get_calendar(&app, &cookie, 0).await;
    assert_eq!(json["days"].as_i64(), Some(1), "0 clamps to 1: {json}");

    // Default (no param) is 30.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/recurring/calendar",
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(json["days"].as_i64(), Some(30));
}
