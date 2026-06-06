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

/// Contribution-timed "you vs the index" comparison over the user's tracked
/// holding lots: if each lot's cost had instead bought the S&P 500 on its
/// acquisition date, what would it be worth now — vs what those lots are
/// actually worth. This is a dollar-weighted (not net-worth) comparison, so it
/// only covers holdings we have lot history for.
#[derive(Debug, serde::Serialize)]
pub struct ContributionComparison {
    pub invested_usd: f64,
    pub your_value_usd: f64,
    pub benchmark_value_usd: f64,
    pub lot_count: i64,
}

pub async fn contribution_comparison(
    db: &PgPool,
    user_id: uuid::Uuid,
) -> ContributionComparison {
    let zero = ContributionComparison {
        invested_usd: 0.0,
        your_value_usd: 0.0,
        benchmark_value_usd: 0.0,
        lot_count: 0,
    };

    // Full S&P series, ascending, for date lookups.
    let sp = series(db, SP500, NaiveDate::from_ymd_opt(2000, 1, 1).unwrap()).await;
    let Some(&(_, latest_close)) = sp.last() else {
        return zero;
    };
    if latest_close <= 0.0 {
        return zero;
    }
    // S&P close on or just before `d`; falls back to the earliest close when
    // the lot predates our stored series.
    let close_on = |d: NaiveDate| -> f64 {
        match sp.binary_search_by(|(pd, _)| pd.cmp(&d)) {
            Ok(i) => sp[i].1,
            Err(0) => sp[0].1,
            Err(i) => sp[i - 1].1,
        }
    };

    let rows = sqlx::query(
        r#"
        SELECT l.qty, l.cost_per_unit, l.usd_fx_rate, l.acquired_at,
               h.value AS h_value, h.quantity AS h_qty
        FROM holding_lots l
        JOIN holdings h ON h.id = l.holding_id
        WHERE l.user_id = $1 AND l.qty > 0
        "#,
    )
    .bind(user_id)
    .fetch_all(db)
    .await
    .unwrap_or_default();

    let dec = |r: &sqlx::postgres::PgRow, c: &str| -> f64 {
        r.try_get::<rust_decimal::Decimal, _>(c)
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
            .unwrap_or(0.0)
    };

    let mut invested = 0.0;
    let mut your_value = 0.0;
    let mut benchmark_value = 0.0;
    let mut count = 0i64;
    for r in &rows {
        let qty = dec(r, "qty");
        let cost_per_unit = dec(r, "cost_per_unit");
        let fx = dec(r, "usd_fx_rate");
        let h_value = dec(r, "h_value");
        let h_qty = dec(r, "h_qty");
        let acquired: Option<NaiveDate> = r.try_get("acquired_at").ok();
        let Some(acquired) = acquired else { continue };

        let cost_usd = if fx > 0.0 {
            qty * cost_per_unit / fx
        } else {
            qty * cost_per_unit
        };
        if cost_usd <= 0.0 {
            continue;
        }
        // Current value of this lot, USD: lot's share of the holding's value.
        let cur_usd = if h_qty > 0.0 {
            qty * (h_value / h_qty)
        } else {
            0.0
        };
        let entry = close_on(acquired);
        let bench_usd = if entry > 0.0 {
            cost_usd * (latest_close / entry)
        } else {
            cost_usd
        };

        invested += cost_usd;
        your_value += cur_usd;
        benchmark_value += bench_usd;
        count += 1;
    }

    ContributionComparison {
        invested_usd: invested,
        your_value_usd: your_value,
        benchmark_value_usd: benchmark_value,
        lot_count: count,
    }
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
