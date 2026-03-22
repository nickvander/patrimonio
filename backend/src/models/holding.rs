use chrono::{DateTime, Utc};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct Holding {
    pub id: Uuid,
    pub account_id: Uuid,
    pub symbol: String,
    pub name: String,
    pub quantity: Option<Decimal>,
    pub price: Option<Decimal>,
    pub value: Option<Decimal>,
    pub cost_basis: Option<Decimal>,
    pub currency: String,
    pub holding_type: Option<String>,
    pub updated_at: Option<DateTime<Utc>>,
}
