//! HSBC México checking-statement parser for poppler `pdftotext -layout`
//! output.
//!
//! The movements table is laid out in spatial columns, but — uniquely among
//! the Mexican banks we parse — HSBC prints the **withdrawal column BEFORE the
//! deposit column**:
//!
//! ```text
//! Día   Descripción          Referencia / Serial    Retiro / Cargo    Depósito / Abono    Saldo
//! ```
//!
//! The shared `column_table::bucket` assigns each money token to its nearest
//! header column, so the reversed order is handled automatically (no
//! "left = deposit" assumption).
//!
//! CAVEATS (this parser needs validation against a real HSBC PDF):
//!  * The exact date token format could not be confirmed — the only real
//!    sample we found had a broken font CMap (digits rendered as blanks). We
//!    accept the common Mexican formats `DD/MM/AAAA`, `DD/MM/AA`,
//!    `DD-MMM-AAAA`, `DD-MMM-AA`. If a real HSBC statement uses a day-only
//!    column, rows won't match and the importer falls back to the preview.
//!  * Some HSBC PDFs have a corrupted embedded font that yields gibberish from
//!    `pdftotext`; those route to OCR upstream, not here.

use super::column_table::{bucket, detect_cols, normalize_desc, ColCols};
use super::layout_util::{month_abbr, strip_amounts};
use crate::models::import::ParsedTransaction;
use anyhow::Result;
use chrono::NaiveDate;
use regex::Regex;
use rust_decimal::Decimal;
use tracing::info;

const DEP: &[&str] = &["DEPOSITO", "DEPÓSITO", "ABONO"];
const WD: &[&str] = &["RETIRO", "CARGO"];

fn is_furniture(upper: &str) -> bool {
    const KEYS: &[&str] = &[
        "RESUMEN DE TU CUENTA",
        "RESUMEN DE CUENTAS",
        "COMISIONES COBRADAS",
        "SALDO PROMEDIO",
        "TASA PROMEDIO",
        "CIFRAS EXPRESADAS",
        "ACLARACIONES",
        "CARGOS OBJETADOS",
        "HSBC MEXICO",
        "HSBC MÉXICO",
        "HMI950125KG8",
        "SALDO INICIAL",
        "SALDO FINAL",
        "ESTADO DE CUENTA",
        "ABREVIATURA",
        "PASEO DE LA REFORMA",
        "PAGINA",
        "PÁGINA",
        "CLAVE DE RASTREO",
        "PARTICIPANTE RECEPTOR",
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

/// Parse the month token, which may be a 3-letter Spanish abbreviation or a
/// 2-digit number.
fn parse_month(tok: &str) -> Option<u32> {
    if let Ok(n) = tok.parse::<u32>() {
        if (1..=12).contains(&n) {
            return Some(n);
        }
        return None;
    }
    month_abbr(&tok.to_uppercase())
}

pub fn parse_text(text: &str) -> Result<Vec<ParsedTransaction>> {
    let upper_all = text.to_uppercase();
    let start = upper_all
        .find("DETALLE MOVIMIENTOS")
        .or_else(|| upper_all.find("DETALLE DE MOVIMIENTOS"))
        .unwrap_or(0);
    let section = &text[start..];

    // DD/MM/AAAA | DD/MM/AA | DD-MMM-AAAA | DD-MMM-AA
    let row_re = Regex::new(r"^\s*(\d{2})[/-]([A-Za-z]{3}|\d{2})[/-](\d{4}|\d{2})\b").unwrap();

    let mut txs: Vec<ParsedTransaction> = Vec::new();
    let mut cols: Option<ColCols> = None;
    let mut cur: Option<Record> = None;

    let flush = |rec: Option<Record>, txs: &mut Vec<ParsedTransaction>| {
        let Some(rec) = rec else { return };
        let amount = match (rec.deposit, rec.retiro) {
            (Some(d), _) => d,
            (_, Some(r)) => -r,
            (None, None) => return,
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
            category_detailed: None,
            original_description: None,
            balance_after: rec.saldo,
            account_label: None,
            declared_closing_balance: None,
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

        // Header row: learn column geometry (handles reversed order).
        if (upper.contains("CARGO") || upper.contains("RETIRO"))
            && (upper.contains("ABONO") || upper.contains("DEPOSITO") || upper.contains("DEPÓSITO"))
            && upper.contains("SALDO")
        {
            if let Some(c) = detect_cols(line, DEP, WD) {
                cols = Some(c);
            }
            continue;
        }

        if let Some(c) = row_re.captures(line) {
            let day: u32 = c[1].parse().unwrap_or(1);
            let Some(month) = parse_month(&c[2]) else {
                continue;
            };
            let yr: i32 = c[3].parse().unwrap_or(0);
            let year = if yr < 100 { 2000 + yr } else { yr };
            let Some(date) = NaiveDate::from_ymd_opt(year, month, day) else {
                continue;
            };
            flush(cur.take(), &mut txs);
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
            let desc = strip_amounts(tail).replace('$', " ");
            let desc = desc.split_whitespace().collect::<Vec<_>>().join(" ");
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
            let desc = strip_amounts(trimmed).replace('$', " ");
            if desc.chars().any(|ch| ch.is_alphabetic()) {
                rec.desc.push(desc);
            }
        }
    }
    flush(cur.take(), &mut txs);

    info!("HSBC layout parser extracted {} transactions", txs.len());
    Ok(txs)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    // Reconstructed from the decoded HSBC layout: confirmed anchor, header
    // words and their REVERSED order (Retiro/Cargo before Depósito/Abono),
    // RESUMEN/legend furniture. Date format is the plausible DD/MM/AAAA (the
    // real sample's digits were unreadable) — flagged in the module docs.
    const SAMPLE: &str = "\
                                   DETALLE MOVIMIENTOS CUENTA INTEGRAL No 1234567890
Día        Descripción              Referencia / Serial      Retiro / Cargo      Depósito / Abono      Saldo
05/02/2026 ABONO TRANSFERENCIA SPEI 0099887766                                       9,500.00          25,500.00
07/02/2026 CGOSER RAP PAGO LUZ CFE  0011223344                  1,250.00                                24,250.00
09/02/2026 COMISION X SERVICIO GBS  0055667788                    150.00                                24,100.00
RESUMEN DE TU CUENTA INTEGRAL
Emitido por HSBC MEXICO SA RFC HMI950125KG8
";

    #[test]
    fn parses_hsbc_reversed_columns() {
        let txs = parse_text(SAMPLE).unwrap();
        assert_eq!(txs.len(), 3, "got {txs:#?}");

        // Deposit (Abono) — sits in the RIGHT money column on HSBC, nearest the
        // Depósito/Abono header → positive.
        assert_eq!(txs[0].date, NaiveDate::from_ymd_opt(2026, 2, 5).unwrap());
        assert_eq!(txs[0].amount, Decimal::from_str("9500.00").unwrap());
        assert!(txs[0].description.contains("ABONO TRANSFERENCIA"));
        assert_eq!(
            txs[0].balance_after,
            Some(Decimal::from_str("25500.00").unwrap())
        );

        // Withdrawals (Cargo) — left money column → negative.
        assert_eq!(txs[1].amount, Decimal::from_str("-1250.00").unwrap());
        assert_eq!(txs[2].amount, Decimal::from_str("-150.00").unwrap());
    }

    #[test]
    fn empty_text_no_transactions() {
        assert!(parse_text("").unwrap().is_empty());
    }
}
