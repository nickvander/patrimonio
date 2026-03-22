use axum::{
    extract::State,
    routing::get,
    Json, Router,
};
use serde::Serialize;

use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_accounts))
        .route("/summary", get(accounts_summary))
}

/// List all accounts across all institutions
async fn list_accounts(State(state): State<AppState>) -> Json<Vec<AccountResponse>> {
    let accounts = sqlx::query_as!(
        AccountRow,
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

    Json(accounts.into_iter().map(AccountResponse::from).collect())
}

/// Get a summary of all accounts (total assets, liabilities, net worth)
async fn accounts_summary(State(state): State<AppState>) -> Json<AccountsSummary> {
    let summary = sqlx::query!(
        r#"
        SELECT
            COALESCE(SUM(CASE WHEN account_type NOT IN ('credit') THEN current_balance ELSE 0 END), 0) as "total_assets!",
            COALESCE(SUM(CASE WHEN account_type = 'credit' THEN ABS(current_balance) ELSE 0 END), 0) as "total_liabilities!",
            COUNT(*) as "account_count!"
        FROM accounts
        "#
    )
    .fetch_one(&state.db)
    .await;

    match summary {
        Ok(row) => {
            let assets: f64 = row.total_assets.to_string().parse().unwrap_or(0.0);
            let liabilities: f64 = row.total_liabilities.to_string().parse().unwrap_or(0.0);
            Json(AccountsSummary {
                total_assets: assets,
                total_liabilities: liabilities,
                net_worth: assets - liabilities,
                account_count: row.account_count as i32,
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

struct AccountRow {
    id: uuid::Uuid,
    name: String,
    account_type: String,
    currency: String,
    current_balance: Option<rust_decimal::Decimal>,
    available_balance: Option<rust_decimal::Decimal>,
    credit_limit: Option<rust_decimal::Decimal>,
    institution_name: String,
    country: String,
    updated_at: Option<chrono::DateTime<chrono::Utc>>,
}

impl From<AccountRow> for AccountResponse {
    fn from(row: AccountRow) -> Self {
        Self {
            id: row.id.to_string(),
            name: row.name,
            account_type: row.account_type,
            currency: row.currency,
            current_balance: row.current_balance.map(|d| d.to_string().parse().unwrap_or(0.0)),
            available_balance: row.available_balance.map(|d| d.to_string().parse().unwrap_or(0.0)),
            credit_limit: row.credit_limit.map(|d| d.to_string().parse().unwrap_or(0.0)),
            institution_name: row.institution_name,
            country: row.country,
            updated_at: row.updated_at.map(|d| d.to_rfc3339()).unwrap_or_default(),
        }
    }
}

#[derive(Serialize)]
struct AccountsSummary {
    total_assets: f64,
    total_liabilities: f64,
    net_worth: f64,
    account_count: i32,
}
