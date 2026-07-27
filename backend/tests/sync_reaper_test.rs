//! Regression tests for the stale-`syncing` reaper.
//!
//! The bug: `sync_status = 'syncing'` had nothing to age it off. A sync task
//! is detached, so it dies with the process — a restart mid-sync left the row
//! stuck in 'syncing' forever, the Settings card spun with no error, and the
//! only escape was a manual re-sync. A run that wedged on a hung upstream call
//! did the same without any restart.
//!
//! Two reap modes, and the distinction matters: at boot ANY 'syncing' row is
//! stale by definition (a run cannot outlive the process), whereas the
//! periodic watchdog must only take rows that have genuinely aged out, or it
//! would cancel healthy in-flight syncs.
//!
//! Needs a real Postgres via `PATRIMONIO_TEST_DATABASE_URL`; unset prints a
//! skip note, set-but-unreachable PANICS (see tests/common/mod.rs).

use sqlx::postgres::PgPoolOptions;
use sqlx::{PgPool, Row};
use uuid::Uuid;

use patrimonio::services::sync::reap_stale_syncs;

mod common;
use common::TestLockGuard;

const TEST_DB_VAR: &str = "PATRIMONIO_TEST_DATABASE_URL";

async fn try_setup() -> Option<(PgPool, Uuid, TestLockGuard)> {
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

    sqlx::query(
        "TRUNCATE transactions, balance_snapshots, accounts, institutions, \
         user_sessions, app_settings, users RESTART IDENTITY CASCADE",
    )
    .execute(&pool)
    .await
    .expect("truncate reaper tables");

    let user_id: Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, email, password_hash) \
         VALUES ('reaper', 'reaper@example.com', 'doesnt-matter') RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .expect("seed user");

    Some((pool, user_id, lock))
}

/// Insert an institution in `status`, optionally with `sync_started_at` set to
/// `age_minutes` ago (None leaves it NULL, as an older binary would).
async fn seed_inst(
    pool: &PgPool,
    user_id: Uuid,
    name: &str,
    status: &str,
    age_minutes: Option<i64>,
) -> Uuid {
    let started = age_minutes.map(|m| format!("{m} minutes"));
    sqlx::query_scalar(
        "INSERT INTO institutions \
           (name, institution_type, country, integration_type, sync_status, user_id, sync_started_at) \
         VALUES ($1, 'bank', 'US', 'plaid', $2, $3, \
                 CASE WHEN $4::text IS NULL THEN NULL ELSE NOW() - $4::interval END) \
         RETURNING id",
    )
    .bind(name)
    .bind(status)
    .bind(user_id)
    .bind(started)
    .fetch_one(pool)
    .await
    .expect("seed institution")
}

async fn status_of(pool: &PgPool, id: Uuid) -> (String, Option<String>, bool) {
    let row = sqlx::query(
        "SELECT sync_status, last_sync_error, sync_started_at IS NULL AS cleared \
         FROM institutions WHERE id = $1",
    )
    .bind(id)
    .fetch_one(pool)
    .await
    .expect("read institution");
    (
        row.get::<Option<String>, _>("sync_status").unwrap_or_default(),
        row.get("last_sync_error"),
        row.get("cleared"),
    )
}

#[tokio::test]
async fn boot_reap_clears_every_syncing_row_regardless_of_age() {
    let Some((pool, user_id, _lock)) = try_setup().await else {
        eprintln!("SKIP: {TEST_DB_VAR} not set");
        return;
    };

    // The reported case: the process restarted seconds into a sync. Age is
    // irrelevant — the task that would have finished it no longer exists.
    let fresh = seed_inst(&pool, user_id, "Fresh", "syncing", Some(0)).await;
    // Stamped by a binary from before sync_started_at existed.
    let legacy = seed_inst(&pool, user_id, "Legacy", "syncing", None).await;
    // Must be left alone: not syncing.
    let idle = seed_inst(&pool, user_id, "Idle", "active", None).await;

    let n = reap_stale_syncs(&pool, true).await.expect("boot reap");
    assert_eq!(n, 2, "both syncing rows reaped, the idle one untouched");

    for (id, label) in [(fresh, "fresh"), (legacy, "legacy")] {
        let (status, err, cleared) = status_of(&pool, id).await;
        assert_eq!(status, "error", "{label} left in a terminal state");
        assert!(
            err.unwrap_or_default().contains("restarted"),
            "{label} explains itself to the user"
        );
        assert!(cleared, "{label} start stamp cleared");
    }

    let (status, _, _) = status_of(&pool, idle).await;
    assert_eq!(status, "active", "a non-syncing row is never touched");
}

#[tokio::test]
async fn watchdog_reaps_only_rows_that_have_aged_out() {
    let Some((pool, user_id, _lock)) = try_setup().await else {
        eprintln!("SKIP: {TEST_DB_VAR} not set");
        return;
    };

    // Wedged for well over the 30-minute threshold.
    let wedged = seed_inst(&pool, user_id, "Wedged", "syncing", Some(45)).await;
    // Genuinely in flight — a big Plaid backfill. Cancelling this would be a
    // regression in the opposite direction.
    let healthy = seed_inst(&pool, user_id, "Healthy", "syncing", Some(2)).await;
    // NULL stamp: a run that may not have stamped yet. The age-based pass has
    // no evidence it is stale, so it must abstain (boot reap covers it).
    let unstamped = seed_inst(&pool, user_id, "Unstamped", "syncing", None).await;

    let n = reap_stale_syncs(&pool, false).await.expect("watchdog reap");
    assert_eq!(n, 1, "only the aged-out row is reaped");

    let (status, err, cleared) = status_of(&pool, wedged).await;
    assert_eq!(status, "error");
    assert!(err.unwrap_or_default().contains("stopped responding"));
    assert!(cleared);

    for (id, label) in [(healthy, "healthy"), (unstamped, "unstamped")] {
        let (status, _, _) = status_of(&pool, id).await;
        assert_eq!(status, "syncing", "{label} sync left running");
    }
}

#[tokio::test]
async fn reaping_is_idempotent_and_quiet_when_nothing_is_stuck() {
    let Some((pool, user_id, _lock)) = try_setup().await else {
        eprintln!("SKIP: {TEST_DB_VAR} not set");
        return;
    };

    seed_inst(&pool, user_id, "Idle", "active", None).await;

    assert_eq!(reap_stale_syncs(&pool, true).await.expect("boot"), 0);
    assert_eq!(reap_stale_syncs(&pool, false).await.expect("watchdog"), 0);

    // And a second boot reap after one already ran finds nothing left.
    seed_inst(&pool, user_id, "Stuck", "syncing", Some(90)).await;
    assert_eq!(reap_stale_syncs(&pool, true).await.expect("first"), 1);
    assert_eq!(
        reap_stale_syncs(&pool, true).await.expect("second"),
        0,
        "already-reaped rows are not reaped twice"
    );
}
