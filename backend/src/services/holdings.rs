//! Shared holdings logic used by both the HTTP handlers (api/accounts.rs) and
//! the nightly price-refresh cron (main.rs). Kept here, rather than in the api
//! module, so the background task doesn't need an `AuthContext` — every
//! function is driven by a `PgPool` + ids.

use crate::services::benchmark;
use sqlx::PgPool;

/// Latest cached close for a symbol, after a best-effort (4-day-gated) Yahoo
/// refresh. Used by the on-demand handlers (add/refresh holding) where a stale
/// cached price is fine.
pub(crate) async fn latest_price(db: &PgPool, symbol: &str) -> Option<rust_decimal::Decimal> {
    // ensure_symbol_fresh refreshes from Yahoo when stale and tolerates a
    // network failure as long as some cached data already exists.
    let _ = benchmark::ensure_symbol_fresh(db, symbol, symbol).await;
    sqlx::query_scalar::<_, rust_decimal::Decimal>(
        "SELECT close FROM benchmark_prices WHERE symbol = $1 ORDER BY price_date DESC LIMIT 1",
    )
    .bind(symbol)
    .fetch_optional(db)
    .await
    .ok()
    .flatten()
}

/// Set a manual account's balance to the sum of its holdings (cash sleeve
/// included), then upsert today's balance snapshot. Called after any holding
/// add/remove/reprice.
pub(crate) async fn recompute_holding_balance(
    db: &PgPool,
    account_id: uuid::Uuid,
    user_id: uuid::Uuid,
) -> Result<(), sqlx::Error> {
    let total: Option<rust_decimal::Decimal> = sqlx::query_scalar(
        "SELECT COALESCE(SUM(value), 0) FROM holdings WHERE account_id = $1 AND user_id = $2",
    )
    .bind(account_id)
    .bind(user_id)
    .fetch_one(db)
    .await?;
    let total = total.unwrap_or_default();

    sqlx::query(
        "UPDATE accounts SET current_balance = $1, updated_at = NOW() WHERE id = $2 AND user_id = $3",
    )
    .bind(total)
    .bind(account_id)
    .bind(user_id)
    .execute(db)
    .await?;

    let currency: String = sqlx::query_scalar("SELECT currency FROM accounts WHERE id = $1")
        .bind(account_id)
        .fetch_one(db)
        .await?;
    let balance_usd = if currency == "MXN" {
        let rate: Option<rust_decimal::Decimal> = sqlx::query_scalar(
            "SELECT rate FROM exchange_rates WHERE base_currency='USD' AND target_currency='MXN' ORDER BY recorded_at DESC LIMIT 1",
        )
        .fetch_optional(db)
        .await?;
        match rate {
            Some(r) if !r.is_zero() => (total / r).round_dp(2),
            _ => total,
        }
    } else {
        total
    };

    sqlx::query(
        r#"
        INSERT INTO balance_snapshots (account_id, balance, as_of_date, currency, balance_usd, user_id)
        VALUES ($1, $2, CURRENT_DATE, $3, $4, $5)
        ON CONFLICT (account_id, as_of_date)
        DO UPDATE SET balance = EXCLUDED.balance, balance_usd = EXCLUDED.balance_usd, created_at = NOW()
        "#,
    )
    .bind(account_id)
    .bind(total)
    .bind(&currency)
    .bind(balance_usd)
    .bind(user_id)
    .execute(db)
    .await?;
    Ok(())
}

/// Outcome of a nightly refresh, for the cron log line.
#[derive(Debug, Default)]
pub struct RefreshSummary {
    pub accounts: usize,
    pub symbols_priced: usize,
}

/// Nightly: re-price every manual account's holdings from Yahoo and recompute
/// each account's balance. Runs across ALL users (no auth context) — each
/// (account, user) pair comes straight from the holdings rows.
///
/// Unlike the on-demand path, this FORCES a fresh fetch per symbol
/// (`refresh_yahoo`) rather than honouring the 4-day staleness gate, so a daily
/// run actually reflects each day's close. Cash-sleeve rows (holding_type
/// 'cash', fixed at 1.00) are skipped for pricing but still counted in the
/// balance recompute. Per-symbol failures are tolerated — the cached price is
/// kept and the sweep continues.
pub async fn refresh_all_prices(db: &PgPool) -> RefreshSummary {
    // (account, user) pairs with at least one priceable (non-cash) holding on
    // a MANUAL account. Plaid investment accounts are priced by Plaid sync, so
    // we leave them alone.
    let targets: Vec<(uuid::Uuid, uuid::Uuid)> = sqlx::query_as(
        r#"
        SELECT DISTINCT h.account_id, h.user_id
        FROM holdings h
        JOIN accounts a ON a.id = h.account_id
        JOIN institutions i ON i.id = a.institution_id
        WHERE i.integration_type = 'manual'
          AND COALESCE(h.holding_type, '') <> 'cash'
        "#,
    )
    .fetch_all(db)
    .await
    .unwrap_or_default();

    let mut summary = RefreshSummary::default();
    for (account_id, user_id) in &targets {
        let symbols: Vec<String> = sqlx::query_scalar(
            "SELECT DISTINCT symbol FROM holdings WHERE account_id = $1 AND user_id = $2 AND COALESCE(holding_type, '') <> 'cash'",
        )
        .bind(account_id)
        .bind(user_id)
        .fetch_all(db)
        .await
        .unwrap_or_default();

        for sym in &symbols {
            // Force today's quote; tolerate a per-symbol failure (keep cache).
            if let Err(e) = benchmark::refresh_yahoo(db, sym, sym).await {
                tracing::warn!("nightly price refresh: {sym} fetch failed: {e}");
                continue;
            }
            let price: Option<rust_decimal::Decimal> = sqlx::query_scalar(
                "SELECT close FROM benchmark_prices WHERE symbol = $1 ORDER BY price_date DESC LIMIT 1",
            )
            .bind(sym)
            .fetch_optional(db)
            .await
            .ok()
            .flatten();
            if let Some(p) = price {
                let _ = sqlx::query(
                    "UPDATE holdings SET price = $1, value = ROUND(quantity * $1, 2), updated_at = NOW() WHERE symbol = $2 AND account_id = $3 AND user_id = $4",
                )
                .bind(p)
                .bind(sym)
                .bind(account_id)
                .bind(user_id)
                .execute(db)
                .await;
                summary.symbols_priced += 1;
            }
        }
        let _ = recompute_holding_balance(db, *account_id, *user_id).await;
        summary.accounts += 1;
    }
    summary
}
