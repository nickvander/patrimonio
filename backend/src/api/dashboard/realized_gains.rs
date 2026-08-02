use axum::{
    extract::{Extension, Query, State},
    response::Response,
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use tracing::error;

use crate::api::middleware::AuthContext;
use crate::AppState;

use super::*;

#[derive(Deserialize)]
pub(super) struct RealizedGainsQuery {
    /// Optional calendar-year filter on the disposal list (the summary +
    /// by-year chart always cover all history).
    year: Option<i32>,
}

#[derive(Serialize)]
struct RealizedDisposal {
    symbol: String,
    name: String,
    /// Contract C-C: owning account's display name (nickname-aware).
    /// Archived accounts are included — history must keep its context. Null
    /// only if the account row is gone.
    account_name: Option<String>,
    account_type: Option<String>,
    /// Whether the disposal happened inside a tax-advantaged wrapper — the
    /// SAME `TAX_ADVANTAGED_ACCOUNT_TYPES` list Tax planning uses, so the
    /// card's taxable subtotal and the tax module never disagree.
    tax_advantaged: bool,
    sell_date: String,
    qty_sold: f64,
    proceeds_usd: f64,
    cost_usd: f64,
    realized_pnl_usd: f64,
    /// Holding period in days (null when the source lot was later deleted).
    holding_days: Option<i32>,
    /// IRS long-term threshold: held > 365 days. Null when unknown.
    long_term: Option<bool>,
}

/// Decode one disposal row (the C-C query shape) into its JSON form —
/// shared by the JSON handler and the CSV exporter so the per-row math
/// (FX-aware proceeds/cost, calendar long-term rule) lives in one place.
fn disposal_from_row(r: &sqlx::postgres::PgRow) -> RealizedDisposal {
    let dec = |col: &str| -> f64 {
        r.try_get::<rust_decimal::Decimal, _>(col)
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
            .unwrap_or(0.0)
    };

    let qty = dec("qty_sold");
    let sell_px = dec("sell_price_per_unit");
    let sell_fx = dec("sell_fx_rate");
    let cost_px = dec("cost_per_unit");
    let cost_fx = dec("cost_fx_rate");
    // fx rate is native-units-per-USD (1.0 for USD securities), so
    // divide native amounts by it to land in USD.
    let proceeds_usd = if sell_fx > 0.0 {
        qty * sell_px / sell_fx
    } else {
        qty * sell_px
    };
    let cost_usd = if cost_fx > 0.0 {
        qty * cost_px / cost_fx
    } else {
        qty * cost_px
    };
    let holding_days: Option<i32> = r.try_get("holding_days").ok();
    // Long-term flag uses the SAME calendar rule as the tax module
    // (TaxCalculator::is_long_term): sold > acquired + 12 calendar
    // months, with checked_add_months clamping Feb-29 → Feb-28. This
    // replaces the old `holding_days > 365` count so the flag agrees
    // across leap years and with the tax-filing buckets. When the
    // source lot is gone (LEFT JOIN → NULL acquired_at) we can't apply
    // the calendar rule, so the flag stays None.
    let acquired_date: Option<chrono::NaiveDate> = r.try_get("acquired_date").ok();
    let sell_date_raw: Option<chrono::NaiveDate> = r.try_get("sell_date_raw").ok();
    let long_term = match (acquired_date, sell_date_raw) {
        (Some(acq), Some(sold)) => acq
            .checked_add_months(chrono::Months::new(12))
            .map(|anniversary| sold > anniversary),
        _ => None,
    };
    let account_type: Option<String> = r
        .try_get::<Option<String>, _>("account_type")
        .ok()
        .flatten();
    let tax_advantaged =
        crate::services::tax::is_tax_advantaged_account_type(account_type.as_deref());
    RealizedDisposal {
        symbol: r.get("symbol"),
        name: r.get("name"),
        account_name: r
            .try_get::<Option<String>, _>("account_name")
            .ok()
            .flatten(),
        account_type,
        tax_advantaged,
        sell_date: r.get("sell_date"),
        qty_sold: qty,
        proceeds_usd,
        cost_usd,
        realized_pnl_usd: dec("realized_pnl_usd"),
        holding_days,
        long_term,
    }
}

/// The disposals query shared by the JSON handler and the CSV exporter
/// (C-C / C-E). `LEFT JOIN accounts` with NO archived filter: a disposal
/// that happened in a since-archived account must keep its context.
const REALIZED_DISPOSALS_SQL: &str = r#"
        SELECT TO_CHAR(d.sell_date, 'YYYY-MM-DD') AS sell_date,
               d.sell_date AS sell_date_raw,
               l.acquired_at AS acquired_date,
               d.qty_sold, d.sell_price_per_unit, d.sell_fx_rate,
               d.cost_per_unit, d.cost_fx_rate, d.realized_pnl_usd,
               h.symbol, h.name,
               COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name,
               a.account_type,
               (d.sell_date - l.acquired_at) AS holding_days
        FROM lot_disposals d
        JOIN holdings h ON h.id = d.holding_id
        LEFT JOIN holding_lots l ON l.id = d.lot_id
        LEFT JOIN accounts a ON a.id = h.account_id
        WHERE d.user_id = $1
          AND h.deleted_at IS NULL
          AND ($2::int IS NULL OR EXTRACT(YEAR FROM d.sell_date)::int = $2)
        ORDER BY d.sell_date DESC
"#;

#[derive(Serialize)]
struct RealizedYear {
    year: i32,
    realized_usd: f64,
}

#[derive(Serialize)]
struct RealizedGainsSummary {
    ytd_realized_usd: f64,
    total_realized_usd: f64,
    /// Contract C-C: Σ `realized_pnl_usd` over the returned (year-filtered)
    /// list's rows that sit in NON-tax-advantaged accounts — the number that
    /// must match Tax planning's taxable figure to the cent.
    taxable_realized_usd: f64,
    /// Count of disposal rows in the (optionally year-filtered) list.
    count: i64,
    /// The year filter applied to the list, if any.
    year: Option<i32>,
}

#[derive(Serialize)]
pub(super) struct RealizedGainsResponse {
    summary: RealizedGainsSummary,
    by_year: Vec<RealizedYear>,
    disposals: Vec<RealizedDisposal>,
}

/// Realized capital gains/losses from `lot_disposals` — the per-sell P&L the
/// FIFO engine crystallizes but the holdings view never surfaces. Each row is
/// one (sell event, depleted lot) pair; `realized_pnl_usd` is pre-computed at
/// sync time. We add USD proceeds/cost for display and a long-term flag
/// (sold > acquired + 12 calendar months, matching the tax module's
/// `is_long_term`) for tax context, joining the source lot for the
/// acquisition date when it still exists.
pub(super) async fn realized_gains(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<RealizedGainsQuery>,
) -> Json<RealizedGainsResponse> {
    let dec = |r: &sqlx::postgres::PgRow, col: &str| -> f64 {
        r.try_get::<rust_decimal::Decimal, _>(col)
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
            .unwrap_or(0.0)
    };

    let rows = sqlx::query(&format!("{REALIZED_DISPOSALS_SQL} LIMIT 500"))
        .bind(ctx.user_id)
        .bind(q.year)
        .fetch_all(&state.db)
        .await
        .unwrap_or_default();

    let disposals: Vec<RealizedDisposal> = rows.iter().map(disposal_from_row).collect();

    let count = disposals.len() as i64;
    // C-C: taxable subtotal over the RETURNED (year-filtered) list only —
    // the card caption pairs it with the same period's total.
    let taxable_realized_usd: f64 = disposals
        .iter()
        .filter(|d| !d.tax_advantaged)
        .map(|d| d.realized_pnl_usd)
        .sum();

    // By-year totals across ALL history (independent of the list filter).
    let year_rows = sqlx::query(
        r#"
        SELECT EXTRACT(YEAR FROM sell_date)::int AS year,
               COALESCE(SUM(realized_pnl_usd), 0) AS total
        FROM lot_disposals
        WHERE user_id = $1
          -- Round 3 soft delete: no holdings join here, so an EXISTS guard.
          AND EXISTS (SELECT 1 FROM holdings h
                      WHERE h.id = lot_disposals.holding_id AND h.deleted_at IS NULL)
        GROUP BY year
        ORDER BY year ASC
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let by_year: Vec<RealizedYear> = year_rows
        .iter()
        .map(|r| RealizedYear {
            year: r.try_get("year").unwrap_or(0),
            realized_usd: dec(r, "total"),
        })
        .collect();

    let total_realized_usd: f64 = by_year.iter().map(|y| y.realized_usd).sum();

    let ytd_row = sqlx::query(
        r#"
        SELECT COALESCE(SUM(realized_pnl_usd), 0) AS total
        FROM lot_disposals
        WHERE user_id = $1
          AND EXTRACT(YEAR FROM sell_date) = EXTRACT(YEAR FROM CURRENT_DATE)
          -- Round 3 soft delete: no holdings join here, so an EXISTS guard.
          AND EXISTS (SELECT 1 FROM holdings h
                      WHERE h.id = lot_disposals.holding_id AND h.deleted_at IS NULL)
        "#,
    )
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten();
    let ytd_realized_usd = ytd_row.as_ref().map(|r| dec(r, "total")).unwrap_or(0.0);

    Json(RealizedGainsResponse {
        summary: RealizedGainsSummary {
            ytd_realized_usd,
            total_realized_usd,
            taxable_realized_usd,
            count,
            year: q.year,
        },
        by_year,
        disposals,
    })
}

/// C-E: the realized-gains list as a CSV download — same rows and order as
/// the JSON endpoint (including the C-C account context), but with NO
/// LIMIT-500 truncation: both ends of the pipe stream, cloning
/// `export_transactions_csv`'s channel pattern.
pub(super) async fn export_realized_gains_csv(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<RealizedGainsQuery>,
) -> Response {
    use bytes::Bytes;
    use futures_util::StreamExt;

    let today = chrono::Local::now().format("%Y-%m-%d").to_string();
    let filename = match q.year {
        Some(y) => format!("patrimonio_realized_gains_{y}_{today}.csv"),
        None => format!("patrimonio_realized_gains_{today}.csv"),
    };

    let (tx, rx) = tokio::sync::mpsc::channel::<Result<Bytes, std::io::Error>>(16);
    let db = state.db.clone();
    let user_id = ctx.user_id;
    let year = q.year;

    tokio::spawn(async move {
        if tx
            .send(Ok(Bytes::from_static(
                b"sell_date,symbol,name,account,account_type,tax_advantaged,qty_sold,proceeds_usd,cost_usd,realized_pnl_usd,holding_days,long_term\n",
            )))
            .await
            .is_err()
        {
            return;
        }

        let mut stream = sqlx::query(REALIZED_DISPOSALS_SQL)
            .bind(user_id)
            .bind(year)
            .fetch(&db);

        while let Some(row_result) = stream.next().await {
            let row = match row_result {
                Ok(r) => r,
                Err(e) => {
                    error!("export_realized_gains_csv stream error: {}", e);
                    let _ = tx
                        .send(Err(std::io::Error::other(format!("csv stream: {e}"))))
                        .await;
                    return;
                }
            };
            let d = disposal_from_row(&row);
            let line = format!(
                // Money fields at 2dp (proceeds/cost/PnL are qty×price float
                // products that otherwise leak `.9999999999995` noise);
                // qty_sold keeps full precision for fractional lots.
                "{},{},{},{},{},{},{},{:.2},{:.2},{:.2},{},{}\n",
                d.sell_date,
                csv_field(&d.symbol),
                csv_field(&d.name),
                csv_field(d.account_name.as_deref().unwrap_or("")),
                csv_field(d.account_type.as_deref().unwrap_or("")),
                d.tax_advantaged,
                d.qty_sold,
                d.proceeds_usd,
                d.cost_usd,
                d.realized_pnl_usd,
                // Empty string for unknowns (deleted source lot), per C-E.
                d.holding_days.map(|v| v.to_string()).unwrap_or_default(),
                d.long_term.map(|v| v.to_string()).unwrap_or_default(),
            );
            if tx.send(Ok(Bytes::from(line))).await.is_err() {
                return;
            }
        }
    });

    let body = axum::body::Body::from_stream(tokio_stream::wrappers::ReceiverStream::new(rx));
    csv_attachment_response(&filename, body)
}
