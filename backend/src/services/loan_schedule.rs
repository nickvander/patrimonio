//! Loan amortization schedule generation.
//!
//! Produces the per-installment rows for a loan's payment plan. ALL
//! money math runs in `rust_decimal::Decimal`, never `f64` — over a
//! 24-row schedule an f64 cent-drift fails to amortize to exactly
//! zero. Only the per-row `amount`/`principal`/`interest` are
//! quantized to 2dp; the periodic rate is kept full precision.
//!
//! The cardinal rule: every payment except the LAST is the level
//! payment `M`; the final row absorbs the rounding residual so
//! `Σ principal == principal` to the cent and the balance closes to
//! exactly 0. This is the bank/GnuCash convention — concentrate the
//! tail, never smear it.

use chrono::{Datelike, Duration, Months, NaiveDate};
use rust_decimal::prelude::*;
use rust_decimal::Decimal;

/// One generated installment (pre-persistence). Dates + 2dp money.
#[derive(Debug, Clone, PartialEq)]
pub struct ScheduleRow {
    pub installment_number: i32,
    pub due_date: NaiveDate,
    pub amount: Decimal,
    pub principal: Decimal,
    pub interest: Decimal,
}

/// Why a schedule couldn't be generated.
#[derive(Debug, PartialEq)]
pub enum ScheduleError {
    /// term_months or payment_frequency is null → open-ended loan,
    /// record-payment-only (no fixed plan to generate).
    OpenEnded,
    /// frequency string wasn't one of monthly/weekly/lump_sum.
    BadFrequency,
}

/// Round to 2 decimal places, half-up — the codebase's money idiom
/// (`accounts.rs` uses `round_dp(2)`).
fn money(d: Decimal) -> Decimal {
    d.round_dp(2)
}

/// Number of periods + periodic rate + a due-date function, derived
/// from the loan's frequency. annual_rate is a fraction (0.05 = 5%).
fn period_params(
    annual_rate: Decimal,
    term_months: i32,
    frequency: &str,
) -> Result<(i32, Decimal), ScheduleError> {
    match frequency {
        "monthly" => Ok((term_months, annual_rate / Decimal::from(12))),
        "weekly" => {
            // term_months months ≈ term_months * 52/12 weeks, rounded.
            let n = ((term_months as i64 * 52) as f64 / 12.0).round() as i32;
            Ok((n.max(1), annual_rate / Decimal::from(52)))
        }
        // A single balloon payment at term end: the whole holding-period
        // rate applies once.
        "lump_sum" => Ok((
            1,
            annual_rate * Decimal::from(term_months) / Decimal::from(12),
        )),
        _ => Err(ScheduleError::BadFrequency),
    }
}

/// due_date of installment k (1-based) for a frequency.
fn due_date_for(
    origination: NaiveDate,
    k: i32,
    term_months: i32,
    frequency: &str,
) -> NaiveDate {
    match frequency {
        // Months::new clamps Jan-31 + 1mo → Feb-28 correctly.
        "monthly" => origination + Months::new(k as u32),
        "weekly" => origination + Duration::days(7 * k as i64),
        // single row, due at term end.
        _ => origination + Months::new(term_months as u32),
    }
}

/// Generate the full schedule. `interest_type` ∈ {none, simple,
/// amortized, interest_only}. `rate_period` ∈ {annual, monthly} — a
/// monthly rate is converted to its effective annual figure (×12) so
/// the existing period math is reused; for a monthly payment frequency
/// this means the per-period rate ends up EXACTLY the rate the user
/// entered (annual/12 = rate·12/12 = rate), preserving "1% per month"
/// without precision loss. Returns the rows or a ScheduleError for
/// open-ended / bad-frequency loans.
pub fn generate(
    principal: Decimal,
    rate: Decimal,
    rate_period: &str,
    interest_type: &str,
    origination: NaiveDate,
    term_months: Option<i32>,
    payment_frequency: Option<&str>,
) -> Result<Vec<ScheduleRow>, ScheduleError> {
    let term = term_months.filter(|t| *t > 0).ok_or(ScheduleError::OpenEnded)?;
    let freq = payment_frequency.ok_or(ScheduleError::OpenEnded)?;
    // Normalize to an effective annual rate up front.
    let annual_rate = if rate_period == "monthly" {
        rate * Decimal::from(12)
    } else {
        rate
    };
    let (n, i) = period_params(annual_rate, term, freq)?;
    if n < 1 {
        return Err(ScheduleError::OpenEnded);
    }

    let rows = match interest_type {
        "amortized" if i > Decimal::ZERO => {
            amortized(principal, i, n)
        }
        // Each period pays interest only; principal balloons at the end.
        "interest_only" => interest_only(principal, i, n),
        // Interest compounds over the term; nothing is paid until a
        // single balloon at maturity = P(1+i)^n.
        "compound" => compound(principal, i, n),
        // 0% amortized is just equal-principal; simple/none share the
        // flat split shape.
        "simple" => simple(principal, annual_rate, term, n),
        _ => none(principal, n),
    };

    // Stamp due dates. Compound is a single balloon at maturity, so it
    // borrows the lump-sum due-date rule (origination + term) rather
    // than the per-period stepping.
    let due_freq = if interest_type == "compound" { "lump_sum" } else { freq };
    Ok(rows
        .into_iter()
        .map(|mut r| {
            r.due_date = due_date_for(origination, r.installment_number, term, due_freq);
            r
        })
        .collect())
}

/// Amortized: level payment M, declining-balance interest, final row
/// absorbs the residual.
fn amortized(principal: Decimal, i: Decimal, n: i32) -> Vec<ScheduleRow> {
    // M = P · i(1+i)^n / ((1+i)^n − 1)
    let one_plus_i = Decimal::ONE + i;
    let pow = one_plus_i.powu(n as u64);
    let m = money(principal * i * pow / (pow - Decimal::ONE));

    let mut rows = Vec::with_capacity(n as usize);
    let mut balance = principal;
    for k in 1..=n {
        let interest_k = money(balance * i);
        let (principal_k, amount_k) = if k == n {
            // Final row: principal = exact remaining balance, payment =
            // principal + its interest. Never trust M on the last row.
            (balance, money(balance + interest_k))
        } else {
            (m - interest_k, m)
        };
        balance -= principal_k;
        rows.push(ScheduleRow {
            installment_number: k,
            due_date: NaiveDate::default(),
            amount: amount_k,
            principal: principal_k,
            interest: interest_k,
        });
    }
    rows
}

/// Simple interest: flat equal principal + flat equal interest per
/// period. Total interest = P · annual_rate · (term_months/12). Final
/// row absorbs both residuals.
fn simple(principal: Decimal, annual_rate: Decimal, term_months: i32, n: i32) -> Vec<ScheduleRow> {
    let total_interest =
        principal * annual_rate * Decimal::from(term_months) / Decimal::from(12);
    let per_principal = money(principal / Decimal::from(n));
    let per_interest = money(total_interest / Decimal::from(n));

    let mut rows = Vec::with_capacity(n as usize);
    let mut principal_acc = Decimal::ZERO;
    let mut interest_acc = Decimal::ZERO;
    for k in 1..=n {
        let (principal_k, interest_k) = if k == n {
            // Tail absorbs the rounding residual on both columns.
            (principal - principal_acc, money(total_interest) - interest_acc)
        } else {
            (per_principal, per_interest)
        };
        principal_acc += principal_k;
        interest_acc += interest_k;
        rows.push(ScheduleRow {
            installment_number: k,
            due_date: NaiveDate::default(),
            amount: money(principal_k + interest_k),
            principal: principal_k,
            interest: interest_k,
        });
    }
    rows
}

/// Interest-only: every installment pays just the period interest
/// (constant, since the balance never declines until the end); the
/// full principal balloons on the final installment.
fn interest_only(principal: Decimal, i: Decimal, n: i32) -> Vec<ScheduleRow> {
    let interest_k = money(principal * i);
    let mut rows = Vec::with_capacity(n as usize);
    for k in 1..=n {
        let (principal_k, amount_k) = if k == n {
            // Balloon: principal returned in full + this period's interest.
            (principal, money(principal + interest_k))
        } else {
            (Decimal::ZERO, interest_k)
        };
        rows.push(ScheduleRow {
            installment_number: k,
            due_date: NaiveDate::default(),
            amount: amount_k,
            principal: principal_k,
            interest: interest_k,
        });
    }
    rows
}

/// Compound: interest compounds each period over the term; nothing is
/// paid until a single balloon at maturity. Total interest =
/// P·((1+i)^n − 1). One row, due at term end.
fn compound(principal: Decimal, i: Decimal, n: i32) -> Vec<ScheduleRow> {
    let grown = principal * (Decimal::ONE + i).powu(n.max(1) as u64);
    let interest = money(grown - principal);
    vec![ScheduleRow {
        installment_number: 1,
        due_date: NaiveDate::default(),
        amount: money(principal + interest),
        principal,
        interest,
    }]
}

/// Expand an explicit CUSTOM schedule — arbitrary {due_date, amount}
/// installments — into ScheduleRows. No periodic rate exists, so the
/// total interest is inferred as `Σamount − principal` (the caller
/// validates it's ≥ 0; a negative excess is treated as 0 here so we
/// never emit negative interest). Interest is spread flat as
/// `money(total_interest / n)` on each non-final row, capped
/// interest-first at the row's own amount and at the remaining total
/// interest; the final row absorbs BOTH residuals so `Σprincipal ==
/// principal` to the cent and the running balance closes to exactly 0.
/// For the 0% case (total_interest == 0) every row is all-principal.
pub fn expand_rows(rows: &[(NaiveDate, Decimal)], principal: Decimal) -> Vec<ScheduleRow> {
    let n = rows.len() as i32;
    if n == 0 {
        return Vec::new();
    }
    let sum: Decimal = rows.iter().map(|(_, a)| *a).sum();
    // Precondition: Σamount ≥ principal. Guard defensively → no negative.
    let total_interest = (sum - principal).max(Decimal::ZERO);
    let per_interest = money(total_interest / Decimal::from(n));

    let mut out = Vec::with_capacity(rows.len());
    let mut balance = principal;
    let mut interest_acc = Decimal::ZERO;
    for (k, (due, amount)) in rows.iter().enumerate() {
        let amount = money(*amount);
        let (principal_k, interest_k) = if k as i32 == n - 1 {
            // Tail: principal = exact remaining balance, interest = the
            // remaining total interest. Closes both columns to the cent.
            (balance, money(total_interest) - interest_acc)
        } else {
            // Interest-first, capped at this row's amount AND at what's
            // left of the total interest — so principal never goes
            // negative and interest never overshoots.
            let interest_k = per_interest
                .min(amount)
                .min(money(total_interest) - interest_acc);
            (amount - interest_k, interest_k)
        };
        balance -= principal_k;
        interest_acc += interest_k;
        out.push(ScheduleRow {
            installment_number: k as i32 + 1,
            due_date: *due,
            amount,
            principal: principal_k,
            interest: interest_k,
        });
    }
    out
}

/// Convenience: expand a "first `first_count` installments at
/// `first_amount`, then `amount` on `day` of every month from
/// `start_date` through `end_date` (inclusive)" pattern into explicit
/// rows, then hand them to `expand_rows`. Month stepping uses
/// `Months::new(1)`, which clamps the day like `due_date_for` (Jan-31
/// → Feb-28). `day` overrides the day-of-month of every generated row;
/// when None the day of `start_date` is used.
pub fn expand_pattern(
    principal: Decimal,
    start_date: NaiveDate,
    end_date: NaiveDate,
    day: Option<u32>,
    first_count: usize,
    first_amount: Decimal,
    amount: Decimal,
) -> Vec<ScheduleRow> {
    // Anchor the day-of-month. Months::new stepping clamps overflow, so
    // we anchor from a first-of-month date and re-apply the day each step
    // to avoid a short month permanently shrinking later dates.
    let anchor_day = day.unwrap_or_else(|| start_date.day());
    let first_month = NaiveDate::from_ymd_opt(start_date.year(), start_date.month(), 1).unwrap();

    let mut rows: Vec<(NaiveDate, Decimal)> = Vec::new();
    let mut month = first_month;
    let mut idx = 0usize;
    loop {
        // Clamp the anchor day into this month (Months stepping already
        // clamps; clamp explicitly for the day override too).
        let due = clamp_day(month, anchor_day);
        if due > end_date {
            break;
        }
        let amt = if idx < first_count { first_amount } else { amount };
        rows.push((due, amt));
        idx += 1;
        month = month + Months::new(1);
    }
    expand_rows(&rows, principal)
}

/// Build a date on `day` of `month`'s year/month, clamped to the last
/// valid day of that month (day 31 in a 30-day month → the 30th).
fn clamp_day(month: NaiveDate, day: u32) -> NaiveDate {
    let mut d = day;
    loop {
        if let Some(date) = NaiveDate::from_ymd_opt(month.year(), month.month(), d) {
            return date;
        }
        d -= 1;
    }
}

/// No interest: equal principal slices, final row absorbs the residual.
fn none(principal: Decimal, n: i32) -> Vec<ScheduleRow> {
    let per = money(principal / Decimal::from(n));
    let mut rows = Vec::with_capacity(n as usize);
    let mut acc = Decimal::ZERO;
    for k in 1..=n {
        let principal_k = if k == n { principal - acc } else { per };
        acc += principal_k;
        rows.push(ScheduleRow {
            installment_number: k,
            due_date: NaiveDate::default(),
            amount: principal_k,
            principal: principal_k,
            interest: Decimal::ZERO,
        });
    }
    rows
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    fn d(s: &str) -> Decimal {
        Decimal::from_str(s).unwrap()
    }
    fn orig() -> NaiveDate {
        NaiveDate::from_ymd_opt(2026, 1, 15).unwrap()
    }

    fn sum_principal(rows: &[ScheduleRow]) -> Decimal {
        rows.iter().map(|r| r.principal).sum()
    }
    fn sum_interest(rows: &[ScheduleRow]) -> Decimal {
        rows.iter().map(|r| r.interest).sum()
    }

    #[test]
    fn amortized_2000_5pct_24mo() {
        // $2000 @ 5% annual, 24 months monthly. Assert INVARIANTS, not
        // a hand-computed M (the level payment works out to ~$87.75 —
        // we let the code compute it and check the properties that
        // actually matter for correctness).
        let rows = generate(
            d("2000"), d("0.05"), "annual", "amortized", orig(), Some(24), Some("monthly"),
        )
        .unwrap();
        assert_eq!(rows.len(), 24);
        // Row-1 interest is exact: 2000 * 0.05/12 = 8.3333 → 8.33.
        assert_eq!(rows[0].interest, d("8.33"));
        // Each row is internally consistent: amount = principal + interest.
        for r in &rows {
            assert_eq!(r.amount, r.principal + r.interest, "row {} inconsistent", r.installment_number);
        }
        // Every payment except the last is the same level payment M.
        let m = rows[0].amount;
        for r in &rows[..23] {
            assert_eq!(r.amount, m, "row {} should be the level payment", r.installment_number);
        }
        // The final row absorbs the accumulated rounding residual, so
        // it differs from the level payment M by at most a small amount
        // (either direction — drift can round up or down). The HARD
        // guarantee is the principal-sum invariant below.
        assert!((m - rows[23].amount).abs() < d("1.00"),
            "final payment {} should be within $1 of level payment {m}", rows[23].amount);
        // HARD invariant: principal sums to EXACTLY the loan principal.
        assert_eq!(sum_principal(&rows), d("2000.00"));
        // Interest is positive and reasonable (~$105 over 24 months).
        assert!(sum_interest(&rows) > d("100") && sum_interest(&rows) < d("110"));
        // Due dates: monthly steps from origination.
        assert_eq!(rows[0].due_date, NaiveDate::from_ymd_opt(2026, 2, 15).unwrap());
        assert_eq!(rows[23].due_date, NaiveDate::from_ymd_opt(2028, 1, 15).unwrap());
    }

    #[test]
    fn amortized_weekly_period_count() {
        // 12 months weekly → 52 periods.
        let rows = generate(
            d("5000"), d("0.06"), "annual", "amortized", orig(), Some(12), Some("weekly"),
        )
        .unwrap();
        assert_eq!(rows.len(), 52);
        assert_eq!(sum_principal(&rows), d("5000.00"));
        assert_eq!(rows[0].due_date, orig() + Duration::days(7));
    }

    #[test]
    fn lump_sum_single_row() {
        // $1000 @ 10% for 12 months, lump sum → 1 row, 100 interest.
        let rows = generate(
            d("1000"), d("0.10"), "annual", "amortized", orig(), Some(12), Some("lump_sum"),
        )
        .unwrap();
        assert_eq!(rows.len(), 1);
        assert_eq!(rows[0].principal, d("1000.00"));
        assert_eq!(rows[0].interest, d("100.00"));
        assert_eq!(rows[0].amount, d("1100.00"));
    }

    #[test]
    fn none_equal_slices_with_tail() {
        // $1000 over 3 months, no interest → 333.33, 333.33, 333.34.
        let rows = generate(
            d("1000"), Decimal::ZERO, "annual", "none", orig(), Some(3), Some("monthly"),
        )
        .unwrap();
        assert_eq!(rows.len(), 3);
        assert_eq!(rows[0].principal, d("333.33"));
        assert_eq!(rows[2].principal, d("333.34")); // tail absorbs the cent
        assert_eq!(sum_principal(&rows), d("1000.00"));
        assert!(rows.iter().all(|r| r.interest == Decimal::ZERO));
    }

    #[test]
    fn simple_flat_split() {
        // $1200 @ 6% for 12 months simple → I = 72.00; per row
        // principal 100, interest 6, amount 106.
        let rows = generate(
            d("1200"), d("0.06"), "annual", "simple", orig(), Some(12), Some("monthly"),
        )
        .unwrap();
        assert_eq!(rows.len(), 12);
        assert_eq!(rows[0].principal, d("100.00"));
        assert_eq!(rows[0].interest, d("6.00"));
        assert_eq!(rows[0].amount, d("106.00"));
        assert_eq!(sum_principal(&rows), d("1200.00"));
        assert_eq!(sum_interest(&rows), d("72.00"));
    }

    #[test]
    fn none_divisible_no_tail_needed() {
        let rows = generate(
            d("1200"), Decimal::ZERO, "annual", "none", orig(), Some(12), Some("monthly"),
        )
        .unwrap();
        assert!(rows.iter().all(|r| r.principal == d("100.00")));
        assert_eq!(sum_principal(&rows), d("1200.00"));
    }

    #[test]
    fn open_ended_rejected() {
        assert_eq!(
            generate(d("1000"), Decimal::ZERO, "annual", "none", orig(), None, Some("monthly")),
            Err(ScheduleError::OpenEnded)
        );
        assert_eq!(
            generate(d("1000"), Decimal::ZERO, "annual", "none", orig(), Some(12), None),
            Err(ScheduleError::OpenEnded)
        );
    }

    #[test]
    fn bad_frequency_rejected() {
        assert_eq!(
            generate(d("1000"), Decimal::ZERO, "annual", "none", orig(), Some(12), Some("daily")),
            Err(ScheduleError::BadFrequency)
        );
    }

    #[test]
    fn zero_rate_amortized_is_equal_principal() {
        // 0% amortized falls through to equal-principal slices.
        let rows = generate(
            d("1200"), Decimal::ZERO, "annual", "amortized", orig(), Some(12), Some("monthly"),
        )
        .unwrap();
        assert_eq!(sum_principal(&rows), d("1200.00"));
        assert!(rows.iter().all(|r| r.interest == Decimal::ZERO));
    }

    #[test]
    fn interest_only_balloon() {
        // $10,000 @ 12% annual, 6 months monthly, interest-only.
        // Monthly periodic = 1% → interest $100 every month; principal
        // balloons in month 6.
        let rows = generate(
            d("10000"), d("0.12"), "annual", "interest_only", orig(), Some(6), Some("monthly"),
        )
        .unwrap();
        assert_eq!(rows.len(), 6);
        for r in &rows[..5] {
            assert_eq!(r.principal, Decimal::ZERO, "non-final rows are interest-only");
            assert_eq!(r.interest, d("100.00"));
            assert_eq!(r.amount, d("100.00"));
        }
        // Final: full principal + the month's interest.
        assert_eq!(rows[5].principal, d("10000.00"));
        assert_eq!(rows[5].interest, d("100.00"));
        assert_eq!(rows[5].amount, d("10100.00"));
        // Principal still sums to exactly the loan principal.
        assert_eq!(sum_principal(&rows), d("10000.00"));
    }

    #[test]
    fn monthly_rate_period_preserves_rate() {
        // "1% per MONTH" amortized over 12 months. With rate_period
        // 'monthly', the per-period rate must be EXACTLY 1% — so row-1
        // interest = 10000 * 0.01 = 100.00 exactly.
        let monthly = generate(
            d("10000"), d("0.01"), "monthly", "amortized", orig(), Some(12), Some("monthly"),
        )
        .unwrap();
        assert_eq!(monthly[0].interest, d("100.00"),
            "1%/month must give exactly $100 first-month interest on $10k");
        assert_eq!(sum_principal(&monthly), d("10000.00"));

        // Equivalence: 1%/month == 12%/annual for a monthly schedule.
        let annual = generate(
            d("10000"), d("0.12"), "annual", "amortized", orig(), Some(12), Some("monthly"),
        )
        .unwrap();
        assert_eq!(monthly[0].amount, annual[0].amount,
            "1%/month and 12%/annual must produce the same monthly payment");
    }

    #[test]
    fn compound_single_balloon() {
        // $1,000 @ 10% annual, 2 years monthly-compounded → one balloon
        // at maturity. (1 + 0.10/12)^24 ≈ 1.22039 → interest ≈ $220.39.
        let rows = generate(
            d("1000"), d("0.10"), "annual", "compound", orig(), Some(24), Some("monthly"),
        )
        .unwrap();
        assert_eq!(rows.len(), 1, "compound is a single balloon");
        assert_eq!(rows[0].principal, d("1000.00"));
        assert!((rows[0].interest - d("220.39")).abs() < d("0.50"),
            "compound interest ~220.39, got {}", rows[0].interest);
        assert_eq!(rows[0].amount, rows[0].principal + rows[0].interest);
        // Due at maturity (origination + 24 months), not period 1.
        assert_eq!(rows[0].due_date, NaiveDate::from_ymd_opt(2028, 1, 15).unwrap());
        // Compound > simple over the same terms (10%·2 = $200 simple).
        assert!(rows[0].interest > d("200.00"));
    }

    #[test]
    fn custom_luis_0pct_37_rows() {
        // The motivating case: a 0% loan, principal 130,000, 37 payments
        // that sum to exactly the principal. Payment 1 = 3500 (2026-06-15),
        // payment 2 = 4000 (2026-07-15, a one-off bump), then 3500 on the
        // 15th of every month from 2026-08-15 through 2029-06-15.
        let mut rows: Vec<(NaiveDate, Decimal)> = vec![
            (NaiveDate::from_ymd_opt(2026, 6, 15).unwrap(), d("3500")),
            (NaiveDate::from_ymd_opt(2026, 7, 15).unwrap(), d("4000")),
        ];
        let mut month = NaiveDate::from_ymd_opt(2026, 8, 15).unwrap();
        let end = NaiveDate::from_ymd_opt(2029, 6, 15).unwrap();
        while month <= end {
            rows.push((month, d("3500")));
            month = month + Months::new(1);
        }
        // 2 explicit + 35 monthly (2026-08 .. 2029-06 inclusive) = 37.
        assert_eq!(rows.len(), 37);
        let total: Decimal = rows.iter().map(|(_, a)| *a).sum();
        assert_eq!(total, d("130000"), "payments must sum to principal");

        let out = expand_rows(&rows, d("130000"));
        assert_eq!(out.len(), 37);
        assert_eq!(sum_principal(&out), d("130000.00"));
        assert_eq!(sum_interest(&out), d("0.00"));
        // Each row: 0% → all principal, amount == principal.
        for r in &out {
            assert_eq!(r.interest, Decimal::ZERO);
            assert_eq!(r.amount, r.principal);
        }
        // Running balance closes to exactly 0 on the last row.
        let paid: Decimal = out.iter().map(|r| r.principal).sum();
        assert_eq!(d("130000") - paid, Decimal::ZERO);
        // Dates + numbering are the input's, 1-based.
        assert_eq!(out[0].installment_number, 1);
        assert_eq!(out[0].due_date, NaiveDate::from_ymd_opt(2026, 6, 15).unwrap());
        assert_eq!(out[1].amount, d("4000.00"));
        assert_eq!(out[36].due_date, end);
    }

    #[test]
    fn custom_with_interest_closes_and_no_negatives() {
        // Σamount = 1100 on principal 1000 → total interest 100. Four rows
        // of 275 (sum 1100). Interest spreads flat (25/row); tail absorbs
        // residuals. Nothing negative; both columns close.
        let rows: Vec<(NaiveDate, Decimal)> = (0..4)
            .map(|k| {
                (
                    NaiveDate::from_ymd_opt(2026, 1 + k, 15).unwrap(),
                    d("275"),
                )
            })
            .collect();
        let out = expand_rows(&rows, d("1000"));
        assert_eq!(out.len(), 4);
        assert_eq!(sum_principal(&out), d("1000.00"));
        assert_eq!(sum_interest(&out), d("100.00"));
        for r in &out {
            assert!(r.principal >= Decimal::ZERO, "no negative principal");
            assert!(r.interest >= Decimal::ZERO, "no negative interest");
            assert_eq!(r.amount, r.principal + r.interest, "row consistent");
        }
        // Running principal balance closes to exactly 0.
        let paid: Decimal = out.iter().map(|r| r.principal).sum();
        assert_eq!(d("1000") - paid, Decimal::ZERO);
    }

    #[test]
    fn custom_expand_pattern_matches_manual() {
        // Pattern: first 1 at 4000, then 3500 monthly on the 15th from
        // 2026-06-15 through 2026-09-15 → 4 rows: 4000, 3500, 3500, 3500.
        let rows = expand_pattern(
            d("14500"),
            NaiveDate::from_ymd_opt(2026, 6, 15).unwrap(),
            NaiveDate::from_ymd_opt(2026, 9, 15).unwrap(),
            Some(15),
            1,
            d("4000"),
            d("3500"),
        );
        assert_eq!(rows.len(), 4);
        assert_eq!(rows[0].amount, d("4000.00"));
        assert_eq!(rows[1].amount, d("3500.00"));
        assert_eq!(rows[3].due_date, NaiveDate::from_ymd_opt(2026, 9, 15).unwrap());
        // 4000 + 3*3500 = 14500 == principal → 0 interest.
        assert_eq!(sum_principal(&rows), d("14500.00"));
        assert_eq!(sum_interest(&rows), d("0.00"));
    }

    #[test]
    fn custom_empty_rows_is_empty() {
        assert!(expand_rows(&[], d("1000")).is_empty());
    }

    #[test]
    fn monthly_rate_simple_interest() {
        // 2%/month simple over 6 months on $1000 → total interest
        // = 1000 * 0.02 * 6 = $120; per row $20 interest + ~166.67 principal.
        let rows = generate(
            d("1000"), d("0.02"), "monthly", "simple", orig(), Some(6), Some("monthly"),
        )
        .unwrap();
        assert_eq!(sum_principal(&rows), d("1000.00"));
        assert_eq!(sum_interest(&rows), d("120.00"));
        assert_eq!(rows[0].interest, d("20.00"));
    }
}
