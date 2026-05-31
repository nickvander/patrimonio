use axum::{
    extract::{Extension, Query, State},
    response::{IntoResponse, Redirect},
    routing::get,
    Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use rand::{rngs::OsRng, RngCore};
use redis::AsyncCommands;
use serde::Deserialize;
use crate::AppState;
use crate::api::session::AuthContext;
use crate::services::encryption;

const OAUTH_STATE_PREFIX: &str = "oauth:coinbase:";
const OAUTH_STATE_TTL_SECONDS: u64 = 600; // 10 min — covers the full Coinbase login + 2FA dance.

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/coinbase", get(coinbase_authorize))
        .route("/coinbase/callback", get(coinbase_callback))
}

/// Redirect to Coinbase OAuth page.
///
/// Generates a one-time `state` token, stores it in Redis bound to the
/// authenticated user, and includes it in the auth URL. The callback
/// must echo it back exactly — without this an attacker can have their
/// own Coinbase `code` redeemed against a victim's session (CSRF on
/// account binding).
async fn coinbase_authorize(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> impl IntoResponse {
    let client_id = match &state.config.coinbase_client_id {
        Some(id) => id,
        None => return frontend_redirect(&state, "error", Some("Coinbase Client ID missing")).into_response(),
    };

    let mut state_bytes = [0u8; 32];
    OsRng.fill_bytes(&mut state_bytes);
    let oauth_state = URL_SAFE_NO_PAD.encode(state_bytes);

    // Store {state -> user_id} in Redis. The callback reads and
    // immediately deletes it (DEL on consume — replay-proof).
    if let Ok(mut conn) = state.redis.get_multiplexed_async_connection().await {
        let key = format!("{OAUTH_STATE_PREFIX}{oauth_state}");
        let _: redis::RedisResult<()> = conn
            .set_ex(&key, ctx.user_id.to_string(), OAUTH_STATE_TTL_SECONDS)
            .await;
    } else {
        tracing::error!("Redis unavailable; refusing to start Coinbase OAuth without CSRF state");
        return frontend_redirect(&state, "error", Some("Auth temporarily unavailable")).into_response();
    }

    let redirect_uri = &state.config.coinbase_redirect_uri;
    // We request wallet:accounts:read to get balances
    let scope = "wallet:accounts:read";

    let auth_url = format!(
        "https://www.coinbase.com/oauth/authorize?response_type=code&client_id={}&redirect_uri={}&scope={}&state={}",
        client_id,
        query_escape(redirect_uri),
        query_escape(scope),
        query_escape(&oauth_state),
    );

    Redirect::to(&auth_url).into_response()
}

#[derive(Deserialize)]
struct CallbackQuery {
    code: Option<String>,
    state: Option<String>,
    error: Option<String>,
}

/// Handle Coinbase OAuth callback.
///
/// Verifies the `state` parameter against the per-user value stored at
/// /coinbase time. A missing, unknown, or stale state aborts the flow
/// before any token exchange — anti-CSRF for account-binding.
async fn coinbase_callback(
    State(state): State<AppState>,
    Query(query): Query<CallbackQuery>,
) -> impl IntoResponse {
    let client = reqwest::Client::new();
    let config = &state.config;

    // 1. Validate the state token. Required for every callback —
    //    Coinbase always echoes whatever we sent in /authorize.
    let provided_state = match query.state.as_deref() {
        Some(s) if !s.is_empty() => s,
        _ => return frontend_redirect(&state, "error", Some("Missing OAuth state")).into_response(),
    };
    let key = format!("{OAUTH_STATE_PREFIX}{provided_state}");
    let bound_user_id = match state.redis.get_multiplexed_async_connection().await {
        Ok(mut conn) => {
            let stored: Option<String> = conn.get(&key).await.unwrap_or(None);
            // Consume on read — replay protection.
            let _: redis::RedisResult<()> = conn.del(&key).await;
            stored
        }
        Err(e) => {
            tracing::error!("Redis lookup for OAuth state failed: {}", e);
            return frontend_redirect(&state, "error", Some("Auth temporarily unavailable")).into_response();
        }
    };
    let Some(bound_user_id) = bound_user_id else {
        return frontend_redirect(&state, "error", Some("Invalid or expired OAuth state")).into_response();
    };
    let bound_user_uuid = match uuid::Uuid::parse_str(&bound_user_id) {
        Ok(u) => u,
        Err(e) => {
            tracing::error!("OAuth state had non-UUID user_id: {}", e);
            return frontend_redirect(&state, "error", Some("Invalid OAuth state")).into_response();
        }
    };

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
            // SECURITY: never log the `tokens` object — even when one field is
            // missing the rest are live credentials. Log only the key names so
            // the failure is still diagnosable without writing a usable token
            // to stdout / log aggregation.
            let token_keys = || {
                tokens
                    .as_object()
                    .map(|o| o.keys().cloned().collect::<Vec<_>>())
                    .unwrap_or_default()
            };
            let access_token = match tokens["access_token"].as_str() {
                Some(token) => token,
                None => {
                    tracing::error!(
                        "Coinbase OAuth response missing access_token (keys: {:?})",
                        token_keys()
                    );
                    return frontend_redirect(&state, "error", Some("Coinbase token missing")).into_response();
                }
            };
            let refresh_token = match tokens["refresh_token"].as_str() {
                Some(token) => token,
                None => {
                    tracing::error!(
                        "Coinbase OAuth response missing refresh_token (keys: {:?})",
                        token_keys()
                    );
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

            // Create or update institution for Coinbase, scoped to the
            // user the OAuth state was bound to. Without the per-user
            // predicate two users linking Coinbase would race for the
            // same row, and one would silently overwrite the other's
            // tokens.
            let update = sqlx::query(
                "UPDATE institutions SET api_key_enc = $1, api_secret_enc = $2 WHERE name = 'Coinbase' AND integration_type = 'coinbase_oauth' AND user_id = $3"
            )
            .bind(&acc_enc)
            .bind(&ref_enc)
            .bind(bound_user_uuid)
            .execute(&state.db)
            .await;

            match update {
                Ok(result) if result.rows_affected() > 0 => {}
                Ok(_) => {
                    if let Err(e) = sqlx::query(
                        r#"
                        INSERT INTO institutions (id, name, institution_type, country, integration_type, api_key_enc, api_secret_enc, user_id)
                        VALUES ($1, 'Coinbase', 'crypto', 'Global', 'coinbase_oauth', $2, $3, $4)
                        "#
                    )
                    .bind(uuid::Uuid::new_v4())
                    .bind(&acc_enc)
                    .bind(&ref_enc)
                    .bind(bound_user_uuid)
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
