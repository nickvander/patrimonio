use axum::{
    extract::State,
    routing::{get, post},
    Json, Router,
    response::IntoResponse,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;

use crate::AppState;
use crate::services::encryption;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_institutions).post(create_institution))
        .route("/sync", post(trigger_sync))
        .route("/link-token", post(create_link_token))
        .route("/exchange-token", post(exchange_public_token))
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
               last_synced_at, sync_status, created_at
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
) -> Json<InstitutionResponse> {
    let row = sqlx::query(
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
    .expect("Failed to create institution");

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
        created_at: row.try_get::<chrono::DateTime<chrono::Utc>, _>("created_at")
            .ok().map(|d| d.to_rfc3339()).unwrap_or_default(),
    })
}

#[derive(Deserialize)]
struct ExchangeTokenRequest {
    public_token: String,
    institution_name: String,
    institution_type: String, // e.g., "banking"
}

/// Creates a Plaid Link token
async fn create_link_token(State(state): State<AppState>) -> Json<serde_json::Value> {
    let client = reqwest::Client::new();
    let url = format!("https://{}.plaid.com/link/token/create", state.config.plaid_env);
    
    let payload = serde_json::json!({
        "client_id": state.config.plaid_client_id,
        "secret": state.config.plaid_secret,
        "client_name": "Patrimonio",
        "country_codes": ["US"],
        "language": "en",
        "user": {
            "client_user_id": "patrimonio-single-user"
        },
        "products": ["transactions", "investments"]
    });

    let res = client.post(&url)
        .json(&payload)
        .send().await.expect("Failed to call Plaid /link/token/create")
        .json::<serde_json::Value>().await.expect("Failed to parse Plaid response");

    Json(res)
}

/// Exchanges the public token for an access token
async fn exchange_public_token(
    State(state): State<AppState>,
    Json(req): Json<ExchangeTokenRequest>,
) -> axum::response::Response {
    let client = reqwest::Client::new();
    let url = format!("https://{}.plaid.com/item/public_token/exchange", state.config.plaid_env);
    
    let payload = serde_json::json!({
        "client_id": state.config.plaid_client_id,
        "secret": state.config.plaid_secret,
        "public_token": req.public_token
    });

    let res = client.post(&url)
        .json(&payload)
        .send().await.expect("Failed to call Plaid /item/public_token/exchange")
        .json::<serde_json::Value>().await.expect("Failed to parse Plaid response");

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

    let enc_key = state.config.encryption_key.as_ref().expect("ENCRYPTION_KEY not configured in .env");
    let encrypted_token = encryption::encrypt(enc_key, access_token)
        .expect("Failed to encrypt Plaid access token");

    let row = sqlx::query(
        r#"
        INSERT INTO institutions (name, institution_type, country, integration_type, plaid_item_id, plaid_access_token_enc)
        VALUES ($1, $2, 'US', 'plaid', $3, $4)
        RETURNING id, name, institution_type, country, integration_type,
                  last_synced_at, sync_status, created_at
        "#
    )
    .bind(&req.institution_name)
    .bind(&req.institution_type)
    .bind(item_id)
    .bind(&encrypted_token)
    .fetch_one(&state.db)
    .await.expect("Failed to insert institution into database");

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

    let config = state.config.clone();
    let db = state.db.clone();
    
    tokio::spawn(async move {
        if let Err(e) = crate::services::sync::sync_all_institutions(&db, &config).await {
            tracing::error!("Plaid webhook background sync failed: {}", e);
        }
    });

    Json(serde_json::json!({"status": "received"}))
}
