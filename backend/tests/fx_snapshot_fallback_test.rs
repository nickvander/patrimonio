//! `balance_usd` must never receive a raw MXN figure.
//!
//! Every snapshot writer used to inline its own
//! `ORDER BY recorded_at DESC LIMIT 1` rate lookup and, when that came back
//! NULL or zero, fall through to `ELSE <native balance>`. A 400,000 MXN
//! account then lands in net worth as $400,000 instead of ~$22,900 — the ~17x
//! class this codebase has already been bitten by — and because the snapshot
//! cron is `ON CONFLICT DO NOTHING` and the chart carries values forward, the
//! spike sticks.
//!
//! Two reachable triggers made "no usable rate" a real state, not a
//! hypothetical: `fetch_and_store_rate` defaulted a missing pair to 0.0 and
//! stored it (so the freshest row was zero), and nothing schedules an FX
//! fetch, so `exchange_rates` is simply empty on a fresh deploy.
//!
//! Needs a real Postgres via `PATRIMONIO_TEST_DATABASE_URL`; unset prints a
//! skip note and returns (set-but-unreachable PANICS — see tests/common/mod.rs).

use rust_decimal::Decimal;
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;

use patrimonio::services::exchange_rate::{
    latest_usd_mxn_rate_for_write, LATEST_USD_MXN_RATE_SQL,
};

mod common;
use common::TestLockGuard;

const TEST_DB_VAR: &str = "PATRIMONIO_TEST_DATABASE_URL";

async fn try_setup() -> Option<(PgPool, TestLockGuard)> {
    let database_url = std::env::var(TEST_DB_VAR).ok()?;
    let lock = TestLockGuard::acquire(&database_url).await?;
    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect(&database_url)
        .await
        .expect("connect to test DB");
    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .expect("apply migrations to test DB");
    sqlx::query("TRUNCATE exchange_rates RESTART IDENTITY CASCADE")
        .execute(&pool)
        .await
        .expect("truncate exchange_rates");
    Some((pool, lock))
}

fn skip_if_no_db<T>(result: Option<T>) -> Option<T> {
    if result.is_none() {
        eprintln!("(skipping: set {TEST_DB_VAR} to enable FX fallback integration tests)");
    }
    result
}

async fn seed_rate(pool: &PgPool, rate: &str, source: &str, minutes_ago: i64) {
    sqlx::query(
        "INSERT INTO exchange_rates (base_currency, target_currency, rate, source, recorded_at) \
         VALUES ('USD', 'MXN', $1::numeric, $2, NOW() - $3 * INTERVAL '1 minute')",
    )
    .bind(rate)
    .bind(source)
    .bind(minutes_ago)
    .execute(pool)
    .await
    .expect("seed rate");
}

/// What the SQL constant resolves to right now.
async fn sql_rate(pool: &PgPool) -> Decimal {
    sqlx::query_scalar::<_, Decimal>(&format!("SELECT {LATEST_USD_MXN_RATE_SQL}"))
        .fetch_one(pool)
        .await
        .expect("resolve rate ladder")
}

fn dec(s: &str) -> Decimal {
    s.parse().expect("decimal")
}

#[tokio::test]
#[serial_test::serial]
async fn empty_rate_table_falls_back_to_a_rate_not_to_one_to_one() {
    let Some((pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };

    assert_eq!(sql_rate(&pool).await, dec("20.0"));
    assert_eq!(latest_usd_mxn_rate_for_write(&pool).await, dec("20.0"));

    // The number that matters: 400,000 MXN converted, not copied.
    let usd = dec("400000") / sql_rate(&pool).await;
    assert_eq!(usd.round_dp(2), dec("20000.00"));
    assert!(
        usd < dec("30000"),
        "must not be the ~17x native-balance passthrough"
    );
}

/// A zero row used to be the FRESHEST row (the upstream payload omitting the
/// pair stored 0.0), which is what selected the native-balance branch.
#[tokio::test]
#[serial_test::serial]
async fn a_zero_rate_row_is_skipped_in_favour_of_the_last_good_one() {
    let Some((pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    seed_rate(&pool, "17.50", "api", 60).await;
    seed_rate(&pool, "0", "api", 1).await; // newest, poisonous

    assert_eq!(
        sql_rate(&pool).await,
        dec("17.50"),
        "the newest row is unusable; fall through to the last good rate"
    );
    assert_eq!(latest_usd_mxn_rate_for_write(&pool).await, dec("17.50"));
}

/// A hand-corrected rate must outrank a bad automated one — matching the
/// reader (`api::dashboard::latest_usd_mxn_rate`) so writes and reads agree.
#[tokio::test]
#[serial_test::serial]
async fn a_manual_override_outranks_a_fresher_api_row() {
    let Some((pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    seed_rate(&pool, "18.00", "manual", 120).await;
    seed_rate(&pool, "17.00", "api", 1).await;

    assert_eq!(sql_rate(&pool).await, dec("18.00"));
    assert_eq!(latest_usd_mxn_rate_for_write(&pool).await, dec("18.00"));
}

#[tokio::test]
#[serial_test::serial]
async fn the_rust_helper_and_the_sql_constant_cannot_drift() {
    let Some((pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    for (rate, source) in [("17.48", "api"), ("0", "api"), ("19.10", "manual")] {
        seed_rate(&pool, rate, source, 1).await;
        assert_eq!(
            latest_usd_mxn_rate_for_write(&pool).await,
            sql_rate(&pool).await,
            "helper must resolve exactly what the SQL ladder does"
        );
    }
}

/// Every writer divides by this rate unconditionally, so zero is a
/// divide-by-zero (or a NULL that skips the row) — the ladder must never
/// return one, whatever the table holds.
#[tokio::test]
#[serial_test::serial]
async fn the_ladder_never_returns_zero() {
    let Some((pool, _lock)) = skip_if_no_db(try_setup().await) else {
        return;
    };
    for bad in ["0", "0.0", "-1.5"] {
        sqlx::query("TRUNCATE exchange_rates RESTART IDENTITY CASCADE")
            .execute(&pool)
            .await
            .expect("truncate");
        seed_rate(&pool, bad, "api", 1).await;
        let r = sql_rate(&pool).await;
        assert!(r > Decimal::ZERO, "ladder returned {r} for stored {bad}");
        assert_eq!(latest_usd_mxn_rate_for_write(&pool).await, r);
    }
}
