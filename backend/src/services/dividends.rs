//! Dividend info for an equity symbol, from the free Yahoo Finance chart API
//! (`events=div`) — the same no-auth source as the price cache. We derive the
//! payment cadence (median ex-date interval snapped to monthly / quarterly /
//! semi-annual / annual), a forward annual rate (cadence × recent average
//! payment), the last ex-dividend date, and an *estimated* next ex-date. The
//! estimate is honest: Yahoo's authenticated calendar endpoint would give the
//! announced date, but the public chart feed only carries history.

use anyhow::{anyhow, Result};
use chrono::{Duration, NaiveDate};
use reqwest::Client;
use serde::Serialize;

/// One historical dividend event (per-share amount on an ex-date).
#[derive(Debug, Clone, Serialize)]
pub struct DividendEvent {
    /// ISO ex-dividend date.
    pub ex_date: String,
    pub amount_per_share: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct DividendInfo {
    pub symbol: String,
    /// Forward annual dividend per share: cadence × average of the most
    /// recent payments (0 for non-payers and stale payers).
    pub annual_rate: f64,
    pub last_amount: f64,
    /// ISO dates.
    pub last_ex_date: Option<String>,
    pub est_next_ex_date: Option<String>,
    /// Payments per year, snapped to a canonical cadence (12/4/2/1;
    /// 0 = non-payer or stale payer).
    pub per_year: i32,
    /// Raw parsed event history (~2y from Yahoo), ascending by ex-date.
    pub history: Vec<DividendEvent>,
}

impl DividendInfo {
    pub(crate) fn none(symbol: &str) -> Self {
        DividendInfo {
            symbol: symbol.to_string(),
            annual_rate: 0.0,
            last_amount: 0.0,
            last_ex_date: None,
            est_next_ex_date: None,
            per_year: 0,
            history: Vec::new(),
        }
    }
}

/// Cadence + rate derived from a dividend event history. Pure output of
/// [`derive_dividend_stats`], kept separate from `DividendInfo` so the math
/// is unit-testable without a network fetch.
#[derive(Debug, Clone, PartialEq)]
pub struct DividendStats {
    /// Forward annual rate per share (0 when stale / non-payer).
    pub annual_rate: f64,
    /// 12 / 4 / 2 / 1, or 0 when the payer has gone stale.
    pub per_year: i32,
    pub est_next_ex_date: Option<NaiveDate>,
}

impl DividendStats {
    fn stale() -> Self {
        DividendStats { annual_rate: 0.0, per_year: 0, est_next_ex_date: None }
    }
}

/// Snap a median ex-date interval (days) to a canonical payments-per-year.
/// The generous bands absorb the jitter real payers show (a "quarterly"
/// stock's intervals wobble between ~85 and ~98 days).
fn snap_per_year(median_interval_days: i64) -> i32 {
    if median_interval_days <= 45 {
        12
    } else if median_interval_days <= 135 {
        4
    } else if median_interval_days <= 270 {
        2
    } else {
        1
    }
}

/// Median of an interval list, snapped to a cadence. None when empty.
fn median_snap(intervals: &mut Vec<i64>) -> Option<i32> {
    if intervals.is_empty() {
        return None;
    }
    intervals.sort_unstable();
    Some(snap_per_year(intervals[intervals.len() / 2]))
}

/// Derive cadence, forward annual rate, and the estimated next ex-date from
/// an ascending event history, evaluated as of `today`.
///
/// Why cadence-snapped instead of "count events in the trailing year": a
/// quarterly payer whose window happens to straddle 5 ex-dates (4 × ~91d
/// spans 364 days — it happens every few years) would report 5 payments and
/// inflate projected income ~25%. Snapping the median interval to 12/4/2/1
/// is immune to that off-by-one.
///
/// Stale-payer decay: the trailing window is anchored at *today*, not at the
/// last ex-date, so a payer that stopped paying decays to zero instead of
/// projecting its old rate forever. Grace is 365 days, stretched to 455 for
/// interval-confirmed annual payers (whose next payment legitimately lands
/// ~a year after the last, plus announcement jitter). A single-event history
/// gets no stretch — one data point isn't evidence of an annual cadence.
pub fn derive_dividend_stats(points: &[(NaiveDate, f64)], today: NaiveDate) -> DividendStats {
    if points.is_empty() {
        return DividendStats::stale(); // non-payer
    }
    let last_date = points.last().unwrap().0;
    let cutoff = today - Duration::days(365);

    // Cadence: median interval between consecutive ex-dates, preferring
    // intervals that END inside the trailing year so an older, denser era
    // (special dividends, a cut) doesn't distort the current cadence. Fall
    // back to the full history when the window holds no complete interval,
    // and to annual for a single-event history.
    let mut window_intervals: Vec<i64> = points
        .windows(2)
        .filter(|w| w[1].0 > cutoff)
        .map(|w| (w[1].0 - w[0].0).num_days())
        .filter(|d| *d > 0)
        .collect();
    let mut full_intervals: Vec<i64> = points
        .windows(2)
        .map(|w| (w[1].0 - w[0].0).num_days())
        .filter(|d| *d > 0)
        .collect();
    let per_year = median_snap(&mut window_intervals)
        .or_else(|| median_snap(&mut full_intervals))
        .unwrap_or(1);

    let age_days = (today - last_date).num_days();
    let grace_days = if per_year == 1 && points.len() >= 2 { 455 } else { 365 };
    if age_days > grace_days {
        return DividendStats::stale();
    }

    // Forward rate: cadence × average of the most recent payments (one full
    // cycle when available). Averaging smooths a raise mid-cycle; using only
    // the last cycle keeps a raise from being diluted by two-year-old rates.
    let n = (per_year as usize).min(points.len());
    let avg_amount: f64 = points[points.len() - n..].iter().map(|(_, a)| *a).sum::<f64>() / n as f64;
    let annual_rate = ((per_year as f64 * avg_amount) * 10000.0).round() / 10000.0;

    // Next ex-date estimate: one cadence step after the last ex-date, rolled
    // forward past today (an estimate in the past is useless to display —
    // the payer just hasn't announced yet, so project the following slot).
    let step = (365.0 / per_year as f64).round() as i64;
    let mut est_next = last_date + Duration::days(step);
    while est_next < today {
        est_next += Duration::days(step);
    }

    DividendStats {
        annual_rate,
        per_year,
        est_next_ex_date: Some(est_next),
    }
}

pub async fn fetch_dividends(symbol: &str) -> Result<DividendInfo> {
    let url = format!(
        "https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?range=2y&interval=1d&events=div"
    );
    let body = Client::new()
        .get(url)
        .header("User-Agent", "Mozilla/5.0 (Patrimonio)")
        .send()
        .await?
        .text()
        .await?;
    let v: serde_json::Value = serde_json::from_str(&body)?;

    let mut points: Vec<(NaiveDate, f64)> = Vec::new();
    if let Some(obj) = v
        .pointer("/chart/result/0/events/dividends")
        .and_then(|d| d.as_object())
    {
        for val in obj.values() {
            let amount = val.get("amount").and_then(|a| a.as_f64());
            let ts = val.get("date").and_then(|d| d.as_i64());
            if let (Some(a), Some(ts)) = (amount, ts) {
                if let Some(dt) = chrono::DateTime::from_timestamp(ts, 0) {
                    points.push((dt.naive_utc().date(), a));
                }
            }
        }
    } else if v.pointer("/chart/result/0").is_none() {
        return Err(anyhow!("unexpected Yahoo chart shape for {symbol}"));
    }

    if points.is_empty() {
        return Ok(DividendInfo::none(symbol)); // non-payer
    }
    points.sort_by_key(|p| p.0);
    let (last_date, last_amount) = *points.last().unwrap();

    let stats = derive_dividend_stats(&points, chrono::Utc::now().date_naive());

    Ok(DividendInfo {
        symbol: symbol.to_string(),
        annual_rate: stats.annual_rate,
        last_amount,
        last_ex_date: Some(last_date.to_string()),
        est_next_ex_date: stats.est_next_ex_date.map(|d| d.to_string()),
        per_year: stats.per_year,
        history: points
            .iter()
            .map(|(d, a)| DividendEvent { ex_date: d.to_string(), amount_per_share: *a })
            .collect(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(s: &str) -> NaiveDate {
        NaiveDate::parse_from_str(s, "%Y-%m-%d").unwrap()
    }

    /// Build an event history ending `last_age_days` before `today`, walking
    /// backwards `count` events spaced `interval_days` apart, all at `amount`.
    fn history(
        today: NaiveDate,
        last_age_days: i64,
        interval_days: i64,
        count: usize,
        amount: f64,
    ) -> Vec<(NaiveDate, f64)> {
        let mut points: Vec<(NaiveDate, f64)> = (0..count)
            .map(|i| {
                (
                    today - Duration::days(last_age_days + interval_days * i as i64),
                    amount,
                )
            })
            .collect();
        points.sort_by_key(|p| p.0);
        points
    }

    #[test]
    fn quarterly_payer_snaps_to_four() {
        let today = d("2026-07-06");
        let points = history(today, 25, 91, 8, 0.25);
        let stats = derive_dividend_stats(&points, today);
        assert_eq!(stats.per_year, 4);
        assert!((stats.annual_rate - 1.0).abs() < 1e-9);
        // Next estimate = last ex-date (25d ago) + 91d.
        assert_eq!(
            stats.est_next_ex_date,
            Some(today - Duration::days(25) + Duration::days(91))
        );
    }

    #[test]
    fn five_ex_dates_in_trailing_year_still_quarterly() {
        // The overcount repro: 4 × ~90d intervals span 360 days, so a naive
        // "count events in window" sees FIVE ex-dates and reports 5×/yr.
        let today = d("2026-07-06");
        let points = history(today, 1, 90, 9, 0.25);
        assert_eq!(
            points.iter().filter(|(dt, _)| *dt > today - Duration::days(365)).count(),
            5
        );
        let stats = derive_dividend_stats(&points, today);
        assert_eq!(stats.per_year, 4);
        // Rate = 4 × avg of the last 4 payments, never 5 × anything.
        assert!((stats.annual_rate - 1.0).abs() < 1e-9);
    }

    #[test]
    fn monthly_payer_snaps_to_twelve() {
        let today = d("2026-07-06");
        let points = history(today, 10, 30, 24, 0.21);
        let stats = derive_dividend_stats(&points, today);
        assert_eq!(stats.per_year, 12);
        assert!((stats.annual_rate - 2.52).abs() < 1e-9);
    }

    #[test]
    fn semi_annual_payer_snaps_to_two() {
        let today = d("2026-07-06");
        let points = history(today, 60, 182, 4, 1.10);
        let stats = derive_dividend_stats(&points, today);
        assert_eq!(stats.per_year, 2);
        assert!((stats.annual_rate - 2.20).abs() < 1e-9);
    }

    #[test]
    fn annual_payer_snaps_to_one() {
        let today = d("2026-07-06");
        let points = history(today, 100, 365, 2, 3.00);
        let stats = derive_dividend_stats(&points, today);
        assert_eq!(stats.per_year, 1);
        assert!((stats.annual_rate - 3.00).abs() < 1e-9);
    }

    #[test]
    fn rate_averages_last_full_cycle() {
        // Quarterly payer that raised from 0.20 to 0.30 two payments ago:
        // forward rate = 4 × avg(0.20, 0.20, 0.30, 0.30) = 1.00.
        let today = d("2026-07-06");
        let mut points = history(today, 20, 91, 4, 0.20);
        let n = points.len();
        points[n - 1].1 = 0.30;
        points[n - 2].1 = 0.30;
        let stats = derive_dividend_stats(&points, today);
        assert_eq!(stats.per_year, 4);
        assert!((stats.annual_rate - 1.00).abs() < 1e-9);
    }

    #[test]
    fn stale_quarterly_payer_decays_to_zero() {
        // Quarterly cadence, but the last ex-date is 400 days old: the payer
        // stopped. Anchoring the window at the last ex-date would happily
        // keep projecting the dead rate.
        let today = d("2026-07-06");
        let points = history(today, 400, 91, 8, 0.25);
        assert_eq!(derive_dividend_stats(&points, today), DividendStats::stale());
    }

    #[test]
    fn annual_payer_gets_grace_to_455_days() {
        let today = d("2026-07-06");
        // Last ex-date 400 days ago, interval-confirmed annual: still live.
        let live = history(today, 400, 365, 3, 2.00);
        let stats = derive_dividend_stats(&live, today);
        assert_eq!(stats.per_year, 1);
        assert!((stats.annual_rate - 2.00).abs() < 1e-9);
        // est_next = last + 365d rolls forward of today automatically.
        assert!(stats.est_next_ex_date.unwrap() >= today);

        // Past the grace (500 days): stale.
        let dead = history(today, 500, 365, 3, 2.00);
        assert_eq!(derive_dividend_stats(&dead, today), DividendStats::stale());
    }

    #[test]
    fn single_event_history() {
        let today = d("2026-07-06");
        // One event 200 days ago: treated as an annual payer.
        let fresh = vec![(today - Duration::days(200), 1.50)];
        let stats = derive_dividend_stats(&fresh, today);
        assert_eq!(stats.per_year, 1);
        assert!((stats.annual_rate - 1.50).abs() < 1e-9);

        // One event 400 days ago: stale — a lone data point earns no
        // annual-payer grace.
        let old = vec![(today - Duration::days(400), 1.50)];
        assert_eq!(derive_dividend_stats(&old, today), DividendStats::stale());

        // No events at all: non-payer.
        assert_eq!(derive_dividend_stats(&[], today), DividendStats::stale());
    }

    #[test]
    fn est_next_never_in_the_past() {
        // Quarterly payer whose last ex-date is 100 days old: the naive
        // estimate (last + 91d) already passed, so it rolls one more step.
        let today = d("2026-07-06");
        let points = history(today, 100, 91, 8, 0.25);
        let stats = derive_dividend_stats(&points, today);
        let est = stats.est_next_ex_date.unwrap();
        assert!(est >= today);
        assert_eq!(est, today - Duration::days(100) + Duration::days(182));
    }
}
