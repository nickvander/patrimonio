//! HTTP-level integration tests for the FX center backend (interactive
//! USD/MXN pill): the per-user alert threshold CRUD on
//! `/api/fx/alert/{base}/{target}`, the `?days=` window on
//! `/api/fx/history/{base}/{target}`, and the crossing-detection fan-out
//! that records `user_notifications` rows for the bell.
//!
//! Like the sibling suites, these need a real Postgres reachable via
//! `PATRIMONIO_TEST_DATABASE_URL`; when unset they print a skip note and
//! return (set-but-unreachable PANICS — see tests/common/mod.rs).

use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{header, HeaderValue, Method, Request, StatusCode};
use axum::middleware::from_fn_with_state;
use axum::Router;
use rust_decimal_macros::dec;
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
/// require_owner on business routes) around the FX router, mirroring
/// main.rs's mounting.
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
         user_fx_alerts, user_notifications, exchange_rates, \
         auth_audit, user_sessions, app_settings, \
         users RESTART IDENTITY CASCADE",
    )
    .execute(&pool)
    .await
    .expect("truncate fx tables");

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
        .nest("/api/fx", patrimonio::api::exchange_rates::router())
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
            "(skipping: set {TEST_DB_VAR}=postgres://user:pass@host/db to enable fx integration tests)"
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

/// Insert an exchange_rates row `days_ago` days in the past.
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

#[tokio::test]
#[serial_test::serial]
async fn fx_alert_upsert_get_delete_roundtrip() {
    let Some((app, _pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, _uid) = bootstrap(&app, &_pool).await;

    // No alert configured yet → explicit null.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/fx/alert/USD/MXN",
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert!(json["alert"].is_null(), "fresh user has no alert: {json}");

    // PUT creates…
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/fx/alert/usd/mxn", // lowercase path must normalize
            Some(&serde_json::json!({"threshold": 17.5})),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(json["alert"]["base"], "USD");
    assert_eq!(json["alert"]["target"], "MXN");
    assert_eq!(json["alert"]["threshold"].as_f64(), Some(17.5));

    // …PUT again updates in place (upsert, not duplicate)…
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/fx/alert/USD/MXN",
            Some(&serde_json::json!({"threshold": 18.25})),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM user_fx_alerts")
        .fetch_one(&_pool)
        .await
        .unwrap();
    assert_eq!(count, 1, "upsert must not create a second row");

    // …GET reflects the update…
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/fx/alert/USD/MXN",
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    let json = body_json(res.into_body()).await;
    assert_eq!(json["alert"]["threshold"].as_f64(), Some(18.25));

    // …DELETE removes it (idempotent 204).
    for _ in 0..2 {
        let res = app
            .clone()
            .oneshot(req(
                Method::DELETE,
                "/api/fx/alert/USD/MXN",
                None,
                Some(&cookie),
            ))
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::NO_CONTENT);
    }
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/fx/alert/USD/MXN",
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    let json = body_json(res.into_body()).await;
    assert!(json["alert"].is_null(), "alert should be gone after delete");
}

#[tokio::test]
#[serial_test::serial]
async fn fx_alert_rejects_nonpositive_threshold() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, _uid) = bootstrap(&app, &pool).await;

    for bad in [0.0, -3.5, 2_000_000.0] {
        let res = app
            .clone()
            .oneshot(req(
                Method::PUT,
                "/api/fx/alert/USD/MXN",
                Some(&serde_json::json!({"threshold": bad})),
                Some(&cookie),
            ))
            .await
            .unwrap();
        assert_eq!(
            res.status(),
            StatusCode::BAD_REQUEST,
            "threshold {bad} must be rejected"
        );
    }
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM user_fx_alerts")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 0, "rejected thresholds must not persist");
}

#[tokio::test]
#[serial_test::serial]
async fn fx_alert_is_user_scoped() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, _uid) = bootstrap(&app, &pool).await;

    // A different user's alert must be invisible to the session user.
    let other_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, email, password_hash) \
         VALUES ('other', 'other@example.com', 'x') RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .expect("seed second user");
    sqlx::query(
        "INSERT INTO user_fx_alerts (user_id, base_currency, target_currency, threshold) \
         VALUES ($1, 'USD', 'MXN', 19.0)",
    )
    .bind(other_id)
    .execute(&pool)
    .await
    .expect("seed other user's alert");

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/fx/alert/USD/MXN",
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert!(
        json["alert"].is_null(),
        "another user's alert leaked across tenants: {json}"
    );

    // And the session user's DELETE must not touch the other row.
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            "/api/fx/alert/USD/MXN",
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM user_fx_alerts")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 1, "other user's alert must survive my delete");
}

#[tokio::test]
#[serial_test::serial]
async fn fx_crossing_records_notification_and_self_debounces() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, uid) = bootstrap(&app, &pool).await;

    // Configure the alert through the real endpoint.
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/fx/alert/USD/MXN",
            Some(&serde_json::json!({"threshold": 17.5})),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    // A refresh that crosses 17.5 upward records exactly one notification.
    let recorded = patrimonio::services::exchange_rate::record_fx_alert_crossings(
        &pool,
        "USD",
        "MXN",
        dec!(17.42),
        dec!(17.58),
    )
    .await
    .expect("crossing evaluation");
    assert_eq!(recorded, 1);

    let (kind, title, read_at): (String, String, Option<chrono::DateTime<chrono::Utc>>) =
        sqlx::query_as("SELECT kind, title, read_at FROM user_notifications WHERE user_id = $1")
            .bind(uid)
            .fetch_one(&pool)
            .await
            .expect("notification row recorded");
    assert_eq!(kind, "fx_alert");
    assert!(
        title.contains("USD/MXN") && title.contains("17.5"),
        "title should name the pair + threshold: {title}"
    );
    assert!(read_at.is_none(), "new notification starts unread");

    // A further move on the SAME side must not re-notify (edge-triggered).
    let recorded = patrimonio::services::exchange_rate::record_fx_alert_crossings(
        &pool,
        "USD",
        "MXN",
        dec!(17.58),
        dec!(17.80),
    )
    .await
    .expect("same-side evaluation");
    assert_eq!(recorded, 0, "same-side move must not re-notify");

    // Crossing back down notifies again.
    let recorded = patrimonio::services::exchange_rate::record_fx_alert_crossings(
        &pool,
        "USD",
        "MXN",
        dec!(17.80),
        dec!(17.30),
    )
    .await
    .expect("downward crossing evaluation");
    assert_eq!(recorded, 1);

    let count: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM user_notifications WHERE user_id = $1")
            .bind(uid)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(count, 2);
}

#[tokio::test]
#[serial_test::serial]
async fn fx_history_days_window_filters_old_points() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, _uid) = bootstrap(&app, &pool).await;

    seed_rate(&pool, "16.90", 40).await;
    seed_rate(&pool, "17.20", 10).await;
    seed_rate(&pool, "17.55", 0).await;

    // Windowed: only the two points inside 30 days.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/fx/history/USD/MXN?days=30",
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    let points = json.as_array().expect("history is an array");
    assert_eq!(points.len(), 2, "40-day-old point must be excluded: {json}");
    assert_eq!(points[0]["rate"].as_f64(), Some(17.20));
    assert_eq!(points[1]["rate"].as_f64(), Some(17.55));

    // Unwindowed: original contract — full history.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/fx/history/USD/MXN",
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    let json = body_json(res.into_body()).await;
    assert_eq!(json.as_array().map(Vec::len), Some(3));

    // Hostile ?days= is clamped, not a 500/unbounded interval.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/fx/history/USD/MXN?days=999999999",
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
}
