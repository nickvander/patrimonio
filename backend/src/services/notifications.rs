//! Unified notifications center — generated-on-read inbox entries.
//!
//! The `user_notifications` table is written from three directions:
//!
//! * event writers (FX alert crossings in `exchange_rate.rs`, import
//!   staleness in `staleness.rs`) insert rows when their cron/refresh
//!   detects the condition;
//! * this module inserts **loan payment due reminders** lazily, when the
//!   inbox is listed (`GET /api/notifications`) — the due window moves
//!   with `CURRENT_DATE`, so generation-on-read is always current without
//!   another cron;
//! * the API layer stamps `read_at` for read state.
//!
//! Lazy generation is made idempotent by `dedupe_key` (unique per user via
//! a partial index): an installment that already produced its reminder —
//! even one the user already read — is skipped by `ON CONFLICT DO
//! NOTHING`, so re-listing the inbox never resurrects read notifications
//! as new unread ones. A rescheduled installment gets a NEW due date and
//! therefore a new dedupe key, which correctly re-alerts.

use anyhow::Result;
use chrono::NaiveDate;
use rust_decimal::Decimal;
use sqlx::{PgPool, Row};
use uuid::Uuid;

/// `user_notifications.kind` for loan payment due reminders.
pub const LOAN_DUE_NOTIFICATION_KIND: &str = "loan_due";

/// `app_settings` key holding the reminder lead time in days. Shared with
/// `GET /api/loans/reminders` so the bell's inbox rows and the lending
/// tab's reminder list agree on the window.
pub const LOAN_LEAD_SETTING_KEY: &str = "lending_reminder_lead_days";

/// Default / clamp bounds for the lead window — identical to
/// `loans::list_reminders` (default 7, clamp 0..=60) so the two surfaces
/// can't drift apart.
pub const DEFAULT_LOAN_LEAD_DAYS: i64 = 7;

/// Record a `user_notifications` row (kind = `loan_due`) for every active
/// loan installment of `user_id` that is due within the user's configured
/// lead window (or already overdue). Returns rows actually inserted.
///
/// Title/body are stored in English with the concrete numbers embedded,
/// matching the fx_alert / import_stale precedent; the notifications
/// center renders locale-aware icons/links off `kind`.
pub async fn record_loan_due_notifications(db: &PgPool, user_id: Uuid) -> Result<usize> {
    // Lead days from settings (JSON number); default 7, clamp 0..=60 —
    // same policy as loans::list_reminders.
    let lead_days: i64 = sqlx::query_scalar::<_, serde_json::Value>(
        "SELECT value FROM app_settings WHERE key = $2 AND user_id = $1",
    )
    .bind(user_id)
    .bind(LOAN_LEAD_SETTING_KEY)
    .fetch_optional(db)
    .await?
    .and_then(|v| v.as_i64())
    .unwrap_or(DEFAULT_LOAN_LEAD_DAYS)
    .clamp(0, 60);

    // Same population as loans::list_reminders: unpaid scheduled
    // installments of active loans inside the window, plus one synthetic
    // whole-balance reminder for schedule-less loans that only carry an
    // expected_repayment_date. Overdue installments (due_date < today)
    // also match `due_date <= today + lead` — a loan created already
    // overdue still gets its reminder.
    let rows = sqlx::query(
        r#"
        SELECT p.id AS payment_id, p.loan_id, l.borrower_name, l.currency,
               p.due_date, p.installment_number,
               COALESCE(p.scheduled_amount, 0) AS amount
        FROM loan_payments p
        JOIN loans l ON l.id = p.loan_id AND l.user_id = p.user_id
        WHERE p.user_id = $1
          AND p.status NOT IN ('paid', 'skipped')
          AND p.actual_tx_id IS NULL
          AND p.due_date IS NOT NULL
          AND l.status = 'active'
          AND p.due_date <= CURRENT_DATE + ($2)::int
        UNION ALL
        SELECT l.id AS payment_id, l.id AS loan_id, l.borrower_name, l.currency,
               l.expected_repayment_date AS due_date, 0 AS installment_number,
               GREATEST(l.principal - COALESCE((
                   SELECT SUM(COALESCE(p.principal_portion, p.paid_amount, 0))
                   FROM loan_payments p
                   WHERE p.loan_id = l.id AND p.paid_amount IS NOT NULL), 0), 0) AS amount
        FROM loans l
        WHERE l.user_id = $1
          AND l.status = 'active'
          AND l.expected_repayment_date IS NOT NULL
          AND l.expected_repayment_date <= CURRENT_DATE + ($2)::int
          AND NOT EXISTS(SELECT 1 FROM loan_payments p
                         WHERE p.loan_id = l.id
                           AND (p.scheduled_principal > 0 OR p.scheduled_interest > 0))
        "#,
    )
    .bind(user_id)
    .bind(lead_days as i32)
    .fetch_all(db)
    .await?;

    let mut recorded = 0usize;
    for row in rows {
        let payment_id: Uuid = row.try_get("payment_id")?;
        let loan_id: Uuid = row.try_get("loan_id")?;
        let borrower: String = row.try_get("borrower_name")?;
        let currency: String = row.try_get("currency")?;
        let due_date: NaiveDate = row.try_get("due_date")?;
        let installment: i32 = row.try_get("installment_number")?;
        let amount: Decimal = row.try_get("amount")?;

        // Keyed on the concrete installment + its due date: daily
        // re-listing is a no-op, while rescheduling the installment
        // (new due date) re-alerts.
        let dedupe_key = format!("loan_due:{payment_id}:{due_date}");
        let title = format!("Repayment from {borrower} due {due_date}");
        // Presentation rounding only; the inbox row is human-readable
        // copy, not a money field the client sums.
        let amount_str = amount.round_dp(2).normalize();
        let body = if installment > 0 {
            format!(
                "Installment #{installment} of {amount_str} {currency} from {borrower} is due on {due_date}."
            )
        } else {
            format!(
                "The outstanding balance of {amount_str} {currency} from {borrower} is expected back on {due_date}."
            )
        };

        let inserted = sqlx::query(
            "INSERT INTO user_notifications \
                 (user_id, kind, title, body, dedupe_key, link_kind, link_id) \
             VALUES ($1, $2, $3, $4, $5, 'loan', $6) \
             ON CONFLICT (user_id, dedupe_key) WHERE dedupe_key IS NOT NULL \
             DO NOTHING",
        )
        .bind(user_id)
        .bind(LOAN_DUE_NOTIFICATION_KIND)
        .bind(&title)
        .bind(&body)
        .bind(&dedupe_key)
        .bind(loan_id.to_string())
        .execute(db)
        .await?
        .rows_affected();
        recorded += inserted as usize;
    }
    Ok(recorded)
}
