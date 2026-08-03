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
//!
//! Each point ALSO carries the day's raw market value (`value_usd`) — the
//! valuation the return is derived from, before flows are divided out. That
//! is what lets the performance card show real dollars while a finger scrubs
//! this chart: `balance_snapshots` (and therefore
//! `/dashboard/portfolio-value-history`) only goes back to whenever the
//! install started snapshotting, whereas this walk reaches the earliest lot.
//! See `TwrPoint::value_usd` for the two limits a caller must respect.

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
    /// Market value of the COVERED positions on this date, USD — the very
    /// valuation the day's return is computed from (`shares_on(d) ×
    /// close_on(d)`, summed over the priced symbols).
    ///
    /// Why it's exposed: `/dashboard/portfolio-value-history` can only reach
    /// back as far as `balance_snapshots` has rows (i.e. to whenever this
    /// install first started snapshotting — weeks, on a young deployment),
    /// while this series reaches back to the earliest known lot (years). The
    /// performance card scrubs THIS chart, so without a value here the
    /// headline had no dollars to show across almost the whole width and
    /// degraded to a percentage — the owner's original complaint.
    ///
    /// This is a real valuation, NOT today's value scaled by `twr`: flows are
    /// divided out of `twr` but are fully present here (a mid-window
    /// contribution steps `value_usd` up while leaving `twr` flat), and the
    /// prices are the actual historical closes.
    ///
    /// ⚠ Two honest limits the caller must respect:
    /// 1. It covers only the priced symbols, so it is the whole portfolio
    ///    only when `coverage_pct` is ~1.0 — below that it UNDERSTATES, and
    ///    must not be labelled "portfolio value".
    /// 2. Before a symbol's earliest lot its share count is assumed flat (the
    ///    module-level "opening position" simplification), so the deep past
    ///    is the opening position at that day's prices.
    pub value_usd: f64,
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

/// Backward share-count reconstruction (the module-doc subtlety): the CURRENT
/// quantity is ground truth, so the position at `d` is
/// `base − Σ(lots acquired after d) + Σ(disposals after d)`. Events dated ON
/// `d` are already reflected in that day's valuation (strict `>` — a lot
/// bought today is part of today's shares). Clamped at 0 so inconsistent data
/// (more future buys than current shares) can't produce a negative valuation.
fn shares_on(base: f64, lots: &[QtyEvent], disps: &[QtyEvent], d: NaiveDate) -> f64 {
    let future_buys: f64 = lots.iter().filter(|e| e.date > d).map(|e| e.qty).sum();
    let future_sells: f64 = disps.iter().filter(|e| e.date > d).map(|e| e.qty).sum();
    (base - future_buys + future_sells).max(0.0)
}

/// Share (0..1) of `total_value` that the priced symbols (the keys of
/// `quotes`) represent, i.e. how much of the portfolio the TWR actually
/// reflects. Returns `(covered_value, coverage_pct)`.
fn covered_fraction(
    quotes: &HashMap<String, Vec<(NaiveDate, f64)>>,
    sym_value: &HashMap<String, f64>,
    total_value: f64,
) -> (f64, f64) {
    let covered_value: f64 = quotes
        .keys()
        .map(|s| sym_value.get(s).copied().unwrap_or(0.0))
        .sum();
    let coverage_pct = if total_value > 0.0 {
        covered_value / total_value
    } else {
        0.0
    };
    (covered_value, coverage_pct)
}

/// Everything the pure daily-valuation walk needs, pre-loaded from the DB by
/// [`portfolio_twr`]. Split out (rather than inlined in the async fn) so the
/// money math is unit-testable with synthetic lots/disposals/prices — the DB
/// loader stays a thin shell around this.
struct DailyTwrInputs<'a> {
    /// Ascending `(date, close)` series per covered symbol.
    quotes: &'a HashMap<String, Vec<(NaiveDate, f64)>>,
    /// CURRENT share count per symbol (ground truth; see module docs).
    cur_qty: &'a HashMap<String, f64>,
    lots_by_sym: &'a HashMap<String, Vec<QtyEvent>>,
    disps_by_sym: &'a HashMap<String, Vec<QtyEvent>>,
    /// Net external flow per day, USD: buys add capital (+), sells remove (−).
    flow_map: &'a HashMap<NaiveDate, f64>,
    /// Benchmark series (ascending). Empty → benchmark index flat at 1.0.
    sp: &'a [(NaiveDate, f64)],
    start: NaiveDate,
    end: NaiveDate,
}

/// Daily-valuation TWR (GIPS method): value the portfolio every calendar day,
/// subtract the day's external flow from the day's return, and chain-link.
/// Returns the per-day points plus the final growth index (1.0-based).
///
/// The first day only establishes the opening value (no return is booked for
/// it) — the opening position is a starting value, NOT a flow, which is
/// exactly why contributions don't masquerade as performance here.
fn compute_daily_twr(inp: &DailyTwrInputs) -> (Vec<TwrPoint>, f64) {
    let sp_first = close_on(inp.sp, inp.start);
    let mut points: Vec<TwrPoint> = Vec::new();
    let mut prev_v: Option<f64> = None;
    let mut growth = 1.0_f64;
    let mut d = inp.start;
    while d <= inp.end {
        let mut v = 0.0;
        for (sym, qseries) in inp.quotes {
            let base = *inp.cur_qty.get(sym).unwrap_or(&0.0);
            let shares = shares_on(
                base,
                inp.lots_by_sym.get(sym).map_or(&[][..], |e| e.as_slice()),
                inp.disps_by_sym.get(sym).map_or(&[][..], |e| e.as_slice()),
                d,
            );
            if shares > 0.0 {
                v += shares * close_on(qseries, d);
            }
        }
        let f = *inp.flow_map.get(&d).unwrap_or(&0.0);
        if let Some(pv) = prev_v {
            if pv > 0.0 {
                let r = (v - f) / pv - 1.0;
                growth *= 1.0 + r;
            }
        }
        prev_v = Some(v);
        let sp_idx = if sp_first > 0.0 {
            close_on(inp.sp, d) / sp_first
        } else {
            1.0
        };
        points.push(TwrPoint {
            date: d.format("%Y-%m-%d").to_string(),
            twr: growth,
            sp: sp_idx,
            // The day's raw market value, flows INCLUDED — see TwrPoint::value_usd.
            value_usd: v,
        });
        d += Duration::days(1);
    }
    (points, growth)
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
    let (covered_value, coverage_pct) = covered_fraction(&quotes, &sym_value, total_value);
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

    // 6. Daily-valuation TWR. Iterate calendar days; quotes forward-fill over
    //    weekends/holidays via close_on, so a no-trade day has r=0 (unless a
    //    cashflow lands on it). The walk itself is pure — see
    //    `compute_daily_twr` (unit-tested with synthetic data).
    let (points, growth) = compute_daily_twr(&DailyTwrInputs {
        quotes: &quotes,
        cur_qty: &cur_qty,
        lots_by_sym: &lots_by_sym,
        disps_by_sym: &disps_by_sym,
        flow_map: &flow_map,
        sp: &sp,
        start,
        end,
    });

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

#[cfg(test)]
mod tests {
    use super::*;

    /// TWR is deliberately f64 (chart display math, not ledger money), so
    /// assertions compare within an epsilon — never `==` on floats.
    fn assert_close(actual: f64, expected: f64, msg: &str) {
        assert!(
            (actual - expected).abs() < 1e-9,
            "{msg}: expected {expected}, got {actual}"
        );
    }

    fn day(d: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 1, d).unwrap()
    }

    fn quotes_of(sym: &str, series: &[(u32, f64)]) -> HashMap<String, Vec<(NaiveDate, f64)>> {
        let mut m = HashMap::new();
        m.insert(
            sym.to_string(),
            series.iter().map(|&(d, p)| (day(d), p)).collect(),
        );
        m
    }

    fn qty_of(sym: &str, qty: f64) -> HashMap<String, f64> {
        let mut m = HashMap::new();
        m.insert(sym.to_string(), qty);
        m
    }

    fn events_of(sym: &str, events: &[(u32, f64)]) -> HashMap<String, Vec<QtyEvent>> {
        let mut m = HashMap::new();
        m.insert(
            sym.to_string(),
            events
                .iter()
                .map(|&(d, qty)| QtyEvent { date: day(d), qty })
                .collect(),
        );
        m
    }

    fn flows_of(flows: &[(u32, f64)]) -> HashMap<NaiveDate, f64> {
        flows.iter().map(|&(d, f)| (day(d), f)).collect()
    }

    // (a) With no external flows, TWR is exactly the plain price return —
    // the growth index tracks price/first_price day by day.
    #[test]
    fn no_flow_twr_equals_plain_price_return() {
        let quotes = quotes_of("GOOG", &[(1, 100.0), (2, 105.0), (3, 110.0)]);
        let (points, growth) = compute_daily_twr(&DailyTwrInputs {
            quotes: &quotes,
            cur_qty: &qty_of("GOOG", 10.0),
            lots_by_sym: &HashMap::new(),
            disps_by_sym: &HashMap::new(),
            flow_map: &HashMap::new(),
            sp: &[],
            start: day(1),
            end: day(3),
        });
        assert_eq!(points.len(), 3);
        // Day 1 establishes the opening value; no return is booked yet.
        assert_close(points[0].twr, 1.0, "index starts at 1.0");
        assert_close(points[1].twr, 1.05, "day 2 = 105/100");
        assert_close(points[2].twr, 1.10, "day 3 = 110/100");
        assert_close(growth, 1.10, "final growth is the price return");
        // No benchmark series → comparison index flat-lines at 1.0.
        assert_close(points[2].sp, 1.0, "empty benchmark stays flat");
    }

    // (b) A mid-period buy at the market price is a DEPOSIT, not a gain: the
    // portfolio doubles in size on day 2, but the growth index must still be
    // exactly the 10% price move. (This is the whole point of TWR — the old
    // net-worth-indexing conflated exactly this.)
    #[test]
    fn mid_period_buy_is_a_flow_not_performance() {
        // 10 shares held; 10 more bought on day 2 at 105 → current qty 20,
        // dated flow +1050 on day 2.
        let quotes = quotes_of("GOOG", &[(1, 100.0), (2, 105.0), (3, 110.0)]);
        let (points, growth) = compute_daily_twr(&DailyTwrInputs {
            quotes: &quotes,
            cur_qty: &qty_of("GOOG", 20.0),
            lots_by_sym: &events_of("GOOG", &[(2, 10.0)]),
            disps_by_sym: &HashMap::new(),
            flow_map: &flows_of(&[(2, 1050.0)]),
            sp: &[],
            start: day(1),
            end: day(3),
        });
        // Value path: 1000 → 2100 → 2200, but return path: +5%, +110/105−1.
        assert_close(growth, 1.10, "deposit must not count as performance");
        assert_close(points[1].twr, 1.05, "day 2 return is the 5% price move");
    }

    // (c) A mid-period sell is a WITHDRAWAL, not a loss: halving the position
    // on day 2 must leave the growth index equal to the pure price return.
    #[test]
    fn mid_period_sell_is_a_flow_not_a_loss() {
        // 20 shares held at start; 10 sold on day 2 at 105 → current qty 10,
        // dated flow −1050 on day 2.
        let quotes = quotes_of("GOOG", &[(1, 100.0), (2, 105.0), (3, 110.0)]);
        let (points, growth) = compute_daily_twr(&DailyTwrInputs {
            quotes: &quotes,
            cur_qty: &qty_of("GOOG", 10.0),
            lots_by_sym: &HashMap::new(),
            disps_by_sym: &events_of("GOOG", &[(2, 10.0)]),
            flow_map: &flows_of(&[(2, -1050.0)]),
            sp: &[],
            start: day(1),
            end: day(3),
        });
        // Value path: 2000 → 1050 → 1100, but the withdrawal is divided out.
        assert_close(growth, 1.10, "withdrawal must not count as a loss");
        assert_close(points[1].twr, 1.05, "day 2 return is the 5% price move");
    }

    // (d) Backward reconstruction: quantity at t reflects only lots/disposals
    // strictly AFTER t, walked back from the current position (the module's
    // core subtlety — lots are sparse, current qty is ground truth).
    #[test]
    fn shares_on_reconstructs_quantity_backward_from_current() {
        // Current position: 100 shares. Known history: bought 25 on day 5,
        // sold 10 on day 8.
        let lots = [QtyEvent {
            date: day(5),
            qty: 25.0,
        }];
        let disps = [QtyEvent {
            date: day(8),
            qty: 10.0,
        }];
        // Before the buy: 100 − 25 (future buy) + 10 (future sell) = 85 —
        // the opening position, NOT zero (lots don't sum to the portfolio).
        assert_close(shares_on(100.0, &lots, &disps, day(3)), 85.0, "before buy");
        // ON the buy date the lot is already in the day's position (strict >).
        assert_close(shares_on(100.0, &lots, &disps, day(5)), 110.0, "on buy day");
        assert_close(
            shares_on(100.0, &lots, &disps, day(6)),
            110.0,
            "between buy and sell",
        );
        // ON the sell date the disposal has already left the position.
        assert_close(
            shares_on(100.0, &lots, &disps, day(8)),
            100.0,
            "on sell day",
        );
        assert_close(shares_on(100.0, &lots, &disps, day(9)), 100.0, "after sell");
        // Inconsistent data (future buys exceed current qty) clamps to 0
        // instead of valuing a negative position.
        let big_buy = [QtyEvent {
            date: day(5),
            qty: 10.0,
        }];
        assert_close(shares_on(5.0, &big_buy, &[], day(1)), 0.0, "clamped at 0");
    }

    // (e) coverage_pct when price data is partial: only symbols present in
    // `quotes` count as covered; the rest still weigh in the denominator so
    // the caller knows how much of the portfolio the TWR reflects.
    #[test]
    fn covered_fraction_counts_only_priced_symbols() {
        let quotes = quotes_of("GOOG", &[(1, 100.0)]);
        let mut sym_value: HashMap<String, f64> = HashMap::new();
        sym_value.insert("GOOG".to_string(), 300.0);
        // An opaque Plaid security_id we can't price — uncovered by design.
        sym_value.insert("OPAQUE123".to_string(), 700.0);
        let (covered, pct) = covered_fraction(&quotes, &sym_value, 1000.0);
        assert_close(covered, 300.0, "covered value = priced symbols only");
        assert_close(pct, 0.3, "coverage is covered/total");
        // Degenerate total → 0, not a divide-by-zero NaN.
        let (_, pct_zero) = covered_fraction(&quotes, &sym_value, 0.0);
        assert_close(pct_zero, 0.0, "zero total value yields 0 coverage");
    }

    // (f) Chain-linking: the growth index equals the product of the daily
    // returns — even with a mid-period flow, linking day returns compounds to
    // the pure price return over the window.
    #[test]
    fn chain_linking_compounds_daily_returns() {
        // Prices 100 → 102 → 99 → 110; buy 5 more shares on day 2 at 102.
        let quotes = quotes_of("GOOG", &[(1, 100.0), (2, 102.0), (3, 99.0), (4, 110.0)]);
        let (points, growth) = compute_daily_twr(&DailyTwrInputs {
            quotes: &quotes,
            cur_qty: &qty_of("GOOG", 15.0),
            lots_by_sym: &events_of("GOOG", &[(2, 5.0)]),
            disps_by_sym: &HashMap::new(),
            flow_map: &flows_of(&[(2, 510.0)]),
            sp: &[],
            start: day(1),
            end: day(4),
        });
        // Daily returns: 102/100−1, 99/102−1, 110/99−1 → product telescopes
        // to 110/100.
        let expected = (102.0 / 100.0) * (99.0 / 102.0) * (110.0 / 99.0);
        assert_close(growth, expected, "index = compounded daily returns");
        assert_close(growth, 1.10, "telescoped product = end/start price");
        // And every intermediate point is the running product so far.
        assert_close(points[1].twr, 1.02, "after day 2");
        assert_close(points[2].twr, 1.02 * (99.0 / 102.0), "after day 3");
    }

    // Benchmark overlay: indexed to its close on the start date, forward-
    // filling gaps via close_on.
    #[test]
    fn benchmark_index_is_relative_to_start_close() {
        let quotes = quotes_of("GOOG", &[(1, 100.0), (3, 110.0)]);
        let sp = [(day(1), 4000.0), (day(3), 4400.0)];
        let (points, _) = compute_daily_twr(&DailyTwrInputs {
            quotes: &quotes,
            cur_qty: &qty_of("GOOG", 1.0),
            lots_by_sym: &HashMap::new(),
            disps_by_sym: &HashMap::new(),
            flow_map: &HashMap::new(),
            sp: &sp,
            start: day(1),
            end: day(3),
        });
        assert_close(points[0].sp, 1.0, "benchmark starts at 1.0");
        // Day 2 has no benchmark close → forward-fill from day 1.
        assert_close(points[1].sp, 1.0, "gap forward-fills previous close");
        assert_close(points[2].sp, 1.1, "day 3 = 4400/4000");
    }

    // (g) `value_usd` is the DOLLAR path, not the return path. This is the
    // whole reason it exists: the performance card's scrub headline needs
    // real money for every plotted day, and `twr` deliberately can't supply
    // it (flows are divided out). A mid-window contribution must therefore
    // step `value_usd` up on the day it lands while leaving `twr` flat.
    #[test]
    fn value_usd_tracks_dollars_including_flows_while_twr_does_not() {
        // Same fixture as (b): 10 shares held, 10 more bought on day 2 @ 105.
        let quotes = quotes_of("GOOG", &[(1, 100.0), (2, 105.0), (3, 110.0)]);
        let (points, _) = compute_daily_twr(&DailyTwrInputs {
            quotes: &quotes,
            cur_qty: &qty_of("GOOG", 20.0),
            lots_by_sym: &events_of("GOOG", &[(2, 10.0)]),
            disps_by_sym: &HashMap::new(),
            flow_map: &flows_of(&[(2, 1050.0)]),
            sp: &[],
            start: day(1),
            end: day(3),
        });
        // Dollars: 10×100 → 20×105 → 20×110. The deposit is VISIBLE here.
        assert_close(points[0].value_usd, 1000.0, "opening position at day 1");
        assert_close(points[1].value_usd, 2100.0, "deposit shows in dollars");
        assert_close(points[2].value_usd, 2200.0, "day 3 at the day-3 close");
        // …while the return over the same days is only the 10% price move,
        // so `value_usd` can never be reconstructed from `twr` (and vice
        // versa): 2200/1000 = 2.2, but growth is 1.10.
        assert_close(points[2].twr, 1.10, "return still excludes the deposit");
    }

    // (h) A sell is the mirror case: `value_usd` drops with the withdrawal
    // even though `twr` doesn't book a loss. Guards against anyone "fixing"
    // value_usd by deriving it from the growth index.
    #[test]
    fn value_usd_drops_on_a_withdrawal_without_booking_a_loss() {
        let quotes = quotes_of("GOOG", &[(1, 100.0), (2, 105.0), (3, 110.0)]);
        let (points, _) = compute_daily_twr(&DailyTwrInputs {
            quotes: &quotes,
            cur_qty: &qty_of("GOOG", 10.0),
            lots_by_sym: &HashMap::new(),
            disps_by_sym: &events_of("GOOG", &[(2, 10.0)]),
            flow_map: &flows_of(&[(2, -1050.0)]),
            sp: &[],
            start: day(1),
            end: day(3),
        });
        assert_close(points[0].value_usd, 2000.0, "20 shares before the sale");
        assert_close(points[1].value_usd, 1050.0, "10 shares after the sale");
        assert_close(points[2].value_usd, 1100.0, "10 shares at the day-3 close");
        assert_close(points[2].twr, 1.10, "withdrawal is not a loss");
    }

    // (i) Multi-symbol: the day's value is the SUM over covered symbols, each
    // at its own reconstructed share count and its own close — not a single
    // position's path. (A per-symbol quote gap forward-fills via close_on.)
    #[test]
    fn value_usd_sums_every_covered_symbol_on_the_day() {
        let mut quotes = quotes_of("GOOG", &[(1, 100.0), (2, 110.0)]);
        quotes.insert(
            "MSFT".to_string(),
            vec![(day(1), 50.0)], // no day-2 close → forward-fills at 50
        );
        let mut qty = qty_of("GOOG", 10.0);
        qty.insert("MSFT".to_string(), 4.0);
        let (points, _) = compute_daily_twr(&DailyTwrInputs {
            quotes: &quotes,
            cur_qty: &qty,
            lots_by_sym: &HashMap::new(),
            disps_by_sym: &HashMap::new(),
            flow_map: &HashMap::new(),
            sp: &[],
            start: day(1),
            end: day(2),
        });
        assert_close(points[0].value_usd, 1200.0, "10×100 + 4×50");
        assert_close(points[1].value_usd, 1300.0, "10×110 + 4×50 (filled)");
    }
}
