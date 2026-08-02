use axum::{
    extract::{Extension, State},
    http::StatusCode,
    Json,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use tracing::error;

use crate::api::middleware::AuthContext;
use crate::AppState;

use super::*;

#[derive(Serialize)]
pub(super) struct DetectedSubscription {
    /// Display label for the merchant. Picked from the same ladder as
    /// the transactions list so renames propagate.
    merchant: String,
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
/// Heuristic: group every **expense** transaction (amount < 0 in this
/// app's sign convention — see `cash_flow_trends` and the Plaid sync
/// path; outflows are stored as negative, inflows as positive) of the
/// last 12 months by a merchant key + amount band. A cluster qualifies
/// as "recurring" when:
///   * ≥ 3 occurrences,
///   * median gap between consecutive charges is 5–62 days (covers
///     weekly through bi-monthly cadence; one-off bursts are filtered
///     out by the gap floor, annual renewals are filtered out by the
///     gap ceiling — both can be added if anyone asks).
///   * Most recent charge is within 90 days (within 91–548 days the
///     cluster is flagged `status: "cancelled"`; older than that is
///     dropped as noise).
///
/// We deliberately exclude income-shaped rows: a checking account
/// that receives monthly "Interest Earned" credits would otherwise
/// match the recurring shape and surface as a fake subscription.
///
/// Returns sorted by status (active first), then by monthly_usd
/// descending so the most expensive subscriptions surface first.
pub(super) async fn detected_subscriptions(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<DetectedSubscription>> {
    // Pull the user's dismissed-as-not-subscription set first, so we
    // can skip those keys during clustering. Small table; we hold the
    // whole thing in memory.
    let ignored_rows =
        sqlx::query("SELECT merchant_key FROM ignored_subscription_merchants WHERE user_id = $1")
            .bind(ctx.user_id)
            .fetch_all(&state.db)
            .await
            .unwrap_or_default();
    let ignored: std::collections::HashSet<String> = ignored_rows
        .iter()
        .filter_map(|r| r.try_get::<String, _>("merchant_key").ok())
        .collect();
    // Same non-spend exclusions the cash-flow views apply (via the shared
    // fragments), so a recurring internal transfer, credit-card payment, loan
    // leg, or investment buy doesn't cluster into a phantom "subscription"
    // (honors user re-tags). The positive-only anti-joins are no-ops here.
    let sql = format!(
        r#"
        SELECT
            t.date, t.amount, t.currency, t.account_id,
            t.description, t.merchant_name, t.counterparty_name,
            t.user_description, t.payment_payee,
            COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        WHERE t.user_id = $1
          -- Outflows only. Sign convention: amount < 0 = expense,
          -- amount > 0 = income. Including income would surface
          -- "Interest earned" / "Dividend" / "Salary" as fake
          -- "subscriptions" once their recurring shape clusters.
          AND t.amount < 0
          AND t.date >= CURRENT_DATE - INTERVAL '548 days'
          AND {EFFECTIVE_CATEGORY_SQL} NOT IN {NON_CASHFLOW_CATEGORIES_SQL}{CASHFLOW_ROW_ANTI_JOINS_SQL}
        ORDER BY t.date DESC
        "#,
    );
    let rows = sqlx::query(&sql)
        .bind(ctx.user_id)
        .fetch_all(&state.db)
        .await
        .unwrap_or_default();

    if rows.is_empty() {
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

    // Build a key per (normalised merchant, amount band). Amount band
    // is the rounded-to-nearest-dollar value, so a $9.99 / $10.00 /
    // $10.01 Netflix sequence all cluster (banks occasionally vary
    // sub-cent on rolling charges).
    use std::collections::HashMap;
    struct AccountTally {
        display: String,
        count: u32,
        // Absolute spend on this account in the cluster's native
        // currency. Sign is implied by the cluster (outflow).
        total_native: f64,
    }
    struct Cluster {
        merchant: String,
        currency: String,
        // (date_yyyymmdd, amount_native_positive) for every observed
        // charge. Amounts are stored as the *absolute* value of the
        // raw row so downstream math (median gap, monthly average)
        // can stay sign-agnostic.
        events: Vec<(chrono::NaiveDate, f64)>,
        // Per-account spend within the cluster, keyed by account UUID.
        // Used to surface "Apple Pay charged Visa AND a fee landed on
        // Checking" when the same merchant clusters across accounts.
        by_account: HashMap<uuid::Uuid, AccountTally>,
    }
    let mut clusters: HashMap<String, Cluster> = HashMap::new();

    fn merchant_key(
        user_desc: Option<&str>,
        counterparty: Option<&str>,
        merchant: Option<&str>,
        payee: Option<&str>,
        description: &str,
    ) -> String {
        // Mirrors the frontend's display ladder (excluding original
        // description, which is too noisy for clustering — POS reference
        // codes vary per swipe). Lowercase + trim so case doesn't split
        // clusters.
        let raw = user_desc
            .filter(|s| !s.trim().is_empty())
            .or(counterparty.filter(|s| !s.trim().is_empty()))
            .or(merchant.filter(|s| !s.trim().is_empty()))
            .or(payee.filter(|s| !s.trim().is_empty()))
            .unwrap_or(description);
        raw.trim().to_lowercase()
    }

    fn display_merchant(
        user_desc: Option<&str>,
        counterparty: Option<&str>,
        merchant: Option<&str>,
        payee: Option<&str>,
        description: &str,
    ) -> String {
        // Pick the most user-recognisable name for display. Same source
        // ladder as `merchant_key` but preserves the original case.
        user_desc
            .filter(|s| !s.trim().is_empty())
            .or(counterparty.filter(|s| !s.trim().is_empty()))
            .or(merchant.filter(|s| !s.trim().is_empty()))
            .or(payee.filter(|s| !s.trim().is_empty()))
            .unwrap_or(description)
            .trim()
            .to_string()
    }

    for r in &rows {
        let date: chrono::NaiveDate = match r.try_get("date") {
            Ok(d) => d,
            Err(_) => continue,
        };
        let raw_amount: f64 = r
            .try_get::<rust_decimal::Decimal, _>("amount")
            .ok()
            .and_then(|d| d.to_string().parse().ok())
            .unwrap_or(0.0);
        // SQL filter already restricts to amount < 0, but a defensive
        // sign check here keeps the loop honest if the WHERE clause is
        // ever softened. From this point on `amount` is the absolute
        // outflow magnitude — sign is implied by the cluster.
        if raw_amount >= 0.0 {
            continue;
        }
        let amount = raw_amount.abs();
        let currency: String = r.try_get("currency").unwrap_or_else(|_| "USD".into());
        let description: String = r.try_get("description").unwrap_or_default();
        let account_id: uuid::Uuid = match r.try_get("account_id") {
            Ok(id) => id,
            Err(_) => continue,
        };
        let account_name: String = r
            .try_get::<String, _>("account_name")
            .unwrap_or_else(|_| "Account".into());
        let merchant_name: Option<String> = r
            .try_get::<Option<String>, _>("merchant_name")
            .ok()
            .flatten();
        let counterparty_name: Option<String> = r
            .try_get::<Option<String>, _>("counterparty_name")
            .ok()
            .flatten();
        let user_description: Option<String> = r
            .try_get::<Option<String>, _>("user_description")
            .ok()
            .flatten();
        let payment_payee: Option<String> = r
            .try_get::<Option<String>, _>("payment_payee")
            .ok()
            .flatten();

        let key_part = merchant_key(
            user_description.as_deref(),
            counterparty_name.as_deref(),
            merchant_name.as_deref(),
            payment_payee.as_deref(),
            &description,
        );
        // Skip generic strings that we can't meaningfully cluster on —
        // letting them through would lump every "Miscellaneous Debit"
        // row together and report a fake subscription.
        let lower = key_part.as_str();
        let generic_prefixes = [
            "miscellaneous",
            "ach ",
            "pos ",
            "online ",
            "wire ",
            "transfer",
            "debit",
            "credit",
            "withdrawal",
            "deposit",
            "bill payment",
            "electronic ",
        ];
        if generic_prefixes
            .iter()
            .any(|p| lower == *p || lower.starts_with(p))
        {
            continue;
        }
        // User-dismissed cluster ("this isn't a subscription"). Skip
        // the merchant entirely — the dismissed key matches whatever
        // the detector clustered on at the time, so re-running won't
        // re-surface it unless the underlying tx data changed in a
        // way that produces a different key.
        if ignored.contains(&key_part) {
            continue;
        }
        let band = amount.round() as i64;
        let key = format!("{key_part}::{band}");
        let display_name = display_merchant(
            user_description.as_deref(),
            counterparty_name.as_deref(),
            merchant_name.as_deref(),
            payment_payee.as_deref(),
            &description,
        );
        let cluster = clusters.entry(key).or_insert_with(|| Cluster {
            merchant: display_name.clone(),
            currency: currency.clone(),
            events: Vec::new(),
            by_account: HashMap::new(),
        });
        cluster.events.push((date, amount));
        let tally = cluster
            .by_account
            .entry(account_id)
            .or_insert(AccountTally {
                display: account_name,
                count: 0,
                total_native: 0.0,
            });
        tally.count += 1;
        tally.total_native += amount;
    }

    let today = chrono::Utc::now().date_naive();
    let mut out = Vec::new();
    for cluster in clusters.values_mut() {
        // Most-recent first; we already pulled rows ORDER BY date DESC
        // but sort again for safety.
        cluster.events.sort_by_key(|e| std::cmp::Reverse(e.0));

        if cluster.events.len() < 3 {
            continue;
        }
        let last_charge = cluster.events[0].0;
        let days_since = (today - last_charge).num_days();
        // Either "active" (last charge ≤ 90 days) or "cancelled" (between
        // 91 days and 18 months ago). Clusters older than that are
        // unlikely to be useful audit signal, so drop them entirely.
        let status: &'static str = if days_since <= 90 {
            "active"
        } else if days_since <= 548 {
            "cancelled"
        } else {
            continue;
        };
        // Median gap between consecutive charges. Bail unless median is
        // in the recurring-cadence band.
        let mut gaps: Vec<i64> = cluster
            .events
            .windows(2)
            .map(|w| (w[0].0 - w[1].0).num_days().abs())
            .collect();
        gaps.sort();
        let median_gap = gaps[gaps.len() / 2];
        if !(5..=62).contains(&median_gap) {
            continue;
        }
        let total: f64 = cluster.events.iter().map(|(_, a)| a).sum();
        let months_observed = (cluster.events.len() as f64 * median_gap as f64) / 30.4375;
        let avg_per_month = if months_observed > 0.0 {
            total / months_observed
        } else {
            total
        };
        let monthly_usd = if cluster.currency.eq_ignore_ascii_case("USD") {
            avg_per_month
        } else if cluster.currency.eq_ignore_ascii_case("MXN") {
            match fx_mxn {
                Some(r) => avg_per_month / r,
                None => 0.0,
            }
        } else {
            avg_per_month
        };
        let last_amount = cluster.events[0].1;

        // Per-account slices: sorted descending by spend, with the
        // share normalised against the cluster total so the frontend
        // doesn't have to redo the math. `total` here is the sum of
        // every tally — same number as `cluster.events.iter().map.sum()`
        // since we feed both from the same loop, but recomputed
        // independently to keep the slice serialisation self-contained.
        let cluster_total: f64 = cluster
            .by_account
            .values()
            .map(|t| t.total_native)
            .sum::<f64>()
            .max(f64::MIN_POSITIVE);
        let mut by_account: Vec<SubscriptionAccountSlice> = cluster
            .by_account
            .values()
            .map(|t| SubscriptionAccountSlice {
                account_name: t.display.clone(),
                occurrences: t.count as i32,
                total_native: t.total_native,
                share: t.total_native / cluster_total,
            })
            .collect();
        by_account.sort_by(|a, b| {
            b.total_native
                .partial_cmp(&a.total_native)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        out.push(DetectedSubscription {
            merchant: cluster.merchant.clone(),
            monthly_usd,
            cadence_days: median_gap as i32,
            last_charge_date: last_charge.to_string(),
            last_amount,
            currency: cluster.currency.clone(),
            occurrences: cluster.events.len() as i32,
            status,
            by_account,
        });
    }

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
    /// Lowercased + trimmed merchant key the user wants the detector
    /// to stop showing. Mirrors the key the detector itself clusters
    /// on, so the frontend can send the same `merchant` value it
    /// rendered.
    merchant: String,
}

/// Mark a detected-subscription cluster as "not a subscription."
/// Lands a row in `ignored_subscription_merchants`; subsequent
/// detector runs skip the key entirely. The user can re-confirm by
/// just letting the cluster come back (we don't expose an
/// "unignore" today — if you actually need to undo, delete the row
/// directly from the DB).
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
