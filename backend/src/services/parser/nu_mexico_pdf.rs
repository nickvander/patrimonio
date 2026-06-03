//! Nu México ("Cuenta Nu" débito/savings) statement parser for poppler
//! `pdftotext -layout` output.
//!
//! Nu's Cuenta statement is born-digital (selectable text, no OCR needed). A
//! "Detalle de movimientos" table lists, per row, a `DD MMM` date, an
//! app-style Spanish description ("Recibiste de…", "Compra en…", "Enviaste
//! a…"), a single SIGNED `Monto`, and a running `$Saldo`:
//!
//! ```text
//! Resumen del periodo
//!     Saldo inicial                              $24,406.48
//! Fecha    Descripción                  Monto         Saldo
//! 01 OCT   Recibiste de NOMINA      +12,000.00    $36,406.48
//! 03 OCT   Compra en OXXO              -150.00    $36,256.48
//! ```
//!
//! Sign comes from the running-balance delta when both the row's `Saldo` and
//! the previous balance are known (ground truth, like the Banamex parser);
//! otherwise from the explicit `+`/`-` on `Monto`, then from a keyword
//! (Recibiste/Compra/…). The year is taken from the `Periodo` header — NOT
//! the current date (the previous implementation's bug imported every
//! historical statement under this year).

use crate::models::import::ParsedTransaction;
use anyhow::{anyhow, Result};
use chrono::NaiveDate;
use lopdf::Document;
use regex::Regex;
use rust_decimal::Decimal;
use std::str::FromStr;
use tracing::info;

/// lopdf entry point (kept for direct callers / fallback). The router
/// prefers `parse_text(&best)` over the richer `pdftotext -layout` text.
pub fn parse(data: &[u8]) -> Result<Vec<ParsedTransaction>> {
    let doc = Document::load_mem(data).map_err(|e| anyhow!("Failed to load PDF: {}", e))?;
    let mut full_text = String::new();
    for (page_num, _) in doc.get_pages().iter() {
        if let Ok(text) = doc.extract_text(&[*page_num]) {
            full_text.push_str(&text);
            full_text.push('\n');
        }
    }
    info!("Extracted {} characters from Nu PDF", full_text.len());
    parse_text(&full_text)
}

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

/// Per-row year from the `Periodo del DD de <mes> de AAAA al DD de <mes> de
/// AAAA` header, handling a Dec→Jan year boundary. Falls back to the first
/// 4-digit year in the document, then to a fixed 2024 if none.
fn year_resolver(upper: &str) -> Box<dyn Fn(u32) -> i32> {
    let re = Regex::new(
        r"PERIODO DEL \d{1,2} DE (\w+) DE (\d{4}) AL \d{1,2} DE (\w+) DE (\d{4})",
    )
    .unwrap();
    let fallback = Regex::new(r"(20\d{2})")
        .unwrap()
        .find(upper)
        .and_then(|m| m.as_str().parse::<i32>().ok())
        .unwrap_or(2024);
    if let Some(c) = re.captures(upper) {
        let sm = month_full(&c[1]).unwrap_or(1);
        let sy: i32 = c[2].parse().unwrap_or(fallback);
        let ey: i32 = c[4].parse().unwrap_or(sy);
        Box::new(move |m: u32| if sy == ey || m >= sm { sy } else { ey })
    } else {
        Box::new(move |_| fallback)
    }
}

/// Sign from an app-style description: `Some(true)` = credit (money in),
/// `Some(false)` = debit (money out), `None` = no keyword signal.
fn keyword_credit(desc_upper: &str) -> Option<bool> {
    const CREDIT: &[&str] = &[
        "RECIBISTE", "RECIBIDO", "DEPOSITO", "DEPÓSITO", "REEMBOLSO",
        "INTERESES", "ABONO", "DEVOLUCION", "DEVOLUCIÓN",
    ];
    const DEBIT: &[&str] = &[
        "ENVIASTE", "COMPRA", "PAGO", "RETIRO", "TRANSFERENCIA", "COMISION",
        "COMISIÓN", "CARGO",
    ];
    if CREDIT.iter().any(|k| desc_upper.contains(k)) {
        Some(true)
    } else if DEBIT.iter().any(|k| desc_upper.contains(k)) {
        Some(false)
    } else {
        None
    }
}

/// A money token with its explicit sign (if the source wrote one).
struct Money {
    neg: Option<bool>,
    value: Decimal,
}

pub fn parse_text(text: &str) -> Result<Vec<ParsedTransaction>> {
    let upper_all = text.to_uppercase();
    let resolve_year = year_resolver(&upper_all);

    // `DD MMM` row lead-in.
    let date_re = Regex::new(r"^\s*(\d{1,2})\s+([A-Za-z]{3})\b").unwrap();
    // A money token: optional +/- , optional $, grouped thousands, 2 decimals.
    let money_re = Regex::new(r"([+\-]?)\s*\$?\s*(\d{1,3}(?:,\d{3})*\.\d{2})").unwrap();

    // Seed the running balance from "Saldo inicial" so the FIRST row's sign
    // is also computed from the (most reliable) balance delta.
    let mut prev_balance: Option<Decimal> = Regex::new(r"SALDO INICIAL\s*\$?\s*([\d,]+\.\d{2})")
        .unwrap()
        .captures(&upper_all)
        .and_then(|c| Decimal::from_str(&c[1].replace(',', "")).ok());

    let mut txs: Vec<ParsedTransaction> = Vec::new();

    for raw in text.lines() {
        let line = raw.trim_end();
        let Some(date_caps) = date_re.captures(line) else {
            continue;
        };
        let Some(month) = month_abbr(&date_caps[2].to_uppercase()) else {
            continue;
        };
        let day: u32 = date_caps[1].parse().unwrap_or(1);
        let rest = &line[date_caps.get(0).unwrap().end()..];

        let monies: Vec<Money> = money_re
            .captures_iter(rest)
            .filter_map(|c| {
                Decimal::from_str(&c[2].replace(',', "")).ok().map(|value| Money {
                    neg: match &c[1] {
                        "-" => Some(true),
                        "+" => Some(false),
                        _ => None,
                    },
                    value,
                })
            })
            .collect();
        if monies.is_empty() {
            continue;
        }

        // ≥2 tokens → [..monto, saldo]; 1 token → just the monto.
        let (balance, monto) = if monies.len() >= 2 {
            (Some(monies[monies.len() - 1].value), &monies[monies.len() - 2])
        } else {
            (None, &monies[0])
        };

        let description = money_re.replace_all(rest, "").trim().to_string();
        if description.is_empty() {
            // No description after stripping amounts — a summary/figure line,
            // not a transaction.
            continue;
        }
        let desc_upper = description.to_uppercase();

        // Sign: balance delta (truth) → explicit token sign → keyword →
        // default debit (spending is the common case; the preview lets the
        // user flip the rare miss).
        let amount = match (balance, prev_balance) {
            (Some(bal), Some(prev)) => bal - prev,
            _ => {
                let neg = match monto.neg {
                    Some(n) => n,
                    None => !keyword_credit(&desc_upper).unwrap_or(false),
                };
                if neg {
                    -monto.value
                } else {
                    monto.value
                }
            }
        };
        if let Some(bal) = balance {
            prev_balance = Some(bal);
        }

        if let Some(date) = NaiveDate::from_ymd_opt(resolve_year(month), month, day) {
            txs.push(ParsedTransaction {
                date,
                description,
                amount,
                currency: "MXN".to_string(),
                category: None,
                original_description: None,
                balance_after: balance,
                account_label: None,
            });
        }
    }

    info!("Nu México PDF parser extracted {} transactions", txs.len());
    Ok(txs)
}

#[cfg(test)]
mod tests {
    use super::*;

    // Reconstructed from the confirmed Nu Cuenta structure: born-digital
    // text, "Saldo inicial" seed, DD MMM dates, app-style descriptions, a
    // single signed Monto + running $Saldo. Fake data.
    const SAMPLE: &str = "\
Nu México Financiera, S.A. de C.V., S.F.P.
Estado de Cuenta
Cuenta Nu: 00017961879
CLABE: 638180000179618790
Periodo del 01 de octubre de 2024 al 31 de octubre de 2024

Resumen del periodo
    Saldo inicial                                          $24,406.48
    Saldo final                                            $32,285.60

Detalle de movimientos
Fecha    Descripción                                         Monto         Saldo
01 OCT   Recibiste de NOMINA EMPRESA SA DE CV            +12,000.00    $36,406.48
03 OCT   Compra en OXXO TIENDA 4421                         -150.00    $36,256.48
05 OCT   Enviaste a JUAN PEREZ RAMIREZ                    -2,500.00    $33,756.48
14 OCT   Deposito SPEI recibido de BBVA MEXICO            +4,272.69    $38,029.17
30 OCT   Pago de tarjeta de credito Nu                    -5,743.57    $32,285.60
";

    #[test]
    fn parses_nu_signed_monto_and_running_balance() {
        let txs = parse_text(SAMPLE).unwrap();
        assert_eq!(txs.len(), 5, "got {:#?}", txs);

        // Year from the Periodo header (2024), NOT the current year.
        assert_eq!(txs[0].date, NaiveDate::from_ymd_opt(2024, 10, 1).unwrap());

        // Sign from the balance delta: 36,406.48 - 24,406.48 = +12,000.00.
        assert_eq!(txs[0].amount, Decimal::from_str("12000.00").unwrap());
        assert!(txs[0].description.contains("Recibiste de NOMINA"));
        assert_eq!(txs[0].balance_after, Some(Decimal::from_str("36406.48").unwrap()));

        // Purchase (balance went down) → negative.
        assert_eq!(txs[1].amount, Decimal::from_str("-150.00").unwrap());
        assert_eq!(txs[2].amount, Decimal::from_str("-2500.00").unwrap());
        // SPEI deposit → positive.
        assert_eq!(txs[3].amount, Decimal::from_str("4272.69").unwrap());
        // Card payment → negative; closing balance captured.
        assert_eq!(txs[4].amount, Decimal::from_str("-5743.57").unwrap());
        assert_eq!(txs[4].balance_after, Some(Decimal::from_str("32285.60").unwrap()));
    }

    #[test]
    fn keyword_sign_without_balance_column() {
        // No Saldo column and no Saldo inicial → sign from the keyword.
        let text = "\
Periodo del 01 de marzo de 2024 al 31 de marzo de 2024
15 MAR   Compra en AMAZON MX                                 899.00
16 MAR   Recibiste de PATRON SA                            3,000.00
";
        let txs = parse_text(text).unwrap();
        assert_eq!(txs.len(), 2, "got {:#?}", txs);
        assert_eq!(txs[0].amount, Decimal::from_str("-899.00").unwrap());
        assert_eq!(txs[1].amount, Decimal::from_str("3000.00").unwrap());
        assert!(txs[0].balance_after.is_none());
    }

    #[test]
    fn empty_text_no_transactions() {
        assert!(parse_text("").unwrap().is_empty());
    }
}
