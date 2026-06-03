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
    
    let pages = doc.get_pages();
    let mut page_keys: Vec<_> = pages.keys().collect();
    page_keys.sort();
    
    for page_num in &page_keys {
        if let Ok(text) = doc.extract_text(&[**page_num]) {
            full_text.push_str(&text);
            full_text.push('\n');
        }
    }
    
    info!("Extracted {} characters from Banamex PDF ({} pages)", full_text.len(), page_keys.len());
    
    // Check if this might be a browser printout instead of an official statement
    if full_text.contains("FIREFOX") && full_text.contains("ABOUT:BLANK") {
        return Err(anyhow!("This appears to be a web browser printout. Please download the official PDF statement from your bank."));
    }
    
    parse_text(&full_text)
}

/// Convert month string (already uppercase) to month number
fn parse_month(s: &str) -> Option<u32> {
    match s {
        "ENE" | "ENERO" => Some(1),
        "FEB" | "FEBRERO" => Some(2),
        "MAR" | "MARZO" => Some(3),
        "ABR" | "ABRIL" => Some(4),
        "MAY" | "MAYO" => Some(5),
        "JUN" | "JUNIO" => Some(6),
        "JUL" | "JULIO" => Some(7),
        "AGO" | "AGOSTO" => Some(8),
        "SEP" | "SEPT" | "SEPTIEMBRE" => Some(9),
        "OCT" | "OCTUBRE" => Some(10),
        "NOV" | "NOVIEMBRE" => Some(11),
        "DIC" | "DICIEMBRE" => Some(12),
        _ => None,
    }
}

pub fn parse_text(text: &str) -> Result<Vec<ParsedTransaction>> {
    let upper_text = text.to_uppercase();
    
    // Find section start
    let detail_headers = [
        "DETALLE DE MOVIMIENTOS", "DETALLE DE OPERACIONES", 
        "DETALLE DE CUENTA", "MOVIMIENTOS DEL PERIODO", "MOVIMIENTOS DEL MES",
    ];
    
    let mut target_text = upper_text.as_str();
    for header in detail_headers {
        if let Some(pos) = upper_text.find(header) {
            info!("Found section header '{}' at pos {}", header, pos);
            target_text = &upper_text[pos..];
            break;
        }
    }

    // The lopdf extraction puts each field on its own line:
    //   25
    //   ENE
    //   PAGO RECIBIDO DE BBVA BANCOMER
    //   POR ORDEN DE ALBERTO GERARDO
    //   ...
    //   21,993.39
    //
    // Strategy: Collect lines into "records" starting with a day+month pair.
    // A new record starts when we see a line that's just 1-2 digits (the day)
    // AND the next line is a valid month name.
    
    // Filter out the Spanish "DE" connector that some Banamex
    // statements use between day and month ("23 DE ENERO"). When
    // lopdf splits fields onto their own lines this appears as a
    // standalone line between "23" and "ENERO" and breaks our
    // day-then-month record detection. Stripping it is safe — "DE"
    // never appears as a real transaction description on its own.
    let lines: Vec<&str> = target_text
        .lines()
        .map(|l| l.trim())
        .filter(|l| !l.eq_ignore_ascii_case("DE"))
        .collect();
    let day_re = Regex::new(r"^\d{1,2}$")?;
    // The `.NN` cents block is optional — real Banamex statements
    // routinely omit decimals for round amounts ($4,000 instead of
    // $4,000.00). The parser still normalizes both into the same
    // Decimal downstream.
    let amount_re = Regex::new(r"^[\$]?\s*(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)$")?;
    
    // First pass: identify record boundaries (indices where a new record starts)
    let mut record_starts: Vec<(usize, u32, u32)> = Vec::new(); // (line_idx, day, month)
    
    for i in 0..lines.len().saturating_sub(1) {
        let line = lines[i];
        let next_line = lines[i + 1];
        
        if day_re.is_match(line) {
            if let Some(month_num) = parse_month(next_line) {
                let day: u32 = line.parse().unwrap_or(1);
                record_starts.push((i, day, month_num));
            }
        }
    }
    
    info!("Found {} potential transaction records", record_starts.len());
    
    // Extract year from header text (e.g., "PERÍODO DEL ... AL ... DEL 2025")
    let mut current_year = chrono::Utc::now().year();
    let year_re = Regex::new(r"(20\d{2})").unwrap();
    // Look in the first 1000 characters for the year to avoid matching random amounts
    if let Some(cap) = year_re.captures(&upper_text[..std::cmp::min(1000, upper_text.len())]) {
        if let Ok(y) = cap[1].parse::<i32>() {
            current_year = y;
            info!("Extracted year {} from statement header", current_year);
        }
    }
    
    let mut transactions = Vec::new();
    
    let blacklist = [
        "SALDO ANTERIOR", "SALDO ACTUAL", "TOTAL DE", "RESUMEN", 
        "SALDO AL", "GAT NOMINAL", "GAT REAL", "CANTIDADES EXPRESADAS",
        "SALDO FINAL", "SALDO PROMEDIO",
    ];

    let mut previous_saldo: Option<Decimal> = None;

    for (idx, &(start, day, month)) in record_starts.iter().enumerate() {
        let end = if idx + 1 < record_starts.len() {
            record_starts[idx + 1].0
        } else {
            lines.len()
        };
        
        let record_lines = &lines[(start + 2)..end];
        
        let mut desc_parts: Vec<&str> = Vec::new();
        let mut amounts: Vec<Decimal> = Vec::new();
        
        for &line in record_lines {
            if line.is_empty() { continue; }

            let cleaned = line.replace("$", "").trim().to_string();
            // A line that was just "$" (the lopdf extractor often
            // emits the currency marker alone) collapses to empty
            // here and would otherwise pollute the description.
            if cleaned.is_empty() { continue; }
            if let Some(cap) = amount_re.captures(&format!("${}", cleaned)) {
                let amount_str = cap[1].replace(",", "");
                if let Ok(amt) = Decimal::from_str(&amount_str) {
                    amounts.push(amt);
                    continue;
                }
            }
            let plain_amount_re = Regex::new(r"^(\d{1,3}(?:,\d{3})*(?:\.\d{2})?)$").unwrap();
            if let Some(cap) = plain_amount_re.captures(&cleaned) {
                let amount_str = cap[1].replace(",", "");
                if let Ok(amt) = Decimal::from_str(&amount_str) {
                    amounts.push(amt);
                    continue;
                }
            }
            
            if line.starts_with("CAJA") || line.starts_with("HORA") 
                || line.starts_with("SUC") || line.starts_with("AUT")
                || line.contains("AUT ") && line.contains("HORA")
            {
                continue;
            }
            
            desc_parts.push(line);
        }
        
        let desc = desc_parts.join(" ");
        if desc.is_empty() { continue; }
        
        if blacklist.iter().any(|&k| desc.contains(k)) {
            debug!("Skipping blacklisted: '{}'", desc);
            continue;
        }
        
        if amounts.is_empty() { continue; }
        
        let transaction_amount = amounts[0].abs();
        
        let date = NaiveDate::from_ymd_opt(current_year, month, day)
            .unwrap_or_else(|| NaiveDate::from_ymd_opt(current_year, 1, 1).unwrap());
        
        let spending = ["COMPRA", "RETIRO", "PAGO", "COMISION", "CARGO", "IVA", "TRASPASO"];
        let income = ["DEPOSITO", "ABONO", "TRANSFERENCIA", "INTERESES", "DEVOLUCION", "NOMINA", "RECIBIDO", "SUELDO"];
        
        let is_spending = spending.iter().any(|k| desc.contains(k));
        let is_income = income.iter().any(|k| desc.contains(k));
        
        let mut determined_sign = false;
        let mut amount = transaction_amount;

        // Use saldo to mathematically prove if money entered or left the account
        if amounts.len() >= 2 {
            let current_saldo = amounts.last().unwrap();
            if let Some(prev) = previous_saldo {
                if *current_saldo < prev {
                    amount = -transaction_amount;
                    determined_sign = true;
                } else if *current_saldo > prev {
                    amount = transaction_amount;
                    determined_sign = true;
                }
            }
            previous_saldo = Some(*current_saldo);
        }

        if !determined_sign {
            if is_income && !is_spending {
                amount = transaction_amount;
            } else if is_spending && !is_income {
                amount = -transaction_amount;
            } else {
                // If totally unknown, default to spending since most lines on statements are unmarked purchases
                amount = -transaction_amount;
            }
        }
        
        debug!("TX: {}/{} '{}' = {} ({} amounts found)", day, month, desc, amount, amounts.len());
        
        transactions.push(ParsedTransaction {
            date,
            description: desc,
            amount,
            currency: "MXN".to_string(),
            category: None,
            original_description: None,
            balance_after: None,
            account_label: None,
        });
    }
    
    info!("Parsed {} transactions from Banamex PDF", transactions.len());
    
    if transactions.is_empty() {
        let snippet: String = target_text.lines().take(30).collect::<Vec<_>>().join("\n");
        info!("No transactions found. First 30 lines of section:\n---\n{}\n---", snippet);
    }
    
    Ok(transactions)
}
