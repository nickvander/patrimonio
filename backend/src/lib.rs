pub mod config;
pub mod api;
pub mod db;
pub mod models;
pub mod panic_guard;
pub mod services;

use std::sync::Arc;
use config::AppConfig;

#[derive(Clone)]
pub struct AppState {
    pub db: sqlx::PgPool,
    pub redis: redis::Client,
    pub config: Arc<AppConfig>,
    /// WebAuthn relying-party config. Built once at startup from
    /// `frontend_base_url`; passkey register/login handlers consume it.
    pub webauthn: Arc<webauthn_rs::Webauthn>,
    /// Real-time event hub. Per-user broadcast channels held in a
    /// shared map so any handler (sync, FX detector, Plaid webhook,
    /// manual edits) can publish "data invalidated" events to every
    /// websocket the user has open. See `services::realtime`.
    pub realtime: services::realtime::Realtime,
}
