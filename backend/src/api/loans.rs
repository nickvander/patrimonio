//! Personal lending API.
//!
//! The user lends money to a named borrower (from the reusable `people`
//! directory); the disbursement is a real bank outflow transaction and
//! each repayment is a real inflow transaction, reconciled manually or
//! via the auto-suggest matcher (`services::loan_match`).
//!
//! Mounted under the `business` router in `main.rs`, so `require_owner`
//! gates every mutating method — read-only invitees can view loans but
//! not create/edit them. Every query is scoped `WHERE user_id = $1`;
//! linking a transaction verifies the tx belongs to the caller first
//! (mirrors `dashboard::create_manual_transaction`). Reconcile / record
//! mutations publish `RealtimeEvent::TransactionsChanged` after commit
//! (the linked rows shift balances + the cash-flow view).

use axum::{
    extract::{Extension, Path, State},
    http::StatusCode,
    response::IntoResponse,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use tracing::error;

use crate::api::session::AuthContext;
use crate::services::loan_match;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_loans).post(create_loan))
        .route("/summary", get(loans_summary))
        .route("/people", get(list_people))
        // Upcoming + overdue installments for the notifications bell.
        .route("/reminders", get(list_reminders))
        // Static segments before dynamic /{id} so the matcher prefers
        // them (same ordering discipline as dashboard.rs fx-transfers).
        .route("/payments/{payment_id}", axum::routing::delete(unreconcile_payment))
        .route("/{id}", get(get_loan).patch(update_loan).delete(delete_loan))
        .route(
            "/{id}/disbursement",
            post(link_disbursement).delete(unlink_disbursement),
        )
        .route("/{id}/payments", get(list_payments).post(record_payment))
        .route("/{id}/schedule", post(generate_schedule))
        .route("/{id}/suggestions/disbursement", get(suggest_disbursement))
        .route("/{id}/suggestions/repayment", get(suggest_repayment))
}

// ---------- shapes ----------

#[derive(Serialize)]
struct LoanView {
    id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    person_id: Option<String>,
    borrower_name: String,
    principal: f64,
    currency: String,
    interest_rate: f64,
    interest_type: String,
    origination_date: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    term_months: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    payment_frequency: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    disbursement_tx_id: Option<String>,
    status: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    notes: Option<String>,
    /// Sum of reconciled repayments (paid_amount) in loan currency.
    total_repaid: f64,
    /// Derived, never stored. For a loan WITH a generated schedule:
    /// principal − Σ scheduled_principal of fully-paid installments.
    /// For a schedule-less loan: principal + simple interest accrued
    /// to today − repaid. Forced to 0 for written_off / cancelled /
    /// paid_off.
    outstanding: f64,
    /// Sum of every installment's scheduled_amount (0 when no schedule).
    total_scheduled: f64,
    /// True once a payment schedule has been generated.
    has_schedule: bool,
    /// Earliest unpaid installment due date (YYYY-MM-DD), if any.
    #[serde(skip_serializing_if = "Option::is_none")]
    next_due: Option<String>,
    /// Any past-due unpaid installment exists.
    overdue: bool,
    /// Borrower has paid more than what's been billed to date.
    paid_ahead: bool,
}

#[derive(Serialize)]
struct PersonView {
    id: String,
    name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    note: Option<String>,
    /// Number of loans to this person + total still outstanding.
    loan_count: i64,
    total_outstanding: f64,
}

#[derive(Serialize)]
struct PaymentView {
    id: String,
    installment_number: i32,
    #[serde(skip_serializing_if = "Option::is_none")]
    due_date: Option<String>,
    scheduled_amount: f64,
    scheduled_principal: f64,
    scheduled_interest: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    actual_tx_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    paid_amount: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    paid_date: Option<String>,
    status: String,
}

#[derive(Deserialize)]
struct CreateLoanRequest {
    /// Either an existing person_id, or a borrower_name to find-or-create.
    #[serde(default)]
    person_id: Option<uuid::Uuid>,
    borrower_name: String,
    principal: f64,
    currency: String,
    #[serde(default)]
    interest_rate: f64,
    #[serde(default = "default_interest_type")]
    interest_type: String,
    origination_date: chrono::NaiveDate,
    #[serde(default)]
    term_months: Option<i32>,
    #[serde(default)]
    payment_frequency: Option<String>,
    #[serde(default)]
    notes: Option<String>,
}

fn default_interest_type() -> String {
    "none".to_string()
}

#[derive(Deserialize)]
struct UpdateLoanRequest {
    #[serde(default)]
    borrower_name: Option<String>,
    #[serde(default)]
    principal: Option<f64>,
    #[serde(default)]
    interest_rate: Option<f64>,
    #[serde(default)]
    interest_type: Option<String>,
    #[serde(default)]
    status: Option<String>,
    #[serde(default)]
    notes: Option<String>,
}

#[derive(Deserialize)]
struct LinkTxRequest {
    transaction_id: uuid::Uuid,
}

#[derive(Deserialize)]
struct RecordPaymentRequest {
    /// The inflow transaction being designated as a repayment.
    transaction_id: uuid::Uuid,
    /// Amount applied to the loan (defaults to the tx's amount).
    #[serde(default)]
    amount: Option<f64>,
    #[serde(default)]
    paid_date: Option<chrono::NaiveDate>,
}

// ---------- helpers ----------

fn dec_to_f64(d: Option<rust_decimal::Decimal>) -> f64 {
    d.and_then(|v| v.to_string().parse().ok()).unwrap_or(0.0)
}

/// Simple interest accrued from origination to today: P · r · t(years).
/// 'none' accrues nothing; 'amortized' is computed from its schedule in
/// v2 — for MVP it falls back to simple so the number is never wrong-
/// signed, just approximate until the schedule generator ships.
fn accrued_interest(
    principal: f64,
    rate: f64,
    interest_type: &str,
    origination: chrono::NaiveDate,
    today: chrono::NaiveDate,
) -> f64 {
    if interest_type == "none" || rate <= 0.0 {
        return 0.0;
    }
    let days = (today - origination).num_days().max(0) as f64;
    let years = days / 365.0;
    principal * rate * years
}

// ---------- loans CRUD ----------

/// Shared SELECT-list of per-loan aggregates computed in SQL so a
/// single query yields everything `loan_view` needs (no N+1). Splice
/// this after `SELECT l.*,` in any loan query. CURRENT_DATE is the
/// reference "today".
const LOAN_AGGREGATES: &str = r#"
    COALESCE((SELECT SUM(p.paid_amount) FROM loan_payments p
              WHERE p.loan_id = l.id AND p.paid_amount IS NOT NULL), 0) AS total_repaid,
    COALESCE((SELECT SUM(p.scheduled_amount) FROM loan_payments p
              WHERE p.loan_id = l.id), 0) AS total_scheduled,
    -- A GENERATED amortization schedule sets scheduled_principal > 0.
    -- Manually-recorded repayments (the MVP path) leave it 0, so they
    -- don't count as a schedule — outstanding for those loans uses the
    -- principal − repaid path instead.
    EXISTS(SELECT 1 FROM loan_payments p
           WHERE p.loan_id = l.id AND p.scheduled_principal > 0) AS has_schedule,
    -- Σ scheduled_principal of FULLY-paid installments → drives the
    -- schedule-aware outstanding (principal − this).
    COALESCE((SELECT SUM(p.scheduled_principal) FROM loan_payments p
              WHERE p.loan_id = l.id AND p.actual_tx_id IS NOT NULL
                AND p.paid_amount >= p.scheduled_amount), 0) AS principal_paid,
    (SELECT MIN(p.due_date) FROM loan_payments p
     WHERE p.loan_id = l.id
       AND (p.actual_tx_id IS NULL OR p.paid_amount < p.scheduled_amount)) AS next_due,
    EXISTS(SELECT 1 FROM loan_payments p
           WHERE p.loan_id = l.id AND p.due_date < CURRENT_DATE
             AND (p.actual_tx_id IS NULL OR p.paid_amount < p.scheduled_amount)) AS overdue,
    -- Σ scheduled_amount billed on or before today (for paid-ahead).
    COALESCE((SELECT SUM(p.scheduled_amount) FROM loan_payments p
              WHERE p.loan_id = l.id AND p.due_date <= CURRENT_DATE), 0) AS cumulative_due
"#;

async fn list_loans(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<LoanView>> {
    let sql = format!(
        "SELECT l.*, {LOAN_AGGREGATES} FROM loans l WHERE l.user_id = $1 \
         ORDER BY l.origination_date DESC, l.created_at DESC"
    );
    let rows = sqlx::query(&sql)
        .bind(ctx.user_id)
        .fetch_all(&state.db)
        .await
        .unwrap_or_default();

    let today = chrono::Utc::now().date_naive();
    Json(rows.iter().map(|r| loan_view(r, today)).collect())
}

fn loan_view(r: &sqlx::postgres::PgRow, today: chrono::NaiveDate) -> LoanView {
    let principal = dec_to_f64(r.try_get("principal").ok());
    let rate = dec_to_f64(r.try_get("interest_rate").ok());
    let interest_type: String = r.try_get("interest_type").unwrap_or_else(|_| "none".to_string());
    let origination: chrono::NaiveDate = r
        .try_get("origination_date")
        .unwrap_or_else(|_| today);
    let status: String = r.try_get("status").unwrap_or_else(|_| "active".to_string());
    let total_repaid = dec_to_f64(r.try_get("total_repaid").ok());
    let total_scheduled = dec_to_f64(r.try_get("total_scheduled").ok());
    let has_schedule: bool = r.try_get("has_schedule").unwrap_or(false);
    let principal_paid = dec_to_f64(r.try_get("principal_paid").ok());
    let cumulative_due = dec_to_f64(r.try_get("cumulative_due").ok());
    let next_due: Option<chrono::NaiveDate> = r.try_get("next_due").ok().flatten();
    let overdue: bool = r.try_get("overdue").unwrap_or(false);

    // Outstanding:
    //   * written_off / cancelled / paid_off → 0 (settled).
    //   * has a schedule → principal − Σ paid scheduled_principal.
    //   * else (open-ended / no schedule) → the simple-interest
    //     approximation: principal + accrued − repaid.
    let outstanding = if matches!(status.as_str(), "written_off" | "cancelled" | "paid_off") {
        0.0
    } else if has_schedule {
        (principal - principal_paid).max(0.0)
    } else {
        let accrued = accrued_interest(principal, rate, &interest_type, origination, today);
        (principal + accrued - total_repaid).max(0.0)
    };
    // Paid-ahead: borrower has repaid more than what's been billed so
    // far (only meaningful with a schedule + something billed).
    let paid_ahead = has_schedule && cumulative_due > 0.0 && total_repaid >= cumulative_due;

    LoanView {
        id: r.get::<uuid::Uuid, _>("id").to_string(),
        person_id: r
            .try_get::<Option<uuid::Uuid>, _>("person_id")
            .ok()
            .flatten()
            .map(|u| u.to_string()),
        borrower_name: r.try_get("borrower_name").unwrap_or_default(),
        principal,
        currency: r.try_get("currency").unwrap_or_default(),
        interest_rate: rate,
        interest_type,
        origination_date: origination.to_string(),
        term_months: r.try_get("term_months").ok().flatten(),
        payment_frequency: r.try_get("payment_frequency").ok().flatten(),
        disbursement_tx_id: r
            .try_get::<Option<uuid::Uuid>, _>("disbursement_tx_id")
            .ok()
            .flatten()
            .map(|u| u.to_string()),
        status,
        notes: r.try_get("notes").ok().flatten(),
        total_repaid,
        outstanding,
        total_scheduled,
        has_schedule,
        next_due: next_due.map(|d| d.to_string()),
        overdue,
        paid_ahead,
    }
}

async fn get_loan(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    let sql = format!(
        "SELECT l.*, {LOAN_AGGREGATES} FROM loans l WHERE l.id = $1 AND l.user_id = $2"
    );
    let row = sqlx::query(&sql)
        .bind(id)
        .bind(ctx.user_id)
        .fetch_optional(&state.db)
        .await;
    match row {
        Ok(Some(r)) => {
            let today = chrono::Utc::now().date_naive();
            Json(loan_view(&r, today)).into_response()
        }
        Ok(None) => StatusCode::NOT_FOUND.into_response(),
        Err(e) => {
            error!("get_loan failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

async fn create_loan(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Json(payload): Json<CreateLoanRequest>,
) -> impl IntoResponse {
    if payload.borrower_name.trim().is_empty() {
        return (StatusCode::BAD_REQUEST, "borrower_name required").into_response();
    }
    if payload.principal <= 0.0 {
        return (StatusCode::BAD_REQUEST, "principal must be positive").into_response();
    }
    if !matches!(payload.interest_type.as_str(), "none" | "simple" | "amortized") {
        return (StatusCode::BAD_REQUEST, "invalid interest_type").into_response();
    }

    // Find-or-create the person. If person_id is supplied, verify it
    // belongs to the caller; otherwise upsert by (user, lower(name)).
    let person_id: Option<uuid::Uuid> = match payload.person_id {
        Some(pid) => {
            let owns = sqlx::query("SELECT 1 FROM people WHERE id = $1 AND user_id = $2")
                .bind(pid)
                .bind(ctx.user_id)
                .fetch_optional(&state.db)
                .await;
            if !matches!(owns, Ok(Some(_))) {
                return StatusCode::NOT_FOUND.into_response();
            }
            Some(pid)
        }
        None => {
            let pid: Result<uuid::Uuid, _> = sqlx::query_scalar(
                r#"
                INSERT INTO people (user_id, name)
                VALUES ($1, $2)
                ON CONFLICT (user_id, LOWER(name))
                DO UPDATE SET name = EXCLUDED.name
                RETURNING id
                "#,
            )
            .bind(ctx.user_id)
            .bind(payload.borrower_name.trim())
            .fetch_one(&state.db)
            .await;
            pid.ok()
        }
    };

    let id: Result<uuid::Uuid, _> = sqlx::query_scalar(
        r#"
        INSERT INTO loans (user_id, person_id, borrower_name, principal, currency,
                           interest_rate, interest_type, origination_date,
                           term_months, payment_frequency, notes)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
        RETURNING id
        "#,
    )
    .bind(ctx.user_id)
    .bind(person_id)
    .bind(payload.borrower_name.trim())
    .bind(rust_decimal::Decimal::from_f64_retain(payload.principal).unwrap_or_default())
    .bind(&payload.currency)
    .bind(rust_decimal::Decimal::from_f64_retain(payload.interest_rate).unwrap_or_default())
    .bind(&payload.interest_type)
    .bind(payload.origination_date)
    .bind(payload.term_months)
    .bind(&payload.payment_frequency)
    .bind(&payload.notes)
    .fetch_one(&state.db)
    .await;

    match id {
        Ok(loan_id) => (
            StatusCode::CREATED,
            Json(serde_json::json!({"id": loan_id.to_string()})),
        )
            .into_response(),
        Err(e) => {
            error!("create_loan failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

async fn update_loan(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
    Json(payload): Json<UpdateLoanRequest>,
) -> impl IntoResponse {
    if let Some(it) = &payload.interest_type {
        if !matches!(it.as_str(), "none" | "simple" | "amortized") {
            return (StatusCode::BAD_REQUEST, "invalid interest_type").into_response();
        }
    }
    if let Some(s) = &payload.status {
        if !matches!(
            s.as_str(),
            "active" | "paid_off" | "written_off" | "cancelled" | "defaulted"
        ) {
            return (StatusCode::BAD_REQUEST, "invalid status").into_response();
        }
    }
    let result = sqlx::query(
        r#"
        UPDATE loans SET
            borrower_name = COALESCE($1, borrower_name),
            principal = COALESCE($2, principal),
            interest_rate = COALESCE($3, interest_rate),
            interest_type = COALESCE($4, interest_type),
            status = COALESCE($5, status),
            notes = COALESCE($6, notes),
            updated_at = NOW()
        WHERE id = $7 AND user_id = $8
        "#,
    )
    .bind(payload.borrower_name)
    .bind(payload.principal.and_then(rust_decimal::Decimal::from_f64_retain))
    .bind(payload.interest_rate.and_then(rust_decimal::Decimal::from_f64_retain))
    .bind(payload.interest_type)
    .bind(payload.status)
    .bind(payload.notes)
    .bind(id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;
    match result {
        Ok(r) if r.rows_affected() == 0 => StatusCode::NOT_FOUND.into_response(),
        Ok(_) => StatusCode::OK.into_response(),
        Err(e) => {
            error!("update_loan failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

async fn delete_loan(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    // loan_payments cascade via FK. The linked transactions are NOT
    // deleted (the loan links to them, it doesn't own them).
    let result = sqlx::query("DELETE FROM loans WHERE id = $1 AND user_id = $2")
        .bind(id)
        .bind(ctx.user_id)
        .execute(&state.db)
        .await;
    match result {
        Ok(r) if r.rows_affected() == 0 => StatusCode::NOT_FOUND.into_response(),
        Ok(_) => {
            // Repayments/disbursement were excluded from cash flow; now
            // that the loan is gone they re-enter, so refresh.
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
            error!("delete_loan failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

// ---------- summary + people ----------

async fn loans_summary(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<serde_json::Value> {
    // Reuse the same enriched aggregates + outstanding logic as the
    // list view so the summary can't drift from the per-loan numbers.
    let sql = format!("SELECT l.*, {LOAN_AGGREGATES} FROM loans l WHERE l.user_id = $1");
    let rows = sqlx::query(&sql)
        .bind(ctx.user_id)
        .fetch_all(&state.db)
        .await
        .unwrap_or_default();

    let today = chrono::Utc::now().date_naive();
    let mut total_lent = 0.0;
    let mut total_outstanding = 0.0;
    let mut active = 0i64;
    for r in &rows {
        let v = loan_view(r, today);
        total_lent += v.principal;
        total_outstanding += v.outstanding;
        if v.status == "active" {
            active += 1;
        }
    }
    Json(serde_json::json!({
        "loan_count": rows.len(),
        "active_count": active,
        "total_lent": total_lent,
        "total_outstanding": total_outstanding,
    }))
}

async fn list_people(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<PersonView>> {
    // Per-person aggregates so the UI can show "lent 3 times, $1,200
    // outstanding". Outstanding is principal − repaid here (we keep the
    // people summary simple — interest is shown at the loan level).
    let rows = sqlx::query(
        r#"
        SELECT pe.id, pe.name, pe.note,
               COUNT(l.id) AS loan_count,
               COALESCE(SUM(
                   GREATEST(l.principal - COALESCE((
                       SELECT SUM(p.paid_amount) FROM loan_payments p
                       WHERE p.loan_id = l.id AND p.paid_amount IS NOT NULL), 0), 0)
               ), 0) AS total_outstanding
        FROM people pe
        LEFT JOIN loans l ON l.person_id = pe.id AND l.user_id = pe.user_id
        WHERE pe.user_id = $1
        GROUP BY pe.id, pe.name, pe.note
        ORDER BY pe.name ASC
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| PersonView {
                id: r.get::<uuid::Uuid, _>("id").to_string(),
                name: r.try_get("name").unwrap_or_default(),
                note: r.try_get("note").ok().flatten(),
                loan_count: r.try_get("loan_count").unwrap_or(0),
                total_outstanding: dec_to_f64(r.try_get("total_outstanding").ok()),
            })
            .collect(),
    )
}

// ---------- transaction linking ----------

/// Verify a transaction belongs to the caller. Returns its currency +
/// date on success. Mirrors create_manual_transaction's ownership guard.
async fn owned_tx(
    state: &AppState,
    user_id: uuid::Uuid,
    tx_id: uuid::Uuid,
) -> Option<(String, chrono::NaiveDate, f64)> {
    let row = sqlx::query("SELECT currency, date, amount FROM transactions WHERE id = $1 AND user_id = $2")
        .bind(tx_id)
        .bind(user_id)
        .fetch_optional(&state.db)
        .await
        .ok()
        .flatten()?;
    let currency: String = row.try_get("currency").ok()?;
    let date: chrono::NaiveDate = row.try_get("date").ok()?;
    let amount = dec_to_f64(row.try_get("amount").ok());
    Some((currency, date, amount))
}

async fn link_disbursement(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
    Json(payload): Json<LinkTxRequest>,
) -> impl IntoResponse {
    if owned_tx(&state, ctx.user_id, payload.transaction_id).await.is_none() {
        return StatusCode::NOT_FOUND.into_response();
    }
    let result = sqlx::query(
        "UPDATE loans SET disbursement_tx_id = $1, updated_at = NOW() WHERE id = $2 AND user_id = $3",
    )
    .bind(payload.transaction_id)
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
                    crate::services::realtime::RealtimeEvent::TransactionsChanged,
                )
                .await;
            StatusCode::OK.into_response()
        }
        // Unique-violation = this tx already funds another loan.
        Err(sqlx::Error::Database(e)) if e.is_unique_violation() => (
            StatusCode::CONFLICT,
            "transaction already linked to another loan",
        )
            .into_response(),
        Err(e) => {
            error!("link_disbursement failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

async fn unlink_disbursement(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    let result = sqlx::query(
        "UPDATE loans SET disbursement_tx_id = NULL, updated_at = NOW() WHERE id = $1 AND user_id = $2",
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
                    crate::services::realtime::RealtimeEvent::TransactionsChanged,
                )
                .await;
            StatusCode::NO_CONTENT.into_response()
        }
        Err(e) => {
            error!("unlink_disbursement failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

// ---------- payments ----------

async fn list_payments(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    // Confirm the loan belongs to the caller before listing.
    let owns = sqlx::query("SELECT 1 FROM loans WHERE id = $1 AND user_id = $2")
        .bind(id)
        .bind(ctx.user_id)
        .fetch_optional(&state.db)
        .await;
    if !matches!(owns, Ok(Some(_))) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let rows = sqlx::query(
        "SELECT * FROM loan_payments WHERE loan_id = $1 AND user_id = $2 ORDER BY installment_number ASC",
    )
    .bind(id)
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| PaymentView {
                id: r.get::<uuid::Uuid, _>("id").to_string(),
                installment_number: r.try_get("installment_number").unwrap_or(0),
                due_date: r
                    .try_get::<Option<chrono::NaiveDate>, _>("due_date")
                    .ok()
                    .flatten()
                    .map(|d| d.to_string()),
                scheduled_amount: dec_to_f64(r.try_get("scheduled_amount").ok()),
                scheduled_principal: dec_to_f64(r.try_get("scheduled_principal").ok()),
                scheduled_interest: dec_to_f64(r.try_get("scheduled_interest").ok()),
                actual_tx_id: r
                    .try_get::<Option<uuid::Uuid>, _>("actual_tx_id")
                    .ok()
                    .flatten()
                    .map(|u| u.to_string()),
                paid_amount: r
                    .try_get::<Option<rust_decimal::Decimal>, _>("paid_amount")
                    .ok()
                    .flatten()
                    .and_then(|d| d.to_string().parse().ok()),
                paid_date: r
                    .try_get::<Option<chrono::NaiveDate>, _>("paid_date")
                    .ok()
                    .flatten()
                    .map(|d| d.to_string()),
                status: r.try_get("status").unwrap_or_else(|_| "scheduled".to_string()),
            })
            .collect::<Vec<_>>(),
    )
    .into_response()
}

/// Record (reconcile) a repayment: designate an inflow transaction as a
/// payment against this loan. Creates a loan_payments row with the next
/// installment number. Idempotent on actual_tx_id (a tx can repay only
/// one installment).
async fn record_payment(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
    Json(payload): Json<RecordPaymentRequest>,
) -> impl IntoResponse {
    let owns = sqlx::query("SELECT 1 FROM loans WHERE id = $1 AND user_id = $2")
        .bind(id)
        .bind(ctx.user_id)
        .fetch_optional(&state.db)
        .await;
    if !matches!(owns, Ok(Some(_))) {
        return StatusCode::NOT_FOUND.into_response();
    }
    let tx = owned_tx(&state, ctx.user_id, payload.transaction_id).await;
    let Some((_currency, tx_date, tx_amount)) = tx else {
        return StatusCode::NOT_FOUND.into_response();
    };
    // Default the applied amount to the transaction's magnitude.
    let amount = payload.amount.unwrap_or(tx_amount.abs());
    let amount_dec = rust_decimal::Decimal::from_f64_retain(amount).unwrap_or_default();
    let paid_date = payload.paid_date.unwrap_or(tx_date);

    // If a GENERATED schedule exists (rows with scheduled_principal > 0),
    // fill the earliest UNPAID scheduled installment rather than
    // appending a new row — that's what makes the schedule-aware
    // outstanding (principal − Σ paid scheduled_principal) decrease.
    // Otherwise (MVP / open-ended loan) append a new installment.
    let next_scheduled: Option<uuid::Uuid> = sqlx::query_scalar(
        "SELECT id FROM loan_payments \
         WHERE loan_id = $1 AND actual_tx_id IS NULL AND scheduled_principal > 0 \
         ORDER BY installment_number ASC LIMIT 1",
    )
    .bind(id)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten();

    let result = if let Some(payment_id) = next_scheduled {
        sqlx::query(
            r#"
            UPDATE loan_payments
            SET actual_tx_id = $1, paid_amount = $2, paid_date = $3,
                status = CASE WHEN $2 >= scheduled_amount THEN 'paid' ELSE 'partial' END
            WHERE id = $4 AND user_id = $5
            "#,
        )
        .bind(payload.transaction_id)
        .bind(amount_dec)
        .bind(paid_date)
        .bind(payment_id)
        .bind(ctx.user_id)
        .execute(&state.db)
        .await
    } else {
        let next: i32 = sqlx::query_scalar(
            "SELECT COALESCE(MAX(installment_number), 0) + 1 FROM loan_payments WHERE loan_id = $1",
        )
        .bind(id)
        .fetch_one(&state.db)
        .await
        .unwrap_or(1);
        sqlx::query(
            r#"
            INSERT INTO loan_payments
                (user_id, loan_id, installment_number, scheduled_amount,
                 actual_tx_id, paid_amount, paid_date, status)
            VALUES ($1, $2, $3, $4, $5, $6, $7, 'paid')
            "#,
        )
        .bind(ctx.user_id)
        .bind(id)
        .bind(next)
        .bind(amount_dec)
        .bind(payload.transaction_id)
        .bind(amount_dec)
        .bind(paid_date)
        .execute(&state.db)
        .await
    };

    match result {
        Ok(_) => {
            // Auto-mark the loan paid_off when the outstanding balance
            // hits zero (best-effort, ignores interest for the trigger
            // since MVP interest is approximate).
            let _ = sqlx::query(
                r#"
                UPDATE loans SET status = 'paid_off', updated_at = NOW()
                WHERE id = $1 AND user_id = $2 AND status = 'active'
                  AND principal <= COALESCE((SELECT SUM(paid_amount) FROM loan_payments
                                             WHERE loan_id = $1 AND paid_amount IS NOT NULL), 0)
                "#,
            )
            .bind(id)
            .bind(ctx.user_id)
            .execute(&state.db)
            .await;
            state
                .realtime
                .publish(
                    ctx.user_id,
                    crate::services::realtime::RealtimeEvent::TransactionsChanged,
                )
                .await;
            StatusCode::CREATED.into_response()
        }
        Err(sqlx::Error::Database(e)) if e.is_unique_violation() => (
            StatusCode::CONFLICT,
            "transaction already recorded as a repayment",
        )
            .into_response(),
        Err(e) => {
            error!("record_payment failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

async fn unreconcile_payment(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(payment_id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    let result = sqlx::query("DELETE FROM loan_payments WHERE id = $1 AND user_id = $2")
        .bind(payment_id)
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
            error!("unreconcile_payment failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

// ---------- auto-suggest ----------

async fn suggest_disbursement(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    let loan = sqlx::query(
        "SELECT principal, currency, origination_date, borrower_name FROM loans WHERE id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await;
    let Ok(Some(l)) = loan else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let principal = dec_to_f64(l.try_get("principal").ok());
    let currency: String = l.try_get("currency").unwrap_or_default();
    let origination: chrono::NaiveDate =
        l.try_get("origination_date").unwrap_or(chrono::Utc::now().date_naive());
    let borrower: String = l.try_get("borrower_name").unwrap_or_default();

    match loan_match::suggest_disbursements(
        &state.db,
        ctx.user_id,
        &currency,
        principal,
        origination,
        &borrower,
    )
    .await
    {
        Ok(suggestions) => Json(suggestions).into_response(),
        Err(e) => {
            error!("suggest_disbursement failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

async fn suggest_repayment(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    let loan = sqlx::query(
        r#"
        SELECT l.principal, l.currency, l.origination_date, l.borrower_name,
               l.term_months, l.interest_type, l.interest_rate,
               t.date AS disbursement_date
        FROM loans l
        LEFT JOIN transactions t ON t.id = l.disbursement_tx_id
        WHERE l.id = $1 AND l.user_id = $2
        "#,
    )
    .bind(id)
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await;
    let Ok(Some(l)) = loan else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let principal = dec_to_f64(l.try_get("principal").ok());
    let currency: String = l.try_get("currency").unwrap_or_default();
    let origination: chrono::NaiveDate =
        l.try_get("origination_date").unwrap_or(chrono::Utc::now().date_naive());
    let borrower: String = l.try_get("borrower_name").unwrap_or_default();
    let term_months: Option<i32> = l.try_get("term_months").ok().flatten();
    // Repayments are searched from the disbursement date (or origination
    // if not yet linked) up to the term horizon (or +18 months default).
    let disbursement_date: chrono::NaiveDate = l
        .try_get::<Option<chrono::NaiveDate>, _>("disbursement_date")
        .ok()
        .flatten()
        .unwrap_or(origination);
    let horizon_months = term_months.unwrap_or(18).max(1) as i64;
    let horizon = disbursement_date + chrono::Duration::days(horizon_months * 31 + 30);

    // Expected installment: prefer the next unpaid installment's
    // scheduled_amount from the generated schedule (exact). Fall back to
    // principal/term when no schedule exists, and to None (no-schedule
    // matcher mode) when there's no term either.
    let next_scheduled: Option<rust_decimal::Decimal> = sqlx::query_scalar(
        "SELECT scheduled_amount FROM loan_payments \
         WHERE loan_id = $1 AND actual_tx_id IS NULL AND scheduled_amount > 0 \
         ORDER BY installment_number ASC LIMIT 1",
    )
    .bind(id)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten();
    let installment = next_scheduled
        .map(|d| d.to_string().parse::<f64>().unwrap_or(0.0))
        .filter(|a| *a > 0.0)
        .or_else(|| term_months.filter(|t| *t > 0).map(|t| principal / t as f64));

    match loan_match::suggest_repayments(
        &state.db,
        ctx.user_id,
        &currency,
        disbursement_date,
        horizon,
        &borrower,
        installment,
    )
    .await
    {
        Ok(suggestions) => Json(suggestions).into_response(),
        Err(e) => {
            error!("suggest_repayment failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

// ---------- schedule generation ----------

/// (Re)generate the amortization schedule for a loan. Refuses (409) if
/// any installment is already reconciled — regen with changed terms
/// would produce a different per-row split and leave paid rows
/// belonging to the old schedule, breaking the Σprincipal == principal
/// invariant. 422 if the loan is open-ended (no term / frequency).
async fn generate_schedule(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    let loan = sqlx::query(
        "SELECT principal, interest_rate, interest_type, origination_date, \
                term_months, payment_frequency \
         FROM loans WHERE id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await;
    let Ok(Some(l)) = loan else {
        return StatusCode::NOT_FOUND.into_response();
    };

    // Refuse if any payment is already reconciled.
    let reconciled: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM loan_payments WHERE loan_id = $1 AND actual_tx_id IS NOT NULL",
    )
    .bind(id)
    .fetch_one(&state.db)
    .await
    .unwrap_or(0);
    if reconciled > 0 {
        return (
            StatusCode::CONFLICT,
            "cannot regenerate schedule: payments already reconciled — unreconcile them first",
        )
            .into_response();
    }

    let principal: rust_decimal::Decimal =
        l.try_get("principal").unwrap_or_default();
    let rate: rust_decimal::Decimal =
        l.try_get("interest_rate").unwrap_or_default();
    let interest_type: String =
        l.try_get("interest_type").unwrap_or_else(|_| "none".to_string());
    let origination: chrono::NaiveDate = match l.try_get("origination_date") {
        Ok(d) => d,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    };
    let term_months: Option<i32> = l.try_get("term_months").ok().flatten();
    let payment_frequency: Option<String> = l.try_get("payment_frequency").ok().flatten();

    let rows = match crate::services::loan_schedule::generate(
        principal,
        rate,
        &interest_type,
        origination,
        term_months,
        payment_frequency.as_deref(),
    ) {
        Ok(r) => r,
        Err(crate::services::loan_schedule::ScheduleError::OpenEnded) => {
            return (
                StatusCode::UNPROCESSABLE_ENTITY,
                "loan has no term / payment frequency — set both to generate a schedule",
            )
                .into_response();
        }
        Err(crate::services::loan_schedule::ScheduleError::BadFrequency) => {
            return (StatusCode::UNPROCESSABLE_ENTITY, "invalid payment frequency").into_response();
        }
    };

    // One transaction: delete any unpaid rows beyond the new length,
    // then upsert each generated row. (No reconciled rows exist — we
    // checked above — so a blanket delete of unpaid rows is safe and
    // simplest.)
    let mut tx = match state.db.begin().await {
        Ok(t) => t,
        Err(e) => {
            error!("generate_schedule begin failed: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };
    if let Err(e) = sqlx::query(
        "DELETE FROM loan_payments WHERE loan_id = $1 AND actual_tx_id IS NULL",
    )
    .bind(id)
    .execute(&mut *tx)
    .await
    {
        error!("generate_schedule clear failed: {e}");
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    for row in &rows {
        let res = sqlx::query(
            r#"
            INSERT INTO loan_payments
                (user_id, loan_id, installment_number, due_date,
                 scheduled_amount, scheduled_principal, scheduled_interest, status)
            VALUES ($1, $2, $3, $4, $5, $6, $7, 'scheduled')
            ON CONFLICT (loan_id, installment_number) DO UPDATE SET
                due_date = EXCLUDED.due_date,
                scheduled_amount = EXCLUDED.scheduled_amount,
                scheduled_principal = EXCLUDED.scheduled_principal,
                scheduled_interest = EXCLUDED.scheduled_interest,
                status = 'scheduled'
            "#,
        )
        .bind(ctx.user_id)
        .bind(id)
        .bind(row.installment_number)
        .bind(row.due_date)
        .bind(row.amount)
        .bind(row.principal)
        .bind(row.interest)
        .execute(&mut *tx)
        .await;
        if let Err(e) = res {
            error!("generate_schedule insert failed: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    }
    if let Err(e) = tx.commit().await {
        error!("generate_schedule commit failed: {e}");
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }

    (
        StatusCode::CREATED,
        Json(serde_json::json!({"installments": rows.len()})),
    )
        .into_response()
}

// ---------- reminders ----------

#[derive(Serialize)]
struct ReminderView {
    loan_id: String,
    payment_id: String,
    borrower_name: String,
    amount: f64,
    currency: String,
    due_date: String,
    installment_number: i32,
    /// Days until due (>0 = upcoming). 0 when overdue.
    days_until: i64,
    /// Days past due (>0 = overdue). 0 when upcoming.
    days_overdue: i64,
}

/// Upcoming + overdue installments for the notifications bell. Reads
/// the user's configured lead-time (app_settings 'lending_reminder_lead_days',
/// default 7) server-side so the window can't be widened by the client.
/// Only active loans; only unpaid, unreconciled, scheduled installments.
async fn list_reminders(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<ReminderView>> {
    // Lead days from settings (JSON number); default 7, clamp 0..=60.
    let lead_days: i64 = sqlx::query_scalar::<_, serde_json::Value>(
        "SELECT value FROM app_settings WHERE key = 'lending_reminder_lead_days' AND user_id = $1",
    )
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten()
    .and_then(|v| v.as_i64())
    .unwrap_or(7)
    .clamp(0, 60);

    let rows = sqlx::query(
        r#"
        SELECT p.id AS payment_id, p.loan_id, l.borrower_name, l.currency,
               p.due_date, p.installment_number,
               COALESCE(p.scheduled_amount, 0) AS amount,
               GREATEST((p.due_date - CURRENT_DATE), 0) AS days_until,
               GREATEST((CURRENT_DATE - p.due_date), 0) AS days_overdue
        FROM loan_payments p
        JOIN loans l ON l.id = p.loan_id AND l.user_id = p.user_id
        WHERE p.user_id = $1
          AND p.status NOT IN ('paid', 'skipped')
          AND p.actual_tx_id IS NULL
          AND p.due_date IS NOT NULL
          AND l.status = 'active'
          AND p.due_date <= CURRENT_DATE + ($2)::int
        ORDER BY p.due_date ASC
        "#,
    )
    .bind(ctx.user_id)
    .bind(lead_days as i32)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| ReminderView {
                loan_id: r.get::<uuid::Uuid, _>("loan_id").to_string(),
                payment_id: r.get::<uuid::Uuid, _>("payment_id").to_string(),
                borrower_name: r.try_get("borrower_name").unwrap_or_default(),
                amount: dec_to_f64(r.try_get("amount").ok()),
                currency: r.try_get("currency").unwrap_or_default(),
                due_date: r
                    .try_get::<chrono::NaiveDate, _>("due_date")
                    .map(|d| d.to_string())
                    .unwrap_or_default(),
                installment_number: r.try_get("installment_number").unwrap_or(0),
                days_until: r.try_get::<i32, _>("days_until").unwrap_or(0) as i64,
                days_overdue: r.try_get::<i32, _>("days_overdue").unwrap_or(0) as i64,
            })
            .collect(),
    )
}
