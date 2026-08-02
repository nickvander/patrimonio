use axum::{
    extract::{Extension, Query, State},
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use std::collections::HashMap;

use crate::api::error::{internal, ApiError};
use crate::api::middleware::AuthContext;
use crate::services::fx::USD_MXN_ROW_RATE_SQL;
use crate::AppState;

use super::*;

#[derive(Deserialize)]
pub(super) struct TrendsQuery {
    /// Trailing window in months (default 12). Clamped to 1..=24 so the
    /// Cash Flow tab's period selector can ask for a tighter window
    /// (This/Last month, 3 months, YTD) without an unbounded scan. Absent
    /// keeps the historical 12-month default so existing callers are
    /// unchanged.
    months: Option<i64>,
}

/// Monthly income and spending trends for this user.
pub(super) async fn cash_flow_trends(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<TrendsQuery>,
) -> Result<Json<Vec<CashFlowPoint>>, ApiError> {
    let months = q.months.unwrap_or(12).clamp(1, 24);
    // Income/spending count genuine household cash flow only; securities
    // trades (Investment) and internal Transfers are peeled into the
    // `invested` / `transferred` buckets (still keyed on the effective
    // category, so a user re-tag flows through). Every other non-cash-flow
    // row — CC-payment leg / CC inflow, tax refund, loan leg, FX pair, split
    // parent — is dropped by the shared `CASHFLOW_ROW_ANTI_JOINS_SQL` WHERE
    // fragment, which those buckets don't need.
    //
    // FX is PER ROW: each MXN transaction is divided by the USD→MXN rate in
    // effect on its own date (the shared `USD_MXN_ROW_RATE_SQL` rule from
    // services::fx — on-or-before-date rate, else latest, else 20.0). This
    // query previously converted up to 24 months of history at the single
    // LATEST rate; USD/MXN moves several percent over a year, so latest-rate
    // conversion systematically skews every historical month's income/spend
    // bars whenever the peso has trended.
    let sql = format!(
        r#"
        SELECT TO_CHAR(t.date, 'YYYY-MM') as month,
               SUM(CASE WHEN t.amount > 0
                        AND {EFFECTIVE_CATEGORY_SQL} NOT IN {NON_CASHFLOW_CATEGORIES_SQL} THEN
                       CASE WHEN a.currency = 'MXN'
                            THEN t.amount / fx.rate
                            ELSE t.amount END
                   ELSE 0 END) as income,
               SUM(CASE WHEN t.amount < 0
                        AND {EFFECTIVE_CATEGORY_SQL} NOT IN {NON_CASHFLOW_CATEGORIES_SQL} THEN
                       CASE WHEN a.currency = 'MXN'
                            THEN ABS(t.amount) / fx.rate
                            ELSE ABS(t.amount) END
                   ELSE 0 END) as spending,
               -- Net cash moved into investments (buys +, sells -): -amount, USD.
               SUM(CASE WHEN {EFFECTIVE_CATEGORY_SQL} = 'INVESTMENT' THEN
                       CASE WHEN a.currency = 'MXN'
                            THEN -t.amount / fx.rate
                            ELSE -t.amount END
                   ELSE 0 END) as invested,
               -- Net internal transfer flow (in +, out -), USD.
               SUM(CASE WHEN {EFFECTIVE_CATEGORY_SQL} IN ('TRANSFER_IN', 'TRANSFER_OUT', 'TRANSFER') THEN
                       CASE WHEN a.currency = 'MXN'
                            THEN t.amount / fx.rate
                            ELSE t.amount END
                   ELSE 0 END) as transferred
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        CROSS JOIN LATERAL (SELECT {USD_MXN_ROW_RATE_SQL} AS rate) fx
        -- Calendar-month-aligned trailing window: months=1 yields the
        -- current month only, months=2 adds the prior month, etc. (mirrors
        -- spending_by_category). The Cash Flow tab's period selector binds
        -- this so "Last month" / "Last 3 months" / "YTD" each pull just the
        -- months they need while the default (12) is unchanged.
        WHERE t.date >= (DATE_TRUNC('month', CURRENT_DATE) - make_interval(months => ($2::int - 1)))
          AND t.user_id = $1{CASHFLOW_ROW_ANTI_JOINS_SQL}
        GROUP BY month
        ORDER BY month ASC
        "#
    );
    // A DB failure must surface as a logged 500, not as fabricated emptiness:
    // the old `.unwrap_or_default()` made "query blew up" indistinguishable
    // from "user has no transactions", silently rendering an empty chart.
    let rows = sqlx::query(&sql)
        .bind(ctx.user_id)
        .bind(months as i32)
        .fetch_all(&state.db)
        .await
        .map_err(internal)?;

    // Decode failures are bugs, not empty states: every SUM column is built
    // from CASE arms with an ELSE 0, over a non-empty GROUP BY group, so a
    // NULL/type mismatch here means the query changed under us — 500 loudly
    // instead of charting a silent 0.
    let mut points = Vec::with_capacity(rows.len());
    for r in &rows {
        let dec = |col: &str| -> Result<f64, ApiError> {
            let d = r
                .try_get::<rust_decimal::Decimal, _>(col)
                .map_err(internal)?;
            Ok(d.to_string().parse().unwrap_or(0.0))
        };
        points.push(CashFlowPoint {
            month: r.try_get("month").map_err(internal)?,
            income: dec("income")?,
            spending: dec("spending")?,
            invested: dec("invested")?,
            transferred: dec("transferred")?,
        });
    }
    Ok(Json(points))
}

#[derive(Deserialize)]
pub(super) struct SpendingByCategoryQuery {
    /// Trailing window in months (default 6). Clamped to 1..=24.
    months: Option<i64>,
    /// Max categories returned; the rest fold into "OTHER". Default 8.
    top: Option<i64>,
}

#[derive(Serialize)]
struct CategoryMonthAmount {
    month: String,
    amount: f64,
}

#[derive(Serialize)]
struct CategorySpending {
    /// PFC primary code or the user's manual override (frontend prettifies).
    category: String,
    total: f64,
    monthly: Vec<CategoryMonthAmount>,
}

#[derive(Serialize)]
pub(super) struct SpendingByCategoryResponse {
    /// Chronological YYYY-MM buckets in the window (only months with data).
    months: Vec<String>,
    categories: Vec<CategorySpending>,
    /// True when the latest USD/MXN rate is missing or stale (>7d), so the
    /// MXN amounts here were normalized at an approximate fallback rate.
    fx_stale: bool,
}

/// Per-category spending over the trailing N months — the "where's my money
/// going" view. Same cash-flow hygiene as `cash_flow_trends` (USD-normalized,
/// excludes internal transfers / CC payments / lending legs / split parents),
/// but grouped by category so each month can be broken down. The top-`top`
/// categories by total are returned verbatim; everything else folds into a
/// single "OTHER" bucket so the stacked chart stays legible.
pub(super) async fn spending_by_category(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<SpendingByCategoryQuery>,
) -> Result<Json<SpendingByCategoryResponse>, ApiError> {
    let months = q.months.unwrap_or(6).clamp(1, 24);
    let top = q.top.unwrap_or(8).clamp(1, 30) as usize;

    // Same cash-flow hygiene as `cash_flow_trends`, via the shared fragments:
    // drop internal transfers / investment moves (by effective category) and
    // the CC-payment / loan-leg / FX-pair / split-parent rows. The positive-
    // only bits of the anti-join fragment (CC inflow, tax refund) are no-ops
    // here since this sums outflows only.
    //
    // FX is PER ROW (shared `USD_MXN_ROW_RATE_SQL`: on-or-before-date rate,
    // else latest, else 20.0) — up to 24 months of MXN outflows used to be
    // converted at the single latest rate, skewing every historical month's
    // category totals whenever the peso has trended.
    let sql = format!(
        r#"
        SELECT TO_CHAR(t.date, 'YYYY-MM') AS month,
               COALESCE(NULLIF(t.user_category, ''), t.category, 'UNCATEGORIZED') AS category,
               SUM(CASE WHEN a.currency = 'MXN'
                        THEN ABS(t.amount) / fx.rate
                        ELSE ABS(t.amount) END) AS amount
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        CROSS JOIN LATERAL (SELECT {USD_MXN_ROW_RATE_SQL} AS rate) fx
        WHERE t.amount < 0
          AND t.date >= (DATE_TRUNC('month', CURRENT_DATE) - make_interval(months => ($2::int - 1)))
          AND t.user_id = $1
          AND {EFFECTIVE_CATEGORY_SQL} NOT IN {NON_CASHFLOW_CATEGORIES_SQL}{CASHFLOW_ROW_ANTI_JOINS_SQL}
        GROUP BY TO_CHAR(t.date, 'YYYY-MM'),
                 COALESCE(NULLIF(t.user_category, ''), t.category, 'UNCATEGORIZED')
        ORDER BY month ASC
        "#,
    );
    // A DB failure must surface as a logged 500, not as fabricated emptiness:
    // the old `.unwrap_or_default()` made "query blew up" indistinguishable
    // from "no spending in the window", silently rendering an empty chart.
    let rows = sqlx::query(&sql)
        .bind(ctx.user_id)
        .bind(months as i32)
        .fetch_all(&state.db)
        .await
        .map_err(internal)?;

    // (category -> (month -> amount)) plus per-category totals and the set of
    // months actually present, so the response only carries populated buckets.
    let mut by_cat: HashMap<String, HashMap<String, f64>> = HashMap::new();
    let mut totals: HashMap<String, f64> = HashMap::new();
    let mut month_set: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();

    for r in &rows {
        let month: String = r.try_get("month").map_err(internal)?;
        let category: String = r.try_get("category").map_err(internal)?;
        // SUM over a non-empty group of ABS(...) values is never NULL, so a
        // decode failure is a bug — 500 loudly instead of a silent 0 bar.
        let amount: f64 = r
            .try_get::<rust_decimal::Decimal, _>("amount")
            .map_err(internal)?
            .to_string()
            .parse()
            .unwrap_or(0.0);
        month_set.insert(month.clone());
        *totals.entry(category.clone()).or_insert(0.0) += amount;
        *by_cat
            .entry(category)
            .or_default()
            .entry(month)
            .or_insert(0.0) += amount;
    }

    let months_vec: Vec<String> = month_set.into_iter().collect();

    // Rank categories by total; keep the top N, fold the rest into OTHER.
    let mut ranked: Vec<(String, f64)> = totals.iter().map(|(k, v)| (k.clone(), *v)).collect();
    ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    let keep: std::collections::HashSet<String> =
        ranked.iter().take(top).map(|(k, _)| k.clone()).collect();

    // Accumulate OTHER across both totals and per-month so the stacked bars
    // still sum to real monthly spending.
    let mut other_total = 0.0;
    let mut other_monthly: HashMap<String, f64> = HashMap::new();
    let mut categories: Vec<CategorySpending> = Vec::new();

    for (cat, per_month) in &by_cat {
        if keep.contains(cat) {
            let monthly = months_vec
                .iter()
                .map(|m| CategoryMonthAmount {
                    month: m.clone(),
                    amount: *per_month.get(m).unwrap_or(&0.0),
                })
                .collect();
            categories.push(CategorySpending {
                category: cat.clone(),
                total: *totals.get(cat).unwrap_or(&0.0),
                monthly,
            });
        } else {
            other_total += *totals.get(cat).unwrap_or(&0.0);
            for (m, v) in per_month {
                *other_monthly.entry(m.clone()).or_insert(0.0) += *v;
            }
        }
    }

    categories.sort_by(|a, b| {
        b.total
            .partial_cmp(&a.total)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    if other_total > 0.0 {
        let monthly = months_vec
            .iter()
            .map(|m| CategoryMonthAmount {
                month: m.clone(),
                amount: *other_monthly.get(m).unwrap_or(&0.0),
            })
            .collect();
        categories.push(CategorySpending {
            category: "OTHER".to_string(),
            total: other_total,
            monthly,
        });
    }

    Ok(Json(SpendingByCategoryResponse {
        months: months_vec,
        categories,
        fx_stale: latest_usd_mxn_rate(&state.db).await.stale,
    }))
}

#[derive(Deserialize)]
pub(super) struct SpendingInsightsQuery {
    /// Number of trailing *complete* months to average over (the baseline).
    /// The comparison month is the most recent complete calendar month; the
    /// baseline is the `lookback` complete months immediately before it.
    /// Default 3, clamped 1..=12.
    lookback: Option<i64>,
}

#[derive(Serialize)]
struct CategoryInsight {
    // Raw category fields so the frontend can prettify identically to the
    // budgets card / spending screen (prettyCategory prefers user_category,
    // then category_detailed, then category). Returning the codes rather than
    // a pre-formatted label keeps the (locale-aware) labelling in one place.
    #[serde(skip_serializing_if = "Option::is_none")]
    user_category: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    category_detailed: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    category: Option<String>,
    /// Spend in the most recent complete calendar month, USD.
    recent: f64,
    /// Average monthly spend over the `lookback` months *before* `recent`, USD.
    /// 0 when there's no baseline history for the category.
    previous_avg: f64,
    /// Average monthly spend over the recent + baseline window
    /// (`lookback` + 1 complete months), USD. Used to seed budget suggestions.
    trailing_avg: f64,
}

#[derive(Serialize)]
pub(super) struct SpendingInsightsResponse {
    /// YYYY-MM of the most recent complete calendar month (the comparison month).
    recent_month: String,
    lookback: i64,
    categories: Vec<CategoryInsight>,
    /// True when the latest USD/MXN rate is missing or stale (>7d) — MXN spend
    /// was normalized at an approximate fallback rate.
    fx_stale: bool,
}

/// Per-category month-over-month-vs-trailing-average spend deltas. Powers the
/// "groceries up 40% vs your 3-month average" notifications and the budget
/// auto-suggestion. Same cash-flow hygiene as `cash_flow_trends` /
/// `spending_by_category` (USD-normalized, excludes internal transfers, CC
/// payments, lending legs, split parents).
///
/// The comparison month is the most recent **complete** calendar month — the
/// current (partial) month is deliberately excluded so a 6th-of-the-month read
/// doesn't report every category as "down". Each category is grouped on the
/// raw (user_category, category_detailed, category) triple; the frontend
/// collapses those to display labels so the keys line up with the budgets card.
pub(super) async fn spending_insights(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<SpendingInsightsQuery>,
) -> Result<Json<SpendingInsightsResponse>, ApiError> {
    let lookback = q.lookback.unwrap_or(3).clamp(1, 12);
    // Window = recent + baseline = lookback + 1 complete months.
    let window = lookback + 1;

    // DB-anchored month labels for the window, newest first (n=1 → recent).
    // Anchoring to the DB's CURRENT_DATE (rather than chrono::Utc) keeps the
    // recent/baseline split consistent with the WHERE-clause below across any
    // server/UTC timezone skew at a month boundary.
    let month_rows = sqlx::query(
        r#"
        SELECT gs.n AS n,
               TO_CHAR(DATE_TRUNC('month', CURRENT_DATE) - make_interval(months => gs.n), 'YYYY-MM') AS m
        FROM generate_series(1, $1::int) AS gs(n)
        ORDER BY gs.n
        "#,
    )
    .bind(window as i32)
    .fetch_all(&state.db)
    .await
    // A failure here used to `.unwrap_or_default()` into an empty label set,
    // making every insight silently disappear — surface it as a logged 500.
    .map_err(internal)?;

    let window_months: Vec<String> = month_rows
        .iter()
        .map(|r| r.try_get::<String, _>("m").map_err(internal))
        .collect::<Result<_, _>>()?;
    // generate_series(1, window>=2) always yields rows, so `first()` is
    // always Some — the fallback only guards an impossible empty series.
    let recent_month = window_months.first().cloned().unwrap_or_default();

    // Same cash-flow exclusions as the other spend views, via the shared
    // fragments (the positive-only anti-joins are no-ops on this outflow sum).
    //
    // FX is PER ROW (shared `USD_MXN_ROW_RATE_SQL`: on-or-before-date rate,
    // else latest, else 20.0) — the recent-vs-baseline comparison used to
    // convert the whole lookback window at the single latest rate, so a peso
    // move could masquerade as a spending change in every MXN category.
    let sql = format!(
        r#"
        SELECT TO_CHAR(t.date, 'YYYY-MM') AS month,
               t.user_category AS user_category,
               t.category_detailed AS category_detailed,
               t.category AS category,
               SUM(CASE WHEN a.currency = 'MXN'
                        THEN ABS(t.amount) / fx.rate
                        ELSE ABS(t.amount) END) AS amount
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        CROSS JOIN LATERAL (SELECT {USD_MXN_ROW_RATE_SQL} AS rate) fx
        WHERE t.amount < 0
          AND t.date >= DATE_TRUNC('month', CURRENT_DATE) - make_interval(months => $2::int)
          AND t.date <  DATE_TRUNC('month', CURRENT_DATE)
          AND t.user_id = $1
          AND {EFFECTIVE_CATEGORY_SQL} NOT IN {NON_CASHFLOW_CATEGORIES_SQL}{CASHFLOW_ROW_ANTI_JOINS_SQL}
        GROUP BY month, t.user_category, t.category_detailed, t.category
        "#,
    );
    // A DB failure must surface as a logged 500, not as fabricated emptiness:
    // the old `.unwrap_or_default()` made "query blew up" indistinguishable
    // from "no spending in the window" (no insights, no budget suggestions).
    let rows = sqlx::query(&sql)
        .bind(ctx.user_id)
        .bind(window as i32)
        .fetch_all(&state.db)
        .await
        .map_err(internal)?;

    // Accumulate per (user_category, category_detailed, category) → (month → amount).
    type CatKey = (Option<String>, Option<String>, Option<String>);
    let mut by_cat: HashMap<CatKey, HashMap<String, f64>> = HashMap::new();
    for r in &rows {
        let month: String = r.try_get("month").map_err(internal)?;
        // The three category columns are legitimately NULLable — read them as
        // Option (NULL is data, not an error) but still 500 on a genuine
        // decode failure. Treat an empty-string user_category as absent so it
        // folds in with the NULL group (both prettify to the detailed/primary
        // label).
        let user_category: Option<String> = r
            .try_get::<Option<String>, _>("user_category")
            .map_err(internal)?
            .filter(|s| !s.trim().is_empty());
        let category_detailed: Option<String> = r
            .try_get::<Option<String>, _>("category_detailed")
            .map_err(internal)?
            .filter(|s| !s.trim().is_empty());
        let category: Option<String> = r
            .try_get::<Option<String>, _>("category")
            .map_err(internal)?
            .filter(|s| !s.trim().is_empty());
        // SUM over a non-empty group of ABS(...) values is never NULL, so a
        // decode failure is a bug — 500 loudly instead of a silent $0 insight.
        let amount: f64 = r
            .try_get::<rust_decimal::Decimal, _>("amount")
            .map_err(internal)?
            .to_string()
            .parse()
            .unwrap_or(0.0);
        *by_cat
            .entry((user_category, category_detailed, category))
            .or_default()
            .entry(month)
            .or_insert(0.0) += amount;
    }

    let baseline_months = &window_months[1.min(window_months.len())..];
    let lookback_f = lookback as f64;
    let window_f = window as f64;

    let mut categories: Vec<CategoryInsight> = by_cat
        .into_iter()
        .map(|((uc, cd, c), per_month)| {
            let recent = *per_month.get(&recent_month).unwrap_or(&0.0);
            let baseline_sum: f64 = baseline_months
                .iter()
                .map(|m| *per_month.get(m).unwrap_or(&0.0))
                .sum();
            CategoryInsight {
                user_category: uc,
                category_detailed: cd,
                category: c,
                recent,
                previous_avg: if lookback_f > 0.0 {
                    baseline_sum / lookback_f
                } else {
                    0.0
                },
                trailing_avg: (recent + baseline_sum) / window_f,
            }
        })
        .collect();

    // Largest trailing spend first — the most material categories lead, which
    // is what both the notification ranking and the budget seed want.
    categories.sort_by(|a, b| {
        b.trailing_avg
            .partial_cmp(&a.trailing_avg)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    Ok(Json(SpendingInsightsResponse {
        recent_month,
        lookback,
        categories,
        fx_stale: latest_usd_mxn_rate(&state.db).await.stale,
    }))
}

#[derive(Serialize)]
pub(super) struct CashFlowPoint {
    month: String,
    income: f64,
    spending: f64,
    /// Net cash moved into investments this period (buys positive, sells
    /// negative), USD. Peeled out of income/spending so the headline is
    /// clean, but surfaced as context so the money isn't invisible.
    invested: f64,
    /// Net internal transfer flow (money in positive, out negative), USD.
    /// Surfaced as context for the same reason.
    transferred: f64,
}
