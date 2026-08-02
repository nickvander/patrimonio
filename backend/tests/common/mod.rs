//! Shared test helpers.
//!
//! Lives at `tests/common/mod.rs` (the `mod.rs` form, not
//! `tests/common.rs`) so cargo treats it as a sub-module of every
//! sibling `tests/*.rs` integration crate rather than as its own
//! test binary. Each test file declares `mod common;` to pull it
//! in.

// Shared harness + seed fixtures for the per-surface integration files that
// were split out of the old all-in-one dashboard_endpoints.rs. Compiled into
// every tests/*.rs binary (each declares `mod common;`), and each binary uses
// only a subset of the helpers — allow(dead_code) keeps the unused remainder
// from failing the clippy -D warnings gate in the binaries that don't.
#[allow(dead_code)]
pub mod fixtures;

use sqlx::{Connection, PgConnection};

/// Holds a Postgres advisory lock for the duration of one test.
///
/// Why this exists: the three integration test files
/// (`auth_endpoints`, `auth_recovery_totp`, `dashboard_endpoints`)
/// each compile into their own test binary. Cargo runs binaries in
/// parallel by default — and within each binary, while
/// `#[serial_test::serial]` serialises tests, that mutex is
/// process-local and doesn't coordinate across binaries.
///
/// All three binaries share a single `patrimonio_test` database and
/// TRUNCATE in setup. Without a cross-process lock, two binaries can
/// race: binary A starts a test, seeds data, runs queries; binary B
/// in parallel hits its own TRUNCATE and wipes A's seeded rows
/// mid-flight, causing random 500s on A's bootstrap or empty result
/// sets where seeded data was expected.
///
/// `pg_advisory_lock(N)` is session-scoped and global within a
/// database. By holding it on a dedicated (non-pooled) connection
/// for the lifetime of one test, every other test — regardless of
/// which binary — blocks on the same lock until we're done. The
/// connection's Drop closes the socket, Postgres detects the
/// disconnect, and the lock releases. The next waiter wakes up.
///
/// Magic key 0x70617472696D6F is ASCII "patrimo" packed into i64 —
/// deterministic and unlikely to collide with any other advisory
/// lock the application code might one day use.
pub struct TestLockGuard {
    // Underscore-prefixed because the connection's purpose is to
    // EXIST (and thus keep the PG session alive). We never run
    // queries through it again after acquire().
    _conn: PgConnection,
}

impl TestLockGuard {
    /// Block until this caller holds the global test lock.
    ///
    /// IMPORTANT: this is only reached once a `PATRIMONIO_TEST_DATABASE_URL`
    /// has been resolved, so a connection failure here means "a DB was
    /// configured but we couldn't reach/authenticate it" — NOT "no DB
    /// available". We therefore PANIC rather than returning `None`. Returning
    /// `None` (the old behaviour) made a wrong password — e.g. after the
    /// Postgres password rotation, with `scripts/test.sh` defaulting to the
    /// pre-rotation `patrimonio` — look identical to "no test DB", so every
    /// integration test silently skipped and the suite vacuously passed,
    /// shipping real SQL bugs (the FBAR + statement-continuity 500s) undetected.
    /// Skipping is decided earlier (when the env var is unset); once a URL is
    /// set, a bad connection must fail loudly.
    pub async fn acquire(database_url: &str) -> Option<Self> {
        let mut conn = PgConnection::connect(database_url)
            .await
            .unwrap_or_else(|e| {
                panic!(
                    "PATRIMONIO_TEST_DATABASE_URL is set but connecting to the test DB \
                 failed ({e}). Integration tests must NOT silently skip when a DB is \
                 configured — fix the URL/credentials (e.g. export the rotated \
                 POSTGRES_PASSWORD from .env; scripts/test.sh now does this)."
                )
            });
        // 0x70617472696D6F = "patrimo" — see struct docs.
        sqlx::query("SELECT pg_advisory_lock(0x70617472696D6F)")
            .execute(&mut conn)
            .await
            .expect("acquire the patrimonio_test advisory lock");
        Some(Self { _conn: conn })
    }
}
