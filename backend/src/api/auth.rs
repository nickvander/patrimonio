use axum::{
    extract::{Query, State},
    response::{IntoResponse, Redirect},
    routing::get,
    Router,
};
use serde::Deserialize;
use crate::AppState;
use crate::services::encryption;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/coinbase", get(coinbase_authorize))
        .route("/coinbase/callback", get(coinbase_callback))
}

/// Redirect to Coinbase OAuth page
async fn coinbase_authorize(State(state): State<AppState>) -> impl IntoResponse {
    let client_id = match &state.config.coinbase_client_id {
        Some(id) => id,
        None => return frontend_redirect(&state, "error", Some("Coinbase Client ID missing")).into_response(),
    };
    
    let redirect_uri = &state.config.coinbase_redirect_uri;
    // We request wallet:accounts:read to get balances
    let scope = "wallet:accounts:read";
    
    let auth_url = format!(
        "https://www.coinbase.com/oauth/authorize?response_type=code&client_id={}&redirect_uri={}&scope={}",
        client_id, redirect_uri, scope
    );
    
    Redirect::to(&auth_url).into_response()
}

#[derive(Deserialize)]
struct CallbackQuery {
    code: Option<String>,
    error: Option<String>,
}

/// Handle Coinbase OAuth callback
async fn coinbase_callback(
    State(state): State<AppState>,
    Query(query): Query<CallbackQuery>,
) -> impl IntoResponse {
    let client = reqwest::Client::new();
    let config = &state.config;
    let code = match query.code {
        Some(code) => code,
        None => {
            let detail = query.error.as_deref().unwrap_or("Coinbase authorization failed");
            return frontend_redirect(&state, "error", Some(detail)).into_response();
        }
    };
    let client_id = match config.coinbase_client_id.as_ref() {
        Some(value) => value,
        None => return frontend_redirect(&state, "error", Some("Coinbase Client ID missing")).into_response(),
    };
    let client_secret = match config.coinbase_client_secret.as_ref() {
        Some(value) => value,
        None => return frontend_redirect(&state, "error", Some("Coinbase Client Secret missing")).into_response(),
    };
    let enc_key = match config.encryption_key.as_ref() {
        Some(value) => value,
        None => return frontend_redirect(&state, "error", Some("Encryption key missing")).into_response(),
    };

    let res = client.post("https://api.coinbase.com/oauth/token")
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", &code),
            ("client_id", client_id),
            ("client_secret", client_secret),
            ("redirect_uri", &config.coinbase_redirect_uri),
        ])
        .send()
        .await;

    match res {
        Ok(response) => {
            if !response.status().is_success() {
                let status = response.status();
                let body = response.text().await.unwrap_or_default();
                tracing::error!("Coinbase OAuth returned {}: {}", status, body);
                return frontend_redirect(&state, "error", Some("Coinbase token exchange failed")).into_response();
            }

            let tokens: serde_json::Value = match response.json().await {
                Ok(tokens) => tokens,
                Err(e) => {
                    tracing::error!("Invalid Coinbase OAuth response: {}", e);
                    return frontend_redirect(&state, "error", Some("Invalid Coinbase response")).into_response();
                }
            };
            let access_token = match tokens["access_token"].as_str() {
                Some(token) => token,
                None => {
                    tracing::error!("Coinbase OAuth response missing access_token: {:?}", tokens);
                    return frontend_redirect(&state, "error", Some("Coinbase token missing")).into_response();
                }
            };
            let refresh_token = match tokens["refresh_token"].as_str() {
                Some(token) => token,
                None => {
                    tracing::error!("Coinbase OAuth response missing refresh_token: {:?}", tokens);
                    return frontend_redirect(&state, "error", Some("Coinbase refresh token missing")).into_response();
                }
            };

            // Encrypt and store in institutions table
            let acc_enc = match encryption::encrypt(enc_key, access_token) {
                Ok(value) => value,
                Err(e) => {
                    tracing::error!("Failed to encrypt Coinbase access token: {}", e);
                    return frontend_redirect(&state, "error", Some("Token encryption failed")).into_response();
                }
            };
            let ref_enc = match encryption::encrypt(enc_key, refresh_token) {
                Ok(value) => value,
                Err(e) => {
                    tracing::error!("Failed to encrypt Coinbase refresh token: {}", e);
                    return frontend_redirect(&state, "error", Some("Token encryption failed")).into_response();
                }
            };

            // Create or update institution for Coinbase
            let update = sqlx::query(
                "UPDATE institutions SET api_key_enc = $1, api_secret_enc = $2 WHERE name = 'Coinbase' AND integration_type = 'coinbase_oauth'"
            )
            .bind(&acc_enc)
            .bind(&ref_enc)
            .execute(&state.db)
            .await;

            match update {
                Ok(result) if result.rows_affected() > 0 => {}
                Ok(_) => {
                    if let Err(e) = sqlx::query(
                        r#"
                        INSERT INTO institutions (id, name, institution_type, country, integration_type, api_key_enc, api_secret_enc)
                        VALUES ($1, 'Coinbase', 'crypto', 'Global', 'coinbase_oauth', $2, $3)
                        "#
                    )
                    .bind(uuid::Uuid::new_v4())
                    .bind(&acc_enc)
                    .bind(&ref_enc)
                    .execute(&state.db)
                    .await
                    {
                        tracing::error!("Failed to save Coinbase OAuth institution: {}", e);
                        return frontend_redirect(&state, "error", Some("Failed to save Coinbase account")).into_response();
                    }
                }
                Err(e) => {
                    tracing::error!("Failed to update Coinbase OAuth institution: {}", e);
                    return frontend_redirect(&state, "error", Some("Failed to save Coinbase account")).into_response();
                }
            }

            // Trigger immediate sync
            let db = state.db.clone();
            let config_clone = config.clone();
            tokio::spawn(async move {
                let _ = crate::services::sync::sync_all_institutions(&db, &config_clone).await;
            });

            // Redirect back to frontend
            frontend_redirect(&state, "success", None).into_response()
        }
        Err(e) => {
            tracing::error!("Coinbase OAuth Error: {}", e);
            frontend_redirect(&state, "error", Some("Coinbase token exchange failed")).into_response()
        }
    }
}

fn frontend_redirect(state: &AppState, status: &str, msg: Option<&str>) -> Redirect {
    let mut url = format!("{}/?status={}", state.config.frontend_base_url.trim_end_matches('/'), status);
    if let Some(msg) = msg {
        url.push_str("&msg=");
        url.push_str(&query_escape(msg));
    }
    Redirect::to(&url)
}

fn query_escape(value: &str) -> String {
    value
        .chars()
        .flat_map(|ch| match ch {
            'A'..='Z' | 'a'..='z' | '0'..='9' | '-' | '_' | '.' | '~' => vec![ch],
            ' ' => vec!['+'],
            _ => format!("%{:02X}", ch as u32).chars().collect(),
        })
        .collect()
}
