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
        .route("/net-worth-history", get(net_worth_history))
        .route("/holdings", get(holdings))
        .route("/credit-utilization", get(credit_utilization))
        .route("/sync-status", get(sync_status))
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

/// Historical net worth data for charting (aggregated from balance_snapshots)
async fn net_worth_history(State(state): State<AppState>) -> Json<Vec<NetWorthPoint>> {
    let rows = sqlx::query(
        r#"
        SELECT bs.as_of_date,
               COALESCE(SUM(CASE WHEN a.account_type NOT IN ('credit') THEN bs.balance ELSE 0 END), 0) as total_assets,
               COALESCE(SUM(CASE WHEN a.account_type = 'credit' THEN ABS(bs.balance) ELSE 0 END), 0) as total_liabilities
        FROM balance_snapshots bs
        JOIN accounts a ON bs.account_id = a.id
        GROUP BY bs.as_of_date
        ORDER BY bs.as_of_date ASC
        "#
    )
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| {
                let assets: f64 = r.try_get::<rust_decimal::Decimal, _>("total_assets")
                    .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
                let liabilities: f64 = r.try_get::<rust_decimal::Decimal, _>("total_liabilities")
                    .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
                NetWorthPoint {
                    date: r.try_get::<chrono::NaiveDate, _>("as_of_date")
                        .ok().map(|d| d.to_string()).unwrap_or_default(),
                    total_assets: assets,
                    total_liabilities: liabilities,
                    net_worth: assets - liabilities,
                }
            })
            .collect(),
    )
}

/// All investment holdings across all accounts
async fn holdings(State(state): State<AppState>) -> Json<HoldingsResponse> {
    let rows = sqlx::query(
        r#"
        SELECT h.symbol, h.name, h.quantity, h.price, h.value,
               h.cost_basis, h.currency, h.holding_type,
               a.name as account_name, i.name as institution_name
        FROM holdings h
        JOIN accounts a ON h.account_id = a.id
        JOIN institutions i ON a.institution_id = i.id
        ORDER BY h.value DESC NULLS LAST
        "#
    )
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let holdings_list: Vec<HoldingDetail> = rows.iter()
        .map(|r| {
            let value: f64 = r.try_get::<rust_decimal::Decimal, _>("value")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
            let cost_basis: f64 = r.try_get::<rust_decimal::Decimal, _>("cost_basis")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
            HoldingDetail {
                symbol: r.get("symbol"),
                name: r.get("name"),
                quantity: r.try_get::<rust_decimal::Decimal, _>("quantity")
                    .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0),
                price: r.try_get::<rust_decimal::Decimal, _>("price")
                    .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0),
                value,
                cost_basis,
                gain_loss: value - cost_basis,
                gain_loss_pct: if cost_basis > 0.0 { ((value - cost_basis) / cost_basis) * 100.0 } else { 0.0 },
                currency: r.get("currency"),
                holding_type: r.try_get::<String, _>("holding_type").unwrap_or_default(),
                account_name: r.get("account_name"),
                institution_name: r.get("institution_name"),
            }
        })
        .collect();

    let total_value: f64 = holdings_list.iter().map(|h| h.value).sum();
    let total_cost: f64 = holdings_list.iter().map(|h| h.cost_basis).sum();

    Json(HoldingsResponse {
        total_value,
        total_cost_basis: total_cost,
        total_gain_loss: total_value - total_cost,
        total_gain_loss_pct: if total_cost > 0.0 { ((total_value - total_cost) / total_cost) * 100.0 } else { 0.0 },
        holdings: holdings_list,
    })
}

/// Credit card utilization for all credit accounts
async fn credit_utilization(State(state): State<AppState>) -> Json<Vec<CreditUtilization>> {
    let rows = sqlx::query(
        r#"
        SELECT a.name, a.current_balance, a.credit_limit,
               i.name as institution_name
        FROM accounts a
        JOIN institutions i ON a.institution_id = i.id
        WHERE a.account_type = 'credit'
        ORDER BY i.name, a.name
        "#
    )
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| {
                let balance: f64 = r.try_get::<rust_decimal::Decimal, _>("current_balance")
                    .ok().map(|d| d.to_string().parse::<f64>().unwrap_or(0.0)).unwrap_or(0.0)
                    .abs();
                let limit: f64 = r.try_get::<rust_decimal::Decimal, _>("credit_limit")
                    .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
                CreditUtilization {
                    name: r.get("name"),
                    institution_name: r.get("institution_name"),
                    balance,
                    credit_limit: limit,
                    utilization_pct: if limit > 0.0 { (balance / limit) * 100.0 } else { 0.0 },
                }
            })
            .collect(),
    )
}

/// Sync status of all institutions
async fn sync_status(State(state): State<AppState>) -> Json<Vec<SyncStatusEntry>> {
    let rows = sqlx::query(
        r#"
        SELECT name, integration_type, sync_status, last_synced_at, country
        FROM institutions
        ORDER BY name
        "#
    )
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| SyncStatusEntry {
                name: r.get("name"),
                integration_type: r.get("integration_type"),
                country: r.get("country"),
                sync_status: r.try_get::<String, _>("sync_status")
                    .unwrap_or_else(|_| "unknown".to_string()),
                last_synced_at: r.try_get::<chrono::DateTime<chrono::Utc>, _>("last_synced_at")
                    .ok().map(|d| d.to_rfc3339()),
            })
            .collect(),
    )
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

#[derive(Serialize)]
struct NetWorthPoint {
    date: String,
    total_assets: f64,
    total_liabilities: f64,
    net_worth: f64,
}

#[derive(Serialize)]
struct HoldingsResponse {
    total_value: f64,
    total_cost_basis: f64,
    total_gain_loss: f64,
    total_gain_loss_pct: f64,
    holdings: Vec<HoldingDetail>,
}

#[derive(Serialize)]
struct HoldingDetail {
    symbol: String,
    name: String,
    quantity: f64,
    price: f64,
    value: f64,
    cost_basis: f64,
    gain_loss: f64,
    gain_loss_pct: f64,
    currency: String,
    holding_type: String,
    account_name: String,
    institution_name: String,
}

#[derive(Serialize)]
struct CreditUtilization {
    name: String,
    institution_name: String,
    balance: f64,
    credit_limit: f64,
    utilization_pct: f64,
}

#[derive(Serialize)]
struct SyncStatusEntry {
    name: String,
    integration_type: String,
    country: String,
    sync_status: String,
    last_synced_at: Option<String>,
}
