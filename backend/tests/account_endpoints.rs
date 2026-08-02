//! HTTP-level integration tests for the `/api/accounts/*` surface:
//! transaction splits, batch update/delete, manual-row PUT edits, per-account
//! transaction paging, holding soft-delete/restore, and the accounts summary.
//!
//! Split out of the former all-in-one `dashboard_endpoints.rs`. Shared
//! harness + fixtures: `tests/common/fixtures.rs`.

mod common;
use common::fixtures::*;

// =====================================================================
// /api/accounts/transactions/{id}/splits — split + unsplit + edit-split
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn split_creates_children_and_hides_parent_in_listing() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let parent = seed_tx(&pool, user_id, account, "Costco run", "200.00").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "Groceries", "amount": "120.00"},
                    {"description": "Household", "amount": "80.00"}
                ]
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Listing hides the parent now (NOT EXISTS-children filter), but
    // both children should appear with parent_id set.
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
    let parent_visible = rows
        .iter()
        .any(|r| r["id"].as_str().unwrap_or_default() == parent.to_string());
    assert!(
        !parent_visible,
        "parent should be hidden once it has children"
    );
    let child_count = rows
        .iter()
        .filter(|r| r["parent_id"].as_str().unwrap_or_default() == parent.to_string())
        .count();
    assert_eq!(child_count, 2, "both children should appear");
}

#[tokio::test]
#[serial_test::serial]
async fn split_rejects_total_mismatch() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let parent = seed_tx(&pool, user_id, account, "Off-by-one", "100.00").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "A", "amount": "60.00"},
                    {"description": "B", "amount": "30.00"}
                ]
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
#[serial_test::serial]
async fn split_rejects_sign_mismatch() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let parent = seed_tx(&pool, user_id, account, "Sign mix", "100.00").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "A", "amount": "150.00"},
                    {"description": "B", "amount": "-50.00"}
                ]
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
#[serial_test::serial]
async fn split_already_split_returns_422() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let parent = seed_tx(&pool, user_id, account, "Already split", "100.00").await;

    let payload = serde_json::json!({
        "splits": [
            {"description": "A", "amount": "60.00"},
            {"description": "B", "amount": "40.00"}
        ]
    });
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&payload),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Second attempt without unsplit first.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&payload),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNPROCESSABLE_ENTITY);
    let body = body_json(res.into_body()).await;
    assert!(
        body["error"]
            .as_str()
            .unwrap_or("")
            .contains("already split"),
        "expected 'already split' error, got: {body:?}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn put_replace_splits_atomic() {
    // The new PUT endpoint replaces children atomically — no window
    // where the parent appears un-split to a concurrent reader.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let parent = seed_tx(&pool, user_id, account, "Atomic edit", "100.00").await;

    // Initial split.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "A", "amount": "50.00"},
                    {"description": "B", "amount": "50.00"}
                ]
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Replace via PUT — no unsplit step needed.
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "X", "amount": "30.00"},
                    {"description": "Y", "amount": "30.00"},
                    {"description": "Z", "amount": "40.00"}
                ]
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["removed"], 2);
    assert_eq!(body["inserted"], 3);

    let amounts: Vec<Decimal> = sqlx::query_scalar(
        "SELECT amount FROM transactions WHERE parent_id = $1 ORDER BY amount DESC",
    )
    .bind(parent)
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(amounts.len(), 3);
    assert_eq!(amounts[0], Decimal::from_str("40.00").unwrap());
    assert_eq!(amounts[1], Decimal::from_str("30.00").unwrap());
    assert_eq!(amounts[2], Decimal::from_str("30.00").unwrap());
}

#[tokio::test]
#[serial_test::serial]
async fn put_replace_splits_rejects_total_mismatch() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let parent = seed_tx(&pool, user_id, account, "Bad replace", "100.00").await;

    // Pre-existing split.
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "A", "amount": "60.00"},
                    {"description": "B", "amount": "40.00"}
                ]
            })),
            Some(&token),
        ))
        .await
        .unwrap();

    // Replace with totals that don't match — must 422, and crucially
    // must NOT delete the existing children before failing
    // (transactional rollback).
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "X", "amount": "10.00"},
                    {"description": "Y", "amount": "20.00"}
                ]
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNPROCESSABLE_ENTITY);

    // Original children should still be there. The validation runs
    // before the BEGIN ... DELETE ... INSERT block.
    let count: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM transactions WHERE parent_id = $1")
        .bind(parent)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(count, 2);
}

#[tokio::test]
#[serial_test::serial]
async fn edit_split_via_unsplit_then_resplit() {
    // This mirrors what the frontend does for the "Edit split" button:
    // DELETE the children, then re-POST a new split set.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let parent = seed_tx(&pool, user_id, account, "Roundtrip", "100.00").await;

    // First split.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "A1", "amount": "50.00"},
                    {"description": "B1", "amount": "50.00"}
                ]
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Unsplit returns 200 with `{"removed": N}` on success.
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/accounts/transactions/{parent}/splits"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["removed"], 2);

    // Children should be gone, parent visible again.
    let children: i64 =
        sqlx::query_scalar("SELECT COUNT(*) FROM transactions WHERE parent_id = $1")
            .bind(parent)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(children, 0);

    // Re-split with new amounts (60/40 instead of 50/50).
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "A2", "amount": "60.00"},
                    {"description": "B2", "amount": "40.00"}
                ]
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let amounts: Vec<Decimal> = sqlx::query_scalar(
        "SELECT amount FROM transactions WHERE parent_id = $1 ORDER BY amount DESC",
    )
    .bind(parent)
    .fetch_all(&pool)
    .await
    .unwrap();
    assert_eq!(amounts.len(), 2);
    assert_eq!(amounts[0], Decimal::from_str("60.00").unwrap());
    assert_eq!(amounts[1], Decimal::from_str("40.00").unwrap());
}

#[tokio::test]
#[serial_test::serial]
async fn unsplit_nonexistent_parent_is_404() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            "/api/accounts/transactions/00000000-0000-0000-0000-000000000000/splits",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
}

#[tokio::test]
#[serial_test::serial]
async fn split_cross_user_is_404() {
    // User A's parent transaction should be invisible to user B.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token_a, user_a) = bootstrap(&app, &pool).await;
    let (_inst, account_a) = seed_account(&pool, user_a).await;
    let parent = seed_tx(&pool, user_a, account_a, "A's tx", "100.00").await;

    // Hand-roll user B (the bootstrap path is owner-only; a second
    // user comes from an invite). We bypass the invite mint for
    // brevity by inserting directly.
    let user_b: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, email, password_hash) \
         VALUES ('bob', 'bob@example.com', 'doesnt-matter-for-this-test') RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .expect("seed user b");
    // Use the production session helper so the SHA-256 of the
    // raw token + the BYTEA encoding match exactly what
    // require_auth expects.
    let token_b = patrimonio::services::sessions::create_session(&pool, user_b, None, None)
        .await
        .expect("create user b session")
        .token;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "A", "amount": "50"},
                    {"description": "B", "amount": "50"}
                ]
            })),
            Some(&token_b),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
    // And token_a should still be able to split its own row.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/transactions/{parent}/splits"),
            Some(&serde_json::json!({
                "splits": [
                    {"description": "A", "amount": "50"},
                    {"description": "B", "amount": "50"}
                ]
            })),
            Some(&token_a),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
}

// =====================================================================
// /api/accounts/transactions/batch — bulk category / account update
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn batch_set_category_on_many_txns() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let t1 = seed_tx(&pool, user_id, account, "Coffee", "4.50").await;
    let t2 = seed_tx(&pool, user_id, account, "Lunch", "12.00").await;
    let t3 = seed_tx(&pool, user_id, account, "Dinner", "30.00").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            "/api/accounts/transactions/batch",
            Some(&serde_json::json!({
                "ids": [t1.to_string(), t2.to_string(), t3.to_string()],
                "user_category": "Dining"
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["updated"], 3);

    for t in [t1, t2, t3] {
        assert_eq!(
            tx_category(&pool, t).await.as_deref(),
            Some("Dining"),
            "all three should be recategorized"
        );
    }
}

#[tokio::test]
#[serial_test::serial]
async fn batch_move_account_on_many_txns() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, src) = seed_account(&pool, user_id).await;
    // A second account under the same institution to move the txns into.
    let dest: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Savings', 'depository', 'USD', 0.00, $2) RETURNING id",
    )
    .bind(inst)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed dest account");

    let t1 = seed_tx(&pool, user_id, src, "A", "1.00").await;
    let t2 = seed_tx(&pool, user_id, src, "B", "2.00").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            "/api/accounts/transactions/batch",
            Some(&serde_json::json!({
                "ids": [t1.to_string(), t2.to_string()],
                "account_id": dest.to_string()
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["updated"], 2);

    assert_eq!(tx_account(&pool, t1).await, dest);
    assert_eq!(tx_account(&pool, t2).await, dest);
}

/// Regression: the single PATCH /transactions/{id} handler wrote a
/// nonexistent `updated_at` column, so every inline edit (rename /
/// recategorize / move account) 500'd. It must 200 and persist.
#[tokio::test]
#[serial_test::serial]
async fn single_update_transaction_sets_category_ok() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let t1 = seed_tx(&pool, user_id, account, "Coffee", "4.50").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/accounts/transactions/{t1}"),
            Some(&serde_json::json!({"user_category": "Dining"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::OK,
        "single inline edit must 200, not 500"
    );
    assert_eq!(tx_category(&pool, t1).await.as_deref(), Some("Dining"));
}

// =====================================================================
// PUT /api/accounts/transactions/{id} — full edit of a manual row
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn put_manual_edit_updates_amount_date_direction_and_clears_overrides() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    // Seed an INFLOW so the edit also flips direction (sign), and give it
    // stale overrides to prove the full edit clears them (a leftover
    // user_category/user_description would keep masking the edited
    // category/description in every list view).
    let tx = seed_tx(&pool, user_id, account, "Coffee", "4.50").await;
    sqlx::query(
        "UPDATE transactions SET user_category = 'Old override', user_description = 'Renamed' \
         WHERE id = $1",
    )
    .bind(tx)
    .execute(&pool)
    .await
    .expect("stamp overrides");

    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            &format!("/api/accounts/transactions/{tx}"),
            Some(&manual_edit_body(account)),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "manual edit should succeed");

    let row = sqlx::query(
        "SELECT date, description, amount, currency, category, user_category, \
                user_description, user_notes, external_id \
         FROM transactions WHERE id = $1",
    )
    .bind(tx)
    .fetch_one(&pool)
    .await
    .expect("read edited row");
    assert_eq!(
        row.get::<chrono::NaiveDate, _>("date").to_string(),
        "2026-01-15"
    );
    assert_eq!(row.get::<String, _>("description"), "Team dinner");
    assert_eq!(
        row.get::<Decimal, _>("amount"),
        Decimal::from_str("-62.75").unwrap(),
        "amount + direction (sign) must be rewritten"
    );
    assert_eq!(row.get::<String, _>("currency"), "USD");
    assert_eq!(
        row.get::<Option<String>, _>("category").as_deref(),
        Some("Dining")
    );
    assert_eq!(
        row.get::<Option<String>, _>("user_notes").as_deref(),
        Some("will be reimbursed")
    );
    assert_eq!(
        row.get::<Option<String>, _>("user_category"),
        None,
        "stale user_category override must be cleared by a full edit"
    );
    assert_eq!(
        row.get::<Option<String>, _>("user_description"),
        None,
        "stale user_description override must be cleared by a full edit"
    );
    // The dedup signature follows the edited fields, exactly as the
    // create path would have computed it for these values.
    assert_eq!(
        row.get::<Option<String>, _>("external_id").as_deref(),
        Some("manual:2026-01-15:-62.75:team dinner"),
    );
}

#[tokio::test]
#[serial_test::serial]
async fn put_manual_edit_rejects_non_manual_source_with_403() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    // A Plaid-synced row: its facts are the bank's, not the user's.
    let tx: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO transactions (account_id, date, description, amount, currency, source, user_id) \
         VALUES ($1, CURRENT_DATE, 'Synced coffee', -4.50, 'USD', 'plaid', $2) RETURNING id",
    )
    .bind(account)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed plaid tx");

    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            &format!("/api/accounts/transactions/{tx}"),
            Some(&manual_edit_body(account)),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::FORBIDDEN,
        "synced rows must never be rewritable"
    );
    let desc: String = sqlx::query_scalar("SELECT description FROM transactions WHERE id = $1")
        .bind(tx)
        .fetch_one(&pool)
        .await
        .expect("row still there");
    assert_eq!(desc, "Synced coffee", "row must be untouched");
}

#[tokio::test]
#[serial_test::serial]
async fn put_manual_edit_cross_user_is_404() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let _ = bootstrap(&app, &pool).await;
    let (alice_id, _alice_token) = seed_owner(&pool, "alice").await;
    let (_bob_id, bob_token) = seed_owner(&pool, "bob").await;
    let (_a_inst, a_acct) = seed_account(&pool, alice_id).await;
    let a_tx = seed_tx(&pool, alice_id, a_acct, "Alice groceries", "-80.00").await;

    // Bob attacks Alice's manual row (even naming her account as target).
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            &format!("/api/accounts/transactions/{a_tx}"),
            Some(&manual_edit_body(a_acct)),
            Some(&bob_token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_FOUND,
        "foreign rows must look nonexistent, not forbidden"
    );
    let desc: String = sqlx::query_scalar("SELECT description FROM transactions WHERE id = $1")
        .bind(a_tx)
        .fetch_one(&pool)
        .await
        .expect("row still there");
    assert_eq!(desc, "Alice groceries", "Alice's row must be untouched");
}

#[tokio::test]
#[serial_test::serial]
async fn put_manual_edit_cannot_move_into_foreign_account() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let _ = bootstrap(&app, &pool).await;
    let (alice_id, alice_token) = seed_owner(&pool, "alice").await;
    let (bob_id, _bob_token) = seed_owner(&pool, "bob").await;
    let (_a_inst, a_acct) = seed_account(&pool, alice_id).await;
    let (_b_inst, b_acct) = seed_account(&pool, bob_id).await;
    let a_tx = seed_tx(&pool, alice_id, a_acct, "Alice cash", "-10.00").await;

    // Alice edits her own row but targets BOB's account — the destination
    // ownership guard must reject it (mirrors the PATCH move guard).
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            &format!("/api/accounts/transactions/{a_tx}"),
            Some(&manual_edit_body(b_acct)),
            Some(&alice_token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
    assert_eq!(
        tx_account(&pool, a_tx).await,
        a_acct,
        "row must stay on Alice's account"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn batch_empty_ids_is_400() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            "/api/accounts/transactions/batch",
            Some(&serde_json::json!({
                "ids": [],
                "user_category": "Dining"
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
#[serial_test::serial]
async fn batch_cross_tenant_cannot_touch_other_users_txns() {
    // User B's transactions must be untouchable from user A's session.
    // The `user_id` predicate filters them out → updated count excludes
    // them, and B's category stays unchanged.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let _ = bootstrap(&app, &pool).await;
    let (alice_id, alice_token) = seed_owner(&pool, "alice").await;
    let (bob_id, _bob_token) = seed_owner(&pool, "bob").await;

    let (_a_inst, a_acct) = seed_account(&pool, alice_id).await;
    let a_tx = seed_tx(&pool, alice_id, a_acct, "Alice tx", "10.00").await;
    let (_b_inst, b_acct) = seed_account(&pool, bob_id).await;
    let b_tx = seed_tx(&pool, bob_id, b_acct, "Bob tx", "20.00").await;

    // Alice tries to recategorize BOTH her tx and Bob's tx in one batch.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            "/api/accounts/transactions/batch",
            Some(&serde_json::json!({
                "ids": [a_tx.to_string(), b_tx.to_string()],
                "user_category": "Hijacked"
            })),
            Some(&alice_token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    // Only Alice's row matches the user_id filter.
    assert_eq!(body["updated"], 1, "Bob's tx must be filtered out");

    assert_eq!(tx_category(&pool, a_tx).await.as_deref(), Some("Hijacked"));
    assert_eq!(
        tx_category(&pool, b_tx).await,
        None,
        "Bob's tx must be unchanged — cross-tenant write blocked"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn batch_partial_owned_and_bogus_ids_updates_only_owned() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let owned = seed_tx(&pool, user_id, account, "Real", "5.00").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            "/api/accounts/transactions/batch",
            Some(&serde_json::json!({
                "ids": [
                    owned.to_string(),
                    "00000000-0000-0000-0000-000000000000",
                    "11111111-1111-1111-1111-111111111111"
                ],
                "user_category": "Mixed"
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["updated"], 1, "only the owned, existing id updates");
    assert_eq!(tx_category(&pool, owned).await.as_deref(), Some("Mixed"));
}

// =====================================================================
// /api/accounts/transactions/batch-delete — bulk delete
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn batch_delete_removes_many_txns() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let t1 = seed_tx(&pool, user_id, account, "Coffee", "4.50").await;
    let t2 = seed_tx(&pool, user_id, account, "Lunch", "12.00").await;
    let t3 = seed_tx(&pool, user_id, account, "Dinner", "30.00").await;
    // A fourth row that is NOT in the batch — must survive.
    let keep = seed_tx(&pool, user_id, account, "Keep", "1.00").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/accounts/transactions/batch-delete",
            Some(&serde_json::json!({
                "ids": [t1.to_string(), t2.to_string(), t3.to_string()]
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["deleted"], 3);

    for t in [t1, t2, t3] {
        assert!(!tx_exists(&pool, t).await, "deleted rows must be gone");
    }
    assert!(tx_exists(&pool, keep).await, "untouched row must survive");
}

#[tokio::test]
#[serial_test::serial]
async fn batch_delete_empty_ids_is_400() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/accounts/transactions/batch-delete",
            Some(&serde_json::json!({ "ids": [] })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
}

#[tokio::test]
#[serial_test::serial]
async fn batch_delete_cannot_touch_other_users_txns() {
    // Rows belonging to another user must be untouchable: the `user_id`
    // predicate filters them out → they're excluded from the deleted
    // count AND still present afterward.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let _ = bootstrap(&app, &pool).await;
    let (alice_id, alice_token) = seed_owner(&pool, "alice").await;
    let (bob_id, _bob_token) = seed_owner(&pool, "bob").await;

    let (_a_inst, a_acct) = seed_account(&pool, alice_id).await;
    let a_tx = seed_tx(&pool, alice_id, a_acct, "Alice tx", "10.00").await;
    let (_b_inst, b_acct) = seed_account(&pool, bob_id).await;
    let b_tx = seed_tx(&pool, bob_id, b_acct, "Bob tx", "20.00").await;

    // Alice tries to delete BOTH her tx and Bob's tx in one batch.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/accounts/transactions/batch-delete",
            Some(&serde_json::json!({
                "ids": [a_tx.to_string(), b_tx.to_string()]
            })),
            Some(&alice_token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    // Only Alice's row matches the user_id filter.
    assert_eq!(body["deleted"], 1, "Bob's tx must be filtered out");

    assert!(!tx_exists(&pool, a_tx).await, "Alice's row deleted");
    assert!(
        tx_exists(&pool, b_tx).await,
        "Bob's tx must survive — cross-tenant delete blocked"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn batch_delete_parent_cascades_to_split_children() {
    // Deleting a split parent must remove its children too (parent_id FK
    // is ON DELETE CASCADE), matching the single delete. The returned
    // count reflects only the directly-matched parent row.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let parent = seed_tx(&pool, user_id, account, "ATM withdrawal", "-200.00").await;

    // Two split children pointing at the parent.
    let child_a: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO transactions (account_id, parent_id, date, description, amount, currency, source, user_id) \
         VALUES ($1, $2, CURRENT_DATE, 'Groceries', $3, 'USD', 'manual', $4) RETURNING id",
    )
    .bind(account)
    .bind(parent)
    .bind(Decimal::from_str("-120.00").unwrap())
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed split child a");
    let child_b: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO transactions (account_id, parent_id, date, description, amount, currency, source, user_id) \
         VALUES ($1, $2, CURRENT_DATE, 'Dinner', $3, 'USD', 'manual', $4) RETURNING id",
    )
    .bind(account)
    .bind(parent)
    .bind(Decimal::from_str("-80.00").unwrap())
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed split child b");

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/accounts/transactions/batch-delete",
            Some(&serde_json::json!({ "ids": [parent.to_string()] })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    // Only the parent is directly matched; children are cascade-deleted.
    assert_eq!(body["deleted"], 1);

    assert!(!tx_exists(&pool, parent).await, "parent deleted");
    assert!(!tx_exists(&pool, child_a).await, "child cascade-deleted");
    assert!(!tx_exists(&pool, child_b).await, "child cascade-deleted");
}

// =====================================================================
// /api/accounts/{id}/transactions — optional limit/offset paging
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn account_transactions_pages_with_limit_and_offset() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    // T0 newest … T4 oldest (distinct dates → deterministic order).
    for i in 0..5 {
        seed_tx_days_ago(&pool, user_id, account, &format!("T{i}"), i).await;
    }

    // No params → legacy behavior: the whole history, newest first.
    let all = account_tx_descriptions(
        &app,
        &token,
        &format!("/api/accounts/{account}/transactions"),
    )
    .await;
    assert_eq!(all, vec!["T0", "T1", "T2", "T3", "T4"]);

    // limit alone → first page, newest first.
    let page1 = account_tx_descriptions(
        &app,
        &token,
        &format!("/api/accounts/{account}/transactions?limit=2"),
    )
    .await;
    assert_eq!(page1, vec!["T0", "T1"]);

    // limit + offset → the next slice, no overlap, no gap.
    let page2 = account_tx_descriptions(
        &app,
        &token,
        &format!("/api/accounts/{account}/transactions?limit=2&offset=2"),
    )
    .await;
    assert_eq!(page2, vec!["T2", "T3"]);

    // Offset past the end → empty list, not an error.
    let past_end = account_tx_descriptions(
        &app,
        &token,
        &format!("/api/accounts/{account}/transactions?limit=2&offset=50"),
    )
    .await;
    assert!(past_end.is_empty());
}

#[tokio::test]
#[serial_test::serial]
async fn account_transactions_clamps_degenerate_limit_and_offset() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    for i in 0..3 {
        seed_tx_days_ago(&pool, user_id, account, &format!("T{i}"), i).await;
    }

    // limit=0 clamps up to 1 (mirrors the dashboard endpoint's
    // clamp(1, 500)) instead of 500-ing or returning everything.
    let clamped_low = account_tx_descriptions(
        &app,
        &token,
        &format!("/api/accounts/{account}/transactions?limit=0"),
    )
    .await;
    assert_eq!(clamped_low, vec!["T0"]);

    // Negative offset floors to 0 → identical to the first page.
    let negative_offset = account_tx_descriptions(
        &app,
        &token,
        &format!("/api/accounts/{account}/transactions?limit=2&offset=-7"),
    )
    .await;
    assert_eq!(negative_offset, vec!["T0", "T1"]);

    // An absurd limit is accepted (clamped server-side to 500) and the
    // small table comes back whole — the clamp must not error.
    let clamped_high = account_tx_descriptions(
        &app,
        &token,
        &format!("/api/accounts/{account}/transactions?limit=99999"),
    )
    .await;
    assert_eq!(clamped_high, vec!["T0", "T1", "T2"]);
}

#[tokio::test]
#[serial_test::serial]
async fn account_transactions_include_persisted_balance_after() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    // Newest row carries a statement-imported running balance; the older
    // one doesn't (Plaid-synced / manual rows leave the column NULL).
    let with_bal = seed_tx_days_ago(&pool, user_id, account, "WithBal", 0).await;
    seed_tx_days_ago(&pool, user_id, account, "NoBal", 1).await;
    sqlx::query("UPDATE transactions SET balance_after = 1234.56 WHERE id = $1")
        .bind(with_bal)
        .execute(&pool)
        .await
        .expect("persist balance_after");

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/accounts/{account}/transactions"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().expect("array body");
    assert_eq!(rows.len(), 2);

    // Newest-first: the statement-imported row surfaces its persisted
    // balance as a JSON number…
    assert_eq!(rows[0]["description"], "WithBal");
    assert_eq!(rows[0]["balance_after"].as_f64(), Some(1234.56));
    // …and a row without one omits the key entirely
    // (skip_serializing_if) rather than sending an explicit null.
    assert_eq!(rows[1]["description"], "NoBal");
    assert!(
        rows[1].get("balance_after").is_none(),
        "NULL balance_after must be omitted from the payload"
    );
}

/// C3-B lifecycle: soft delete hides the holding AND its lots/tax history
/// from every surface (holdings, CSV/lots exports, allocation, realized
/// gains incl. by_year/ytd, instrument + dividend detail, tax summary, TWR,
/// account balance) while the row survives in the DB; restore brings every
/// figure back byte-identical.
#[tokio::test]
#[serial_test::serial]
async fn holding_soft_delete_excluded_everywhere_then_restore_byte_identical() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;
    let (brok, nvda) = seed_soft_delete_portfolio(&pool, user_id, inst).await;

    let this_year = chrono::Utc::now().format("%Y").to_string();
    let surfaces = [
        "/api/dashboard/holdings".to_string(),
        "/api/dashboard/allocation".to_string(),
        "/api/dashboard/realized-gains".to_string(),
        "/api/dashboard/portfolio-twr".to_string(),
        format!("/api/tax/summary?year={this_year}&status=Single"),
        format!("/api/accounts/{brok}/holdings"),
    ];
    async fn fetch_all(app: &Router, token: &str, surfaces: &[String]) -> Vec<Value> {
        let mut out = Vec::new();
        for uri in surfaces {
            let res = app
                .clone()
                .oneshot(req(Method::GET, uri, None, Some(token)))
                .await
                .unwrap();
            assert_eq!(res.status(), StatusCode::OK, "{uri}");
            out.push(body_json(res.into_body()).await);
        }
        out
    }
    let before = fetch_all(&app, &token, &surfaces).await;
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
    let lots_csv_before = body_text(res.into_body()).await;
    assert!(lots_csv_before.contains("NVDA"), "{lots_csv_before}");

    // ---- DELETE: same status as the old hard delete; row survives. ----
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/accounts/{brok}/holdings/{nvda}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    let deleted_at: Option<chrono::DateTime<chrono::Utc>> =
        sqlx::query_scalar("SELECT deleted_at FROM holdings WHERE id = $1")
            .bind(nvda)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(deleted_at.is_some(), "soft delete keeps the row");

    // Holdings: row gone, totals down to VTI only.
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
    assert!(!body["holdings"]
        .as_array()
        .unwrap()
        .iter()
        .any(|h| h["symbol"] == "NVDA"));
    assert!(
        (body["total_value_usd"].as_f64().unwrap() - 600.0).abs() < 0.01,
        "{}",
        body["total_value_usd"]
    );

    // Allocation: the NVDA equity band vanished; VTI (equity, still live)
    // remains, so no unclassified band appears for this account.
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
    assert!(!body
        .as_array()
        .unwrap()
        .iter()
        .any(|r| r["sub_category"] == "NVDA"));

    // Realized gains: NVDA's disposals (both years) hidden — the list, the
    // taxable subtotal, ytd, and by_year all shrink to VTI's 300.
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
    let body = body_json(res.into_body()).await;
    assert_eq!(body["summary"]["count"].as_i64().unwrap(), 1);
    assert!((body["summary"]["taxable_realized_usd"].as_f64().unwrap() - 300.0).abs() < 0.001);
    assert!((body["summary"]["ytd_realized_usd"].as_f64().unwrap() - 300.0).abs() < 0.001);
    assert!((body["summary"]["total_realized_usd"].as_f64().unwrap() - 300.0).abs() < 0.001);
    let by_year = body["by_year"].as_array().unwrap();
    assert_eq!(
        by_year.len(),
        1,
        "prior-year band was NVDA-only: {by_year:?}"
    );

    // Realized-gains CSV: no NVDA rows either.
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
    let csv = body_text(res.into_body()).await;
    assert!(!csv.contains("NVDA"), "{csv}");
    // Lots CSV: the ghost's lot is invisible.
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
    let csv = body_text(res.into_body()).await;
    assert!(!csv.contains("NVDA"), "{csv}");

    // Instrument + dividend detail: the symbol is no longer held → 404.
    for uri in [
        "/api/dashboard/instruments/NVDA",
        "/api/dashboard/dividends/NVDA",
    ] {
        let res = app
            .clone()
            .oneshot(req(Method::GET, uri, None, Some(&token)))
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::NOT_FOUND, "{uri}");
    }

    // Tax summary: only VTI's 300 short-term survives the window.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/tax/summary?year={this_year}&status=Single"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert!(
        (body["short_term_gains"].as_f64().unwrap() - 300.0).abs() < 0.01,
        "{}",
        body["short_term_gains"]
    );

    // Account panel + balance: recomputed without the ghost.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/accounts/{brok}/holdings"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert!(!body
        .as_array()
        .unwrap()
        .iter()
        .any(|h| h["symbol"] == "NVDA"));
    let balance: Decimal = sqlx::query_scalar("SELECT current_balance FROM accounts WHERE id = $1")
        .bind(brok)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(balance, Decimal::from_str("600.00").unwrap());

    // ---- RESTORE: 200 with the HOLDING_COLS row shape. ----
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/{brok}/holdings/{nvda}/restore"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["id"].as_str().unwrap(), nvda.to_string());
    assert_eq!(body["symbol"], "NVDA");
    assert!((body["value"].as_f64().unwrap() - 1000.0).abs() < 0.01);

    // Every captured surface is byte-identical to its pre-delete snapshot.
    let after = fetch_all(&app, &token, &surfaces).await;
    for (i, (b, a)) in before.iter().zip(after.iter()).enumerate() {
        assert_eq!(
            b, a,
            "surface {} ({}) changed across delete→restore",
            i, surfaces[i]
        );
    }
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
    assert_eq!(body_text(res.into_body()).await, lots_csv_before);
    let balance: Decimal = sqlx::query_scalar("SELECT current_balance FROM accounts WHERE id = $1")
        .bind(brok)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(balance, Decimal::from_str("1600.00").unwrap());
}

/// B4 purge rules: re-adding the same symbol hard-purges the soft-deleted
/// ghost (restore later must not resurrect a duplicate), and a ghost aged
/// past 24 h disappears on the next holdings write (lazy sweep — no cron).
#[tokio::test]
#[serial_test::serial]
async fn soft_delete_purge_on_readd_and_lazy_24h_sweep() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_id).await;
    let brok = seed_typed_account(&pool, user_id, inst, "Brokerage", "brokerage", "1000.00").await;
    let voo = seed_holding(
        &pool,
        user_id,
        brok,
        "VOO",
        "Vanguard S&P 500",
        "etf",
        "2",
        Some("500"),
        "1000",
        None,
    )
    .await;
    // Fresh close so create_holding's pricing path never reaches for Yahoo.
    seed_close(&pool, "VOO", 0, "500").await;
    seed_close(&pool, "ZZOLD", 0, "10").await;

    // Soft-delete VOO, then re-add the same symbol: the ghost is purged and
    // exactly ONE row (the new one) remains.
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/accounts/{brok}/holdings/{voo}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/{brok}/holdings"),
            Some(&serde_json::json!({"symbol": "VOO", "quantity": 3})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM holdings WHERE account_id = $1 AND symbol = 'VOO'",
    )
    .bind(brok)
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(count, 1, "ghost purged on re-add");
    // The purged ghost can no longer be restored.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/{brok}/holdings/{voo}/restore"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);

    // Lazy sweep: a ghost older than 24 h is hard-deleted (cascade takes its
    // lots) by the NEXT holdings write for this user.
    let old = seed_holding(
        &pool,
        user_id,
        brok,
        "ZZOLD",
        "Old Ghost",
        "equity",
        "1",
        Some("10"),
        "10",
        None,
    )
    .await;
    sqlx::query("UPDATE holdings SET deleted_at = now() - interval '25 hours' WHERE id = $1")
        .bind(old)
        .execute(&pool)
        .await
        .unwrap();
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/{brok}/holdings"),
            Some(&serde_json::json!({"symbol": "MSFT", "quantity": 1})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let gone: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM holdings WHERE id = $1")
        .bind(old)
        .fetch_one(&pool)
        .await
        .unwrap();
    assert_eq!(gone, 0, "expired ghost swept on the next holdings write");
}

/// C3-B 404 paths: another user can't restore my holding, a second restore
/// is a no-op 404, and a never-existed id 404s — all with the contract's
/// error body.
#[tokio::test]
#[serial_test::serial]
async fn restore_holding_404s_for_wrong_user_and_double_restore() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token_a, user_a) = bootstrap(&app, &pool).await;
    let (inst, _acct) = seed_account(&pool, user_a).await;
    let brok = seed_typed_account(&pool, user_a, inst, "Brokerage", "brokerage", "1000.00").await;
    let voo = seed_holding(
        &pool,
        user_a,
        brok,
        "VOO",
        "Vanguard S&P 500",
        "etf",
        "2",
        Some("500"),
        "1000",
        None,
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/accounts/{brok}/holdings/{voo}"),
            None,
            Some(&token_a),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);

    // Hand-rolled user B (same pattern as split_cross_user_is_404).
    let user_b: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, email, password_hash) \
         VALUES ('bob', 'bob@example.com', 'doesnt-matter-for-this-test') RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .expect("seed user b");
    let token_b = patrimonio::services::sessions::create_session(&pool, user_b, None, None)
        .await
        .expect("create user b session")
        .token;

    // B can't restore A's holding — and the ghost stays soft-deleted.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/{brok}/holdings/{voo}/restore"),
            None,
            Some(&token_b),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["error"], "nothing to restore");
    let still_deleted: bool =
        sqlx::query_scalar("SELECT deleted_at IS NOT NULL FROM holdings WHERE id = $1")
            .bind(voo)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert!(still_deleted);

    // Owner restores fine; the SECOND restore finds nothing.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/{brok}/holdings/{voo}/restore"),
            None,
            Some(&token_a),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/{brok}/holdings/{voo}/restore"),
            None,
            Some(&token_a),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["error"], "nothing to restore");

    // Never-existed id: same 404.
    let bogus = uuid::Uuid::new_v4();
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/accounts/{brok}/holdings/{bogus}/restore"),
            None,
            Some(&token_a),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NOT_FOUND);
}

/// Regression: GET /api/accounts/summary must convert each balance to USD
/// before summing. A MXN balance was previously added to the USD total at its
/// raw peso value (the ~18x cross-currency overstatement class), so a $1,000
/// USD + MX$20,000 (≈$1,000) portfolio reported total_assets ≈ 21,000 instead
/// of ≈ 2,000. This pins the FX conversion.
#[tokio::test]
#[serial_test::serial]
async fn accounts_summary_converts_mxn_to_usd_not_raw_sum() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    // seed_account gives one USD depository account with 1000.00 balance.
    let (inst_id, _usd_acct) = seed_account(&pool, user_id).await;

    // A second account in pesos: MX$20,000. At 20 USD→MXN that is $1,000 USD.
    sqlx::query(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Nu MXN', 'depository', 'MXN', 20000.00, $2)",
    )
    .bind(inst_id)
    .bind(user_id)
    .execute(&pool)
    .await
    .expect("seed MXN account");

    // USD→MXN = 20.0 so the peso balance converts to exactly $1,000 USD.
    sqlx::query(
        "INSERT INTO exchange_rates (base_currency, target_currency, rate, recorded_at) \
         VALUES ('USD', 'MXN', 20.00, NOW())",
    )
    .execute(&pool)
    .await
    .expect("seed fx rate");

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/accounts/summary",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let total_assets = body["total_assets"].as_f64().expect("total_assets f64");
    // $1,000 USD + $1,000 USD-equivalent = ~$2,000, NOT the raw 21,000 sum.
    assert!(
        (total_assets - 2000.0).abs() < 0.5,
        "expected ~2000 USD, got {total_assets} (raw cross-currency sum would be ~21000)"
    );
    assert!(
        total_assets < 5000.0,
        "total_assets {total_assets} looks like an un-converted peso sum"
    );
    assert_eq!(body["account_count"], 2);
}
