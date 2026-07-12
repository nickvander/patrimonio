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

/// The picker's small, curated set of "most common" benchmarks. Each entry maps
/// a stable `store_as` key (also the API value and `benchmark_prices.symbol`) to
/// the Yahoo chart-API symbol with reliable daily history. URL-encode the caret
/// (`%5E`) for Yahoo index tickers; plain ETF tickers need no encoding.
/// Anything not in this table resolves to the S&P 500 default, so an unknown or
/// illiquid `?benchmark=` fails soft to the existing behavior rather than 500ing.
const BENCHMARKS: &[(&str, &str)] = &[
    (SP500, "%5EGSPC"),  // S&P 500 (^GSPC)
    ("NDX", "%5ENDX"),   // Nasdaq-100 (^NDX)
    ("ACWI", "ACWI"),    // MSCI ACWI / Total World ETF
    ("AGG", "AGG"),      // US Aggregate Bonds ETF
    ("MXX", "%5EMXX"),   // IPC Mexico (^MXX)
];

/// Resolve a requested benchmark key to its `(store_as, yahoo_symbol)`. Unknown
/// or empty keys fall back to the S&P 500 so the comparison still renders. The
/// returned `store_as` is what to pass to [`series`]/[`ensure_symbol_fresh`].
pub fn resolve_benchmark(requested: Option<&str>) -> (&'static str, &'static str) {
    let want = requested.unwrap_or(SP500);
    BENCHMARKS
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case(want))
        .copied()
        .unwrap_or((SP500, "%5EGSPC"))
}

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
    // `%5E` is the URL-encoded caret in Yahoo's index ticker `^GSPC`.
    refresh_yahoo(db, "%5EGSPC", SP500).await
}

/// Fetch ~5 years of daily closes for `yahoo_symbol` from the Yahoo v8 chart
/// API and upsert them into `benchmark_prices` under `store_as`. This is the
/// generic engine behind both the S&P benchmark and the per-holding quote
/// cache used by the time-weighted-return computation — same table, same
/// freshness gate, just a different symbol. Returns how many rows were
/// written; network/parse failures bubble up so callers can fall back to
/// whatever is already stored.
pub async fn refresh_yahoo(db: &PgPool, yahoo_symbol: &str, store_as: &str) -> Result<usize> {
    let url = format!(
        "https://query1.finance.yahoo.com/v8/finance/chart/{yahoo_symbol}?range=5y&interval=1d"
    );
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
        if let Ok(dec) = Decimal::from_str(&format!("{c:.4}")) {
            rows.push((dt.naive_utc().date(), dec));
        }
    }
    if rows.is_empty() {
        return Err(anyhow!("Yahoo returned no usable points for {store_as}"));
    }

    // Multi-row upsert in chunks (Postgres caps bind params at 65535).
    let mut written = 0usize;
    for chunk in rows.chunks(1000) {
        let mut qb = sqlx::QueryBuilder::new(
            "INSERT INTO benchmark_prices (symbol, price_date, close) ",
        );
        qb.push_values(chunk, |mut b, (date, close)| {
            b.push_bind(store_as).push_bind(date).push_bind(close);
        });
        qb.push(" ON CONFLICT (symbol, price_date) DO UPDATE SET close = EXCLUDED.close, recorded_at = NOW()");
        qb.build().execute(db).await?;
        written += chunk.len();
    }

    tracing::info!("Refreshed {} quote series: {} daily closes", store_as, written);
    Ok(written)
}

/// Ensure the S&P 500 series is reasonably fresh (newest close within ~4 days,
/// covering weekends/holidays), refreshing from the network if not. Tolerates
/// network failure as long as *some* data already exists.
pub async fn ensure_fresh(db: &PgPool) -> Result<()> {
    ensure_symbol_fresh(db, "%5EGSPC", SP500).await
}

/// Generic freshness gate for any cached quote series. Refreshes
/// `store_as` from `yahoo_symbol` when the newest stored close is more than
/// ~4 days old (covering weekends/holidays). Tolerates network failure as
/// long as *some* data is already stored for `store_as`.
pub async fn ensure_symbol_fresh(
    db: &PgPool,
    yahoo_symbol: &str,
    store_as: &str,
) -> Result<()> {
    let stale = match latest_date(db, store_as).await {
        Some(d) => Utc::now().date_naive() - d > Duration::days(4),
        None => true,
    };
    if stale {
        if let Err(e) = refresh_yahoo(db, yahoo_symbol, store_as).await {
            // Only hard-fail when we have nothing to serve at all.
            if latest_date(db, store_as).await.is_none() {
                return Err(e);
            }
            tracing::warn!("{store_as} quote refresh failed, serving cached series: {e}");
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
    /// Per-ticker breakdown of the counted lots. Each row is aggregated with
    /// the SAME per-lot math as the totals above, so summing the rows
    /// reproduces the totals (modulo the 2dp presentation rounding applied
    /// per row). Sorted by `invested_usd` descending.
    pub symbols: Vec<SymbolComparison>,
    /// Holdings in the same population the comparison draws from (this
    /// user's non-deleted holdings) that have current value but contributed
    /// ZERO counted lots — either no lots at all, or every lot skipped
    /// (missing acquired date / non-positive cost). Surfaced so the owner
    /// can see what the dollar-weighted comparison does NOT cover.
    /// Sorted by `value_usd` descending.
    pub untracked: Vec<UntrackedHolding>,
    pub untracked_value_usd: f64,
}

/// One distinct holding symbol's slice of the contribution comparison.
/// `first_acquired` / `last_acquired` are ISO `YYYY-MM-DD` of the earliest /
/// latest counted lot for the symbol.
#[derive(Debug, serde::Serialize)]
pub struct SymbolComparison {
    pub symbol: String,
    pub lot_count: i64,
    pub invested_usd: f64,
    pub your_value_usd: f64,
    pub benchmark_value_usd: f64,
    pub first_acquired: String,
    pub last_acquired: String,
}

/// A holding the comparison can't see (no counted lots) but which holds real
/// value today. `value_usd` follows the counted path's `h.value` convention
/// (used as USD as-is — see the lot loop's `cur_usd`), so the tracked and
/// untracked columns are directly comparable.
#[derive(Debug, serde::Serialize)]
pub struct UntrackedHolding {
    pub symbol: String,
    pub value_usd: f64,
}

/// Presentation rounding for the money fields of the per-symbol / untracked
/// breakdown: house rule is `Decimal::round_dp(2)` before handing an f64 to
/// the client.
fn round2(v: f64) -> f64 {
    use rust_decimal::prelude::ToPrimitive;
    Decimal::from_f64_retain(v)
        .map(|d| d.round_dp(2))
        .and_then(|d| d.to_f64())
        .unwrap_or(v)
}

pub async fn contribution_comparison(
    db: &PgPool,
    user_id: uuid::Uuid,
    benchmark: Option<&str>,
) -> ContributionComparison {
    let zero = ContributionComparison {
        invested_usd: 0.0,
        your_value_usd: 0.0,
        benchmark_value_usd: 0.0,
        lot_count: 0,
        symbols: Vec::new(),
        untracked: Vec::new(),
        untracked_value_usd: 0.0,
    };

    // Resolve the requested benchmark (defaults to S&P 500) and make sure its
    // series is reasonably fresh before reading. A bad/illiquid symbol that
    // can't be fetched simply yields an empty series → we return `zero`
    // (no benchmark numbers), never a 500.
    let (store_as, yahoo_symbol) = resolve_benchmark(benchmark);
    let _ = ensure_symbol_fresh(db, yahoo_symbol, store_as).await;

    // Full benchmark series, ascending, for date lookups.
    let sp = series(db, store_as, NaiveDate::from_ymd_opt(2000, 1, 1).unwrap()).await;
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
               h.id AS holding_id, h.symbol, h.name,
               h.value AS h_value, h.quantity AS h_qty
        FROM holding_lots l
        JOIN holdings h ON h.id = l.holding_id
        WHERE l.user_id = $1 AND l.qty > 0 AND h.deleted_at IS NULL
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

    // Per-symbol accumulator: exactly the same per-lot numbers as the
    // totals, just bucketed by display symbol, so the rows always sum back
    // to the aggregate the chart shows.
    struct SymAgg {
        lot_count: i64,
        invested: f64,
        your_value: f64,
        benchmark_value: f64,
        first_acquired: NaiveDate,
        last_acquired: NaiveDate,
    }
    let mut by_symbol: std::collections::HashMap<String, SymAgg> =
        std::collections::HashMap::new();
    // Holdings that contributed at least one counted lot — everything else
    // in the population with value is "untracked" below.
    let mut counted_holdings: std::collections::HashSet<uuid::Uuid> =
        std::collections::HashSet::new();

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

        if let Ok(hid) = r.try_get::<uuid::Uuid, _>("holding_id") {
            counted_holdings.insert(hid);
        }
        let agg = by_symbol
            .entry(display_symbol(r))
            .or_insert_with(|| SymAgg {
                lot_count: 0,
                invested: 0.0,
                your_value: 0.0,
                benchmark_value: 0.0,
                first_acquired: acquired,
                last_acquired: acquired,
            });
        agg.lot_count += 1;
        agg.invested += cost_usd;
        agg.your_value += cur_usd;
        agg.benchmark_value += bench_usd;
        agg.first_acquired = agg.first_acquired.min(acquired);
        agg.last_acquired = agg.last_acquired.max(acquired);
    }

    let mut symbols: Vec<SymbolComparison> = by_symbol
        .into_iter()
        .map(|(symbol, a)| SymbolComparison {
            symbol,
            lot_count: a.lot_count,
            invested_usd: round2(a.invested),
            your_value_usd: round2(a.your_value),
            benchmark_value_usd: round2(a.benchmark_value),
            first_acquired: a.first_acquired.to_string(),
            last_acquired: a.last_acquired.to_string(),
        })
        .collect();
    symbols.sort_by(|a, b| {
        b.invested_usd
            .partial_cmp(&a.invested_usd)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    // Holdings the comparison could NOT see: same population as the lot
    // query (this user's non-deleted holdings — deliberately no account
    // filter, matching the counted JOIN above), currently worth something,
    // but with zero counted lots. `h.value` is used as USD as-is, exactly
    // like `cur_usd` above — the two columns must stay comparable.
    let untracked_rows = sqlx::query(
        r#"
        SELECT h.id, h.symbol, h.name, h.value
        FROM holdings h
        WHERE h.user_id = $1 AND h.deleted_at IS NULL AND h.value > 0
        "#,
    )
    .bind(user_id)
    .fetch_all(db)
    .await
    .unwrap_or_default();

    let mut untracked: Vec<UntrackedHolding> = untracked_rows
        .iter()
        .filter(|r| {
            !r.try_get::<uuid::Uuid, _>("id")
                .map(|id| counted_holdings.contains(&id))
                .unwrap_or(false)
        })
        .map(|r| UntrackedHolding {
            symbol: display_symbol(r),
            value_usd: round2(dec(r, "value")),
        })
        .collect();
    untracked.sort_by(|a, b| {
        b.value_usd
            .partial_cmp(&a.value_usd)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let untracked_value_usd = round2(untracked.iter().map(|u| u.value_usd).sum());

    ContributionComparison {
        invested_usd: invested,
        your_value_usd: your_value,
        benchmark_value_usd: benchmark_value,
        lot_count: count,
        symbols,
        untracked,
        untracked_value_usd,
    }
}

/// Display key for a holdings row: the ticker symbol, falling back to the
/// holding's name when the symbol is empty/whitespace (both columns are
/// NOT NULL, but manual entries sometimes leave the symbol blank).
fn display_symbol(r: &sqlx::postgres::PgRow) -> String {
    let symbol: String = r.try_get("symbol").unwrap_or_default();
    let trimmed = symbol.trim();
    if trimmed.is_empty() {
        let name: String = r.try_get("name").unwrap_or_default();
        name.trim().to_string()
    } else {
        trimmed.to_string()
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
