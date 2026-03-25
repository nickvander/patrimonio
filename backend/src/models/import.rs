use serde::{Deserialize, Serialize};
use rust_decimal::Decimal;
use chrono::NaiveDate;

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ParsedTransaction {
    pub date: NaiveDate,
    pub description: String,
    pub amount: Decimal,
    pub currency: String,
    pub category: Option<String>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ImportResult {
    pub institution_id: String,
    pub account_id: Option<String>,
    pub transactions: Vec<ParsedTransaction>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ConfirmImportRequest {
    pub account_id: uuid::Uuid,
    pub transactions: Vec<ParsedTransaction>,
}
