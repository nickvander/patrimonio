//! HTTP-level integration tests for the `/api/loans/*` surface: CRUD +
//! summary, payments (cash + tx-linked, partial top-up, overpay spill),
//! schedules, reminders, write-off, interest income/accrual, CSV exports,
//! and the agreement view.
//!
//! Split out of the former all-in-one `dashboard_endpoints.rs`. Shared
//! harness + fixtures: `tests/common/fixtures.rs`.

mod common;
use common::fixtures::*;

// =====================================================================
// /api/loans — personal lending MVP
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn loan_create_list_summary_roundtrip() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose Ramirez",
            "principal": 5000.0,
            "currency": "USD",
            "origination_date": "2026-01-15"
        }),
    )
    .await;

    // List shows it with outstanding = principal (no repayments yet).
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans", None, Some(&token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let arr = body_json(res.into_body()).await;
    let loans = arr.as_array().unwrap();
    assert_eq!(loans.len(), 1);
    assert_eq!(loans[0]["borrower_name"], "Jose Ramirez");
    assert!((loans[0]["outstanding"].as_f64().unwrap() - 5000.0).abs() < 0.01);

    // A person row was auto-created.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans/people", None, Some(&token)))
        .await
        .unwrap();
    let people = body_json(res.into_body()).await;
    assert_eq!(people.as_array().unwrap().len(), 1);
    assert_eq!(people[0]["name"], "Jose Ramirez");

    // Summary math.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans/summary", None, Some(&token)))
        .await
        .unwrap();
    let s = body_json(res.into_body()).await;
    assert_eq!(s["loan_count"].as_i64().unwrap(), 1);
    assert!((s["total_lent"].as_f64().unwrap() - 5000.0).abs() < 0.01);
    assert!((s["total_outstanding"].as_f64().unwrap() - 5000.0).abs() < 0.01);

    let _ = loan_id;
}

#[tokio::test]
#[serial_test::serial]
async fn loan_record_payment_reduces_outstanding_and_is_idempotent() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose Ramirez",
            "principal": 1000.0,
            "currency": "USD",
            "origination_date": "2026-01-15"
        }),
    )
    .await;

    // An incoming repayment of 400.
    let repay_tx = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "400.00",
        "2026-02-15",
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay_tx.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Outstanding is now 600.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(
        (l["outstanding"].as_f64().unwrap() - 600.0).abs() < 0.01,
        "expected 600 outstanding, got {}",
        l["outstanding"]
    );
    assert!((l["total_repaid"].as_f64().unwrap() - 400.0).abs() < 0.01);

    // Linking the SAME transaction again is rejected (409) — a
    // repayment can only apply to one installment.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay_tx.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CONFLICT, "double-link must 409");
}

#[tokio::test]
#[serial_test::serial]
async fn loan_cash_payment_without_transaction() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Cash Friend",
            "principal": 1000.0,
            "currency": "USD",
            "origination_date": "2026-01-15"
        }),
    )
    .await;

    // Record a cash repayment of 250 with NO transaction_id.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"amount": 250.0, "paid_date": "2026-02-01"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::CREATED,
        "cash payment must succeed"
    );

    // Outstanding drops to 750.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(
        (l["outstanding"].as_f64().unwrap() - 750.0).abs() < 0.01,
        "expected 750 outstanding after cash payment, got {}",
        l["outstanding"]
    );
    assert!((l["total_repaid"].as_f64().unwrap() - 250.0).abs() < 0.01);

    // A cash payment with no amount is rejected (400).
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::BAD_REQUEST,
        "a cash payment with no amount must 400"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn loan_disbursement_and_repayment_excluded_from_cash_flow() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // The disbursement outflow + a normal expense in the same month.
    let disb_tx = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Wire to Jose",
        "-1000.00",
        "2026-03-10",
    )
    .await;
    let _grocery =
        seed_tx_dated(&pool, user_id, acct, "Supermarket", "-200.00", "2026-03-11").await;
    // A repayment inflow + a normal paycheck inflow in another month.
    let repay_tx = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "500.00",
        "2026-04-10",
    )
    .await;
    let _paycheck = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "ACME Payroll",
        "3000.00",
        "2026-04-15",
    )
    .await;

    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose",
            "principal": 1000.0,
            "currency": "USD",
            "origination_date": "2026-03-10"
        }),
    )
    .await;

    // Baseline cash flow BEFORE linking: March spending includes the
    // 1000 disbursement + 200 grocery = 1200; April income includes
    // 500 + 3000 = 3500.
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
        (march["spending"].as_f64().unwrap() - 1200.0).abs() < 0.01,
        "pre-link March spending should be 1200, got {}",
        march["spending"]
    );

    // Link disbursement + record repayment.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/disbursement"),
            Some(&serde_json::json!({"transaction_id": disb_tx.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay_tx.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // AFTER linking: the disbursement drops out of March spending
    // (1200 → 200) and the repayment drops out of April income
    // (3500 → 3000).
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
    let arr = trends.as_array().unwrap();
    let march = arr
        .iter()
        .find(|p| p["month"] == "2026-03")
        .cloned()
        .unwrap();
    let april = arr
        .iter()
        .find(|p| p["month"] == "2026-04")
        .cloned()
        .unwrap();
    assert!(
        (march["spending"].as_f64().unwrap() - 200.0).abs() < 0.01,
        "post-link March spending should exclude the disbursement (200), got {}",
        march["spending"]
    );
    assert!(
        (april["income"].as_f64().unwrap() - 3000.0).abs() < 0.01,
        "post-link April income should exclude the repayment (3000), got {}",
        april["income"]
    );
}

#[tokio::test]
#[serial_test::serial]
async fn loan_suggest_disbursement_matches_and_rejects() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // Case 1 (TP): exact -5000 on origination date, name in description.
    let good = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "ZELLE TO JOSE RAMIREZ",
        "-5000.00",
        "2026-01-15",
    )
    .await;
    // Case 4 (TN): wrong amount, same day.
    let _wrong_amount =
        seed_tx_dated(&pool, user_id, acct, "Coffee", "-250.00", "2026-01-15").await;
    // Case 8 (TN): right amount, far date (59 days out → outside ±7).
    let _far = seed_tx_dated(&pool, user_id, acct, "Other", "-5000.00", "2026-03-15").await;
    // Case 9 (TN): an INFLOW of the right magnitude can't be a disbursement.
    let _inflow = seed_tx_dated(&pool, user_id, acct, "Deposit", "5000.00", "2026-01-15").await;

    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose Ramirez",
            "principal": 5000.0,
            "currency": "USD",
            "origination_date": "2026-01-15"
        }),
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}/suggestions/disbursement"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let suggestions = body_json(res.into_body()).await;
    let arr = suggestions.as_array().unwrap();
    // Only the exact-amount same-day outflow should be suggested.
    assert_eq!(
        arr.len(),
        1,
        "exactly one disbursement suggestion expected, got {arr:?}"
    );
    assert_eq!(arr[0]["transaction_id"].as_str().unwrap(), good.to_string());
    assert!(
        arr[0]["confidence"].as_i64().unwrap() >= 80,
        "exact+name should be high confidence"
    );
    assert_eq!(arr[0]["name_matched"], true);
}

#[tokio::test]
#[serial_test::serial]
async fn loan_suggest_excludes_already_linked_disbursement() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;
    let tx = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Wire to Jose",
        "-5000.00",
        "2026-01-15",
    )
    .await;

    // Loan A links the tx as its disbursement.
    let loan_a = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose", "principal": 5000.0, "currency": "USD", "origination_date": "2026-01-15"
    })).await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_a}/disbursement"),
            Some(&serde_json::json!({"transaction_id": tx.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    // Loan B (same borrower/amount) must NOT see that tx suggested —
    // it's already linked (Case 7 / Case 19 disambiguation).
    let loan_b = create_loan(&app, &token, &serde_json::json!({
        "borrower_name": "Jose", "principal": 5000.0, "currency": "USD", "origination_date": "2026-01-15"
    })).await;
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_b}/suggestions/disbursement"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let suggestions = body_json(res.into_body()).await;
    assert_eq!(
        suggestions.as_array().unwrap().len(),
        0,
        "an already-linked disbursement must not be suggested for another loan"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn loan_cross_tenant_isolation() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (alice_token, _alice) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(&app, &alice_token, &serde_json::json!({
        "borrower_name": "Alice Friend", "principal": 2000.0, "currency": "USD", "origination_date": "2026-01-01"
    })).await;

    // Bob, a second hand-rolled owner.
    let (_bob_id, bob_token) = seed_owner(&pool, "bob").await;

    // Bob cannot GET Alice's loan.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&bob_token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_FOUND,
        "Bob must not read Alice's loan"
    );

    // Bob cannot DELETE Alice's loan.
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&bob_token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_FOUND,
        "Bob must not delete Alice's loan"
    );

    // Bob's own loan list is empty.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans", None, Some(&bob_token)))
        .await
        .unwrap();
    let arr = body_json(res.into_body()).await;
    assert_eq!(
        arr.as_array().unwrap().len(),
        0,
        "Bob sees none of Alice's loans"
    );
}

// =====================================================================
// /api/loans Phase 2 — schedules, status, reminders
// =====================================================================

/// An installment paid EXACTLY must land as 'paid'.
///
/// `Decimal::from_f64_retain(1033.33)` keeps the full binary expansion
/// (`1033.3299999999999272…`), and the allocation loop compares that
/// unrounded value against the stored `scheduled_amount` (`1033.330000`) in
/// SQL — so an exact payoff evaluated `>=` as FALSE and the row stayed
/// 'partial' while `paid_amount` was written as exactly `scheduled_amount`.
/// A self-contradicting row, and `list_reminders` filters on
/// `status NOT IN ('paid','skipped')`, so the installment reminded forever
/// and `services::notifications` kept minting rows for it.
#[tokio::test]
#[serial_test::serial]
async fn loan_exact_installment_payment_is_marked_paid() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    // 12,400 / 12 = 1033.333… → installments of 1033.33 with the tail row
    // absorbing the residual. The repeating cent is the whole point.
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 12400.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let rows = loan_payment_rows(&app, &token, loan_id).await;
    let first_due = rows[0]["scheduled_amount"].as_f64().unwrap();
    assert!((first_due - 1033.33).abs() < 0.001, "got {first_due}");

    // Pay it to the cent.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"amount": first_due, "paid_date": "2026-02-15"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let rows = loan_payment_rows(&app, &token, loan_id).await;
    assert_eq!(
        rows[0]["status"].as_str(),
        Some("paid"),
        "an exactly-paid installment must not read as partial"
    );
    assert_eq!(rows.len(), 12, "no phantom installment appended");
}

/// Topping a partial payment up to the exact scheduled amount must close the
/// installment and NOT append a residual row: `533.33 - 533.32999999999992724`
/// leaves 1.1e-13 of f64 dust, and `if remaining > 0.0` treated that as real
/// money, inserting a 0.00 installment that then showed up in the plan table
/// and both exports.
#[tokio::test]
#[serial_test::serial]
async fn loan_partial_then_exact_topup_leaves_no_phantom_installment() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 12400.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    app.clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();

    for amount in [500.0, 533.33] {
        let res = app
            .clone()
            .oneshot(req(
                Method::POST,
                &format!("/api/loans/{loan_id}/payments"),
                Some(&serde_json::json!({"amount": amount, "paid_date": "2026-02-15"})),
                Some(&token),
            ))
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::CREATED, "payment of {amount}");
    }

    let rows = loan_payment_rows(&app, &token, loan_id).await;
    assert_eq!(
        rows.len(),
        12,
        "phantom 0.00 installment appended: {rows:#?}"
    );
    assert_eq!(rows[0]["status"].as_str(), Some("paid"));
    let paid = rows[0]["paid_amount"].as_f64().unwrap();
    assert!((paid - 1033.33).abs() < 0.001, "got {paid}");
}

#[tokio::test]
#[serial_test::serial]
async fn loan_schedule_generates_and_sums_to_principal() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "simple",
            "interest_rate": 0.06, "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;

    // Generate the schedule.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["installments"].as_i64().unwrap(), 12);

    // Payments list shows 12 rows; scheduled_principal sums to 1200.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}/payments"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let payments = body_json(res.into_body()).await;
    let rows = payments.as_array().unwrap();
    assert_eq!(rows.len(), 12);
    let sum_principal: f64 = rows
        .iter()
        .map(|r| r["scheduled_principal"].as_f64().unwrap())
        .sum();
    assert!(
        (sum_principal - 1200.0).abs() < 0.001,
        "scheduled principal must sum to 1200, got {sum_principal}"
    );
    // Simple 6% → total interest 72.
    let sum_interest: f64 = rows
        .iter()
        .map(|r| r["scheduled_interest"].as_f64().unwrap())
        .sum();
    assert!(
        (sum_interest - 72.0).abs() < 0.01,
        "interest should be 72, got {sum_interest}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn loan_schedule_regen_refused_when_payment_reconciled() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    // Generate, then reconcile a repayment.
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    let repay = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "100.00",
        "2026-02-15",
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Regen must now be refused with 409.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::CONFLICT,
        "regen with a reconciled payment must 409"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn loan_schedule_open_ended_rejected() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    // No term_months / payment_frequency → open-ended.
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 500.0, "currency": "USD",
            "origination_date": "2026-01-15"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNPROCESSABLE_ENTITY);
}

#[tokio::test]
#[serial_test::serial]
async fn loan_write_off_zeroes_outstanding_default_keeps_it() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1000.0, "currency": "USD",
            "origination_date": "2026-01-15"
        }),
    )
    .await;

    // Default keeps outstanding.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/loans/{loan_id}"),
            Some(&serde_json::json!({"status": "defaulted"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(
        (l["outstanding"].as_f64().unwrap() - 1000.0).abs() < 0.01,
        "defaulted keeps outstanding, got {}",
        l["outstanding"]
    );

    // Write-off zeroes it.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/loans/{loan_id}"),
            Some(&serde_json::json!({"status": "written_off"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(
        l["outstanding"].as_f64().unwrap().abs() < 0.01,
        "written_off zeroes outstanding, got {}",
        l["outstanding"]
    );
}

#[tokio::test]
#[serial_test::serial]
async fn loan_reminders_upcoming_overdue_and_exclusions() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 300.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 3, "payment_frequency": "monthly"
        }),
    )
    .await;

    // Hand-place three installments with controlled due dates relative
    // to CURRENT_DATE: one in 3 days (upcoming), one in 40 days (outside
    // default lead 7 → excluded), one 2 days ago (overdue).
    sqlx::query("DELETE FROM loan_payments WHERE loan_id = $1")
        .bind(loan_id)
        .execute(&pool)
        .await
        .unwrap();
    for (n, offset) in [(1i32, 3i64), (2, 40), (3, -2)] {
        sqlx::query(
            "INSERT INTO loan_payments (user_id, loan_id, installment_number, due_date, \
             scheduled_amount, scheduled_principal, status) \
             VALUES ($1, $2, $3, CURRENT_DATE + ($4)::int, 100.00, 100.00, 'scheduled')",
        )
        .bind(user_id)
        .bind(loan_id)
        .bind(n)
        .bind(offset as i32)
        .execute(&pool)
        .await
        .unwrap();
    }

    // Default lead 7: expect installment 1 (upcoming) + installment 3
    // (overdue); installment 2 (40d out) excluded.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans/reminders", None, Some(&token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let reminders = body_json(res.into_body()).await;
    let arr = reminders.as_array().unwrap();
    assert_eq!(arr.len(), 2, "expected upcoming + overdue, got {arr:?}");
    let has_upcoming = arr.iter().any(|r| r["days_until"].as_i64().unwrap() > 0);
    let has_overdue = arr.iter().any(|r| r["days_overdue"].as_i64().unwrap() > 0);
    assert!(
        has_upcoming && has_overdue,
        "both an upcoming and an overdue reminder"
    );

    // Widen lead to 60 → installment 2 now appears too (3 total).
    set_setting(
        &pool,
        user_id,
        "lending_reminder_lead_days",
        serde_json::json!(60),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans/reminders", None, Some(&token)))
        .await
        .unwrap();
    let reminders = body_json(res.into_body()).await;
    assert_eq!(
        reminders.as_array().unwrap().len(),
        3,
        "lead 60 surfaces the 40-day-out installment"
    );

    // Write off the loan → no reminders (loan not active).
    let _ = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/loans/{loan_id}"),
            Some(&serde_json::json!({"status": "written_off"})),
            Some(&token),
        ))
        .await
        .unwrap();
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans/reminders", None, Some(&token)))
        .await
        .unwrap();
    let reminders = body_json(res.into_body()).await;
    assert_eq!(
        reminders.as_array().unwrap().len(),
        0,
        "written-off loan yields no reminders"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn loan_reminders_cross_tenant_isolated() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let _ = bootstrap(&app, &pool).await;
    let (alice_id, alice_token) = seed_owner(&pool, "alice").await;
    let (_bob_id, bob_token) = seed_owner(&pool, "bob").await;

    // Alice has a loan + an overdue installment.
    let loan_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO loans (user_id, borrower_name, principal, currency, origination_date, status) \
         VALUES ($1, 'Friend', 500.00, 'USD', CURRENT_DATE - 60, 'active') RETURNING id",
    ).bind(alice_id).fetch_one(&pool).await.unwrap();
    sqlx::query(
        "INSERT INTO loan_payments (user_id, loan_id, installment_number, due_date, \
         scheduled_amount, scheduled_principal, status) \
         VALUES ($1, $2, 1, CURRENT_DATE - 2, 100.00, 100.00, 'scheduled')",
    )
    .bind(alice_id)
    .bind(loan_id)
    .execute(&pool)
    .await
    .unwrap();

    // Alice sees 1 reminder; Bob sees none.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/loans/reminders",
            None,
            Some(&alice_token),
        ))
        .await
        .unwrap();
    assert_eq!(
        body_json(res.into_body()).await.as_array().unwrap().len(),
        1
    );
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/loans/reminders",
            None,
            Some(&bob_token),
        ))
        .await
        .unwrap();
    assert_eq!(
        body_json(res.into_body()).await.as_array().unwrap().len(),
        0,
        "Bob must not see Alice's reminders"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn loan_list_collection_path_contract() {
    // Regression guard for the "couldn't load loans" bug: axum 0.8's
    // nest("/api/loans") + inner "/" route matches /api/loans but
    // 404s /api/loans/ (trailing slash). The frontend MUST call the
    // no-slash form — this pins that contract so a future client
    // change back to the slash form is caught here.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    // The path the frontend uses → must be 200.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans", None, Some(&token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "GET /api/loans must be 200");
    // POST collection (createLoan) → must be 201.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/loans",
            Some(&serde_json::json!({
                "borrower_name": "Slash Test", "principal": 100.0,
                "currency": "USD", "origination_date": "2026-01-01"
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::CREATED,
        "POST /api/loans must 201"
    );
    // Documented axum behavior: the trailing-slash form does NOT match.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/loans/", None, Some(&token)))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_FOUND,
        "trailing-slash /api/loans/ 404s under axum nest — clients use the no-slash form"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn loan_interest_only_and_monthly_rate_schedule() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    // 1% per MONTH, interest-only, 6 months on $10,000.
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 10000.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "interest_only",
            "interest_rate": 0.01, "rate_period": "monthly",
            "term_months": 6, "payment_frequency": "monthly"
        }),
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}/payments"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let rows = body_json(res.into_body()).await;
    let arr = rows.as_array().unwrap();
    assert_eq!(arr.len(), 6);
    // First five rows: interest only, $100 each (1% of 10k), no principal.
    for r in &arr[..5] {
        assert!((r["scheduled_interest"].as_f64().unwrap() - 100.0).abs() < 0.01);
        assert!(r["scheduled_principal"].as_f64().unwrap().abs() < 0.01);
    }
    // Final row: full principal balloon.
    assert!(
        (arr[5]["scheduled_principal"].as_f64().unwrap() - 10000.0).abs() < 0.01,
        "interest-only balloon should return full principal, got {}",
        arr[5]["scheduled_principal"]
    );

    // The loan echoes back rate_period for the UI.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert_eq!(l["rate_period"], "monthly");
    assert_eq!(l["interest_type"], "interest_only");
}

// =====================================================================
// B1 — partial payment top-up stays on the same installment
// =====================================================================

/// A PARTIAL payment to installment 1, then the remainder, must fully
/// pay installment 1 (status='paid', paid_amount == scheduled total)
/// WITHOUT spilling into installment 2. Regression for the bug where the
/// next-installment selector keyed off `actual_tx_id IS NULL`, so the
/// remainder skipped the partial row and filled installment 2 instead.
#[tokio::test]
#[serial_test::serial]
async fn loan_partial_payment_tops_up_same_installment() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, _acct) = seed_account(&pool, user_id).await;

    // Interest-free loan: $1,200 over 12 months → $100 principal/month,
    // each installment's scheduled_amount is exactly 100.
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Partial: $40 against installment 1 (cash, no tx).
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"amount": 40.0, "paid_date": "2026-02-15"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // After the partial: installment 1 is 'partial' with paid_amount 40;
    // installment 2 untouched.
    let rows = loan_payments(&app, &token, loan_id).await;
    let i1 = &rows[0];
    let i2 = &rows[1];
    assert_eq!(i1["installment_number"].as_i64().unwrap(), 1);
    assert_eq!(
        i1["status"], "partial",
        "installment 1 should be partial after $40"
    );
    assert!((i1["paid_amount"].as_f64().unwrap() - 40.0).abs() < 0.01);
    assert!(
        i2["paid_amount"].is_null(),
        "installment 2 must be untouched by the partial"
    );

    // Remainder: $60 → fully covers installment 1's $100 schedule.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"amount": 60.0, "paid_date": "2026-02-20"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let rows = loan_payments(&app, &token, loan_id).await;
    let i1 = &rows[0];
    let i2 = &rows[1];
    // Installment 1 is now fully paid: status='paid', paid_amount == 100.
    assert_eq!(
        i1["status"], "paid",
        "installment 1 must be paid after the remainder"
    );
    assert!(
        (i1["paid_amount"].as_f64().unwrap() - 100.0).abs() < 0.01,
        "installment 1 paid_amount should equal the $100 schedule, got {}",
        i1["paid_amount"]
    );
    // CRITICAL: the remainder did NOT spill into installment 2.
    assert_eq!(i2["installment_number"].as_i64().unwrap(), 2);
    assert!(
        i2["paid_amount"].is_null(),
        "remainder must NOT spill into installment 2 — got paid_amount {}",
        i2["paid_amount"]
    );
    assert_eq!(
        i2["status"], "scheduled",
        "installment 2 must still be scheduled"
    );

    // Outstanding dropped by exactly $100 (1200 - 100).
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(
        (l["outstanding"].as_f64().unwrap() - 1100.0).abs() < 0.01,
        "outstanding should be 1100 after one full installment, got {}",
        l["outstanding"]
    );
    assert!((l["total_repaid"].as_f64().unwrap() - 100.0).abs() < 0.01);
}

// =====================================================================
// B2 — update_loan regenerates the schedule + validates principal
// =====================================================================

/// Changing the principal of a scheduled loan (no reconciled payments)
/// must regenerate the schedule rows to the new principal — Σ
/// scheduled_principal == new principal — instead of leaving a stale
/// schedule.
#[tokio::test]
#[serial_test::serial]
async fn loan_update_principal_regenerates_schedule() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();

    // Bump the principal to $2,400.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/loans/{loan_id}"),
            Some(&serde_json::json!({"principal": 2400.0})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::OK,
        "update with valid principal must 200"
    );

    // Schedule regenerated: still 12 rows, Σ scheduled_principal == 2400.
    let rows = loan_payments(&app, &token, loan_id).await;
    let arr = rows.as_array().unwrap();
    assert_eq!(arr.len(), 12, "schedule still has 12 installments");
    let sum_principal: f64 = arr
        .iter()
        .map(|r| r["scheduled_principal"].as_f64().unwrap())
        .sum();
    assert!(
        (sum_principal - 2400.0).abs() < 0.01,
        "scheduled principal must sum to the new 2400, got {sum_principal}"
    );

    // The loan view's total_scheduled tracks the new principal too.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(
        (l["total_scheduled"].as_f64().unwrap() - 2400.0).abs() < 0.01,
        "total_scheduled should follow the regenerated schedule, got {}",
        l["total_scheduled"]
    );
}

/// update_loan with principal <= 0 returns 400 (not a 500 surfacing the
/// DB CHECK).
#[tokio::test]
#[serial_test::serial]
async fn loan_update_nonpositive_principal_is_400() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1000.0, "currency": "USD",
            "origination_date": "2026-01-15"
        }),
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/loans/{loan_id}"),
            Some(&serde_json::json!({"principal": 0.0})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::BAD_REQUEST,
        "principal 0 must 400, not 500"
    );

    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/loans/{loan_id}"),
            Some(&serde_json::json!({"principal": -50.0})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::BAD_REQUEST,
        "negative principal must 400"
    );
}

/// A schedule-affecting edit (principal) on a loan WITH a reconciled
/// payment is rejected with 409 — terms can't change after money has
/// been reconciled (chosen policy; unreconcile first).
#[tokio::test]
#[serial_test::serial]
async fn loan_update_terms_rejected_after_reconcile() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    // Reconcile a real repayment.
    let repay = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "100.00",
        "2026-02-15",
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Changing principal now must 409.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/loans/{loan_id}"),
            Some(&serde_json::json!({"principal": 5000.0})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::CONFLICT,
        "schedule-affecting edit after reconcile must 409"
    );

    // A non-schedule field (notes) is still editable on the same loan.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/loans/{loan_id}"),
            Some(&serde_json::json!({"notes": "called borrower"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::OK,
        "non-schedule edit stays allowed after reconcile"
    );
}

/// Regression for the spurious-409 bug: the edit dialog re-sends
/// principal/interest_rate/interest_type on EVERY save (pre-filled,
/// unchanged). Editing only the borrower name on a reconciled loan —
/// while the payload still carries the unchanged principal — must NOT be
/// treated as a term change, so it must 200, not 409. (Presence-based
/// detection would wrongly reject this and drop the legitimate edit.)
#[tokio::test]
#[serial_test::serial]
async fn loan_update_unchanged_principal_after_reconcile_ok() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    let repay = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "100.00",
        "2026-02-15",
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // Edit ONLY the borrower name, but resend the unchanged principal /
    // interest_type exactly as the dialog does. Must succeed.
    let res = app
        .clone()
        .oneshot(req(
            Method::PATCH,
            &format!("/api/loans/{loan_id}"),
            Some(&serde_json::json!({
                "borrower_name": "Jose Ramirez",
                "principal": 1200.0,
                "interest_type": "none"
            })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::OK,
        "resending an UNCHANGED principal must not 409 a reconciled loan"
    );

    // The name change actually persisted.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert_eq!(
        l["borrower_name"], "Jose Ramirez",
        "borrower rename must persist"
    );
}

/// B1, the real (tx-linked) bug path: a PARTIAL payment that is
/// reconciled against a bank transaction sets actual_tx_id on the row.
/// The old `actual_tx_id IS NULL` selector skipped such a row, so the
/// next payment stranded the remainder on installment 2. The remainder
/// must top up the SAME installment instead.
#[tokio::test]
#[serial_test::serial]
async fn loan_tx_linked_partial_tops_up_same_installment() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();

    // Partial of $40 reconciled against a real $40 transaction → the row
    // now carries a non-NULL actual_tx_id (the case the old selector
    // skipped).
    let tx40 = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "40.00",
        "2026-02-15",
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": tx40.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let rows = loan_payments(&app, &token, loan_id).await;
    assert_eq!(
        rows[0]["status"], "partial",
        "installment 1 should be partial after the $40 tx"
    );

    // Remainder $60 (cash). Must top up installment 1, not spill to 2.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"amount": 60.0, "paid_date": "2026-02-20"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let rows = loan_payments(&app, &token, loan_id).await;
    assert_eq!(
        rows[0]["status"], "paid",
        "installment 1 must be paid after the remainder"
    );
    assert!(
        (rows[0]["paid_amount"].as_f64().unwrap() - 100.0).abs() < 0.01,
        "installment 1 should total $100, got {}",
        rows[0]["paid_amount"]
    );
    assert!(
        rows[1]["paid_amount"].is_null(),
        "remainder must NOT spill into installment 2 — got {}",
        rows[1]["paid_amount"]
    );
}

/// POST /schedule on a loan id that doesn't exist (or isn't ours) must
/// 404, not 500 (the shared regenerate_schedule helper must distinguish
/// not-found from a real DB error).
#[tokio::test]
#[serial_test::serial]
async fn loan_generate_schedule_unknown_id_is_404() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let bogus = uuid::Uuid::new_v4();
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{bogus}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_FOUND,
        "schedule on an unknown loan must 404, not 500"
    );
}

// =====================================================================
// Interest income (cash basis) — principal/interest split + report
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn loan_scheduled_repayment_records_interest_split() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // Interest-only loan: $10,000 @ 1%/month, 6 months. Each scheduled
    // installment's interest is $100; principal balloons at the end.
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 10000.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "interest_only",
            "interest_rate": 0.01, "rate_period": "monthly",
            "term_months": 6, "payment_frequency": "monthly"
        }),
    )
    .await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();

    // Reconcile a $100 inflow against the first installment → it's all
    // interest (interest-only), no principal.
    let repay = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "100.00",
        "2026-02-15",
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // The loan's interest_earned reflects the $100.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(
        (l["interest_earned"].as_f64().unwrap() - 100.0).abs() < 0.01,
        "interest-only first payment is all interest, got {}",
        l["interest_earned"]
    );

    // Interest-income report: $100 interest, $0 principal this year.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/loans/interest-income?year=2026",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let report = body_json(res.into_body()).await;
    assert!((report["total_interest"].as_f64().unwrap() - 100.0).abs() < 0.01);
    assert!(report["total_principal"].as_f64().unwrap().abs() < 0.01);
    assert_eq!(report["by_loan"].as_array().unwrap().len(), 1);
    // Per-month series has the Feb bucket.
    let months = report["by_month"].as_array().unwrap();
    assert!(months.iter().any(|m| m["month"] == "2026-02"));
}

#[tokio::test]
#[serial_test::serial]
async fn loan_open_ended_us_rule_interest_first() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // Open-ended (no schedule) loan: $1,000 @ 12%/year simple. A
    // repayment one year later accrues ~$120 interest; US Rule applies
    // it interest-first.
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1000.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "simple",
            "interest_rate": 0.12, "rate_period": "annual"
        }),
    )
    .await;

    // A $300 inflow ~365 days after origination.
    let repay = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "300.00",
        "2027-01-15",
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // ~$120 interest accrued (1000 * 0.12 * 1yr), allocated first; the
    // rest (~$180) is principal.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    let earned = l["interest_earned"].as_f64().unwrap();
    assert!(
        (earned - 120.0).abs() < 1.0,
        "US-rule interest-first ~120, got {earned}"
    );
    // Outstanding dropped by the principal portion (~180), not the full 300.
    let outstanding = l["outstanding"].as_f64().unwrap();
    assert!(
        (outstanding - 820.0).abs() < 1.5,
        "outstanding should drop by principal portion only (~820), got {outstanding}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn loan_zero_interest_repayment_is_all_principal() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 500.0, "currency": "USD",
            "origination_date": "2026-01-15"
        }),
    )
    .await; // interest_type defaults to none
    let repay = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "200.00",
        "2026-03-15",
    )
    .await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/loans/interest-income",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let report = body_json(res.into_body()).await;
    assert!(
        report["total_interest"].as_f64().unwrap().abs() < 0.01,
        "0% loan generates no interest income"
    );
    assert!((report["total_principal"].as_f64().unwrap() - 200.0).abs() < 0.01);
}

#[tokio::test]
#[serial_test::serial]
async fn loan_interest_income_csv_export() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose Ramirez", "principal": 1000.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "simple",
            "interest_rate": 0.12, "rate_period": "annual"
        }),
    )
    .await;
    let repay = seed_tx_dated(&pool, user_id, acct, "Zelle", "300.00", "2026-07-15").await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": repay.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/loans/interest-income/export?year=2026",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let ct = res
        .headers()
        .get("content-type")
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert!(
        ct.contains("text/csv"),
        "expected CSV content-type, got {ct}"
    );
    let bytes = axum::body::to_bytes(res.into_body(), 1024 * 64)
        .await
        .unwrap();
    let csv = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(
        csv.starts_with("borrower,currency,date,amount_paid,principal,interest,running_balance")
    );
    assert!(csv.contains("Jose Ramirez"), "borrower row present");
    assert!(csv.contains("300.00"), "payment amount present");
}

#[tokio::test]
#[serial_test::serial]
async fn loan_interest_income_cross_tenant_isolated() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let _ = bootstrap(&app, &pool).await;
    let (alice_id, alice_token) = seed_owner(&pool, "alice").await;
    let (_bob_id, bob_token) = seed_owner(&pool, "bob").await;
    // Alice: a loan + a reconciled interest-bearing payment row.
    let loan_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO loans (user_id, borrower_name, principal, currency, origination_date, status, interest_type, interest_rate) \
         VALUES ($1, 'Friend', 1000.00, 'USD', '2026-01-01', 'active', 'simple', 0.10) RETURNING id",
    ).bind(alice_id).fetch_one(&pool).await.unwrap();
    sqlx::query(
        "INSERT INTO loan_payments (user_id, loan_id, installment_number, paid_amount, paid_date, \
         principal_portion, interest_portion, balance_after, status) \
         VALUES ($1, $2, 1, 200.00, '2026-06-01', 150.00, 50.00, 850.00, 'paid')",
    )
    .bind(alice_id)
    .bind(loan_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/loans/interest-income",
            None,
            Some(&alice_token),
        ))
        .await
        .unwrap();
    let r = body_json(res.into_body()).await;
    assert!((r["total_interest"].as_f64().unwrap() - 50.0).abs() < 0.01);
    // Bob sees nothing.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/loans/interest-income",
            None,
            Some(&bob_token),
        ))
        .await
        .unwrap();
    let r = body_json(res.into_body()).await;
    assert!(
        r["total_interest"].as_f64().unwrap().abs() < 0.01,
        "Bob must not see Alice's interest income"
    );
}

// =====================================================================
// Phase 3 completion — compound, accrued, summary CSV, agreement, flag
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn loan_compound_single_balloon_schedule() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1000.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "compound",
            "interest_rate": 0.10, "rate_period": "annual",
            "term_months": 24, "payment_frequency": "monthly"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}/payments"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let rows = body_json(res.into_body()).await;
    let arr = rows.as_array().unwrap();
    assert_eq!(arr.len(), 1, "compound is a single balloon");
    // ~$220 compound interest over 2y monthly-compounded at 10%.
    assert!((arr[0]["scheduled_interest"].as_f64().unwrap() - 220.0).abs() < 2.0);
    assert!((arr[0]["scheduled_principal"].as_f64().unwrap() - 1000.0).abs() < 0.01);
}

#[tokio::test]
#[serial_test::serial]
async fn loan_interest_accrued_is_informational() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    // 12% annual simple, open-ended, originated ~today minus enough to
    // accrue. Use a clearly-past origination so accrual is non-trivial.
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1000.0, "currency": "USD",
            "origination_date": "2026-01-01", "interest_type": "simple",
            "interest_rate": 0.12, "rate_period": "annual"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    // interest_accrued is present and >= 0 (exact value depends on
    // today's date relative to origination).
    assert!(l["interest_accrued"].as_f64().unwrap() >= 0.0);
    // A 0% loan accrues nothing.
    let zero = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Ana", "principal": 500.0, "currency": "USD",
            "origination_date": "2026-01-01"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{zero}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(l["interest_accrued"].as_f64().unwrap().abs() < 0.01);
}

#[tokio::test]
#[serial_test::serial]
async fn loan_below_market_flag_over_threshold() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    // 0% loan over the $10k de-minimis → flagged.
    let _big = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "BigFriend", "principal": 25000.0, "currency": "USD",
            "origination_date": "2026-01-01"
        }),
    )
    .await;
    // 0% loan under the threshold → not flagged.
    let _small = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "SmallFriend", "principal": 500.0, "currency": "USD",
            "origination_date": "2026-01-01"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/loans/interest-income",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let report = body_json(res.into_body()).await;
    let flagged = report["below_market_loans"].as_array().unwrap();
    assert_eq!(flagged.len(), 1, "only the >$10k 0% loan is flagged");
    assert_eq!(flagged[0]["borrower_name"], "BigFriend");
}

#[tokio::test]
#[serial_test::serial]
async fn loan_interest_summary_csv_by_borrower_year() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    // Seed a loan + a reconciled interest-bearing payment directly.
    let loan_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO loans (user_id, borrower_name, principal, currency, origination_date, status, interest_type, interest_rate) \
         VALUES ($1, 'Jose Ramirez', 1000.00, 'USD', '2026-01-01', 'active', 'simple', 0.10) RETURNING id",
    ).bind(user_id).fetch_one(&pool).await.unwrap();
    sqlx::query(
        "INSERT INTO loan_payments (user_id, loan_id, installment_number, paid_amount, paid_date, \
         principal_portion, interest_portion, balance_after, status) \
         VALUES ($1, $2, 1, 200.00, '2026-06-01', 150.00, 50.00, 850.00, 'paid')",
    )
    .bind(user_id)
    .bind(loan_id)
    .execute(&pool)
    .await
    .unwrap();

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/loans/interest-income/summary",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let ct = res
        .headers()
        .get("content-type")
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert!(ct.contains("text/csv"));
    let bytes = axum::body::to_bytes(res.into_body(), 1024 * 64)
        .await
        .unwrap();
    let csv = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(csv.starts_with("borrower,currency,year,interest_received,principal_received"));
    assert!(csv.contains("2026"));
    assert!(csv.contains("Jose Ramirez"));
    assert!(csv.contains("50.00"));
}

#[tokio::test]
#[serial_test::serial]
async fn loan_agreement_html_renders_and_is_scoped() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose Ramirez", "principal": 5000.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "simple",
            "interest_rate": 0.06, "rate_period": "annual",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}/agreement"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let ct = res
        .headers()
        .get("content-type")
        .unwrap()
        .to_str()
        .unwrap()
        .to_string();
    assert!(ct.contains("text/html"), "agreement is HTML, got {ct}");
    let bytes = axum::body::to_bytes(res.into_body(), 1024 * 64)
        .await
        .unwrap();
    let html = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(html.contains("Promissory Note"));
    assert!(html.contains("Jose Ramirez"));
    // Sectioned layout (the output redesign).
    assert!(html.contains("<h2>Parties</h2>"), "Parties section present");
    assert!(
        html.contains("<h2>Loan terms</h2>"),
        "Loan terms section present"
    );
    assert!(html.contains("Status as of"), "Status section present");

    // Cross-tenant: a different owner can't fetch it.
    let (_bob, bob_token) = seed_owner(&pool, "bob").await;
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}/agreement"),
            None,
            Some(&bob_token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NOT_FOUND,
        "agreement must be owner-scoped"
    );
}

/// Regression: the agreement printable double-counted interest in its
/// PAID/REMAINING figures. total_repaid (Σ paid_amount) already includes
/// each payment's interest portion, but loan_agreement added
/// interest_earned on top — so one $70 repayment on a $120 + $20
/// flat-interest loan rendered "PAID $80.00 / REMAINING $60.00" while the
/// app correctly showed $70 / $70. The document must match the loan view.
#[tokio::test]
#[serial_test::serial]
async fn loan_agreement_paid_matches_loan_view_with_interest() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    // $120 principal + $20 agreed flat interest, modeled as a custom
    // schedule (one $140 row; interest inferred as rows − principal).
    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose Ramirez", "principal": 120.0, "currency": "USD",
            "origination_date": "2026-01-15"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule/custom"),
            Some(&serde_json::json!({ "rows": [{ "due_date": "2026-12-15", "amount": 140.0 }] })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::CREATED,
        "custom schedule should 201"
    );
    // One $70 cash repayment — carries a non-zero interest portion, which
    // is exactly what the old code double-counted.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({ "amount": 70.0, "paid_date": "2026-06-01" })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED, "cash payment should 201");

    // The app's source of truth: Repaid $70, owed $70.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!((l["total_repaid"].as_f64().unwrap() - 70.0).abs() < 0.01);
    assert!((l["total_owed"].as_f64().unwrap() - 70.0).abs() < 0.01);
    assert!(
        l["interest_earned"].as_f64().unwrap() > 0.0,
        "payment must carry an interest portion or this test can't catch the double-count"
    );

    // The agreement must show the SAME figures: PAID $70.00 / REMAINING
    // $70.00, "$70.00 of $140.00 paid · 50%" — not $80 / $60 / 57%.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}/agreement"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let bytes = axum::body::to_bytes(res.into_body(), 1024 * 64)
        .await
        .unwrap();
    let html = String::from_utf8(bytes.to_vec()).unwrap();
    assert!(
        html.contains(r#"<div class="k">Paid</div><div class="val">$70.00</div>"#),
        "agreement PAID must equal the loan view's total_repaid ($70.00)"
    );
    assert!(
        html.contains(r#"<div class="k">Remaining</div><div class="val">$70.00</div>"#),
        "agreement REMAINING must equal the loan view's total_owed ($70.00)"
    );
    assert!(
        html.contains("$70.00 of $140.00 paid · 50%"),
        "progress bar label must read $70.00 of $140.00 paid · 50%"
    );
}

// =====================================================================
// Overpay-spill — a payment exceeding one installment spills onto later
// installments (in installment_number order), inside one write tx.
// =====================================================================

/// A single $250 cash payment on a $1,200/12mo interest-free schedule
/// ($100/installment) must FULLY pay installments 1 & 2 and leave
/// installment 3 partial ($50), with 4-12 untouched. Outstanding drops by
/// exactly the principal applied; total_repaid == 250.
#[tokio::test]
#[serial_test::serial]
async fn loan_overpay_spills_across_installments() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, _acct) = seed_account(&pool, user_id).await;

    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    // One $250 cash payment → spills 100 + 100 + 50.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"amount": 250.0, "paid_date": "2026-02-15"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let rows = loan_payments(&app, &token, loan_id).await;
    assert_eq!(rows[0]["status"], "paid", "installment 1 fully paid");
    assert!((rows[0]["paid_amount"].as_f64().unwrap() - 100.0).abs() < 0.01);
    assert_eq!(rows[1]["status"], "paid", "installment 2 fully paid");
    assert!((rows[1]["paid_amount"].as_f64().unwrap() - 100.0).abs() < 0.01);
    assert_eq!(rows[2]["status"], "partial", "installment 3 partial");
    assert!(
        (rows[2]["paid_amount"].as_f64().unwrap() - 50.0).abs() < 0.01,
        "installment 3 should hold the $50 remainder, got {}",
        rows[2]["paid_amount"]
    );
    // 4-12 untouched.
    for r in rows.as_array().unwrap().iter().skip(3) {
        assert!(
            r["paid_amount"].is_null(),
            "installment {} must be untouched, got {}",
            r["installment_number"],
            r["paid_amount"]
        );
        assert_eq!(r["status"], "scheduled");
    }

    // No double-count on paid_amount: every touched row's paid_amount is
    // bounded by its scheduled_amount (the spill never overfills a row).
    for r in rows.as_array().unwrap().iter() {
        if let Some(p) = r["paid_amount"].as_f64() {
            assert!(
                p <= r["scheduled_amount"].as_f64().unwrap() + 0.01,
                "paid_amount must never exceed scheduled_amount, row {}",
                r["installment_number"]
            );
        }
    }

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(
        (l["outstanding"].as_f64().unwrap() - 950.0).abs() < 0.01,
        "outstanding should be 950 after $250 spill, got {}",
        l["outstanding"]
    );
    assert!(
        (l["total_repaid"].as_f64().unwrap() - 250.0).abs() < 0.01,
        "total_repaid should be 250, got {}",
        l["total_repaid"]
    );
}

/// A tx-linked overpay: the bank tx attaches to the FIRST touched
/// installment only; spilled installments carry NULL actual_tx_id.
/// DELETE-ing that first row then unreconciles cleanly — only the
/// tx-bearing row is removed, the spilled cash-style top-up stays.
#[tokio::test]
#[serial_test::serial]
async fn loan_overpay_tx_attaches_to_first_row_and_unreconciles() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();

    // $250 inflow reconciled → spills 100 + 100 + 50.
    let tx = seed_tx_dated(
        &pool,
        user_id,
        acct,
        "Zelle from Jose",
        "250.00",
        "2026-02-15",
    )
    .await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"transaction_id": tx.to_string()})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let rows = loan_payments(&app, &token, loan_id).await;
    // First touched row carries the tx; rows 2 & 3 do not.
    assert_eq!(
        rows[0]["actual_tx_id"].as_str(),
        Some(tx.to_string().as_str()),
        "first installment must carry the bank tx"
    );
    assert!(
        rows[1]["actual_tx_id"].is_null(),
        "spilled installment 2 must have NULL actual_tx_id"
    );
    assert!(
        rows[2]["actual_tx_id"].is_null(),
        "spilled installment 3 must have NULL actual_tx_id"
    );
    let first_row_id = rows[0]["id"].as_str().unwrap().to_string();

    // Unreconcile: DELETE the first (tx-bearing) row. It removes exactly
    // that row's $100 principal; the spilled $150 stays recorded.
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/loans/payments/{first_row_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::NO_CONTENT,
        "unreconcile deletes the row"
    );

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    // 250 repaid − 100 removed = 150 still repaid → outstanding 1050.
    assert!(
        (l["total_repaid"].as_f64().unwrap() - 150.0).abs() < 0.01,
        "after unreconcile total_repaid should be 150, got {}",
        l["total_repaid"]
    );
    assert!(
        (l["outstanding"].as_f64().unwrap() - 1050.0).abs() < 0.01,
        "after unreconcile outstanding should be 1050, got {}",
        l["outstanding"]
    );
}

/// Regression: an EXACT-FIT single payment ($100) still fully pays just
/// installment 1, and an UNDER-FILL ($30) still leaves it partial — the
/// spill loop must not change single-installment behaviour.
#[tokio::test]
#[serial_test::serial]
async fn loan_exact_fit_and_underfill_single_installment() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, _acct) = seed_account(&pool, user_id).await;

    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();

    // Exact fit: $100 → installment 1 paid, installment 2 untouched.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"amount": 100.0, "paid_date": "2026-02-15"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let rows = loan_payments(&app, &token, loan_id).await;
    assert_eq!(rows[0]["status"], "paid");
    assert!((rows[0]["paid_amount"].as_f64().unwrap() - 100.0).abs() < 0.01);
    assert!(rows[1]["paid_amount"].is_null(), "exact fit must not spill");

    // Under-fill: $30 → installment 2 partial, installment 3 untouched.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"amount": 30.0, "paid_date": "2026-03-15"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);
    let rows = loan_payments(&app, &token, loan_id).await;
    assert_eq!(rows[1]["status"], "partial");
    assert!((rows[1]["paid_amount"].as_f64().unwrap() - 30.0).abs() < 0.01);
    assert!(
        rows[2]["paid_amount"].is_null(),
        "under-fill must not spill"
    );
}

/// Overpay BEYOND the whole schedule: $1,300 on a $1,200 schedule pays
/// all 12 installments and appends a manual 'paid' row for the $100
/// surplus. Outstanding hits 0 (principal fully repaid; the surplus is
/// all principal on an interest-free loan).
#[tokio::test]
#[serial_test::serial]
async fn loan_overpay_beyond_schedule_appends_surplus_row() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, _acct) = seed_account(&pool, user_id).await;

    let loan_id = create_loan(
        &app,
        &token,
        &serde_json::json!({
            "borrower_name": "Jose", "principal": 1200.0, "currency": "USD",
            "origination_date": "2026-01-15", "interest_type": "none",
            "term_months": 12, "payment_frequency": "monthly"
        }),
    )
    .await;
    let _ = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/schedule"),
            Some(&serde_json::json!({})),
            Some(&token),
        ))
        .await
        .unwrap();

    // $1,300 → 12 × $100 + a $100 surplus row.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            &format!("/api/loans/{loan_id}/payments"),
            Some(&serde_json::json!({"amount": 1300.0, "paid_date": "2026-02-15"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CREATED);

    let rows = loan_payments(&app, &token, loan_id).await;
    // All 12 scheduled installments paid.
    for r in rows.as_array().unwrap().iter().take(12) {
        assert_eq!(
            r["status"], "paid",
            "installment {} must be paid",
            r["installment_number"]
        );
        assert!((r["paid_amount"].as_f64().unwrap() - 100.0).abs() < 0.01);
    }
    // A 13th appended manual row holds the $100 surplus.
    assert_eq!(
        rows.as_array().unwrap().len(),
        13,
        "a surplus row is appended"
    );
    assert_eq!(rows[12]["status"], "paid");
    assert!(
        (rows[12]["paid_amount"].as_f64().unwrap() - 100.0).abs() < 0.01,
        "surplus row should hold $100, got {}",
        rows[12]["paid_amount"]
    );

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/loans/{loan_id}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let l = body_json(res.into_body()).await;
    assert!(
        l["outstanding"].as_f64().unwrap().abs() < 0.01,
        "outstanding must be 0 after over-payoff, got {}",
        l["outstanding"]
    );
    assert!(
        (l["total_repaid"].as_f64().unwrap() - 1300.0).abs() < 0.01,
        "total_repaid should be 1300, got {}",
        l["total_repaid"]
    );
}
