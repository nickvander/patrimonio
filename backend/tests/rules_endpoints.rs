//! User rules engine — CRUD, the dry-run/apply safety contract, the two
//! forward write paths, and the precedence matrix.
//!
//! The invariant under test (work/RULES_ENGINE_DESIGN.md, DEC-027): no
//! historical category/description ever changes without an explicit,
//! previewed, confirmed apply — and a human edit always wins. Most of the
//! tests here exist to pin one specific way that could break.

mod common;
use common::fixtures::*;

use patrimonio::services::rules::{self, UserRule};
use serde_json::json;
use uuid::Uuid;

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

/// `fixtures::try_setup` + a loud Redis check.
///
/// The preview/apply contract stores its single-use token in Redis, so a
/// misconfigured or dead Redis would turn every preview into a 500. Per
/// the house rule ("never conflate misconfigured with not configured"),
/// that must PANIC here rather than skip: skipping on a broken dependency
/// is how a suite passes vacuously.
async fn setup() -> Option<(Router, PgPool, common::TestLockGuard)> {
    let out = try_setup(false, None).await?;
    let url = test_redis_url();
    let client = redis::Client::open(url.clone())
        .unwrap_or_else(|e| panic!("test Redis URL {url} is not a valid Redis URL: {e}"));
    let mut conn = client
        .get_multiplexed_async_connection()
        .await
        .unwrap_or_else(|e| {
            panic!(
                "a test DB is configured, so the rules tests must run — but Redis at {url} is \
                 unreachable ({e}). Start it (see AGENTS.md) or fix {TEST_REDIS_VAR}; do NOT \
                 let this look like a passing suite."
            )
        });
    let pong: String = redis::cmd("PING")
        .query_async(&mut conn)
        .await
        .unwrap_or_else(|e| panic!("Redis at {url} did not answer PING: {e}"));
    assert_eq!(pong, "PONG", "unexpected Redis PING reply");
    Some(out)
}

/// A checksum over every field the rules engine could possibly write.
/// Used by the zero-mutation tests: if creating/editing/deleting a rule
/// changed ANY transaction's category, description or provenance, this
/// string changes.
async fn tx_checksum(pool: &PgPool) -> String {
    sqlx::query_scalar::<_, Option<String>>(
        "SELECT md5(string_agg(sig, '|' ORDER BY sig)) FROM ( \
           SELECT id::text || '~' || COALESCE(category, '') || '~' \
                  || COALESCE(user_category, '') || '~' || COALESCE(user_category_source, '') \
                  || '~' || COALESCE(user_description, '') || '~' \
                  || COALESCE(user_description_source, '') AS sig \
           FROM transactions) s",
    )
    .fetch_one(pool)
    .await
    .expect("checksum transactions")
    .unwrap_or_else(|| "empty".to_string())
}

/// Seed a transaction with explicit provenance — the precedence matrix
/// needs rows in each state {manual, legacy NULL source, learned, rule,
/// curated-only}.
#[allow(clippy::too_many_arguments)]
async fn seed_tx_provenance(
    pool: &PgPool,
    user_id: Uuid,
    account_id: Uuid,
    description: &str,
    amount: &str,
    category: Option<&str>,
    user_category: Option<&str>,
    user_category_source: Option<&str>,
) -> Uuid {
    sqlx::query_scalar(
        "INSERT INTO transactions \
             (account_id, date, description, amount, currency, source, user_id, \
              category, user_category, user_category_source) \
         VALUES ($1, CURRENT_DATE, $2, $3, 'USD', 'plaid', $4, $5, $6, $7) RETURNING id",
    )
    .bind(account_id)
    .bind(description)
    .bind(Decimal::from_str(amount).unwrap())
    .bind(user_id)
    .bind(category)
    .bind(user_category)
    .bind(user_category_source)
    .fetch_one(pool)
    .await
    .expect("seed provenance tx")
}

async fn provenance_of(pool: &PgPool, tx_id: Uuid) -> (Option<String>, Option<String>) {
    let row =
        sqlx::query("SELECT user_category, user_category_source FROM transactions WHERE id = $1")
            .bind(tx_id)
            .fetch_one(pool)
            .await
            .expect("read provenance");
    (
        row.try_get("user_category").ok().flatten(),
        row.try_get("user_category_source").ok().flatten(),
    )
}

async fn description_provenance_of(pool: &PgPool, tx_id: Uuid) -> (Option<String>, Option<String>) {
    let row = sqlx::query(
        "SELECT user_description, user_description_source FROM transactions WHERE id = $1",
    )
    .bind(tx_id)
    .fetch_one(pool)
    .await
    .expect("read description provenance");
    (
        row.try_get("user_description").ok().flatten(),
        row.try_get("user_description_source").ok().flatten(),
    )
}

async fn post_json(app: &Router, token: &str, uri: &str, body: &Value) -> (StatusCode, Value) {
    let res = app
        .clone()
        .oneshot(req(Method::POST, uri, Some(body), Some(token)))
        .await
        .unwrap();
    let status = res.status();
    (status, body_json(res.into_body()).await)
}

async fn create_rule(app: &Router, token: &str, body: &Value) -> Value {
    let (status, json) = post_json(app, token, "/api/rules", body).await;
    assert_eq!(status, StatusCode::CREATED, "create rule: {json:?}");
    json
}

/// Preview a definition and return the parsed response.
async fn preview(app: &Router, token: &str, body: &Value) -> Value {
    let (status, json) = post_json(app, token, "/api/rules/preview", body).await;
    assert_eq!(status, StatusCode::OK, "preview: {json:?}");
    json
}

async fn apply(
    app: &Router,
    token: &str,
    rule_id: &str,
    preview_token: &str,
) -> (StatusCode, Value) {
    post_json(
        app,
        token,
        &format!("/api/rules/{rule_id}/apply"),
        &json!({ "preview_token": preview_token }),
    )
    .await
}

fn oxxo_rule() -> Value {
    json!({
        "match_type": "contains",
        "match_value": "oxxo",
        "set_category": "Groceries",
    })
}

// ---------------------------------------------------------------------------
// CRUD
// ---------------------------------------------------------------------------

#[tokio::test]
#[serial_test::serial]
async fn rule_crud_roundtrip() {
    let Some((app, pool, _lock)) = skip_if_no_db(setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;

    // Create two rules — new rules append at the end of the order.
    let first = create_rule(&app, &token, &oxxo_rule()).await;
    let second = create_rule(
        &app,
        &token,
        &json!({
            "match_type": "merchant_key",
            "match_value": "STARBUCKS REFORMA",
            "account_id": account.to_string(),
            "currency": "usd",
            "direction": "outflow",
            "amount_min": "10.00",
            "amount_max": "500.00",
            "set_description": "Starbucks",
        }),
    )
    .await;
    assert!(
        second["priority"].as_i64().unwrap() > first["priority"].as_i64().unwrap(),
        "new rules append at the end of the evaluation order"
    );
    assert_eq!(second["currency"], "USD", "currency is canonicalized");

    // List returns both in priority order, including inactive ones.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/rules", None, Some(&token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let list = body_json(res.into_body()).await;
    assert_eq!(list.as_array().unwrap().len(), 2);

    // PATCH: deactivate, and clear a scope with an explicit null.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/rules/{}", second["id"].as_str().unwrap()),
            Some(&json!({ "active": false, "account_id": null })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let patched = body_json(res.into_body()).await;
    assert_eq!(patched["active"], false);
    assert!(
        patched["account_id"].is_null(),
        "explicit null clears the scope"
    );
    assert_eq!(
        patched["match_value"], "STARBUCKS REFORMA",
        "an absent field is left alone"
    );

    // Reorder rewrites priorities.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            "/api/rules/reorder",
            Some(&json!({ "ordered_ids": [second["id"], first["id"]] })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let reordered = body_json(res.into_body()).await;
    assert_eq!(reordered[0]["id"], second["id"]);
    assert_eq!(reordered[1]["id"], first["id"]);

    // Delete, then 404 on the second delete.
    for (i, expected) in [StatusCode::NO_CONTENT, StatusCode::NOT_FOUND]
        .into_iter()
        .enumerate()
    {
        let res = app
            .clone()
            .oneshot(req(
                Method::DELETE,
                &format!("/api/rules/{}", first["id"].as_str().unwrap()),
                None,
                Some(&token),
            ))
            .await
            .unwrap();
        assert_eq!(res.status(), expected, "delete attempt {}", i + 1);
    }
}

#[tokio::test]
#[serial_test::serial]
async fn rule_validation_rejects_nonsense() {
    let Some((app, pool, _lock)) = skip_if_no_db(setup().await) else {
        return;
    };
    let (token, _user_id) = bootstrap(&app, &pool).await;

    for (body, why) in [
        (
            json!({"match_type": "regex", "match_value": "x", "set_category": "A"}),
            "regex is out in v1",
        ),
        (
            json!({"match_type": "contains", "match_value": "   ", "set_category": "A"}),
            "blank match value",
        ),
        (
            json!({"match_type": "contains", "match_value": "x"}),
            "no action",
        ),
        (
            json!({"match_type": "contains", "match_value": "x", "set_category": "  "}),
            "blank action",
        ),
        (
            json!({"match_type": "contains", "match_value": "x", "set_category": "A", "direction": "sideways"}),
            "bad direction",
        ),
        (
            json!({"match_type": "contains", "match_value": "x", "set_category": "A", "amount_min": "-5"}),
            "negative bound",
        ),
        (
            json!({"match_type": "contains", "match_value": "x", "set_category": "A", "amount_min": "50", "amount_max": "10"}),
            "inverted range",
        ),
    ] {
        let (status, json) = post_json(&app, &token, "/api/rules", &body).await;
        assert_eq!(status, StatusCode::BAD_REQUEST, "{why}: {json:?}");
    }

    // A scope pointing at somebody else's account is a 404, not a rule.
    let (other_user, _other_token) = seed_owner(&pool, "neighbour").await;
    let (_inst, other_account) = seed_account(&pool, other_user).await;
    let (status, _json) = post_json(
        &app,
        &token,
        "/api/rules",
        &json!({
            "match_type": "contains", "match_value": "x", "set_category": "A",
            "account_id": other_account.to_string(),
        }),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "cross-tenant account scope");
}

#[tokio::test]
#[serial_test::serial]
async fn rule_mutations_never_touch_transactions() {
    // THE invariant: creating, editing, disabling or deleting a rule
    // mutates ZERO transaction rows on its own. Only the previewed,
    // confirmed apply may.
    let Some((app, pool, _lock)) = skip_if_no_db(setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    for i in 0..5 {
        seed_tx_provenance(
            &pool,
            user_id,
            account,
            &format!("OXXO SUC {i}"),
            "-120.00",
            Some("GENERAL_MERCHANDISE"),
            None,
            None,
        )
        .await;
    }
    let before = tx_checksum(&pool).await;

    let rule = create_rule(&app, &token, &oxxo_rule()).await;
    let id = rule["id"].as_str().unwrap().to_string();
    assert_eq!(tx_checksum(&pool).await, before, "create mutated rows");

    // A preview is a read — it must not write either.
    preview(&app, &token, &oxxo_rule()).await;
    assert_eq!(tx_checksum(&pool).await, before, "preview mutated rows");

    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/rules/{id}"),
            Some(&json!({ "set_category": "Convenience", "active": false })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(tx_checksum(&pool).await, before, "patch mutated rows");

    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/rules/{id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    assert_eq!(tx_checksum(&pool).await, before, "delete mutated rows");
}

// ---------------------------------------------------------------------------
// Preview / apply contract
// ---------------------------------------------------------------------------

#[tokio::test]
#[serial_test::serial]
async fn preview_then_apply_updates_exactly_the_previewed_rows() {
    let Some((app, pool, _lock)) = skip_if_no_db(setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;

    let match1 = seed_tx_provenance(
        &pool,
        user_id,
        account,
        "OXXO SUC 1",
        "-120.00",
        Some("GENERAL_MERCHANDISE"),
        None,
        None,
    )
    .await;
    let match2 = seed_tx_provenance(
        &pool,
        user_id,
        account,
        "COMPRA OXXO GAS",
        "-540.00",
        None,
        None,
        None,
    )
    .await;
    let miss = seed_tx_provenance(
        &pool,
        user_id,
        account,
        "WALMART SUPERCENTER",
        "-900.00",
        Some("GENERAL_MERCHANDISE"),
        None,
        None,
    )
    .await;

    let def = json!({
        "match_type": "contains",
        "match_value": "oxxo",
        "set_category": "Groceries",
        "set_description": "OXXO",
    });
    let pv = preview(&app, &token, &def).await;
    assert_eq!(pv["matched"], 2);
    assert_eq!(pv["category_changes"], 2);
    assert_eq!(pv["description_changes"], 2);
    assert_eq!(pv["skipped_manual"], 0);
    assert_eq!(pv["fx_transfer_legs"], 0);
    assert_eq!(pv["expires_in_seconds"], 900);
    assert_eq!(pv["samples"].as_array().unwrap().len(), 2);

    let rule = create_rule(&app, &token, &def).await;
    let (status, applied) = apply(
        &app,
        &token,
        rule["id"].as_str().unwrap(),
        pv["preview_token"].as_str().unwrap(),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{applied:?}");
    assert_eq!(applied["updated_category"], 2);
    assert_eq!(applied["updated_description"], 2);
    assert_eq!(applied["skipped"], 0);

    for id in [match1, match2] {
        assert_eq!(
            provenance_of(&pool, id).await,
            (Some("Groceries".into()), Some("rule".into()))
        );
        assert_eq!(
            description_provenance_of(&pool, id).await,
            (Some("OXXO".into()), Some("rule".into()))
        );
        let rule_id: Option<Uuid> =
            sqlx::query_scalar("SELECT user_category_rule_id FROM transactions WHERE id = $1")
                .bind(id)
                .fetch_one(&pool)
                .await
                .unwrap();
        assert_eq!(
            rule_id.map(|u| u.to_string()).as_deref(),
            rule["id"].as_str(),
            "the applied row records WHICH rule wrote it"
        );
    }
    // The non-matching row is untouched — the apply only ever writes the
    // previewed id set.
    assert_eq!(provenance_of(&pool, miss).await, (None, None));
}

#[tokio::test]
#[serial_test::serial]
async fn manual_edit_survives_rule_apply() {
    // The precedence matrix, cell by cell: manual and legacy-NULL-source
    // values are untouchable; rule- and learned-sourced values are freely
    // overwritten; an unset value is filled.
    let Some((app, pool, _lock)) = skip_if_no_db(setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;

    let manual = seed_tx_provenance(
        &pool,
        user_id,
        account,
        "OXXO manual",
        "-10.00",
        None,
        Some("Dining"),
        Some("manual"),
    )
    .await;
    let legacy = seed_tx_provenance(
        &pool,
        user_id,
        account,
        "OXXO legacy",
        "-10.00",
        None,
        Some("Dining"),
        None,
    )
    .await;
    let learned = seed_tx_provenance(
        &pool,
        user_id,
        account,
        "OXXO learned",
        "-10.00",
        None,
        Some("Dining"),
        Some("learned"),
    )
    .await;
    let ruled = seed_tx_provenance(
        &pool,
        user_id,
        account,
        "OXXO ruled",
        "-10.00",
        None,
        Some("Dining"),
        Some("rule"),
    )
    .await;
    let curated = seed_tx_provenance(
        &pool,
        user_id,
        account,
        "OXXO curated",
        "-10.00",
        Some("FOOD_AND_DRINK"),
        None,
        None,
    )
    .await;

    let pv = preview(&app, &token, &oxxo_rule()).await;
    assert_eq!(pv["matched"], 5);
    assert_eq!(pv["skipped_manual"], 2, "manual + legacy are protected");
    assert_eq!(
        pv["category_changes"], 3,
        "learned, rule and curated rows all change"
    );

    let rule = create_rule(&app, &token, &oxxo_rule()).await;
    let (status, applied) = apply(
        &app,
        &token,
        rule["id"].as_str().unwrap(),
        pv["preview_token"].as_str().unwrap(),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{applied:?}");
    assert_eq!(applied["updated_category"], 3);

    assert_eq!(
        provenance_of(&pool, manual).await,
        (Some("Dining".into()), Some("manual".into())),
        "a human edit is absolute"
    );
    assert_eq!(
        provenance_of(&pool, legacy).await,
        (Some("Dining".into()), None),
        "a legacy (NULL-source) value is treated as manual"
    );
    for id in [learned, ruled, curated] {
        assert_eq!(
            provenance_of(&pool, id).await,
            (Some("Groceries".into()), Some("rule".into()))
        );
    }
}

#[tokio::test]
#[serial_test::serial]
async fn row_manually_edited_between_preview_and_apply_is_skipped() {
    let Some((app, pool, _lock)) = skip_if_no_db(setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let a = seed_tx_provenance(
        &pool, user_id, account, "OXXO one", "-10.00", None, None, None,
    )
    .await;
    let b = seed_tx_provenance(
        &pool, user_id, account, "OXXO two", "-10.00", None, None, None,
    )
    .await;

    let pv = preview(&app, &token, &oxxo_rule()).await;
    assert_eq!(pv["matched"], 2);
    let rule = create_rule(&app, &token, &oxxo_rule()).await;

    // The user edits one of the previewed rows through the normal PATCH
    // before confirming the apply.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/accounts/transactions/{a}"),
            Some(&json!({ "user_category": "Coffee" })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    assert_eq!(
        provenance_of(&pool, a).await,
        (Some("Coffee".into()), Some("manual".into())),
        "the PATCH stamps manual provenance — that's what fences the row off"
    );

    let (status, applied) = apply(
        &app,
        &token,
        rule["id"].as_str().unwrap(),
        pv["preview_token"].as_str().unwrap(),
    )
    .await;
    assert_eq!(status, StatusCode::OK, "{applied:?}");
    assert_eq!(applied["updated_category"], 1);
    assert_eq!(applied["skipped"], 1, "the freshly-edited row is reported");
    assert_eq!(
        provenance_of(&pool, a).await,
        (Some("Coffee".into()), Some("manual".into())),
        "clobbered instead of skipped"
    );
    assert_eq!(
        provenance_of(&pool, b).await,
        (Some("Groceries".into()), Some("rule".into()))
    );
}

#[tokio::test]
#[serial_test::serial]
async fn rule_edited_after_preview_is_stale() {
    let Some((app, pool, _lock)) = skip_if_no_db(setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let tx = seed_tx_provenance(
        &pool,
        user_id,
        account,
        "OXXO SUC 9",
        "-10.00",
        None,
        None,
        None,
    )
    .await;

    let pv = preview(&app, &token, &oxxo_rule()).await;
    let rule = create_rule(&app, &token, &oxxo_rule()).await;
    let id = rule["id"].as_str().unwrap().to_string();

    // Change what the rule WRITES after the diff was shown.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/rules/{id}"),
            Some(&json!({ "set_category": "Convenience" })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    let (status, body) = apply(&app, &token, &id, pv["preview_token"].as_str().unwrap()).await;
    assert_eq!(
        status,
        StatusCode::CONFLICT,
        "applying a preview of a since-edited rule must 409: {body:?}"
    );
    assert_eq!(
        provenance_of(&pool, tx).await,
        (None, None),
        "the stale apply wrote nothing"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn preview_token_is_single_use() {
    let Some((app, pool, _lock)) = skip_if_no_db(setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    seed_tx_provenance(
        &pool,
        user_id,
        account,
        "OXXO SUC 3",
        "-10.00",
        None,
        None,
        None,
    )
    .await;

    let pv = preview(&app, &token, &oxxo_rule()).await;
    let rule = create_rule(&app, &token, &oxxo_rule()).await;
    let id = rule["id"].as_str().unwrap();
    let preview_token = pv["preview_token"].as_str().unwrap();

    let (first, _) = apply(&app, &token, id, preview_token).await;
    assert_eq!(first, StatusCode::OK);
    // A double-clicked confirm must not fire the apply twice.
    let (second, body) = apply(&app, &token, id, preview_token).await;
    assert_eq!(second, StatusCode::CONFLICT, "{body:?}");

    // An invented token is likewise rejected (never a silent no-op 200).
    let (bogus, _) = apply(&app, &token, id, "not-a-real-token").await;
    assert_eq!(bogus, StatusCode::CONFLICT);
}

#[tokio::test]
#[serial_test::serial]
async fn preview_warns_about_fx_transfer_legs() {
    // DEC-028: rules MAY recategorize FX-transfer legs, but the diff has
    // to say so — recategorizing one re-enters it into cash-flow totals.
    let Some((app, pool, _lock)) = skip_if_no_db(setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    let src = seed_tx_provenance(
        &pool,
        user_id,
        account,
        "OXXO WISE OUT",
        "-1000.00",
        None,
        None,
        None,
    )
    .await;
    let dst = seed_tx_provenance(
        &pool,
        user_id,
        account,
        "OXXO WISE IN",
        "1000.00",
        None,
        None,
        None,
    )
    .await;
    sqlx::query(
        "INSERT INTO cash_fx_transfers \
             (user_id, source_tx_id, dest_tx_id, source_amount, source_currency, \
              dest_amount, dest_currency, implied_fx_rate, detection_confidence, user_confirmed) \
         VALUES ($1, $2, $3, 1000, 'USD', 18000, 'MXN', 18.0, 90, true)",
    )
    .bind(user_id)
    .bind(src)
    .bind(dst)
    .execute(&pool)
    .await
    .expect("seed fx transfer");

    let pv = preview(&app, &token, &oxxo_rule()).await;
    assert_eq!(pv["matched"], 2);
    assert_eq!(pv["fx_transfer_legs"], 2, "both legs are flagged");
}

#[tokio::test]
#[serial_test::serial]
async fn preview_reports_the_derived_merchant_key() {
    let Some((app, pool, _lock)) = skip_if_no_db(setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    seed_tx_provenance(
        &pool,
        user_id,
        account,
        "COMPRA STARBUCKS REFORMA REF 9981",
        "-95.00",
        None,
        None,
        None,
    )
    .await;

    let pv = preview(
        &app,
        &token,
        &json!({
            "match_type": "merchant_key",
            "match_value": "COMPRA STARBUCKS REFORMA REF 9981",
            "set_category": "Coffee",
        }),
    )
    .await;
    assert_eq!(pv["derived_merchant_key"], "STARBUCKS REFORMA");
    assert_eq!(pv["matched"], 1, "the merchant_key matcher found the row");
}

// ---------------------------------------------------------------------------
// Forward path: statement import
// ---------------------------------------------------------------------------

async fn confirm_import(app: &Router, token: &str, account: Uuid, rows: Value) -> StatusCode {
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/imports/confirm",
            Some(&json!({ "account_id": account.to_string(), "transactions": rows })),
            Some(token),
        ))
        .await
        .unwrap();
    res.status()
}

#[tokio::test]
#[serial_test::serial]
async fn import_confirm_applies_rules_over_the_learned_map() {
    let Some((app, pool, _lock)) = skip_if_no_db(setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;

    // A past MANUAL edit teaches the learned map "STARBUCKS REFORMA →
    // Coffee"; an explicit rule says Dining. The rule must win.
    seed_tx_provenance(
        &pool,
        user_id,
        account,
        "STARBUCKS REFORMA 1",
        "-95.00",
        None,
        Some("Coffee"),
        Some("manual"),
    )
    .await;
    create_rule(
        &app,
        &token,
        &json!({
            "match_type": "contains",
            "match_value": "starbucks",
            "set_category": "Dining",
            "set_description": "Starbucks",
        }),
    )
    .await;

    let rows = json!([
        {"date": "2026-02-01", "description": "COMPRA STARBUCKS REFORMA REF 9981",
         "amount": "-95.00", "currency": "USD"},
        {"date": "2026-02-02", "description": "WALMART SUPERCENTER",
         "amount": "-300.00", "currency": "USD"},
    ]);
    assert_eq!(
        confirm_import(&app, &token, account, rows.clone()).await,
        StatusCode::OK
    );

    let row = sqlx::query(
        "SELECT user_category, user_category_source, user_description, user_description_source, \
                user_category_rule_id \
         FROM transactions WHERE description = 'COMPRA STARBUCKS REFORMA REF 9981'",
    )
    .fetch_one(&pool)
    .await
    .expect("imported row");
    assert_eq!(
        row.get::<Option<String>, _>("user_category"),
        Some("Dining".into())
    );
    assert_eq!(
        row.get::<Option<String>, _>("user_category_source"),
        Some("rule".into())
    );
    assert_eq!(
        row.get::<Option<String>, _>("user_description"),
        Some("Starbucks".into())
    );
    assert_eq!(
        row.get::<Option<String>, _>("user_description_source"),
        Some("rule".into())
    );
    assert!(row
        .get::<Option<Uuid>, _>("user_category_rule_id")
        .is_some());

    // The row no rule matched carries no rule provenance at all.
    let walmart = sqlx::query(
        "SELECT user_category, user_category_source FROM transactions WHERE description = 'WALMART SUPERCENTER'",
    )
    .fetch_one(&pool)
    .await
    .expect("walmart row");
    assert_eq!(walmart.get::<Option<String>, _>("user_category"), None);
    assert_eq!(
        walmart.get::<Option<String>, _>("user_category_source"),
        None
    );

    // Re-importing the same batch is idempotent: the ON CONFLICT clause
    // still touches only balance_after, so a value already stored (here,
    // one the user has since corrected by hand) is never clobbered.
    sqlx::query(
        "UPDATE transactions SET user_category = 'Corrected', user_category_source = 'manual' \
         WHERE description = 'COMPRA STARBUCKS REFORMA REF 9981'",
    )
    .execute(&pool)
    .await
    .unwrap();
    assert_eq!(
        confirm_import(&app, &token, account, rows).await,
        StatusCode::OK
    );
    let after = sqlx::query(
        "SELECT COUNT(*) AS n, MAX(user_category) AS cat FROM transactions \
         WHERE description = 'COMPRA STARBUCKS REFORMA REF 9981'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(after.get::<i64, _>("n"), 1, "re-import must not duplicate");
    assert_eq!(
        after.get::<Option<String>, _>("cat"),
        Some("Corrected".into()),
        "re-import must not clobber a manual correction"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn learned_map_ignores_rule_and_learned_rows() {
    // Regression for the feedback loop: without the source filter on the
    // learned-map query, a value a RULE wrote re-enters the map as if it
    // were a human edit — and a deleted rule keeps resurrecting itself.
    let Some((app, pool, _lock)) = skip_if_no_db(setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;

    // No active rules at all — only history, in each provenance state.
    seed_tx_provenance(
        &pool,
        user_id,
        account,
        "STARBUCKS REFORMA 1",
        "-95.00",
        None,
        Some("RuleCoffee"),
        Some("rule"),
    )
    .await;
    seed_tx_provenance(
        &pool,
        user_id,
        account,
        "SEVEN ELEVEN CENTRO",
        "-40.00",
        None,
        Some("LearnedSnacks"),
        Some("learned"),
    )
    .await;
    seed_tx_provenance(
        &pool,
        user_id,
        account,
        "WALMART SUPERCENTER",
        "-300.00",
        None,
        Some("HumanGroceries"),
        Some("manual"),
    )
    .await;

    let rows = json!([
        {"date": "2026-03-01", "description": "COMPRA STARBUCKS REFORMA REF 77", "amount": "-95.00", "currency": "USD"},
        {"date": "2026-03-02", "description": "COMPRA SEVEN ELEVEN CENTRO 4", "amount": "-40.00", "currency": "USD"},
        {"date": "2026-03-03", "description": "COMPRA WALMART SUPERCENTER 8", "amount": "-300.00", "currency": "USD"},
    ]);
    assert_eq!(
        confirm_import(&app, &token, account, rows).await,
        StatusCode::OK
    );

    let learned_for = |desc: &'static str| {
        let pool = pool.clone();
        async move {
            sqlx::query(
                "SELECT user_category, user_category_source FROM transactions WHERE description = $1",
            )
            .bind(desc)
            .fetch_one(&pool)
            .await
            .map(|r| {
                (
                    r.get::<Option<String>, _>("user_category"),
                    r.get::<Option<String>, _>("user_category_source"),
                )
            })
            .expect("imported row")
        }
    };
    assert_eq!(
        learned_for("COMPRA STARBUCKS REFORMA REF 77").await,
        (None, None),
        "a rule-written value must NOT feed the learned map"
    );
    assert_eq!(
        learned_for("COMPRA SEVEN ELEVEN CENTRO 4").await,
        (None, None),
        "a learned value must NOT feed the learned map back into itself"
    );
    assert_eq!(
        learned_for("COMPRA WALMART SUPERCENTER 8").await,
        (Some("HumanGroceries".into()), Some("learned".into())),
        "a genuine human edit still teaches the learned map, stamped 'learned'"
    );
}

// ---------------------------------------------------------------------------
// Forward path: Plaid sync (the gap this feature exists to close)
// ---------------------------------------------------------------------------

#[tokio::test]
#[serial_test::serial]
async fn plaid_sync_applies_rules_on_insert_only() {
    let Some((app, pool, _lock)) = skip_if_no_db(setup().await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst, _account) = seed_account(&pool, user_id).await;
    // Plaid rows land on an account matched by external_id.
    let account: Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, external_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'plaid-acct-1', 'Chase Checking', 'depository', 'USD', 500.00, $2) RETURNING id",
    )
    .bind(inst)
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed plaid account");

    create_rule(
        &app,
        &token,
        &json!({
            "match_type": "contains",
            "match_value": "starbucks",
            "set_category": "Dining",
            "set_description": "Starbucks",
        }),
    )
    .await;
    let rules: Vec<UserRule> = rules::load_rules(&pool, user_id).await.expect("load rules");
    assert_eq!(rules.len(), 1);

    let plaid_tx = |name: &str| {
        json!({
            "account_id": "plaid-acct-1",
            "transaction_id": "plaid-tx-1",
            "date": "2026-04-01",
            "name": name,
            "amount": 5.75,
            "iso_currency_code": "USD",
            "pending": false,
            "personal_finance_category": {"primary": "FOOD_AND_DRINK", "detailed": "FOOD_AND_DRINK_COFFEE"},
        })
    };

    patrimonio::services::sync::upsert_plaid_transaction(
        &pool,
        &plaid_tx("STARBUCKS STORE 1234"),
        user_id,
        &rules,
    )
    .await
    .expect("insert plaid tx");

    let tx_id: Uuid = sqlx::query_scalar(
        "SELECT id FROM transactions WHERE external_id = 'plaid-tx-1' AND account_id = $1",
    )
    .bind(account)
    .fetch_one(&pool)
    .await
    .expect("plaid row exists");
    assert_eq!(
        provenance_of(&pool, tx_id).await,
        (Some("Dining".into()), Some("rule".into())),
        "the Plaid path is the gap this feature closes"
    );
    assert_eq!(
        description_provenance_of(&pool, tx_id).await,
        (Some("Starbucks".into()), Some("rule".into()))
    );

    // The user corrects it by hand, then Plaid re-sends the row
    // (pending → posted / description refresh). The conflict path must
    // NOT touch any user_* column.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/accounts/transactions/{tx_id}"),
            Some(&json!({ "user_category": "Coffee", "user_description": "Morning coffee" })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    patrimonio::services::sync::upsert_plaid_transaction(
        &pool,
        &plaid_tx("STARBUCKS STORE 1234 - POSTED"),
        user_id,
        &rules,
    )
    .await
    .expect("re-sync plaid tx");

    assert_eq!(
        provenance_of(&pool, tx_id).await,
        (Some("Coffee".into()), Some("manual".into())),
        "a re-sync must never clobber a manual edit"
    );
    assert_eq!(
        description_provenance_of(&pool, tx_id).await,
        (Some("Morning coffee".into()), Some("manual".into()))
    );
    let refreshed: String =
        sqlx::query_scalar("SELECT description FROM transactions WHERE id = $1")
            .bind(tx_id)
            .fetch_one(&pool)
            .await
            .unwrap();
    assert_eq!(
        refreshed, "STARBUCKS STORE 1234 - POSTED",
        "the bank-reported description still refreshes on conflict"
    );
}

// ---------------------------------------------------------------------------
// Security
// ---------------------------------------------------------------------------

#[tokio::test]
#[serial_test::serial]
async fn rules_are_scoped_to_their_owner() {
    let Some((app, pool, _lock)) = skip_if_no_db(setup().await) else {
        return;
    };
    let (token_a, user_a) = bootstrap(&app, &pool).await;
    let (user_b, token_b) = seed_owner(&pool, "neighbour").await;
    let (_inst_a, account_a) = seed_account(&pool, user_a).await;
    let (_inst_b, account_b) = seed_account(&pool, user_b).await;

    let a_tx = seed_tx_provenance(
        &pool, user_a, account_a, "OXXO A", "-10.00", None, None, None,
    )
    .await;
    let b_tx = seed_tx_provenance(
        &pool, user_b, account_b, "OXXO B", "-10.00", None, None, None,
    )
    .await;

    // B's preview sees only B's row...
    let pv_b = preview(&app, &token_b, &oxxo_rule()).await;
    assert_eq!(pv_b["matched"], 1, "preview is user-scoped");
    let rule_b = create_rule(&app, &token_b, &oxxo_rule()).await;
    let (status, _) = apply(
        &app,
        &token_b,
        rule_b["id"].as_str().unwrap(),
        pv_b["preview_token"].as_str().unwrap(),
    )
    .await;
    assert_eq!(status, StatusCode::OK);
    assert_eq!(
        provenance_of(&pool, b_tx).await,
        (Some("Groceries".into()), Some("rule".into()))
    );
    assert_eq!(
        provenance_of(&pool, a_tx).await,
        (None, None),
        "B's rule must never reach A's history"
    );

    // ...and A can neither see, edit nor apply B's rule.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/rules", None, Some(&token_a)))
        .await
        .unwrap();
    let list = body_json(res.into_body()).await;
    assert!(
        list.as_array().unwrap().is_empty(),
        "A sees no rules of B's"
    );

    let rule_b_id = rule_b["id"].as_str().unwrap();
    for (method, body) in [
        (Method::PATCH, Some(json!({ "active": false }))),
        (Method::DELETE, None),
    ] {
        let res = app
            .clone()
            .oneshot(req(
                method.clone(),
                &format!("/api/rules/{rule_b_id}"),
                body.as_ref(),
                Some(&token_a),
            ))
            .await
            .unwrap();
        assert_eq!(
            res.status(),
            StatusCode::NOT_FOUND,
            "{method} another user's rule"
        );
    }
    let (status, _) = apply(
        &app,
        &token_a,
        rule_b_id,
        pv_b["preview_token"].as_str().unwrap(),
    )
    .await;
    assert_eq!(status, StatusCode::NOT_FOUND, "A cannot apply B's rule");
}

#[tokio::test]
#[serial_test::serial]
async fn read_only_user_cannot_mutate_rules() {
    let Some((app, pool, _lock)) = skip_if_no_db(setup().await) else {
        return;
    };
    let (owner_token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    seed_tx_provenance(
        &pool,
        user_id,
        account,
        "OXXO SUC 1",
        "-10.00",
        None,
        None,
        None,
    )
    .await;
    let rule = create_rule(&app, &owner_token, &oxxo_rule()).await;
    let rule_id = rule["id"].as_str().unwrap();

    let ro_user_id: Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, email, password_hash, role) \
         VALUES ('viewer', 'viewer@example.com', 'doesnt-matter', 'read_only') RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .expect("seed read-only user");
    let ro_token = patrimonio::services::sessions::create_session(&pool, ro_user_id, None, None)
        .await
        .expect("create read-only session")
        .token;

    // Every mutation — including preview and apply, which are POSTs — is
    // owner-gated.
    for (method, uri, body) in [
        (Method::POST, "/api/rules".to_string(), Some(oxxo_rule())),
        (
            Method::POST,
            "/api/rules/preview".to_string(),
            Some(oxxo_rule()),
        ),
        (
            Method::PATCH,
            format!("/api/rules/{rule_id}"),
            Some(json!({"active": false})),
        ),
        (
            Method::PATCH,
            "/api/rules/reorder".to_string(),
            Some(json!({"ordered_ids": [rule_id]})),
        ),
        (
            Method::POST,
            format!("/api/rules/{rule_id}/apply"),
            Some(json!({"preview_token": "x"})),
        ),
        (Method::DELETE, format!("/api/rules/{rule_id}"), None),
    ] {
        let res = app
            .clone()
            .oneshot(req(method.clone(), &uri, body.as_ref(), Some(&ro_token)))
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::FORBIDDEN, "{method} {uri}");
    }

    // A read-only user CAN list rules (GETs pass require_owner).
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/rules", None, Some(&ro_token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
}
