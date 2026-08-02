//! HTTP-level integration tests for the import cleanup / destructive
//! endpoints: `POST /api/imports/check-duplicates`, `DELETE
//! /api/imports/batches/{id}` (undo an import), and `POST
//! /api/imports/transactions/bulk-delete` — happy paths plus the isolation
//! invariant that matters most for destructive routes: user B must not be
//! able to delete (or probe) user A's rows, and a cross-user attempt must
//! leave the rows demonstrably present.
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
    .expect("truncate import tables");

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
            "(skipping: set {TEST_DB_VAR}=postgres://user:pass@host/db to enable import-endpoint integration tests)"
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

/// A second, fully-owner-role user with a real session cookie — so the
/// cross-user assertions test pure `user_id` scoping, not the role gate.
async fn second_user(pool: &PgPool) -> (String, Uuid) {
    let user_id: Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, email, password_hash) \
         VALUES ('other', 'other@example.com', 'x') RETURNING id",
    )
    .fetch_one(pool)
    .await
    .expect("seed second user");
    let session = patrimonio::services::sessions::create_session(pool, user_id, None, None)
        .await
        .expect("mint session for second user");
    (session.token, user_id)
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
/// `src/api/imports.rs` (`manual:{date}:{amount}:{lowercased desc, 50
/// chars}`), because check-duplicates only flags rows whose stored
/// `external_id` equals the signature it computes for the submitted rows.
fn sig(date: &str, amount: &str, desc: &str) -> String {
    format!(
        "manual:{date}:{amount}:{}",
        desc.to_lowercase().chars().take(50).collect::<String>()
    )
}

/// Insert an already-imported transaction row for `user_id`.
#[allow(clippy::too_many_arguments)]
async fn seed_tx(
    pool: &PgPool,
    user_id: Uuid,
    account_id: Uuid,
    date: &str,
    amount: &str,
    desc: &str,
    batch_id: Option<Uuid>,
    source_id: &str,
) {
    sqlx::query(
        "INSERT INTO transactions \
         (account_id, external_id, date, description, amount, currency, \
          source, source_id, user_id, import_batch_id, import_file) \
         VALUES ($1, $2, $3::date, $4, $5::numeric, 'MXN', 'csv', $6, $7, $8, 'stmt.pdf')",
    )
    .bind(account_id)
    .bind(sig(date, amount, desc))
    .bind(date)
    .bind(desc)
    .bind(amount)
    .bind(source_id)
    .bind(user_id)
    .bind(batch_id)
    .execute(pool)
    .await
    .expect("seed transaction");
}

async fn tx_count(pool: &PgPool, user_id: Uuid) -> i64 {
    sqlx::query_scalar("SELECT COUNT(*) FROM transactions WHERE user_id = $1")
        .bind(user_id)
        .fetch_one(pool)
        .await
        .unwrap()
}

/// One ParsedTransaction-shaped JSON row for check-duplicates.
fn parsed_tx(date: &str, amount: &str, desc: &str) -> Value {
    json!({
        "date": date,
        "description": desc,
        "amount": amount,
        "currency": "MXN",
    })
}

// ---------------------------------------------------------------------------

#[tokio::test]
#[serial_test::serial]
async fn check_duplicates_flags_only_already_imported_rows() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie, uid) = bootstrap(&app, &pool).await;
    let account = seed_account(&pool, uid, "Banamex").await;

    // One row already imported under the exact signature confirm would use.
    seed_tx(
        &pool,
        uid,
        account,
        "2026-03-15",
        "-50.00",
        "COMPRA OXXO",
        None,
        "csv_import",
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/imports/check-duplicates",
            Some(&json!({
                "account_id": account.to_string(),
                "transactions": [
                    parsed_tx("2026-03-15", "-50.00", "COMPRA OXXO"),
                    parsed_tx("2026-03-16", "-75.25", "SUPER SORIANA"),
                ],
            })),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(
        json["duplicate_indices"],
        json!([0]),
        "only the already-imported row (index 0) is a duplicate: {json}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn check_duplicates_does_not_cross_user_boundaries() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie_a, _uid_a) = bootstrap(&app, &pool).await;
    let (_cookie_b, uid_b) = second_user(&pool).await;
    let account_b = seed_account(&pool, uid_b, "B-Banamex").await;

    // B has this exact row imported. A probing with B's account id must
    // learn NOTHING — the query is (account_id, user_id)-scoped, so the
    // duplicate must not be reported.
    seed_tx(
        &pool,
        uid_b,
        account_b,
        "2026-03-15",
        "-50.00",
        "COMPRA OXXO",
        None,
        "csv_import",
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/imports/check-duplicates",
            Some(&json!({
                "account_id": account_b.to_string(),
                "transactions": [parsed_tx("2026-03-15", "-50.00", "COMPRA OXXO")],
            })),
            Some(&cookie_a),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(
        json["duplicate_indices"],
        json!([]),
        "another user's rows must not be probeable via check-duplicates: {json}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn undo_batch_deletes_own_rows_but_not_another_users() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie_a, uid_a) = bootstrap(&app, &pool).await;
    let (cookie_b, uid_b) = second_user(&pool).await;
    let account_a = seed_account(&pool, uid_a, "A-Banamex").await;
    let account_b = seed_account(&pool, uid_b, "B-Banamex").await;

    let batch_a = Uuid::new_v4();
    seed_tx(
        &pool,
        uid_a,
        account_a,
        "2026-01-05",
        "-10.00",
        "ROW A1",
        Some(batch_a),
        "csv_import",
    )
    .await;
    seed_tx(
        &pool,
        uid_a,
        account_a,
        "2026-01-06",
        "-20.00",
        "ROW A2",
        Some(batch_a),
        "csv_import",
    )
    .await;
    let batch_b = Uuid::new_v4();
    seed_tx(
        &pool,
        uid_b,
        account_b,
        "2026-01-05",
        "-30.00",
        "ROW B1",
        Some(batch_b),
        "csv_import",
    )
    .await;

    // Cross-user attempt FIRST: B "undoes" A's batch. The user_id scope must
    // make this a no-op — and A's rows must still be there afterwards.
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/imports/batches/{batch_a}"),
            None,
            Some(&cookie_b),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(json["deleted"], 0, "cross-user undo must delete nothing");
    assert_eq!(
        tx_count(&pool, uid_a).await,
        2,
        "A's rows survive B's attempt"
    );

    // Happy path: A undoes their own batch — both rows go, B's row stays.
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/imports/batches/{batch_a}"),
            None,
            Some(&cookie_a),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(json["deleted"], 2, "own undo removes the whole batch");
    assert_eq!(tx_count(&pool, uid_a).await, 0);
    assert_eq!(tx_count(&pool, uid_b).await, 1, "B's batch is untouched");
}

#[tokio::test]
#[serial_test::serial]
async fn bulk_delete_scopes_dry_runs_and_respects_imported_only() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    let (cookie_a, uid_a) = bootstrap(&app, &pool).await;
    let (cookie_b, _uid_b) = second_user(&pool).await;
    let account_a = seed_account(&pool, uid_a, "A-Banamex").await;

    // Three statement-imported rows in January, one bank-synced row in
    // January, one imported row in February (outside the range).
    for (date, amount, desc) in [
        ("2026-01-05", "-10.00", "IMP JAN 1"),
        ("2026-01-10", "-20.00", "IMP JAN 2"),
        ("2026-01-15", "-30.00", "IMP JAN 3"),
    ] {
        seed_tx(
            &pool,
            uid_a,
            account_a,
            date,
            amount,
            desc,
            None,
            "csv_import",
        )
        .await;
    }
    seed_tx(
        &pool,
        uid_a,
        account_a,
        "2026-01-12",
        "-40.00",
        "PLAID SYNCED",
        None,
        "plaid_txn_1",
    )
    .await;
    seed_tx(
        &pool,
        uid_a,
        account_a,
        "2026-02-01",
        "-50.00",
        "IMP FEB",
        None,
        "csv_import",
    )
    .await;

    let range = |dry_run: bool, imported_only: bool| {
        json!({
            "account_id": account_a.to_string(),
            "date_from": "2026-01-01",
            "date_to": "2026-01-31",
            "imported_only": imported_only,
            "dry_run": dry_run,
        })
    };

    // Dry run: reports the 3 imported-only rows and deletes nothing.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/imports/transactions/bulk-delete",
            Some(&range(true, true)),
            Some(&cookie_a),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(json["count"], 3, "dry run counts imported rows in range");
    assert_eq!(tx_count(&pool, uid_a).await, 5, "dry run deletes nothing");

    // Cross-user: B cannot bulk-delete in A's account — a foreign account id
    // reads as not-found (no existence oracle) and the rows stay.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/imports/transactions/bulk-delete",
            Some(&range(false, false)),
            Some(&cookie_b),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND, "foreign account → 404");
    assert_eq!(
        tx_count(&pool, uid_a).await,
        5,
        "A's rows survive B's attempt"
    );

    // Real delete, imported_only: the 3 January imports go; the bank-synced
    // row and the February row stay.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/imports/transactions/bulk-delete",
            Some(&range(false, true)),
            Some(&cookie_a),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(json["deleted"], 3);
    let remaining: Vec<String> =
        sqlx::query_scalar("SELECT description FROM transactions WHERE user_id = $1 ORDER BY date")
            .bind(uid_a)
            .fetch_all(&pool)
            .await
            .unwrap();
    assert_eq!(
        remaining,
        vec!["PLAID SYNCED".to_string(), "IMP FEB".to_string()],
        "bank-synced + out-of-range rows must survive imported_only delete"
    );

    // Deleting without imported_only sweeps the rest of January.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/imports/transactions/bulk-delete",
            Some(&range(false, false)),
            Some(&cookie_a),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let json = body_json(res.into_body()).await;
    assert_eq!(json["deleted"], 1, "the bank-synced January row");
    assert_eq!(
        tx_count(&pool, uid_a).await,
        1,
        "only the February row is left"
    );
}
