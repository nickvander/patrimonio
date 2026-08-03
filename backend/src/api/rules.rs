//! User rules engine — CRUD + the dry-run/apply safety contract.
//!
//! See `work/RULES_ENGINE_DESIGN.md` §4 and DEC-027/DEC-028. The
//! non-negotiable invariant this module implements:
//!
//! > **`POST /api/rules/{id}/apply` is the ONLY statement anywhere in the
//! > codebase that writes `user_*` with `*_source = 'rule'` onto
//! > pre-existing rows**, and it only ever runs with a valid,
//! > fingerprint-matched, single-use preview token. Creating, editing,
//! > enabling, disabling or deleting a rule mutates ZERO `transactions`
//! > rows.
//!
//! Everything else (import confirm, Plaid sync) applies rules on INSERT
//! only, so a rule can never silently rewrite spending history — which
//! would move tax and cash-flow totals under the owner.

use axum::{
    extract::{Path, State},
    http::StatusCode,
    routing::{get, patch, post},
    Extension, Json, Router,
};
use base64::Engine as _;
use rand::RngCore;
use redis::AsyncCommands;
use rust_decimal::Decimal;
use serde::{Deserialize, Deserializer, Serialize};
use sqlx::Row;
use uuid::Uuid;

use crate::api::error::{internal, ApiError};
use crate::api::middleware::AuthContext;
use crate::services::realtime::RealtimeEvent;
use crate::services::rules::{
    self, RuleInput, UserRule, CATEGORY_UNPROTECTED_SQL, DESCRIPTION_UNPROTECTED_SQL, RULE_COLUMNS,
};
use crate::AppState;

/// How long a previewed diff stays applicable. Long enough to read the
/// sample list and confirm, short enough that the world hasn't moved
/// under it. The apply re-asserts the manual-protection predicate in SQL
/// anyway, so a stale-but-live token still can't clobber a human edit.
const PREVIEW_TTL_SECONDS: u64 = 900;

/// Cap on the sample rows returned with a preview — the diff UI shows a
/// scrollable excerpt, not the whole match set (which can be thousands of
/// rows on a long history).
const MAX_SAMPLES: usize = 50;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_rules).post(create_rule))
        // Static segments BEFORE /{id} or axum swallows them as an id.
        .route("/preview", post(preview_rule))
        .route("/reorder", patch(reorder_rules))
        .route("/{id}", patch(update_rule).delete(delete_rule))
        .route("/{id}/apply", post(apply_rule))
}

// ---------------------------------------------------------------------------
// DTOs
// ---------------------------------------------------------------------------

/// A rule definition as the client states it. Used verbatim by create and
/// by preview — the preview endpoint takes the definition inline (not an
/// id) so the diff works BEFORE the rule exists as well as for edits.
#[derive(Debug, Deserialize)]
struct RuleDefinition {
    match_type: String,
    match_value: String,
    #[serde(default)]
    account_id: Option<Uuid>,
    #[serde(default)]
    currency: Option<String>,
    #[serde(default)]
    direction: Option<String>,
    #[serde(default)]
    amount_min: Option<Decimal>,
    #[serde(default)]
    amount_max: Option<Decimal>,
    #[serde(default)]
    set_category: Option<String>,
    #[serde(default)]
    set_description: Option<String>,
}

#[derive(Debug, Deserialize)]
struct CreateRuleRequest {
    #[serde(flatten)]
    definition: RuleDefinition,
    #[serde(default)]
    active: Option<bool>,
}

/// Distinguish "key absent" from "key present and null" so a PATCH can
/// both *leave a scope alone* and *clear it*. `Option<Option<T>>` alone
/// isn't enough — serde maps a JSON `null` to the OUTER `None` — hence the
/// explicit `deserialize_with`.
fn present_option<'de, T, D>(deserializer: D) -> Result<Option<T>, D::Error>
where
    T: Deserialize<'de>,
    D: Deserializer<'de>,
{
    T::deserialize(deserializer).map(Some)
}

/// Partial edit. Absent field = leave alone; explicit `null` = clear.
/// The handler merges the patch onto the stored row and re-validates the
/// MERGED definition, so a patch can't produce a rule the create path
/// would have rejected.
#[derive(Debug, Deserialize)]
struct UpdateRuleRequest {
    #[serde(default)]
    match_type: Option<String>,
    #[serde(default)]
    match_value: Option<String>,
    #[serde(default, deserialize_with = "present_option")]
    account_id: Option<Option<Uuid>>,
    #[serde(default, deserialize_with = "present_option")]
    currency: Option<Option<String>>,
    #[serde(default, deserialize_with = "present_option")]
    direction: Option<Option<String>>,
    #[serde(default, deserialize_with = "present_option")]
    amount_min: Option<Option<Decimal>>,
    #[serde(default, deserialize_with = "present_option")]
    amount_max: Option<Option<Decimal>>,
    #[serde(default, deserialize_with = "present_option")]
    set_category: Option<Option<String>>,
    #[serde(default, deserialize_with = "present_option")]
    set_description: Option<Option<String>>,
    #[serde(default)]
    priority: Option<i32>,
    #[serde(default)]
    active: Option<bool>,
}

#[derive(Debug, Serialize)]
struct RuleDto {
    id: String,
    match_type: String,
    match_value: String,
    account_id: Option<String>,
    currency: Option<String>,
    direction: Option<String>,
    amount_min: Option<Decimal>,
    amount_max: Option<Decimal>,
    set_category: Option<String>,
    set_description: Option<String>,
    priority: i32,
    active: bool,
    created_at: String,
    updated_at: String,
}

impl From<&UserRule> for RuleDto {
    fn from(r: &UserRule) -> Self {
        Self {
            id: r.id.to_string(),
            match_type: r.match_type.clone(),
            match_value: r.match_value.clone(),
            account_id: r.account_id.map(|a| a.to_string()),
            currency: r.currency.clone(),
            direction: r.direction.clone(),
            amount_min: r.amount_min,
            amount_max: r.amount_max,
            set_category: r.set_category.clone(),
            set_description: r.set_description.clone(),
            priority: r.priority,
            active: r.active,
            created_at: r.created_at.to_rfc3339(),
            updated_at: r.updated_at.to_rfc3339(),
        }
    }
}

#[derive(Debug, Serialize)]
struct PreviewSample {
    id: String,
    date: String,
    account_name: String,
    /// What the transactions list shows for this row today — the same
    /// ladder the frontend uses (`user_description → counterparty →
    /// merchant → original_description → description`).
    display_description: String,
    old_category: Option<String>,
    new_category: Option<String>,
    old_description: Option<String>,
    new_description: Option<String>,
}

#[derive(Debug, Serialize)]
struct PreviewResponse {
    /// Rows the rule matches at all.
    matched: usize,
    /// Matched rows whose DISPLAYED category would change. The apply also
    /// stamps provenance on matched rows whose value is already correct,
    /// so `updated_category` from the apply can exceed this by the number
    /// of such no-op-in-display rows.
    category_changes: usize,
    description_changes: usize,
    /// Matched rows left alone because a human set that field.
    skipped_manual: usize,
    /// Matched rows that are legs of a confirmed cross-currency transfer.
    /// Recategorizing one re-enters it into cash-flow totals (the spending
    /// anti-joins key off category) — allowed, but the diff warns
    /// (DEC-028).
    fx_transfer_legs: usize,
    /// `categorize::merchant_key` of the entered match value — feeds the
    /// merchant_key matcher UI so the user sees the key their rule will
    /// actually compare against.
    derived_merchant_key: String,
    samples: Vec<PreviewSample>,
    preview_token: String,
    expires_in_seconds: u64,
}

/// What the preview stashes in Redis. Plain JSON, not encrypted: unlike
/// the passkey flow state (`api/passkeys.rs`), this holds no credential —
/// only transaction ids the caller already owns, and the capability is the
/// 192-bit random token itself, which is namespaced by user id in the key.
#[derive(Debug, Serialize, Deserialize)]
struct PreviewState {
    user_id: Uuid,
    rule_fingerprint: String,
    category_ids: Vec<Uuid>,
    description_ids: Vec<Uuid>,
}

#[derive(Debug, Deserialize)]
struct ApplyRequest {
    preview_token: String,
}

#[derive(Debug, Serialize)]
struct ApplyResponse {
    updated_category: u64,
    updated_description: u64,
    /// Previewed rows the apply did NOT touch because they were manually
    /// edited between preview and apply. Surfaced in the UI honestly
    /// rather than swallowed.
    skipped: u64,
}

#[derive(Debug, Deserialize)]
struct ReorderRequest {
    ordered_ids: Vec<Uuid>,
}

// ---------------------------------------------------------------------------
// Validation
// ---------------------------------------------------------------------------

/// A validated, canonicalized definition. Empty strings collapse to
/// `None` so "cleared in the UI" and "never set" are the same stored
/// state, and the CHECK constraints in the migration can't fire as a 500.
struct CleanDefinition {
    match_type: String,
    match_value: String,
    account_id: Option<Uuid>,
    currency: Option<String>,
    direction: Option<String>,
    amount_min: Option<Decimal>,
    amount_max: Option<Decimal>,
    set_category: Option<String>,
    set_description: Option<String>,
}

fn blank_to_none(v: Option<String>) -> Option<String> {
    v.map(|s| s.trim().to_string()).filter(|s| !s.is_empty())
}

fn bad(msg: &str) -> ApiError {
    ApiError::new(StatusCode::BAD_REQUEST, msg)
}

fn validate(def: RuleDefinition) -> Result<CleanDefinition, ApiError> {
    let match_type = def.match_type.trim().to_ascii_lowercase();
    if !rules::MATCH_TYPES.contains(&match_type.as_str()) {
        return Err(bad(
            "match_type must be one of merchant_key, contains, starts_with, exact",
        ));
    }
    let match_value = def.match_value.trim().to_string();
    if match_value.is_empty() {
        return Err(bad("match_value can't be empty"));
    }
    let currency = blank_to_none(def.currency).map(|c| c.to_uppercase());
    let direction = blank_to_none(def.direction).map(|d| d.to_ascii_lowercase());
    if let Some(d) = direction.as_deref() {
        if !rules::DIRECTIONS.contains(&d) {
            return Err(bad("direction must be inflow or outflow"));
        }
    }
    for amount in [def.amount_min, def.amount_max].into_iter().flatten() {
        if amount < Decimal::ZERO {
            return Err(bad(
                "amount bounds are positive magnitudes (they compare ABS(amount))",
            ));
        }
    }
    if let (Some(min), Some(max)) = (def.amount_min, def.amount_max) {
        if max < min {
            return Err(bad("amount_max must be >= amount_min"));
        }
    }
    let set_category = blank_to_none(def.set_category);
    let set_description = blank_to_none(def.set_description);
    if set_category.is_none() && set_description.is_none() {
        return Err(bad("a rule must set a category, a description, or both"));
    }
    Ok(CleanDefinition {
        match_type,
        match_value,
        account_id: def.account_id,
        currency,
        direction,
        amount_min: def.amount_min,
        amount_max: def.amount_max,
        set_category,
        set_description,
    })
}

/// A scoped account must belong to the caller — otherwise a rule could be
/// scoped to (and preview rows from) someone else's account.
async fn assert_owns_account(
    state: &AppState,
    ctx: &AuthContext,
    account_id: Option<Uuid>,
) -> Result<(), ApiError> {
    let Some(id) = account_id else {
        return Ok(());
    };
    let owns = sqlx::query("SELECT 1 FROM accounts WHERE id = $1 AND user_id = $2")
        .bind(id)
        .bind(ctx.user_id)
        .fetch_optional(&state.db)
        .await
        .map_err(internal)?;
    if owns.is_none() {
        return Err(ApiError::new(StatusCode::NOT_FOUND, "account not found"));
    }
    Ok(())
}

/// Build the in-memory rule the matcher evaluates. `id`/`priority`/
/// `active` are irrelevant to matching a single definition (and to the
/// fingerprint), so preview passes a nil id.
fn transient_rule(def: &CleanDefinition, id: Uuid) -> UserRule {
    let now = chrono::Utc::now();
    UserRule {
        id,
        match_type: def.match_type.clone(),
        match_value: def.match_value.clone(),
        account_id: def.account_id,
        currency: def.currency.clone(),
        direction: def.direction.clone(),
        amount_min: def.amount_min,
        amount_max: def.amount_max,
        set_category: def.set_category.clone(),
        set_description: def.set_description.clone(),
        priority: 0,
        active: true,
        created_at: now,
        updated_at: now,
    }
}

// ---------------------------------------------------------------------------
// CRUD — none of these touch `transactions`
// ---------------------------------------------------------------------------

async fn list_rules(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Result<Json<Vec<RuleDto>>, ApiError> {
    let rows = sqlx::query(&format!(
        "SELECT {RULE_COLUMNS} FROM user_rules WHERE user_id = $1 \
         ORDER BY priority ASC, created_at ASC, id ASC"
    ))
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;
    Ok(Json(
        rows.iter()
            .map(|r| RuleDto::from(&rules::rule_from_row(r)))
            .collect(),
    ))
}

async fn create_rule(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Json(payload): Json<CreateRuleRequest>,
) -> Result<(StatusCode, Json<RuleDto>), ApiError> {
    let def = validate(payload.definition)?;
    assert_owns_account(&state, &ctx, def.account_id).await?;

    // New rules append at the end of the evaluation order. The
    // MAX-subselect runs inside the INSERT so two concurrent creates
    // can't both read the same max.
    let row = sqlx::query(&format!(
        "INSERT INTO user_rules \
             (user_id, match_type, match_value, account_id, currency, direction, \
              amount_min, amount_max, set_category, set_description, priority, active) \
         VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, \
                 (SELECT COALESCE(MAX(priority), -10) + 10 FROM user_rules WHERE user_id = $1), $11) \
         RETURNING {RULE_COLUMNS}"
    ))
    .bind(ctx.user_id)
    .bind(&def.match_type)
    .bind(&def.match_value)
    .bind(def.account_id)
    .bind(&def.currency)
    .bind(&def.direction)
    .bind(def.amount_min)
    .bind(def.amount_max)
    .bind(&def.set_category)
    .bind(&def.set_description)
    .bind(payload.active.unwrap_or(true))
    .fetch_one(&state.db)
    .await
    .map_err(internal)?;

    Ok((
        StatusCode::CREATED,
        Json(RuleDto::from(&rules::rule_from_row(&row))),
    ))
}

async fn update_rule(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<Uuid>,
    Json(payload): Json<UpdateRuleRequest>,
) -> Result<Json<RuleDto>, ApiError> {
    let existing = sqlx::query(&format!(
        "SELECT {RULE_COLUMNS} FROM user_rules WHERE id = $1 AND user_id = $2"
    ))
    .bind(id)
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await
    .map_err(internal)?
    .map(|r| rules::rule_from_row(&r))
    .ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, "rule not found"))?;

    // Merge the patch onto the stored definition, then validate the
    // result — a partial edit can't sneak past the create-path rules.
    let merged = RuleDefinition {
        match_type: payload.match_type.unwrap_or(existing.match_type),
        match_value: payload.match_value.unwrap_or(existing.match_value),
        account_id: payload.account_id.unwrap_or(existing.account_id),
        currency: payload.currency.unwrap_or(existing.currency),
        direction: payload.direction.unwrap_or(existing.direction),
        amount_min: payload.amount_min.unwrap_or(existing.amount_min),
        amount_max: payload.amount_max.unwrap_or(existing.amount_max),
        set_category: payload.set_category.unwrap_or(existing.set_category),
        set_description: payload.set_description.unwrap_or(existing.set_description),
    };
    let def = validate(merged)?;
    assert_owns_account(&state, &ctx, def.account_id).await?;

    let row = sqlx::query(&format!(
        "UPDATE user_rules SET \
             match_type = $1, match_value = $2, account_id = $3, currency = $4, \
             direction = $5, amount_min = $6, amount_max = $7, set_category = $8, \
             set_description = $9, priority = $10, active = $11, updated_at = NOW() \
         WHERE id = $12 AND user_id = $13 \
         RETURNING {RULE_COLUMNS}"
    ))
    .bind(&def.match_type)
    .bind(&def.match_value)
    .bind(def.account_id)
    .bind(&def.currency)
    .bind(&def.direction)
    .bind(def.amount_min)
    .bind(def.amount_max)
    .bind(&def.set_category)
    .bind(&def.set_description)
    .bind(payload.priority.unwrap_or(existing.priority))
    .bind(payload.active.unwrap_or(existing.active))
    .bind(id)
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await
    .map_err(internal)?
    .ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, "rule not found"))?;

    Ok(Json(RuleDto::from(&rules::rule_from_row(&row))))
}

/// Delete a rule. The values it already applied are KEPT (DEC-028): the
/// FK is `ON DELETE SET NULL`, so `*_rule_id` goes NULL while `*_source`
/// stays `'rule'` — machine-owned residue a future rule may overwrite,
/// but never a silent rewrite of history.
async fn delete_rule(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    let res = sqlx::query("DELETE FROM user_rules WHERE id = $1 AND user_id = $2")
        .bind(id)
        .bind(ctx.user_id)
        .execute(&state.db)
        .await
        .map_err(internal)?;
    if res.rows_affected() == 0 {
        return Err(ApiError::new(StatusCode::NOT_FOUND, "rule not found"));
    }
    Ok(StatusCode::NO_CONTENT)
}

/// Rewrite priorities from a client-supplied order (the management
/// screen's drag handle). Spaced by 10 so a later single-rule nudge has
/// room without a full rewrite.
async fn reorder_rules(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Json(payload): Json<ReorderRequest>,
) -> Result<Json<Vec<RuleDto>>, ApiError> {
    if payload.ordered_ids.is_empty() {
        return Err(bad("ordered_ids can't be empty"));
    }
    let mut tx = state.db.begin().await.map_err(internal)?;
    for (i, id) in payload.ordered_ids.iter().enumerate() {
        let res = sqlx::query(
            "UPDATE user_rules SET priority = $1, updated_at = NOW() \
             WHERE id = $2 AND user_id = $3",
        )
        .bind((i as i32) * 10)
        .bind(id)
        .bind(ctx.user_id)
        .execute(&mut *tx)
        .await
        .map_err(internal)?;
        if res.rows_affected() == 0 {
            // An id the caller doesn't own (or a stale list) would
            // otherwise leave a half-applied order behind.
            return Err(ApiError::new(StatusCode::NOT_FOUND, "rule not found"));
        }
    }
    tx.commit().await.map_err(internal)?;

    let rows = sqlx::query(&format!(
        "SELECT {RULE_COLUMNS} FROM user_rules WHERE user_id = $1 \
         ORDER BY priority ASC, created_at ASC, id ASC"
    ))
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;
    Ok(Json(
        rows.iter()
            .map(|r| RuleDto::from(&rules::rule_from_row(r)))
            .collect(),
    ))
}

// ---------------------------------------------------------------------------
// Preview (dry run) — reads only
// ---------------------------------------------------------------------------

/// Coarse prefilter: the caller's rows, narrowed by the rule's account /
/// currency scope only. Everything else (matcher, direction, amount
/// range) is decided in Rust by the single matcher, so the dry run and
/// the apply can never disagree about which rows match. No LIMIT: the
/// previewed id set must be the COMPLETE change set, and this is a
/// single-household deployment.
const PREVIEW_ROWS_SQL: &str = r#"
    SELECT t.id, t.date, t.description, t.original_description, t.merchant_name,
           t.counterparty_name, t.amount, t.currency, t.account_id, t.category,
           t.user_category, t.user_category_source,
           t.user_description, t.user_description_source,
           a.name AS account_name,
           EXISTS (
               SELECT 1 FROM cash_fx_transfers f
               WHERE (f.source_tx_id = t.id OR f.dest_tx_id = t.id)
                 AND (f.user_confirmed OR f.detection_confidence >= 70)
           ) AS is_fx_leg
      FROM transactions t
      JOIN accounts a ON a.id = t.account_id
     WHERE t.user_id = $1
       AND ($2::uuid IS NULL OR t.account_id = $2)
       AND ($3::text IS NULL OR UPPER(t.currency) = UPPER($3))
     ORDER BY t.date DESC, t.id DESC
"#;

async fn preview_rule(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Json(payload): Json<RuleDefinition>,
) -> Result<Json<PreviewResponse>, ApiError> {
    let def = validate(payload)?;
    assert_owns_account(&state, &ctx, def.account_id).await?;
    let rule = transient_rule(&def, Uuid::nil());
    let rule_set = [rule.clone()];

    let rows = sqlx::query(PREVIEW_ROWS_SQL)
        .bind(ctx.user_id)
        .bind(def.account_id)
        .bind(&def.currency)
        .fetch_all(&state.db)
        .await
        .map_err(internal)?;

    let mut matched = 0usize;
    let mut category_changes = 0usize;
    let mut description_changes = 0usize;
    let mut skipped_manual = 0usize;
    let mut fx_transfer_legs = 0usize;
    let mut category_ids: Vec<Uuid> = Vec::new();
    let mut description_ids: Vec<Uuid> = Vec::new();
    let mut samples: Vec<PreviewSample> = Vec::new();

    for row in &rows {
        let description: String = row.get("description");
        let original_description: Option<String> =
            row.try_get("original_description").ok().flatten();
        let merchant_name: Option<String> = row.try_get("merchant_name").ok().flatten();
        let counterparty_name: Option<String> = row.try_get("counterparty_name").ok().flatten();
        let currency: String = row.get("currency");
        let amount: Decimal = row.get("amount");
        let account_id: Uuid = row.get("account_id");

        let outcome = rules::apply_rules(
            &rule_set,
            &RuleInput {
                description: &description,
                original_description: original_description.as_deref(),
                merchant_name: merchant_name.as_deref(),
                counterparty_name: counterparty_name.as_deref(),
                amount,
                currency: &currency,
                account_id,
            },
        );
        if outcome.is_empty() {
            continue;
        }
        matched += 1;
        if row.try_get::<bool, _>("is_fx_leg").unwrap_or(false) {
            fx_transfer_legs += 1;
        }

        let id: Uuid = row.get("id");
        let base_category: Option<String> = row.try_get("category").ok().flatten();
        let user_category: Option<String> = row.try_get("user_category").ok().flatten();
        let user_category_source: Option<String> =
            row.try_get("user_category_source").ok().flatten();
        let user_description: Option<String> = row.try_get("user_description").ok().flatten();
        let user_description_source: Option<String> =
            row.try_get("user_description_source").ok().flatten();

        // Effective values = what the user sees today (every read path
        // prefers the user_* column, falling back to the base column).
        let effective_category = user_category
            .clone()
            .filter(|v| !v.is_empty())
            .or_else(|| base_category.clone());
        let display_description = user_description
            .clone()
            .filter(|v| !v.is_empty())
            .or_else(|| counterparty_name.clone())
            .or_else(|| merchant_name.clone())
            .or_else(|| original_description.clone())
            .unwrap_or_else(|| description.clone());

        let mut row_protected = false;
        let mut new_category: Option<String> = None;
        let mut new_description: Option<String> = None;

        if let Some((value, _)) = outcome.category.as_ref() {
            if rules::is_protected(user_category.as_deref(), user_category_source.as_deref()) {
                row_protected = true;
            } else {
                category_ids.push(id);
                if effective_category.as_deref() != Some(value.as_str()) {
                    category_changes += 1;
                    new_category = Some(value.clone());
                }
            }
        }
        if let Some((value, _)) = outcome.description.as_ref() {
            if rules::is_protected(
                user_description.as_deref(),
                user_description_source.as_deref(),
            ) {
                row_protected = true;
            } else {
                description_ids.push(id);
                if display_description != *value {
                    description_changes += 1;
                    new_description = Some(value.clone());
                }
            }
        }
        if row_protected {
            skipped_manual += 1;
        }

        if samples.len() < MAX_SAMPLES && (new_category.is_some() || new_description.is_some()) {
            let date: chrono::NaiveDate = row.get("date");
            samples.push(PreviewSample {
                id: id.to_string(),
                date: date.to_string(),
                account_name: row.get("account_name"),
                display_description: display_description.clone(),
                old_category: effective_category.clone(),
                new_category,
                old_description: Some(display_description),
                new_description,
            });
        }
    }

    // Mint the single-use token LAST, so a failure above never leaves a
    // token pointing at a half-computed id set.
    let token = random_token();
    let state_payload = PreviewState {
        user_id: ctx.user_id,
        rule_fingerprint: rules::fingerprint(&rule),
        category_ids,
        description_ids,
    };
    let json = serde_json::to_string(&state_payload).map_err(internal)?;
    let mut conn = state
        .redis
        .get_multiplexed_async_connection()
        .await
        .map_err(internal)?;
    let _: () = conn
        .set_ex(preview_key(ctx.user_id, &token), json, PREVIEW_TTL_SECONDS)
        .await
        .map_err(internal)?;

    Ok(Json(PreviewResponse {
        matched,
        category_changes,
        description_changes,
        skipped_manual,
        fx_transfer_legs,
        derived_merchant_key: crate::services::categorize::merchant_key(&def.match_value),
        samples,
        preview_token: token,
        expires_in_seconds: PREVIEW_TTL_SECONDS,
    }))
}

/// Namespaced by user id so one caller can never even *probe* another
/// caller's token: a mismatched user simply misses the key.
fn preview_key(user_id: Uuid, token: &str) -> String {
    format!("rules:preview:{user_id}:{token}")
}

fn random_token() -> String {
    let mut bytes = [0u8; 24];
    rand::thread_rng().fill_bytes(&mut bytes);
    base64::engine::general_purpose::URL_SAFE_NO_PAD.encode(bytes)
}

// ---------------------------------------------------------------------------
// Apply — the ONLY endpoint that rewrites history
// ---------------------------------------------------------------------------

async fn apply_rule(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<Uuid>,
    Json(payload): Json<ApplyRequest>,
) -> Result<Json<ApplyResponse>, ApiError> {
    let rule = sqlx::query(&format!(
        "SELECT {RULE_COLUMNS} FROM user_rules WHERE id = $1 AND user_id = $2"
    ))
    .bind(id)
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await
    .map_err(internal)?
    .map(|r| rules::rule_from_row(&r))
    .ok_or_else(|| ApiError::new(StatusCode::NOT_FOUND, "rule not found"))?;

    // GETDEL: the token is consumed atomically, so a double-click (or a
    // replayed request) can't fire the apply twice.
    let mut conn = state
        .redis
        .get_multiplexed_async_connection()
        .await
        .map_err(internal)?;
    let raw: Option<String> = conn
        .get_del(preview_key(ctx.user_id, &payload.preview_token))
        .await
        .map_err(internal)?;
    let raw = raw.ok_or_else(|| {
        ApiError::new(
            StatusCode::CONFLICT,
            "This preview has expired or was already applied. Re-run the preview.",
        )
    })?;
    let preview: PreviewState = serde_json::from_str(&raw).map_err(internal)?;
    // Defense in depth — the key is already user-namespaced.
    if preview.user_id != ctx.user_id {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "This preview belongs to a different session. Re-run the preview.",
        ));
    }
    // A rule edited after the preview would apply values the user never
    // saw in the diff. That is exactly the silent rewrite this feature
    // exists to prevent, so it's a hard 409, not a re-computation.
    if preview.rule_fingerprint != rules::fingerprint(&rule) {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "The rule changed after this preview was generated. Re-run the preview.",
        ));
    }

    let mut tx = state.db.begin().await.map_err(internal)?;
    let mut updated_category = 0u64;
    let mut updated_description = 0u64;

    if rule.set_category.is_some() && !preview.category_ids.is_empty() {
        // The protection predicate is RE-ASSERTED here, not trusted from
        // the preview: a row a human edited between preview and apply is
        // skipped, never clobbered.
        let res = sqlx::query(&format!(
            "UPDATE transactions \
                SET user_category = $1, user_category_source = 'rule', user_category_rule_id = $2 \
              WHERE id = ANY($3) AND user_id = $4 AND {CATEGORY_UNPROTECTED_SQL}"
        ))
        .bind(rule.set_category.as_deref())
        .bind(rule.id)
        .bind(&preview.category_ids)
        .bind(ctx.user_id)
        .execute(&mut *tx)
        .await
        .map_err(internal)?;
        updated_category = res.rows_affected();
    }
    if rule.set_description.is_some() && !preview.description_ids.is_empty() {
        let res = sqlx::query(&format!(
            "UPDATE transactions \
                SET user_description = $1, user_description_source = 'rule', \
                    user_description_rule_id = $2 \
              WHERE id = ANY($3) AND user_id = $4 AND {DESCRIPTION_UNPROTECTED_SQL}"
        ))
        .bind(rule.set_description.as_deref())
        .bind(rule.id)
        .bind(&preview.description_ids)
        .bind(ctx.user_id)
        .execute(&mut *tx)
        .await
        .map_err(internal)?;
        updated_description = res.rows_affected();
    }
    tx.commit().await.map_err(internal)?;

    let previewed = (preview.category_ids.len() + preview.description_ids.len()) as u64;
    let skipped = previewed.saturating_sub(updated_category + updated_description);

    state
        .realtime
        .publish(ctx.user_id, RealtimeEvent::TransactionsChanged)
        .await;

    Ok(Json(ApplyResponse {
        updated_category,
        updated_description,
        skipped,
    }))
}
