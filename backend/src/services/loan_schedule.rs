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

use chrono::{Duration, Months, NaiveDate};
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

fn cents(n: i64) -> Decimal {
    Decimal::new(n, 2)
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
        // 0% amortized is just equal-principal; simple/none share the
        // flat split shape.
        "simple" => simple(principal, annual_rate, term, n),
        _ => none(principal, n),
    };

    // Stamp due dates.
    Ok(rows
        .into_iter()
        .map(|mut r| {
            r.due_date = due_date_for(origination, r.installment_number, term, freq);
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
    fn cents_helper_sanity() {
        assert_eq!(cents(1), d("0.01"));
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
