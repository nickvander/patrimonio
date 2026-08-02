use axum::{
    extract::{Extension, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use std::collections::HashMap;
use tracing::error;

use crate::api::middleware::AuthContext;
use crate::AppState;

use super::*;

/// All investment holdings for this user across their accounts.
///
/// Each holding is reported in BOTH USD and MXN so a bi-national
/// investor can read their position either way without converting in
/// their head. When `holding_lots` rows exist for a holding, the cost
/// basis is computed by summing each lot's `qty * cost_per_unit`
/// converted at that lot's own `usd_fx_rate` — this is the proper
/// FX-aware basis. When no lots exist (today's default — the lot
/// table is forward-compat infrastructure; `services/sync.rs` doesn't
/// populate it yet) we fall back to `holdings.cost_basis` converted
/// at the current FX rate, which still produces the right number in
/// the native currency and a reasonable approximation in the other.
/// Fetch + decode every active-account holding row for `user_id`, with the
/// lots-aware dual-currency cost basis. Shared by the JSON handler and the
/// CSV exporter (contract C-E) so the two can never disagree on a row.
/// Day-change fields are left `None` here; the JSON handler fills them from
/// `benchmark_prices` afterwards (contract C-B).
async fn fetch_holdings_details(
    db: &sqlx::PgPool,
    user_id: uuid::Uuid,
    fx_usd_to_mxn: f64,
) -> Vec<HoldingDetail> {
    let rows = sqlx::query(
        r#"
        SELECT h.id, h.symbol, h.name, h.quantity, h.price, h.value,
               h.cost_basis, h.currency, h.holding_type, a.account_type,
               COALESCE(NULLIF(a.nickname, ''), a.name) as account_name,
               i.name as institution_name
        FROM holdings h
        JOIN accounts a ON h.account_id = a.id
        JOIN institutions i ON a.institution_id = i.id
        WHERE h.user_id = $1 AND a.archived_at IS NULL AND h.deleted_at IS NULL
        ORDER BY h.value DESC NULLS LAST
        "#,
    )
    .bind(user_id)
    .fetch_all(db)
    .await
    .unwrap_or_default();

    // Round 3 (C3-A): the user's asset-class overrides, fetched ONCE per
    // request and consulted per row below.
    let overrides = crate::services::holdings::fetch_asset_class_overrides(db, user_id).await;

    // Pull any lots for this user in one query, group by holding.
    // Filter zero-qty rows here — those are FIFO-depletion markers
    // (one per sell event) inserted to make re-syncs idempotent.
    // They have no owned shares, so they shouldn't appear in the
    // breakdown or contribute to cost basis.
    let lot_rows = sqlx::query(
        r#"
        SELECT holding_id, qty, cost_per_unit, currency, usd_fx_rate,
               acquired_at
        FROM holding_lots
        WHERE user_id = $1 AND qty > 0
        ORDER BY acquired_at ASC, id ASC
        "#,
    )
    .bind(user_id)
    .fetch_all(db)
    .await
    .unwrap_or_default();

    // Two parallel maps: one for the cost-basis computation (the
    // tuple form was already in use downstream), one for the
    // serialised lot breakdown surfaced to the frontend.
    let mut lots_by_holding: HashMap<uuid::Uuid, Vec<(f64, f64, String, f64)>> = HashMap::new();
    let mut lot_details_by_holding: HashMap<uuid::Uuid, Vec<HoldingLot>> = HashMap::new();
    for r in &lot_rows {
        let hid: uuid::Uuid = match r.try_get("holding_id") {
            Ok(v) => v,
            Err(_) => continue,
        };
        let qty: f64 = r
            .try_get::<rust_decimal::Decimal, _>("qty")
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
            .unwrap_or(0.0);
        let cpu: f64 = r
            .try_get::<rust_decimal::Decimal, _>("cost_per_unit")
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
            .unwrap_or(0.0);
        let ccy: String = r.try_get("currency").unwrap_or_else(|_| "USD".to_string());
        let fx: f64 = r
            .try_get::<rust_decimal::Decimal, _>("usd_fx_rate")
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(1.0))
            .unwrap_or(1.0);
        let acquired_at: String = r
            .try_get::<chrono::NaiveDate, _>("acquired_at")
            .map(|d| d.to_string())
            .unwrap_or_default();
        lots_by_holding
            .entry(hid)
            .or_default()
            .push((qty, cpu, ccy.clone(), fx));
        let native_cost = qty * cpu;
        let usd_cost = match ccy.as_str() {
            "USD" => native_cost,
            "MXN" => {
                if fx > 0.0 {
                    native_cost / fx
                } else {
                    native_cost
                }
            }
            _ => native_cost,
        };
        lot_details_by_holding
            .entry(hid)
            .or_default()
            .push(HoldingLot {
                acquired_at,
                qty,
                cost_per_unit: cpu,
                currency: ccy,
                usd_fx_rate: fx,
                native_cost,
                usd_cost,
            });
    }

    let to_usd = |amount: f64, ccy: &str| -> f64 {
        match ccy {
            "USD" => amount,
            "MXN" => amount / fx_usd_to_mxn,
            _ => amount, // unknown currency — treat as 1:1 to USD for now
        }
    };

    rows.iter()
        .map(|r| {
            let id: uuid::Uuid = r.try_get("id").unwrap_or_else(|_| uuid::Uuid::nil());
            let value: f64 = r
                .try_get::<rust_decimal::Decimal, _>("value")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0);
            // NULL cost_basis means the institution didn't report a
            // basis (Plaid omits it for many employer plans, statement
            // imports never have one). That is "unknown", which is NOT
            // the same as a true zero-cost position — so it stays
            // Option<f64> all the way to the JSON (null), never 0.0.
            let cost_basis_native: Option<f64> = r
                .try_get::<Option<rust_decimal::Decimal>, _>("cost_basis")
                .ok()
                .flatten()
                .map(|d| d.to_string().parse().unwrap_or(0.0));
            let currency: String = r.get("currency");

            // Cost basis in USD: prefer lots (FX-aware) when present;
            // fall back to current-FX conversion of the flat basis.
            // None when neither lots nor a flat basis exist.
            let cost_basis_usd: Option<f64> = if let Some(lots) = lots_by_holding.get(&id) {
                Some(
                    lots.iter()
                        .map(|(qty, cpu, ccy, fx)| {
                            let native = qty * cpu;
                            // Lot's currency may differ from holding's
                            // currency in edge cases (multi-currency
                            // brokerages); convert via the lot's recorded
                            // historical FX rate.
                            match ccy.as_str() {
                                "USD" => native,
                                "MXN" => {
                                    if *fx > 0.0 {
                                        native / fx
                                    } else {
                                        native / fx_usd_to_mxn
                                    }
                                }
                                _ => native,
                            }
                        })
                        .sum::<f64>(),
                )
            } else {
                cost_basis_native.map(|cb| to_usd(cb, &currency))
            };

            let value_usd = to_usd(value, &currency);
            let cost_basis_mxn = cost_basis_usd.map(|cb| cb * fx_usd_to_mxn);
            let value_mxn = value_usd * fx_usd_to_mxn;

            let symbol: String = r.get("symbol");
            let name: String = r.get("name");
            let holding_type: String = r.try_get::<String, _>("holding_type").unwrap_or_default();
            // Canonical asset class (contract C2) — the allocation endpoint
            // classifies with the same function, so a band's key always
            // matches the rows the band should filter to. A user override
            // (C3-A) outranks the heuristic in BOTH places.
            let asset_class = crate::services::holdings::effective_asset_class(
                &overrides,
                &holding_type,
                &symbol,
                &name,
            );

            HoldingDetail {
                symbol,
                name,
                quantity: r
                    .try_get::<rust_decimal::Decimal, _>("quantity")
                    .ok()
                    .map(|d| d.to_string().parse().unwrap_or(0.0))
                    .unwrap_or(0.0),
                price: r
                    .try_get::<rust_decimal::Decimal, _>("price")
                    .ok()
                    .map(|d| d.to_string().parse().unwrap_or(0.0))
                    .unwrap_or(0.0),
                value,
                cost_basis: cost_basis_native,
                gain_loss: cost_basis_native.map(|cb| value - cb),
                // Percent return is undefined both when the basis is
                // unknown and when it's a true zero-cost position
                // (division by zero) — null in either case.
                gain_loss_pct: cost_basis_native.and_then(|cb| {
                    if cb > 0.0 {
                        Some(((value - cb) / cb) * 100.0)
                    } else {
                        None
                    }
                }),
                value_usd,
                value_mxn,
                cost_basis_usd,
                cost_basis_mxn,
                gain_loss_usd: cost_basis_usd.map(|cb| value_usd - cb),
                gain_loss_mxn: cost_basis_mxn.map(|cb| value_mxn - cb),
                currency,
                holding_type,
                asset_class,
                account_type: r.try_get::<String, _>("account_type").unwrap_or_default(),
                account_name: r.get("account_name"),
                institution_name: r.get("institution_name"),
                // Filled by the JSON handler from `benchmark_prices` (C-B);
                // stays null for consumers that never compute it (CSV export).
                day_change_usd: None,
                day_change_pct: None,
                price_as_of: None,
                lots: lot_details_by_holding.remove(&id).unwrap_or_default(),
            }
        })
        .collect()
}

/// Day change for one holdings row, derived from its last two stored closes
/// (contract C-B). `closes` is the per-symbol result of [`latest_two_closes`]
/// — newest first. Returns `None` (all three JSON fields null, row excluded
/// from the totals + coverage numerator) for cash sleeves, symbols with fewer
/// than two stored closes, and stale series (latest close more than 7
/// calendar days before `today`).
struct RowDayChange {
    day_change_usd: f64,
    /// Percent (already ×100), native-currency-agnostic since the underlying
    /// ratio comes from the symbol's own close series.
    day_change_pct: f64,
    as_of: chrono::NaiveDate,
}

fn day_change_for_row(
    value_usd: f64,
    is_cash: bool,
    closes: Option<&[(chrono::NaiveDate, f64)]>,
    today: chrono::NaiveDate,
) -> Option<RowDayChange> {
    if is_cash {
        return None;
    }
    let closes = closes?;
    if closes.len() < 2 {
        return None;
    }
    let (d0, c0) = closes[0];
    let (_, c1) = closes[1];
    if today.signed_duration_since(d0) > chrono::Duration::days(7) {
        return None;
    }
    if c1 <= 0.0 {
        return None;
    }
    let pct = (c0 - c1) / c1;
    Some(RowDayChange {
        day_change_usd: value_usd * pct,
        day_change_pct: pct * 100.0,
        as_of: d0,
    })
}

/// Response-level day-change aggregates over the per-row results (C-B).
/// `rows` yields `(value_usd, day_change_usd, price_as_of)` per holding; a
/// row is "covered" when its day change is known.
struct DayChangeTotals {
    day_change_usd: Option<f64>,
    day_change_pct: Option<f64>,
    /// Σ value_usd of covered rows ÷ total value_usd × 100; 0 when none.
    coverage_pct: f64,
    /// Max covered close date (ISO), i.e. the freshest close the totals use.
    as_of: Option<String>,
}

fn day_change_totals<'a, I>(rows: I) -> DayChangeTotals
where
    I: Iterator<Item = (f64, Option<f64>, Option<&'a str>)>,
{
    let mut total_value = 0.0_f64;
    let mut covered_value = 0.0_f64;
    let mut prior_value = 0.0_f64;
    let mut change_sum = 0.0_f64;
    let mut any_covered = false;
    let mut as_of: Option<String> = None;
    for (value_usd, day_change_usd, price_as_of) in rows {
        total_value += value_usd;
        let Some(chg) = day_change_usd else { continue };
        any_covered = true;
        change_sum += chg;
        covered_value += value_usd;
        prior_value += value_usd - chg;
        if let Some(d) = price_as_of {
            if as_of.as_deref().is_none_or(|cur| d > cur) {
                as_of = Some(d.to_string());
            }
        }
    }
    DayChangeTotals {
        day_change_usd: any_covered.then_some(change_sum),
        day_change_pct: if any_covered && prior_value > 0.0 {
            Some(change_sum / prior_value * 100.0)
        } else {
            None
        },
        coverage_pct: if total_value > 0.0 {
            covered_value / total_value * 100.0
        } else {
            0.0
        },
        as_of,
    }
}

/// The two most recent stored closes per symbol (newest first) from
/// `benchmark_prices` — the C-B day-change data path. One query, no network:
/// the nightly refresh + TWR quote cache keep real tickers populated; opaque
/// symbols simply have no rows and degrade to null day changes.
async fn latest_two_closes(
    db: &sqlx::PgPool,
    symbols: &[String],
) -> HashMap<String, Vec<(chrono::NaiveDate, f64)>> {
    if symbols.is_empty() {
        return HashMap::new();
    }
    let rows = sqlx::query(
        r#"
        SELECT symbol, price_date, close
        FROM (
            SELECT symbol, price_date, close,
                   ROW_NUMBER() OVER (PARTITION BY symbol ORDER BY price_date DESC) AS rn
            FROM benchmark_prices
            WHERE symbol = ANY($1)
        ) ranked
        WHERE rn <= 2
        ORDER BY symbol ASC, price_date DESC
        "#,
    )
    .bind(symbols)
    .fetch_all(db)
    .await
    .unwrap_or_default();

    let mut by_symbol: HashMap<String, Vec<(chrono::NaiveDate, f64)>> = HashMap::new();
    for r in &rows {
        let (Ok(symbol), Ok(date)) = (
            r.try_get::<String, _>("symbol"),
            r.try_get::<chrono::NaiveDate, _>("price_date"),
        ) else {
            continue;
        };
        let close = r
            .try_get::<rust_decimal::Decimal, _>("close")
            .ok()
            .and_then(|d| d.to_string().parse::<f64>().ok())
            .unwrap_or(0.0);
        by_symbol.entry(symbol).or_default().push((date, close));
    }
    by_symbol
}

pub(super) async fn holdings(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<HoldingsResponse> {
    // FX rate + staleness flag (missing or >7 days old). Replaces the old
    // silent 20.0 fallback so MXN-converted portfolio figures can be badged.
    let fx_info = latest_usd_mxn_rate(&state.db).await;
    let fx_usd_to_mxn: f64 = fx_info.rate;
    let fx_stale = fx_info.stale;

    let mut holdings_list = fetch_holdings_details(&state.db, ctx.user_id, fx_usd_to_mxn).await;

    // C-B: day change between the last two STORED closes per symbol — one
    // query over `benchmark_prices`, never a live quote fan-out. Cash sleeves
    // and unresolvable symbols honestly stay null instead of pretending.
    let quote_symbols: Vec<String> = {
        let mut seen = std::collections::HashSet::new();
        holdings_list
            .iter()
            .filter(|h| h.holding_type != "cash" && h.asset_class != "cash")
            .filter(|h| !h.symbol.is_empty())
            .filter(|h| seen.insert(h.symbol.clone()))
            .map(|h| h.symbol.clone())
            .collect()
    };
    let closes_by_symbol = latest_two_closes(&state.db, &quote_symbols).await;
    let today = chrono::Utc::now().date_naive();
    for h in &mut holdings_list {
        let is_cash = h.holding_type == "cash" || h.asset_class == "cash";
        if let Some(rc) = day_change_for_row(
            h.value_usd,
            is_cash,
            closes_by_symbol.get(&h.symbol).map(|v| v.as_slice()),
            today,
        ) {
            h.day_change_usd = Some(rc.day_change_usd);
            h.day_change_pct = Some(rc.day_change_pct);
            h.price_as_of = Some(rc.as_of.to_string());
        }
    }
    let day_totals = day_change_totals(
        holdings_list
            .iter()
            .map(|h| (h.value_usd, h.day_change_usd, h.price_as_of.as_deref())),
    );

    // Total value covers EVERY holding; the gain/loss totals only
    // cover holdings with a KNOWN basis (numerator and denominator
    // alike), so one 401k with an unreported basis doesn't silently
    // drag the portfolio return toward zero.
    let total_value: f64 = holdings_list.iter().map(|h| h.value).sum();
    let total_value_usd: f64 = holdings_list.iter().map(|h| h.value_usd).sum();
    let total_value_mxn: f64 = holdings_list.iter().map(|h| h.value_mxn).sum();

    let total_cost: f64 = holdings_list.iter().filter_map(|h| h.cost_basis).sum();
    let known_value: f64 = holdings_list
        .iter()
        .filter(|h| h.cost_basis.is_some())
        .map(|h| h.value)
        .sum();
    let total_cost_usd: f64 = holdings_list.iter().filter_map(|h| h.cost_basis_usd).sum();
    let known_value_usd: f64 = holdings_list
        .iter()
        .filter(|h| h.cost_basis_usd.is_some())
        .map(|h| h.value_usd)
        .sum();
    let total_cost_mxn: f64 = holdings_list.iter().filter_map(|h| h.cost_basis_mxn).sum();
    let known_value_mxn: f64 = holdings_list
        .iter()
        .filter(|h| h.cost_basis_mxn.is_some())
        .map(|h| h.value_mxn)
        .sum();
    let holdings_without_basis = holdings_list
        .iter()
        .filter(|h| h.cost_basis.is_none() && h.cost_basis_usd.is_none())
        .count();

    Json(HoldingsResponse {
        total_value,
        total_cost_basis: total_cost,
        total_gain_loss: known_value - total_cost,
        total_gain_loss_pct: if total_cost > 0.0 {
            ((known_value - total_cost) / total_cost) * 100.0
        } else {
            0.0
        },
        total_value_usd,
        total_value_mxn,
        total_cost_basis_usd: total_cost_usd,
        total_cost_basis_mxn: total_cost_mxn,
        total_gain_loss_usd: known_value_usd - total_cost_usd,
        total_gain_loss_mxn: known_value_mxn - total_cost_mxn,
        holdings_without_basis,
        fx_rate_used: fx_usd_to_mxn,
        fx_stale,
        day_change_usd: day_totals.day_change_usd,
        day_change_pct: day_totals.day_change_pct,
        day_change_coverage_pct: day_totals.coverage_pct,
        day_change_as_of: day_totals.as_of,
        holdings: holdings_list,
    })
}

/// C-E: the holdings table as a CSV download. Reuses the JSON handler's row
/// builder (`fetch_holdings_details`) so counts and the lots-aware basis
/// match the endpoint exactly. Holdings are bounded (tens of rows), so the
/// body is assembled in memory — the streaming channel of the transactions
/// exporter buys nothing here while the lots map needs the whole set anyway.
pub(super) async fn export_holdings_csv(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Response {
    let fx_info = latest_usd_mxn_rate(&state.db).await;
    let list = fetch_holdings_details(&state.db, ctx.user_id, fx_info.rate).await;

    let today = chrono::Local::now().format("%Y-%m-%d").to_string();
    let filename = format!("patrimonio_holdings_{today}.csv");

    // Money (and %) fields serialize at 2dp: the raw f64 Display leaked
    // float noise like `3679.9999999999995` into spreadsheets. CSV-only —
    // the JSON endpoint keeps full precision.
    let money = |v: f64| format!("{v:.2}");
    let opt = |v: Option<f64>| v.map(|x| format!("{x:.2}")).unwrap_or_default();
    let mut csv = String::from(
        "symbol,name,account,institution,account_type,asset_class,quantity,price,currency,value,value_usd,cost_basis_usd,gain_loss_usd,gain_loss_pct\n",
    );
    for h in &list {
        csv.push_str(&format!(
            "{},{},{},{},{},{},{},{},{},{},{},{},{},{}\n",
            csv_field(&h.symbol),
            csv_field(&h.name),
            csv_field(&h.account_name),
            csv_field(&h.institution_name),
            csv_field(&h.account_type),
            csv_field(&h.asset_class),
            h.quantity,
            money(h.price),
            h.currency,
            money(h.value),
            money(h.value_usd),
            opt(h.cost_basis_usd),
            opt(h.gain_loss_usd),
            opt(h.gain_loss_pct),
        ));
    }
    csv_attachment_response(&filename, axum::body::Body::from(csv))
}

/// C-E: every active purchase lot as a CSV download. Same depletion-marker
/// filter (`qty > 0`) and USD-cost math as the JSON endpoint's nested lots.
pub(super) async fn export_lots_csv(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Response {
    let rows = sqlx::query(
        r#"
        SELECT h.symbol,
               COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name,
               l.acquired_at, l.qty, l.cost_per_unit, l.currency, l.usd_fx_rate
        FROM holding_lots l
        JOIN holdings h ON h.id = l.holding_id
        JOIN accounts a ON a.id = h.account_id
        WHERE l.user_id = $1 AND l.qty > 0 AND a.archived_at IS NULL
          AND h.deleted_at IS NULL
        ORDER BY h.symbol ASC, l.acquired_at ASC, l.id ASC
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let today = chrono::Local::now().format("%Y-%m-%d").to_string();
    let filename = format!("patrimonio_lots_{today}.csv");

    let mut csv = String::from("symbol,account,acquired_at,qty,cost_per_unit,currency,usd_cost\n");
    for r in &rows {
        let dec = |col: &str| -> f64 {
            r.try_get::<rust_decimal::Decimal, _>(col)
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0)
        };
        let qty = dec("qty");
        let cpu = dec("cost_per_unit");
        let fx = dec("usd_fx_rate");
        let currency: String = r.try_get("currency").unwrap_or_else(|_| "USD".to_string());
        let native_cost = qty * cpu;
        // Mirrors the HoldingLot::usd_cost conversion in the JSON handler.
        let usd_cost = match currency.as_str() {
            "USD" => native_cost,
            "MXN" => {
                if fx > 0.0 {
                    native_cost / fx
                } else {
                    native_cost
                }
            }
            _ => native_cost,
        };
        let acquired_at: String = r
            .try_get::<chrono::NaiveDate, _>("acquired_at")
            .map(|d| d.to_string())
            .unwrap_or_default();
        csv.push_str(&format!(
            // Money fields at 2dp — the qty*cpu/fx float math leaked
            // `.9999999999995`-style noise into the export. Quantity stays
            // full precision (fractional crypto/fund lots are meaningful).
            "{},{},{},{},{:.2},{},{:.2}\n",
            csv_field(&r.try_get::<String, _>("symbol").unwrap_or_default()),
            csv_field(&r.try_get::<String, _>("account_name").unwrap_or_default()),
            acquired_at,
            qty,
            cpu,
            currency,
            usd_cost,
        ));
    }
    csv_attachment_response(&filename, axum::body::Body::from(csv))
}

#[derive(Serialize)]
pub(super) struct HoldingsResponse {
    /// Totals in the holdings' native currencies summed naively.
    /// Useful when every holding shares one currency; meaningless
    /// when mixing USD + MXN positions, in which case the consumer
    /// should read `total_value_usd` / `total_value_mxn`.
    total_value: f64,
    /// Sum of cost bases over holdings whose basis is KNOWN. Holdings
    /// with an unknown basis (institution didn't report one — NULL in
    /// the DB, no lots) are excluded from `total_cost_basis` and from
    /// both sides of `total_gain_loss` / `total_gain_loss_pct`, while
    /// `total_value` still covers everything. See
    /// `holdings_without_basis` for how many were excluded.
    total_cost_basis: f64,
    total_gain_loss: f64,
    total_gain_loss_pct: f64,
    /// Dual-currency totals — each holding converted via current FX
    /// (or per-lot historical FX when `holding_lots` rows are
    /// available) and summed. Bi-national investors should display
    /// whichever side matches their reporting currency.
    total_value_usd: f64,
    total_value_mxn: f64,
    total_cost_basis_usd: f64,
    total_cost_basis_mxn: f64,
    total_gain_loss_usd: f64,
    total_gain_loss_mxn: f64,
    /// Number of holdings excluded from the gain/loss totals because
    /// no cost basis is available (lets the UI caveat the totals).
    holdings_without_basis: usize,
    /// USD->MXN rate used for the dual-currency (USD↔MXN) conversions above.
    fx_rate_used: f64,
    /// True when that FX rate is missing or older than 7 days — the MXN-side
    /// totals are approximate and should be flagged in the UI.
    fx_stale: bool,
    /// Contract C-B: portfolio day change summed over the COVERED rows (rows
    /// whose per-row `day_change_usd` is non-null). Null when no row is
    /// covered — the UI hides the "Today" pill rather than showing $0.
    day_change_usd: Option<f64>,
    /// Σ day change ÷ Σ prior-close value of covered rows × 100.
    day_change_pct: Option<f64>,
    /// Σ value_usd of covered rows ÷ total value_usd × 100 (0 when none) —
    /// lets the header pill carry an honest "covers N% of portfolio" note.
    day_change_coverage_pct: f64,
    /// Max covered close date (YYYY-MM-DD): the "as of" label for the pill.
    day_change_as_of: Option<String>,
    holdings: Vec<HoldingDetail>,
}

#[derive(Serialize)]
struct HoldingDetail {
    symbol: String,
    name: String,
    quantity: f64,
    price: f64,
    value: f64,
    /// None (JSON null) when the institution doesn't report a basis —
    /// e.g. Plaid employer plans, statement-imported holdings. Unknown
    /// is deliberately distinct from a true zero-cost position, which
    /// serialises as a real 0.0.
    cost_basis: Option<f64>,
    gain_loss: Option<f64>,
    /// None when the basis is unknown OR the position is zero-cost
    /// (percent return undefined).
    gain_loss_pct: Option<f64>,
    /// Per-holding dual-currency conversions. `value_usd` and
    /// `cost_basis_usd` always agree with the holding's native
    /// number when the security is USD-denominated; for MXN
    /// securities they're computed via current FX. The MXN side is
    /// always derivable from the USD side via current FX, but we
    /// pre-compute both so the frontend doesn't need the FX rate to
    /// render the row.
    value_usd: f64,
    value_mxn: f64,
    cost_basis_usd: Option<f64>,
    cost_basis_mxn: Option<f64>,
    gain_loss_usd: Option<f64>,
    gain_loss_mxn: Option<f64>,
    currency: String,
    holding_type: String,
    /// Canonical asset class (contract C2):
    /// equity|bonds|cash|crypto|real_estate|commodities|other. Derived from
    /// (holding_type, symbol, name) by `services::holdings::classify_asset`
    /// — same classifier as the allocation endpoint, so tapping an
    /// asset-class band filters to exactly the rows carrying its key.
    asset_class: String,
    /// Owning account's type (e.g. "401k", "brokerage") — lets the frontend
    /// filter the table when an account-type allocation band is tapped.
    account_type: String,
    account_name: String,
    institution_name: String,
    /// Contract C-B: change between the symbol's last two stored closes,
    /// applied to this row's USD value. All three stay null (real JSON
    /// nulls, no skip attrs) for cash sleeves, symbols with fewer than two
    /// stored closes, and closes older than 7 calendar days.
    day_change_usd: Option<f64>,
    day_change_pct: Option<f64>,
    /// Date of the latest stored close backing the day change (YYYY-MM-DD).
    price_as_of: Option<String>,
    /// Per-lot breakdown when `holding_lots` rows exist for this
    /// holding. Lets power users see WHY the FX-aware cost basis
    /// differs from the naive current-FX number — each lot carries
    /// the historical FX rate at acquisition. Empty for holdings
    /// that pre-date the lot-tracker (institutions not yet
    /// re-synced) or for non-investment rows.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    lots: Vec<HoldingLot>,
}

#[derive(Serialize)]
struct HoldingLot {
    /// Acquisition date (YYYY-MM-DD) of the lot. FIFO order is
    /// implied by the array order — the frontend renders them in
    /// acquired-first order.
    acquired_at: String,
    /// Lot quantity. Always > 0 for active lots; depletion markers
    /// (qty 0) are filtered out before this serialises.
    qty: f64,
    /// Native cost per unit (the share / unit price at acquisition).
    cost_per_unit: f64,
    /// Currency the cost is denominated in — same as the holding for
    /// homogeneous brokerages, can differ for multi-currency accounts.
    currency: String,
    /// USD↔native FX rate that was in effect on `acquired_at`. We
    /// snapshot this at lot creation so future FX moves don't
    /// retroactively shift historical cost basis.
    usd_fx_rate: f64,
    /// Convenience: qty × cost_per_unit (native).
    native_cost: f64,
    /// Convenience: native_cost ÷ usd_fx_rate (or = native_cost when
    /// the lot is already USD).
    usd_cost: f64,
}

// =====================================================================
// Instrument detail (contract C-A)
// =====================================================================

/// One account's share of the position, for the instrument sheet.
#[derive(Serialize)]
struct InstrumentAccount {
    account_id: String,
    account_name: String,
    account_type: String,
    /// `services::tax::is_tax_advantaged_account_type` — the same list Tax
    /// planning uses.
    tax_advantaged: bool,
    quantity: f64,
    value_usd: f64,
}

/// One active purchase lot (depletion markers already filtered out).
#[derive(Serialize)]
struct InstrumentLot {
    acquired_at: String,
    qty: f64,
    cost_per_unit: f64,
    currency: String,
    usd_cost: f64,
}

/// One daily close of the instrument's stored price series.
#[derive(Serialize)]
struct InstrumentPricePoint {
    date: String,
    close: f64,
}

/// Per-symbol instrument detail (contract C-A) — consumed by the Portfolio
/// tab's instrument sheet. Every nullable stays a real JSON `null` (no skip
/// attrs): the frontend is built against the full field set.
#[derive(Serialize)]
struct InstrumentDetailResponse {
    symbol: String,
    name: String,
    /// Native currency of the (dominant) position.
    currency: String,
    /// Canonical asset class (contract C2), same classifier as holdings —
    /// reflects a user override (C3-A) when one exists.
    asset_class: String,
    /// C3-A: `"override"` when `asset_class` comes from the user's pinned
    /// classification, `"heuristic"` otherwise.
    asset_class_source: &'static str,
    /// C3-A extension: the `classify_asset` heuristic result regardless of
    /// any override — lets the sheet label its "Automatic — <class>" revert
    /// row while an override is active. Equals `asset_class` when
    /// `asset_class_source == "heuristic"`.
    asset_class_heuristic: &'static str,
    /// Shares held across all of the user's active accounts.
    quantity: f64,
    /// Latest per-share price (native currency); null when unpriced.
    price: Option<f64>,
    value_usd: f64,
    /// Null when any account's basis is unknown (all-or-nothing: a partial
    /// basis would silently misstate the gain).
    cost_basis_usd: Option<f64>,
    gain_loss_usd: Option<f64>,
    gain_loss_pct: Option<f64>,
    /// Symbol value ÷ total portfolio (holdings) value × 100.
    portfolio_weight_pct: f64,
    /// C-B day-change rules applied to the aggregate position: null for
    /// cash sleeves, <2 stored closes, or a stale (>7 day) latest close.
    day_change_usd: Option<f64>,
    day_change_pct: Option<f64>,
    price_as_of: Option<String>,
    accounts: Vec<InstrumentAccount>,
    lots: Vec<InstrumentLot>,
    /// Stored daily closes over the requested range, ascending. Empty for
    /// opaque/unresolvable symbols — never an error.
    prices: Vec<InstrumentPricePoint>,
}

/// One of the user's holdings rows for the requested symbol, already
/// decoded — input to `build_instrument_detail`. The per-holding USD basis
/// is pre-computed by the handler with the SAME lots-aware logic the
/// holdings endpoint uses.
struct InstrumentPosition {
    symbol: String,
    name: String,
    holding_type: String,
    quantity: f64,
    price: Option<f64>,
    value: f64,
    cost_basis_usd: Option<f64>,
    currency: String,
    account_id: String,
    account_name: String,
    account_type: String,
}

/// Inclusive start date for the requested chart range. Unknown/absent
/// values fail soft to the 1-year default.
fn instrument_range_start(range: Option<&str>, today: chrono::NaiveDate) -> chrono::NaiveDate {
    match range.unwrap_or("1y") {
        "1m" => today - chrono::Duration::days(31),
        "3m" => today - chrono::Duration::days(92),
        "max" => chrono::NaiveDate::from_ymd_opt(2000, 1, 1).unwrap(),
        _ => today - chrono::Duration::days(365),
    }
}

/// Assemble the C-A response from the user's rows + lots + stored prices.
/// Pure so the shape and math are unit-testable offline. `positions` must be
/// non-empty, ordered by value descending — the first row donates the
/// representative name/price/currency. `closes` is the symbol's last two
/// stored closes (newest first), when available.
#[allow(clippy::too_many_arguments)] // pure builder: the args ARE the contract inputs
fn build_instrument_detail(
    positions: &[InstrumentPosition],
    lots: Vec<InstrumentLot>,
    prices: &[(chrono::NaiveDate, f64)],
    closes: Option<&[(chrono::NaiveDate, f64)]>,
    asset_class_override: Option<&str>,
    total_portfolio_value_usd: f64,
    fx_usd_to_mxn: f64,
    today: chrono::NaiveDate,
) -> InstrumentDetailResponse {
    let to_usd = |amount: f64, ccy: &str| -> f64 {
        match ccy {
            "USD" => amount,
            "MXN" => {
                if fx_usd_to_mxn > 0.0 {
                    amount / fx_usd_to_mxn
                } else {
                    amount
                }
            }
            _ => amount,
        }
    };
    let round2 = |v: f64| (v * 100.0).round() / 100.0;

    let first = &positions[0];
    let quantity: f64 = positions.iter().map(|p| p.quantity).sum();
    let value_usd = round2(positions.iter().map(|p| to_usd(p.value, &p.currency)).sum());

    // Basis is all-or-nothing, same rationale as the dividend detail: a
    // partial basis would misstate the aggregate gain.
    let cost_basis_usd: Option<f64> = if positions.iter().all(|p| p.cost_basis_usd.is_some()) {
        Some(round2(
            positions
                .iter()
                .map(|p| p.cost_basis_usd.unwrap_or(0.0))
                .sum(),
        ))
    } else {
        None
    };
    let gain_loss_usd = cost_basis_usd.map(|cb| round2(value_usd - cb));
    let gain_loss_pct = cost_basis_usd
        .filter(|cb| *cb > 0.0)
        .map(|cb| round2((value_usd - cb) / cb * 100.0));

    // C3-A precedence: the user's pinned class outranks the heuristic; the
    // source field tells the sheet which one it is showing. The heuristic is
    // always emitted too, so the sheet can label its "Automatic — <class>"
    // revert row while an override is active.
    let asset_class_heuristic =
        crate::services::holdings::classify_asset(&first.holding_type, &first.symbol, &first.name);
    let (asset_class, asset_class_source) = match asset_class_override {
        Some(c) => (c.to_string(), "override"),
        None => (asset_class_heuristic.to_string(), "heuristic"),
    };
    let is_cash = first.holding_type == "cash" || asset_class == "cash";
    let day = day_change_for_row(value_usd, is_cash, closes, today);

    let portfolio_weight_pct = if total_portfolio_value_usd > 0.0 {
        round2(value_usd / total_portfolio_value_usd * 100.0)
    } else {
        0.0
    };

    InstrumentDetailResponse {
        symbol: first.symbol.clone(),
        name: first.name.clone(),
        currency: first.currency.clone(),
        asset_class,
        asset_class_source,
        asset_class_heuristic,
        quantity,
        price: first.price,
        value_usd,
        cost_basis_usd,
        gain_loss_usd,
        gain_loss_pct,
        portfolio_weight_pct,
        day_change_usd: day.as_ref().map(|d| round2(d.day_change_usd)),
        day_change_pct: day.as_ref().map(|d| round2(d.day_change_pct)),
        price_as_of: day.as_ref().map(|d| d.as_of.to_string()),
        accounts: positions
            .iter()
            .map(|p| InstrumentAccount {
                account_id: p.account_id.clone(),
                account_name: p.account_name.clone(),
                account_type: p.account_type.clone(),
                tax_advantaged: crate::services::tax::is_tax_advantaged_account_type(Some(
                    &p.account_type,
                )),
                quantity: p.quantity,
                value_usd: round2(to_usd(p.value, &p.currency)),
            })
            .collect(),
        lots,
        prices: prices
            .iter()
            .map(|(d, c)| InstrumentPricePoint {
                date: d.to_string(),
                close: *c,
            })
            .collect(),
    }
}

#[derive(Deserialize)]
pub(super) struct InstrumentQuery {
    /// Chart range: 1m | 3m | 1y (default) | max.
    range: Option<String>,
}

/// GET /instruments/{symbol} — instrument detail for one held symbol
/// (contract C-A). Matched case-insensitively against the caller's
/// active-account holdings; 404 when they hold no such symbol. Opaque
/// symbols (401k trust units, `CUR:USD`) still answer 200 with empty
/// `prices` and null day-change stats — never a 500. Prices come from the
/// stored `benchmark_prices` series after a best-effort 4-day-gated
/// refresh, and ONLY for ticker-shaped symbols (no doomed Yahoo lookups
/// for trust-fund names).
pub(super) async fn instrument_detail(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    axum::extract::Path(symbol): axum::extract::Path<String>,
    Query(q): Query<InstrumentQuery>,
) -> Response {
    let fx_info = latest_usd_mxn_rate(&state.db).await;
    let fx_usd_to_mxn = fx_info.rate;

    let rows = sqlx::query(
        r#"
        SELECT h.id, h.symbol, h.name, h.quantity, h.price, h.value, h.cost_basis,
               h.currency, COALESCE(h.holding_type, '') AS holding_type,
               a.id AS account_id, a.account_type,
               COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name
        FROM holdings h
        JOIN accounts a ON h.account_id = a.id
        WHERE h.user_id = $1
          AND a.archived_at IS NULL
          AND h.deleted_at IS NULL
          AND UPPER(h.symbol) = UPPER($2)
        ORDER BY h.value DESC NULLS LAST
        "#,
    )
    .bind(ctx.user_id)
    .bind(&symbol)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    if rows.is_empty() {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "unknown symbol"})),
        )
            .into_response();
    }

    // Active lots for these holdings — both the per-lot breakdown and the
    // lots-preferred (FX-aware) cost basis, mirroring the holdings handler.
    let holding_ids: Vec<uuid::Uuid> = rows
        .iter()
        .filter_map(|r| r.try_get::<uuid::Uuid, _>("id").ok())
        .collect();
    let lot_rows = sqlx::query(
        r#"
        SELECT holding_id, qty, cost_per_unit, currency, usd_fx_rate, acquired_at
        FROM holding_lots
        WHERE user_id = $1 AND holding_id = ANY($2) AND qty > 0
        ORDER BY acquired_at ASC, id ASC
        "#,
    )
    .bind(ctx.user_id)
    .bind(&holding_ids)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let mut lots: Vec<InstrumentLot> = Vec::new();
    let mut lot_basis_by_holding: HashMap<uuid::Uuid, f64> = HashMap::new();
    for r in &lot_rows {
        let hid: uuid::Uuid = match r.try_get("holding_id") {
            Ok(v) => v,
            Err(_) => continue,
        };
        let dec = |col: &str| -> f64 {
            r.try_get::<rust_decimal::Decimal, _>(col)
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0)
        };
        let qty = dec("qty");
        let cpu = dec("cost_per_unit");
        let fx = dec("usd_fx_rate");
        let ccy: String = r.try_get("currency").unwrap_or_else(|_| "USD".to_string());
        let native_cost = qty * cpu;
        // Same conversion as the holdings handler's lots-preferred basis:
        // the lot's own historical FX rate, current-FX fallback.
        let usd_cost = match ccy.as_str() {
            "USD" => native_cost,
            "MXN" => {
                if fx > 0.0 {
                    native_cost / fx
                } else {
                    native_cost / fx_usd_to_mxn
                }
            }
            _ => native_cost,
        };
        *lot_basis_by_holding.entry(hid).or_insert(0.0) += usd_cost;
        lots.push(InstrumentLot {
            acquired_at: r
                .try_get::<chrono::NaiveDate, _>("acquired_at")
                .map(|d| d.to_string())
                .unwrap_or_default(),
            qty,
            cost_per_unit: cpu,
            currency: ccy,
            usd_cost,
        });
    }

    let dec_f64 = |r: &sqlx::postgres::PgRow, col: &str| -> Option<f64> {
        r.try_get::<Option<rust_decimal::Decimal>, _>(col)
            .ok()
            .flatten()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
    };
    let positions: Vec<InstrumentPosition> = rows
        .iter()
        .map(|r| {
            let currency: String = r.try_get("currency").unwrap_or_else(|_| "USD".to_string());
            let hid: uuid::Uuid = r.try_get("id").unwrap_or_else(|_| uuid::Uuid::nil());
            // Lots-preferred USD basis; flat-basis fallback at current FX —
            // exactly the holdings handler's policy.
            let cost_basis_usd = lot_basis_by_holding.get(&hid).copied().or_else(|| {
                dec_f64(r, "cost_basis").map(|cb| match currency.as_str() {
                    "USD" => cb,
                    "MXN" => {
                        if fx_usd_to_mxn > 0.0 {
                            cb / fx_usd_to_mxn
                        } else {
                            cb
                        }
                    }
                    _ => cb,
                })
            });
            InstrumentPosition {
                symbol: r.get("symbol"),
                name: r.get("name"),
                holding_type: r.try_get("holding_type").unwrap_or_default(),
                quantity: dec_f64(r, "quantity").unwrap_or(0.0),
                price: dec_f64(r, "price").filter(|p| *p > 0.0),
                value: dec_f64(r, "value").unwrap_or(0.0),
                cost_basis_usd,
                currency,
                account_id: r
                    .try_get::<uuid::Uuid, _>("account_id")
                    .map(|u| u.to_string())
                    .unwrap_or_default(),
                account_name: r.get("account_name"),
                account_type: r.try_get::<String, _>("account_type").unwrap_or_default(),
            }
        })
        .collect();

    // Denominator for the portfolio weight: every active-account holding,
    // converted with the same MXN policy as the holdings handler.
    let total_portfolio_value_usd: f64 = sqlx::query(
        r#"
        SELECT COALESCE(SUM(
            CASE WHEN h.currency = 'MXN' THEN h.value / $1::numeric ELSE h.value END
        ), 0) AS total
        FROM holdings h
        JOIN accounts a ON h.account_id = a.id
        WHERE h.user_id = $2 AND a.archived_at IS NULL AND h.deleted_at IS NULL
        "#,
    )
    .bind(fx_usd_to_mxn)
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten()
    .and_then(|r| r.try_get::<rust_decimal::Decimal, _>("total").ok())
    .and_then(|d| d.to_string().parse::<f64>().ok())
    .unwrap_or(0.0);

    // Round 3 (C3-A): the caller's override for this one symbol — a single
    // indexed PK lookup, passed into the pure builder as Option<&str>.
    let asset_class_override: Option<String> = sqlx::query_scalar(
        "SELECT asset_class FROM asset_class_overrides WHERE user_id = $1 AND symbol = $2",
    )
    .bind(ctx.user_id)
    .bind(positions[0].symbol.trim().to_uppercase())
    .fetch_optional(&state.db)
    .await
    .unwrap_or(None);

    // Stored price series — ticker-shaped symbols only. `ensure_symbol_fresh`
    // is best-effort (4-day gate, tolerates network failure when cached data
    // exists); opaque symbols skip straight to the empty-series degradation.
    let today = chrono::Utc::now().date_naive();
    let canonical_symbol = positions[0].symbol.clone();
    let (prices, closes_by_symbol) = if crate::services::twr::looks_like_ticker(&canonical_symbol) {
        let _ = crate::services::benchmark::ensure_symbol_fresh(
            &state.db,
            &canonical_symbol,
            &canonical_symbol,
        )
        .await;
        let from = instrument_range_start(q.range.as_deref(), today);
        (
            crate::services::benchmark::series(&state.db, &canonical_symbol, from).await,
            latest_two_closes(&state.db, std::slice::from_ref(&canonical_symbol)).await,
        )
    } else {
        (Vec::new(), HashMap::new())
    };
    let closes = closes_by_symbol
        .get(&canonical_symbol)
        .map(|v| v.as_slice());

    Json(build_instrument_detail(
        &positions,
        lots,
        &prices,
        closes,
        asset_class_override.as_deref(),
        total_portfolio_value_usd,
        fx_usd_to_mxn,
        today,
    ))
    .into_response()
}

/// Contract C3-A request body: `{"asset_class": "bonds"}` sets an override,
/// `{"asset_class": null}` clears it back to the heuristic.
#[derive(Deserialize)]
pub(super) struct AssetClassOverrideRequest {
    asset_class: Option<String>,
}

/// PUT /instruments/{symbol}/asset-class — pin (UPSERT) or clear (DELETE) the
/// caller's asset-class override for a held symbol (contract C3-A). Keyed
/// per (user, UPPER(TRIM(symbol))) in `asset_class_overrides`, NOT on the
/// holdings row — import/sync churns holdings rows, and a classification is a
/// property of the instrument, so one edit covers every account holding it.
pub(super) async fn set_asset_class_override(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    axum::extract::Path(symbol): axum::extract::Path<String>,
    Json(payload): Json<AssetClassOverrideRequest>,
) -> Response {
    // Validate BEFORE the held check so a bogus class is always 422, even
    // for a symbol the caller doesn't hold.
    if let Some(ref class) = payload.asset_class {
        if !crate::services::holdings::ASSET_CLASSES.contains(&class.as_str()) {
            return (
                StatusCode::UNPROCESSABLE_ENTITY,
                Json(serde_json::json!({"error": "invalid asset class"})),
            )
                .into_response();
        }
    }

    // Same case-insensitive active-holdings match as `instrument_detail`; the
    // top-value row donates the representative type/name for the heuristic
    // fallback in the response.
    let row = sqlx::query(
        r#"
        SELECT h.symbol, h.name, COALESCE(h.holding_type, '') AS holding_type
        FROM holdings h
        JOIN accounts a ON h.account_id = a.id
        WHERE h.user_id = $1
          AND a.archived_at IS NULL
          AND h.deleted_at IS NULL
          AND UPPER(h.symbol) = UPPER($2)
        ORDER BY h.value DESC NULLS LAST
        LIMIT 1
        "#,
    )
    .bind(ctx.user_id)
    .bind(&symbol)
    .fetch_optional(&state.db)
    .await
    .unwrap_or(None);

    let Some(row) = row else {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "unknown symbol"})),
        )
            .into_response();
    };
    let held_symbol: String = row.get("symbol");
    let held_name: String = row.try_get("name").unwrap_or_default();
    let held_type: String = row.try_get("holding_type").unwrap_or_default();
    // Overrides are stored normalized — the same UPPER(TRIM) key every
    // classify site looks up.
    let key = held_symbol.trim().to_uppercase();

    let write = match payload.asset_class.as_deref() {
        Some(class) => {
            sqlx::query(
                "INSERT INTO asset_class_overrides (user_id, symbol, asset_class, updated_at) \
                 VALUES ($1, $2, $3, now()) \
                 ON CONFLICT (user_id, symbol) \
                 DO UPDATE SET asset_class = EXCLUDED.asset_class, updated_at = now()",
            )
            .bind(ctx.user_id)
            .bind(&key)
            .bind(class)
            .execute(&state.db)
            .await
        }
        None => {
            sqlx::query("DELETE FROM asset_class_overrides WHERE user_id = $1 AND symbol = $2")
                .bind(ctx.user_id)
                .bind(&key)
                .execute(&state.db)
                .await
        }
    };
    if let Err(e) = write {
        error!("Failed to write asset-class override for {key}: {e}");
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }

    // Echo the now-effective classification: the override when set, the
    // heuristic after a clear.
    let (asset_class, source) = match payload.asset_class {
        Some(class) => (class, "override"),
        None => (
            crate::services::holdings::classify_asset(&held_type, &held_symbol, &held_name)
                .to_string(),
            "heuristic",
        ),
    };
    Json(serde_json::json!({
        "symbol": key,
        "asset_class": asset_class,
        "asset_class_source": source,
    }))
    .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;

    // =================================================================
    // C-B — day change from stored closes
    // =================================================================

    fn day(y: i32, m: u32, d: u32) -> chrono::NaiveDate {
        chrono::NaiveDate::from_ymd_opt(y, m, d).unwrap()
    }

    /// Cash sleeves never carry a day change, even with a fresh series.
    #[test]
    fn day_change_null_for_cash_row() {
        let closes = [(day(2026, 7, 2), 1.0), (day(2026, 7, 1), 1.0)];
        assert!(day_change_for_row(200.0, true, Some(&closes), day(2026, 7, 6)).is_none());
    }

    /// One stored close (or none) is not enough to compute a change.
    #[test]
    fn day_change_null_for_single_close_or_missing_series() {
        let one = [(day(2026, 7, 2), 171.7)];
        assert!(day_change_for_row(1000.0, false, Some(&one), day(2026, 7, 6)).is_none());
        assert!(day_change_for_row(1000.0, false, None, day(2026, 7, 6)).is_none());
    }

    /// A latest close more than 7 calendar days old is stale — null rather
    /// than presenting a week-old move as "today".
    #[test]
    fn day_change_null_for_stale_close() {
        let stale = [(day(2026, 6, 28), 102.0), (day(2026, 6, 27), 100.0)];
        assert!(day_change_for_row(1000.0, false, Some(&stale), day(2026, 7, 6)).is_none());
        // Exactly 7 days old is still acceptable (weekend + holiday runs).
        let edge = [(day(2026, 6, 29), 102.0), (day(2026, 6, 28), 100.0)];
        assert!(day_change_for_row(1000.0, false, Some(&edge), day(2026, 7, 6)).is_some());
    }

    /// pct = (c0 − c1)/c1 in the symbol's native currency; the row's USD
    /// change scales its USD value by that same ratio.
    #[test]
    fn day_change_math_from_last_two_closes() {
        let closes = [(day(2026, 7, 2), 102.0), (day(2026, 7, 1), 100.0)];
        let rc = day_change_for_row(1000.0, false, Some(&closes), day(2026, 7, 6)).unwrap();
        assert!((rc.day_change_pct - 2.0).abs() < 1e-9);
        assert!((rc.day_change_usd - 20.0).abs() < 1e-9);
        assert_eq!(rc.as_of, day(2026, 7, 2));
    }

    /// Coverage counts ONLY rows with a known day change; the top-level pct
    /// divides by the covered rows' prior value; as_of is the max covered
    /// close date.
    #[test]
    fn day_change_totals_coverage_and_pct_math() {
        // Covered: 1020 (chg +20, as-of Jul 2), 510 (chg +10, as-of Jul 1).
        // Uncovered: a 470 trust row → coverage = 1530/2000 = 76.5%.
        let rows = vec![
            (1020.0, Some(20.0), Some("2026-07-02")),
            (510.0, Some(10.0), Some("2026-07-01")),
            (470.0, None, None),
        ];
        let t = day_change_totals(rows.into_iter());
        assert!((t.day_change_usd.unwrap() - 30.0).abs() < 1e-9);
        // Prior value = (1020-20) + (510-10) = 1500 → 30/1500 = 2%.
        assert!((t.day_change_pct.unwrap() - 2.0).abs() < 1e-9);
        assert!((t.coverage_pct - 76.5).abs() < 1e-9);
        assert_eq!(t.as_of.as_deref(), Some("2026-07-02"));
    }

    /// No covered rows: null totals, 0 coverage — the UI hides the pill.
    #[test]
    fn day_change_totals_null_when_nothing_covered() {
        let rows = vec![(470.0, None, None), (200.0, None, None)];
        let t = day_change_totals(rows.into_iter());
        assert!(t.day_change_usd.is_none());
        assert!(t.day_change_pct.is_none());
        assert!((t.coverage_pct - 0.0).abs() < 1e-9);
        assert!(t.as_of.is_none());
    }

    // =================================================================
    // C-A — instrument detail
    // =================================================================

    /// The C-A contract shape, field for field, for a held ticker. The
    /// frontend instrument sheet is built against exactly this JSON.
    #[test]
    fn instrument_detail_matches_contract_c_a_for_held_ticker() {
        let positions = vec![InstrumentPosition {
            symbol: "NVDA".to_string(),
            name: "NVIDIA Corp".to_string(),
            holding_type: "equity".to_string(),
            quantity: 29.5,
            price: Some(172.40),
            value: 5085.80,
            cost_basis_usd: Some(3100.00),
            currency: "USD".to_string(),
            account_id: "6e9c1a4e-0000-0000-0000-000000000001".to_string(),
            account_name: "Robinhood".to_string(),
            account_type: "brokerage".to_string(),
        }];
        let lots = vec![InstrumentLot {
            acquired_at: "2024-03-01".to_string(),
            qty: 10.0,
            cost_per_unit: 88.10,
            currency: "USD".to_string(),
            usd_cost: 881.00,
        }];
        let prices = vec![(day(2026, 7, 1), 170.0), (day(2026, 7, 2), 171.7)];
        // Newest first, +1.0% day move.
        let closes = [(day(2026, 7, 2), 171.7), (day(2026, 7, 1), 170.0)];

        let got = serde_json::to_value(build_instrument_detail(
            &positions,
            lots,
            &prices,
            Some(&closes),
            None,
            1_525_740.0,
            20.0,
            day(2026, 7, 6),
        ))
        .unwrap();
        let want = serde_json::json!({
            "symbol": "NVDA",
            "name": "NVIDIA Corp",
            "currency": "USD",
            "asset_class": "equity",
            "asset_class_source": "heuristic",
            "asset_class_heuristic": "equity",
            "quantity": 29.5,
            "price": 172.40,
            "value_usd": 5085.80,
            "cost_basis_usd": 3100.00,
            "gain_loss_usd": 1985.80,
            "gain_loss_pct": 64.06,
            "portfolio_weight_pct": 0.33,
            "day_change_usd": 50.86,
            "day_change_pct": 1.0,
            "price_as_of": "2026-07-02",
            "accounts": [
                {
                    "account_id": "6e9c1a4e-0000-0000-0000-000000000001",
                    "account_name": "Robinhood",
                    "account_type": "brokerage",
                    "tax_advantaged": false,
                    "quantity": 29.5,
                    "value_usd": 5085.80
                }
            ],
            "lots": [
                {"acquired_at": "2024-03-01", "qty": 10.0, "cost_per_unit": 88.10,
                 "currency": "USD", "usd_cost": 881.00}
            ],
            "prices": [
                {"date": "2026-07-01", "close": 170.0},
                {"date": "2026-07-02", "close": 171.7}
            ]
        });
        assert_eq!(got, want);
    }

    /// An opaque symbol (401k trust units): 200 with empty prices and null
    /// price/basis/day-change stats — everything else still renders. The
    /// 401k account is flagged tax-advantaged via the tax module's list.
    #[test]
    fn instrument_detail_opaque_symbol_degrades_to_empty_prices_and_nulls() {
        let positions = vec![InstrumentPosition {
            symbol: "VANG TARGET RET 2045".to_string(),
            name: "Vanguard Target Retirement 2045 Trust".to_string(),
            holding_type: String::new(),
            quantity: 100.0,
            price: None,
            value: 12000.0,
            cost_basis_usd: None,
            currency: "USD".to_string(),
            account_id: "6e9c1a4e-0000-0000-0000-000000000002".to_string(),
            account_name: "Employer 401k".to_string(),
            account_type: "401k".to_string(),
        }];

        let got = serde_json::to_value(build_instrument_detail(
            &positions,
            Vec::new(),
            &[],
            None,
            None,
            24000.0,
            20.0,
            day(2026, 7, 6),
        ))
        .unwrap();
        assert_eq!(got["symbol"], "VANG TARGET RET 2045");
        // Name/type default classifies trust units as equity (round-1 C2).
        assert_eq!(got["asset_class"], "equity");
        assert_eq!(got["asset_class_source"], "heuristic");
        assert_eq!(got["asset_class_heuristic"], "equity");
        assert_eq!(got["value_usd"], 12000.0);
        assert_eq!(got["portfolio_weight_pct"], 50.0);
        // Nullables are real JSON nulls, not absent keys.
        assert!(got["price"].is_null());
        assert!(got["cost_basis_usd"].is_null());
        assert!(got["gain_loss_usd"].is_null());
        assert!(got["gain_loss_pct"].is_null());
        assert!(got["day_change_usd"].is_null());
        assert!(got["day_change_pct"].is_null());
        assert!(got["price_as_of"].is_null());
        assert_eq!(got["prices"], serde_json::json!([]));
        assert_eq!(got["lots"], serde_json::json!([]));
        assert_eq!(got["accounts"][0]["tax_advantaged"], true);
    }

    /// C3-A: a pre-fetched override outranks the heuristic in the pure
    /// builder and flips the source field; None keeps round-2 output intact.
    #[test]
    fn instrument_detail_override_wins_and_flags_source() {
        let positions = vec![InstrumentPosition {
            symbol: "VBTLX".to_string(),
            name: "Vanguard Total Bond Market Index Fund".to_string(),
            holding_type: "mutual fund".to_string(),
            quantity: 100.0,
            price: Some(9.85),
            value: 985.0,
            cost_basis_usd: Some(1000.0),
            currency: "USD".to_string(),
            account_id: "6e9c1a4e-0000-0000-0000-000000000003".to_string(),
            account_name: "IRA".to_string(),
            account_type: "ira".to_string(),
        }];
        let got = serde_json::to_value(build_instrument_detail(
            &positions,
            Vec::new(),
            &[],
            None,
            Some("other"),
            985.0,
            20.0,
            day(2026, 7, 6),
        ))
        .unwrap();
        assert_eq!(got["asset_class"], "other");
        assert_eq!(got["asset_class_source"], "override");
        // The heuristic is still reported so the sheet can offer
        // "Automatic — Bonds" as the revert row (VBTLX is a known bond fund).
        assert_eq!(got["asset_class_heuristic"], "bonds");
    }

    /// Range keys map to sensible window starts; unknown fails soft to 1y.
    #[test]
    fn instrument_range_start_windows() {
        let today = day(2026, 7, 6);
        assert_eq!(instrument_range_start(Some("1m"), today), day(2026, 6, 5));
        assert_eq!(instrument_range_start(Some("3m"), today), day(2026, 4, 5));
        assert_eq!(instrument_range_start(Some("1y"), today), day(2025, 7, 6));
        assert_eq!(instrument_range_start(Some("max"), today), day(2000, 1, 1));
        assert_eq!(instrument_range_start(None, today), day(2025, 7, 6));
        assert_eq!(
            instrument_range_start(Some("bogus"), today),
            day(2025, 7, 6)
        );
    }

    // =================================================================
    // C-D — conservative payment matching (regex gate)
    // =================================================================
}
