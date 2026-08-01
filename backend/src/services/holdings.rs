//! Shared holdings logic used by both the HTTP handlers (api/accounts.rs) and
//! the nightly price-refresh cron (main.rs). Kept here, rather than in the api
//! module, so the background task doesn't need an `AuthContext` — every
//! function is driven by a `PgPool` + ids.

use crate::services::benchmark;
use sqlx::PgPool;

/// Bond funds that don't self-identify: Plaid/imports type them 'etf' or
/// 'mutual fund', so without this list VBTLX and BND land in the equity band
/// and the allocation view shows zero bond exposure. Uppercase tickers.
const BOND_FUND_SYMBOLS: &[&str] = &[
    "BND", "AGG", "TLT", "IEF", "SHY", "BNDX", "VBTLX", "VBMFX", "VBILX", "FXNAX", "VGIT", "VGSH",
    "VGLT", "VCIT", "VCSH", "VTEB", "MUB", "LQD", "HYG", "JNK", "TIP", "VTIP", "GOVT", "BIV",
    "BSV", "BLV", "SCHZ",
];

/// Money-market funds — cash sleeves that arrive typed 'mutual fund'.
const MONEY_MARKET_SYMBOLS: &[&str] = &["SPAXX", "VMFXX", "SWVXX", "SPRXX", "FDRXX", "FDLXX"];

/// Canonical asset class for a holding (contract C2). Returns one of:
/// `equity | bonds | cash | crypto | real_estate | commodities | other`.
///
/// Display labels stay human elsewhere; FILTERING keys on this value, which
/// is what makes a 'mutual fund' bond fund (VBTLX) and 'etf' bond funds
/// (BND/TLT) land in the same Bonds band. Heuristics run in order —
/// holding_type first (most authoritative when it's specific), then the
/// known-symbol sets, then name matching, then the equity default for the
/// generic instrument-shaped types.
pub(crate) fn classify_asset(holding_type: &str, symbol: &str, name: &str) -> &'static str {
    let ht = holding_type.trim().to_lowercase();
    let sym = symbol.trim().to_uppercase();
    let name_l = name.to_lowercase();

    // Bonds: explicit type, known fund ticker, or a bond-shaped name.
    // 'fixed income' is Plaid's spelling of the bonds holding type.
    if ht == "bonds" || ht == "bond" || ht == "fixed income" || ht == "fixed_income" {
        return "bonds";
    }
    if BOND_FUND_SYMBOLS.contains(&sym.as_str()) {
        return "bonds";
    }
    if ["bond", "treasur", "fixed income", "tips", "gnma"]
        .iter()
        .any(|kw| name_l.contains(kw))
    {
        return "bonds";
    }

    // Cash: cash sleeves, money-market funds, and Plaid's `CUR:XXX`
    // brokerage-cash pseudo-symbols (see services/twr.rs).
    if ht == "cash"
        || sym.starts_with("CUR:")
        || MONEY_MARKET_SYMBOLS.contains(&sym.as_str())
        || name_l.contains("money market")
    {
        return "cash";
    }

    if ht == "crypto" || ht == "cryptocurrency" {
        return "crypto";
    }
    if ht == "real estate" || ht == "real_estate" || ht == "reit" {
        return "real_estate";
    }
    if ht == "commodity" || ht == "commodities" {
        return "commodities";
    }

    // The generic instrument-shaped types (and the untyped default) are
    // equity once nothing above matched; anything more exotic
    // ('derivative', 'loan', …) is honestly 'other'.
    match ht.as_str() {
        "" | "equity" | "etf" | "mutual fund" | "mutual_fund" | "stock" => "equity",
        _ => "other",
    }
}

/// The canonical asset-class keys `classify_asset` can return — also the only
/// values the override endpoint (round 3) accepts, matching the CHECK
/// constraint on `asset_class_overrides`.
pub(crate) const ASSET_CLASSES: &[&str] = &[
    "equity",
    "bonds",
    "cash",
    "crypto",
    "real_estate",
    "commodities",
    "other",
];

/// Round 3: the user's asset-class overrides, keyed `UPPER(symbol)` →
/// canonical class. One indexed PK-range lookup; handlers fetch this ONCE per
/// request and thread it through [`effective_asset_class`]. Empty on error —
/// a failed fetch degrades to the heuristic, never a 500.
pub(crate) async fn fetch_asset_class_overrides(
    db: &PgPool,
    user_id: uuid::Uuid,
) -> std::collections::HashMap<String, String> {
    sqlx::query_as::<_, (String, String)>(
        "SELECT symbol, asset_class FROM asset_class_overrides WHERE user_id = $1",
    )
    .bind(user_id)
    .fetch_all(db)
    .await
    .unwrap_or_default()
    .into_iter()
    .collect()
}

/// Round 3 precedence: a per-(user, symbol) override wins over the heuristic;
/// otherwise fall through to [`classify_asset`] unchanged. Overrides are
/// stored normalized `UPPER(TRIM(symbol))`, so the lookup normalizes the same
/// way.
pub(crate) fn effective_asset_class(
    overrides: &std::collections::HashMap<String, String>,
    holding_type: &str,
    symbol: &str,
    name: &str,
) -> String {
    overrides
        .get(&symbol.trim().to_uppercase())
        .cloned()
        .unwrap_or_else(|| classify_asset(holding_type, symbol, name).to_string())
}

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
    // Soft-deleted rows (round 3 undo window) are excluded — this is what
    // makes the account balance drop the moment a holding is deleted.
    let total: Option<rust_decimal::Decimal> = sqlx::query_scalar(
        "SELECT COALESCE(SUM(value), 0) FROM holdings WHERE account_id = $1 AND user_id = $2 AND deleted_at IS NULL",
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
    // Shared rate ladder (always positive) — the old inline lookup fell back
    // to the native total when no usable row existed, writing raw MXN into
    // balance_usd.
    let balance_usd = if currency == "MXN" {
        let rate = crate::services::exchange_rate::latest_usd_mxn_rate_for_write(db).await;
        (total / rate).round_dp(2)
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
          AND h.deleted_at IS NULL
        "#,
    )
    .fetch_all(db)
    .await
    .unwrap_or_default();

    let mut summary = RefreshSummary::default();
    for (account_id, user_id) in &targets {
        // Don't re-price soft-deleted ghosts.
        let symbols: Vec<String> = sqlx::query_scalar(
            "SELECT DISTINCT symbol FROM holdings WHERE account_id = $1 AND user_id = $2 AND COALESCE(holding_type, '') <> 'cash' AND deleted_at IS NULL",
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

#[cfg(test)]
mod tests {
    use super::{classify_asset, effective_asset_class};
    use std::collections::HashMap;

    /// Round 3: an override outranks the heuristic; a missing override falls
    /// through to `classify_asset` unchanged (clearing = removing the map
    /// entry, so the same call reverts); lookups normalize UPPER(TRIM).
    #[test]
    fn override_wins_and_clear_reverts_to_heuristic() {
        let mut overrides: HashMap<String, String> = HashMap::new();
        overrides.insert("VBTLX".to_string(), "other".to_string());

        // Override wins even though the heuristic says bonds.
        assert_eq!(
            effective_asset_class(&overrides, "mutual fund", "VBTLX", "Vanguard Total Bond"),
            "other"
        );
        // Lookup is UPPER(TRIM)-normalized like the write side.
        assert_eq!(
            effective_asset_class(&overrides, "mutual fund", " vbtlx ", "Vanguard Total Bond"),
            "other"
        );
        // Non-overridden symbols are byte-identical to the heuristic (C2).
        assert_eq!(
            effective_asset_class(&overrides, "etf", "BND", "Vanguard Total Bond Market ETF"),
            classify_asset("etf", "BND", "Vanguard Total Bond Market ETF")
        );

        // Clearing the override reverts to the heuristic.
        overrides.remove("VBTLX");
        assert_eq!(
            effective_asset_class(&overrides, "mutual fund", "VBTLX", "Vanguard Total Bond"),
            "bonds"
        );
    }

    /// Every value the override endpoint may store is a canonical class key.
    #[test]
    fn asset_classes_list_matches_classifier_outputs() {
        for class in super::ASSET_CLASSES {
            assert!(matches!(
                *class,
                "equity" | "bonds" | "cash" | "crypto" | "real_estate" | "commodities" | "other"
            ));
        }
        assert_eq!(super::ASSET_CLASSES.len(), 7);
    }

    #[test]
    fn bond_funds_classify_as_bonds_regardless_of_holding_type() {
        // The prod repro: the only bond exposure is a 'mutual fund' (VBTLX)
        // and two 'etf's (BND, TLT) — the type column alone puts all three
        // in equity.
        assert_eq!(
            classify_asset(
                "mutual fund",
                "VBTLX",
                "Vanguard Total Bond Market Index Fund"
            ),
            "bonds"
        );
        assert_eq!(
            classify_asset("etf", "BND", "Vanguard Total Bond Market ETF"),
            "bonds"
        );
        assert_eq!(
            classify_asset("etf", "TLT", "iShares 20+ Year Treasury Bond ETF"),
            "bonds"
        );
        // Explicit type wins even with no recognizable symbol/name.
        assert_eq!(classify_asset("bonds", "XYZ", "Some Fund"), "bonds");
        assert_eq!(classify_asset("fixed income", "912828XY", "Note"), "bonds");
        // Name-only match (unknown ticker, generic type), case-insensitive.
        assert_eq!(
            classify_asset("mutual fund", "ZZBOND", "Corporate Bond Ladder 2030"),
            "bonds"
        );
        assert_eq!(
            classify_asset("etf", "SCHP", "Schwab U.S. TIPS ETF"),
            "bonds"
        );
        assert_eq!(
            classify_asset("", "T2026", "US Treasury Note 4.25% 2026"),
            "bonds"
        );
    }

    #[test]
    fn cash_sleeves_and_pseudo_symbols_classify_as_cash() {
        assert_eq!(classify_asset("cash", "CASH", "Cash sleeve"), "cash");
        // Plaid brokerage-cash pseudo-symbols.
        assert_eq!(classify_asset("", "CUR:USD", "US Dollar"), "cash");
        assert_eq!(classify_asset("equity", "cur:mxn", "Mexican Peso"), "cash");
        // Money-market funds arrive typed 'mutual fund'.
        assert_eq!(
            classify_asset("mutual fund", "SPAXX", "Fidelity Government Money Market"),
            "cash"
        );
        assert_eq!(
            classify_asset("mutual fund", "VMFXX", "Vanguard Federal Money Market Fund"),
            "cash"
        );
        assert_eq!(
            classify_asset("etf", "XX123", "Premier Money Market Portfolio"),
            "cash"
        );
    }

    #[test]
    fn remaining_types_map_to_their_canonical_keys() {
        assert_eq!(classify_asset("crypto", "BTC", "Bitcoin"), "crypto");
        assert_eq!(
            classify_asset("cryptocurrency", "ETH", "Ethereum"),
            "crypto"
        );
        assert_eq!(
            classify_asset("real estate", "VNQ2", "Real Estate Holding"),
            "real_estate"
        );
        assert_eq!(
            classify_asset("commodities", "GLD2", "Gold Trust"),
            "commodities"
        );
        // NULL/'' and the generic instrument types default to equity.
        assert_eq!(classify_asset("", "AAPL", "Apple Inc"), "equity");
        assert_eq!(classify_asset("equity", "NVDA", "NVIDIA Corp"), "equity");
        assert_eq!(
            classify_asset("etf", "VTI", "Vanguard Total Stock Market ETF"),
            "equity"
        );
        assert_eq!(
            classify_asset("mutual fund", "FXAIX", "Fidelity 500 Index Fund"),
            "equity"
        );
        // 401k trust units with no symbol and an opaque name: equity default.
        assert_eq!(
            classify_asset("", "", "Vanguard Target Retirement 2045 Trust"),
            "equity"
        );
        // Exotic types are honestly 'other'.
        assert_eq!(
            classify_asset("derivative", "SPX260918C", "SPX Call"),
            "other"
        );
        assert_eq!(classify_asset("loan", "", "Private note"), "other");
    }
}
