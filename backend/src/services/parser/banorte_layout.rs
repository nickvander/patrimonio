//! Banorte (Banco Mercantil del Norte) checking-statement parser for poppler
//! `pdftotext -layout` output.
//!
//! The "DETALLE DE MOVIMIENTOS (PESOS)" table is laid out in spatial columns:
//!
//! ```text
//!    FECHA      DESCRIPCIÓN / ESTABLECIMIENTO        MONTO DEL DEPOSITO    MONTO DEL RETIRO    SALDO
//! 31-ENE-21 SALDO ANTERIOR                                                                   3,643,498.89
//! 01-FEB-21 CONCENTRACION DE PAGOS PAGO DETALLE 001300        756.72                          3,644,255.61
//! 02-FEB-21 CARGO POR COMISION CEP EMPRESA NO.001300                          345.00          4,081,043.56
//! ```
//!
//! Facts that shape the parser (verified against a real statement):
//!  * Rows start with a `DD-MMM-AA` date — a **two-digit year** IS in the row.
//!  * MONTO DEL DEPOSITO (credit) vs MONTO DEL RETIRO (debit) is positional;
//!    SALDO is the running balance on every row.
//!  * The opening row is `SALDO ANTERIOR` (balance only, no movement) and is
//!    skipped naturally because it has neither a deposit nor a withdrawal.
//!  * Indented lines with no date are description continuations (RFC,
//!    references). The abbreviation legend and legal footer are furniture.

use super::column_table::{bucket, detect_cols, normalize_desc, ColCols};
use super::layout_util::{month_abbr, strip_amounts};
use crate::models::import::ParsedTransaction;
use anyhow::Result;
use chrono::NaiveDate;
use regex::Regex;
use rust_decimal::Decimal;
use tracing::info;

const DEP: &[&str] = &["DEPOSITO", "DEPÓSITO"];
const WD: &[&str] = &["RETIRO"];

fn is_furniture(upper: &str) -> bool {
    const KEYS: &[&str] = &[
        "RESUMEN INTEGRAL",
        "RESUMEN DEL PERIODO",
        "RESUMEN DE COMISIONES",
        "REFERENCIA DE ABREVIATURAS",
        "LINEA DIRECTA",
        "LÍNEA DIRECTA",
        "ADVERTENCIA",
        "BANCO MERCANTIL DEL NORTE",
        "BMN930209927",
        "ESTADO DE CUENTA",
        "ENLACE GLOBAL",
        "SALDO INICIAL",
        "SALDO ACTUAL",
        "SALDO AL CORTE",
        "SALDO FINAL",
        "SIN MOVIMIENTOS",
        "LA FECHA DE CORTE",
        "400,000 UDI",
        "PAGINA",
        "PÁGINA",
    ];
    if KEYS.iter().any(|k| upper.contains(k)) {
        return true;
    }
    Regex::new(r"\b[A-Z]{2,6}=").unwrap().is_match(upper)
}

struct Record {
    date: NaiveDate,
    desc: Vec<String>,
    deposit: Option<Decimal>,
    retiro: Option<Decimal>,
    saldo: Option<Decimal>,
}

pub fn parse_text(text: &str) -> Result<Vec<ParsedTransaction>> {
    let upper_all = text.to_uppercase();
    let start = upper_all.find("DETALLE DE MOVIMIENTOS").unwrap_or(0);
    let section = &text[start..];

    // DD-MMM-AA lead-in (two-digit year).
    let row_re = Regex::new(r"^\s*(\d{2})-([A-Za-z]{3})-(\d{2})\b").unwrap();

    let mut txs: Vec<ParsedTransaction> = Vec::new();
    let mut cols: Option<ColCols> = None;
    let mut cur: Option<Record> = None;

    let flush = |rec: Option<Record>, txs: &mut Vec<ParsedTransaction>| {
        let Some(rec) = rec else { return };
        let amount = match (rec.deposit, rec.retiro) {
            (Some(d), _) => d,
            (_, Some(r)) => -r,
            (None, None) => return, // SALDO ANTERIOR / balance-only rows
        };
        let description = normalize_desc(&rec.desc);
        if description.is_empty() {
            return;
        }
        txs.push(ParsedTransaction {
            date: rec.date,
            description,
            amount,
            currency: "MXN".to_string(),
            category: None,
            original_description: None,
            balance_after: rec.saldo,
            account_label: None,
            from_ocr: false,
        });
    };

    for raw in section.lines() {
        let line = raw.trim_end();
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let upper = trimmed.to_uppercase();

        // Header row: learn column geometry.
        if (upper.contains("DEPOSITO") || upper.contains("DEPÓSITO")) && upper.contains("RETIRO") {
            if let Some(c) = detect_cols(line, DEP, WD) {
                cols = Some(c);
            }
            continue;
        }

        if let Some(c) = row_re.captures(line) {
            flush(cur.take(), &mut txs);
            let day: u32 = c[1].parse().unwrap_or(1);
            let month = month_abbr(&c[2].to_uppercase()).unwrap_or(1);
            let yy: i32 = c[3].parse().unwrap_or(0);
            let year = 2000 + yy;
            let Some(date) = NaiveDate::from_ymd_opt(year, month, day) else {
                continue;
            };
            let tail = &line[c.get(0).unwrap().end()..];
            let mut rec = Record {
                date,
                desc: Vec::new(),
                deposit: None,
                retiro: None,
                saldo: None,
            };
            if let Some(c) = cols {
                let (d, w, s) = bucket(line, c);
                rec.deposit = d;
                rec.retiro = w;
                rec.saldo = s;
            }
            let desc = strip_amounts(tail);
            if !desc.is_empty() {
                rec.desc.push(desc);
            }
            cur = Some(rec);
            continue;
        }

        if is_furniture(&upper) {
            continue;
        }
        if let Some(rec) = cur.as_mut() {
            let desc = strip_amounts(trimmed);
            if desc.chars().any(|ch| ch.is_alphabetic()) {
                rec.desc.push(desc);
            }
        }
    }
    flush(cur.take(), &mut txs);

    info!("Banorte layout parser extracted {} transactions", txs.len());
    Ok(txs)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    // Reconstructed from a real Banorte `pdftotext -layout` extraction:
    // confirmed anchor, header words + order, DD-MMM-AA dates with two-digit
    // year, SALDO ANTERIOR opener, multi-line continuation. Fake amounts.
    const SAMPLE: &str = "\
                                          DETALLE DE MOVIMIENTOS (PESOS)
   FECHA      DESCRIPCIÓN / ESTABLECIMIENTO                       MONTO DEL DEPOSITO      MONTO DEL RETIRO            SALDO
31-ENE-21 SALDO ANTERIOR                                                                                          3,643,498.89
01-FEB-21 CONCENTRACION DE PAGOS PAGO DETALLE 001300                      756.72                                  3,644,255.61
          WEB DEL RFC LODA850206L15 RAS 72791033739950001300
02-FEB-21 CARGO POR COMISION CEP EMPRESA NO.001300                                            345.00              3,643,910.61
02-FEB-21 CARGO POR IVA CEP EMPRESA NO.001300                                                  55.20              3,643,855.41
05-FEB-21 SPEI RECIBIDO BBVA RENTA DEPTO FEBRERO                        9,500.00                                  3,653,355.41
Referencia de Abreviaturas
ABO= ABONO   CGO= CARGO   COM= COMISION
Banco Mercantil del Norte S.A. R.F.C. BMN930209927
";

    #[test]
    fn parses_banorte_columns_and_signs() {
        let txs = parse_text(SAMPLE).unwrap();
        assert_eq!(txs.len(), 4, "got {:#?}", txs);

        // Deposit row: year 2021 from the two-digit token, balance captured.
        assert_eq!(txs[0].date, NaiveDate::from_ymd_opt(2021, 2, 1).unwrap());
        assert_eq!(txs[0].amount, Decimal::from_str("756.72").unwrap());
        assert!(txs[0].description.contains("CONCENTRACION DE PAGOS"));
        assert!(txs[0].description.contains("LODA850206L15"), "continuation appended");
        assert_eq!(txs[0].balance_after, Some(Decimal::from_str("3644255.61").unwrap()));

        // Commission + IVA are withdrawals (negative).
        assert_eq!(txs[1].amount, Decimal::from_str("-345.00").unwrap());
        assert_eq!(txs[2].amount, Decimal::from_str("-55.20").unwrap());

        // SPEI received is a deposit.
        assert_eq!(txs[3].amount, Decimal::from_str("9500.00").unwrap());
    }

    #[test]
    fn empty_text_no_transactions() {
        assert!(parse_text("").unwrap().is_empty());
    }
}
