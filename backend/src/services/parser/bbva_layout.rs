//! BBVA México ("Estado de Cuenta") parser for poppler `pdftotext -layout`
//! output.
//!
//! BBVA lays its "Detalle de Movimientos Realizados" table out in spatial
//! columns:
//!
//! ```text
//!   OPER LIQ   COD. DESCRIPCIÓN        REFERENCIA      CARGOS     ABONOS   OPERACIÓN LIQUIDACIÓN
//! 02/MAY 02/MAY T20 SPEI RECIBIDO                                12,500.00 27,700.00  27,700.00
//!               0001234567 NOMINA MAYO Ref. 4567890 EMPRESA EJEMPLO SA DE CV
//! 05/MAY 05/MAY T17 SPEI ENVIADO STP             3,200.00
//!               0009876543 PAGO RENTA Ref. 1122334 MARIA LOPEZ
//! ```
//!
//! Key facts that shape the parser (cross-checked against real statements):
//!  * A record starts with `OPER LIQ COD` — two `DD/MMM` dates and a
//!    `[A-Z]\d\d` operation code. Lines without that lead-in are
//!    description continuations of the previous record.
//!  * CARGOS (debit) vs ABONOS (credit) is **positional**, not signed — we
//!    bucket each money token by its column against the header positions.
//!  * The running balance (OPERACIÓN/LIQUIDACIÓN) is printed only on the
//!    last row of each day, so many rows carry no balance — that's fine,
//!    `balance_after` is optional.
//!  * The year is not in the rows; it comes from the `Periodo` header.

use super::layout_util::{amounts_with_pos, col_of, month_abbr, strip_amounts};
use crate::models::import::ParsedTransaction;
use anyhow::Result;
use chrono::NaiveDate;
use regex::Regex;
use rust_decimal::Decimal;
use tracing::info;

/// Column boundaries derived from the table header line, in char columns.
/// `cargo_abono` splits the CARGOS and ABONOS columns; `abono_balance`
/// splits ABONOS from the (OPERACIÓN/LIQUIDACIÓN) balance columns.
#[derive(Clone, Copy)]
struct Columns {
    cargo_abono: usize,
    abono_balance: usize,
}

/// Detect the CARGOS/ABONOS/SALDO column geometry from a header line.
fn detect_columns(line: &str) -> Option<Columns> {
    let upper = line.to_uppercase();
    let cargos = col_of(&upper, "CARGOS")?;
    let abonos = col_of(&upper, "ABONOS")?;
    if abonos <= cargos {
        return None;
    }
    // Balance region starts at OPERACIÓN (fall back to LIQUIDACIÓN). If
    // neither header is present, assume the balance columns sit one
    // ABONOS-width to its right.
    let balance = col_of(&upper, "OPERACI")
        .or_else(|| col_of(&upper, "LIQUIDACI"))
        .unwrap_or(abonos + (abonos - cargos));
    Some(Columns {
        cargo_abono: (cargos + abonos) / 2,
        abono_balance: (abonos + balance) / 2,
    })
}

/// Resolve per-row year from the `Periodo DEL dd/mm/aaaa AL dd/mm/aaaa`
/// header, handling a statement that straddles a year boundary
/// (Dec → Jan). Returns a closure month → year.
fn year_resolver(upper: &str) -> Box<dyn Fn(u32) -> i32> {
    let re = Regex::new(r"DEL\s+\d{2}/(\d{2})/(\d{4})\s+AL\s+\d{2}/(\d{2})/(\d{4})").unwrap();
    let fallback = Regex::new(r"(20\d{2})")
        .unwrap()
        .find(upper)
        .and_then(|m| m.as_str().parse::<i32>().ok())
        .unwrap_or(2025);
    if let Some(c) = re.captures(upper) {
        let sm: u32 = c[1].parse().unwrap_or(1);
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
        Box::new(move |_| fallback)
    }
}

/// True for page furniture (repeated headers, legal footer, summary block)
/// that must never be read as description or amounts.
fn is_furniture(upper: &str) -> bool {
    const KEYS: &[&str] = &[
        "ESTADO DE CUENTA",
        "PAGINA",
        "PÁGINA",
        "INSTITUCION DE BANCA",
        "INSTITUCIÓN DE BANCA",
        "PASEO DE LA REFORMA",
        "DETALLE DE MOVIMIENTOS",
        "INFORMACION FINANCIERA",
        "INFORMACIÓN FINANCIERA",
        "NO. CUENTA",
        "NO. CLIENTE",
        "MONEDA NACIONAL",
        "GRUPO FINANCIERO",
    ];
    KEYS.iter().any(|k| upper.contains(k))
}

/// The CFDI/SAT digital tax-stamp tail at the end of modern statements —
/// stop parsing here, it's base64 noise.
fn is_stamp_tail(upper: &str) -> bool {
    upper.contains("CADENA ORIGINAL")
        || upper.contains("SELLO DIGITAL")
        || upper.contains("TIMBRE FISCAL")
        || upper.contains("CERTIFICACION DIGITAL DEL SAT")
}

struct Record {
    day: u32,
    month: u32,
    desc: Vec<String>,
    cargo: Option<Decimal>,
    abono: Option<Decimal>,
    balance: Option<Decimal>,
}

pub fn parse_text(text: &str) -> Result<Vec<ParsedTransaction>> {
    let upper_all = text.to_uppercase();
    let resolve_year = year_resolver(&upper_all);

    // Anchor at the movement table so the summary block above it can't
    // masquerade as transactions.
    let start = upper_all.find("DETALLE DE MOVIMIENTOS").unwrap_or(0);
    let section = &text[start..];

    // OPER LIQ COD lead-in. Captures OPER day + month abbreviation.
    let row_re =
        Regex::new(r"^\s*(\d{1,2})/([A-Z]{3})\s+\d{1,2}/[A-Z]{3}\s+([A-Z]\d{2})\b").unwrap();

    let mut txs: Vec<ParsedTransaction> = Vec::new();
    let mut cols: Option<Columns> = None;
    let mut cur: Option<Record> = None;

    let flush = |rec: Option<Record>, txs: &mut Vec<ParsedTransaction>| {
        let Some(rec) = rec else { return };
        let amount = match (rec.cargo, rec.abono) {
            (Some(c), _) => -c,
            (_, Some(a)) => a,
            // No movement on the row (balance-only / informational) — skip.
            (None, None) => return,
        };
        let description = rec.desc.join(" ").split_whitespace().collect::<Vec<_>>().join(" ");
        if description.is_empty() {
            return;
        }
        if let Some(date) = NaiveDate::from_ymd_opt(resolve_year(rec.month), rec.month, rec.day) {
            txs.push(ParsedTransaction {
                date,
                description,
                amount,
                currency: "MXN".to_string(),
                category: None,
                original_description: None,
                balance_after: rec.balance,
                account_label: None,
                from_ocr: false,
            });
        }
    };

    for raw in section.lines() {
        let line = raw.trim_end();
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let upper = trimmed.to_uppercase();

        if is_stamp_tail(&upper) {
            break;
        }

        // Learn / refresh the column geometry from each header occurrence.
        if upper.contains("CARGOS") && upper.contains("ABONOS") {
            if let Some(c) = detect_columns(line) {
                cols = Some(c);
            }
            continue;
        }

        if let Some(c) = row_re.captures(line) {
            // New record — flush the previous.
            flush(cur.take(), &mut txs);

            let day: u32 = c[1].parse().unwrap_or(1);
            let month = month_abbr(&c[2]).unwrap_or(1);
            let cod_end = c.get(0).unwrap().end();
            let tail = &line[cod_end..];

            let mut rec = Record {
                day,
                month,
                desc: Vec::new(),
                cargo: None,
                abono: None,
                balance: None,
            };
            bucket_amounts(line, cols, &mut rec);
            let desc = strip_amounts(tail);
            if !desc.is_empty() {
                rec.desc.push(desc);
            }
            cur = Some(rec);
            continue;
        }

        // Not a row start. Either furniture (skip) or a description
        // continuation of the current record.
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

    info!("BBVA layout parser extracted {} transactions", txs.len());
    Ok(txs)
}

/// Bucket each money token on `line` into cargo / abono / balance by its
/// column position. When we couldn't detect the header geometry, fall back
/// to "last token is balance, the one before is the movement" (still better
/// than nothing) and leave the sign to the description-less default of a
/// debit, which the preview lets the user correct.
fn bucket_amounts(line: &str, cols: Option<Columns>, rec: &mut Record) {
    let amts = amounts_with_pos(line);
    if amts.is_empty() {
        return;
    }
    match cols {
        Some(c) => {
            for a in amts {
                if a.center < c.cargo_abono {
                    rec.cargo = Some(a.value);
                } else if a.center < c.abono_balance {
                    rec.abono = Some(a.value);
                } else {
                    // OPERACIÓN + LIQUIDACIÓN are (near-)equal; keep the
                    // right-most as the row's balance_after.
                    rec.balance = Some(a.value);
                }
            }
        }
        None => {
            if amts.len() == 1 {
                rec.cargo = Some(amts[0].value);
            } else {
                rec.balance = Some(amts[amts.len() - 1].value);
                rec.cargo = Some(amts[amts.len() - 2].value);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    // Reconstructed from real BBVA México `pdftotext -layout` structure:
    // confirmed header labels, OPER/LIQ DD/MMM dates, COD codes, CARGOS/
    // ABONOS/OPERACIÓN/LIQUIDACIÓN columns, the "balance only on the day's
    // last row" quirk, and the legal footer. Fake account/amounts.
    const SAMPLE: &str = "\
                                          Periodo                 DEL 01/05/2026 AL 31/05/2026
                                          No. de Cuenta                           1234567890
Información Financiera                                                    MONEDA NACIONAL
 Saldo de Liquidación Inicial          15,200.00
Detalle de Movimientos Realizados
     FECHA                                                                         SALDO
  OPER LIQ    COD. DESCRIPCIÓN              REFERENCIA               CARGOS         ABONOS      OPERACIÓN LIQUIDACIÓN
02/MAY 02/MAY T20 SPEI RECIBIDO BANORTE                                          12,500.00      27,700.00   27,700.00
              0001234567 NOMINA MAYO Ref. 4567890 EMPRESA EJEMPLO SA DE CV
05/MAY 05/MAY T17 SPEI ENVIADO STP                                 3,200.00
              0009876543 PAGO RENTA Ref. 1122334 MARIA LOPEZ HERNANDEZ
12/MAY 12/MAY C19 INTERESES GANADOS                                                  18.42      21,168.42   21,168.42
15/MAY 15/MAY N06 COMPRA CON TARJETA DE DEBITO                       532.68                     18,635.74   18,635.74
              OXXO COL DEL VALLE Ref. 7766554
31/MAY 31/MAY N03 COMISION MANEJO DE CUENTA                           37.32                     22,532.68   22,532.68
BBVA MEXICO, S.A., INSTITUCION DE BANCA MULTIPLE, GRUPO FINANCIERO BBVA MEXICO
Av. Paseo de la Reforma 510, Col. Juárez R.F.C. BBA830831LJ2
";

    #[test]
    fn parses_bbva_columns_and_signs() {
        let txs = parse_text(SAMPLE).unwrap();
        assert_eq!(txs.len(), 5, "got {:#?}", txs);

        // 1) ABONO (deposit) on 02 May 2026, year from Periodo.
        assert_eq!(txs[0].date, NaiveDate::from_ymd_opt(2026, 5, 2).unwrap());
        assert_eq!(txs[0].amount, Decimal::from_str("12500.00").unwrap());
        assert!(txs[0].description.contains("SPEI RECIBIDO"));
        assert!(txs[0].description.contains("EMPRESA EJEMPLO"), "continuation joined");
        assert_eq!(txs[0].balance_after, Some(Decimal::from_str("27700.00").unwrap()));

        // 2) CARGO (withdrawal) with NO balance printed on the row.
        assert_eq!(txs[1].amount, Decimal::from_str("-3200.00").unwrap());
        assert_eq!(txs[1].balance_after, None, "balance omitted on this row");
        assert!(txs[1].description.contains("PAGO RENTA"));

        // 3) Interest abono.
        assert_eq!(txs[2].amount, Decimal::from_str("18.42").unwrap());

        // 4) Debit-card purchase (cargo).
        assert_eq!(txs[3].amount, Decimal::from_str("-532.68").unwrap());
        assert!(txs[3].description.contains("OXXO"));

        // 5) Commission (cargo) — last row.
        assert_eq!(txs[4].amount, Decimal::from_str("-37.32").unwrap());
        assert_eq!(txs[4].balance_after, Some(Decimal::from_str("22532.68").unwrap()));
    }

    #[test]
    fn empty_text_no_transactions() {
        assert!(parse_text("").unwrap().is_empty());
    }
}
