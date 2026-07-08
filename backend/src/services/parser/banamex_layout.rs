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
        // The next account section's "Detalle de operaciones" header lands
        // at the tail of the previous section — don't let it pollute the
        // last record's description.
        || upper.starts_with("DETALLE")
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
    // MOST RELIABLE: the cut date "FECHA DE CORTE 23 DE MAYO DE 2026". The
    // statement covers ~one month ending here, so every row is in `corte_year`
    // for months up to `corte_month`, and `corte_year - 1` for any later month
    // (the Dec→Jan straddle). This avoids the old failure where a stray "20xx"
    // in a reference/account number (e.g. "2074") was taken as the year and
    // dated a whole statement to the future.
    if let Some(c) =
        Regex::new(r"FECHA DE CORTE\s+\d{1,2}\s+DE\s+(\w+)\s+DE\s+(20\d{2})")
            .unwrap()
            .captures(upper)
    {
        if let (Some(cm), Ok(cy)) = (month_full(&c[1]), c[2].parse::<i32>()) {
            return Box::new(move |m: u32| if m > cm { cy - 1 } else { cy });
        }
    }

    // Next: an explicit two-year período ("… del 2025 al … del 2026").
    if let Some(c) = Regex::new(
        r"PER[IÍ]ODO DEL \d{1,2} DE (\w+) DEL (20\d{2}) AL \d{1,2} DE (\w+) DEL (20\d{2})",
    )
    .unwrap()
    .captures(upper)
    {
        let sm = month_full(&c[1]).unwrap_or(1);
        let sy: i32 = c[2].parse().unwrap_or(2025);
        let ey: i32 = c[4].parse().unwrap_or(sy);
        return Box::new(move |m: u32| if sy == ey || m >= sm { sy } else { ey });
    }

    // Single-year período ("… al 24 de mayo del 2026").
    if let Some(y) = Regex::new(r"PER[IÍ]ODO DEL .* DEL (20\d{2})")
        .unwrap()
        .captures(upper)
        .and_then(|c| c[1].parse::<i32>().ok())
    {
        return Box::new(move |_m: u32| y);
    }

    // Last resort: the first 20xx in the header.
    let fallback = Regex::new(r"(20\d{2})")
        .unwrap()
        .find(&upper[..upper.len().min(3000)])
        .and_then(|m| m.as_str().parse::<i32>().ok())
        .unwrap_or(2025);
    Box::new(move |_m: u32| fallback)
}

/// Parse the `pdftotext -layout` text of a Banamex statement.
///
/// A single Banamex PDF bundles MULTIPLE accounts (a primary MiCuenta, then
/// a Pagaré / Ahorro / Inversión sub-account), each with its OWN detail
/// table and its own opening "SALDO ANTERIOR". We split on those openers and
/// parse each section independently, tagging the secondary sections with an
/// `account_label` so the import flow can route them to their own account —
/// otherwise that savings balance is silently dropped from net worth.
pub fn parse_text(text: &str) -> Result<Vec<ParsedTransaction>> {
    let upper = text.to_uppercase();
    let resolve_year = year_resolver(&upper);

    // Anchor to the detail table when present, so summary figures don't
    // masquerade as transactions. Falls back to the whole document.
    let start = upper.find("DETALLE DE OPERACIONES").unwrap_or(0);
    let section = &text[start..];
    let lines: Vec<&str> = section.lines().collect();

    // Section openers: each account's opening "SALDO ANTERIOR" row (the
    // uppercase detail form — the mixed-case "Saldo anterior" summary boxes
    // don't match, so they never split a section).
    let openers: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter(|(_, l)| l.contains("SALDO ANTERIOR"))
        .map(|(i, _)| i)
        .collect();

    let mut txs: Vec<ParsedTransaction> = Vec::new();
    if openers.is_empty() {
        // No opener found — parse the whole thing as one (primary) section.
        txs.extend(parse_section(&lines, resolve_year.as_ref()));
    } else {
        for (sec_idx, &begin) in openers.iter().enumerate() {
            let end = openers.get(sec_idx + 1).copied().unwrap_or(lines.len());
            let label = section_label(sec_idx);
            let mut sec_txs = parse_section(&lines[begin..end], resolve_year.as_ref());
            for t in &mut sec_txs {
                t.account_label = label.clone();
            }
            txs.extend(sec_txs);
        }
    }

    info!("Banamex layout parser extracted {} transactions", txs.len());
    Ok(txs)
}

/// Stable destination label for an account section. The primary (index 0)
/// keeps `None` so single-account statements — and the primary account of a
/// bundled statement — behave EXACTLY as before. Secondary sections get a
/// stable ordinal label; the user maps it to their real savings/Pagaré
/// account in the import picker (so the label only needs to be consistent
/// across statements, not pretty).
fn section_label(sec_idx: usize) -> Option<String> {
    match sec_idx {
        0 => None,
        1 => Some("Cuenta secundaria".to_string()),
        n => Some(format!("Cuenta secundaria {}", n)),
    }
}

/// Parse a SINGLE account section (one "SALDO ANTERIOR" opener + its detail
/// rows). Sign comes from the running-SALDO delta — the bank's own balance
/// column is the most reliable signal. `account_label` is left `None`; the
/// caller stamps the section's label.
fn parse_section(lines: &[&str], resolve_year: &dyn Fn(u32) -> i32) -> Vec<ParsedTransaction> {
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
                category_detailed: None,
                original_description: None,
                balance_after: Some(saldo),
                account_label: None,
                from_ocr: false,
            });
        }
    };

    for raw in lines {
        let line = raw.trim_end();
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        let upper_line = trimmed.to_uppercase();
        let amounts: Vec<Decimal> = amt_re
            .find_iter(trimmed)
            .filter(|m| {
                // A number directly followed by '%' is a rate (the "0.50%"
                // in "INTERESES AL 0.50%"), not money.
                if trimmed[m.end()..].starts_with('%') {
                    return false;
                }
                // A real amount stands alone — reject matches embedded in a
                // longer token, e.g. the "0624.01" inside a page-footer code
                // "...B26INDA009.OD.0624.01", which otherwise corrupts the
                // record's amount + running balance. The preceding char must
                // not be a digit, letter, or '.'.
                let before = trimmed[..m.start()].chars().last();
                !matches!(before, Some(c) if c.is_ascii_alphanumeric() || c == '.')
            })
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

    txs
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

        // Running balance captured (drives the account's current balance).
        assert_eq!(txs[2].balance_after, Some(Decimal::from_str("31000.00").unwrap()));
    }

    // Multi-account statement: a primary MiCuenta + a secondary
    // (Pagaré/Ahorro) section, each with its own "SALDO ANTERIOR" opener and
    // running-balance table. Also exercises an interest rate that must NOT
    // be read as money and a page-footer code with an embedded ".dd".
    const MULTI: &str = "\
Período del 25 de mayo del 2024 al 24 de junio del 2024
Detalle de Operaciones   FECHA  CONCEPTO   RETIROS  DEPÓSITOS  SALDO
25 MAY       SALDO ANTERIOR                                              5,000.00
28 MAY       PAGO RECIBIDO DE BBVA
             HORA 08:30 SUC 0519                            3,000.00     8,000.00
             0005073                      000190.B26INDA009.OD.0624.01
29 MAY       INTERESES AL 0.50%                             2.23         8,002.23
Detalle de operaciones
25 MAY       SALDO ANTERIOR                                              88,317.93
28 MAY       TRASPASO ENTRE CUENTAS
             HORA 08:30 SUC 0519           3,000.00                      85,317.93
29 MAY       INTERESES GANADOS                              12.50        85,330.43
";

    #[test]
    fn parses_both_accounts_and_labels_the_secondary() {
        let txs = parse_text(MULTI).unwrap();
        // Both account sections are now parsed: 2 primary + 2 secondary.
        assert_eq!(txs.len(), 4, "got {:#?}", txs);

        // --- Primary section (account_label None) ---
        // The deposit's balance is 8,000 — the "0624.01" inside the footer
        // code did NOT corrupt it.
        assert_eq!(txs[0].amount, Decimal::from_str("3000.00").unwrap());
        assert_eq!(txs[0].balance_after, Some(Decimal::from_str("8000.00").unwrap()));
        assert_eq!(txs[0].account_label, None);
        // The 0.50% rate is not money: the interest row's amount is 2.23.
        assert_eq!(txs[1].amount, Decimal::from_str("2.23").unwrap());
        assert_eq!(txs[1].account_label, None);
        assert!(!txs[1].description.to_uppercase().contains("DETALLE"),
            "next section's header must not leak into the description");

        // --- Secondary section (account_label = Cuenta secundaria) ---
        // Sign comes from this section's OWN running balance (its prev_saldo
        // was reset to 88,317.93), so the traspaso is -3,000 not garbage.
        assert_eq!(txs[2].amount, Decimal::from_str("-3000.00").unwrap());
        assert_eq!(txs[2].balance_after, Some(Decimal::from_str("85317.93").unwrap()));
        assert_eq!(txs[2].account_label.as_deref(), Some("Cuenta secundaria"));
        assert_eq!(txs[3].amount, Decimal::from_str("12.50").unwrap());
        assert_eq!(txs[3].account_label.as_deref(), Some("Cuenta secundaria"));

        assert!(txs.iter().all(|t| t.description.chars().any(|c| c.is_alphabetic())),
            "no bare-number descriptions");
    }

    #[test]
    fn empty_text_no_transactions() {
        assert!(parse_text("").unwrap().is_empty());
    }
}
