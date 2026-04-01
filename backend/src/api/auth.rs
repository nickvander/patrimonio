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
        None => return Redirect::to("http://localhost:3000/management?status=error&msg=Coinbase+Client+ID+missing").into_response(),
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
    code: String,
}

/// Handle Coinbase OAuth callback
async fn coinbase_callback(
    State(state): State<AppState>,
    Query(query): Query<CallbackQuery>,
) -> impl IntoResponse {
    let client = reqwest::Client::new();
    let config = &state.config;

    let res = client.post("https://api.coinbase.com/oauth/token")
        .form(&[
            ("grant_type", "authorization_code"),
            ("code", &query.code),
            ("client_id", config.coinbase_client_id.as_ref().unwrap()),
            ("client_secret", config.coinbase_client_secret.as_ref().unwrap()),
            ("redirect_uri", &config.coinbase_redirect_uri),
        ])
        .send()
        .await;

    match res {
        Ok(response) => {
            let tokens: serde_json::Value = response.json().await.unwrap();
            let access_token = tokens["access_token"].as_str().unwrap();
            let refresh_token = tokens["refresh_token"].as_str().unwrap();

            // Encrypt and store in institutions table
            let enc_key = config.encryption_key.as_ref().expect("ENCRYPTION_KEY missing");
            let acc_enc = encryption::encrypt(enc_key, access_token).unwrap();
            let ref_enc = encryption::encrypt(enc_key, refresh_token).unwrap();

            // Create or update institution for Coinbase
            let inst_id = uuid::Uuid::new_v4();
            let _ = sqlx::query(
                r#"
                INSERT INTO institutions (id, name, institution_type, country, integration_type, api_key_enc, api_secret_enc)
                VALUES ($1, 'Coinbase', 'crypto', 'Global', 'coinbase_oauth', $2, $3)
                ON CONFLICT (name) DO UPDATE SET api_key_enc = $2, api_secret_enc = $3
                "#
            )
            .bind(inst_id)
            .bind(acc_enc)
            .bind(ref_enc)
            .execute(&state.db)
            .await;

            // Trigger immediate sync
            let db = state.db.clone();
            let config_clone = config.clone();
            tokio::spawn(async move {
                let _ = crate::services::sync::sync_all_institutions(&db, &config_clone).await;
            });

            // Redirect back to frontend
            Redirect::to("http://localhost:3000/management?status=success").into_response()
        }
        Err(e) => {
            tracing::error!("Coinbase OAuth Error: {}", e);
            Redirect::to("http://localhost:3000/management?status=error").into_response()
        }
    }
}
