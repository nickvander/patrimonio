use axum::{
    extract::{Extension, Query, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use std::collections::HashMap;

use crate::api::middleware::AuthContext;
use crate::AppState;

use super::*;

/// Cap on concurrent live Yahoo dividend fetches. The per-account endpoint
/// hits these serially; the portfolio view fans out across every distinct
/// symbol the user holds, so we bound the in-flight requests to stay polite
/// to the free feed while still beating an N-serial loop.
const DIVIDEND_FETCH_CONCURRENCY: usize = 8;

/// One symbol's contribution to portfolio dividend income.
#[derive(Serialize)]
struct DividendSymbolContribution {
    symbol: String,
    /// Shares held across all of the user's accounts (combined).
    quantity: f64,
    /// Trailing-12-month dividend per share, native currency.
    annual_rate: f64,
    /// Projected annual income for the held quantity, converted to USD.
    annual_income_usd: f64,
    /// Yield on current value (annual_income / value), percent. Null when we
    /// have no price to value the position.
    yield_pct: Option<f64>,
    last_ex_date: Option<String>,
    est_next_ex_date: Option<String>,
    per_year: i32,
}

/// An upcoming estimated ex-dividend date for a held symbol.
#[derive(Serialize)]
struct UpcomingExDate {
    symbol: String,
    est_next_ex_date: String,
    /// Per-symbol projected income (USD) landing around that date.
    annual_income_usd: f64,
}

#[derive(Serialize)]
pub(super) struct PortfolioDividendsResponse {
    /// Sum of per-symbol projected annual income, in USD.
    projected_annual_income_usd: f64,
    /// Blended yield-on-value: total projected income / total valued holdings,
    /// percent. Null when no priced, dividend-paying position exists.
    blended_yield_pct: Option<f64>,
    /// Per-symbol contributions, dividend payers first, by income descending.
    contributions: Vec<DividendSymbolContribution>,
    /// Every held payer's upcoming estimated ex-date, soonest first — one
    /// entry per payer, NO server-side cap (the old truncate-to-5 silently
    /// dropped the later-quarter dates; the list is bounded by payer count).
    upcoming_ex_dates: Vec<UpcomingExDate>,
    /// True when an MXN position was converted with a missing/stale FX rate.
    fx_stale: bool,
    /// Round 4 (contract C4-B): 12-month income calendar, starting at the
    /// current month (UTC). Additive — everything above is byte-identical
    /// to the round-3 response; consumers that don't know the field ignore
    /// it.
    calendar: Vec<DividendCalendarMonth>,
}

/// One month bucket of the projected dividend calendar (contract C4-B).
#[derive(Serialize)]
struct DividendCalendarMonth {
    /// `YYYY-MM`, UTC; the 12 buckets are chronological from the current month.
    month: String,
    /// Sum of the month's entries, rounded to cents (USD).
    total_usd: f64,
    /// Per-symbol projected payments, sorted `amount_usd` descending.
    entries: Vec<DividendCalendarEntry>,
}

/// One projected per-symbol payment inside a calendar month (contract C4-B).
#[derive(Serialize)]
struct DividendCalendarEntry {
    symbol: String,
    /// Estimated ex-date (YYYY-MM-DD).
    est_date: String,
    /// `annual_income_usd / per_year`, rounded to cents (USD — already
    /// FX-converted per sleeve upstream).
    amount_usd: f64,
}

/// The ONE date-stepping implementation shared by the detail endpoint's
/// `schedule` (see `build_dividend_detail`) and the calendar (C4-B): up to
/// `per_year` dates at `est_next + k*round(365/per_year)` days, pruned to
/// those within `horizon_days` of `est_next`. Empty for non-payers
/// (`per_year <= 0`) and missing/unparsable estimates.
fn projected_ex_dates(
    per_year: i32,
    est_next: Option<&str>,
    horizon_days: i64,
) -> Vec<chrono::NaiveDate> {
    if per_year <= 0 {
        return Vec::new();
    }
    let Some(start) = est_next.and_then(|d| chrono::NaiveDate::parse_from_str(d, "%Y-%m-%d").ok())
    else {
        return Vec::new();
    };
    let step = (365.0 / per_year as f64).round() as i64;
    (0..per_year as i64)
        .map(|k| start + chrono::Duration::days(step * k))
        .filter(|d| (*d - start).num_days() < horizon_days)
        .collect()
}

/// Contract C4-B: bucket every payer's projected payments into exactly 12
/// chronological `YYYY-MM` months starting at `today`'s month (UTC). Pure so
/// the bucketing, rounding, and ordering are unit-testable offline. Symbols
/// with `per_year == 0` (non-payers, failed fetches, unresolvable) and
/// zero-income payers contribute nothing; a projected date landing outside
/// the window (an annual payer's next date > 12 months out) is dropped —
/// the acknowledged small delta vs `projected_annual_income_usd`.
fn build_dividend_calendar(
    contributions: &[DividendSymbolContribution],
    today: chrono::NaiveDate,
) -> Vec<DividendCalendarMonth> {
    use chrono::Datelike;
    // 12 month keys from the current month; index for O(1) bucketing.
    let month_keys: Vec<String> = (0..12)
        .map(|i| {
            let m0 = today.year() * 12 + today.month0() as i32 + i;
            format!("{:04}-{:02}", m0.div_euclid(12), m0.rem_euclid(12) + 1)
        })
        .collect();
    let index: HashMap<&str, usize> = month_keys
        .iter()
        .enumerate()
        .map(|(i, k)| (k.as_str(), i))
        .collect();

    let mut buckets: Vec<Vec<DividendCalendarEntry>> = (0..12).map(|_| Vec::new()).collect();
    for c in contributions {
        if c.per_year <= 0 || c.annual_income_usd <= 0.0 {
            continue;
        }
        let amount = ((c.annual_income_usd / c.per_year as f64) * 100.0).round() / 100.0;
        for date in projected_ex_dates(c.per_year, c.est_next_ex_date.as_deref(), 365) {
            let key = format!("{:04}-{:02}", date.year(), date.month());
            if let Some(&i) = index.get(key.as_str()) {
                buckets[i].push(DividendCalendarEntry {
                    symbol: c.symbol.clone(),
                    est_date: date.to_string(),
                    amount_usd: amount,
                });
            }
        }
    }

    month_keys
        .into_iter()
        .zip(buckets)
        .map(|(month, mut entries)| {
            entries.sort_by(|a, b| {
                b.amount_usd
                    .partial_cmp(&a.amount_usd)
                    .unwrap_or(std::cmp::Ordering::Equal)
            });
            let total_usd =
                (entries.iter().map(|e| e.amount_usd).sum::<f64>() * 100.0).round() / 100.0;
            DividendCalendarMonth {
                month,
                total_usd,
                entries,
            }
        })
        .collect()
}

/// Every payer's upcoming estimated ex-date (est date >= `today`, ISO),
/// soonest first. Deliberately uncapped — the round-1 truncate-to-5 was
/// exactly what cut the September/October entries out of the upcoming list.
/// Pure so the no-cap behaviour is unit-testable offline.
fn upcoming_ex_dates(
    contributions: &[DividendSymbolContribution],
    today: &str,
) -> Vec<UpcomingExDate> {
    let mut upcoming: Vec<UpcomingExDate> = contributions
        .iter()
        .filter(|c| c.annual_income_usd > 0.0)
        .filter_map(|c| {
            c.est_next_ex_date
                .as_ref()
                .filter(|d| d.as_str() >= today)
                .map(|d| UpcomingExDate {
                    symbol: c.symbol.clone(),
                    est_next_ex_date: d.clone(),
                    annual_income_usd: c.annual_income_usd,
                })
        })
        .collect();
    upcoming.sort_by(|a, b| a.est_next_ex_date.cmp(&b.est_next_ex_date));
    upcoming
}

/// Portfolio-wide dividend income: aggregates the per-symbol dividend engine
/// across every active account the user holds, so the Portfolio tab can show
/// projected annual income, a blended yield-on-value, the top payers, the
/// next estimated ex-dates, and (round 4, C4-B) the 12-month income calendar.
/// Uses the Redis-cached fetch (`dividends::fetch_dividends_cached`, C4-C)
/// and fans the lookups out with bounded concurrency; a single symbol's
/// fetch failure degrades only that symbol's income to zero, never the
/// whole response.
pub(super) async fn portfolio_dividends(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<PortfolioDividendsResponse> {
    let fx_info = latest_usd_mxn_rate(&state.db).await;
    let fx_usd_to_mxn = fx_info.rate;
    let mut fx_stale_used = false;

    // Combine quantity (and the latest seen price) per (symbol, currency)
    // across every active, non-cash holding. Grouping by currency too — not
    // one arbitrary MAX(currency)/MAX(price) per symbol — keeps a position
    // held in both a USD and an MXN account convertible per sleeve; the
    // sleeves merge back into one per-symbol contribution below. Cash-sleeve
    // rows are fixed at 1.00 and never pay a dividend, so they're filtered
    // out before the fan-out.
    let rows = sqlx::query(
        r#"
        SELECT h.symbol,
               h.currency,
               COALESCE(SUM(h.quantity), 0) AS quantity,
               MAX(h.price) AS price
        FROM holdings h
        JOIN accounts a ON h.account_id = a.id
        WHERE h.user_id = $1
          AND a.archived_at IS NULL
          AND h.deleted_at IS NULL
          AND COALESCE(h.holding_type, '') <> 'cash'
          AND h.symbol IS NOT NULL AND h.symbol <> ''
        GROUP BY h.symbol, h.currency
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    struct Pos {
        symbol: String,
        quantity: f64,
        price: Option<f64>,
        currency: String,
    }
    let positions: Vec<Pos> = rows
        .iter()
        .map(|r| {
            let quantity = r
                .try_get::<rust_decimal::Decimal, _>("quantity")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0);
            let price = r
                .try_get::<Option<rust_decimal::Decimal>, _>("price")
                .ok()
                .flatten()
                .map(|d| d.to_string().parse().unwrap_or(0.0));
            Pos {
                symbol: r.get("symbol"),
                quantity,
                price,
                currency: r.try_get("currency").unwrap_or_else(|_| "USD".to_string()),
            }
        })
        .collect();

    // Fan out the live dividend lookups with BOUNDED concurrency (mirrors the
    // sync batch's buffer_unordered pattern) instead of awaiting them one at a
    // time. Each future returns its symbol + the dividend tuple (or None on a
    // fetch error) so a single failure degrades only that symbol. Dedupe
    // first — a symbol held in two currencies is two positions but one fetch.
    use futures_util::StreamExt;
    let symbols: Vec<String> = {
        let mut seen = std::collections::HashSet::new();
        positions
            .iter()
            .filter(|p| seen.insert(p.symbol.clone()))
            .map(|p| p.symbol.clone())
            .collect()
    };
    let redis = &state.redis;
    let fetched: HashMap<String, (f64, Option<String>, Option<String>, i32)> =
        futures_util::stream::iter(symbols.into_iter().map(|symbol| {
            async move {
                // Same engine the per-account endpoint uses, now behind the
                // round-4 Redis envelope cache (C4-C) — the concurrency bound
                // mostly gates cold-cache fills. Map a fetch error to None so
                // it degrades to zero income for this symbol only.
                let info =
                    match crate::services::dividends::fetch_dividends_cached(redis, &symbol, false)
                        .await
                    {
                        Ok(i) => Some((
                            i.annual_rate,
                            i.last_ex_date,
                            i.est_next_ex_date,
                            i.per_year,
                        )),
                        Err(_) => None,
                    };
                (symbol, info)
            }
        }))
        .buffer_unordered(DIVIDEND_FETCH_CONCURRENCY)
        .collect::<Vec<_>>()
        .await
        .into_iter()
        .filter_map(|(sym, info)| info.map(|i| (sym, i)))
        .collect();

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

    let mut contributions: Vec<DividendSymbolContribution> = Vec::new();
    let mut total_income_usd = 0.0_f64;
    let mut total_valued_usd = 0.0_f64;

    // Merge the per-(symbol, currency) sleeves back into ONE contribution
    // per symbol: each sleeve converts its own income/value to USD before
    // the sums, so the per-symbol income is exactly the sum of the
    // correctly-converted per-account incomes.
    let mut symbol_order: Vec<&str> = Vec::new();
    let mut sleeves: HashMap<&str, Vec<&Pos>> = HashMap::new();
    for p in &positions {
        let entry = sleeves.entry(p.symbol.as_str()).or_default();
        if entry.is_empty() {
            symbol_order.push(p.symbol.as_str());
        }
        entry.push(p);
    }

    for symbol in symbol_order {
        // Missing tuple = fetch failed for this symbol: degrade to zero income
        // for it alone, but still surface the row so the position isn't hidden.
        let (annual_rate, last_ex_date, est_next_ex_date, per_year) =
            fetched.get(symbol).cloned().unwrap_or((0.0, None, None, 0));

        let mut quantity = 0.0_f64;
        let mut income_usd = 0.0_f64;
        let mut valued_usd = 0.0_f64;
        let mut priced = false;
        for p in &sleeves[symbol] {
            quantity += p.quantity;
            let income_native = annual_rate * p.quantity;
            income_usd += to_usd(income_native, &p.currency);
            if p.currency == "MXN" && income_native != 0.0 && fx_info.stale {
                fx_stale_used = true;
            }
            // Only priced sleeves feed the yield-on-value denominators.
            if let Some(px) = p.price.filter(|px| *px > 0.0) {
                valued_usd += to_usd(px * p.quantity, &p.currency);
                priced = true;
            }
        }

        let annual_income_usd = (income_usd * 100.0).round() / 100.0;
        // Income / value — identical to the old rate/price form for a
        // single-currency position, and well-defined when the symbol is
        // valued in two currencies.
        let yield_pct = if priced && valued_usd > 0.0 {
            Some(((annual_income_usd / valued_usd * 100.0) * 100.0).round() / 100.0)
        } else {
            None
        };

        total_valued_usd += valued_usd;
        total_income_usd += annual_income_usd;

        contributions.push(DividendSymbolContribution {
            symbol: symbol.to_string(),
            quantity,
            annual_rate,
            annual_income_usd,
            yield_pct,
            last_ex_date,
            est_next_ex_date,
            per_year,
        });
    }

    // Payers first, then by income descending; non-payers (zero income) sink
    // to the bottom while still being available to the frontend if it wants
    // the full list.
    contributions.sort_by(|a, b| {
        b.annual_income_usd
            .partial_cmp(&a.annual_income_usd)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    // ALL upcoming estimated ex-dates among held payers, soonest first — one
    // row per payer, uncapped (the list is bounded by payer count). ISO date
    // strings sort lexicographically, so a plain string sort/compare is
    // chronological; drop estimates already in the past (a payer whose last
    // dividend is older than one pay-interval estimates a date that has
    // already passed).
    let today_date = chrono::Utc::now().date_naive();
    let today = today_date.format("%Y-%m-%d").to_string();
    let upcoming = upcoming_ex_dates(&contributions, &today);

    // Round 4 (C4-B): 12-month projected income calendar, from the same
    // contributions the upcoming list reads.
    let calendar = build_dividend_calendar(&contributions, today_date);

    let total_income_usd = (total_income_usd * 100.0).round() / 100.0;
    let blended_yield_pct = if total_valued_usd > 0.0 && total_income_usd > 0.0 {
        Some(((total_income_usd / total_valued_usd * 100.0) * 100.0).round() / 100.0)
    } else {
        None
    };

    Json(PortfolioDividendsResponse {
        projected_annual_income_usd: total_income_usd,
        blended_yield_pct,
        contributions,
        upcoming_ex_dates: upcoming,
        fx_stale: fx_stale_used,
        calendar,
    })
}

/// One account's share of a position, for the dividend detail sheet (lets
/// the frontend badge Roth/IRA context per account).
#[derive(Serialize)]
struct DividendDetailAccount {
    account_id: String,
    account_name: String,
    account_type: String,
    quantity: f64,
}

/// One projected payment in the next-12-months schedule.
#[derive(Serialize)]
struct DividendScheduleEntry {
    /// Estimated ex-date (YYYY-MM-DD).
    est_date: String,
    /// Expected payment for the whole held position, USD.
    est_amount_usd: f64,
}

/// Per-symbol dividend detail (contract C1) — consumed by the Portfolio
/// tab's click-through sheet. Every nullable stays a real JSON `null` (no
/// skip attrs): the frontend is built against the full field set.
#[derive(Serialize)]
struct DividendDetailResponse {
    symbol: String,
    name: String,
    /// Native currency of the (dominant) position.
    currency: String,
    /// Shares held across all of the user's accounts.
    quantity: f64,
    /// Latest per-share price (native currency); null when unpriced.
    price: Option<f64>,
    market_value_usd: f64,
    /// Null when no account reports a basis (all-or-nothing: a partial
    /// basis would silently overstate yield-on-cost).
    cost_basis_usd: Option<f64>,
    /// Forward annual dividend per share, native currency.
    rate_per_share_annual: f64,
    per_year: i32,
    /// Expected USD payment per distribution for the whole position
    /// (= rate/per_year × quantity, converted).
    per_payment_amount: f64,
    annual_income_usd: f64,
    /// Income / market value, percent (0 when unvalued).
    yield_pct: f64,
    yield_on_cost_pct: Option<f64>,
    last_ex_date: Option<String>,
    est_next_ex_date: Option<String>,
    accounts: Vec<DividendDetailAccount>,
    /// Raw ~2y Yahoo event history, ascending by ex-date.
    history: Vec<crate::services::dividends::DividendEvent>,
    /// Next 12 months: `per_year` payments starting at `est_next_ex_date`,
    /// spaced 365/per_year days.
    schedule: Vec<DividendScheduleEntry>,
    /// Contract C-D: dividend payments that actually LANDED in the user's
    /// accounts, newest first (≤40). Conservatively matched (see
    /// `fetch_dividend_payments`) — may under-report, never mis-attributes.
    /// Empty when nothing matches; never an error.
    payments: Vec<DividendPayment>,
}

/// One real dividend transaction matched to this symbol (contract C-D).
#[derive(Serialize)]
struct DividendPayment {
    /// Transaction date (YYYY-MM-DD).
    date: String,
    amount_usd: f64,
    /// Receiving account's display name (nickname-aware).
    account_name: String,
}

/// Postgres regex matching `symbol` as a whole word (`\m…\M`), or `None`
/// when the symbol contains characters outside `[A-Za-z0-9.-]` — opaque
/// symbols (`CUR:USD`, 401k trust names with spaces) skip transaction
/// matching entirely rather than risk a malformed or over-broad pattern
/// (veto #8: conservative by design).
fn dividend_symbol_word_pattern(symbol: &str) -> Option<String> {
    let sym = symbol.trim();
    if sym.is_empty()
        || !sym
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
    {
        return None;
    }
    // Escape the two permitted non-alphanumerics ('.' would otherwise match
    // any character; '-' is escaped for belt-and-braces clarity).
    let escaped: String = sym
        .chars()
        .flat_map(|c| {
            if c.is_ascii_alphanumeric() {
                vec![c]
            } else {
                vec!['\\', c]
            }
        })
        .collect();
    Some(format!(r"\m{escaped}\M"))
}

/// The C-D payment-history query: positive transactions in the accounts
/// that hold the symbol, tagged `INCOME_DIVIDENDS` (or "dividend"-worded)
/// AND naming the ticker as a whole word. Deliberately conservative — a
/// broker description without the ticker won't match (under-reporting),
/// but a row can never be attributed to the wrong symbol or account.
async fn fetch_dividend_payments(
    db: &sqlx::PgPool,
    user_id: uuid::Uuid,
    holding_account_ids: &[uuid::Uuid],
    symbol: &str,
    fx_usd_to_mxn: f64,
) -> Vec<DividendPayment> {
    let Some(pattern) = dividend_symbol_word_pattern(symbol) else {
        return Vec::new();
    };
    if holding_account_ids.is_empty() {
        return Vec::new();
    }
    let rows = sqlx::query(
        r#"
        SELECT t.date, t.amount, t.currency,
               COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        WHERE a.user_id = $1
          AND t.account_id = ANY($2)
          AND t.amount > 0
          AND (UPPER(COALESCE(t.category_detailed, '')) = 'INCOME_DIVIDENDS'
               OR t.description ~* '\mdividend(o|s|os)?\M')
          AND t.description ~* $3
        ORDER BY t.date DESC
        LIMIT 40
        "#,
    )
    .bind(user_id)
    .bind(holding_account_ids)
    .bind(&pattern)
    .fetch_all(db)
    .await
    .unwrap_or_default();

    rows.iter()
        .map(|r| {
            let amount: f64 = r
                .try_get::<rust_decimal::Decimal, _>("amount")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0);
            let currency: String = r.try_get("currency").unwrap_or_else(|_| "USD".to_string());
            let amount_usd = match currency.as_str() {
                "USD" => amount,
                "MXN" => {
                    if fx_usd_to_mxn > 0.0 {
                        amount / fx_usd_to_mxn
                    } else {
                        amount
                    }
                }
                _ => amount,
            };
            DividendPayment {
                date: r
                    .try_get::<chrono::NaiveDate, _>("date")
                    .map(|d| d.to_string())
                    .unwrap_or_default(),
                amount_usd: (amount_usd * 100.0).round() / 100.0,
                account_name: r.try_get("account_name").unwrap_or_default(),
            }
        })
        .collect()
}

/// One of the user's holdings rows for the requested symbol (plus its
/// owning account), already decoded — input to `build_dividend_detail`.
struct DetailPosition {
    symbol: String,
    name: String,
    quantity: f64,
    price: Option<f64>,
    value: f64,
    cost_basis: Option<f64>,
    currency: String,
    account_id: String,
    account_name: String,
    account_type: String,
}

/// Assemble the C1 response from the user's rows + the (possibly empty)
/// dividend info. Pure so the shape and math are unit-testable offline.
/// `positions` must be non-empty, ordered by value descending — the first
/// row donates the representative name/price/currency.
fn build_dividend_detail(
    positions: &[DetailPosition],
    info: &crate::services::dividends::DividendInfo,
    fx_usd_to_mxn: f64,
    payments: Vec<DividendPayment>,
) -> DividendDetailResponse {
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
    let market_value_usd = round2(positions.iter().map(|p| to_usd(p.value, &p.currency)).sum());

    // Basis is all-or-nothing: summing only the accounts that report one
    // would divide full income by a partial basis and overstate
    // yield-on-cost.
    let cost_basis_usd: Option<f64> = if positions.iter().all(|p| p.cost_basis.is_some()) {
        Some(round2(
            positions
                .iter()
                .map(|p| to_usd(p.cost_basis.unwrap_or(0.0), &p.currency))
                .sum(),
        ))
    } else {
        None
    };

    // Income converts per position (each row in its own currency), same as
    // the portfolio-wide endpoint.
    let annual_income_usd = round2(
        positions
            .iter()
            .map(|p| to_usd(info.annual_rate * p.quantity, &p.currency))
            .sum(),
    );
    let per_payment_amount = if info.per_year > 0 {
        ((annual_income_usd / info.per_year as f64) * 10000.0).round() / 10000.0
    } else {
        0.0
    };

    let yield_pct = if market_value_usd > 0.0 {
        round2(annual_income_usd / market_value_usd * 100.0)
    } else {
        0.0
    };
    let yield_on_cost_pct = cost_basis_usd
        .filter(|cb| *cb > 0.0)
        .map(|cb| round2(annual_income_usd / cb * 100.0));

    // Projection: per_year payments from est_next_ex_date, one cadence step
    // apart, each the expected per-payment amount. Empty for non-payers and
    // Yahoo-unresolvable symbols. Round 4: the stepping is the shared
    // `projected_ex_dates` — the SAME implementation the C4-B calendar uses,
    // so the two can never drift.
    let schedule: Vec<DividendScheduleEntry> =
        projected_ex_dates(info.per_year, info.est_next_ex_date.as_deref(), 365)
            .into_iter()
            .map(|d| DividendScheduleEntry {
                est_date: d.to_string(),
                est_amount_usd: per_payment_amount,
            })
            .collect();

    DividendDetailResponse {
        symbol: first.symbol.clone(),
        name: first.name.clone(),
        currency: first.currency.clone(),
        quantity,
        price: first.price,
        market_value_usd,
        cost_basis_usd,
        rate_per_share_annual: info.annual_rate,
        per_year: info.per_year,
        per_payment_amount,
        annual_income_usd,
        yield_pct,
        yield_on_cost_pct,
        last_ex_date: info.last_ex_date.clone(),
        est_next_ex_date: info.est_next_ex_date.clone(),
        accounts: positions
            .iter()
            .map(|p| DividendDetailAccount {
                account_id: p.account_id.clone(),
                account_name: p.account_name.clone(),
                account_type: p.account_type.clone(),
                quantity: p.quantity,
            })
            .collect(),
        history: info.history.clone(),
        schedule,
        payments,
    }
}

/// Contract C4-D query: `?refresh=true` bypasses the cache's fresh windows
/// (a live fetch happens even inside the 12 h window) while keeping the
/// stale-on-failure fallback. Absent/false → cached behavior.
#[derive(Deserialize)]
pub(super) struct DividendDetailQuery {
    refresh: Option<bool>,
}

/// GET /dividends/{symbol} — dividend detail for one held symbol (contract
/// C1). Matched case-insensitively against the caller's non-cash holdings;
/// 404 when they hold no such symbol. A held symbol Yahoo can't resolve
/// (401k trust units, `CUR:USD` pseudo-symbols) still answers 200 with
/// zeroed rates and empty history/schedule — never a 500.
pub(super) async fn dividend_detail(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    axum::extract::Path(symbol): axum::extract::Path<String>,
    Query(q): Query<DividendDetailQuery>,
) -> Response {
    let rows = sqlx::query(
        r#"
        SELECT h.symbol, h.name, h.quantity, h.price, h.value, h.cost_basis,
               h.currency, a.id AS account_id, a.account_type,
               COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name
        FROM holdings h
        JOIN accounts a ON h.account_id = a.id
        WHERE h.user_id = $1
          AND a.archived_at IS NULL
          AND h.deleted_at IS NULL
          AND COALESCE(h.holding_type, '') <> 'cash'
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

    let dec_f64 = |r: &sqlx::postgres::PgRow, col: &str| -> Option<f64> {
        r.try_get::<Option<rust_decimal::Decimal>, _>(col)
            .ok()
            .flatten()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
    };
    let positions: Vec<DetailPosition> = rows
        .iter()
        .map(|r| DetailPosition {
            symbol: r.get("symbol"),
            name: r.get("name"),
            quantity: dec_f64(r, "quantity").unwrap_or(0.0),
            price: dec_f64(r, "price").filter(|p| *p > 0.0),
            value: dec_f64(r, "value").unwrap_or(0.0),
            cost_basis: dec_f64(r, "cost_basis"),
            currency: r.try_get("currency").unwrap_or_else(|_| "USD".to_string()),
            account_id: r
                .try_get::<uuid::Uuid, _>("account_id")
                .map(|u| u.to_string())
                .unwrap_or_default(),
            account_name: r.get("account_name"),
            account_type: r.try_get::<String, _>("account_type").unwrap_or_default(),
        })
        .collect();

    // Use the stored casing for the Yahoo lookup, not the caller's. A fetch
    // error degrades to the zeroed non-payer info — same policy as the
    // portfolio fan-out. Round 4: Redis-cached (C4-C); `?refresh=true`
    // bypasses the fresh windows (C4-D).
    let canonical_symbol = positions[0].symbol.clone();
    let info = crate::services::dividends::fetch_dividends_cached(
        &state.redis,
        &canonical_symbol,
        q.refresh.unwrap_or(false),
    )
    .await
    .unwrap_or_else(|_| crate::services::dividends::DividendInfo::none(&canonical_symbol));

    let fx_info = latest_usd_mxn_rate(&state.db).await;

    // C-D: real payments, matched only within the accounts that hold the
    // symbol (already fetched above).
    let holding_account_ids: Vec<uuid::Uuid> = rows
        .iter()
        .filter_map(|r| r.try_get::<uuid::Uuid, _>("account_id").ok())
        .collect();
    let payments = fetch_dividend_payments(
        &state.db,
        ctx.user_id,
        &holding_account_ids,
        &canonical_symbol,
        fx_info.rate,
    )
    .await;

    Json(build_dividend_detail(
        &positions,
        &info,
        fx_info.rate,
        payments,
    ))
    .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::dividends::{DividendEvent, DividendInfo};

    /// The C1 contract shape, field for field, for a quarterly payer. The
    /// frontend sheet is built against exactly this JSON.
    #[test]
    fn dividend_detail_matches_contract_c1_for_quarterly_payer() {
        let positions = vec![DetailPosition {
            symbol: "NVDA".to_string(),
            name: "NVIDIA Corp".to_string(),
            quantity: 29.5,
            price: Some(172.40),
            value: 5085.80,
            cost_basis: Some(3100.00),
            currency: "USD".to_string(),
            account_id: "6e9c1a4e-0000-0000-0000-000000000001".to_string(),
            account_name: "Robinhood".to_string(),
            account_type: "brokerage".to_string(),
        }];
        let info = DividendInfo {
            symbol: "NVDA".to_string(),
            annual_rate: 0.04,
            last_amount: 0.01,
            last_ex_date: Some("2026-06-11".to_string()),
            est_next_ex_date: Some("2026-09-10".to_string()),
            per_year: 4,
            history: vec![
                DividendEvent {
                    ex_date: "2024-08-28".to_string(),
                    amount_per_share: 0.01,
                },
                DividendEvent {
                    ex_date: "2026-06-11".to_string(),
                    amount_per_share: 0.01,
                },
            ],
        };

        let got = serde_json::to_value(build_dividend_detail(&positions, &info, 20.0, Vec::new()))
            .unwrap();
        let want = serde_json::json!({
            "symbol": "NVDA",
            "name": "NVIDIA Corp",
            "currency": "USD",
            "quantity": 29.5,
            "price": 172.40,
            "market_value_usd": 5085.80,
            "cost_basis_usd": 3100.00,
            "rate_per_share_annual": 0.04,
            "per_year": 4,
            "per_payment_amount": 0.295,
            "annual_income_usd": 1.18,
            "yield_pct": 0.02,
            "yield_on_cost_pct": 0.04,
            "last_ex_date": "2026-06-11",
            "est_next_ex_date": "2026-09-10",
            "accounts": [
                {
                    "account_id": "6e9c1a4e-0000-0000-0000-000000000001",
                    "account_name": "Robinhood",
                    "account_type": "brokerage",
                    "quantity": 29.5
                }
            ],
            "history": [
                {"ex_date": "2024-08-28", "amount_per_share": 0.01},
                {"ex_date": "2026-06-11", "amount_per_share": 0.01}
            ],
            "schedule": [
                {"est_date": "2026-09-10", "est_amount_usd": 0.295},
                {"est_date": "2026-12-10", "est_amount_usd": 0.295},
                {"est_date": "2027-03-11", "est_amount_usd": 0.295},
                {"est_date": "2027-06-10", "est_amount_usd": 0.295}
            ],
            "payments": []
        });
        assert_eq!(got, want);
    }

    /// A held symbol Yahoo can't resolve (401k trust units, CUR:USD): 200
    /// with zeroed rates, nulls, and empty history/schedule — never a 500.
    #[test]
    fn dividend_detail_unresolvable_symbol_degrades_to_nulls_and_empties() {
        let positions = vec![DetailPosition {
            symbol: "VANG TARGET RET 2045".to_string(),
            name: "Vanguard Target Retirement 2045 Trust".to_string(),
            quantity: 100.0,
            price: None,
            value: 0.0,
            cost_basis: None,
            currency: "USD".to_string(),
            account_id: "6e9c1a4e-0000-0000-0000-000000000002".to_string(),
            account_name: "Employer 401k".to_string(),
            account_type: "401k".to_string(),
        }];
        let info = DividendInfo::none("VANG TARGET RET 2045");

        let got = serde_json::to_value(build_dividend_detail(&positions, &info, 20.0, Vec::new()))
            .unwrap();
        assert_eq!(got["per_year"], 0);
        assert_eq!(got["rate_per_share_annual"], 0.0);
        assert_eq!(got["annual_income_usd"], 0.0);
        assert_eq!(got["yield_pct"], 0.0);
        // Nullables are real JSON nulls, not absent keys.
        assert!(got["price"].is_null());
        assert!(got["cost_basis_usd"].is_null());
        assert!(got["yield_on_cost_pct"].is_null());
        assert!(got["last_ex_date"].is_null());
        assert!(got["est_next_ex_date"].is_null());
        assert_eq!(got["history"], serde_json::json!([]));
        assert_eq!(got["schedule"], serde_json::json!([]));
        assert_eq!(got["accounts"][0]["account_type"], "401k");
    }

    /// Same symbol held in USD and MXN accounts: each sleeve converts in its
    /// own currency before the sums (B5).
    #[test]
    fn dividend_detail_converts_each_currency_sleeve_separately() {
        let positions = vec![
            DetailPosition {
                symbol: "ACME".to_string(),
                name: "Acme Corp".to_string(),
                quantity: 10.0,
                price: Some(100.0),
                value: 1000.0,
                cost_basis: Some(800.0),
                currency: "USD".to_string(),
                account_id: "a".to_string(),
                account_name: "US broker".to_string(),
                account_type: "brokerage".to_string(),
            },
            DetailPosition {
                symbol: "ACME".to_string(),
                name: "Acme Corp".to_string(),
                quantity: 10.0,
                price: Some(2000.0),
                value: 20000.0,
                cost_basis: Some(16000.0),
                currency: "MXN".to_string(),
                account_id: "b".to_string(),
                account_name: "MX broker".to_string(),
                account_type: "brokerage".to_string(),
            },
        ];
        let info = DividendInfo {
            symbol: "ACME".to_string(),
            annual_rate: 4.0,
            last_amount: 1.0,
            last_ex_date: Some("2026-06-01".to_string()),
            est_next_ex_date: Some("2026-08-31".to_string()),
            per_year: 4,
            history: Vec::new(),
        };

        let got = serde_json::to_value(build_dividend_detail(&positions, &info, 20.0, Vec::new()))
            .unwrap();
        // 1000 USD + 20000 MXN / 20 = 2000 USD.
        assert_eq!(got["market_value_usd"], 2000.0);
        // Income: 40 USD + 40 MXN / 20 = 42 USD; NOT 80 (both as USD) nor
        // 4 (both as MXN) — the old MAX(currency) bug's two failure modes.
        assert_eq!(got["annual_income_usd"], 42.0);
        // Basis: 800 USD + 16000 MXN / 20 = 1600 USD.
        assert_eq!(got["cost_basis_usd"], 1600.0);
        assert_eq!(got["quantity"], 20.0);
        assert_eq!(got["accounts"].as_array().unwrap().len(), 2);
    }

    // Tiny date literal helper, duplicated in `holdings::tests` — both test
    // mods predate the dashboard split, where they shared one `tests` module.
    fn day(y: i32, m: u32, d: u32) -> chrono::NaiveDate {
        chrono::NaiveDate::from_ymd_opt(y, m, d).unwrap()
    }

    /// Ticker-shaped symbols produce a whole-word pattern with regex
    /// metacharacters escaped.
    #[test]
    fn dividend_symbol_pattern_escapes_safe_symbols() {
        assert_eq!(
            dividend_symbol_word_pattern("SCHD").as_deref(),
            Some(r"\mSCHD\M")
        );
        assert_eq!(
            dividend_symbol_word_pattern("BRK.B").as_deref(),
            Some(r"\mBRK\.B\M")
        );
        assert_eq!(
            dividend_symbol_word_pattern("BF-B").as_deref(),
            Some(r"\mBF\-B\M")
        );
    }

    /// Symbols with characters outside [A-Za-z0-9.-] (pseudo-symbols, trust
    /// names) skip transaction matching entirely — `[]`, never a bad regex.
    #[test]
    fn dividend_symbol_pattern_rejects_unsafe_symbols() {
        assert!(dividend_symbol_word_pattern("CUR:USD").is_none());
        assert!(dividend_symbol_word_pattern("VANG TARGET RET 2045").is_none());
        assert!(dividend_symbol_word_pattern("").is_none());
        assert!(dividend_symbol_word_pattern("A|B").is_none());
    }

    // =================================================================
    // C-E — CSV quoting
    // =================================================================

    /// Ten payers spanning Jul–Oct: ALL ten surface (the old truncate(5)
    /// cut exactly the September/October rows), ascending, past dates and
    /// non-payers dropped.
    #[test]
    fn upcoming_ex_dates_uncapped_ascending_and_future_only() {
        let mk = |sym: &str, date: Option<&str>, income: f64| DividendSymbolContribution {
            symbol: sym.to_string(),
            quantity: 1.0,
            annual_rate: 1.0,
            annual_income_usd: income,
            yield_pct: None,
            last_ex_date: None,
            est_next_ex_date: date.map(str::to_string),
            per_year: 4,
        };
        let contributions = vec![
            mk("A", Some("2026-07-10"), 10.0),
            mk("B", Some("2026-07-24"), 10.0),
            mk("C", Some("2026-08-05"), 10.0),
            mk("D", Some("2026-08-19"), 10.0),
            mk("E", Some("2026-09-02"), 10.0),
            mk("F", Some("2026-09-16"), 10.0),
            mk("G", Some("2026-09-30"), 10.0),
            mk("H", Some("2026-10-08"), 10.0),
            mk("I", Some("2026-10-21"), 10.0),
            mk("J", Some("2026-10-29"), 10.0),
            // Dropped: estimate already past / zero projected income.
            mk("PAST", Some("2026-06-30"), 10.0),
            mk("NOPAY", Some("2026-09-09"), 0.0),
        ];
        let upcoming = upcoming_ex_dates(&contributions, "2026-07-06");
        assert_eq!(upcoming.len(), 10, "no server-side cap");
        assert!(upcoming
            .windows(2)
            .all(|w| w[0].est_next_ex_date <= w[1].est_next_ex_date));
        assert!(upcoming
            .iter()
            .any(|u| u.est_next_ex_date.starts_with("2026-09")));
        assert!(upcoming
            .iter()
            .all(|u| u.symbol != "PAST" && u.symbol != "NOPAY"));
    }

    // =================================================================
    // Round 4 B4 — shared date-stepping + the C4-B calendar
    // =================================================================

    /// Builder for calendar-test contributions.
    fn contribution(
        symbol: &str,
        annual_income_usd: f64,
        per_year: i32,
        est_next: Option<&str>,
    ) -> DividendSymbolContribution {
        DividendSymbolContribution {
            symbol: symbol.to_string(),
            quantity: 1.0,
            annual_rate: annual_income_usd,
            annual_income_usd,
            yield_pct: None,
            last_ex_date: None,
            est_next_ex_date: est_next.map(str::to_string),
            per_year,
        }
    }

    /// The stepping fn: `per_year` dates one cadence step apart, empty for
    /// non-payers and missing estimates, pruned by the horizon.
    #[test]
    fn projected_ex_dates_steps_and_prunes() {
        // Quarterly: 4 dates, 91 days apart.
        let dates = projected_ex_dates(4, Some("2026-09-10"), 365);
        assert_eq!(
            dates,
            vec![
                day(2026, 9, 10),
                day(2026, 12, 10),
                day(2027, 3, 11),
                day(2027, 6, 10)
            ]
        );
        // Non-payer / missing / unparsable estimate: empty.
        assert!(projected_ex_dates(0, Some("2026-09-10"), 365).is_empty());
        assert!(projected_ex_dates(4, None, 365).is_empty());
        assert!(projected_ex_dates(4, Some("not-a-date"), 365).is_empty());
        // A tighter horizon prunes the later steps.
        assert_eq!(projected_ex_dates(4, Some("2026-09-10"), 100).len(), 2);
    }

    /// The detail endpoint's `schedule` and the calendar step through the
    /// SAME fn — for identical inputs their dates agree exactly.
    #[test]
    fn detail_schedule_and_calendar_dates_agree() {
        let info = DividendInfo {
            symbol: "KO".to_string(),
            annual_rate: 2.0,
            last_amount: 0.5,
            last_ex_date: Some("2026-06-12".to_string()),
            est_next_ex_date: Some("2026-09-12".to_string()),
            per_year: 4,
            history: Vec::new(),
        };
        let positions = vec![DetailPosition {
            symbol: "KO".to_string(),
            name: "Coca-Cola".to_string(),
            quantity: 10.0,
            price: Some(70.0),
            value: 700.0,
            cost_basis: None,
            currency: "USD".to_string(),
            account_id: "a".to_string(),
            account_name: "Broker".to_string(),
            account_type: "brokerage".to_string(),
        }];
        let detail = build_dividend_detail(&positions, &info, 20.0, Vec::new());
        let schedule_dates: Vec<String> =
            detail.schedule.iter().map(|s| s.est_date.clone()).collect();

        let contributions = vec![contribution("KO", 20.0, 4, Some("2026-09-12"))];
        let calendar = build_dividend_calendar(&contributions, day(2026, 7, 6));
        let calendar_dates: Vec<String> = calendar
            .iter()
            .flat_map(|m| m.entries.iter().map(|e| e.est_date.clone()))
            .collect();
        assert_eq!(schedule_dates, calendar_dates);
    }

    /// Quarterly payer: 4 entries in 4 distinct months, summing to the
    /// annual income (±1¢ rounding); always exactly 12 chronological months.
    #[test]
    fn calendar_quarterly_payer_four_months_summing_to_annual() {
        let contributions = vec![contribution("KO", 400.0, 4, Some("2026-07-14"))];
        let calendar = build_dividend_calendar(&contributions, day(2026, 7, 6));

        assert_eq!(calendar.len(), 12);
        assert_eq!(calendar[0].month, "2026-07");
        assert_eq!(calendar[11].month, "2027-06");
        assert!(calendar.windows(2).all(|w| w[0].month < w[1].month));

        let paying: Vec<&DividendCalendarMonth> =
            calendar.iter().filter(|m| !m.entries.is_empty()).collect();
        assert_eq!(paying.len(), 4);
        assert_eq!(
            paying.iter().map(|m| m.month.as_str()).collect::<Vec<_>>(),
            vec!["2026-07", "2026-10", "2027-01", "2027-04"]
        );
        let total: f64 = calendar.iter().map(|m| m.total_usd).sum();
        assert!((total - 400.0).abs() < 0.01 + 1e-9);
        assert_eq!(paying[0].entries[0].amount_usd, 100.0);
        assert_eq!(paying[0].entries[0].est_date, "2026-07-14");
    }

    /// Monthly payer fills all 12 buckets; annual payer fills exactly 1.
    #[test]
    fn calendar_monthly_fills_twelve_annual_fills_one() {
        let contributions = vec![
            contribution("O", 120.0, 12, Some("2026-07-10")),
            contribution("ANN", 50.0, 1, Some("2027-03-01")),
        ];
        let calendar = build_dividend_calendar(&contributions, day(2026, 7, 6));
        assert!(calendar
            .iter()
            .all(|m| m.entries.iter().any(|e| e.symbol == "O")));
        let ann_months: Vec<&str> = calendar
            .iter()
            .filter(|m| m.entries.iter().any(|e| e.symbol == "ANN"))
            .map(|m| m.month.as_str())
            .collect();
        assert_eq!(ann_months, vec!["2027-03"]);
        let total: f64 = calendar.iter().map(|m| m.total_usd).sum();
        assert!((total - 170.0).abs() < 0.01 + 1e-9);
    }

    /// Non-payers (`per_year == 0` — failed fetches, unresolvable symbols)
    /// contribute nothing; a payer-free portfolio still gets 12 empty months.
    #[test]
    fn calendar_zero_per_year_contributes_nothing() {
        let contributions = vec![
            contribution("VANG TARGET RET 2045", 0.0, 0, None),
            contribution("CUR:USD", 0.0, 0, Some("2026-08-01")),
        ];
        let calendar = build_dividend_calendar(&contributions, day(2026, 7, 6));
        assert_eq!(calendar.len(), 12);
        assert!(calendar
            .iter()
            .all(|m| m.entries.is_empty() && m.total_usd == 0.0));
    }

    /// The acknowledged delta vs `projected_annual_income_usd`: an annual
    /// payer whose next date falls past the 12-month window contributes
    /// nothing — every other payer's income lands in full.
    #[test]
    fn calendar_drops_only_payments_outside_the_window() {
        let contributions = vec![
            contribution("KO", 400.0, 4, Some("2026-07-14")),
            // Window is 2026-07 .. 2027-06; this annual estimate is 2027-07.
            contribution("FAR", 50.0, 1, Some("2027-07-01")),
        ];
        let calendar = build_dividend_calendar(&contributions, day(2026, 7, 6));
        let total: f64 = calendar.iter().map(|m| m.total_usd).sum();
        assert!((total - 400.0).abs() < 0.01 + 1e-9);
        assert!(calendar
            .iter()
            .all(|m| m.entries.iter().all(|e| e.symbol != "FAR")));
    }

    /// Entries within a month sort by amount descending; the December
    /// year-rollover buckets correctly.
    #[test]
    fn calendar_entries_sorted_by_amount_descending() {
        let contributions = vec![
            contribution("SMALL", 40.0, 4, Some("2026-09-13")),
            contribution("BIG", 400.0, 4, Some("2026-09-12")),
        ];
        let calendar = build_dividend_calendar(&contributions, day(2026, 7, 6));
        let sept = calendar.iter().find(|m| m.month == "2026-09").unwrap();
        assert_eq!(
            sept.entries
                .iter()
                .map(|e| e.symbol.as_str())
                .collect::<Vec<_>>(),
            vec!["BIG", "SMALL"]
        );
        assert_eq!(sept.total_usd, 110.0);
        // Quarterly from September crosses the year boundary: 2026-12 pays.
        assert!(calendar
            .iter()
            .any(|m| m.month == "2026-12" && !m.entries.is_empty()));
    }

    // =================================================================
    // Round 4 B5 — shape-freeze: the full portfolio response snapshot
    // =================================================================

    /// The complete `PortfolioDividendsResponse` JSON from fixed inputs —
    /// a quarterly + monthly + unresolvable mix. Every round-3 field is
    /// byte-identical; the ONLY addition vs the round-3 shape is
    /// `calendar` (asserted explicitly on the key set below).
    #[test]
    fn portfolio_dividends_response_shape_freeze() {
        let contributions = vec![
            contribution_full(
                "O",
                12.0,
                3.0,
                36.0,
                Some(5.0),
                Some("2026-07-01"),
                Some("2026-07-15"),
                12,
            ),
            contribution_full(
                "KO",
                10.0,
                2.0,
                20.0,
                Some(2.86),
                Some("2026-06-13"),
                Some("2026-09-12"),
                4,
            ),
            contribution_full("VANG TARGET RET 2045", 100.0, 0.0, 0.0, None, None, None, 0),
        ];
        let today = day(2026, 7, 6);
        let response = PortfolioDividendsResponse {
            projected_annual_income_usd: 56.0,
            blended_yield_pct: Some(4.0),
            upcoming_ex_dates: upcoming_ex_dates(&contributions, "2026-07-06"),
            calendar: build_dividend_calendar(&contributions, today),
            contributions,
            fx_stale: false,
        };
        let got = serde_json::to_value(&response).unwrap();

        // The no-behavior-change promise, key for key: round-3 top-level
        // keys plus exactly ONE addition.
        let round3_keys = [
            "projected_annual_income_usd",
            "blended_yield_pct",
            "contributions",
            "upcoming_ex_dates",
            "fx_stale",
        ];
        let mut got_keys: Vec<&str> = got
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        got_keys.sort_unstable();
        let mut want_keys: Vec<&str> = round3_keys
            .iter()
            .copied()
            .chain(std::iter::once("calendar"))
            .collect();
        want_keys.sort_unstable();
        assert_eq!(got_keys, want_keys, "exactly one added key: `calendar`");

        let want = serde_json::json!({
            "projected_annual_income_usd": 56.0,
            "blended_yield_pct": 4.0,
            "contributions": [
                {"symbol": "O", "quantity": 12.0, "annual_rate": 3.0,
                 "annual_income_usd": 36.0, "yield_pct": 5.0,
                 "last_ex_date": "2026-07-01", "est_next_ex_date": "2026-07-15",
                 "per_year": 12},
                {"symbol": "KO", "quantity": 10.0, "annual_rate": 2.0,
                 "annual_income_usd": 20.0, "yield_pct": 2.86,
                 "last_ex_date": "2026-06-13", "est_next_ex_date": "2026-09-12",
                 "per_year": 4},
                {"symbol": "VANG TARGET RET 2045", "quantity": 100.0,
                 "annual_rate": 0.0, "annual_income_usd": 0.0, "yield_pct": null,
                 "last_ex_date": null, "est_next_ex_date": null, "per_year": 0}
            ],
            "upcoming_ex_dates": [
                {"symbol": "O", "est_next_ex_date": "2026-07-15", "annual_income_usd": 36.0},
                {"symbol": "KO", "est_next_ex_date": "2026-09-12", "annual_income_usd": 20.0}
            ],
            "fx_stale": false,
            "calendar": [
                {"month": "2026-07", "total_usd": 3.0, "entries": [
                    {"symbol": "O", "est_date": "2026-07-15", "amount_usd": 3.0}]},
                {"month": "2026-08", "total_usd": 3.0, "entries": [
                    {"symbol": "O", "est_date": "2026-08-14", "amount_usd": 3.0}]},
                {"month": "2026-09", "total_usd": 8.0, "entries": [
                    {"symbol": "KO", "est_date": "2026-09-12", "amount_usd": 5.0},
                    {"symbol": "O", "est_date": "2026-09-13", "amount_usd": 3.0}]},
                {"month": "2026-10", "total_usd": 3.0, "entries": [
                    {"symbol": "O", "est_date": "2026-10-13", "amount_usd": 3.0}]},
                {"month": "2026-11", "total_usd": 3.0, "entries": [
                    {"symbol": "O", "est_date": "2026-11-12", "amount_usd": 3.0}]},
                {"month": "2026-12", "total_usd": 8.0, "entries": [
                    {"symbol": "KO", "est_date": "2026-12-12", "amount_usd": 5.0},
                    {"symbol": "O", "est_date": "2026-12-12", "amount_usd": 3.0}]},
                {"month": "2027-01", "total_usd": 3.0, "entries": [
                    {"symbol": "O", "est_date": "2027-01-11", "amount_usd": 3.0}]},
                {"month": "2027-02", "total_usd": 3.0, "entries": [
                    {"symbol": "O", "est_date": "2027-02-10", "amount_usd": 3.0}]},
                {"month": "2027-03", "total_usd": 8.0, "entries": [
                    {"symbol": "KO", "est_date": "2027-03-13", "amount_usd": 5.0},
                    {"symbol": "O", "est_date": "2027-03-12", "amount_usd": 3.0}]},
                {"month": "2027-04", "total_usd": 3.0, "entries": [
                    {"symbol": "O", "est_date": "2027-04-11", "amount_usd": 3.0}]},
                {"month": "2027-05", "total_usd": 3.0, "entries": [
                    {"symbol": "O", "est_date": "2027-05-11", "amount_usd": 3.0}]},
                {"month": "2027-06", "total_usd": 8.0, "entries": [
                    {"symbol": "KO", "est_date": "2027-06-12", "amount_usd": 5.0},
                    {"symbol": "O", "est_date": "2027-06-10", "amount_usd": 3.0}]}
            ]
        });
        assert_eq!(got, want);
    }

    /// Fully-specified contribution for the shape-freeze snapshot.
    #[allow(clippy::too_many_arguments)]
    fn contribution_full(
        symbol: &str,
        quantity: f64,
        annual_rate: f64,
        annual_income_usd: f64,
        yield_pct: Option<f64>,
        last_ex_date: Option<&str>,
        est_next_ex_date: Option<&str>,
        per_year: i32,
    ) -> DividendSymbolContribution {
        DividendSymbolContribution {
            symbol: symbol.to_string(),
            quantity,
            annual_rate,
            annual_income_usd,
            yield_pct,
            last_ex_date: last_ex_date.map(str::to_string),
            est_next_ex_date: est_next_ex_date.map(str::to_string),
            per_year,
        }
    }
}
