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
            // Optional, not recommended: the live USD/MXN rate the app uses
            // for multi-currency conversion works fine on cached/fallback
            // rates, so an unset key is a non-event — keep it out of the
            // "recommended before production" recap and let the UI hide it
            // when unconfigured (only confirm it when a key IS present).
            severity: "optional".to_string(),
            detail: if config.exchange_rate_api_key.is_some() {
                "Live FX API key configured".to_string()
            } else {
                "Optional — set EXCHANGE_RATE_API_KEY for live rates; cached/fallback rates are used otherwise".to_string()
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
            // Optional, not recommended: without it Plaid falls back to ~4h
            // polling, which is fine for a single-owner self-host. Keep it out
            // of the nag list and hide it when unset (the UI only surfaces
            // unconfigured `optional` checks once they're actually set).
            severity: "optional".to_string(),
            detail: match &config.plaid_webhook_url {
                Some(url) => format!("Configured → {}", url),
                None => "Optional — set PLAID_WEBHOOK_URL for real-time syncs; otherwise Plaid polls every ~4h (see docs/deployment.md)".to_string(),
            },
        },
        SetupCheck {
            // ALLOWED_ORIGINS controls which origins the CORS layer
            // accepts. An empty list (or one missing the frontend's
            // real origin) silently breaks the browser-side login
            // flow on a real deployment — the request never reaches
            // the handler. Surfacing it here turns "the app just
            // doesn't work" into a one-glance diagnosis.
            key: "cors".to_string(),
            label: "CORS allow-list".to_string(),
            configured: !config.allowed_origins.is_empty()
                && config.allowed_origins.iter().any(|o| o == &config.frontend_base_url),
            severity: "required_for_linking".to_string(),
            detail: cors_check_detail(config),
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

/// Human-readable diagnostic for the CORS check. Lists the expected
/// frontend origin + the actual allow-list contents so the operator
/// doesn't have to grep logs to see why the browser is failing the
/// preflight.
fn cors_check_detail(config: &crate::config::AppConfig) -> String {
    let origins_str = if config.allowed_origins.is_empty() {
        "(empty)".to_string()
    } else {
        config.allowed_origins.join(", ")
    };
    if config.allowed_origins.is_empty() {
        format!(
            "ALLOWED_ORIGINS is empty — the browser will fail CORS preflights. \
             Set it to include {} (or whatever origin the frontend is served from).",
            config.frontend_base_url
        )
    } else if !config
        .allowed_origins
        .iter()
        .any(|o| o == &config.frontend_base_url)
    {
        format!(
            "ALLOWED_ORIGINS = [{}] but the frontend is served from {} — \
             add it to the list or the browser will fail CORS preflights.",
            origins_str, config.frontend_base_url
        )
    } else {
        format!("Allow-list: {}", origins_str)
    }
}
