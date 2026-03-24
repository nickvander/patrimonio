pub mod nu_mexico;
pub mod nu_mexico_pdf;
pub mod banamex;
pub mod cetes;
pub mod cetes_pdf;

#[cfg(test)]
mod tests;

use crate::models::import::ParsedTransaction;
use anyhow::{Result, anyhow};

pub fn detect_and_parse(file_name: &str, data: &[u8]) -> Result<Vec<ParsedTransaction>> {
    let lower_name = file_name.to_lowercase();
    
    // CSV Parsers
    if lower_name.ends_with(".csv") {
        if lower_name.contains("nu") {
            return nu_mexico::parse_csv(data);
        }
        if lower_name.contains("banamex") {
            return banamex::parse_csv(data);
        }
        if lower_name.contains("cetes") {
            return cetes::parse_csv(data);
        }
    }
    
    // PDF Parsers
    if lower_name.ends_with(".pdf") {
        if lower_name.contains("nu") {
            return nu_mexico_pdf::parse(data);
        }
        if lower_name.contains("cetes") {
            return cetes_pdf::parse(data);
        }
    }
    
    Err(anyhow!("Unsupported file format or institution: {}", file_name))
}
