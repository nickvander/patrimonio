//! HTTP-level integration tests for the unified notifications center:
//! `GET /api/notifications` (one inbox over every source, unread count for
//! the bell badge, loan-due generation-on-read with dedupe) and
//! `POST /api/notifications/read` (server-side read state).
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

/// Build the production middleware stack around the notifications router,
/// mirroring main.rs's mounting: NOT owner-gated (self-scoped inbox), but
/// inside require_auth + CSRF.
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
         user_notifications, loan_payments, loans, people, \
         auth_audit, user_sessions, app_settings, \
         users RESTART IDENTITY CASCADE",
    )
    .execute(&pool)
    .await
    .expect("truncate notification tables");

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

    // Notifications mount WITHOUT require_owner, exactly like main.rs.
    let account_mgmt = Router::new()
        .nest("/api/auth", patrimonio::api::session::protected_router())
        .nest(
            "/api/notifications",
            patrimonio::api::notifications::router(),
        );
    let protected = account_mgmt
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
            "(skipping: set {TEST_DB_VAR}=postgres://user:pass@host/db to enable notification integration tests)"
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

/// Insert a stored notification directly (as the fx_alert / import_stale
/// writers do), `minutes_ago` in the past so ordering is deterministic.
async fn seed_notification(
    pool: &PgPool,
    user_id: uuid::Uuid,
    kind: &str,
    title: &str,
    minutes_ago: i64,
) -> uuid::Uuid {
    sqlx::query_scalar(
        "INSERT INTO user_notifications (user_id, kind, title, body, created_at) \
         VALUES ($1, $2, $3, 'body', NOW() - $4 * INTERVAL '1 minute') \
         RETURNING id",
    )
    .bind(user_id)
    .bind(kind)
    .bind(title)
    .bind(minutes_ago)
    .fetch_one(pool)
    .await
    .expect("seed notification")
}

/// Seed an active loan with one scheduled installment due `days_from_now`
/// days from today. Returns (loan_id, payment_id).
async fn seed_loan_with_installment(
    pool: &PgPool,
    user_id: uuid::Uuid,
    days_from_now: i64,
) -> (uuid::Uuid, uuid::Uuid) {
    let loan_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO loans (user_id, borrower_name, principal, currency, origination_date) \
         VALUES ($1, 'Ana', 1000, 'MXN', CURRENT_DATE - 30) RETURNING id",
    )
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed loan");
    let payment_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO loan_payments \
             (user_id, loan_id, installment_number, due_date, scheduled_amount, scheduled_principal) \
         VALUES ($1, $2, 1, CURRENT_DATE + $3::int, 250, 250) RETURNING id",
    )
    .bind(user_id)
    .bind(loan_id)
    .bind(days_from_now as i32)
    .fetch_one(pool)
    .await
    .expect("seed installment");
    (loan_id, payment_id)
}

#[tokio::test]
#[serial_test::serial]
async fn inbox_lists_all_sources_newest_first_with_unread_count() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, uid) = bootstrap(&app, &pool).await;

    // Rows as written by the fx-center and staleness features.
    seed_notification(&pool, uid, "fx_alert", "USD/MXN crossed 17.5", 60).await;
    seed_notification(&pool, uid, "import_stale", "BBVA statement import overdue", 5).await;

    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/notifications", None, Some(&cookie)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    let list = json["notifications"].as_array().expect("notifications array");
    assert_eq!(list.len(), 2, "both sources in one list: {json}");
    // Newest first.
    assert_eq!(list[0]["kind"], "import_stale");
    assert_eq!(list[1]["kind"], "fx_alert");
    assert!(list[0]["read_at"].is_null(), "fresh rows are unread");
    assert_eq!(json["unread_count"], 2, "badge counts every unread row");
}

#[tokio::test]
#[serial_test::serial]
async fn requires_auth() {
    let Some((app, _pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/notifications", None, None))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
#[serial_test::serial]
async fn loan_due_reminder_is_generated_on_read_and_deduped() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, uid) = bootstrap(&app, &pool).await;
    // Due in 3 days — inside the default 7-day lead window.
    let (loan_id, _payment_id) = seed_loan_with_installment(&pool, uid, 3).await;
    // Control: due in 30 days — OUTSIDE the window; must not notify.
    seed_loan_with_installment(&pool, uid, 30).await;

    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/notifications", None, Some(&cookie)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    let list = json["notifications"].as_array().unwrap();
    assert_eq!(list.len(), 1, "only the in-window installment notifies: {json}");
    assert_eq!(list[0]["kind"], "loan_due");
    assert_eq!(list[0]["link_kind"], "loan");
    assert_eq!(list[0]["link_id"], loan_id.to_string());
    assert!(
        list[0]["title"].as_str().unwrap().contains("Ana"),
        "title names the borrower: {json}"
    );

    // Listing again must NOT mint a second reminder for the same
    // installment (the dedupe key makes generation-on-read idempotent).
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/notifications", None, Some(&cookie)))
        .await
        .unwrap();
    let json = body_json(res.into_body()).await;
    assert_eq!(
        json["notifications"].as_array().unwrap().len(),
        1,
        "re-listing is idempotent: {json}"
    );
    assert_eq!(json["unread_count"], 1);
}

#[tokio::test]
#[serial_test::serial]
async fn read_loan_reminder_stays_read_on_relist() {
    // Regression guard for the exact failure dedupe_key exists to
    // prevent: mark the generated reminder read, list again, and the
    // reminder must NOT come back as a fresh unread row.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, uid) = bootstrap(&app, &pool).await;
    seed_loan_with_installment(&pool, uid, 3).await;

    // Generate + mark everything read.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/notifications", None, Some(&cookie)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/notifications/read",
            Some(&serde_json::json!({"all": true})),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(json["marked"], 1);
    assert_eq!(json["unread_count"], 0);

    // Relist: still one row, still read, badge stays at zero.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/notifications", None, Some(&cookie)))
        .await
        .unwrap();
    let json = body_json(res.into_body()).await;
    let list = json["notifications"].as_array().unwrap();
    assert_eq!(list.len(), 1);
    assert!(
        !list[0]["read_at"].is_null(),
        "read state survives regeneration: {json}"
    );
    assert_eq!(json["unread_count"], 0, "truly all clear: {json}");
}

#[tokio::test]
#[serial_test::serial]
async fn mark_read_specific_ids_only() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, uid) = bootstrap(&app, &pool).await;
    let read_id = seed_notification(&pool, uid, "fx_alert", "USD/MXN crossed 17.5", 60).await;
    seed_notification(&pool, uid, "import_stale", "BBVA statement import overdue", 5).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/notifications/read",
            Some(&serde_json::json!({"ids": [read_id]})),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(json["marked"], 1);
    assert_eq!(json["unread_count"], 1, "the other row stays unread");

    // Marking the same id again is a no-op (already read).
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/notifications/read",
            Some(&serde_json::json!({"ids": [read_id]})),
            Some(&cookie),
        ))
        .await
        .unwrap();
    let json = body_json(res.into_body()).await;
    assert_eq!(json["marked"], 0);
    assert_eq!(json["unread_count"], 1);
}

#[tokio::test]
#[serial_test::serial]
async fn settled_installment_retires_its_reminder() {
    // Sibling of the import-staleness resolver: a due reminder is a claim
    // about the present. Paying the installment used to clear it from the
    // lending tab while the bell kept asking for the money forever.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, uid) = bootstrap(&app, &pool).await;
    let (_loan_id, payment_id) = seed_loan_with_installment(&pool, uid, 3).await;

    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/notifications", None, Some(&cookie)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(json["notifications"].as_array().unwrap().len(), 1);

    // Ana pays.
    sqlx::query("UPDATE loan_payments SET status = 'paid', paid_amount = 250 WHERE id = $1")
        .bind(payment_id)
        .execute(&pool)
        .await
        .expect("settle installment");

    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/notifications", None, Some(&cookie)))
        .await
        .unwrap();
    let json = body_json(res.into_body()).await;
    assert_eq!(
        json["notifications"].as_array().unwrap().len(),
        0,
        "a settled installment must not keep nagging: {json}"
    );
    assert_eq!(json["unread_count"], 0, "and the badge clears too: {json}");
}

#[tokio::test]
#[serial_test::serial]
async fn rescheduling_replaces_the_reminder_instead_of_stacking_one() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, uid) = bootstrap(&app, &pool).await;
    let (_loan_id, payment_id) = seed_loan_with_installment(&pool, uid, 3).await;

    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/notifications", None, Some(&cookie)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    // Moved a few days later — still inside the lead window, so it still
    // warrants a reminder, but the old date must not linger alongside it.
    // Read the new date back from the DB rather than recomputing it here,
    // so the assertion can't drift on the server's date/timezone.
    let new_due: String = sqlx::query_scalar(
        "UPDATE loan_payments SET due_date = CURRENT_DATE + 5 WHERE id = $1 \
         RETURNING due_date::text",
    )
    .bind(payment_id)
    .fetch_one(&pool)
    .await
    .expect("reschedule installment");

    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/notifications", None, Some(&cookie)))
        .await
        .unwrap();
    let json = body_json(res.into_body()).await;
    let list = json["notifications"].as_array().unwrap();
    assert_eq!(
        list.len(),
        1,
        "one installment, one reminder — the stale date is retired: {json}"
    );
    assert!(
        list[0]["title"].as_str().unwrap().contains(&new_due),
        "the surviving reminder carries the NEW due date: {json}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn notifications_are_user_scoped() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, _uid) = bootstrap(&app, &pool).await;

    // Another user's notification must be invisible to the caller and
    // unmarkable through the caller's session.
    let other_uid: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, password_hash) VALUES ('other', 'x') RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .expect("second user");
    let other_notif =
        seed_notification(&pool, other_uid, "fx_alert", "USD/MXN crossed 18", 10).await;

    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/notifications", None, Some(&cookie)))
        .await
        .unwrap();
    let json = body_json(res.into_body()).await;
    assert_eq!(
        json["notifications"].as_array().unwrap().len(),
        0,
        "other user's rows must not leak: {json}"
    );
    assert_eq!(json["unread_count"], 0);

    // Attempting to mark the foreign id read silently no-ops.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/notifications/read",
            Some(&serde_json::json!({"ids": [other_notif]})),
            Some(&cookie),
        ))
        .await
        .unwrap();
    let json = body_json(res.into_body()).await;
    assert_eq!(json["marked"], 0);
    let still_unread: bool = sqlx::query_scalar(
        "SELECT read_at IS NULL FROM user_notifications WHERE id = $1",
    )
    .bind(other_notif)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert!(still_unread, "foreign row untouched");
}

#[tokio::test]
#[serial_test::serial]
async fn mark_read_rejects_oversized_id_list() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, _uid) = bootstrap(&app, &pool).await;
    let ids: Vec<String> = (0..501).map(|_| uuid::Uuid::new_v4().to_string()).collect();
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/notifications/read",
            Some(&serde_json::json!({"ids": ids})),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
}
