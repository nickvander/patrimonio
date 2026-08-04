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
//! * **The statement's closing balance** is, in order of preference:
//!   1. the statement's own **declared** total — `SALDO FINAL DEL PERIODO`
//!      and friends, captured by the parser from the line the bank prints as
//!      its summary (`ParsedTransaction::declared_closing_balance`). This is
//!      the INDEPENDENT figure: it is not derived from the rows at all.
//!   2. otherwise, the last value in the bank's running SALDO column
//!      (`ParsedTransaction::balance_after`) — still a figure the bank
//!      printed, but attached to a row we parsed.
//!
//!   Which one was used is reported as `closing_balance_source`, and both
//!   numbers are reported separately (`declared_closing_balance` /
//!   `running_closing_balance`) so the caller can distinguish a genuinely
//!   independent check from a self-consistent one — and can show the user the
//!   two disagreeing figures when they disagree.
//!
//!   The statement's opening balance always comes from the running column
//!   (`first balance_after − the amounts up to and including that row`).
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
//! ## Why the declared balance matters (and what is still uncovered)
//!
//! With the closing balance read off the LAST PARSED row, a parser that
//! silently drops trailing rows "matches to the centavo": the rows it kept
//! define the balance it is checked against, so the check is self-referential
//! in exactly that case. A declared total breaks that circle — the bank's
//! printed figure does not move when our parse loses a row, so the loss
//! shows up as a `difference`.
//!
//! **Which parsers declare one** (`closing_balance_source == Declared` only
//! for these — everything else is the running-column fallback, which is
//! honest but not independent):
//!
//! * `santander_layout.rs` — the closing `SALDO FINAL DEL PERIODO` row
//!   (its opener, `… DEL PERIODO ANTERIOR`, is deliberately excluded).
//! * `nu_mexico_pdf.rs` — the older running-balance layout's
//!   "Resumen del periodo → Saldo final". Nu's CURRENT layout prints only a
//!   grand total across account + cajitas + crédito, which is not this
//!   account's closing balance, so it declares nothing.
//!
//! Still uncovered, deliberately:
//!
//! * `banorte_layout.rs`, `hsbc_layout.rs`, `banamex_pdf.rs`,
//!   `banamex_layout.rs` recognise `SALDO FINAL` / `SALDO AL CORTE` only as a
//!   furniture/blacklist keyword, and no fixture we have contains the line
//!   with its amount — so where on the line the total sits is unverified.
//!   Guessing would risk a plausible-looking WRONG number, which is worse
//!   than the fallback; they stay on the running column until a real
//!   statement is available.
//! * `cetes_pdf.rs` declares a portfolio "Total final", not a closing balance
//!   for the cash movements it emits as rows — a different quantity. It is
//!   already stamped as a lone balance marker, which this module reports as
//!   `Unavailable` / `BalanceMarkerOnly` rather than pretending to reconcile.
//! * The **opening** balance is still taken from the running column, so a
//!   parser that drops LEADING rows is not caught by this (the opening is
//!   back-computed from the first row it kept).
//! * A declared total only helps when the statement also has a running
//!   column: without one there is no opening balance to add movements to, so
//!   the outcome stays `Unavailable` / `NoRunningBalance`.

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
    /// The statement's own DECLARED closing total, stamped identically on
    /// every row of the statement by the parsers that can read it (see the
    /// module doc for which). `None` leaves this statement on the
    /// running-column fallback.
    pub declared_closing_balance: Option<Decimal>,
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

/// Where the closing balance we checked against came from — the difference
/// between a genuinely INDEPENDENT check and a self-consistent one.
///
/// Not a status: the outcome vocabulary is unchanged, this is the provenance
/// of the number behind it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ClosingBalanceSource {
    /// The statement's own printed total (`SALDO FINAL DEL PERIODO`, …). It
    /// does not come from the parsed rows, so it catches a parse that dropped
    /// trailing rows.
    Declared,
    /// The last value of the bank's running SALDO column. Proves the rows are
    /// internally consistent; CANNOT prove no trailing row was dropped, since
    /// the last row we kept defines the balance being checked.
    RunningBalance,
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
    /// The bank's own opening SALDO for the period (always recovered from the
    /// running column) and the closing balance we actually checked against —
    /// the declared total when there is one, else the running column's last
    /// value. `closing_balance_source` says which.
    pub statement_opening_balance: Option<Decimal>,
    pub statement_closing_balance: Option<Decimal>,
    /// Provenance of `statement_closing_balance`. `None` iff we couldn't
    /// check the statement at all.
    pub closing_balance_source: Option<ClosingBalanceSource>,
    /// The two candidates, reported separately and always (explicit `null`
    /// when absent) so the caller never has to infer one from the other.
    /// **`declared != running` is the fingerprint of a parse that lost rows**:
    /// the bank's own total disagrees with where our rows end.
    pub declared_closing_balance: Option<Decimal>,
    pub running_closing_balance: Option<Decimal>,
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
                closing_balance_source: None,
                declared_closing_balance: None,
                running_closing_balance: None,
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

    // The running-balance column anchors the OPENING balance, so a statement
    // without one still can't be reconciled — a declared closing total alone
    // gives us nothing to add the period's movements to.
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
    // Running closing = the last printed balance, plus any trailing amounts
    // printed without one. Self-consistent by construction: it is defined by
    // the rows we parsed, so it cannot notice rows we didn't.
    let last = *balance_idx.last().unwrap_or(&first);
    let running_closing = (rows[last].balance_after.unwrap_or_default()
        + rows[last + 1..].iter().map(|r| r.amount).sum::<Decimal>())
    .round_dp(2);

    // The statement's own declared total, when a parser captured one. Every
    // row of a statement carries the same value; if this group somehow holds
    // two different ones (two statements or two account sections merged under
    // one file name) we refuse to pick a winner and fall back to the running
    // column rather than check against an arbitrary half of the file.
    let declared: Vec<Decimal> = {
        let mut seen: Vec<Decimal> = Vec::new();
        for d in rows.iter().filter_map(|r| r.declared_closing_balance) {
            let d = d.round_dp(2);
            if !seen.contains(&d) {
                seen.push(d);
            }
        }
        seen
    };
    let declared_closing: Option<Decimal> = match declared.as_slice() {
        [only] => Some(*only),
        _ => None,
    };

    // Prefer the declared total: it is the only closing balance that is
    // independent of the rows, so it is the only one that can catch a parse
    // that silently dropped trailing rows. A disagreement between it and the
    // running column is a REAL finding, and it must land in `difference` (a
    // gap the user can act on), never as an error that hides the import.
    let (statement_closing, closing_source) = match declared_closing {
        Some(d) => (d, ClosingBalanceSource::Declared),
        None => (running_closing, ClosingBalanceSource::RunningBalance),
    };

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
    result.closing_balance_source = Some(closing_source);
    result.declared_closing_balance = declared_closing;
    result.running_closing_balance = Some(running_closing);
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
            declared_closing_balance: None,
            duplicate: false,
        }
    }

    /// Stamp a parser-captured declared closing total on every row, the way
    /// the layout parsers do.
    fn declaring(rows: Vec<IncomingRow>, declared: &str) -> Vec<IncomingRow> {
        rows.into_iter()
            .map(|r| IncomingRow {
                declared_closing_balance: Some(dec(declared)),
                ..r
            })
            .collect()
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
    fn without_a_declared_total_the_check_says_it_used_the_running_column() {
        // The fallback must never be reported as an independent check.
        let r = reconcile_statement("mar.pdf", &january(), &[]);
        assert_eq!(
            r.closing_balance_source,
            Some(ClosingBalanceSource::RunningBalance)
        );
        assert_eq!(r.declared_closing_balance, None);
        assert_eq!(r.running_closing_balance, Some(dec("1150.00")));
        assert_eq!(r.statement_closing_balance, Some(dec("1150.00")));
    }

    #[test]
    fn a_declared_total_is_preferred_over_the_running_column() {
        // Same statement, but the parser captured the bank's own SALDO FINAL.
        // It agrees with the running column here, so the outcome is unchanged
        // — except that the check is now independent, and says so.
        let rows = declaring(january(), "1150.00");
        let r = reconcile_statement("mar.pdf", &rows, &[]);
        assert_eq!(r.status, ReconcileStatus::Reconciled);
        assert_eq!(
            r.closing_balance_source,
            Some(ClosingBalanceSource::Declared),
            "{r:?}"
        );
        assert_eq!(r.declared_closing_balance, Some(dec("1150.00")));
        assert_eq!(r.running_closing_balance, Some(dec("1150.00")));
        assert_eq!(r.statement_closing_balance, Some(dec("1150.00")));
        assert_eq!(r.difference, Some(Decimal::ZERO));
    }

    #[test]
    fn a_declared_total_that_disagrees_with_the_rows_surfaces_as_a_difference() {
        // THE case this whole mechanism exists for. The parser dropped the
        // statement's last row (a +200 deposit): the rows it kept are
        // perfectly self-consistent and end at 1150, so the running-column
        // check reconciles to the centavo and the loss is invisible. The bank
        // declared 1350 — that 200 must surface as a difference, on an
        // importable statement, not as an error or a silent green.
        let rows = declaring(january(), "1350.00");
        let r = reconcile_statement("mar.pdf", &rows, &[]);
        assert_eq!(
            r.statement_closing_balance,
            Some(dec("1350.00")),
            "the declared total is the authority"
        );
        assert_eq!(
            r.running_closing_balance,
            Some(dec("1150.00")),
            "the running column is still reported, so the UI can show both"
        );
        assert_eq!(r.computed_closing_balance, Some(dec("1150.00")));
        assert_eq!(
            r.difference,
            Some(dec("200.00")),
            "the app is 200 SHORT of what the bank declared"
        );
        assert_eq!(
            r.status,
            ReconcileStatus::Unexplained,
            "a real, actionable gap — not Unavailable, not Reconciled: {r:?}"
        );
        assert_eq!(
            r.closing_balance_source,
            Some(ClosingBalanceSource::Declared)
        );
        assert!(r.candidates.is_empty());
    }

    #[test]
    fn the_same_statement_reads_green_on_the_running_column_and_red_on_the_declared_one() {
        // Side-by-side proof that the declared total is not decorative: the
        // identical rows reconcile when checked against themselves.
        let self_referential = reconcile_statement("mar.pdf", &january(), &[]);
        let independent = reconcile_statement("mar.pdf", &declaring(january(), "1350.00"), &[]);
        assert_eq!(self_referential.status, ReconcileStatus::Reconciled);
        assert_eq!(independent.status, ReconcileStatus::Unexplained);
    }

    #[test]
    fn conflicting_declared_totals_in_one_file_fall_back_to_the_running_column() {
        // Two statements (or two account sections) merged under one file name
        // carry two different declared totals. Picking one arbitrarily would
        // check the ledger against half the file; fall back instead, and don't
        // claim independence.
        let mut rows = declaring(january(), "1150.00");
        rows[2].declared_closing_balance = Some(dec("9999.00"));
        let r = reconcile_statement("mar.pdf", &rows, &[]);
        assert_eq!(
            r.closing_balance_source,
            Some(ClosingBalanceSource::RunningBalance),
            "{r:?}"
        );
        assert_eq!(r.declared_closing_balance, None);
        assert_eq!(r.statement_closing_balance, Some(dec("1150.00")));
        assert_eq!(r.status, ReconcileStatus::Reconciled);
    }

    #[test]
    fn a_declared_total_does_not_rescue_a_statement_with_no_running_balance() {
        // No running column → no opening balance to add the period's
        // movements to. Reporting a difference against the declared total
        // alone would be arithmetic on a number we don't have.
        let rows: Vec<IncomingRow> = declaring(
            vec![
                incoming(d(2026, 1, 5), "-200.00", None),
                incoming(d(2026, 1, 20), "-150.00", None),
            ],
            "1150.00",
        );
        let r = reconcile_statement("mar.pdf", &rows, &[]);
        assert_eq!(r.status, ReconcileStatus::Unavailable);
        assert_eq!(
            r.unavailable_reason,
            Some(UnavailableReason::NoRunningBalance)
        );
        assert_eq!(r.closing_balance_source, None);
        assert_eq!(r.difference, None);
    }

    #[test]
    fn a_declared_gap_explained_by_a_stored_row_still_names_that_row() {
        // The declared total feeds the SAME explanation search: the bank says
        // the period ends 300 higher than the app will, and a hand-typed row
        // inside the period is exactly that 300.
        let stray = stored(d(2026, 1, 14), "-300.00", "OXXO (typed by hand)");
        let stray_id = stray.id;
        let r = reconcile_statement("mar.pdf", &declaring(january(), "1150.00"), &[stray]);
        assert_eq!(r.status, ReconcileStatus::ExplainedByExistingTransactions);
        assert_eq!(r.difference, Some(dec("300.00")));
        assert_eq!(r.candidates.len(), 1);
        assert_eq!(r.candidates[0].transaction_id, stray_id);
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
