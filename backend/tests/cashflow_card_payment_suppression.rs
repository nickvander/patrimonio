//! Regression suite for the 2026-08-04 confirmed bug: **a credit-card payment
//! made from checking was counted as spending** whenever the payment leg
//! carried a spending category.
//!
//! Observed on production: the owner's Bilt rent card charges $3,038.13 of rent
//! to the card, and the checking→card payments are ALSO categorized
//! `RENT_AND_UTILITIES_RENT` (the merchant is literally "BILT CARD"), so July
//! `RENT_AND_UTILITIES` totalled **$8,951.77** against a $3,038.13/mo lease —
//! ~$5,900 of phantom spending in one month. The category-based guard
//! (`category_detailed = 'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT'`) never fired
//! because the provider didn't tag those legs.
//!
//! The fix recognizes a payment leg STRUCTURALLY inside
//! `CASHFLOW_ROW_ANTI_JOINS_SQL`: an outflow from a non-liability account is
//! suppressed only when the SAME user has a matching inflow on one of their
//! liability accounts (equal absolute amount, same account currency, within
//! ±5 days). The dangerous failure mode is the opposite one — suppressing real
//! spending — so most of the tests below pin cases that must SURVIVE.
//!
//! Shared harness + fixtures: `tests/common/fixtures.rs`.

mod common;
use common::fixtures::*;

use chrono::Datelike;

/// First day of the previous calendar month. Every row in this file is seeded
/// into that month: it is entirely in the past (so `spending-insights`-style
/// windows see it too), always inside the trends/spending windows, and — with
/// day numbers kept in 3..=25 — a ±5-day pair-match can never straddle a month
/// boundary and split an assertion across two buckets.
fn prev_month_first() -> chrono::NaiveDate {
    let today = chrono::Utc::now().date_naive();
    let this_first = today.with_day(1).expect("day 1 always valid");
    (this_first - chrono::Duration::days(1))
        .with_day(1)
        .expect("day 1 always valid")
}

/// `YYYY-MM` key of the previous month — the bucket the assertions read.
fn prev_month_key() -> String {
    prev_month_first().format("%Y-%m").to_string()
}

/// `YYYY-MM-DD` for day `day` of the previous month.
fn prev_month_day(day: u32) -> String {
    prev_month_first()
        .with_day(day)
        .expect("day within month")
        .format("%Y-%m-%d")
        .to_string()
}

/// Seed a liability account (Plaid `credit`) with its own institution, so a
/// second user can own one without touching the first user's institution.
async fn seed_card(pool: &PgPool, user_id: uuid::Uuid, name: &str, currency: &str) -> uuid::Uuid {
    let inst: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ('Card Issuer', 'bank', 'US', 'manual', 'ok', $1) RETURNING id",
    )
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed card institution");
    sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, $2, 'credit', $3, -500.00, $4) RETURNING id",
    )
    .bind(inst)
    .bind(name)
    .bind(currency)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed card account")
}

/// Seed a second depository (cash) account for a user — the owner pays the same
/// card from two different checking accounts.
async fn seed_second_checking(pool: &PgPool, user_id: uuid::Uuid) -> uuid::Uuid {
    let inst: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ('Second Bank', 'bank', 'US', 'manual', 'ok', $1) RETURNING id",
    )
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed second institution");
    sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Checking 2', 'depository', 'USD', 5000.00, $2) RETURNING id",
    )
    .bind(inst)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed second checking")
}

/// Insert one transaction with an explicit date, category and PFC detailed
/// code (the detailed code is what the pre-existing card-payment guard keys
/// off, so the tests need to set it — and, more importantly, to leave it unset
/// on the legs that reproduce the bug).
#[allow(clippy::too_many_arguments)]
async fn seed_leg(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    description: &str,
    amount: &str,
    date: &str,
    category: &str,
    category_detailed: Option<&str>,
) {
    seed_leg_currency(
        pool,
        user_id,
        account_id,
        description,
        amount,
        "USD",
        date,
        category,
        category_detailed,
    )
    .await;
}

/// `seed_leg` with an explicit transaction currency, for the peso account.
#[allow(clippy::too_many_arguments)]
async fn seed_leg_currency(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    description: &str,
    amount: &str,
    currency: &str,
    date: &str,
    category: &str,
    category_detailed: Option<&str>,
) {
    sqlx::query(
        "INSERT INTO transactions (account_id, date, description, amount, currency, source, user_id, category, category_detailed) \
         VALUES ($1, $2::date, $3, $4, $5, 'manual', $6, $7, $8)",
    )
    .bind(account_id)
    .bind(date)
    .bind(description)
    .bind(Decimal::from_str(amount).unwrap())
    .bind(currency)
    .bind(user_id)
    .bind(category)
    .bind(category_detailed)
    .execute(pool)
    .await
    .expect("seed leg");
}

/// `/api/dashboard/trends` spending figure for the previous month.
async fn prev_month_spending(app: &Router, token: &str) -> f64 {
    let res = app
        .clone()
        .oneshot(req(Method::GET, "/api/dashboard/trends", None, Some(token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "trends should 200");
    let trends = body_json(res.into_body()).await;
    let key = prev_month_key();
    trends
        .as_array()
        .expect("trends array")
        .iter()
        .find(|p| p["month"] == key)
        .map(|p| p["spending"].as_f64().expect("spending is a number"))
        .unwrap_or(0.0)
}

/// Total for one category from `/api/dashboard/spending-by-category`.
async fn category_total(app: &Router, token: &str, category: &str) -> f64 {
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/spending-by-category",
            None,
            Some(token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::OK,
        "spending-by-category should 200"
    );
    let body = body_json(res.into_body()).await;
    body["categories"]
        .as_array()
        .expect("categories array")
        .iter()
        .find(|c| c["category"] == category)
        .map(|c| c["total"].as_f64().expect("total is a number"))
        .unwrap_or(0.0)
}

/// THE REPORTED SHAPE. A rent charge on the card plus the checking→card payment
/// that settles it, both categorized `RENT_AND_UTILITIES_RENT` (Plaid's read of
/// the "BILT CARD" merchant). Rent must be counted ONCE: $3,038.13, not
/// $6,076.26.
#[tokio::test]
#[serial_test::serial]
async fn card_payment_from_checking_is_not_spending() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, checking) = seed_account(&pool, user_id).await;
    let card = seed_card(&pool, user_id, "Bilt Blue Card", "USD").await;

    // The genuine spend: rent charged to the card.
    seed_leg(
        &pool,
        user_id,
        card,
        "Bilt Housing Payment",
        "-3038.13",
        &prev_month_day(5),
        "RENT_AND_UTILITIES",
        Some("RENT_AND_UTILITIES_RENT"),
    )
    .await;
    // The payment: checking outflow + the card-side inflow that settles it.
    // NOT tagged LOAN_PAYMENTS_CREDIT_CARD_PAYMENT — that is exactly why the
    // old category-only guard missed it.
    seed_leg(
        &pool,
        user_id,
        checking,
        "BILT CARD",
        "-3038.13",
        &prev_month_day(8),
        "RENT_AND_UTILITIES",
        Some("RENT_AND_UTILITIES_RENT"),
    )
    .await;
    seed_leg(
        &pool,
        user_id,
        card,
        "Payment - Bilt Housing",
        "3038.13",
        &prev_month_day(8),
        "RENT_AND_UTILITIES",
        Some("RENT_AND_UTILITIES_RENT"),
    )
    .await;

    let spending = prev_month_spending(&app, &token).await;
    assert!(
        (spending - 3038.13).abs() < 0.01,
        "rent must be counted once (3038.13); the checking→card payment leg is not spending, got {spending}"
    );

    let rent = category_total(&app, &token, "RENT_AND_UTILITIES").await;
    assert!(
        (rent - 3038.13).abs() < 0.01,
        "RENT_AND_UTILITIES must total 3038.13, not double-count the payment leg, got {rent}"
    );
}

/// THE GUARDRAIL THAT MATTERS MOST. A genuine purchase that merely happens to
/// equal a card-payment amount must still count. Two flavours:
///   (a) no liability inflow exists at all;
///   (b) a liability inflow of the same amount exists but ±5 days away it is
///       not — 15 days apart is a coincidence, not a payment pair.
#[tokio::test]
#[serial_test::serial]
async fn purchase_without_matching_card_inflow_still_counts() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, checking) = seed_account(&pool, user_id).await;
    let card = seed_card(&pool, user_id, "Visa", "USD").await;

    // (a) A real rent payment straight from checking — same amount, same
    //     category as the card scenario, but the card has no inflow at all.
    seed_leg(
        &pool,
        user_id,
        checking,
        "LANDLORD RENT",
        "-3038.13",
        &prev_month_day(6),
        "RENT_AND_UTILITIES",
        Some("RENT_AND_UTILITIES_RENT"),
    )
    .await;
    // (b) A $500 purchase on day 20 and an unrelated $500 card inflow on day 5
    //     — 15 days apart, outside the ±5-day pairing window.
    seed_leg(
        &pool,
        user_id,
        card,
        "Statement credit",
        "500.00",
        &prev_month_day(5),
        "GENERAL_MERCHANDISE",
        None,
    )
    .await;
    seed_leg(
        &pool,
        user_id,
        checking,
        "Furniture store",
        "-500.00",
        &prev_month_day(20),
        "GENERAL_MERCHANDISE",
        None,
    )
    .await;

    let spending = prev_month_spending(&app, &token).await;
    assert!(
        (spending - 3538.13).abs() < 0.01,
        "a purchase with no matching liability inflow (and one outside the ±5-day window) must still count: expected 3538.13, got {spending}"
    );
}

/// Partial and repeat payments against ONE card. Matching is leg-to-leg
/// (outflow vs the card's inflow), never against the card balance, so a
/// $2,552.85 payment toward a $3,038.13 balance is still a payment. Both
/// payment legs vanish; the single card charge remains.
#[tokio::test]
#[serial_test::serial]
async fn partial_and_repeat_payments_all_suppressed() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, checking) = seed_account(&pool, user_id).await;
    let checking2 = seed_second_checking(&pool, user_id).await;
    let card = seed_card(&pool, user_id, "Bilt Blue Card", "USD").await;

    seed_leg(
        &pool,
        user_id,
        card,
        "Bilt Housing Payment",
        "-3038.13",
        &prev_month_day(3),
        "RENT_AND_UTILITIES",
        Some("RENT_AND_UTILITIES_RENT"),
    )
    .await;
    // Full payment from checking #1 (posts to the card the same day).
    seed_leg(
        &pool,
        user_id,
        checking,
        "BILT CARD",
        "-3038.13",
        &prev_month_day(10),
        "RENT_AND_UTILITIES",
        Some("RENT_AND_UTILITIES_RENT"),
    )
    .await;
    seed_leg(
        &pool,
        user_id,
        card,
        "Payment - Bilt Housing",
        "3038.13",
        &prev_month_day(10),
        "RENT_AND_UTILITIES",
        Some("RENT_AND_UTILITIES_RENT"),
    )
    .await;
    // Partial payment from checking #2, posting to the card the next day.
    seed_leg(
        &pool,
        user_id,
        checking2,
        "BILT CARD",
        "-2552.85",
        &prev_month_day(20),
        "RENT_AND_UTILITIES",
        Some("RENT_AND_UTILITIES_RENT"),
    )
    .await;
    seed_leg(
        &pool,
        user_id,
        card,
        "Payment - Bilt Housing",
        "2552.85",
        &prev_month_day(21),
        "RENT_AND_UTILITIES",
        Some("RENT_AND_UTILITIES_RENT"),
    )
    .await;

    let spending = prev_month_spending(&app, &token).await;
    assert!(
        (spending - 3038.13).abs() < 0.01,
        "one card charge, two payment legs: spending must be 3038.13 (pre-fix: 8629.11), got {spending}"
    );
}

/// CROSS-TENANT SAFETY. Another person's credit-card inflow must never explain
/// away this user's spending — the pair-match is user-scoped on BOTH legs.
#[tokio::test]
#[serial_test::serial]
async fn other_users_card_inflow_does_not_suppress_spending() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, checking) = seed_account(&pool, user_id).await;

    // A different household member with their own card, paid the same day for
    // the same amount.
    let (other_id, _other_token) = seed_owner(&pool, "neighbor").await;
    let other_card = seed_card(&pool, other_id, "Their Amex", "USD").await;
    seed_leg(
        &pool,
        other_id,
        other_card,
        "Payment Thank You",
        "500.00",
        &prev_month_day(12),
        "LOAN_PAYMENTS",
        Some("LOAN_PAYMENTS_CREDIT_CARD_PAYMENT"),
    )
    .await;

    // This user's genuine $500 purchase.
    seed_leg(
        &pool,
        user_id,
        checking,
        "Appliance store",
        "-500.00",
        &prev_month_day(12),
        "GENERAL_MERCHANDISE",
        None,
    )
    .await;

    let spending = prev_month_spending(&app, &token).await;
    assert!(
        (spending - 500.0).abs() < 0.01,
        "another user's card inflow must not suppress this user's spending, got {spending}"
    );
}

/// The pre-existing category-based exclusion is unchanged: a leg the provider
/// DID tag `LOAN_PAYMENTS_CREDIT_CARD_PAYMENT` stays excluded even with no
/// matching liability inflow anywhere (e.g. the card isn't linked).
#[tokio::test]
#[serial_test::serial]
async fn categorized_card_payment_still_excluded_without_a_counterpart() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, checking) = seed_account(&pool, user_id).await;

    seed_leg(
        &pool,
        user_id,
        checking,
        "AMEX EPAYMENT",
        "-1200.00",
        &prev_month_day(9),
        "LOAN_PAYMENTS",
        Some("LOAN_PAYMENTS_CREDIT_CARD_PAYMENT"),
    )
    .await;
    seed_leg(
        &pool,
        user_id,
        checking,
        "Supermarket",
        "-75.00",
        &prev_month_day(9),
        "FOOD_AND_DRINK",
        None,
    )
    .await;

    let spending = prev_month_spending(&app, &token).await;
    assert!(
        (spending - 75.0).abs() < 0.01,
        "the categorized card payment stays excluded (groceries only), got {spending}"
    );
}

/// A refund posted to the card is an inflow on a LIABILITY account, and the
/// purchase it refunds sits on that same card — i.e. an outflow from a
/// liability account. The structural rule only ever suppresses outflows from
/// CASH accounts, so a card purchase is never explained away by a card credit.
#[tokio::test]
#[serial_test::serial]
async fn card_purchase_is_not_suppressed_by_a_card_refund() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, _checking) = seed_account(&pool, user_id).await;
    let card = seed_card(&pool, user_id, "Visa", "USD").await;

    seed_leg(
        &pool,
        user_id,
        card,
        "Electronics store",
        "-120.00",
        &prev_month_day(10),
        "GENERAL_MERCHANDISE",
        None,
    )
    .await;
    seed_leg(
        &pool,
        user_id,
        card,
        "Electronics store refund",
        "120.00",
        &prev_month_day(12),
        "GENERAL_MERCHANDISE",
        None,
    )
    .await;

    let spending = prev_month_spending(&app, &token).await;
    assert!(
        (spending - 120.0).abs() < 0.01,
        "a card purchase must survive an equal card refund (the inflow is excluded, the purchase is not), got {spending}"
    );
}

/// Currency guard: 3,038.13 MXN out of a peso checking account is ~$152 and has
/// nothing to do with a $3,038.13 card payment. Pair-matching requires the two
/// accounts to share a currency, so the nominal collision must not suppress the
/// peso outflow.
#[tokio::test]
#[serial_test::serial]
async fn same_nominal_amount_in_a_different_currency_is_not_a_match() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let mxn_checking = seed_account_currency(&pool, user_id, "MXN").await;
    let usd_card = seed_card(&pool, user_id, "US Visa", "USD").await;

    // A rate on-or-before the seeded rows so the conversion is deterministic
    // (no rate at all would fall back to 20.0 anyway, but pin it explicitly).
    seed_fx_rate_days_ago(&pool, "20.00", 400).await;

    seed_leg_currency(
        &pool,
        user_id,
        mxn_checking,
        "Renta CDMX",
        "-3038.13",
        "MXN",
        &prev_month_day(11),
        "RENT_AND_UTILITIES",
        Some("RENT_AND_UTILITIES_RENT"),
    )
    .await;
    seed_leg(
        &pool,
        user_id,
        usd_card,
        "Payment Thank You",
        "3038.13",
        &prev_month_day(11),
        "LOAN_PAYMENTS",
        Some("LOAN_PAYMENTS_CREDIT_CARD_PAYMENT"),
    )
    .await;

    let spending = prev_month_spending(&app, &token).await;
    assert!(
        (spending - 151.9065).abs() < 0.01,
        "a peso outflow must not be paired with a same-nominal USD card inflow: expected ~151.91 USD, got {spending}"
    );
}
