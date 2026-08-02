//! HTTP-level integration tests for the genuinely-dashboard surface
//! (`/api/dashboard/*`): net-worth / portfolio history, cash flow, spending,
//! allocation, benchmarks, holdings views, since-last-login, plus the
//! role/cross-tenant middleware checks that span the dashboard routers.
//!
//! Historically this file also carried loans / accounts / institutions-sync /
//! subscriptions / fx-transfers tests (10.5k lines); those now live in their
//! own per-surface files. Shared harness + fixtures: `tests/common/fixtures.rs`.

mod common;
use common::fixtures::*;

// =====================================================================
// /api/dashboard/transactions — provenance (fix-3)
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn transactions_listing_includes_source_field() {
    // fix-3: the listing omitted `source`, so the frontend assumed
    // 'plaid' and stamped "Synced via Plaid" on hand-entered rows.
    // The field must be present on every row (explicitly null at
    // worst — provenance is never left to be guessed client-side).
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let manual = seed_tx(&pool, user_id, account, "CRITIC TEST coffee", "-4.50").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/transactions?limit=100",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().unwrap();
    let row = rows
        .iter()
        .find(|r| r["id"].as_str().unwrap_or_default() == manual.to_string())
        .expect("seeded manual tx should be listed");
    assert_eq!(
        row["source"], "manual",
        "listing must carry the row's provenance"
    );
    // Every row serializes the key, even if the column were null.
    for r in rows {
        assert!(
            r.as_object().unwrap().contains_key("source"),
            "source key must be present on every row"
        );
    }
}

#[tokio::test]
#[serial_test::serial]
async fn transactions_listing_includes_user_notes_and_user_category() {
    // manual-tx-edit QA fix: this feed powers the main Transactions tab,
    // whose "Edit transaction" dialog prefills notes/category from the
    // row. The SELECT omitted user_notes/user_category, so the dialog
    // prefilled null and the subsequent PUT wrote user_notes = NULL —
    // a saved note was silently wiped by editing an unrelated field.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let noted = seed_tx(&pool, user_id, account, "CRITIC TEST noted row", "-9.99").await;
    sqlx::query(
        "UPDATE transactions SET user_notes = 'note to keep', user_category = 'Coffee' \
         WHERE id = $1 AND user_id = $2",
    )
    .bind(noted)
    .bind(user_id)
    .execute(&pool)
    .await
    .expect("stamp overrides");

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/transactions?limit=100",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().unwrap();
    let row = rows
        .iter()
        .find(|r| r["id"].as_str().unwrap_or_default() == noted.to_string())
        .expect("seeded manual tx should be listed");
    assert_eq!(
        row["user_notes"], "note to keep",
        "feed must carry the stored note — the edit dialog prefills from it"
    );
    assert_eq!(
        row["user_category"], "Coffee",
        "feed must carry the category override (user_category-first display)"
    );
    // Both keys serialize on every row (explicit null at worst), matching
    // the per-account feed's shape so both edit surfaces see one contract.
    for r in rows {
        let obj = r.as_object().unwrap();
        assert!(
            obj.contains_key("user_notes"),
            "user_notes key on every row"
        );
        assert!(
            obj.contains_key("user_category"),
            "user_category key on every row"
        );
    }
}

// =====================================================================
// /api/dashboard/since-last-login
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn since_last_login_empty_when_no_previous_login() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/since-last-login",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    // Fresh bootstrap leaves previous_login_at NULL, so we get a
    // no-op envelope with new_transactions=0.
    assert_eq!(body["new_transactions"], 0);
    assert!(body["previous_login_at"].is_null() || body["previous_login_at"] == Value::Null);
}

#[tokio::test]
#[serial_test::serial]
async fn since_last_login_counts_new_transactions() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;

    // Fake a previous login 24h ago.
    sqlx::query("UPDATE users SET previous_login_at = NOW() - INTERVAL '24 hours' WHERE id = $1")
        .bind(user_id)
        .execute(&pool)
        .await
        .unwrap();
    // Seed two transactions — both created_at NOW(), so after the anchor.
    seed_tx(&pool, user_id, account, "After anchor 1", "10.00").await;
    seed_tx(&pool, user_id, account, "After anchor 2", "20.00").await;
    // Plus one split parent + its children, which should NOT count (parents are excluded).
    let parent = seed_tx(&pool, user_id, account, "Will be split", "30.00").await;
    sqlx::query(
        "INSERT INTO transactions (account_id, parent_id, date, description, amount, currency, source, user_id) \
         VALUES ($1, $2, CURRENT_DATE, 'child1', 15.00, 'USD', 'split', $3), \
                ($1, $2, CURRENT_DATE, 'child2', 15.00, 'USD', 'split', $3)",
    )
    .bind(account)
    .bind(parent)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/since-last-login",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    // 2 non-split + 2 children = 4. (The parent row is now hidden by
    // the NOT EXISTS-children filter — that's the contract.)
    assert_eq!(body["new_transactions"], 4);
    assert!(body["previous_login_at"].as_str().is_some());
}

#[tokio::test]
#[serial_test::serial]
async fn since_last_login_anchors_on_the_last_visit_not_the_last_login() {
    // Regression guard for the reported bug: a session survives for weeks,
    // so anchoring on `previous_login_at` told a user who opens the app
    // every day "143 new transactions since your last visit · Jul 13".
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;

    // Signed in a month ago, last actually looked at the dashboard
    // yesterday — the shape of a phone that stays logged in.
    sqlx::query(
        "UPDATE users SET previous_login_at = NOW() - INTERVAL '30 days', \
                          last_visit_at = NOW() - INTERVAL '1 day' \
         WHERE id = $1",
    )
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    // Landed a week ago (before yesterday's visit — already seen) and an
    // hour ago (genuinely new).
    seed_tx_created_hours_ago(&pool, user_id, account, "seen last week", 24 * 7).await;
    seed_tx_created_hours_ago(&pool, user_id, account, "actually new", 1).await;

    let body = since_last_login_body(&app, &token).await;
    assert_eq!(
        body["new_transactions"], 1,
        "only what arrived since the last VISIT counts — anchoring on the \
         30-day-old login would have reported both: {body}"
    );
    let anchor = body["previous_login_at"].as_str().expect("anchor present");
    let anchor = chrono::DateTime::parse_from_rfc3339(anchor).expect("rfc3339 anchor");
    let age_hours = (chrono::Utc::now() - anchor.with_timezone(&chrono::Utc)).num_hours();
    assert!(
        (20..30).contains(&age_hours),
        "the anchor is yesterday's visit, not the month-old login: {age_hours}h"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn reloading_within_a_visit_does_not_move_the_anchor() {
    // The summary must not evaporate while the user is reading it: a
    // second dashboard load in the same sitting is the same visit.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;

    sqlx::query(
        "UPDATE users SET previous_login_at = NOW() - INTERVAL '30 days', \
                          last_visit_at = NOW() - INTERVAL '1 day' \
         WHERE id = $1",
    )
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();
    // Arrived 6h ago: new relative to yesterday's visit, but older than
    // the 5h-ago visit the anchor advances to at the end of this test.
    seed_tx_created_hours_ago(&pool, user_id, account, "actually new", 6).await;

    let first = since_last_login_body(&app, &token).await;
    let second = since_last_login_body(&app, &token).await;
    assert_eq!(
        first["previous_login_at"], second["previous_login_at"],
        "a refresh inside the visit window keeps the same anchor: \
         {first} vs {second}"
    );
    assert_eq!(
        second["new_transactions"], 1,
        "…and therefore still reports what's new: {second}"
    );

    // Only once the gap has passed does the anchor advance to the visit
    // that just ended.
    sqlx::query("UPDATE users SET last_visit_at = NOW() - INTERVAL '5 hours' WHERE id = $1")
        .bind(user_id)
        .execute(&pool)
        .await
        .unwrap();
    let third = since_last_login_body(&app, &token).await;
    assert_ne!(
        third["previous_login_at"], second["previous_login_at"],
        "a gap starts a new visit and moves the anchor: {third}"
    );
    assert_eq!(
        third["new_transactions"], 0,
        "nothing has arrived since that visit ended: {third}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn since_last_login_largest_move_carries_account_id() {
    // Additive-field regression (P1-2): largest_move now names the moved
    // account by id (uuid as text) so the client can scope its drill-down
    // to the account. account_name / delta_usd must be unchanged.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;

    // Anchor 24h ago, snapshots straddling it: $1,000.00 two days back,
    // $3,612.87 now → a +$2,612.87 move on this depository account.
    sqlx::query("UPDATE users SET previous_login_at = NOW() - INTERVAL '24 hours' WHERE id = $1")
        .bind(user_id)
        .execute(&pool)
        .await
        .unwrap();
    sqlx::query(
        "INSERT INTO balance_snapshots \
             (account_id, balance, balance_usd, as_of_date, currency, user_id, created_at) \
         VALUES ($1, 1000.00, 1000.00, CURRENT_DATE - 2, 'USD', $2, NOW() - INTERVAL '48 hours'), \
                ($1, 3612.87, 3612.87, CURRENT_DATE, 'USD', $2, NOW())",
    )
    .bind(account)
    .bind(user_id)
    .execute(&pool)
    .await
    .expect("seed straddling snapshots");

    let body = since_last_login_body(&app, &token).await;
    let mv = &body["largest_move"];
    assert!(mv.is_object(), "largest_move present: {body}");
    assert_eq!(
        mv["account_id"],
        account.to_string(),
        "the additive account_id is the seeded account's uuid: {mv}"
    );
    // The pre-existing fields are untouched by the addition.
    assert_eq!(mv["account_name"], "Checking", "{mv}");
    let delta = mv["delta_usd"].as_f64().expect("delta_usd is a number");
    assert!(
        (delta - 2612.87).abs() < 0.01,
        "delta_usd unchanged by the additive field: {delta}"
    );
    // FIX-2: the additive institution_name disambiguates generic account
    // nicknames on the client ("Cards · SoFi"). seed_account files the
    // account under the "Test Bank" institution.
    assert_eq!(
        mv["institution_name"], "Test Bank",
        "largest_move carries the account's institution name: {mv}"
    );
    // The omission contract for accounts without an institution (None →
    // key absent, not null) can't be seeded through the DB — accounts.
    // institution_id is NOT NULL — so it's pinned by the serde unit test
    // `balance_move_omits_absent_institution_name` in api/dashboard.rs.
}

// =====================================================================
// /api/dashboard/net-worth-history (the SQL-rewritten endpoint)
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn net_worth_history_aggregates_per_date_and_institution() {
    // Seed snapshots across two institutions on two dates so we can
    // check the per-institution map. This exercises the SQL rewrite
    // (jsonb_object_agg) directly.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst1, account1) = seed_account(&pool, user_id).await;
    // Second institution with a different name.
    let inst2: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ('Brokerage', 'brokerage', 'US', 'manual', 'ok', $1) RETURNING id",
    )
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    let account2: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'IRA', 'investment', 'USD', 5000.00, $2) RETURNING id",
    )
    .bind(inst2)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();

    // Snapshots on two days for both accounts.
    let insert_snap = |acct: uuid::Uuid, balance: &'static str, day: &'static str| {
        let pool = pool.clone();
        async move {
            sqlx::query(
                "INSERT INTO balance_snapshots (account_id, balance, balance_usd, as_of_date, currency, user_id) \
                 VALUES ($1, $2::numeric, $2::numeric, $3::date, 'USD', $4)",
            )
            .bind(acct)
            .bind(balance)
            .bind(day)
            .bind(user_id)
            .execute(&pool)
            .await
            .unwrap();
        }
    };
    insert_snap(account1, "1000.00", "2026-05-01").await;
    insert_snap(account2, "5000.00", "2026-05-01").await;
    insert_snap(account1, "1100.00", "2026-05-02").await;
    insert_snap(account2, "5200.00", "2026-05-02").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/net-worth-history",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().unwrap();
    assert_eq!(rows.len(), 2, "two distinct as_of_dates");
    // Rows are ascending by date.
    assert_eq!(rows[0]["date"], "2026-05-01");
    assert_eq!(rows[1]["date"], "2026-05-02");
    // Day 1 net worth = 1000 + 5000.
    assert!((rows[0]["net_worth"].as_f64().unwrap() - 6000.0).abs() < 0.01);
    // Day 2 net worth = 1100 + 5200.
    assert!((rows[1]["net_worth"].as_f64().unwrap() - 6300.0).abs() < 0.01);
    // Per-institution map is populated.
    let by_inst = rows[1]["by_institution"].as_object().unwrap();
    assert!((by_inst["Test Bank"].as_f64().unwrap() - 1100.0).abs() < 0.01);
    assert!((by_inst["Brokerage"].as_f64().unwrap() - 5200.0).abs() < 0.01);
}

#[tokio::test]
#[serial_test::serial]
async fn net_worth_history_carries_infrequently_snapshotted_accounts_forward() {
    // The HealthEquity bug: an account that snapshots on day 1 but NOT day 2
    // (a weekly-syncing HSA next to daily-syncing Plaid accounts) must still
    // be valued on day 2 at its last-known balance — otherwise it vanishes
    // from that date's net worth AND by_institution, and the movers
    // attribution reads its full balance as "growth from zero".
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst1, account1) = seed_account(&pool, user_id).await; // "Test Bank"
    let inst2: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ('HealthEquity', 'brokerage', 'US', 'manual', 'ok', $1) RETURNING id",
    )
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    let account2: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'HSA', 'investment', 'USD', 48000.00, $2) RETURNING id",
    )
    .bind(inst2)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    let insert_snap = |acct: uuid::Uuid, balance: &'static str, day: &'static str| {
        let pool = pool.clone();
        async move {
            sqlx::query(
                "INSERT INTO balance_snapshots (account_id, balance, balance_usd, as_of_date, currency, user_id) \
                 VALUES ($1, $2::numeric, $2::numeric, $3::date, 'USD', $4)",
            )
            .bind(acct).bind(balance).bind(day).bind(user_id)
            .execute(&pool).await.unwrap();
        }
    };
    // account1 snapshots both days; the HSA only on day 1.
    insert_snap(account1, "1000.00", "2026-05-01").await;
    insert_snap(account2, "48000.00", "2026-05-01").await;
    insert_snap(account1, "1100.00", "2026-05-02").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/net-worth-history",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().unwrap();
    assert_eq!(rows.len(), 2, "two distinct as_of_dates");
    // Day 2 must still include the HSA's carried-forward $48k:
    // 1100 + 48000 = 49100 (before the fix this was just 1100).
    assert!(
        (rows[1]["net_worth"].as_f64().unwrap() - 49100.0).abs() < 0.01,
        "day-2 net worth carries the HSA forward, got {}",
        rows[1]["net_worth"]
    );
    let by_inst = rows[1]["by_institution"].as_object().unwrap();
    assert!(
        (by_inst["HealthEquity"].as_f64().unwrap() - 48000.0).abs() < 0.01,
        "HealthEquity present on day 2 via carry-forward, not missing"
    );
    assert!((by_inst["Test Bank"].as_f64().unwrap() - 1100.0).abs() < 0.01);
}

#[tokio::test]
#[serial_test::serial]
async fn net_worth_history_handles_liabilities() {
    // A credit-card liability should show up as a NEGATIVE in
    // by_institution AND reduce net_worth. Tests the is_liability
    // classifier wired into the new CTE.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let inst: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ('Plastic Co', 'bank', 'US', 'manual', 'ok', $1) RETURNING id",
    )
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    let card: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Visa', 'credit', 'USD', 500.00, $2) RETURNING id",
    )
    .bind(inst)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO balance_snapshots (account_id, balance, balance_usd, as_of_date, currency, user_id) \
         VALUES ($1, 500.00, 500.00, '2026-05-01'::date, 'USD', $2)",
    )
    .bind(card)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/net-worth-history",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let row = &body.as_array().unwrap()[0];
    assert!((row["total_liabilities"].as_f64().unwrap() - 500.0).abs() < 0.01);
    assert!((row["total_assets"].as_f64().unwrap() - 0.0).abs() < 0.01);
    assert!((row["net_worth"].as_f64().unwrap() - -500.0).abs() < 0.01);
    let by_inst = row["by_institution"].as_object().unwrap();
    assert!((by_inst["Plastic Co"].as_f64().unwrap() - -500.0).abs() < 0.01);
}

// =====================================================================
// Multi-user roles — require_owner middleware
// =====================================================================
// The `require_owner` middleware sits on every business sub-router
// in `main.rs` and 403's mutating requests from read-only users
// while leaving GETs untouched.

#[tokio::test]
#[serial_test::serial]
async fn read_only_user_can_get_but_not_mutate() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    // Bootstrap the owner first (bootstrap path always creates an
    // owner; the role split kicks in for invited users).
    let (_owner_token, _owner_id) = bootstrap(&app, &pool).await;
    // Hand-roll a read-only user.
    let ro_user_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, email, password_hash, role) \
         VALUES ('viewer', 'viewer@example.com', 'doesnt-matter', 'read_only') \
         RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .expect("seed read-only user");
    let ro_token = patrimonio::services::sessions::create_session(&pool, ro_user_id, None, None)
        .await
        .expect("create read-only session")
        .token;

    // GET passes — read-only is allowed to read their own data.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/transactions",
            None,
            Some(&ro_token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    // POST on a business route is rejected with 403.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/dashboard/subscriptions/ignore",
            Some(&serde_json::json!({"merchant": "test"})),
            Some(&ro_token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);
    let body = body_json(res.into_body()).await;
    assert!(body["error"].as_str().unwrap_or("").contains("read-only"));
}

#[tokio::test]
#[serial_test::serial]
async fn read_only_user_can_still_log_out() {
    // require_owner does NOT apply to /api/auth/* — a read-only user
    // must be able to manage their own session (logout, change
    // password, manage their own passkeys).
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (_owner_token, _owner_id) = bootstrap(&app, &pool).await;
    let ro_user_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, email, password_hash, role) \
         VALUES ('viewer2', 'viewer2@example.com', 'doesnt-matter', 'read_only') \
         RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .expect("seed read-only user");
    let ro_token = patrimonio::services::sessions::create_session(&pool, ro_user_id, None, None)
        .await
        .expect("create read-only session")
        .token;

    let res = app
        .clone()
        .oneshot(req(Method::POST, "/api/auth/logout", None, Some(&ro_token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
}

#[tokio::test]
#[serial_test::serial]
async fn owner_role_passes_require_owner() {
    // Sanity check: the default owner role goes through every gate
    // for a mutating request just like before role landed.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _owner_id) = bootstrap(&app, &pool).await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/dashboard/subscriptions/ignore",
            Some(&serde_json::json!({"merchant": "ok-path"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
}

// =====================================================================
// Cross-tenant isolation
// =====================================================================
// The multi-user data model wires `user_id` predicates through ~60
// queries. This block creates two users (owner Alice + owner Bob),
// seeds account + transaction + ignored-subscription rows for each,
// then asserts every read endpoint returns ONLY the caller's data.
// Belt-and-suspenders for the predicate threading; catches any
// future query that forgets the user_id filter.

#[tokio::test]
#[serial_test::serial]
async fn cross_tenant_isolation_dashboard() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    // Bootstrap so the first-user slot is filled, then hand-roll
    // two independent owners.
    let _ = bootstrap(&app, &pool).await;
    let (alice_id, alice_token) = seed_owner(&pool, "alice").await;
    let (bob_id, bob_token) = seed_owner(&pool, "bob").await;

    // Seed one account + one transaction per user.
    let (_a_inst, a_acct) = seed_account(&pool, alice_id).await;
    let a_tx = seed_tx(&pool, alice_id, a_acct, "Alice-only payee", "-42.00").await;
    let (_b_inst, b_acct) = seed_account(&pool, bob_id).await;
    let b_tx = seed_tx(&pool, bob_id, b_acct, "Bob-only payee", "-77.00").await;

    // /dashboard/transactions
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/transactions?limit=200",
            None,
            Some(&alice_token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let ids: Vec<String> = body
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|r| r["id"].as_str().map(String::from))
        .collect();
    assert!(
        ids.contains(&a_tx.to_string()),
        "Alice should see her own tx"
    );
    assert!(
        !ids.contains(&b_tx.to_string()),
        "Alice MUST NOT see Bob's tx — predicate leak"
    );

    // /accounts
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/accounts", None, Some(&bob_token)))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let acct_ids: Vec<String> = body
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|r| r["id"].as_str().map(String::from))
        .collect();
    assert!(
        acct_ids.contains(&b_acct.to_string()),
        "Bob sees own account"
    );
    assert!(
        !acct_ids.contains(&a_acct.to_string()),
        "Bob MUST NOT see Alice's account"
    );

    // /dashboard/overview — totals must reflect only the caller's
    // accounts. Each owner has one account with current_balance =
    // 1000.00 (per seed_account); cross-tenant leakage would
    // double that.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/overview",
            None,
            Some(&alice_token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let accounts_in_overview = body["accounts"].as_array().unwrap();
    assert_eq!(
        accounts_in_overview.len(),
        1,
        "Alice's overview should show exactly 1 account, got {}",
        accounts_in_overview.len()
    );
    assert!(
        accounts_in_overview
            .iter()
            .all(|a| a["id"].as_str().unwrap() != b_acct.to_string()),
        "Alice's overview leaked Bob's account"
    );

    // Mutating endpoint: Bob tries to PATCH Alice's account balance
    // → 404 (predicate filter excludes foreign rows).
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/accounts/{a_acct}/balance"),
            Some(&serde_json::json!({"current_balance": 999.99})),
            Some(&bob_token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_FOUND,
        "Bob MUST NOT be able to PATCH Alice's account"
    );

    // Seed an ignored subscription for Alice; Bob's /ignored list
    // must NOT include it.
    sqlx::query(
        "INSERT INTO ignored_subscription_merchants (user_id, merchant_key) \
         VALUES ($1, 'alice-private')",
    )
    .bind(alice_id)
    .execute(&pool)
    .await
    .expect("seed alice's ignored sub");
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/subscriptions/ignored",
            None,
            Some(&bob_token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let merchants: Vec<String> = body
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|r| r["merchant_key"].as_str().map(String::from))
        .collect();
    assert!(
        !merchants.contains(&"alice-private".to_string()),
        "Bob MUST NOT see Alice's ignored subscriptions"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn cross_tenant_isolation_sessions_list() {
    // /api/auth/sessions must return only the caller's own sessions —
    // an obvious place where a missing predicate would leak every
    // user's sessions to anyone authenticated.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let _ = bootstrap(&app, &pool).await;
    let (alice_id, alice_token) = seed_owner(&pool, "alice2").await;
    let (_bob_id, bob_token) = seed_owner(&pool, "bob2").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/auth/sessions",
            None,
            Some(&alice_token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let arr = body.as_array().unwrap();
    assert_eq!(arr.len(), 1, "Alice should see exactly her one session");

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/auth/sessions",
            None,
            Some(&bob_token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let arr = body.as_array().unwrap();
    assert_eq!(arr.len(), 1, "Bob should see exactly his one session");

    // And /me returns only the caller's view.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/auth/me", None, Some(&alice_token)))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert_eq!(body["id"].as_str().unwrap(), alice_id.to_string());
    assert_eq!(body["username"].as_str().unwrap(), "alice2");
    assert_eq!(body["role"].as_str().unwrap(), "owner");
}

/// Cash flow must count genuine income/spending only — not securities trades
/// (category `Investment`) nor internal `Transfer`s between the user's own
/// accounts. Regression for the "Buy VOO shows as $3,326 expense / a $10k ACH
/// shows as income" bug, where `spending_by_category` said "no spending" while
/// the headline claimed thousands of expense.
#[tokio::test]
async fn cash_flow_excludes_investment_trades_and_transfers() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // In one month: a securities buy, an internal transfer in, a dividend, and
    // a real grocery expense. Only the dividend (income) and grocery (spending)
    // are household cash flow.
    seed_tx_dated_cat(
        &pool,
        user_id,
        acct,
        "Buy 5 VOO @ 665.20",
        "-3326.00",
        "2026-03-05",
        "Investment",
    )
    .await;
    seed_tx_dated_cat(
        &pool,
        user_id,
        acct,
        "ACH deposit from checking",
        "10000.00",
        "2026-03-06",
        "Transfer",
    )
    .await;
    seed_tx_dated_cat(
        &pool,
        user_id,
        acct,
        "Dividend received - AAPL",
        "46.80",
        "2026-03-07",
        "Income",
    )
    .await;
    seed_tx_dated_cat(
        &pool,
        user_id,
        acct,
        "Supermarket",
        "-200.00",
        "2026-03-08",
        "Food",
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/trends",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let trends = body_json(res.into_body()).await;
    let march = trends
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["month"] == "2026-03")
        .cloned()
        .unwrap();

    // Income = dividend only (transfer-in excluded); spending = grocery only
    // (investment buy excluded).
    assert!(
        (march["income"].as_f64().unwrap() - 46.80).abs() < 0.01,
        "March income should exclude the $10k transfer, leaving the $46.80 dividend, got {}",
        march["income"]
    );
    assert!(
        (march["spending"].as_f64().unwrap() - 200.0).abs() < 0.01,
        "March spending should exclude the $3,326 VOO buy, leaving the $200 grocery, got {}",
        march["spending"]
    );

    // The peeled-off money is still visible as context: the VOO buy shows as
    // net invested (+3326) and the ACH deposit as net transferred in (+10000).
    assert!(
        (march["invested"].as_f64().unwrap() - 3326.0).abs() < 0.01,
        "March invested should surface the VOO buy (3326), got {}",
        march["invested"]
    );
    assert!(
        (march["transferred"].as_f64().unwrap() - 10000.0).abs() < 0.01,
        "March transferred should surface the ACH deposit (10000), got {}",
        march["transferred"]
    );
}

/// A positive inflow into a credit-card (liability) account — a payment,
/// refund, or reward-redemption — is not household income. Its purchases
/// (negatives) still count as spending. Regression for CC "Payment Thank You"
/// legs, Bilt rent-card payments, and statement credits inflating income.
#[tokio::test]
async fn cash_flow_excludes_credit_card_inflows_from_income() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, checking) = seed_account(&pool, user_id).await;
    let card: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Visa', 'credit', 'USD', -500.00, $2) RETURNING id",
    )
    .bind(inst)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed credit account");

    // Real payroll into checking; a CC payment inflow + a card purchase on the card.
    seed_tx_dated(
        &pool,
        user_id,
        checking,
        "ACME Payroll",
        "3000.00",
        "2026-03-15",
    )
    .await;
    seed_tx_dated(
        &pool,
        user_id,
        card,
        "Payment Thank You-Mobile",
        "800.00",
        "2026-03-16",
    )
    .await;
    seed_tx_dated(
        &pool,
        user_id,
        card,
        "Grocery Store",
        "-120.00",
        "2026-03-17",
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/trends",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let trends = body_json(res.into_body()).await;
    let march = trends
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["month"] == "2026-03")
        .cloned()
        .unwrap();

    assert!(
        (march["income"].as_f64().unwrap() - 3000.0).abs() < 0.01,
        "CC payment inflow must not count as income (payroll only), got {}",
        march["income"]
    );
    assert!(
        (march["spending"].as_f64().unwrap() - 120.0).abs() < 0.01,
        "card purchase should still count as spending, got {}",
        march["spending"]
    );
}

/// A tax refund is a return of the user's own overpaid tax, not earned income,
/// so it must not inflate the cash-flow income line the month it lands.
#[tokio::test]
async fn cash_flow_excludes_tax_refund_from_income() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, checking) = seed_account(&pool, user_id).await;

    seed_tx_dated(
        &pool,
        user_id,
        checking,
        "ACME Payroll",
        "3000.00",
        "2026-03-15",
    )
    .await;
    // A federal tax refund as Plaid tags it: INCOME / INCOME_TAX_REFUND.
    sqlx::query(
        "INSERT INTO transactions (account_id, date, description, amount, currency, source, user_id, category, category_detailed) \
         VALUES ($1, '2026-03-20'::date, 'IRS TREAS 310 TAX REF', 5000.00, 'USD', 'manual', $2, 'INCOME', 'INCOME_TAX_REFUND')",
    )
    .bind(checking)
    .bind(user_id)
    .execute(&pool)
    .await
    .expect("seed tax refund");

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/trends",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let trends = body_json(res.into_body()).await;
    let march = trends
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["month"] == "2026-03")
        .cloned()
        .unwrap();

    assert!(
        (march["income"].as_f64().unwrap() - 3000.0).abs() < 0.01,
        "tax refund must not count as income (payroll only), got {}",
        march["income"]
    );
}

/// A user re-categorization (user_category) overrides the raw Plaid category in
/// the cash-flow exclusions, in BOTH directions — matching how labels and the
/// tax view already treat it. Re-tagging a row "Transfer" drops it from income;
/// re-tagging a TRANSFER_IN row "Income" brings it back in.
#[tokio::test]
async fn cash_flow_honors_user_category_override() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, checking) = seed_account(&pool, user_id).await;

    // Plain payroll baseline.
    seed_tx_dated(
        &pool,
        user_id,
        checking,
        "ACME Payroll",
        "1000.00",
        "2026-03-12",
    )
    .await;
    // (a) A raw INCOME row the user re-tagged as a Transfer → excluded from income.
    // (b) A raw TRANSFER_IN row the user re-tagged as Income → counted as income.
    for (amount, category, user_cat, day) in [
        ("500.00", "INCOME", "Transfer", "10"),
        ("700.00", "TRANSFER_IN", "Income", "11"),
    ] {
        sqlx::query(
            "INSERT INTO transactions (account_id, date, description, amount, currency, source, user_id, category, user_category) \
             VALUES ($1, ('2026-03-' || $6)::date, 'x', $2, 'USD', 'manual', $3, $4, $5)",
        )
        .bind(checking)
        .bind(Decimal::from_str(amount).unwrap())
        .bind(user_id)
        .bind(category)
        .bind(user_cat)
        .bind(day)
        .execute(&pool)
        .await
        .expect("seed override tx");
    }

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/trends",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let trends = body_json(res.into_body()).await;
    let march = trends
        .as_array()
        .unwrap()
        .iter()
        .find(|p| p["month"] == "2026-03")
        .cloned()
        .unwrap();

    // 1000 payroll + 700 (TRANSFER_IN re-tagged Income); the 500 re-tagged Transfer is excluded.
    assert!((march["income"].as_f64().unwrap() - 1700.0).abs() < 0.01,
        "user_category override should drop the re-tagged Transfer and keep the re-tagged Income, got {}", march["income"]);
}

#[tokio::test]
#[serial_test::serial]
async fn spending_by_category_groups_and_excludes() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // This month: 200 + 100 food, 50 merchandise.
    seed_categorized_expense(&pool, user_id, acct, "FOOD_AND_DRINK", "-200.00", 0).await;
    seed_categorized_expense(&pool, user_id, acct, "FOOD_AND_DRINK", "-100.00", 0).await;
    seed_categorized_expense(&pool, user_id, acct, "GENERAL_MERCHANDISE", "-50.00", 0).await;
    // Last month: 150 food.
    seed_categorized_expense(&pool, user_id, acct, "FOOD_AND_DRINK", "-150.00", 1).await;
    // Noise that must be excluded: income (positive) and an internal transfer.
    seed_categorized_expense(&pool, user_id, acct, "TRANSFER_OUT", "-500.00", 0).await;
    sqlx::query(
        "INSERT INTO transactions (account_id, date, description, amount, currency, category, source, user_id) \
         VALUES ($1, CURRENT_DATE, 'paycheck', 3000.00, 'USD', 'INCOME', 'manual', $2)",
    )
    .bind(acct)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/spending-by-category?months=3&top=8",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    let cats = body["categories"].as_array().unwrap();
    let food = cats
        .iter()
        .find(|c| c["category"] == "FOOD_AND_DRINK")
        .expect("food category present");
    // 200 + 100 (this month) + 150 (last month) = 450, transfer/income excluded.
    assert!(
        (food["total"].as_f64().unwrap() - 450.0).abs() < 0.01,
        "food total should be 450, got {}",
        food["total"]
    );
    let merch = cats
        .iter()
        .find(|c| c["category"] == "GENERAL_MERCHANDISE")
        .expect("merchandise present");
    assert!((merch["total"].as_f64().unwrap() - 50.0).abs() < 0.01);

    // The internal transfer must not appear as a spending category.
    assert!(
        !cats.iter().any(|c| c["category"] == "TRANSFER_OUT"),
        "internal transfers must be excluded"
    );
    // Food ranks first (highest total).
    assert_eq!(cats[0]["category"], "FOOD_AND_DRINK");
    // Two distinct months present.
    assert_eq!(body["months"].as_array().unwrap().len(), 2);
}

#[tokio::test]
#[serial_test::serial]
async fn spending_insights_recent_vs_trailing_average() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // FOOD: $400 in the most recent complete month (1mo ago), $200 in each of
    // the three baseline months (2/3/4mo ago). recent=400, previous_avg=200
    // (+100%), trailing_avg = (400+600)/4 = 250.
    seed_categorized_expense(&pool, user_id, acct, "FOOD_AND_DRINK", "-400.00", 1).await;
    seed_categorized_expense(&pool, user_id, acct, "FOOD_AND_DRINK", "-200.00", 2).await;
    seed_categorized_expense(&pool, user_id, acct, "FOOD_AND_DRINK", "-200.00", 3).await;
    seed_categorized_expense(&pool, user_id, acct, "FOOD_AND_DRINK", "-200.00", 4).await;
    // Current (partial) month must be EXCLUDED from the comparison entirely.
    seed_categorized_expense(&pool, user_id, acct, "FOOD_AND_DRINK", "-999.00", 0).await;
    // A smaller category present only in a baseline month.
    seed_categorized_expense(&pool, user_id, acct, "GENERAL_MERCHANDISE", "-60.00", 2).await;
    // Noise: an internal transfer + income must never surface as spend.
    seed_categorized_expense(&pool, user_id, acct, "TRANSFER_OUT", "-500.00", 1).await;
    sqlx::query(
        "INSERT INTO transactions (account_id, date, description, amount, currency, category, source, user_id) \
         VALUES ($1, (CURRENT_DATE - make_interval(months => 1))::date, 'paycheck', 3000.00, 'USD', 'INCOME', 'manual', $2)",
    )
    .bind(acct)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/spending-insights?lookback=3",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    assert_eq!(body["lookback"], 3);
    // recent_month is the most recent *complete* calendar month (last month).
    let expected_recent: String = sqlx::query_scalar(
        "SELECT TO_CHAR(DATE_TRUNC('month', CURRENT_DATE) - interval '1 month', 'YYYY-MM')",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(body["recent_month"], expected_recent);

    let cats = body["categories"].as_array().unwrap();
    // FOOD has the largest trailing spend → ranked first.
    assert_eq!(cats[0]["category"], "FOOD_AND_DRINK");
    let food = &cats[0];
    assert!(
        (food["recent"].as_f64().unwrap() - 400.0).abs() < 0.01,
        "recent should be 400 (current month's 999 excluded), got {}",
        food["recent"]
    );
    assert!(
        (food["previous_avg"].as_f64().unwrap() - 200.0).abs() < 0.01,
        "previous_avg should be 200, got {}",
        food["previous_avg"]
    );
    assert!(
        (food["trailing_avg"].as_f64().unwrap() - 250.0).abs() < 0.01,
        "trailing_avg should be 250, got {}",
        food["trailing_avg"]
    );

    let merch = cats
        .iter()
        .find(|c| c["category"] == "GENERAL_MERCHANDISE")
        .expect("merchandise present");
    // Only a baseline month → recent 0, previous_avg = 60/3 = 20, trailing = 60/4 = 15.
    assert!((merch["recent"].as_f64().unwrap()).abs() < 0.01);
    assert!((merch["previous_avg"].as_f64().unwrap() - 20.0).abs() < 0.01);
    assert!((merch["trailing_avg"].as_f64().unwrap() - 15.0).abs() < 0.01);

    // Internal transfers and income are never spending categories.
    assert!(!cats.iter().any(|c| c["category"] == "TRANSFER_OUT"));
    assert!(!cats.iter().any(|c| c["category"] == "INCOME"));
}

#[tokio::test]
#[serial_test::serial]
async fn portfolio_value_history_sums_only_investment_accounts() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;

    // An investment account (it has a holding) and a cash account (none).
    let invest: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Brokerage', 'brokerage', 'USD', 6000.00, $2) RETURNING id",
    )
    .bind(inst)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO holdings (account_id, symbol, name, currency, holding_type, quantity, value, user_id) \
         VALUES ($1,'VTI','Vanguard','USD','equity',10,6000,$2)",
    )
    .bind(invest)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();
    let cash: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Checking', 'checking', 'USD', 2500.00, $2) RETURNING id",
    )
    .bind(inst)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();

    // Two snapshot dates for BOTH accounts; only the investment account's
    // value should be summed into the series.
    for (acct, d, usd) in [
        (invest, "2026-04-01", "5000"),
        (cash, "2026-04-01", "2000"),
        (invest, "2026-05-01", "6000"),
        (cash, "2026-05-01", "2500"),
    ] {
        sqlx::query(
            "INSERT INTO balance_snapshots (account_id, balance, balance_usd, as_of_date, currency, user_id) \
             VALUES ($1, $2, $2, $3::date, 'USD', $4)",
        )
        .bind(acct)
        .bind(Decimal::from_str(usd).unwrap())
        .bind(d)
        .bind(user_id)
        .execute(&pool)
        .await
        .unwrap();
    }

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/portfolio-value-history",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let pts = body.as_array().unwrap();
    assert_eq!(pts.len(), 2, "two snapshot dates, got {pts:#?}");
    assert_eq!(pts[0]["date"], "2026-04-01");
    assert!(
        (pts[0]["value_usd"].as_f64().unwrap() - 5000.0).abs() < 0.01,
        "Apr should be the investment account only (5000), got {}",
        pts[0]["value_usd"]
    );
    assert!(
        (pts[1]["value_usd"].as_f64().unwrap() - 6000.0).abs() < 0.01,
        "May should be 6000, got {}",
        pts[1]["value_usd"]
    );
}

/// Partial-sync regression: accounts snapshot on different days, so a date's
/// naive per-date SUM only covered the accounts that snapshotted that day —
/// the trailing point after a one-institution refresh read as ONE account's
/// balance (the performance headline showed $299k for a $380k portfolio).
/// The series must carry each account's last-known balance forward instead.
#[tokio::test]
#[serial_test::serial]
async fn portfolio_value_history_carries_unsynced_accounts_forward() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;

    // Two investment accounts (both hold something).
    let mut accounts = Vec::new();
    for (name, sym) in [("Brokerage A", "VTI"), ("Brokerage B", "AAPL")] {
        let id: uuid::Uuid = sqlx::query_scalar(
            "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
             VALUES ($1, $2, 'brokerage', 'USD', 1000.00, $3) RETURNING id",
        )
        .bind(inst)
        .bind(name)
        .bind(user_id)
        .fetch_one(&pool)
        .await
        .unwrap();
        sqlx::query(
            "INSERT INTO holdings (account_id, symbol, name, currency, holding_type, quantity, value, user_id) \
             VALUES ($1,$2,$2,'USD','equity',10,1000,$3)",
        )
        .bind(id)
        .bind(sym)
        .bind(user_id)
        .execute(&pool)
        .await
        .unwrap();
        accounts.push(id);
    }
    let (a, b) = (accounts[0], accounts[1]);

    // Day 1: both accounts snapshot. Day 2: only account A resynced.
    for (acct, d, usd) in [
        (a, "2026-06-01", "298000"),
        (b, "2026-06-01", "81000"),
        (a, "2026-06-02", "298993.70"),
    ] {
        sqlx::query(
            "INSERT INTO balance_snapshots (account_id, balance, balance_usd, as_of_date, currency, user_id) \
             VALUES ($1, $2, $2, $3::date, 'USD', $4)",
        )
        .bind(acct)
        .bind(Decimal::from_str(usd).unwrap())
        .bind(d)
        .bind(user_id)
        .execute(&pool)
        .await
        .unwrap();
    }

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/portfolio-value-history",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let pts = body.as_array().unwrap();
    assert_eq!(pts.len(), 2, "two snapshot dates, got {pts:#?}");
    assert!(
        (pts[0]["value_usd"].as_f64().unwrap() - 379_000.0).abs() < 0.01,
        "day 1 sums both accounts, got {}",
        pts[0]["value_usd"]
    );
    // The trailing point must include B's carried-forward $81,000 — not
    // just A's fresh snapshot.
    assert!(
        (pts[1]["value_usd"].as_f64().unwrap() - 379_993.70).abs() < 0.01,
        "trailing point must carry account B forward, got {}",
        pts[1]["value_usd"]
    );
}

#[tokio::test]
#[serial_test::serial]
async fn allocation_merges_cash_holdings_with_cash_accounts() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, acct) = seed_account(&pool, user_id).await;

    // A money-market HOLDING stored with lower-case holding_type 'cash', plus
    // an 'equity' holding.
    sqlx::query(
        "INSERT INTO holdings (account_id, symbol, name, currency, holding_type, quantity, value, user_id) \
         VALUES ($1,'VMFXX','Vanguard MM','USD','cash',100,5000,$2), \
                ($1,'AAPL','Apple','USD','equity',10,1000,$2)",
    )
    .bind(acct)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();
    // A cash ACCOUNT (checking) → the union hard-codes Title-Case 'Cash'.
    sqlx::query(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Checking', 'checking', 'USD', 2000.00, $2)",
    )
    .bind(inst)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/allocation",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().unwrap();

    // Every category carries a human display label plus the canonical
    // asset_class key (contract C2): the 'cash' holding classifies as 'cash'
    // (merging with the checking account) and 'equity' as 'equity'.
    assert!(
        !rows
            .iter()
            .any(|r| r["category"] == "cash" || r["category"] == "equity"),
        "categories should be human display labels, got {rows:#?}"
    );
    // Both the money-market holding (VMFXX) and the checking account sit under a
    // single 'Cash' band — the classifier and the accounts-union agree on the
    // canonical 'cash' key.
    let cash_subs: Vec<&str> = rows
        .iter()
        .filter(|r| r["asset_class"] == "cash")
        .filter_map(|r| r["sub_category"].as_str())
        .collect();
    // VMFXX is a short all-caps symbol, so the endpoint surfaces it as the
    // symbol rather than the long fund name.
    assert!(
        cash_subs.contains(&"VMFXX"),
        "MM holding under Cash: {cash_subs:?}"
    );
    assert!(
        cash_subs.contains(&"Checking"),
        "checking under Cash: {cash_subs:?}"
    );
    assert!(rows
        .iter()
        .all(|r| r["asset_class"] != "cash" || r["category"] == "Cash"));
    // The equity holding lands under the canonical 'equity' key with its
    // human display label.
    let equity = rows
        .iter()
        .find(|r| r["asset_class"] == "equity")
        .expect("an equity band");
    assert_eq!(equity["category"], "Stocks & funds");
}

#[tokio::test]
#[serial_test::serial]
async fn benchmark_series_returns_stored_sp500() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user_id) = bootstrap(&app, &pool).await;

    // Seed recent S&P 500 closes so ensure_fresh treats the series as fresh
    // and never touches the network during the test.
    for (offset, close) in [(2, "5000.00"), (1, "5050.00"), (0, "5100.00")] {
        sqlx::query(
            "INSERT INTO benchmark_prices (symbol, price_date, close) \
             VALUES ('SP500', (CURRENT_DATE - make_interval(days => $1))::date, $2) \
             ON CONFLICT (symbol, price_date) DO UPDATE SET close = EXCLUDED.close",
        )
        .bind(offset)
        .bind(Decimal::from_str(close).unwrap())
        .execute(&pool)
        .await
        .unwrap();
    }

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/benchmark?from=2000-01-01",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    assert_eq!(body["symbol"], "SP500");
    let pts = body["points"].as_array().unwrap();
    assert_eq!(pts.len(), 3, "three seeded closes, got {pts:#?}");
    // Ascending by date → last point is today's 5100.00.
    assert!((pts[2]["close"].as_f64().unwrap() - 5100.0).abs() < 0.01);
    assert!((pts[0]["close"].as_f64().unwrap() - 5000.0).abs() < 0.01);
}

#[tokio::test]
#[serial_test::serial]
async fn emergency_fund_runway_from_cash_and_spend() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;

    // A checking account (counts as liquid cash) with $6,000.
    let cash_acct: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Checking', 'checking', 'USD', 6000.00, $2) RETURNING id",
    )
    .bind(inst)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();

    // Two months of spending: $1,000 + $1,000 over 2 distinct months → $1,000/mo.
    seed_categorized_expense(&pool, user_id, cash_acct, "FOOD_AND_DRINK", "-1000.00", 0).await;
    seed_categorized_expense(
        &pool,
        user_id,
        cash_acct,
        "GENERAL_MERCHANDISE",
        "-1000.00",
        1,
    )
    .await;
    // An income row + an internal transfer must NOT reduce the runway.
    sqlx::query(
        "INSERT INTO transactions (account_id, date, description, amount, currency, category, source, user_id) \
         VALUES ($1, CURRENT_DATE, 'pay', 5000.00, 'USD', 'INCOME', 'manual', $2)",
    )
    .bind(cash_acct)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();
    seed_categorized_expense(&pool, user_id, cash_acct, "TRANSFER_OUT", "-9999.00", 0).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/emergency-fund",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    // $6,000 cash, $1,000/mo spend → 6.0 months.
    assert!(
        (body["liquid_cash_usd"].as_f64().unwrap() - 6000.0).abs() < 0.01,
        "liquid cash should be 6000, got {}",
        body["liquid_cash_usd"]
    );
    assert!(
        (body["monthly_spend_usd"].as_f64().unwrap() - 1000.0).abs() < 0.01,
        "monthly spend should be 1000 (transfer/income excluded), got {}",
        body["monthly_spend_usd"]
    );
    assert!(
        (body["months_covered"].as_f64().unwrap() - 6.0).abs() < 0.05,
        "runway should be ~6 months, got {}",
        body["months_covered"]
    );
}

#[tokio::test]
#[serial_test::serial]
async fn benchmark_comparison_contribution_weighted() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // S&P at the acquisition date (5000) and today (6000) → factor 1.2.
    sqlx::query(
        "INSERT INTO benchmark_prices (symbol, price_date, close) VALUES \
         ('SP500','2026-01-01',5000),('SP500',CURRENT_DATE,6000) \
         ON CONFLICT (symbol, price_date) DO UPDATE SET close = EXCLUDED.close",
    )
    .execute(&pool)
    .await
    .unwrap();

    // A holding worth $2,400 (10 sh @ $240) with one lot bought at $100/sh.
    let holding_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, quantity, value, user_id) \
         VALUES ($1,'VTI','Vanguard','USD',10,2400,$2) RETURNING id",
    )
    .bind(acct)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1,$2,$3,'2026-01-01',10,100,'USD',1.0,'l1')",
    )
    .bind(holding_id).bind(acct).bind(user_id).execute(&pool).await.unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/benchmark-comparison",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    assert_eq!(body["lot_count"].as_i64().unwrap(), 1);
    assert!((body["invested_usd"].as_f64().unwrap() - 1000.0).abs() < 0.01);
    assert!((body["your_value_usd"].as_f64().unwrap() - 2400.0).abs() < 0.01);
    // $1,000 invested in the index (5000→6000 = +20%) → $1,200.
    assert!((body["benchmark_value_usd"].as_f64().unwrap() - 1200.0).abs() < 0.01);
}

/// The comparison itemizes WHAT it recorded: a per-symbol breakdown built
/// with the same per-lot math as the totals (so rows sum back to them),
/// plus the holdings it could NOT cover (value but zero counted lots) and
/// their total. Regression test for the "aggregates only — can't see what's
/// in or out" gap.
#[tokio::test]
#[serial_test::serial]
async fn benchmark_comparison_per_symbol_breakdown_and_untracked() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // S&P closes: 5000 (D-60), 5500 (D-30), 6000 (today). A today-dated
    // close keeps the series "fresh" so the test never reaches out to Yahoo.
    sqlx::query(
        "INSERT INTO benchmark_prices (symbol, price_date, close) VALUES \
         ('SP500', CURRENT_DATE - 60, 5000), \
         ('SP500', CURRENT_DATE - 30, 5500), \
         ('SP500', CURRENT_DATE,      6000) \
         ON CONFLICT (symbol, price_date) DO UPDATE SET close = EXCLUDED.close",
    )
    .execute(&pool)
    .await
    .unwrap();
    // Expected ISO dates straight from Postgres so the assertion can't
    // drift from CURRENT_DATE across a midnight/timezone boundary.
    let (d60, d30): (String, String) =
        sqlx::query_as("SELECT (CURRENT_DATE - 60)::text, (CURRENT_DATE - 30)::text")
            .fetch_one(&pool)
            .await
            .unwrap();

    // Tracked holding 1: VOO, worth $2,400 (10 sh), one lot of 10 @
    // $100.0033 on D-60 → invested 1000.033, which must be presented as
    // 1000.03 (2dp house rounding).
    let voo: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, quantity, value, user_id) \
         VALUES ($1,'VOO','Vanguard S&P 500','USD',10,2400,$2) RETURNING id",
    )
    .bind(acct)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1,$2,$3, CURRENT_DATE - 60, 10, 100.0033, 'USD', 1.0, 'voo1')",
    )
    .bind(voo).bind(acct).bind(user_id).execute(&pool).await.unwrap();

    // Tracked holding 2: AAPL, worth $550 (5 sh), two lots — 2 @ $50 on
    // D-60 (index 5000) and 3 @ $60 on D-30 (index 5500).
    let aapl: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, quantity, value, user_id) \
         VALUES ($1,'AAPL','Apple','USD',5,550,$2) RETURNING id",
    )
    .bind(acct)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) VALUES \
         ($1,$2,$3, CURRENT_DATE - 60, 2, 50, 'USD', 1.0, 'aapl1'), \
         ($1,$2,$3, CURRENT_DATE - 30, 3, 60, 'USD', 1.0, 'aapl2')",
    )
    .bind(aapl).bind(acct).bind(user_id).execute(&pool).await.unwrap();

    // Untracked holding: FXAIX worth $25,000, no lots at all.
    sqlx::query(
        "INSERT INTO holdings (account_id, symbol, name, currency, quantity, value, user_id) \
         VALUES ($1,'FXAIX','Fidelity 500','USD',100,25000,$2)",
    )
    .bind(acct)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();
    // Untracked holding: has a lot, but its cost is 0 → the lot is skipped,
    // so the holding contributed zero counted lots.
    let crypto: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, quantity, value, user_id) \
         VALUES ($1,'BTC','Bitcoin','USD',1,100,$2) RETURNING id",
    )
    .bind(acct)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    sqlx::query(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1,$2,$3, CURRENT_DATE - 10, 1, 0, 'USD', 1.0, 'btc1')",
    )
    .bind(crypto).bind(acct).bind(user_id).execute(&pool).await.unwrap();
    // Zero-value lot-less holding and a soft-deleted holding: neither may
    // appear anywhere.
    sqlx::query(
        "INSERT INTO holdings (account_id, symbol, name, currency, quantity, value, user_id) \
         VALUES ($1,'EMPTY','Sold Out','USD',0,0,$2), \
                ($1,'GONE','Deleted','USD',3,999,$2)",
    )
    .bind(acct)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();
    sqlx::query("UPDATE holdings SET deleted_at = NOW() WHERE symbol = 'GONE' AND user_id = $1")
        .bind(user_id)
        .execute(&pool)
        .await
        .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/benchmark-comparison",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    // Totals: 1000.033 + 280 invested over 3 counted lots.
    assert_eq!(body["lot_count"].as_i64().unwrap(), 3);
    let total_invested = body["invested_usd"].as_f64().unwrap();
    let total_value = body["your_value_usd"].as_f64().unwrap();
    let total_bench = body["benchmark_value_usd"].as_f64().unwrap();
    assert!(
        (total_invested - 1280.033).abs() < 0.01,
        "invested total, got {total_invested}"
    );
    assert!(
        (total_value - 2950.0).abs() < 0.01,
        "value total, got {total_value}"
    );

    // Per-symbol rows: sorted by invested_usd DESC → VOO before AAPL.
    let symbols = body["symbols"].as_array().unwrap();
    assert_eq!(symbols.len(), 2, "two tracked symbols, got {symbols:#?}");
    let voo_row = &symbols[0];
    let aapl_row = &symbols[1];
    assert_eq!(voo_row["symbol"], "VOO");
    assert_eq!(aapl_row["symbol"], "AAPL");

    // VOO: exact 2dp presentation (1000.033 → 1000.03), 5000→6000 = ×1.2.
    assert_eq!(voo_row["lot_count"].as_i64().unwrap(), 1);
    assert!(
        (voo_row["invested_usd"].as_f64().unwrap() - 1000.03).abs() < 1e-9,
        "VOO invested must be rounded to exactly 1000.03, got {}",
        voo_row["invested_usd"]
    );
    assert!((voo_row["your_value_usd"].as_f64().unwrap() - 2400.0).abs() < 1e-9);
    assert!(
        (voo_row["benchmark_value_usd"].as_f64().unwrap() - 1200.04).abs() < 1e-9,
        "VOO benchmark: 1000.033 × 1.2 = 1200.0396 → 1200.04, got {}",
        voo_row["benchmark_value_usd"]
    );
    assert_eq!(voo_row["first_acquired"], d60.as_str());
    assert_eq!(voo_row["last_acquired"], d60.as_str());

    // AAPL: 2 lots; bench = 100×(6000/5000) + 180×(6000/5500) = 316.36.
    assert_eq!(aapl_row["lot_count"].as_i64().unwrap(), 2);
    assert!((aapl_row["invested_usd"].as_f64().unwrap() - 280.0).abs() < 1e-9);
    assert!((aapl_row["your_value_usd"].as_f64().unwrap() - 550.0).abs() < 1e-9);
    assert!(
        (aapl_row["benchmark_value_usd"].as_f64().unwrap() - 316.36).abs() < 1e-9,
        "AAPL benchmark, got {}",
        aapl_row["benchmark_value_usd"]
    );
    assert_eq!(aapl_row["first_acquired"], d60.as_str());
    assert_eq!(aapl_row["last_acquired"], d30.as_str());

    // The rows must reproduce the totals (modulo the per-row 2dp rounding).
    let sum = |field: &str| -> f64 { symbols.iter().map(|s| s[field].as_f64().unwrap()).sum() };
    assert!((sum("invested_usd") - total_invested).abs() < 0.01);
    assert!((sum("your_value_usd") - total_value).abs() < 0.01);
    assert!((sum("benchmark_value_usd") - total_bench).abs() < 0.01);

    // Untracked: FXAIX (no lots) then BTC (only a skipped zero-cost lot),
    // value DESC; the zero-value and soft-deleted holdings are absent.
    let untracked = body["untracked"].as_array().unwrap();
    assert_eq!(untracked.len(), 2, "untracked, got {untracked:#?}");
    assert_eq!(untracked[0]["symbol"], "FXAIX");
    assert!((untracked[0]["value_usd"].as_f64().unwrap() - 25000.0).abs() < 1e-9);
    assert_eq!(untracked[1]["symbol"], "BTC");
    assert!((untracked[1]["value_usd"].as_f64().unwrap() - 100.0).abs() < 1e-9);
    assert!((body["untracked_value_usd"].as_f64().unwrap() - 25100.0).abs() < 1e-9);
}

/// True time-weighted return divides out the contribution: a mid-window buy
/// must NOT inflate the return the way a naive (end-start)/start would. We
/// hand-build a price path where the honest TWR is +21% even though the
/// dollar value more than doubled (because most of the value came from the
/// contribution, not the market).
#[tokio::test]
#[serial_test::serial]
async fn portfolio_twr_divides_out_contributions() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // Quote path for AAPL: 100 (D-60) → 110 (D-30) → 121 (today), i.e. two
    // +10% legs = +21% compounded. S&P: 1000 (D-60) → 1100 (today) = +10%.
    // Dates are CURRENT_DATE-relative so the seeded series reads as "fresh"
    // and the freshness gate doesn't reach out to Yahoo during the test.
    sqlx::query(
        "INSERT INTO benchmark_prices (symbol, price_date, close) VALUES \
         ('AAPL', CURRENT_DATE - 60, 100), \
         ('AAPL', CURRENT_DATE - 30, 110), \
         ('AAPL', CURRENT_DATE,      121), \
         ('SP500', CURRENT_DATE - 60, 1000), \
         ('SP500', CURRENT_DATE,      1100) \
         ON CONFLICT (symbol, price_date) DO UPDATE SET close = EXCLUDED.close",
    )
    .execute(&pool)
    .await
    .unwrap();

    // Current position: 10 shares worth 10 × 121 = 1210.
    let holding_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, quantity, value, user_id) \
         VALUES ($1,'AAPL','Apple','USD',10,1210,$2) RETURNING id",
    )
    .bind(acct)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();
    // Opening lot of 6 @ 100 on D-60, then a contribution of 4 @ 110 on D-30.
    // 6 + 4 = the 10 shares held today.
    sqlx::query(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) VALUES \
         ($1,$2,$3, CURRENT_DATE - 60, 6, 100, 'USD', 1.0, 'open'), \
         ($1,$2,$3, CURRENT_DATE - 30, 4, 110, 'USD', 1.0, 'add')",
    )
    .bind(holding_id)
    .bind(acct)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/portfolio-twr",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    // Whole portfolio is the priceable AAPL position.
    assert!(
        (body["coverage_pct"].as_f64().unwrap() - 1.0).abs() < 0.001,
        "coverage should be 100%, got {}",
        body["coverage_pct"]
    );
    assert!((body["total_value_usd"].as_f64().unwrap() - 1210.0).abs() < 0.5);
    // The honest TWR is +21% — NOT the ~+102% a naive value change would show
    // (1210 vs the 600 opening value includes the 440 contribution).
    assert!(
        (body["your_twr"].as_f64().unwrap() - 0.21).abs() < 0.005,
        "TWR should be ~0.21 (contribution divided out), got {}",
        body["your_twr"]
    );
    assert!(
        (body["sp_twr"].as_f64().unwrap() - 0.10).abs() < 0.005,
        "S&P TWR should be ~0.10, got {}",
        body["sp_twr"]
    );
    // Daily growth index: starts at 1.0, ends at ~1.21 / ~1.10.
    let points = body["points"].as_array().unwrap();
    assert!(
        points.len() > 50,
        "expected a daily series, got {}",
        points.len()
    );
    let last = points.last().unwrap();
    assert!((last["twr"].as_f64().unwrap() - 1.21).abs() < 0.005);
    assert!((last["sp"].as_f64().unwrap() - 1.10).abs() < 0.005);
}

#[tokio::test]
#[serial_test::serial]
async fn tax_summary_splits_short_and_long_term_from_lots() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    let holding_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, user_id) \
         VALUES ($1, 'VTI', 'Vanguard', 'USD', $2) RETURNING id",
    )
    .bind(acct)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();

    // A short-term lot (acquired 2026-01, sold 2026-06 → < 1yr) and a long-term
    // lot (acquired 2022, sold 2026-06 → > 1yr).
    let st_lot: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1,$2,$3,'2026-01-01',10,60,'USD',1.0,'st') RETURNING id",
    )
    .bind(holding_id).bind(acct).bind(user_id).fetch_one(&pool).await.unwrap();
    let lt_lot: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1,$2,$3,'2022-01-01',10,40,'USD',1.0,'lt') RETURNING id",
    )
    .bind(holding_id).bind(acct).bind(user_id).fetch_one(&pool).await.unwrap();

    for (lot, src, pnl) in [(st_lot, "sell-st", "500"), (lt_lot, "sell-lt", "3000")] {
        sqlx::query(
            "INSERT INTO lot_disposals \
             (user_id, holding_id, account_id, lot_id, sell_source_id, qty_sold, sell_price_per_unit, \
              sell_currency, sell_fx_rate, sell_date, cost_per_unit, cost_fx_rate, realized_pnl_usd) \
             VALUES ($1,$2,$3,$4,$5,10,100,'USD',1.0,'2026-06-01',60,1.0,$6)",
        )
        .bind(user_id).bind(holding_id).bind(acct).bind(lot).bind(src)
        .bind(Decimal::from_str(pnl).unwrap())
        .execute(&pool).await.unwrap();
    }

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/tax/summary?year=2026&status=Single",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let status = res.status();
    let body = body_json(res.into_body()).await;
    assert_eq!(status, StatusCode::OK, "tax summary body: {body}");

    assert_eq!(body["gains_from_lots"], serde_json::json!(true));
    assert!((body["short_term_gains"].as_f64().unwrap() - 500.0).abs() < 0.01);
    assert!((body["long_term_gains"].as_f64().unwrap() - 3000.0).abs() < 0.01);
    assert!((body["capital_gains"].as_f64().unwrap() - 3500.0).abs() < 0.01);
    // T4 expectation update: this pinned ~$50 when brackets applied from
    // dollar zero. With the (unverified) standard deduction, the $500 ST gain
    // is fully absorbed and the $3,000 LT gain sits in the 0% LTCG band → $0.
    assert!(
        (body["estimated_liability_us"].as_f64().unwrap()).abs() < 0.01,
        "expected $0 US liability, got {}",
        body["estimated_liability_us"]
    );
}

#[tokio::test]
#[serial_test::serial]
async fn tax_csv_export_includes_realized_gains_and_st_lt_summary() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    let holding_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, user_id) \
         VALUES ($1, 'VTI', 'Vanguard', 'USD', $2) RETURNING id",
    )
    .bind(acct)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();

    // One short-term lot (held <1yr) and one long-term lot (held >1yr), both
    // sold in 2026.
    let st_lot: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1,$2,$3,'2026-01-01',10,60,'USD',1.0,'st') RETURNING id",
    )
    .bind(holding_id).bind(acct).bind(user_id).fetch_one(&pool).await.unwrap();
    let lt_lot: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1,$2,$3,'2022-01-01',10,40,'USD',1.0,'lt') RETURNING id",
    )
    .bind(holding_id).bind(acct).bind(user_id).fetch_one(&pool).await.unwrap();

    for (lot, src, pnl) in [(st_lot, "sell-st", "500"), (lt_lot, "sell-lt", "3000")] {
        sqlx::query(
            "INSERT INTO lot_disposals \
             (user_id, holding_id, account_id, lot_id, sell_source_id, qty_sold, sell_price_per_unit, \
              sell_currency, sell_fx_rate, sell_date, cost_per_unit, cost_fx_rate, realized_pnl_usd) \
             VALUES ($1,$2,$3,$4,$5,10,100,'USD',1.0,'2026-06-01',60,1.0,$6)",
        )
        .bind(user_id).bind(holding_id).bind(acct).bind(lot).bind(src)
        .bind(Decimal::from_str(pnl).unwrap())
        .execute(&pool).await.unwrap();
    }

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/tax/export?year=2026&status=Single",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(res.headers().get(header::CONTENT_TYPE).unwrap(), "text/csv");
    let bytes = to_bytes(res.into_body(), 1024 * 256).await.unwrap();
    let csv = String::from_utf8(bytes.to_vec()).unwrap();

    // The Form 8949-style section + per-disposal detail.
    assert!(
        csv.contains("Realized capital gains (lot disposals)"),
        "csv:\n{csv}"
    );
    assert!(csv.contains("Date acquired"), "header present");
    assert!(csv.contains("VTI"), "disposal symbol present");
    assert!(csv.contains("Short-term"), "ST term label present");
    assert!(csv.contains("Long-term"), "LT term label present");
    assert!(csv.contains("2022-01-01"), "LT acquisition date present");
    // Derived USD proceeds (10*100) and cost (10*60).
    assert!(csv.contains("1000.00"), "proceeds present");
    assert!(csv.contains("600.00"), "cost basis present");

    // The summary block with the ST/LT split.
    assert!(csv.contains("Short-term gains (USD),500.00"), "csv:\n{csv}");
    assert!(csv.contains("Long-term gains (USD),3000.00"), "csv:\n{csv}");
    assert!(csv.contains("Total capital gains (USD),3500.00"));
    assert!(csv.contains("Precise lot disposals"), "basis note present");

    // The PDF export still renders (200 + a non-empty application/pdf body).
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/tax/export/pdf?year=2026&status=Single",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(
        res.headers().get(header::CONTENT_TYPE).unwrap(),
        "application/pdf"
    );
    let pdf = to_bytes(res.into_body(), 1024 * 1024).await.unwrap();
    assert!(pdf.len() > 200, "pdf body should be non-trivial");
    assert_eq!(&pdf[0..4], b"%PDF", "starts with the PDF magic header");
}

#[tokio::test]
#[serial_test::serial]
async fn account_balance_history_returns_monthly_closing() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // Two months of statement rows with a running balance_after. The endpoint
    // should return the LAST balance in each month.
    let insert = |date: &'static str, amount: &'static str, bal: &'static str| {
        let pool = pool.clone();
        async move {
            sqlx::query(
                "INSERT INTO transactions (account_id, date, description, amount, currency, balance_after, source, user_id) \
                 VALUES ($1, $2::date, 'row', $3, 'USD', $4, 'manual', $5)",
            )
            .bind(acct)
            .bind(date)
            .bind(Decimal::from_str(amount).unwrap())
            .bind(Decimal::from_str(bal).unwrap())
            .bind(user_id)
            .execute(&pool)
            .await
            .unwrap();
        }
    };
    insert("2026-03-05", "-100.00", "900.00").await;
    insert("2026-03-20", "-50.00", "850.00").await; // latest in March
    insert("2026-04-10", "200.00", "1050.00").await; // latest in April
                                                     // A row with no balance_after must be ignored.
    seed_tx_dated(&pool, user_id, acct, "no balance", "-10.00", "2026-04-15").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/dashboard/account-balance-history?account_id={acct}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let arr = body.as_array().unwrap();
    assert_eq!(arr.len(), 2, "two months expected");
    assert_eq!(arr[0]["month"], "2026-03");
    assert!((arr[0]["balance"].as_f64().unwrap() - 850.0).abs() < 0.01);
    assert_eq!(arr[1]["month"], "2026-04");
    assert!((arr[1]["balance"].as_f64().unwrap() - 1050.0).abs() < 0.01);

    // Tenant isolation: a bogus account id yields an empty series, not data.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/account-balance-history?account_id=not-a-uuid",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert_eq!(body.as_array().unwrap().len(), 0);
}

/// An account with NO `balance_after` transactions but >=2 daily
/// `balance_snapshots` (the Plaid / manual case) now returns a
/// snapshot-derived monthly series — the latest snapshot in each month.
/// A statement account (with `balance_after`) is unaffected: its snapshots
/// are ignored so nothing double-counts.
#[tokio::test]
#[serial_test::serial]
async fn account_balance_history_falls_back_to_snapshots() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;

    // Account A: snapshot-only (no balance_after rows).
    let (_inst, snap_acct) = seed_account(&pool, user_id).await;
    let insert_snap = |acct: uuid::Uuid, date: &'static str, bal: &'static str| {
        let pool = pool.clone();
        async move {
            sqlx::query(
                "INSERT INTO balance_snapshots (account_id, balance, balance_usd, as_of_date, currency, user_id) \
                 VALUES ($1, $2, $2, $3::date, 'USD', $4)",
            )
            .bind(acct)
            .bind(Decimal::from_str(bal).unwrap())
            .bind(date)
            .bind(user_id)
            .execute(&pool)
            .await
            .unwrap();
        }
    };
    insert_snap(snap_acct, "2026-05-03", "500.00").await;
    insert_snap(snap_acct, "2026-05-28", "550.00").await; // latest in May
    insert_snap(snap_acct, "2026-06-15", "600.00").await; // latest in June

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/dashboard/account-balance-history?account_id={snap_acct}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let arr = body.as_array().unwrap();
    assert_eq!(arr.len(), 2, "two snapshot-derived months expected");
    assert_eq!(arr[0]["month"], "2026-05");
    assert!((arr[0]["balance"].as_f64().unwrap() - 550.0).abs() < 0.01);
    assert_eq!(arr[1]["month"], "2026-06");
    assert!((arr[1]["balance"].as_f64().unwrap() - 600.0).abs() < 0.01);

    // Account B: statement account WITH balance_after — snapshots must be
    // ignored (statement path wins, no double count / no regression).
    let (_inst2, stmt_acct) = seed_account(&pool, user_id).await;
    sqlx::query(
        "INSERT INTO transactions (account_id, date, description, amount, currency, balance_after, source, user_id) \
         VALUES ($1, '2026-05-10'::date, 'row', '-20.00', 'USD', '980.00', 'manual', $2)",
    )
    .bind(stmt_acct)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();
    // A stray snapshot on the same account that must NOT surface.
    insert_snap(stmt_acct, "2026-06-01", "1234.56").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/dashboard/account-balance-history?account_id={stmt_acct}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let arr = body.as_array().unwrap();
    assert_eq!(
        arr.len(),
        1,
        "statement account: only its balance_after month"
    );
    assert_eq!(arr[0]["month"], "2026-05");
    assert!((arr[0]["balance"].as_f64().unwrap() - 980.0).abs() < 0.01);
}

#[tokio::test]
#[serial_test::serial]
async fn realized_gains_summary_and_long_term_flag() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    let holding_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holdings (account_id, symbol, name, currency, user_id) \
         VALUES ($1, 'VTI', 'Vanguard Total Market', 'USD', $2) RETURNING id",
    )
    .bind(acct)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();

    let lot_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO holding_lots \
         (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1, $2, $3, (CURRENT_DATE - INTERVAL '3 years')::date, 10, 60, 'USD', 1.0, 'lot-1') RETURNING id",
    )
    .bind(holding_id)
    .bind(acct)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .unwrap();

    // This-year disposal: held ~3 years (long-term), +400 gain.
    sqlx::query(
        "INSERT INTO lot_disposals \
         (user_id, holding_id, account_id, lot_id, sell_source_id, qty_sold, sell_price_per_unit, \
          sell_currency, sell_fx_rate, sell_date, cost_per_unit, cost_fx_rate, realized_pnl_usd) \
         VALUES ($1, $2, $3, $4, 'sell-1', 10, 100, 'USD', 1.0, CURRENT_DATE, 60, 1.0, 400)",
    )
    .bind(user_id)
    .bind(holding_id)
    .bind(acct)
    .bind(lot_id)
    .execute(&pool)
    .await
    .unwrap();

    // Prior-year disposal: lot since deleted (lot_id NULL), -150 loss.
    sqlx::query(
        "INSERT INTO lot_disposals \
         (user_id, holding_id, account_id, lot_id, sell_source_id, qty_sold, sell_price_per_unit, \
          sell_currency, sell_fx_rate, sell_date, cost_per_unit, cost_fx_rate, realized_pnl_usd) \
         VALUES ($1, $2, $3, NULL, 'sell-2', 5, 50, 'USD', 1.0, (CURRENT_DATE - INTERVAL '2 years')::date, 80, 1.0, -150)",
    )
    .bind(user_id)
    .bind(holding_id)
    .bind(acct)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/realized-gains",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    // Summary: all-time = 400 - 150 = 250; YTD = 400 (this-year only).
    assert!((body["summary"]["total_realized_usd"].as_f64().unwrap() - 250.0).abs() < 0.01);
    assert!((body["summary"]["ytd_realized_usd"].as_f64().unwrap() - 400.0).abs() < 0.01);
    assert_eq!(body["summary"]["count"].as_i64().unwrap(), 2);
    assert_eq!(body["by_year"].as_array().unwrap().len(), 2);

    // Most recent disposal first: the long-term gain with USD proceeds/cost.
    let d0 = &body["disposals"][0];
    assert_eq!(d0["symbol"], "VTI");
    assert!((d0["realized_pnl_usd"].as_f64().unwrap() - 400.0).abs() < 0.01);
    assert!((d0["proceeds_usd"].as_f64().unwrap() - 1000.0).abs() < 0.01);
    assert!((d0["cost_usd"].as_f64().unwrap() - 600.0).abs() < 0.01);
    assert_eq!(d0["long_term"], serde_json::json!(true));
    assert!(d0["holding_days"].as_i64().unwrap() > 365);
    // The deleted-lot disposal has an unknown holding period.
    let d1 = &body["disposals"][1];
    assert!(d1["long_term"].is_null());

    // Year filter narrows the list to the current year only.
    let this_year = &d0["sell_date"].as_str().unwrap()[..4];
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/dashboard/realized-gains?year={this_year}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert_eq!(body["summary"]["count"].as_i64().unwrap(), 1);
    assert_eq!(body["disposals"].as_array().unwrap().len(), 1);
}

// =====================================================================
// Round 2 — WS1: day change (C-B), instrument detail (C-A), dividend
// payments (C-D), realized-gains account context (C-C), CSV exports
// (C-E), unclassified allocation band (C-G).
// =====================================================================

/// C-B: per-row day change comes from the last two STORED closes; cash
/// sleeves, single-close and stale-close symbols stay null and are excluded
/// from the totals + coverage numerator.
#[tokio::test]
#[serial_test::serial]
async fn holdings_day_change_from_stored_closes_and_coverage() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;
    let brok = seed_typed_account(&pool, user_id, inst, "Brokerage", "brokerage", "2090.00").await;

    // Covered: GOOG, two fresh closes 100 -> 102 (+2%).
    seed_holding(
        &pool,
        user_id,
        brok,
        "GOOG",
        "Alphabet",
        "equity",
        "10",
        Some("102"),
        "1020",
        Some("900"),
    )
    .await;
    seed_close(&pool, "GOOG", 1, "100").await;
    seed_close(&pool, "GOOG", 0, "102").await;
    // Null paths: 401k-trust style row (no closes at all)…
    seed_holding(
        &pool,
        user_id,
        brok,
        "VANG TARGET RET 2045",
        "Vanguard Target 2045 Trust",
        "",
        "47",
        None,
        "470",
        None,
    )
    .await;
    // …cash sleeve (fresh closes exist but the row is cash)…
    seed_holding(
        &pool,
        user_id,
        brok,
        "CUR:USD",
        "US Dollar",
        "cash",
        "200",
        Some("1"),
        "200",
        None,
    )
    .await;
    // …stale series (latest close 8 days old)…
    seed_holding(
        &pool,
        user_id,
        brok,
        "MSFT",
        "Microsoft",
        "equity",
        "1",
        Some("300"),
        "300",
        None,
    )
    .await;
    seed_close(&pool, "MSFT", 9, "290").await;
    seed_close(&pool, "MSFT", 8, "300").await;
    // …and a single-close symbol.
    seed_holding(
        &pool,
        user_id,
        brok,
        "NVDA",
        "NVIDIA",
        "equity",
        "1",
        Some("100"),
        "100",
        None,
    )
    .await;
    seed_close(&pool, "NVDA", 0, "100").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/holdings",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    let holdings = body["holdings"].as_array().unwrap();
    let by_symbol = |s: &str| holdings.iter().find(|h| h["symbol"] == s).unwrap();

    let goog = by_symbol("GOOG");
    assert!(
        (goog["day_change_pct"].as_f64().unwrap() - 2.0).abs() < 1e-6,
        "{goog}"
    );
    assert!(
        (goog["day_change_usd"].as_f64().unwrap() - 20.4).abs() < 1e-6,
        "{goog}"
    );
    let today = chrono::Utc::now().date_naive().to_string();
    assert_eq!(goog["price_as_of"].as_str().unwrap(), today);
    // Round-1 regression guard: asset_class untouched.
    assert_eq!(goog["asset_class"], "equity");

    for sym in ["VANG TARGET RET 2045", "CUR:USD", "MSFT", "NVDA"] {
        let h = by_symbol(sym);
        assert!(h["day_change_usd"].is_null(), "{sym} should be null: {h}");
        assert!(h["day_change_pct"].is_null(), "{sym} should be null: {h}");
        assert!(h["price_as_of"].is_null(), "{sym} should be null: {h}");
    }

    // Totals cover GOOG only: +20.4 on a prior value of 999.6.
    assert!((body["day_change_usd"].as_f64().unwrap() - 20.4).abs() < 1e-6);
    assert!((body["day_change_pct"].as_f64().unwrap() - (20.4 / 999.6 * 100.0)).abs() < 1e-6);
    // Coverage: 1020 covered of 2090 total.
    assert!(
        (body["day_change_coverage_pct"].as_f64().unwrap() - (1020.0 / 2090.0 * 100.0)).abs()
            < 1e-6,
        "coverage: {}",
        body["day_change_coverage_pct"]
    );
    assert_eq!(body["day_change_as_of"].as_str().unwrap(), today);
}

/// C-A: full contract for a held ticker (chart ranges honored), graceful
/// degradation for an opaque symbol, 404 for an unheld one.
#[tokio::test]
#[serial_test::serial]
async fn instrument_detail_contract_ranges_opaque_and_404() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;
    let brok = seed_typed_account(&pool, user_id, inst, "Robinhood", "brokerage", "5085.80").await;
    let k401 = seed_typed_account(&pool, user_id, inst, "Employer 401k", "401k", "12000.00").await;

    let nvda = seed_holding(
        &pool,
        user_id,
        brok,
        "NVDA",
        "NVIDIA Corp",
        "equity",
        "29.5",
        Some("172.40"),
        "5085.80",
        Some("3100"),
    )
    .await;
    seed_holding(
        &pool,
        user_id,
        k401,
        "VANG TARGET RET 2045",
        "Vanguard Target Retirement 2045 Trust",
        "",
        "100",
        None,
        "12000",
        None,
    )
    .await;
    sqlx::query(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1, $2, $3, '2024-03-01', 10, 88.10, 'USD', 1.0, 'lot-nvda')",
    )
    .bind(nvda)
    .bind(brok)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    // Four stored closes; latest is CURRENT_DATE so the freshness gate never
    // reaches for Yahoo during the test.
    seed_close(&pool, "NVDA", 100, "150").await;
    seed_close(&pool, "NVDA", 50, "160").await;
    seed_close(&pool, "NVDA", 10, "170").await;
    seed_close(&pool, "NVDA", 0, "171.7").await;

    // Case-insensitive match + default 1y range.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/instruments/nvda",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    assert_eq!(body["symbol"], "NVDA");
    assert_eq!(body["name"], "NVIDIA Corp");
    assert_eq!(body["currency"], "USD");
    assert_eq!(body["asset_class"], "equity");
    assert!((body["quantity"].as_f64().unwrap() - 29.5).abs() < 1e-9);
    assert!((body["price"].as_f64().unwrap() - 172.40).abs() < 1e-9);
    assert!((body["value_usd"].as_f64().unwrap() - 5085.80).abs() < 1e-9);
    // Lots-preferred basis: the single lot (881) outranks the flat 3100.
    assert!((body["cost_basis_usd"].as_f64().unwrap() - 881.0).abs() < 1e-9);
    assert!((body["gain_loss_usd"].as_f64().unwrap() - 4204.8).abs() < 1e-9);
    // Weight over the whole holdings portfolio (5085.80 + 12000).
    let want_weight = (5085.80f64 / 17085.80 * 100.0 * 100.0).round() / 100.0;
    assert!((body["portfolio_weight_pct"].as_f64().unwrap() - want_weight).abs() < 1e-9);
    // Day change from the last two closes: 170 -> 171.7 = +1%.
    assert!((body["day_change_pct"].as_f64().unwrap() - 1.0).abs() < 1e-9);
    assert!((body["day_change_usd"].as_f64().unwrap() - 50.86).abs() < 1e-9);
    let today = chrono::Utc::now().date_naive().to_string();
    assert_eq!(body["price_as_of"].as_str().unwrap(), today);
    let accounts = body["accounts"].as_array().unwrap();
    assert_eq!(accounts.len(), 1);
    assert_eq!(accounts[0]["account_name"], "Robinhood");
    assert_eq!(accounts[0]["account_type"], "brokerage");
    assert_eq!(accounts[0]["tax_advantaged"], false);
    let lots = body["lots"].as_array().unwrap();
    assert_eq!(lots.len(), 1);
    assert_eq!(lots[0]["acquired_at"], "2024-03-01");
    assert!((lots[0]["usd_cost"].as_f64().unwrap() - 881.0).abs() < 1e-9);
    assert_eq!(
        body["prices"].as_array().unwrap().len(),
        4,
        "1y default: all four closes"
    );

    // Ranges narrow the series.
    for (range, want_points) in [("1m", 2), ("3m", 3), ("max", 4)] {
        let res = app
            .clone()
            .oneshot(req(
                Method::GET,
                &format!("/api/dashboard/instruments/NVDA?range={range}"),
                None,
                Some(&token),
            ))
            .await
            .unwrap();
        let body = body_json(res.into_body()).await;
        assert_eq!(
            body["prices"].as_array().unwrap().len(),
            want_points,
            "range={range}"
        );
    }

    // Opaque symbol: 200 with empty prices + null day stats, accounts intact.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/instruments/VANG%20TARGET%20RET%202045",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["prices"], serde_json::json!([]));
    assert!(body["day_change_usd"].is_null());
    assert!(body["day_change_pct"].is_null());
    assert!(body["price_as_of"].is_null());
    assert!(body["price"].is_null());
    assert!(body["cost_basis_usd"].is_null());
    assert_eq!(body["accounts"][0]["account_type"], "401k");
    assert_eq!(body["accounts"][0]["tax_advantaged"], true);

    // Unheld symbol: 404 with the C-A error shape.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/instruments/TSLA",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["error"], "unknown symbol");
}

/// C-D: payments match conservatively — positive INCOME_DIVIDENDS (or
/// dividend-worded) rows naming the ticker as a whole word, in accounts
/// that hold the symbol; everything else stays out; regex-unsafe symbols
/// skip matching entirely.
#[tokio::test]
#[serial_test::serial]
async fn dividend_detail_payments_matched_conservatively() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;
    let holder = seed_typed_account(&pool, user_id, inst, "Fidelity HSA", "hsa", "1000.00").await;
    let other = seed_typed_account(
        &pool,
        user_id,
        inst,
        "Other Brokerage",
        "brokerage",
        "1000.00",
    )
    .await;

    // ZZTQ deliberately unresolvable on Yahoo — the live dividend fetch
    // degrades to none and the payments section still populates.
    seed_holding(
        &pool,
        user_id,
        holder,
        "ZZTQ",
        "ZZ Test Corp",
        "equity",
        "10",
        Some("100"),
        "1000",
        None,
    )
    .await;

    // Matches: positive + INCOME_DIVIDENDS + ticker as a whole word, in the
    // holding account.
    seed_dividend_tx(
        &pool,
        user_id,
        holder,
        "Dividend received: ZZTQ",
        "105.60",
        Some("INCOME_DIVIDENDS"),
        0,
    )
    .await;
    // Matches: no category, but the Spanish "dividendo" wording + ticker.
    seed_dividend_tx(
        &pool,
        user_id,
        holder,
        "Dividendo ZZTQ pagado",
        "33.00",
        None,
        30,
    )
    .await;
    // No match: ticker only as a substring (ZZTQX).
    seed_dividend_tx(
        &pool,
        user_id,
        holder,
        "ZZTQX distribution",
        "50.00",
        Some("INCOME_DIVIDENDS"),
        1,
    )
    .await;
    // No match: negative amount (a reversal).
    seed_dividend_tx(
        &pool,
        user_id,
        holder,
        "ZZTQ dividend reversal",
        "-105.60",
        Some("INCOME_DIVIDENDS"),
        2,
    )
    .await;
    // No match: right wording, WRONG account (doesn't hold ZZTQ).
    seed_dividend_tx(
        &pool,
        user_id,
        other,
        "ZZTQ dividend",
        "75.00",
        Some("INCOME_DIVIDENDS"),
        3,
    )
    .await;
    // No match: dividend wording without the ticker.
    seed_dividend_tx(
        &pool,
        user_id,
        holder,
        "Quarterly dividend payment",
        "12.00",
        None,
        4,
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/dividends/ZZTQ",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    let payments = body["payments"].as_array().expect("payments array");
    assert_eq!(
        payments.len(),
        2,
        "exactly the two conservative matches: {payments:#?}"
    );
    // Newest first.
    assert!((payments[0]["amount_usd"].as_f64().unwrap() - 105.60).abs() < 0.001);
    assert_eq!(payments[0]["account_name"], "Fidelity HSA");
    assert!((payments[1]["amount_usd"].as_f64().unwrap() - 33.0).abs() < 0.001);

    // Regex-unsafe symbol (':' outside [A-Za-z0-9.-]): matching is skipped
    // entirely — empty payments even with a would-be-matching row present.
    seed_holding(
        &pool,
        user_id,
        holder,
        "ZZ:WEIRD",
        "Weird Pseudo",
        "equity",
        "1",
        Some("1"),
        "1",
        None,
    )
    .await;
    seed_dividend_tx(
        &pool,
        user_id,
        holder,
        "ZZ:WEIRD dividend",
        "9.00",
        Some("INCOME_DIVIDENDS"),
        5,
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/dividends/ZZ%3AWEIRD",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["payments"], serde_json::json!([]));
}

/// C-C: every disposal row carries its account context + advantaged flag,
/// and the summary's taxable subtotal covers the returned (year-filtered)
/// list's non-advantaged rows only.
#[tokio::test]
#[serial_test::serial]
async fn realized_gains_account_context_and_taxable_subtotal() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;
    let brok = seed_typed_account(&pool, user_id, inst, "Robinhood", "brokerage", "0").await;
    let roth = seed_typed_account(&pool, user_id, inst, "Roth IRA", "roth", "0").await;
    // Nickname outranks the bank name in the row context.
    sqlx::query("UPDATE accounts SET nickname = 'My Roth' WHERE id = $1")
        .bind(roth)
        .execute(&pool)
        .await
        .unwrap();

    seed_disposal(&pool, user_id, brok, "VTI", "1774.50", 0, "s1").await;
    seed_disposal(&pool, user_id, roth, "SCHD", "1195.00", 0, "s2").await;
    seed_disposal(&pool, user_id, brok, "VXUS", "4053.50", 1, "s3").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/realized-gains",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    let disposals = body["disposals"].as_array().unwrap();
    assert_eq!(disposals.len(), 3);
    let schd = disposals.iter().find(|d| d["symbol"] == "SCHD").unwrap();
    assert_eq!(schd["account_name"], "My Roth");
    assert_eq!(schd["account_type"], "roth");
    assert_eq!(schd["tax_advantaged"], true);
    let vti = disposals.iter().find(|d| d["symbol"] == "VTI").unwrap();
    assert_eq!(vti["account_name"], "Robinhood");
    assert_eq!(vti["tax_advantaged"], false);
    // All-history list: both brokerage disposals are taxable.
    assert!(
        (body["summary"]["taxable_realized_usd"].as_f64().unwrap() - 5828.0).abs() < 0.001,
        "taxable: {}",
        body["summary"]["taxable_realized_usd"]
    );

    // Year filter recomputes the taxable subtotal over that year's list.
    let this_year = chrono::Utc::now().format("%Y").to_string();
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/dashboard/realized-gains?year={this_year}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert_eq!(body["summary"]["count"].as_i64().unwrap(), 2);
    assert!(
        (body["summary"]["taxable_realized_usd"].as_f64().unwrap() - 1774.50).abs() < 0.001,
        "year-filtered taxable: {}",
        body["summary"]["taxable_realized_usd"]
    );
}

/// C-E: holdings + lots CSV exports — headers, filename, RFC-4180 quoting
/// of a name containing a comma AND quotes, and row counts matching the
/// JSON endpoint's data.
#[tokio::test]
#[serial_test::serial]
async fn holdings_and_lots_csv_exports() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;
    let brok =
        seed_typed_account(&pool, user_id, inst, "Main Brokerage", "brokerage", "1000").await;
    let acme = seed_holding(
        &pool,
        user_id,
        brok,
        "ACME",
        "Acme \"Widgets\", Inc",
        "equity",
        "10",
        Some("100"),
        "1000",
        Some("800"),
    )
    .await;
    sqlx::query(
        "INSERT INTO holding_lots (holding_id, account_id, user_id, acquired_at, qty, cost_per_unit, currency, usd_fx_rate, source_id) \
         VALUES ($1, $2, $3, '2024-01-15', 10, 80, 'USD', 1.0, 'lot-acme'), \
                ($1, $2, $3, '2024-02-15', 0, 90, 'USD', 1.0, 'depletion-marker')",
    )
    .bind(acme)
    .bind(brok)
    .bind(user_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/holdings/export",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert!(res
        .headers()
        .get(header::CONTENT_TYPE)
        .unwrap()
        .to_str()
        .unwrap()
        .starts_with("text/csv"));
    let dispo = res
        .headers()
        .get(header::CONTENT_DISPOSITION)
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert!(dispo.contains("attachment"), "{dispo}");
    assert!(dispo.contains("patrimonio_holdings_"), "{dispo}");
    let body = body_text(res.into_body()).await;
    let lines: Vec<&str> = body.trim_end().split('\n').collect();
    assert_eq!(lines[0], "symbol,name,account,institution,account_type,asset_class,quantity,price,currency,value,value_usd,cost_basis_usd,gain_loss_usd,gain_loss_pct");
    assert_eq!(lines.len(), 2, "header + one holding: {body}");
    // RFC-4180: embedded quotes doubled, whole field quoted, comma preserved.
    assert!(
        lines[1].contains("\"Acme \"\"Widgets\"\", Inc\""),
        "quoting: {}",
        lines[1]
    );
    // Lots-preferred basis (800) surfaces in the row — money fields are
    // serialized at 2dp so spreadsheets never see float noise like
    // `3679.9999999999995`.
    assert!(lines[1].contains(",800.00,"), "basis: {}", lines[1]);

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/holdings/lots/export",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let dispo = res
        .headers()
        .get(header::CONTENT_DISPOSITION)
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert!(dispo.contains("patrimonio_lots_"), "{dispo}");
    let body = body_text(res.into_body()).await;
    let lines: Vec<&str> = body.trim_end().split('\n').collect();
    assert_eq!(
        lines[0],
        "symbol,account,acquired_at,qty,cost_per_unit,currency,usd_cost"
    );
    // The qty-0 depletion marker is filtered — one active lot only.
    assert_eq!(lines.len(), 2, "header + one active lot: {body}");
    assert!(lines[1].contains("2024-01-15"), "{}", lines[1]);
    assert!(
        lines[1].ends_with(",800.00"),
        "usd_cost (2dp money): {}",
        lines[1]
    );
}

/// C-E: realized-gains CSV honors the year filter, carries the C-C account
/// context, and rejects unauthenticated callers like its siblings.
#[tokio::test]
#[serial_test::serial]
async fn realized_gains_csv_export_year_filter_and_auth() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;
    let brok = seed_typed_account(&pool, user_id, inst, "Robinhood", "brokerage", "0").await;
    let roth = seed_typed_account(&pool, user_id, inst, "Roth IRA", "roth", "0").await;

    seed_disposal(&pool, user_id, brok, "VTI", "1774.50", 0, "s1").await;
    seed_disposal(&pool, user_id, roth, "SCHD", "1195.00", 0, "s2").await;
    seed_disposal(&pool, user_id, brok, "VXUS", "4053.50", 1, "s3").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/realized-gains/export",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let dispo = res
        .headers()
        .get(header::CONTENT_DISPOSITION)
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert!(dispo.contains("patrimonio_realized_gains_"), "{dispo}");
    let body = body_text(res.into_body()).await;
    let lines: Vec<&str> = body.trim_end().split('\n').collect();
    assert_eq!(lines[0], "sell_date,symbol,name,account,account_type,tax_advantaged,qty_sold,proceeds_usd,cost_usd,realized_pnl_usd,holding_days,long_term");
    assert_eq!(lines.len(), 4, "header + all three disposals: {body}");
    let schd_line = lines.iter().find(|l| l.contains("SCHD")).unwrap();
    assert!(
        schd_line.contains("\"roth\",true"),
        "C-C context in CSV: {schd_line}"
    );

    // Year filter: only the prior-year row, and the year lands in the filename.
    let prior_year = chrono::Utc::now()
        .format("%Y")
        .to_string()
        .parse::<i32>()
        .unwrap()
        - 1;
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/dashboard/realized-gains/export?year={prior_year}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let dispo = res
        .headers()
        .get(header::CONTENT_DISPOSITION)
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert!(
        dispo.contains(&format!("patrimonio_realized_gains_{prior_year}_")),
        "{dispo}"
    );
    let body = body_text(res.into_body()).await;
    let lines: Vec<&str> = body.trim_end().split('\n').collect();
    assert_eq!(lines.len(), 2, "header + the one {prior_year} row: {body}");
    assert!(lines[1].contains("VXUS"), "{}", lines[1]);

    // Unauthenticated: same rejection as the transactions export.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/realized-gains/export",
            None,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

/// C-G: an active investment-category account with a balance but NO
/// holdings rows surfaces as an 'unclassified' allocation band; the same
/// category of account WITH holdings never double-counts.
#[tokio::test]
#[serial_test::serial]
async fn allocation_unclassified_band_for_holdingsless_investment_account() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;

    // Balance-only investment account (the CETES case).
    seed_typed_account(&pool, user_id, inst, "CETES", "investment", "12000.00").await;
    // Investment account WITH holdings — must NOT produce a band.
    let brok = seed_typed_account(&pool, user_id, inst, "Brokerage", "brokerage", "6000.00").await;
    seed_holding(
        &pool,
        user_id,
        brok,
        "VTI",
        "Vanguard Total Market",
        "equity",
        "10",
        Some("600"),
        "6000",
        None,
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/allocation",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().unwrap();

    let unclassified: Vec<_> = rows
        .iter()
        .filter(|r| r["asset_class"] == "unclassified")
        .collect();
    assert_eq!(unclassified.len(), 1, "exactly the CETES band: {rows:#?}");
    assert_eq!(unclassified[0]["category"], "Unclassified");
    assert_eq!(unclassified[0]["sub_category"], "CETES");
    assert!((unclassified[0]["value"].as_f64().unwrap() - 12000.0).abs() < 0.01);
    // The holdings-backed account still classifies through its holdings.
    assert!(rows
        .iter()
        .any(|r| r["asset_class"] == "equity" && r["sub_category"] == "VTI"));
}

/// fix-5: a balance-only account whose account_type IS an asset class
/// ('bonds' — the CETES Directo case: literally Mexican treasury bills)
/// lands in the Bonds band, not "Unclassified (account balance)"; ambiguous
/// types ('brokerage') still surface as unclassified. The MXN balance also
/// pins the FX swap: the allocation endpoint now goes through the shared
/// `latest_usd_mxn_rate` (manual-override precedence), not its old inline
/// newest-row query with a silent `.unwrap_or(20.0)` fallback.
#[tokio::test]
#[serial_test::serial]
async fn allocation_bonds_account_type_classifies_as_bonds() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;

    // Balance-only bonds account in MXN (CETES Directo).
    sqlx::query(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'CETES Directo', 'bonds', 'MXN', 180000.00, $2)",
    )
    .bind(inst)
    .bind(user_id)
    .execute(&pool)
    .await
    .expect("seed CETES account");
    // Balance-only AMBIGUOUS type — must stay unclassified.
    seed_typed_account(
        &pool,
        user_id,
        inst,
        "Mystery Brokerage",
        "brokerage",
        "5000.00",
    )
    .await;

    // A newer 'api' rate AND an older 'manual' override: the shared
    // latest_usd_mxn_rate picks the manual row (18.0); the old inline query
    // ordered by recorded_at alone and would have used 17.0.
    sqlx::query(
        "INSERT INTO exchange_rates (base_currency, target_currency, rate, recorded_at, source) \
         VALUES ('USD', 'MXN', 17.00, NOW(), 'api'), \
                ('USD', 'MXN', 18.00, NOW() - INTERVAL '1 hour', 'manual')",
    )
    .execute(&pool)
    .await
    .expect("seed fx rates");

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/allocation",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().unwrap();

    // CETES → Bonds, converted at the manual 18.0 rate: 180000 / 18 = 10000.
    let bonds: Vec<_> = rows
        .iter()
        .filter(|r| r["asset_class"] == "bonds")
        .collect();
    assert_eq!(bonds.len(), 1, "exactly the CETES band: {rows:#?}");
    assert_eq!(bonds[0]["category"], "Bonds");
    assert_eq!(bonds[0]["sub_category"], "CETES Directo");
    assert!(
        (bonds[0]["value"].as_f64().unwrap() - 10000.0).abs() < 0.01,
        "expected 180000 MXN / 18.0 manual rate = 10000 USD, got {}",
        bonds[0]["value"]
    );

    // The ambiguous brokerage balance is the ONLY unclassified band.
    let unclassified: Vec<_> = rows
        .iter()
        .filter(|r| r["asset_class"] == "unclassified")
        .collect();
    assert_eq!(unclassified.len(), 1, "only the brokerage band: {rows:#?}");
    assert_eq!(unclassified[0]["sub_category"], "Mystery Brokerage");
}

// =====================================================================
// Round 3 — C3-A asset-class overrides + C3-B soft delete / restore
// =====================================================================

/// C3-A: the PUT matrix (200 set / 200 clear / 422 bad class / 404 unheld)
/// and the read-side precedence — one override flips the holdings rows in
/// EVERY account, the allocation band, the CSV export, and the instrument
/// detail (with its `asset_class_source` flag); clearing reverts them all.
#[tokio::test]
#[serial_test::serial]
async fn asset_class_override_matrix_and_precedence_everywhere() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;
    let brok = seed_typed_account(&pool, user_id, inst, "Brokerage", "brokerage", "6000.00").await;
    let ira = seed_typed_account(&pool, user_id, inst, "IRA", "ira", "3000.00").await;

    // Same instrument in TWO accounts — one edit must cover both.
    seed_holding(
        &pool,
        user_id,
        brok,
        "VTI",
        "Vanguard Total Market",
        "etf",
        "10",
        Some("600"),
        "6000",
        None,
    )
    .await;
    seed_holding(
        &pool,
        user_id,
        ira,
        "VTI",
        "Vanguard Total Market",
        "etf",
        "5",
        Some("600"),
        "3000",
        None,
    )
    .await;
    // Fresh close so /instruments/VTI never reaches for Yahoo in the test.
    seed_close(&pool, "VTI", 0, "600").await;

    let alloc_total = |rows: &Value| -> f64 {
        rows.as_array()
            .unwrap()
            .iter()
            .map(|r| r["value"].as_f64().unwrap())
            .sum()
    };
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/allocation",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let total_before = alloc_total(&body_json(res.into_body()).await);

    // ---- SET: case-insensitive path, normalized symbol echoed back. ----
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/dashboard/instruments/vti/asset-class",
            Some(&serde_json::json!({"asset_class": "bonds"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(
        body,
        serde_json::json!({
            "symbol": "VTI",
            "asset_class": "bonds",
            "asset_class_source": "override"
        })
    );

    // Holdings: BOTH rows (brokerage + IRA) carry the override.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/holdings",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let vti_rows: Vec<_> = body["holdings"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|h| h["symbol"] == "VTI")
        .collect();
    assert_eq!(vti_rows.len(), 2);
    assert!(
        vti_rows.iter().all(|h| h["asset_class"] == "bonds"),
        "{vti_rows:?}"
    );

    // Allocation: the VTI band moved to bonds wholesale; total unchanged.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/allocation",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().unwrap();
    let vti_band = rows
        .iter()
        .find(|r| r["sub_category"] == "VTI")
        .expect("VTI band");
    assert_eq!(vti_band["asset_class"], "bonds");
    assert!((vti_band["value"].as_f64().unwrap() - 9000.0).abs() < 0.01);
    assert!(!rows
        .iter()
        .any(|r| r["asset_class"] == "equity" && r["sub_category"] == "VTI"));
    assert!(
        (alloc_total(&body) - total_before).abs() < 0.01,
        "dimension total unchanged"
    );

    // CSV export classifies with the same precedence.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/holdings/export",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let csv = body_text(res.into_body()).await;
    let vti_line = csv.lines().find(|l| l.contains("\"VTI\"")).unwrap();
    assert!(vti_line.contains("\"bonds\""), "csv: {vti_line}");

    // Instrument detail: override + source flag.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/instruments/VTI",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert_eq!(body["asset_class"], "bonds");
    assert_eq!(body["asset_class_source"], "override");
    // C3-A extension: the heuristic rides along so the sheet can label its
    // "Automatic — Equity" revert row while the override is active.
    assert_eq!(body["asset_class_heuristic"], "equity");

    // ---- CLEAR: null body reverts everything to the heuristic. ----
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/dashboard/instruments/VTI/asset-class",
            Some(&serde_json::json!({"asset_class": null})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(
        body,
        serde_json::json!({
            "symbol": "VTI",
            "asset_class": "equity",
            "asset_class_source": "heuristic"
        })
    );
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/holdings",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert!(body["holdings"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|h| h["symbol"] == "VTI")
        .all(|h| h["asset_class"] == "equity"));
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/instruments/VTI",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert_eq!(body["asset_class"], "equity");
    assert_eq!(body["asset_class_source"], "heuristic");
    assert_eq!(body["asset_class_heuristic"], "equity");

    // ---- 422: unknown class key. ----
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/dashboard/instruments/VTI/asset-class",
            Some(&serde_json::json!({"asset_class": "stonks"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNPROCESSABLE_ENTITY);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["error"], "invalid asset class");

    // ---- 404: symbol the caller doesn't hold. ----
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/dashboard/instruments/TSLA/asset-class",
            Some(&serde_json::json!({"asset_class": "bonds"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["error"], "unknown symbol");
}

// =====================================================================
// /dashboard/transactions — currency / sign / q filters
//
// The loan-repayment picker used to pull one recent page and filter in
// the client, so a repayment older than the newest N — or in a foreign
// currency — was invisible. These filters push that scoping into SQL over
// the WHOLE table: the picker can now find any matching inflow.
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn transactions_currency_sign_and_search_filters() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let _ = bootstrap(&app, &pool).await;
    let (user_id, token) = seed_owner(&pool, "picker").await;

    let mxn = seed_account_currency(&pool, user_id, "MXN").await;
    let usd = seed_account_currency(&pool, user_id, "USD").await;

    // The repayment we want the picker to find.
    let repayment = seed_tx_currency(
        &pool,
        user_id,
        mxn,
        "SPEI RECIBIDO LUIS OJEDA",
        "3500.00",
        "MXN",
    )
    .await;
    // Same-currency inflow that does NOT match the search.
    let other_mxn_inflow =
        seed_tx_currency(&pool, user_id, mxn, "OXXO reembolso", "200.00", "MXN").await;
    // Wrong sign (MXN outflow) — must never appear as a repayment candidate.
    let mxn_outflow = seed_tx_currency(&pool, user_id, mxn, "CFE pago", "-1000.00", "MXN").await;
    // Right sign, wrong currency — reconciling it would 400, so it must be
    // filtered out before the user can pick it.
    let usd_inflow = seed_tx_currency(&pool, user_id, usd, "PAYCHECK LUIS", "500.00", "USD").await;

    // currency=MXN & sign=inflow → the two MXN inflows only.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/transactions?currency=MXN&sign=inflow&limit=200",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let ids = tx_ids(body_json(res.into_body()).await);
    assert!(
        ids.contains(&repayment.to_string()),
        "MXN inflow must be listed"
    );
    assert!(
        ids.contains(&other_mxn_inflow.to_string()),
        "other MXN inflow must be listed"
    );
    assert!(
        !ids.contains(&mxn_outflow.to_string()),
        "sign=inflow must exclude the MXN outflow"
    );
    assert!(
        !ids.contains(&usd_inflow.to_string()),
        "currency=MXN must exclude the USD inflow"
    );

    // Add a search term → only the SPEI Luis inflow survives, proving the
    // match is found in SQL rather than by scanning one client-side page.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/transactions?currency=MXN&sign=inflow&q=luis",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let ids = tx_ids(body_json(res.into_body()).await);
    assert_eq!(
        ids,
        vec![repayment.to_string()],
        "q=luis should return exactly the SPEI Luis repayment"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn transactions_exclude_linked_hides_reconciled_repayment() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let _ = bootstrap(&app, &pool).await;
    let (user_id, token) = seed_owner(&pool, "linkpicker").await;

    let mxn = seed_account_currency(&pool, user_id, "MXN").await;
    let linked =
        seed_tx_currency(&pool, user_id, mxn, "SPEI RECIBIDO LUIS", "3500.00", "MXN").await;
    let free = seed_tx_currency(&pool, user_id, mxn, "SPEI RECIBIDO OTRO", "3500.00", "MXN").await;

    // Reconcile `linked` to a loan payment.
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

    // Without the flag, both inflows show.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/transactions?sign=inflow&currency=MXN",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let ids = tx_ids(body_json(res.into_body()).await);
    assert!(ids.contains(&linked.to_string()) && ids.contains(&free.to_string()));

    // With exclude_linked, the reconciled one drops out; the free one stays.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/transactions?sign=inflow&currency=MXN&exclude_linked=true",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let ids = tx_ids(body_json(res.into_body()).await);
    assert!(
        !ids.contains(&linked.to_string()),
        "exclude_linked must hide the already-reconciled tx"
    );
    assert!(
        ids.contains(&free.to_string()),
        "exclude_linked must keep an unlinked tx"
    );
}

// =====================================================================
// Dashboard trends / spending / emergency-fund — per-row historical FX
//
// Same bug class as /api/projections/defaults above: these endpoints used
// to convert MONTHS of historical MXN transactions at the single LATEST
// USD/MXN rate. Each test seeds flows in two months under two different
// stored rates and asserts the response matches per-row (on-or-before-date)
// conversion — and provably differs from what latest-rate conversion would
// produce.
//
// Shared fixture: rate 20.00 recorded ~100 days ago, rate 21.00 recorded
// ~40 days ago (also the latest). Month A (100d back) flows convert at 20;
// month B (40d back) flows convert at 21. 100d and 40d are always in
// different calendar months (60 days apart) and both inside every window
// these endpoints use.
// =====================================================================

/// Regression: /api/dashboard/trends must convert each month's MXN flows at
/// that month's rate, not restate the whole 12-month chart at today's rate.
#[tokio::test]
#[serial_test::serial]
async fn cash_flow_trends_converts_each_month_at_its_own_fx_rate() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let mxn_acct = seed_account_currency(&pool, user_id, "MXN").await;

    seed_fx_rate_days_ago(&pool, "20.00", 100).await;
    seed_fx_rate_days_ago(&pool, "21.00", 40).await;

    // Month A (rate 20): +20,000 → $1,000.00; −2,100 → $105.00
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "salary A", "20000.00", "MXN", 100).await;
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent A", "-2100.00", "MXN", 100).await;
    // Month B (rate 21): +10,000 → $476.190476…; −1,050 → $50.00
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "salary B", "10000.00", "MXN", 40).await;
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent B", "-1050.00", "MXN", 40).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/trends",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let points = body.as_array().expect("trends array");
    assert_eq!(points.len(), 2, "one point per seeded month: {body}");

    // Rows come back ORDER BY month ASC, so [0] = month A, [1] = month B.
    let inc_a = points[0]["income"].as_f64().unwrap();
    let sp_a = points[0]["spending"].as_f64().unwrap();
    let inc_b = points[1]["income"].as_f64().unwrap();
    let sp_b = points[1]["spending"].as_f64().unwrap();
    assert!(
        (inc_a - 1000.00).abs() < 0.01,
        "month A income {inc_a}: expected 1000.00 at its own rate 20 \
         (latest-rate bug would give 952.38)"
    );
    assert!(
        (sp_a - 105.00).abs() < 0.01,
        "month A spending {sp_a}: expected 105.00 at its own rate 20 \
         (latest-rate bug would give 100.00)"
    );
    assert!(
        (inc_b - 476.19).abs() < 0.01,
        "month B income {inc_b}: expected 476.19 at rate 21"
    );
    assert!(
        (sp_b - 50.00).abs() < 0.01,
        "month B spending {sp_b}: expected 50.00 at rate 21"
    );
}

/// Regression: /api/dashboard/emergency-fund's trailing-12-month spend
/// (the runway denominator) must convert per row. The liquid-cash numerator
/// deliberately stays at the LATEST rate — a current balance is a
/// present-day value — and this test pins that policy split.
#[tokio::test]
#[serial_test::serial]
async fn emergency_fund_spend_per_row_fx_cash_at_latest_rate() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;

    // A liquid (checking) MXN account holding 2,100 MXN today.
    let inst_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ('Banco', 'bank', 'MX', 'manual', 'ok', $1) RETURNING id",
    )
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed institution");
    let mxn_acct: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Cuenta', 'checking', 'MXN', 2100.00, $2) RETURNING id",
    )
    .bind(inst_id)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed checking account");

    seed_fx_rate_days_ago(&pool, "20.00", 100).await;
    seed_fx_rate_days_ago(&pool, "21.00", 40).await;

    // −2,100 MXN at rate 20 → $105.00; −1,050 MXN at rate 21 → $50.00.
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent A", "-2100.00", "MXN", 100).await;
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent B", "-1050.00", "MXN", 40).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/emergency-fund",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    // Current cash converts at the LATEST rate (21): 2100 / 21 = $100.00.
    let cash = body["liquid_cash_usd"].as_f64().unwrap();
    assert!(
        (cash - 100.00).abs() < 0.01,
        "liquid_cash_usd {cash}: current balances convert at the latest rate (2100/21 = 100)"
    );

    // Historical spend converts PER ROW: (105 + 50) / 2 months = $77.50.
    let spend = body["monthly_spend_usd"].as_f64().unwrap();
    assert!(
        (spend - 77.50).abs() < 0.01,
        "monthly_spend_usd {spend}: expected per-row FX 77.50 \
         (latest-rate bug would give 75.00)"
    );
    assert_eq!(body["months_of_data"].as_i64(), Some(2));
    let covered = body["months_covered"].as_f64().unwrap();
    assert!(
        (covered - 100.0 / 77.50).abs() < 0.001,
        "months_covered {covered}: expected 100 / 77.50"
    );
}

/// Regression: /api/dashboard/spending-by-category totals use per-row FX
/// (same converted-CTE shape as trends — one representative assertion).
#[tokio::test]
#[serial_test::serial]
async fn spending_by_category_per_row_fx() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let mxn_acct = seed_account_currency(&pool, user_id, "MXN").await;

    seed_fx_rate_days_ago(&pool, "20.00", 100).await;
    seed_fx_rate_days_ago(&pool, "21.00", 40).await;
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent A", "-2100.00", "MXN", 100).await;
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent B", "-1050.00", "MXN", 40).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/spending-by-category",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    let cats = body["categories"].as_array().expect("categories array");
    assert_eq!(cats.len(), 1, "one seeded category: {body}");
    assert_eq!(cats[0]["category"], "UNCATEGORIZED");
    let total = cats[0]["total"].as_f64().unwrap();
    // Per-row: 2100/20 + 1050/21 = 105 + 50 = 155. Latest-rate bug: 150.
    assert!(
        (total - 155.00).abs() < 0.01,
        "category total {total}: expected per-row FX 155.00 (latest-rate bug would give 150.00)"
    );
}

/// Regression: /api/dashboard/spending-insights averages use per-row FX
/// (same converted-CTE shape — one representative assertion on the
/// trailing average, which spans both rate regimes).
#[tokio::test]
#[serial_test::serial]
async fn spending_insights_per_row_fx() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let mxn_acct = seed_account_currency(&pool, user_id, "MXN").await;

    seed_fx_rate_days_ago(&pool, "20.00", 100).await;
    seed_fx_rate_days_ago(&pool, "21.00", 40).await;
    // Both dates are always inside the default window (lookback 3 → the 4
    // complete months before the current one): 40 days back is always before
    // the current month starts, 100 days back is always after the window
    // start (≥ ~120 days back).
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent A", "-2100.00", "MXN", 100).await;
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent B", "-1050.00", "MXN", 40).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/spending-insights",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    let cats = body["categories"].as_array().expect("categories array");
    assert_eq!(cats.len(), 1, "one seeded category group: {body}");
    let trailing = cats[0]["trailing_avg"].as_f64().unwrap();
    // Per-row: (2100/20 + 1050/21) / 4-month window = 155/4 = 38.75.
    // Latest-rate bug: 150/4 = 37.50.
    assert!(
        (trailing - 38.75).abs() < 0.01,
        "trailing_avg {trailing}: expected per-row FX 38.75 (latest-rate bug would give 37.50)"
    );
}

// =====================================================================
// Dashboard trends / spending / emergency-fund — errors are 500s, empty
// data is still a 200
//
// These four handlers used to swallow DB failures (`.unwrap_or_default()`
// / `.ok().flatten()`), rendering "the query blew up" as an empty chart /
// all-zeros runway. They now return Result<_, ApiError> and 500 loudly.
// The tests below pin the OTHER half of that contract: a user with
// genuinely no data must still get a 200 with the same empty-shaped body
// as before — only errors changed behavior. (A real DB error can't be
// simulated through the harness; the signature change + clippy guard it.)
// =====================================================================

/// A brand-new user with zero transactions gets 200 + `[]` from /trends,
/// not an error — "no data" is a legitimate empty state, not a failure.
#[tokio::test]
#[serial_test::serial]
async fn cash_flow_trends_no_data_is_200_empty_array() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user_id) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/trends",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::OK,
        "empty data must stay a 200, not a 500"
    );
    let body = body_json(res.into_body()).await;
    assert_eq!(
        body,
        serde_json::json!([]),
        "no transactions → empty array, same shape as before the error-handling change"
    );
}

/// A brand-new user with zero accounts/transactions gets 200 + an
/// all-zeros runway from /emergency-fund — the ungrouped aggregates
/// still decode as (0, 0) on genuinely empty data.
#[tokio::test]
#[serial_test::serial]
async fn emergency_fund_no_data_is_200_zero_runway() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user_id) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/emergency-fund",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::OK,
        "empty data must stay a 200, not a 500"
    );
    let body = body_json(res.into_body()).await;
    assert_eq!(
        body["liquid_cash_usd"].as_f64(),
        Some(0.0),
        "no accounts → $0 cash: {body}"
    );
    assert_eq!(
        body["monthly_spend_usd"].as_f64(),
        Some(0.0),
        "no spend → $0/mo: {body}"
    );
    assert_eq!(
        body["months_covered"].as_f64(),
        Some(0.0),
        "no spend signal → 0 months: {body}"
    );
    assert_eq!(
        body["months_of_data"].as_i64(),
        Some(0),
        "no history → 0 months of data: {body}"
    );
}

/// All four upgraded chart endpoints still require auth: unauthenticated
/// requests are 401, not empty-but-200 bodies.
#[tokio::test]
#[serial_test::serial]
async fn dashboard_chart_endpoints_unauthenticated_are_401() {
    let Some((app, _pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    for uri in [
        "/api/dashboard/trends",
        "/api/dashboard/spending-by-category",
        "/api/dashboard/spending-insights",
        "/api/dashboard/emergency-fund",
        "/api/dashboard/benchmark-comparison",
    ] {
        let res = app
            .clone()
            .oneshot(req(Method::GET, uri, None, None))
            .await
            .unwrap();
        assert_eq!(
            res.status(),
            StatusCode::UNAUTHORIZED,
            "{uri} without a session must 401"
        );
    }
}
