//! Single owner of the USD↔MXN FX conversion rules: the shared SQL
//! fragments and the hard-fallback rate.
//!
//! These used to live as hand-synced copies in `services/tax.rs`,
//! `services/exchange_rate.rs`, `api/dashboard.rs`, `services/projections.rs`
//! and `services/sync.rs`; copies drifting apart is exactly how the historical
//! FX bugs happened (raw MXN summed as USD ≈ 18x off; native MXN balance
//! written to `balance_usd` ≈ 17x off). Add new FX rules HERE — never
//! re-inline a fragment or the fallback at a call site.

use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use sqlx::PgPool;

/// Hard fallback when `exchange_rates` holds no usable USD/MXN row — a
/// wrong-ish magnitude (off ~14%) beats the alternative it replaced
/// (treating native MXN as USD, off ~1750%). Only ever used when no rate
/// row exists at all; `api::dashboard::latest_usd_mxn_rate` deliberately
/// flags it `stale` so it can never pass for a live rate.
///
/// ⚠ The literal `20.0` tail inside the SQL constants below is this same
/// number spelled into SQL — if this rate ever changes, change them together.
pub const FX_FALLBACK_USD_MXN: f64 = 20.0;

/// [`FX_FALLBACK_USD_MXN`] as a `Decimal`, for Rust-side money math.
pub const FX_FALLBACK_USD_MXN_DEC: Decimal = dec!(20.0);

/// SQL scalar: the USD→MXN rate in effect on a transaction row's date.
/// Requires the enclosing query to alias `transactions` as `t`; meant to be
/// wrapped in `CROSS JOIN LATERAL (SELECT {..} AS rate) fx`.
///
/// Lookup rule (mirrors sync.rs `lookup_usd_fx_rate`, the same rule the lot
/// FX columns were stamped with):
///   1. the latest stored `exchange_rates` row dated on-or-before `t.date`
///      (`recorded_at < t.date + 1 day` so same-day timestamps count);
///   2. else the latest stored USD→MXN rate of any date (fresh FX history
///      that starts after old imported statements);
///   3. else a hard 20.0 ballpark — wrong-ish magnitude beats the old
///      behavior of summing raw MXN and USD amounts together, which was off
///      ~18x by construction. Zero/negative stored rates are skipped so a
///      bad row can never divide-by-zero a sum into NULL.
pub(crate) const USD_MXN_ROW_RATE_SQL: &str = r#"COALESCE(
    (SELECT rate FROM exchange_rates
      WHERE base_currency = 'USD' AND target_currency = 'MXN'
        AND rate > 0
        AND recorded_at < (t.date + INTERVAL '1 day')
      ORDER BY recorded_at DESC LIMIT 1),
    (SELECT rate FROM exchange_rates
      WHERE base_currency = 'USD' AND target_currency = 'MXN'
        AND rate > 0
      ORDER BY recorded_at DESC LIMIT 1),
    20.0
)"#;

/// SQL expressions converting `t.amount` to USD / MXN using `fx.rate` (the
/// LATERAL-projected `USD_MXN_ROW_RATE_SQL`). Currencies other than MXN are
/// treated as USD-equivalent (fx = 1) — the same "trust the native amount"
/// stance sync.rs takes for unknown currencies.
pub(crate) const AMOUNT_USD_SQL: &str =
    "(CASE WHEN UPPER(t.currency) = 'MXN' THEN t.amount / fx.rate ELSE t.amount END)";
pub(crate) const AMOUNT_MXN_SQL: &str =
    "(CASE WHEN UPPER(t.currency) = 'MXN' THEN t.amount ELSE t.amount * fx.rate END)";

/// SQL scalar: the USD→MXN rate to convert a *present-day* balance with.
/// Always resolves to a positive number, so a caller can divide by it
/// unconditionally.
///
/// Ladder, matching `api::dashboard::latest_usd_mxn_rate` (the reader every
/// dashboard endpoint uses) so writes and reads can't disagree:
///   1. a user-entered `manual` override — a corrected rate must outrank a
///      bad upstream fetch;
///   2. else the freshest stored rate;
///   3. else the hard fallback.
///
/// `rate > 0` on both queries: a zero row must be skipped, not selected.
///
/// WHY this exists as a shared constant: every `balance_usd` writer used to
/// inline its own `ORDER BY recorded_at DESC LIMIT 1` and then, when that
/// came back NULL or zero, fall through to `ELSE <native balance>` — writing
/// a raw MXN figure into the USD column. A 400,000 MXN account then lands in
/// net worth as $400,000 instead of ~$22,900, and because the snapshot cron
/// is `ON CONFLICT DO NOTHING` and the chart carries values forward, that
/// spike sticks. The fallback rate is off by ~14%; the fallback it replaced
/// was off by ~1750%.
pub const LATEST_USD_MXN_RATE_SQL: &str = r#"COALESCE(
    (SELECT rate FROM exchange_rates
      WHERE base_currency = 'USD' AND target_currency = 'MXN'
        AND rate > 0 AND source = 'manual'
      ORDER BY recorded_at DESC LIMIT 1),
    (SELECT rate FROM exchange_rates
      WHERE base_currency = 'USD' AND target_currency = 'MXN'
        AND rate > 0
      ORDER BY recorded_at DESC LIMIT 1),
    20.0
)"#;

/// Rust-side twin of [`LATEST_USD_MXN_RATE_SQL`], for writers that compute
/// `balance_usd` in Rust rather than in the INSERT. Implemented by running
/// the constant itself, so the two can never drift.
///
/// Guaranteed positive: callers divide by it without a zero check.
pub async fn latest_usd_mxn_rate_for_write(db: &PgPool) -> Decimal {
    sqlx::query_scalar::<_, Decimal>(&format!("SELECT {LATEST_USD_MXN_RATE_SQL}"))
        .fetch_one(db)
        .await
        .ok()
        .filter(|r| *r > Decimal::ZERO)
        .unwrap_or(FX_FALLBACK_USD_MXN_DEC)
}
