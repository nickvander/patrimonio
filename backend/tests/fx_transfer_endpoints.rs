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

// =====================================================================
// /api/dashboard/fx-transfers/costs — annual transfer-cost report
// =====================================================================

/// Insert a USD→MXN exchange rate recorded on an explicit date (noon,
/// so `recorded_at::date` round-trips to the same day in any session
/// time zone the test DB happens to use).
async fn seed_rate_on(pool: &sqlx::PgPool, rate: &str, date: &str) {
    sqlx::query(
        "INSERT INTO exchange_rates (base_currency, target_currency, rate, recorded_at) \
         VALUES ('USD', 'MXN', $1::numeric, $2::date + INTERVAL '12 hours')",
    )
    .bind(rate)
    .bind(date)
    .execute(pool)
    .await
    .expect("seed dated fx rate");
}

/// Link two transactions as a cash FX transfer with explicit leg
/// amounts/currencies, implied rate and (optional) detection keyword.
#[allow(clippy::too_many_arguments)]
async fn link_transfer(
    pool: &sqlx::PgPool,
    user_id: uuid::Uuid,
    src: uuid::Uuid,
    dst: uuid::Uuid,
    src_amt: &str,
    src_ccy: &str,
    dst_amt: &str,
    dst_ccy: &str,
    implied: &str,
    keyword: Option<&str>,
) {
    sqlx::query(
        "INSERT INTO cash_fx_transfers (user_id, source_tx_id, dest_tx_id, \
         source_amount, source_currency, dest_amount, dest_currency, \
         implied_fx_rate, detection_confidence, user_confirmed, matched_keyword) \
         VALUES ($1, $2, $3, $4::numeric, $5, $6::numeric, $7, $8::numeric, 90, true, $9)",
    )
    .bind(user_id)
    .bind(src)
    .bind(dst)
    .bind(src_amt)
    .bind(src_ccy)
    .bind(dst_amt)
    .bind(dst_ccy)
    .bind(implied)
    .bind(keyword)
    .execute(pool)
    .await
    .expect("seed fx transfer link");
}

fn assert_close(v: f64, expected: f64, field: &str) {
    assert!(
        (v - expected).abs() < 1e-9,
        "{field}: expected {expected}, got {v}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn fx_transfer_costs_empty() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/fx-transfers/costs",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(
        body["spot_window_days"].as_i64(),
        Some(7),
        "the ±7-day spot tolerance must be surfaced for the UI caveat"
    );
    assert!(body["years"].as_array().unwrap().is_empty());
}

/// Multi-year, multi-provider seeding with deterministic spot lookups:
/// exact totals per year/provider, TRANSFERWISE folded into WISE, the
/// keyword-less link in the unknown (null) bucket, and a transfer with
/// no rate inside ±7 days excluded from cost (counted, not guessed).
#[tokio::test]
#[serial_test::serial]
async fn fx_transfer_costs_multi_year_multi_provider_exact_totals() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;

    // Spot rates. The 2024-03-01 row is a decoy: 9 days before the first
    // 2024 transfer, i.e. OUTSIDE the ±7-day window — if it were picked
    // the 2024 totals below would come out wrong.
    seed_rate_on(&pool, "19.00", "2024-03-01").await;
    seed_rate_on(&pool, "20.00", "2024-03-12").await;
    seed_rate_on(&pool, "20.00", "2025-06-03").await;
    // Deliberately NO rate anywhere near 2025-12-20.

    // 2024 / WISE: sent $1,000, got 19,500 MXN. Spot 20.00 values the
    // pesos at $975 → cost $25.00.
    let s1 = seed_tx_dated(
        &pool,
        user_id,
        account,
        "WISE out",
        "-1000.00",
        "2024-03-10",
    )
    .await;
    let d1 = seed_tx_dated(&pool, user_id, account, "MXN in", "19500.00", "2024-03-10").await;
    link_transfer(
        &pool,
        user_id,
        s1,
        d1,
        "1000.00",
        "USD",
        "19500.00",
        "MXN",
        "19.50",
        Some("WISE"),
    )
    .await;

    // 2024 / TRANSFERWISE (must fold into the WISE bucket): sent $500,
    // got 9,800 MXN → $490 at spot 20.00 → cost $10.00.
    let s2 = seed_tx_dated(&pool, user_id, account, "TW out", "-500.00", "2024-03-14").await;
    let d2 = seed_tx_dated(&pool, user_id, account, "MXN in 2", "9800.00", "2024-03-14").await;
    link_transfer(
        &pool,
        user_id,
        s2,
        d2,
        "500.00",
        "USD",
        "9800.00",
        "MXN",
        "19.60",
        Some("TRANSFERWISE"),
    )
    .await;

    // 2025 / keyword-less (unknown bucket), MXN→USD: sent 20,000 MXN
    // (= $1,000 at spot 20.00), received $950 → cost $50.00.
    let s3 = seed_tx_dated(
        &pool,
        user_id,
        account,
        "SPEI out",
        "-20000.00",
        "2025-06-05",
    )
    .await;
    let d3 = seed_tx_dated(&pool, user_id, account, "USD in", "950.00", "2025-06-05").await;
    link_transfer(
        &pool, user_id, s3, d3, "20000.00", "MXN", "950.00", "USD", "21.05", None,
    )
    .await;

    // 2025 / REMITLY with NO spot inside ±7 days: cost is excluded (not
    // guessed); the $800 sent still counts toward "moved".
    let s4 = seed_tx_dated(
        &pool,
        user_id,
        account,
        "REMITLY out",
        "-800.00",
        "2025-12-20",
    )
    .await;
    let d4 = seed_tx_dated(
        &pool,
        user_id,
        account,
        "MXN in 3",
        "15200.00",
        "2025-12-20",
    )
    .await;
    link_transfer(
        &pool,
        user_id,
        s4,
        d4,
        "800.00",
        "USD",
        "15200.00",
        "MXN",
        "19.00",
        Some("REMITLY"),
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/fx-transfers/costs",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["spot_window_days"].as_i64(), Some(7));

    let years = body["years"].as_array().unwrap();
    assert_eq!(years.len(), 2, "two calendar years expected");

    // Newest year first.
    let y2025 = &years[0];
    let y2024 = &years[1];
    assert_eq!(y2025["year"].as_i64(), Some(2025));
    assert_eq!(y2024["year"].as_i64(), Some(2024));

    // ---- 2024: both transfers fold into a single WISE bucket ----
    assert_eq!(y2024["transfer_count"].as_i64(), Some(2));
    assert_close(y2024["total_cost_usd"].as_f64().unwrap(), 35.0, "2024 cost");
    assert_close(
        y2024["total_moved_usd"].as_f64().unwrap(),
        1500.0,
        "2024 moved USD",
    );
    assert_close(
        y2024["moved_by_currency"]["USD"].as_f64().unwrap(),
        1500.0,
        "2024 moved by ccy",
    );
    assert_eq!(y2024["missing_spot_count"].as_i64(), Some(0));
    let p2024 = y2024["providers"].as_array().unwrap();
    assert_eq!(
        p2024.len(),
        1,
        "TRANSFERWISE must fold into WISE, not split the bucket"
    );
    assert_eq!(p2024[0]["provider"].as_str(), Some("WISE"));
    assert_eq!(p2024[0]["transfer_count"].as_i64(), Some(2));
    assert_close(
        p2024[0]["total_cost_usd"].as_f64().unwrap(),
        35.0,
        "WISE 2024 cost",
    );

    // ---- 2025: unknown bucket + REMITLY-with-no-spot ----
    assert_eq!(y2025["transfer_count"].as_i64(), Some(2));
    assert_close(y2025["total_cost_usd"].as_f64().unwrap(), 50.0, "2025 cost");
    // 20,000 MXN at spot 20.00 = $1,000, plus the $800 REMITLY send.
    assert_close(
        y2025["total_moved_usd"].as_f64().unwrap(),
        1800.0,
        "2025 moved USD",
    );
    assert_close(
        y2025["moved_by_currency"]["MXN"].as_f64().unwrap(),
        20000.0,
        "2025 moved MXN",
    );
    assert_close(
        y2025["moved_by_currency"]["USD"].as_f64().unwrap(),
        800.0,
        "2025 moved USD leg",
    );
    assert_eq!(
        y2025["missing_spot_count"].as_i64(),
        Some(1),
        "the no-nearby-rate transfer is excluded from cost, not guessed"
    );
    let p2025 = y2025["providers"].as_array().unwrap();
    assert_eq!(p2025.len(), 2);
    // Sorted by cost desc: the unknown bucket ($50) ahead of REMITLY ($0).
    assert!(
        p2025[0]["provider"].is_null(),
        "keyword-less link lands in the null/unknown bucket"
    );
    assert_eq!(p2025[0]["transfer_count"].as_i64(), Some(1));
    assert_close(
        p2025[0]["total_cost_usd"].as_f64().unwrap(),
        50.0,
        "unknown-bucket cost",
    );
    assert_eq!(p2025[1]["provider"].as_str(), Some("REMITLY"));
    assert_eq!(p2025[1]["missing_spot_count"].as_i64(), Some(1));
    assert_close(
        p2025[1]["total_cost_usd"].as_f64().unwrap(),
        0.0,
        "uncosted provider contributes zero cost",
    );
    assert_close(
        p2025[1]["total_moved_usd"].as_f64().unwrap(),
        800.0,
        "uncosted provider still counts moved",
    );
}

/// Another user's transfers must never leak into the caller's report.
#[tokio::test]
#[serial_test::serial]
async fn fx_transfer_costs_scoped_to_caller() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    // A second owner with a linked (and costed) transfer of their own.
    let (other_id, _other_token) = seed_owner(&pool, "otherowner").await;
    let (_inst, other_account) = seed_account(&pool, other_id).await;
    seed_rate_on(&pool, "20.00", "2024-05-02").await;
    let s = seed_tx_dated(
        &pool,
        other_id,
        other_account,
        "WISE out",
        "-1000.00",
        "2024-05-01",
    )
    .await;
    let d = seed_tx_dated(
        &pool,
        other_id,
        other_account,
        "MXN in",
        "19000.00",
        "2024-05-01",
    )
    .await;
    link_transfer(
        &pool,
        other_id,
        s,
        d,
        "1000.00",
        "USD",
        "19000.00",
        "MXN",
        "19.00",
        Some("WISE"),
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/fx-transfers/costs",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert!(
        body["years"].as_array().unwrap().is_empty(),
        "caller must not see another user's transfers"
    );
}
