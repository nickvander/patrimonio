//! Regression test for the loan-repayment suggestion date boundary.
//!
//! A repayment dated EXACTLY on the loan's disbursement/origination day
//! (the `after_date` lower bound) used to be dropped by a strict
//! `t.date > $3` in `suggest_repayments`, so the "Link bank transaction"
//! sheet reported "No matching bank transactions found" for a payment the
//! user could plainly see in the account. The bound is now inclusive;
//! the disbursement itself is an outflow, so `amount > 0` still keeps it
//! out. This test pins that: a same-day inflow must be suggested, while a
//! genuinely-earlier inflow must not.
//!
//! Needs a real Postgres via `PATRIMONIO_TEST_DATABASE_URL`; skips (green)
//! when unset. Shares the test DB, so it runs serially like the others.

use std::str::FromStr;

use chrono::NaiveDate;
use rust_decimal::Decimal;
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;

use patrimonio::services::loan_match;

const TEST_DB_VAR: &str = "PATRIMONIO_TEST_DATABASE_URL";

async fn try_pool() -> Option<PgPool> {
    let database_url = std::env::var(TEST_DB_VAR).ok()?;
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
    Some(pool)
}

async fn seed_user(pool: &PgPool) -> uuid::Uuid {
    sqlx::query_scalar(
        "INSERT INTO users (username, email, password_hash) \
         VALUES ('lender', 'lender@example.com', 'x') RETURNING id",
    )
    .fetch_one(pool)
    .await
    .expect("seed user")
}

async fn seed_mxn_depository(pool: &PgPool, user_id: uuid::Uuid) -> uuid::Uuid {
    let inst_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ('Nu México', 'bank', 'MX', 'manual', 'ok', $1) RETURNING id",
    )
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed institution");
    sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, 'Nu MXN', 'depository', 'MXN', 0.00, $2) RETURNING id",
    )
    .bind(inst_id)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed account")
}

async fn seed_inflow(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    date: NaiveDate,
    description: &str,
    amount: &str,
) -> uuid::Uuid {
    sqlx::query_scalar(
        "INSERT INTO transactions (account_id, date, description, amount, currency, source, user_id) \
         VALUES ($1, $2, $3, $4, 'MXN', 'manual', $5) RETURNING id",
    )
    .bind(account_id)
    .bind(date)
    .bind(description)
    .bind(Decimal::from_str(amount).unwrap())
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed inflow")
}

#[tokio::test]
#[serial_test::serial]
async fn same_day_repayment_is_suggested() {
    let Some(pool) = try_pool().await else {
        eprintln!("(skipping: set {TEST_DB_VAR} to run loan-match boundary test)");
        return;
    };

    let user = seed_user(&pool).await;
    let account = seed_mxn_depository(&pool, user).await;

    // The loan was disbursed / originated on this day; the borrower repaid
    // the first installment the SAME day.
    let origination = NaiveDate::from_ymd_opt(2026, 6, 15).unwrap();
    let horizon = NaiveDate::from_ymd_opt(2027, 12, 15).unwrap();

    let on_boundary = seed_inflow(
        &pool,
        user,
        account,
        origination,
        "SPEI RECIBIDO LUIS OJEDA",
        "3500.00",
    )
    .await;
    // A genuinely-earlier inflow must stay excluded by the lower bound.
    let before = seed_inflow(
        &pool,
        user,
        account,
        NaiveDate::from_ymd_opt(2026, 6, 14).unwrap(),
        "SPEI RECIBIDO LUIS OJEDA",
        "3500.00",
    )
    .await;

    let suggestions = loan_match::suggest_repayments(
        &pool,
        user,
        "MXN",
        origination,
        horizon,
        "Luis Enrique Ojeda",
        Some(3500.0),
        None,
    )
    .await
    .expect("suggest_repayments");

    let ids: Vec<String> = suggestions.iter().map(|s| s.transaction_id.clone()).collect();
    assert!(
        ids.contains(&on_boundary.to_string()),
        "same-day repayment must be suggested (inclusive lower bound); got {ids:?}"
    );
    assert!(
        !ids.contains(&before.to_string()),
        "an inflow dated before the disbursement day must not be suggested; got {ids:?}"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn no_schedule_lump_sum_payoff_is_suggested() {
    let Some(pool) = try_pool().await else {
        eprintln!("(skipping: set {TEST_DB_VAR} to run loan-match boundary test)");
        return;
    };

    let user = seed_user(&pool).await;
    let account = seed_mxn_depository(&pool, user).await;

    let origination = NaiveDate::from_ymd_opt(2026, 6, 15).unwrap();
    let horizon = NaiveDate::from_ymd_opt(2027, 12, 15).unwrap();
    let paid_on = NaiveDate::from_ymd_opt(2026, 8, 1).unwrap();

    // A terse, nameless, NON-round inflow that exactly clears the loan.
    // With no schedule this used to be dropped (no name, not round); the
    // payoff signal (amount ≈ outstanding) should now surface it.
    let payoff = seed_inflow(
        &pool,
        user,
        account,
        paid_on,
        "SPEI RECIBIDO 0009876",
        "4237.55",
    )
    .await;

    // No schedule (installment None). Borrower name deliberately absent
    // from the description so only the payoff signal can match.
    let with_target = loan_match::suggest_repayments(
        &pool,
        user,
        "MXN",
        origination,
        horizon,
        "Anonymous Borrower",
        None,
        Some(4237.55),
    )
    .await
    .expect("suggest_repayments");
    let ids: Vec<String> = with_target.iter().map(|s| s.transaction_id.clone()).collect();
    assert!(
        ids.contains(&payoff.to_string()),
        "a nameless, non-round payoff matching the outstanding balance must be suggested; got {ids:?}"
    );

    // Control: without the payoff target the same inflow has no signal
    // (no name, not round) and must stay out — proving the gate still bites.
    let without_target = loan_match::suggest_repayments(
        &pool,
        user,
        "MXN",
        origination,
        horizon,
        "Anonymous Borrower",
        None,
        None,
    )
    .await
    .expect("suggest_repayments");
    let ids: Vec<String> =
        without_target.iter().map(|s| s.transaction_id.clone()).collect();
    assert!(
        !ids.contains(&payoff.to_string()),
        "without a payoff target a nameless non-round inflow must not be suggested; got {ids:?}"
    );
}
