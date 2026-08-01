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
    extract::{Extension, Path, Query, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use tracing::error;

use crate::api::session::AuthContext;
use crate::services::loan_match;
use crate::AppState;

/// A money amount quantised to cents, ready to bind.
///
/// `Decimal::from_f64_retain` keeps the FULL binary expansion — it does not
/// round — so `from_f64_retain(1033.33)` is
/// `1033.3299999999999272404238578`. Binding that unrounded is what made an
/// exact payoff read as a partial payment: the allocation loop compares
/// `COALESCE(paid_amount, 0) + $2 >= scheduled_amount` in SQL, where
/// `scheduled_amount` is the stored `NUMERIC(20,6)` cents (`1033.330000`) and
/// `$2` still carries the full expansion — so the row stayed `'partial'`
/// while `paid_amount` (rounded on store by the column's scale) was written
/// as exactly `scheduled_amount`. A self-contradicting row, and
/// `list_reminders` filters on `status NOT IN ('paid','skipped')`, so the
/// installment reminded forever.
///
/// Schedules are generated at 2dp (`services::loan_schedule::round2`), so
/// cents is the right quantum here. Rates and non-money values must NOT go
/// through this.
fn cents(x: f64) -> rust_decimal::Decimal {
    rust_decimal::Decimal::from_f64_retain(x)
        .unwrap_or_default()
        .round_dp(2)
}

/// Half a cent. Residual f64 arithmetic in the allocation loop leaves dust
/// (`533.33 - 533.32999999999992724 = 1.1e-13`); comparing that against a
/// bare `0.0` appended a phantom 0.00 installment to the schedule — visible
/// in the plan table and both exports. Anything under half a cent is zero.
const MONEY_EPSILON: f64 = 0.005;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_loans).post(create_loan))
        .route("/summary", get(loans_summary))
        .route("/people", get(list_people))
        // Upcoming + overdue installments for the notifications bell.
        .route("/reminders", get(list_reminders))
        // Interest-income report + its CSV exports (static before /{id}).
        .route("/interest-income", get(interest_income))
        .route("/interest-income/export", get(export_interest_income))
        // Per-borrower per-year totals (Schedule-B style) CSV.
        .route("/interest-income/summary", get(export_interest_summary))
        // Static segments before dynamic /{id} so the matcher prefers
        // them (same ordering discipline as dashboard.rs fx-transfers).
        .route(
            "/payments/{payment_id}",
            axum::routing::delete(unreconcile_payment),
        )
        .route(
            "/{id}",
            get(get_loan).patch(update_loan).delete(delete_loan),
        )
        .route(
            "/{id}/disbursement",
            post(link_disbursement).delete(unlink_disbursement),
        )
        .route("/{id}/payments", get(list_payments).post(record_payment))
        // Attach a real bank tx to an installment already paid OFF-BANK.
        .route(
            "/{id}/payments/{payment_id}/attach-tx",
            post(attach_payment_tx),
        )
        .route("/{id}/schedule", post(generate_schedule))
        .route("/{id}/schedule/custom", post(set_custom_schedule))
        .route("/{id}/payoff", post(payoff_loan))
        .route("/{id}/suggestions/disbursement", get(suggest_disbursement))
        .route("/{id}/suggestions/repayment", get(suggest_repayment))
        // Printable promissory-note / agreement (HTML → browser PDF).
        .route("/{id}/agreement", get(loan_agreement))
        // Borrower-facing payment plan: printable HTML and a CSV that
        // opens directly in Google Sheets / Excel.
        .route("/{id}/plan", get(loan_payment_plan))
        .route("/{id}/schedule.csv", get(export_schedule_csv))
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
    /// 'annual' or 'monthly' — the period interest_rate is expressed in.
    rate_period: String,
    origination_date: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    term_months: Option<i32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    payment_frequency: Option<String>,
    /// Optional explicit "pay back by" date (YYYY-MM-DD), schedule or not.
    #[serde(skip_serializing_if = "Option::is_none")]
    expected_repayment_date: Option<String>,
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
    /// What the borrower still owes IN TOTAL — principal + unpaid scheduled
    /// interest (Σ scheduled payments − repaid). Equals `outstanding` for a
    /// 0%/no-schedule loan. The figure the lending UI shows as "owed"; net
    /// worth still uses the interest-excluded `outstanding`.
    total_owed: f64,
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
    /// Cumulative interest income realized on this loan (Σ
    /// interest_portion of reconciled repayments). Cash basis.
    interest_earned: f64,
    /// Simple interest accrued on the current outstanding balance from
    /// origination to today, MINUS interest already received. A
    /// non-income, informational "interest owed so far" figure (cash
    /// basis means it isn't income until paid). 0 for none/0% loans.
    interest_accrued: f64,
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
    // Details of the linked bank transaction (present only for a reconciled
    // row), so the UI can show a rich, tappable payment card.
    #[serde(skip_serializing_if = "Option::is_none")]
    tx_description: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    merchant_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    category: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    account_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tx_amount: Option<f64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    tx_currency: Option<String>,
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
    /// 'annual' (default) or 'monthly' — the period the interest_rate
    /// is expressed in, stored faithfully so "1%/month" stays exact.
    #[serde(default = "default_rate_period")]
    rate_period: String,
    origination_date: chrono::NaiveDate,
    #[serde(default)]
    term_months: Option<i32>,
    #[serde(default)]
    payment_frequency: Option<String>,
    #[serde(default)]
    notes: Option<String>,
    /// Optional explicit "pay back by" date. Independent of term/frequency —
    /// gives even an open-ended, no-interest loan a due date.
    #[serde(default)]
    expected_repayment_date: Option<chrono::NaiveDate>,
}

fn default_interest_type() -> String {
    "none".to_string()
}

fn default_rate_period() -> String {
    "annual".to_string()
}

fn valid_interest_type(t: &str) -> bool {
    matches!(
        t,
        "none" | "simple" | "amortized" | "interest_only" | "compound" | "custom"
    )
}

/// One explicit installment for a CUSTOM schedule upload.
#[derive(Deserialize)]
struct CustomRow {
    due_date: chrono::NaiveDate,
    amount: f64,
}

/// The "first N at first_amount, then amount monthly on day-of-month
/// from start_date through end_date (inclusive)" shorthand for a CUSTOM
/// schedule — expanded server-side into explicit rows.
#[derive(Deserialize)]
struct CustomPattern {
    start_date: chrono::NaiveDate,
    end_date: chrono::NaiveDate,
    /// Day-of-month for the monthly installments; defaults to
    /// start_date's day when omitted.
    #[serde(default)]
    day_of_month: Option<u32>,
    /// How many leading installments use `first_amount`.
    first_count: usize,
    first_amount: f64,
    amount: f64,
}

/// POST /{id}/schedule/custom body: EITHER explicit `rows` OR a
/// `pattern`. Exactly one must be present (validated in the handler).
#[derive(Deserialize)]
struct CustomScheduleRequest {
    #[serde(default)]
    rows: Option<Vec<CustomRow>>,
    #[serde(default)]
    pattern: Option<CustomPattern>,
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
    #[serde(default)]
    expected_repayment_date: Option<chrono::NaiveDate>,
}

#[derive(Deserialize)]
struct LinkTxRequest {
    transaction_id: uuid::Uuid,
}

#[derive(Deserialize)]
struct RecordPaymentRequest {
    /// The inflow transaction designated as a repayment. Optional: when
    /// omitted the payment is a cash/off-bank repayment and `amount` is
    /// required (actual_tx_id stays NULL).
    #[serde(default)]
    transaction_id: Option<uuid::Uuid>,
    /// Amount applied to the loan. Defaults to the tx's amount when a
    /// transaction is linked; required for a cash payment.
    #[serde(default)]
    amount: Option<f64>,
    #[serde(default)]
    paid_date: Option<chrono::NaiveDate>,
}

// ---------- helpers ----------

fn dec_to_f64(d: Option<rust_decimal::Decimal>) -> f64 {
    d.and_then(|v| v.to_string().parse().ok()).unwrap_or(0.0)
}

/// Money with thousands separators, e.g. `fmt_money("MX$", 16000.0)` ->
/// "MX$16,000.00". Comma grouping + dot decimal reads correctly for both
/// English and Mexican Spanish (MXN uses the same convention).
fn fmt_money(sym: &str, x: f64) -> String {
    let neg = x < 0.0;
    let s = format!("{:.2}", x.abs());
    let (int_part, dec) = s.split_once('.').unwrap_or((s.as_str(), "00"));
    let len = int_part.len();
    let mut grouped = String::with_capacity(len + len / 3);
    for (i, c) in int_part.chars().enumerate() {
        if i > 0 && (len - i) % 3 == 0 {
            grouped.push(',');
        }
        grouped.push(c);
    }
    format!("{}{sym}{grouped}.{dec}", if neg { "-" } else { "" })
}

/// Simple interest accrued from origination to today: P · r · t(years).
/// Used for the informational `interest_accrued` ("interest owed so
/// far") figure — NOT for `outstanding`, which is the running principal.
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

/// Interest portion of one repayment (cash-basis interest income),
/// allocated INTEREST-FIRST per the US Rule — no compounding of unpaid
/// interest into principal.
///
///   * Scheduled installment (we know its `scheduled_interest`): the
///     interest portion is min(scheduled_interest, amount) — a full
///     payment realizes the planned interest; a partial payment counts
///     toward interest first.
///   * Open-ended / ad-hoc (no schedule): accrue interest on the
///     outstanding balance at the loan's rate over the days since the
///     last payment, then allocate interest-first. 'none' / 0% → 0.
#[allow(clippy::too_many_arguments)]
fn split_interest_portion(
    amount: f64,
    balance_before: f64,
    scheduled_interest: Option<f64>,
    rate: f64,
    rate_period: &str,
    interest_type: &str,
    last_date: chrono::NaiveDate,
    paid_date: chrono::NaiveDate,
) -> f64 {
    if let Some(si) = scheduled_interest {
        // Interest-first cap: never attribute more interest than was
        // scheduled, nor more than the amount actually paid.
        return si.min(amount).max(0.0);
    }
    if interest_type == "none" || rate <= 0.0 {
        return 0.0;
    }
    // Open-ended accrual: convert to an effective annual rate, accrue
    // simple interest over elapsed days on the outstanding balance.
    let annual = if rate_period == "monthly" {
        rate * 12.0
    } else {
        rate
    };
    let days = (paid_date - last_date).num_days().max(0) as f64;
    let accrued = balance_before * annual * (days / 365.0);
    // Allocate interest-first, capped at the payment.
    accrued.min(amount).max(0.0)
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
    -- A GENERATED schedule sets scheduled_principal > 0 (or, for an
    -- interest-only / custom 0-principal row, scheduled_interest > 0).
    -- Manually-recorded repayments (the MVP path) leave BOTH 0, so they
    -- don't count as a schedule — outstanding for those loans uses the
    -- principal − repaid path instead.
    EXISTS(SELECT 1 FROM loan_payments p
           WHERE p.loan_id = l.id
             AND (p.scheduled_principal > 0 OR p.scheduled_interest > 0)) AS has_schedule,
    -- Σ principal_portion of every PAID payment → the running principal
    -- balance is principal − this (= balance_after of the last payment).
    -- Falls back to the full paid_amount for legacy rows recorded before
    -- the principal/interest split shipped. Keyed on paid_amount (not
    -- actual_tx_id) so cash/off-bank payments — which have no linked
    -- transaction — still reduce the balance; scheduled-but-unpaid rows
    -- have paid_amount NULL and are correctly excluded.
    COALESCE((SELECT SUM(COALESCE(p.principal_portion, p.paid_amount, 0))
              FROM loan_payments p
              WHERE p.loan_id = l.id AND p.paid_amount IS NOT NULL), 0) AS principal_paid,
    -- Earliest unpaid scheduled installment, OR — for a schedule-less but
    -- still-active loan — its explicit expected_repayment_date. "Unpaid" is
    -- keyed on paid_amount, NOT actual_tx_id: a cash/off-bank repayment fills
    -- paid_amount with no linked transaction, and such a fully-paid
    -- installment must NOT keep showing as due/overdue.
    COALESCE(
      (SELECT MIN(p.due_date) FROM loan_payments p
       WHERE p.loan_id = l.id
         AND (p.paid_amount IS NULL OR p.paid_amount < p.scheduled_amount)),
      CASE WHEN l.status = 'active' THEN l.expected_repayment_date END
    ) AS next_due,
    (EXISTS(SELECT 1 FROM loan_payments p
            WHERE p.loan_id = l.id AND p.due_date < CURRENT_DATE
              AND (p.paid_amount IS NULL OR p.paid_amount < p.scheduled_amount))
     OR (l.status = 'active'
         AND l.expected_repayment_date IS NOT NULL
         AND l.expected_repayment_date < CURRENT_DATE
         AND NOT EXISTS(SELECT 1 FROM loan_payments p
                        WHERE p.loan_id = l.id
                          AND (p.scheduled_principal > 0 OR p.scheduled_interest > 0)))
    ) AS overdue,
    -- Σ scheduled_amount billed on or before today (for paid-ahead).
    COALESCE((SELECT SUM(p.scheduled_amount) FROM loan_payments p
              WHERE p.loan_id = l.id AND p.due_date <= CURRENT_DATE), 0) AS cumulative_due,
    -- Cumulative realized interest income (cash basis).
    COALESCE((SELECT SUM(p.interest_portion) FROM loan_payments p
              WHERE p.loan_id = l.id AND p.interest_portion IS NOT NULL), 0) AS interest_earned
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
    let interest_type: String = r
        .try_get("interest_type")
        .unwrap_or_else(|_| "none".to_string());
    let rate_period: String = r
        .try_get("rate_period")
        .unwrap_or_else(|_| "annual".to_string());
    // Effective annual rate for the schedule-less simple-interest
    // approximation — a stored monthly rate is ×12.
    let effective_annual = if rate_period == "monthly" {
        rate * 12.0
    } else {
        rate
    };
    let origination: chrono::NaiveDate = r.try_get("origination_date").unwrap_or(today);
    let status: String = r.try_get("status").unwrap_or_else(|_| "active".to_string());
    let total_repaid = dec_to_f64(r.try_get("total_repaid").ok());
    let total_scheduled = dec_to_f64(r.try_get("total_scheduled").ok());
    let has_schedule: bool = r.try_get("has_schedule").unwrap_or(false);
    let principal_paid = dec_to_f64(r.try_get("principal_paid").ok());
    let cumulative_due = dec_to_f64(r.try_get("cumulative_due").ok());
    let next_due: Option<chrono::NaiveDate> = r.try_get("next_due").ok().flatten();
    let overdue: bool = r.try_get("overdue").unwrap_or(false);

    // Outstanding = remaining PRINCIPAL balance:
    //   * written_off / cancelled / paid_off → 0 (settled).
    //   * else → principal − Σ principal_portion of reconciled payments
    //     (the running balance, == balance_after of the last payment).
    // Accrued-but-unpaid interest is deliberately NOT added here — it's
    // not part of the principal owed and (cash basis) isn't income
    // until received. It's surfaced separately as `interest_accrued`.
    let outstanding = if matches!(status.as_str(), "written_off" | "cancelled" | "paid_off") {
        0.0
    } else {
        (principal - principal_paid).max(0.0)
    };
    // Total still owed = scheduled payments (principal + interest) minus what
    // was repaid, when a schedule exists; else the principal-based
    // outstanding (a no-schedule loan has no scheduled interest).
    let total_owed = if matches!(status.as_str(), "written_off" | "cancelled" | "paid_off") {
        0.0
    } else if has_schedule {
        (total_scheduled - total_repaid).max(0.0)
    } else {
        outstanding
    };
    // Paid-ahead: borrower has repaid more than what's been billed so
    // far (only meaningful with a schedule + something billed).
    let paid_ahead = has_schedule && cumulative_due > 0.0 && total_repaid >= cumulative_due;

    // Accrued-but-unpaid interest (informational, non-income). Simple
    // accrual on the current outstanding balance from origination to
    // today, net of interest already received. Settled loans owe none.
    let interest_earned = dec_to_f64(r.try_get("interest_earned").ok());
    let interest_accrued = if matches!(status.as_str(), "written_off" | "cancelled" | "paid_off") {
        0.0
    } else {
        let gross = accrued_interest(
            outstanding,
            effective_annual,
            &interest_type,
            origination,
            today,
        );
        (gross - interest_earned).max(0.0)
    };

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
        rate_period,
        origination_date: origination.to_string(),
        term_months: r.try_get("term_months").ok().flatten(),
        payment_frequency: r.try_get("payment_frequency").ok().flatten(),
        expected_repayment_date: r
            .try_get::<Option<chrono::NaiveDate>, _>("expected_repayment_date")
            .ok()
            .flatten()
            .map(|d| d.to_string()),
        disbursement_tx_id: r
            .try_get::<Option<uuid::Uuid>, _>("disbursement_tx_id")
            .ok()
            .flatten()
            .map(|u| u.to_string()),
        status,
        notes: r.try_get("notes").ok().flatten(),
        total_repaid,
        outstanding,
        total_owed,
        total_scheduled,
        has_schedule,
        next_due: next_due.map(|d| d.to_string()),
        overdue,
        paid_ahead,
        interest_earned,
        interest_accrued,
    }
}

async fn get_loan(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    let sql =
        format!("SELECT l.*, {LOAN_AGGREGATES} FROM loans l WHERE l.id = $1 AND l.user_id = $2");
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
    if !valid_interest_type(&payload.interest_type) {
        return (StatusCode::BAD_REQUEST, "invalid interest_type").into_response();
    }
    if !matches!(payload.rate_period.as_str(), "annual" | "monthly") {
        return (StatusCode::BAD_REQUEST, "invalid rate_period").into_response();
    }
    // Bound the term so schedule generation can't be asked to allocate a
    // runaway number of installment rows (a process-crash DoS). The DB
    // already enforces `> 0`; this adds the upper bound.
    if let Some(t) = payload.term_months {
        if t <= 0 || t > crate::services::loan_schedule::MAX_TERM_MONTHS {
            return (
                StatusCode::BAD_REQUEST,
                "term_months must be between 1 and 1200",
            )
                .into_response();
        }
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
                           interest_rate, interest_type, rate_period, origination_date,
                           term_months, payment_frequency, notes, expected_repayment_date)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
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
    .bind(&payload.rate_period)
    .bind(payload.origination_date)
    .bind(payload.term_months)
    .bind(&payload.payment_frequency)
    .bind(&payload.notes)
    .bind(payload.expected_repayment_date)
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
        if !valid_interest_type(it) {
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
    // B2(b): validate principal > 0 in Rust so a non-positive value
    // returns a clean 400 instead of surfacing the DB CHECK as a 500
    // (mirrors create_loan).
    if let Some(p) = payload.principal {
        if p <= 0.0 {
            return (StatusCode::BAD_REQUEST, "principal must be positive").into_response();
        }
    }

    // B2(a): does this edit change a schedule-affecting term? If a
    // generated schedule exists, the loans row and the loan_payments
    // schedule would otherwise diverge (total_scheduled / per-row
    // interest / reminders / agreement). We regenerate AFTER the UPDATE
    // below, from the loan's new terms.
    //
    // "Changed" is detected by VALUE, not mere payload presence: the edit
    // dialog re-sends principal/interest_rate/interest_type on every save
    // (pre-filled, unchanged), so a presence-based check would spuriously
    // treat a borrower-name-only edit as a term change — and on a
    // reconciled loan that wrongly 409s and drops the legitimate edit.
    // We compare each submitted value against the stored row instead.
    //
    // Policy for a schedule WITH reconciled payments: REJECT the
    // schedule-affecting edit with 409 (do not silently regenerate, do
    // not leave a stale schedule). This is the safest, least-surprising
    // choice — it matches generate_schedule's existing guard and keeps
    // the Σprincipal == principal invariant intact. The user unreconciles
    // first, edits terms, then re-reconciles. Non-schedule fields
    // (borrower_name, status, notes) are unaffected and always editable.
    let current: Option<(rust_decimal::Decimal, rust_decimal::Decimal, String)> =
        match sqlx::query_as(
            "SELECT principal, interest_rate, interest_type FROM loans \
             WHERE id = $1 AND user_id = $2",
        )
        .bind(id)
        .bind(ctx.user_id)
        .fetch_optional(&state.db)
        .await
        {
            Ok(c) => c,
            Err(e) => {
                error!("update_loan term load failed: {e}");
                return StatusCode::INTERNAL_SERVER_ERROR.into_response();
            }
        };
    let Some((cur_principal, cur_rate, cur_type)) = current else {
        return StatusCode::NOT_FOUND.into_response();
    };
    // Decimal equality is by numeric value (scale-insensitive), and both
    // create_loan and the value below go through from_f64_retain on the
    // same f64, so an unchanged resend compares equal.
    let principal_changed = payload
        .principal
        .and_then(rust_decimal::Decimal::from_f64_retain)
        .is_some_and(|p| p != cur_principal);
    let rate_changed = payload
        .interest_rate
        .and_then(rust_decimal::Decimal::from_f64_retain)
        .is_some_and(|r| r != cur_rate);
    let type_changed = payload
        .interest_type
        .as_deref()
        .is_some_and(|t| t != cur_type);
    let schedule_affecting = principal_changed || rate_changed || type_changed;
    // CUSTOM loans own an explicitly-uploaded schedule that no formula
    // reproduces. Changing principal / rate / interest_type would desync
    // the loans row from those rows (or, if we regenerated, silently
    // destroy them). Refuse the term edit — the user re-uploads the custom
    // schedule to change terms. Status / notes / expected_repayment_date
    // stay editable. (Mirrors the reconciled-loan 409 guard just below.)
    let is_custom = cur_type == "custom" || payload.interest_type.as_deref() == Some("custom");
    if is_custom && schedule_affecting {
        return (
            StatusCode::CONFLICT,
            "custom-schedule loan: re-upload the custom schedule to change terms",
        )
            .into_response();
    }
    if schedule_affecting {
        let reconciled: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM loan_payments \
             WHERE loan_id = $1 AND user_id = $2 AND actual_tx_id IS NOT NULL",
        )
        .bind(id)
        .bind(ctx.user_id)
        .fetch_one(&state.db)
        .await
        .unwrap_or(0);
        if reconciled > 0 {
            return (
                StatusCode::CONFLICT,
                "cannot change loan terms after payments are reconciled — unreconcile them first",
            )
                .into_response();
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
            expected_repayment_date = COALESCE($7, expected_repayment_date),
            updated_at = NOW()
        WHERE id = $8 AND user_id = $9
        "#,
    )
    .bind(payload.borrower_name)
    .bind(
        payload
            .principal
            .and_then(rust_decimal::Decimal::from_f64_retain),
    )
    .bind(
        payload
            .interest_rate
            .and_then(rust_decimal::Decimal::from_f64_retain),
    )
    .bind(payload.interest_type)
    .bind(payload.status)
    .bind(payload.notes)
    .bind(payload.expected_repayment_date)
    .bind(id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;
    match result {
        Ok(r) if r.rows_affected() == 0 => StatusCode::NOT_FOUND.into_response(),
        Ok(_) => {
            // Rebuild the schedule from the new terms IFF one already
            // exists (require_existing=true: don't fabricate a schedule
            // for an MVP loan that never had one). Reconciled loans were
            // already rejected above, so this only ever rebuilds unpaid
            // schedules.
            if schedule_affecting {
                match regenerate_schedule(&state.db, id, ctx.user_id, true).await {
                    RegenOutcome::Regenerated(_) | RegenOutcome::NoSchedule => {}
                    RegenOutcome::Reconciled => {
                        // Guarded above; treat as a conflict if it races.
                        return (
                            StatusCode::CONFLICT,
                            "cannot change loan terms after payments are reconciled — unreconcile them first",
                        )
                            .into_response();
                    }
                    // The UPDATE above already changed this loan's row, so
                    // NotFound can't happen here; fold it in defensively.
                    RegenOutcome::NotFound => return StatusCode::NOT_FOUND.into_response(),
                    // The loan still has a schedule but the new terms make
                    // it open-ended / invalid — shouldn't happen via this
                    // path (term/frequency aren't editable here), so log
                    // and report a server error rather than corrupt state.
                    // Custom loans are guarded out above (is_custom &&
                    // schedule_affecting → 409), so this is unreachable;
                    // fold it into the defensive server-error arm.
                    RegenOutcome::OpenEnded
                    | RegenOutcome::BadFrequency
                    | RegenOutcome::Custom
                    | RegenOutcome::DbError => {
                        error!("update_loan schedule regen failed for loan {id}");
                        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
                    }
                }
            }
            StatusCode::OK.into_response()
        }
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
    // Per-currency breakdown: summing USD + MXN principal into one number is
    // meaningless (the ~18x-overstatement bug class). Keep the flat totals
    // for backward compat but label them, and expose a per-currency map plus
    // a single `totals_currency` when every loan shares one — mirrors the
    // interest_income response so the UI can convert/label safely.
    let mut by_currency: std::collections::BTreeMap<String, (f64, f64)> =
        std::collections::BTreeMap::new();
    for r in &rows {
        let v = loan_view(r, today);
        total_lent += v.principal;
        total_outstanding += v.outstanding;
        let entry = by_currency.entry(v.currency.clone()).or_insert((0.0, 0.0));
        entry.0 += v.principal;
        entry.1 += v.outstanding;
        if v.status == "active" {
            active += 1;
        }
    }
    let totals_by_currency: Vec<serde_json::Value> = by_currency
        .iter()
        .map(|(cur, (lent, outstanding))| {
            serde_json::json!({
                "currency": cur,
                "total_lent": lent,
                "total_outstanding": outstanding,
            })
        })
        .collect();
    let totals_currency: Option<&String> = match by_currency.len() {
        1 => by_currency.keys().next(),
        _ => None,
    };
    Json(serde_json::json!({
        "loan_count": rows.len(),
        "active_count": active,
        // Legacy naive cross-currency sums (backward compat). Prefer
        // `totals_by_currency` when `totals_currency` is null (mixed).
        "total_lent": total_lent,
        "total_outstanding": total_outstanding,
        "totals_by_currency": totals_by_currency,
        "totals_currency": totals_currency,
    }))
}

async fn list_people(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<PersonView>> {
    // Per-person aggregates so the UI can show "lent 3 times, $1,200
    // outstanding". Outstanding is principal − principal repaid; the
    // interest portion of each payment is income, not a reduction of the
    // amount owed, so it must NOT count against principal here.
    let rows = sqlx::query(
        r#"
        SELECT pe.id, pe.name, pe.note,
               COUNT(l.id) AS loan_count,
               COALESCE(SUM(
                   GREATEST(l.principal - COALESCE((
                       SELECT SUM(COALESCE(p.principal_portion, p.paid_amount, 0))
                       FROM loan_payments p
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
    let row = sqlx::query(
        "SELECT currency, date, amount FROM transactions WHERE id = $1 AND user_id = $2",
    )
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
    let Some((tx_currency, _tx_date, _tx_amount)) =
        owned_tx(&state, ctx.user_id, payload.transaction_id).await
    else {
        return StatusCode::NOT_FOUND.into_response();
    };
    // The funding tx must be in the loan's currency — lending out MXN
    // principal is an MXN outflow. A mismatched currency would link a tx
    // whose amount doesn't correspond to the principal.
    let loan_currency: Option<String> =
        sqlx::query_scalar("SELECT currency FROM loans WHERE id = $1 AND user_id = $2")
            .bind(id)
            .bind(ctx.user_id)
            .fetch_optional(&state.db)
            .await
            .ok()
            .flatten();
    let Some(loan_currency) = loan_currency else {
        return StatusCode::NOT_FOUND.into_response();
    };
    if !loan_currency.is_empty() && !tx_currency.eq_ignore_ascii_case(&loan_currency) {
        return (
            StatusCode::BAD_REQUEST,
            "transaction currency does not match the loan currency",
        )
            .into_response();
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
        "SELECT p.*, \
                t.description AS tx_description, t.merchant_name AS tx_merchant, \
                t.category AS tx_category, t.amount AS tx_amount, t.currency AS tx_currency, \
                COALESCE(NULLIF(a.nickname, ''), a.name) AS tx_account_name \
         FROM loan_payments p \
         LEFT JOIN transactions t ON t.id = p.actual_tx_id \
         LEFT JOIN accounts a ON a.id = t.account_id \
         WHERE p.loan_id = $1 AND p.user_id = $2 \
         ORDER BY p.installment_number ASC",
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
                status: r
                    .try_get("status")
                    .unwrap_or_else(|_| "scheduled".to_string()),
                tx_description: r
                    .try_get::<Option<String>, _>("tx_description")
                    .ok()
                    .flatten(),
                merchant_name: r.try_get::<Option<String>, _>("tx_merchant").ok().flatten(),
                category: r.try_get::<Option<String>, _>("tx_category").ok().flatten(),
                account_name: r
                    .try_get::<Option<String>, _>("tx_account_name")
                    .ok()
                    .flatten(),
                tx_amount: r
                    .try_get::<Option<rust_decimal::Decimal>, _>("tx_amount")
                    .ok()
                    .flatten()
                    .and_then(|d| d.to_string().parse().ok()),
                tx_currency: r.try_get::<Option<String>, _>("tx_currency").ok().flatten(),
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
    let owns = sqlx::query("SELECT currency FROM loans WHERE id = $1 AND user_id = $2")
        .bind(id)
        .bind(ctx.user_id)
        .fetch_optional(&state.db)
        .await;
    let Ok(Some(loan_meta)) = owns else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let loan_currency: String = loan_meta.try_get("currency").unwrap_or_default();
    let today = chrono::Utc::now().date_naive();
    // Two modes: link a real bank inflow, or record a cash/off-bank
    // payment (no tx). The amount defaults to the linked tx's magnitude;
    // a cash payment must state its amount.
    let (amount, paid_date) = match payload.transaction_id {
        Some(tx_id) => {
            let Some((tx_currency, tx_date, tx_amount)) =
                owned_tx(&state, ctx.user_id, tx_id).await
            else {
                return StatusCode::NOT_FOUND.into_response();
            };
            // A repayment must be in the loan's currency. Reconciling a
            // foreign-currency inflow would silently record the wrong
            // amount (e.g. a $500 USD inflow against an MXN loan).
            if !loan_currency.is_empty() && !tx_currency.eq_ignore_ascii_case(&loan_currency) {
                return (
                    StatusCode::BAD_REQUEST,
                    "transaction currency does not match the loan currency",
                )
                    .into_response();
            }
            (
                payload.amount.unwrap_or(tx_amount.abs()),
                payload.paid_date.unwrap_or(tx_date),
            )
        }
        None => {
            let Some(amt) = payload.amount.filter(|a| *a > 0.0) else {
                return (
                    StatusCode::BAD_REQUEST,
                    "a cash payment requires a positive amount",
                )
                    .into_response();
            };
            (amt, payload.paid_date.unwrap_or(today))
        }
    };

    // Loan terms + running state needed to split this payment into
    // principal vs interest (cash-basis interest income).
    let loan = sqlx::query(
        r#"
        SELECT l.principal, l.interest_rate, l.interest_type, l.rate_period,
               l.origination_date,
               COALESCE((SELECT SUM(p.principal_portion) FROM loan_payments p
                         WHERE p.loan_id = l.id AND p.principal_portion IS NOT NULL), 0)
                   AS principal_paid,
               (SELECT MAX(p.paid_date) FROM loan_payments p
                WHERE p.loan_id = l.id AND p.paid_date IS NOT NULL) AS last_paid
        FROM loans l WHERE l.id = $1 AND l.user_id = $2
        "#,
    )
    .bind(id)
    .bind(ctx.user_id)
    .fetch_one(&state.db)
    .await;
    let Ok(loan) = loan else {
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    };
    let principal = dec_to_f64(loan.try_get("principal").ok());
    let rate = dec_to_f64(loan.try_get("interest_rate").ok());
    let interest_type: String = loan
        .try_get("interest_type")
        .unwrap_or_else(|_| "none".to_string());
    let rate_period: String = loan
        .try_get("rate_period")
        .unwrap_or_else(|_| "annual".to_string());
    let origination: chrono::NaiveDate = loan.try_get("origination_date").unwrap_or(paid_date);
    let principal_paid = dec_to_f64(loan.try_get("principal_paid").ok());
    let last_paid: Option<chrono::NaiveDate> = loan.try_get("last_paid").ok().flatten();
    let balance_before = (principal - principal_paid).max(0.0);

    // If a GENERATED schedule exists (rows with scheduled_principal > 0),
    // fill the earliest NOT-YET-FULLY-PAID scheduled installment rather
    // than appending a new row — that's what makes the schedule-aware
    // outstanding (principal − Σ paid scheduled_principal) decrease.
    //
    // B1 fix: we key off "not fully paid" (status in scheduled/partial/
    // late AND paid_amount < scheduled_amount), NOT off actual_tx_id IS
    // NULL. A partial payment leaves the row with status='partial' and
    // (when tx-linked) a non-NULL actual_tx_id; the old NULL-keyed
    // selector skipped that row, so the NEXT payment filled installment
    // k+1 and stranded k's remainder. Now the remainder is topped up on
    // the same row.
    //
    // Multi-tx-per-installment constraint: the partial unique index
    // idx_loan_payments_actual_tx allows only ONE actual_tx_id per row,
    // and DELETE /payments/{id} unreconciles by deleting the whole row.
    // We therefore cannot attach a SECOND bank tx to a row that already
    // carries one without breaking the one-tx-per-row + unreconcile
    // model. The minimal correct behaviour: top up paid_amount/splits in
    // place and only adopt the incoming tx_id when the row has none yet
    // (cash top-up, or the first reconciliation). A row's actual_tx_id is
    // thus "the first reconciled tx"; the running balance stays correct
    // regardless. (A future schema with a child loan_payment_txs table
    // could store every tx — out of scope here.)
    //
    // Overpay-spill (this loop): a payment that EXCEEDS the current
    // installment's remaining scheduled_amount now SPILLS the surplus
    // onto the next not-fully-paid installment(s), in installment_number
    // order, inside ONE write transaction. We walk the schedule applying
    // min(remaining, installment_remaining) to each row, splitting each
    // slice interest-first against THAT row's remaining scheduled
    // interest, flipping it paid/partial, until the money runs out or the
    // schedule is exhausted. Any surplus beyond the whole schedule falls
    // back to the no-schedule branch (append a manual 'paid' repayment
    // row). tx-id placement: the linked bank tx attaches to the FIRST
    // installment this payment touches; spilled slices on later rows
    // carry NO actual_tx_id (cash-style top-ups). That keeps the
    // one-tx-per-row + whole-row-delete model intact — DELETE-ing the
    // first row unreconciles exactly the bank tx, as today.
    // Every not-fully-paid scheduled installment, earliest first. We walk
    // this list spilling the payment across rows. (Same predicate as the
    // old single-row selector, just without LIMIT 1.)
    let scheduled_rows: Vec<(uuid::Uuid, f64, f64, f64, f64, bool)> = sqlx::query(
        "SELECT id, scheduled_amount, scheduled_interest, \
                COALESCE(paid_amount, 0) AS paid_so_far, \
                COALESCE(interest_portion, 0) AS interest_so_far, \
                actual_tx_id \
         FROM loan_payments \
         WHERE loan_id = $1 AND (scheduled_principal > 0 OR scheduled_interest > 0) \
           AND (paid_amount IS NULL OR paid_amount < scheduled_amount) \
           AND status <> 'skipped' \
         ORDER BY installment_number ASC",
    )
    .bind(id)
    .fetch_all(&state.db)
    .await
    .map(|rows| {
        rows.into_iter()
            .map(|r| {
                (
                    r.get::<uuid::Uuid, _>("id"),
                    dec_to_f64(r.try_get("scheduled_amount").ok()),
                    dec_to_f64(r.try_get("scheduled_interest").ok()),
                    dec_to_f64(r.try_get("paid_so_far").ok()),
                    dec_to_f64(r.try_get("interest_so_far").ok()),
                    r.try_get::<Option<uuid::Uuid>, _>("actual_tx_id")
                        .ok()
                        .flatten()
                        .is_some(),
                )
            })
            .collect()
    })
    .unwrap_or_default();

    // Apply the whole payment in ONE transaction so a mid-spill failure
    // rolls back cleanly. `remaining` is the still-unallocated cash;
    // `running_balance` is the loan's running principal (principal − Σ
    // principal_portion), threaded through each slice so balance_after on
    // every touched row is exact. `tx_used` tracks whether the bank tx has
    // already been attached — it lands on the FIRST row we touch only.
    let mut tx_conn = match state.db.begin().await {
        Ok(t) => t,
        Err(e) => {
            error!("record_payment begin failed: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };
    let mut remaining = amount;
    let mut running_balance = balance_before;
    let mut tx_used = false;
    let mut last_interest_date = last_paid.unwrap_or(origination);

    let result: Result<(), sqlx::Error> = async {
        for (row_id, sched_amount, sched_interest, paid_so_far, interest_so_far, has_tx) in
            scheduled_rows
        {
            if remaining <= MONEY_EPSILON {
                break;
            }
            // How much of THIS installment is still owed, and the slice of
            // the payment we apply to it.
            let row_remaining = (sched_amount - paid_so_far).max(0.0);
            if row_remaining <= MONEY_EPSILON {
                continue;
            }
            let slice = remaining.min(row_remaining);

            // Interest-first split against THIS row's REMAINING scheduled
            // interest (scheduled_interest already realized on prior
            // top-ups of the same row), then ADD to its existing portions.
            let row_scheduled_interest = (sched_interest - interest_so_far).max(0.0);
            let interest_portion = split_interest_portion(
                slice,
                running_balance,
                Some(row_scheduled_interest),
                rate,
                &rate_period,
                &interest_type,
                last_interest_date,
                paid_date,
            );
            let principal_portion = (slice - interest_portion).max(0.0);
            running_balance = (running_balance - principal_portion).max(0.0);

            // The bank tx attaches to the FIRST row only; later (spilled)
            // rows that don't already carry a tx stay NULL (cash-style).
            let tx_for_row = if has_tx {
                None
            } else if !tx_used {
                tx_used = true;
                payload.transaction_id
            } else {
                None
            };

            sqlx::query(
                r#"
                UPDATE loan_payments
                SET actual_tx_id = COALESCE(actual_tx_id, $1),
                    paid_amount = COALESCE(paid_amount, 0) + $2,
                    paid_date = $3,
                    principal_portion = COALESCE(principal_portion, 0) + $4,
                    interest_portion = COALESCE(interest_portion, 0) + $5,
                    balance_after = $6,
                    status = CASE WHEN COALESCE(paid_amount, 0) + $2 >= scheduled_amount
                                  THEN 'paid' ELSE 'partial' END
                WHERE id = $7 AND user_id = $8
                "#,
            )
            .bind(tx_for_row)
            .bind(cents(slice))
            .bind(paid_date)
            .bind(cents(principal_portion))
            .bind(cents(interest_portion))
            .bind(cents(running_balance))
            .bind(row_id)
            .bind(ctx.user_id)
            .execute(&mut *tx_conn)
            .await?;

            remaining -= slice;
            last_interest_date = paid_date;
        }

        // Surplus beyond the whole schedule (or a loan with no generated
        // schedule at all): append a manual 'paid' repayment row for the
        // leftover, exactly as the old no-schedule branch did. Open-ended
        // accrual (no scheduled_interest) handles its own interest-first
        // split here.
        if remaining > MONEY_EPSILON {
            let interest_portion = split_interest_portion(
                remaining,
                running_balance,
                None,
                rate,
                &rate_period,
                &interest_type,
                last_interest_date,
                paid_date,
            );
            let principal_portion = (remaining - interest_portion).max(0.0);
            running_balance = (running_balance - principal_portion).max(0.0);
            let tx_for_row = if tx_used { None } else { payload.transaction_id };

            let next: i32 = sqlx::query_scalar(
                "SELECT COALESCE(MAX(installment_number), 0) + 1 FROM loan_payments WHERE loan_id = $1",
            )
            .bind(id)
            .fetch_one(&mut *tx_conn)
            .await
            .unwrap_or(1);
            sqlx::query(
                r#"
                INSERT INTO loan_payments
                    (user_id, loan_id, installment_number, scheduled_amount,
                     actual_tx_id, paid_amount, paid_date,
                     principal_portion, interest_portion, balance_after, status)
                VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, 'paid')
                "#,
            )
            .bind(ctx.user_id)
            .bind(id)
            .bind(next)
            .bind(cents(remaining))
            .bind(tx_for_row)
            .bind(cents(remaining))
            .bind(paid_date)
            .bind(cents(principal_portion))
            .bind(cents(interest_portion))
            .bind(cents(running_balance))
            .execute(&mut *tx_conn)
            .await?;
        }
        Ok(())
    }
    .await;

    let result = match result {
        Ok(()) => tx_conn.commit().await.map(|_| ()),
        Err(e) => {
            let _ = tx_conn.rollback().await;
            Err(e)
        }
    };

    match result {
        Ok(_) => {
            // Auto-mark the loan paid_off once the PRINCIPAL is fully repaid.
            // Compare against summed principal_portion (return of capital), not
            // paid_amount — otherwise interest payments push the total over
            // principal and the loan is marked paid_off while capital is still
            // outstanding.
            let _ = sqlx::query(
                r#"
                UPDATE loans SET status = 'paid_off', updated_at = NOW()
                WHERE id = $1 AND user_id = $2 AND status = 'active'
                  AND principal <= COALESCE((
                      SELECT SUM(COALESCE(principal_portion, paid_amount, 0))
                      FROM loan_payments
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

/// POST /{id}/payments/{payment_id}/attach-tx — "upgrade" an off-bank
/// installment to a bank-linked one.
///
/// When a repayment is marked paid before the bank statement lands, the
/// installment carries `paid_amount` (the recorded cash) but `actual_tx_id
/// IS NULL`. `record_payment` deliberately skips fully-paid rows, so a
/// later attempt to reconcile the real inflow would SPILL onto the next
/// installment and double-count. This endpoint instead attaches the now-
/// imported tx to the SAME row: it keeps the recorded `paid_amount` and
/// principal/interest split untouched (no recompute) and only sets
/// `actual_tx_id` + `paid_date`. Linking matters beyond bookkeeping —
/// loan-linked transactions are excluded from cash-flow/income, so
/// attaching the real deposit stops it from inflating income.
async fn attach_payment_tx(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path((id, payment_id)): Path<(uuid::Uuid, uuid::Uuid)>,
    Json(payload): Json<LinkTxRequest>,
) -> impl IntoResponse {
    // 1. Loan must belong to the caller; keep its currency for the guard.
    let loan_currency: Option<String> =
        sqlx::query_scalar("SELECT currency FROM loans WHERE id = $1 AND user_id = $2")
            .bind(id)
            .bind(ctx.user_id)
            .fetch_optional(&state.db)
            .await
            .ok()
            .flatten();
    let Some(loan_currency) = loan_currency else {
        return StatusCode::NOT_FOUND.into_response();
    };

    // 2. Load the target installment (scoped to this loan + user).
    let payment = sqlx::query(
        "SELECT paid_amount, actual_tx_id FROM loan_payments \
         WHERE id = $1 AND loan_id = $2 AND user_id = $3",
    )
    .bind(payment_id)
    .bind(id)
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await;
    let Ok(Some(payment)) = payment else {
        return StatusCode::NOT_FOUND.into_response();
    };

    // 3. Only an OFF-BANK recorded payment can be upgraded: it must have a
    //    recorded amount and no tx yet. Distinguish the two failure modes.
    let paid_amount: Option<rust_decimal::Decimal> = payment
        .try_get::<Option<rust_decimal::Decimal>, _>("paid_amount")
        .ok()
        .flatten();
    let already_linked: Option<uuid::Uuid> = payment
        .try_get::<Option<uuid::Uuid>, _>("actual_tx_id")
        .ok()
        .flatten();
    if paid_amount.is_none() {
        return (StatusCode::CONFLICT, "payment has no recorded amount").into_response();
    }
    if already_linked.is_some() {
        return (
            StatusCode::CONFLICT,
            "payment already linked to a transaction",
        )
            .into_response();
    }

    // 4. The incoming tx must belong to the caller.
    let Some((tx_currency, tx_date, _tx_amount)) =
        owned_tx(&state, ctx.user_id, payload.transaction_id).await
    else {
        return StatusCode::NOT_FOUND.into_response();
    };

    // 5. Currency guard (mirrors record_payment): a foreign-currency inflow
    //    would misrepresent the loan's recorded repayment.
    if !loan_currency.is_empty() && !tx_currency.eq_ignore_ascii_case(&loan_currency) {
        return (
            StatusCode::BAD_REQUEST,
            "transaction currency does not match the loan currency",
        )
            .into_response();
    }

    // 6. Attach the tx + adopt its date. Keep paid_amount and the split as
    //    recorded. The partial unique index idx_loan_payments_actual_tx
    //    rejects a tx already linked elsewhere → 409.
    let result = sqlx::query(
        "UPDATE loan_payments SET actual_tx_id = $1, paid_date = $2 \
         WHERE id = $3 AND user_id = $4",
    )
    .bind(payload.transaction_id)
    .bind(tx_date)
    .bind(payment_id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;
    match result {
        Ok(r) if r.rows_affected() == 0 => StatusCode::NOT_FOUND.into_response(),
        Ok(_) => {
            // Re-exclude the newly-linked deposit from cash flow.
            state
                .realtime
                .publish(
                    ctx.user_id,
                    crate::services::realtime::RealtimeEvent::TransactionsChanged,
                )
                .await;
            StatusCode::OK.into_response()
        }
        Err(sqlx::Error::Database(e)) if e.is_unique_violation() => (
            StatusCode::CONFLICT,
            "transaction already linked to another loan payment",
        )
            .into_response(),
        Err(e) => {
            error!("attach_payment_tx failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
}

async fn unreconcile_payment(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(payment_id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    // A row that belongs to a generated schedule (scheduled_principal > 0,
    // OR scheduled_interest > 0 for an interest-only / custom 0-principal
    // row) must NOT be deleted — that would gap the schedule. Reverting it
    // to 'scheduled' clears the actuals while keeping the installment. Only
    // standalone payment rows (cash/off-bank or overflow inserts, both
    // scheduled columns 0) are deleted outright.
    let row = sqlx::query(
        "SELECT scheduled_principal, scheduled_interest \
         FROM loan_payments WHERE id = $1 AND user_id = $2",
    )
    .bind(payment_id)
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await;
    let is_schedule_row = match row {
        Ok(Some(r)) => {
            dec_to_f64(r.try_get("scheduled_principal").ok()) > 0.0
                || dec_to_f64(r.try_get("scheduled_interest").ok()) > 0.0
        }
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(e) => {
            error!("unreconcile_payment lookup failed: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };
    let result = if is_schedule_row {
        sqlx::query(
            "UPDATE loan_payments
                SET actual_tx_id = NULL,
                    paid_amount = NULL,
                    paid_date = NULL,
                    principal_portion = NULL,
                    interest_portion = NULL,
                    balance_after = NULL,
                    status = 'scheduled'
              WHERE id = $1 AND user_id = $2",
        )
        .bind(payment_id)
        .bind(ctx.user_id)
        .execute(&state.db)
        .await
    } else {
        sqlx::query("DELETE FROM loan_payments WHERE id = $1 AND user_id = $2")
            .bind(payment_id)
            .bind(ctx.user_id)
            .execute(&state.db)
            .await
    };
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
    let origination: chrono::NaiveDate = l
        .try_get("origination_date")
        .unwrap_or(chrono::Utc::now().date_naive());
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
    let origination: chrono::NaiveDate = l
        .try_get("origination_date")
        .unwrap_or(chrono::Utc::now().date_naive());
    let borrower: String = l.try_get("borrower_name").unwrap_or_default();
    let term_months: Option<i32> = l.try_get("term_months").ok().flatten();
    // Repayments are searched from the disbursement date (or origination
    // if not yet linked) up to the term horizon (or +18 months default).
    let disbursement_date: chrono::NaiveDate = l
        .try_get::<Option<chrono::NaiveDate>, _>("disbursement_date")
        .ok()
        .flatten()
        .unwrap_or(origination);
    // Clamp before the date arithmetic: `NaiveDate + Duration` panics when
    // pushed past chrono's max year, and a legacy row could hold a huge
    // term_months (new ones are bounded at create). MAX_TERM_MONTHS worth
    // of days stays well inside range.
    let horizon_months = term_months
        .unwrap_or(18)
        .clamp(1, crate::services::loan_schedule::MAX_TERM_MONTHS) as i64;
    let horizon = disbursement_date + chrono::Duration::days(horizon_months * 31 + 30);

    // Expected installment: the REMAINING amount on the earliest not-fully-
    // paid installment from the generated schedule. Using `scheduled_amount -
    // paid_amount` (rather than skipping any reconciled row via
    // `actual_tx_id IS NULL`) means a partially-paid installment still scores
    // against what's left on IT, not the next installment's full amount. Falls
    // back to principal/term when no schedule exists, and to None (no-schedule
    // matcher mode) when there's no term either.
    let next_scheduled: Option<rust_decimal::Decimal> = sqlx::query_scalar(
        "SELECT scheduled_amount - COALESCE(paid_amount, 0) FROM loan_payments \
         WHERE loan_id = $1 AND scheduled_amount > 0 \
         AND COALESCE(paid_amount, 0) < scheduled_amount \
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

    // Outstanding balance = principal minus everything already reconciled.
    // In no-schedule mode this lets a single lump-sum payoff be suggested
    // even with a terse, nameless bank description (a common IOU shape).
    let paid_so_far: Option<rust_decimal::Decimal> = sqlx::query_scalar(
        "SELECT COALESCE(SUM(paid_amount), 0) FROM loan_payments WHERE loan_id = $1",
    )
    .bind(id)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten();
    let outstanding = principal - dec_to_f64(paid_so_far);
    let lump_sum_target = Some(outstanding).filter(|a| *a > 0.0);

    match loan_match::suggest_repayments(
        &state.db,
        ctx.user_id,
        &currency,
        disbursement_date,
        horizon,
        &borrower,
        installment,
        lump_sum_target,
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

/// Outcome of an attempt to (re)build a loan's amortization schedule via
/// the shared [`regenerate_schedule`] helper.
enum RegenOutcome {
    /// Schedule rebuilt; carries the installment count.
    Regenerated(usize),
    /// The loan had no generated schedule yet — nothing to rebuild. (The
    /// caller decides whether that's fine, e.g. update_loan on an MVP
    /// loan with only manually-recorded payments.)
    NoSchedule,
    /// At least one installment is already reconciled — refused, since a
    /// rebuild would re-split paid rows and break Σprincipal == principal.
    Reconciled,
    /// Loan is open-ended (no term / payment_frequency).
    OpenEnded,
    /// payment_frequency is set but invalid.
    BadFrequency,
    /// The loan is a CUSTOM (explicit-row) schedule — the formula
    /// (re)builder refuses to touch it so it can't clobber the uploaded
    /// rows. Callers route to POST /schedule/custom instead.
    Custom,
    /// The loan doesn't exist (or isn't this user's) — maps to 404, not
    /// 500, so POST /schedule on a bad id behaves like the other handlers.
    NotFound,
    /// A DB error occurred.
    DbError,
}

/// Shared schedule (re)builder used by both `generate_schedule` (the
/// POST /schedule endpoint) and `update_loan` (when a schedule-affecting
/// term changes). Computes the schedule from the loan's CURRENT terms and
/// upserts the rows in one transaction.
///
/// Guard: refuses (returns `Reconciled`) if any installment is already
/// reconciled — a rebuild with changed terms would re-split paid rows and
/// break the Σprincipal == principal invariant. `require_existing` =
/// true makes the helper a no-op (`NoSchedule`) when the loan has no
/// generated schedule yet, which is what update_loan wants: editing the
/// principal of an MVP loan that never had a schedule shouldn't fabricate
/// one.
async fn regenerate_schedule(
    db: &sqlx::PgPool,
    loan_id: uuid::Uuid,
    user_id: uuid::Uuid,
    require_existing: bool,
) -> RegenOutcome {
    let loan = sqlx::query(
        "SELECT principal, interest_rate, interest_type, rate_period, origination_date, \
                term_months, payment_frequency \
         FROM loans WHERE id = $1 AND user_id = $2",
    )
    .bind(loan_id)
    .bind(user_id)
    .fetch_optional(db)
    .await;
    let l = match loan {
        Ok(Some(l)) => l,
        Ok(None) => return RegenOutcome::NotFound,
        Err(e) => {
            error!("regenerate_schedule loan load failed: {e}");
            return RegenOutcome::DbError;
        }
    };

    if require_existing {
        let has_schedule: bool = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM loan_payments \
             WHERE loan_id = $1 AND (scheduled_principal > 0 OR scheduled_interest > 0))",
        )
        .bind(loan_id)
        .fetch_one(db)
        .await
        .unwrap_or(false);
        if !has_schedule {
            return RegenOutcome::NoSchedule;
        }
    }

    // Refuse if any payment is already reconciled.
    let reconciled: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM loan_payments WHERE loan_id = $1 AND actual_tx_id IS NOT NULL",
    )
    .bind(loan_id)
    .fetch_one(db)
    .await
    .unwrap_or(0);
    if reconciled > 0 {
        return RegenOutcome::Reconciled;
    }

    let principal: rust_decimal::Decimal = l.try_get("principal").unwrap_or_default();
    let rate: rust_decimal::Decimal = l.try_get("interest_rate").unwrap_or_default();
    let interest_type: String = l
        .try_get("interest_type")
        .unwrap_or_else(|_| "none".to_string());
    // CUSTOM schedules are uploaded explicitly, never derived from terms.
    // The formula builder must never touch them (that would replace the
    // uploaded rows with an equal-principal 'none' schedule).
    if interest_type == "custom" {
        return RegenOutcome::Custom;
    }
    let rate_period: String = l
        .try_get("rate_period")
        .unwrap_or_else(|_| "annual".to_string());
    let origination: chrono::NaiveDate = match l.try_get("origination_date") {
        Ok(d) => d,
        Err(_) => return RegenOutcome::DbError,
    };
    let term_months: Option<i32> = l.try_get("term_months").ok().flatten();
    let payment_frequency: Option<String> = l.try_get("payment_frequency").ok().flatten();

    let rows = match crate::services::loan_schedule::generate(
        principal,
        rate,
        &rate_period,
        &interest_type,
        origination,
        term_months,
        payment_frequency.as_deref(),
    ) {
        Ok(r) => r,
        Err(crate::services::loan_schedule::ScheduleError::OpenEnded) => {
            return RegenOutcome::OpenEnded;
        }
        Err(crate::services::loan_schedule::ScheduleError::BadFrequency) => {
            return RegenOutcome::BadFrequency;
        }
        Err(crate::services::loan_schedule::ScheduleError::TermTooLong) => {
            // Legacy loan with an out-of-range term (new ones are rejected
            // at create). Treat like a bad frequency: a 400, not a rebuild.
            return RegenOutcome::BadFrequency;
        }
    };

    // One transaction: clear unpaid rows then upsert each generated row.
    // (No reconciled rows exist — we checked above — so a blanket delete
    // of unpaid rows is safe and simplest.)
    let mut tx = match db.begin().await {
        Ok(t) => t,
        Err(e) => {
            error!("regenerate_schedule begin failed: {e}");
            return RegenOutcome::DbError;
        }
    };
    match persist_schedule_rows(&mut tx, loan_id, user_id, &rows, principal).await {
        Ok(_) => {}
        Err(e) => {
            error!("regenerate_schedule persist failed: {e}");
            return RegenOutcome::DbError;
        }
    }
    if let Err(e) = tx.commit().await {
        error!("regenerate_schedule commit failed: {e}");
        return RegenOutcome::DbError;
    }
    RegenOutcome::Regenerated(rows.len())
}

/// Clear the loan's unpaid installments (reconciled rows are left alone)
/// and upsert `rows` as the schedule, in the caller's transaction. Shared
/// by `regenerate_schedule` (formula schedules) and `set_custom_schedule`
/// (explicit CUSTOM rows) so both write identical SQL. `balance_after` is
/// the running principal balance after each row (principal − cumulative
/// principal); by the tail-absorbs-residual invariant it closes to
/// exactly 0 on the final row. Returns the number of rows written.
async fn persist_schedule_rows(
    tx: &mut sqlx::Transaction<'_, sqlx::Postgres>,
    loan_id: uuid::Uuid,
    user_id: uuid::Uuid,
    rows: &[crate::services::loan_schedule::ScheduleRow],
    principal: rust_decimal::Decimal,
) -> Result<usize, sqlx::Error> {
    sqlx::query("DELETE FROM loan_payments WHERE loan_id = $1 AND actual_tx_id IS NULL")
        .bind(loan_id)
        .execute(&mut **tx)
        .await?;
    let mut balance = principal;
    for row in rows {
        balance -= row.principal;
        sqlx::query(
            r#"
            INSERT INTO loan_payments
                (user_id, loan_id, installment_number, due_date,
                 scheduled_amount, scheduled_principal, scheduled_interest,
                 balance_after, status)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, 'scheduled')
            ON CONFLICT (loan_id, installment_number) DO UPDATE SET
                due_date = EXCLUDED.due_date,
                scheduled_amount = EXCLUDED.scheduled_amount,
                scheduled_principal = EXCLUDED.scheduled_principal,
                scheduled_interest = EXCLUDED.scheduled_interest,
                balance_after = EXCLUDED.balance_after,
                status = 'scheduled'
            "#,
        )
        .bind(user_id)
        .bind(loan_id)
        .bind(row.installment_number)
        .bind(row.due_date)
        .bind(row.amount)
        .bind(row.principal)
        .bind(row.interest)
        .bind(balance)
        .execute(&mut **tx)
        .await?;
    }
    Ok(rows.len())
}

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
    match regenerate_schedule(&state.db, id, ctx.user_id, false).await {
        RegenOutcome::Regenerated(n) => (
            StatusCode::CREATED,
            Json(serde_json::json!({"installments": n})),
        )
            .into_response(),
        RegenOutcome::NoSchedule => {
            // require_existing=false above, so this is unreachable here;
            // an empty schedule still produces Regenerated(0).
            (
                StatusCode::CREATED,
                Json(serde_json::json!({"installments": 0})),
            )
                .into_response()
        }
        RegenOutcome::Reconciled => (
            StatusCode::CONFLICT,
            "cannot regenerate schedule: payments already reconciled — unreconcile them first",
        )
            .into_response(),
        RegenOutcome::OpenEnded => (
            StatusCode::UNPROCESSABLE_ENTITY,
            "loan has no term / payment frequency — set both to generate a schedule",
        )
            .into_response(),
        RegenOutcome::BadFrequency => (
            StatusCode::UNPROCESSABLE_ENTITY,
            "invalid payment frequency",
        )
            .into_response(),
        RegenOutcome::Custom => (
            StatusCode::UNPROCESSABLE_ENTITY,
            "custom-schedule loan: use POST /schedule/custom",
        )
            .into_response(),
        RegenOutcome::NotFound => StatusCode::NOT_FOUND.into_response(),
        RegenOutcome::DbError => StatusCode::INTERNAL_SERVER_ERROR.into_response(),
    }
}

/// Upload a CUSTOM, explicit-row payment schedule: arbitrary
/// {due_date, amount} installments that no interest formula produces
/// (e.g. a 0% loan whose N payments sum to principal, with a one-off
/// bump). Body carries EITHER explicit `rows` OR a `pattern` shorthand —
/// exactly one. Flips the loan to interest_type='custom' and clears
/// term_months / payment_frequency (they no longer describe the plan),
/// then persists the rows via the shared `persist_schedule_rows`.
///
/// 404 unknown loan, 400 if neither/both of rows|pattern, 409 if any
/// installment is already reconciled (as generate_schedule), 422 on an
/// empty schedule or Σamount < principal (would imply negative interest).
/// Returns 201 {"installments": n}.
async fn set_custom_schedule(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
    Json(payload): Json<CustomScheduleRequest>,
) -> impl IntoResponse {
    use rust_decimal::Decimal;

    // Exactly one of rows / pattern.
    if payload.rows.is_some() == payload.pattern.is_some() {
        return (
            StatusCode::BAD_REQUEST,
            "provide exactly one of `rows` or `pattern`",
        )
            .into_response();
    }

    // Verify ownership + load principal (needed for interest inference).
    let loan = sqlx::query("SELECT principal FROM loans WHERE id = $1 AND user_id = $2")
        .bind(id)
        .bind(ctx.user_id)
        .fetch_optional(&state.db)
        .await;
    let principal: Decimal = match loan {
        Ok(Some(r)) => r.try_get("principal").unwrap_or_default(),
        Ok(None) => return StatusCode::NOT_FOUND.into_response(),
        Err(e) => {
            error!("set_custom_schedule loan load failed: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };

    // Refuse if any payment is already reconciled (same guard as regen).
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
            "cannot set custom schedule: payments already reconciled — unreconcile them first",
        )
            .into_response();
    }

    // Expand to ScheduleRows (from explicit rows or the pattern shorthand).
    let f = |x: f64| Decimal::from_f64_retain(x).unwrap_or_default();
    let rows = if let Some(rs) = &payload.rows {
        let pairs: Vec<(chrono::NaiveDate, Decimal)> =
            rs.iter().map(|r| (r.due_date, f(r.amount))).collect();
        crate::services::loan_schedule::expand_rows(&pairs, principal)
    } else {
        let p = payload.pattern.as_ref().unwrap();
        crate::services::loan_schedule::expand_pattern(
            principal,
            p.start_date,
            p.end_date,
            p.day_of_month,
            p.first_count,
            f(p.first_amount),
            f(p.amount),
        )
    };

    // Validate: non-empty, and Σamount ≥ principal (else the inferred
    // interest would be negative).
    if rows.is_empty() {
        return (
            StatusCode::UNPROCESSABLE_ENTITY,
            "schedule has no installments",
        )
            .into_response();
    }
    let total: Decimal = rows.iter().map(|r| r.amount).sum();
    if total < principal {
        return (
            StatusCode::UNPROCESSABLE_ENTITY,
            "payments sum to less than the principal",
        )
            .into_response();
    }

    // One transaction: flip the loan to custom, clear formula terms, then
    // replace the unpaid schedule rows.
    let mut tx = match state.db.begin().await {
        Ok(t) => t,
        Err(e) => {
            error!("set_custom_schedule begin failed: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };
    if let Err(e) = sqlx::query(
        "UPDATE loans SET interest_type = 'custom', term_months = NULL, \
                payment_frequency = NULL, updated_at = NOW() \
         WHERE id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(ctx.user_id)
    .execute(&mut *tx)
    .await
    {
        error!("set_custom_schedule loan update failed: {e}");
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }
    let n = match persist_schedule_rows(&mut tx, id, ctx.user_id, &rows, principal).await {
        Ok(n) => n,
        Err(e) => {
            error!("set_custom_schedule persist failed: {e}");
            return StatusCode::INTERNAL_SERVER_ERROR.into_response();
        }
    };
    if let Err(e) = tx.commit().await {
        error!("set_custom_schedule commit failed: {e}");
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
        Json(serde_json::json!({"installments": n})),
    )
        .into_response()
}

/// Administrative early/full payoff: close an active loan and void any
/// remaining unpaid scheduled installments.
///
/// Deliberately does NOT fabricate a payment row — cash-basis interest
/// income only counts money that actually arrived, so the user still
/// reconciles the real final transaction through the normal repayment
/// flow. This endpoint is the "mark it settled" administrative action:
/// it flips the loan to `paid_off` (which makes `outstanding` read 0 in
/// loan_view) and marks the unpaid scheduled rows `skipped` so the
/// schedule table stops showing pending installments on a closed loan.
/// Already-reconciled installments are left untouched.
async fn payoff_loan(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
) -> impl IntoResponse {
    // Only an active loan can be paid off — written_off / cancelled /
    // already-paid_off are terminal and shouldn't be silently flipped.
    let result = sqlx::query(
        "UPDATE loans SET status = 'paid_off', updated_at = NOW() \
         WHERE id = $1 AND user_id = $2 AND status = 'active'",
    )
    .bind(id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;
    match result {
        Ok(r) if r.rows_affected() == 0 => {
            // Either the loan doesn't belong to the caller, or it isn't
            // active. Disambiguate so the client can message correctly.
            let exists: bool = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM loans WHERE id = $1 AND user_id = $2)",
            )
            .bind(id)
            .bind(ctx.user_id)
            .fetch_one(&state.db)
            .await
            .unwrap_or(false);
            if exists {
                (StatusCode::CONFLICT, "loan is not active").into_response()
            } else {
                StatusCode::NOT_FOUND.into_response()
            }
        }
        Ok(_) => {
            // Void the still-pending scheduled installments. Leave any
            // reconciled rows (actual_tx_id IS NOT NULL) as the audit
            // trail of what was actually paid.
            let _ = sqlx::query(
                "UPDATE loan_payments SET status = 'skipped' \
                 WHERE loan_id = $1 AND user_id = $2 \
                   AND actual_tx_id IS NULL \
                   AND (scheduled_principal > 0 OR scheduled_interest > 0) \
                   AND status NOT IN ('paid', 'skipped')",
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
            StatusCode::OK.into_response()
        }
        Err(e) => {
            error!("payoff_loan failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR.into_response()
        }
    }
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
        UNION ALL
        -- Schedule-less loans that carry only an expected_repayment_date get
        -- one synthetic reminder for the whole outstanding balance. payment_id
        -- reuses the loan id (there's no installment row to reference).
        SELECT l.id AS payment_id, l.id AS loan_id, l.borrower_name, l.currency,
               l.expected_repayment_date AS due_date, 0 AS installment_number,
               GREATEST(l.principal - COALESCE((
                   SELECT SUM(COALESCE(p.principal_portion, p.paid_amount, 0))
                   FROM loan_payments p
                   WHERE p.loan_id = l.id AND p.paid_amount IS NOT NULL), 0), 0) AS amount,
               GREATEST((l.expected_repayment_date - CURRENT_DATE), 0) AS days_until,
               GREATEST((CURRENT_DATE - l.expected_repayment_date), 0) AS days_overdue
        FROM loans l
        WHERE l.user_id = $1
          AND l.status = 'active'
          AND l.expected_repayment_date IS NOT NULL
          AND l.expected_repayment_date <= CURRENT_DATE + ($2)::int
          AND NOT EXISTS(SELECT 1 FROM loan_payments p
                         WHERE p.loan_id = l.id
                           AND (p.scheduled_principal > 0 OR p.scheduled_interest > 0))
        ORDER BY due_date ASC
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

// ---------- interest income (cash basis) ----------

#[derive(Deserialize)]
struct InterestQuery {
    /// Optional calendar-year filter (cash basis: by paid_date). When
    /// absent, all-time.
    #[serde(default)]
    year: Option<i32>,
}

#[derive(Serialize)]
struct InterestByLoan {
    loan_id: String,
    borrower_name: String,
    currency: String,
    interest_received: f64,
    principal_received: f64,
    payments_count: i64,
}

#[derive(Serialize)]
struct InterestByMonth {
    /// YYYY-MM.
    month: String,
    interest_received: f64,
}

/// Interest-income report. Cash basis — interest is recognized in the
/// month/year the repayment was RECEIVED (paid_date), per IRS Topic 403
/// for an individual cash-method lender. Per-loan rows are grouped by
/// borrower-style (one row per loan), plus per-month series + grand
/// total. Tax content is structural only, not advice.
async fn interest_income(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<InterestQuery>,
) -> Json<serde_json::Value> {
    // Year filter applied on paid_date. NULL year → all-time (the
    // `$2::int IS NULL OR ...` form keeps one query for both paths).
    let by_loan = sqlx::query(
        r#"
        SELECT l.id AS loan_id, l.borrower_name, l.currency,
               COALESCE(SUM(p.interest_portion), 0) AS interest_received,
               COALESCE(SUM(p.principal_portion), 0) AS principal_received,
               COUNT(p.id) AS payments_count
        FROM loans l
        JOIN loan_payments p ON p.loan_id = l.id AND p.user_id = l.user_id
        WHERE l.user_id = $1
          AND p.interest_portion IS NOT NULL
          AND p.paid_date IS NOT NULL
          AND ($2::int IS NULL OR EXTRACT(YEAR FROM p.paid_date) = $2)
        GROUP BY l.id, l.borrower_name, l.currency
        HAVING COALESCE(SUM(p.interest_portion), 0) <> 0
            OR COALESCE(SUM(p.principal_portion), 0) <> 0
        ORDER BY interest_received DESC
        "#,
    )
    .bind(ctx.user_id)
    .bind(q.year)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let by_month = sqlx::query(
        r#"
        SELECT TO_CHAR(p.paid_date, 'YYYY-MM') AS month,
               COALESCE(SUM(p.interest_portion), 0) AS interest_received
        FROM loan_payments p
        WHERE p.user_id = $1
          AND p.interest_portion IS NOT NULL
          AND p.paid_date IS NOT NULL
          AND ($2::int IS NULL OR EXTRACT(YEAR FROM p.paid_date) = $2)
        GROUP BY month
        ORDER BY month ASC
        "#,
    )
    .bind(ctx.user_id)
    .bind(q.year)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let loans: Vec<InterestByLoan> = by_loan
        .iter()
        .map(|r| InterestByLoan {
            loan_id: r.get::<uuid::Uuid, _>("loan_id").to_string(),
            borrower_name: r.try_get("borrower_name").unwrap_or_default(),
            currency: r.try_get("currency").unwrap_or_default(),
            interest_received: dec_to_f64(r.try_get("interest_received").ok()),
            principal_received: dec_to_f64(r.try_get("principal_received").ok()),
            payments_count: r.try_get("payments_count").unwrap_or(0),
        })
        .collect();
    let months: Vec<InterestByMonth> = by_month
        .iter()
        .map(|r| InterestByMonth {
            month: r.try_get("month").unwrap_or_default(),
            interest_received: dec_to_f64(r.try_get("interest_received").ok()),
        })
        .collect();
    // Legacy flat totals: a NAÏVE sum across all loans regardless of currency.
    // Kept for backward compatibility (the frontend reads these), but they only
    // mean something when every loan shares one currency. The per-currency
    // breakdown below is the correct figure to display when currencies mix —
    // MXN interest and USD interest must never be added unlabeled.
    let total_interest: f64 = loans.iter().map(|l| l.interest_received).sum();
    let total_principal: f64 = loans.iter().map(|l| l.principal_received).sum();

    // Per-currency totals so mixed-currency portfolios aren't summed across an
    // FX boundary. Additive field — does not change the legacy totals.
    let mut by_currency: std::collections::BTreeMap<String, (f64, f64, i64)> =
        std::collections::BTreeMap::new();
    for l in &loans {
        let e = by_currency
            .entry(l.currency.clone())
            .or_insert((0.0, 0.0, 0));
        e.0 += l.interest_received;
        e.1 += l.principal_received;
        e.2 += l.payments_count;
    }
    let totals_by_currency: Vec<serde_json::Value> = by_currency
        .into_iter()
        .map(|(currency, (interest, principal, payments))| {
            serde_json::json!({
                "currency": currency,
                "total_interest": interest,
                "total_principal": principal,
                "payments_count": payments,
            })
        })
        .collect();
    // The single currency when the report is unambiguous (every loan shares
    // one), else null — lets the UI label the flat totals safely.
    let totals_currency: Option<String> = match totals_by_currency.len() {
        1 => totals_by_currency[0]
            .get("currency")
            .and_then(|v| v.as_str())
            .map(|s| s.to_string()),
        _ => None,
    };

    // Informational (NOT tax advice): IRS §7872 can impute interest on
    // a below-market (0% / very-low-rate) loan, but only once aggregate
    // loans between two individuals exceed the $10,000 gift-loan
    // de-minimis. Surface active 0%-rate loans whose principal clears
    // that threshold so the user can raise it with an accountant.
    let below_market_rows = sqlx::query(
        r#"
        SELECT borrower_name, principal, currency
        FROM loans
        WHERE user_id = $1 AND status = 'active' AND interest_rate = 0
        ORDER BY principal DESC
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();
    // The $10,000 de-minimis is a USD figure, so compare each loan's
    // USD-EQUIVALENT principal — otherwise a 15,000-MXN (~$830) 0% loan
    // is wrongly flagged as clearing the threshold. US+MX app: convert
    // MXN at the current rate, treat anything else as already-USD.
    let usd_mxn = crate::api::dashboard::latest_usd_mxn_rate(&state.db)
        .await
        .rate;
    let below_market: Vec<serde_json::Value> = below_market_rows
        .iter()
        .filter_map(|r| {
            let principal = dec_to_f64(r.try_get("principal").ok());
            let currency = r.try_get::<String, _>("currency").unwrap_or_default();
            let usd_principal = if currency.eq_ignore_ascii_case("MXN") && usd_mxn > 0.0 {
                principal / usd_mxn
            } else {
                principal
            };
            if usd_principal <= 10_000.0 {
                return None;
            }
            Some(serde_json::json!({
                "borrower_name": r.try_get::<String, _>("borrower_name").unwrap_or_default(),
                "principal": principal,
                "currency": currency,
            }))
        })
        .collect();

    Json(serde_json::json!({
        "year": q.year,
        // Legacy naive cross-currency sums (backward compat). Prefer
        // `totals_by_currency` when `totals_currency` is null (mixed currencies).
        "total_interest": total_interest,
        "total_principal": total_principal,
        // Currency label for the flat totals: the shared currency when all
        // loans agree, else null (meaning the flat totals mix currencies and
        // `totals_by_currency` should be used instead).
        "totals_currency": totals_currency,
        // Correct per-currency totals so MXN and USD are never added unlabeled.
        "totals_by_currency": totals_by_currency,
        "by_loan": loans,
        "by_month": months,
        "below_market_loans": below_market,
    }))
}

/// CSV export of every reconciled repayment with its principal/interest
/// split — a separate file from the transactions export so that stays
/// clean. Columns: date, borrower, payment, principal, interest,
/// balance_after, currency. Small dataset → built in memory.
async fn export_interest_income(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<InterestQuery>,
) -> Response {
    // Ordered borrower-first so every payer's history is contiguous, then
    // by date within each borrower — far easier to scan or pivot than a
    // single date-sorted stream that interleaves everyone.
    let rows = sqlx::query(
        r#"
        SELECT p.paid_date, l.borrower_name, l.currency,
               p.paid_amount, p.principal_portion, p.interest_portion, p.balance_after
        FROM loan_payments p
        JOIN loans l ON l.id = p.loan_id AND l.user_id = p.user_id
        WHERE p.user_id = $1
          AND p.interest_portion IS NOT NULL
          AND p.paid_date IS NOT NULL
          AND ($2::int IS NULL OR EXTRACT(YEAR FROM p.paid_date) = $2)
        ORDER BY l.borrower_name ASC, p.paid_date ASC
        "#,
    )
    .bind(ctx.user_id)
    .bind(q.year)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    fn esc(s: &str) -> String {
        format!("\"{}\"", s.replace('"', "\"\""))
    }
    // Clean rectangular table (no inline subtotal rows, so it imports into
    // any spreadsheet). Borrower + currency lead; the two split columns are
    // named plainly; running_balance is the principal still owed after the
    // payment.
    let mut csv =
        String::from("borrower,currency,date,amount_paid,principal,interest,running_balance\n");
    for r in &rows {
        let date = r
            .try_get::<chrono::NaiveDate, _>("paid_date")
            .map(|d| d.to_string())
            .unwrap_or_default();
        let borrower: String = r.try_get("borrower_name").unwrap_or_default();
        let currency: String = r.try_get("currency").unwrap_or_default();
        let pay = dec_to_f64(r.try_get("paid_amount").ok());
        let principal = dec_to_f64(r.try_get("principal_portion").ok());
        let interest = dec_to_f64(r.try_get("interest_portion").ok());
        let bal = dec_to_f64(r.try_get("balance_after").ok());
        csv.push_str(&format!(
            "{},{currency},{date},{pay:.2},{principal:.2},{interest:.2},{bal:.2}\n",
            esc(&borrower)
        ));
    }

    let filename = match q.year {
        Some(y) => format!("patrimonio-loan-interest-{y}.csv"),
        None => "patrimonio-loan-interest.csv".to_string(),
    };
    (
        [
            (header::CONTENT_TYPE, "text/csv; charset=utf-8".to_string()),
            (
                header::CONTENT_DISPOSITION,
                format!("attachment; filename=\"{filename}\""),
            ),
        ],
        csv,
    )
        .into_response()
}

/// Per-borrower, per-year interest-income totals as CSV (Schedule-B
/// style: one line per payer per tax year). Hand to an accountant.
async fn export_interest_summary(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Response {
    let rows = sqlx::query(
        r#"
        SELECT l.borrower_name, l.currency,
               EXTRACT(YEAR FROM p.paid_date)::int AS year,
               COALESCE(SUM(p.interest_portion), 0) AS interest_total,
               COALESCE(SUM(p.principal_portion), 0) AS principal_total
        FROM loans l
        JOIN loan_payments p ON p.loan_id = l.id AND p.user_id = l.user_id
        WHERE l.user_id = $1
          AND p.interest_portion IS NOT NULL
          AND p.paid_date IS NOT NULL
        GROUP BY l.borrower_name, l.currency, EXTRACT(YEAR FROM p.paid_date)
        HAVING COALESCE(SUM(p.interest_portion), 0) <> 0
        ORDER BY l.borrower_name ASC, year DESC
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    fn esc(s: &str) -> String {
        format!("\"{}\"", s.replace('"', "\"\""))
    }
    // Borrower-first to match the detail CSV: all of a payer's years sit
    // together, newest year first within each.
    let mut csv = String::from("borrower,currency,year,interest_received,principal_received\n");
    for r in &rows {
        let year: i32 = r.try_get("year").unwrap_or(0);
        let borrower: String = r.try_get("borrower_name").unwrap_or_default();
        let currency: String = r.try_get("currency").unwrap_or_default();
        let interest = dec_to_f64(r.try_get("interest_total").ok());
        let principal = dec_to_f64(r.try_get("principal_total").ok());
        csv.push_str(&format!(
            "{},{currency},{year},{interest:.2},{principal:.2}\n",
            esc(&borrower)
        ));
    }
    (
        [
            (header::CONTENT_TYPE, "text/csv; charset=utf-8".to_string()),
            (
                header::CONTENT_DISPOSITION,
                "attachment; filename=\"patrimonio-loan-interest-summary.csv\"".to_string(),
            ),
        ],
        csv,
    )
        .into_response()
}

/// Printable promissory-note / loan agreement as a self-contained HTML
/// document. Opened in a browser tab; the user prints to PDF (the
/// standard web approach — no server-side PDF dependency). Includes the
/// parties, terms, and the amortization schedule when one exists. This
/// is a record-keeping convenience, NOT legal advice.
#[derive(Deserialize)]
struct AgreementQuery {
    /// `es` for Spanish, anything else (or absent) for English.
    #[serde(default)]
    lang: Option<String>,
}

async fn loan_agreement(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
    Query(q): Query<AgreementQuery>,
) -> Response {
    let es = q.lang.as_deref() == Some("es");
    // Bilingual static-label helper.
    let t = |en: &'static str, es_s: &'static str| -> &'static str {
        if es {
            es_s
        } else {
            en
        }
    };
    let sql =
        format!("SELECT l.*, {LOAN_AGGREGATES} FROM loans l WHERE l.id = $1 AND l.user_id = $2");
    let row = sqlx::query(&sql)
        .bind(id)
        .bind(ctx.user_id)
        .fetch_optional(&state.db)
        .await;
    let Ok(Some(r)) = row else {
        return StatusCode::NOT_FOUND.into_response();
    };
    let today = chrono::Utc::now().date_naive();
    let v = loan_view(&r, today);

    // Lender display name: the user's configured full name (app setting
    // 'lender_name'), else their username. Lets the agreement read
    // "Nick Van der Auwermeulen" instead of a login handle.
    let configured_name: Option<String> =
        sqlx::query("SELECT value FROM app_settings WHERE key = 'lender_name' AND user_id = $1")
            .bind(ctx.user_id)
            .fetch_optional(&state.db)
            .await
            .ok()
            .flatten()
            .and_then(|r| r.try_get::<serde_json::Value, _>("value").ok())
            .and_then(|val| val.as_str().map(|s| s.trim().to_string()))
            .filter(|s| !s.is_empty());
    let lender: String = match configured_name {
        Some(name) => name,
        None => sqlx::query_scalar("SELECT username FROM users WHERE id = $1")
            .bind(ctx.user_id)
            .fetch_optional(&state.db)
            .await
            .ok()
            .flatten()
            .unwrap_or_else(|| "Lender".to_string()),
    };

    // Schedule rows for the table (if generated).
    let payments = sqlx::query(
        "SELECT installment_number, due_date, scheduled_amount, scheduled_principal, \
                scheduled_interest, status \
         FROM loan_payments \
         WHERE loan_id = $1 AND (scheduled_principal > 0 OR scheduled_interest > 0) \
         ORDER BY installment_number ASC",
    )
    .bind(id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    fn esc_html(s: &str) -> String {
        s.replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
    }
    let sym = if v.currency == "MXN" { "MX$" } else { "$" };
    let money = |x: f64| fmt_money(sym, x);
    let per = if v.rate_period == "monthly" {
        t("month", "mes")
    } else {
        t("year", "año")
    };
    let pct = v.interest_rate * 100.0;
    let total_sched_interest: f64 = payments
        .iter()
        .map(|p| dec_to_f64(p.try_get("scheduled_interest").ok()))
        .sum();
    // A custom schedule carries no rate but can still charge interest; a
    // 0%/none loan charges none. Drives both the terms line and the clause.
    let has_interest = v.interest_rate > 0.0 || total_sched_interest > 0.0;
    // Total the borrower owes = Σ scheduled payments (principal + interest)
    // when a schedule exists, else the principal. Makes "owes 16,000, not
    // 14,000" explicit throughout the document.
    let total_sched_payment: f64 = payments
        .iter()
        .map(|p| dec_to_f64(p.try_get("scheduled_amount").ok()))
        .sum();
    let total_to_repay = if payments.is_empty() {
        v.principal
    } else {
        total_sched_payment
    };
    // total_repaid is Σ paid_amount, which already INCLUDES each payment's
    // interest portion — adding interest_earned on top double-counted it
    // (one $70 repayment on a $120 + $20 flat-interest loan rendered as
    // PAID $80 / REMAINING $60 while the app correctly showed $70 / $70).
    // Keep these figures identical to the loan view's total_repaid /
    // total_owed so the document handed to the borrower matches the app.
    let total_paid = v.total_repaid;
    let remaining_owed = (total_to_repay - total_paid).max(0.0);
    let interest_desc = if !has_interest {
        t("no interest", "sin intereses").to_string()
    } else {
        match v.interest_type.as_str() {
            "simple" if es => format!("interés simple de {pct:.3}% por {per}"),
            "simple" => format!("simple interest at {pct:.3}% per {per}"),
            "amortized" if es => format!("amortizado a {pct:.3}% por {per}"),
            "amortized" => format!("amortized at {pct:.3}% per {per}"),
            "interest_only" if es => {
                format!("solo interés a {pct:.3}% por {per} (capital al vencimiento)")
            }
            "interest_only" => {
                format!("interest-only at {pct:.3}% per {per} (principal due at maturity)")
            }
            "compound" if es => {
                format!("interés compuesto a {pct:.3}% por {per} (al vencimiento)")
            }
            "compound" => {
                format!("compound interest at {pct:.3}% per {per} (due at maturity)")
            }
            // 'custom' (or any other) with interest present: it's itemised in
            // the schedule rather than expressed as a single rate.
            _ if es => "el interés indicado en el calendario".to_string(),
            _ => "the interest itemised in the schedule".to_string(),
        }
    };

    let mut schedule_html = String::new();
    if !payments.is_empty() {
        let paid_count = payments
            .iter()
            .filter(|p| p.try_get::<String, _>("status").ok().as_deref() == Some("paid"))
            .count();
        let total_count = payments.len();
        // A plain-language caption above the grid so the schedule reads as a
        // progress record, not just a table.
        let caption = if es {
            format!(
                "{paid_count} de {total_count} pagos completados · {} pendiente",
                money(remaining_owed)
            )
        } else {
            format!(
                "{paid_count} of {total_count} payments completed · {} remaining",
                money(remaining_owed)
            )
        };
        schedule_html.push_str(&format!(
            "<h2>{}</h2><p class=\"caption\">{caption}</p><table><thead><tr>\
             <th>#</th><th>{}</th><th class=\"num\">{}</th><th class=\"num\">{}</th><th class=\"num\">{}</th><th class=\"st\">{}</th></tr></thead><tbody>",
            t("Repayment schedule", "Calendario de pagos"),
            t("Due", "Vence"),
            t("Payment", "Pago"),
            t("Principal", "Capital"),
            t("Interest", "Interés"),
            t("Status", "Estado"),
        ));
        for p in &payments {
            let n: i32 = p.try_get("installment_number").unwrap_or(0);
            let due = p
                .try_get::<chrono::NaiveDate, _>("due_date")
                .map(|d| d.to_string())
                .unwrap_or_default();
            let amt = dec_to_f64(p.try_get("scheduled_amount").ok());
            let prin = dec_to_f64(p.try_get("scheduled_principal").ok());
            let int = dec_to_f64(p.try_get("scheduled_interest").ok());
            let paid = p.try_get::<String, _>("status").ok().as_deref() == Some("paid");
            let (row_cls, status_cell) = if paid {
                (
                    " class=\"paid\"",
                    format!("<span class=\"ok\">✔ {}</span>", t("Paid", "Pagado")),
                )
            } else {
                ("", t("Pending", "Pendiente").to_string())
            };
            schedule_html.push_str(&format!(
                "<tr{row_cls}><td>{n}</td><td>{due}</td><td class=\"num\">{}</td><td class=\"num\">{}</td><td class=\"num\">{}</td><td class=\"st\">{status_cell}</td></tr>",
                money(amt), money(prin), money(int)
            ));
        }
        schedule_html.push_str("</tbody></table>");
    }

    let term_line = match (v.term_months, v.payment_frequency.as_deref()) {
        (Some(tm), Some(f)) => {
            let freq = if es {
                match f {
                    "monthly" => "mensuales",
                    "weekly" => "semanales",
                    "lump_sum" => "de pago único",
                    other => other,
                }
            } else {
                f
            };
            if es {
                format!("Plazo: {tm} meses, pagos {freq}.")
            } else {
                format!("Term: {tm} months, {f} payments.")
            }
        }
        // A custom schedule has no term/frequency but IS a fixed set of
        // payments — don't call it open-ended.
        _ if !payments.is_empty() => {
            let n = payments.len();
            if es {
                format!("{n} pagos programados.")
            } else {
                format!("{n} scheduled payments.")
            }
        }
        _ => t(
            "Open-ended (no fixed schedule).",
            "Abierto (sin calendario fijo).",
        )
        .to_string(),
    };
    let paid_pct = if total_to_repay > 0.0 {
        (total_paid / total_to_repay * 100.0).clamp(0.0, 100.0)
    } else {
        0.0
    };
    let total_repay_disp = money(total_to_repay);
    let total_paid_disp = money(total_paid);
    let remaining_disp = money(remaining_owed);
    // Show the principal + interest composition so the total reads clearly.
    let breakdown = if !payments.is_empty() && total_sched_interest > 0.0 {
        if es {
            format!(
                "<div class=\"sub\">Capital {} + interés {}</div>",
                money(v.principal),
                money(total_sched_interest)
            )
        } else {
            format!(
                "<div class=\"sub\">Principal {} + interest {}</div>",
                money(v.principal),
                money(total_sched_interest)
            )
        }
    } else {
        String::new()
    };

    let principal_str = format!("{:.2}", v.principal);
    let currency_esc = esc_html(&v.currency);
    let interest_esc = esc_html(&interest_desc);
    // "…with the interest…" vs "…without interest" so a 0% loan doesn't read
    // "together with no interest".
    let value_para = match (es, has_interest) {
        (true, true) => format!("Por el valor recibido, el Prestatario se compromete a pagar al Prestamista la suma principal de <strong>{principal_str} {currency_esc}</strong>, con {interest_esc}, conforme a los términos aquí establecidos."),
        (true, false) => format!("Por el valor recibido, el Prestatario se compromete a pagar al Prestamista la suma principal de <strong>{principal_str} {currency_esc}</strong>, sin intereses, conforme a los términos aquí establecidos."),
        (false, true) => format!("For value received, the Borrower promises to pay the Lender the principal sum of <strong>{principal_str} {currency_esc}</strong>, with {interest_esc}, according to the terms set out herein."),
        (false, false) => format!("For value received, the Borrower promises to pay the Lender the principal sum of <strong>{principal_str} {currency_esc}</strong>, without interest, according to the terms set out herein."),
    };
    let (en_on, es_on) = if es { ("", " on") } else { (" on", "") };
    let status_hdr = format!("{} {}", t("Status as of", "Estado al"), today);
    let principal_disp = format!("{principal_str} {currency_esc}");

    let html = format!(
        r#"<!DOCTYPE html><html lang="{doc_lang}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title} — {borrower}</title>
<style>
  :root {{ --ink:#1f2933; --muted:#6b7280; --line:#e5e7eb; --accent:#0f766e; --soft:#f0fdfa; --bg:#ffffff; }}
  * {{ box-sizing: border-box; }}
  body {{ font-family: ui-sans-serif, system-ui, -apple-system, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif; max-width: 780px; margin: 0 auto; color: var(--ink); line-height: 1.55; padding: 24px 20px 64px; background: var(--bg); }}
  .topbar {{ display:flex; align-items:center; justify-content:space-between; gap:12px; flex-wrap:wrap; margin-bottom: 20px; }}
  .brand {{ font-size:12px; font-weight:700; letter-spacing:.14em; text-transform:uppercase; color:var(--accent); }}
  .tools {{ display:flex; align-items:center; gap:10px; }}
  .lang a {{ text-decoration:none; color:var(--muted); font-size:12px; font-weight:600; padding:3px 7px; border-radius:6px; }}
  .lang a.on {{ background:var(--soft); color:var(--accent); }}
  button.print {{ font: inherit; font-size:12px; font-weight:600; padding:7px 12px; border:1px solid var(--accent); background:var(--accent); color:#fff; border-radius:8px; cursor:pointer; }}
  h1 {{ font-size: 24px; margin: 0 0 4px; letter-spacing:-0.01em; }}
  .subtitle {{ color:var(--muted); font-size:13px; margin:0 0 24px; }}
  h2 {{ font-size: 13px; text-transform:uppercase; letter-spacing:.08em; color:var(--accent); margin: 30px 0 10px; }}
  .cards {{ display:grid; grid-template-columns: repeat(3, 1fr); gap:12px; margin-top:8px; }}
  .card {{ border:1px solid var(--line); border-radius:12px; padding:14px 16px; background:var(--bg); }}
  .card .k {{ font-size:11px; color:var(--muted); text-transform:uppercase; letter-spacing:.05em; }}
  .card .val {{ font-size:20px; font-weight:800; margin-top:4px; font-variant-numeric: tabular-nums; }}
  .card .sub {{ font-size:11px; color:var(--muted); margin-top:6px; }}
  .card.accent {{ background:var(--soft); border-color:#99f6e4; }}
  .card.accent .val {{ color:var(--accent); }}
  .bar {{ height:8px; border-radius:6px; background:var(--line); overflow:hidden; margin:14px 0 4px; }}
  .bar > span {{ display:block; height:100%; background:var(--accent); }}
  .barlabel {{ font-size:12px; color:var(--muted); }}
  .dl {{ display:grid; grid-template-columns: 180px 1fr; gap:6px 16px; font-size:14px; }}
  .dl .k {{ color:var(--muted); }}
  .dl .v {{ font-weight:600; }}
  p.para {{ font-size:14px; }}
  table {{ width: 100%; border-collapse: collapse; font-size: 13px; margin-top: 8px; }}
  thead th {{ background:var(--soft); color:var(--accent); text-align:left; padding:8px 10px; border-bottom:2px solid #99f6e4; font-size:11px; text-transform:uppercase; letter-spacing:.05em; }}
  tbody td {{ padding:7px 10px; border-bottom:1px solid var(--line); }}
  tbody tr:nth-child(even) {{ background:#fafafa; }}
  tbody tr.paid {{ background:#f0fdf4; }}
  tbody tr.paid td:nth-child(2) {{ color:var(--muted); }}
  td.num, th.num {{ text-align:right; font-variant-numeric: tabular-nums; }}
  td.st, th.st {{ text-align:center; white-space:nowrap; }}
  .ok {{ color:#16a34a; font-weight:700; }}
  p.caption {{ font-size:13px; color:var(--muted); margin:2px 0 10px; }}
  thead th:nth-child(n+3) {{ text-align:right; }}
  .sig {{ margin-top: 44px; display: flex; justify-content: space-between; gap:24px; }}
  .sig div {{ flex:1; border-top: 1px solid var(--ink); padding-top: 6px; font-size: 12px; color:var(--muted); }}
  .note {{ margin-top: 28px; font-size: 11px; color: var(--muted); border-top:1px solid var(--line); padding-top:12px; }}
  @media (max-width: 520px) {{ .cards {{ grid-template-columns: 1fr; }} .dl {{ grid-template-columns: 130px 1fr; }} }}
  /* Zero @page margins suppress the browser's print header/footer (URL,
     date, page numbers) — those render INSIDE the page margin band. The
     document supplies its own margins via body padding instead, so the
     saved PDF is clean. */
  @page {{ margin: 0; }}
  @media print {{ body {{ padding: 16mm 18mm 18mm; }} .tools {{ display:none; }} .card, thead th {{ -webkit-print-color-adjust: exact; print-color-adjust: exact; }} }}
</style></head><body>
<div class="topbar">
  <span class="brand">Patrimonio</span>
  <div class="tools">
    <span class="lang"><a href="?lang=en" class="{en_on_cls}">EN</a><a href="?lang=es" class="{es_on_cls}">ES</a></span>
    <button class="print" onclick="window.print()">{print}</button>
  </div>
</div>
<h1>{title}</h1>
<p class="subtitle">{subtitle}</p>

<h2>{status_hdr}</h2>
<div class="cards">
  <div class="card"><div class="k">{total_lbl}</div><div class="val">{total_repay_disp}</div>{breakdown}</div>
  <div class="card"><div class="k">{paid_lbl}</div><div class="val">{total_paid_disp}</div></div>
  <div class="card accent"><div class="k">{remaining_lbl}</div><div class="val">{remaining_disp}</div></div>
</div>
<div class="bar"><span style="width:{paid_pct:.1}%"></span></div>
<div class="barlabel">{total_paid_disp} {of_word} {total_repay_disp} {paid_word} · {paid_pct:.0}%</div>

<h2>{parties_hdr}</h2>
<div class="dl">
  <div class="k">{lender_lbl}</div><div class="v">{lender}</div>
  <div class="k">{borrower_lbl}</div><div class="v">{borrower}</div>
</div>

<h2>{terms_hdr}</h2>
<div class="dl">
  <div class="k">{principal_lbl}</div><div class="v">{principal_disp}</div>
  <div class="k">{date_lbl}</div><div class="v">{origination}</div>
  <div class="k">{interest_lbl2}</div><div class="v">{interest_desc}</div>
  <div class="k">{schedule_lbl}</div><div class="v">{term_line_val}</div>
</div>

<p class="para">{value_para}</p>
{schedule_html}
<div class="sig"><div>{lender_sig}</div><div>{borrower_sig}</div></div>
<p class="note">{disclaimer}</p>
</body></html>"#,
        doc_lang = if es { "es" } else { "en" },
        title = t("Promissory Note & Loan Agreement", "Pagaré y Contrato de Préstamo"),
        subtitle = t(
            "A personal record of the loan, its terms, and its repayment.",
            "Registro personal del préstamo: sus términos y sus pagos."
        ),
        print = t("Print / Save as PDF", "Imprimir / Guardar como PDF"),
        en_on_cls = en_on.trim(),
        es_on_cls = es_on.trim(),
        status_hdr = status_hdr,
        total_lbl = t("Total to repay", "Total a pagar"),
        paid_lbl = t("Paid", "Pagado"),
        remaining_lbl = t("Remaining", "Pendiente"),
        total_repay_disp = total_repay_disp,
        total_paid_disp = total_paid_disp,
        remaining_disp = remaining_disp,
        breakdown = breakdown,
        of_word = t("of", "de"),
        paid_word = t("paid", "pagado"),
        parties_hdr = t("Parties", "Partes"),
        lender_lbl = t("Lender", "Prestamista"),
        borrower_lbl = t("Borrower", "Prestatario"),
        terms_hdr = t("Loan terms", "Términos del préstamo"),
        principal_lbl = t("Principal", "Capital"),
        date_lbl = t("Date of loan", "Fecha del préstamo"),
        interest_lbl2 = t("Interest", "Interés"),
        schedule_lbl = t("Schedule", "Calendario"),
        lender_sig = t("Lender signature / date", "Firma del prestamista / fecha"),
        borrower_sig = t("Borrower signature / date", "Firma del prestatario / fecha"),
        disclaimer = t(
            "Generated by Patrimonio as a personal record-keeping convenience. This document is not legal advice; consult a qualified professional for an enforceable agreement.",
            "Generado por Patrimonio como registro personal. Este documento no constituye asesoría legal; para un contrato exigible, consulta a un profesional."
        ),
        borrower = esc_html(&v.borrower_name),
        lender = esc_html(&lender),
        principal_disp = principal_disp,
        origination = v.origination_date,
        interest_desc = interest_esc,
        term_line_val = esc_html(&term_line),
        value_para = value_para,
        paid_pct = paid_pct,
        schedule_html = schedule_html,
    );

    (
        [(header::CONTENT_TYPE, "text/html; charset=utf-8".to_string())],
        html,
    )
        .into_response()
}

// ---------- borrower-facing payment plan (CSV + printable) ----------

/// One payment-plan row for the borrower-facing exports, carrying a
/// running principal balance (what's still owed AFTER this payment) —
/// the figure a borrower actually wants, which neither the schedule
/// table nor the legal agreement shows.
struct PlanRow {
    installment_number: i32,
    due_date: Option<chrono::NaiveDate>,
    amount: rust_decimal::Decimal,
    principal: rust_decimal::Decimal,
    interest: rust_decimal::Decimal,
    balance_remaining: rust_decimal::Decimal,
    status: String,
}

/// Attach a running principal balance to a list of per-row principals.
/// `balance_remaining` after row k = principal − Σ principal[0..=k]; by
/// the schedule's tail-absorbs-residual invariant it closes to EXACTLY 0
/// on the final row. Tiny negative drift (defensive) is clamped to 0.
/// Pure + DB-free so it's unit-testable against `loan_schedule::generate`.
fn running_balances(
    principal: rust_decimal::Decimal,
    principals: &[rust_decimal::Decimal],
) -> Vec<rust_decimal::Decimal> {
    use rust_decimal::Decimal;
    let mut balance = principal;
    let mut out = Vec::with_capacity(principals.len());
    for p in principals {
        balance -= *p;
        if balance < Decimal::ZERO {
            balance = Decimal::ZERO;
        }
        out.push(balance);
    }
    out
}

/// Build the borrower-facing plan rows for a loan. Prefers the persisted
/// scheduled installments (so paid/scheduled status is real), and falls
/// back to an ephemeral schedule computed exactly as `generate_schedule`
/// would — so the export works even before the user clicks "Generate".
/// Err mirrors `loan_schedule::generate`'s open-ended / bad-frequency
/// guards.
// builder-style fn: each loan term is a distinct scalar arg, grouping them into
// a struct would just move the argument list elsewhere for no clarity gain
#[allow(clippy::too_many_arguments)]
async fn build_plan_rows(
    db: &sqlx::PgPool,
    loan_id: uuid::Uuid,
    principal: rust_decimal::Decimal,
    rate: rust_decimal::Decimal,
    rate_period: &str,
    interest_type: &str,
    origination: chrono::NaiveDate,
    term_months: Option<i32>,
    payment_frequency: Option<&str>,
) -> Result<Vec<PlanRow>, crate::services::loan_schedule::ScheduleError> {
    use rust_decimal::Decimal;

    let persisted = sqlx::query(
        "SELECT installment_number, due_date, scheduled_amount, scheduled_principal, \
                scheduled_interest, status \
         FROM loan_payments \
         WHERE loan_id = $1 AND (scheduled_principal > 0 OR scheduled_interest > 0) \
         ORDER BY installment_number ASC",
    )
    .bind(loan_id)
    .fetch_all(db)
    .await
    .unwrap_or_default();

    // Normalise persisted rows and ephemeral rows to a common tuple shape:
    // (installment, due_date, amount, principal, interest, status).
    type Raw = (
        i32,
        Option<chrono::NaiveDate>,
        Decimal,
        Decimal,
        Decimal,
        String,
    );
    let raw: Vec<Raw> = if !persisted.is_empty() {
        persisted
            .iter()
            .map(|p| {
                (
                    p.try_get("installment_number").unwrap_or(0),
                    p.try_get::<Option<chrono::NaiveDate>, _>("due_date")
                        .ok()
                        .flatten(),
                    p.try_get("scheduled_amount").unwrap_or_default(),
                    p.try_get("scheduled_principal").unwrap_or_default(),
                    p.try_get("scheduled_interest").unwrap_or_default(),
                    p.try_get("status")
                        .unwrap_or_else(|_| "scheduled".to_string()),
                )
            })
            .collect()
    } else {
        let rows = crate::services::loan_schedule::generate(
            principal,
            rate,
            rate_period,
            interest_type,
            origination,
            term_months,
            payment_frequency,
        )?;
        rows.into_iter()
            .map(|r| {
                (
                    r.installment_number,
                    Some(r.due_date),
                    r.amount,
                    r.principal,
                    r.interest,
                    "scheduled".to_string(),
                )
            })
            .collect()
    };

    let principals: Vec<Decimal> = raw.iter().map(|t| t.3).collect();
    let balances = running_balances(principal, &principals);
    Ok(raw
        .into_iter()
        .zip(balances)
        .map(|((n, due, amount, prin, int, status), bal)| PlanRow {
            installment_number: n,
            due_date: due,
            amount,
            principal: prin,
            interest: int,
            balance_remaining: bal,
            status,
        })
        .collect())
}

/// Load the loan fields the plan exports need, then build the plan rows.
/// Returns (borrower, currency, principal, rows) or an HTTP-ready error
/// response (404 unknown loan, 422 open-ended / bad frequency).
async fn loan_plan_context(
    db: &sqlx::PgPool,
    loan_id: uuid::Uuid,
    user_id: uuid::Uuid,
) -> Result<(sqlx::postgres::PgRow, Vec<PlanRow>), Response> {
    let sql =
        format!("SELECT l.*, {LOAN_AGGREGATES} FROM loans l WHERE l.id = $1 AND l.user_id = $2");
    let row = sqlx::query(&sql)
        .bind(loan_id)
        .bind(user_id)
        .fetch_optional(db)
        .await;
    let r = match row {
        Ok(Some(r)) => r,
        Ok(None) => return Err(StatusCode::NOT_FOUND.into_response()),
        Err(e) => {
            error!("loan_plan_context load failed: {e}");
            return Err(StatusCode::INTERNAL_SERVER_ERROR.into_response());
        }
    };

    let principal: rust_decimal::Decimal = r.try_get("principal").unwrap_or_default();
    let rate: rust_decimal::Decimal = r.try_get("interest_rate").unwrap_or_default();
    let interest_type: String = r.try_get("interest_type").unwrap_or_else(|_| "none".into());
    let rate_period: String = r.try_get("rate_period").unwrap_or_else(|_| "annual".into());
    let origination: chrono::NaiveDate = match r.try_get("origination_date") {
        Ok(d) => d,
        Err(_) => return Err(StatusCode::INTERNAL_SERVER_ERROR.into_response()),
    };
    let term_months: Option<i32> = r.try_get("term_months").ok().flatten();
    let payment_frequency: Option<String> = r.try_get("payment_frequency").ok().flatten();

    let rows = match build_plan_rows(
        db,
        loan_id,
        principal,
        rate,
        &rate_period,
        &interest_type,
        origination,
        term_months,
        payment_frequency.as_deref(),
    )
    .await
    {
        Ok(rows) => rows,
        Err(_) => {
            return Err((
                StatusCode::UNPROCESSABLE_ENTITY,
                "loan has no term / payment frequency — there's no fixed plan to export",
            )
                .into_response())
        }
    };
    Ok((r, rows))
}

/// CSV of the borrower's payment plan — installments with their
/// principal/interest split AND the running balance remaining. Opens
/// straight into Google Sheets / Excel. Filename carries the borrower.
async fn export_schedule_csv(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
) -> Response {
    let (r, rows) = match loan_plan_context(&state.db, id, ctx.user_id).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    let borrower: String = r.try_get("borrower_name").unwrap_or_default();

    fn esc(s: &str) -> String {
        format!("\"{}\"", s.replace('"', "\"\""))
    }
    // A 0% / custom-with-no-markup schedule carries no interest, so drop
    // the Principal + Interest columns — they'd just be a redundant copy of
    // Payment and a wall of 0.00. Show them only when interest is real.
    let has_interest = rows
        .iter()
        .any(|p| p.interest > rust_decimal::Decimal::ZERO);
    let mut csv = if has_interest {
        String::from("#,Due date,Payment,Principal,Interest,Balance remaining,Status\n")
    } else {
        String::from("#,Due date,Payment,Balance remaining,Status\n")
    };
    for p in &rows {
        let due = p.due_date.map(|d| d.to_string()).unwrap_or_default();
        if has_interest {
            csv.push_str(&format!(
                "{},{},{:.2},{:.2},{:.2},{:.2},{}\n",
                p.installment_number,
                due,
                dec_to_f64(Some(p.amount)),
                dec_to_f64(Some(p.principal)),
                dec_to_f64(Some(p.interest)),
                dec_to_f64(Some(p.balance_remaining)),
                esc(&p.status),
            ));
        } else {
            csv.push_str(&format!(
                "{},{},{:.2},{:.2},{}\n",
                p.installment_number,
                due,
                dec_to_f64(Some(p.amount)),
                dec_to_f64(Some(p.balance_remaining)),
                esc(&p.status),
            ));
        }
    }

    // Sanitise the borrower for a Content-Disposition filename.
    let slug: String = borrower
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect::<String>()
        .trim_matches('-')
        .to_string();
    let slug = if slug.is_empty() {
        "loan".to_string()
    } else {
        slug
    };
    let filename = format!("patrimonio-payment-plan-{slug}.csv");

    (
        [
            (header::CONTENT_TYPE, "text/csv; charset=utf-8".to_string()),
            (
                header::CONTENT_DISPOSITION,
                format!("attachment; filename=\"{filename}\""),
            ),
        ],
        csv,
    )
        .into_response()
}

/// Printable, borrower-facing payment plan as a self-contained HTML
/// document (opened in a browser tab; the borrower prints / saves to
/// PDF). Friendlier than the legal agreement: a plain-language intro and
/// a schedule table that shows the BALANCE REMAINING after each payment.
async fn loan_payment_plan(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
) -> Response {
    let (r, rows) = match loan_plan_context(&state.db, id, ctx.user_id).await {
        Ok(v) => v,
        Err(resp) => return resp,
    };
    let today = chrono::Utc::now().date_naive();
    let v = loan_view(&r, today);

    let lender: String = sqlx::query_scalar("SELECT username FROM users WHERE id = $1")
        .bind(ctx.user_id)
        .fetch_optional(&state.db)
        .await
        .ok()
        .flatten()
        .unwrap_or_else(|| "your lender".to_string());

    fn esc_html(s: &str) -> String {
        s.replace('&', "&amp;")
            .replace('<', "&lt;")
            .replace('>', "&gt;")
    }
    let sym = if v.currency == "MXN" { "MX$" } else { "$" };
    let money = |x: f64| fmt_money(sym, x);

    // Plain-language interest description (mirrors loan_agreement's).
    let per = if v.rate_period == "monthly" {
        "month"
    } else {
        "year"
    };
    let interest_desc = match v.interest_type.as_str() {
        "none" => "no interest — you pay back exactly what you borrowed".to_string(),
        "simple" => format!(
            "simple interest at {:.3}% per {per}, figured once and split evenly",
            v.interest_rate * 100.0
        ),
        "amortized" => format!(
            "{:.3}% per {per}; each payment covers the interest plus a little principal",
            v.interest_rate * 100.0
        ),
        "interest_only" => format!(
            "interest-only at {:.3}% per {per}; the full amount is due with the final payment",
            v.interest_rate * 100.0
        ),
        "compound" => format!(
            "compound interest at {:.3}% per {per}; nothing is due until the end",
            v.interest_rate * 100.0
        ),
        _ => format!("{:.3}% per {per}", v.interest_rate * 100.0),
    };

    // Schedule table with the balance-remaining column + a paid marker,
    // plus a totals footer.
    let mut total_amount = 0.0;
    let mut total_principal = 0.0;
    let mut total_interest = 0.0;
    let mut body = String::new();
    for p in &rows {
        let due = p.due_date.map(|d| d.to_string()).unwrap_or_default();
        let amt = dec_to_f64(Some(p.amount));
        let prin = dec_to_f64(Some(p.principal));
        let int = dec_to_f64(Some(p.interest));
        let bal = dec_to_f64(Some(p.balance_remaining));
        total_amount += amt;
        total_principal += prin;
        total_interest += int;
        let mark = if p.status == "paid" { "✓ paid" } else { "" };
        body.push_str(&format!(
            "<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td>{}</td><td class=\"paid\">{}</td></tr>",
            p.installment_number,
            due,
            money(amt),
            money(prin),
            money(int),
            money(bal),
            mark,
        ));
    }
    let schedule_html = format!(
        "<table><thead><tr><th>#</th><th>Due</th><th>Payment</th><th>Principal</th>\
         <th>Interest</th><th>Balance left</th><th></th></tr></thead><tbody>{body}\
         <tr class=\"totals\"><td></td><td>Total</td><td>{}</td><td>{}</td><td>{}</td>\
         <td></td><td></td></tr></tbody></table>",
        money(total_amount),
        money(total_principal),
        money(total_interest),
    );

    let term_line = match (v.term_months, v.payment_frequency.as_deref()) {
        (Some(t), Some(f)) => format!("{t} months · {f} payments"),
        _ => "open-ended (no fixed schedule)".to_string(),
    };

    let html = format!(
        r#"<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<title>Payment plan — {borrower}</title>
<style>
  body {{ font-family: -apple-system, system-ui, 'Segoe UI', Roboto, sans-serif; max-width: 760px; margin: 40px auto; color: #1a1a1a; line-height: 1.6; padding: 0 20px; }}
  h1 {{ font-size: 22px; margin-bottom: 4px; }}
  .sub {{ color: #555; margin-top: 0; }}
  .intro {{ background: #f4f8f6; border: 1px solid #d9e6e0; border-radius: 10px; padding: 14px 16px; margin: 20px 0; }}
  .intro strong {{ font-weight: 700; }}
  table {{ width: 100%; border-collapse: collapse; font-size: 13px; margin-top: 8px; }}
  th, td {{ border-bottom: 1px solid #e3e3e3; padding: 6px 8px; text-align: right; }}
  th:first-child, td:first-child, th:nth-child(2), td:nth-child(2) {{ text-align: left; }}
  thead th {{ border-bottom: 2px solid #1a1a1a; }}
  .totals td {{ border-top: 2px solid #1a1a1a; font-weight: 700; }}
  td.paid {{ color: #2e7d5b; font-weight: 600; text-align: left; }}
  .note {{ margin-top: 28px; font-size: 11px; color: #777; }}
  /* Same trick as the loan agreement: @page margin 0 removes the
     browser's URL/date/page-number print chrome; body padding provides
     the visual margins in the saved PDF. */
  @page {{ margin: 0; }}
  @media print {{ body {{ margin: 0 auto; padding: 14mm 16mm; }} button {{ display: none; }} }}
</style></head><body>
<button onclick="window.print()" style="float:right;padding:6px 12px;">Print / Save as PDF</button>
<h1>Payment plan</h1>
<p class="sub">for {borrower}, from {lender}</p>
<div class="intro">
  You borrowed <strong>{principal:.2} {currency}</strong> on <strong>{origination}</strong>.
  Terms: {interest_desc}. Schedule: {term_line}.
  Below is each payment, what it covers, and how much is left to pay afterward.
</div>
{schedule_html}
<p class="note">Generated by Patrimonio as a record-keeping convenience — not legal advice.
Figures are computed from the loan's terms; minor rounding lands on the final payment.</p>
</body></html>"#,
        borrower = esc_html(&v.borrower_name),
        lender = esc_html(&lender),
        principal = v.principal,
        currency = esc_html(&v.currency),
        origination = v.origination_date,
        interest_desc = esc_html(&interest_desc),
        term_line = esc_html(&term_line),
        schedule_html = schedule_html,
    );

    (
        [(header::CONTENT_TYPE, "text/html; charset=utf-8".to_string())],
        html,
    )
        .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal::Decimal;
    use std::str::FromStr;

    #[test]
    fn fmt_money_groups_thousands() {
        assert_eq!(fmt_money("MX$", 16000.0), "MX$16,000.00");
        assert_eq!(fmt_money("$", 1234567.5), "$1,234,567.50");
        assert_eq!(fmt_money("MX$", 500.0), "MX$500.00");
        assert_eq!(fmt_money("MX$", 0.0), "MX$0.00");
        assert_eq!(fmt_money("$", -4200.25), "-$4,200.25");
        assert_eq!(fmt_money("$", 999.99), "$999.99");
    }

    fn d(s: &str) -> Decimal {
        Decimal::from_str(s).unwrap()
    }

    /// The running balance must close to EXACTLY zero on the final row of
    /// every schedule type, and produce one balance per installment.
    #[test]
    fn running_balance_closes_to_zero() {
        let orig = chrono::NaiveDate::from_ymd_opt(2026, 1, 15).unwrap();
        let cases = [
            ("amortized", d("2000"), d("0.05"), 24, "monthly"),
            ("none", d("1000"), Decimal::ZERO, 3, "monthly"),
            ("simple", d("1200"), d("0.06"), 12, "monthly"),
            ("interest_only", d("10000"), d("0.12"), 6, "monthly"),
            ("compound", d("1000"), d("0.10"), 24, "monthly"),
        ];
        for (itype, principal, rate, term, freq) in cases {
            let sched = crate::services::loan_schedule::generate(
                principal,
                rate,
                "annual",
                itype,
                orig,
                Some(term),
                Some(freq),
            )
            .unwrap();
            let principals: Vec<Decimal> = sched.iter().map(|r| r.principal).collect();
            let balances = running_balances(principal, &principals);
            assert_eq!(
                balances.len(),
                sched.len(),
                "{itype}: one balance per installment"
            );
            assert_eq!(
                *balances.last().unwrap(),
                Decimal::ZERO,
                "{itype}: final balance must be exactly 0"
            );
            // Balance is monotonically non-increasing.
            for w in balances.windows(2) {
                assert!(w[1] <= w[0], "{itype}: balance should never grow");
            }
        }
    }

    /// A CUSTOM explicit-row schedule also closes to exactly 0, via the
    /// same running_balances the plan/CSV exports use.
    #[test]
    fn custom_schedule_running_balance_closes_to_zero() {
        let rows = crate::services::loan_schedule::expand_rows(
            &[
                (
                    chrono::NaiveDate::from_ymd_opt(2026, 6, 15).unwrap(),
                    d("3500"),
                ),
                (
                    chrono::NaiveDate::from_ymd_opt(2026, 7, 15).unwrap(),
                    d("4000"),
                ),
                (
                    chrono::NaiveDate::from_ymd_opt(2026, 8, 15).unwrap(),
                    d("2500"),
                ),
            ],
            d("10000"),
        );
        let principals: Vec<Decimal> = rows.iter().map(|r| r.principal).collect();
        let balances = running_balances(d("10000"), &principals);
        assert_eq!(balances.len(), 3);
        assert_eq!(*balances.last().unwrap(), Decimal::ZERO);
    }

    /// The `has_schedule` predicate widened from `scheduled_principal > 0`
    /// to `(scheduled_principal > 0 OR scheduled_interest > 0)`. This mirrors
    /// that SQL boolean in Rust to lock the intent: a MANUALLY-recorded
    /// repayment row (both scheduled columns 0 — the MVP path) must NOT be
    /// counted as a schedule, while a generated row (either column > 0) is.
    #[test]
    fn has_schedule_predicate_excludes_manual_repayments() {
        // (scheduled_principal, scheduled_interest) → is_schedule_row
        let is_schedule = |sp: f64, si: f64| sp > 0.0 || si > 0.0;
        // Manual repayment appended by record_payment: neither column set.
        assert!(!is_schedule(0.0, 0.0), "manual repayment is not a schedule");
        // Formula/custom principal row.
        assert!(is_schedule(100.0, 0.0));
        // Interest-only / custom 0-principal installment (interest only).
        assert!(is_schedule(0.0, 25.0));
        // A normal amortized row with both.
        assert!(is_schedule(90.0, 10.0));
    }
}
