//! HTTP-level integration tests for recurring & scheduled transactions
//! (MVP): CRUD on `/api/recurring`, ownership scoping, and the
//! `/api/recurring/upcoming` expected-occurrence expansion incl. the
//! per-row MXN→USD conversion of its totals.
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
         recurring_rules, transactions, accounts, institutions, \
         exchange_rates, auth_audit, user_sessions, app_settings, \
         users RESTART IDENTITY CASCADE",
    )
    .execute(&pool)
    .await
    .expect("truncate recurring tables");

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
            "(skipping: set {TEST_DB_VAR}=postgres://user:pass@host/db to enable recurring integration tests)"
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

/// Seed one institution + one account for the given user. Returns the
/// account id.
async fn seed_account(pool: &PgPool, user_id: uuid::Uuid, currency: &str) -> uuid::Uuid {
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
         VALUES ($1, 'Checking', 'depository', $2, 1000.00, $3) RETURNING id",
    )
    .bind(inst_id)
    .bind(currency)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed account")
}

fn rule_body(account_id: uuid::Uuid, amount: f64, currency: &str, cadence: &str) -> Value {
    serde_json::json!({
        "account_id": account_id.to_string(),
        "description": "Rent",
        "category": "Housing",
        "amount": amount,
        "currency": currency,
        "cadence": cadence,
        "next_due_date": "2026-08-01"
    })
}

#[tokio::test]
#[serial_test::serial]
async fn recurring_crud_roundtrip_and_pause() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    let account_id = seed_account(&pool, user_id, "USD").await;

    // Create.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/recurring",
            Some(&rule_body(account_id, -1200.0, "usd", "monthly")),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED, "create rule");
    let json = body_json(res.into_body()).await;
    assert_eq!(json["description"], "Rent");
    assert_eq!(json["currency"], "USD", "currency normalizes to uppercase");
    assert_eq!(json["cadence"], "monthly");
    // anchor_day defaults to next_due_date's day when omitted.
    assert_eq!(json["anchor_day"], 1);
    assert_eq!(json["active"], true);
    assert_eq!(json["account_name"], "Checking");
    let rule_id = json["id"].as_str().expect("rule id").to_string();

    // List shows it.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/recurring", None, Some(&cookie)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(json.as_array().map(Vec::len), Some(1), "one rule listed: {json}");

    // Pause.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/recurring/{rule_id}"),
            Some(&serde_json::json!({"active": false})),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(json["active"], false, "rule paused");

    // Paused rule contributes nothing to upcoming.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/recurring/upcoming?from=2026-08-01&to=2026-08-31",
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(
        json["items"].as_array().map(Vec::len),
        Some(0),
        "paused rule excluded from upcoming: {json}"
    );

    // Delete; idempotent second delete also 204.
    for _ in 0..2 {
        let res = app
            .clone()
            .oneshot(req(
                Method::DELETE,
                &format!("/api/recurring/{rule_id}"),
                None,
                Some(&cookie),
            ))
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::NO_CONTENT);
    }
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/recurring", None, Some(&cookie)))
        .await
        .unwrap();
    let json = body_json(res.into_body()).await;
    assert_eq!(json.as_array().map(Vec::len), Some(0), "rule gone after delete");
}

#[tokio::test]
#[serial_test::serial]
async fn recurring_rejects_foreign_account_and_bad_input() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, _user_id) = bootstrap(&app, &pool).await;

    // Hand-roll user B (bootstrap is owner-only) and give them an account.
    let user_b: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, email, password_hash) \
         VALUES ('bob', 'bob@example.com', 'doesnt-matter-for-this-test') RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .expect("seed user b");
    let foreign_account = seed_account(&pool, user_b, "USD").await;

    // Creating a rule against someone else's account must 404 (not
    // create, not 403 — don't leak that the account exists).
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/recurring",
            Some(&rule_body(foreign_account, -50.0, "USD", "monthly")),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND, "foreign account rejected");
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM recurring_rules")
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 0, "no rule row planted");

    // Bad cadence and zero amount are client errors, not 500s.
    let own_account = seed_account(&pool, _user_id, "USD").await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/recurring",
            Some(&rule_body(own_account, -50.0, "USD", "fortnightly")),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST, "unknown cadence → 400");
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/recurring",
            Some(&rule_body(own_account, 0.0, "USD", "monthly")),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST, "zero amount → 400");
}

#[tokio::test]
#[serial_test::serial]
async fn recurring_upcoming_expands_and_converts_mxn_per_row() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    let usd_account = seed_account(&pool, user_id, "USD").await;
    let mxn_account = seed_account(&pool, user_id, "MXN").await;

    // Latest USD→MXN rate = 20 so the MXN math is easy to eyeball.
    sqlx::query(
        "INSERT INTO exchange_rates (base_currency, target_currency, rate, recorded_at, source) \
         VALUES ('USD', 'MXN', 20.0, NOW(), 'api')",
    )
    .execute(&pool)
    .await
    .expect("seed rate");

    // -500 USD monthly on the 15th + -2000 MXN monthly on the 1st +
    // +3000 USD salary biweekly seeded 2026-08-05.
    for (account, amount, currency, cadence, due) in [
        (usd_account, -500.0, "USD", "monthly", "2026-08-15"),
        (mxn_account, -2000.0, "MXN", "monthly", "2026-08-01"),
        (usd_account, 3000.0, "USD", "biweekly", "2026-08-05"),
    ] {
        let res = app
            .clone()
            .oneshot(req(
                Method::POST,
                "/api/recurring",
                Some(&serde_json::json!({
                    "account_id": account.to_string(),
                    "description": format!("rule {currency} {cadence}"),
                    "amount": amount,
                    "currency": currency,
                    "cadence": cadence,
                    "next_due_date": due
                })),
                Some(&cookie),
            ))
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::CREATED);
    }

    // August 2026 window: 1 occurrence each of the monthlies, biweekly
    // fires 8/5 and 8/19 → inflows 6000 USD; outflows 500 + 2000/20=100
    // → 600 USD. The MXN row must convert PER ROW, not sum raw (the
    // historical ~18x cross-currency bug this suite pins).
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/recurring/upcoming?from=2026-08-01&to=2026-08-31",
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    let items = json["items"].as_array().expect("items array");
    assert_eq!(items.len(), 4, "2 monthly + 2 biweekly occurrences: {json}");
    assert_eq!(json["expected_inflows_usd"].as_f64(), Some(6000.0), "{json}");
    assert_eq!(json["expected_outflows_usd"].as_f64(), Some(600.0), "{json}");
    // Items are date-sorted and carry native currency + per-row USD.
    assert_eq!(items[0]["due_date"], "2026-08-01");
    assert_eq!(items[0]["currency"], "MXN");
    assert_eq!(items[0]["amount"].as_f64(), Some(-2000.0));
    assert_eq!(items[0]["amount_usd"].as_f64(), Some(-100.0));

    // Another user sees nothing (row-level isolation).
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
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/recurring/upcoming?from=2026-08-01&to=2026-08-31",
            None,
            Some(&token_b),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(
        json["items"].as_array().map(Vec::len),
        Some(0),
        "user B must not see user A's expected flows: {json}"
    );

    // Oversized window is a client error (DoS clamp).
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/recurring/upcoming?from=2026-01-01&to=2028-01-01",
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST, "window clamp");
}
