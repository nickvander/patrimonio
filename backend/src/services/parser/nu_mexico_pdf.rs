//! Nu México ("Cuenta Nu" débito/savings) statement parser for poppler
//! `pdftotext -layout` output.
//!
//! Nu's Cuenta statement is born-digital (selectable text, no OCR needed).
//! Real statements have TWO movement tables, each row carrying a full
//! `DD MMM YYYY` date, an app-style Spanish description, and a single SIGNED
//! `$Monto` (there is NO running-balance column on the current layout):
//!
//! ```text
//!   Detalle de movimientos en tu cuenta
//!    29 SEP 2025   Depósito en Cajita: Cajita Turbo        -$2,948.17
//!    29 SEP 2025   NICK… Transferencia interbancaria       +$2,500.00
//!
//!   Detalle de movimientos de tus cajitas
//!    29 SEP 2025   Depósito en Cajita: Cajita Turbo        +$2,948.17
//!    27 SEP 2025   Congelaste saldo … en tu Cajita: Ahorro -$14,500.00
//! ```
//!
//! The two sections are mirror images of each cajita transfer (the main
//! account loses what a cajita gains), so we keep BOTH but tag them to
//! different accounts: main-account rows have `account_label = None`; cajita
//! rows are tagged with the cajita name (`Ahorro`, `Cajita Turbo`, …) so the
//! importer can route each cajita to its own sub-account. Freeze/unfreeze
//! rows (`Congelaste` / `Descongelamos`) only move money between a cajita's
//! "Disponible" and "Congelado" buckets — they don't change the cajita total,
//! so they're skipped.
//!
//! The year is read straight off the row (`DD MMM YYYY`). An older Nu layout
//! printed only `DD MMM` plus a `Saldo` column; that path is still supported
//! (year from the `Periodo` header, sign from the running-balance delta).

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
    let doc = Document::load_mem(data).map_err(|e| anyhow!("Failed to load PDF: {e}"))?;
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

/// Per-row year for the OLDER `DD MMM` (no inline year) layout, from the
/// `Periodo del DD de <mes> de AAAA al …` header. The fallback "first 20xx in
/// the document" is anchored with `\b` so it can't latch onto a year-like run
/// inside an account number (e.g. `01018002079` → `2079`).
fn year_resolver(upper: &str) -> Box<dyn Fn(u32) -> i32> {
    let re =
        Regex::new(r"PERIODO[: ]+DEL \d{1,2} DE (\w+) DE (\d{4}) AL \d{1,2} DE (\w+) DE (\d{4})")
            .unwrap();
    let fallback = Regex::new(r"\b(20\d{2})\b")
        .unwrap()
        .captures(upper)
        .and_then(|c| c[1].parse::<i32>().ok())
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
        "RECIBISTE",
        "RECIBIDO",
        "DEPOSITO",
        "DEPÓSITO",
        "REEMBOLSO",
        "INTERESES",
        "ABONO",
        "DEVOLUCION",
        "DEVOLUCIÓN",
    ];
    const DEBIT: &[&str] = &[
        "ENVIASTE",
        "COMPRA",
        "PAGO",
        "RETIRO",
        "TRANSFERENCIA",
        "COMISION",
        "COMISIÓN",
        "CARGO",
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

#[derive(Clone, Copy, PartialEq)]
enum Section {
    /// Before any movement header, or the old single-table layout.
    Other,
    /// "Detalle de movimientos en tu cuenta" — the spendable main account.
    MainAccount,
    /// "Detalle de movimientos de tus cajitas" — per-cajita ledger.
    Cajitas,
}

pub fn parse_text(text: &str) -> Result<Vec<ParsedTransaction>> {
    let upper_all = text.to_uppercase();
    let resolve_year = year_resolver(&upper_all);

    // `DD MMM YYYY` (current layout: year on the row) or `DD MMM` (older).
    let date_ymd = Regex::new(r"^\s*(\d{1,2})\s+([A-Za-z]{3})\s+(\d{4})\b").unwrap();
    let date_dm = Regex::new(r"^\s*(\d{1,2})\s+([A-Za-z]{3})\b").unwrap();
    // A money token: optional +/- , optional $, grouped thousands, 2 decimals.
    let money_re = Regex::new(r"([+\-]?)\s*\$?\s*(\d{1,3}(?:,\d{3})*\.\d{2})").unwrap();
    // Cajita name: "… Cajita: <Name>" to end of (amount-stripped) description.
    let cajita_re = Regex::new(r"(?i)Cajita:\s*(.+?)\s*$").unwrap();

    // Seed the running balance from "Saldo inicial" for the OLD layout, where
    // the per-row sign is computed from the balance delta. The current layout
    // has explicit +/- signs and no Saldo column, so this stays None there.
    let mut prev_balance: Option<Decimal> = Regex::new(r"SALDO INICIAL\s*\$?\s*([\d,]+\.\d{2})")
        .unwrap()
        .captures(&upper_all)
        .and_then(|c| Decimal::from_str(&c[1].replace(',', "")).ok());

    let mut section = Section::Other;
    let mut txs: Vec<ParsedTransaction> = Vec::new();

    for raw in text.lines() {
        let line = raw.trim_end();
        let lu = line.to_uppercase();
        if lu.contains("DETALLE DE MOVIMIENTOS EN TU CUENTA") {
            section = Section::MainAccount;
            continue;
        }
        if lu.contains("DETALLE DE MOVIMIENTOS DE TUS CAJITAS") {
            section = Section::Cajitas;
            continue;
        }

        // Date + (optional inline) year.
        let (day, month, inline_year, rest_at) = if let Some(c) = date_ymd.captures(line) {
            (
                c[1].parse::<u32>().ok(),
                month_abbr(&c[2].to_uppercase()),
                c[3].parse::<i32>().ok(),
                c.get(0).unwrap().end(),
            )
        } else if let Some(c) = date_dm.captures(line) {
            (
                c[1].parse::<u32>().ok(),
                month_abbr(&c[2].to_uppercase()),
                None,
                c.get(0).unwrap().end(),
            )
        } else {
            // Continuation line (SPEI details, etc.) or non-transaction text.
            continue;
        };
        let (Some(day), Some(month)) = (day, month) else {
            continue;
        };
        let rest = &line[rest_at..];

        let monies: Vec<Money> = money_re
            .captures_iter(rest)
            .filter_map(|c| {
                Decimal::from_str(&c[2].replace(',', ""))
                    .ok()
                    .map(|value| Money {
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

        // ≥2 tokens → [..monto, saldo] (old layout); 1 token → just the monto.
        let (balance, monto) = if monies.len() >= 2 {
            (
                Some(monies[monies.len() - 1].value),
                &monies[monies.len() - 2],
            )
        } else {
            (None, &monies[0])
        };

        let description = money_re.replace_all(rest, "").trim().to_string();
        if description.is_empty() {
            continue;
        }
        let desc_upper = description.to_uppercase();

        // Per-cajita routing. Freeze/unfreeze only shuffle a cajita's
        // Disponible/Congelado buckets — not a real cashflow — so drop them.
        let mut account_label: Option<String> = None;
        if section == Section::Cajitas {
            if desc_upper.contains("CONGEL") {
                continue;
            }
            if let Some(c) = cajita_re.captures(&description) {
                account_label = Some(c[1].trim().to_string());
            }
        }

        // Sign: balance delta (old-layout truth) → explicit token sign →
        // keyword → default debit.
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

        let year = inline_year.unwrap_or_else(|| resolve_year(month));
        if let Some(date) = NaiveDate::from_ymd_opt(year, month, day) {
            txs.push(ParsedTransaction {
                date,
                description,
                amount,
                currency: "MXN".to_string(),
                category: None,
                category_detailed: None,
                original_description: None,
                balance_after: balance,
                account_label,
                from_ocr: false,
            });
        }
    }

    // Stamp the MAIN "Cuenta" account's AVAILABLE balance onto its latest
    // (non-cajita) transaction's balance_after. `confirm_handler`'s `closing`
    // turns it into that account's current_balance and a net-worth snapshot.
    //
    // NOT the headline grand total ("Saldo al generar este estado de cuenta"
    // = available + cajitas + crédito): each cajita is routed to its OWN
    // sub-account carrying its own balance, so stamping the grand total here
    // double-counts every cajita in net worth. Prefer the explicit available
    // figure; else derive it by removing the cajita total from the grand
    // total; else (no cajitas seen) the grand total IS the available balance.
    let summary = parse_account_summary(text);
    let available = summary
        .en_su_cuenta
        .or(match (summary.saldo_total, summary.total_cajitas) {
            (Some(total), Some(cajitas)) => Some(total - cajitas),
            (total, None) => total,
            (None, _) => None,
        });
    if let Some(available) = available {
        if let Some((idx, _)) = txs
            .iter()
            .enumerate()
            .filter(|(_, t)| t.account_label.is_none())
            .max_by(|(_, a), (_, b)| a.date.cmp(&b.date))
        {
            txs[idx].balance_after = Some(available);
        }
    }

    info!("Nu México PDF parser extracted {} transactions", txs.len());
    Ok(txs)
}

/// The headline balances Nu prints in the "Cómo está organizado tu dinero"
/// summary box. Per-cajita balances are NOT printed (only the total), so
/// callers reconstruct those from the cajita movement history.
#[derive(Debug, Default, Clone, PartialEq)]
pub struct NuSummary {
    /// "En su Cuenta" — the spendable main-account balance.
    pub en_su_cuenta: Option<Decimal>,
    /// "Total Cajitas" — sum across all cajitas.
    pub total_cajitas: Option<Decimal>,
    /// "Crédito con garantía".
    pub credito: Option<Decimal>,
    /// "Saldo al generar este estado de cuenta" — the grand total.
    pub saldo_total: Option<Decimal>,
}

/// Extract the summary-box balances from a Nu statement. Used to suggest
/// starting balances when an account doesn't exist yet.
pub fn parse_account_summary(text: &str) -> NuSummary {
    let mut out = NuSummary::default();
    let money_re = Regex::new(r"\$\s*(\d{1,3}(?:,\d{3})*\.\d{2})").unwrap();
    let dec = |s: &str| Decimal::from_str(&s.replace(',', "")).ok();

    // "Saldo al generar este estado de cuenta   $63,525.30"
    if let Some(c) =
        Regex::new(r"(?i)Saldo al generar este estado de cuenta\s*\$?\s*([\d,]+\.\d{2})")
            .unwrap()
            .captures(text)
    {
        out.saldo_total = dec(&c[1]);
    }

    // The "En su Cuenta | Total Cajitas | Crédito con garantía" labels sit on
    // one line; the three amounts on the next non-empty line, in that order.
    let lines: Vec<&str> = text.lines().collect();
    for (i, line) in lines.iter().enumerate() {
        let lu = line.to_uppercase();
        if lu.contains("EN SU CUENTA") && lu.contains("TOTAL CAJITAS") {
            for next in lines.iter().skip(i + 1).take(4) {
                let amounts: Vec<Decimal> = money_re
                    .captures_iter(next)
                    .filter_map(|c| dec(&c[1]))
                    .collect();
                if amounts.len() >= 2 {
                    out.en_su_cuenta = Some(amounts[0]);
                    out.total_cajitas = Some(amounts[1]);
                    out.credito = amounts.get(2).copied();
                    break;
                }
            }
            break;
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    // OLDER layout: DD MMM + a running $Saldo column, year from the Periodo
    // header. Kept to prove backward compatibility.
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
        assert_eq!(txs.len(), 5, "got {txs:#?}");
        assert_eq!(txs[0].date, NaiveDate::from_ymd_opt(2024, 10, 1).unwrap());
        assert_eq!(txs[0].amount, Decimal::from_str("12000.00").unwrap());
        assert!(txs[0].description.contains("Recibiste de NOMINA"));
        assert_eq!(
            txs[0].balance_after,
            Some(Decimal::from_str("36406.48").unwrap())
        );
        assert_eq!(txs[1].amount, Decimal::from_str("-150.00").unwrap());
        assert_eq!(txs[2].amount, Decimal::from_str("-2500.00").unwrap());
        assert_eq!(txs[3].amount, Decimal::from_str("4272.69").unwrap());
        assert_eq!(txs[4].amount, Decimal::from_str("-5743.57").unwrap());
        assert_eq!(
            txs[4].balance_after,
            Some(Decimal::from_str("32285.60").unwrap())
        );
    }

    #[test]
    fn keyword_sign_without_balance_column() {
        let text = "\
Periodo del 01 de marzo de 2024 al 31 de marzo de 2024
15 MAR   Compra en AMAZON MX                                 899.00
16 MAR   Recibiste de PATRON SA                            3,000.00
";
        let txs = parse_text(text).unwrap();
        assert_eq!(txs.len(), 2, "got {txs:#?}");
        assert_eq!(txs[0].amount, Decimal::from_str("-899.00").unwrap());
        assert_eq!(txs[1].amount, Decimal::from_str("3000.00").unwrap());
        assert!(txs[0].balance_after.is_none());
    }

    // CURRENT layout: inline DD MMM YYYY, signed $Monto, two sections,
    // cajita rows tagged + freeze rows dropped. Mirrors the real statements.
    const CURRENT: &str = "\
Nick Van Der Auwermeulen
Cuenta Nu: 01018002079
CLABE: 638180010180020790
Periodo: del 01 al 30 sep 2025

Cómo está organizado tu dinero
                En su Cuenta            Total Cajitas         Crédito con garantía
                $0.00                   $62,672.07            $828.50
  Saldo al generar este estado de cuenta                      $63,525.30

        Detalle de movimientos en tu cuenta
 29 SEP 2025   Depósito en Cajita: Cajita Turbo                       -$2,948.17
 29 SEP 2025   NICK… Transferencia interbancaria                      +$2,500.00
                      Depósito SPEI, Hora: 20:54:10, Recibido de BANAMEX. Del cliente
 29 SEP 2025   Retiro de Cajita: Ahorro                               +$35,448.17

        Detalle de movimientos de tus cajitas
 29 SEP 2025   Depósito en Cajita: Cajita Turbo                       +$2,948.17
 29 SEP 2025   Retiro de Cajita: Ahorro                               -$35,448.17
 27 SEP 2025   Congelaste saldo hasta el 25 OCT 2025 en tu Cajita: Ahorro   -$14,500.00
";

    #[test]
    fn parses_current_layout_two_sections_with_cajita_labels() {
        let txs = parse_text(CURRENT).unwrap();

        // Inline year is honoured (NOT 2079 from the account number).
        assert!(
            txs.iter()
                .all(|t| t.date.format("%Y").to_string() == "2025"),
            "years: {:?}",
            txs.iter().map(|t| t.date).collect::<Vec<_>>()
        );

        // Main-account rows: account_label None, BANAMEX in a description must
        // NOT matter here.
        let main: Vec<_> = txs.iter().filter(|t| t.account_label.is_none()).collect();
        assert_eq!(main.len(), 3, "main rows: {main:#?}");
        // Signs come from the explicit +/-.
        assert_eq!(main[0].amount, Decimal::from_str("-2948.17").unwrap());
        assert_eq!(main[1].amount, Decimal::from_str("2500.00").unwrap());

        // Cajita rows tagged by name; freeze row dropped.
        let cajita: Vec<_> = txs.iter().filter(|t| t.account_label.is_some()).collect();
        assert_eq!(cajita.len(), 2, "cajita rows: {cajita:#?}");
        assert_eq!(cajita[0].account_label.as_deref(), Some("Cajita Turbo"));
        assert_eq!(cajita[0].amount, Decimal::from_str("2948.17").unwrap());
        assert_eq!(cajita[1].account_label.as_deref(), Some("Ahorro"));
        assert_eq!(cajita[1].amount, Decimal::from_str("-35448.17").unwrap());
        // The "Congelaste…" row was skipped.
        assert!(!txs
            .iter()
            .any(|t| t.description.to_uppercase().contains("CONGEL")));
    }

    #[test]
    fn extracts_summary_balances() {
        let s = parse_account_summary(CURRENT);
        assert_eq!(s.en_su_cuenta, Some(Decimal::from_str("0.00").unwrap()));
        assert_eq!(
            s.total_cajitas,
            Some(Decimal::from_str("62672.07").unwrap())
        );
        assert_eq!(s.credito, Some(Decimal::from_str("828.50").unwrap()));
        assert_eq!(s.saldo_total, Some(Decimal::from_str("63525.30").unwrap()));
    }

    #[test]
    fn empty_text_no_transactions() {
        assert!(parse_text("").unwrap().is_empty());
    }

    #[test]
    fn main_row_balance_is_available_not_grand_total() {
        // Regression: the main "Cuenta" row must carry the AVAILABLE balance
        // (en su cuenta = 0.00 in this fixture), NOT the grand total
        // (saldo_total = 63525.30). Stamping the grand total double-counts
        // every cajita that gets routed to its own sub-account.
        let txs = parse_text(CURRENT).unwrap();
        let stamped: Vec<_> = txs
            .iter()
            .filter(|t| t.account_label.is_none() && t.balance_after.is_some())
            .collect();
        assert_eq!(
            stamped.len(),
            1,
            "exactly one main row is stamped: {stamped:#?}"
        );
        assert_eq!(
            stamped[0].balance_after,
            Some(Decimal::from_str("0.00").unwrap()),
            "main row must carry available, not the grand total"
        );
        assert!(
            txs.iter()
                .all(|t| t.balance_after != Some(Decimal::from_str("63525.30").unwrap())),
            "the grand total must never be stamped as a balance"
        );
    }
}
