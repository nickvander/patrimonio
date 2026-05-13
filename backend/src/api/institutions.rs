use axum::{
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post, delete},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;

use crate::AppState;
use crate::services::encryption;
use tracing::{info, error};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_institutions).post(create_institution))
        .route("/sync", post(trigger_sync))
        .route("/link-token", post(create_link_token))
        .route("/reconnect-token/{id}", post(create_reconnect_token))
        .route("/{id}", delete(delete_institution))
        .route("/exchange-token", post(exchange_public_token))
        .route("/crypto", post(link_crypto_institution))
        .route("/webhook", post(plaid_webhook))
}

/// Manually trigger a sync for all institutions
async fn trigger_sync(State(state): State<AppState>) -> axum::response::Response {
    let config = state.config.clone();
    let db = state.db.clone();
    if let Err(e) = crate::services::sync::sync_all_institutions(&db, &config).await {
        tracing::error!("Manual Plaid sync failed: {}", e);
        return (axum::http::StatusCode::INTERNAL_SERVER_ERROR, axum::response::Json(serde_json::json!({
            "error": "Sync failed",
            "details": e.to_string()
        }))).into_response();
    }
    Json(serde_json::json!({"status": "ok"})).into_response()
}

/// List all linked institutions
async fn list_institutions(State(state): State<AppState>) -> Json<Vec<InstitutionResponse>> {
    let rows = sqlx::query(
        r#"
        SELECT id, name, institution_type, country, integration_type,
               last_synced_at, sync_status, last_sync_error, created_at
        FROM institutions
        ORDER BY name
        "#
    )
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let institutions = rows.iter().map(|row| {
        InstitutionResponse {
            id: row.get::<uuid::Uuid, _>("id").to_string(),
            name: row.get("name"),
            institution_type: row.get("institution_type"),
            country: row.get("country"),
            integration_type: row.get("integration_type"),
            last_synced_at: row.try_get::<chrono::DateTime<chrono::Utc>, _>("last_synced_at")
                .ok().map(|d| d.to_rfc3339()),
            sync_status: row.try_get::<String, _>("sync_status")
                .unwrap_or_else(|_| "pending".to_string()),
            last_sync_error: row.try_get("last_sync_error").ok(),
            created_at: row.try_get::<chrono::DateTime<chrono::Utc>, _>("created_at")
                .ok().map(|d| d.to_rfc3339()).unwrap_or_default(),
        }
    }).collect();

    Json(institutions)
}

/// Manually create an institution (for CSV-imported / Mexican accounts)
async fn create_institution(
    State(state): State<AppState>,
    Json(req): Json<CreateInstitutionRequest>,
) -> Response {
    let row = match sqlx::query(
        r#"
        INSERT INTO institutions (name, institution_type, country, integration_type)
        VALUES ($1, $2, $3, $4)
        RETURNING id, name, institution_type, country, integration_type,
                  last_synced_at, sync_status, created_at
        "#
    )
    .bind(&req.name)
    .bind(&req.institution_type)
    .bind(&req.country)
    .bind(&req.integration_type)
    .fetch_one(&state.db)
    .await
    {
        Ok(row) => row,
        Err(e) => {
            tracing::error!("Failed to create institution: {}", e);
            return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Failed to create institution", None);
        }
    };

    Json(InstitutionResponse {
        id: row.get::<uuid::Uuid, _>("id").to_string(),
        name: row.get("name"),
        institution_type: row.get("institution_type"),
        country: row.get("country"),
        integration_type: row.get("integration_type"),
        last_synced_at: row.try_get::<chrono::DateTime<chrono::Utc>, _>("last_synced_at")
            .ok().map(|d| d.to_rfc3339()),
        sync_status: row.try_get::<String, _>("sync_status")
            .unwrap_or_else(|_| "pending".to_string()),
        last_sync_error: None,
        created_at: row.try_get::<chrono::DateTime<chrono::Utc>, _>("created_at")
            .ok().map(|d| d.to_rfc3339()).unwrap_or_default(),
    }).into_response()
}

#[derive(Deserialize)]
struct ExchangeTokenRequest {
    public_token: String,
    institution_name: String,
    institution_type: String, // e.g., "banking"
}

/// Creates a Plaid Link token
async fn create_link_token(State(state): State<AppState>) -> Response {
    let (client_id, secret) = match (&state.config.plaid_client_id, &state.config.plaid_secret) {
        (Some(client_id), Some(secret)) => (client_id, secret),
        _ => {
            return json_error(
                StatusCode::SERVICE_UNAVAILABLE,
                "Plaid is not configured",
                Some("Set PLAID_CLIENT_ID and PLAID_SECRET before linking Plaid accounts"),
            );
        }
    };

    let client = reqwest::Client::new();
    let url = format!("https://{}.plaid.com/link/token/create", state.config.plaid_env);
    
    let payload = serde_json::json!({
        "client_id": client_id,
        "secret": secret,
        "client_name": "Patrimonio",
        "country_codes": ["US"],
        "language": "en",
        "user": {
            "client_user_id": "patrimonio-single-user"
        },
        "products": ["transactions", "investments"],
        "redirect_uri": state.config.plaid_redirect_uri
    });

    let response = match client.post(&url)
        .json(&payload)
        .send()
        .await
    {
        Ok(response) => response,
        Err(e) => {
            tracing::error!("Failed to call Plaid /link/token/create: {}", e);
            return json_error(StatusCode::BAD_GATEWAY, "Plaid link token request failed", Some(&e.to_string()));
        }
    };

    let status = response.status();
    let res = match response.json::<serde_json::Value>().await {
        Ok(value) => value,
        Err(e) => {
            tracing::error!("Failed to parse Plaid link token response: {}", e);
            return json_error(StatusCode::BAD_GATEWAY, "Plaid returned an invalid response", Some(&e.to_string()));
        }
    };

    if !status.is_success() {
        tracing::error!("Plaid link token error: {:?}", res);
        return (StatusCode::BAD_GATEWAY, Json(res)).into_response();
    }

    Json(res).into_response()
}

/// Creates a Plaid Link token for update mode (reconnect)
async fn create_reconnect_token(
    State(state): State<AppState>,
    axum::extract::Path(id): axum::extract::Path<uuid::Uuid>,
) -> Response {
    let (client_id, secret) = match (&state.config.plaid_client_id, &state.config.plaid_secret) {
        (Some(client_id), Some(secret)) => (client_id, secret),
        _ => return json_error(StatusCode::SERVICE_UNAVAILABLE, "Plaid is not configured", None),
    };

    let row = match sqlx::query("SELECT plaid_access_token_enc FROM institutions WHERE id = $1")
        .bind(id)
        .fetch_one(&state.db)
        .await
    {
        Ok(row) => row,
        Err(_) => return json_error(StatusCode::NOT_FOUND, "Institution not found", None),
    };

    let enc_token: Vec<u8> = match row.try_get("plaid_access_token_enc") {
        Ok(t) => t,
        Err(_) => return json_error(StatusCode::BAD_REQUEST, "Institution has no Plaid token", None),
    };

    let enc_key = match state.config.encryption_key.as_ref() {
        Some(k) => k,
        None => return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Encryption not configured", None),
    };

    let access_token = match encryption::decrypt(enc_key, &enc_token) {
        Ok(t) => t,
        Err(_) => return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Failed to decrypt token", None),
    };

    let client = reqwest::Client::new();
    let url = format!("https://{}.plaid.com/link/token/create", state.config.plaid_env);
    
    let payload = serde_json::json!({
        "client_id": client_id,
        "secret": secret,
        "client_name": "Patrimonio",
        "access_token": access_token,
        "user": {
            "client_user_id": "patrimonio-single-user"
        },
        "redirect_uri": state.config.plaid_redirect_uri
    });

    let response = match client.post(&url).json(&payload).send().await {
        Ok(r) => r,
        Err(e) => return json_error(StatusCode::BAD_GATEWAY, "Plaid request failed", Some(&e.to_string())),
    };

    let res: serde_json::Value = response.json().await.unwrap_or_default();
    Json(res).into_response()
}

/// Exchanges the public token for an access token
async fn exchange_public_token(
    State(state): State<AppState>,
    Json(req): Json<ExchangeTokenRequest>,
) -> axum::response::Response {
    let (client_id, secret) = match (&state.config.plaid_client_id, &state.config.plaid_secret) {
        (Some(client_id), Some(secret)) => (client_id, secret),
        _ => {
            return json_error(
                StatusCode::SERVICE_UNAVAILABLE,
                "Plaid is not configured",
                Some("Set PLAID_CLIENT_ID and PLAID_SECRET before exchanging Plaid tokens"),
            );
        }
    };

    let client = reqwest::Client::new();
    let url = format!("https://{}.plaid.com/item/public_token/exchange", state.config.plaid_env);
    
    let payload = serde_json::json!({
        "client_id": client_id,
        "secret": secret,
        "public_token": req.public_token
    });

    let response = match client.post(&url)
        .json(&payload)
        .send()
        .await
    {
        Ok(response) => response,
        Err(e) => {
            tracing::error!("Failed to call Plaid /item/public_token/exchange: {}", e);
            return json_error(StatusCode::BAD_GATEWAY, "Plaid token exchange request failed", Some(&e.to_string()));
        }
    };

    let res = match response.json::<serde_json::Value>().await {
        Ok(value) => value,
        Err(e) => {
            tracing::error!("Failed to parse Plaid token exchange response: {}", e);
            return json_error(StatusCode::BAD_GATEWAY, "Plaid returned an invalid response", Some(&e.to_string()));
        }
    };

    if let Some(err) = res["error_message"].as_str() {
        tracing::error!("Plaid Exchange Error: {}", err);
        return (axum::http::StatusCode::BAD_REQUEST, axum::response::Json(serde_json::json!({
            "error": "Plaid API error",
            "details": err
        }))).into_response();
    }

    let access_token = match res["access_token"].as_str() {
        Some(t) => t,
        None => {
            tracing::error!("Plaid response missing access_token: {:?}", res);
            return (axum::http::StatusCode::BAD_REQUEST, axum::response::Json(serde_json::json!({
                "error": "Missing access_token",
                "details": res.to_string()
            }))).into_response();
        }
    };
    let item_id = res["item_id"].as_str().unwrap_or("unknown_item");

    let enc_key = match state.config.encryption_key.as_ref() {
        Some(key) => key,
        None => {
            return json_error(
                StatusCode::SERVICE_UNAVAILABLE,
                "Encryption is not configured",
                Some("Set ENCRYPTION_KEY before linking accounts"),
            );
        }
    };
    let encrypted_token = match encryption::encrypt(enc_key, access_token) {
        Ok(token) => token,
        Err(e) => {
            tracing::error!("Failed to encrypt Plaid access token: {}", e);
            return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Failed to encrypt Plaid token", None);
        }
    };

    let row = match sqlx::query(
        r#"
        INSERT INTO institutions (name, institution_type, country, integration_type, plaid_item_id, plaid_access_token_enc, sync_status)
        VALUES ($1, $2, 'US', 'plaid', $3, $4, 'syncing')
        RETURNING id, name, institution_type, country, integration_type,
                  last_synced_at, sync_status, created_at
        "#
    )
    .bind(&req.institution_name)
    .bind(&req.institution_type)
    .bind(item_id)
    .bind(&encrypted_token)
    .fetch_one(&state.db)
    .await
    {
        Ok(row) => row,
        Err(e) => {
            tracing::error!("Failed to insert Plaid institution: {}", e);
            return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Failed to save Plaid institution", None);
        }
    };

    let config = state.config.clone();
    let db = state.db.clone();
    tokio::spawn(async move {
        if let Err(e) = crate::services::sync::sync_all_institutions(&db, &config).await {
            tracing::error!("Immediate Plaid sync failed for new institution: {}", e);
        }
    });

    Json(InstitutionResponse {
        id: row.get::<uuid::Uuid, _>("id").to_string(),
        name: row.get("name"),
        institution_type: row.get("institution_type"),
        country: row.get("country"),
        integration_type: row.get("integration_type"),
        last_synced_at: row.try_get::<chrono::DateTime<chrono::Utc>, _>("last_synced_at")
            .ok().map(|d| d.to_rfc3339()),
        sync_status: row.try_get::<String, _>("sync_status")
            .unwrap_or_else(|_| "pending".to_string()),
        last_sync_error: None,
        created_at: row.try_get::<chrono::DateTime<chrono::Utc>, _>("created_at")
            .ok().map(|d| d.to_rfc3339()).unwrap_or_default(),
    }).into_response()
}

#[derive(Deserialize)]
struct LinkCryptoRequest {
    name: String,
    integration_type: String, // "coinbase" or "bitso"
    api_key: String,
    api_secret: String,
    api_pass: Option<String>,
}

/// Link a crypto exchange with API credentials
async fn link_crypto_institution(
    State(state): State<AppState>,
    Json(req): Json<LinkCryptoRequest>,
) -> axum::response::Response {
    let enc_key = match state.config.encryption_key.as_ref() {
        Some(key) => key,
        None => {
            return json_error(
                StatusCode::SERVICE_UNAVAILABLE,
                "Encryption is not configured",
                Some("Set ENCRYPTION_KEY before linking crypto exchanges"),
            );
        }
    };
    
    let key_enc = match encryption::encrypt(enc_key, &req.api_key) {
        Ok(value) => value,
        Err(e) => return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Failed to encrypt API key", Some(&e.to_string())),
    };
    let secret_enc = match encryption::encrypt(enc_key, &req.api_secret) {
        Ok(value) => value,
        Err(e) => return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Failed to encrypt API secret", Some(&e.to_string())),
    };
    let pass_enc = match req.api_pass {
        Some(pass) => match encryption::encrypt(enc_key, &pass) {
            Ok(value) => Some(value),
            Err(e) => return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Failed to encrypt API passphrase", Some(&e.to_string())),
        },
        None => None,
    };

    let row = match sqlx::query(
        r#"
        INSERT INTO institutions (name, institution_type, country, integration_type, api_key_enc, api_secret_enc, api_pass_enc)
        VALUES ($1, 'crypto', 'Global', $2, $3, $4, $5)
        RETURNING id, name, institution_type, country, integration_type,
                  last_synced_at, sync_status, created_at
        "#
    )
    .bind(&req.name)
    .bind(&req.integration_type)
    .bind(&key_enc)
    .bind(&secret_enc)
    .bind(&pass_enc)
    .fetch_one(&state.db)
    .await
    {
        Ok(row) => row,
        Err(e) => {
            tracing::error!("Failed to link crypto institution: {}", e);
            return json_error(StatusCode::INTERNAL_SERVER_ERROR, "Failed to link crypto institution", None);
        }
    };

    let config = state.config.clone();
    let db = state.db.clone();
    tokio::spawn(async move {
        if let Err(e) = crate::services::sync::sync_all_institutions(&db, &config).await {
            tracing::error!("Immediate crypto sync failed for new institution: {}", e);
        }
    });

    Json(InstitutionResponse {
        id: row.get::<uuid::Uuid, _>("id").to_string(),
        name: row.get("name"),
        institution_type: row.get("institution_type"),
        country: row.get("country"),
        integration_type: row.get("integration_type"),
        last_synced_at: row.try_get::<chrono::DateTime<chrono::Utc>, _>("last_synced_at")
            .ok().map(|d| d.to_rfc3339()),
        sync_status: row.try_get::<String, _>("sync_status")
            .unwrap_or_else(|_| "pending".to_string()),
        last_sync_error: None,
        created_at: row.try_get::<chrono::DateTime<chrono::Utc>, _>("created_at")
            .ok().map(|d| d.to_rfc3339()).unwrap_or_default(),
    }).into_response()
}

#[derive(Deserialize)]
struct CreateInstitutionRequest {
    name: String,
    institution_type: String,
    country: String,
    integration_type: String,
}

#[derive(Serialize)]
struct InstitutionResponse {
    id: String,
    name: String,
    institution_type: String,
    country: String,
    integration_type: String,
    last_synced_at: Option<String>,
    sync_status: String,
    last_sync_error: Option<String>,
    created_at: String,
}

#[derive(Deserialize)]
struct PlaidWebhook {
    webhook_type: String,
    webhook_code: String,
    item_id: String,
}

/// Webhook from Plaid triggered on item updates
async fn plaid_webhook(
    State(state): State<AppState>,
    Json(req): Json<PlaidWebhook>,
) -> Json<serde_json::Value> {
    tracing::info!("Plaid Webhook: {} - {} for item {}", req.webhook_type, req.webhook_code, req.item_id);

    let status = match req.webhook_code.as_str() {
        "ERROR" | "ITEM_LOGIN_REQUIRED" | "PENDING_EXPIRATION" | "USER_PERMISSION_REVOKED" => {
            Some("reconnect_required")
        }
        "SYNC_UPDATES_AVAILABLE" | "DEFAULT_UPDATE" | "HISTORICAL_UPDATE" | "INITIAL_UPDATE" => {
            Some("syncing")
        }
        _ => None,
    };

    if let Some(status) = status {
        let _ = sqlx::query("UPDATE institutions SET sync_status = $1 WHERE plaid_item_id = $2")
            .bind(status)
            .bind(&req.item_id)
            .execute(&state.db)
            .await;
    }

    let config = state.config.clone();
    let db = state.db.clone();
    
    tokio::spawn(async move {
        if let Err(e) = crate::services::sync::sync_all_institutions(&db, &config).await {
            tracing::error!("Plaid webhook background sync failed: {}", e);
        }
    });

    Json(serde_json::json!({"status": "received"}))
}

/// Delete an institution and all associated data
async fn delete_institution(
    State(state): State<AppState>,
    axum::extract::Path(id): axum::extract::Path<uuid::Uuid>,
) -> impl IntoResponse {
    info!("Deleting institution: {}", id);

    // SQLX automatically handles cascading if defined in the schema,
    // but we'll be explicit about deleting dependent data if needed.
    // Assuming schema has cascading deletes for accounts, transactions, etc.
    let result = sqlx::query("DELETE FROM institutions WHERE id = $1")
        .bind(id)
        .execute(&state.db)
        .await;

    match result {
        Ok(_) => StatusCode::NO_CONTENT.into_response(),
        Err(e) => {
            error!("Failed to delete institution: {}", e);
            json_error(StatusCode::INTERNAL_SERVER_ERROR, "Failed to delete institution", Some(&e.to_string()))
        }
    }
}

fn json_error(status: StatusCode, error: &str, details: Option<&str>) -> Response {
    let mut payload = serde_json::json!({ "error": error });
    if let Some(details) = details {
        payload["details"] = serde_json::Value::String(details.to_string());
    }
    (status, Json(payload)).into_response()
}
