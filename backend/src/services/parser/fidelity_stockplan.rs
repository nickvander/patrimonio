//! Fidelity Stock Plan Services statement parser (the "NetBenefits" equity-comp
//! report) for poppler `pdftotext -layout` output — these ship a garbled text
//! layer, so they arrive OCR'd.
//!
//! Two variants, same shape: a monthly "STOCK PLAN SERVICES REPORT" and a
//! "YEAR-END INVESTMENT REPORT". Both are holdings statements — the account is
//! a single (or few) common-stock position plus a trivial money-market core:
//!
//! ```text
//!   Your Stock Plan Account Value:                          $85,348.32
//!   ...
//!   Holdings
//!   Stocks
//!   ORACLE CORP (ORCL)     $91,403.00   325.000   $262.6100   $85,348.25 ...
//!   FID TREASURY ONLY MMKT FUND CL   $0.07   0.070   $1.0000   $0.07 ...
//!   OUS (FYIXX)
//! ```
//!
//! The account's worth is the stock, repriced live — so, like the HSA, we model
//! it as holdings (the equity positions, parsed here and attached as live-priced
//! holdings via account_info), not a frozen number. `parse_text` emits a single
//! per-statement VALUE MARKER (period-end date, `balance_after` = the reported
//! account value, amount 0) so importing a run of statements seeds the
//! historical net-worth points; the current value then comes from the live
//! holding. One balance row per statement → the continuity check skips it.
//!
//! The tiny money-market core (its ticker wraps to the next OCR line and its
//! value rounds to ~$0) is intentionally not parsed as a holding — the value
//! marker already carries the exact total.

use crate::models::import::ParsedTransaction;
use crate::services::parser::ImportHolding;
use anyhow::Result;
use chrono::NaiveDate;
use regex::Regex;
use rust_decimal::Decimal;
use std::str::FromStr;
use tracing::info;

pub fn looks_like(upper: &str) -> bool {
    upper.contains("STOCK PLAN SERVICES")
        || (upper.contains("STOCK PLAN ACCOUNT") && upper.contains("NETBENEFITS"))
}

fn dec(s: &str) -> Option<Decimal> {
    Decimal::from_str(&s.replace([',', '$', ' '], "")).ok()
}

/// Format a USD amount with a `$` and thousands separators for a human-facing
/// description, e.g. 85348.32 → "$85,348.32".
fn money(d: Decimal) -> String {
    let neg = d.is_sign_negative();
    let s = format!("{:.2}", d.abs());
    let (int_part, frac) = s.split_once('.').unwrap_or((s.as_str(), "00"));
    let n = int_part.len();
    let mut grouped = String::new();
    for (i, ch) in int_part.chars().enumerate() {
        if i > 0 && (n - i) % 3 == 0 {
            grouped.push(',');
        }
        grouped.push(ch);
    }
    format!("{}${grouped}.{frac}", if neg { "-" } else { "" })
}

fn month_num(name: &str) -> Option<u32> {
    Some(
        match name
            .to_lowercase()
            .chars()
            .take(3)
            .collect::<String>()
            .as_str()
        {
            "jan" => 1,
            "feb" => 2,
            "mar" => 3,
            "apr" => 4,
            "may" => 5,
            "jun" => 6,
            "jul" => 7,
            "aug" => 8,
            "sep" => 9,
            "oct" => 10,
            "nov" => 11,
            "dec" => 12,
            _ => return None,
        },
    )
}

/// "Your Stock Plan Account Value: $85,348.32" — the period-end total.
pub fn parse_account_value(text: &str) -> Option<Decimal> {
    Regex::new(r"(?i)Your Stock Plan Account Value:?\s*\$?\s*([\d,]+\.\d{2})")
        .unwrap()
        .captures(text)
        .and_then(|c| dec(&c[1]))
}

/// The statement period's END date, from the "Month D, YYYY - Month D, YYYY"
/// header (monthly or year-end).
pub fn parse_period_end(text: &str) -> Option<NaiveDate> {
    let c =
        Regex::new(r"(?i)[A-Za-z]+\s+\d{1,2},\s+\d{4}\s*-\s*([A-Za-z]+)\s+(\d{1,2}),\s+(\d{4})")
            .unwrap()
            .captures(text)?;
    let month = month_num(&c[1])?;
    let day: u32 = c[2].parse().ok()?;
    let year: i32 = c[3].parse().ok()?;
    NaiveDate::from_ymd_opt(year, month, day)
}

/// Equity holdings from the Holdings section. A holding line has a ticker in
/// parens followed by a 3-decimal quantity and a 4-decimal per-unit price; the
/// `(TICKER)` tokens scattered through the legal prose ("(ETFs)", "(EAI)", …)
/// never have that numeric tail, so they don't match.
pub fn parse_holdings(text: &str) -> Vec<ImportHolding> {
    let re = Regex::new(
        r"(?m)^\s*([A-Za-z][A-Za-z0-9 .,&/'-]+?)\s*\(([A-Z]{1,6})\)\s+[^\n]*?(\d[\d,]*\.\d{3})\b[^\n]*?\$?\d[\d,]*\.\d{4}",
    )
    .unwrap();
    let mut out: Vec<ImportHolding> = Vec::new();
    for c in re.captures_iter(text) {
        let symbol = c[2].to_string();
        if out.iter().any(|h| h.symbol == symbol) {
            continue; // same position appears on multiple pages
        }
        let Some(qty) = c[3].replace(',', "").parse::<f64>().ok() else {
            continue;
        };
        if qty <= 0.0 {
            continue;
        }
        out.push(ImportHolding {
            symbol,
            name: Some(c[1].trim().to_string()),
            quantity: qty,
            value: None, // priced live on import
            cash: false,
            holding_type: None, // → "equity"
        });
    }
    out
}

pub fn parse_text(text: &str) -> Result<Vec<ParsedTransaction>> {
    let (Some(value), Some(end)) = (parse_account_value(text), parse_period_end(text)) else {
        return Ok(Vec::new());
    };
    // A single period-end value marker. Amount 0 keeps it out of cash-flow
    // analytics; `balance_after` seeds the dated net-worth snapshot. The live
    // value comes from the attached holding.
    // Show the value IN the description: the amount stays 0 (an unrealized
    // holding gain isn't a cash flow, and a negative amount would count as
    // spending), so a bare row would read as an empty "$0.00". The value lives
    // in `balance_after` (→ net-worth snapshot) and here for human eyes.
    let tx = ParsedTransaction {
        date: end,
        description: format!(
            "Stock plan value {} ({})",
            money(value),
            end.format("%b %Y")
        ),
        amount: Decimal::ZERO,
        currency: "USD".to_string(),
        category: None,
        category_detailed: None,
        original_description: None,
        balance_after: Some(value),
        account_label: None,
        from_ocr: false,
    };
    info!("Fidelity Stock Plan parser: value {} as of {}", value, end);
    Ok(vec![tx])
}

#[cfg(test)]
mod tests {
    use super::*;

    // Synthetic, mirrors the real layout (no PII).
    const MONTHLY: &str = "\
                                   STOCK PLAN SERVICES REPORT
                                   October 1, 2025 - October 31, 2025
 TEST HOLDER
   Participant Number: I10544013
   Your Stock Plan Account Value:                          $85,348.32
   Change in Investment Value *      -6,054.75   31,190.26

Account Summary                       TEST HOLDER - STOCK PLAN ACCOUNT

Holdings
Core Account
FID TREASURY ONLY MMKT FUND CL    $0.07    0.070    $1.0000    $0.07   not applicable
OUS (FYIXX)
Stocks
Common Stock
ORACLE CORP (ORCL)    $91,403.00    325.000    $262.6100    $85,348.25    $13,914.00    $71,434.25    $650.00
Total Stocks (100% of account holdings)    $91,403.00    $85,348.25
www.netbenefits.com
";

    const YEAR_END: &str = "\
                          2025 YEAR-END INVESTMENT REPORT
                          January 1, 2025 - December 31, 2025
 TEST HOLDER - STOCK PLAN ACCOUNT
   Your Stock Plan Account Value:                          $63,345.82
Holdings
Stocks
ORACLE CORP (ORCL)    325.000    $194.9100    $63,345.75    $13,914.00    $49,431.75    $617.50
www.netbenefits.com
";

    #[test]
    fn detects_both_variants() {
        assert!(looks_like(&MONTHLY.to_uppercase()));
        assert!(looks_like(&YEAR_END.to_uppercase()));
        assert!(!looks_like("SOME BANK STATEMENT"));
    }

    #[test]
    fn money_formats_with_commas() {
        assert_eq!(money(Decimal::from_str("85348.32").unwrap()), "$85,348.32");
        assert_eq!(money(Decimal::from_str("0.07").unwrap()), "$0.07");
        assert_eq!(
            money(Decimal::from_str("1234567.80").unwrap()),
            "$1,234,567.80"
        );
    }

    #[test]
    fn monthly_value_marker() {
        let txs = parse_text(MONTHLY).unwrap();
        assert_eq!(txs.len(), 1);
        assert_eq!(txs[0].date, NaiveDate::from_ymd_opt(2025, 10, 31).unwrap());
        assert_eq!(txs[0].amount, Decimal::ZERO);
        assert_eq!(
            txs[0].balance_after,
            Some(Decimal::from_str("85348.32").unwrap())
        );
        // The value is in the description so the row isn't a bare "$0.00".
        assert!(
            txs[0].description.contains("$85,348.32"),
            "desc: {}",
            txs[0].description
        );
    }

    #[test]
    fn year_end_value_marker() {
        let txs = parse_text(YEAR_END).unwrap();
        assert_eq!(txs.len(), 1);
        assert_eq!(txs[0].date, NaiveDate::from_ymd_opt(2025, 12, 31).unwrap());
        assert_eq!(
            txs[0].balance_after,
            Some(Decimal::from_str("63345.82").unwrap())
        );
    }

    #[test]
    fn extracts_stock_holding_skips_mmkt() {
        for sample in [MONTHLY, YEAR_END] {
            let h = parse_holdings(sample);
            assert_eq!(h.len(), 1, "only the stock, not the MMkt core: {h:?}");
            assert_eq!(h[0].symbol, "ORCL");
            assert_eq!(h[0].quantity, 325.0);
            assert!(!h[0].cash);
        }
    }
}
