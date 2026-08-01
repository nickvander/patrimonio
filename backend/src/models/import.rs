use chrono::NaiveDate;
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};

#[derive(Debug, Serialize, Deserialize, Clone, Default)]
pub struct ParsedTransaction {
    pub date: NaiveDate,
    pub description: String,
    pub amount: Decimal,
    pub currency: String,
    pub category: Option<String>,
    /// The Plaid-style DETAILED category (`category_detailed` column) when the
    /// parser can pin a row to a finer taxonomy than the PFC primary
    /// `category`. The cetesdirecto parsers set this to
    /// `INCOME_INTEREST_EARNED` for yield credits (so the tax summary itemizes
    /// CETES interest as interest income) and `TAX_ISR_WITHHELD` for ISR
    /// retentions (so the summary can total tax withheld). `#[serde(default)]`
    /// keeps the preview→confirm round-trip backward-compatible: an older
    /// preview that lacks the field still deserializes (→ None), and a present
    /// value survives the round-trip because the confirm handler deserializes
    /// the flattened `ParsedTransaction`. None for parsers/rows with no detail.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub category_detailed: Option<String>,
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
    /// True when this row's text came from OCR (a scanned / photographed /
    /// browser-printed statement) rather than an extractable text layer. OCR
    /// can misread an amount or date, so the preview flags these rows for the
    /// user to eyeball before confirming. Transient (not persisted) — a
    /// review hint, not stored data.
    #[serde(default)]
    pub from_ocr: bool,
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::str::FromStr;

    fn sample(detail: Option<&str>) -> ParsedTransaction {
        ParsedTransaction {
            date: NaiveDate::from_ymd_opt(2026, 6, 1).unwrap(),
            description: "PREMIO CETES".to_string(),
            amount: Decimal::from_str("2000.00").unwrap(),
            currency: "MXN".to_string(),
            category: Some("INCOME".to_string()),
            category_detailed: detail.map(|s| s.to_string()),
            ..Default::default()
        }
    }

    #[test]
    fn category_detailed_survives_preview_confirm_roundtrip() {
        // The preview serializes a row; the Flutter client passes the row map
        // back through to confirm, which deserializes the flattened
        // ParsedTransaction. A present detail must round-trip intact.
        let tx = sample(Some("INCOME_INTEREST_EARNED"));
        let json = serde_json::to_string(&tx).unwrap();
        assert!(json.contains("INCOME_INTEREST_EARNED"));
        let back: ParsedTransaction = serde_json::from_str(&json).unwrap();
        assert_eq!(
            back.category_detailed.as_deref(),
            Some("INCOME_INTEREST_EARNED")
        );
    }

    #[test]
    fn missing_category_detailed_deserializes_to_none() {
        // Backward-compat: an OLD preview JSON without the field (older client)
        // still deserializes — the field defaults to None rather than erroring.
        let legacy = r#"{"date":"2026-06-01","description":"X","amount":"1.00","currency":"MXN","category":null}"#;
        let back: ParsedTransaction = serde_json::from_str(legacy).unwrap();
        assert!(back.category_detailed.is_none());
    }

    #[test]
    fn none_category_detailed_is_skipped_in_json() {
        // skip_serializing_if keeps the wire payload lean and unchanged for the
        // common (no-detail) case — old clients see the same shape they did.
        let tx = sample(None);
        let json = serde_json::to_string(&tx).unwrap();
        assert!(!json.contains("category_detailed"), "json: {json}");
    }
}
