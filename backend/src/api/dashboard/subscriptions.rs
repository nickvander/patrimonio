use axum::{
    extract::{Extension, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use tracing::error;

use crate::api::middleware::AuthContext;
use crate::services::subscription_detect::detect_recurring_charges;
use crate::AppState;

#[derive(Serialize)]
pub(super) struct DetectedSubscription {
    /// Display label for the merchant. Picked from the same ladder as
    /// the transactions list so renames propagate.
    merchant: String,
    /// The detector's normalised clustering key — lowercased + trimmed
    /// `merchant`, and exactly what `ignored_subscription_merchants
    /// .merchant_key` stores. **This is the value the ignore endpoint
    /// wants** (`POST /api/dashboard/subscriptions/ignore`, whose wire
    /// field is confusingly named `merchant`) and the value the
    /// un-ignore path segment takes (`DELETE
    /// /api/dashboard/subscriptions/ignored/{merchant_key}`).
    ///
    /// Exposed so a client can dismiss a card by echoing a server-supplied
    /// string instead of re-deriving the detector's normalisation itself —
    /// a re-derivation that silently stops matching the moment the
    /// detector's key rules change. `/api/recurring/calendar` carries the
    /// same field on its detected occurrences for the same reason.
    merchant_key: String,
    /// Monthly burn in USD (sum of all charges / number-of-months observed).
    /// Always positive — sign is implied (it's a recurring outflow).
    monthly_usd: f64,
    /// Estimated cadence in days between the two most recent charges.
    /// 30 = monthly, 7 = weekly, etc.
    cadence_days: i32,
    /// Date (YYYY-MM-DD) of the most recent charge.
    last_charge_date: String,
    /// Native amount + currency of the most recent charge so the UI
    /// can format it correctly.
    last_amount: f64,
    currency: String,
    /// How many separate charges we saw. >= 3 to qualify as recurring.
    occurrences: i32,
    /// "active" when last charge is within 90 days, "cancelled" when
    /// the cluster qualified as recurring at some point but hasn't
    /// charged in the last 90 days. The frontend renders cancelled
    /// subscriptions in a separate, collapsed "Stopped" section so
    /// the user can audit "did I actually cancel that?".
    status: &'static str,
    /// Per-account distribution within the cluster. Surfaces the
    /// "Apple Pay charged Visa AND a fee landed on Checking" case so
    /// the user can see which channel(s) are paying. Sorted descending
    /// by `total_native`; the largest contributor first.
    by_account: Vec<SubscriptionAccountSlice>,
}

#[derive(Serialize)]
struct SubscriptionAccountSlice {
    /// Account display name (nickname when set, else bank-supplied name).
    account_name: String,
    /// Number of charges that landed on this account in the cluster's
    /// observed window.
    occurrences: i32,
    /// Absolute spend on this account in the cluster's native currency.
    total_native: f64,
    /// Share of the cluster total (0.0–1.0). Lets the frontend draw
    /// a tiny inline bar without recomputing.
    share: f64,
}

/// Detected recurring outflows (subscriptions, bills, gym dues, etc.).
///
/// The clustering heuristic itself lives in
/// `services::subscription_detect` — it is shared with the bills calendar
/// (`GET /api/recurring/calendar`), which projects the same clusters
/// forward as expected occurrences. Keeping one detector means the card
/// and the calendar can never disagree about what recurs, and the
/// ignored-merchants predicate is applied in exactly one place.
///
/// This handler is the presentation layer only: FX→USD normalisation of
/// the per-month figure, ordering, and the display cap.
///
/// Each item carries both `merchant` (display label) and `merchant_key`
/// (the detector's normalised key). Dismissing a card means POSTing the
/// **`merchant_key`** to `/api/dashboard/subscriptions/ignore` — see
/// `IgnoreSubscriptionRequest` for why the wire field there is still
/// spelled `merchant`.
///
/// Returns sorted by status (active first), then by monthly_usd
/// descending so the most expensive subscriptions surface first.
pub(super) async fn detected_subscriptions(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<DetectedSubscription>> {
    // Best-effort read: this card is informational, so a detection failure
    // renders an empty card rather than a 500 on the dashboard. (The
    // calendar, where an empty detected set is semantically meaningful —
    // it is the bug this feature exists to fix — propagates the error
    // instead.)
    let clusters = detect_recurring_charges(&state.db, ctx.user_id)
        .await
        .unwrap_or_default();
    if clusters.is_empty() {
        return Json(vec![]);
    }

    // Look up the latest USD/MXN rate once for the monthly_usd
    // normalisation. A MXN-denominated subscription gets reported in
    // USD so the user can compare totals across currencies. If the
    // rate is missing we conservatively skip MXN rows from the USD
    // total — they'll still appear with their native amount.
    let fx_mxn_row = sqlx::query(
        "SELECT rate FROM exchange_rates WHERE base_currency = 'USD' AND target_currency = 'MXN' \
         ORDER BY recorded_at DESC LIMIT 1",
    )
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten();
    let fx_mxn: Option<f64> = fx_mxn_row
        .and_then(|r| r.try_get::<rust_decimal::Decimal, _>("rate").ok())
        .and_then(|d| d.to_string().parse::<f64>().ok())
        .filter(|r| *r > 0.0);

    let mut out: Vec<DetectedSubscription> = clusters
        .iter()
        .map(|c| {
            // Per-row FX→USD (house invariant): MXN divides by the latest
            // rate; every other currency is treated as USD-equivalent
            // ("trust the native amount"), matching AMOUNT_USD_SQL. A
            // missing rate zeroes only the USD projection — the native
            // amount still renders.
            let monthly_usd = if c.currency.eq_ignore_ascii_case("MXN") {
                match fx_mxn {
                    Some(r) => c.avg_per_month_native / r,
                    None => 0.0,
                }
            } else {
                c.avg_per_month_native
            };
            DetectedSubscription {
                merchant: c.merchant.clone(),
                merchant_key: c.merchant_key.clone(),
                monthly_usd,
                cadence_days: c.cadence_days as i32,
                last_charge_date: c.last_charge_date.to_string(),
                last_amount: c.last_amount,
                currency: c.currency.clone(),
                occurrences: c.occurrences,
                status: c.status,
                by_account: c
                    .by_account
                    .iter()
                    .map(|a| SubscriptionAccountSlice {
                        account_name: a.account_name.clone(),
                        occurrences: a.occurrences,
                        total_native: a.total_native,
                        share: a.share,
                    })
                    .collect(),
            }
        })
        .collect();

    // Active first (sorted by monthly spend), then cancelled (sorted by
    // recency of last charge — most recently stopped is most actionable).
    out.sort_by(|a, b| match (a.status, b.status) {
        ("active", "cancelled") => std::cmp::Ordering::Less,
        ("cancelled", "active") => std::cmp::Ordering::Greater,
        ("cancelled", "cancelled") => b.last_charge_date.cmp(&a.last_charge_date),
        _ => b
            .monthly_usd
            .partial_cmp(&a.monthly_usd)
            .unwrap_or(std::cmp::Ordering::Equal),
    });
    out.truncate(40);
    Json(out)
}

#[derive(Deserialize)]
pub(super) struct IgnoreSubscriptionRequest {
    /// **Wire field name `merchant`; expected content is the
    /// `merchant_key`.** Send the `merchant_key` served by
    /// `GET /api/dashboard/subscriptions` (or by a detected occurrence of
    /// `GET /api/recurring/calendar`) — the detector's normalised
    /// clustering key — NOT the human-readable `merchant` display label.
    ///
    /// The name is a legacy of the field predating `merchant_key` being
    /// exposed at all; renaming it would break the shipped web + Android
    /// clients, so the mismatch is documented instead of fixed.
    ///
    /// The handler normalises the incoming value with
    /// `.trim().to_lowercase()` before storing it. That happens to be the
    /// *entire* derivation of `merchant_key` from `merchant` today, so a
    /// display label currently round-trips by accident — but it is an
    /// accident, not a contract: the moment the detector's key rules gain
    /// a step (punctuation stripping, POS-suffix trimming, …), a display
    /// label starts producing a key that matches no cluster. And an
    /// unmatched key does **not** error — the row inserts and the handler
    /// returns 204 while the card stays exactly where it was. Only an
    /// empty-after-trim value is rejected (400).
    merchant: String,
}

/// Mark a detected-subscription cluster as "not a subscription."
/// Lands a row in `ignored_subscription_merchants`; subsequent
/// detector runs skip the key entirely. The user can re-confirm by
/// just letting the cluster come back.
///
/// Takes `{"merchant": "<merchant_key>"}` — the wire field is named
/// `merchant` for backwards compatibility but the value must be the
/// detector's normalised `merchant_key` (now served on every
/// subscriptions item); see `IgnoreSubscriptionRequest`. Undo is
/// `DELETE /api/dashboard/subscriptions/ignored/{merchant_key}`.
pub(super) async fn ignore_subscription(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Json(req): Json<IgnoreSubscriptionRequest>,
) -> StatusCode {
    let key = req.merchant.trim().to_lowercase();
    if key.is_empty() {
        return StatusCode::BAD_REQUEST;
    }
    let result = sqlx::query(
        "INSERT INTO ignored_subscription_merchants (user_id, merchant_key) \
         VALUES ($1, $2) ON CONFLICT DO NOTHING",
    )
    .bind(ctx.user_id)
    .bind(&key)
    .execute(&state.db)
    .await;
    match result {
        Ok(_) => StatusCode::NO_CONTENT,
        Err(e) => {
            error!("ignore_subscription failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

#[derive(Serialize)]
pub(super) struct IgnoredSubscription {
    merchant_key: String,
    ignored_at: String,
}

/// List every dismissed subscription merchant for this user. Used by
/// the "Manage hidden subscriptions" panel so the user can undo a
/// previous dismiss without manually editing the DB.
pub(super) async fn list_ignored_subscriptions(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<IgnoredSubscription>> {
    let rows = sqlx::query(
        "SELECT merchant_key, ignored_at FROM ignored_subscription_merchants \
         WHERE user_id = $1 ORDER BY ignored_at DESC",
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .filter_map(|r| {
                let merchant_key = r.try_get::<String, _>("merchant_key").ok()?;
                let ignored_at = r
                    .try_get::<chrono::DateTime<chrono::Utc>, _>("ignored_at")
                    .ok()
                    .map(|d| d.to_rfc3339())
                    .unwrap_or_default();
                Some(IgnoredSubscription {
                    merchant_key,
                    ignored_at,
                })
            })
            .collect(),
    )
}

/// Un-ignore: delete the row so the detector can re-surface this
/// merchant on its next run. Idempotent — returns 204 either way
/// (deleting a non-existent ignore is a no-op).
pub(super) async fn unignore_subscription(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    axum::extract::Path(merchant_key): axum::extract::Path<String>,
) -> StatusCode {
    let key = merchant_key.trim().to_lowercase();
    if key.is_empty() {
        return StatusCode::BAD_REQUEST;
    }
    let result = sqlx::query(
        "DELETE FROM ignored_subscription_merchants \
         WHERE user_id = $1 AND merchant_key = $2",
    )
    .bind(ctx.user_id)
    .bind(&key)
    .execute(&state.db)
    .await;
    match result {
        Ok(_) => StatusCode::NO_CONTENT,
        Err(e) => {
            error!("unignore_subscription failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}
