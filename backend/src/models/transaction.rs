use chrono::{DateTime, NaiveDate, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct Transaction {
    pub id: Uuid,
    pub account_id: Uuid,
    pub external_id: Option<String>,
    pub date: NaiveDate,
    pub description: String,
    pub amount: Decimal,
    pub currency: String,
    pub category: Option<String>,
    pub merchant_name: Option<String>,
    pub pending: Option<bool>,
    pub created_at: Option<DateTime<Utc>>,
}
