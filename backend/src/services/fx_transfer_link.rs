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

    // 2b. Load the user's permanently-dismissed pairs so we skip them
    //     during the walk below. Without this the detector would
    //     happily re-propose a pair the user explicitly told us to
    //     stop suggesting on the previous sweep.
    let dismissed_rows =
        sqlx::query("SELECT source_tx_id, dest_tx_id FROM dismissed_fx_pairs WHERE user_id = $1")
            .bind(user_id)
            .fetch_all(db)
            .await
            .unwrap_or_default();
    let dismissed: std::collections::HashSet<(uuid::Uuid, uuid::Uuid)> = dismissed_rows
        .iter()
        .filter_map(|r| {
            let s: uuid::Uuid = r.try_get("source_tx_id").ok()?;
            let d: uuid::Uuid = r.try_get("dest_tx_id").ok()?;
            Some((s, d))
        })
        .collect();

    // 2c. Transactions already part of a link (especially user-confirmed
    //     pairs, which we never re-evaluate). Their legs are reserved up
    //     front so the one-to-one assignment below can't build a second,
    //     conflicting pairing for a transaction that's already spoken for.
    //     Auto-detected-but-unconfirmed links are cleared by the
    //     `2026061402_fx_transfer_relink.sql` backfill on deploy, so on the
    //     next sweep they get recomputed under the new matching rules rather
    //     than locking in the old cross-product pairings.
    let existing_rows =
        sqlx::query("SELECT source_tx_id, dest_tx_id FROM cash_fx_transfers WHERE user_id = $1")
            .bind(user_id)
            .fetch_all(db)
            .await
            .unwrap_or_default();
    let mut used: std::collections::HashSet<uuid::Uuid> = std::collections::HashSet::new();
    for r in &existing_rows {
        if let Ok(s) = r.try_get::<uuid::Uuid, _>("source_tx_id") {
            used.insert(s);
        }
        if let Ok(d) = r.try_get::<uuid::Uuid, _>("dest_tx_id") {
            used.insert(d);
        }
    }

    // 3. Walk every (USD-out, MXN-in) pair AND (MXN-out, USD-in)
    //    pair. We only consider expense-on-source + income-on-dest.
    //    Sign convention: outflow is stored as NEGATIVE (matches
    //    `services/sync.rs` which negates Plaid's outflow-positive
    //    amounts on import, and `cash_flow_trends` which sums
    //    `amount > 0` as income). An older comment here claimed
    //    "amount > 0 is outflow" — that was inverted and caused
    //    every detector run to short-circuit with 0 candidates
    //    against real data.
    // Drop candidates below the value floor measured in USD-equivalent, so a
    // MXN leg is judged in dollars rather than raw pesos.
    let candidates: Vec<TxCandidate> = candidates
        .into_iter()
        .filter(|c| usd_value(c, reference_rate) >= MIN_USD_VALUE)
        .collect();

    // Pre-compute identity tokens once per candidate — the pairing is O(n²)
    // and recomputing per pair would be wasteful.
    let id_tokens: Vec<std::collections::HashSet<String>> =
        candidates.iter().map(identity_tokens).collect();

    // 3. Score every (outflow, inflow) cross-currency pair that clears the
    //    bar, but DON'T insert yet. The old code inserted every qualifying
    //    pair immediately, so N similar outflows and N similar inflows in the
    //    same window produced an N×N cross-product of links — the "Andrea
    //    transfers look random" bug. Instead we collect candidates and then
    //    assign greedily one-to-one below.
    struct PairScore {
        source_idx: usize,
        dest_idx: usize,
        confidence: i32,
        gap_days: i64,
        rate_deviation: f64,
        implied_rate: f64,
        matched_keyword: Option<String>,
    }
    let mut checked = 0usize;
    let mut scored: Vec<PairScore> = Vec::new();

    for (si, source) in candidates.iter().enumerate() {
        if source.amount >= 0.0 {
            // source must be an outflow (negative amount in this
            // app's sign convention).
            continue;
        }
        for (di, dest) in candidates.iter().enumerate() {
            if dest.amount <= 0.0 {
                // dest must be an inflow (positive amount).
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
            // Skip permanently-dismissed pairs. The user has already
            // looked at this exact two-tx combination and said "not
            // a transfer" — re-proposing it would be a regression.
            if dismissed.contains(&(source.id, dest.id)) {
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
            let rate_deviation = ((implied_rate - reference_rate) / reference_rate).abs();

            // Match a keyword if one is present in either tx.
            let matched_keyword = first_keyword(source).or_else(|| first_keyword(dest));
            // Shared counterparty identity across the two legs.
            let has_identity = !id_tokens[si].is_disjoint(&id_tokens[di]);

            // Confidence score. Higher = more likely to be a real
            // remittance link. We split into three tiers in the UI:
            //   >= 80 auto-confirm and quiet, 50–79 surface in detail
            //   modal, < 50 discard.
            let confidence = score_match(
                rate_deviation,
                gap_days,
                matched_keyword.is_some(),
                has_identity,
            );
            checked += 1;
            if confidence < 50 {
                continue;
            }
            // Keyword-less pairs are the false-positive risk: without a
            // remittance keyword we require a shared counterparty identity
            // (plus the strict window/rate band), so a coincidental
            // same-week, near-market-rate outflow/inflow with unrelated
            // counterparties no longer auto-links.
            if matched_keyword.is_none()
                && !keywordless_pair_allowed(has_identity, gap_days, rate_deviation)
            {
                continue;
            }

            scored.push(PairScore {
                source_idx: si,
                dest_idx: di,
                confidence,
                gap_days,
                rate_deviation,
                implied_rate,
                matched_keyword,
            });
        }
    }

    // 4. Greedy one-to-one assignment. Best pairs first (highest confidence,
    //    then the closest dates, then the tightest rate), and once a
    //    transaction is used as either leg it can't appear in another pair.
    //    This collapses the old cross-product to a clean set of distinct
    //    transfers and lets date-proximity pick the right counterpart among
    //    several same-amount legs.
    scored.sort_by(|a, b| {
        b.confidence
            .cmp(&a.confidence)
            .then(a.gap_days.cmp(&b.gap_days))
            .then(
                a.rate_deviation
                    .partial_cmp(&b.rate_deviation)
                    .unwrap_or(std::cmp::Ordering::Equal),
            )
    });

    let mut inserted = 0usize;

    for p in &scored {
        let source = &candidates[p.source_idx];
        let dest = &candidates[p.dest_idx];
        if used.contains(&source.id) || used.contains(&dest.id) {
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
        .bind(source.amount.abs())
        .bind(&source.currency)
        .bind(dest.amount.abs())
        .bind(&dest.currency)
        .bind(p.implied_rate)
        .bind(p.confidence as i16)
        .bind(p.matched_keyword.clone())
        .execute(db)
        .await?;

        if result.rows_affected() > 0 {
            inserted += 1;
            // Reserve both legs so neither pairs with anything else.
            used.insert(source.id);
            used.insert(dest.id);
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
fn score_match(rate_deviation: f64, gap_days: i64, has_keyword: bool, has_identity: bool) -> i32 {
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
    // Shared counterparty identity (e.g. both legs name "ANDREA") is strong
    // evidence the two sides are the same transfer, and is what distinguishes
    // one person-to-person transfer from another of a similar amount in the
    // same window. Boosts confidence and, via the greedy assignment, wins the
    // pairing over a coincidental same-ratio leg that doesn't share a name.
    if has_identity {
        score += 15;
    }
    score.min(95)
}

/// Whether a KEYWORD-LESS candidate pair is trustworthy enough to auto-link.
///
/// Pure amount/date/rate coincidence is not enough: an opposite-currency
/// outflow and inflow that merely land in the same week at a near-market rate
/// (e.g. a doctor's-office card payment vs an unrelated peso deposit) used to
/// auto-link. Without a remittance keyword we additionally require a SHARED
/// COUNTERPARTY IDENTITY (the same person/entity named on both legs), inside
/// the strict window and rate band. A keyword (WISE, REMITLY, …) bypasses this
/// gate entirely in the caller.
fn keywordless_pair_allowed(has_identity: bool, gap_days: i64, rate_deviation: f64) -> bool {
    has_identity && gap_days <= STRICT_WINDOW_DAYS && rate_deviation <= STRICT_TOLERANCE_PCT
}

/// Generic tokens that carry no identity — payment mechanisms, legal
/// suffixes, and filler that would otherwise cause unrelated transfers to
/// "share" an identity. Compared upper-cased.
const IDENTITY_STOPWORDS: &[&str] = &[
    "TRANSFER",
    "TRANSFERENCIA",
    "TRANSFERENCIAS",
    "SPEI",
    "PAGO",
    "PAGOS",
    "DEPOSITO",
    "DEPÓSITO",
    "ABONO",
    "CARGO",
    "RETIRO",
    "PAYMENT",
    "BILL",
    "FROM",
    "WITH",
    "THE",
    "AND",
    "PARA",
    "POR",
    "DESDE",
    "CASH",
    "ENVIO",
    "ENVÍO",
    "INTERNACIONAL",
    "INTERBANCARIA",
    "INC",
    "LLC",
    "SA",
    "CV",
    "SAPI",
    "SADECV",
    "BANK",
    "BANCO",
    "ACCOUNT",
    "CUENTA",
    "REF",
    "FOLIO",
];

/// Significant identity tokens drawn from a transaction's name fields —
/// counterparty / payee / payer first (the people-facing fields), then the
/// raw description. Tokens are upper-cased, alphabetic, length ≥ 4, and not
/// stopwords or remittance-service names.
fn identity_tokens(tx: &TxCandidate) -> std::collections::HashSet<String> {
    let mut out = std::collections::HashSet::new();
    let fields = [
        tx.counterparty_name.as_deref(),
        tx.payment_payee.as_deref(),
        tx.payment_payer.as_deref(),
        tx.merchant_name.as_deref(),
        Some(tx.description.as_str()),
        tx.original_description.as_deref(),
    ];
    for field in fields.into_iter().flatten() {
        for raw in field.to_uppercase().split(|c: char| !c.is_alphabetic()) {
            if raw.len() < 4 {
                continue;
            }
            if IDENTITY_STOPWORDS.contains(&raw) {
                continue;
            }
            if REMITTANCE_KEYWORDS.contains(&raw) {
                continue;
            }
            out.insert(raw.to_string());
        }
    }
    out
}

/// USD-equivalent magnitude of a transaction, used for the value floor so a
/// MXN leg is measured in dollars (≈ amount / rate) rather than raw pesos —
/// otherwise `MIN_USD_VALUE` pesos is only a few dollars and lets a flood of
/// tiny MXN inflows into the candidate pool.
fn usd_value(tx: &TxCandidate, reference_rate: f64) -> f64 {
    let abs = tx.amount.abs();
    if tx.currency == "MXN" {
        abs / reference_rate
    } else {
        abs
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn scoring_strong_match_with_keyword_is_high() {
        // 0% deviation, same day, keyword present.
        let score = score_match(0.0, 0, true, false);
        assert!(score >= 90, "expected near-max, got {score}");
    }

    #[test]
    fn scoring_no_keyword_still_passable_when_tight() {
        // 0% deviation, same day, no keyword/identity → 50 + 25 = 75.
        let score = score_match(0.0, 0, false, false);
        assert!((70..=80).contains(&score));
    }

    #[test]
    fn scoring_falls_off_with_deviation() {
        // 100% of the tolerance band consumed → 0 rate pts.
        let score = score_match(RATE_TOLERANCE_PCT, 0, false, false);
        assert!(
            score < 50,
            "loose match should score below threshold, got {score}"
        );
    }

    #[test]
    fn keywordless_pair_needs_identity_inside_strict_band() {
        // Tight rate, same day, shared identity → allowed.
        assert!(keywordless_pair_allowed(true, 1, 0.01));
        // Tight + same day but NO shared identity → rejected. This is the
        // coincidence false-positive (e.g. "Consultorio Andrea" card payment
        // vs an unrelated peso deposit) the user hit.
        assert!(!keywordless_pair_allowed(false, 1, 0.01));
        // Shared identity but outside the strict window → rejected.
        assert!(!keywordless_pair_allowed(true, 5, 0.01));
        // Shared identity but rate too far off the day's reference → rejected.
        assert!(!keywordless_pair_allowed(true, 1, 0.08));
    }

    #[test]
    fn scoring_identity_lifts_a_keywordless_pair() {
        // A keyword-less but tight pair that shares a counterparty identity
        // should out-score the same pair without it, and clear auto-confirm.
        let without = score_match(0.0, 0, false, false);
        let with = score_match(0.0, 0, false, true);
        assert!(with > without, "identity should raise the score");
        assert!(with >= 85, "identity + tight should be high, got {with}");
    }

    #[test]
    fn identity_tokens_share_a_person_name_but_not_generic_words() {
        let mk = |cp: &str| TxCandidate {
            id: uuid::Uuid::new_v4(),
            account_id: uuid::Uuid::new_v4(),
            date: chrono::NaiveDate::from_ymd_opt(2026, 5, 1).unwrap(),
            amount: 100.0,
            currency: "USD".into(),
            description: "SPEI TRANSFERENCIA".into(),
            merchant_name: None,
            counterparty_name: Some(cp.to_string()),
            original_description: None,
            payment_payee: None,
            payment_payer: None,
        };
        // Two legs that both name Andrea share an identity token...
        let a = identity_tokens(&mk("Andrea Lopez"));
        let b = identity_tokens(&mk("ANDREA L"));
        assert!(!a.is_disjoint(&b), "shared name should overlap");
        // ...but two legs that only share the generic "SPEI TRANSFERENCIA"
        // boilerplate do NOT (those are stopwords).
        let c = identity_tokens(&mk("Carlos"));
        let d = identity_tokens(&mk("Beatriz"));
        assert!(c.is_disjoint(&d), "different names must not overlap");
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
