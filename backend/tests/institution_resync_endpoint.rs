//! Integration tests for the per-institution FULL RE-PULL:
//! `POST /api/institutions/{id}/resync`.
//!
//! Background: `plaid_transactions_cursor` only ever advances, and a Plaid
//! `removed` entry hard-DELETEs the local row — so a transaction that was
//! never delivered (the owner's June "Bilt Housing Payment" pair) had no
//! recovery path at all. The re-pull clears the cursor so Plaid replays the
//! item's whole history, and the transaction upsert is keyed on
//! `(account_id, external_id)` so the replay heals gaps without duplicating
//! rows or clobbering the owner's own corrections.
//!
//! The last test is the one that matters: it drives the REAL re-import write
//! path (`services::sync::upsert_plaid_transaction`, `pub` precisely so an
//! integration test can reach it without a Plaid sandbox) over rows that
//! already carry a hand edit and a rule-applied edit, and asserts both — plus
//! their provenance columns — survive.

mod common;
use common::fixtures::*;

/// Seed a Plaid institution with a stored `/transactions/sync` cursor.
async fn seed_plaid_inst_with_cursor(
    pool: &PgPool,
    user_id: uuid::Uuid,
    cursor: &str,
    status: &str,
) -> uuid::Uuid {
    sqlx::query_scalar(
        "INSERT INTO institutions \
         (name, institution_type, country, integration_type, sync_status, \
          plaid_transactions_cursor, user_id) \
         VALUES ('Bilt', 'bank', 'US', 'plaid', $1, $2, $3) RETURNING id",
    )
    .bind(status)
    .bind(cursor)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed plaid institution")
}

async fn cursor_of(pool: &PgPool, id: uuid::Uuid) -> Option<String> {
    sqlx::query_scalar("SELECT plaid_transactions_cursor FROM institutions WHERE id = $1")
        .bind(id)
        .fetch_one(pool)
        .await
        .expect("read cursor")
}

fn resync_uri(id: uuid::Uuid) -> String {
    format!("/api/institutions/{id}/resync")
}

/// The core contract: the cursor is cleared (so the next `/transactions/sync`
/// replays full history) and a sync is actually kicked off — 202, never a
/// blocking request.
#[tokio::test]
#[serial_test::serial]
async fn resync_clears_cursor_and_triggers_sync() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    let inst = seed_plaid_inst_with_cursor(&pool, user_id, "cursor-from-june", "synced").await;

    let res = app
        .clone()
        .oneshot(req(Method::POST, &resync_uri(inst), None, Some(&cookie)))
        .await
        .unwrap();
    let status = res.status();
    let body = body_json(res.into_body()).await;
    assert_eq!(
        status,
        StatusCode::ACCEPTED,
        "a full re-pull is fire-and-forget (DEC-021), not a blocking request"
    );
    assert_eq!(body["status"], "accepted");

    assert_eq!(
        cursor_of(&pool, inst).await,
        None,
        "the whole point: with a NULL cursor Plaid replays the item's full history"
    );

    // The cursor must be cleared BEFORE the sync starts, and the sync must
    // actually be triggered. `mark_syncable_syncing` runs synchronously inside
    // the handler, so by the time we see the 202 the institution has left
    // 'synced'; the detached task can only move it on to another non-'synced'
    // status here (no Plaid creds / no access token in the harness).
    assert_ne!(
        sync_status_of(&pool, inst).await,
        "synced",
        "the re-pull must actually kick a sync, not just reset the cursor"
    );
}

/// Cross-tenant safety: another user's institution is a flat 404, and its
/// cursor is left alone (a reset would silently force a full re-pull on a
/// stranger's Plaid item).
#[tokio::test]
#[serial_test::serial]
async fn resync_foreign_institution_is_404_and_leaves_cursor() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (cookie, _user_a) = bootstrap(&app, &pool).await;
    let user_b: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, password_hash) VALUES ('other', 'x') RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .expect("seed second user");
    let foreign = seed_plaid_inst_with_cursor(&pool, user_b, "b-cursor", "synced").await;

    let res = app
        .clone()
        .oneshot(req(Method::POST, &resync_uri(foreign), None, Some(&cookie)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["error"], "Institution not found");

    assert_eq!(
        cursor_of(&pool, foreign).await,
        Some("b-cursor".to_string()),
        "another user's cursor must never be reset"
    );
    assert_eq!(
        sync_status_of(&pool, foreign).await,
        "synced",
        "and their institution must not be marked syncing"
    );

    // An id that belongs to nobody is the same 404 — no existence probe.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &resync_uri(uuid::Uuid::new_v4()),
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
}

/// Manual / CSV institutions have no Plaid cursor. Saying "accepted" and
/// doing nothing is how a missing transaction goes unnoticed for another
/// month — the endpoint must reject them explicitly.
#[tokio::test]
#[serial_test::serial]
async fn resync_manual_institution_is_a_clear_error_and_leaves_cursor_untouched() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    let manual = seed_inst(&pool, user_id, "manual", "manual").await;
    // A manual institution has no business carrying a cursor, but stamp one so
    // the "untouched" assertion below can actually fail if the guard is
    // dropped.
    sqlx::query("UPDATE institutions SET plaid_transactions_cursor = 'stale' WHERE id = $1")
        .bind(manual)
        .execute(&pool)
        .await
        .expect("stamp cursor");

    let res = app
        .clone()
        .oneshot(req(Method::POST, &resync_uri(manual), None, Some(&cookie)))
        .await
        .unwrap();
    let status = res.status();
    let body = body_json(res.into_body()).await;
    assert_eq!(
        status,
        StatusCode::BAD_REQUEST,
        "a manual institution can't be re-pulled from Plaid"
    );
    assert_eq!(
        body["error"], "Full re-pull is only available for Plaid institutions",
        "the error has to name the reason, not fail silently"
    );

    assert_eq!(
        cursor_of(&pool, manual).await,
        Some("stale".to_string()),
        "the rejected request must not have touched the cursor"
    );
    assert_eq!(
        sync_status_of(&pool, manual).await,
        "manual",
        "and must not have marked it syncing"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn resync_unauthenticated_is_401() {
    let Some((app, _pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &resync_uri(uuid::Uuid::new_v4()),
            None,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

/// CSRF middleware sits OUTSIDE auth, so a missing `X-Requested-With` on this
/// mutating route is a 403 before the session is ever looked at.
#[tokio::test]
#[serial_test::serial]
async fn resync_without_csrf_header_is_403() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    let inst = seed_plaid_inst_with_cursor(&pool, user_id, "c", "synced").await;

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri(resync_uri(inst))
                .header(header::COOKIE, cookie_header(&cookie))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);
    assert_eq!(
        cursor_of(&pool, inst).await,
        Some("c".to_string()),
        "a CSRF-rejected request must not have reset anything"
    );
}

/// **The one that matters.** A full re-pull replays EVERY transaction Plaid
/// holds for the item, including thousands of rows the owner has already
/// corrected by hand or had labelled by a rule. Re-importing over them must
/// preserve `user_category` / `user_description` and their provenance
/// (`*_source`, `*_rule_id`) — otherwise the recovery tool wipes months of
/// corrections as the price of recovering two rows.
///
/// This drives the real re-import write path with canned Plaid JSON (there is
/// no Plaid sandbox in CI); the HTTP endpoint above only clears the cursor and
/// hands off to exactly this function.
#[tokio::test]
#[serial_test::serial]
async fn full_repull_preserves_user_edits_and_their_provenance() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (_cookie, user_id) = bootstrap(&app, &pool).await;
    let inst = seed_plaid_inst_with_cursor(&pool, user_id, "cursor-from-june", "synced").await;

    let account: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, external_id, name, account_type, currency, \
         current_balance, user_id) \
         VALUES ($1, 'plaid-acct-bilt', 'Bilt Card', 'credit', 'USD', -100.00, $2) RETURNING id",
    )
    .bind(inst)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed plaid account");

    // A real rule row so the rule-applied transaction's FK resolves; the rule
    // is deliberately NOT passed to the re-import (rule application is
    // insert-only), which is precisely why its residue must survive on its own.
    let rule_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO user_rules (user_id, match_type, match_value, set_category) \
         VALUES ($1, 'contains', 'mta', 'Transit') RETURNING id",
    )
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed rule");

    // Row 1: corrected by hand (both fields, source 'manual').
    let hand_edited: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO transactions \
         (account_id, external_id, date, description, amount, currency, source, user_id, \
          user_category, user_category_source, user_description, user_description_source) \
         VALUES ($1, 'plaid-tx-rent', DATE '2026-06-25', 'BILT HOUSING PAYMENT', -3038.13, \
                 'USD', 'plaid', $2, 'Rent', 'manual', 'June rent', 'manual') RETURNING id",
    )
    .bind(account)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed hand-edited tx");

    // Row 2: labelled by a rule (source 'rule', with the rule id recorded).
    let rule_labelled: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO transactions \
         (account_id, external_id, date, description, amount, currency, source, user_id, \
          user_category, user_category_source, user_category_rule_id, \
          user_description, user_description_source, user_description_rule_id) \
         VALUES ($1, 'plaid-tx-mta', DATE '2026-06-14', 'MTA*NYCT PAYGO', -2.90, \
                 'USD', 'plaid', $2, 'Transit', 'rule', $3, 'Subway', 'rule', $3) RETURNING id",
    )
    .bind(account)
    .bind(user_id)
    .bind(rule_id)
    .fetch_one(&pool)
    .await
    .expect("seed rule-labelled tx");

    // The full re-pull: Plaid replays both rows (same transaction_ids), with
    // its own bank-reported description/category and no knowledge of the
    // user's edits. Empty rule set — a re-pull is a data recovery, not a
    // re-categorisation.
    let replay = |ext: &str, name: &str, amount: f64, date: &str| {
        serde_json::json!({
            "account_id": "plaid-acct-bilt",
            "transaction_id": ext,
            "date": date,
            "name": name,
            "amount": amount,
            "iso_currency_code": "USD",
            "pending": false,
            "personal_finance_category": {
                "primary": "GENERAL_SERVICES",
                "detailed": "GENERAL_SERVICES_OTHER_GENERAL_SERVICES"
            },
        })
    };
    for tx in [
        replay(
            "plaid-tx-rent",
            "Bilt Housing Payment",
            3038.13,
            "2026-06-25",
        ),
        replay("plaid-tx-mta", "MTA*NYCT PAYGO", 2.90, "2026-06-14"),
    ] {
        patrimonio::services::sync::upsert_plaid_transaction(&pool, &tx, user_id, &[])
            .await
            .expect("re-pull upsert");
    }

    // Same rows, not new ones — the `(account_id, external_id)` conflict key
    // is what makes a cursor reset non-duplicating.
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM transactions WHERE account_id = $1")
        .bind(account)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 2, "a full re-pull must not duplicate existing rows");

    let user_fields = |id: uuid::Uuid| {
        let pool = pool.clone();
        async move {
            let row = sqlx::query(
                "SELECT user_category, user_category_source, user_category_rule_id, \
                 user_description, user_description_source, user_description_rule_id, \
                 description FROM transactions WHERE id = $1",
            )
            .bind(id)
            .fetch_one(&pool)
            .await
            .expect("read transaction");
            (
                row.get::<Option<String>, _>("user_category"),
                row.get::<Option<String>, _>("user_category_source"),
                row.get::<Option<uuid::Uuid>, _>("user_category_rule_id"),
                row.get::<Option<String>, _>("user_description"),
                row.get::<Option<String>, _>("user_description_source"),
                row.get::<Option<uuid::Uuid>, _>("user_description_rule_id"),
                row.get::<String, _>("description"),
            )
        }
    };

    let hand = user_fields(hand_edited).await;
    assert_eq!(
        (hand.0.clone(), hand.1.clone(), hand.2),
        (Some("Rent".into()), Some("manual".into()), None),
        "a hand-edited category must survive a full re-pull"
    );
    assert_eq!(
        (hand.3.clone(), hand.4.clone(), hand.5),
        (Some("June rent".into()), Some("manual".into()), None),
        "a hand-edited description must survive a full re-pull"
    );
    assert_eq!(
        hand.6, "Bilt Housing Payment",
        "the bank-reported description still refreshes — only user_* is untouchable"
    );

    let ruled = user_fields(rule_labelled).await;
    assert_eq!(
        (ruled.0.clone(), ruled.1.clone(), ruled.2),
        (Some("Transit".into()), Some("rule".into()), Some(rule_id)),
        "a rule-applied category AND its provenance must survive a full re-pull"
    );
    assert_eq!(
        (ruled.3.clone(), ruled.4.clone(), ruled.5),
        (Some("Subway".into()), Some("rule".into()), Some(rule_id)),
        "a rule-applied description AND its provenance must survive a full re-pull"
    );
}
