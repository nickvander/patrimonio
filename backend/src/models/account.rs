use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct Account {
    pub id: Uuid,
    pub institution_id: Uuid,
    pub external_id: Option<String>,
    pub name: String,
    pub account_type: String,
    pub currency: String,
    pub current_balance: Option<Decimal>,
    pub available_balance: Option<Decimal>,
    pub credit_limit: Option<Decimal>,
    pub ticker_symbol: Option<String>,
    pub crypto_amount: Option<Decimal>,
    pub coinbase_account_id: Option<String>,
    pub updated_at: Option<DateTime<Utc>>,
}
