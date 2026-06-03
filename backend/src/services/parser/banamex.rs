use crate::models::import::ParsedTransaction;
use anyhow::{Result, anyhow};
use csv::ReaderBuilder;
use rust_decimal::Decimal;
use chrono::NaiveDate;
use std::io::Cursor;

pub fn parse_csv(data: &[u8]) -> Result<Vec<ParsedTransaction>> {
    let mut rdr = ReaderBuilder::new()
        .has_headers(true)
        .from_reader(Cursor::new(data));
    
    let mut transactions = Vec::new();
    
    for result in rdr.records() {
        let record = result.map_err(|e| anyhow!("CSV parse error: {}", e))?;
        
        // Banamex format (Mock): Date, Concept, Amount
        // 15/03/2024, COMPRA OXXO, -50.00
        let date_str = record.get(0).ok_or_else(|| anyhow!("Missing date"))?.trim();
        let description = record.get(1).ok_or_else(|| anyhow!("Missing concept"))?.trim().to_string();
        let amount_str = record.get(2).ok_or_else(|| anyhow!("Missing amount"))?.trim();
        
        let date = NaiveDate::parse_from_str(date_str, "%d/%m/%Y")
            .or_else(|_| NaiveDate::parse_from_str(date_str, "%Y-%m-%d"))
            .map_err(|_| anyhow!("Invalid date format: {}", date_str))?;
            
        let amount = amount_str.parse::<Decimal>()
            .map_err(|_| anyhow!("Invalid amount: {}", amount_str))?;
            
        transactions.push(ParsedTransaction {
            date,
            description,
            amount,
            currency: "MXN".to_string(),
            category: None,
            original_description: None,
            balance_after: None,
            account_label: None,
        });
    }
    
    Ok(transactions)
}
