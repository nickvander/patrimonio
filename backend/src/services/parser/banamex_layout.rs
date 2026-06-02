//! Banamex statement parser for poppler `pdftotext -layout` output.
//!
//! The in-process lopdf extractor cannot read Banamex's official AFP→PDF
//! statements — it reports "0 pages" and returns nothing. `pdftotext`
//! extracts them cleanly, but lays the "Detalle de Operaciones" table out
//! in spatial COLUMNS rather than one-field-per-line:
//!
//! ```text
//! FECHA   CONCEPTO                              RETIROS    DEPÓSITOS   SALDO
//!         SALDO ANTERIOR                                              4,000.00
//! 29 DIC  PAGO RECIBIDO DE EDGAR
//!         ...
//!         CAJA 0071 AUT 00024631                          8,800.00   12,800.00
//! 29 DIC  PAGO INTERBANCARIO A NU MEXICO
//!         ...                                  8,800.00               4,000.00
//! ```
//!
//! A record starts with a `DD MMM` date; the concepto wraps over several
//! lines; the transaction amount and the running SALDO sit at the end of
//! the record. SIGN is taken from the SALDO delta (the bank's own running
//! balance — the most reliable signal), matching `banamex_pdf`'s
//! convention: balance up = inflow (+), balance down = outflow (−).

use crate::models::import::ParsedTransaction;
use anyhow::Result;
use chrono::NaiveDate;
use regex::Regex;
use rust_decimal::Decimal;
use std::str::FromStr;
use tracing::info;

fn month_abbr(s: &str) -> Option<u32> {
    match s {
        "ENE" => Some(1),
        "FEB" => Some(2),
        "MAR" => Some(3),
        "ABR" => Some(4),
        "MAY" => Some(5),
        "JUN" => Some(6),
        "JUL" => Some(7),
        "AGO" => Some(8),
        "SEP" => Some(9),
        "OCT" => Some(10),
        "NOV" => Some(11),
        "DIC" => Some(12),
        _ => None,
    }
}

fn month_full(s: &str) -> Option<u32> {
    match s {
        "ENERO" => Some(1),
        "FEBRERO" => Some(2),
        "MARZO" => Some(3),
        "ABRIL" => Some(4),
        "MAYO" => Some(5),
        "JUNIO" => Some(6),
        "JULIO" => Some(7),
        "AGOSTO" => Some(8),
        "SEPTIEMBRE" => Some(9),
        "OCTUBRE" => Some(10),
        "NOVIEMBRE" => Some(11),
        "DICIEMBRE" => Some(12),
        _ => None,
    }
}

/// A line that's transaction metadata, not part of the human description.
fn is_meta_line(upper: &str) -> bool {
    upper.starts_with("CAJA")
        || upper.starts_with("HORA")
        || upper.starts_with("SUC")
        || upper.starts_with("AUT")
        || upper.starts_with("REF.")
        || upper.starts_with("RASTREO")
        || upper.starts_with("CLAVE")
        || upper.starts_with("CTA.")
        || upper.starts_with("PÁGINA")
        || upper.starts_with("PAGINA")
        || upper.starts_with("AVENIDA")
        || upper.starts_with("PLAZA")
        || upper.starts_with("SUC.")
}

/// Whole-record skip: summary lines + net-zero informational notices.
fn is_skippable(upper: &str) -> bool {
    const KEYS: &[&str] = &[
        "SALDO ANTERIOR",
        "SALDO AL CORTE",
        "SALDO MINIMO",
        "SALDO PROMEDIO",
        "TOTAL DE",
        "RESUMEN",
        // "Exención de cobro de comisión" — the commission was waived,
        // so it's a $0 net event, not a transaction.
        "EXENCION COBRO COMISION",
        "EXENCIÓN COBRO COMISIÓN",
    ];
    KEYS.iter().any(|k| upper.contains(k))
}

/// Resolve the per-record year from the statement's "Período" line, which
/// may straddle a year boundary (… del 25 de diciembre del 2025 al 24 de
/// enero del 2026). Returns a closure month → year.
fn year_resolver(upper: &str) -> Box<dyn Fn(u32) -> i32> {
    let re = Regex::new(
        r"PER[IÍ]ODO DEL \d{1,2} DE (\w+) DEL (20\d{2}) AL \d{1,2} DE (\w+) DEL (20\d{2})",
    )
    .unwrap();
    let fallback = Regex::new(r"(20\d{2})")
        .unwrap()
        .find(&upper[..upper.len().min(3000)])
        .and_then(|m| m.as_str().parse::<i32>().ok())
        .unwrap_or(2025);

    if let Some(c) = re.captures(upper) {
        let sm = month_full(&c[1]).unwrap_or(1);
        let sy: i32 = c[2].parse().unwrap_or(fallback);
        let ey: i32 = c[4].parse().unwrap_or(sy);
        Box::new(move |m: u32| {
            if sy == ey {
                sy
            } else if m >= sm {
                sy
            } else {
                ey
            }
        })
    } else {
        Box::new(move |_m: u32| fallback)
    }
}

/// Parse the `pdftotext -layout` text of a Banamex statement.
pub fn parse_text(text: &str) -> Result<Vec<ParsedTransaction>> {
    let upper = text.to_uppercase();
    let resolve_year = year_resolver(&upper);

    // Anchor to the detail table when present, so summary figures don't
    // masquerade as transactions. Falls back to the whole document.
    let start = upper
        .find("DETALLE DE OPERACIONES")
        .unwrap_or(0);
    let section = &text[start..];

    let date_re =
        Regex::new(r"^\s*(\d{1,2})\s+(ENE|FEB|MAR|ABR|MAY|JUN|JUL|AGO|SEP|OCT|NOV|DIC)\b").unwrap();
    let amt_re = Regex::new(r"\d{1,3}(?:,\d{3})*\.\d{2}").unwrap();

    let mut txs: Vec<ParsedTransaction> = Vec::new();
    let mut prev_saldo: Option<Decimal> = None;

    // Current record being assembled.
    let mut cur_day = 0u32;
    let mut cur_month = 0u32;
    let mut cur_desc: Vec<String> = Vec::new();
    let mut cur_amounts: Vec<Decimal> = Vec::new();
    let mut in_record = false;

    // Close out the current record into a transaction (or skip it).
    let flush = |day: u32,
                     month: u32,
                     desc: &mut Vec<String>,
                     amounts: &mut Vec<Decimal>,
                     prev_saldo: &mut Option<Decimal>,
                     txs: &mut Vec<ParsedTransaction>| {
        let description = desc.join(" ").trim().to_string();
        let upper_desc = description.to_uppercase();
        desc.clear();
        if description.is_empty() || amounts.is_empty() || is_skippable(&upper_desc) {
            // Still advance the running balance if the row carried a saldo,
            // so the NEXT record's sign is computed against the right base.
            if let Some(s) = amounts.last() {
                *prev_saldo = Some(*s);
            }
            amounts.clear();
            return;
        }
        // Last number on the record is the running SALDO; the one before it
        // is the transaction amount.
        let saldo = *amounts.last().unwrap();
        let magnitude = if amounts.len() >= 2 {
            amounts[amounts.len() - 2]
        } else {
            // Only a saldo on the row → infer the amount from the delta.
            match *prev_saldo {
                Some(p) => (saldo - p).abs(),
                None => {
                    *prev_saldo = Some(saldo);
                    amounts.clear();
                    return;
                }
            }
        };

        // Sign from the SALDO delta (most reliable). If the balance didn't
        // move, it's a net-zero informational row — skip it.
        let signed = match *prev_saldo {
            Some(p) if saldo > p => magnitude,
            Some(p) if saldo < p => -magnitude,
            Some(_) => {
                *prev_saldo = Some(saldo);
                amounts.clear();
                return;
            }
            None => magnitude, // first record, no prior balance — take as-is
        };
        *prev_saldo = Some(saldo);
        amounts.clear();

        if let Some(date) = NaiveDate::from_ymd_opt(resolve_year(month), month, day) {
            txs.push(ParsedTransaction {
                date,
                description,
                amount: signed,
                currency: "MXN".to_string(),
                category: None,
                original_description: None,
            });
        }
    };

    for raw in section.lines() {
        let line = raw.trim_end();
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let upper_line = trimmed.to_uppercase();
        let amounts: Vec<Decimal> = amt_re
            .find_iter(trimmed)
            .filter_map(|m| Decimal::from_str(&m.as_str().replace(',', "")).ok())
            .collect();

        if let Some(c) = date_re.captures(line) {
            // New record — flush the previous one.
            if in_record {
                flush(
                    cur_day,
                    cur_month,
                    &mut cur_desc,
                    &mut cur_amounts,
                    &mut prev_saldo,
                    &mut txs,
                );
            }
            cur_day = c[1].parse().unwrap_or(1);
            cur_month = month_abbr(&c[2]).unwrap_or(1);
            cur_amounts = amounts.clone();
            cur_desc = Vec::new();
            // Any description text after the date on the same line.
            let after = line[c.get(0).unwrap().end()..].trim();
            let after_no_amt = amt_re.replace_all(after, "").trim().to_string();
            if !after_no_amt.is_empty() && !is_meta_line(&after_no_amt.to_uppercase()) {
                cur_desc.push(after_no_amt);
            }
            in_record = true;
            continue;
        }

        if !in_record {
            // Establish the opening balance from "SALDO ANTERIOR".
            if upper_line.contains("SALDO ANTERIOR") {
                if let Some(s) = amounts.last() {
                    prev_saldo = Some(*s);
                }
            }
            continue;
        }

        // Within a record: collect amounts, and description text that isn't
        // metadata.
        cur_amounts.extend(amounts);
        let text_only = amt_re.replace_all(trimmed, "").trim().to_string();
        if !text_only.is_empty() && !is_meta_line(&text_only.to_uppercase()) {
            cur_desc.push(text_only);
        }
    }

    if in_record {
        flush(
            cur_day,
            cur_month,
            &mut cur_desc,
            &mut cur_amounts,
            &mut prev_saldo,
            &mut txs,
        );
    }

    info!("Banamex layout parser extracted {} transactions", txs.len());
    Ok(txs)
}

#[cfg(test)]
mod tests {
    use super::*;

    // A trimmed, representative slice of real `pdftotext -layout` output.
    const SAMPLE: &str = "\
Período del 25 de diciembre del 2025 al 24 de enero del 2026
Detalle de OperacionesEn pesos Moneda Nacional
FECHA        CONCEPTO                                    RETIROS     DEPÓSITOS    SALDO
             SALDO ANTERIOR                                                      4,000.00
29 DIC       PAGO RECIBIDO DE EDGAR
             OMAR,MEDINA/COLORBIO SU
             CAJA 0071 AUT 00024631
             HORA 00:08 SUC 0870                                      8,800.00   12,800.00
29 DIC       PAGO INTERBANCARIO A NU MEXICO
             AL BENEF. NICK
             HORA 10:40 SUC 0519                          8,800.00                4,000.00
12 ENE       PAGO RECIBIDO DE NU MEXICO
             HORA 09:00 SUC 0519                                     27,000.00   31,000.00
";

    #[test]
    fn parses_deposits_and_withdrawals_with_signs() {
        let txs = parse_text(SAMPLE).unwrap();
        assert_eq!(txs.len(), 3, "got {:?}", txs);

        // Deposit on 29 Dec 2025 (year resolved from the período).
        assert_eq!(txs[0].date, NaiveDate::from_ymd_opt(2025, 12, 29).unwrap());
        assert!(txs[0].description.contains("PAGO RECIBIDO DE EDGAR"));
        assert!(!txs[0].description.contains("CAJA"), "meta lines stripped");
        assert_eq!(txs[0].amount, Decimal::from_str("8800.00").unwrap());

        // Withdrawal (balance went 12,800 → 4,000) → negative.
        assert_eq!(txs[1].amount, Decimal::from_str("-8800.00").unwrap());

        // Jan row rolls into 2026.
        assert_eq!(txs[2].date, NaiveDate::from_ymd_opt(2026, 1, 12).unwrap());
        assert_eq!(txs[2].amount, Decimal::from_str("27000.00").unwrap());
    }

    #[test]
    fn empty_text_no_transactions() {
        assert!(parse_text("").unwrap().is_empty());
    }
}
