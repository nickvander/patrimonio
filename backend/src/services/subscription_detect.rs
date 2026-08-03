//! Recurring-charge detection — the clustering core behind BOTH the
//! dashboard's "Recurring charges" card (`GET /api/dashboard/subscriptions`)
//! and the bills calendar (`GET /api/recurring/calendar`).
//!
//! It used to live inside the dashboard handler, which is exactly why the
//! calendar shipped blind: the calendar only expanded explicit
//! `recurring_rules` + loan dues, so an owner with zero rules saw nothing but
//! loan repayments while their detected charges sat in a card the calendar
//! couldn't read. The detection logic now lives here, next to the other
//! detectors (`fx_transfer_link`, `staleness`, `loan_match`), and both
//! surfaces call the same function — one heuristic, one ignore-list
//! predicate, no drift.
//!
//! **The presentation layer stays with each caller.** This module returns
//! *native* magnitudes and the raw cluster shape; FX→USD conversion, sorting,
//! and display caps belong to the endpoint (the subscriptions card converts to
//! `monthly_usd` and truncates; the calendar projects occurrences forward).
//! That split is what keeps the extraction behaviour-preserving for the
//! shipped `/api/dashboard/subscriptions` response.
//!
//! Sign convention: this app stores outflows as negative `transactions.amount`
//! and inflows as positive. Every amount that leaves this module is the
//! **absolute magnitude** of an outflow — the sign is implied by the cluster
//! (a subscription is always money leaving), and callers re-apply it.

use std::collections::{HashMap, HashSet};

use chrono::NaiveDate;
use rust_decimal::Decimal;
use sqlx::{PgPool, Row};
use uuid::Uuid;

use crate::api::dashboard::{
    CASHFLOW_ROW_ANTI_JOINS_SQL, EFFECTIVE_CATEGORY_SQL, NON_CASHFLOW_CATEGORIES_SQL,
};

/// How far back the detector looks. Also the hard age ceiling: a cluster whose
/// most recent charge is older than this is dropped entirely (see `status`).
const OBSERVATION_DAYS: i64 = 548;
/// A cluster needs at least this many charges to count as recurring — two
/// charges is a coincidence, three is a cadence.
const MIN_OCCURRENCES: usize = 3;
/// Last charge within this many days ⇒ `"active"`; beyond it (up to
/// `OBSERVATION_DAYS`) ⇒ `"cancelled"`.
const ACTIVE_MAX_DAYS: i64 = 90;
/// Accepted median-gap band, in days: weekly (7) through bi-monthly (62).
/// The floor filters one-off bursts, the ceiling filters annual renewals.
const MIN_CADENCE_DAYS: i64 = 5;
const MAX_CADENCE_DAYS: i64 = 62;
/// Average days per month, used to normalise "spend per month" from a cadence
/// that isn't monthly (365.25 / 12).
const DAYS_PER_MONTH: f64 = 30.4375;

/// Per-account distribution within a cluster. Surfaces the "Apple Pay charged
/// Visa AND a fee landed on Checking" case. Sorted descending by
/// `total_native`, so `by_account[0]` is the cluster's dominant account — the
/// one the calendar projects the charge onto.
pub(crate) struct DetectedAccountSlice {
    pub account_id: Uuid,
    /// Account display name (nickname when set, else bank-supplied name).
    pub account_name: String,
    pub occurrences: i32,
    /// Absolute spend on this account in the cluster's native currency.
    pub total_native: f64,
    /// Share of the cluster total (0.0–1.0).
    pub share: f64,
}

/// One detected recurring charge.
pub(crate) struct DetectedCluster {
    /// Stable synthetic identity: `"{merchant_key}::{amount_band}"`. Used as
    /// the calendar occurrence id — it survives across requests (unlike a row
    /// id, there is no row) so the frontend can key/dismiss on it.
    pub key: String,
    /// Display label, original case, from the same source ladder the
    /// transactions list uses (so renames propagate).
    pub merchant: String,
    /// Lowercased+trimmed clustering key — the same value
    /// `ignored_subscription_merchants.merchant_key` stores.
    pub merchant_key: String,
    pub currency: String,
    /// Median gap between consecutive charges, in days. 30 = monthly.
    pub cadence_days: i64,
    pub last_charge_date: NaiveDate,
    /// Magnitude of the most recent charge (native currency, positive).
    pub last_amount: f64,
    /// Same value as `last_amount` but never round-tripped through `f64` —
    /// this is what money math (the calendar's occurrence amounts) uses.
    pub last_amount_dec: Decimal,
    pub occurrences: i32,
    /// `"active"` (last charge ≤ 90 days) or `"cancelled"` (91–548 days).
    /// Callers that project future cash MUST filter to `"active"`: projecting
    /// a cancelled cluster manufactures phantom bills.
    pub status: &'static str,
    /// Average spend per month in the cluster's NATIVE currency (total
    /// observed spend / months observed). Callers convert to USD themselves.
    pub avg_per_month_native: f64,
    pub by_account: Vec<DetectedAccountSlice>,
}

/// Merchant clustering key. Mirrors the frontend's display ladder (minus the
/// raw description, which is too noisy — POS reference codes vary per swipe).
/// Lowercase + trim so case doesn't split a cluster.
fn merchant_key(
    user_desc: Option<&str>,
    counterparty: Option<&str>,
    merchant: Option<&str>,
    payee: Option<&str>,
    description: &str,
) -> String {
    display_merchant(user_desc, counterparty, merchant, payee, description).to_lowercase()
}

/// The most user-recognisable name for display. Same source ladder as
/// `merchant_key`, but preserves the original case.
fn display_merchant(
    user_desc: Option<&str>,
    counterparty: Option<&str>,
    merchant: Option<&str>,
    payee: Option<&str>,
    description: &str,
) -> String {
    user_desc
        .filter(|s| !s.trim().is_empty())
        .or(counterparty.filter(|s| !s.trim().is_empty()))
        .or(merchant.filter(|s| !s.trim().is_empty()))
        .or(payee.filter(|s| !s.trim().is_empty()))
        .unwrap_or(description)
        .trim()
        .to_string()
}

/// Strings too generic to cluster on: letting them through would lump every
/// "Miscellaneous Debit" row together and report a fake subscription.
fn is_generic_key(key: &str) -> bool {
    const GENERIC_PREFIXES: [&str; 12] = [
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
    GENERIC_PREFIXES
        .iter()
        .any(|p| key == *p || key.starts_with(p))
}

/// Detect the user's recurring outflows.
///
/// Heuristic: group every **expense** transaction of the last
/// `OBSERVATION_DAYS` by (normalised merchant, amount band). A cluster
/// qualifies as recurring when it has ≥ `MIN_OCCURRENCES` charges, a median
/// gap inside the cadence band, and a most-recent charge inside
/// `OBSERVATION_DAYS`.
///
/// Income-shaped rows are deliberately excluded — a checking account that
/// receives monthly "Interest Earned" credits would otherwise match the
/// recurring shape and surface as a fake subscription — as are the same
/// non-spend categories the cash-flow views exclude (internal transfers,
/// credit-card payments, loan legs, investment moves), via the shared
/// `dashboard` SQL fragments so the exclusion set can never drift.
///
/// Merchants the user dismissed ("this isn't a subscription") are filtered
/// **inside** this function, so every caller honours the ignore list by
/// construction — no caller can forget the predicate.
///
/// Returned sorted by `key` for determinism; callers apply their own display
/// ordering.
pub(crate) async fn detect_recurring_charges(
    db: &PgPool,
    user_id: Uuid,
) -> anyhow::Result<Vec<DetectedCluster>> {
    // The dismissed-as-not-a-subscription set. Small table; held in memory and
    // applied during clustering. A read failure propagates rather than
    // degrading to "show everything": silently resurrecting a merchant the
    // user explicitly hid is worse than an empty card.
    let ignored_rows =
        sqlx::query("SELECT merchant_key FROM ignored_subscription_merchants WHERE user_id = $1")
            .bind(user_id)
            .fetch_all(db)
            .await?;
    let ignored: HashSet<String> = ignored_rows
        .iter()
        .filter_map(|r| r.try_get::<String, _>("merchant_key").ok())
        .collect();

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
          AND t.date >= CURRENT_DATE - INTERVAL '{OBSERVATION_DAYS} days'
          AND {EFFECTIVE_CATEGORY_SQL} NOT IN {NON_CASHFLOW_CATEGORIES_SQL}{CASHFLOW_ROW_ANTI_JOINS_SQL}
        ORDER BY t.date DESC
        "#,
    );
    let rows = sqlx::query(&sql).bind(user_id).fetch_all(db).await?;
    if rows.is_empty() {
        return Ok(Vec::new());
    }

    struct AccountTally {
        display: String,
        count: u32,
        total_native: f64,
    }
    struct Cluster {
        merchant: String,
        merchant_key: String,
        currency: String,
        /// (date, magnitude) for every observed charge, sign-stripped so the
        /// downstream math (median gap, monthly average) stays sign-agnostic.
        events: Vec<(NaiveDate, f64, Decimal)>,
        by_account: HashMap<Uuid, AccountTally>,
    }
    let mut clusters: HashMap<String, Cluster> = HashMap::new();

    for r in &rows {
        let date: NaiveDate = match r.try_get("date") {
            Ok(d) => d,
            Err(_) => continue,
        };
        let raw_dec: Decimal = r.try_get("amount").unwrap_or_default();
        let raw_amount: f64 = raw_dec.to_string().parse().unwrap_or(0.0);
        // The SQL already restricts to amount < 0, but a defensive sign check
        // keeps the loop honest if the WHERE clause is ever softened. From
        // here on `amount` is the absolute outflow magnitude.
        if raw_amount >= 0.0 {
            continue;
        }
        let amount = raw_amount.abs();
        let amount_dec = raw_dec.abs();
        let currency: String = r.try_get("currency").unwrap_or_else(|_| "USD".into());
        let description: String = r.try_get("description").unwrap_or_default();
        let account_id: Uuid = match r.try_get("account_id") {
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
        if is_generic_key(&key_part) {
            continue;
        }
        // User-dismissed cluster. Skip the merchant entirely — the dismissed
        // key matches whatever the detector clustered on at the time, so
        // re-running won't re-surface it unless the underlying tx data changed
        // in a way that produces a different key.
        if ignored.contains(&key_part) {
            continue;
        }
        // Amount band = rounded-to-nearest-unit value, so a 9.99 / 10.00 /
        // 10.01 Netflix sequence all clusters (banks vary sub-cent on rolling
        // charges).
        let band = amount.round() as i64;
        let key = format!("{key_part}::{band}");
        let display_name = display_merchant(
            user_description.as_deref(),
            counterparty_name.as_deref(),
            merchant_name.as_deref(),
            payment_payee.as_deref(),
            &description,
        );
        let cluster = clusters.entry(key.clone()).or_insert_with(|| Cluster {
            merchant: display_name,
            merchant_key: key_part,
            currency: currency.clone(),
            events: Vec::new(),
            by_account: HashMap::new(),
        });
        cluster.events.push((date, amount, amount_dec));
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
    let mut out: Vec<DetectedCluster> = Vec::new();
    for (key, cluster) in clusters.iter_mut() {
        // Most-recent first; rows already arrive DESC but sort for safety.
        cluster.events.sort_by_key(|e| std::cmp::Reverse(e.0));
        if cluster.events.len() < MIN_OCCURRENCES {
            continue;
        }
        let last_charge = cluster.events[0].0;
        let days_since = (today - last_charge).num_days();
        let status: &'static str = if days_since <= ACTIVE_MAX_DAYS {
            "active"
        } else if days_since <= OBSERVATION_DAYS {
            "cancelled"
        } else {
            // Older than the observation window: not useful audit signal.
            continue;
        };
        let mut gaps: Vec<i64> = cluster
            .events
            .windows(2)
            .map(|w| (w[0].0 - w[1].0).num_days().abs())
            .collect();
        gaps.sort_unstable();
        let median_gap = gaps[gaps.len() / 2];
        if !(MIN_CADENCE_DAYS..=MAX_CADENCE_DAYS).contains(&median_gap) {
            continue;
        }
        let total: f64 = cluster.events.iter().map(|(_, a, _)| a).sum();
        let months_observed = (cluster.events.len() as f64 * median_gap as f64) / DAYS_PER_MONTH;
        let avg_per_month_native = if months_observed > 0.0 {
            total / months_observed
        } else {
            total
        };

        // Per-account slices: descending by spend, share normalised against
        // the cluster total so no caller has to redo the math. Recomputed from
        // the tallies (rather than reusing `total`) to keep the slice
        // serialisation self-contained.
        let cluster_total: f64 = cluster
            .by_account
            .values()
            .map(|t| t.total_native)
            .sum::<f64>()
            .max(f64::MIN_POSITIVE);
        let mut by_account: Vec<DetectedAccountSlice> = cluster
            .by_account
            .iter()
            .map(|(id, t)| DetectedAccountSlice {
                account_id: *id,
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

        out.push(DetectedCluster {
            key: key.clone(),
            merchant: cluster.merchant.clone(),
            merchant_key: cluster.merchant_key.clone(),
            currency: cluster.currency.clone(),
            cadence_days: median_gap,
            last_charge_date: last_charge,
            last_amount: cluster.events[0].1,
            last_amount_dec: cluster.events[0].2,
            occurrences: cluster.events.len() as i32,
            status,
            avg_per_month_native,
            by_account,
        });
    }

    // Deterministic order in, deterministic order out: HashMap iteration would
    // otherwise reshuffle equal-ranked clusters between requests.
    out.sort_by(|a, b| a.key.cmp(&b.key));
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merchant_key_walks_the_display_ladder_and_lowercases() {
        // user_description wins over every other field.
        assert_eq!(
            merchant_key(Some("My Gym"), Some("CP"), Some("MERCH"), None, "DESC"),
            "my gym"
        );
        // Blank fields fall through to the next rung.
        assert_eq!(
            merchant_key(Some("  "), None, Some("NETFLIX.COM"), None, "POS 1234"),
            "netflix.com"
        );
        // Nothing set → the raw description.
        assert_eq!(merchant_key(None, None, None, None, "  CFE  "), "cfe");
    }

    #[test]
    fn generic_keys_are_never_clustered() {
        // These would otherwise lump unrelated rows into a fake subscription.
        assert!(is_generic_key("miscellaneous debit"));
        assert!(is_generic_key("transfer"));
        assert!(is_generic_key("ach payment"));
        assert!(is_generic_key("electronic withdrawal"));
        // Real merchant names survive.
        assert!(!is_generic_key("netflix.com"));
        assert!(!is_generic_key("cfe"));
        // "credit" is generic; "credit union dues" starts with it and is too.
        assert!(is_generic_key("credit"));
    }
}
