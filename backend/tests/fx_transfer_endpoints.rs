//! HTTP-level integration tests for the `/api/dashboard/fx-transfers`
//! listing (cross-currency transfer pairs + spot rate).
//!
//! Split out of the former all-in-one `dashboard_endpoints.rs`. Shared
//! harness + fixtures: `tests/common/fixtures.rs`.

mod common;
use common::fixtures::*;

// =====================================================================
// /api/dashboard/fx-transfers
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn fx_transfers_listing_empty() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/fx-transfers",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert!(body.as_array().unwrap().is_empty());
}

/// When a transfer exists and there's an `exchange_rates` row near the
/// source date, the endpoint should populate `spot_fx_rate` so the
/// frontend can render "Wise gave you 19.40, market was 19.62"
/// without a separate FX lookup per row. Locks in the per-date
/// subquery rewrite added for the cross-currency cash-flow card.
#[tokio::test]
#[serial_test::serial]
async fn fx_transfers_listing_populates_spot_rate() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;

    // Two transactions on the same day: USD outflow + MXN inflow.
    let src_id = seed_tx(&pool, user_id, account, "WISE transfer", "-1000.00").await;
    let dst_id = seed_tx(&pool, user_id, account, "Nu Bank deposit", "19500.00").await;

    // Spot rate two days ahead of source-date: 19.62 USD→MXN.
    // (Within the ±7d window the endpoint searches.)
    sqlx::query(
        "INSERT INTO exchange_rates (base_currency, target_currency, rate, recorded_at) \
         VALUES ('USD', 'MXN', 19.62, NOW() + INTERVAL '2 days')",
    )
    .execute(&pool)
    .await
    .expect("seed spot rate");

    // Link the pair at the implied (Wise) rate of 19.50.
    sqlx::query(
        "INSERT INTO cash_fx_transfers (user_id, source_tx_id, dest_tx_id, \
         source_amount, source_currency, dest_amount, dest_currency, \
         implied_fx_rate, detection_confidence, user_confirmed, matched_keyword) \
         VALUES ($1, $2, $3, 1000.00, 'USD', 19500.00, 'MXN', 19.50, 90, true, 'WISE')",
    )
    .bind(user_id)
    .bind(src_id)
    .bind(dst_id)
    .execute(&pool)
    .await
    .expect("seed fx transfer");

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/fx-transfers",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let arr = body.as_array().unwrap();
    assert_eq!(arr.len(), 1, "exactly one linked transfer expected");
    let entry = &arr[0];
    let implied = entry["implied_fx_rate"].as_f64().unwrap();
    let spot = entry["spot_fx_rate"].as_f64();
    assert!(
        (implied - 19.5).abs() < 0.001,
        "implied 19.50 expected, got {implied}"
    );
    assert!(
        spot.is_some() && (spot.unwrap() - 19.62).abs() < 0.001,
        "spot rate 19.62 expected, got {spot:?}"
    );
}
