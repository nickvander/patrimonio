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
        .route("/", get(list_accounts))
        .route("/summary", get(accounts_summary))
}

/// List all accounts across all institutions
async fn list_accounts(State(state): State<AppState>) -> Json<Vec<AccountResponse>> {
    let rows = sqlx::query(
        r#"
        SELECT a.id, a.name, a.account_type, a.currency,
               a.current_balance, a.available_balance, a.credit_limit,
               i.name as institution_name, i.country, a.updated_at
        FROM accounts a
        JOIN institutions i ON a.institution_id = i.id
        ORDER BY i.name, a.name
        "#
    )
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let accounts = rows.iter().map(|row| {
        AccountResponse {
            id: row.get::<uuid::Uuid, _>("id").to_string(),
            name: row.get("name"),
            account_type: row.get("account_type"),
            currency: row.get("currency"),
            current_balance: row.try_get::<rust_decimal::Decimal, _>("current_balance")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)),
            available_balance: row.try_get::<rust_decimal::Decimal, _>("available_balance")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)),
            credit_limit: row.try_get::<rust_decimal::Decimal, _>("credit_limit")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)),
            institution_name: row.get("institution_name"),
            country: row.get("country"),
            updated_at: row.try_get::<chrono::DateTime<chrono::Utc>, _>("updated_at")
                .ok().map(|d| d.to_rfc3339()).unwrap_or_default(),
        }
    }).collect();

    Json(accounts)
}

/// Get a summary of all accounts (total assets, liabilities, net worth)
async fn accounts_summary(State(state): State<AppState>) -> Json<AccountsSummary> {
    let row = sqlx::query(
        r#"
        SELECT
            COALESCE(SUM(CASE WHEN account_type NOT IN ('credit') THEN current_balance ELSE 0 END), 0) as total_assets,
            COALESCE(SUM(CASE WHEN account_type = 'credit' THEN ABS(current_balance) ELSE 0 END), 0) as total_liabilities,
            COUNT(*) as account_count
        FROM accounts
        "#
    )
    .fetch_one(&state.db)
    .await;

    match row {
        Ok(row) => {
            let assets: f64 = row.try_get::<rust_decimal::Decimal, _>("total_assets")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
            let liabilities: f64 = row.try_get::<rust_decimal::Decimal, _>("total_liabilities")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
            Json(AccountsSummary {
                total_assets: assets,
                total_liabilities: liabilities,
                net_worth: assets - liabilities,
                account_count: row.try_get::<i64, _>("account_count").unwrap_or(0) as i32,
            })
        }
        Err(_) => Json(AccountsSummary {
            total_assets: 0.0,
            total_liabilities: 0.0,
            net_worth: 0.0,
            account_count: 0,
        }),
    }
}

#[derive(Serialize)]
struct AccountResponse {
    id: String,
    name: String,
    account_type: String,
    currency: String,
    current_balance: Option<f64>,
    available_balance: Option<f64>,
    credit_limit: Option<f64>,
    institution_name: String,
    country: String,
    updated_at: String,
}

#[derive(Serialize)]
struct AccountsSummary {
    total_assets: f64,
    total_liabilities: f64,
    net_worth: f64,
    account_count: i32,
}
