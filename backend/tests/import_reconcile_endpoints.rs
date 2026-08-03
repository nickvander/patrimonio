//! HTTP-level integration tests for `POST /api/imports/reconcile` — the
//! guided statement-reconciliation check that runs BEFORE confirm.
//!
//! Covers the five outcomes the frontend has to render distinctly (reconciled,
//! reconciled-only-after-the-duplicate-skip, gap explained by a named stored
//! transaction, unexplained gap, and "we can't check this one"), a
//! multi-account import where one account reconciles and another doesn't, and
//! the user-scoping invariant: user B's account id must 404 for user A rather
//! than reconcile against — or leak the existence of — someone else's ledger.
//!
//! Needs a real Postgres via `PATRIMONIO_TEST_DATABASE_URL`; unset prints a
//! skip note and returns (set-but-unreachable PANICS — see
//! tests/common/mod.rs).

use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{header, HeaderValue, Method, Request, StatusCode};
use axum::middleware::from_fn_with_state;
use axum::Router;
use serde_json::{json, Value};
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use tower::ServiceExt;
use uuid::Uuid;

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
         transactions, balance_snapshots, accounts, institutions, \
         exchange_rates, auth_audit, user_sessions, app_settings, \
         users RESTART IDENTITY CASCADE",
    )
    .execute(&pool)
    .await
    .expect("truncate reconcile tables");

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
        .layer(axum::middleware::from_fn(
            patrimonio::api::middleware::require_owner,
        ));
    let protected = business
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
            "(skipping: set {TEST_DB_VAR}=postgres://user:pass@host/db to enable import-reconcile integration tests)"
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

/// Bootstrap the first (owner) user; returns (cookie, user_id).
async fn bootstrap(app: &Router, pool: &PgPool) -> (String, Uuid) {
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
    let user_id: Uuid = sqlx::query_scalar("SELECT id FROM users LIMIT 1")
        .fetch_one(pool)
        .await
        .expect("user row exists after bootstrap");
    (token, user_id)
}

/// A second, fully-owner-role user — so the cross-user assertion tests pure
/// `user_id` scoping, not the role gate.
async fn second_user(pool: &PgPool) -> Uuid {
    sqlx::query_scalar(
        "INSERT INTO users (username, email, password_hash) \
         VALUES ('other', 'other@example.com', 'x') RETURNING id",
    )
    .fetch_one(pool)
    .await
    .expect("seed second user")
}

/// Seed an institution + MXN account for `user_id`; returns the account id.
async fn seed_account(pool: &PgPool, user_id: Uuid, name: &str) -> Uuid {
    let inst_id: Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, user_id) \
         VALUES ($1, 'bank', 'MX', 'manual', $2) RETURNING id",
    )
    .bind(name)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed institution");
    sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, $2, 'checking', 'MXN', 1000, $3) RETURNING id",
    )
    .bind(inst_id)
    .bind(name)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed account")
}

/// The import dedup signature — MUST mirror `tx_signature` in
/// `src/api/imports.rs`, because "will be skipped as a duplicate" is decided
/// by comparing the submitted rows' signatures against stored `external_id`s.
fn sig(date: &str, amount: &str, desc: &str) -> String {
    format!(
        "manual:{date}:{amount}:{}",
        desc.to_lowercase().chars().take(50).collect::<String>()
    )
}

/// Insert a stored transaction. `external_id` is the import signature when
/// `as_import` is true (i.e. the row IS a previously-imported statement row),
/// and a non-matching id otherwise (a hand-entered row the import can't
/// recognise) — which is exactly the double-entry situation the reconciler
/// must catch.
async fn seed_tx(
    pool: &PgPool,
    user_id: Uuid,
    account_id: Uuid,
    date: &str,
    amount: &str,
    desc: &str,
    as_import: bool,
) -> Uuid {
    let external_id = if as_import {
        sig(date, amount, desc)
    } else {
        format!("manual-entry:{}", Uuid::new_v4())
    };
    sqlx::query_scalar(
        "INSERT INTO transactions \
         (account_id, external_id, date, description, amount, currency, \
          source, source_id, user_id) \
         VALUES ($1, $2, $3::date, $4, $5::numeric, 'MXN', 'csv', 'csv_import', $6) \
         RETURNING id",
    )
    .bind(account_id)
    .bind(external_id)
    .bind(date)
    .bind(desc)
    .bind(amount)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed transaction")
}

/// One preview-shaped statement row: flattened `ParsedTransaction` fields plus
/// `source_file`. `balance` is the bank's running SALDO after the row.
fn stmt_row(date: &str, amount: &str, desc: &str, balance: Option<&str>, file: &str) -> Value {
    let mut row = json!({
        "date": date,
        "description": desc,
        "amount": amount,
        "currency": "MXN",
        "source_file": file,
    });
    if let Some(b) = balance {
        row["balance_after"] = json!(b);
    }
    row
}

/// A clean January: opens at 1000, three movements, closes at 1150.
fn january(file: &str) -> Vec<Value> {
    vec![
        stmt_row("2026-01-05", "-200.00", "COMPRA OXXO", Some("800.00"), file),
        stmt_row("2026-01-12", "500.00", "DEPOSITO", Some("1300.00"), file),
        stmt_row("2026-01-20", "-150.00", "PAGO CFE", Some("1150.00"), file),
    ]
}

async fn reconcile(app: &Router, cookie: &str, body: &Value) -> (StatusCode, Value) {
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/imports/reconcile",
            Some(body),
            Some(cookie),
        ))
        .await
        .unwrap();
    let status = res.status();
    (status, body_json(res.into_body()).await)
}

fn approx(v: &Value, expected: f64) -> bool {
    v.as_f64().map(|f| (f - expected).abs() < 0.005) == Some(true)
}

// ---------------------------------------------------------------------------

#[tokio::test]
#[serial_test::serial]
async fn a_statement_that_matches_the_ledger_reconciles_to_the_centavo() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, uid) = bootstrap(&app, &pool).await;
    let account = seed_account(&pool, uid, "Banamex").await;

    let (status, json) = reconcile(
        &app,
        &cookie,
        &json!({ "accounts": [{
            "account_id": account.to_string(),
            "transactions": january("ene.pdf"),
        }]}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{json}");

    let acct = &json["accounts"][0];
    assert_eq!(acct["status"], "reconciled", "{json}");
    let stmt = &acct["statements"][0];
    assert_eq!(stmt["file"], "ene.pdf");
    assert_eq!(stmt["status"], "reconciled", "{json}");
    assert!(approx(&stmt["statement_opening_balance"], 1000.0), "{json}");
    assert!(approx(&stmt["statement_closing_balance"], 1150.0), "{json}");
    assert!(approx(&stmt["computed_closing_balance"], 1150.0), "{json}");
    assert!(approx(&stmt["difference"], 0.0), "{json}");
    assert_eq!(stmt["duplicate_rows"], 0);
    assert_eq!(stmt["candidates"], json!([]));
    assert_eq!(stmt["unavailable_reason"], Value::Null);
}

#[tokio::test]
#[serial_test::serial]
async fn a_re_import_reconciles_only_after_the_duplicate_skip() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, uid) = bootstrap(&app, &pool).await;
    let account = seed_account(&pool, uid, "Banamex").await;

    // The whole statement is already imported, under the exact signatures
    // confirm writes. Counting the incoming rows AND their stored twins would
    // manufacture a gap of the statement's own net change (+150).
    for (date, amount, desc) in [
        ("2026-01-05", "-200.00", "COMPRA OXXO"),
        ("2026-01-12", "500.00", "DEPOSITO"),
        ("2026-01-20", "-150.00", "PAGO CFE"),
    ] {
        seed_tx(&pool, uid, account, date, amount, desc, true).await;
    }

    let (status, json) = reconcile(
        &app,
        &cookie,
        &json!({ "accounts": [{
            "account_id": account.to_string(),
            "transactions": january("ene.pdf"),
        }]}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{json}");

    let stmt = &json["accounts"][0]["statements"][0];
    assert_eq!(
        stmt["status"], "reconciled_after_duplicate_skip",
        "reconciles, but only because all 3 rows are already present: {json}"
    );
    assert!(approx(&stmt["difference"], 0.0), "{json}");
    assert_eq!(stmt["duplicate_rows"], 3, "{json}");
    assert_eq!(stmt["existing_rows_in_period"], 3, "{json}");
    assert_eq!(
        stmt["candidates"],
        json!([]),
        "a row the import itself accounts for is never a candidate: {json}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn a_gap_equal_to_one_stored_transaction_names_that_transaction() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, uid) = bootstrap(&app, &pool).await;
    let account = seed_account(&pool, uid, "Banamex").await;

    // A hand-typed twin of a statement charge, worded differently so the
    // dedup signature does NOT match. After the import the app would sit 300
    // below the bank — and that 300 is exactly this row.
    let stray = seed_tx(
        &pool,
        uid,
        account,
        "2026-01-14",
        "-300.00",
        "oxxo (typed by hand)",
        false,
    )
    .await;

    let (status, json) = reconcile(
        &app,
        &cookie,
        &json!({ "accounts": [{
            "account_id": account.to_string(),
            "transactions": january("ene.pdf"),
        }]}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{json}");

    let stmt = &json["accounts"][0]["statements"][0];
    assert_eq!(
        stmt["status"], "explained_by_existing_transactions",
        "{json}"
    );
    assert!(approx(&stmt["difference"], 300.0), "{json}");
    assert!(approx(&stmt["computed_closing_balance"], 850.0), "{json}");
    let candidates = stmt["candidates"].as_array().expect("candidates array");
    assert_eq!(candidates.len(), 1, "{json}");
    assert_eq!(
        candidates[0]["transaction_id"],
        json!(stray.to_string()),
        "the specific stored row is named, not just the number: {json}"
    );
    assert_eq!(candidates[0]["kind"], "double_entry_in_period", "{json}");
    assert!(approx(&candidates[0]["amount"], -300.0), "{json}");
}

#[tokio::test]
#[serial_test::serial]
async fn an_unexplained_gap_is_reported_without_a_candidate() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, uid) = bootstrap(&app, &pool).await;
    let account = seed_account(&pool, uid, "Banamex").await;

    // The bank's own running balance jumps: a mid-period fee the parser never
    // emitted as a row. Nothing in the account explains it — and the import
    // must still be offered.
    let rows = vec![
        stmt_row(
            "2026-01-05",
            "-200.00",
            "COMPRA OXXO",
            Some("800.00"),
            "ene.pdf",
        ),
        stmt_row(
            "2026-01-20",
            "-150.00",
            "PAGO CFE",
            Some("610.00"),
            "ene.pdf",
        ),
    ];
    let (status, json) = reconcile(
        &app,
        &cookie,
        &json!({ "accounts": [{ "account_id": account.to_string(), "transactions": rows }]}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "the check never blocks: {json}");

    let stmt = &json["accounts"][0]["statements"][0];
    assert_eq!(stmt["status"], "unexplained", "{json}");
    assert!(approx(&stmt["difference"], -40.0), "{json}");
    assert_eq!(stmt["candidates"], json!([]), "{json}");
    assert_eq!(stmt["unavailable_reason"], Value::Null, "{json}");
}

#[tokio::test]
#[serial_test::serial]
async fn a_statement_without_a_running_balance_is_unavailable_not_a_false_zero() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, uid) = bootstrap(&app, &pool).await;
    let account = seed_account(&pool, uid, "CetesDirecto").await;

    // A CSV / movement-list statement: no SALDO column anywhere. Reporting
    // `difference: 0` here would be a lie the UI would render green.
    let rows = vec![
        stmt_row("2026-01-05", "-200.00", "COMPRA", None, "movs.csv"),
        stmt_row("2026-01-20", "500.00", "PREMIO", None, "movs.csv"),
    ];
    let (status, json) = reconcile(
        &app,
        &cookie,
        &json!({ "accounts": [{ "account_id": account.to_string(), "transactions": rows }]}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{json}");

    let stmt = &json["accounts"][0]["statements"][0];
    assert_eq!(stmt["status"], "unavailable", "{json}");
    assert_eq!(stmt["unavailable_reason"], "no_running_balance", "{json}");
    assert_eq!(
        stmt["difference"],
        Value::Null,
        "the field must be present and null — never a false zero: {json}"
    );
    assert_eq!(stmt["statement_closing_balance"], Value::Null, "{json}");
    assert_eq!(stmt["computed_closing_balance"], Value::Null, "{json}");
    assert_eq!(
        json["accounts"][0]["status"], "unavailable",
        "an unchecked statement must not roll up to green: {json}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn a_lone_period_total_marker_is_reported_as_unavailable() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, uid) = bootstrap(&app, &pool).await;
    let account = seed_account(&pool, uid, "Nu").await;

    // Nu's "Saldo al generar" / cetes' "Total final": ONE balance stamped on
    // the last row for the snapshot back-fill, not a running ledger. There is
    // no opening balance to anchor on.
    let rows = vec![
        stmt_row("2026-01-05", "-200.00", "COMPRA", None, "nu.pdf"),
        stmt_row("2026-01-12", "500.00", "DEPOSITO", None, "nu.pdf"),
        stmt_row("2026-01-20", "-150.00", "PAGO", Some("32285.60"), "nu.pdf"),
    ];
    let (status, json) = reconcile(
        &app,
        &cookie,
        &json!({ "accounts": [{ "account_id": account.to_string(), "transactions": rows }]}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{json}");

    let stmt = &json["accounts"][0]["statements"][0];
    assert_eq!(stmt["status"], "unavailable", "{json}");
    assert_eq!(stmt["unavailable_reason"], "balance_marker_only", "{json}");
    assert_eq!(stmt["difference"], Value::Null, "{json}");
}

#[tokio::test]
#[serial_test::serial]
async fn a_multi_account_import_reports_each_account_separately() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, uid) = bootstrap(&app, &pool).await;
    let clean = seed_account(&pool, uid, "Banamex").await;
    let messy = seed_account(&pool, uid, "BBVA").await;

    // The second account carries a stored row the statement doesn't know about.
    let stray = seed_tx(
        &pool,
        uid,
        messy,
        "2026-01-14",
        "-300.00",
        "cargo capturado a mano",
        false,
    )
    .await;

    let (status, json) = reconcile(
        &app,
        &cookie,
        &json!({ "accounts": [
            { "account_id": clean.to_string(), "transactions": january("banamex-ene.pdf") },
            { "account_id": messy.to_string(),  "transactions": january("bbva-ene.pdf") },
        ]}),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{json}");

    let accounts = json["accounts"].as_array().expect("accounts array");
    assert_eq!(accounts.len(), 2, "{json}");
    assert_eq!(accounts[0]["account_id"], json!(clean.to_string()));
    assert_eq!(accounts[0]["account_name"], "Banamex");
    assert_eq!(accounts[0]["status"], "reconciled", "{json}");
    assert_eq!(accounts[0]["statements"][0]["file"], "banamex-ene.pdf");

    assert_eq!(accounts[1]["account_id"], json!(messy.to_string()));
    assert_eq!(
        accounts[1]["status"], "explained_by_existing_transactions",
        "one account reconciling must not mask the other: {json}"
    );
    assert_eq!(
        accounts[1]["statements"][0]["candidates"][0]["transaction_id"],
        json!(stray.to_string()),
        "{json}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn reconcile_does_not_cross_user_boundaries() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie_a, _uid_a) = bootstrap(&app, &pool).await;
    let uid_b = second_user(&pool).await;
    let account_b = seed_account(&pool, uid_b, "B-Banamex").await;
    // B has a stray row that WOULD explain a gap — A must learn nothing about
    // it, not even by the shape of the answer.
    seed_tx(
        &pool,
        uid_b,
        account_b,
        "2026-01-14",
        "-300.00",
        "b's private row",
        false,
    )
    .await;

    let (status, json) = reconcile(
        &app,
        &cookie_a,
        &json!({ "accounts": [{
            "account_id": account_b.to_string(),
            "transactions": january("ene.pdf"),
        }]}),
    )
    .await;
    assert_eq!(
        status,
        StatusCode::NOT_FOUND,
        "another user's account must 404, not reconcile: {json}"
    );
    let body = json.to_string();
    assert!(
        !body.contains("b's private row") && !body.contains("300"),
        "no detail about B's ledger may leak: {body}"
    );
}
