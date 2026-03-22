use axum::{
    extract::State,
    routing::get,
    Json, Router,
};
use serde::Serialize;
use sqlx::Row;

use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/overview", get(dashboard_overview))
}

/// Dashboard overview: net worth, account breakdown, recent changes
async fn dashboard_overview(State(state): State<AppState>) -> Json<DashboardOverview> {
    // Net worth by currency
    let currency_rows = sqlx::query(
        r#"
        SELECT currency,
               COALESCE(SUM(CASE WHEN account_type NOT IN ('credit') THEN current_balance ELSE 0 END), 0) as assets,
               COALESCE(SUM(CASE WHEN account_type = 'credit' THEN ABS(current_balance) ELSE 0 END), 0) as liabilities
        FROM accounts
        GROUP BY currency
        "#
    )
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let currency_breakdown: Vec<CurrencyBreakdown> = currency_rows.iter()
        .map(|r| {
            let assets: f64 = r.try_get::<rust_decimal::Decimal, _>("assets")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
            let liabilities: f64 = r.try_get::<rust_decimal::Decimal, _>("liabilities")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
            CurrencyBreakdown {
                currency: r.get("currency"),
                assets,
                liabilities,
                net: assets - liabilities,
            }
        })
        .collect();

    // Account type breakdown
    let type_rows = sqlx::query(
        r#"
        SELECT account_type,
               COUNT(*) as count,
               COALESCE(SUM(current_balance), 0) as total
        FROM accounts
        GROUP BY account_type
        "#
    )
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let type_breakdown: Vec<TypeBreakdown> = type_rows.iter()
        .map(|r| TypeBreakdown {
            account_type: r.get("account_type"),
            count: r.try_get::<i64, _>("count").unwrap_or(0) as i32,
            total: r.try_get::<rust_decimal::Decimal, _>("total")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0),
        })
        .collect();

    // Institution breakdown
    let institution_rows = sqlx::query(
        r#"
        SELECT i.name as institution_name, i.country,
               COUNT(*) as account_count,
               COALESCE(SUM(a.current_balance), 0) as total
        FROM accounts a
        JOIN institutions i ON a.institution_id = i.id
        GROUP BY i.name, i.country
        ORDER BY total DESC
        "#
    )
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let institution_breakdown: Vec<InstitutionBreakdown> = institution_rows.iter()
        .map(|r| InstitutionBreakdown {
            name: r.get("institution_name"),
            country: r.get("country"),
            account_count: r.try_get::<i64, _>("account_count").unwrap_or(0) as i32,
            total: r.try_get::<rust_decimal::Decimal, _>("total")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0),
        })
        .collect();

    let total_net: f64 = currency_breakdown.iter().map(|c| c.net).sum();

    Json(DashboardOverview {
        net_worth: total_net,
        currency_breakdown,
        type_breakdown,
        institution_breakdown,
    })
}

#[derive(Serialize)]
struct DashboardOverview {
    net_worth: f64,
    currency_breakdown: Vec<CurrencyBreakdown>,
    type_breakdown: Vec<TypeBreakdown>,
    institution_breakdown: Vec<InstitutionBreakdown>,
}

#[derive(Serialize)]
struct CurrencyBreakdown {
    currency: String,
    assets: f64,
    liabilities: f64,
    net: f64,
}

#[derive(Serialize)]
struct TypeBreakdown {
    account_type: String,
    count: i32,
    total: f64,
}

#[derive(Serialize)]
struct InstitutionBreakdown {
    name: String,
    country: String,
    account_count: i32,
    total: f64,
}
