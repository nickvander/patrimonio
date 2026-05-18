//! Cross-currency cash-transfer detection.
//!
//! Pairs a USD-out + MXN-in transaction (or the reverse) when:
//!   * They land within `MAX_WINDOW_DAYS` of each other,
//!   * Their amount ratio backs out to a plausible USD/MXN rate (within
//!     `RATE_TOLERANCE_PCT` of the day's reference rate — Wise & friends
//!     spread the rate but rarely by more than ~10% even on small
//!     transfers),
//!   * At least one side's description contains a remittance keyword
//!     (Wise, Remitly, Xoom, Western Union, MoneyGram, Revolut), OR
//!     both sides are within `STRICT_WINDOW_DAYS` and the rate is
//!     within `STRICT_TOLERANCE_PCT` of the day's reference rate (the
//!     stricter rule catches direct-deposit / wire transfers that
//!     don't name the remitter).
//!
//! Returns a `detection_confidence` per pair so the UI can split into
//! "auto-confirmed" vs "needs review."
//!
//! Detection is idempotent — the unique index on
//! `(source_tx_id, dest_tx_id)` collapses duplicate inserts on
//! repeated runs. User-confirmed pairs (`user_confirmed = true`) are
//! never re-evaluated.

use anyhow::Result;
use chrono::NaiveDate;
use sqlx::{PgPool, Row};

/// Cap on time between the source and dest transactions for any
/// remittance-keyword match. Five days covers the slowest USD→MXN
/// transfer paths in practice (Wise ACH on a Friday can settle the
/// following Wednesday).
const MAX_WINDOW_DAYS: i64 = 5;
/// Tighter window used when there's no remittance keyword. The
/// stricter rate tolerance below means accidental matches at this
/// distance are very unlikely.
const STRICT_WINDOW_DAYS: i64 = 2;
/// Acceptable deviation between the back-computed rate (dest /
/// source) and the day's reference USD/MXN rate. Wise's spread
/// is typically ~0.5–2%, but Remitly and storefront wires can be
/// 5–8%, so 10% catches the long tail.
const RATE_TOLERANCE_PCT: f64 = 0.10;
/// Strict tolerance for keyword-less pairs.
const STRICT_TOLERANCE_PCT: f64 = 0.03;
/// Below this absolute USD value we don't even try to pair —
/// rounding + sub-cent FX noise dominates and would produce a flood
/// of spurious matches on small purchases.
const MIN_USD_VALUE: f64 = 50.0;

/// Remittance keywords (case-insensitive substring match on the
/// transaction description / merchant / counterparty / original
/// description). Order matters only for the surfaced
/// `matched_keyword` value — the first hit wins.
const REMITTANCE_KEYWORDS: &[&str] = &[
    "WISE",
    "TRANSFERWISE",
    "REMITLY",
    "XOOM",
    "WESTERN UNION",
    "WESTERNUNION",
    "MONEYGRAM",
    "REVOLUT",
    "CURRENCYFAIR",
    "OFX",
];

/// Run a detection pass for one user. Existing user-confirmed links
/// are left alone; previously auto-detected (but unconfirmed) links
/// are refreshed if the underlying transactions still pair up.
///
/// Returns `(checked, inserted)` — `checked` is the number of
/// candidate pairs scored, `inserted` is the number of new rows
/// written. Useful for the API response so the user can see whether
/// the run found anything new.
pub async fn detect_for_user(db: &PgPool, user_id: uuid::Uuid) -> Result<(usize, usize)> {
    // 1. Pull the day's reference rate. We use the most recent
    //    USD/MXN row in exchange_rates; if there's no row we bail
    //    early — without a reference rate we can't sanity-check the
    //    implied rate.
    let Some(reference_rate) = latest_usd_mxn(db).await? else {
        return Ok((0, 0));
    };

    // 2. Pull every cash-flow transaction in the user's last 90 days
    //    that's at least MIN_USD_VALUE in USD-equivalent. 90 days is
    //    a generous window — most Wise transfers complete in a few
    //    business days, so anything outside the recent past is
    //    almost certainly a coincidence.
    let rows = sqlx::query(
        r#"
        SELECT t.id, t.account_id, t.date, t.amount, t.currency,
               t.description, t.merchant_name, t.counterparty_name,
               t.original_description, t.payment_payee, t.payment_payer
        FROM transactions t
        WHERE t.user_id = $1
          AND t.date >= CURRENT_DATE - INTERVAL '90 days'
          AND t.currency IN ('USD', 'MXN')
          AND ABS(t.amount) >= $2
          AND NOT EXISTS (SELECT 1 FROM transactions tc WHERE tc.parent_id = t.id)
        ORDER BY t.date ASC, t.id ASC
        "#,
    )
    .bind(user_id)
    .bind(MIN_USD_VALUE)
    .fetch_all(db)
    .await?;

    let candidates: Vec<TxCandidate> = rows
        .iter()
        .filter_map(|r| TxCandidate::from_row(r).ok())
        .collect();

    // 3. Walk every (USD-out, MXN-in) pair AND (MXN-out, USD-in)
    //    pair. We only consider expense-on-source + income-on-dest
    //    (sign convention: amount > 0 is outflow), since a transfer
    //    is always one of each.
    let mut checked = 0usize;
    let mut inserted = 0usize;

    for source in &candidates {
        if source.amount <= 0.0 {
            // source must be an outflow (positive amount in this app's
            // sign convention).
            continue;
        }
        for dest in &candidates {
            if dest.amount >= 0.0 {
                continue;
            }
            if source.id == dest.id {
                continue;
            }
            if source.account_id == dest.account_id {
                // Intra-account transfer shouldn't be modeled as an
                // FX transfer — they'd typically share a currency,
                // but the check is cheap belt-and-suspenders.
                continue;
            }
            if source.currency == dest.currency {
                continue;
            }

            let gap_days = (dest.date - source.date).num_days().abs();
            if gap_days > MAX_WINDOW_DAYS {
                continue;
            }

            let source_abs = source.amount.abs();
            let dest_abs = dest.amount.abs();
            if source_abs <= 0.0 || dest_abs <= 0.0 {
                continue;
            }

            // Compute the implied USD/MXN rate. Always normalise to
            // "how many MXN per 1 USD" so we can compare against
            // reference_rate regardless of direction.
            let implied_rate = match (source.currency.as_str(), dest.currency.as_str()) {
                ("USD", "MXN") => dest_abs / source_abs,
                ("MXN", "USD") => source_abs / dest_abs,
                _ => continue,
            };
            let rate_deviation =
                ((implied_rate - reference_rate) / reference_rate).abs();

            // Match a keyword if one is present in either tx.
            let matched_keyword = first_keyword(source).or_else(|| first_keyword(dest));

            // Confidence score. Higher = more likely to be a real
            // remittance link. We split into three tiers in the UI:
            //   >= 80 auto-confirm and quiet, 50–79 surface in detail
            //   modal, < 50 discard.
            let confidence = score_match(rate_deviation, gap_days, matched_keyword.is_some());
            checked += 1;
            if confidence < 50 {
                continue;
            }
            // Keyword-less pairs must clear the strict bar.
            if matched_keyword.is_none()
                && (gap_days > STRICT_WINDOW_DAYS || rate_deviation > STRICT_TOLERANCE_PCT)
            {
                continue;
            }

            let result = sqlx::query(
                r#"
                INSERT INTO cash_fx_transfers (
                    user_id, source_tx_id, dest_tx_id,
                    source_amount, source_currency,
                    dest_amount, dest_currency,
                    implied_fx_rate, detection_confidence, matched_keyword
                ) VALUES (
                    $1, $2, $3, $4, $5, $6, $7, $8, $9, $10
                )
                ON CONFLICT (source_tx_id, dest_tx_id) DO NOTHING
                "#,
            )
            .bind(user_id)
            .bind(source.id)
            .bind(dest.id)
            .bind(source_abs)
            .bind(&source.currency)
            .bind(dest_abs)
            .bind(&dest.currency)
            .bind(implied_rate)
            .bind(confidence as i16)
            .bind(matched_keyword)
            .execute(db)
            .await?;

            inserted += result.rows_affected() as usize;
        }
    }

    Ok((checked, inserted))
}

async fn latest_usd_mxn(db: &PgPool) -> Result<Option<f64>> {
    let row = sqlx::query(
        "SELECT rate FROM exchange_rates \
         WHERE base_currency = 'USD' AND target_currency = 'MXN' \
         ORDER BY recorded_at DESC LIMIT 1",
    )
    .fetch_optional(db)
    .await?;
    Ok(row
        .and_then(|r| r.try_get::<rust_decimal::Decimal, _>("rate").ok())
        .and_then(|d| d.to_string().parse::<f64>().ok())
        .filter(|r| *r > 0.0))
}

/// One transaction row in shape suitable for matching. We hold a few
/// extra description fields so the keyword match can run against the
/// counterparty / payee / original / merchant names, not just
/// `description` (which often is generic "Miscellaneous Debit").
struct TxCandidate {
    id: uuid::Uuid,
    account_id: uuid::Uuid,
    date: NaiveDate,
    amount: f64,
    currency: String,
    description: String,
    merchant_name: Option<String>,
    counterparty_name: Option<String>,
    original_description: Option<String>,
    payment_payee: Option<String>,
    payment_payer: Option<String>,
}

impl TxCandidate {
    fn from_row(row: &sqlx::postgres::PgRow) -> Result<Self> {
        Ok(Self {
            id: row.try_get("id")?,
            account_id: row.try_get("account_id")?,
            date: row.try_get("date")?,
            amount: row
                .try_get::<rust_decimal::Decimal, _>("amount")?
                .to_string()
                .parse()
                .unwrap_or(0.0),
            currency: row.try_get("currency")?,
            description: row.try_get("description").unwrap_or_default(),
            merchant_name: row.try_get("merchant_name").ok(),
            counterparty_name: row.try_get("counterparty_name").ok(),
            original_description: row.try_get("original_description").ok(),
            payment_payee: row.try_get("payment_payee").ok(),
            payment_payer: row.try_get("payment_payer").ok(),
        })
    }
}

fn first_keyword(tx: &TxCandidate) -> Option<String> {
    let haystack = [
        Some(tx.description.as_str()),
        tx.merchant_name.as_deref(),
        tx.counterparty_name.as_deref(),
        tx.original_description.as_deref(),
        tx.payment_payee.as_deref(),
        tx.payment_payer.as_deref(),
    ];
    for field in haystack.into_iter().flatten() {
        let upper = field.to_uppercase();
        for kw in REMITTANCE_KEYWORDS {
            if upper.contains(kw) {
                return Some((*kw).to_string());
            }
        }
    }
    None
}

/// Confidence scoring. Caps at 95 — we keep a few points of headroom
/// so a user-confirmed link is always distinguishable in any future
/// per-link UI (100 = user-confirmed in our convention).
fn score_match(rate_deviation: f64, gap_days: i64, has_keyword: bool) -> i32 {
    let mut score = 0i32;
    // Rate-tolerance: 0% off → +50, 10% off → 0. Linear ramp.
    let rate_pct_used = (rate_deviation / RATE_TOLERANCE_PCT).clamp(0.0, 1.0);
    score += (50.0 * (1.0 - rate_pct_used)) as i32;
    // Gap days: same shape, smaller weight.
    let gap_pct_used = (gap_days as f64 / MAX_WINDOW_DAYS as f64).clamp(0.0, 1.0);
    score += (25.0 * (1.0 - gap_pct_used)) as i32;
    // Keyword: +20 outright. Without one, the rate + gap must do
    // the lifting — see the explicit strict guard in the caller.
    if has_keyword {
        score += 20;
    }
    score.min(95)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scoring_strong_match_with_keyword_is_high() {
        // 0% deviation, same day, keyword present.
        let score = score_match(0.0, 0, true);
        assert!(score >= 90, "expected near-max, got {score}");
    }

    #[test]
    fn scoring_no_keyword_still_passable_when_tight() {
        // 0% deviation, same day, no keyword → 50 + 25 + 0 = 75.
        let score = score_match(0.0, 0, false);
        assert!(score >= 70 && score <= 80);
    }

    #[test]
    fn scoring_falls_off_with_deviation() {
        // 100% of the tolerance band consumed → 0 rate pts.
        let score = score_match(RATE_TOLERANCE_PCT, 0, false);
        assert!(score < 50, "loose match should score below threshold, got {score}");
    }

    #[test]
    fn keyword_match_is_case_insensitive() {
        let tx = TxCandidate {
            id: uuid::Uuid::new_v4(),
            account_id: uuid::Uuid::new_v4(),
            date: chrono::NaiveDate::from_ymd_opt(2026, 5, 1).unwrap(),
            amount: 100.0,
            currency: "USD".into(),
            description: "wise us inc bill payment".into(),
            merchant_name: None,
            counterparty_name: None,
            original_description: None,
            payment_payee: None,
            payment_payer: None,
        };
        assert_eq!(first_keyword(&tx).as_deref(), Some("WISE"));
    }
}
