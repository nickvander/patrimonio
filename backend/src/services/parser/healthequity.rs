//! HealthEquity HSA (Health Savings Account) statement parser for poppler
//! `pdftotext -layout` output (these statements have a garbled text layer, so
//! in practice they arrive OCR'd — the layout below is what the OCR yields).
//!
//! A HealthEquity statement is a HYBRID: a tiny *cash* spending account plus an
//! *invested* portfolio (mutual funds). The cash side is a normal dated ledger:
//!
//! ```text
//!         Date        Description of Transaction              (Withdrawal)     Balance
//!                                     Beginning Balance                       $ 479.41
//!    01/02/2026       Employer Contribution for 2026             2,000.00      2,479.41
//!    01/02/2026       Investment: VFIFX                         (2,231.33)       500.00
//!    01/05/2026       Investment Admin Fee December 2025. Average      (2.88)    497.12
//!                     HealthEquity investments of $34,669.61 at 0.0083%.
//!                                     Ending Balance                          $ 497.16
//!
//!                              Investment Portfolio
//!    Fund   Category                          Shares   Closing Price   Closing Value
//!    VFIFX  VANGUARD TARGET RETIREMENT 2050   623.74          61.05       38,079.27
//!                                     Closing Account Value             $ 38,079.27
//! ```
//!
//! We import each cash movement as a transaction (date, description, signed
//! amount — withdrawals are parenthesised). But the cash balance (~$500) is NOT
//! the account's worth: the money lives in the fund. Like the cetesdirecto
//! parser, we leave each row's `balance_after` None and stamp the *total*
//! account value (cash ending + investment closing value) onto the latest-dated
//! transaction, so net worth and the snapshot back-fill see the real HSA value
//! and the continuity check (which needs >=2 balance rows) skips these — no
//! false "missing statement" warnings as the market value drifts month to month.

use crate::models::import::ParsedTransaction;
use anyhow::Result;
use chrono::NaiveDate;
use regex::Regex;
use rust_decimal::Decimal;
use std::str::FromStr;
use tracing::info;

/// True when the extracted text looks like a HealthEquity HSA statement.
pub fn looks_like(upper: &str) -> bool {
    upper.contains("HEALTHEQUITY")
        || (upper.contains("HEALTH SAVINGS ACCOUNT") && upper.contains("INVESTMENT PORTFOLIO"))
}

fn dec(s: &str) -> Option<Decimal> {
    Decimal::from_str(&s.replace([',', '$', ' '], "")).ok()
}

/// Parse one money token, honouring accounting parentheses as negative:
/// "2,000.00" → +2000.00, "(2,231.33)" → -2231.33.
fn signed(token: &str) -> Option<Decimal> {
    let neg = token.contains('(');
    let cleaned: String = token
        .chars()
        .filter(|c| c.is_ascii_digit() || *c == '.')
        .collect();
    let v = Decimal::from_str(&cleaned).ok()?;
    Some(if neg { -v } else { v })
}

pub fn parse_text(text: &str) -> Result<Vec<ParsedTransaction>> {
    // A cash row: MM/DD/YYYY, a description, the deposit/(withdrawal) amount,
    // then the running account balance. Both money columns carry exactly two
    // decimals; the description never ends in a `.dd` token, so the lazy
    // description binds the final two money tokens to amount + balance.
    let row_re = Regex::new(
        r"^\s*(\d{2})/(\d{2})/(\d{4})\s+(.+?)\s+(\(?\$?[\d,]+\.\d{2}\)?)\s+(\$?[\d,]+\.\d{2})\s*$",
    )
    .unwrap();

    let mut txs: Vec<ParsedTransaction> = Vec::new();
    let mut in_table = false;

    for raw in text.lines() {
        let line = raw.trim_end();
        let upper = line.to_uppercase();

        // The ledger opens at the "Beginning Balance" marker and closes at
        // "Ending Balance"; the investment portfolio table sits below it.
        if upper.contains("BEGINNING BALANCE") {
            in_table = true;
            continue;
        }
        if upper.contains("ENDING BALANCE") {
            in_table = false;
            continue;
        }
        if !in_table {
            continue;
        }

        let Some(c) = row_re.captures(line) else {
            // A non-dated line inside the ledger is a wrapped continuation of
            // the previous row's description (e.g. the admin-fee basis line).
            let trimmed = line.trim();
            if !trimmed.is_empty() {
                if let Some(last) = txs.last_mut() {
                    last.description.push(' ');
                    last.description.push_str(trimmed);
                }
            }
            continue;
        };

        let month: u32 = c[1].parse().unwrap_or(0);
        let day: u32 = c[2].parse().unwrap_or(0);
        let year: i32 = c[3].parse().unwrap_or(0);
        let Some(date) = NaiveDate::from_ymd_opt(year, month, day) else {
            continue;
        };
        let description = c[4].trim().to_string();
        let Some(amount) = signed(&c[5]) else {
            continue;
        };
        if description.is_empty() {
            continue;
        }

        txs.push(ParsedTransaction {
            date,
            description,
            amount,
            currency: "USD".to_string(),
            category: None,
            category_detailed: None,
            original_description: None,
            // Cash balance (~$500) isn't the account's worth — the total is
            // stamped onto the latest row below. Leaving these None keeps the
            // import from pinning the account to the idle cash, and the
            // continuity check skips single-balance statements.
            balance_after: None,
            account_label: None,
            declared_closing_balance: None,
            from_ocr: false,
        });
    }

    // Stamp the period-end TOTAL account value (cash ending + invested value)
    // onto the latest-dated transaction — the figure that belongs in net worth.
    if let Some(total) = parse_total_account_value(text) {
        if let Some((idx, _)) = txs
            .iter()
            .enumerate()
            .max_by(|(_, a), (_, b)| a.date.cmp(&b.date))
        {
            txs[idx].balance_after = Some(total);
        }
    }

    info!("HealthEquity parser extracted {} transactions", txs.len());
    Ok(txs)
}

/// Cash "Ending Balance" (the spending-account closing balance).
pub fn parse_cash_ending_balance(text: &str) -> Option<Decimal> {
    Regex::new(r"(?i)Ending Balance\s*\$?\s*([\d,]+\.\d{2})")
        .unwrap()
        .captures(text)
        .and_then(|c| dec(&c[1]))
}

/// Invested portfolio "Closing Account Value".
pub fn parse_investment_value(text: &str) -> Option<Decimal> {
    Regex::new(r"(?i)Closing Account Value\s*\$?\s*([\d,]+\.\d{2})")
        .unwrap()
        .captures(text)
        .and_then(|c| dec(&c[1]))
}

/// The account's true worth at period end = idle cash + invested value. Falls
/// back to whichever component is present if the other is missing.
pub fn parse_total_account_value(text: &str) -> Option<Decimal> {
    let cash = parse_cash_ending_balance(text);
    let invested = parse_investment_value(text);
    match (cash, invested) {
        (Some(c), Some(i)) => Some(c + i),
        (c, i) => c.or(i),
    }
}

/// The single fund the HSA is invested in: (symbol, shares, closing value).
/// Used to suggest a holding for the Portfolio view. None if not printed.
pub fn parse_investment_holding(text: &str) -> Option<(String, Decimal, Decimal)> {
    // A 1–5 letter mutual-fund ticker followed (possibly across OCR-wrapped
    // lines) by shares, a per-share price, and the closing value. We anchor on
    // the ticker token and the three trailing decimals on its line.
    let line_re = Regex::new(
        r"(?m)^\s*([A-Z]{4,6})\b.*?([\d,]+\.\d{2,4})\s+([\d,]+\.\d{2,4})\s+([\d,]+\.\d{2})\s*$",
    )
    .unwrap();
    for c in line_re.captures_iter(text) {
        let sym = c[1].to_string();
        // Skip obvious non-tickers that can appear in all-caps headings.
        if sym == "FUND" || sym == "TOTAL" {
            continue;
        }
        let shares = dec(&c[2])?;
        let value = dec(&c[4])?;
        return Some((sym, shares, value));
    }
    None
}

#[cfg(test)]
mod tests {
    use super::*;

    // Synthetic statement mirroring the real HealthEquity layout (no PII).
    const SAMPLE: &str = "\
                                                    Account Statement
                                                    Health Savings Account
 Test Holder                                        Account Number: 9999999
                                                    Period: 01/01/26 through 01/31/26

                                                          Deposit or            Account
        Date        Description of Transaction          (Withdrawal)            Balance
                              Beginning Balance                                $ 479.41
   01/02/2026       Employer Contribution for 2026          2,000.00            2,479.41
   01/02/2026       Employee Contribution for 2026             251.92           2,731.33
   01/02/2026       Investment: VFIFX                       (2,231.33)            500.00
   01/05/2026       Investment Admin Fee December 2025. Average    (2.88)        497.12
                    HealthEquity investments of $34,669.61 at 0.0083%.
   01/31/2026       Interest for 1/1/2026 - 1/31/2026               0.04         497.16
                              Ending Balance                                   $ 497.16

                              Investment Portfolio
     Fund    Category                          Shares     Closing Price   Closing Value
     VFIFX   VANGUARD TARGET RETIREMENT 2050   623.74            61.05        38,079.27
                              Closing Account Value                         $ 38,079.27
";

    #[test]
    fn parses_cash_ledger_with_signs() {
        let txs = parse_text(SAMPLE).unwrap();
        assert_eq!(txs.len(), 5, "got {txs:#?}");

        assert_eq!(txs[0].date, NaiveDate::from_ymd_opt(2026, 1, 2).unwrap());
        assert_eq!(txs[0].amount, Decimal::from_str("2000.00").unwrap());
        assert_eq!(txs[0].currency, "USD");
        assert!(txs[0].description.contains("Employer Contribution"));

        // Parenthesised withdrawal → negative.
        assert_eq!(txs[2].amount, Decimal::from_str("-2231.33").unwrap());
        assert!(txs[2].description.contains("Investment: VFIFX"));

        // Wrapped continuation line is appended to the admin-fee description.
        assert_eq!(txs[3].amount, Decimal::from_str("-2.88").unwrap());
        assert!(
            txs[3]
                .description
                .contains("HealthEquity investments of $34,669.61"),
            "continuation should append: {:?}",
            txs[3].description
        );
    }

    #[test]
    fn stamps_total_value_on_latest_row_only() {
        let txs = parse_text(SAMPLE).unwrap();
        // Exactly one row carries a balance: the latest-dated (01/31).
        let with_bal: Vec<_> = txs.iter().filter(|t| t.balance_after.is_some()).collect();
        assert_eq!(with_bal.len(), 1, "only the period-end total is stamped");
        assert_eq!(
            with_bal[0].date,
            NaiveDate::from_ymd_opt(2026, 1, 31).unwrap()
        );
        // 497.16 cash + 38,079.27 invested = 38,576.43.
        assert_eq!(
            with_bal[0].balance_after,
            Some(Decimal::from_str("38576.43").unwrap())
        );
    }

    #[test]
    fn extracts_components_and_holding() {
        assert_eq!(
            parse_cash_ending_balance(SAMPLE),
            Some(Decimal::from_str("497.16").unwrap())
        );
        assert_eq!(
            parse_investment_value(SAMPLE),
            Some(Decimal::from_str("38079.27").unwrap())
        );
        let (sym, shares, value) = parse_investment_holding(SAMPLE).unwrap();
        assert_eq!(sym, "VFIFX");
        assert_eq!(shares, Decimal::from_str("623.74").unwrap());
        assert_eq!(value, Decimal::from_str("38079.27").unwrap());
    }

    #[test]
    fn detects_statement() {
        assert!(looks_like(&SAMPLE.to_uppercase()));
        assert!(!looks_like("SOME OTHER BANK STATEMENT"));
    }
}
