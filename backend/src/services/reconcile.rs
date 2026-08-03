//! Guided statement reconciliation at import time — the YNAB "matches to the
//! centavo" ritual, applied to file imports.
//!
//! `continuity.rs` answers "is a statement MISSING between two others?".
//! This module answers the complementary, per-statement question the user
//! actually acts on:
//!
//! > After this import lands, will the app's ledger for this statement's
//! > period end on the same balance the bank printed?
//!
//! ## Where the two balances come from
//!
//! * **The statement's closing balance** is the bank's own running SALDO
//!   column (`ParsedTransaction::balance_after`) — a figure the bank printed,
//!   not one we computed from the rows. The statement's opening balance is
//!   recovered the same way (`first balance_after − the amounts up to and
//!   including that row`).
//! * **The computed closing balance** is `opening + every amount the account
//!   will hold for that period after the import` — the rows the app ALREADY
//!   has in the period, plus the incoming rows that will actually be inserted
//!   (a row whose dedup signature already exists is skipped by confirm's
//!   `ON CONFLICT`, so it must be counted exactly once).
//!
//! The two agree whenever the app's ledger for the period is exactly the
//! statement. They diverge when the app holds rows the statement doesn't —
//! a hand-entered twin of an imported row, a Plaid row, an older import under
//! a different signature — and the DIFFERENCE then equals the sum of those
//! extra rows. That is the whole point of this module: it does not just
//! report `expected != actual`, it goes looking for the specific transactions
//! that explain the gap so the UI can say *what to do*.
//!
//! ## What this is NOT
//!
//! It never blocks an import. Real statements carry mid-period adjustments,
//! fees and interest lines that a layout parser misses, so an unexplained gap
//! is guidance, not a gate — the caller surfaces the state and lets the user
//! proceed.
//!
//! ## ⚠ Known limitation (recorded, not fixed here)
//!
//! Because the closing balance is read off the LAST PARSED row, a parser that
//! silently drops trailing rows still "matches to the centavo" — the check is
//! self-referential in exactly that one case. The fix is to capture the
//! statement's independently-declared SALDO FINAL / SALDO AL CORTE, which the
//! layout parsers currently treat as a block-terminator token and discard
//! (`banorte_layout.rs`, `hsbc_layout.rs`, `banamex_pdf.rs`, `cetes_pdf.rs`,
//! `santander_layout.rs`). Capturing it is a follow-up that touches every
//! layout parser; until then this module is honest about the fact that its
//! authority is the running balance column.

use chrono::NaiveDate;
use rust_decimal::Decimal;
use serde::Serialize;
use uuid::Uuid;

/// How far outside the statement period we look for a MISDATED row that would
/// explain the gap (a row the user booked in the wrong month). Two weeks
/// covers a statement-cutoff slip without dragging in a neighbouring month's
/// whole ledger.
pub const CANDIDATE_WINDOW_DAYS: i64 = 14;

/// DoS / cost clamps on the explanation search. The subset scan is
/// `O(pool^subset)`, so both ends are bounded: at most 40 candidate rows and
/// at most 3 of them per explanation (≈10k combinations worst case). A user
/// whose period holds hundreds of unexplained rows gets `unexplained` rather
/// than a request that burns CPU hunting for a combination nobody could read
/// anyway.
pub const MAX_CANDIDATE_POOL: usize = 40;
/// Largest number of transactions we will combine into one explanation.
pub const MAX_CANDIDATE_SUBSET: usize = 3;

/// One incoming (parsed, about-to-be-imported) statement row.
///
/// Rows must arrive in STATEMENT order within a file — that is how the
/// parsers emit them and how the preview round-trips them — because the
/// opening balance is recovered by walking forward from the first row that
/// carries a running balance.
#[derive(Debug, Clone)]
pub struct IncomingRow {
    /// The statement file this row came from — the grouping key. One
    /// reconciliation is produced per file.
    pub file: String,
    pub date: NaiveDate,
    pub amount: Decimal,
    pub currency: String,
    /// The bank's running SALDO after this row. `None` for parsers that don't
    /// expose one (CSV exports, cetesdirecto movement lists).
    pub balance_after: Option<Decimal>,
    /// True when this row's dedup signature already exists in the account, so
    /// confirm's `ON CONFLICT` will skip the insert. Such a row must be
    /// counted ONCE (via its stored twin), never twice.
    pub duplicate: bool,
}

/// One row the account ALREADY holds, near the statement's period.
#[derive(Debug, Clone)]
pub struct ExistingRow {
    pub id: Uuid,
    pub date: NaiveDate,
    pub description: String,
    pub amount: Decimal,
    pub currency: String,
    /// True when this row is the stored twin of one of the incoming rows
    /// (same dedup signature) — i.e. the statement DOES account for it, so it
    /// can never be a candidate explanation for a gap.
    pub matched_by_incoming: bool,
}

/// The outcome of one statement's reconciliation.
///
/// Serialized `snake_case` (the one place this crate uses `rename_all`: the
/// values are a closed vocabulary the frontend switches on, not field names).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ReconcileStatus {
    /// The computed balance equals the statement's, to the centavo, and every
    /// incoming row is new. The green case.
    Reconciled,
    /// It reconciles, but only because some incoming rows are already in the
    /// account and will be skipped. Distinct from `Reconciled` so the UI can
    /// say "12 rows were already here" instead of implying 12 new ones landed.
    ReconciledAfterDuplicateSkip,
    /// There is a gap, and specific existing transactions sum to exactly that
    /// gap — the actionable case. See `candidates`.
    ExplainedByExistingTransactions,
    /// There is a gap and nothing in the account explains it. Usually a
    /// mid-period adjustment/fee the parser missed. Still importable.
    Unexplained,
    /// We could not check this statement at all. `unavailable_reason` says
    /// why. NEVER a stand-in for "it reconciles" — the frontend must render
    /// this distinctly from a zero difference.
    Unavailable,
}

impl ReconcileStatus {
    /// Ranking used to roll per-statement outcomes up to an account verdict.
    /// "We couldn't check" outranks both green states deliberately: an
    /// account summary must not read green when half its statements were
    /// never checked.
    fn severity(self) -> u8 {
        match self {
            ReconcileStatus::Reconciled => 0,
            ReconcileStatus::ReconciledAfterDuplicateSkip => 1,
            ReconcileStatus::Unavailable => 2,
            ReconcileStatus::ExplainedByExistingTransactions => 3,
            ReconcileStatus::Unexplained => 4,
        }
    }
}

/// Why a statement could not be reconciled. A machine code, not a sentence —
/// the backend has no locale, so the UI renders the wording (same contract as
/// `continuity::ContinuityGap`).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum UnavailableReason {
    /// No row in this statement carries a running balance, and no parser
    /// currently surfaces a declared closing balance for it. Nothing to
    /// reconcile AGAINST.
    NoRunningBalance,
    /// The file's only balance-bearing row is a period-total MARKER (cetes
    /// "Total final", Nu "Saldo al generar") stamped for the snapshot
    /// back-fill, not a running ledger — so there is no opening balance to
    /// anchor on. Same heuristic `continuity.rs` uses to avoid chaining those.
    BalanceMarkerOnly,
    /// The statement, or the account rows in its period, span more than one
    /// currency. Summing across currencies is a banned operation here (it has
    /// historically produced ~18x overstatements), so we refuse rather than
    /// report a meaningless number.
    MixedCurrency,
}

/// How a candidate transaction would explain the gap.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum CandidateKind {
    /// Inside the statement period and NOT on the statement: the account
    /// holds it but the bank doesn't — a likely double entry to delete.
    DoubleEntryInPeriod,
    /// Just outside the period: the bank counts it inside, the app has it
    /// dated outside — a likely misdated row to move.
    MisdatedNearPeriod,
}

/// One existing transaction offered as an explanation for the gap.
#[derive(Debug, Clone, Serialize)]
pub struct CandidateTransaction {
    pub transaction_id: Uuid,
    /// ISO `YYYY-MM-DD`.
    pub date: String,
    pub description: String,
    pub amount: Decimal,
    pub kind: CandidateKind,
}

/// Per-statement reconciliation result.
///
/// Every optional money field is serialized EXPLICITLY as `null` when absent
/// (no `skip_serializing_if`): an omitted key is indistinguishable from a
/// missing one on the client, and the whole point of `unavailable` is that
/// "we can't check this" must render differently from "it reconciles".
#[derive(Debug, Clone, Serialize)]
pub struct StatementReconciliation {
    pub file: String,
    /// ISO `YYYY-MM-DD` bounds of the rows in this file.
    pub period_start: String,
    pub period_end: String,
    /// The single currency of this statement, or `None` when the rows
    /// disagree (which is itself an `unavailable` reason).
    pub currency: Option<String>,
    pub status: ReconcileStatus,
    /// Set iff `status == Unavailable`.
    pub unavailable_reason: Option<UnavailableReason>,
    /// The bank's own opening / closing SALDO for the period.
    pub statement_opening_balance: Option<Decimal>,
    pub statement_closing_balance: Option<Decimal>,
    /// Opening + every amount the account will hold for this period after the
    /// import lands.
    pub computed_closing_balance: Option<Decimal>,
    /// `statement_closing_balance − computed_closing_balance`, rounded to 2dp.
    /// Positive = the app is SHORT of the bank; negative = the app holds more
    /// than the bank does.
    pub difference: Option<Decimal>,
    /// Rows this file contributes to the import.
    pub incoming_rows: usize,
    /// …of which confirm will skip as already present.
    pub duplicate_rows: usize,
    /// Rows the account already holds inside the period.
    pub existing_rows_in_period: usize,
    /// Specific transactions that sum to the gap. Empty unless
    /// `status == ExplainedByExistingTransactions`.
    pub candidates: Vec<CandidateTransaction>,
}

/// Per-account roll-up: one entry per statement file, plus a worst-of verdict.
#[derive(Debug, Clone, Serialize)]
pub struct AccountReconciliation {
    pub account_id: Uuid,
    pub account_name: String,
    pub currency: String,
    /// Worst statement outcome (see `ReconcileStatus::severity`), so a
    /// multi-account import can show one badge per account.
    pub status: ReconcileStatus,
    pub statements: Vec<StatementReconciliation>,
}

/// Group an account's incoming rows by statement file, preserving first-seen
/// order, and reconcile each against the account's existing rows.
///
/// `existing` is every row the account already holds anywhere near the import
/// (the caller widens the span by `CANDIDATE_WINDOW_DAYS`); the per-statement
/// period filtering happens here so the pure logic stays testable without a DB.
pub fn reconcile_account(
    account_id: Uuid,
    account_name: &str,
    account_currency: &str,
    incoming: &[IncomingRow],
    existing: &[ExistingRow],
) -> AccountReconciliation {
    let mut order: Vec<String> = Vec::new();
    let mut groups: std::collections::HashMap<String, Vec<IncomingRow>> =
        std::collections::HashMap::new();
    for row in incoming {
        let entry = groups.entry(row.file.clone()).or_insert_with(|| {
            order.push(row.file.clone());
            Vec::new()
        });
        entry.push(row.clone());
    }

    let statements: Vec<StatementReconciliation> = order
        .into_iter()
        .map(|file| {
            let rows = &groups[&file];
            reconcile_statement(&file, rows, existing)
        })
        .collect();

    let status = statements
        .iter()
        .map(|s| s.status)
        .max_by_key(|s| s.severity())
        // An account with no rows at all can't be reconciled; say so rather
        // than claim a green.
        .unwrap_or(ReconcileStatus::Unavailable);

    AccountReconciliation {
        account_id,
        account_name: account_name.to_string(),
        currency: account_currency.to_string(),
        status,
        statements,
    }
}

/// Reconcile ONE statement file. `rows` are that file's incoming rows in
/// statement order; `existing` is the account's nearby stored rows.
pub fn reconcile_statement(
    file: &str,
    rows: &[IncomingRow],
    existing: &[ExistingRow],
) -> StatementReconciliation {
    let duplicate_rows = rows.iter().filter(|r| r.duplicate).count();
    let base =
        |status, reason, period: Option<(NaiveDate, NaiveDate)>, currency, existing_count| {
            StatementReconciliation {
                file: file.to_string(),
                period_start: period.map(|(s, _)| s.to_string()).unwrap_or_default(),
                period_end: period.map(|(_, e)| e.to_string()).unwrap_or_default(),
                currency,
                status,
                unavailable_reason: reason,
                statement_opening_balance: None,
                statement_closing_balance: None,
                computed_closing_balance: None,
                difference: None,
                incoming_rows: rows.len(),
                duplicate_rows,
                existing_rows_in_period: existing_count,
                candidates: Vec::new(),
            }
        };

    let (Some(period_start), Some(period_end)) = (
        rows.iter().map(|r| r.date).min(),
        rows.iter().map(|r| r.date).max(),
    ) else {
        // Unreachable via the handler (empty groups are never created), but a
        // pure function must not panic on an empty slice.
        return base(
            ReconcileStatus::Unavailable,
            Some(UnavailableReason::NoRunningBalance),
            None,
            None,
            0,
        );
    };
    let period = Some((period_start, period_end));

    // Single-currency assertion #1: the statement itself. A statement bundling
    // two currencies can't have one running balance, so refuse before doing
    // any arithmetic on it.
    let currencies: std::collections::BTreeSet<String> = rows
        .iter()
        .map(|r| r.currency.trim().to_uppercase())
        .collect();
    if currencies.len() != 1 {
        return base(
            ReconcileStatus::Unavailable,
            Some(UnavailableReason::MixedCurrency),
            period,
            None,
            0,
        );
    }
    let currency = currencies.into_iter().next().unwrap_or_default();
    let currency_out = Some(currency.clone());

    let in_period: Vec<&ExistingRow> = existing
        .iter()
        .filter(|r| r.date >= period_start && r.date <= period_end)
        .collect();

    // Single-currency assertion #2: the account's own rows in the period. A
    // stray USD row inside an MXN statement's period would otherwise be summed
    // straight into an MXN total — the exact cross-currency mistake that once
    // produced ~18x overstatements. Refuse instead of guessing.
    if in_period
        .iter()
        .any(|r| r.currency.trim().to_uppercase() != currency)
    {
        return base(
            ReconcileStatus::Unavailable,
            Some(UnavailableReason::MixedCurrency),
            period,
            currency_out,
            in_period.len(),
        );
    }

    // The bank's running-balance column is the only closing-balance authority
    // this pipeline currently has (see the module doc's ⚠ note).
    let balance_idx: Vec<usize> = rows
        .iter()
        .enumerate()
        .filter(|(_, r)| r.balance_after.is_some())
        .map(|(i, _)| i)
        .collect();
    if balance_idx.is_empty() {
        return base(
            ReconcileStatus::Unavailable,
            Some(UnavailableReason::NoRunningBalance),
            period,
            currency_out,
            in_period.len(),
        );
    }
    if crate::services::continuity::is_balance_marker_only(balance_idx.len(), rows.len()) {
        return base(
            ReconcileStatus::Unavailable,
            Some(UnavailableReason::BalanceMarkerOnly),
            period,
            currency_out,
            in_period.len(),
        );
    }

    // Opening = the first printed balance, minus every amount up to and
    // including the row it belongs to. When every row carries a balance (the
    // normal layout-parser case) this is just `first.balance_after -
    // first.amount`; the general form also survives a leading run of rows the
    // parser could not attach a balance to.
    let first = balance_idx[0];
    let opening = rows[first].balance_after.unwrap_or_default()
        - rows[..=first].iter().map(|r| r.amount).sum::<Decimal>();
    // Closing = the last printed balance, plus any trailing amounts printed
    // without one.
    let last = *balance_idx.last().unwrap_or(&first);
    let statement_closing = rows[last].balance_after.unwrap_or_default()
        + rows[last + 1..].iter().map(|r| r.amount).sum::<Decimal>();

    // What the account will actually hold for this period once the import
    // lands: the rows already stored, plus the incoming rows that are NOT
    // duplicates (a duplicate is already represented by its stored twin, so
    // adding it would double-count it).
    let existing_sum: Decimal = in_period.iter().map(|r| r.amount).sum();
    let incoming_sum: Decimal = rows.iter().filter(|r| !r.duplicate).map(|r| r.amount).sum();
    let computed_closing = opening + existing_sum + incoming_sum;
    let difference = (statement_closing - computed_closing).round_dp(2);

    let mut result = base(
        ReconcileStatus::Reconciled,
        None,
        period,
        currency_out,
        in_period.len(),
    );
    result.statement_opening_balance = Some(opening.round_dp(2));
    result.statement_closing_balance = Some(statement_closing.round_dp(2));
    result.computed_closing_balance = Some(computed_closing.round_dp(2));
    result.difference = Some(difference);

    if difference.is_zero() {
        result.status = if duplicate_rows > 0 {
            ReconcileStatus::ReconciledAfterDuplicateSkip
        } else {
            ReconcileStatus::Reconciled
        };
        return result;
    }

    // A gap. Go looking for the specific rows that explain it, smallest
    // explanation first — "this ONE transaction is a double entry" is
    // actionable; "some combination of nine rows" is not.
    //
    // Signs, both worked out in terms of a candidate row's own amount `a`:
    //   * DOUBLE ENTRY (row is inside the period, not on the statement): it is
    //     already in `computed`, which is therefore `a` too high, so
    //     `difference = -a` → search the in-period pool for `-difference`.
    //   * MISDATED (bank counted it inside, the app has it dated outside): it
    //     is missing from `computed`, so `difference = a` → search the
    //     just-outside pool for `+difference`.
    let in_period_pool: Vec<&ExistingRow> = in_period
        .iter()
        .copied()
        .filter(|r| !r.matched_by_incoming && !r.amount.is_zero())
        .take(MAX_CANDIDATE_POOL)
        .collect();
    if let Some(found) = subset_summing_to(&in_period_pool, -difference) {
        result.status = ReconcileStatus::ExplainedByExistingTransactions;
        result.candidates = found
            .into_iter()
            .map(|r| candidate(r, CandidateKind::DoubleEntryInPeriod))
            .collect();
        return result;
    }

    let window = chrono::Duration::days(CANDIDATE_WINDOW_DAYS);
    let near_pool: Vec<&ExistingRow> = existing
        .iter()
        .filter(|r| {
            (r.date < period_start || r.date > period_end)
                && r.date >= period_start - window
                && r.date <= period_end + window
                && !r.matched_by_incoming
                && !r.amount.is_zero()
                && r.currency.trim().to_uppercase() == currency
        })
        .take(MAX_CANDIDATE_POOL)
        .collect();
    if let Some(found) = subset_summing_to(&near_pool, difference) {
        result.status = ReconcileStatus::ExplainedByExistingTransactions;
        result.candidates = found
            .into_iter()
            .map(|r| candidate(r, CandidateKind::MisdatedNearPeriod))
            .collect();
        return result;
    }

    result.status = ReconcileStatus::Unexplained;
    result
}

fn candidate(row: &ExistingRow, kind: CandidateKind) -> CandidateTransaction {
    CandidateTransaction {
        transaction_id: row.id,
        date: row.date.to_string(),
        description: row.description.clone(),
        amount: row.amount.round_dp(2),
        kind,
    }
}

/// Smallest subset of `pool` whose amounts sum to `target` (2dp), or `None`.
/// Sizes are tried in increasing order so a one-row explanation always wins
/// over a three-row coincidence.
fn subset_summing_to<'a>(
    pool: &[&'a ExistingRow],
    target: Decimal,
) -> Option<Vec<&'a ExistingRow>> {
    let target = target.round_dp(2);
    for size in 1..=MAX_CANDIDATE_SUBSET {
        let mut acc: Vec<&ExistingRow> = Vec::with_capacity(size);
        if let Some(found) = search(pool, target, size, 0, &mut acc) {
            return Some(found);
        }
    }
    None
}

fn search<'a>(
    pool: &[&'a ExistingRow],
    target: Decimal,
    remaining: usize,
    start: usize,
    acc: &mut Vec<&'a ExistingRow>,
) -> Option<Vec<&'a ExistingRow>> {
    if remaining == 0 {
        let sum: Decimal = acc.iter().map(|r| r.amount).sum();
        return (sum.round_dp(2) == target).then(|| acc.clone());
    }
    for i in start..pool.len() {
        acc.push(pool[i]);
        if let Some(found) = search(pool, target, remaining - 1, i + 1, acc) {
            return Some(found);
        }
        acc.pop();
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    fn d(y: i32, m: u32, day: u32) -> NaiveDate {
        NaiveDate::from_ymd_opt(y, m, day).unwrap()
    }
    fn dec(s: &str) -> Decimal {
        Decimal::from_str(s).unwrap()
    }

    fn incoming(date: NaiveDate, amount: &str, balance: Option<&str>) -> IncomingRow {
        IncomingRow {
            file: "mar.pdf".into(),
            date,
            amount: dec(amount),
            currency: "MXN".into(),
            balance_after: balance.map(dec),
            duplicate: false,
        }
    }

    fn stored(date: NaiveDate, amount: &str, desc: &str) -> ExistingRow {
        ExistingRow {
            id: Uuid::new_v4(),
            date,
            description: desc.into(),
            amount: dec(amount),
            currency: "MXN".into(),
            matched_by_incoming: false,
        }
    }

    /// Jan: opens at 1000, three movements, closes at 1150.
    fn january() -> Vec<IncomingRow> {
        vec![
            incoming(d(2026, 1, 5), "-200.00", Some("800.00")),
            incoming(d(2026, 1, 12), "500.00", Some("1300.00")),
            incoming(d(2026, 1, 20), "-150.00", Some("1150.00")),
        ]
    }

    #[test]
    fn a_clean_statement_reconciles_to_the_centavo() {
        let r = reconcile_statement("mar.pdf", &january(), &[]);
        assert_eq!(r.status, ReconcileStatus::Reconciled);
        assert_eq!(r.statement_opening_balance, Some(dec("1000.00")));
        assert_eq!(r.statement_closing_balance, Some(dec("1150.00")));
        assert_eq!(r.computed_closing_balance, Some(dec("1150.00")));
        assert_eq!(r.difference, Some(Decimal::ZERO));
        assert!(r.candidates.is_empty());
    }

    #[test]
    fn duplicate_rows_are_counted_once_not_twice() {
        // The user already imported this statement: every incoming row has a
        // stored twin. Counting both would double the period's movements and
        // manufacture a gap of exactly the statement's own net change.
        let mut rows = january();
        for r in &mut rows {
            r.duplicate = true;
        }
        let existing: Vec<ExistingRow> = january()
            .iter()
            .map(|r| ExistingRow {
                id: Uuid::new_v4(),
                date: r.date,
                description: "already here".into(),
                amount: r.amount,
                currency: "MXN".into(),
                matched_by_incoming: true,
            })
            .collect();
        let r = reconcile_statement("mar.pdf", &rows, &existing);
        assert_eq!(
            r.status,
            ReconcileStatus::ReconciledAfterDuplicateSkip,
            "reconciles, but only because the 3 dupes are skipped: {r:?}"
        );
        assert_eq!(r.difference, Some(Decimal::ZERO));
        assert_eq!(r.duplicate_rows, 3);
    }

    #[test]
    fn a_gap_equal_to_one_existing_row_names_that_row() {
        // A hand-entered twin of a statement row (different wording, so no
        // signature match) sits inside the period. The app would end the month
        // 300 lower than the bank — and that 300 IS the stray row.
        let stray = stored(d(2026, 1, 14), "-300.00", "OXXO (typed by hand)");
        let stray_id = stray.id;
        let r = reconcile_statement("mar.pdf", &january(), &[stray]);
        assert_eq!(r.status, ReconcileStatus::ExplainedByExistingTransactions);
        assert_eq!(r.difference, Some(dec("300.00")));
        assert_eq!(r.candidates.len(), 1, "{:?}", r.candidates);
        assert_eq!(r.candidates[0].transaction_id, stray_id);
        assert_eq!(r.candidates[0].kind, CandidateKind::DoubleEntryInPeriod);
    }

    #[test]
    fn a_gap_can_be_explained_by_a_pair_of_rows() {
        let a = stored(d(2026, 1, 8), "-120.00", "A");
        let b = stored(d(2026, 1, 9), "-80.00", "B");
        let r = reconcile_statement("mar.pdf", &january(), &[a, b]);
        assert_eq!(r.status, ReconcileStatus::ExplainedByExistingTransactions);
        assert_eq!(r.difference, Some(dec("200.00")));
        assert_eq!(r.candidates.len(), 2);
    }

    #[test]
    fn a_row_matched_by_the_import_is_never_a_candidate() {
        // A stored row the incoming batch also carries is accounted for by the
        // statement — it must not be offered as a "double entry". Here it also
        // means the numbers still reconcile.
        let mut rows = january();
        rows[0].duplicate = true;
        let mut twin = stored(d(2026, 1, 5), "-200.00", "same row, already stored");
        twin.matched_by_incoming = true;
        let r = reconcile_statement("mar.pdf", &rows, &[twin]);
        assert_eq!(r.status, ReconcileStatus::ReconciledAfterDuplicateSkip);
        assert!(r.candidates.is_empty());
    }

    #[test]
    fn an_unexplained_gap_reports_the_number_without_inventing_a_cause() {
        // The bank's own chain jumps: a mid-period fee the parser missed.
        // Nothing in the account explains it.
        let rows = vec![
            incoming(d(2026, 1, 5), "-200.00", Some("800.00")),
            incoming(d(2026, 1, 20), "-150.00", Some("610.00")), // 800-150 = 650, not 610
        ];
        let r = reconcile_statement("mar.pdf", &rows, &[]);
        assert_eq!(r.status, ReconcileStatus::Unexplained);
        assert_eq!(r.difference, Some(dec("-40.00")));
        assert!(r.candidates.is_empty());
    }

    #[test]
    fn a_misdated_row_just_outside_the_period_is_offered_as_a_candidate() {
        // The bank's chain runs 1000 → 800 → 400: it counted a 400 charge
        // inside January that the parser did not emit as a row. The app has
        // that charge, but dated Feb 2 — so the app ends January 400 SHORT of
        // the bank, and the misdated row is the explanation.
        let rows = vec![
            incoming(d(2026, 1, 5), "-200.00", Some("800.00")),
            // A row the parser DID emit, carrying the post-charge balance.
            incoming(d(2026, 1, 20), "0.00", Some("400.00")),
        ];
        let misdated = stored(d(2026, 2, 2), "-400.00", "same charge, wrong month");
        let misdated_id = misdated.id;
        let r = reconcile_statement("mar.pdf", &rows, &[misdated]);
        assert_eq!(r.difference, Some(dec("-400.00")));
        assert_eq!(
            r.status,
            ReconcileStatus::ExplainedByExistingTransactions,
            "{r:?}"
        );
        assert_eq!(r.candidates.len(), 1);
        assert_eq!(r.candidates[0].transaction_id, misdated_id);
        assert_eq!(r.candidates[0].kind, CandidateKind::MisdatedNearPeriod);
    }

    #[test]
    fn no_running_balance_is_unavailable_not_a_zero_difference() {
        // A CSV / cetesdirecto movement list. Reporting `difference: 0` here
        // would be a lie the UI would render green.
        let rows = vec![
            incoming(d(2026, 1, 5), "-200.00", None),
            incoming(d(2026, 1, 20), "-150.00", None),
        ];
        let r = reconcile_statement("mar.pdf", &rows, &[]);
        assert_eq!(r.status, ReconcileStatus::Unavailable);
        assert_eq!(
            r.unavailable_reason,
            Some(UnavailableReason::NoRunningBalance)
        );
        assert_eq!(r.difference, None, "must NOT report a false zero");
        assert_eq!(r.statement_closing_balance, None);
    }

    #[test]
    fn a_lone_period_total_marker_is_unavailable_not_a_ledger() {
        // cetes "Total final" / Nu "Saldo al generar": one balance stamped on
        // one row among many. There is no running ledger to anchor an opening
        // balance on — same heuristic continuity.rs uses.
        let rows = vec![
            incoming(d(2026, 1, 5), "-200.00", None),
            incoming(d(2026, 1, 12), "500.00", None),
            incoming(d(2026, 1, 20), "-150.00", Some("32285.60")),
        ];
        let r = reconcile_statement("mar.pdf", &rows, &[]);
        assert_eq!(r.status, ReconcileStatus::Unavailable);
        assert_eq!(
            r.unavailable_reason,
            Some(UnavailableReason::BalanceMarkerOnly)
        );
        assert_eq!(r.difference, None);
    }

    #[test]
    fn a_single_row_statement_still_reconciles() {
        // The marker heuristic must not swallow a genuine sparse month: one
        // transaction, one balance — balance count == row count.
        let rows = vec![incoming(d(2026, 1, 5), "-200.00", Some("800.00"))];
        let r = reconcile_statement("mar.pdf", &rows, &[]);
        assert_eq!(r.status, ReconcileStatus::Reconciled);
        assert_eq!(r.statement_opening_balance, Some(dec("1000.00")));
    }

    #[test]
    fn a_mixed_currency_statement_is_refused_not_summed() {
        let mut rows = january();
        rows[1].currency = "USD".into();
        let r = reconcile_statement("mar.pdf", &rows, &[]);
        assert_eq!(r.status, ReconcileStatus::Unavailable);
        assert_eq!(r.unavailable_reason, Some(UnavailableReason::MixedCurrency));
        assert_eq!(r.difference, None);
    }

    #[test]
    fn a_foreign_currency_row_inside_the_period_is_refused_not_summed() {
        let mut stray = stored(d(2026, 1, 14), "-300.00", "USD row");
        stray.currency = "USD".into();
        let r = reconcile_statement("mar.pdf", &january(), &[stray]);
        assert_eq!(r.status, ReconcileStatus::Unavailable);
        assert_eq!(r.unavailable_reason, Some(UnavailableReason::MixedCurrency));
    }

    #[test]
    fn rows_outside_the_period_do_not_count_toward_the_computed_balance() {
        let before = stored(d(2025, 12, 20), "-999.00", "last month");
        let after = stored(d(2026, 3, 1), "-999.00", "next month");
        let r = reconcile_statement("mar.pdf", &january(), &[before, after]);
        assert_eq!(r.status, ReconcileStatus::Reconciled);
        assert_eq!(r.existing_rows_in_period, 0);
    }

    #[test]
    fn an_account_verdict_is_the_worst_of_its_statements() {
        // One clean file + one broken file. The account must not read green.
        let mut rows = january();
        for r in &mut rows {
            r.file = "jan.pdf".into();
        }
        rows.push(IncomingRow {
            file: "feb.pdf".into(),
            ..incoming(d(2026, 2, 5), "-100.00", Some("900.00"))
        });
        rows.push(IncomingRow {
            file: "feb.pdf".into(),
            ..incoming(d(2026, 2, 6), "-100.00", Some("700.00")) // jumps by 100
        });
        let out = reconcile_account(Uuid::new_v4(), "Banamex", "MXN", &rows, &[]);
        assert_eq!(out.statements.len(), 2);
        assert_eq!(out.statements[0].status, ReconcileStatus::Reconciled);
        assert_eq!(out.statements[1].status, ReconcileStatus::Unexplained);
        assert_eq!(out.status, ReconcileStatus::Unexplained);
    }

    #[test]
    fn an_unavailable_statement_outranks_a_green_one_in_the_account_verdict() {
        let mut rows = january();
        for r in &mut rows {
            r.file = "jan.pdf".into();
        }
        rows.push(IncomingRow {
            file: "feb.csv".into(),
            ..incoming(d(2026, 2, 5), "-100.00", None)
        });
        let out = reconcile_account(Uuid::new_v4(), "Banamex", "MXN", &rows, &[]);
        assert_eq!(
            out.status,
            ReconcileStatus::Unavailable,
            "an unchecked statement must not read as green"
        );
    }

    #[test]
    fn the_candidate_search_is_bounded() {
        // 200 unexplained rows: the clamp keeps the pool at 40 and the search
        // bounded, and the outcome is an honest `unexplained` rather than a
        // combinatorial hunt.
        let existing: Vec<ExistingRow> = (0..200)
            .map(|i| stored(d(2026, 1, 10), &format!("-{}.13", i + 1), "noise"))
            .collect();
        let r = reconcile_statement("mar.pdf", &january(), &existing);
        assert!(
            matches!(
                r.status,
                ReconcileStatus::Unexplained | ReconcileStatus::ExplainedByExistingTransactions
            ),
            "{r:?}"
        );
        assert!(r.candidates.len() <= MAX_CANDIDATE_SUBSET);
    }
}
