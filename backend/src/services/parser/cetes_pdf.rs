//! cetesdirecto (Nacional Financiera / NAFIN) statement parser for poppler
//! `pdftotext -layout` output.
//!
//! cetesdirecto statements are INVESTMENT-PORTFOLIO statements, not bank
//! ledgers. The page we import is "Movimientos del período" — the cash
//! sub-ledger of the contract — a fixed-column table:
//!
//! ```text
//! Fecha de   Fecha de    Folio        Descripción  Emisora  Serie  Títulos  Precio      Plazo Tasa  Cargo      Abono      Saldo efectivo
//! registro   liquidación
//! Saldo inicial                                                                                                                     0.36
//! 08/04/24   08/04/24    SVD…INGEFVO  …            PESOS    PESOS  0        0           0     0.00  0.00       24,000.00  24,000.36
//! 09/04/24   11/04/24    SVD…COMPRA   …            CETES    241003 2,530    9.48423610  175   11.19 23,995.12  0.00       -23,994.90
//! Saldo final                                                                                                                       0.92
//! ```
//!
//! We import each movement as a transaction: the liquidación date, a
//! description built from the code + emisora + serie (e.g. "COMPRA CETES
//! 241003", "INGEFVO"), a signed amount of `Abono − Cargo`, and the running
//! `Saldo efectivo` as `balance_after`. The amounts have exactly two decimals,
//! which distinguishes the Cargo/Abono/Saldo columns from Precio (8 decimals)
//! and Títulos (no decimals); the last three two-decimal numbers on a row are
//! Cargo, Abono, Saldo in that order.
//!
//! NOTE: `Saldo efectivo` is the *cash* balance (usually ~0 — the money sits
//! in CETES/BONDDIA instruments). The portfolio VALUE is "Total final" in the
//! summary box, exposed via [parse_portfolio_total] for callers that want to
//! value the account by its holdings rather than its idle cash.

use crate::models::import::ParsedTransaction;
use anyhow::{anyhow, Result};
use chrono::NaiveDate;
use lopdf::Document;
use regex::Regex;
use rust_decimal::Decimal;
use std::str::FromStr;
use tracing::info;

pub fn parse(data: &[u8]) -> Result<Vec<ParsedTransaction>> {
    let doc = Document::load_mem(data).map_err(|e| anyhow!("Failed to load PDF: {}", e))?;
    let mut full_text = String::new();
    for (page_num, _) in doc.get_pages().iter() {
        if let Ok(text) = doc.extract_text(&[*page_num]) {
            full_text.push_str(&text);
            full_text.push('\n');
        }
    }
    info!("Extracted {} characters from Cetes PDF", full_text.len());
    parse_text(&full_text)
}

fn dec(s: &str) -> Option<Decimal> {
    Decimal::from_str(&s.replace(',', "")).ok()
}

pub fn parse_text(text: &str) -> Result<Vec<ParsedTransaction>> {
    // A movimiento row: registro + liquidación date (DD/MM/YY), then the rest.
    let row_re =
        Regex::new(r"^\s*(\d{2})/(\d{2})/(\d{2})\s+(\d{2})/(\d{2})/(\d{2})\s+(.+)$").unwrap();
    // Folio (SVD + digits) immediately followed by the descripción code.
    let folio_re = Regex::new(r"^(SVD\d+)([A-Za-z]+)").unwrap();
    // Money columns have EXACTLY two decimals; Precio has 8 and Títulos none.
    // The `regex` crate has no look-around, so we match any decimal and keep
    // only the 2-decimal ones — leaving Tasa/Cargo/Abono/Saldo, of which the
    // last three are Cargo, Abono, Saldo.
    let money_re = Regex::new(r"-?[\d,]+\.(\d+)").unwrap();

    let mut txs: Vec<ParsedTransaction> = Vec::new();
    let mut in_section = false;

    for raw in text.lines() {
        let line = raw.trim_end();
        let upper = line.to_uppercase();
        if upper.contains("MOVIMIENTOS DEL PER") {
            in_section = true;
            continue;
        }
        // "Saldo final" closes the movements block on each page; a repeated
        // header re-opens it. Anything outside is summary/holdings text.
        if upper.trim_start().starts_with("SALDO FINAL") {
            in_section = false;
            continue;
        }
        if !in_section {
            continue;
        }

        let Some(c) = row_re.captures(line) else {
            continue;
        };
        // Use the liquidación date (when the cash actually settled).
        let day: u32 = c[4].parse().unwrap_or(1);
        let month: u32 = c[5].parse().unwrap_or(1);
        let yy: i32 = c[6].parse().unwrap_or(0);
        let year = 2000 + yy;
        let Some(date) = NaiveDate::from_ymd_opt(year, month, day) else {
            continue;
        };

        let rest = c[7].trim();
        let monies: Vec<Decimal> = money_re
            .captures_iter(rest)
            .filter(|m| m[1].len() == 2)
            .filter_map(|m| dec(m.get(0).unwrap().as_str()))
            .collect();
        if monies.len() < 3 {
            continue; // not a real movement row
        }
        let n = monies.len();
        let cargo = monies[n - 3];
        let abono = monies[n - 2];
        let amount = abono - cargo;

        // Build a readable description: code + emisora + serie.
        let tokens: Vec<&str> = rest.split_whitespace().collect();
        let mut parts: Vec<String> = Vec::new();
        if let Some(first) = tokens.first() {
            let code = folio_re
                .captures(first)
                .map(|fc| fc[2].to_string())
                .unwrap_or_else(|| first.to_string());
            parts.push(code);
        }
        // Emisora / serie are the next two tokens (skip the filler "PESOS").
        for t in tokens.iter().skip(1).take(2) {
            if *t != "PESOS" && !parts.contains(&t.to_string()) {
                parts.push(t.to_string());
            }
        }
        let description = parts.join(" ").trim().to_string();
        if description.is_empty() {
            continue;
        }

        // T14: tag explicit YIELD/interest credits as income so cetesdirecto
        // returns reach the tax base. Principal movements (INGEFVO funding,
        // COMPRA buys, VENTA redemptions that bundle principal+yield) and ISR
        // retentions stay uncategorized — see
        // `categorize::classify_cetes_movement` for how yield is separated
        // from principal (by movement type, not by netting a redemption).
        // TODO(T14): when the import insert path persists ISR retenido, route
        // `categorize::is_cetes_isr_withholding(&description)` rows into a
        // withholding field so the MX card can show "estimated minus
        // withheld". `ParsedTransaction` has no such field today (no migration
        // here), so a retention row stays an ordinary outflow.
        let category = crate::services::categorize::classify_cetes_movement(&description, amount);

        txs.push(ParsedTransaction {
            date,
            description,
            amount,
            currency: "MXN".to_string(),
            category,
            original_description: None,
            // The "Saldo efectivo" is just idle cash (~0); the account's real
            // value is the portfolio "Total final". Leaving balance_after None
            // keeps the import-confirm step from pinning the account to the
            // cash balance, and the continuity check skips these rows.
            balance_after: None,
            account_label: None,
            from_ocr: false,
        });
    }

    // Stamp the statement's portfolio "Total final" onto the latest-dated
    // transaction's balance_after. That's the account's real value at the
    // period end — the snapshot back-fill (import confirm) turns it into a
    // dated net-worth point, and `closing` sets the current balance. Only one
    // row per statement carries it, so the continuity check (which needs >=2
    // balance rows) skips these — no false "missing statement" warnings.
    if let Some(total) = parse_portfolio_total(text) {
        if let Some((idx, _)) = txs
            .iter()
            .enumerate()
            .max_by(|(_, a), (_, b)| a.date.cmp(&b.date))
        {
            txs[idx].balance_after = Some(total);
        }
    }

    info!("cetesdirecto parser extracted {} transactions", txs.len());
    Ok(txs)
}

/// The portfolio's "Total final" (cartera + efectivo) from the summary box —
/// the figure that actually belongs in net worth, since the cash `Saldo
/// efectivo` in the movements is ~0. Returns None if the statement doesn't
/// print it.
pub fn parse_portfolio_total(text: &str) -> Option<Decimal> {
    Regex::new(r"(?i)Total final:?\s*\$?\s*([\d,]+\.\d{2})")
        .unwrap()
        .captures(text)
        .and_then(|c| Decimal::from_str(&c[1].replace(',', "")).ok())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Mirrors a real cetesdirecto "Movimientos del período" page.
    const SAMPLE: &str = "\
Resumen del portafolio
Total de cartera:    $   94,537.80
Total final:         $   94,538.72

Movimientos del período
Fecha de   Fecha de   Folio        Descripción  Emisora  Serie   Títulos  Precio      Plazo Tasa   Cargo      Abono      Saldo efectivo
registro   liquidación
Saldo inicial                                                                                                                     0.36
08/04/24   08/04/24   SVD363835179INGEFVO       PESOS    PESOS   0        0           0     0.00   0.00       24,000.00  24,000.36
08/04/24   08/04/24   SVD363835180COMPSI        BONDDIA  PF2     12,319   1.94806300  0     0.00   23,998.19  0.00       2.17
09/04/24   11/04/24   SVD364117037COMPRA        CETES    241003  2,530    9.48423610  175   11.19  23,995.12  0.00       -23,994.90
11/04/24   11/04/24   SVD365324483VTASI         BONDDIA  PF2     12,307   1.94977000  0     0.00   0.00       23,995.82  0.92
Saldo final                                                                                                                       0.92
";

    #[test]
    fn parses_movimientos_table() {
        let txs = parse_text(SAMPLE).unwrap();
        assert_eq!(txs.len(), 4, "got {:#?}", txs);

        // Cash deposit: Abono 24,000 − Cargo 0 = +24,000; date is liquidación.
        assert_eq!(txs[0].date, NaiveDate::from_ymd_opt(2024, 4, 8).unwrap());
        assert_eq!(txs[0].amount, Decimal::from_str("24000.00").unwrap());
        assert!(txs[0].description.contains("INGEFVO"));
        // balance_after is intentionally None (cash saldo isn't the account value).
        assert!(txs[0].balance_after.is_none());

        // Buy BONDDIA: Cargo 23,998.19 → negative.
        assert_eq!(txs[1].amount, Decimal::from_str("-23998.19").unwrap());
        assert!(txs[1].description.contains("COMPSI"));
        assert!(txs[1].description.contains("BONDDIA"));

        // Buy CETES (liquidación 11/04): negative, serie carried into desc.
        assert_eq!(txs[2].date, NaiveDate::from_ymd_opt(2024, 4, 11).unwrap());
        assert_eq!(txs[2].amount, Decimal::from_str("-23995.12").unwrap());
        assert!(txs[2].description.contains("CETES"));
        assert!(txs[2].description.contains("241003"));

        // Sell BONDDIA: Abono 23,995.82 → positive.
        assert_eq!(txs[3].amount, Decimal::from_str("23995.82").unwrap());
    }

    #[test]
    fn extracts_portfolio_total() {
        assert_eq!(
            parse_portfolio_total(SAMPLE),
            Some(Decimal::from_str("94538.72").unwrap())
        );
    }

    #[test]
    fn ignores_non_movement_text() {
        let txs = parse_text("Resumen del portafolio\nTotal final: $1,000.00\n").unwrap();
        assert!(txs.is_empty());
    }
}
