//! Statement continuity / gap detection for imports.
//!
//! Each statement carries a running balance (`balance_after`, the bank's
//! SALDO column). Within one statement that balance is continuous by
//! construction. ACROSS statements of the same account it must also chain:
//! the opening balance of month N+1 should equal the closing balance of
//! month N. When it doesn't, a statement between them is probably missing
//! (the gap month had transactions, so the balance jumped).
//!
//! We run this at confirm time over the rows being imported into ONE
//! account, so there's no cross-account ambiguity — every row here belongs
//! to the same ledger. The result is advisory: a list of human-readable
//! warnings the UI surfaces after the import ("looks like Feb is missing").

use chrono::NaiveDate;
use rust_decimal::Decimal;

/// Minimal view of an imported row needed for the continuity check.
pub struct Row {
    /// The statement file this row came from — the grouping key.
    pub file: String,
    pub date: NaiveDate,
    pub amount: Decimal,
    /// Running balance after this row (the bank's SALDO). `None` for parsers
    /// that don't expose it; such rows can't be checked.
    pub balance_after: Option<Decimal>,
}

struct Summary {
    file: String,
    start: NaiveDate,
    end: NaiveDate,
    opening: Decimal,
    closing: Decimal,
}

/// Per-statement opening/closing balances, derived from the running
/// `balance_after`. Rows must arrive in statement (running) order within
/// each file — which is how the parser emits them and how the preview
/// round-trips them. Files with no `balance_after` rows are skipped.
fn summaries(rows: &[Row]) -> Vec<Summary> {
    // Group by file, preserving first-seen order.
    let mut order: Vec<String> = Vec::new();
    let mut groups: std::collections::HashMap<String, Vec<&Row>> = std::collections::HashMap::new();
    for r in rows {
        groups.entry(r.file.clone()).or_insert_with(|| {
            order.push(r.file.clone());
            Vec::new()
        });
        groups.get_mut(&r.file).unwrap().push(r);
    }

    let mut out = Vec::new();
    for file in order {
        let group = &groups[&file];
        let with_bal: Vec<&&Row> = group.iter().filter(|r| r.balance_after.is_some()).collect();
        if with_bal.is_empty() {
            continue;
        }
        let first = with_bal.first().unwrap();
        let last = with_bal.last().unwrap();
        let opening = first.balance_after.unwrap() - first.amount;
        let closing = last.balance_after.unwrap();
        let start = group.iter().map(|r| r.date).min().unwrap();
        let end = group.iter().map(|r| r.date).max().unwrap();
        out.push(Summary {
            file,
            start,
            end,
            opening,
            closing,
        });
    }
    out
}

/// A detected balance discontinuity between two sequential statements. The
/// fields are structured (not a pre-formatted sentence) so the UI can render
/// the message in the user's language — the backend has no locale.
#[derive(Debug, Clone, serde::Serialize)]
pub struct ContinuityGap {
    pub from_file: String,
    pub to_file: String,
    /// Closing balance of `from_file` and opening balance of `to_file`, as
    /// plain decimal strings (e.g. "97665.80"); the UI formats them.
    pub from_balance: String,
    pub to_balance: String,
    /// Period boundary dates (ISO `YYYY-MM-DD`).
    pub from_date: String,
    pub to_date: String,
    /// Unexplained difference (to_balance - from_balance).
    pub diff: String,
}

/// Detect balance discontinuities between sequential statements. Returns one
/// gap per discontinuity; empty when the statements chain cleanly (or there's
/// only one).
pub fn continuity_warnings(rows: &[Row]) -> Vec<ContinuityGap> {
    let mut summaries = summaries(rows);
    // Order statements by their period so we compare month N against N+1
    // regardless of upload order.
    summaries.sort_by(|a, b| a.start.cmp(&b.start).then(a.end.cmp(&b.end)));

    let tol = Decimal::new(1, 2); // 0.01 — ignore sub-cent rounding.
    let mut warnings = Vec::new();
    for pair in summaries.windows(2) {
        let (cur, next) = (&pair[0], &pair[1]);
        // Only compare strictly-sequential statements. Overlapping periods
        // (a month imported twice, or two unrelated statements) aren't a
        // before/after pair, so skip them.
        if next.start <= cur.end {
            continue;
        }
        let diff = next.opening - cur.closing;
        if diff.abs() > tol {
            warnings.push(ContinuityGap {
                from_file: cur.file.clone(),
                to_file: next.file.clone(),
                from_balance: cur.closing.round_dp(2).to_string(),
                to_balance: next.opening.round_dp(2).to_string(),
                from_date: cur.end.to_string(),
                to_date: next.start.to_string(),
                diff: diff.round_dp(2).to_string(),
            });
        }
    }
    warnings
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
    fn row(file: &str, date: NaiveDate, amount: &str, bal: &str) -> Row {
        Row {
            file: file.to_string(),
            date,
            amount: dec(amount),
            balance_after: Some(dec(bal)),
        }
    }

    #[test]
    fn flags_a_missing_middle_statement() {
        let rows = vec![
            // Jan: opening 1000 → closing 1500.
            row("jan.pdf", d(2024, 1, 5), "500.00", "1500.00"),
            // Feb: opens at 1500 (chains) → closing 1700.
            row("feb.pdf", d(2024, 2, 5), "200.00", "1700.00"),
            // Apr: opens at 2000 — March is MISSING, balance jumped +300.
            row("apr.pdf", d(2024, 4, 5), "100.00", "2100.00"),
        ];
        let w = continuity_warnings(&rows);
        assert_eq!(w.len(), 1, "got {:#?}", w);
        assert_eq!(w[0].from_file, "feb.pdf");
        assert_eq!(w[0].to_file, "apr.pdf");
        assert!(w[0].diff.contains("300"), "reports the gap size");
    }

    #[test]
    fn clean_chain_has_no_warnings() {
        let rows = vec![
            row("jan.pdf", d(2024, 1, 5), "500.00", "1500.00"),
            row("feb.pdf", d(2024, 2, 5), "200.00", "1700.00"),
            row("mar.pdf", d(2024, 3, 5), "300.00", "2000.00"),
        ];
        assert!(continuity_warnings(&rows).is_empty());
    }

    #[test]
    fn out_of_order_upload_still_chains() {
        // Same clean chain, uploaded newest-first — sorting by period fixes
        // the comparison order.
        let rows = vec![
            row("mar.pdf", d(2024, 3, 5), "300.00", "2000.00"),
            row("jan.pdf", d(2024, 1, 5), "500.00", "1500.00"),
            row("feb.pdf", d(2024, 2, 5), "200.00", "1700.00"),
        ];
        assert!(continuity_warnings(&rows).is_empty());
    }

    #[test]
    fn duplicate_overlapping_period_is_not_flagged() {
        // The same month present twice (overlapping periods) is not a
        // sequential pair — must not be reported as a gap.
        let rows = vec![
            row("jan.pdf", d(2024, 1, 5), "500.00", "1500.00"),
            row("jan-copy.pdf", d(2024, 1, 5), "500.00", "1500.00"),
        ];
        assert!(continuity_warnings(&rows).is_empty());
    }

    #[test]
    fn rows_without_balance_are_skipped() {
        let rows = vec![
            Row { file: "a.csv".into(), date: d(2024, 1, 5), amount: dec("500.00"), balance_after: None },
            Row { file: "b.csv".into(), date: d(2024, 3, 5), amount: dec("100.00"), balance_after: None },
        ];
        assert!(continuity_warnings(&rows).is_empty());
    }
}
