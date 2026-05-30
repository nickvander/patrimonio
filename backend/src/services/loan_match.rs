//! Loan reconciliation auto-suggest.
//!
//! Given a loan (principal, currency, origination date, borrower name)
//! this scans the user's bank transactions and SUGGESTS which are the
//! likely disbursement (the outflow when the money was lent) and which
//! are likely repayments (inflows after disbursement). The user
//! confirms or rejects each suggestion; nothing is written until they
//! confirm.
//!
//! Mirrors `services/fx_transfer_link.rs`: tunable `const` thresholds,
//! a linear-ramp `score_*` that caps below the user-confirmed sentinel
//! (100), a borrower-name bonus over a multi-field haystack, and a
//! date-windowed user-scoped candidate query with `NOT EXISTS` dedup.
//!
//! Performance: both candidate queries are a single indexed range scan
//! on `idx_transactions_user_date (user_id, date DESC)` bounded to a
//! date window — O(window), not O(all transactions). They run
//! on-demand when the user opens a loan's reconcile view, never on
//! dashboard load or sync.

use anyhow::Result;
use chrono::NaiveDate;
use sqlx::{PgPool, Row};
use uuid::Uuid;

/// Disbursement amount tolerance. Tighter than the FX matcher's 10%
/// (`fx_transfer_link::RATE_TOLERANCE_PCT`) because a disbursement is
/// the SAME currency with no exchange-rate noise — the only slack is a
/// wire fee the sender absorbed or a round-down. 2% lets a $5000 loan
/// still match a $4985 wire (after a $15 fee).
const DISBURSE_AMOUNT_TOL: f64 = 0.02;
/// Floor on the tolerance band in absolute currency units, so tiny
/// principals (where 2% is sub-dollar) still match a near-exact tx.
const DISBURSE_AMOUNT_TOL_ABS: f64 = 1.0;
/// Date window around origination_date for disbursement candidates.
/// Wider than the FX matcher's 5 because origination_date is
/// user-entered from memory and may drift from the bank-clearing date.
const DISBURSE_WINDOW_DAYS: i64 = 7;

/// Repayment amount tolerance. Wider than disbursement (5% vs 2%)
/// because borrowers round their payments — "owed 115.56, paid 115 or
/// 120".
const REPAY_AMOUNT_TOL: f64 = 0.05;
/// Date window around a scheduled due_date for repayment candidates.
/// People pay late, so this is generous.
const REPAY_WINDOW_DAYS: i64 = 15;

/// Depository account types a personal loan is funded from / repaid
/// to (lowercased — the query compares `LOWER(account_type)`). You
/// don't lend off a credit card. Covers Plaid subtypes (stored
/// lowercase by sync.rs), the manual add-account dialog's capitalized
/// forms (folded by LOWER), and the generic 'depository' the bootstrap
/// / test path uses. This filter only narrows AUTO-SUGGESTIONS — manual
/// linking (link_disbursement / record_payment) has no account filter,
/// so an oddly-typed account can always be reconciled by hand.
const DEPOSITORY_TYPES: &[&str] = &[
    "checking",
    "savings",
    "cash",
    "cash management",
    "cd",
    "money market",
    "depository",
];

/// A scored reconciliation suggestion returned to the UI.
#[derive(Debug, Clone, serde::Serialize)]
pub struct LoanSuggestion {
    pub transaction_id: String,
    pub date: String,
    /// Native amount (signed — negative for the disbursement outflow,
    /// positive for repayment inflows).
    pub amount: f64,
    pub currency: String,
    pub description: String,
    /// 0–100. >= 80 high-confidence, 50–79 review, < 50 not returned.
    pub confidence: i32,
    /// True when the borrower's name appeared in the transaction text.
    pub name_matched: bool,
}

/// One transaction candidate pulled from the windowed query.
struct TxCandidate {
    id: Uuid,
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
    fn from_row(row: &sqlx::postgres::PgRow) -> Result<Self, sqlx::Error> {
        Ok(Self {
            id: row.try_get("id")?,
            date: row.try_get("date")?,
            amount: row
                .try_get::<rust_decimal::Decimal, _>("amount")
                .ok()
                .and_then(|d| d.to_string().parse().ok())
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

    fn label(&self) -> String {
        self.counterparty_name
            .clone()
            .filter(|s| !s.is_empty())
            .or_else(|| self.merchant_name.clone().filter(|s| !s.is_empty()))
            .unwrap_or_else(|| self.description.clone())
    }
}

/// Does the borrower's name appear in any of the transaction's text
/// fields? Tokenizes the borrower name and matches each token of
/// length >= 3 case-insensitively, so "Jose Ramirez" hits "RAMIREZ J"
/// or "Zelle to Jose". Mirrors `fx_transfer_link::first_keyword`'s
/// haystack.
fn borrower_name_hit(tx: &TxCandidate, borrower_name: &str) -> bool {
    let tokens: Vec<String> = borrower_name
        .split_whitespace()
        .filter(|t| t.len() >= 3)
        .map(|t| t.to_uppercase())
        .collect();
    if tokens.is_empty() {
        return false;
    }
    let haystack = [
        Some(tx.description.as_str()),
        tx.merchant_name.as_deref(),
        tx.counterparty_name.as_deref(),
        tx.original_description.as_deref(),
        tx.payment_payee.as_deref(),
        tx.payment_payer.as_deref(),
    ];
    let combined: String = haystack
        .into_iter()
        .flatten()
        .map(|s| s.to_uppercase())
        .collect::<Vec<_>>()
        .join(" \u{1f} ");
    tokens.iter().any(|t| combined.contains(t.as_str()))
}

/// Disbursement confidence. Amount is the dominant signal (same
/// currency, no rate noise), date proximity second, borrower-name a
/// bonus. Caps at 95 (headroom below user-confirmed = 100).
fn score_disbursement(amount_dev: f64, gap_days: i64, name_hit: bool) -> i32 {
    let mut score = 0i32;
    let amount_used = (amount_dev / DISBURSE_AMOUNT_TOL).clamp(0.0, 1.0);
    score += (55.0 * (1.0 - amount_used)) as i32;
    let date_used = (gap_days as f64 / DISBURSE_WINDOW_DAYS as f64).clamp(0.0, 1.0);
    score += (25.0 * (1.0 - date_used)) as i32;
    if name_hit {
        score += 20;
    }
    score.min(95)
}

/// Repayment confidence. Borrower-name weighted higher than for
/// disbursement (inflow amounts are ambiguous, the name is the
/// discriminator). `gap_days`/`window` only contribute in schedule
/// mode; pass a 0 gap with the full window for the no-schedule case so
/// the date term zeroes out and name + amount carry it.
fn score_repayment(
    amount_dev: f64,
    gap_days: i64,
    window_days: i64,
    name_hit: bool,
    round_number: bool,
) -> i32 {
    let mut score = 0i32;
    let amount_used = (amount_dev / REPAY_AMOUNT_TOL).clamp(0.0, 1.0);
    score += (45.0 * (1.0 - amount_used)) as i32;
    if window_days > 0 {
        let date_used = (gap_days as f64 / window_days as f64).clamp(0.0, 1.0);
        score += (20.0 * (1.0 - date_used)) as i32;
    }
    if name_hit {
        score += 25;
    }
    if round_number {
        score += 5;
    }
    score.min(95)
}

/// A round-number amount (ends in .00 and is a multiple of a small
/// unit) — a weak signal that an inflow is a deliberate repayment
/// rather than a precise merchant credit.
fn is_round_number(amount: f64) -> bool {
    (amount.fract()).abs() < 0.005 && (amount % 10.0).abs() < 0.005
}

/// Suggest disbursement candidates for a loan. Returns scored
/// suggestions ordered best-first, filtered to confidence >= 50.
#[allow(clippy::too_many_arguments)]
pub async fn suggest_disbursements(
    db: &PgPool,
    user_id: Uuid,
    currency: &str,
    principal: f64,
    origination_date: NaiveDate,
    borrower_name: &str,
) -> Result<Vec<LoanSuggestion>> {
    // Tolerance band as absolute bounds — keeps the row count tiny by
    // filtering in SQL, not Rust. MAX(2%, $1) per the design.
    let tol_abs = (principal * DISBURSE_AMOUNT_TOL).max(DISBURSE_AMOUNT_TOL_ABS);
    let lo = principal - tol_abs;
    let hi = principal + tol_abs;
    let depository: Vec<String> = DEPOSITORY_TYPES.iter().map(|s| s.to_string()).collect();

    let rows = sqlx::query(
        r#"
        SELECT t.id, t.date, t.amount, t.currency, t.description,
               t.merchant_name, t.counterparty_name, t.original_description,
               t.payment_payee, t.payment_payer
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        WHERE t.user_id = $1
          AND t.currency = $2
          AND t.amount < 0
          AND t.date BETWEEN $3 - ($4 || ' days')::interval
                         AND $3 + ($4 || ' days')::interval
          AND LOWER(a.account_type) = ANY($5)
          AND ABS(t.amount) BETWEEN $6 AND $7
          AND NOT EXISTS (SELECT 1 FROM transactions c WHERE c.parent_id = t.id)
          AND NOT EXISTS (SELECT 1 FROM loans l WHERE l.disbursement_tx_id = t.id)
        ORDER BY ABS(t.date - $3) ASC, ABS(ABS(t.amount) - $8) ASC
        LIMIT 20
        "#,
    )
    .bind(user_id)
    .bind(currency)
    .bind(origination_date)
    .bind(DISBURSE_WINDOW_DAYS.to_string())
    .bind(&depository)
    .bind(rust_decimal::Decimal::from_f64_retain(lo).unwrap_or_default())
    .bind(rust_decimal::Decimal::from_f64_retain(hi).unwrap_or_default())
    .bind(rust_decimal::Decimal::from_f64_retain(principal).unwrap_or_default())
    .fetch_all(db)
    .await?;

    let mut out = Vec::new();
    for row in &rows {
        let tx = match TxCandidate::from_row(row) {
            Ok(t) => t,
            Err(_) => continue,
        };
        let abs_amount = tx.amount.abs();
        let amount_dev = if principal > 0.0 {
            (abs_amount - principal).abs() / principal
        } else {
            1.0
        };
        let gap = (tx.date - origination_date).num_days().abs();
        let name_hit = borrower_name_hit(&tx, borrower_name);
        // Strict guard: without a name hit, the amount + date must both
        // be in-band. The band is already enforced by the SQL, so this
        // mainly bars the rare in-band-but-edge case from scoring high
        // on name alone (it can't — there's no name).
        let confidence = score_disbursement(amount_dev, gap, name_hit);
        if confidence < 50 {
            continue;
        }
        out.push(LoanSuggestion {
            transaction_id: tx.id.to_string(),
            date: tx.date.to_string(),
            amount: tx.amount,
            currency: tx.currency.clone(),
            description: tx.label(),
            confidence,
            name_matched: name_hit,
        });
    }
    out.sort_by(|a, b| b.confidence.cmp(&a.confidence));
    Ok(out)
}

/// Suggest repayment candidates for a loan. `installment_amount` is the
/// expected per-payment figure when a schedule exists; pass `None` for
/// the no-schedule (interest-free IOU) case, where any plausible inflow
/// up to the remaining balance is scored on name + round-number.
pub async fn suggest_repayments(
    db: &PgPool,
    user_id: Uuid,
    currency: &str,
    after_date: NaiveDate,
    horizon_date: NaiveDate,
    borrower_name: &str,
    installment_amount: Option<f64>,
) -> Result<Vec<LoanSuggestion>> {
    let depository: Vec<String> = DEPOSITORY_TYPES.iter().map(|s| s.to_string()).collect();
    let rows = sqlx::query(
        r#"
        SELECT t.id, t.date, t.amount, t.currency, t.description,
               t.merchant_name, t.counterparty_name, t.original_description,
               t.payment_payee, t.payment_payer
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        WHERE t.user_id = $1
          AND t.currency = $2
          AND t.amount > 0
          AND t.date > $3
          AND t.date <= $4
          AND LOWER(a.account_type) = ANY($5)
          AND NOT EXISTS (SELECT 1 FROM transactions c WHERE c.parent_id = t.id)
          AND NOT EXISTS (SELECT 1 FROM loan_payments p WHERE p.actual_tx_id = t.id)
        ORDER BY t.date ASC
        LIMIT 50
        "#,
    )
    .bind(user_id)
    .bind(currency)
    .bind(after_date)
    .bind(horizon_date)
    .bind(&depository)
    .fetch_all(db)
    .await?;

    let mut out = Vec::new();
    for row in &rows {
        let tx = match TxCandidate::from_row(row) {
            Ok(t) => t,
            Err(_) => continue,
        };
        let name_hit = borrower_name_hit(&tx, borrower_name);
        let round = is_round_number(tx.amount);
        let confidence = match installment_amount {
            Some(expected) if expected > 0.0 => {
                let amount_dev = (tx.amount - expected).abs() / expected;
                // Outside the band, a non-multiple inflow only survives
                // if the name matches — otherwise it's noise (paychecks,
                // refunds). gap_days = 0 here (caller doesn't track per-
                // installment due dates in MVP); date term drops out.
                if amount_dev > REPAY_AMOUNT_TOL && !name_hit {
                    continue;
                }
                score_repayment(amount_dev, 0, REPAY_WINDOW_DAYS, name_hit, round)
            }
            _ => {
                // No-schedule mode: require a name hit OR a round number
                // to avoid suggesting every inflow.
                if !name_hit && !round {
                    continue;
                }
                // amount_dev not meaningful with no expected amount;
                // treat as in-band and lean on name + round.
                score_repayment(0.0, 0, 0, name_hit, round)
            }
        };
        if confidence < 50 {
            continue;
        }
        out.push(LoanSuggestion {
            transaction_id: tx.id.to_string(),
            date: tx.date.to_string(),
            amount: tx.amount,
            currency: tx.currency.clone(),
            description: tx.label(),
            confidence,
            name_matched: name_hit,
        });
    }
    out.sort_by(|a, b| b.confidence.cmp(&a.confidence));
    out.truncate(20);
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn disbursement_exact_amount_same_day_with_name_is_high() {
        // Case 1: exact, same day, name hit.
        let s = score_disbursement(0.0, 0, true);
        assert!(s >= 90, "expected near-max, got {s}");
    }

    #[test]
    fn disbursement_few_days_off_no_name_is_mid() {
        // Case 2: exact amount, 3 days off, no name.
        let s = score_disbursement(0.0, 3, false);
        assert!((50..80).contains(&s), "expected mid band, got {s}");
    }

    #[test]
    fn disbursement_wire_fee_in_band_is_high() {
        // Case 3: 0.3% off (a $15 fee on $5000), same day, no name.
        let s = score_disbursement(0.003, 0, false);
        assert!(s >= 70, "expected high, got {s}");
    }

    #[test]
    fn repayment_on_time_with_name_is_high() {
        // Case 10: exact installment, name hit.
        let s = score_repayment(0.0, 0, REPAY_WINDOW_DAYS, true, true);
        assert!(s >= 70, "expected high, got {s}");
    }

    #[test]
    fn repayment_rounded_within_band_scores() {
        // Case 11: ~2.9% off (owed 1030, paid 1000), name hit, round.
        let s = score_repayment(0.029, 0, REPAY_WINDOW_DAYS, true, true);
        assert!(s >= 60, "expected mid/high, got {s}");
    }

    #[test]
    fn round_number_detection() {
        assert!(is_round_number(1000.0));
        assert!(is_round_number(120.0));
        assert!(!is_round_number(115.56));
        assert!(!is_round_number(1033.33));
    }

    #[test]
    fn borrower_name_tokenization() {
        let tx = TxCandidate {
            id: Uuid::nil(),
            date: NaiveDate::from_ymd_opt(2026, 1, 15).unwrap(),
            amount: -5000.0,
            currency: "USD".to_string(),
            description: "ZELLE TO JOSE RAMIREZ".to_string(),
            merchant_name: None,
            counterparty_name: None,
            original_description: None,
            payment_payee: None,
            payment_payer: None,
        };
        assert!(borrower_name_hit(&tx, "Jose Ramirez"));
        assert!(borrower_name_hit(&tx, "jose"));
        // A two-char token is ignored, so a borrower named "Al" never
        // matches on the short token alone.
        let tx2 = TxCandidate {
            description: "PAYMENT".to_string(),
            ..tx
        };
        assert!(!borrower_name_hit(&tx2, "Al"));
    }
}
