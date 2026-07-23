use axum::{
    extract::{Extension, Query, State},
    routing::get,
    Json, Router,
};
use rust_decimal::prelude::ToPrimitive;
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use serde::Serialize;
use sqlx::Row;

use crate::api::dashboard::trailing_cashflow_exclusions_sql;
use crate::api::session::{internal, ApiError, AuthContext};
use crate::services::projections::{self, ProjectionRequest, ProjectionResponse};
use crate::services::tax::USD_MXN_ROW_RATE_SQL;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/calculate", get(calculate_projection))
        .route("/defaults", get(projection_defaults))
}

/// Calculate a wealth projection. All figures are real (today's) dollars.
async fn calculate_projection(
    State(state): State<AppState>,
    Query(mut payload): Query<ProjectionRequest>,
) -> Result<Json<ProjectionResponse>, ApiError> {
    // "Retire in Mexico" scenario: when the client didn't supply a usable
    // USD→MXN rate, fill it from the latest stored rate so the scenario math
    // matches every other FX surface. `exchange_rates` is global reference
    // data (no user rows), so this is the one query legitimately not scoped
    // by user_id. The engine itself still hard-falls-back to 20.0 (the
    // USD_MXN_ROW_RATE_SQL constant) if the table is empty.
    if payload.mx_scenario == Some(true)
        && !payload
            .usd_mxn_rate
            .is_some_and(|r| r.is_finite() && r > 0.0)
    {
        payload.usd_mxn_rate = sqlx::query_scalar::<_, f64>(
            "SELECT rate::float8 FROM exchange_rates
              WHERE base_currency = 'USD' AND target_currency = 'MXN' AND rate > 0
              ORDER BY recorded_at DESC LIMIT 1",
        )
        .fetch_optional(&state.db)
        .await
        .map_err(internal)?;
    }
    Ok(Json(projections::calculate_projection(&payload)))
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
) -> Result<Json<ProjectionDefaults>, ApiError> {
    // Mirror cash_flow_trends: convert every amount to USD, exclude internal
    // transfers / CC payments / lending legs / split parents so the income and
    // spending totals reflect genuine external cash flow.
    //
    // The exclusion set is the SHARED fragment
    // (dashboard::trailing_cashflow_exclusions_sql) used verbatim by
    // `dashboard::emergency_fund`, so the projection's trailing-12-mo spend and
    // the emergency-fund runway can never silently disagree — both apply the
    // cash_fx_transfers anti-join that this query previously lacked.
    //
    // FX is PER ROW: each MXN transaction is divided by the USD→MXN rate in
    // effect on its own date (the shared `USD_MXN_ROW_RATE_SQL` rule from
    // services::tax — on-or-before-date rate, else latest, else 20.0). This
    // query previously converted all 12 months at the single LATEST rate;
    // USD/MXN moves several percent over a year, so latest-rate conversion
    // systematically skews the annualized income/spend (and therefore the
    // prefilled contribution) whenever the peso has trended.
    let excl = trailing_cashflow_exclusions_sql();
    let sql = format!(
        r#"
        SELECT
            COALESCE(SUM(CASE WHEN t.amount > 0 THEN
                CASE WHEN a.currency = 'MXN'
                     THEN t.amount / fx.rate
                     ELSE t.amount END
                ELSE 0 END), 0) AS income,
            COALESCE(SUM(CASE WHEN t.amount < 0 THEN
                CASE WHEN a.currency = 'MXN'
                     THEN ABS(t.amount) / fx.rate
                     ELSE ABS(t.amount) END
                ELSE 0 END), 0) AS spending,
            COUNT(DISTINCT TO_CHAR(t.date, 'YYYY-MM')) AS months
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        CROSS JOIN LATERAL (SELECT {USD_MXN_ROW_RATE_SQL} AS rate) fx
        WHERE TRUE
        {excl}
        "#,
    );
    // A DB failure here must surface as a logged 500, not as fabricated
    // zeros: the old `.ok()` path made "query blew up" indistinguishable
    // from "user has no transactions", silently shipping a $0 prefill.
    let row = sqlx::query(&sql)
        .bind(ctx.user_id)
        .fetch_one(&state.db)
        .await
        .map_err(internal)?;

    let income: Decimal = row.try_get("income").map_err(internal)?;
    let spending: Decimal = row.try_get("spending").map_err(internal)?;
    let months: i64 = row.try_get::<i64, _>("months").map_err(internal)?.max(0);

    // Annualize from however many months we actually have, so a user with 4
    // months of imported history isn't told they spend a third of reality.
    // Math stays in Decimal and is presented at 2dp — raw f64 division used
    // to ship noise like 1828.8000000000002 to the client.
    let n = Decimal::from(months.max(1));
    let annual_income_d = income / n * dec!(12);
    let annual_expenses_d = spending / n * dec!(12);
    let monthly_contribution_d = ((annual_income_d - annual_expenses_d) / dec!(12))
        .max(Decimal::ZERO)
        .round_dp(2);

    Ok(Json(ProjectionDefaults {
        monthly_contribution: monthly_contribution_d.to_f64().unwrap_or(0.0),
        annual_expenses: annual_expenses_d.round_dp(2).to_f64().unwrap_or(0.0),
        annual_income: annual_income_d.round_dp(2).to_f64().unwrap_or(0.0),
        months_of_data: months as i32,
    }))
}
