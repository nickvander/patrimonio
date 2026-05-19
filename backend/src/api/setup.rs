use axum::{extract::State, routing::get, Json, Router};
use serde::Serialize;

use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new().route("/status", get(setup_status))
}

async fn setup_status(State(state): State<AppState>) -> Json<SetupStatus> {
    let config = &state.config;

    let checks = vec![
        SetupCheck {
            key: "plaid".to_string(),
            label: "Plaid account linking".to_string(),
            configured: config.plaid_client_id.is_some() && config.plaid_secret.is_some(),
            severity: "required_for_linking".to_string(),
            detail: if config.plaid_client_id.is_some() && config.plaid_secret.is_some() {
                format!("Configured for {} environment", config.plaid_env)
            } else {
                "Set PLAID_CLIENT_ID and PLAID_SECRET to link US accounts".to_string()
            },
        },
        SetupCheck {
            key: "encryption".to_string(),
            label: "Credential encryption".to_string(),
            configured: config.encryption_key.is_some(),
            severity: "required_for_linking".to_string(),
            detail: if config.encryption_key.is_some() {
                "Configured".to_string()
            } else {
                "Set ENCRYPTION_KEY before storing Plaid, Coinbase, or Bitso credentials".to_string()
            },
        },
        SetupCheck {
            key: "fx".to_string(),
            label: "Exchange rates".to_string(),
            configured: config.exchange_rate_api_key.is_some(),
            severity: "recommended".to_string(),
            detail: if config.exchange_rate_api_key.is_some() {
                "Live FX API key configured".to_string()
            } else {
                "No EXCHANGE_RATE_API_KEY set; app can still use cached/fallback rates".to_string()
            },
        },
        SetupCheck {
            key: "coinbase".to_string(),
            label: "Coinbase OAuth".to_string(),
            configured: config.coinbase_client_id.is_some() && config.coinbase_client_secret.is_some(),
            severity: "optional".to_string(),
            detail: if config.coinbase_client_id.is_some() && config.coinbase_client_secret.is_some() {
                "Configured".to_string()
            } else {
                "Set Coinbase OAuth credentials to enable Coinbase linking".to_string()
            },
        },
        SetupCheck {
            // Surfaced in the Management tab so the user can see whether
            // Plaid push delivery is wired up. Without this URL set Plaid
            // falls back to polling every ~4h, which is the default but
            // not what someone running a real deployment wants.
            key: "plaid_webhook".to_string(),
            label: "Plaid webhook URL".to_string(),
            configured: config.plaid_webhook_url.is_some(),
            severity: "recommended".to_string(),
            detail: match &config.plaid_webhook_url {
                Some(url) => format!("Configured → {}", url),
                None => "Set PLAID_WEBHOOK_URL to a public HTTPS endpoint to enable real-time syncs (see docs/deployment.md)".to_string(),
            },
        },
    ];

    let ready_for_plaid_linking = checks
        .iter()
        .filter(|check| check.severity == "required_for_linking")
        .all(|check| check.configured);

    Json(SetupStatus {
        ready_for_plaid_linking,
        plaid_environment: config.plaid_env.clone(),
        frontend_base_url: config.frontend_base_url.clone(),
        checks,
    })
}

#[derive(Serialize)]
struct SetupStatus {
    ready_for_plaid_linking: bool,
    plaid_environment: String,
    frontend_base_url: String,
    checks: Vec<SetupCheck>,
}

#[derive(Serialize)]
struct SetupCheck {
    key: String,
    label: String,
    configured: bool,
    severity: String,
    detail: String,
}
