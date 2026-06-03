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
    /// Running account balance AFTER this transaction (the statement's
    /// SALDO column), when the parser tracks it. The import sets the
    /// account's current balance from the latest-dated row's value —
    /// idempotent on re-import, unlike summing amounts. None for parsers
    /// that don't expose a running balance (CSV, etc.).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub balance_after: Option<Decimal>,
    /// The statement account-section this row belongs to, when a single
    /// PDF bundles more than one account (Banamex bundles a primary
    /// MiCuenta + a Pagaré/Ahorro/Inversión sub-account). `None` for the
    /// primary section and for single-account statements — so the common
    /// case is unchanged. When `Some`, the import flow offers to route that
    /// section to its own account so its balance isn't lost.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub account_label: Option<String>,
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
