//! HTTP-level integration tests for `/api/projections/defaults`
//! (per-row FX, 2dp rounding, loud errors). The projection math endpoints
//! live in `projection_endpoints.rs`.
//!
//! Split out of the former all-in-one `dashboard_endpoints.rs`. Shared
//! harness + fixtures: `tests/common/fixtures.rs`.

mod common;
use common::fixtures::*;

// =====================================================================
// /api/projections/defaults — per-row FX, 2dp rounding, loud errors
// =====================================================================

/// Regression: /api/projections/defaults must convert each MXN transaction at
/// the FX rate in effect ON ITS OWN DATE (the shared services::tax
/// USD_MXN_ROW_RATE_SQL rule), not at the single latest rate. Rates move
/// several percent over a trailing year, so latest-rate conversion skews the
/// annualized income/spend whenever the peso has trended. Also pins:
/// 2dp-rounded outputs, and 401 for unauthenticated callers (the handler now
/// returns Result<_, ApiError> instead of fabricating zeros).
#[tokio::test]
#[serial_test::serial]
async fn projection_defaults_per_row_fx_and_errors() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };

    // Unauthenticated first: no cookie → 401, never a zeros body.
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/projections/defaults", None, None))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::UNAUTHORIZED,
        "defaults without a session must 401"
    );

    let (token, user_id) = bootstrap(&app, &pool).await;
    let mxn_acct = seed_account_currency(&pool, user_id, "MXN").await;

    // Two rates in force in two different months:
    //   ~100 days ago: 20.00 MXN per USD
    //   ~40 days ago:  21.00 MXN per USD  (also the LATEST rate)
    seed_fx_rate_days_ago(&pool, "20.00", 100).await;
    seed_fx_rate_days_ago(&pool, "21.00", 40).await;

    // Month A (100 days ago, rate 20): +20,000 MXN → $1,000.00; −2,100 MXN → $105.00
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "salary A", "20000.00", "MXN", 100).await;
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent A", "-2100.00", "MXN", 100).await;
    // Month B (40 days ago, rate 21): +10,000 MXN → $476.190476…; −1,050 MXN → $50.00
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "salary B", "10000.00", "MXN", 40).await;
    seed_tx_currency_days_ago(&pool, user_id, mxn_acct, "rent B", "-1050.00", "MXN", 40).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/projections/defaults",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    let income = body["annual_income"].as_f64().expect("annual_income f64");
    let expenses = body["annual_expenses"]
        .as_f64()
        .expect("annual_expenses f64");
    let contribution = body["monthly_contribution"]
        .as_f64()
        .expect("monthly_contribution f64");
    assert_eq!(body["months_of_data"].as_i64(), Some(2));

    // Per-row conversion, annualized over the 2 months of data:
    //   income  = (20000/20 + 10000/21) / 2 * 12 = 8857.142857… → 8857.14
    //   spend   = (2100/20  + 1050/21)  / 2 * 12 = 930.00
    //   monthly = (8857.14… − 930) / 12          = 660.595…    → 660.60
    // Latest-rate (21.0) conversion would instead give income = 8571.43 and
    // spend = 900.00 — the bug this test pins against.
    assert!(
        (income - 8857.14).abs() < 0.01,
        "annual_income {income}: expected per-row FX 8857.14 (latest-rate bug would give 8571.43)"
    );
    assert!(
        (expenses - 930.00).abs() < 0.01,
        "annual_expenses {expenses}: expected per-row FX 930.00 (latest-rate bug would give 900.00)"
    );
    assert!(
        (contribution - 660.60).abs() < 0.01,
        "monthly_contribution {contribution}: expected 660.60"
    );

    assert_two_dp(income, "annual_income");
    assert_two_dp(expenses, "annual_expenses");
    assert_two_dp(contribution, "monthly_contribution");
}

/// Regression: months_of_data counts DISTINCT calendar months with data, and
/// the annualization divides by that count — 2 months of history must not be
/// stretched as if it were a full year (a user with 2 months of imports would
/// otherwise be told they earn/spend a sixth of reality).
#[tokio::test]
#[serial_test::serial]
async fn projection_defaults_months_of_data_partial_months() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user_id).await;

    // Transactions in exactly two distinct months (100 and 40 days back are
    // always >31 days apart, hence different calendar months, and both are
    // inside the trailing-12-month window).
    seed_tx_currency_days_ago(&pool, user_id, acct, "pay 1", "3000.00", "USD", 100).await;
    seed_tx_currency_days_ago(&pool, user_id, acct, "pay 2", "3000.00", "USD", 40).await;
    seed_tx_currency_days_ago(&pool, user_id, acct, "groceries", "-600.00", "USD", 40).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/projections/defaults",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;

    assert_eq!(
        body["months_of_data"].as_i64(),
        Some(2),
        "two distinct months of transactions → months_of_data == 2"
    );
    // Annualization divides by 2 (the actual months), not 12:
    //   income  = 6000 / 2 * 12 = 36000
    //   spend   =  600 / 2 * 12 =  3600
    //   monthly = (36000 − 3600) / 12 = 2700
    let income = body["annual_income"].as_f64().unwrap();
    let expenses = body["annual_expenses"].as_f64().unwrap();
    let contribution = body["monthly_contribution"].as_f64().unwrap();
    assert!((income - 36000.0).abs() < 0.01, "annual_income {income}");
    assert!(
        (expenses - 3600.0).abs() < 0.01,
        "annual_expenses {expenses}"
    );
    assert!(
        (contribution - 2700.0).abs() < 0.01,
        "monthly_contribution {contribution}"
    );
}
