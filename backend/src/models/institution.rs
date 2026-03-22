use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::FromRow;
use uuid::Uuid;

#[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
pub struct Institution {
    pub id: Uuid,
    pub name: String,
    pub institution_type: String,
    pub country: String,
    pub integration_type: String,
    pub plaid_item_id: Option<String>,
    pub last_synced_at: Option<DateTime<Utc>>,
    pub sync_status: Option<String>,
    pub created_at: Option<DateTime<Utc>>,
}
