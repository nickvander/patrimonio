//! Recurring & scheduled transactions (MVP).
//!
//! CRUD for `recurring_rules` plus an "expected upcoming" expansion the
//! cash-flow tab renders. Deliberately **no auto-posting**: nothing in
//! this module ever writes to `transactions`, so an expected occurrence
//! is display-only and can never corrupt real balances or history.
//!
//! Sign convention matches `transactions.amount` everywhere: negative =
//! outflow (expense), positive = inflow (income).

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::{get, patch},
    Extension, Json, Router,
};
use chrono::{Datelike, NaiveDate};
use rust_decimal::Decimal;
use rust_decimal_macros::dec;
use serde::{Deserialize, Serialize};
use sqlx::Row;

use crate::api::session::{internal, ApiError, AuthContext};
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_rules).post(create_rule))
        // Static segment BEFORE /{id} or "upcoming" is swallowed as an id.
        .route("/upcoming", get(upcoming))
        .route("/{id}", patch(update_rule).delete(delete_rule))
}

/// The only cadences the MVP supports. A CHECK constraint mirrors this
/// list in the migration; validating here keeps the error a friendly 400
/// instead of a 500 from the constraint.
const CADENCES: [&str; 4] = ["weekly", "biweekly", "monthly", "yearly"];

// ---------------------------------------------------------------------------
// Occurrence expansion (pure — unit-tested at the bottom of this file)
// ---------------------------------------------------------------------------

fn days_in_month(year: i32, month: u32) -> u32 {
    // First day of the next month minus one day; chrono has no direct API.
    let (ny, nm) = if month == 12 { (year + 1, 1) } else { (year, month + 1) };
    NaiveDate::from_ymd_opt(ny, nm, 1)
        .and_then(|d| d.pred_opt())
        .map(|d| d.day())
        .unwrap_or(28)
}

/// The date `anchor_day` lands on within (year, month), clamped to the
/// month's length so an anchor of 31 resolves to Feb 28/29 instead of
/// skipping short months entirely.
fn clamped_day(year: i32, month: u32, anchor_day: u32) -> NaiveDate {
    let day = anchor_day.min(days_in_month(year, month)).max(1);
    // Clamped day is always valid; the unwrap-style fallback can't fire in
    // practice but keeps this total rather than panicking.
    NaiveDate::from_ymd_opt(year, month, day)
        .unwrap_or_else(|| NaiveDate::from_ymd_opt(year, month, 1).unwrap_or_default())
}

/// The occurrence immediately after `current` for a rule.
fn next_occurrence(cadence: &str, anchor_day: u32, current: NaiveDate) -> NaiveDate {
    match cadence {
        "weekly" => current + chrono::Duration::days(7),
        "biweekly" => current + chrono::Duration::days(14),
        "yearly" => clamped_day(current.year() + 1, current.month(), anchor_day),
        // monthly (default): step one calendar month, re-anchoring on
        // anchor_day so "the 31st" recovers to 31 after a 30-day month
        // instead of drifting down permanently.
        _ => {
            let (y, m) = if current.month() == 12 {
                (current.year() + 1, 1)
            } else {
                (current.year(), current.month() + 1)
            };
            clamped_day(y, m, anchor_day)
        }
    }
}

/// All occurrences of a rule inside `[from, to]`, expanded from the
/// stored `next_due_date` seed. The seed may be stale (in the past) —
/// no cron advances it — so we simply roll forward until the window.
/// Iterations are hard-capped: a `to` far in the future against a
/// years-old seed on a weekly cadence walks many steps, and the cap
/// keeps a hostile query window from spinning the handler.
fn occurrences_in_window(
    cadence: &str,
    anchor_day: u32,
    seed: NaiveDate,
    from: NaiveDate,
    to: NaiveDate,
) -> Vec<NaiveDate> {
    let mut out = Vec::new();
    let mut d = seed;
    for _ in 0..2000 {
        if d > to {
            break;
        }
        if d >= from {
            out.push(d);
        }
        d = next_occurrence(cadence, anchor_day, d);
    }
    out
}

/// First occurrence on/after `today` — the "effective" next due date the
/// UI shows regardless of how stale the stored seed is.
fn effective_next_due(cadence: &str, anchor_day: u32, seed: NaiveDate, today: NaiveDate) -> NaiveDate {
    let mut d = seed;
    for _ in 0..2000 {
        if d >= today {
            return d;
        }
        d = next_occurrence(cadence, anchor_day, d);
    }
    d
}

// ---------------------------------------------------------------------------
// DTOs
// ---------------------------------------------------------------------------

#[derive(Serialize)]
struct RecurringRuleDto {
    id: String,
    account_id: String,
    account_name: String,
    description: String,
    category: Option<String>,
    amount: Decimal,
    currency: String,
    cadence: String,
    anchor_day: i16,
    /// Stored seed date (spec field).
    next_due_date: String,
    /// First occurrence on/after today — what the UI should display.
    effective_next_due: String,
    active: bool,
}

fn rule_dto_from_row(row: &sqlx::postgres::PgRow, today: NaiveDate) -> anyhow::Result<RecurringRuleDto> {
    let cadence: String = row.try_get("cadence")?;
    let anchor_day: i16 = row.try_get("anchor_day")?;
    let next_due: NaiveDate = row.try_get("next_due_date")?;
    Ok(RecurringRuleDto {
        id: row.try_get::<uuid::Uuid, _>("id")?.to_string(),
        account_id: row.try_get::<uuid::Uuid, _>("account_id")?.to_string(),
        account_name: row.try_get("account_name")?,
        description: row.try_get("description")?,
        category: row.try_get("category")?,
        amount: row.try_get("amount")?,
        currency: row.try_get("currency")?,
        anchor_day,
        effective_next_due: effective_next_due(&cadence, anchor_day.max(1) as u32, next_due, today)
            .to_string(),
        next_due_date: next_due.to_string(),
        cadence,
        active: row.try_get("active")?,
    })
}

const RULE_SELECT_SQL: &str = r#"
    SELECT r.id, r.account_id,
           COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name,
           r.description, r.category, r.amount, r.currency,
           r.cadence, r.anchor_day, r.next_due_date, r.active
    FROM recurring_rules r
    JOIN accounts a ON a.id = r.account_id
"#;

// ---------------------------------------------------------------------------
// Handlers
// ---------------------------------------------------------------------------

/// GET / — the management list: every rule (active and paused), newest
/// first so a just-created rule is visible at the top.
async fn list_rules(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Result<Json<Vec<RecurringRuleDto>>, ApiError> {
    let rows = sqlx::query(&format!(
        "{RULE_SELECT_SQL} WHERE r.user_id = $1 ORDER BY r.created_at DESC"
    ))
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;

    let today = chrono::Utc::now().date_naive();
    let mut out = Vec::with_capacity(rows.len());
    for r in &rows {
        out.push(rule_dto_from_row(r, today).map_err(internal)?);
    }
    Ok(Json(out))
}

#[derive(Deserialize)]
struct CreateRuleRequest {
    account_id: uuid::Uuid,
    description: String,
    #[serde(default)]
    category: Option<String>,
    /// Signed, matching transactions: negative = expected outflow.
    amount: Decimal,
    currency: String,
    cadence: String,
    /// Day-of-month anchor for monthly/yearly; optional — defaults to
    /// `next_due_date`'s day so simple clients never have to send it.
    #[serde(default)]
    anchor_day: Option<i16>,
    next_due_date: NaiveDate,
}

/// POST / — create a rule ("Make recurring" / the Add-transaction
/// "repeats" option).
async fn create_rule(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Json(req): Json<CreateRuleRequest>,
) -> Result<(StatusCode, Json<RecurringRuleDto>), ApiError> {
    let description = req.description.trim();
    if description.is_empty() {
        return Err(ApiError::new(StatusCode::BAD_REQUEST, "description is required"));
    }
    if req.amount == Decimal::ZERO {
        return Err(ApiError::new(StatusCode::BAD_REQUEST, "amount must be non-zero"));
    }
    if !CADENCES.contains(&req.cadence.as_str()) {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "cadence must be one of weekly, biweekly, monthly, yearly",
        ));
    }
    let anchor_day = req.anchor_day.unwrap_or(req.next_due_date.day() as i16);
    if !(1..=31).contains(&anchor_day) {
        return Err(ApiError::new(StatusCode::BAD_REQUEST, "anchor_day must be 1-31"));
    }
    let currency = req.currency.trim().to_uppercase();
    if currency.is_empty() || currency.len() > 8 {
        return Err(ApiError::new(StatusCode::BAD_REQUEST, "currency is required"));
    }

    // Verify the target account belongs to the caller before attaching a
    // rule to it — same guard as create_manual_transaction; without it an
    // attacker could plant expected flows on a victim's account.
    let owns = sqlx::query("SELECT 1 FROM accounts WHERE id = $1 AND user_id = $2")
        .bind(req.account_id)
        .bind(ctx.user_id)
        .fetch_optional(&state.db)
        .await
        .map_err(internal)?;
    if owns.is_none() {
        return Err(ApiError::new(StatusCode::NOT_FOUND, "account not found"));
    }

    let id: uuid::Uuid = sqlx::query_scalar(
        r#"
        INSERT INTO recurring_rules
            (user_id, account_id, description, category, amount, currency,
             cadence, anchor_day, next_due_date)
        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
        RETURNING id
        "#,
    )
    .bind(ctx.user_id)
    .bind(req.account_id)
    .bind(description)
    .bind(req.category.as_deref().map(str::trim).filter(|c| !c.is_empty()))
    .bind(req.amount)
    .bind(&currency)
    .bind(&req.cadence)
    .bind(anchor_day)
    .bind(req.next_due_date)
    .fetch_one(&state.db)
    .await
    .map_err(internal)?;

    let row = sqlx::query(&format!(
        "{RULE_SELECT_SQL} WHERE r.user_id = $1 AND r.id = $2"
    ))
    .bind(ctx.user_id)
    .bind(id)
    .fetch_one(&state.db)
    .await
    .map_err(internal)?;
    let dto = rule_dto_from_row(&row, chrono::Utc::now().date_naive()).map_err(internal)?;
    Ok((StatusCode::CREATED, Json(dto)))
}

#[derive(Deserialize)]
struct UpdateRuleRequest {
    /// MVP management surface is pause/resume only.
    active: bool,
}

/// PATCH /{id} — pause or resume a rule.
async fn update_rule(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
    Json(req): Json<UpdateRuleRequest>,
) -> Result<Json<RecurringRuleDto>, ApiError> {
    let updated = sqlx::query(
        "UPDATE recurring_rules SET active = $1, updated_at = NOW() \
         WHERE id = $2 AND user_id = $3",
    )
    .bind(req.active)
    .bind(id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await
    .map_err(internal)?;
    if updated.rows_affected() == 0 {
        return Err(ApiError::new(StatusCode::NOT_FOUND, "rule not found"));
    }
    let row = sqlx::query(&format!(
        "{RULE_SELECT_SQL} WHERE r.user_id = $1 AND r.id = $2"
    ))
    .bind(ctx.user_id)
    .bind(id)
    .fetch_one(&state.db)
    .await
    .map_err(internal)?;
    let dto = rule_dto_from_row(&row, chrono::Utc::now().date_naive()).map_err(internal)?;
    Ok(Json(dto))
}

/// DELETE /{id} — remove a rule. Idempotent 204.
async fn delete_rule(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<uuid::Uuid>,
) -> Result<StatusCode, ApiError> {
    sqlx::query("DELETE FROM recurring_rules WHERE id = $1 AND user_id = $2")
        .bind(id)
        .bind(ctx.user_id)
        .execute(&state.db)
        .await
        .map_err(internal)?;
    Ok(StatusCode::NO_CONTENT)
}

#[derive(Deserialize, Default)]
struct UpcomingQuery {
    /// ISO dates; default window is [today, end of the current month] —
    /// "what's still expected this period".
    from: Option<NaiveDate>,
    to: Option<NaiveDate>,
}

#[derive(Serialize)]
struct UpcomingItem {
    rule_id: String,
    account_id: String,
    account_name: String,
    description: String,
    category: Option<String>,
    /// Native-currency signed amount (negative = expected outflow).
    amount: Decimal,
    currency: String,
    due_date: String,
    /// Per-row USD conversion so the frontend can total without doing FX.
    amount_usd: Decimal,
}

#[derive(Serialize)]
struct UpcomingResponse {
    from: String,
    to: String,
    items: Vec<UpcomingItem>,
    /// USD totals, summed from the per-row conversions (house rule: never
    /// sum raw amounts across currencies). Outflows are reported as a
    /// positive magnitude for direct display.
    expected_inflows_usd: Decimal,
    expected_outflows_usd: Decimal,
}

/// GET /upcoming — expected occurrences from ACTIVE rules in the window.
/// Display-only ("expected, not actual"): nothing here posts anything.
async fn upcoming(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<UpcomingQuery>,
) -> Result<Json<UpcomingResponse>, ApiError> {
    let today = chrono::Utc::now().date_naive();
    let from = q.from.unwrap_or(today);
    let default_to = clamped_day(today.year(), today.month(), 31); // end of current month
    let to = q.to.unwrap_or(default_to);
    if to < from {
        return Err(ApiError::new(StatusCode::BAD_REQUEST, "to must be on/after from"));
    }
    // DoS clamp: expansion cost scales with the window; a year is far more
    // than the cash-flow view ever asks for.
    if (to - from).num_days() > 400 {
        return Err(ApiError::new(StatusCode::BAD_REQUEST, "window too large (max 400 days)"));
    }

    let rows = sqlx::query(&format!(
        "{RULE_SELECT_SQL} WHERE r.user_id = $1 AND r.active ORDER BY r.created_at"
    ))
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;

    // Latest USD→MXN rate for converting future-dated MXN expectations.
    // "Rate on tx date" (the tax.rs rule) doesn't apply — these dates are
    // in the future — so latest-known is the honest estimate. Same
    // hard fallback (20.0) and rate>0 guard as USD_MXN_ROW_RATE_SQL.
    let usd_mxn: Decimal = sqlx::query_scalar(
        "SELECT rate FROM exchange_rates \
         WHERE base_currency = 'USD' AND target_currency = 'MXN' AND rate > 0 \
         ORDER BY recorded_at DESC LIMIT 1",
    )
    .fetch_optional(&state.db)
    .await
    .map_err(internal)?
    .unwrap_or(dec!(20.0));

    let mut items = Vec::new();
    for r in &rows {
        let cadence: String = r.try_get("cadence").map_err(internal)?;
        let anchor_day: i16 = r.try_get("anchor_day").map_err(internal)?;
        let seed: NaiveDate = r.try_get("next_due_date").map_err(internal)?;
        let amount: Decimal = r.try_get("amount").map_err(internal)?;
        let currency: String = r.try_get("currency").map_err(internal)?;
        // Per-row FX→USD BEFORE summing (house invariant): MXN divides by
        // the latest rate; every other currency is treated as
        // USD-equivalent (trust the native amount), matching AMOUNT_USD_SQL.
        let amount_usd = if currency.eq_ignore_ascii_case("MXN") {
            (amount / usd_mxn).round_dp(2)
        } else {
            amount
        };
        for due in occurrences_in_window(&cadence, anchor_day.max(1) as u32, seed, from, to) {
            items.push(UpcomingItem {
                rule_id: r.try_get::<uuid::Uuid, _>("id").map_err(internal)?.to_string(),
                account_id: r
                    .try_get::<uuid::Uuid, _>("account_id")
                    .map_err(internal)?
                    .to_string(),
                account_name: r.try_get("account_name").map_err(internal)?,
                description: r.try_get("description").map_err(internal)?,
                category: r.try_get("category").map_err(internal)?,
                amount,
                currency: currency.clone(),
                due_date: due.to_string(),
                amount_usd,
            });
        }
    }
    items.sort_by(|a, b| a.due_date.cmp(&b.due_date).then(a.description.cmp(&b.description)));

    let mut inflows = Decimal::ZERO;
    let mut outflows = Decimal::ZERO;
    for it in &items {
        if it.amount_usd > Decimal::ZERO {
            inflows += it.amount_usd;
        } else {
            outflows += -it.amount_usd;
        }
    }

    Ok(Json(UpcomingResponse {
        from: from.to_string(),
        to: to.to_string(),
        items,
        expected_inflows_usd: inflows.round_dp(2),
        expected_outflows_usd: outflows.round_dp(2),
    }))
}

// ---------------------------------------------------------------------------
// Unit tests for the pure expansion logic
// ---------------------------------------------------------------------------

#[cfg(test)]
mod tests {
    use super::*;

    fn d(y: i32, m: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, day).unwrap()
    }

    #[test]
    fn monthly_anchor_clamps_to_short_months_and_recovers() {
        // Anchor 31 seeded Jan 31: Feb clamps to 28, then March recovers
        // to 31 (no permanent drift down to 28).
        let occ = occurrences_in_window("monthly", 31, d(2026, 1, 31), d(2026, 1, 1), d(2026, 4, 30));
        assert_eq!(
            occ,
            vec![d(2026, 1, 31), d(2026, 2, 28), d(2026, 3, 31), d(2026, 4, 30)]
        );
    }

    #[test]
    fn biweekly_steps_fourteen_days() {
        let occ = occurrences_in_window("biweekly", 1, d(2026, 7, 3), d(2026, 7, 1), d(2026, 7, 31));
        assert_eq!(occ, vec![d(2026, 7, 3), d(2026, 7, 17), d(2026, 7, 31)]);
    }

    #[test]
    fn weekly_rolls_stale_seed_forward_into_window() {
        // Seed months in the past — expansion rolls forward, only window
        // dates are returned.
        let occ = occurrences_in_window("weekly", 1, d(2026, 1, 5), d(2026, 7, 20), d(2026, 7, 27));
        assert_eq!(occ, vec![d(2026, 7, 20), d(2026, 7, 27)]);
    }

    #[test]
    fn yearly_leap_day_clamps() {
        // Feb-29 anchor in a leap year clamps to Feb-28 in common years.
        let occ = occurrences_in_window("yearly", 29, d(2024, 2, 29), d(2025, 1, 1), d(2027, 12, 31));
        assert_eq!(occ, vec![d(2025, 2, 28), d(2026, 2, 28), d(2027, 2, 28)]);
    }

    #[test]
    fn effective_next_due_rolls_forward() {
        assert_eq!(
            effective_next_due("monthly", 15, d(2026, 1, 15), d(2026, 7, 23)),
            d(2026, 8, 15)
        );
        // Already in the future → unchanged.
        assert_eq!(
            effective_next_due("monthly", 15, d(2026, 9, 15), d(2026, 7, 23)),
            d(2026, 9, 15)
        );
    }
}
