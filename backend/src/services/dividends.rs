//! Dividend info for an equity symbol, from the free Yahoo Finance chart API
//! (`events=div`) — the same no-auth source as the price cache. We derive a
//! trailing-12-month rate, the last ex-dividend date, and an *estimated* next
//! ex-date (last + the median pay interval). The estimate is honest: Yahoo's
//! authenticated calendar endpoint would give the announced date, but the
//! public chart feed only carries history.

use anyhow::{anyhow, Result};
use chrono::{Duration, NaiveDate};
use reqwest::Client;
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct DividendInfo {
    pub symbol: String,
    /// Trailing-12-month dividend per share (0 for non-payers).
    pub annual_rate: f64,
    pub last_amount: f64,
    /// ISO dates.
    pub last_ex_date: Option<String>,
    pub est_next_ex_date: Option<String>,
    /// Payments seen in the trailing year (4 = quarterly).
    pub per_year: i32,
}

impl DividendInfo {
    fn none(symbol: &str) -> Self {
        DividendInfo {
            symbol: symbol.to_string(),
            annual_rate: 0.0,
            last_amount: 0.0,
            last_ex_date: None,
            est_next_ex_date: None,
            per_year: 0,
        }
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

    let cutoff = last_date - Duration::days(365);
    let recent: Vec<&(NaiveDate, f64)> =
        points.iter().filter(|(d, _)| *d > cutoff).collect();
    let annual_rate: f64 = recent.iter().map(|(_, a)| *a).sum();
    let per_year = recent.len() as i32;

    let mut intervals: Vec<i64> = points
        .windows(2)
        .map(|w| (w[1].0 - w[0].0).num_days())
        .filter(|d| *d > 0)
        .collect();
    intervals.sort_unstable();
    let est_next = intervals
        .get(intervals.len() / 2)
        .map(|med| last_date + Duration::days(*med));

    Ok(DividendInfo {
        symbol: symbol.to_string(),
        annual_rate: (annual_rate * 10000.0).round() / 10000.0,
        last_amount,
        last_ex_date: Some(last_date.to_string()),
        est_next_ex_date: est_next.map(|d| d.to_string()),
        per_year,
    })
}
