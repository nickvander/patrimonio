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
//!    no DEPOSITOS/RETIROS so neither becomes a transaction. The CLOSING
//!    one's SALDO is kept as `declared_closing_balance` (stamped on every
//!    parsed row): it is the bank's own period total, so reconciliation can
//!    check the ledger against a figure that does NOT come from the rows we
//!    happened to parse. The opener is excluded by its `ANTERIOR` suffix.
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

    // The statement's own DECLARED closing total, captured from the closing
    // `SALDO FINAL DEL PERIODO` row instead of only using it as a terminator.
    // It is what makes the reconciliation check independent of the parsed
    // rows: read off the last row we kept, a dropped trailing row is
    // invisible; read off the bank's printed total, it is a gap.
    let mut declared_closing: Option<Decimal> = None;

    let flush = |rec: Option<Record>,
                 txs: &mut Vec<ParsedTransaction>,
                 declared_closing: &mut Option<Decimal>| {
        let Some(rec) = rec else { return };
        let description = rec
            .desc
            .join(" ")
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        let amount = match (rec.deposit, rec.retiro) {
            (Some(d), _) => d,
            (_, Some(r)) => -r,
            // Opening/closing "SALDO FINAL…" rows have no movement. The
            // CLOSING one — `SALDO FINAL DEL PERIODO`, as opposed to the
            // opener `SALDO FINAL DEL PERIODO ANTERIOR` — carries the
            // period's declared total in the SALDO column; keep it (the row
            // itself is still not a transaction). A later occurrence wins, so
            // on a multi-page extraction the last printed total stands.
            (None, None) => {
                let upper = description.to_uppercase();
                if upper.contains("SALDO FINAL DEL PERIODO") && !upper.contains("ANTERIOR") {
                    if let Some(saldo) = rec.saldo {
                        *declared_closing = Some(saldo);
                    }
                }
                return;
            }
        };
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

        // Learn / refresh the column geometry from each header.
        if (upper.contains("DEPOSITOS") || upper.contains("DEPÓSITOS")) && upper.contains("RETIROS")
        {
            if let Some(c) = detect_columns(line) {
                cols = Some(c);
            }
            continue;
        }

        if let Some(c) = row_re.captures(line) {
            flush(cur.take(), &mut txs, &mut declared_closing);
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
    flush(cur.take(), &mut txs, &mut declared_closing);

    // Stamp the declared total on every row of the statement (not just the
    // last): the import preview lets the user exclude rows, and the check must
    // still know what the bank declared for the period whichever rows survive.
    if let Some(total) = declared_closing {
        for t in &mut txs {
            t.declared_closing_balance = Some(total);
        }
    }

    info!(
        "Santander layout parser extracted {} transactions (declared closing: {:?})",
        txs.len(),
        declared_closing
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
    fn captures_the_declared_saldo_final_del_periodo() {
        // The closing row is still not a transaction, but its SALDO is now
        // kept: every parsed row carries the bank's declared period total.
        let txs = parse_text(SAMPLE).unwrap();
        assert_eq!(txs.len(), 5, "the closing row is still not a transaction");
        for t in &txs {
            assert_eq!(
                t.declared_closing_balance,
                Some(Decimal::from_str("22401.60").unwrap()),
                "declared total stamped on every row: {t:?}"
            );
        }
    }

    #[test]
    fn the_opening_saldo_final_anterior_row_is_not_read_as_the_declared_closing() {
        // `SALDO FINAL DEL PERIODO ANTERIOR` is the OPENER (8,540.10). Reading
        // it as the declared closing would compare the ledger against last
        // month's balance and manufacture a gap on every Santander import.
        let txs = parse_text(SAMPLE).unwrap();
        assert!(
            txs.iter()
                .all(|t| t.declared_closing_balance != Some(Decimal::from_str("8540.10").unwrap())),
            "the ANTERIOR opener must never be the declared closing"
        );
    }

    #[test]
    fn a_dropped_trailing_row_leaves_the_declared_total_above_the_running_column() {
        // THE case this capture exists for: the last movement (COMISION
        // −190.00) never makes it into the parsed rows — a layout quirk, a
        // page-break, a regex miss. The running column then ends at 22,591.60
        // and the rows are perfectly self-consistent, so the old
        // last-row-is-the-closing-balance check reconciled to the centavo.
        // The bank's own declared total still says 22,401.60 — a real gap.
        let truncated = SAMPLE.replace(
            "27-MAY-2026   3456112   COMISION MANEJO DE CUENTA                                              190.00           22,401.60\n",
            "",
        );
        let txs = parse_text(&truncated).unwrap();
        assert_eq!(txs.len(), 4, "one movement dropped: {txs:#?}");
        assert_eq!(
            txs.last().unwrap().balance_after,
            Some(Decimal::from_str("22591.60").unwrap()),
            "the running column ends one row early"
        );
        assert_eq!(
            txs.last().unwrap().declared_closing_balance,
            Some(Decimal::from_str("22401.60").unwrap()),
            "the declared total is unaffected by the dropped row"
        );
    }

    #[test]
    fn a_statement_without_a_closing_row_declares_nothing() {
        // No `SALDO FINAL DEL PERIODO` row → no declared balance and no
        // guess: reconciliation stays on its running-column fallback.
        let no_closing = SAMPLE.replace(
            "31-MAY-2026   3990771   SALDO FINAL DEL PERIODO                                                                 22,401.60\n",
            "",
        );
        let txs = parse_text(&no_closing).unwrap();
        assert_eq!(txs.len(), 5);
        assert!(txs.iter().all(|t| t.declared_closing_balance.is_none()));
    }

    #[test]
    fn empty_text_no_transactions() {
        assert!(parse_text("").unwrap().is_empty());
    }
}
