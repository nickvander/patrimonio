//! Revolut Bank (S.A., Institución de Banca Múltiple — Mexico) statement parser.
//!
//! Revolut MX exports two born-digital PDF layouts (no OCR needed), both in
//! MXN. They look different enough that we branch internally:
//!
//! 1. **Instant Access Savings** statement — the savings pocket on its own.
//!    Page header `Instant Access Savings` + `Generated on …` + `Period: …`.
//!    A single account. Its transaction table carries a `Gross interest rate
//!    earned` column, and `pdftotext -layout` splits every record across
//!    THREE physical lines: the date renders as `May 26,` on the first line
//!    and `2026` on the third, with the amounts sitting on the middle line.
//!    Rows are mostly the daily `Net interest paid …` credit, plus the odd
//!    `Deposit to …`.
//!
//! 2. **`<CCY>` Statement** personal statement — the whole relationship.
//!    Page header `MXN Statement` + `From … to …` + account number / CLABEs.
//!    It bundles MULTIPLE months and, within each month, TWO labelled
//!    sections: `Account transactions …` (the Mexican Peso current account)
//!    and `Instant Access Savings transactions …` (the savings pocket, which
//!    we tag with an `account_label` so the import routes it to its own
//!    account). Each record keeps the full date on one line; the columns are
//!    `Money out | Money in | Balance` — note the OPPOSITE order to the
//!    savings layout's `Money in | Money out`.
//!
//! **Sign convention.** Both layouts always print a running `Balance`, so we
//! derive the signed amount from the balance delta (inflow raises it, outflow
//! lowers it), seeded by the statement's opening balance. This is immune to
//! the two layouts' opposite in/out column order — we never have to guess
//! which column an amount sits under.

use crate::models::import::ParsedTransaction;
use anyhow::Result;
use chrono::NaiveDate;
use lopdf::Document;
use regex::Regex;
use rust_decimal::Decimal;
use std::str::FromStr;
use tracing::info;

/// Cheap content sniff for the dispatch ladder in `mod.rs`. Both layouts
/// carry the issuer name in their footer ("Revolut Bank, S.A., …").
pub fn looks_like(upper_text: &str) -> bool {
    upper_text.contains("REVOLUT")
}

/// In-process lopdf entry point (fallback when `pdftotext -layout` is
/// unavailable); mirrors the other parsers' `parse`/`parse_text` pair.
pub fn parse(data: &[u8]) -> Result<Vec<ParsedTransaction>> {
    let doc = Document::load_mem(data).map_err(|e| anyhow::anyhow!("load PDF: {e}"))?;
    let mut text = String::new();
    for (page, _) in doc.get_pages().iter() {
        if let Ok(t) = doc.extract_text(&[*page]) {
            text.push_str(&t);
            text.push('\n');
        }
    }
    parse_text(&text)
}

/// Primary entry point over `pdftotext -layout` output.
pub fn parse_text(text: &str) -> Result<Vec<ParsedTransaction>> {
    // The personal statement is the only one with a `Account transactions
    // from …` section header (the Mexican Peso current account). The
    // savings-only statement has just a bare `Transactions from …`.
    if text.contains("Account transactions from") {
        parse_personal(text)
    } else {
        parse_savings(text)
    }
}

fn dec(s: &str) -> Option<Decimal> {
    Decimal::from_str(&s.replace([',', '$'], "")).ok()
}

pub(crate) fn month_num(abbr: &str) -> Option<u32> {
    Some(match abbr {
        "Jan" => 1,
        "Feb" => 2,
        "Mar" => 3,
        "Apr" => 4,
        "May" => 5,
        "Jun" => 6,
        "Jul" => 7,
        "Aug" => 8,
        "Sep" => 9,
        "Oct" => 10,
        "Nov" => 11,
        "Dec" => 12,
        _ => return None,
    })
}

/// Money tokens in the transaction tables are always `$1,234.56` (positive;
/// direction is encoded by which column, which we resolve via balance delta).
fn money_re() -> Regex {
    Regex::new(r"\$([\d,]+\.\d{2})").unwrap()
}

/// Classify a Revolut line into (primary, detailed). English descriptions, so
/// `categorize::categorize` (Spanish-keyed) won't catch them — we tag the two
/// shapes that matter here and leave the rest to the generic pass.
fn classify(desc: &str, amount: Decimal) -> (Option<String>, Option<String>) {
    let d = desc.to_lowercase();
    if d.contains("interest") {
        // Net interest paid — savings yield. Already net of withholding on
        // these statements, so it's a plain interest-income credit.
        return (Some("INCOME".into()), Some("INCOME_INTEREST_EARNED".into()));
    }
    // Internal pocket moves and SPEI transfers: a transfer in/out by sign.
    if d.contains("instant access savings")
        || d.contains("transfer")
        || d.contains("deposit")
        || d.contains("withdrawal")
    {
        return if amount < Decimal::ZERO {
            (Some("TRANSFER_OUT".into()), None)
        } else {
            (Some("TRANSFER_IN".into()), None)
        };
    }
    (None, None)
}

/// Trim Revolut's chrome off a raw description: drop the `for May 1, 2026`
/// tail of interest rows and strip stray quotes, then collapse whitespace.
fn clean_desc(raw: &str) -> String {
    let mut s = raw.trim().to_string();
    if let Some(idx) = s.find(" for ") {
        // Only the interest rows use " for <date>"; safe to cut there.
        if s[..idx].to_lowercase().contains("interest") {
            s.truncate(idx);
        }
    }
    let s = s.replace('"', "");
    let multispace = Regex::new(r"\s{2,}").unwrap();
    multispace.replace_all(s.trim(), " ").to_string()
}

// ───────────────────────── savings-only layout ─────────────────────────

fn parse_savings(text: &str) -> Result<Vec<ParsedTransaction>> {
    let money = money_re();
    let day_re = Regex::new(r"([A-Z][a-z]{2})\s+(\d{1,2}),").unwrap();
    let year_re = Regex::new(r"(?:^|\s)(20\d{2})(?:\s|$|,)").unwrap();

    // Seed the running balance from the summary so the first row's sign is
    // correct (delta from opening).
    let mut prev_balance = Regex::new(r"Opening Balance\s+\$([\d,]+\.\d{2})")
        .unwrap()
        .captures(text)
        .and_then(|c| dec(&c[1]))
        .unwrap_or(Decimal::ZERO);

    let mut txs: Vec<ParsedTransaction> = Vec::new();
    let mut in_section = false;
    let mut block: Vec<String> = Vec::new();

    // Records are blank-line-separated blocks; flush on each blank line.
    let mut lines: Vec<&str> = text.lines().collect();
    lines.push(""); // sentinel flush
    for raw in lines {
        let line = raw.trim_end();
        let trimmed = line.trim();

        if trimmed.starts_with("Transactions from") {
            in_section = true;
            block.clear();
            continue;
        }
        // The trailing "Interest" explainer heading closes the ledger.
        if trimmed == "Interest" {
            in_section = false;
        }

        if !line.trim().is_empty() {
            if in_section {
                block.push(line.to_string());
            }
            continue;
        }

        // Blank line → flush the accumulated block.
        if in_section && !block.is_empty() {
            if let Some(tx) = savings_block(&block, &day_re, &year_re, &money, &mut prev_balance) {
                txs.push(tx);
            }
        }
        block.clear();
    }

    info!("Revolut savings: parsed {} transactions", txs.len());
    Ok(txs)
}

fn savings_block(
    block: &[String],
    day_re: &Regex,
    year_re: &Regex,
    money: &Regex,
    prev_balance: &mut Decimal,
) -> Option<ParsedTransaction> {
    let joined = block.join(" ");
    let dc = day_re.captures(&joined)?;
    let month = month_num(&dc[1])?;
    let day: u32 = dc[2].parse().ok()?;
    let year: i32 = year_re.captures(&joined).and_then(|c| c[1].parse().ok())?;
    let date = NaiveDate::from_ymd_opt(year, month, day)?;

    let monies: Vec<Decimal> = money
        .captures_iter(&joined)
        .filter_map(|c| dec(&c[1]))
        .collect();
    if monies.len() < 2 {
        return None; // not a real ledger row (header/footer/period line)
    }
    let balance = *monies.last().unwrap();
    let amount = balance - *prev_balance;
    *prev_balance = balance;

    // Description = the block text minus the date tokens / amounts / rate.
    let mut desc = joined.clone();
    desc = day_re.replace(&desc, "").to_string();
    desc = year_re.replace_all(&desc, " ").to_string();
    desc = money.replace_all(&desc, "").to_string();
    desc = Regex::new(r"\d+\.\d{2}%")
        .unwrap()
        .replace_all(&desc, "")
        .to_string();
    let description = clean_desc(&desc);
    if description.is_empty() {
        return None;
    }

    let (category, category_detailed) = classify(&description, amount);
    Some(ParsedTransaction {
        date,
        description,
        amount,
        currency: "MXN".into(),
        category,
        category_detailed,
        original_description: None,
        balance_after: Some(balance),
        account_label: None,
        declared_closing_balance: None,
        from_ocr: false,
    })
}

// ───────────────────────── personal layout ─────────────────────────

fn parse_personal(text: &str) -> Result<Vec<ParsedTransaction>> {
    let money = money_re();
    // Full date on a single line: "Apr 23, 2026   <desc>   $… $…".
    let row_re = Regex::new(r"^\s*([A-Z][a-z]{2})\s+(\d{1,2}),\s+(20\d{2})\s+(.*)$").unwrap();
    // Balance-summary product rows carry each pocket's OPENING balance (first
    // money column), which seeds the matching section's running balance.
    let open_re =
        Regex::new(r"^\s*(Mexican Peso Account|Instant Access Savings)\s+\$([\d,]+\.\d{2})")
            .unwrap();
    let ccy = Regex::new(r"\b([A-Z]{3}) Statement\b")
        .unwrap()
        .captures(text)
        .map(|c| c[1].to_string())
        .unwrap_or_else(|| "MXN".into());

    let mut txs: Vec<ParsedTransaction> = Vec::new();
    let mut in_section = false;
    let mut label: Option<String> = None;
    let mut prev_balance = Decimal::ZERO;
    // Opening balances parsed from the most recent month's summary, consumed
    // when the corresponding section opens.
    let mut pending_open_main: Option<Decimal> = None;
    let mut pending_open_savings: Option<Decimal> = None;

    for raw in text.lines() {
        let line = raw.trim_end();
        let trimmed = line.trim();

        // Stash opening balances as we pass the per-month summary.
        if let Some(c) = open_re.captures(line) {
            let open = dec(&c[2]);
            if &c[1] == "Mexican Peso Account" {
                pending_open_main = open;
            } else {
                pending_open_savings = open;
            }
            continue;
        }

        // Section boundaries.
        if trimmed.starts_with("Instant Access Savings transactions from") {
            in_section = true;
            label = Some("Instant Access Savings".into());
            prev_balance = pending_open_savings.unwrap_or(Decimal::ZERO);
            continue;
        }
        if trimmed.starts_with("Account transactions from") {
            in_section = true;
            // Label the peso section too (not None/"primary"): the personal
            // statement bundles two real accounts, and leaving this unlabeled
            // let the import UI silently fold the peso rows into whatever
            // "primary" account the user picked (usually their savings). With
            // BOTH sections labelled, the UI forces an explicit destination
            // for each, keeping the peso current account and the savings
            // pocket separate.
            label = Some("Mexican Peso Account".into());
            prev_balance = pending_open_main.unwrap_or(Decimal::ZERO);
            continue;
        }
        if trimmed.starts_with("Summary of balances")
            || trimmed.starts_with("Balance summary")
            || trimmed.starts_with("Earnings summary")
            || trimmed.starts_with("Revolut Bank, S.A.")
        {
            in_section = false;
            continue;
        }
        if !in_section {
            continue;
        }

        let Some(c) = row_re.captures(line) else {
            continue; // continuation line (From:/Description:/year wrap)
        };
        let month = match month_num(&c[1]) {
            Some(m) => m,
            None => continue,
        };
        let day: u32 = c[2].parse().unwrap_or(0);
        let year: i32 = c[3].parse().unwrap_or(0);
        let Some(date) = NaiveDate::from_ymd_opt(year, month, day) else {
            continue;
        };

        let rest = &c[4];
        let monies: Vec<Decimal> = money
            .captures_iter(rest)
            .filter_map(|m| dec(&m[1]))
            .collect();
        if monies.is_empty() {
            continue;
        }
        let balance = *monies.last().unwrap();
        let amount = balance - prev_balance;
        prev_balance = balance;

        // Description = everything before the first money token.
        let desc_raw = match money.find(rest) {
            Some(m) => &rest[..m.start()],
            None => rest,
        };
        let description = clean_desc(desc_raw);
        if description.is_empty() {
            continue;
        }

        let (category, category_detailed) = classify(&description, amount);
        txs.push(ParsedTransaction {
            date,
            description,
            amount,
            currency: ccy.clone(),
            category,
            category_detailed,
            original_description: None,
            balance_after: Some(balance),
            account_label: label.clone(),
            declared_closing_balance: None,
            from_ocr: false,
        });
    }

    info!("Revolut personal: parsed {} transactions", txs.len());
    Ok(txs)
}
