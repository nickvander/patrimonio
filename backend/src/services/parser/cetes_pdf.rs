use lopdf::Document;
use crate::models::import::ParsedTransaction;
use anyhow::{Result, anyhow};
use tracing::info;
use regex::Regex;
use chrono::NaiveDate;
use rust_decimal::Decimal;
use std::str::FromStr;

pub fn parse(data: &[u8]) -> Result<Vec<ParsedTransaction>> {
    let doc = Document::load_mem(data).map_err(|e| anyhow!("Failed to load PDF: {}", e))?;
    let mut full_text = String::new();
    
    let pages = doc.get_pages();
    for (page_num, _) in pages.iter() {
        if let Ok(text) = doc.extract_text(&[*page_num]) {
            full_text.push_str(&text);
            full_text.push('\n');
        }
    }
    
    info!("Extracted {} characters from Cetes PDF", full_text.len());
    
    parse_text(&full_text)
}

pub fn parse_text(text: &str) -> Result<Vec<ParsedTransaction>> {
    let mut transactions = Vec::new();
    
    // Pattern for Cetesdirecto Movimientos (approximated):
    // "15/03/2024 COMPRA CETES 28 DIAS $ 1,000.00"
    // We look for: DD/MM/YYYY, Description (lazy), $ (optional), Amount
    // Refined pattern: explicitly handle the optional $ and ensure amount captures correctly
    // We use a more restrictive amount pattern to avoid capturing "28" from "CETES 28 DIAS"
    let re = Regex::new(r"(?P<day>\d{1,2})/(?P<month>\d{1,2})/(?P<year>\d{4})\s+(?P<desc>.+?)\s+(?:[\$]\s*)?(?P<amount>-?\d[\d,.]*\.\d{2})")?;
    
    for cap in re.captures_iter(text) {
        let day = cap.name("day").unwrap().as_str().parse::<u32>().unwrap_or(1);
        let month = cap.name("month").unwrap().as_str().parse::<u32>().unwrap_or(1);
        let year = cap.name("year").unwrap().as_str().parse::<i32>().unwrap_or(2024);
        let desc = cap.name("desc").unwrap().as_str().trim();
        let amount_str = cap.name("amount").unwrap().as_str().replace(",", "");
        
        let date = NaiveDate::from_ymd_opt(year, month, day)
            .unwrap_or_else(|| NaiveDate::from_ymd_opt(year, 1, 1).unwrap());
        
        let amount = Decimal::from_str(&amount_str).unwrap_or_default();
        
        // Skip some noise typical in Cetes PDFs (headers, footers matching the regex)
        if desc.is_empty() || amount.is_zero() || desc.contains("SUBTOTAL") {
            continue;
        }

        transactions.push(ParsedTransaction {
            date,
            description: desc.to_string(),
            amount,
            currency: "MXN".to_string(),
            category: None,
        });
    }
    
    info!("Parsed {} transactions from Cetes PDF", transactions.len());
    
    Ok(transactions)
}
