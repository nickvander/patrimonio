use axum::{
    extract::{Extension, Query, State},
    routing::get,
    Json, Router,
};
use serde::Serialize;
use sqlx::Row;

use crate::api::dashboard::{latest_usd_mxn_rate, trailing_cashflow_exclusions_sql};
use crate::api::session::AuthContext;
use crate::services::projections::{self, ProjectionRequest, ProjectionResponse};
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/calculate", get(calculate_projection))
        .route("/defaults", get(projection_defaults))
}

/// Calculate a wealth projection. All figures are real (today's) dollars.
async fn calculate_projection(
    State(_state): State<AppState>,
    Query(payload): Query<ProjectionRequest>,
) -> Json<ProjectionResponse> {
    Json(projections::calculate_projection(&payload))
}

/// Best-effort projection inputs derived from the user's tracked cash flow.
///
/// This is Patrimonio's edge over a generic calculator: we already know the
/// user's real income and spending, so we can prefill the contribution and the
/// retirement-spend instead of asking them to guess. Values are in USD (the
/// dashboard's reporting unit) and the frontend treats them as overridable
/// defaults.
#[derive(Serialize)]
struct ProjectionDefaults {
    /// Trailing average monthly savings (income − spending), USD. Floored at 0.
    monthly_contribution: f64,
    /// Annualized spending, USD — a sensible default for retirement expenses.
    annual_expenses: f64,
    /// Annualized income, USD (for context / the savings-rate display).
    annual_income: f64,
    /// Number of distinct months of data the estimate is based on.
    months_of_data: i32,
}

async fn projection_defaults(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<ProjectionDefaults> {
    // Mirror cash_flow_trends: convert every amount to USD, exclude internal
    // transfers / CC payments / lending legs / split parents so the income and
    // spending totals reflect genuine external cash flow.
    //
    // The exclusion set is the SHARED fragment
    // (dashboard::TRAILING_CASHFLOW_EXCLUSIONS_SQL) used verbatim by
    // `dashboard::emergency_fund`, so the projection's trailing-12-mo spend and
    // the emergency-fund runway can never silently disagree — both now apply
    // the cash_fx_transfers anti-join that this query previously lacked.
    //
    // FX uses the shared policy (real rate when present, flagged fallback when
    // missing/stale). The resolved rate is bound as $2 and used as the MXN→USD
    // divisor — numerically identical to the old in-SQL latest rate whenever a
    // fresh rate exists.
    let fx = latest_usd_mxn_rate(&state.db).await.rate;
    let excl = trailing_cashflow_exclusions_sql();
    let sql = format!(
        r#"
        SELECT
            COALESCE(SUM(CASE WHEN t.amount > 0 THEN
                CASE WHEN a.currency = 'MXN'
                     THEN t.amount / $2::numeric
                     ELSE t.amount END
                ELSE 0 END), 0) AS income,
            COALESCE(SUM(CASE WHEN t.amount < 0 THEN
                CASE WHEN a.currency = 'MXN'
                     THEN ABS(t.amount) / $2::numeric
                     ELSE ABS(t.amount) END
                ELSE 0 END), 0) AS spending,
            COUNT(DISTINCT TO_CHAR(t.date, 'YYYY-MM')) AS months
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        WHERE TRUE
        {excl}
        "#,
    );
    let row = sqlx::query(&sql)
        .bind(ctx.user_id)
        .bind(fx)
        .fetch_one(&state.db)
        .await
        .ok();

    let (income, spending, months) = match row {
        Some(r) => {
            let income: f64 = r
                .try_get::<rust_decimal::Decimal, _>("income")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0);
            let spending: f64 = r
                .try_get::<rust_decimal::Decimal, _>("spending")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0);
            let months: i64 = r.try_get("months").unwrap_or(0);
            (income, spending, months.max(0))
        }
        None => (0.0, 0.0, 0),
    };

    // Annualize from however many months we actually have, so a user with 4
    // months of imported history isn't told they spend a third of reality.
    let n = months.max(1) as f64;
    let annual_income = income / n * 12.0;
    let annual_expenses = spending / n * 12.0;
    let monthly_contribution = ((annual_income - annual_expenses) / 12.0).max(0.0);

    Json(ProjectionDefaults {
        monthly_contribution,
        annual_expenses,
        annual_income,
        months_of_data: months as i32,
    })
}
