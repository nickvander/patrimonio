//! Market-benchmark prices (S&P 500) for the "net worth vs the market" chart.
//!
//! Mirrors the FX pattern: fetch from a free, keyless source (the Yahoo Finance
//! v8 chart API), persist daily closes in `benchmark_prices`, and gate
//! re-fetches behind a freshness check so the dashboard reads come from our own
//! table, not the network. The series is refreshed lazily when the newest
//! stored close is more than a few days old.

use anyhow::{anyhow, Result};
use chrono::{Duration, NaiveDate, Utc};
use reqwest::Client;
use rust_decimal::Decimal;
use sqlx::{PgPool, Row};
use std::str::FromStr;

pub const SP500: &str = "SP500";

/// Newest stored trading day for `symbol`, if any.
pub async fn latest_date(db: &PgPool, symbol: &str) -> Option<NaiveDate> {
    sqlx::query("SELECT MAX(price_date) AS d FROM benchmark_prices WHERE symbol = $1")
        .bind(symbol)
        .fetch_optional(db)
        .await
        .ok()
        .flatten()
        .and_then(|r| r.try_get::<Option<NaiveDate>, _>("d").ok().flatten())
}

/// Fetch ~5 years of daily S&P 500 closes from Yahoo and upsert them.
/// Returns how many rows were written. Network failures bubble up so the
/// caller can fall back to whatever is already stored.
pub async fn refresh_sp500(db: &PgPool) -> Result<usize> {
    let url = "https://query1.finance.yahoo.com/v8/finance/chart/%5EGSPC?range=5y&interval=1d";
    let client = Client::new();
    let body = client
        .get(url)
        .header("User-Agent", "Mozilla/5.0 (Patrimonio)")
        .send()
        .await?
        .text()
        .await?;
    let v: serde_json::Value = serde_json::from_str(&body)?;

    let result = v
        .pointer("/chart/result/0")
        .ok_or_else(|| anyhow!("unexpected Yahoo chart shape"))?;
    let timestamps = result
        .pointer("/timestamp")
        .and_then(|t| t.as_array())
        .ok_or_else(|| anyhow!("no timestamps"))?;
    let closes = result
        .pointer("/indicators/quote/0/close")
        .and_then(|c| c.as_array())
        .ok_or_else(|| anyhow!("no closes"))?;

    // Pair (timestamp, close), skipping holidays where Yahoo emits null.
    let mut rows: Vec<(NaiveDate, Decimal)> = Vec::new();
    for (ts, close) in timestamps.iter().zip(closes.iter()) {
        let (Some(ts), Some(c)) = (ts.as_i64(), close.as_f64()) else {
            continue;
        };
        let Some(dt) = chrono::DateTime::from_timestamp(ts, 0) else {
            continue;
        };
        if let Ok(dec) = Decimal::from_str(&format!("{:.4}", c)) {
            rows.push((dt.naive_utc().date(), dec));
        }
    }
    if rows.is_empty() {
        return Err(anyhow!("Yahoo returned no usable S&P 500 points"));
    }

    // Multi-row upsert in chunks (Postgres caps bind params at 65535).
    let mut written = 0usize;
    for chunk in rows.chunks(1000) {
        let mut qb = sqlx::QueryBuilder::new(
            "INSERT INTO benchmark_prices (symbol, price_date, close) ",
        );
        qb.push_values(chunk, |mut b, (date, close)| {
            b.push_bind(SP500).push_bind(date).push_bind(close);
        });
        qb.push(" ON CONFLICT (symbol, price_date) DO UPDATE SET close = EXCLUDED.close, recorded_at = NOW()");
        qb.build().execute(db).await?;
        written += chunk.len();
    }

    tracing::info!("Refreshed S&P 500 benchmark: {} daily closes", written);
    Ok(written)
}

/// Ensure the S&P 500 series is reasonably fresh (newest close within ~4 days,
/// covering weekends/holidays), refreshing from the network if not. Tolerates
/// network failure as long as *some* data already exists.
pub async fn ensure_fresh(db: &PgPool) -> Result<()> {
    let stale = match latest_date(db, SP500).await {
        Some(d) => Utc::now().date_naive() - d > Duration::days(4),
        None => true,
    };
    if stale {
        if let Err(e) = refresh_sp500(db).await {
            // Only hard-fail when we have nothing to serve at all.
            if latest_date(db, SP500).await.is_none() {
                return Err(e);
            }
            tracing::warn!("S&P 500 refresh failed, serving cached series: {e}");
        }
    }
    Ok(())
}

/// Daily closes for `symbol` on or after `from`, ascending.
pub async fn series(db: &PgPool, symbol: &str, from: NaiveDate) -> Vec<(NaiveDate, f64)> {
    let rows = sqlx::query(
        "SELECT price_date, close FROM benchmark_prices \
         WHERE symbol = $1 AND price_date >= $2 ORDER BY price_date ASC",
    )
    .bind(symbol)
    .bind(from)
    .fetch_all(db)
    .await
    .unwrap_or_default();
    rows.iter()
        .filter_map(|r| {
            let d: NaiveDate = r.try_get("price_date").ok()?;
            let c: Decimal = r.try_get("close").ok()?;
            Some((d, c.to_string().parse().unwrap_or(0.0)))
        })
        .collect()
}
