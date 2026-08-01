//! Scotiabank México (Scotiabank Inverlat) checking-statement parser for
//! poppler `pdftotext -layout` output.
//!
//! The "Detalle de tus movimientos" table is laid out in spatial columns:
//!
//! ```text
//!    Fecha     Concepto              Origen / Referencia    Depósito      Retiro       Saldo
//! 04 MAR   01 EFECTIVO COBRANZA      601174896201           $2,767.29                  $3,986,297.17
//! 01 MAR   COBRO DE COMISION         0000000000000000                     $1.00        $3,983,530.04
//! ```
//!
//! Facts that shape the parser (verified against two real statements, 2017 &
//! 2024 — identical layout):
//!  * Rows start with a `DD MMM` date with **NO year in the row**. The year
//!    lives only in the period header (`Periodo 01-MAR-24/27-MAR-24`), so we
//!    parse it once and inherit it, handling a Dec→Jan period rollover.
//!  * Depósito (credit) vs Retiro (debit) is positional; both and SALDO carry
//!    a `$` prefix. SALDO is the running balance on the first line of each row.
//!  * There is no "SALDO ANTERIOR" opener row — the first movement is real.

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
        "RESUMEN DE SALDOS",
        "COMPORTAMIENTO DE TRANSACCIONES",
        "TOTAL DE COMISIONES",
        "CAT PROMEDIO",
        "ADVERTENCIAS",
        "INCUMPLIR TUS OBLIGACIONES",
        "AL SER TU CREDITO",
        "AL SER TU CRÉDITO",
        "PARA MAYOR INFORMACION",
        "PARA MAYOR INFORMACIÓN",
        "CENTRO DE ATENCION",
        "CENTRO DE ATENCIÓN",
        "SCOTIABANK INVERLAT",
        "ESTADO DE CUENTA",
        "SALDO INICIAL",
        "SALDO FINAL",
        "PAGINA",
        "PÁGINA",
        "CONDUSEF",
        "UNE@SCOTIABANK",
        "LEY DE INSTITUCIONES DE CREDITO",
        "LEY DE INSTITUCIONES DE CRÉDITO",
    ];
    KEYS.iter().any(|k| upper.contains(k))
}

/// Resolve the year for a transaction month from the statement period.
struct YearCtx {
    start_month: u32,
    start_year: i32,
    end_month: u32,
    end_year: i32,
}

impl YearCtx {
    fn year_for(&self, month: u32) -> i32 {
        if month == self.end_month && self.end_year != self.start_year {
            self.end_year
        } else if month == self.start_month {
            self.start_year
        } else if self.end_year != self.start_year && month < self.start_month {
            self.end_year
        } else {
            self.start_year
        }
    }
}

fn period(text: &str) -> YearCtx {
    // Periodo 01-MAR-24/27-MAR-24  (DD-MMM-AA / DD-MMM-AA)
    let re =
        Regex::new(r"(\d{2})-([A-Za-z]{3})-(\d{2})\s*/\s*(\d{2})-([A-Za-z]{3})-(\d{2})").unwrap();
    if let Some(c) = re.captures(text) {
        let sm = month_abbr(&c[2].to_uppercase()).unwrap_or(1);
        let sy = 2000 + c[3].parse::<i32>().unwrap_or(25);
        let em = month_abbr(&c[5].to_uppercase()).unwrap_or(sm);
        let ey = 2000 + c[6].parse::<i32>().unwrap_or(sy - 2000);
        return YearCtx {
            start_month: sm,
            start_year: sy,
            end_month: em,
            end_year: ey,
        };
    }
    YearCtx {
        start_month: 1,
        start_year: 2025,
        end_month: 12,
        end_year: 2025,
    }
}

struct Record {
    date: NaiveDate,
    desc: Vec<String>,
    deposit: Option<Decimal>,
    retiro: Option<Decimal>,
    saldo: Option<Decimal>,
}

pub fn parse_text(text: &str) -> Result<Vec<ParsedTransaction>> {
    let yctx = period(text);
    let upper_all = text.to_uppercase();
    let start = upper_all.find("DETALLE DE TUS MOVIMIENTOS").unwrap_or(0);
    let section = &text[start..];

    // DD MMM lead-in (no year).
    let row_re = Regex::new(r"^\s*(\d{2})\s+([A-Za-z]{3})\b").unwrap();

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
        if (upper.contains("DEPOSITO") || upper.contains("DEPÓSITO"))
            && upper.contains("RETIRO")
            && upper.contains("SALDO")
        {
            if let Some(c) = detect_cols(line, DEP, WD) {
                cols = Some(c);
            }
            continue;
        }

        // A real date row needs a valid month abbreviation.
        let is_date_row = row_re
            .captures(line)
            .and_then(|c| month_abbr(&c[2].to_uppercase()).map(|_| ()))
            .is_some();

        if is_date_row {
            let c = row_re.captures(line).unwrap();
            flush(cur.take(), &mut txs);
            let day: u32 = c[1].parse().unwrap_or(1);
            let month = month_abbr(&c[2].to_uppercase()).unwrap_or(1);
            let year = yctx.year_for(month);
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

    info!(
        "Scotiabank layout parser extracted {} transactions",
        txs.len()
    );
    Ok(txs)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    // Reconstructed from real Scotiabank `pdftotext -layout` extractions:
    // confirmed anchor, header words + order, DD MMM dates (no year), $-prefixed
    // columns, period header drives the year. Fake amounts.
    const SAMPLE: &str = "\
Estado de Cuenta   Periodo 01-MAR-24/27-MAR-24
                                        Detalle de tus movimientos
   Fecha     Concepto                       Origen / Referencia        Depósito          Retiro            Saldo
01 MAR   COBRO DE COMISION                  000000000000000000                            $1.00         $3,983,530.04
04 MAR   01 EFECTIVO COBRANZA C/ RECIBO     601174896201               $2,767.29                        $3,986,297.17
11 MAR   SEL TRASPASO ENTRE CUENTAS         00000000000000011254       $11,246.10                       $3,999,983.28
27 MAR   SPEI ENVIADO BANORTE PROVEEDOR     998877                                        $3,200.00     $3,996,783.28
Resumen de Saldos
Scotiabank Inverlat S.A.
";

    #[test]
    fn parses_scotiabank_no_year_dates() {
        let txs = parse_text(SAMPLE).unwrap();
        assert_eq!(txs.len(), 4, "got {txs:#?}");

        // Year inherited from the period header (2024).
        assert_eq!(txs[0].date, NaiveDate::from_ymd_opt(2024, 3, 1).unwrap());
        assert_eq!(txs[0].amount, Decimal::from_str("-1.00").unwrap());
        assert!(txs[0].description.contains("COBRO DE COMISION"));
        assert!(!txs[0].description.contains('$'), "dollar signs stripped");
        assert_eq!(
            txs[0].balance_after,
            Some(Decimal::from_str("3983530.04").unwrap())
        );

        // Deposit row.
        assert_eq!(txs[1].amount, Decimal::from_str("2767.29").unwrap());
        assert!(txs[1].description.contains("EFECTIVO COBRANZA"));

        // SPEI sent is a withdrawal.
        assert_eq!(txs[3].amount, Decimal::from_str("-3200.00").unwrap());
    }

    #[test]
    fn december_rollover_uses_end_year() {
        let sample = "\
Periodo 27-DIC-24/27-ENE-25
Detalle de tus movimientos
   Fecha     Concepto                 Origen / Referencia       Depósito        Retiro          Saldo
28 DIC   COMPRA OXXO                  111                                       $100.00        $5,000.00
05 ENE   SPEI RECIBIDO NOMINA         222                       $9,000.00                      $14,000.00
";
        let txs = parse_text(sample).unwrap();
        assert_eq!(txs.len(), 2, "got {txs:#?}");
        assert_eq!(txs[0].date, NaiveDate::from_ymd_opt(2024, 12, 28).unwrap());
        assert_eq!(txs[1].date, NaiveDate::from_ymd_opt(2025, 1, 5).unwrap());
    }

    #[test]
    fn empty_text_no_transactions() {
        assert!(parse_text("").unwrap().is_empty());
    }
}
