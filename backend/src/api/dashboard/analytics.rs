use axum::{
    extract::{Extension, Query, State},
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;

use crate::api::error::{internal, ApiError};
use crate::api::middleware::AuthContext;
use crate::services::fx::USD_MXN_ROW_RATE_SQL;
use crate::AppState;

use super::*;

#[derive(Deserialize)]
pub(super) struct BenchmarkQuery {
    /// ISO date (YYYY-MM-DD) to start the series from. Defaults to ~3 years ago.
    from: Option<String>,
}

#[derive(Serialize)]
struct BenchmarkPoint {
    date: String,
    close: f64,
}

#[derive(Serialize)]
pub(super) struct BenchmarkResponse {
    symbol: String,
    points: Vec<BenchmarkPoint>,
}

/// S&P 500 daily closes for overlaying "net worth vs the market". Lazily
/// refreshes from the free Yahoo feed when stale, then serves from our table.
/// Not user-scoped — the index is the same for everyone — but still behind
/// auth like the rest of the dashboard.
pub(super) async fn benchmark_series(
    State(state): State<AppState>,
    Extension(_ctx): Extension<AuthContext>,
    Query(q): Query<BenchmarkQuery>,
) -> Json<BenchmarkResponse> {
    use crate::services::benchmark;
    // Best-effort freshness; on failure we still serve whatever is stored.
    let _ = benchmark::ensure_fresh(&state.db).await;

    let from = q
        .from
        .as_deref()
        .and_then(|s| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").ok())
        .unwrap_or_else(|| chrono::Utc::now().date_naive() - chrono::Duration::days(365 * 3));

    let points = benchmark::series(&state.db, benchmark::SP500, from)
        .await
        .into_iter()
        .map(|(d, c)| BenchmarkPoint {
            date: d.format("%Y-%m-%d").to_string(),
            close: c,
        })
        .collect();

    Json(BenchmarkResponse {
        symbol: benchmark::SP500.to_string(),
        points,
    })
}

/// Optional `?benchmark=` selector shared by the TWR + contribution-comparison
/// endpoints. Defaults (when absent) to the S&P 500, preserving prior behavior;
/// an unrecognized/illiquid symbol fails soft in the service layer.
#[derive(Deserialize)]
pub(super) struct BenchmarkSelectQuery {
    benchmark: Option<String>,
}

/// Dollar-weighted "you vs the selected benchmark" over the user's tracked
/// holding lots. `?benchmark=` defaults to the S&P 500 when omitted.
pub(super) async fn benchmark_comparison(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<BenchmarkSelectQuery>,
) -> Json<crate::services::benchmark::ContributionComparison> {
    Json(
        crate::services::benchmark::contribution_comparison(
            &state.db,
            ctx.user_id,
            q.benchmark.as_deref(),
        )
        .await,
    )
}

/// True time-weighted return: a daily growth index of the investment
/// portfolio (cashflows divided out) + the S&P 500 over the same dates, plus
/// how much of the portfolio we can price historically (`coverage_pct`).
pub(super) async fn portfolio_twr(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<BenchmarkSelectQuery>,
) -> Json<crate::services::twr::TwrResult> {
    Json(crate::services::twr::portfolio_twr(&state.db, ctx.user_id, q.benchmark.as_deref()).await)
}

#[derive(Serialize)]
pub(super) struct EmergencyFundResponse {
    /// Total liquid cash across checking/savings/cash accounts, USD.
    liquid_cash_usd: f64,
    /// Trailing average monthly spending, USD (same hygiene as cash-flow).
    monthly_spend_usd: f64,
    /// liquid_cash / monthly_spend; 0 when there's no spend signal yet.
    months_covered: f64,
    /// Distinct months of spending data backing the estimate.
    months_of_data: i32,
}

/// Emergency-fund runway: how many months of tracked spending the user's liquid
/// cash would cover. Cash is USD-normalized like the rest of the dashboard;
/// spend reuses the cash-flow exclusions (no transfers / CC payments / lending
/// legs / split parents), annualized over however many months exist.
pub(super) async fn emergency_fund(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Result<Json<EmergencyFundResponse>, ApiError> {
    // Shared FX policy for CURRENT balances: real latest rate when present,
    // hard fallback flagged stale (and warn-logged) when missing/old. The
    // latest rate is correct here — a cash balance is a present-day value, so
    // it converts at the present-day rate. Historical spend below deliberately
    // does NOT use this: each transaction converts at its own date's rate.
    let fx = latest_usd_mxn_rate(&state.db).await.rate;

    let cash_row = sqlx::query(
        r#"
        SELECT COALESCE(SUM(
            CASE WHEN currency = 'MXN' THEN current_balance / $2::numeric
                 ELSE current_balance END), 0) AS cash
        FROM accounts
        WHERE user_id = $1
          AND archived_at IS NULL
          -- CDs are excluded: they carry an early-withdrawal penalty, so they
          -- are not the immediately-accessible cash an emergency fund measures.
          AND account_type IN ('checking', 'savings', 'cash', 'cash management', 'money market')
        "#,
    )
    .bind(ctx.user_id)
    .bind(fx)
    // Ungrouped COALESCE(SUM(...), 0) aggregate: always exactly one non-NULL
    // row, even with zero matching accounts — so fetch_one, and any failure
    // is a real DB/decode error. The old `.ok().flatten()` turned "query blew
    // up" into an all-zeros runway indistinguishable from "no cash tracked";
    // now it surfaces as a logged 500 (mirrors projections::projection_defaults).
    .fetch_one(&state.db)
    .await
    .map_err(internal)?;
    let liquid_cash_usd: f64 = cash_row
        .try_get::<rust_decimal::Decimal, _>("cash")
        .map_err(internal)?
        .to_string()
        .parse()
        .unwrap_or(0.0);

    // Trailing spend + month count. The exclusion set is the SHARED fragment
    // (trailing_cashflow_exclusions_sql) used verbatim by
    // `projections::projection_defaults`, so the two trailing-12-mo
    // aggregations can never silently drift.
    //
    // FX is PER ROW: each MXN transaction is divided by the USD→MXN rate in
    // effect on its own date (the shared `USD_MXN_ROW_RATE_SQL` rule from
    // services::fx — on-or-before-date rate, else latest, else 20.0). This
    // trailing-12-month spend used to divide by the single LATEST rate, so a
    // peso trend skewed the runway's monthly-spend denominator. (The cash
    // numerator above correctly keeps the latest rate — it's a current value.)
    let excl = trailing_cashflow_exclusions_sql();
    let spend_sql = format!(
        r#"
        SELECT
            COALESCE(SUM(CASE WHEN a.currency = 'MXN'
                     THEN ABS(t.amount) / fx.rate
                     ELSE ABS(t.amount) END), 0) AS spending,
            COUNT(DISTINCT TO_CHAR(t.date, 'YYYY-MM')) AS months
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        CROSS JOIN LATERAL (SELECT {USD_MXN_ROW_RATE_SQL} AS rate) fx
        WHERE t.amount < 0
        {excl}
        "#,
    );
    // Same shape as the cash query above: ungrouped aggregate → exactly one
    // row, COALESCE/COUNT are never NULL. Zero transactions still decodes as
    // (0, 0) — only genuine DB/decode failures become logged 500s (the old
    // `.ok().flatten()` shipped them as a fabricated all-zeros runway).
    let spend_row = sqlx::query(&spend_sql)
        .bind(ctx.user_id)
        .fetch_one(&state.db)
        .await
        .map_err(internal)?;

    let spending: f64 = spend_row
        .try_get::<rust_decimal::Decimal, _>("spending")
        .map_err(internal)?
        .to_string()
        .parse()
        .unwrap_or(0.0);
    let months: i64 = spend_row
        .try_get::<i64, _>("months")
        .map_err(internal)?
        .max(0);

    let monthly_spend_usd = if months > 0 {
        spending / months as f64
    } else {
        0.0
    };
    let months_covered = if monthly_spend_usd > 0.0 {
        liquid_cash_usd / monthly_spend_usd
    } else {
        0.0
    };

    Ok(Json(EmergencyFundResponse {
        liquid_cash_usd,
        monthly_spend_usd,
        months_covered,
        months_of_data: months as i32,
    }))
}

#[derive(Deserialize)]
pub(super) struct AccountBalanceHistoryQuery {
    account_id: String,
}

#[derive(Serialize)]
pub(super) struct BalancePoint {
    month: String,
    balance: f64,
}

/// Monthly closing balance for one account, in the account's native currency.
///
/// Primary source is the persisted `balance_after` (the statement SALDO captured
/// at import) — the latest in-month balance per month. Accounts imported from
/// statements keep this path unchanged. When an account has **no** `balance_after`
/// history (Plaid-only / manual accounts), we fall back to `balance_snapshots`
/// (the daily historisation net-worth already reads), taking the latest snapshot
/// in each month. Both branches yield the same `{month, balance}` shape, so the
/// chart broadens to snapshot-backed accounts with no client change. Statement
/// accounts never hit the fallback, so nothing double-counts.
pub(super) async fn account_balance_history(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<AccountBalanceHistoryQuery>,
) -> Json<Vec<BalancePoint>> {
    let account_id = match uuid::Uuid::parse_str(&q.account_id) {
        Ok(id) => id,
        Err(_) => return Json(Vec::new()),
    };

    // Map a `(month TEXT, balance NUMERIC)` row set into the response shape.
    let to_points = |rows: Vec<sqlx::postgres::PgRow>| -> Vec<BalancePoint> {
        rows.iter()
            .map(|r| BalancePoint {
                month: r.get("month"),
                balance: r
                    .try_get::<rust_decimal::Decimal, _>("balance")
                    .ok()
                    .map(|d| d.to_string().parse().unwrap_or(0.0))
                    .unwrap_or(0.0),
            })
            .collect()
    };

    // Primary: statement `balance_after` (unchanged).
    let statement_rows = sqlx::query(
        r#"
        SELECT DISTINCT ON (TO_CHAR(t.date, 'YYYY-MM'))
               TO_CHAR(t.date, 'YYYY-MM') AS month,
               t.balance_after AS balance
        FROM transactions t
        WHERE t.account_id = $1
          AND t.user_id = $2
          AND t.balance_after IS NOT NULL
        ORDER BY TO_CHAR(t.date, 'YYYY-MM') ASC, t.date DESC, t.id DESC
        "#,
    )
    .bind(account_id)
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    if !statement_rows.is_empty() {
        return Json(to_points(statement_rows));
    }

    // Fallback: latest daily snapshot per month, native `bs.balance`.
    let snapshot_rows = sqlx::query(
        r#"
        SELECT DISTINCT ON (TO_CHAR(bs.as_of_date, 'YYYY-MM'))
               TO_CHAR(bs.as_of_date, 'YYYY-MM') AS month,
               bs.balance                        AS balance
        FROM balance_snapshots bs
        WHERE bs.account_id = $1
          AND bs.user_id    = $2
        ORDER BY TO_CHAR(bs.as_of_date, 'YYYY-MM') ASC, bs.as_of_date DESC
        "#,
    )
    .bind(account_id)
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(to_points(snapshot_rows))
}
