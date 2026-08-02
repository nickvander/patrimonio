use axum::{
    extract::{Extension, State},
    Json,
};
use serde::Serialize;
use sqlx::Row;
use std::collections::HashMap;

use crate::api::middleware::AuthContext;
use crate::AppState;

use super::*;

/// Human display label for a canonical asset-class key (contract C2). The
/// frontend renders this; FILTERING keys on the canonical value itself.
fn asset_class_label(key: &str) -> &'static str {
    match key {
        "equity" => "Stocks & funds",
        "bonds" => "Bonds",
        "cash" => "Cash",
        "crypto" => "Crypto",
        "real_estate" => "Real estate",
        "commodities" => "Commodities",
        // Contract C-G: investment-category account balances with no holdings
        // rows — real value the asset-class view would otherwise omit, but
        // with no per-holding detail to classify or filter to.
        "unclassified" => "Unclassified",
        _ => "Other",
    }
}

/// Asset allocation by category and sub-category, scoped to caller.
///
/// Classification happens in Rust via `classify_asset` (contract C2) rather
/// than on the raw `holding_type` in SQL: the type column alone puts a
/// 'mutual fund' bond fund (VBTLX) and 'etf' bond funds (BND/TLT) in the
/// equity band, so a user whose whole bond exposure is funds sees no Bonds
/// band at all. The cash/crypto accounts-union rows (bank balances have no
/// holdings rows) are tagged with their canonical class directly.
pub(super) async fn asset_allocation(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<AllocationEntry>> {
    // Shared FX path (manual-override precedence + missing/stale policy in
    // one place) — this handler used to run its own inline query with a
    // silent `.unwrap_or(20.0)` fallback that the holdings endpoint had
    // already dropped, so the two portfolio surfaces could value the same
    // MXN balance at different rates.
    let fx_rate = latest_usd_mxn_rate(&state.db).await.rate;

    let rows = sqlx::query(
        r#"
        SELECT kind, holding_type, symbol, name, sub_category, value_usd, qty
        FROM (
            SELECT 'holding' as kind,
                   holding_type,
                   symbol,
                   name,
                   CASE
                       WHEN symbol IS NULL THEN name
                       WHEN LENGTH(symbol) > 8 OR (symbol <> UPPER(symbol) AND LENGTH(symbol) > 4)
                            THEN COALESCE(NULLIF(name, ''), symbol)
                       ELSE symbol
                   END as sub_category,
                   CASE
                       WHEN currency = 'MXN' THEN value / $1::numeric
                       ELSE value
                   END as value_usd,
                   COALESCE(quantity, 0)::numeric as qty
            FROM holdings h
            WHERE user_id = $2
              AND h.deleted_at IS NULL
              AND EXISTS (SELECT 1 FROM accounts a
                          WHERE a.id = h.account_id AND a.archived_at IS NULL)
            UNION ALL
            SELECT 'cash' as kind,
                   NULL as holding_type,
                   NULL as symbol,
                   name,
                   name as sub_category,
                   CASE
                       WHEN currency = 'MXN' THEN current_balance / $1::numeric
                       ELSE current_balance
                   END as value_usd,
                   0::numeric as qty
            FROM accounts
            WHERE account_type IN ('checking', 'savings', 'cash', 'cash management', 'cd', 'money market')
              AND user_id = $2
              AND archived_at IS NULL
            UNION ALL
            SELECT 'crypto' as kind,
                   NULL as holding_type,
                   NULL as symbol,
                   name,
                   name as sub_category,
                   CASE
                       WHEN currency = 'MXN' THEN current_balance / $1::numeric
                       ELSE current_balance
                   END as value_usd,
                   COALESCE(crypto_amount, 0)::numeric as qty
            FROM accounts
            WHERE account_type IN ('crypto')
              AND user_id = $2
              AND archived_at IS NULL
            UNION ALL
            -- Contract C-G: active investment-category accounts with NO
            -- holdings rows (e.g. a CETES account tracked by balance only).
            -- Surfacing the balance as an 'unclassified' band reconciles the
            -- asset-class view with net worth; accounts WITH holdings are
            -- covered by the holdings branch and never double-counted here.
            -- An UNAMBIGUOUS account type maps straight to its asset class:
            -- 'bonds' (CETES Directo — literally Mexican treasury bills) is
            -- bonds, full stop; leaving it 'unclassified' skewed the Bonds
            -- target to a false "on target" and showed an impossible
            -- "classify these holdings" nudge. Ambiguous types ('brokerage',
            -- 'ira', …) could hold anything and stay unclassified.
            SELECT CASE WHEN account_type = 'bonds' THEN 'bonds'
                        ELSE 'unclassified' END as kind,
                   NULL as holding_type,
                   NULL as symbol,
                   name,
                   name as sub_category,
                   CASE
                       WHEN currency = 'MXN' THEN current_balance / $1::numeric
                       ELSE current_balance
                   END as value_usd,
                   0::numeric as qty
            FROM accounts
            WHERE account_type IN ('brokerage', '401k', '403b', '457b', 'ira', 'roth',
                                   'roth 401k', 'hsa', '529', 'pension', 'investment', 'bonds')
              AND user_id = $2
              AND archived_at IS NULL
              -- An account whose only holding is soft-deleted correctly
              -- becomes an unclassified band for the undo window.
              AND NOT EXISTS (SELECT 1 FROM holdings h
                              WHERE h.account_id = accounts.id AND h.deleted_at IS NULL)
        ) sub
        "#
    )
    .bind(fx_rate)
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    // Round 3 (C3-A): the user's overrides, fetched ONCE per request — the
    // same precedence the holdings endpoint applies, so a band's key always
    // matches the rows it filters to.
    let overrides =
        crate::services::holdings::fetch_asset_class_overrides(&state.db, ctx.user_id).await;

    // Classify each row, then group by (canonical class, sub-category). A
    // HashMap keyed on both keeps the same grouping the old SQL GROUP BY
    // gave, with the class computed in Rust.
    let mut grouped: HashMap<(String, String), (f64, f64)> = HashMap::new();
    for r in &rows {
        let kind: String = r.try_get("kind").unwrap_or_default();
        let value: f64 = r
            .try_get::<rust_decimal::Decimal, _>("value_usd")
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
            .unwrap_or(0.0);
        let qty: f64 = r
            .try_get::<rust_decimal::Decimal, _>("qty")
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
            .unwrap_or(0.0);
        let sub_category: String = r
            .try_get::<Option<String>, _>("sub_category")
            .ok()
            .flatten()
            .unwrap_or_else(|| "Unknown".to_string());

        // Accounts-union rows (bank cash, crypto-by-balance) carry their
        // class in `kind`; holdings rows go through the shared classifier
        // (override-aware, C3-A).
        let asset_class: String = match kind.as_str() {
            "cash" => "cash".to_string(),
            "crypto" => "crypto".to_string(),
            // Balance-only account whose type IS an asset class (C-G, e.g.
            // account_type='bonds') — classified in SQL, no holdings row to
            // run through the classifier.
            "bonds" => "bonds".to_string(),
            "unclassified" => "unclassified".to_string(),
            _ => {
                let holding_type: String = r
                    .try_get::<Option<String>, _>("holding_type")
                    .ok()
                    .flatten()
                    .unwrap_or_default();
                let symbol: String = r
                    .try_get::<Option<String>, _>("symbol")
                    .ok()
                    .flatten()
                    .unwrap_or_default();
                let name: String = r
                    .try_get::<Option<String>, _>("name")
                    .ok()
                    .flatten()
                    .unwrap_or_default();
                crate::services::holdings::effective_asset_class(
                    &overrides,
                    &holding_type,
                    &symbol,
                    &name,
                )
            }
        };

        let slot = grouped
            .entry((asset_class, sub_category))
            .or_insert((0.0, 0.0));
        slot.0 += value;
        slot.1 += qty;
    }

    let mut entries: Vec<AllocationEntry> = grouped
        .into_iter()
        .map(
            |((asset_class, sub_category), (value, quantity))| AllocationEntry {
                category: asset_class_label(&asset_class).to_string(),
                asset_class,
                sub_category,
                value,
                quantity,
            },
        )
        .collect();
    entries.sort_by(|a, b| {
        b.value
            .partial_cmp(&a.value)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    Json(entries)
}

#[derive(Serialize)]
pub(super) struct AllocationEntry {
    /// Human display label ("Bonds", "Stocks & funds") for the band.
    category: String,
    /// Canonical machine key (contract C2) the band filters on:
    /// equity|bonds|cash|crypto|real_estate|commodities|other.
    asset_class: String,
    sub_category: String,
    value: f64,
    /// Total share count for holdings (0 for cash and crypto-by-value rows).
    quantity: f64,
}
