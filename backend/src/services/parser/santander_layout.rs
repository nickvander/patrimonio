//! Santander México ("Estado de Cuenta Integral") parser for poppler
//! `pdftotext -layout` output.
//!
//! The "DETALLE DE MOVIMIENTOS" table is laid out in spatial columns:
//!
//! ```text
//! F E C H A      FOLIO     DESCRIPCION                 DEPOSITOS      RETIROS        SALDO
//! 30-ABR-2026             SALDO FINAL DEL PERIODO ANTERIOR                          8,540.10
//! 04-MAY-2026   0000000   ABONO NOMINA QUINCENA 1      12,500.00                   21,040.10
//! 05-MAY-2026   1184302   COMPRA OXXO TIENDA 4521                       248.50      20,791.60
//! ```
//!
//! Facts that shape the parser (cross-checked against real statements):
//!  * Rows start with a `DD-MMM-AAAA` date (year IS in the row, unlike
//!    BBVA/Banamex). An optional all-digit FOLIO follows.
//!  * DEPOSITOS (credit) vs RETIROS (debit) is **positional** — bucket each
//!    money token by its column against the header positions. SALDO is the
//!    running balance, present on every row.
//!  * The opening row is `SALDO FINAL DEL PERIODO ANTERIOR` (balance only,
//!    no movement) and the closing row `SALDO FINAL DEL PERIODO` — both have
//!    no DEPOSITOS/RETIROS so they're naturally skipped.
//!  * Lines with no date are description continuations; the abbreviation
//!    legend (`ABO= ABONO  CGO= CARGO …`) and `* GAT …` notes at the end are
//!    furniture and must not be appended as description.

use super::layout_util::{amounts_with_pos, col_of, month_abbr, strip_amounts};
use crate::models::import::ParsedTransaction;
use anyhow::Result;
use chrono::NaiveDate;
use regex::Regex;
use rust_decimal::Decimal;
use tracing::info;

/// Column boundaries from the table header, in char columns.
#[derive(Clone, Copy)]
struct Columns {
    dep_ret: usize,
    ret_saldo: usize,
}

fn detect_columns(line: &str) -> Option<Columns> {
    let upper = line.to_uppercase();
    let dep = col_of(&upper, "DEPOSITOS").or_else(|| col_of(&upper, "DEPÓSITOS"))?;
    let ret = col_of(&upper, "RETIROS")?;
    let saldo = col_of(&upper, "SALDO")?;
    if !(dep < ret && ret < saldo) {
        return None;
    }
    Some(Columns {
        dep_ret: (dep + ret) / 2,
        ret_saldo: (ret + saldo) / 2,
    })
}

/// Page furniture / legend that must never be parsed as a transaction or
/// appended as description.
fn is_furniture(upper: &str) -> bool {
    const KEYS: &[&str] = &[
        "ESTADO DE CUENTA",
        "BANCO SANTANDER",
        "BSM970519DU8",
        "PROLONGACION PASEO",
        "PROLONGACIÓN PASEO",
        "DELEGACION ALVARO",
        "AGRADECEREMOS",
        "GAT NOMINAL",
        "GAT REAL",
        "DETALLE DE MOVIMIENTOS",
        "CODIGO DE CLIENTE",
        "CÓDIGO DE CLIENTE",
        "CUENTA DE CHEQUES",
        "SALDO INICIAL",
        "SALDO PROMEDIO",
        "DIAS DEL PERIODO",
        "DÍAS DEL PERIODO",
        "TASA BRUTA",
        "CORTE AL",
    ];
    if KEYS.iter().any(|k| upper.contains(k)) {
        return true;
    }
    // The abbreviation legend rows: tokens like "ABO=", "CGO=", "SPEI=".
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
    // Anchor at the movements table; fall back to whole doc.
    let upper_all = text.to_uppercase();
    let start = upper_all.find("DETALLE DE MOVIMIENTOS").unwrap_or(0);
    let section = &text[start..];

    // Date + optional all-digit FOLIO lead-in.
    let row_re = Regex::new(r"^\s*(\d{2})-([A-Z]{3})-(\d{4})\s+(\d+\s+)?").unwrap();

    let mut txs: Vec<ParsedTransaction> = Vec::new();
    let mut cols: Option<Columns> = None;
    let mut cur: Option<Record> = None;

    let flush = |rec: Option<Record>, txs: &mut Vec<ParsedTransaction>| {
        let Some(rec) = rec else { return };
        let amount = match (rec.deposit, rec.retiro) {
            (Some(d), _) => d,
            (_, Some(r)) => -r,
            // Opening/closing "SALDO FINAL…" rows have no movement.
            (None, None) => return,
        };
        let description = rec
            .desc
            .join(" ")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        if description.is_empty() {
            return;
        }
        txs.push(ParsedTransaction {
            date: rec.date,
            description,
            amount,
            currency: "MXN".to_string(),
            category: None,
            category_detailed: None,
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

        // Learn / refresh the column geometry from each header.
        if (upper.contains("DEPOSITOS") || upper.contains("DEPÓSITOS")) && upper.contains("RETIROS")
        {
            if let Some(c) = detect_columns(line) {
                cols = Some(c);
            }
            continue;
        }

        if let Some(c) = row_re.captures(line) {
            flush(cur.take(), &mut txs);
            let day: u32 = c[1].parse().unwrap_or(1);
            let month = month_abbr(&c[2]).unwrap_or(1);
            let year: i32 = c[3].parse().unwrap_or(2025);
            let Some(date) = NaiveDate::from_ymd_opt(year, month, day) else {
                continue;
            };
            let tail_start = c.get(0).unwrap().end();
            let tail = &line[tail_start..];

            let mut rec = Record {
                date,
                desc: Vec::new(),
                deposit: None,
                retiro: None,
                saldo: None,
            };
            bucket_amounts(line, cols, &mut rec);
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

    info!(
        "Santander layout parser extracted {} transactions",
        txs.len()
    );
    Ok(txs)
}

fn bucket_amounts(line: &str, cols: Option<Columns>, rec: &mut Record) {
    let amts = amounts_with_pos(line);
    if amts.is_empty() {
        return;
    }
    match cols {
        Some(c) => {
            for a in amts {
                if a.center < c.dep_ret {
                    rec.deposit = Some(a.value);
                } else if a.center < c.ret_saldo {
                    rec.retiro = Some(a.value);
                } else {
                    rec.saldo = Some(a.value);
                }
            }
        }
        None => {
            // No header geometry: last token is SALDO; a preceding token is
            // the movement (assume retiro — the preview lets the user fix).
            rec.saldo = Some(amts[amts.len() - 1].value);
            if amts.len() >= 2 {
                rec.retiro = Some(amts[amts.len() - 2].value);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    // Reconstructed from real Santander México `pdftotext -layout`
    // structure: confirmed column headers (`F E C H A`, DEPOSITOS/RETIROS/
    // SALDO), DD-MMM-AAAA dates, SALDO FINAL DEL PERIODO ANTERIOR opener,
    // abbreviation legend, and bank footer. Fake account/amounts.
    const SAMPLE: &str = "\
                                                CUENTA NOMINA 60-00123456-7
                                                DETALLE DE MOVIMIENTOS CUENTA DE CHEQUES
F E C H A      FOLIO     DESCRIPCION                                          DEPOSITOS         RETIROS              SALDO
30-ABR-2026             SALDO FINAL DEL PERIODO ANTERIOR                                                          8,540.10
04-MAY-2026   0000000   ABONO NOMINA QUINCENA 1 MAY 2026                      12,500.00                          21,040.10
05-MAY-2026   1184302   COMPRA OXXO TIENDA 4521 GUADALAJARA                                     248.50           20,791.60
09-MAY-2026   2233190   SPEI ENVIADO BBVA JUAN PEREZ                                          3,200.00           17,591.60
12-MAY-2026   2345671   SPEI RECIBIDO BANORTE RENTA DEPTO MAYO                 5,000.00                          22,591.60
27-MAY-2026   3456112   COMISION MANEJO DE CUENTA                                              190.00           22,401.60
31-MAY-2026   3990771   SALDO FINAL DEL PERIODO                                                                 22,401.60
ABO=       ABONO (S)              CGO=  CARGO            SPEI=  SISTEMA DE PAGOS ELECTRONICOS
BANCO SANTANDER (MEXICO) S.A., INSTITUCION DE BANCA MULTIPLE, R.F.C. BSM970519DU8
";

    #[test]
    fn parses_santander_columns_and_signs() {
        let txs = parse_text(SAMPLE).unwrap();
        // Opening + closing SALDO FINAL rows are skipped → 5 real movements.
        assert_eq!(txs.len(), 5, "got {txs:#?}");

        // 1) Payroll deposit, year + balance from the row.
        assert_eq!(txs[0].date, NaiveDate::from_ymd_opt(2026, 5, 4).unwrap());
        assert_eq!(txs[0].amount, Decimal::from_str("12500.00").unwrap());
        assert!(txs[0].description.contains("ABONO NOMINA"));
        assert!(!txs[0].description.starts_with("0000000"), "folio stripped");
        assert_eq!(
            txs[0].balance_after,
            Some(Decimal::from_str("21040.10").unwrap())
        );

        // 2) Debit-card purchase (retiro → negative).
        assert_eq!(txs[1].amount, Decimal::from_str("-248.50").unwrap());
        assert!(txs[1].description.contains("OXXO"));

        // 3) SPEI sent (retiro).
        assert_eq!(txs[2].amount, Decimal::from_str("-3200.00").unwrap());

        // 4) SPEI received (deposit).
        assert_eq!(txs[3].amount, Decimal::from_str("5000.00").unwrap());

        // 5) Commission (retiro), last real row's balance is the closing.
        assert_eq!(txs[4].amount, Decimal::from_str("-190.00").unwrap());
        assert_eq!(
            txs[4].balance_after,
            Some(Decimal::from_str("22401.60").unwrap())
        );
    }

    #[test]
    fn empty_text_no_transactions() {
        assert!(parse_text("").unwrap().is_empty());
    }
}
