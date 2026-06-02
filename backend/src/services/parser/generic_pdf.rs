//! Generic, institution-agnostic statement parser.
//!
//! A last-resort heuristic for text-layer PDFs we don't have a custom
//! parser for (an unsupported bank, or a known bank whose layout the
//! dedicated parser didn't recognise). It walks the extracted text
//! looking for `date → description → amount` runs and emits a
//! transaction for each.
//!
//! Deliberately CONSERVATIVE to avoid fabricating rows: it requires a
//! plausible date, a non-empty alphabetic description, and an amount
//! WITH decimals (`.dd`). It cannot reliably infer a transaction's
//! direction (inflow vs outflow) the way a bank-specific parser does
//! from running balances — so the amount is taken at face value and the
//! user reviews everything in the import preview before confirming.

use crate::models::import::ParsedTransaction;
use anyhow::Result;
use chrono::{Datelike, NaiveDate};
use regex::Regex;
use rust_decimal::Decimal;
use std::str::FromStr;
use tracing::info;

/// Spanish (and a few English) month names → 1..=12. Input is matched
/// case-insensitively against an already-uppercased line.
fn month_name(s: &str) -> Option<u32> {
    match s.trim() {
        "ENE" | "ENERO" | "JAN" | "JANUARY" => Some(1),
        "FEB" | "FEBRERO" | "FEBRUARY" => Some(2),
        "MAR" | "MARZO" | "MARCH" => Some(3),
        "ABR" | "ABRIL" | "APR" | "APRIL" => Some(4),
        "MAY" | "MAYO" => Some(5),
        "JUN" | "JUNIO" | "JUNE" => Some(6),
        "JUL" | "JULIO" | "JULY" => Some(7),
        "AGO" | "AGOSTO" | "AUG" | "AUGUST" => Some(8),
        "SEP" | "SEPT" | "SEPTIEMBRE" | "SEPTEMBER" => Some(9),
        "OCT" | "OCTUBRE" | "OCTOBER" => Some(10),
        "NOV" | "NOVIEMBRE" | "NOVEMBER" => Some(11),
        "DIC" | "DICIEMBRE" | "DEC" | "DECEMBER" => Some(12),
        _ => None,
    }
}

/// True when `line` contains any structural / summary keyword that must
/// never be treated as a transaction description.
fn is_noise(line: &str) -> bool {
    const NOISE: &[&str] = &[
        "SALDO", "TOTAL", "RESUMEN", "GAT ", "PERIODO", "PERÍODO", "PAGINA",
        "PÁGINA", "ESTADO DE CUENTA", "CLABE", "R.F.C", "RFC", "SUBTOTAL",
        "COMISION", "COMISIÓN", "INTERESES GANADOS", "PAGE ", " OF ",
    ];
    NOISE.iter().any(|n| line.contains(n))
}

/// Parse raw PDF text (already extracted by lopdf) into transactions.
/// Returns an empty vec rather than an error when nothing matches — the
/// caller decides how to message "no transactions found".
pub fn parse_text(text: &str) -> Result<Vec<ParsedTransaction>> {
    let upper = text.to_uppercase();

    // Best-effort statement year, for date forms that omit it (e.g. the
    // Spanish "day / MONTH" pair). First 19xx/20xx in the header wins;
    // fall back to the current year.
    let year_re = Regex::new(r"(19|20)\d{2}").unwrap();
    let year_hint = year_re
        .find(&upper[..upper.len().min(2000)])
        .and_then(|m| m.as_str().parse::<i32>().ok())
        .unwrap_or_else(|| chrono::Utc::now().year());

    // Amount REQUIRES decimals here (.dd) — in generic mode that guard
    // keeps page numbers, years and reference codes from being read as
    // money. A leading minus is preserved as the sign.
    let amount_re = Regex::new(r"^\$?\s*(-?\d{1,3}(?:,\d{3})*\.\d{2})$").unwrap();
    let iso_re = Regex::new(r"^(\d{4})-(\d{2})-(\d{2})$").unwrap();
    let dmy_re = Regex::new(r"^(\d{1,2})[/-](\d{1,2})[/-](\d{2,4})$").unwrap();
    let day_re = Regex::new(r"^(\d{1,2})$").unwrap();

    let lines: Vec<String> = upper
        .lines()
        .map(|l| l.trim().to_string())
        .filter(|l| !l.is_empty() && !l.eq_ignore_ascii_case("DE"))
        .collect();

    let mut txs: Vec<ParsedTransaction> = Vec::new();
    let mut current_date: Option<NaiveDate> = None;
    let mut desc: Vec<String> = Vec::new();

    let mut emit = |date: Option<NaiveDate>, desc: &mut Vec<String>, amt: Decimal| {
        if let Some(d) = date {
            let description = desc.join(" ").trim().to_string();
            let has_alpha = description.chars().any(|c| c.is_alphabetic());
            if description.len() >= 3 && has_alpha && !is_noise(&description) {
                txs.push(ParsedTransaction {
                    date: d,
                    description,
                    amount: amt,
                    currency: "MXN".to_string(),
                    category: None,
                    original_description: None,
                });
            }
        }
        desc.clear();
    };

    let mut i = 0;
    while i < lines.len() {
        let line = &lines[i];

        // ISO date: 2025-01-31
        if let Some(c) = iso_re.captures(line) {
            current_date = NaiveDate::from_ymd_opt(
                c[1].parse().unwrap_or(year_hint),
                c[2].parse().unwrap_or(1),
                c[3].parse().unwrap_or(1),
            );
            desc.clear();
            i += 1;
            continue;
        }
        // d/m/y or d-m-y (2- or 4-digit year)
        if let Some(c) = dmy_re.captures(line) {
            let d: u32 = c[1].parse().unwrap_or(1);
            let m: u32 = c[2].parse().unwrap_or(1);
            let mut y: i32 = c[3].parse().unwrap_or(year_hint);
            if y < 100 {
                y += 2000;
            }
            current_date = NaiveDate::from_ymd_opt(y, m, d);
            desc.clear();
            i += 1;
            continue;
        }
        // Spanish "day" line followed by a "MONTH" line (lopdf splits
        // each field onto its own line).
        if day_re.is_match(line) && i + 1 < lines.len() {
            if let Some(m) = month_name(&lines[i + 1]) {
                let d: u32 = line.parse().unwrap_or(1);
                current_date = NaiveDate::from_ymd_opt(year_hint, m, d);
                desc.clear();
                i += 2;
                continue;
            }
        }
        // Amount → close out the current record.
        let cleaned = line.replace('$', "");
        let cleaned = cleaned.trim();
        if let Some(c) = amount_re.captures(&format!("${cleaned}")) {
            if let Ok(amt) = Decimal::from_str(&c[1].replace(',', "")) {
                emit(current_date, &mut desc, amt);
            }
            i += 1;
            continue;
        }
        // Otherwise it's (probably) a description fragment. Keep a short
        // rolling window so an amount picks up the nearest context.
        if !is_noise(line) && line.chars().any(|c| c.is_alphabetic()) {
            desc.push(line.clone());
            if desc.len() > 6 {
                desc.remove(0);
            }
        }
        i += 1;
    }

    if !txs.is_empty() {
        info!("Generic parser extracted {} transactions", txs.len());
    }
    Ok(txs)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn iso_date_single_line_rows() {
        // A simple "date desc amount" layout, one field per line.
        let text = "\
ESTADO DE CUENTA 2025
2025-01-05
NETFLIX SUSCRIPCION
199.00
2025-01-10
TRANSFERENCIA A JUAN
-1,500.00
SALDO FINAL
8,300.50
";
        let txs = parse_text(text).unwrap();
        assert_eq!(txs.len(), 2, "two real rows; SALDO line is noise");
        assert_eq!(txs[0].date, NaiveDate::from_ymd_opt(2025, 1, 5).unwrap());
        assert_eq!(txs[0].description, "NETFLIX SUSCRIPCION");
        assert_eq!(txs[0].amount, Decimal::from_str("199.00").unwrap());
        assert_eq!(txs[1].amount, Decimal::from_str("-1500.00").unwrap());
    }

    #[test]
    fn spanish_day_month_pairs() {
        let text = "\
PERIODO DEL 1 AL 31 DE ENERO DEL 2024
05
ENE
PAGO TARJETA
1,234.56
12
ENE
DEPOSITO EFECTIVO
500.00
";
        let txs = parse_text(text).unwrap();
        assert_eq!(txs.len(), 2);
        assert_eq!(txs[0].date, NaiveDate::from_ymd_opt(2024, 1, 5).unwrap());
        assert_eq!(txs[0].description, "PAGO TARJETA");
        assert_eq!(txs[1].date, NaiveDate::from_ymd_opt(2024, 1, 12).unwrap());
    }

    #[test]
    fn dmy_slash_dates() {
        let text = "\
05/02/2025
COMPRA OXXO
89.50
";
        let txs = parse_text(text).unwrap();
        assert_eq!(txs.len(), 1);
        assert_eq!(txs[0].date, NaiveDate::from_ymd_opt(2025, 2, 5).unwrap());
    }

    #[test]
    fn rejects_amounts_without_decimals_and_noise() {
        // Page numbers, years and decimal-less integers must NOT become
        // transactions in generic mode.
        let text = "\
PAGINA 1 OF 11
2025
05/02/2025
4000
99
";
        let txs = parse_text(text).unwrap();
        assert!(txs.is_empty(), "no decimal amounts → no rows, got {:?}", txs);
    }

    #[test]
    fn empty_text_yields_no_rows() {
        assert!(parse_text("").unwrap().is_empty());
        assert!(parse_text("   \n  \n").unwrap().is_empty());
    }
}
