use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use sqlx::FromRow;

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct ExchangeRate {
    pub id: i64,
    pub base_currency: String,
    pub target_currency: String,
    pub rate: Decimal,
    pub recorded_at: DateTime<Utc>,
}
