//! What a confirmed statement import does to the account's PRESENT-day
//! balance, and to the `balance_snapshots` row that the net-worth chart
//! reads for today.
//!
//! Two bugs are pinned here:
//!
//! 1. The chart lagged the hero. `/dashboard/overview` reads
//!    `accounts.current_balance` (updated by the import), while
//!    `/dashboard/net-worth-history` reads `balance_snapshots`, whose only
//!    other writer for today is the nightly cron. So right after an import
//!    the headline figure moved and the chart's last point didn't — which
//!    made a manual "Sync now" look like the thing that applied the import.
//!
//! 2. Importing a BACKLOG walked the balance backwards: the closing balance
//!    was applied unconditionally, so a 2024 statement imported after a 2026
//!    one reset `current_balance` to the two-year-old figure.
//!
//! Needs a real Postgres via `PATRIMONIO_TEST_DATABASE_URL`; unset prints a
//! skip note and returns (set-but-unreachable PANICS — see tests/common/mod.rs).

use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{header, HeaderValue, Method, Request, StatusCode};
use axum::middleware::from_fn_with_state;
use axum::Router;
use rust_decimal::Decimal;
use serde_json::{json, Value};
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use tower::ServiceExt;

use patrimonio::config::AppConfig;
use patrimonio::AppState;

mod common;
use common::TestLockGuard;

const TEST_DB_VAR: &str = "PATRIMONIO_TEST_DATABASE_URL";
const SESSION_COOKIE: &str = "patrimonio_session";

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
         user_notifications, transactions, balance_snapshots, accounts, \
         institutions, exchange_rates, auth_audit, user_sessions, \
         app_settings, users RESTART IDENTITY CASCADE",
    )
    .execute(&pool)
    .await
    .expect("truncate import-snapshot tables");

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

    let public = Router::new().nest("/api/auth", patrimonio::api::session::public_router());

    let business = Router::new()
        .nest("/api/imports", patrimonio::api::imports::router())
        .nest("/api/dashboard", patrimonio::api::dashboard::router())
        .layer(axum::middleware::from_fn(
            patrimonio::api::session::require_owner,
        ));
    let protected = business
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
            "(skipping: set {TEST_DB_VAR}=postgres://user:pass@host/db to enable import-snapshot integration tests)"
        );
    }
    result
}

async fn body_json(body: Body) -> Value {
    let bytes = to_bytes(body, 1024 * 1024).await.expect("read body");
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
        builder = builder.header(
            header::COOKIE,
            HeaderValue::from_str(&format!("{SESSION_COOKIE}={token}")).unwrap(),
        );
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
            Some(&json!({
                "username": "owner",
                "email": "owner@example.com",
                "password": "correcthorsebatterystaple"
            })),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "bootstrap should succeed");
    let token = set_cookie_value(res.headers()).expect("bootstrap sets cookie");
    let user_id: uuid::Uuid = sqlx::query_scalar("SELECT id FROM users LIMIT 1")
        .fetch_one(pool)
        .await
        .expect("user row exists after bootstrap");
    (token, user_id)
}

/// A cetesdirecto-shaped MXN account: import-only, no live feed.
async fn seed_account(pool: &PgPool, user_id: uuid::Uuid, balance: &str) -> uuid::Uuid {
    let inst_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, user_id) \
         VALUES ('cetesdirecto', 'brokerage', 'MX', 'manual', $1) RETURNING id",
    )
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed institution");

    sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'CETES Directo', 'bonds', 'MXN', $2::numeric, $3) RETURNING id",
    )
    .bind(inst_id)
    .bind(balance)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed account")
}

/// One statement's worth of rows, with the portfolio total stamped on the
/// latest-dated one — exactly what `cetes_pdf::parse` produces.
fn statement(date: &str, amount: &str, closing: &str) -> Value {
    json!({
        "account_id": null, // filled by caller
        "transactions": [{
            "date": date,
            "description": "PREMIO CETES",
            "amount": amount,
            "currency": "MXN",
            "balance_after": closing,
            "source_file": format!("{date}.pdf"),
        }]
    })
}

fn confirm_body(account_id: uuid::Uuid, date: &str, amount: &str, closing: &str) -> Value {
    let mut v = statement(date, amount, closing);
    v["account_id"] = json!(account_id.to_string());
    v
}

async fn current_balance(pool: &PgPool, account_id: uuid::Uuid) -> Decimal {
    sqlx::query_scalar("SELECT current_balance FROM accounts WHERE id = $1")
        .bind(account_id)
        .fetch_one(pool)
        .await
        .expect("read balance")
}

async fn snapshot_today(pool: &PgPool, account_id: uuid::Uuid) -> Option<(Decimal, Decimal)> {
    sqlx::query_as(
        "SELECT balance, balance_usd FROM balance_snapshots \
         WHERE account_id = $1 AND as_of_date = CURRENT_DATE",
    )
    .bind(account_id)
    .fetch_optional(pool)
    .await
    .expect("read today's snapshot")
}

fn dec(s: &str) -> Decimal {
    s.parse().expect("decimal")
}

// ---------------------------------------------------------------------------

/// The chart's source of truth for today must move with the import, not wait
/// for the nightly cron (or a manual sync) to notice.
#[tokio::test]
#[serial_test::serial]
async fn import_records_todays_snapshot_so_the_chart_matches_the_hero() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    let account = seed_account(&pool, user_id, "85000").await;

    // 1 USD = 17.50 MXN, so the snapshot's USD leg must be converted, not
    // copied (copying is the ~17x net-worth overstatement bug).
    sqlx::query(
        "INSERT INTO exchange_rates (base_currency, target_currency, rate, source, recorded_at) \
         VALUES ('USD', 'MXN', 17.50, 'test', NOW())",
    )
    .execute(&pool)
    .await
    .expect("seed FX rate");

    assert!(
        snapshot_today(&pool, account).await.is_none(),
        "precondition: no snapshot for today yet"
    );

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/imports/confirm",
            Some(&confirm_body(account, "2026-06-30", "258.74", "92500.00")),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(body_json(res.into_body()).await["new_transactions"], 1);

    assert_eq!(
        current_balance(&pool, account).await,
        dec("92500.00"),
        "the hero figure (accounts.current_balance) tracks the statement"
    );
    let (balance, balance_usd) = snapshot_today(&pool, account)
        .await
        .expect("import must write TODAY's snapshot, not only the period-end one");
    assert_eq!(balance, dec("92500.00"), "chart agrees with the hero");
    assert_eq!(
        balance_usd,
        dec("5285.71"),
        "MXN must be FX-converted at write time (92500 / 17.50)"
    );

    // The period-end row still lands too — that's the history back-fill.
    let june: Option<Decimal> = sqlx::query_scalar(
        "SELECT balance FROM balance_snapshots WHERE account_id = $1 AND as_of_date = '2026-06-30'",
    )
    .bind(account)
    .fetch_optional(&pool)
    .await
    .expect("read june snapshot");
    assert_eq!(june, Some(dec("92500.00")), "history back-fill unchanged");
}

/// An import that lands after the cron already wrote today's row must win:
/// the cron copied the PRE-import balance, the statement is newer.
#[tokio::test]
#[serial_test::serial]
async fn import_overwrites_a_cron_snapshot_taken_earlier_today() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    let account = seed_account(&pool, user_id, "85000").await;

    sqlx::query(
        "INSERT INTO balance_snapshots (account_id, balance, as_of_date, currency, balance_usd, user_id) \
         VALUES ($1, 85000, CURRENT_DATE, 'MXN', 85000, $2)",
    )
    .bind(account)
    .bind(user_id)
    .execute(&pool)
    .await
    .expect("seed this morning's cron snapshot");

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/imports/confirm",
            Some(&confirm_body(account, "2026-06-30", "258.74", "92500.00")),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let (balance, _) = snapshot_today(&pool, account).await.expect("snapshot");
    assert_eq!(
        balance,
        dec("92500.00"),
        "the statement is fresher than the morning's copy of the old balance"
    );
}

/// Importing a backlog must not walk the present-day balance backwards.
#[tokio::test]
#[serial_test::serial]
async fn an_older_statement_does_not_regress_the_current_balance() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    let account = seed_account(&pool, user_id, "0").await;

    // Newest statement first (the realistic order: you import the latest,
    // then go back and fill the gaps).
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/imports/confirm",
            Some(&confirm_body(account, "2026-06-30", "258.74", "92500.00")),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    // …then a two-year-old one.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/imports/confirm",
            Some(&confirm_body(account, "2024-04-30", "100.00", "24000.00")),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "the old rows still import");

    assert_eq!(
        current_balance(&pool, account).await,
        dec("92500.00"),
        "history must not overwrite the present-day balance"
    );
    let (balance, _) = snapshot_today(&pool, account).await.expect("snapshot");
    assert_eq!(
        balance,
        dec("92500.00"),
        "…and must not overwrite today's chart point either"
    );

    // The old statement's own month-end point IS recorded — that's the point
    // of importing a backlog.
    let april: Option<Decimal> = sqlx::query_scalar(
        "SELECT balance FROM balance_snapshots WHERE account_id = $1 AND as_of_date = '2024-04-30'",
    )
    .bind(account)
    .fetch_optional(&pool)
    .await
    .expect("read april snapshot");
    assert_eq!(april, Some(dec("24000.00")), "history still back-fills");
}

/// Re-importing the SAME statement is a no-op, not a regression: the guard
/// compares dates with `>=` precisely so equality still applies.
#[tokio::test]
#[serial_test::serial]
async fn re_importing_the_same_statement_stays_idempotent() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    let account = seed_account(&pool, user_id, "0").await;

    for expected_new in [1, 0] {
        let res = app
            .clone()
            .oneshot(req(
                Method::POST,
                "/api/imports/confirm",
                Some(&confirm_body(account, "2026-06-30", "258.74", "92500.00")),
                Some(&cookie),
            ))
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::OK);
        assert_eq!(
            body_json(res.into_body()).await["new_transactions"],
            expected_new,
            "second confirm is all duplicates"
        );
    }

    assert_eq!(current_balance(&pool, account).await, dec("92500.00"));
    let (balance, _) = snapshot_today(&pool, account).await.expect("snapshot");
    assert_eq!(balance, dec("92500.00"));
}
