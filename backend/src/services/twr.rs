//! True time-weighted return (TWR) for the investment portfolio.
//!
//! Why TWR (and why the old net-worth-indexing was wrong): indexing net
//! worth (or summed account balances) to its first value reports absurd
//! returns, because the series ramps from ~0 as accounts first sync —
//! contributions get conflated with market gains. TWR is the standard fix:
//! it values the portfolio every day and chain-links daily returns, with
//! external cashflows divided out so contribution *timing and size* don't
//! affect the figure (the GIPS "daily valuation method").
//!
//! Data model, and the one subtlety that makes this correct with the data
//! we actually have:
//!
//!   * `holding_lots` is sparse — it only captures acquisitions the (future)
//!     Plaid investments-transactions sync recorded; the bulk of each
//!     position predates lot tracking. So we CANNOT reconstruct share counts
//!     by summing lots — that would miss most of the portfolio (e.g. GOOG
//!     has thousands of shares but ~zero lot qty).
//!   * Instead we treat the CURRENT quantity as ground truth and walk
//!     backward: `shares(t) = current_qty − Σ(lots acquired after t)
//!     + Σ(disposals after t)`. Everything before the first lot is the
//!       "opening position", valued at the start-date price — a real opening
//!       market value, not a ramp from zero.
//!   * Flows are then only the incremental lot buys/sells, dated. The opening
//!     position is the starting value, NOT a flow.
//!
//! Valuation uses the per-symbol daily quote cache (`benchmark.rs`,
//! `benchmark_prices`). v1 prices USD-denominated securities only; anything
//! we can't price historically (opaque Plaid security_ids, non-USD funds) is
//! reported as *uncovered* via `coverage_pct` rather than silently dropped.
//!
//! Output is a daily growth index of $1 invested at `start_date` (1.0 at the
//! start), alongside the S&P 500 indexed over the same dates. Because the
//! index is multiplicative, the caller can compute the TWR over any sub-range
//! by division: `twr[a,b] = index(b)/index(a) − 1`.

use std::collections::HashMap;

use chrono::{Duration, NaiveDate, Utc};
use sqlx::{PgPool, Row};
use uuid::Uuid;

use crate::services::benchmark;

#[derive(Debug, serde::Serialize)]
pub struct TwrPoint {
    pub date: String,
    /// Growth index of $1 invested at `start_date` (1.0 at the start).
    pub twr: f64,
    /// S&P 500 growth index over the same dates (1.0 at the start).
    pub sp: f64,
}

#[derive(Debug, serde::Serialize)]
pub struct TwrResult {
    pub start_date: Option<String>,
    pub end_date: Option<String>,
    /// Share (0..1) of current portfolio value (USD) we can price
    /// historically — i.e. what fraction of the portfolio the TWR reflects.
    pub coverage_pct: f64,
    pub covered_value_usd: f64,
    pub total_value_usd: f64,
    /// Cumulative TWR over the full window (final growth index − 1).
    pub your_twr: f64,
    /// Cumulative S&P 500 TWR over the same window.
    pub sp_twr: f64,
    pub points: Vec<TwrPoint>,
}

impl TwrResult {
    fn empty() -> Self {
        TwrResult {
            start_date: None,
            end_date: None,
            coverage_pct: 0.0,
            covered_value_usd: 0.0,
            total_value_usd: 0.0,
            your_twr: 0.0,
            sp_twr: 0.0,
            points: Vec::new(),
        }
    }
}

/// A symbol looks like a real exchange ticker we can quote on Yahoo. Mirrors
/// the frontend's "hide Plaid security_id hash" heuristic: real tickers are
/// short and upper-case; Plaid `security_id`s are long and mixed-case.
/// `CUR:*` pseudo-symbols are brokerage cash, not securities.
pub(crate) fn looks_like_ticker(s: &str) -> bool {
    if s.is_empty() || s.starts_with("CUR:") {
        return false;
    }
    let len = s.chars().count();
    if len > 8 {
        return false;
    }
    if s != s.to_uppercase() && len > 4 {
        return false;
    }
    true
}

fn dec(r: &sqlx::postgres::PgRow, c: &str) -> f64 {
    r.try_get::<rust_decimal::Decimal, _>(c)
        .ok()
        .and_then(|d| d.to_string().parse().ok())
        .unwrap_or(0.0)
}

/// Close on or just before `d`; falls back to the earliest close when `d`
/// predates the series. Series must be ascending by date.
fn close_on(series: &[(NaiveDate, f64)], d: NaiveDate) -> f64 {
    if series.is_empty() {
        return 0.0;
    }
    match series.binary_search_by(|(pd, _)| pd.cmp(&d)) {
        Ok(i) => series[i].1,
        Err(0) => series[0].1,
        Err(i) => series[i - 1].1,
    }
}

/// One dated share-quantity change (a lot acquisition or a disposal).
struct QtyEvent {
    date: NaiveDate,
    qty: f64,
}

pub async fn portfolio_twr(db: &PgPool, user_id: Uuid, benchmark: Option<&str>) -> TwrResult {
    // 1. Holdings → current qty per candidate symbol + total portfolio value
    //    in USD. v1 only prices USD securities historically, so non-USD
    //    holdings count toward the total (denominator) via the current FX
    //    rate but are treated as uncovered.
    let fx_usd_to_mxn = current_usd_mxn(db).await;
    // Soft-deleted holdings (round 3 undo window) are invisible to TWR.
    let holdings = sqlx::query(
        "SELECT symbol, currency, quantity, value FROM holdings WHERE user_id = $1 AND deleted_at IS NULL",
    )
    .bind(user_id)
    .fetch_all(db)
    .await
    .unwrap_or_default();
    if holdings.is_empty() {
        return TwrResult::empty();
    }

    let mut total_value = 0.0_f64;
    let mut cur_qty: HashMap<String, f64> = HashMap::new();
    let mut sym_value: HashMap<String, f64> = HashMap::new();
    for r in &holdings {
        let sym: String = r.try_get("symbol").unwrap_or_default();
        let ccy: String = r.try_get("currency").unwrap_or_default();
        let qty = dec(r, "quantity");
        let val = dec(r, "value");
        let val_usd = match ccy.as_str() {
            "USD" => val,
            "MXN" if fx_usd_to_mxn > 0.0 => val / fx_usd_to_mxn,
            _ => val,
        };
        total_value += val_usd;
        // v1 prices USD tickers only.
        if ccy == "USD" && looks_like_ticker(&sym) {
            *cur_qty.entry(sym.clone()).or_default() += qty;
            *sym_value.entry(sym.clone()).or_default() += val;
        }
    }
    if cur_qty.is_empty() || total_value <= 0.0 {
        let mut e = TwrResult::empty();
        e.total_value_usd = total_value;
        return e;
    }

    // 2. Make sure we have fresh quotes for the S&P and each candidate symbol.
    //    All best-effort: a failed fetch just falls back to whatever is cached
    //    (and an uncached symbol drops to "uncovered").
    let _ = benchmark::ensure_fresh(db).await;
    for sym in cur_qty.keys() {
        let _ = benchmark::ensure_symbol_fresh(db, sym, sym).await;
    }

    // 3. Pull each candidate's stored series; those with data are "covered".
    let epoch = NaiveDate::from_ymd_opt(2000, 1, 1).unwrap();
    let mut quotes: HashMap<String, Vec<(NaiveDate, f64)>> = HashMap::new();
    for sym in cur_qty.keys() {
        let s = benchmark::series(db, sym, epoch).await;
        if !s.is_empty() {
            quotes.insert(sym.clone(), s);
        }
    }
    let covered_value: f64 = quotes
        .keys()
        .map(|s| sym_value.get(s).copied().unwrap_or(0.0))
        .sum();
    let coverage_pct = if total_value > 0.0 {
        covered_value / total_value
    } else {
        0.0
    };
    if quotes.is_empty() {
        let mut e = TwrResult::empty();
        e.total_value_usd = total_value;
        e.covered_value_usd = covered_value;
        e.coverage_pct = coverage_pct;
        return e;
    }

    // 4. Lots (buys) + disposals (sells) for covered symbols. These give the
    //    dated external flows and the share-count deltas.
    let lot_rows = sqlx::query(
        "SELECT h.symbol AS symbol, l.qty, l.cost_per_unit, l.usd_fx_rate, l.acquired_at \
         FROM holding_lots l JOIN holdings h ON h.id = l.holding_id \
         WHERE l.user_id = $1 AND l.qty > 0 AND h.deleted_at IS NULL",
    )
    .bind(user_id)
    .fetch_all(db)
    .await
    .unwrap_or_default();
    let disp_rows = sqlx::query(
        "SELECT h.symbol AS symbol, d.qty_sold, d.sell_price_per_unit, d.sell_fx_rate, d.sell_date \
         FROM lot_disposals d JOIN holdings h ON h.id = d.holding_id \
         WHERE d.user_id = $1 AND h.deleted_at IS NULL",
    )
    .bind(user_id)
    .fetch_all(db)
    .await
    .unwrap_or_default();

    // Net external flow per day, USD: buys add capital (+), sells remove (−).
    let mut flow_map: HashMap<NaiveDate, f64> = HashMap::new();
    let mut lots_by_sym: HashMap<String, Vec<QtyEvent>> = HashMap::new();
    let mut disps_by_sym: HashMap<String, Vec<QtyEvent>> = HashMap::new();

    for r in &lot_rows {
        let sym: String = r.try_get("symbol").unwrap_or_default();
        if !quotes.contains_key(&sym) {
            continue;
        }
        let Ok(date) = r.try_get::<NaiveDate, _>("acquired_at") else {
            continue;
        };
        let qty = dec(r, "qty");
        let cpu = dec(r, "cost_per_unit");
        let fx = dec(r, "usd_fx_rate");
        let cost_usd = if fx > 0.0 { qty * cpu / fx } else { qty * cpu };
        *flow_map.entry(date).or_default() += cost_usd;
        lots_by_sym
            .entry(sym)
            .or_default()
            .push(QtyEvent { date, qty });
    }
    for r in &disp_rows {
        let sym: String = r.try_get("symbol").unwrap_or_default();
        if !quotes.contains_key(&sym) {
            continue;
        }
        let Ok(date) = r.try_get::<NaiveDate, _>("sell_date") else {
            continue;
        };
        let qty = dec(r, "qty_sold");
        let spp = dec(r, "sell_price_per_unit");
        let fx = dec(r, "sell_fx_rate");
        let proceeds_usd = if fx > 0.0 { qty * spp / fx } else { qty * spp };
        *flow_map.entry(date).or_default() -= proceeds_usd;
        disps_by_sym
            .entry(sym)
            .or_default()
            .push(QtyEvent { date, qty });
    }

    // 5. Window. Start at the earliest acquisition we know about (the first
    //    point we have transaction info for); before that we don't know the
    //    composition. With no covered lots, fall back to a 1-year lookback of
    //    the current positions (a buy-and-hold price return).
    let today = Utc::now().date_naive();
    let earliest_lot = lots_by_sym.values().flatten().map(|e| e.date).min();
    let start = earliest_lot.unwrap_or(today - Duration::days(365));
    let latest_quote = quotes
        .values()
        .filter_map(|v| v.last().map(|(d, _)| *d))
        .max()
        .unwrap_or(today);
    let end = latest_quote.min(today);
    if start >= end {
        let mut e = TwrResult::empty();
        e.total_value_usd = total_value;
        e.covered_value_usd = covered_value;
        e.coverage_pct = coverage_pct;
        return e;
    }

    // Resolve the requested benchmark (defaults to S&P 500) and freshen its
    // series before reading. A bad/illiquid symbol yields an empty series, so
    // `sp_first` is 0.0 and the comparison index flat-lines at 1.0 — the card
    // still renders the portfolio line, just without a benchmark overlay.
    let (bench_key, bench_yahoo) = benchmark::resolve_benchmark(benchmark);
    let _ = benchmark::ensure_symbol_fresh(db, bench_yahoo, bench_key).await;
    let sp = benchmark::series(db, bench_key, epoch).await;
    let sp_first = close_on(&sp, start);

    // 6. Daily-valuation TWR. Iterate calendar days; quotes forward-fill over
    //    weekends/holidays via close_on, so a no-trade day has r=0 (unless a
    //    cashflow lands on it).
    let mut points: Vec<TwrPoint> = Vec::new();
    let mut prev_v: Option<f64> = None;
    let mut growth = 1.0_f64;
    let mut d = start;
    while d <= end {
        let mut v = 0.0;
        for (sym, qseries) in &quotes {
            let base = *cur_qty.get(sym).unwrap_or(&0.0);
            let future_buys: f64 = lots_by_sym
                .get(sym)
                .map(|evs| evs.iter().filter(|e| e.date > d).map(|e| e.qty).sum())
                .unwrap_or(0.0);
            let future_sells: f64 = disps_by_sym
                .get(sym)
                .map(|evs| evs.iter().filter(|e| e.date > d).map(|e| e.qty).sum())
                .unwrap_or(0.0);
            let shares = (base - future_buys + future_sells).max(0.0);
            if shares > 0.0 {
                v += shares * close_on(qseries, d);
            }
        }
        let f = *flow_map.get(&d).unwrap_or(&0.0);
        if let Some(pv) = prev_v {
            if pv > 0.0 {
                let r = (v - f) / pv - 1.0;
                growth *= 1.0 + r;
            }
        }
        prev_v = Some(v);
        let sp_idx = if sp_first > 0.0 {
            close_on(&sp, d) / sp_first
        } else {
            1.0
        };
        points.push(TwrPoint {
            date: d.format("%Y-%m-%d").to_string(),
            twr: growth,
            sp: sp_idx,
        });
        d += Duration::days(1);
    }

    let your_twr = growth - 1.0;
    let sp_twr = points.last().map(|p| p.sp - 1.0).unwrap_or(0.0);

    TwrResult {
        start_date: Some(start.format("%Y-%m-%d").to_string()),
        end_date: Some(end.format("%Y-%m-%d").to_string()),
        coverage_pct,
        covered_value_usd: covered_value,
        total_value_usd: total_value,
        your_twr,
        sp_twr,
        points,
    }
}

/// Latest stored USD→MXN rate (for valuing any non-USD holdings into the
/// USD total). Falls back to 0.0 (caller treats the value as already-USD).
async fn current_usd_mxn(db: &PgPool) -> f64 {
    sqlx::query(
        "SELECT rate FROM exchange_rates \
         WHERE base_currency = 'USD' AND target_currency = 'MXN' \
         ORDER BY recorded_at DESC LIMIT 1",
    )
    .fetch_optional(db)
    .await
    .ok()
    .flatten()
    .map(|r| {
        r.try_get::<rust_decimal::Decimal, _>("rate")
            .ok()
            .and_then(|d| d.to_string().parse().ok())
            .unwrap_or(0.0)
    })
    .unwrap_or(0.0)
}
