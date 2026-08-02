use axum::{
    extract::{Extension, Path, Query, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{delete, get, patch, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use tracing::{error, info};

use crate::api::dashboard::latest_usd_mxn_rate;
use crate::api::session::{internal, ApiError, AuthContext};
use crate::models::holding::Holding;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_accounts).post(create_account))
        .route("/summary", get(accounts_summary))
        // "Closed accounts" — accounts Plaid stopped returning (closed/removed
        // at the bank) that the sync reversibly archived. Static path, declared
        // before the dynamic `/{id}` routes so it isn't swallowed as an id.
        .route("/archived", get(list_archived_accounts))
        .route("/{id}/restore", post(restore_account))
        // Global "refresh all my stock prices" — re-prices every manual
        // holding from the live quote cache. Static path, declared before the
        // dynamic `/{id}` routes.
        .route("/holdings/refresh-all", post(refresh_all_holdings))
        .route("/{id}", delete(delete_account))
        .route("/{id}/balance", patch(update_account_balance))
        .route("/{id}/nickname", patch(update_account_nickname))
        // Manual holdings (e.g. a Fidelity NetBenefits ESPP position not on
        // Plaid): add shares by ticker, priced live from the Yahoo quote cache.
        .route("/{id}/holdings", get(list_holdings).post(create_holding))
        // Bulk attach statement-derived holdings (HSA fund + cash sleeve),
        // replacing any prior manual rows for the same symbol so a re-import
        // reflects the latest statement.
        .route("/{id}/holdings/import", post(import_holdings))
        .route("/{id}/holdings/refresh", post(refresh_holdings))
        .route("/{id}/holdings/dividends", get(holdings_dividends))
        .route("/{id}/holdings/{hid}", delete(delete_holding))
        // Round 3 (contract C3-B): un-delete a soft-deleted holding inside
        // the 24 h undo window. 404 once purged (or never existed).
        .route("/{id}/holdings/{hid}/restore", post(restore_holding))
        .route("/{id}/transactions", get(get_account_transactions))
        // Static segment must precede the dynamic `/{tx_id}` route so
        // `/transactions/batch` isn't swallowed as a tx_id path param.
        .route("/transactions/batch", patch(batch_update_transactions))
        // POST (not DELETE) so the body-carrying batch delete is distinct
        // from the param route below and reuses the static-before-dynamic
        // ordering already required for `/transactions/batch`.
        .route(
            "/transactions/batch-delete",
            post(batch_delete_transactions),
        )
        // PATCH tweaks user overrides on ANY row; PUT is the full edit of a
        // manually-entered row (source='manual' only — see the handler).
        .route(
            "/transactions/{tx_id}",
            patch(update_transaction)
                .put(update_manual_transaction)
                .delete(delete_transaction),
        )
        .route(
            "/transactions/{tx_id}/splits",
            axum::routing::post(split_transaction)
                .put(replace_splits)
                .delete(unsplit_transaction),
        )
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
        Ok(r) if r.rows_affected() == 1 => {
            state
                .realtime
                .publish(
                    ctx.user_id,
                    crate::services::realtime::RealtimeEvent::AccountsChanged,
                )
                .await;
            StatusCode::OK.into_response()
        }
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
    /// Optional free-form note about this valuation — written to
    /// the resulting balance_snapshots row. Used by manual-asset
    /// flows (real estate, private equity) to capture "why" each
    /// revaluation moved the number. None / empty leaves the
    /// snapshot's notes column NULL.
    #[serde(default)]
    notes: Option<String>,
}

async fn update_account_balance(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
    Json(payload): Json<UpdateBalanceRequest>,
) -> impl IntoResponse {
    info!(
        "Updating balance for account {}: {}",
        id, payload.current_balance
    );

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
    let account = sqlx::query("SELECT currency FROM accounts WHERE id = $1 AND user_id = $2")
        .bind(id)
        .bind(ctx.user_id)
        .fetch_one(&state.db)
        .await;

    if let Ok(row) = account {
        let currency: String = row.get("currency");

        // 3. Upsert balance snapshot for today
        // balance_usd is FX-converted via the shared rate ladder, which always
        // returns a positive rate — the old inline lookup fell back to the
        // NATIVE balance when the query missed, writing raw MXN into the USD
        // column (~17x overstatement in net worth).
        let mut balance_usd = payload.current_balance;
        if currency == "MXN" {
            let rate =
                crate::services::exchange_rate::latest_usd_mxn_rate_for_write(&state.db).await;
            balance_usd = (payload.current_balance / rate).round_dp(2);
        } else if currency != "USD" {
            // Default to 1:1 if not USD/MXN for now
            balance_usd = payload.current_balance;
        }

        // Normalize blank notes to NULL so the column reflects
        // intent ("no note") rather than empty-string trash.
        let notes: Option<String> = payload
            .notes
            .as_ref()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty());

        let _ = sqlx::query(
            r#"
            INSERT INTO balance_snapshots (account_id, balance, as_of_date, currency, balance_usd, user_id, valuation_notes)
            VALUES ($1, $2, CURRENT_DATE, $3, $4, $5, $6)
            ON CONFLICT (account_id, as_of_date)
            DO UPDATE SET balance = EXCLUDED.balance,
                          balance_usd = EXCLUDED.balance_usd,
                          valuation_notes = COALESCE(EXCLUDED.valuation_notes, balance_snapshots.valuation_notes),
                          created_at = NOW()
            "#
        )
        .bind(id)
        .bind(payload.current_balance)
        .bind(currency)
        .bind(balance_usd)
        .bind(ctx.user_id)
        .bind(notes)
        .execute(&state.db)
        .await;
    }

    state
        .realtime
        .publish(
            ctx.user_id,
            crate::services::realtime::RealtimeEvent::AccountsChanged,
        )
        .await;
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
        WHERE a.user_id = $1 AND a.archived_at IS NULL
        ORDER BY i.name, a.name
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let accounts = rows
        .iter()
        .map(|row| AccountResponse {
            id: row.get::<uuid::Uuid, _>("id").to_string(),
            name: row.get("name"),
            nickname: row.try_get::<Option<String>, _>("nickname").ok().flatten(),
            account_type: row.get("account_type"),
            currency: row.get("currency"),
            current_balance: row
                .try_get::<rust_decimal::Decimal, _>("current_balance")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0)),
            available_balance: row
                .try_get::<rust_decimal::Decimal, _>("available_balance")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0)),
            credit_limit: row
                .try_get::<rust_decimal::Decimal, _>("credit_limit")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0)),
            institution_name: row.get("institution_name"),
            country: row.get("country"),
            updated_at: row
                .try_get::<chrono::DateTime<chrono::Utc>, _>("updated_at")
                .ok()
                .map(|d| d.to_rfc3339())
                .unwrap_or_default(),
        })
        .collect();

    Json(accounts)
}

/// Get a summary of accounts for this user (total assets, liabilities, net worth)
async fn accounts_summary(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<AccountsSummary> {
    // Convert every balance to USD before summing. Without this, a MXN
    // balance (e.g. MX$100,000 ≈ US$5,000) is added to the USD total as
    // 100,000 — the ~18x cross-currency overstatement class. MXN divides by
    // the USD→MXN rate; all other currencies are trusted 1:1, matching
    // dashboard_overview (the sibling endpoint this had drifted from).
    let fx_rate = latest_usd_mxn_rate(&state.db).await.rate;
    let row = sqlx::query(
        r#"
        SELECT
            COALESCE(SUM(CASE WHEN NOT is_liability_account_type(account_type)
                              THEN CASE WHEN currency = 'MXN'
                                        THEN current_balance / $2::numeric
                                        ELSE current_balance END
                              ELSE 0 END), 0) as total_assets,
            COALESCE(SUM(CASE WHEN is_liability_account_type(account_type)
                              THEN ABS(CASE WHEN currency = 'MXN'
                                            THEN current_balance / $2::numeric
                                            ELSE current_balance END)
                              ELSE 0 END), 0) as total_liabilities,
            COUNT(*) as account_count
        FROM accounts
        WHERE user_id = $1 AND archived_at IS NULL
        "#,
    )
    .bind(ctx.user_id)
    .bind(fx_rate)
    .fetch_one(&state.db)
    .await;

    match row {
        Ok(row) => {
            let assets: f64 = row
                .try_get::<rust_decimal::Decimal, _>("total_assets")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0);
            let liabilities: f64 = row
                .try_get::<rust_decimal::Decimal, _>("total_liabilities")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0);
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
    /// Optional statement-derived identity (CLABE / holder), e.g. when the
    /// account is created inline during a Nu / cetesdirecto import.
    #[serde(default)]
    pub clabe: Option<String>,
    #[serde(default)]
    pub holder_name: Option<String>,
    /// Optional statement-derived institution (e.g. "CetesDirecto", "Nu
    /// México"). When set, the account is filed under a per-user institution
    /// with this name instead of the generic "Manual" bucket, so imported
    /// accounts group under their real bank.
    #[serde(default)]
    pub institution_name: Option<String>,
}

async fn create_account(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Json(payload): Json<CreateAccountRequest>,
) -> impl IntoResponse {
    info!(
        "Creating manual account for user {}: {}",
        ctx.user_id, payload.name
    );

    // 1. Get or create a per-user "Manual" institution. Each user gets
    //    their own Manual row so manual accounts can never bleed across
    //    tenants via the institution table.
    let institution_id = if let Some(id) = payload.institution_id {
        // Verify the supplied institution belongs to this user.
        let owns = sqlx::query("SELECT 1 FROM institutions WHERE id = $1 AND user_id = $2")
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
        // File the account under a per-user institution. Statement imports
        // pass the real bank name ("CetesDirecto", "Nu México") so the account
        // groups under its bank; everything else falls back to "Manual".
        let inst_name = payload
            .institution_name
            .as_ref()
            .map(|s| s.trim())
            .filter(|s| !s.is_empty())
            .unwrap_or("Manual")
            .to_string();
        // Find this user's institution with that name (find-or-create).
        let inst = sqlx::query("SELECT id FROM institutions WHERE name = $1 AND user_id = $2")
            .bind(&inst_name)
            .bind(ctx.user_id)
            .fetch_optional(&state.db)
            .await;
        match inst {
            Ok(Some(row)) => row.get("id"),
            Ok(None) => {
                let new_inst_id = uuid::Uuid::new_v4();
                let created = sqlx::query(
                    "INSERT INTO institutions (id, name, institution_type, country, integration_type, user_id) VALUES ($1, $2, 'manual', 'MX', 'manual', $3)"
                )
                .bind(new_inst_id)
                .bind(&inst_name)
                .bind(ctx.user_id)
                .execute(&state.db)
                .await;
                if let Err(e) = created {
                    error!(
                        "Failed to create per-user institution '{}': {}",
                        inst_name, e
                    );
                    return StatusCode::INTERNAL_SERVER_ERROR.into_response();
                }
                new_inst_id
            }
            Err(e) => {
                error!("Database error finding institution '{}': {}", inst_name, e);
                return StatusCode::INTERNAL_SERVER_ERROR.into_response();
            }
        }
    };

    // 2. Insert the account, stamped with the owner.
    let account_id = uuid::Uuid::new_v4();
    // Normalise CLABE to digits-only (18) so it stores/copies cleanly.
    let clabe = payload.clabe.as_ref().and_then(|c| {
        let digits: String = c.chars().filter(|ch| ch.is_ascii_digit()).collect();
        (digits.len() == 18).then_some(digits)
    });
    let holder = payload
        .holder_name
        .as_ref()
        .map(|h| h.trim())
        .filter(|h| !h.is_empty());

    // Normalise the type to lowercase so manual/imported accounts share the
    // same convention as Plaid-synced ones (which arrive lowercase, e.g.
    // "checking", "credit card"). Without this, an imported "Checking" and a
    // synced "checking" form two separate buckets in the dashboard's
    // GROUP BY account_type breakdown. Classification is already
    // case-insensitive, so this is purely about display/grouping hygiene.
    let account_type = payload.account_type.trim().to_lowercase();

    let result = sqlx::query(
        r#"
        INSERT INTO accounts (id, institution_id, name, account_type, currency, current_balance, updated_at, user_id, clabe, holder_name)
        VALUES ($1, $2, $3, $4, $5, $6, NOW(), $7, $8, $9)
        "#
    )
    .bind(account_id)
    .bind(institution_id)
    .bind(&payload.name)
    .bind(&account_type)
    .bind(&payload.currency)
    .bind(payload.initial_balance)
    .bind(ctx.user_id)
    .bind(&clabe)
    .bind(holder)
    .execute(&state.db)
    .await;

    if let Err(e) = result {
        error!("Failed to create account: {}", e);
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }

    // 3. Create initial balance snapshot. Same shared-ladder conversion as the
    // update path: never fall back to the native balance for balance_usd.
    let mut balance_usd = payload.initial_balance;
    if payload.currency == "MXN" {
        let rate = crate::services::exchange_rate::latest_usd_mxn_rate_for_write(&state.db).await;
        balance_usd = (payload.initial_balance / rate).round_dp(2);
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

    state
        .realtime
        .publish(
            ctx.user_id,
            crate::services::realtime::RealtimeEvent::AccountsChanged,
        )
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
    /// Plaid `payment_meta.payee` — recovers the merchant for
    /// ACH/wire/bill-pay rows where Plaid's `name` is generic.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub payment_payee: Option<String>,
    /// Plaid `payment_meta.payer` — symmetric for incoming transfers.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub payment_payer: Option<String>,
    /// Non-null when this row is a child of a split. The parent itself
    /// is filtered out of list views by the read-side query.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub parent_id: Option<String>,
    pub source: Option<String>,
    /// Statement-imported rows persist the bank's own running balance
    /// (the statement's SALDO column — see the
    /// 2026060102_transaction_balance_after migration). Null for
    /// Plaid-synced rows / manual adds; the per-account panel estimates
    /// those client-side from the account's current balance instead.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub balance_after: Option<f64>,
    pub account_name: String,
    pub institution_name: String,
    /// RFC3339 instant the row was INSERTED (sync/import/manual-add time),
    /// as opposed to `date` — the bank-POSTED day. Mirrors
    /// `TransactionEntry.created_at` in api/dashboard.rs so the
    /// since-last-visit drill-down can filter by sync time on either feed
    /// (posted-date windows can never faithfully show "new since X" rows —
    /// card transactions post days before the sync fetches them). Empty
    /// string only if the column were somehow NULL (pre-default row).
    pub created_at: String,
}

/// Optional paging for the per-account history. Both params are
/// optional so the legacy no-param call keeps its original shape.
#[derive(Deserialize)]
struct AccountTransactionsQuery {
    limit: Option<i64>,
    offset: Option<i64>,
}

/// Get historical transactions for a specific account, newest first.
///
/// Paged when `limit`/`offset` are supplied: an explicit `limit` is
/// clamped to 1..=500 per request (mirroring `/dashboard/transactions`),
/// `offset` is floored at 0. With no `limit` the response keeps the
/// legacy single-shot behavior — capped at `MAX_ACCOUNT_TRANSACTIONS`
/// rows so a long-lived account doesn't return tens of thousands and
/// OOM the renderer.
async fn get_account_transactions(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
    Query(q): Query<AccountTransactionsQuery>,
) -> impl IntoResponse {
    const MAX_ACCOUNT_TRANSACTIONS: i64 = 1000;
    let limit = q
        .limit
        .map(|l| l.clamp(1, 500))
        .unwrap_or(MAX_ACCOUNT_TRANSACTIONS);
    let offset = q.offset.unwrap_or(0).max(0);
    // Scoped to the caller. An unknown account id (or one belonging to
    // another user) returns an empty list — the same shape the UI sees
    // for a brand-new empty account.
    let rows = sqlx::query(
        r#"
        SELECT t.id,
               -- Total matching rows BEFORE LIMIT/OFFSET — the window
               -- function shares the identical WHERE (account + user scope,
               -- split-parent exclusion), so the X-Total-Count header can't
               -- drift from the list and is stable across offset pages.
               -- See dashboard::total_count_headers for why it's a header,
               -- not a body envelope.
               COUNT(*) OVER () AS total_count,
               t.date, t.description, t.amount, t.currency, t.category,
               t.category_detailed, t.payment_channel, t.merchant_name,
               t.original_description, t.counterparty_name, t.counterparty_logo_url,
               t.user_category, t.user_notes, t.user_description, t.source,
               t.payment_payee, t.payment_payer, t.parent_id, t.balance_after,
               t.created_at,
               COALESCE(NULLIF(a.nickname, ''), a.name) as account_name,
               i.name as institution_name
        FROM transactions t
        JOIN accounts a ON t.account_id = a.id
        JOIN institutions i ON a.institution_id = i.id
        WHERE t.account_id = $1 AND t.user_id = $2
          AND NOT EXISTS (SELECT 1 FROM transactions tc WHERE tc.parent_id = t.id)
        ORDER BY t.date DESC, t.created_at DESC
        LIMIT $3 OFFSET $4
        "#,
    )
    .bind(id)
    .bind(ctx.user_id)
    .bind(limit)
    .bind(offset)
    .fetch_all(&state.db)
    .await;

    // Best-effort read semantics unchanged: a DB error still yields an
    // empty 200 array with no header — but capture Result-ness first, so
    // "succeeded and found nothing" stays distinguishable below.
    let db_ok = rows.is_ok();
    let rows = rows.unwrap_or_default();

    // Same window total on every row; read it off the first. A successful
    // empty FIRST page (offset == 0) provably means the account's total is
    // 0 — emit it so the panel can clear a stale "Showing 0 of N" after
    // the last rows were deleted. An empty page beyond the end (offset >
    // 0) proves nothing → no header (see dashboard::total_count_headers).
    let total = rows
        .first()
        .and_then(|r| r.try_get::<i64, _>("total_count").ok())
        .or((db_ok && offset == 0).then_some(0));

    let txs: Vec<TransactionResponse> = rows
        .iter()
        .map(|row| TransactionResponse {
            id: row.get::<uuid::Uuid, _>("id").to_string(),
            date: row
                .try_get::<chrono::NaiveDate, _>("date")
                .map(|d| d.to_string())
                .unwrap_or_default(),
            description: row.try_get::<String, _>("description").unwrap_or_default(),
            amount: row
                .try_get::<rust_decimal::Decimal, _>("amount")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0),
            currency: row
                .try_get::<String, _>("currency")
                .unwrap_or_else(|_| "USD".to_string()),
            category: row
                .try_get::<String, _>("category")
                .unwrap_or_else(|_| "Uncategorized".to_string()),
            category_detailed: row
                .try_get::<Option<String>, _>("category_detailed")
                .ok()
                .flatten(),
            payment_channel: row
                .try_get::<Option<String>, _>("payment_channel")
                .ok()
                .flatten(),
            merchant_name: row
                .try_get::<Option<String>, _>("merchant_name")
                .ok()
                .flatten(),
            original_description: row
                .try_get::<Option<String>, _>("original_description")
                .ok()
                .flatten(),
            counterparty_name: row
                .try_get::<Option<String>, _>("counterparty_name")
                .ok()
                .flatten(),
            counterparty_logo_url: row
                .try_get::<Option<String>, _>("counterparty_logo_url")
                .ok()
                .flatten(),
            user_category: row.try_get("user_category").ok(),
            user_notes: row.try_get("user_notes").ok(),
            user_description: row
                .try_get::<Option<String>, _>("user_description")
                .ok()
                .flatten(),
            payment_payee: row
                .try_get::<Option<String>, _>("payment_payee")
                .ok()
                .flatten(),
            payment_payer: row
                .try_get::<Option<String>, _>("payment_payer")
                .ok()
                .flatten(),
            parent_id: row
                .try_get::<Option<uuid::Uuid>, _>("parent_id")
                .ok()
                .flatten()
                .map(|u| u.to_string()),
            source: row.try_get("source").ok(),
            balance_after: row
                .try_get::<Option<rust_decimal::Decimal>, _>("balance_after")
                .ok()
                .flatten()
                .and_then(|d| d.to_string().parse().ok()),
            account_name: row.get("account_name"),
            institution_name: row.get("institution_name"),
            created_at: row
                .try_get::<Option<chrono::DateTime<chrono::Utc>>, _>("created_at")
                .ok()
                .flatten()
                .map(|dt| dt.to_rfc3339())
                .unwrap_or_default(),
        })
        .collect();

    (crate::api::dashboard::total_count_headers(total), Json(txs))
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
            account_id    = COALESCE($4, account_id)
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
        Ok(_) => {
            state
                .realtime
                .publish(
                    ctx.user_id,
                    crate::services::realtime::RealtimeEvent::TransactionsChanged,
                )
                .await;
            StatusCode::OK.into_response()
        }
        Err(e) => {
            error!("Failed to update transaction: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[derive(Deserialize)]
struct UpdateManualTransactionRequest {
    /// Mirrors `CreateManualTransactionRequest` (api/dashboard.rs) — the
    /// Edit flow reopens the add dialog pre-filled and resubmits the
    /// same field set, now against an existing row.
    account_id: uuid::Uuid,
    date: chrono::NaiveDate,
    description: String,
    /// Negative = outflow (expense), positive = inflow (income) — same
    /// storage convention as the create path and the Plaid sync import.
    amount: rust_decimal::Decimal,
    currency: String,
    #[serde(default)]
    category: Option<String>,
    #[serde(default)]
    notes: Option<String>,
}

/// Full edit of a manually-entered transaction (PUT). Unlike the PATCH
/// above — user-override tweaks that are valid on any row — this
/// rewrites the facts themselves (amount, date, direction, currency,
/// account, description), which is only safe when the user *is* the
/// source of truth, i.e. `source = 'manual'`. Synced/imported rows get
/// 403 so bank-reported history can't silently drift from the statement;
/// rows the caller doesn't own get 404 (indistinguishable from missing).
///
/// Mirrors the create/delete paths: `create_manual_transaction` derives
/// nothing beyond the row itself (no balance/snapshot writes — manual
/// rows leave `balance_after` NULL and the account's balance is the
/// user-maintained figure), so the update likewise touches only the row
/// and republishes the realtime event. The dedup `external_id`
/// signature is recomputed from the new fields so the create path's
/// double-submit collapsing keeps working against the edited values.
async fn update_manual_transaction(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(tx_id): Path<uuid::Uuid>,
    Json(payload): Json<UpdateManualTransactionRequest>,
) -> Result<StatusCode, ApiError> {
    info!(
        "Editing manual transaction {} for user {}",
        tx_id, ctx.user_id
    );

    // Preflight: the row must exist and belong to the caller, and be a
    // plain (unsplit) manual row.
    let row = sqlx::query(
        "SELECT t.source, t.parent_id IS NOT NULL AS is_split_child, \
                EXISTS(SELECT 1 FROM transactions c WHERE c.parent_id = t.id) AS is_split_parent \
         FROM transactions t WHERE t.id = $1 AND t.user_id = $2",
    )
    .bind(tx_id)
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await
    .map_err(internal)?
    .ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, "transaction not found"))?;

    let source: Option<String> = row.try_get("source").ok().flatten();
    if source.as_deref() != Some("manual") {
        return Err(ApiError::new(
            StatusCode::FORBIDDEN,
            "only manually-entered transactions can be edited",
        ));
    }
    // Split children inherit source='manual' from a manual parent, and a
    // split parent's amount anchors the children-sum-to-parent invariant
    // — editing either directly would silently break the split. Those go
    // through the split editor / unsplit flow instead.
    let is_split_child: bool = row.try_get("is_split_child").unwrap_or(false);
    let is_split_parent: bool = row.try_get("is_split_parent").unwrap_or(false);
    if is_split_child || is_split_parent {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "split transactions can't be edited directly — edit or undo the split instead",
        ));
    }

    // The (possibly changed) target account must belong to the caller —
    // same guard as the PATCH's move path, otherwise an edit could
    // re-parent a row into someone else's account.
    let owns = sqlx::query("SELECT 1 FROM accounts WHERE id = $1 AND user_id = $2")
        .bind(payload.account_id)
        .bind(ctx.user_id)
        .fetch_optional(&state.db)
        .await
        .map_err(internal)?;
    if owns.is_none() {
        return Err(ApiError::new(StatusCode::NOT_FOUND, "account not found"));
    }

    // Same dedup signature as create_manual_transaction, recomputed from
    // the edited fields. A collision with another row's signature on the
    // same account means the edit would duplicate it — surfaced as 409.
    let signature = format!(
        "manual:{}:{}:{}",
        payload.date,
        payload.amount,
        payload
            .description
            .to_lowercase()
            .chars()
            .take(50)
            .collect::<String>()
    );

    // user_category / user_description overrides are cleared: the edit
    // dialog prefills FROM the effective (override-first) values and the
    // user has just re-stated them — a stale override left in place
    // would keep masking the very columns this edit writes and make the
    // edit look ignored in every list view.
    let result = sqlx::query(
        r#"
        UPDATE transactions
        SET account_id = $1,
            external_id = $2,
            date = $3,
            description = $4,
            amount = $5,
            currency = $6,
            category = $7,
            user_category = NULL,
            user_description = NULL,
            user_notes = $8
        WHERE id = $9 AND user_id = $10 AND source = 'manual'
        "#,
    )
    .bind(payload.account_id)
    .bind(&signature)
    .bind(payload.date)
    .bind(&payload.description)
    .bind(payload.amount)
    .bind(&payload.currency)
    .bind(&payload.category)
    .bind(payload.notes.as_ref().filter(|n| !n.is_empty()))
    .bind(tx_id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;

    match result {
        // Raced away between preflight and write (deleted concurrently).
        Ok(r) if r.rows_affected() == 0 => Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "transaction not found",
        )),
        Ok(_) => {
            state
                .realtime
                .publish(
                    ctx.user_id,
                    crate::services::realtime::RealtimeEvent::TransactionsChanged,
                )
                .await;
            Ok(StatusCode::OK)
        }
        // (account_id, external_id) unique clash — the edited values now
        // exactly match another manual entry. Same message the create
        // path uses for its ON CONFLICT dedup.
        Err(sqlx::Error::Database(e)) if e.is_unique_violation() => Err(ApiError::new(
            StatusCode::CONFLICT,
            "duplicate manual transaction",
        )),
        Err(e) => Err(internal(e)),
    }
}

#[derive(Deserialize)]
struct BatchUpdateTransactionsRequest {
    /// Transactions to update. The `user_id` filter on the UPDATE is the
    /// security boundary — ids the caller doesn't own are silently
    /// skipped (they don't match the WHERE clause), never trusted.
    ids: Vec<uuid::Uuid>,
    /// Optional batch changes. COALESCE semantics, mirroring the single
    /// PATCH: a missing/None field leaves the column alone.
    user_category: Option<String>,
    user_notes: Option<String>,
    user_description: Option<String>,
    /// Reassign every matched transaction to a different account. Must
    /// belong to the caller (validated below, same as the single PATCH).
    account_id: Option<uuid::Uuid>,
}

#[derive(Serialize)]
struct BatchUpdateResponse {
    updated: u64,
}

/// Update many transactions in a single request (and a single SQL
/// statement). The bulk-action UI uses this to recategorize or move a
/// selection of transactions without firing N separate PATCHes.
///
/// Field semantics mirror `update_transaction` exactly: optional fields
/// use COALESCE ("leave alone" when absent), `user_description` uses the
/// CASE clearing trick, and the `user_id` predicate scopes every write
/// to the caller. Returns `{ "updated": <rows_affected> }`.
async fn batch_update_transactions(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Json(payload): Json<BatchUpdateTransactionsRequest>,
) -> impl IntoResponse {
    info!(
        "Batch-updating {} transactions for user {}: cat={:?}, account_id={:?}",
        payload.ids.len(),
        ctx.user_id,
        payload.user_category,
        payload.account_id
    );

    // An empty selection is a client bug, not a no-op we should reward
    // with 200. Reject it.
    if payload.ids.is_empty() {
        return StatusCode::BAD_REQUEST.into_response();
    }

    // If moving transactions, the destination account must belong to the
    // caller — otherwise the batch could re-parent rows into someone
    // else's account. Same check as the single PATCH.
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
            account_id    = COALESCE($4, account_id)
        WHERE id = ANY($5) AND user_id = $6
        "#,
    )
    .bind(payload.user_category)
    .bind(payload.user_notes)
    .bind(payload.user_description)
    .bind(payload.account_id)
    .bind(&payload.ids)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;

    match result {
        Ok(r) => {
            state
                .realtime
                .publish(
                    ctx.user_id,
                    crate::services::realtime::RealtimeEvent::TransactionsChanged,
                )
                .await;
            (
                StatusCode::OK,
                Json(BatchUpdateResponse {
                    updated: r.rows_affected(),
                }),
            )
                .into_response()
        }
        Err(e) => {
            error!("Failed to batch-update transactions: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[derive(Deserialize)]
struct BatchDeleteTransactionsRequest {
    /// Transactions to delete. As with the batch update, the `user_id`
    /// predicate on the DELETE is the security boundary — ids the caller
    /// doesn't own simply don't match the WHERE clause and are skipped,
    /// never trusted.
    ids: Vec<uuid::Uuid>,
}

#[derive(Serialize)]
struct BatchDeleteResponse {
    deleted: u64,
}

/// Delete many transactions in a single request (and a single SQL
/// statement). The bulk-action UI uses this to drop a selection without
/// firing N separate DELETEs.
///
/// Semantics mirror `delete_transaction` exactly: a plain DELETE scoped
/// by `user_id`. Split parents behave the same — the `parent_id` FK is
/// `ON DELETE CASCADE`, so deleting a parent removes its children
/// automatically (the returned count reflects the directly-matched rows,
/// not cascade-deleted children, same as the single delete). Returns
/// `{ "deleted": <rows_affected> }`.
async fn batch_delete_transactions(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Json(payload): Json<BatchDeleteTransactionsRequest>,
) -> impl IntoResponse {
    info!(
        "Batch-deleting {} transactions for user {}",
        payload.ids.len(),
        ctx.user_id
    );

    // An empty selection is a client bug, not a no-op we should reward
    // with 200. Reject it (matches batch_update_transactions).
    if payload.ids.is_empty() {
        return StatusCode::BAD_REQUEST.into_response();
    }

    let result = sqlx::query("DELETE FROM transactions WHERE id = ANY($1) AND user_id = $2")
        .bind(&payload.ids)
        .bind(ctx.user_id)
        .execute(&state.db)
        .await;

    match result {
        Ok(r) => {
            state
                .realtime
                .publish(
                    ctx.user_id,
                    crate::services::realtime::RealtimeEvent::TransactionsChanged,
                )
                .await;
            (
                StatusCode::OK,
                Json(BatchDeleteResponse {
                    deleted: r.rows_affected(),
                }),
            )
                .into_response()
        }
        Err(e) => {
            error!("Failed to batch-delete transactions: {}", e);
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
    let result = sqlx::query("DELETE FROM transactions WHERE id = $1 AND user_id = $2")
        .bind(tx_id)
        .bind(ctx.user_id)
        .execute(&state.db)
        .await;
    match result {
        Ok(r) if r.rows_affected() == 0 => StatusCode::NOT_FOUND.into_response(),
        Ok(_) => {
            state
                .realtime
                .publish(
                    ctx.user_id,
                    crate::services::realtime::RealtimeEvent::TransactionsChanged,
                )
                .await;
            StatusCode::NO_CONTENT.into_response()
        }
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
        Ok(_) => {
            state
                .realtime
                .publish(
                    ctx.user_id,
                    crate::services::realtime::RealtimeEvent::AccountsChanged,
                )
                .await;
            StatusCode::NO_CONTENT.into_response()
        }
        Err(e) => {
            error!("Failed to delete account: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

/// One archived ("closed") account, surfaced to the "Closed accounts" UI so
/// the user can review what the sync auto-archived and either restore it or
/// permanently delete it.
#[derive(Serialize)]
struct ArchivedAccountResponse {
    id: String,
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    nickname: Option<String>,
    institution_name: String,
    account_type: String,
    current_balance: Option<f64>,
    currency: String,
    archived_at: String,
}

/// List the caller's archived accounts — the ones the sync stopped seeing in
/// Plaid's response and reversibly archived (closed/removed at the bank).
/// Excluded from every net-worth / balance / list query; this endpoint is the
/// only place they surface, so a "Closed accounts" screen can offer restore or
/// permanent delete.
async fn list_archived_accounts(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<ArchivedAccountResponse>> {
    let rows = sqlx::query(
        r#"
        SELECT a.id, a.name, a.nickname, a.account_type, a.currency,
               a.current_balance, i.name as institution_name, a.archived_at
        FROM accounts a
        JOIN institutions i ON a.institution_id = i.id
        WHERE a.user_id = $1 AND a.archived_at IS NOT NULL
        ORDER BY a.archived_at DESC, i.name, a.name
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let accounts = rows
        .iter()
        .map(|row| ArchivedAccountResponse {
            id: row.get::<uuid::Uuid, _>("id").to_string(),
            name: row.get("name"),
            nickname: row.try_get::<Option<String>, _>("nickname").ok().flatten(),
            institution_name: row.get("institution_name"),
            account_type: row.get("account_type"),
            current_balance: row
                .try_get::<rust_decimal::Decimal, _>("current_balance")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0)),
            currency: row.get("currency"),
            archived_at: row
                .try_get::<chrono::DateTime<chrono::Utc>, _>("archived_at")
                .ok()
                .map(|d| d.to_rfc3339())
                .unwrap_or_default(),
        })
        .collect();

    Json(accounts)
}

/// Restore a previously-archived account (clear archived_at) so it counts
/// toward net worth and reappears in lists again. Scoped to the caller. A
/// missing / not-owned / not-archived id returns 404. Note that the next sync
/// re-archives it if Plaid still isn't returning that external_id — restore is
/// for the case where the account is genuinely back, or was archived in error.
async fn restore_account(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    info!("Restoring account {} for user {}", id, ctx.user_id);

    let result = sqlx::query(
        "UPDATE accounts SET archived_at = NULL, updated_at = NOW() \
         WHERE id = $1 AND user_id = $2 AND archived_at IS NOT NULL",
    )
    .bind(id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;

    match result {
        Ok(r) if r.rows_affected() == 0 => StatusCode::NOT_FOUND.into_response(),
        Ok(_) => {
            state
                .realtime
                .publish(
                    ctx.user_id,
                    crate::services::realtime::RealtimeEvent::AccountsChanged,
                )
                .await;
            StatusCode::NO_CONTENT.into_response()
        }
        Err(e) => {
            error!("Failed to restore account: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

#[derive(Deserialize)]
struct SplitRequest {
    splits: Vec<SplitChild>,
}

#[derive(Deserialize)]
struct SplitChild {
    description: String,
    amount: rust_decimal::Decimal,
    /// User-supplied category for this leg. None = inherit the parent's
    /// category at insert time (then editable like any other tx).
    #[serde(default)]
    category: Option<String>,
}

/// Split a transaction into N children. The original parent stays in
/// the DB for audit but is hidden from every list and aggregate by the
/// `NOT EXISTS (SELECT 1 FROM transactions c WHERE c.parent_id = t.id)`
/// filter that's now woven through the read-side queries.
///
/// Validates:
///   * `splits.len() >= 2` — a one-split "split" is just an edit.
///   * Every child amount has the same sign as the parent. A split
///     that mixes inflows + outflows is almost always a typo (and the
///     few legitimate cases — partial refunds — are better modeled
///     as separate manual transactions).
///   * `sum(child.amount) == parent.amount` to within 1 cent. The 1¢
///     tolerance handles the inevitable rounding when splitting a
///     $33.34 charge three ways.
///   * No nested splits — you can't split a row that's already a
///     child of another split.
///   * Parent isn't already split (re-splitting would orphan the
///     existing children).
async fn split_transaction(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(tx_id): Path<uuid::Uuid>,
    Json(payload): Json<SplitRequest>,
) -> impl IntoResponse {
    use rust_decimal::Decimal;
    if payload.splits.len() < 2 {
        return (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(serde_json::json!({"error": "Need at least two splits"})),
        )
            .into_response();
    }

    let parent_row = sqlx::query(
        r#"
        SELECT t.id, t.account_id, t.date, t.amount, t.currency, t.description,
               t.category, t.user_category, t.source, t.parent_id,
               (SELECT 1 FROM transactions c WHERE c.parent_id = t.id LIMIT 1) AS has_children
        FROM transactions t
        WHERE t.id = $1 AND t.user_id = $2
        "#,
    )
    .bind(tx_id)
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await;
    let parent = match parent_row {
        Ok(Some(r)) => r,
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(e) => {
            error!("split_transaction lookup failed: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };
    let parent_parent_id: Option<uuid::Uuid> = parent.try_get("parent_id").ok();
    if parent_parent_id.is_some() {
        return (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(serde_json::json!({"error": "Cannot split a transaction that is already a split-child"})),
        )
            .into_response();
    }
    let has_children: Option<i32> = parent.try_get("has_children").ok();
    if has_children.is_some() {
        return (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(serde_json::json!({"error": "Transaction is already split — unsplit first"})),
        )
            .into_response();
    }

    let parent_amount: Decimal = parent.get("amount");
    let parent_account_id: uuid::Uuid = parent.get("account_id");
    let parent_date: chrono::NaiveDate = parent.get("date");
    let parent_currency: String = parent.get("currency");
    let parent_category: Option<String> = parent.try_get("category").ok();
    let parent_source: Option<String> = parent.try_get("source").ok().flatten();

    let parent_is_positive = parent_amount.is_sign_positive();
    let mut total = Decimal::ZERO;
    for child in &payload.splits {
        let trimmed = child.description.trim();
        if trimmed.is_empty() {
            return (
                StatusCode::UNPROCESSABLE_ENTITY,
                Json(serde_json::json!({"error": "Every split needs a description"})),
            )
                .into_response();
        }
        if child.amount.is_zero() {
            return (
                StatusCode::UNPROCESSABLE_ENTITY,
                Json(serde_json::json!({"error": "Zero-amount splits are not allowed"})),
            )
                .into_response();
        }
        if child.amount.is_sign_positive() != parent_is_positive {
            return (
                StatusCode::UNPROCESSABLE_ENTITY,
                Json(serde_json::json!({
                    "error": "Every split must share the parent's sign (all expense or all income)"
                })),
            )
                .into_response();
        }
        total += child.amount;
    }
    // 1¢ tolerance — split-three-ways rounding on a $33.34 charge.
    let diff = (total - parent_amount).abs();
    if diff > Decimal::new(1, 2) {
        return (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(serde_json::json!({
                "error": format!(
                    "Split total ({}) doesn't match parent ({}) — off by {}",
                    total, parent_amount, diff
                )
            })),
        )
            .into_response();
    }

    // Transactional insert so a mid-flight failure can't leave a
    // half-split row.
    let mut tx = match state.db.begin().await {
        Ok(t) => t,
        Err(e) => {
            error!("split begin failed: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };

    for child in &payload.splits {
        let category = child
            .category
            .as_deref()
            .filter(|s| !s.trim().is_empty())
            .map(str::to_string)
            .or_else(|| parent_category.clone());
        let res = sqlx::query(
            r#"
            INSERT INTO transactions (
                account_id, parent_id, date, description, amount, currency,
                category, user_category, source, user_id
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
            "#,
        )
        .bind(parent_account_id)
        .bind(tx_id)
        .bind(parent_date)
        .bind(child.description.trim())
        .bind(child.amount)
        .bind(&parent_currency)
        .bind(category.as_deref())
        .bind(child.category.as_deref().filter(|s| !s.trim().is_empty()))
        .bind(parent_source.as_deref().unwrap_or("split"))
        .bind(ctx.user_id)
        .execute(&mut *tx)
        .await;
        if let Err(e) = res {
            error!("split child insert failed: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    }
    if let Err(e) = tx.commit().await {
        error!("split commit failed: {e}");
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }

    state
        .realtime
        .publish(
            ctx.user_id,
            crate::services::realtime::RealtimeEvent::TransactionsChanged,
        )
        .await;
    (
        StatusCode::CREATED,
        Json(serde_json::json!({
            "parent_id": tx_id.to_string(),
            "splits": payload.splits.len()
        })),
    )
        .into_response()
}

/// Un-split: delete every child of this parent. The parent itself
/// stays untouched, so the original transaction re-emerges in the
/// list. Returns 404 when the target isn't a split parent owned by
/// the caller. Returns 200 with the count of removed children.
async fn unsplit_transaction(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(tx_id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    // Ownership predicate via JOIN to parent — without this an
    // attacker who knew a parent UUID could nuke another user's
    // splits. The DELETE only fires when the parent belongs to ctx.
    let result = sqlx::query(
        r#"
        DELETE FROM transactions
        WHERE parent_id = $1
          AND parent_id IN (SELECT id FROM transactions WHERE id = $1 AND user_id = $2)
        "#,
    )
    .bind(tx_id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;
    match result {
        Ok(r) if r.rows_affected() == 0 => StatusCode::NOT_FOUND.into_response(),
        Ok(r) => {
            state
                .realtime
                .publish(
                    ctx.user_id,
                    crate::services::realtime::RealtimeEvent::TransactionsChanged,
                )
                .await;
            Json(serde_json::json!({"removed": r.rows_affected()})).into_response()
        }
        Err(e) => {
            error!("unsplit_transaction failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

/// Atomically replace the children of an already-split parent in a
/// single round-trip. The frontend's "Edit split" flow used to do
/// DELETE-then-POST (two requests with a small race window where a
/// concurrent fetch would see the parent restored without children);
/// this endpoint collapses both ops into one DB transaction so the
/// row never appears un-split to any reader. Validation rules are
/// identical to `split_transaction`. Accepts the same payload shape
/// (`{ "splits": [...] }`) plus an implicit "parent must already be
/// split" precondition — call POST for the first split, PUT for
/// every edit afterward.
async fn replace_splits(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(tx_id): Path<uuid::Uuid>,
    Json(payload): Json<SplitRequest>,
) -> impl IntoResponse {
    use rust_decimal::Decimal;
    if payload.splits.len() < 2 {
        return (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(serde_json::json!({"error": "Need at least two splits"})),
        )
            .into_response();
    }

    let parent_row = sqlx::query(
        r#"
        SELECT t.id, t.account_id, t.date, t.amount, t.currency, t.description,
               t.category, t.source, t.parent_id
        FROM transactions t
        WHERE t.id = $1 AND t.user_id = $2
        "#,
    )
    .bind(tx_id)
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await;
    let parent = match parent_row {
        Ok(Some(r)) => r,
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(e) => {
            error!("replace_splits lookup failed: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };
    let parent_parent_id: Option<uuid::Uuid> = parent.try_get("parent_id").ok();
    if parent_parent_id.is_some() {
        return (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(serde_json::json!({"error": "Cannot split a transaction that is already a split-child"})),
        )
            .into_response();
    }

    let parent_amount: Decimal = parent.get("amount");
    let parent_account_id: uuid::Uuid = parent.get("account_id");
    let parent_date: chrono::NaiveDate = parent.get("date");
    let parent_currency: String = parent.get("currency");
    let parent_category: Option<String> = parent.try_get("category").ok();
    let parent_source: Option<String> = parent.try_get("source").ok().flatten();

    let parent_is_positive = parent_amount.is_sign_positive();
    let mut total = Decimal::ZERO;
    for child in &payload.splits {
        let trimmed = child.description.trim();
        if trimmed.is_empty() {
            return (
                StatusCode::UNPROCESSABLE_ENTITY,
                Json(serde_json::json!({"error": "Every split needs a description"})),
            )
                .into_response();
        }
        if child.amount.is_zero() {
            return (
                StatusCode::UNPROCESSABLE_ENTITY,
                Json(serde_json::json!({"error": "Zero-amount splits are not allowed"})),
            )
                .into_response();
        }
        if child.amount.is_sign_positive() != parent_is_positive {
            return (
                StatusCode::UNPROCESSABLE_ENTITY,
                Json(serde_json::json!({
                    "error": "Every split must share the parent's sign (all expense or all income)"
                })),
            )
                .into_response();
        }
        total += child.amount;
    }
    let diff = (total - parent_amount).abs();
    if diff > Decimal::new(1, 2) {
        return (
            StatusCode::UNPROCESSABLE_ENTITY,
            Json(serde_json::json!({
                "error": format!(
                    "Split total ({}) doesn't match parent ({}) — off by {}",
                    total, parent_amount, diff
                )
            })),
        )
            .into_response();
    }

    // Single DB transaction: DELETE existing children, then INSERT the
    // new set. No window in which the parent appears restored.
    let mut tx = match state.db.begin().await {
        Ok(t) => t,
        Err(e) => {
            error!("replace_splits begin failed: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };

    let removed = match sqlx::query("DELETE FROM transactions WHERE parent_id = $1")
        .bind(tx_id)
        .execute(&mut *tx)
        .await
    {
        Ok(r) => r.rows_affected(),
        Err(e) => {
            error!("replace_splits delete failed: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };

    for child in &payload.splits {
        let category = child
            .category
            .as_deref()
            .filter(|s| !s.trim().is_empty())
            .map(str::to_string)
            .or_else(|| parent_category.clone());
        let res = sqlx::query(
            r#"
            INSERT INTO transactions (
                account_id, parent_id, date, description, amount, currency,
                category, user_category, source, user_id
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
            "#,
        )
        .bind(parent_account_id)
        .bind(tx_id)
        .bind(parent_date)
        .bind(child.description.trim())
        .bind(child.amount)
        .bind(&parent_currency)
        .bind(category.as_deref())
        .bind(child.category.as_deref().filter(|s| !s.trim().is_empty()))
        .bind(parent_source.as_deref().unwrap_or("split"))
        .bind(ctx.user_id)
        .execute(&mut *tx)
        .await;
        if let Err(e) = res {
            error!("replace_splits child insert failed: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    }
    if let Err(e) = tx.commit().await {
        error!("replace_splits commit failed: {e}");
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }

    state
        .realtime
        .publish(
            ctx.user_id,
            crate::services::realtime::RealtimeEvent::TransactionsChanged,
        )
        .await;
    (
        StatusCode::OK,
        Json(serde_json::json!({
            "parent_id": tx_id.to_string(),
            "removed": removed,
            "inserted": payload.splits.len(),
        })),
    )
        .into_response()
}

// ---------------------------------------------------------------------------
// Manual holdings (ticker + share quantity), priced from the Yahoo quote cache
// ---------------------------------------------------------------------------

#[derive(Deserialize)]
pub struct CreateHoldingRequest {
    /// Ticker symbol, e.g. "ORCL". Used verbatim as the Yahoo symbol.
    pub symbol: String,
    /// Display name; defaults to the symbol.
    pub name: Option<String>,
    pub quantity: rust_decimal::Decimal,
    /// Optional total cost basis (what you paid), for gain/loss.
    pub cost_basis: Option<rust_decimal::Decimal>,
}

// latest_price + recompute_holding_balance moved to services::holdings so the
// nightly refresh cron can share them without an HTTP/auth context.
use crate::services::holdings::{latest_price, recompute_holding_balance};

/// Recompute a holdings-backed account's balance as the sum of its holdings'
/// values, and snapshot it (FX-aware) so it flows into net worth — the same
/// way a Plaid investment account's balance is the sum of its holdings.
async fn account_owned(db: &sqlx::PgPool, account_id: uuid::Uuid, user_id: uuid::Uuid) -> bool {
    matches!(
        sqlx::query_scalar::<_, uuid::Uuid>(
            "SELECT id FROM accounts WHERE id = $1 AND user_id = $2",
        )
        .bind(account_id)
        .bind(user_id)
        .fetch_optional(db)
        .await,
        Ok(Some(_))
    )
}

/// True only for an owned, MANUAL account. Holdings can only be hand-edited on
/// manual accounts — never a Plaid-synced one, where balance + holdings are
/// authoritative from the institution (we'd corrupt them and fight the sync).
async fn account_is_manual(db: &sqlx::PgPool, account_id: uuid::Uuid, user_id: uuid::Uuid) -> bool {
    matches!(
        sqlx::query_scalar::<_, String>(
            "SELECT i.integration_type FROM accounts a JOIN institutions i ON i.id = a.institution_id WHERE a.id = $1 AND a.user_id = $2",
        )
        .bind(account_id)
        .bind(user_id)
        .fetch_optional(db)
        .await,
        Ok(Some(ref t)) if t == "manual"
    )
}

const HOLDING_COLS: &str =
    "id, account_id, symbol, name, quantity, price, value, cost_basis, currency, holding_type, updated_at";

/// Round 3 lazy sweep: hard-purge this user's soft-deleted holdings older
/// than the 24 h undo window. Runs at the top of every holdings write
/// (create/delete) — no cron job; the FK ON DELETE CASCADE cleans the
/// ghosts' lots and disposals. Best-effort: a sweep failure never blocks
/// the write that triggered it.
async fn sweep_expired_soft_deletes(db: &sqlx::PgPool, user_id: uuid::Uuid) {
    if let Err(e) = sqlx::query(
        "DELETE FROM holdings WHERE user_id = $1 AND deleted_at < now() - interval '24 hours'",
    )
    .bind(user_id)
    .execute(db)
    .await
    {
        error!("Failed to sweep expired soft-deleted holdings: {}", e);
    }
}

async fn create_holding(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(account_id): Path<uuid::Uuid>,
    Json(payload): Json<CreateHoldingRequest>,
) -> impl IntoResponse {
    if !account_is_manual(&state.db, account_id, ctx.user_id).await {
        return (
            StatusCode::FORBIDDEN,
            "holdings can only be added to a manual account",
        )
            .into_response();
    }
    sweep_expired_soft_deletes(&state.db, ctx.user_id).await;
    let symbol = payload.symbol.trim().to_uppercase();
    if symbol.is_empty() {
        return (StatusCode::BAD_REQUEST, "symbol required").into_response();
    }
    let name = payload
        .name
        .as_ref()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| symbol.clone());

    let price = latest_price(&state.db, &symbol).await;
    let value = price.map(|p| (p * payload.quantity).round_dp(2));

    // Purge on re-add: a still-soft-deleted row for the same (account,
    // symbol) must not survive — restoring it later would resurrect a
    // duplicate position. A fresh add IS the hard event superseding undo.
    let _ = sqlx::query(
        "DELETE FROM holdings WHERE account_id = $1 AND user_id = $2 AND UPPER(symbol) = $3 AND deleted_at IS NOT NULL",
    )
    .bind(account_id)
    .bind(ctx.user_id)
    .bind(&symbol)
    .execute(&state.db)
    .await;

    let id = uuid::Uuid::new_v4();
    let insert = sqlx::query(
        r#"
        INSERT INTO holdings (id, account_id, user_id, symbol, name, quantity, price, value, cost_basis, currency, holding_type, updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'USD', 'equity', NOW())
        "#,
    )
    .bind(id)
    .bind(account_id)
    .bind(ctx.user_id)
    .bind(&symbol)
    .bind(&name)
    .bind(payload.quantity)
    .bind(price)
    .bind(value)
    .bind(payload.cost_basis)
    .execute(&state.db)
    .await;
    if let Err(e) = insert {
        error!("Failed to insert holding: {}", e);
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    if let Err(e) = recompute_holding_balance(&state.db, account_id, ctx.user_id).await {
        error!("Failed to recompute holding balance: {}", e);
    }
    match sqlx::query_as::<_, Holding>(&format!(
        "SELECT {HOLDING_COLS} FROM holdings WHERE id = $1"
    ))
    .bind(id)
    .fetch_one(&state.db)
    .await
    {
        Ok(h) => (StatusCode::CREATED, Json(h)).into_response(),
        Err(_) => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

#[derive(serde::Deserialize)]
struct ImportHoldingsRequest {
    holdings: Vec<crate::services::parser::ImportHolding>,
}

/// Attach a batch of statement-derived holdings to a manual account — an HSA's
/// invested fund (live-priced from Yahoo) plus its cash sleeve (fixed at 1.00).
/// Each symbol REPLACES any prior manually-imported row for the same symbol, so
/// re-importing newer statements just updates the quantities. The account's
/// balance is then recomputed as the sum of its holdings.
///
/// ATOMIC, and it must stay that way. The replace is a hard DELETE followed by
/// an INSERT — imports supersede any undo (see `delete_holding`) — so a failure
/// between the two destroys a position with no way back. Both statements used
/// to be `let _ =` inside a handler that returned 200 unconditionally: a failed
/// INSERT (mis-parsed quantity, pool blip) dropped the fund, silently
/// recomputed the account down to its cash sleeve, and told the user "Import
/// successful". One transaction per request; errors reach the client.
async fn import_holdings(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(account_id): Path<uuid::Uuid>,
    Json(payload): Json<ImportHoldingsRequest>,
) -> impl IntoResponse {
    if !account_is_manual(&state.db, account_id, ctx.user_id).await {
        return (
            StatusCode::FORBIDDEN,
            "holdings can only be added to a manual account",
        )
            .into_response();
    }
    let mut tx = match state.db.begin().await {
        Ok(t) => t,
        Err(e) => {
            error!("import_holdings begin failed: {e}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "could not start the holdings import",
            )
                .into_response();
        }
    };

    for h in &payload.holdings {
        let symbol = h.symbol.trim().to_uppercase();
        if symbol.is_empty() {
            continue;
        }
        let Some(qty) = rust_decimal::Decimal::from_f64_retain(h.quantity) else {
            continue;
        };
        // Replace any prior manual row for this (account, symbol) so a re-import
        // is idempotent. Plaid-sourced rows (external_id set) are left alone.
        if let Err(e) = sqlx::query(
            "DELETE FROM holdings WHERE account_id = $1 AND user_id = $2 AND symbol = $3 AND external_id IS NULL",
        )
        .bind(account_id)
        .bind(ctx.user_id)
        .bind(&symbol)
        .execute(&mut *tx)
        .await
        {
            error!("Failed to clear prior holding rows for {symbol}: {e}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "holdings import failed; nothing was changed",
            )
                .into_response();
        }

        let name = h
            .name
            .as_ref()
            .map(|s| s.trim().to_string())
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| symbol.clone());
        let stmt_value = h.value.and_then(rust_decimal::Decimal::from_f64_retain);
        let (price, value, htype): (
            Option<rust_decimal::Decimal>,
            Option<rust_decimal::Decimal>,
            String,
        ) = if h.cash {
            // Cash sleeve: $1.00 NAV, value = the cash amount; never Yahoo-priced.
            (
                Some(rust_decimal::Decimal::ONE),
                stmt_value.or(Some(qty)),
                "cash".to_string(),
            )
        } else {
            // Equity/fund: live price from the Yahoo quote cache; fall back to
            // the statement's reported value if the symbol can't be priced.
            let p = latest_price(&state.db, &symbol).await;
            let v = p.map(|p| (p * qty).round_dp(2)).or(stmt_value);
            // Allocation bucket — defaults to "equity"; a fund import
            // (e.g. HSA target-date) sets "mutual fund".
            let kind = h
                .holding_type
                .as_ref()
                .map(|s| s.trim().to_lowercase())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "equity".to_string());
            (p, v, kind)
        };

        if let Err(e) = sqlx::query(
            r#"
            INSERT INTO holdings (id, account_id, user_id, symbol, name, quantity, price, value, currency, holding_type, updated_at)
            VALUES (gen_random_uuid(), $1, $2, $3, $4, $5, $6, $7, 'USD', $8, NOW())
            "#,
        )
        .bind(account_id)
        .bind(ctx.user_id)
        .bind(&symbol)
        .bind(&name)
        .bind(qty)
        .bind(price)
        .bind(value)
        .bind(htype)
        .execute(&mut *tx)
        .await
        {
            // The DELETE above already ran for this symbol — without the
            // rollback this drop of the transaction performs, the position
            // would simply be gone.
            error!("Failed to insert imported holding {symbol}: {e}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                "holdings import failed; nothing was changed",
            )
                .into_response();
        }
    }

    if let Err(e) = tx.commit().await {
        error!("import_holdings commit failed: {e}");
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            "holdings import failed; nothing was changed",
        )
            .into_response();
    }

    // Balance is derived from the rows we just wrote, so a failure here leaves
    // the account showing a stale total against correct holdings — report it
    // rather than letting the client paint success over it.
    if let Err(e) = recompute_holding_balance(&state.db, account_id, ctx.user_id).await {
        error!("Failed to recompute balance after holdings import: {}", e);
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            "holdings were imported but the account balance could not be recomputed",
        )
            .into_response();
    }
    StatusCode::OK.into_response()
}

async fn list_holdings(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(account_id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    let rows = sqlx::query_as::<_, Holding>(&format!(
        "SELECT {HOLDING_COLS} FROM holdings WHERE account_id = $1 AND user_id = $2 AND deleted_at IS NULL ORDER BY value DESC NULLS LAST"
    ))
    .bind(account_id)
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();
    Json(rows).into_response()
}

/// Round 3: delete is a SOFT delete (`deleted_at = now()`), reversible via
/// the restore endpoint for 24 h. Status code and response shape are
/// unchanged from the old hard delete (contract C3-B). Imports and account
/// deletion still hard-delete — a fresh import supersedes any undo.
async fn delete_holding(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path((account_id, hid)): Path<(uuid::Uuid, uuid::Uuid)>,
) -> impl IntoResponse {
    if !account_is_manual(&state.db, account_id, ctx.user_id).await {
        return StatusCode::FORBIDDEN.into_response();
    }
    sweep_expired_soft_deletes(&state.db, ctx.user_id).await;
    let res = sqlx::query(
        "UPDATE holdings SET deleted_at = now() WHERE id = $1 AND account_id = $2 AND user_id = $3 AND deleted_at IS NULL",
    )
    .bind(hid)
    .bind(account_id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;
    match res {
        Ok(r) if r.rows_affected() > 0 => {
            let _ = recompute_holding_balance(&state.db, account_id, ctx.user_id).await;
            StatusCode::NO_CONTENT.into_response()
        }
        Ok(_) => StatusCode::NOT_FOUND.into_response(),
        Err(e) => {
            error!("Failed to delete holding: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

/// Round 3 (contract C3-B): undo a soft delete by nulling `deleted_at`. The
/// holding, its lots, and its realized-gain history all reappear atomically
/// (they were only hidden behind the holding's flag). 404 when there is no
/// soft-deleted row to restore — wrong user/account, double restore, or the
/// ghost was already purged (24 h sweep / purge-on-re-add).
async fn restore_holding(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path((account_id, hid)): Path<(uuid::Uuid, uuid::Uuid)>,
) -> impl IntoResponse {
    let res = sqlx::query(
        "UPDATE holdings SET deleted_at = NULL WHERE id = $1 AND account_id = $2 AND user_id = $3 AND deleted_at IS NOT NULL",
    )
    .bind(hid)
    .bind(account_id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;
    match res {
        Ok(r) if r.rows_affected() > 0 => {
            let _ = recompute_holding_balance(&state.db, account_id, ctx.user_id).await;
            // Same HOLDING_COLS shape as the create-holding readback.
            match sqlx::query_as::<_, Holding>(&format!(
                "SELECT {HOLDING_COLS} FROM holdings WHERE id = $1"
            ))
            .bind(hid)
            .fetch_one(&state.db)
            .await
            {
                Ok(h) => (StatusCode::OK, Json(h)).into_response(),
                Err(e) => {
                    error!("Failed to read back restored holding: {}", e);
                    StatusCode::INTERNAL_SERVER_ERROR.into_response()
                }
            }
        }
        Ok(_) => (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "nothing to restore"})),
        )
            .into_response(),
        Err(e) => {
            error!("Failed to restore holding: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

/// Re-price every holding in the account from the live Yahoo cache and
/// recompute the account balance. Lets the user refresh on demand until the
/// daily price job lands.
async fn refresh_holdings(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(account_id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    if !account_is_manual(&state.db, account_id, ctx.user_id).await {
        return StatusCode::FORBIDDEN.into_response();
    }
    let symbols: Vec<String> = sqlx::query_scalar(
        "SELECT DISTINCT symbol FROM holdings WHERE account_id = $1 AND user_id = $2 AND deleted_at IS NULL",
    )
    .bind(account_id)
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();
    for sym in &symbols {
        if let Some(price) = latest_price(&state.db, sym).await {
            let _ = sqlx::query(
                "UPDATE holdings SET price = $1, value = ROUND(quantity * $1, 2), updated_at = NOW() WHERE symbol = $2 AND account_id = $3 AND user_id = $4",
            )
            .bind(price)
            .bind(sym)
            .bind(account_id)
            .bind(ctx.user_id)
            .execute(&state.db)
            .await;
        }
    }
    if let Err(e) = recompute_holding_balance(&state.db, account_id, ctx.user_id).await {
        error!("Failed to recompute after refresh: {}", e);
    }
    list_holdings(State(state), Extension(ctx), Path(account_id))
        .await
        .into_response()
}

/// Per-holding dividend info (trailing annual rate, yield, estimated next
/// ex-date) + the projected annual income for the held quantity. Sourced from
/// the same free Yahoo feed as prices.
async fn holdings_dividends(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(account_id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    if !account_owned(&state.db, account_id, ctx.user_id).await {
        return StatusCode::NOT_FOUND.into_response();
    }
    let rows = sqlx::query(
        // Skip cash-sleeve rows (mirrors the portfolio-wide endpoint) —
        // they're fixed at 1.00, never pay a dividend, and a Yahoo lookup
        // for them only wastes a request + logs a miss.
        "SELECT symbol, quantity, price FROM holdings WHERE account_id = $1 AND user_id = $2 AND COALESCE(holding_type, '') <> 'cash' AND deleted_at IS NULL",
    )
    .bind(account_id)
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let mut out = Vec::new();
    for row in rows {
        let symbol: String = row.get("symbol");
        let qty: Option<rust_decimal::Decimal> = row.get("quantity");
        let price: Option<rust_decimal::Decimal> = row.get("price");
        let qf = qty
            .map(|q| q.to_string().parse::<f64>().unwrap_or(0.0))
            .unwrap_or(0.0);
        let pf = price.and_then(|p| p.to_string().parse::<f64>().ok());

        let info = benchmark_dividends(&state.redis, &symbol).await;
        let annual_rate = info.as_ref().map(|i| i.0).unwrap_or(0.0);
        let annual_income = ((annual_rate * qf) * 100.0).round() / 100.0;
        let yield_pct = pf
            .filter(|p| *p > 0.0)
            .map(|p| ((annual_rate / p * 100.0) * 100.0).round() / 100.0);
        out.push(serde_json::json!({
            "symbol": symbol,
            "quantity": qf,
            "annual_rate": annual_rate,
            "annual_income": annual_income,
            "yield_pct": yield_pct,
            "last_ex_date": info.as_ref().and_then(|i| i.1.clone()),
            "est_next_ex_date": info.as_ref().and_then(|i| i.2.clone()),
            "per_year": info.as_ref().map(|i| i.3).unwrap_or(0),
        }));
    }
    Json(out).into_response()
}

/// Re-price every manual holding the user has (across all their manual
/// accounts) and recompute those account balances. The portfolio-wide analog
/// of the per-account refresh button.
async fn refresh_all_holdings(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> impl IntoResponse {
    let accounts: Vec<uuid::Uuid> = sqlx::query_scalar(
        r#"
        SELECT DISTINCT a.id
        FROM accounts a
        JOIN institutions i ON i.id = a.institution_id
        JOIN holdings h ON h.account_id = a.id
        WHERE a.user_id = $1 AND i.integration_type = 'manual'
          AND h.deleted_at IS NULL
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let mut symbols_priced = 0;
    for account_id in &accounts {
        let symbols: Vec<String> = sqlx::query_scalar(
            // Skip cash-sleeve positions — they're fixed at 1.00 and have no
            // Yahoo quote, so a lookup would only waste a request + log a miss.
            "SELECT DISTINCT symbol FROM holdings WHERE account_id = $1 AND user_id = $2 AND COALESCE(holding_type, '') <> 'cash' AND deleted_at IS NULL",
        )
        .bind(account_id)
        .bind(ctx.user_id)
        .fetch_all(&state.db)
        .await
        .unwrap_or_default();
        for sym in &symbols {
            if let Some(price) = latest_price(&state.db, sym).await {
                let _ = sqlx::query(
                    "UPDATE holdings SET price = $1, value = ROUND(quantity * $1, 2), updated_at = NOW() WHERE symbol = $2 AND account_id = $3 AND user_id = $4",
                )
                .bind(price)
                .bind(sym)
                .bind(account_id)
                .bind(ctx.user_id)
                .execute(&state.db)
                .await;
                symbols_priced += 1;
            }
        }
        let _ = recompute_holding_balance(&state.db, *account_id, ctx.user_id).await;
    }
    Json(serde_json::json!({
        "accounts_refreshed": accounts.len(),
        "symbols_priced": symbols_priced,
    }))
    .into_response()
}

/// (annual_rate, last_ex_date, est_next_ex_date, per_year) for a symbol, or
/// None on a fetch error. Non-payers come back as a zero-rate Some. Round 4:
/// served through the Redis envelope cache (C4-C) — Redis being down
/// degrades to a live fetch inside `fetch_dividends_cached`.
async fn benchmark_dividends(
    redis: &redis::Client,
    symbol: &str,
) -> Option<(f64, Option<String>, Option<String>, i32)> {
    match crate::services::dividends::fetch_dividends_cached(redis, symbol, false).await {
        Ok(i) => Some((
            i.annual_rate,
            i.last_ex_date,
            i.est_next_ex_date,
            i.per_year,
        )),
        Err(_) => None,
    }
}
