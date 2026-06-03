use lopdf::Document;
use crate::models::import::ParsedTransaction;
use anyhow::{Result, anyhow};
use tracing::{info, debug};
use regex::Regex;
use chrono::{Datelike, NaiveDate};
use rust_decimal::Decimal;
use std::str::FromStr;

pub fn parse(data: &[u8]) -> Result<Vec<ParsedTransaction>> {
    let doc = Document::load_mem(data).map_err(|e| anyhow!("Failed to load PDF: {}", e))?;
    let mut full_text = String::new();
    
    // Extract text from all pages
    let pages = doc.get_pages();
    for (page_num, _) in pages.iter() {
        if let Ok(text) = doc.extract_text(&[*page_num]) {
            full_text.push_str(&text);
            full_text.push('\n');
        }
    }
    
    info!("Extracted {} characters from Nu PDF", full_text.len());
    
    parse_text(&full_text)
}

pub fn parse_text(text: &str) -> Result<Vec<ParsedTransaction>> {
    let mut transactions = Vec::new();
    
    // Improved pattern for Nu Mexico:
    // Supports: "15 MAR Uber Mexico $ 150.50", "15 mar Pago de tarjeta 5,000.00", etc.
    let re = Regex::new(r"(?P<day>\d{1,2})\s+(?P<month>[a-zA-Z]{3})\s+(?P<desc>.+?)\s+[\$]?\s*(?P<amount>-?\d[\d,.]*\.\d{2})")?;
    
    let current_year = chrono::Utc::now().year();

    for cap in re.captures_iter(text) {
        let day_str = cap.name("day").unwrap().as_str();
        let month_str = cap.name("month").unwrap().as_str();
        let desc = cap.name("desc").unwrap().as_str().trim();
        let amount_str = cap.name("amount").unwrap().as_str().replace(",", "");
        
        let month_num = match month_str.to_uppercase().as_str() {
            "ENE" => 1, "FEB" => 2, "MAR" => 3, "ABR" => 4,
            "MAY" => 5, "JUN" => 6, "JUL" => 7, "AGO" => 8,
            "SEP" => 9, "OCT" => 10, "NOV" => 11, "DIC" => 12,
            _ => {
                debug!("Skipping match with unknown month: {}", month_str);
                continue;
            }
        };
        
        let day_num = day_str.parse::<u32>().unwrap_or(1);
        let date = NaiveDate::from_ymd_opt(current_year, month_num, day_num)
            .unwrap_or_else(|| NaiveDate::from_ymd_opt(current_year, 1, 1).unwrap());
        
        let amount = Decimal::from_str(&amount_str).unwrap_or_default();
        
        // Nu Mexico specific: often positive values for purchases, but we should treat them as negative
        // if they are obviously spendings. However, simplest is to follow the PDF's lead.
        // If the amount doesn't have a sign, but the description looks like spending (not "ABONO" or "TRANSFERENCIA"),
        // we could negate it, but usually Nu PDF uses "-" for expenses.
        
        transactions.push(ParsedTransaction {
            date,
            description: desc.to_string(),
            amount,
            currency: "MXN".to_string(),
            category: None,
            original_description: None,
            balance_after: None,
            account_label: None,
        });
    }
    
    info!("Parsed {} transactions from Nu PDF", transactions.len());
    
    if transactions.is_empty() {
        let snippet: String = text.chars().take(500).collect();
        info!("No transactions found in Nu PDF. Extraction snippet: \n---\n{}\n---", snippet);
    }
    
    Ok(transactions)
}
