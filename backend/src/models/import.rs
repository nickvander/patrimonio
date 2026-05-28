use serde::{Deserialize, Serialize};
use rust_decimal::Decimal;
use chrono::NaiveDate;

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct ParsedTransaction {
    pub date: NaiveDate,
    pub description: String,
    pub amount: Decimal,
    pub currency: String,
    pub category: Option<String>,
    /// Raw description as the bank/PDF emitted it, BEFORE
    /// `polish_description` stripped generic prefixes / trailing dates.
    /// Saved alongside the polished `description` so the frontend's
    /// `displayLabel` ladder (`user_description → counterparty →
    /// merchant → original_description → description`) can fall back
    /// to the verbatim line when the polished form turns out too
    /// terse for the user. None when polishing made no change.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub original_description: Option<String>,
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
