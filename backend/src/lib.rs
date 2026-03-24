pub mod config;
pub mod api;
pub mod db;
pub mod models;
pub mod services;

use std::sync::Arc;
use config::AppConfig;

#[derive(Clone)]
pub struct AppState {
    pub db: sqlx::PgPool,
    pub redis: redis::Client,
    pub config: Arc<AppConfig>,
}
