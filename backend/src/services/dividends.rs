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
use serde::{Deserialize, Serialize};

/// One historical dividend event (per-share amount on an ex-date).
/// `Deserialize` is additive (round-4 Redis cache envelope); the
/// `Serialize` output is unchanged — asserted lossless in a test.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct DividendEvent {
    /// ISO ex-dividend date.
    pub ex_date: String,
    pub amount_per_share: f64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
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
fn median_snap(intervals: &mut [i64]) -> Option<i32> {
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

// =====================================================================
// Round 4 (contract C4-C): Redis-backed per-symbol cache
// =====================================================================

/// Fresh window: a cached success younger than this is served without a
/// live fetch. Dividends change quarterly — 12 h is generous.
const CACHE_FRESH_SECS: i64 = 43_200;
/// Negative window: a cached fetch *failure* younger than this short-
/// circuits to `Err` without re-hitting Yahoo (stops the handful of
/// unresolvable held symbols from being re-fetched on every request).
const CACHE_NEGATIVE_SECS: i64 = 3_600;
/// Redis retention (SETEX TTL): a stale success inside this window is
/// still served when a live re-fetch fails — a whole weekend of Yahoo
/// outage shows last-known income instead of zeros.
const CACHE_RETENTION_SECS: i64 = 604_800;

/// The JSON value stored per symbol: `{"fetched_at", "ok": true, "info"}`
/// for a successful fetch (including zeroed non-payers), or
/// `{"fetched_at", "ok": false}` for a network/shape failure.
#[derive(Debug, Clone, Serialize, Deserialize)]
struct CacheEnvelope {
    /// Unix seconds of the live fetch that produced this envelope.
    fetched_at: i64,
    ok: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    info: Option<DividendInfo>,
}

/// What `decide` tells the caller to do with a (possibly absent) envelope.
#[derive(Debug)]
enum CacheAction {
    /// Fresh success: serve it, no fetch.
    ServeFresh(DividendInfo),
    /// Fresh failure marker: return `Err` without a fetch.
    ServeNegative,
    /// Go live. `stale` carries the last-known success (any age within
    /// retention) to serve if the live fetch fails.
    Fetch { stale: Option<DividendInfo> },
}

/// The serve/fetch/stale policy, pure so freshness, negative-TTL, and
/// bypass rules are unit-testable without Redis or Yahoo. Retention is
/// enforced by the Redis TTL itself — any envelope we can still read is
/// within the 7-day window. `bypass` skips both fresh-serve branches but
/// keeps the stale-on-failure fallback.
fn decide(envelope: Option<CacheEnvelope>, now: i64, bypass: bool) -> CacheAction {
    let Some(env) = envelope else {
        return CacheAction::Fetch { stale: None };
    };
    let age = now - env.fetched_at;
    match (env.ok, env.info) {
        (true, Some(info)) => {
            if !bypass && age < CACHE_FRESH_SECS {
                CacheAction::ServeFresh(info)
            } else {
                CacheAction::Fetch { stale: Some(info) }
            }
        }
        (false, _) if !bypass && age < CACHE_NEGATIVE_SECS => CacheAction::ServeNegative,
        // Expired failure marker, or a corrupt ok-without-info envelope.
        _ => CacheAction::Fetch { stale: None },
    }
}

fn cache_key(symbol: &str) -> String {
    format!("div:v1:{}", symbol.trim().to_uppercase())
}

/// Best-effort envelope read. Redis being down/unreachable (or the value
/// unparsable) reads as "no envelope" — the caller degrades to a live fetch.
async fn read_envelope(redis: &redis::Client, key: &str) -> Option<CacheEnvelope> {
    let mut conn = redis.get_multiplexed_async_connection().await.ok()?;
    let raw: Option<String> = redis::cmd("GET").arg(key).query_async(&mut conn).await.ok()?;
    raw.and_then(|s| serde_json::from_str(&s).ok())
}

/// Best-effort envelope write with the 7-day retention TTL.
async fn write_envelope(redis: &redis::Client, key: &str, env: &CacheEnvelope) {
    if let Ok(mut conn) = redis.get_multiplexed_async_connection().await {
        if let Ok(json) = serde_json::to_string(env) {
            let _: Result<(), _> = redis::cmd("SETEX")
                .arg(key)
                .arg(CACHE_RETENTION_SECS)
                .arg(json)
                .query_async(&mut conn)
                .await;
        }
    }
}

/// Per-symbol in-process fill locks (round-4 B2): at cold cache the
/// Overview tile and the Portfolio card fan out `/holdings/dividends`
/// near-simultaneously — the lock makes the loser wait and re-read the
/// cache instead of doubling every Yahoo call.
static FETCH_LOCKS: std::sync::LazyLock<
    std::sync::Mutex<std::collections::HashMap<String, std::sync::Arc<tokio::sync::Mutex<()>>>>,
> = std::sync::LazyLock::new(Default::default);

/// Same semantics as [`fetch_dividends`] (`Ok(info)` incl. zeroed
/// non-payers; `Err` for network/shape failures) but Redis-backed per
/// contract C4-C. Redis being down degrades to a live fetch, never to an
/// error. `bypass_fresh` skips the fresh-serve branches (the detail
/// endpoint's `?refresh=true`) but keeps the stale-on-failure fallback
/// and always writes on success.
pub async fn fetch_dividends_cached(
    redis: &redis::Client,
    symbol: &str,
    bypass_fresh: bool,
) -> Result<DividendInfo> {
    fetch_dividends_cached_with(redis, symbol, bypass_fresh, |s: String| async move {
        fetch_dividends(&s).await
    })
    .await
}

/// [`fetch_dividends_cached`] with the live fetcher injected, so the cache
/// policy and coalescing are testable against Redis without Yahoo. The
/// fetcher takes an owned `String` to sidestep HRTB inference on closures.
async fn fetch_dividends_cached_with<F, Fut>(
    redis: &redis::Client,
    symbol: &str,
    bypass_fresh: bool,
    fetch: F,
) -> Result<DividendInfo>
where
    F: Fn(String) -> Fut,
    Fut: std::future::Future<Output = Result<DividendInfo>>,
{
    let key = cache_key(symbol);
    let now = || chrono::Utc::now().timestamp();

    // Fast path: no lock while the cache answers.
    match decide(read_envelope(redis, &key).await, now(), bypass_fresh) {
        CacheAction::ServeFresh(info) => return Ok(info),
        CacheAction::ServeNegative => {
            return Err(anyhow!("dividend fetch for {symbol} recently failed (negative cache)"))
        }
        CacheAction::Fetch { .. } => {}
    }

    let result = {
        // Coalesce concurrent fills: take (or create) this symbol's lock —
        // the map mutex is held only for the map op, never across an await.
        let lock = FETCH_LOCKS.lock().unwrap().entry(key.clone()).or_default().clone();
        let _guard = lock.lock().await;
        // Re-read: the coalescing winner has usually filled the cache.
        match decide(read_envelope(redis, &key).await, now(), bypass_fresh) {
            CacheAction::ServeFresh(info) => Ok(info),
            CacheAction::ServeNegative => {
                Err(anyhow!("dividend fetch for {symbol} recently failed (negative cache)"))
            }
            CacheAction::Fetch { stale } => {
                tracing::debug!("dividends: miss, fetching {symbol}");
                match fetch(symbol.to_string()).await {
                    Ok(info) => {
                        let env =
                            CacheEnvelope { fetched_at: now(), ok: true, info: Some(info.clone()) };
                        write_envelope(redis, &key, &env).await;
                        Ok(info)
                    }
                    Err(e) => match stale {
                        // Keep the original envelope (and its TTL): retention
                        // counts from the last successful fetch.
                        Some(info) => {
                            tracing::warn!(
                                "dividends: live fetch failed for {symbol}, serving stale cache: {e}"
                            );
                            Ok(info)
                        }
                        None => {
                            let env = CacheEnvelope { fetched_at: now(), ok: false, info: None };
                            write_envelope(redis, &key, &env).await;
                            Err(e)
                        }
                    },
                }
            }
        }
    };

    // Opportunistically drop the lock entry once we're its last holder.
    let mut locks = FETCH_LOCKS.lock().unwrap();
    if locks.get(&key).is_some_and(|l| std::sync::Arc::strong_count(l) == 1) {
        locks.remove(&key);
    }
    drop(locks);
    result
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

    // =================================================================
    // Round 4 B1 — cache envelope + `decide` policy matrix
    // =================================================================

    fn sample_info(symbol: &str) -> DividendInfo {
        DividendInfo {
            symbol: symbol.to_string(),
            annual_rate: 1.0,
            last_amount: 0.25,
            last_ex_date: Some("2026-06-11".to_string()),
            est_next_ex_date: Some("2026-09-10".to_string()),
            per_year: 4,
            history: vec![DividendEvent {
                ex_date: "2026-06-11".to_string(),
                amount_per_share: 0.25,
            }],
        }
    }

    fn ok_env(fetched_at: i64, symbol: &str) -> CacheEnvelope {
        CacheEnvelope { fetched_at, ok: true, info: Some(sample_info(symbol)) }
    }

    fn err_env(fetched_at: i64) -> CacheEnvelope {
        CacheEnvelope { fetched_at, ok: false, info: None }
    }

    /// The additive `Deserialize` derive must round-trip losslessly, and
    /// the `Serialize` output stays exactly the round-3 shape (no new or
    /// renamed fields).
    #[test]
    fn dividend_info_serde_round_trip_is_lossless() {
        let info = sample_info("NVDA");
        let json = serde_json::to_value(&info).unwrap();
        assert_eq!(
            json,
            serde_json::json!({
                "symbol": "NVDA",
                "annual_rate": 1.0,
                "last_amount": 0.25,
                "last_ex_date": "2026-06-11",
                "est_next_ex_date": "2026-09-10",
                "per_year": 4,
                "history": [{"ex_date": "2026-06-11", "amount_per_share": 0.25}]
            })
        );
        let back: DividendInfo = serde_json::from_value(json.clone()).unwrap();
        assert_eq!(serde_json::to_value(&back).unwrap(), json);
    }

    /// The envelope serializes per C4-C: failure markers carry no `info`
    /// key at all (not a null).
    #[test]
    fn cache_envelope_shapes_match_contract() {
        let ok = serde_json::to_value(ok_env(100, "KO")).unwrap();
        assert_eq!(ok["ok"], true);
        assert_eq!(ok["fetched_at"], 100);
        assert_eq!(ok["info"]["symbol"], "KO");
        let err = serde_json::to_value(err_env(100)).unwrap();
        assert_eq!(err, serde_json::json!({"fetched_at": 100, "ok": false}));
    }

    /// Fresh success (< 12 h) serves from cache.
    #[test]
    fn decide_fresh_hit_serves_cached() {
        let now = 1_000_000_000;
        let env = ok_env(now - CACHE_FRESH_SECS + 1, "KO");
        match decide(Some(env), now, false) {
            CacheAction::ServeFresh(info) => assert_eq!(info.symbol, "KO"),
            other => panic!("expected ServeFresh, got {other:?}"),
        }
    }

    /// A success at/past the 12 h window refetches, carrying itself as the
    /// stale fallback.
    #[test]
    fn decide_expired_success_refetches_with_stale_fallback() {
        let now = 1_000_000_000;
        let env = ok_env(now - CACHE_FRESH_SECS, "KO");
        match decide(Some(env), now, false) {
            CacheAction::Fetch { stale: Some(info) } => assert_eq!(info.symbol, "KO"),
            other => panic!("expected Fetch with stale fallback, got {other:?}"),
        }
    }

    /// A fresh failure marker (< 1 h) is a negative hit: Err without fetch.
    #[test]
    fn decide_fresh_negative_errs_without_fetch() {
        let now = 1_000_000_000;
        let env = err_env(now - CACHE_NEGATIVE_SECS + 1);
        assert!(matches!(decide(Some(env), now, false), CacheAction::ServeNegative));
    }

    /// An expired failure marker (>= 1 h) retries live, with nothing to
    /// fall back on.
    #[test]
    fn decide_expired_negative_refetches_without_fallback() {
        let now = 1_000_000_000;
        let env = err_env(now - CACHE_NEGATIVE_SECS);
        assert!(matches!(decide(Some(env), now, false), CacheAction::Fetch { stale: None }));
    }

    /// No envelope at all: plain miss.
    #[test]
    fn decide_missing_envelope_fetches() {
        assert!(matches!(decide(None, 1_000, false), CacheAction::Fetch { stale: None }));
    }

    /// Bypass skips BOTH fresh-serve branches but keeps the stale
    /// fallback from a fresh success.
    #[test]
    fn decide_bypass_skips_fresh_but_keeps_stale_fallback() {
        let now = 1_000_000_000;
        match decide(Some(ok_env(now - 10, "KO")), now, true) {
            CacheAction::Fetch { stale: Some(info) } => assert_eq!(info.symbol, "KO"),
            other => panic!("expected Fetch with stale fallback, got {other:?}"),
        }
        assert!(matches!(
            decide(Some(err_env(now - 10)), now, true),
            CacheAction::Fetch { stale: None }
        ));
    }

    /// A corrupt ok-envelope with no payload degrades to a plain miss.
    #[test]
    fn decide_ok_envelope_without_info_fetches() {
        let now = 1_000_000_000;
        let env = CacheEnvelope { fetched_at: now - 10, ok: true, info: None };
        assert!(matches!(decide(Some(env), now, false), CacheAction::Fetch { stale: None }));
    }

    // =================================================================
    // Round 4 B1/B2 — Redis-backed integration (injected fetcher; skips
    // when the dev Redis on :6380 is unreachable)
    // =================================================================

    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::Arc;

    const TEST_REDIS_URL: &str = "redis://:patrimonio_dev@127.0.0.1:6380/";

    /// Dev Redis client, or None (→ the caller skips) when unreachable.
    async fn test_redis() -> Option<redis::Client> {
        let client = redis::Client::open(TEST_REDIS_URL).ok()?;
        let mut conn = client.get_multiplexed_async_connection().await.ok()?;
        let _: String = redis::cmd("PING").query_async(&mut conn).await.ok()?;
        Some(client)
    }

    async fn del_key(client: &redis::Client, key: &str) {
        if let Ok(mut conn) = client.get_multiplexed_async_connection().await {
            let _: Result<(), _> = redis::cmd("DEL").arg(key).query_async(&mut conn).await;
        }
    }

    async fn get_raw(client: &redis::Client, key: &str) -> Option<String> {
        let mut conn = client.get_multiplexed_async_connection().await.ok()?;
        redis::cmd("GET").arg(key).query_async(&mut conn).await.ok()?
    }

    /// Miss → one live fetch, envelope written with the retention TTL,
    /// info served; an immediate second call is a fresh hit (no fetch).
    #[tokio::test]
    async fn cached_miss_fills_envelope_then_serves_fresh() {
        let Some(client) = test_redis().await else {
            eprintln!("skipping: dev Redis :6380 unreachable");
            return;
        };
        let symbol = "ZZTEST-B1-MISS";
        let key = cache_key(symbol);
        del_key(&client, &key).await;

        let calls = Arc::new(AtomicUsize::new(0));
        let fetch = |s: String| {
            let calls = calls.clone();
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok(sample_info(&s))
            }
        };
        let got = fetch_dividends_cached_with(&client, symbol, false, fetch).await.unwrap();
        assert_eq!(got.per_year, 4);
        assert_eq!(calls.load(Ordering::SeqCst), 1);

        // Envelope landed with the 7-day retention TTL.
        let raw = get_raw(&client, &key).await.expect("envelope written");
        let env: CacheEnvelope = serde_json::from_str(&raw).unwrap();
        assert!(env.ok);
        assert_eq!(env.info.unwrap().per_year, 4);
        let mut conn = client.get_multiplexed_async_connection().await.unwrap();
        let ttl: i64 = redis::cmd("TTL").arg(&key).query_async(&mut conn).await.unwrap();
        assert!(ttl > CACHE_RETENTION_SECS - 60 && ttl <= CACHE_RETENTION_SECS);

        // Second call: fresh hit, no new fetch.
        let again = fetch_dividends_cached_with(&client, symbol, false, |s: String| {
            let calls = calls.clone();
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                Ok(sample_info(&s))
            }
        })
        .await
        .unwrap();
        assert_eq!(again.per_year, 4);
        assert_eq!(calls.load(Ordering::SeqCst), 1, "fresh hit must not re-fetch");

        del_key(&client, &key).await;
    }

    /// Live failure with a stale success in retention serves the stale
    /// info (Ok, not Err) and leaves the envelope untouched.
    #[tokio::test]
    async fn cached_error_serves_stale_success() {
        let Some(client) = test_redis().await else {
            eprintln!("skipping: dev Redis :6380 unreachable");
            return;
        };
        let symbol = "ZZTEST-B1-STALE";
        let key = cache_key(symbol);
        // Seed an EXPIRED (but retained) success.
        let fetched_at = chrono::Utc::now().timestamp() - CACHE_FRESH_SECS - 100;
        write_envelope(&client, &key, &ok_env(fetched_at, symbol)).await;

        let got = fetch_dividends_cached_with(&client, symbol, false, |_: String| async {
            Err(anyhow!("yahoo down"))
        })
        .await
        .unwrap();
        assert_eq!(got.symbol, symbol);
        assert_eq!(got.per_year, 4);
        // The stale success was NOT overwritten by a failure marker.
        let env: CacheEnvelope =
            serde_json::from_str(&get_raw(&client, &key).await.unwrap()).unwrap();
        assert!(env.ok);
        assert_eq!(env.fetched_at, fetched_at);

        del_key(&client, &key).await;
    }

    /// Live failure with nothing cached writes a negative marker and
    /// errs; the next call inside the 1 h window errs WITHOUT fetching.
    #[tokio::test]
    async fn cached_error_without_cache_writes_negative_marker() {
        let Some(client) = test_redis().await else {
            eprintln!("skipping: dev Redis :6380 unreachable");
            return;
        };
        let symbol = "ZZTEST-B1-NEG";
        let key = cache_key(symbol);
        del_key(&client, &key).await;

        let calls = Arc::new(AtomicUsize::new(0));
        let fetch = |_: String| {
            let calls = calls.clone();
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                Err(anyhow!("unresolvable"))
            }
        };
        assert!(fetch_dividends_cached_with(&client, symbol, false, &fetch).await.is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 1);
        let env: CacheEnvelope =
            serde_json::from_str(&get_raw(&client, &key).await.unwrap()).unwrap();
        assert!(!env.ok);

        // Negative-fresh: Err again, but with NO second live attempt.
        assert!(fetch_dividends_cached_with(&client, symbol, false, &fetch).await.is_err());
        assert_eq!(calls.load(Ordering::SeqCst), 1, "negative cache must suppress the refetch");

        del_key(&client, &key).await;
    }

    /// Bypass ignores a fresh envelope (live fetch happens) but still
    /// falls back to the fresh-but-bypassed success when the fetch fails.
    #[tokio::test]
    async fn cached_bypass_fetches_live_but_keeps_stale_fallback() {
        let Some(client) = test_redis().await else {
            eprintln!("skipping: dev Redis :6380 unreachable");
            return;
        };
        let symbol = "ZZTEST-B1-BYPASS";
        let key = cache_key(symbol);
        write_envelope(&client, &key, &ok_env(chrono::Utc::now().timestamp() - 10, symbol)).await;

        // Success path: live info (different rate) replaces the envelope.
        let mut live = sample_info(symbol);
        live.annual_rate = 9.0;
        let live_clone = live.clone();
        let got = fetch_dividends_cached_with(&client, symbol, true, move |_: String| {
            let live = live_clone.clone();
            async move { Ok(live) }
        })
        .await
        .unwrap();
        assert_eq!(got.annual_rate, 9.0);
        let env: CacheEnvelope =
            serde_json::from_str(&get_raw(&client, &key).await.unwrap()).unwrap();
        assert_eq!(env.info.unwrap().annual_rate, 9.0);

        // Failure path: bypass still serves the (fresh) cached success.
        let got = fetch_dividends_cached_with(&client, symbol, true, |_: String| async {
            Err(anyhow!("yahoo down"))
        })
        .await
        .unwrap();
        assert_eq!(got.annual_rate, 9.0);

        del_key(&client, &key).await;
    }

    /// B2 coalescing: two concurrent calls for one symbol at cold cache
    /// produce exactly ONE fill — the loser waits on the per-symbol lock
    /// and re-reads the winner's envelope.
    #[tokio::test]
    async fn concurrent_cold_calls_coalesce_to_one_fill() {
        let Some(client) = test_redis().await else {
            eprintln!("skipping: dev Redis :6380 unreachable");
            return;
        };
        let symbol = "ZZTEST-B2-COALESCE";
        let key = cache_key(symbol);
        del_key(&client, &key).await;

        let calls = Arc::new(AtomicUsize::new(0));
        let slow_fetch = |s: String| {
            let calls = calls.clone();
            async move {
                calls.fetch_add(1, Ordering::SeqCst);
                tokio::time::sleep(std::time::Duration::from_millis(150)).await;
                Ok(sample_info(&s))
            }
        };
        let (a, b) = tokio::join!(
            fetch_dividends_cached_with(&client, symbol, false, &slow_fetch),
            fetch_dividends_cached_with(&client, symbol, false, &slow_fetch),
        );
        assert_eq!(a.unwrap().per_year, 4);
        assert_eq!(b.unwrap().per_year, 4);
        assert_eq!(calls.load(Ordering::SeqCst), 1, "concurrent cold calls must coalesce");
        // The lock-map entry was pruned once the last holder released it.
        assert!(!FETCH_LOCKS.lock().unwrap().contains_key(&key));

        del_key(&client, &key).await;
    }

    /// Redis unreachable degrades to a live fetch — never an error.
    #[tokio::test]
    async fn redis_down_degrades_to_live_fetch() {
        // Nothing listens on this port.
        let client = redis::Client::open("redis://127.0.0.1:1/").unwrap();
        let got = fetch_dividends_cached_with(&client, "ZZTEST-B1-NOREDIS", false, |s: String| async move {
            Ok(sample_info(&s))
        })
        .await
        .unwrap();
        assert_eq!(got.per_year, 4);
    }
}
