//! Recurring & scheduled transactions (MVP).
//!
//! CRUD for `recurring_rules` plus an "expected upcoming" expansion the
//! cash-flow tab renders. Deliberately **no auto-posting**: nothing in
//! this module ever writes to `transactions`, so an expected occurrence
//! is display-only and can never corrupt real balances or history.
//!
//! Sign convention matches `transactions.amount` everywhere: negative =
//! outflow (expense), positive = inflow (income).

use std::collections::{HashMap, HashSet};

use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::{get, patch},
    Extension, Json, Router,
};
use chrono::{Datelike, NaiveDate};
use rust_decimal::prelude::ToPrimitive;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use sqlx::Row;

use crate::api::error::{internal, ApiError};
use crate::api::middleware::AuthContext;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_rules).post(create_rule))
        // Static segments BEFORE /{id} or they're swallowed as an id.
        .route("/upcoming", get(upcoming))
        .route("/calendar", get(calendar))
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
    let (ny, nm) = if month == 12 {
        (year + 1, 1)
    } else {
        (year, month + 1)
    };
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
fn effective_next_due(
    cadence: &str,
    anchor_day: u32,
    seed: NaiveDate,
    today: NaiveDate,
) -> NaiveDate {
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

fn rule_dto_from_row(
    row: &sqlx::postgres::PgRow,
    today: NaiveDate,
) -> anyhow::Result<RecurringRuleDto> {
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
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "description is required",
        ));
    }
    if req.amount == Decimal::ZERO {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "amount must be non-zero",
        ));
    }
    if !CADENCES.contains(&req.cadence.as_str()) {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "cadence must be one of weekly, biweekly, monthly, yearly",
        ));
    }
    let anchor_day = req.anchor_day.unwrap_or(req.next_due_date.day() as i16);
    if !(1..=31).contains(&anchor_day) {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "anchor_day must be 1-31",
        ));
    }
    let currency = req.currency.trim().to_uppercase();
    if currency.is_empty() || currency.len() > 8 {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "currency is required",
        ));
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
    .bind(
        req.category
            .as_deref()
            .map(str::trim)
            .filter(|c| !c.is_empty()),
    )
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
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "to must be on/after from",
        ));
    }
    // DoS clamp: expansion cost scales with the window; a year is far more
    // than the cash-flow view ever asks for.
    if (to - from).num_days() > 400 {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "window too large (max 400 days)",
        ));
    }

    let rows = sqlx::query(&format!(
        "{RULE_SELECT_SQL} WHERE r.user_id = $1 AND r.active ORDER BY r.created_at"
    ))
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;

    let usd_mxn = latest_usd_mxn(&state.db).await.map_err(internal)?;

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
                rule_id: r
                    .try_get::<uuid::Uuid, _>("id")
                    .map_err(internal)?
                    .to_string(),
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
    items.sort_by(|a, b| {
        a.due_date
            .cmp(&b.due_date)
            .then(a.description.cmp(&b.description))
    });

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
// Bills calendar: occurrence states + expected↔posted matching + projection
// ---------------------------------------------------------------------------

/// Latest USD→MXN rate for converting expected (often future-dated) MXN
/// amounts. "Rate on tx date" (the tax.rs rule) doesn't apply — these dates
/// are estimates — so latest-known is the honest choice. Same hard fallback
/// (20.0) and rate>0 guard as `services/fx.rs::USD_MXN_ROW_RATE_SQL`.
async fn latest_usd_mxn(db: &sqlx::PgPool) -> Result<Decimal, sqlx::Error> {
    Ok(sqlx::query_scalar(
        "SELECT rate FROM exchange_rates \
         WHERE base_currency = 'USD' AND target_currency = 'MXN' AND rate > 0 \
         ORDER BY recorded_at DESC LIMIT 1",
    )
    .fetch_optional(db)
    .await?
    .unwrap_or(crate::services::fx::FX_FALLBACK_USD_MXN_DEC))
}

/// Amount tolerance for matching an expected bill to a posted transaction.
/// Wider than loan_match's 2% disbursement band because utility bills vary
/// month to month (a CFE bill is "about $400", not exactly $400); tighter
/// than "anything goes" so a same-day grocery run can't swallow the rent.
const BILL_AMOUNT_TOL: f64 = 0.10;
/// Absolute floor on the tolerance band, so tiny bills (where 10% is
/// sub-dollar) still match a near-exact posted row. Mirrors
/// `loan_match::DISBURSE_AMOUNT_TOL_ABS`.
const BILL_AMOUNT_TOL_ABS: f64 = 1.0;
/// Date window around a due date. Bills clear a few days early (autopay
/// pulled on a weekend boundary) or late (manual payment); ±5 matches the
/// FX-transfer linker's window and keeps adjacent monthly occurrences of
/// the same rule (28+ days apart) from competing for one posted row.
const BILL_DATE_WINDOW_DAYS: i64 = 5;
/// An unmatched occurrence this many days overdue or fewer is "late";
/// beyond it, "missed". Both render as attention states — the split just
/// lets the UI soften a bill that's two days behind vs. a month behind.
const LATE_GRACE_DAYS: i64 = 7;

/// Match confidence, 0–100 (same linear-ramp shape as
/// `loan_match::score_disbursement` — that module is the house precedent
/// for expected↔posted scoring; don't invent a new heuristic). Amount is
/// the dominant signal (same account + currency, no FX noise), date second,
/// a description-token hit a bonus. Suggestions below 50 don't match.
fn score_bill_match(amount_dev: f64, gap_days: i64, desc_hit: bool) -> i32 {
    let mut score = 0i32;
    let amount_used = (amount_dev / BILL_AMOUNT_TOL).clamp(0.0, 1.0);
    score += (55.0 * (1.0 - amount_used)) as i32;
    let date_used = (gap_days as f64 / BILL_DATE_WINDOW_DAYS as f64).clamp(0.0, 1.0);
    score += (35.0 * (1.0 - date_used)) as i32;
    if desc_hit {
        score += 10;
    }
    score.min(95)
}

/// Does any token (≥3 chars) of the rule's description appear in the posted
/// row's text? Same tokenization as `loan_match::borrower_name_hit`, over
/// the two text fields a bill row reliably carries.
fn description_hit(rule_description: &str, tx_description: &str, merchant: Option<&str>) -> bool {
    let tokens: Vec<String> = rule_description
        .split_whitespace()
        .filter(|t| t.len() >= 3)
        .map(|t| t.to_uppercase())
        .collect();
    if tokens.is_empty() {
        return false;
    }
    let haystack = format!(
        "{} \u{1f} {}",
        tx_description.to_uppercase(),
        merchant.unwrap_or_default().to_uppercase()
    );
    tokens.iter().any(|t| haystack.contains(t.as_str()))
}

/// How current an account's *transaction* data is, for deciding whether an
/// overdue-and-unmatched bill is genuinely missed or just not imported yet.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum AccountFreshness {
    /// Synced (Plaid etc.): transactions arrive continuously, so absence of
    /// a match at an overdue date is real evidence.
    Synced,
    /// Manual statement-import account: data only covers through the newest
    /// imported transaction DATE (None = no transactions ever imported).
    /// Deliberately NOT `updated_at` / snapshot dates: a balance update or
    /// an import performed today can still only *cover* through the
    /// statement's last row — matching runs on posted transactions, so
    /// coverage must be measured in transaction dates or a bill due after
    /// the statement cut-off renders a false red.
    ManualCoveredThrough(Option<NaiveDate>),
}

/// Occurrence state (pure — unit-tested below).
///
/// The hard requirement from FUTURE.md: an account whose data arrives by
/// manual statement import must NEVER show `late`/`missed` for a due date
/// its imported data doesn't cover yet — mid-cycle the app cannot
/// distinguish "missed" from "not yet imported", and a false red destroys
/// trust faster than no calendar.
fn occurrence_state(
    due: NaiveDate,
    today: NaiveDate,
    matched: bool,
    freshness: AccountFreshness,
) -> &'static str {
    if matched {
        return "paid";
    }
    if due >= today {
        return "upcoming";
    }
    if let AccountFreshness::ManualCoveredThrough(coverage) = freshness {
        let covered = coverage.map(|c| due <= c).unwrap_or(false);
        if !covered {
            return "pending_import";
        }
    }
    if (today - due).num_days() <= LATE_GRACE_DAYS {
        "late"
    } else {
        "missed"
    }
}

#[derive(Deserialize, Default)]
struct CalendarQuery {
    /// Forward horizon in days; clamped to 1..=90 (silent clamp, matching
    /// the staleness-threshold policy — a hostile value degrades, it
    /// doesn't error). The window also looks the same distance back so
    /// past occurrences' states are visible on the calendar.
    days: Option<i64>,
}

#[derive(Serialize)]
struct CalendarOccurrence {
    /// "recurring" (a recurring_rules expansion) or "loan" (a loan_payments
    /// schedule row — an expected repayment INFLOW to the lender).
    source: String,
    /// rule id for recurring; loan_payments id for loans.
    id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    account_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    account_name: Option<String>,
    description: String,
    /// Native-currency signed amount (negative = expected outflow), same
    /// convention as transactions.amount.
    amount: Decimal,
    currency: String,
    /// Per-row USD conversion (house rule: the frontend never does FX).
    amount_usd: Decimal,
    due_date: String,
    /// paid | upcoming | late | missed | pending_import.
    state: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    matched_tx_id: Option<String>,
}

#[derive(Serialize)]
struct ProjectionPoint {
    date: String,
    /// Projected cash per currency bucket. Native amounts — a per-currency
    /// curve needs no FX (the whole point is "will THIS currency's cash go
    /// negative"); only `amount_usd` on occurrences converts.
    usd: Decimal,
    mxn: Decimal,
}

#[derive(Serialize)]
struct FxTransferSuggestion {
    /// The currency whose projected cash crosses below zero.
    deficit_currency: String,
    /// The currency that stays positive across the whole window.
    surplus_currency: String,
    /// First date the deficit curve is below zero.
    date: String,
    /// Deepest projected shortfall, as a positive magnitude in the deficit
    /// currency (native — converting it would obscure "how much to move").
    shortfall: Decimal,
}

#[derive(Serialize)]
struct CalendarResponse {
    from: String,
    to: String,
    today: String,
    days: i64,
    occurrences: Vec<CalendarOccurrence>,
    /// One point per day from today through today+days (cumulative).
    projection: Vec<ProjectionPoint>,
    /// Informational only — "move USD→MXN before the 15th". No automation.
    #[serde(skip_serializing_if = "Option::is_none")]
    fx_transfer_suggestion: Option<FxTransferSuggestion>,
}

/// One posted-transaction candidate for expected↔posted matching.
struct BillCandidate {
    id: uuid::Uuid,
    account_id: uuid::Uuid,
    date: NaiveDate,
    amount: Decimal,
    currency: String,
    description: String,
    merchant_name: Option<String>,
}

/// GET /calendar?days=N — the bills-calendar feed: every expected
/// occurrence (recurring rules + loan schedule dues) in [today-N, today+N]
/// with a matched/paid/late/pending-import state, plus the per-currency
/// projected cash curve over [today, today+N] and an FX-transfer
/// suggestion when one currency is projected to run dry while the other
/// stays positive. Display-only: nothing here posts or mutates anything.
async fn calendar(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<CalendarQuery>,
) -> Result<Json<CalendarResponse>, ApiError> {
    let days = q.days.unwrap_or(30).clamp(1, 90);
    let today = chrono::Utc::now().date_naive();
    let from = today - chrono::Duration::days(days);
    let to = today + chrono::Duration::days(days);

    // Active rules + whether each account is a manual statement-import one
    // (institution-level flag, same classifier as services/staleness.rs).
    let rule_rows = sqlx::query(
        r#"
        SELECT r.id, r.account_id,
               COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name,
               r.description, r.amount, r.currency,
               r.cadence, r.anchor_day, r.next_due_date,
               (i.integration_type = 'manual') AS is_manual
        FROM recurring_rules r
        JOIN accounts a ON a.id = r.account_id
        JOIN institutions i ON i.id = a.institution_id
        WHERE r.user_id = $1 AND r.active
        ORDER BY r.created_at
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;

    // Data-coverage date per account: the newest posted transaction DATE
    // (see AccountFreshness for why not updated_at / snapshots). One query
    // for all of the user's accounts — the set is small.
    let coverage_rows = sqlx::query(
        r#"
        SELECT a.id AS account_id, MAX(t.date) AS newest_tx_date
        FROM accounts a
        LEFT JOIN transactions t ON t.account_id = a.id AND t.user_id = $1
        WHERE a.user_id = $1
        GROUP BY a.id
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;
    let mut coverage: HashMap<uuid::Uuid, Option<NaiveDate>> = HashMap::new();
    for r in &coverage_rows {
        coverage.insert(
            r.try_get("account_id").map_err(internal)?,
            r.try_get("newest_tx_date").ok(),
        );
    }

    // Posted-transaction candidates for matching: the rules' accounts,
    // windowed to [from - match window, today] (an expected occurrence can
    // be paid a few days early, so the window reaches slightly past any
    // in-window due date that's already reachable by a posted row). Split
    // parents are excluded like loan_match does — their children carry the
    // real spend.
    let rule_account_ids: Vec<uuid::Uuid> = {
        let mut ids: Vec<uuid::Uuid> = Vec::new();
        for r in &rule_rows {
            let id: uuid::Uuid = r.try_get("account_id").map_err(internal)?;
            if !ids.contains(&id) {
                ids.push(id);
            }
        }
        ids
    };
    let mut candidates: Vec<BillCandidate> = Vec::new();
    if !rule_account_ids.is_empty() {
        let tx_rows = sqlx::query(
            r#"
            SELECT t.id, t.account_id, t.date, t.amount, t.currency,
                   t.description, t.merchant_name
            FROM transactions t
            WHERE t.user_id = $1
              AND t.account_id = ANY($2)
              AND t.date BETWEEN $3 AND $4
              AND NOT EXISTS (SELECT 1 FROM transactions c WHERE c.parent_id = t.id)
            ORDER BY t.date ASC
            LIMIT 5000
            "#,
        )
        .bind(ctx.user_id)
        .bind(&rule_account_ids)
        .bind(from - chrono::Duration::days(BILL_DATE_WINDOW_DAYS))
        .bind(today)
        .fetch_all(&state.db)
        .await
        .map_err(internal)?;
        for r in &tx_rows {
            candidates.push(BillCandidate {
                id: r.try_get("id").map_err(internal)?,
                account_id: r.try_get("account_id").map_err(internal)?,
                date: r.try_get("date").map_err(internal)?,
                amount: r.try_get("amount").map_err(internal)?,
                currency: r.try_get("currency").map_err(internal)?,
                description: r.try_get::<String, _>("description").unwrap_or_default(),
                merchant_name: r.try_get("merchant_name").ok(),
            });
        }
    }

    let usd_mxn = latest_usd_mxn(&state.db).await.map_err(internal)?;
    let to_usd = |amount: Decimal, currency: &str| -> Decimal {
        // Per-row FX→USD BEFORE any summing (house invariant): MXN divides
        // by the latest rate; every other currency is USD-equivalent
        // ("trust the native amount"), matching AMOUNT_USD_SQL.
        if currency.eq_ignore_ascii_case("MXN") {
            (amount / usd_mxn).round_dp(2)
        } else {
            amount
        }
    };

    // Expand rule occurrences, then greedily match each (date-ascending, so
    // an earlier occurrence gets first claim) against the best-scoring
    // unused posted row. Hard gates first (account, currency, sign, date
    // window, amount band), then the loan_match-style linear-ramp score.
    struct PendingOccurrence {
        rule_idx: usize,
        due: NaiveDate,
    }
    let mut pending: Vec<PendingOccurrence> = Vec::new();
    for (idx, r) in rule_rows.iter().enumerate() {
        let cadence: String = r.try_get("cadence").map_err(internal)?;
        let anchor_day: i16 = r.try_get("anchor_day").map_err(internal)?;
        let seed: NaiveDate = r.try_get("next_due_date").map_err(internal)?;
        for due in occurrences_in_window(&cadence, anchor_day.max(1) as u32, seed, from, to) {
            pending.push(PendingOccurrence { rule_idx: idx, due });
        }
    }
    pending.sort_by_key(|p| p.due);

    let mut used_tx: HashSet<uuid::Uuid> = HashSet::new();
    let mut occurrences: Vec<CalendarOccurrence> = Vec::new();
    for p in &pending {
        let r = &rule_rows[p.rule_idx];
        let account_id: uuid::Uuid = r.try_get("account_id").map_err(internal)?;
        let amount: Decimal = r.try_get("amount").map_err(internal)?;
        let currency: String = r.try_get("currency").map_err(internal)?;
        let description: String = r.try_get("description").map_err(internal)?;
        let is_manual: bool = r.try_get("is_manual").unwrap_or(false);

        let mut best: Option<(i32, i64, uuid::Uuid)> = None; // (score, gap, tx id)
        for c in &candidates {
            if used_tx.contains(&c.id)
                || c.account_id != account_id
                || !c.currency.eq_ignore_ascii_case(&currency)
                || c.amount.is_sign_negative() != amount.is_sign_negative()
            {
                continue;
            }
            let gap = (c.date - p.due).num_days().abs();
            if gap > BILL_DATE_WINDOW_DAYS {
                continue;
            }
            // Amount band: 10% of the expected magnitude, floored at $1
            // absolute (Decimal math end-to-end; f64 only for the score).
            let expected_abs = amount.abs();
            let diff = (c.amount.abs() - expected_abs).abs();
            let tol = (expected_abs
                * Decimal::from_f64_retain(BILL_AMOUNT_TOL).unwrap_or_default())
            .max(Decimal::from_f64_retain(BILL_AMOUNT_TOL_ABS).unwrap_or_default());
            if diff > tol {
                continue;
            }
            let amount_dev = if expected_abs > Decimal::ZERO {
                (diff / expected_abs).to_f64().unwrap_or(1.0)
            } else {
                1.0
            };
            let hit = description_hit(&description, &c.description, c.merchant_name.as_deref());
            let score = score_bill_match(amount_dev, gap, hit);
            if score < 50 {
                continue;
            }
            if best
                .map(|(s, g, _)| (score, -gap) > (s, -g))
                .unwrap_or(true)
            {
                best = Some((score, gap, c.id));
            }
        }
        let matched_tx_id = best.map(|(_, _, id)| id);
        if let Some(id) = matched_tx_id {
            used_tx.insert(id);
        }

        let freshness = if is_manual {
            AccountFreshness::ManualCoveredThrough(coverage.get(&account_id).copied().flatten())
        } else {
            AccountFreshness::Synced
        };
        let state_str = occurrence_state(p.due, today, matched_tx_id.is_some(), freshness);
        occurrences.push(CalendarOccurrence {
            source: "recurring".to_string(),
            id: r
                .try_get::<uuid::Uuid, _>("id")
                .map_err(internal)?
                .to_string(),
            account_id: Some(account_id.to_string()),
            account_name: r.try_get("account_name").ok(),
            description,
            amount,
            currency: currency.clone(),
            amount_usd: to_usd(amount, &currency),
            due_date: p.due.to_string(),
            state: state_str.to_string(),
            matched_tx_id: matched_tx_id.map(|id| id.to_string()),
        });
    }

    // Loan schedule dues: expected repayment INFLOWS. paid/skipped state
    // lives on the loan_payments row itself (the reconcile flow writes it),
    // so no re-matching here. A loan due has no bound cash account until
    // reconciled, so the pending_import guard doesn't apply — overdue
    // unpaid installments read late/missed, consistent with the lending
    // tab's aging report. paid_off loans stay included so a mid-window
    // payoff still shows its paid installments.
    let loan_rows = sqlx::query(
        r#"
        SELECT p.id, l.borrower_name, l.currency, p.due_date,
               p.scheduled_amount, p.paid_amount,
               (p.status = 'paid' OR p.actual_tx_id IS NOT NULL) AS is_paid,
               p.actual_tx_id
        FROM loan_payments p
        JOIN loans l ON l.id = p.loan_id AND l.user_id = p.user_id
        WHERE p.user_id = $1
          AND p.status <> 'skipped'
          AND p.due_date IS NOT NULL
          AND p.due_date BETWEEN $2 AND $3
          AND l.status IN ('active', 'paid_off')
        ORDER BY p.due_date ASC
        "#,
    )
    .bind(ctx.user_id)
    .bind(from)
    .bind(to)
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;
    for r in &loan_rows {
        let due: NaiveDate = r.try_get("due_date").map_err(internal)?;
        let is_paid: bool = r.try_get("is_paid").unwrap_or(false);
        let scheduled: Decimal = r.try_get("scheduled_amount").unwrap_or_default();
        let paid: Option<Decimal> = r.try_get("paid_amount").ok();
        // Show what actually arrived once paid; the expectation otherwise.
        let amount = if is_paid {
            paid.unwrap_or(scheduled)
        } else {
            scheduled
        };
        let currency: String = r.try_get("currency").map_err(internal)?;
        let state_str = occurrence_state(due, today, is_paid, AccountFreshness::Synced);
        occurrences.push(CalendarOccurrence {
            source: "loan".to_string(),
            id: r
                .try_get::<uuid::Uuid, _>("id")
                .map_err(internal)?
                .to_string(),
            account_id: None,
            account_name: None,
            description: r.try_get("borrower_name").unwrap_or_default(),
            amount,
            currency: currency.clone(),
            amount_usd: to_usd(amount, &currency),
            due_date: due.to_string(),
            state: state_str.to_string(),
            matched_tx_id: r
                .try_get::<uuid::Uuid, _>("actual_tx_id")
                .ok()
                .map(|id| id.to_string()),
        });
    }
    occurrences.sort_by(|a, b| {
        a.due_date
            .cmp(&b.due_date)
            .then(a.description.cmp(&b.description))
    });

    // Starting cash per currency: each depository account's LATEST snapshot
    // (DISTINCT ON = the carry-forward pattern collapsed to a single "as of
    // today" point — every account contributes its last-known balance, so
    // an account that hasn't snapshotted in a week still counts; a per-date
    // GROUP BY would drop it, the skill's #1 bug class). Cash-like accounts
    // only (loan_match::DEPOSITORY_TYPES — you don't pay rent from a
    // brokerage); the liability classifier flips sign the same way the
    // net-worth queries do, though a liability-typed depository account is
    // a data oddity in practice.
    let depository: Vec<String> = crate::services::loan_match::DEPOSITORY_TYPES
        .iter()
        .map(|s| s.to_string())
        .collect();
    let snap_rows = sqlx::query(
        r#"
        SELECT DISTINCT ON (bs.account_id)
               bs.balance, bs.currency,
               is_liability_account_type(a.account_type) AS is_liability
        FROM balance_snapshots bs
        JOIN accounts a ON a.id = bs.account_id
        WHERE bs.user_id = $1
          AND a.archived_at IS NULL
          AND LOWER(a.account_type) = ANY($2)
        ORDER BY bs.account_id, bs.as_of_date DESC, bs.id DESC
        "#,
    )
    .bind(ctx.user_id)
    .bind(&depository)
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;
    let mut start_usd = Decimal::ZERO;
    let mut start_mxn = Decimal::ZERO;
    for r in &snap_rows {
        let balance: Decimal = r.try_get("balance").unwrap_or_default();
        let is_liability: bool = r.try_get("is_liability").unwrap_or(false);
        let signed = if is_liability {
            -balance.abs()
        } else {
            balance
        };
        let currency: String = r.try_get("currency").unwrap_or_default();
        // Per-currency buckets, NEVER a cross-currency sum: MXN cash is its
        // own curve; every other currency rides the USD curve (the
        // AMOUNT_USD_SQL "USD-equivalent" convention).
        if currency.eq_ignore_ascii_case("MXN") {
            start_mxn += signed;
        } else {
            start_usd += signed;
        }
    }

    // Daily deltas from occurrences still expected to clear: state
    // "upcoming" only. Paid rows are already in the balances; late/missed/
    // pending_import ones have unknowable timing, and silently projecting
    // them forward would double-book the pessimism the states already show.
    let mut delta_by_day: HashMap<NaiveDate, (Decimal, Decimal)> = HashMap::new();
    for o in &occurrences {
        if o.state != "upcoming" {
            continue;
        }
        let Ok(due) = o.due_date.parse::<NaiveDate>() else {
            continue;
        };
        if due < today || due > to {
            continue;
        }
        let entry = delta_by_day
            .entry(due)
            .or_insert((Decimal::ZERO, Decimal::ZERO));
        if o.currency.eq_ignore_ascii_case("MXN") {
            entry.1 += o.amount;
        } else {
            entry.0 += o.amount;
        }
    }
    let mut projection = Vec::with_capacity(days as usize + 1);
    let mut run_usd = start_usd;
    let mut run_mxn = start_mxn;
    for offset in 0..=days {
        let d = today + chrono::Duration::days(offset);
        if let Some((du, dm)) = delta_by_day.get(&d) {
            run_usd += *du;
            run_mxn += *dm;
        }
        projection.push(ProjectionPoint {
            date: d.to_string(),
            usd: run_usd.round_dp(2),
            mxn: run_mxn.round_dp(2),
        });
    }

    // FX-transfer suggestion: one currency's curve crosses below zero while
    // the other stays positive at EVERY point — i.e. the shortfall is
    // fixable by moving the user's own money across. Informational only.
    let usd_min = projection.iter().map(|p| p.usd).min().unwrap_or_default();
    let mxn_min = projection.iter().map(|p| p.mxn).min().unwrap_or_default();
    let first_below = |pick: fn(&ProjectionPoint) -> Decimal| {
        projection
            .iter()
            .find(|p| pick(p) < Decimal::ZERO)
            .map(|p| p.date.clone())
    };
    let fx_transfer_suggestion = if usd_min < Decimal::ZERO && mxn_min > Decimal::ZERO {
        first_below(|p| p.usd).map(|date| FxTransferSuggestion {
            deficit_currency: "USD".to_string(),
            surplus_currency: "MXN".to_string(),
            date,
            shortfall: usd_min.abs(),
        })
    } else if mxn_min < Decimal::ZERO && usd_min > Decimal::ZERO {
        first_below(|p| p.mxn).map(|date| FxTransferSuggestion {
            deficit_currency: "MXN".to_string(),
            surplus_currency: "USD".to_string(),
            date,
            shortfall: mxn_min.abs(),
        })
    } else {
        None
    };

    Ok(Json(CalendarResponse {
        from: from.to_string(),
        to: to.to_string(),
        today: today.to_string(),
        days,
        occurrences,
        projection,
        fx_transfer_suggestion,
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
        let occ =
            occurrences_in_window("monthly", 31, d(2026, 1, 31), d(2026, 1, 1), d(2026, 4, 30));
        assert_eq!(
            occ,
            vec![
                d(2026, 1, 31),
                d(2026, 2, 28),
                d(2026, 3, 31),
                d(2026, 4, 30)
            ]
        );
    }

    #[test]
    fn biweekly_steps_fourteen_days() {
        let occ =
            occurrences_in_window("biweekly", 1, d(2026, 7, 3), d(2026, 7, 1), d(2026, 7, 31));
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
        let occ =
            occurrences_in_window("yearly", 29, d(2024, 2, 29), d(2025, 1, 1), d(2027, 12, 31));
        assert_eq!(occ, vec![d(2025, 2, 28), d(2026, 2, 28), d(2027, 2, 28)]);
    }

    #[test]
    fn bill_match_score_bands() {
        // Exact amount, same day, description hit → near-max.
        assert!(score_bill_match(0.0, 0, true) >= 90);
        // Exact amount, 3 days off, no hit → still comfortably a match.
        assert!(score_bill_match(0.0, 3, false) >= 60);
        // Amount at the tolerance edge, same day, no hit → below the 50
        // threshold: amount is the dominant signal.
        assert!(score_bill_match(BILL_AMOUNT_TOL, 0, false) < 50);
    }

    #[test]
    fn occurrence_state_matrix() {
        let today = d(2026, 8, 3);
        // Matched wins regardless of date or freshness.
        assert_eq!(
            occurrence_state(d(2026, 7, 1), today, true, AccountFreshness::Synced),
            "paid"
        );
        // Future (or today) and unmatched → upcoming.
        assert_eq!(
            occurrence_state(today, today, false, AccountFreshness::Synced),
            "upcoming"
        );
        // Overdue on a synced account: late inside the grace window,
        // missed beyond it.
        assert_eq!(
            occurrence_state(d(2026, 8, 1), today, false, AccountFreshness::Synced),
            "late"
        );
        assert_eq!(
            occurrence_state(d(2026, 7, 1), today, false, AccountFreshness::Synced),
            "missed"
        );
    }

    #[test]
    fn manual_account_uncovered_due_is_pending_import_never_missed() {
        // THE hard requirement (FUTURE.md): a manual-import account whose
        // newest imported data predates the due date must read
        // pending_import, not late/missed — the bill may simply not be
        // imported yet.
        let today = d(2026, 8, 3);
        let covered_through = Some(d(2026, 7, 10));
        assert_eq!(
            occurrence_state(
                d(2026, 7, 15),
                today,
                false,
                AccountFreshness::ManualCoveredThrough(covered_through)
            ),
            "pending_import"
        );
        // No data ever imported → also pending_import.
        assert_eq!(
            occurrence_state(
                d(2026, 7, 15),
                today,
                false,
                AccountFreshness::ManualCoveredThrough(None)
            ),
            "pending_import"
        );
        // But once the imported data COVERS the due date, absence of a
        // match is real evidence — the normal late/missed ladder applies.
        assert_eq!(
            occurrence_state(
                d(2026, 7, 1),
                today,
                false,
                AccountFreshness::ManualCoveredThrough(Some(d(2026, 7, 20)))
            ),
            "missed"
        );
    }

    #[test]
    fn description_tokens_match_case_insensitively() {
        assert!(description_hit("CFE Electricity", "PAGO CFE SSC", None));
        assert!(description_hit("Gym", "gym membership", None));
        assert!(description_hit(
            "Netflix",
            "CARGO RECURRENTE",
            Some("NETFLIX.COM")
        ));
        // Tokens under 3 chars never match on their own.
        assert!(!description_hit("Al", "PAYMENT ALPHA", None));
        assert!(!description_hit("Rent", "SUPER OXXO", None));
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
