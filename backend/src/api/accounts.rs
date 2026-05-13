use axum::{
    extract::{Path, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{get, patch, delete},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use tracing::{error, info};

use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_accounts).post(create_account))
        .route("/summary", get(accounts_summary))
        .route("/{id}", delete(delete_account))
        .route("/{id}/balance", patch(update_account_balance))
        .route("/{id}/transactions", get(get_account_transactions))
        .route("/transactions/{tx_id}", patch(update_transaction).delete(delete_transaction))
}

#[derive(Deserialize)]
struct UpdateBalanceRequest {
    current_balance: rust_decimal::Decimal,
}

async fn update_account_balance(
    State(state): State<AppState>,
    Path(id): Path<uuid::Uuid>,
    Json(payload): Json<UpdateBalanceRequest>,
) -> impl IntoResponse {
    info!("Updating balance for account {}: {}", id, payload.current_balance);

    // 1. Update the account's current balance
    let update_acc = sqlx::query(
        "UPDATE accounts SET current_balance = $1, updated_at = NOW() WHERE id = $2"
    )
    .bind(payload.current_balance)
    .bind(id)
    .execute(&state.db)
    .await;

    if let Err(e) = update_acc {
        error!("Failed to update account balance: {}", e);
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }

    // 2. Fetch the account's currency to ensure the snapshot is accurate
    let account = sqlx::query("SELECT currency FROM accounts WHERE id = $1")
        .bind(id)
        .fetch_one(&state.db)
        .await;

    if let Ok(row) = account {
        let currency: String = row.get("currency");
        
        // 3. Upsert balance snapshot for today
        // We calculate balance_usd if currency is MXN by fetching latest rate
        let mut balance_usd = payload.current_balance;
        if currency == "MXN" {
            let rate_row = sqlx::query(
                "SELECT rate FROM exchange_rates WHERE base_currency = 'USD' AND target_currency = 'MXN' ORDER BY recorded_at DESC LIMIT 1"
            )
            .fetch_one(&state.db)
            .await;
            
            if let Ok(r) = rate_row {
                let rate: rust_decimal::Decimal = r.get("rate");
                if !rate.is_zero() {
                    balance_usd = payload.current_balance / rate;
                }
            }
        } else if currency != "USD" {
            // Default to 1:1 if not USD/MXN for now
            balance_usd = payload.current_balance;
        }

        let _ = sqlx::query(
            r#"
            INSERT INTO balance_snapshots (account_id, balance, as_of_date, currency, balance_usd)
            VALUES ($1, $2, CURRENT_DATE, $3, $4)
            ON CONFLICT (account_id, as_of_date) 
            DO UPDATE SET balance = EXCLUDED.balance, balance_usd = EXCLUDED.balance_usd, created_at = NOW()
            "#
        )
        .bind(id)
        .bind(payload.current_balance)
        .bind(currency)
        .bind(balance_usd)
        .execute(&state.db)
        .await;
    }

    StatusCode::OK.into_response()
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

#[derive(Deserialize)]
pub struct CreateAccountRequest {
    pub name: String,
    pub account_type: String,
    pub currency: String,
    pub institution_id: Option<uuid::Uuid>,
    pub initial_balance: rust_decimal::Decimal,
}

async fn create_account(
    State(state): State<AppState>,
    Json(payload): Json<CreateAccountRequest>,
) -> impl IntoResponse {
    info!("Creating manual account: {}", payload.name);

    // 1. Get or create a "Manual" institution if none provided
    let institution_id = if let Some(id) = payload.institution_id {
        id
    } else {
        // Find "Manual" institution
        let inst = sqlx::query("SELECT id FROM institutions WHERE name = 'Manual'")
            .fetch_optional(&state.db)
            .await;
        
        match inst {
            Ok(Some(row)) => row.get("id"),
            Ok(None) => {
                // Create it
                let new_inst_id = uuid::Uuid::new_v4();
                let _ = sqlx::query(
                    "INSERT INTO institutions (id, name, institution_type, country, integration_type) VALUES ($1, 'Manual', 'manual', 'MX', 'manual')"
                )
                .bind(new_inst_id)
                .execute(&state.db)
                .await;
                new_inst_id
            }
            Err(e) => {
                error!("Database error finding Manual institution: {}", e);
                return StatusCode::INTERNAL_SERVER_ERROR.into_response();
            }
        }
    };

    // 2. Insert the account
    let account_id = uuid::Uuid::new_v4();
    let result = sqlx::query(
        r#"
        INSERT INTO accounts (id, institution_id, name, account_type, currency, current_balance, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, NOW())
        "#
    )
    .bind(account_id)
    .bind(institution_id)
    .bind(&payload.name)
    .bind(&payload.account_type)
    .bind(&payload.currency)
    .bind(payload.initial_balance)
    .execute(&state.db)
    .await;

    if let Err(e) = result {
        error!("Failed to create account: {}", e);
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }

    // 3. Create initial balance snapshot
    let mut balance_usd = payload.initial_balance;
    if payload.currency == "MXN" {
        let rate_row = sqlx::query(
            "SELECT rate FROM exchange_rates WHERE base_currency = 'USD' AND target_currency = 'MXN' ORDER BY recorded_at DESC LIMIT 1"
        )
        .fetch_one(&state.db)
        .await;
        
        if let Ok(r) = rate_row {
            let rate: rust_decimal::Decimal = r.get("rate");
            if !rate.is_zero() {
                balance_usd = (payload.initial_balance / rate).round_dp(2);
            }
        }
    }

    let _ = sqlx::query(
        r#"
        INSERT INTO balance_snapshots (account_id, balance, as_of_date, currency, balance_usd)
        VALUES ($1, $2, CURRENT_DATE, $3, $4)
        "#
    )
    .bind(account_id)
    .bind(payload.initial_balance)
    .bind(&payload.currency)
    .bind(balance_usd)
    .execute(&state.db)
    .await;

    StatusCode::CREATED.into_response()
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

#[derive(Serialize)]
pub struct TransactionResponse {
    pub id: String,
    pub date: String,
    pub description: String,
    pub amount: f64,
    pub currency: String,
    pub category: String,
    pub user_category: Option<String>,
    pub user_notes: Option<String>,
    pub source: Option<String>,
    pub account_name: String,
    pub institution_name: String,
}

/// Get all historical transactions for a specific account
async fn get_account_transactions(
    State(state): State<AppState>,
    Path(id): Path<uuid::Uuid>,
) -> Json<Vec<TransactionResponse>> {
    let rows = sqlx::query(
        r#"
        SELECT t.id, t.date, t.description, t.amount, t.currency, t.category,
               t.user_category, t.user_notes, t.source,
               a.name as account_name, i.name as institution_name
        FROM transactions t
        JOIN accounts a ON t.account_id = a.id
        JOIN institutions i ON a.institution_id = i.id
        WHERE t.account_id = $1
        ORDER BY t.date DESC, t.created_at DESC
        "#
    )
    .bind(id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let txs = rows.iter().map(|row| TransactionResponse {
        id: row.get::<uuid::Uuid, _>("id").to_string(),
        date: row.try_get::<chrono::NaiveDate, _>("date")
            .map(|d| d.to_string())
            .unwrap_or_default(),
        description: row.try_get::<String, _>("description").unwrap_or_default(),
        amount: row.try_get::<rust_decimal::Decimal, _>("amount")
            .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0),
        currency: row.try_get::<String, _>("currency").unwrap_or_else(|_| "USD".to_string()),
        category: row.try_get::<String, _>("category").unwrap_or_else(|_| "Uncategorized".to_string()),
        user_category: row.try_get("user_category").ok(),
        user_notes: row.try_get("user_notes").ok(),
        source: row.try_get("source").ok(),
        account_name: row.get("account_name"),
        institution_name: row.get("institution_name"),
    }).collect();

    Json(txs)
}

#[derive(Deserialize)]
struct UpdateTransactionRequest {
    user_category: Option<String>,
    user_notes: Option<String>,
    /// Reassign the transaction to a different account. Used when a manual
    /// import landed on the wrong account.
    account_id: Option<uuid::Uuid>,
}

/// Update a transaction's user overrides (category, notes, account).
/// Only fields explicitly present in the payload are updated — None means
/// "leave it alone" rather than "clear it".
async fn update_transaction(
    State(state): State<AppState>,
    Path(tx_id): Path<uuid::Uuid>,
    Json(payload): Json<UpdateTransactionRequest>,
) -> impl IntoResponse {
    info!(
        "Updating transaction {}: cat={:?}, notes={:?}, account_id={:?}",
        tx_id, payload.user_category, payload.user_notes, payload.account_id
    );

    let result = sqlx::query(
        r#"
        UPDATE transactions
        SET user_category = COALESCE($1, user_category),
            user_notes    = COALESCE($2, user_notes),
            account_id    = COALESCE($3, account_id),
            updated_at    = NOW()
        WHERE id = $4
        "#,
    )
    .bind(payload.user_category)
    .bind(payload.user_notes)
    .bind(payload.account_id)
    .bind(tx_id)
    .execute(&state.db)
    .await;

    match result {
        Ok(_) => StatusCode::OK.into_response(),
        Err(e) => {
            error!("Failed to update transaction: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

/// Delete a single transaction.
async fn delete_transaction(
    State(state): State<AppState>,
    Path(tx_id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    info!("Deleting transaction: {}", tx_id);
    let result = sqlx::query("DELETE FROM transactions WHERE id = $1")
        .bind(tx_id)
        .execute(&state.db)
        .await;
    match result {
        Ok(_) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => {
            error!("Failed to delete transaction: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

/// Delete a single account
async fn delete_account(
    State(state): State<AppState>,
    Path(id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    info!("Deleting account: {}", id);

    let result = sqlx::query("DELETE FROM accounts WHERE id = $1")
        .bind(id)
        .execute(&state.db)
        .await;

    match result {
        Ok(_) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => {
            error!("Failed to delete account: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}
