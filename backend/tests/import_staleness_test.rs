//! Integration tests for staleness reminders on import-only (manual)
//! institutions: the `last_data_at` field on `/api/dashboard/overview`
//! accounts (feeds the "as of <date>" chip + dashboard banner) and the
//! `record_staleness_notifications` sweep the daily cron runs (writes
//! `user_notifications` rows, kind = `import_stale`, once per staleness
//! episode, honoring the per-user `import_staleness_days` setting).
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
use patrimonio::services::staleness::record_staleness_notifications;
use patrimonio::AppState;

mod common;
use common::TestLockGuard;

const TEST_DB_VAR: &str = "PATRIMONIO_TEST_DATABASE_URL";
const SESSION_COOKIE: &str = "patrimonio_session";

/// Build the production middleware stack (CSRF outer, auth inner,
/// require_owner on business routes) around the dashboard + settings
/// routers, mirroring main.rs's mounting.
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
    .expect("truncate staleness tables");

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
        .nest("/api/dashboard", patrimonio::api::dashboard::router())
        .nest("/api/settings", patrimonio::api::settings::router())
        .layer(axum::middleware::from_fn(
            patrimonio::api::session::require_owner,
        ));
    // Notifications sit outside require_owner in main.rs (a read-only
    // member must be able to read their own inbox) — mirror that, since
    // listing the inbox is what retires resolved reminders.
    let account_mgmt = Router::new()
        .nest("/api/auth", patrimonio::api::session::protected_router())
        .nest(
            "/api/notifications",
            patrimonio::api::notifications::router(),
        );
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
            "(skipping: set {TEST_DB_VAR}=postgres://user:pass@host/db to enable staleness integration tests)"
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

/// Seed an institution + one account whose `updated_at` sits `days_ago`
/// days in the past. Returns (institution_id, account_id).
async fn seed_institution_account(
    pool: &PgPool,
    user_id: uuid::Uuid,
    name: &str,
    integration_type: &str,
    days_ago: i64,
) -> (uuid::Uuid, uuid::Uuid) {
    let inst_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, user_id) \
         VALUES ($1, 'bank', 'MX', $2, $3) RETURNING id",
    )
    .bind(name)
    .bind(integration_type)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed institution");

    let acct_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, \
                               user_id, updated_at) \
         VALUES ($1, $2, 'checking', 'MXN', 1000, $3, NOW() - $4 * INTERVAL '1 day') \
         RETURNING id",
    )
    .bind(inst_id)
    .bind(format!("{name} Checking"))
    .bind(user_id)
    .bind(days_ago)
    .fetch_one(pool)
    .await
    .expect("seed account");
    (inst_id, acct_id)
}

/// Re-age an account's `updated_at` to `days_ago` days in the past.
async fn age_account(pool: &PgPool, account_id: uuid::Uuid, days_ago: i64) {
    sqlx::query("UPDATE accounts SET updated_at = NOW() - $2 * INTERVAL '1 day' WHERE id = $1")
        .bind(account_id)
        .bind(days_ago)
        .execute(pool)
        .await
        .expect("age account");
}

async fn stale_notification_count(pool: &PgPool, user_id: uuid::Uuid) -> i64 {
    sqlx::query_scalar(
        "SELECT COUNT(*) FROM user_notifications WHERE user_id = $1 AND kind = 'import_stale'",
    )
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("count notifications")
}

// ---------------------------------------------------------------------------
// /api/dashboard/overview → last_data_at
// ---------------------------------------------------------------------------

#[tokio::test]
#[serial_test::serial]
async fn overview_reports_last_data_at_only_for_manual_accounts() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;

    let (_i1, manual_acct) =
        seed_institution_account(&pool, user_id, "Banamex", "manual", 40).await;
    seed_institution_account(&pool, user_id, "Chase", "plaid", 40).await;

    // A transaction inserted 10 days ago (import time) must win over the
    // 40-day-old account row: created_at is the import wall-clock, while
    // the tx's own `date` is historical and must NOT matter.
    sqlx::query(
        "INSERT INTO transactions (account_id, date, description, amount, currency, user_id, created_at) \
         VALUES ($1, '2020-01-15', 'old statement row', -50, 'MXN', $2, NOW() - INTERVAL '10 days')",
    )
    .bind(manual_acct)
    .bind(user_id)
    .execute(&pool)
    .await
    .expect("seed transaction");

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/overview",
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    let accounts = json["accounts"].as_array().expect("accounts array");
    assert_eq!(accounts.len(), 2, "both seeded accounts visible: {json}");

    let manual = accounts
        .iter()
        .find(|a| a["integration_type"] == "manual")
        .expect("manual account present");
    let plaid = accounts
        .iter()
        .find(|a| a["integration_type"] == "plaid")
        .expect("plaid account present");

    // Manual account carries last_data_at ≈ 10 days ago (the tx insert).
    let last_str = manual["last_data_at"]
        .as_str()
        .expect("manual account has last_data_at");
    let last: chrono::DateTime<chrono::Utc> = chrono::DateTime::parse_from_rfc3339(last_str)
        .unwrap()
        .into();
    let age_days = (chrono::Utc::now() - last).num_days();
    assert!(
        (9..=10).contains(&age_days),
        "tx insert time (10d) must win over account updated_at (40d), got {age_days}d"
    );

    // Synced accounts have no last_data_at (field omitted when None).
    assert!(
        plaid.get("last_data_at").is_none() || plaid["last_data_at"].is_null(),
        "plaid account must not carry last_data_at: {plaid}"
    );
}

// ---------------------------------------------------------------------------
// record_staleness_notifications (the daily-cron sweep)
// ---------------------------------------------------------------------------

#[tokio::test]
#[serial_test::serial]
async fn staleness_notification_once_per_episode_and_rearms_after_import() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (_cookie, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) =
        seed_institution_account(&pool, user_id, "CetesDirecto", "manual", 40).await;
    // A stale Plaid institution must never produce an import reminder.
    seed_institution_account(&pool, user_id, "Chase", "plaid", 400).await;

    // First sweep records exactly one reminder…
    let recorded = record_staleness_notifications(&pool)
        .await
        .expect("sweep 1");
    assert_eq!(recorded, 1, "one stale manual institution → one row");
    assert_eq!(stale_notification_count(&pool, user_id).await, 1);
    let (kind, title): (String, String) =
        sqlx::query_as("SELECT kind, title FROM user_notifications WHERE user_id = $1")
            .bind(user_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(kind, "import_stale");
    assert!(
        title.contains("CetesDirecto"),
        "title names the institution: {title}"
    );

    // …a second run the same day stays silent (dedup, not daily spam)…
    let recorded = record_staleness_notifications(&pool)
        .await
        .expect("sweep 2");
    assert_eq!(recorded, 0, "same episode must not re-notify");
    assert_eq!(stale_notification_count(&pool, user_id).await, 1);

    // …a fresh import (updated_at = now) ends the episode: still silent…
    age_account(&pool, acct, 0).await;
    let recorded = record_staleness_notifications(&pool)
        .await
        .expect("sweep 3");
    assert_eq!(recorded, 0, "fresh data → nothing stale");
    assert_eq!(stale_notification_count(&pool, user_id).await, 1);

    // …and once it goes stale AGAIN, a new episode notifies again. Simulate
    // the passage of time honestly: the old notification is now in the deep
    // past, and the account's last import (45d ago) is NEWER than it — the
    // real-world ordering (import at T1 > old notification, then T1+45 rolls
    // past the threshold). Re-aging only the account would put last_data_at
    // BEFORE the notification, an impossible history.
    sqlx::query(
        "UPDATE user_notifications SET created_at = NOW() - INTERVAL '100 days' \
         WHERE user_id = $1 AND kind = 'import_stale'",
    )
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();
    age_account(&pool, acct, 45).await;
    let recorded = record_staleness_notifications(&pool)
        .await
        .expect("sweep 4");
    assert_eq!(recorded, 1, "new staleness episode re-arms the reminder");
    assert_eq!(stale_notification_count(&pool, user_id).await, 2);
}

#[tokio::test]
#[serial_test::serial]
async fn staleness_threshold_setting_is_honored() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    seed_institution_account(&pool, user_id, "Nu México", "manual", 40).await;

    // User raised the threshold to 60 days → 40-day-old data is fine.
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/settings/import_staleness_days",
            Some(&serde_json::json!(60)),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let recorded = record_staleness_notifications(&pool).await.expect("sweep");
    assert_eq!(recorded, 0, "40d old < 60d threshold → no reminder");

    // Tightening it to 14 days flips the same data to stale.
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/settings/import_staleness_days",
            Some(&serde_json::json!(14)),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let recorded = record_staleness_notifications(&pool).await.expect("sweep");
    assert_eq!(recorded, 1, "40d old > 14d threshold → reminder");
    assert_eq!(stale_notification_count(&pool, user_id).await, 1);
}

// ---------------------------------------------------------------------------
// Snooze (banner dismiss = 7-day per-institution silence) + permanent mute
// ---------------------------------------------------------------------------

/// The institution's freshest data timestamp, exactly as the sweep sees it.
async fn last_data_at(pool: &PgPool, inst_id: uuid::Uuid) -> chrono::DateTime<chrono::Utc> {
    sqlx::query_scalar(
        "SELECT MAX(GREATEST(a.updated_at, tx.last_tx_at)) \
         FROM accounts a \
         LEFT JOIN LATERAL ( \
             SELECT MAX(t.created_at) AS last_tx_at \
             FROM transactions t WHERE t.account_id = a.id \
         ) tx ON TRUE \
         WHERE a.institution_id = $1",
    )
    .bind(inst_id)
    .fetch_one(pool)
    .await
    .expect("institution last_data_at")
}

#[tokio::test]
#[serial_test::serial]
async fn snoozed_institution_is_silent_until_expiry_then_notifies_again() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) =
        seed_institution_account(&pool, user_id, "CetesDirecto", "manual", 45).await;
    let data_as_of = last_data_at(&pool, inst).await;

    // Dismissing the banner writes the snooze through the real settings
    // endpoint (same JSON the frontend produces): until = +7d, plus the
    // last_data_at observed at dismiss time.
    let until = chrono::Utc::now() + chrono::Duration::days(7);
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/settings/import_staleness_snoozes",
            Some(&serde_json::json!({
                inst.to_string(): {
                    "until": until.to_rfc3339(),
                    "data_as_of": data_as_of.to_rfc3339(),
                }
            })),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    // While snoozed the sweep must stay COMPLETELY silent — no bell row,
    // not merely a deduplicated one.
    let recorded = record_staleness_notifications(&pool).await.expect("sweep");
    assert_eq!(recorded, 0, "active snooze → no notification row");
    assert_eq!(stale_notification_count(&pool, user_id).await, 0);

    // Rewind the snooze window to the past: still stale → notifies again.
    let expired = chrono::Utc::now() - chrono::Duration::hours(1);
    sqlx::query(
        "UPDATE app_settings \
         SET value = jsonb_set(value, ARRAY[$2], jsonb_build_object( \
                 'until', to_jsonb($3::text), \
                 'data_as_of', value->$2->>'data_as_of')) \
         WHERE user_id = $1 AND key = 'import_staleness_snoozes'",
    )
    .bind(user_id)
    .bind(inst.to_string())
    .bind(expired.to_rfc3339())
    .execute(&pool)
    .await
    .expect("expire snooze");

    let recorded = record_staleness_notifications(&pool)
        .await
        .expect("sweep 2");
    assert_eq!(recorded, 1, "expired snooze + still stale → reminder fires");
    assert_eq!(stale_notification_count(&pool, user_id).await, 1);
}

#[tokio::test]
#[serial_test::serial]
async fn fresh_import_invalidates_an_active_snooze() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    // Aggressive 1-day threshold so "stale again soon after an import"
    // can happen INSIDE a still-open 7-day snooze window — the exact case
    // where data_as_of (not window expiry) must do the re-arming.
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/settings/import_staleness_days",
            Some(&serde_json::json!(1)),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let (inst, acct) = seed_institution_account(&pool, user_id, "Banamex", "manual", 45).await;
    let data_as_of = last_data_at(&pool, inst).await;
    let until = chrono::Utc::now() + chrono::Duration::days(7);
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/settings/import_staleness_snoozes",
            Some(&serde_json::json!({
                inst.to_string(): {
                    "until": until.to_rfc3339(),
                    "data_as_of": data_as_of.to_rfc3339(),
                }
            })),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(
        record_staleness_notifications(&pool)
            .await
            .expect("sweep 1"),
        0,
        "snoozed → silent"
    );

    // A fresh import 2 days later (inside the snooze window) that is
    // already 1-day-stale again: last_data_at is now NEWER than the
    // snooze's data_as_of, so the snooze no longer applies.
    age_account(&pool, acct, 2).await;
    let recorded = record_staleness_notifications(&pool)
        .await
        .expect("sweep 2");
    assert_eq!(
        recorded, 1,
        "data newer than the snooze's data_as_of = new episode → reminder fires"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn muted_institution_never_notifies_but_others_still_do() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    let (muted_inst, _) =
        seed_institution_account(&pool, user_id, "CetesDirecto", "manual", 45).await;
    seed_institution_account(&pool, user_id, "Banamex", "manual", 60).await;

    // "Remind me" toggled off for CetesDirecto in Settings.
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/settings/import_staleness_muted",
            Some(&serde_json::json!([muted_inst.to_string()])),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let recorded = record_staleness_notifications(&pool).await.expect("sweep");
    assert_eq!(recorded, 1, "only the unmuted institution notifies");
    let titles: Vec<String> = sqlx::query_scalar(
        "SELECT title FROM user_notifications WHERE user_id = $1 AND kind = 'import_stale'",
    )
    .bind(user_id)
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(titles.len(), 1);
    assert!(
        titles[0].contains("Banamex"),
        "the bell row belongs to the unmuted institution: {titles:?}"
    );

    // Mute is permanent: later sweeps stay silent for the muted one even
    // as it gets more stale (dedup never enters the picture).
    let recorded = record_staleness_notifications(&pool)
        .await
        .expect("sweep 2");
    assert_eq!(recorded, 0);
    assert_eq!(stale_notification_count(&pool, user_id).await, 1);
}

#[tokio::test]
#[serial_test::serial]
async fn overview_accounts_carry_the_institution_id_snoozes_are_keyed_on() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    let (inst, _) = seed_institution_account(&pool, user_id, "Banamex", "manual", 5).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/overview",
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    let accounts = json["accounts"].as_array().expect("accounts array");
    assert_eq!(
        accounts[0]["institution_id"].as_str(),
        Some(inst.to_string().as_str()),
        "overview accounts expose institution_id so the frontend can key \
         snooze/mute entries on it: {json}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn archived_accounts_do_not_keep_an_institution_on_the_radar() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (_cookie, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_institution_account(&pool, user_id, "Banamex", "manual", 40).await;
    sqlx::query("UPDATE accounts SET archived_at = NOW() WHERE id = $1")
        .bind(acct)
        .execute(&pool)
        .await
        .unwrap();

    let recorded = record_staleness_notifications(&pool).await.expect("sweep");
    assert_eq!(
        recorded, 0,
        "an institution with only archived accounts must not nag"
    );
}

// ---------------------------------------------------------------------------
// resolve_stale_import_notifications — retiring reminders that stopped
// being true. Regression guard for the reported bug: importing a
// CetesDirecto statement cleared the dashboard banner, but the bell kept
// repeating "CetesDirecto data is 45 days old" indefinitely, because
// nothing ever took a written reminder back.
// ---------------------------------------------------------------------------

/// The single `import_stale` row's body, for asserting on its day count.
async fn stale_notification_body(pool: &PgPool, user_id: uuid::Uuid) -> String {
    sqlx::query_scalar(
        "SELECT body FROM user_notifications WHERE user_id = $1 AND kind = 'import_stale'",
    )
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("one import_stale row")
}

#[tokio::test]
#[serial_test::serial]
async fn a_fresh_import_retires_the_reminder_on_the_next_inbox_read() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) =
        seed_institution_account(&pool, user_id, "CetesDirecto", "manual", 45).await;

    record_staleness_notifications(&pool).await.expect("sweep");
    assert_eq!(stale_notification_count(&pool, user_id).await, 1);

    // The bell shows it while it is true…
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/notifications", None, Some(&cookie)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(json["notifications"].as_array().unwrap().len(), 1);
    assert_eq!(json["unread_count"], 1);

    // …the user imports a statement (import confirm bumps updated_at)…
    age_account(&pool, acct, 0).await;

    // …and the very next read retires it, badge included.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/notifications", None, Some(&cookie)))
        .await
        .unwrap();
    let json = body_json(res.into_body()).await;
    assert_eq!(
        json["notifications"].as_array().unwrap().len(),
        0,
        "a reminder that is no longer true must not survive the import: {json}"
    );
    assert_eq!(
        json["unread_count"], 0,
        "retiring the row also de-badges the bell: {json}"
    );
    assert_eq!(stale_notification_count(&pool, user_id).await, 0);
}

#[tokio::test]
#[serial_test::serial]
async fn a_still_stale_reminder_is_re_dated_rather_than_frozen() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) =
        seed_institution_account(&pool, user_id, "CetesDirecto", "manual", 45).await;

    record_staleness_notifications(&pool).await.expect("sweep");
    assert!(
        stale_notification_body(&pool, user_id)
            .await
            .contains("45 days old"),
        "sanity: the reminder was raised at 45 days"
    );

    // A week passes with no import. The row must still be there — it is
    // still true — but saying 52, not the number it was born with.
    age_account(&pool, acct, 52).await;
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/notifications", None, Some(&cookie)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(
        json["notifications"].as_array().unwrap().len(),
        1,
        "still stale → still reminded: {json}"
    );
    let body = json["notifications"][0]["body"].as_str().unwrap();
    assert!(
        body.contains("52 days old"),
        "the day count tracks today, not the day the reminder was written: {body}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn muting_retires_an_already_written_reminder() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) =
        seed_institution_account(&pool, user_id, "CetesDirecto", "manual", 45).await;

    record_staleness_notifications(&pool).await.expect("sweep");
    assert_eq!(stale_notification_count(&pool, user_id).await, 1);

    // "Remind me" toggled off AFTER the reminder was already in the inbox:
    // the sweep would no longer write it, so it must not linger either.
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/settings/import_staleness_muted",
            Some(&serde_json::json!([inst.to_string()])),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/notifications", None, Some(&cookie)))
        .await
        .unwrap();
    let json = body_json(res.into_body()).await;
    assert_eq!(
        json["notifications"].as_array().unwrap().len(),
        0,
        "muting an institution clears its outstanding bell row: {json}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn resolution_never_touches_a_row_it_cannot_attribute() {
    // The resolver deletes on proof that the condition ended, never on a
    // failure to find the institution — otherwise any join gap (a deleted
    // or renamed institution, a row written by an older build) would read
    // as "resolved" and silently eat the user's inbox.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;

    // No institution named Revolut exists at all.
    sqlx::query(
        "INSERT INTO user_notifications (user_id, kind, title, body) \
         VALUES ($1, 'import_stale', 'Revolut statement import overdue', 'Revolut data is 38 days old.')",
    )
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();
    // …and an unrelated event row, which is not condition-backed at all.
    sqlx::query(
        "INSERT INTO user_notifications (user_id, kind, title, body) \
         VALUES ($1, 'fx_alert', 'USD/MXN crossed 17.5', 'body')",
    )
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/notifications", None, Some(&cookie)))
        .await
        .unwrap();
    let json = body_json(res.into_body()).await;
    assert_eq!(
        json["notifications"].as_array().unwrap().len(),
        2,
        "unattributable and event-style rows both survive: {json}"
    );
}
