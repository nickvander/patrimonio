//! Regression tests for the `X-Total-Count` response header on the two
//! transaction list endpoints (`/api/dashboard/transactions` and
//! `/api/accounts/{id}/transactions`).
//!
//! The header exists so the frontend can show a stable "Showing X of N"
//! denominator instead of a total that visibly counts up while the
//! whole-history filter cascade streams pages. It is a HEADER (not a body
//! envelope) so shipped APKs that decode the body as a bare JSON array keep
//! working. The count comes from `COUNT(*) OVER ()` inside the same query,
//! so it must honor the exact list contract: user scoping, the split-parent
//! NOT EXISTS exclusion, and the currency/sign/q/exclude_linked filters —
//! and be identical on every offset page.
//!
//! Same harness rules as `dashboard_endpoints.rs`: real Postgres via
//! `PATRIMONIO_TEST_DATABASE_URL` (unset → loud skip note; set-but-broken →
//! panic in TestLockGuard), serialised via `#[serial]` + the cross-binary
//! advisory lock.

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

/// Build the full production middleware stack (CSRF outer, auth inner,
/// require_owner on business routes) — mirrors `dashboard_endpoints.rs`.
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
    .expect("truncate tables");

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
        .nest("/api/accounts", patrimonio::api::accounts::router())
        .nest("/api/dashboard", patrimonio::api::dashboard::router())
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

    Some((public.merge(protected).with_state(state), pool, lock))
}

fn skip_if_no_db<T>(result: Option<T>) -> Option<T> {
    if result.is_none() {
        eprintln!(
            "(skipping: set {TEST_DB_VAR}=postgres://user:pass@host/db to enable X-Total-Count integration tests)"
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

fn cookie_header(token: &str) -> HeaderValue {
    HeaderValue::from_str(&format!("{SESSION_COOKIE}={token}")).expect("valid cookie header")
}

fn req(method: Method, uri: &str, cookie: Option<&str>) -> Request<Body> {
    let mut builder = Request::builder().method(method).uri(uri);
    if let Some(token) = cookie {
        builder = builder.header(header::COOKIE, cookie_header(token));
    }
    builder.body(Body::empty()).unwrap()
}

/// Bootstrap the first (owner) user so the setup gate is satisfied.
async fn bootstrap(app: &Router) {
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/auth/bootstrap")
                .header("X-Requested-With", "patrimonio")
                .header(header::CONTENT_TYPE, "application/json")
                .body(Body::from(
                    serde_json::json!({
                        "username": "owner",
                        "email": "owner@example.com",
                        "password": "correcthorsebatterystaple"
                    })
                    .to_string(),
                ))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "bootstrap should succeed");
}

/// Hand-rolled additional owner + production-minted session token.
async fn seed_owner(pool: &PgPool, username: &str) -> (uuid::Uuid, String) {
    let user_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, email, password_hash, role) \
         VALUES ($1, $2, 'doesnt-matter', 'owner') RETURNING id",
    )
    .bind(username)
    .bind(format!("{username}@example.com"))
    .fetch_one(pool)
    .await
    .expect("seed owner");
    let token = patrimonio::services::sessions::create_session(pool, user_id, None, None)
        .await
        .expect("create owner session")
        .token;
    (user_id, token)
}

async fn seed_account(pool: &PgPool, user_id: uuid::Uuid, currency: &str) -> uuid::Uuid {
    let inst_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ('Bank', 'bank', 'US', 'manual', 'ok', $1) RETURNING id",
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

async fn seed_tx(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    description: &str,
    amount: &str,
    currency: &str,
) -> uuid::Uuid {
    sqlx::query_scalar(
        "INSERT INTO transactions (account_id, date, description, amount, currency, source, user_id) \
         VALUES ($1, CURRENT_DATE, $2, $3, $4, 'manual', $5) RETURNING id",
    )
    .bind(account_id)
    .bind(description)
    .bind(Decimal::from_str(amount).unwrap())
    .bind(currency)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed tx")
}

/// Like [`seed_tx`] but with an explicit posted `date` and `created_at`
/// instant, for the sync-time-vs-posted-date tests: a card transaction
/// POSTS days before the sync INSERTS it, so the two must be controllable
/// independently.
async fn seed_tx_at(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    description: &str,
    date: &str,
    created_at: &str,
) -> uuid::Uuid {
    sqlx::query_scalar(
        "INSERT INTO transactions (account_id, date, description, amount, currency, source, user_id, created_at) \
         VALUES ($1, $2::date, $3, -5.00, 'USD', 'manual', $4, $5::timestamptz) RETURNING id",
    )
    .bind(account_id)
    .bind(date)
    .bind(description)
    .bind(user_id)
    .bind(created_at)
    .fetch_one(pool)
    .await
    .expect("seed tx with created_at")
}

/// Split `parent` into two children (direct INSERTs — the split endpoint's
/// own behavior is covered elsewhere; here we only need the rows).
async fn seed_split_children(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account: uuid::Uuid,
    parent: uuid::Uuid,
) {
    for (desc, amount) in [("child a", "-10.00"), ("child b", "-15.00")] {
        sqlx::query(
            "INSERT INTO transactions (account_id, parent_id, date, description, amount, currency, source, user_id) \
             VALUES ($1, $2, CURRENT_DATE, $3, $4, 'USD', 'manual', $5)",
        )
        .bind(account)
        .bind(parent)
        .bind(desc)
        .bind(Decimal::from_str(amount).unwrap())
        .bind(user_id)
        .execute(pool)
        .await
        .expect("seed split child");
    }
}

/// Read `X-Total-Count` off a response, if present.
fn total_count(headers: &axum::http::HeaderMap) -> Option<i64> {
    headers
        .get("x-total-count")
        .and_then(|v| v.to_str().ok())
        .and_then(|s| s.parse().ok())
}

async fn get(app: &Router, uri: &str, token: &str) -> (Option<i64>, Value) {
    let res = app
        .clone()
        .oneshot(req(Method::GET, uri, Some(token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "GET {uri}");
    let total = total_count(res.headers());
    (total, body_json(res.into_body()).await)
}

#[tokio::test]
#[serial_test::serial]
async fn dashboard_total_count_excludes_split_parents_and_is_stable_across_pages() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    bootstrap(&app).await;
    let (user_id, token) = seed_owner(&pool, "counter").await;
    let account = seed_account(&pool, user_id, "USD").await;

    // 7 plain rows + 1 split parent (excluded) + its 2 children (included):
    // the list contract counts 7 + 2 = 9.
    for i in 0..7 {
        seed_tx(&pool, user_id, account, &format!("tx {i}"), "-5.00", "USD").await;
    }
    let parent = seed_tx(&pool, user_id, account, "split parent", "-25.00", "USD").await;
    seed_split_children(&pool, user_id, account, parent).await;

    let (total, body) = get(&app, "/api/dashboard/transactions?limit=4", &token).await;
    assert_eq!(
        total,
        Some(9),
        "total must exclude the split parent but include its children"
    );
    assert_eq!(body.as_array().unwrap().len(), 4, "page 1 honors limit");

    // Identical total on every offset page — that's what makes the client's
    // denominator stable while it streams pages.
    let (total2, body2) = get(&app, "/api/dashboard/transactions?limit=4&offset=4", &token).await;
    assert_eq!(total2, Some(9), "offset page carries the same total");
    assert_eq!(body2.as_array().unwrap().len(), 4);
    let (total3, body3) = get(&app, "/api/dashboard/transactions?limit=4&offset=8", &token).await;
    assert_eq!(total3, Some(9), "last page carries the same total");
    assert_eq!(body3.as_array().unwrap().len(), 1);
}

#[tokio::test]
#[serial_test::serial]
async fn dashboard_total_count_respects_filters_and_matches_paged_length() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    bootstrap(&app).await;
    let (user_id, token) = seed_owner(&pool, "filters").await;
    let usd = seed_account(&pool, user_id, "USD").await;
    let mxn = seed_account(&pool, user_id, "MXN").await;

    for i in 0..3 {
        seed_tx(
            &pool,
            user_id,
            usd,
            &format!("usd out {i}"),
            "-10.00",
            "USD",
        )
        .await;
    }
    seed_tx(&pool, user_id, usd, "PAYCHECK ACME", "500.00", "USD").await;
    let linked = seed_tx(&pool, user_id, mxn, "SPEI RECIBIDO LUIS", "3500.00", "MXN").await;
    seed_tx(&pool, user_id, mxn, "SPEI RECIBIDO OTRO", "3500.00", "MXN").await;

    // Reconcile one MXN inflow to a loan so exclude_linked bites.
    let loan_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO loans (user_id, borrower_name, principal, currency, origination_date) \
         VALUES ($1, 'Luis', 3500, 'MXN', CURRENT_DATE) RETURNING id",
    )
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed loan");
    sqlx::query(
        "INSERT INTO loan_payments (user_id, loan_id, installment_number, actual_tx_id, paid_amount) \
         VALUES ($1, $2, 1, $3, 3500)",
    )
    .bind(user_id)
    .bind(loan_id)
    .bind(linked)
    .execute(&pool)
    .await
    .expect("seed loan payment");

    // For each filter combination the header total must equal the number of
    // rows the same filter yields when fully paged (limit large enough).
    for uri in [
        "/api/dashboard/transactions?currency=MXN",
        "/api/dashboard/transactions?sign=inflow",
        "/api/dashboard/transactions?q=spei",
        "/api/dashboard/transactions?currency=MXN&sign=inflow&exclude_linked=true",
    ] {
        let (total, body) = get(&app, &format!("{uri}&limit=200"), &token).await;
        let rows = body.as_array().unwrap().len() as i64;
        assert_eq!(
            total,
            Some(rows),
            "{uri}: header total must equal the fully-paged filtered length"
        );
    }
    // Spot values: 2 MXN rows, 2 unlinked+linked SPEI hits, 1 after exclude.
    let (mxn_total, _) = get(
        &app,
        "/api/dashboard/transactions?currency=MXN&limit=200",
        &token,
    )
    .await;
    assert_eq!(mxn_total, Some(2));
    let (excl_total, _) = get(
        &app,
        "/api/dashboard/transactions?currency=MXN&sign=inflow&exclude_linked=true&limit=200",
        &token,
    )
    .await;
    assert_eq!(
        excl_total,
        Some(1),
        "exclude_linked drops the reconciled row"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn total_count_is_user_scoped_and_zero_on_empty_first_page() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    bootstrap(&app).await;
    let (user_a, token_a) = seed_owner(&pool, "alice").await;
    let (_user_b, token_b) = seed_owner(&pool, "bob").await;
    let account_a = seed_account(&pool, user_a, "USD").await;
    for i in 0..5 {
        seed_tx(
            &pool,
            user_a,
            account_a,
            &format!("a tx {i}"),
            "-1.00",
            "USD",
        )
        .await;
    }

    let (total_a, body_a) = get(&app, "/api/dashboard/transactions", &token_a).await;
    assert_eq!(total_a, Some(5));
    assert_eq!(body_a.as_array().unwrap().len(), 5);

    // User B has no transactions: an empty 200 array with X-Total-Count: 0
    // — a successful empty FIRST page proves the total, and B's own zero
    // is never a reflection of A's count.
    let (total_b, body_b) = get(&app, "/api/dashboard/transactions", &token_b).await;
    assert_eq!(
        total_b,
        Some(0),
        "a successful empty first page proves the total is 0"
    );
    assert_eq!(body_b.as_array().unwrap().len(), 0);

    // B can also never see A's account list. (The per-account endpoint's
    // cross-tenant behavior is asserted in the account test below.)
}

#[tokio::test]
#[serial_test::serial]
async fn account_transactions_total_count_same_contract() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    bootstrap(&app).await;
    let (user_id, token) = seed_owner(&pool, "acctcount").await;
    let (_other_user, other_token) = seed_owner(&pool, "intruder").await;
    let account = seed_account(&pool, user_id, "USD").await;
    let other_account = seed_account(&pool, user_id, "USD").await;

    for i in 0..6 {
        seed_tx(
            &pool,
            user_id,
            account,
            &format!("acct tx {i}"),
            "-2.00",
            "USD",
        )
        .await;
    }
    // A row on ANOTHER account of the same user must not count.
    seed_tx(&pool, user_id, other_account, "elsewhere", "-2.00", "USD").await;
    // Split parent on this account: excluded; children included → 6 + 2 = 8.
    let parent = seed_tx(&pool, user_id, account, "split parent", "-25.00", "USD").await;
    seed_split_children(&pool, user_id, account, parent).await;

    let base = format!("/api/accounts/{account}/transactions");
    let (total, body) = get(&app, &format!("{base}?limit=3"), &token).await;
    assert_eq!(
        total,
        Some(8),
        "account total excludes split parent, includes children"
    );
    assert_eq!(body.as_array().unwrap().len(), 3);
    // Stable across offset pages.
    let (total2, body2) = get(&app, &format!("{base}?limit=3&offset=6"), &token).await;
    assert_eq!(total2, Some(8));
    assert_eq!(body2.as_array().unwrap().len(), 2);

    // Another user probing this account id: empty list with a total of 0 —
    // indistinguishable from a brand-new empty account, so the real count
    // never leaks across tenants.
    let (other_total, other_body) = get(&app, &base, &other_token).await;
    assert_eq!(
        other_total,
        Some(0),
        "cross-tenant probe reads as an empty account (total 0), never the owner's count"
    );
    assert_eq!(other_body.as_array().unwrap().len(), 0);
}

/// Fix A (since-visit drill-downs): both list endpoints now carry an
/// RFC3339 `created_at` (row INSERT time — sync/import/manual-add) on
/// every transaction, distinct from the bank-POSTED `date`. The frontend's
/// "New since your last visit" filter matches on it, because a posted-date
/// window can never faithfully show rows that POSTED before the anchor but
/// were SYNCED after it.
#[tokio::test]
#[serial_test::serial]
async fn created_at_present_parseable_and_ordered_on_both_endpoints() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    bootstrap(&app).await;
    let (user_id, token) = seed_owner(&pool, "createdat").await;
    let account = seed_account(&pool, user_id, "USD").await;

    // The exact user-repro shape: the newest-POSTED row was synced FIRST,
    // and an older-posted row arrived in a LATER sync — created_at order
    // deliberately disagrees with posted-date order.
    seed_tx_at(
        &pool,
        user_id,
        account,
        "posted jul 30, synced jul 29",
        "2026-07-30",
        "2026-07-29T18:00:00Z",
    )
    .await;
    seed_tx_at(
        &pool,
        user_id,
        account,
        "posted jul 28, synced aug 1",
        "2026-07-28",
        "2026-08-01T02:00:00Z",
    )
    .await;
    seed_tx_at(
        &pool,
        user_id,
        account,
        "posted jul 28, synced jul 29",
        "2026-07-28",
        "2026-07-29T12:00:00Z",
    )
    .await;

    for uri in [
        "/api/dashboard/transactions".to_string(),
        format!("/api/accounts/{account}/transactions"),
    ] {
        let (_, body) = get(&app, &uri, &token).await;
        let rows = body.as_array().unwrap();
        assert_eq!(rows.len(), 3, "{uri}: all seeded rows returned");

        let parsed: Vec<(chrono::NaiveDate, chrono::DateTime<chrono::FixedOffset>)> = rows
            .iter()
            .map(|r| {
                let date: chrono::NaiveDate = r["date"]
                    .as_str()
                    .expect("date is a string")
                    .parse()
                    .expect("date parses");
                let created = chrono::DateTime::parse_from_rfc3339(
                    r["created_at"].as_str().expect("created_at is a string"),
                )
                .expect("created_at parses as RFC3339");
                (date, created)
            })
            .collect();

        // List contract: ORDER BY date DESC, created_at DESC — sane order
        // means (date, created_at) is non-increasing lexicographically.
        for pair in parsed.windows(2) {
            let (d1, c1) = &pair[0];
            let (d2, c2) = &pair[1];
            assert!(
                d1 > d2 || (d1 == d2 && c1 >= c2),
                "{uri}: rows must be ordered by (date DESC, created_at DESC), got ({d1}, {c1}) before ({d2}, {c2})"
            );
        }
        // And the seeded instants round-trip: the Aug 1 sync is among them.
        assert!(
            parsed.iter().any(|(_, c)| *c
                == "2026-08-01T02:00:00Z"
                    .parse::<chrono::DateTime<chrono::FixedOffset>>()
                    .unwrap()),
            "{uri}: the late-synced row's created_at survives the trip"
        );
    }
}

/// Fix B: deleting the last rows must not leave a stale total. A
/// successful empty FIRST page (offset == 0) now carries `X-Total-Count:
/// 0` (the total is provably zero); an empty page BEYOND the end (offset
/// past the last row) still carries no header — it proves nothing.
#[tokio::test]
#[serial_test::serial]
async fn empty_first_page_reports_zero_but_offset_beyond_end_stays_absent() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    bootstrap(&app).await;
    let (user_id, token) = seed_owner(&pool, "emptier").await;
    let account = seed_account(&pool, user_id, "USD").await;
    for i in 0..3 {
        seed_tx(
            &pool,
            user_id,
            account,
            &format!("doomed {i}"),
            "-1.00",
            "USD",
        )
        .await;
    }

    let acct_base = format!("/api/accounts/{account}/transactions");

    // Populated: both endpoints agree on the non-zero total…
    let (total, _) = get(&app, "/api/dashboard/transactions", &token).await;
    assert_eq!(total, Some(3));
    let (acct_total, _) = get(&app, &acct_base, &token).await;
    assert_eq!(acct_total, Some(3));

    // …and an empty offset-BEYOND-END page proves nothing → no header
    // (the window function had no rows to ride on, and offset != 0).
    for uri in [
        "/api/dashboard/transactions?limit=4&offset=50".to_string(),
        format!("{acct_base}?limit=4&offset=50"),
    ] {
        let (beyond_total, beyond_body) = get(&app, &uri, &token).await;
        assert_eq!(
            beyond_total, None,
            "{uri}: empty page beyond the end must carry no header"
        );
        assert_eq!(beyond_body.as_array().unwrap().len(), 0);
    }

    // Delete everything (the user clearing out their manual rows)…
    sqlx::query("DELETE FROM transactions WHERE user_id = $1")
        .bind(user_id)
        .execute(&pool)
        .await
        .expect("delete all rows");

    // …then the offset-0 fetch must report the provable zero, so the
    // client can drop its remembered "of 3".
    for uri in ["/api/dashboard/transactions".to_string(), acct_base] {
        let (zero_total, zero_body) = get(&app, &uri, &token).await;
        assert_eq!(
            zero_total,
            Some(0),
            "{uri}: successful empty first page must report total 0"
        );
        assert_eq!(zero_body.as_array().unwrap().len(), 0);
    }
}
