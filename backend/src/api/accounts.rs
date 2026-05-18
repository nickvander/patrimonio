use axum::{
    extract::{Extension, Path, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{get, patch, delete},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use tracing::{error, info};

use crate::api::session::AuthContext;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_accounts).post(create_account))
        .route("/summary", get(accounts_summary))
        .route("/{id}", delete(delete_account))
        .route("/{id}/balance", patch(update_account_balance))
        .route("/{id}/nickname", patch(update_account_nickname))
        .route("/{id}/transactions", get(get_account_transactions))
        .route("/transactions/{tx_id}", patch(update_transaction).delete(delete_transaction))
}

#[derive(Deserialize)]
struct UpdateNicknameRequest {
    nickname: String,
}

/// Set or clear a user-defined nickname on an account. An empty string
/// clears the override so the UI falls back to the bank-supplied name.
/// Plaid sync never touches this column, so the rename survives re-sync.
async fn update_account_nickname(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
    Json(payload): Json<UpdateNicknameRequest>,
) -> impl IntoResponse {
    let trimmed = payload.nickname.trim();
    let value: Option<&str> = if trimmed.is_empty() {
        None
    } else {
        Some(trimmed)
    };
    let result = sqlx::query(
        "UPDATE accounts SET nickname = $1, updated_at = NOW() WHERE id = $2 AND user_id = $3",
    )
    .bind(value)
    .bind(id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;
    match result {
        Ok(r) if r.rows_affected() == 1 => StatusCode::OK.into_response(),
        Ok(_) => StatusCode::NOT_FOUND.into_response(),
        Err(e) => {
            error!("Failed to update account nickname: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[derive(Deserialize)]
struct UpdateBalanceRequest {
    current_balance: rust_decimal::Decimal,
}

async fn update_account_balance(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
    Json(payload): Json<UpdateBalanceRequest>,
) -> impl IntoResponse {
    info!("Updating balance for account {}: {}", id, payload.current_balance);

    // 1. Update the account's current balance — scoped to owner.
    let update_acc = sqlx::query(
        "UPDATE accounts SET current_balance = $1, updated_at = NOW() WHERE id = $2 AND user_id = $3"
    )
    .bind(payload.current_balance)
    .bind(id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;

    match &update_acc {
        Err(e) => {
            error!("Failed to update account balance: {}", e);
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
        Ok(r) if r.rows_affected() == 0 => {
            return StatusCode::NOT_FOUND.into_response();
        }
        Ok(_) => {}
    }

    // 2. Fetch the account's currency to ensure the snapshot is accurate.
    //    Still scoped by user_id — defence in depth even though step 1
    //    already proved ownership.
    let account =
        sqlx::query("SELECT currency FROM accounts WHERE id = $1 AND user_id = $2")
            .bind(id)
            .bind(ctx.user_id)
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
            INSERT INTO balance_snapshots (account_id, balance, as_of_date, currency, balance_usd, user_id)
            VALUES ($1, $2, CURRENT_DATE, $3, $4, $5)
            ON CONFLICT (account_id, as_of_date)
            DO UPDATE SET balance = EXCLUDED.balance, balance_usd = EXCLUDED.balance_usd, created_at = NOW()
            "#
        )
        .bind(id)
        .bind(payload.current_balance)
        .bind(currency)
        .bind(balance_usd)
        .bind(ctx.user_id)
        .execute(&state.db)
        .await;
    }

    StatusCode::OK.into_response()
}

/// List all accounts the authenticated user owns.
async fn list_accounts(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<AccountResponse>> {
    let rows = sqlx::query(
        r#"
        SELECT a.id, a.name, a.nickname, a.account_type, a.currency,
               a.current_balance, a.available_balance, a.credit_limit,
               i.name as institution_name, i.country, a.updated_at
        FROM accounts a
        JOIN institutions i ON a.institution_id = i.id
        WHERE a.user_id = $1
        ORDER BY i.name, a.name
        "#
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let accounts = rows.iter().map(|row| {
        AccountResponse {
            id: row.get::<uuid::Uuid, _>("id").to_string(),
            name: row.get("name"),
            nickname: row.try_get::<Option<String>, _>("nickname").ok().flatten(),
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

/// Get a summary of accounts for this user (total assets, liabilities, net worth)
async fn accounts_summary(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<AccountsSummary> {
    let row = sqlx::query(
        r#"
        SELECT
            COALESCE(SUM(CASE WHEN account_type NOT IN ('credit') THEN current_balance ELSE 0 END), 0) as total_assets,
            COALESCE(SUM(CASE WHEN account_type = 'credit' THEN ABS(current_balance) ELSE 0 END), 0) as total_liabilities,
            COUNT(*) as account_count
        FROM accounts
        WHERE user_id = $1
        "#
    )
    .bind(ctx.user_id)
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
    Extension(ctx): Extension<AuthContext>,
    Json(payload): Json<CreateAccountRequest>,
) -> impl IntoResponse {
    info!("Creating manual account for user {}: {}", ctx.user_id, payload.name);

    // 1. Get or create a per-user "Manual" institution. Each user gets
    //    their own Manual row so manual accounts can never bleed across
    //    tenants via the institution table.
    let institution_id = if let Some(id) = payload.institution_id {
        // Verify the supplied institution belongs to this user.
        let owns = sqlx::query(
            "SELECT 1 FROM institutions WHERE id = $1 AND user_id = $2"
        )
        .bind(id)
        .bind(ctx.user_id)
        .fetch_optional(&state.db)
        .await;
        match owns {
            Ok(Some(_)) => id,
            Ok(None) => return StatusCode::NOT_FOUND.into_response(),
            Err(e) => {
                error!("Failed to verify institution ownership: {}", e);
                return StatusCode::INTERNAL_SERVER_ERROR.into_response();
            }
        }
    } else {
        // Find this user's Manual institution.
        let inst = sqlx::query(
            "SELECT id FROM institutions WHERE name = 'Manual' AND user_id = $1"
        )
        .bind(ctx.user_id)
        .fetch_optional(&state.db)
        .await;
        match inst {
            Ok(Some(row)) => row.get("id"),
            Ok(None) => {
                let new_inst_id = uuid::Uuid::new_v4();
                let created = sqlx::query(
                    "INSERT INTO institutions (id, name, institution_type, country, integration_type, user_id) VALUES ($1, 'Manual', 'manual', 'MX', 'manual', $2)"
                )
                .bind(new_inst_id)
                .bind(ctx.user_id)
                .execute(&state.db)
                .await;
                if let Err(e) = created {
                    error!("Failed to create per-user Manual institution: {}", e);
                    return StatusCode::INTERNAL_SERVER_ERROR.into_response();
                }
                new_inst_id
            }
            Err(e) => {
                error!("Database error finding Manual institution: {}", e);
                return StatusCode::INTERNAL_SERVER_ERROR.into_response();
            }
        }
    };

    // 2. Insert the account, stamped with the owner.
    let account_id = uuid::Uuid::new_v4();
    let result = sqlx::query(
        r#"
        INSERT INTO accounts (id, institution_id, name, account_type, currency, current_balance, updated_at, user_id)
        VALUES ($1, $2, $3, $4, $5, $6, NOW(), $7)
        "#
    )
    .bind(account_id)
    .bind(institution_id)
    .bind(&payload.name)
    .bind(&payload.account_type)
    .bind(&payload.currency)
    .bind(payload.initial_balance)
    .bind(ctx.user_id)
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
        INSERT INTO balance_snapshots (account_id, balance, as_of_date, currency, balance_usd, user_id)
        VALUES ($1, $2, CURRENT_DATE, $3, $4, $5)
        "#
    )
    .bind(account_id)
    .bind(payload.initial_balance)
    .bind(&payload.currency)
    .bind(balance_usd)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;

    StatusCode::CREATED.into_response()
}

#[derive(Serialize)]
struct AccountResponse {
    id: String,
    name: String,
    /// User-defined nickname that overrides the bank-supplied `name` in
    /// the UI. None when not set.
    #[serde(skip_serializing_if = "Option::is_none")]
    nickname: Option<String>,
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
    #[serde(skip_serializing_if = "Option::is_none")]
    pub category_detailed: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub payment_channel: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub merchant_name: Option<String>,
    /// Plaid `original_description` — the raw bank line. Surfaced as a
    /// fallback when `description` (Plaid `name`) is too generic.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub original_description: Option<String>,
    /// Best counterparty name from Plaid `counterparties[]` (highest-
    /// confidence merchant). Preferred over `merchant_name` for display.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub counterparty_name: Option<String>,
    /// Counterparty logo URL (Plaid-hosted). Shown next to the merchant
    /// name in the transaction detail panel when available.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub counterparty_logo_url: Option<String>,
    pub user_category: Option<String>,
    pub user_notes: Option<String>,
    /// User-supplied display label that overrides the auto-picked one.
    /// When present, the frontend's `displayLabel` helper uses this
    /// before any of the counterparty / merchant / original fallbacks.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub user_description: Option<String>,
    pub source: Option<String>,
    pub account_name: String,
    pub institution_name: String,
}

/// Get historical transactions for a specific account. Capped at
/// `MAX_ACCOUNT_TRANSACTIONS` rows so a long-lived account doesn't
/// return tens of thousands and OOM the renderer. The frontend's
/// account view shows recent history; a future pagination follow-up
/// will let the user page beyond this cap.
async fn get_account_transactions(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
) -> Json<Vec<TransactionResponse>> {
    const MAX_ACCOUNT_TRANSACTIONS: i64 = 1000;
    // Scoped to the caller. An unknown account id (or one belonging to
    // another user) returns an empty list — the same shape the UI sees
    // for a brand-new empty account.
    let rows = sqlx::query(
        r#"
        SELECT t.id, t.date, t.description, t.amount, t.currency, t.category,
               t.category_detailed, t.payment_channel, t.merchant_name,
               t.original_description, t.counterparty_name, t.counterparty_logo_url,
               t.user_category, t.user_notes, t.user_description, t.source,
               COALESCE(NULLIF(a.nickname, ''), a.name) as account_name,
               i.name as institution_name
        FROM transactions t
        JOIN accounts a ON t.account_id = a.id
        JOIN institutions i ON a.institution_id = i.id
        WHERE t.account_id = $1 AND t.user_id = $2
        ORDER BY t.date DESC, t.created_at DESC
        LIMIT $3
        "#
    )
    .bind(id)
    .bind(ctx.user_id)
    .bind(MAX_ACCOUNT_TRANSACTIONS)
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
        category_detailed: row.try_get::<Option<String>, _>("category_detailed").ok().flatten(),
        payment_channel: row.try_get::<Option<String>, _>("payment_channel").ok().flatten(),
        merchant_name: row.try_get::<Option<String>, _>("merchant_name").ok().flatten(),
        original_description: row.try_get::<Option<String>, _>("original_description").ok().flatten(),
        counterparty_name: row.try_get::<Option<String>, _>("counterparty_name").ok().flatten(),
        counterparty_logo_url: row.try_get::<Option<String>, _>("counterparty_logo_url").ok().flatten(),
        user_category: row.try_get("user_category").ok(),
        user_notes: row.try_get("user_notes").ok(),
        user_description: row.try_get::<Option<String>, _>("user_description").ok().flatten(),
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
    /// User-supplied display label that overrides the cleaned Plaid /
    /// counterparty / original-description fallback chain. Empty
    /// string clears the override; missing key leaves it alone.
    user_description: Option<String>,
    /// Reassign the transaction to a different account. Used when a manual
    /// import landed on the wrong account.
    account_id: Option<uuid::Uuid>,
}

/// Update a transaction's user overrides (category, notes, account).
/// Only fields explicitly present in the payload are updated — None means
/// "leave it alone" rather than "clear it".
async fn update_transaction(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(tx_id): Path<uuid::Uuid>,
    Json(payload): Json<UpdateTransactionRequest>,
) -> impl IntoResponse {
    info!(
        "Updating transaction {} for user {}: cat={:?}, notes={:?}, account_id={:?}",
        tx_id, ctx.user_id, payload.user_category, payload.user_notes, payload.account_id
    );

    // If the caller is moving the transaction to a different account,
    // that destination must also belong to them. Otherwise an attacker
    // could re-parent a transaction into someone else's account.
    if let Some(dest) = payload.account_id {
        let owns = sqlx::query("SELECT 1 FROM accounts WHERE id = $1 AND user_id = $2")
            .bind(dest)
            .bind(ctx.user_id)
            .fetch_optional(&state.db)
            .await;
        if !matches!(owns, Ok(Some(_))) {
            return StatusCode::NOT_FOUND.into_response();
        }
    }

    // For user_description specifically, an explicit empty string
    // clears the override (reverts the row to the auto-picked label);
    // a missing key leaves the existing value alone. CASE encodes
    // both semantics in one SQL expression.
    let result = sqlx::query(
        r#"
        UPDATE transactions
        SET user_category = COALESCE($1, user_category),
            user_notes    = COALESCE($2, user_notes),
            user_description = CASE
                WHEN $3::text IS NULL THEN user_description
                WHEN $3::text = '' THEN NULL
                ELSE $3::text
            END,
            account_id    = COALESCE($4, account_id),
            updated_at    = NOW()
        WHERE id = $5 AND user_id = $6
        "#,
    )
    .bind(payload.user_category)
    .bind(payload.user_notes)
    .bind(payload.user_description)
    .bind(payload.account_id)
    .bind(tx_id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;

    match result {
        Ok(r) if r.rows_affected() == 0 => StatusCode::NOT_FOUND.into_response(),
        Ok(_) => StatusCode::OK.into_response(),
        Err(e) => {
            error!("Failed to update transaction: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

/// Delete a single transaction belonging to the caller.
async fn delete_transaction(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(tx_id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    info!("Deleting transaction {} for user {}", tx_id, ctx.user_id);
    let result =
        sqlx::query("DELETE FROM transactions WHERE id = $1 AND user_id = $2")
            .bind(tx_id)
            .bind(ctx.user_id)
            .execute(&state.db)
            .await;
    match result {
        Ok(r) if r.rows_affected() == 0 => StatusCode::NOT_FOUND.into_response(),
        Ok(_) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => {
            error!("Failed to delete transaction: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

/// Delete a single account belonging to the caller. Transactions,
/// holdings, and balance_snapshots cascade via the FK.
async fn delete_account(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    info!("Deleting account {} for user {}", id, ctx.user_id);

    let result = sqlx::query("DELETE FROM accounts WHERE id = $1 AND user_id = $2")
        .bind(id)
        .bind(ctx.user_id)
        .execute(&state.db)
        .await;

    match result {
        Ok(r) if r.rows_affected() == 0 => StatusCode::NOT_FOUND.into_response(),
        Ok(_) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => {
            error!("Failed to delete account: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}
