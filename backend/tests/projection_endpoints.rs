//! HTTP-level integration tests for `/api/projections/calculate`, focused on
//! the "Retire in Mexico" scenario: the new optional query params must
//! deserialize off the query string (serde_urlencoded, not JSON), the handler
//! must fill the USD→MXN rate from the latest `exchange_rates` row when the
//! client omits it, and a legacy request must keep its exact response shape
//! (no `mx_scenario` key at all).
//!
//! Like the sibling suites, these need a real Postgres reachable via
//! `PATRIMONIO_TEST_DATABASE_URL`; when unset they print a skip note and
//! return (set-but-unreachable PANICS — see tests/common/mod.rs).

use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{header, HeaderValue, Method, Request, StatusCode};
use axum::middleware::from_fn_with_state;
use axum::Router;
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
/// require_owner on business routes) around the projections router,
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
         exchange_rates, auth_audit, user_sessions, app_settings, \
         users RESTART IDENTITY CASCADE",
    )
    .execute(&pool)
    .await
    .expect("truncate projection tables");

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

    let public = Router::new().nest("/api/auth", patrimonio::api::session::public_router());

    let business = Router::new()
        .nest(
            "/api/projections",
            patrimonio::api::projections::router(),
        )
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
            "(skipping: set {TEST_DB_VAR}=postgres://user:pass@host/db to enable projection integration tests)"
        );
    }
    result
}

async fn body_json(body: Body) -> Value {
    let bytes = to_bytes(body, 1024 * 1024 * 4).await.expect("read body");
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

fn get(uri: &str, cookie: &str) -> Request<Body> {
    Request::builder()
        .method(Method::GET)
        .uri(uri)
        .header(
            header::COOKIE,
            HeaderValue::from_str(&format!("{SESSION_COOKIE}={cookie}")).unwrap(),
        )
        .body(Body::empty())
        .unwrap()
}

/// Bootstrap the first (owner) user; returns the session cookie.
async fn bootstrap(app: &Router) -> String {
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/auth/bootstrap")
                .header("X-Requested-With", "patrimonio")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::to_vec(&serde_json::json!({
                        "username": "owner",
                        "email": "owner@example.com",
                        "password": "correcthorsebatterystaple"
                    }))
                    .unwrap(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "bootstrap should succeed");
    set_cookie_value(res.headers()).expect("bootstrap should set cookie")
}

async fn seed_rate(pool: &PgPool, rate: &str, days_ago: i64) {
    sqlx::query(
        "INSERT INTO exchange_rates (base_currency, target_currency, rate, recorded_at, source) \
         VALUES ('USD', 'MXN', $1::numeric, NOW() - $2 * INTERVAL '1 day', 'api')",
    )
    .bind(rate)
    .bind(days_ago)
    .execute(pool)
    .await
    .expect("seed exchange rate");
}

/// The shared legacy parameter tail every request in this suite uses:
/// $100k start, $1k/mo, 7% nominal, $40k spend, 4% SWR, 30y horizon,
/// retire at year 0 so FX drift is a no-op and figures are closed-form.
const BASE_QS: &str = "start_balance=100000&monthly_contribution=1000&annual_return_rate=0.07\
&annual_expenses=40000&withdrawal_rate=0.04&years=30&years_to_retirement=0\
&monte_carlo_trials=100&mc_seed=42";

#[tokio::test]
#[serial_test::serial]
async fn legacy_request_has_no_mx_block() {
    let Some((app, _pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let cookie = bootstrap(&app).await;

    let res = app
        .clone()
        .oneshot(get(&format!("/api/projections/calculate?{BASE_QS}"), &cookie))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(json["fire_metrics"]["fi_number"].as_f64(), Some(1_000_000.0));
    assert!(
        json.get("mx_scenario").is_none(),
        "legacy response must not carry an mx_scenario key: {json}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn mx_scenario_uses_latest_stored_rate_when_client_omits_it() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let cookie = bootstrap(&app).await;

    // Latest rate is 17.00 (the 20.50 row is older and must lose).
    seed_rate(&pool, "20.50", 5).await;
    seed_rate(&pool, "17.00", 0).await;

    // 680,000 MXN/yr at 17.00 → $40k effective → the familiar $1M FI number.
    let res = app
        .clone()
        .oneshot(get(
            &format!(
                "/api/projections/calculate?{BASE_QS}\
                 &mx_scenario=true&annual_expenses_usd_portion=0\
                 &annual_expenses_mxn_portion=680000&fx_annual_drift=0"
            ),
            &cookie,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    let mx = &json["mx_scenario"];
    assert_eq!(mx["fx_rate_today"].as_f64(), Some(17.0), "latest DB rate: {json}");
    assert_eq!(mx["fx_rate_at_retirement"].as_f64(), Some(17.0));
    assert!((mx["effective_annual_expenses_usd"].as_f64().unwrap() - 40_000.0).abs() < 1e-6);
    assert!((json["fire_metrics"]["fi_number"].as_f64().unwrap() - 1_000_000.0).abs() < 1e-6);
    assert!(
        (mx["fi_number_mxn"].as_f64().unwrap() - 17_000_000.0).abs() < 1e-3,
        "MXN FI number restated at the rate: {json}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn mx_scenario_client_rate_wins_over_db() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let cookie = bootstrap(&app).await;
    seed_rate(&pool, "17.00", 0).await;

    let res = app
        .clone()
        .oneshot(get(
            &format!(
                "/api/projections/calculate?{BASE_QS}\
                 &mx_scenario=true&annual_expenses_usd_portion=10000\
                 &annual_expenses_mxn_portion=200000&fx_annual_drift=0.02\
                 &usd_mxn_rate=20"
            ),
            &cookie,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    let mx = &json["mx_scenario"];
    assert_eq!(
        mx["fx_rate_today"].as_f64(),
        Some(20.0),
        "the client's live rate must not be overridden by the DB: {json}"
    );
    // years_to_retirement=0 → drift never compounds, rate at retirement ==
    // today's, effective = 10k + 200k/20 = $20k.
    assert!((mx["effective_annual_expenses_usd"].as_f64().unwrap() - 20_000.0).abs() < 1e-6);
    assert_eq!(mx["fx_annual_drift"].as_f64(), Some(0.02));
}

#[tokio::test]
#[serial_test::serial]
async fn mx_scenario_empty_rate_table_falls_back_to_house_constant() {
    let Some((app, _pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let cookie = bootstrap(&app).await;
    // No exchange_rates rows at all: the engine's 20.0 hard fallback (the
    // USD_MXN_ROW_RATE_SQL constant) must kick in rather than a 500.
    let res = app
        .clone()
        .oneshot(get(
            &format!(
                "/api/projections/calculate?{BASE_QS}\
                 &mx_scenario=true&annual_expenses_usd_portion=0\
                 &annual_expenses_mxn_portion=800000&fx_annual_drift=0"
            ),
            &cookie,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(json["mx_scenario"]["fx_rate_today"].as_f64(), Some(20.0));
}
