use axum::{
    extract::{Extension, State},
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::{get, post, delete},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;

use crate::api::session::AuthContext;
use crate::AppState;
use crate::services::encryption;
use tracing::{info, error};

/// User-facing institution CRUD + sync. Mounted under the
/// authenticated router in main.rs.
pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_institutions).post(create_institution))
        .route("/sync", post(trigger_sync))
        .route("/{id}/sync", post(trigger_sync_one))
        .route("/link-token", post(create_link_token))
        .route("/reconnect-token/{id}", post(create_reconnect_token))
        .route("/{id}", delete(delete_institution))
        .route("/exchange-token", post(exchange_public_token))
        .route("/update-webhook", post(update_webhooks_all))
        .route("/crypto", post(link_crypto_institution))
}

/// Plaid webhook receiver. Must live on the public router because
/// Plaid POSTs to it directly with no session cookie. The handler
/// itself refuses to do anything unless webhook verification is
/// configured — see `plaid_webhook` for the gating.
pub fn webhook_router() -> Router<AppState> {
    Router::new().route("/webhook", post(plaid_webhook))
}

/// Sync request body for the global `/sync` endpoint. Accepts an
/// optional `ids` array; when present, only those institutions are
/// touched, replacing what used to be a client-side loop of single
/// `/institutions/{id}/sync` calls.
#[derive(Deserialize, Default)]
struct SyncRequest {
    #[serde(default)]
    ids: Option<Vec<uuid::Uuid>>,
}

/// Manually trigger a sync. With an empty body the engine runs against
/// every institution the caller owns; with `{"ids": [...]}` it runs
/// against only those (each id is verified to belong to the caller —
/// foreign ids are silently filtered out so an attacker can't probe
/// for the existence of another user's institutions).
async fn trigger_sync(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    body: Option<Json<SyncRequest>>,
) -> axum::response::Response {
    let config = state.config.clone();
    let db = state.db.clone();
    let only_ids = body.and_then(|b| b.0.ids);
    if let Err(e) = crate::services::sync::sync_user_institutions(
        &db,
        &config,
        ctx.user_id,
        only_ids,
    )
    .await
    {
        // Log the detail server-side; don't echo internals (SQL / upstream
        // Plaid text) to the client where they'd leak implementation detail.
        tracing::error!("Manual Plaid sync failed: {}", e);
        return (axum::http::StatusCode::INTERNAL_SERVER_ERROR, axum::response::Json(serde_json::json!({
            "error": "Sync failed"
        }))).into_response();
    }
    // Wake every open dashboard tab for this user. The event is
    // coarse — the client refetches /dashboard/* on receipt rather
    // than trying to apply a delta. Cheap because no tabs open ==
    // no subscribers == no work.
    state
        .realtime
        .publish(
            ctx.user_id,
            crate::services::realtime::RealtimeEvent::TransactionsChanged,
        )
        .await;
    Json(serde_json::json!({"status": "ok"})).into_response()
}

/// Sync a single institution by id — used by the per-institution
/// retry shortcut on the dashboard. Ownership is checked at the
/// engine layer (the institution row is loaded with a `user_id`
/// predicate); a foreign id returns 404-equivalent silently.
async fn trigger_sync_one(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    axum::extract::Path(id): axum::extract::Path<uuid::Uuid>,
) -> axum::response::Response {
    let config = state.config.clone();
    let db = state.db.clone();
    if let Err(e) = crate::services::sync::sync_user_institutions(
        &db,
        &config,
        ctx.user_id,
        Some(vec![id]),
    )
    .await
    {
        tracing::error!("Per-institution sync failed for {id}: {e}");
        return (
            axum::http::StatusCode::INTERNAL_SERVER_ERROR,
            axum::response::Json(serde_json::json!({
                "error": "Sync failed"
            })),
        )
            .into_response();
    }
    state
        .realtime
        .publish(
            ctx.user_id,
            crate::services::realtime::RealtimeEvent::TransactionsChanged,
        )
        .await;
    Json(serde_json::json!({"status": "ok"})).into_response()
}

/// List all linked institutions for the authenticated user.
async fn list_institutions(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<InstitutionResponse>> {
    let rows = sqlx::query(
        r#"
        SELECT id, name, institution_type, country, integration_type,
               last_synced_at, sync_status, last_sync_error, created_at
        FROM institutions
        WHERE user_id = $1
        ORDER BY name
        "#
    )
    .bind(ctx.user_id)
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
    Extension(ctx): Extension<AuthContext>,
    Json(req): Json<CreateInstitutionRequest>,
) -> Response {
    let row = match sqlx::query(
        r#"
        INSERT INTO institutions (name, institution_type, country, integration_type, user_id)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id, name, institution_type, country, integration_type,
                  last_synced_at, sync_status, created_at
        "#
    )
    .bind(&req.name)
    .bind(&req.institution_type)
    .bind(&req.country)
    .bind(&req.integration_type)
    .bind(ctx.user_id)
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
    
    let mut payload = serde_json::json!({
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
    // Plaid will POST update notifications to this URL once the item
    // is created. Items inherit the webhook URL from their link
    // session, so the *first* time Plaid Production is configured the
    // operator MUST set PLAID_WEBHOOK_URL — items linked before that
    // env var was set will keep polling forever until the user
    // re-links them or hits /item/webhook/update (not yet exposed).
    if let Some(webhook) = &state.config.plaid_webhook_url {
        payload["webhook"] = serde_json::Value::String(webhook.clone());
    }

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
    Extension(ctx): Extension<AuthContext>,
    axum::extract::Path(id): axum::extract::Path<uuid::Uuid>,
) -> Response {
    let (client_id, secret) = match (&state.config.plaid_client_id, &state.config.plaid_secret) {
        (Some(client_id), Some(secret)) => (client_id, secret),
        _ => return json_error(StatusCode::SERVICE_UNAVAILABLE, "Plaid is not configured", None),
    };

    // Ownership predicate prevents reconnecting another user's
    // institution. Without the user_id filter an attacker who knew
    // a victim's institution UUID could mint a Plaid Link token
    // bound to the victim's bank session.
    let row = match sqlx::query(
        "SELECT plaid_access_token_enc FROM institutions WHERE id = $1 AND user_id = $2"
    )
        .bind(id)
        .bind(ctx.user_id)
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
    
    // Plaid /link/token/create in update mode still requires country_codes
    // and language. Match the values used by the new-link flow above.
    let mut payload = serde_json::json!({
        "client_id": client_id,
        "secret": secret,
        "client_name": "Patrimonio",
        "country_codes": ["US"],
        "language": "en",
        "access_token": access_token,
        "user": {
            "client_user_id": "patrimonio-single-user"
        },
        "redirect_uri": state.config.plaid_redirect_uri
    });
    // Re-establish the webhook URL on every reconnect. Items that
    // were originally linked before PLAID_WEBHOOK_URL was configured
    // pick up the URL here, so reconnecting an old institution is
    // also the recommended way to flip it from polling to push.
    if let Some(webhook) = &state.config.plaid_webhook_url {
        payload["webhook"] = serde_json::Value::String(webhook.clone());
    }

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
    Extension(ctx): Extension<AuthContext>,
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
            // Log server-side only; the raw Plaid exchange response must not
            // be echoed to the client.
            tracing::error!("Plaid response missing access_token: {:?}", res);
            return (axum::http::StatusCode::BAD_REQUEST, axum::response::Json(serde_json::json!({
                "error": "Missing access_token"
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
        INSERT INTO institutions (name, institution_type, country, integration_type, plaid_item_id, plaid_access_token_enc, sync_status, user_id)
        VALUES ($1, $2, 'US', 'plaid', $3, $4, 'syncing', $5)
        RETURNING id, name, institution_type, country, integration_type,
                  last_synced_at, sync_status, created_at
        "#
    )
    .bind(&req.institution_name)
    .bind(&req.institution_type)
    .bind(item_id)
    .bind(&encrypted_token)
    .bind(ctx.user_id)
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
    let user_id = ctx.user_id;
    tokio::spawn(async move {
        if let Err(e) =
            crate::services::sync::sync_user_institutions(&db, &config, user_id, None).await
        {
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
    Extension(ctx): Extension<AuthContext>,
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
        INSERT INTO institutions (name, institution_type, country, integration_type, api_key_enc, api_secret_enc, api_pass_enc, user_id)
        VALUES ($1, 'crypto', 'Global', $2, $3, $4, $5, $6)
        RETURNING id, name, institution_type, country, integration_type,
                  last_synced_at, sync_status, created_at
        "#
    )
    .bind(&req.name)
    .bind(&req.integration_type)
    .bind(&key_enc)
    .bind(&secret_enc)
    .bind(&pass_enc)
    .bind(ctx.user_id)
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
    let user_id = ctx.user_id;
    tokio::spawn(async move {
        if let Err(e) =
            crate::services::sync::sync_user_institutions(&db, &config, user_id, None).await
        {
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

/// Webhook from Plaid triggered on item updates.
///
/// Plaid signs every webhook with a JWT in `Plaid-Verification`. We
/// reject any request that doesn't carry the header, and any request
/// whose JWT fails ES256 verification, has a stale `iat`, or whose
/// `request_body_sha256` claim doesn't match the SHA-256 of the body
/// the receiver actually saw. The full rule set lives in
/// `services::plaid_webhook_verify`. Only after verification do we
/// touch the DB or spawn a background sync.
///
/// The body has to be read as `Bytes` (not `Json<PlaidWebhook>`)
/// because the verifier hashes the raw bytes — `serde_json::from_slice`
/// happens *after* the signature check passes.
async fn plaid_webhook(
    State(state): State<AppState>,
    headers: axum::http::HeaderMap,
    body: axum::body::Bytes,
) -> axum::response::Response {
    let Some(verification) = headers
        .get("plaid-verification")
        .and_then(|v| v.to_str().ok())
    else {
        tracing::warn!("Plaid webhook rejected: missing Plaid-Verification header");
        return (
            axum::http::StatusCode::UNAUTHORIZED,
            Json(serde_json::json!({"error": "Webhook signature required"})),
        )
            .into_response();
    };

    if let Err(e) = crate::services::plaid_webhook_verify::verify_plaid_webhook(
        &state.config,
        verification,
        body.as_ref(),
    )
    .await
    {
        tracing::warn!("Plaid webhook signature verification failed: {e}");
        return (
            axum::http::StatusCode::UNAUTHORIZED,
            Json(serde_json::json!({"error": "Webhook signature invalid"})),
        )
            .into_response();
    }

    let req: PlaidWebhook = match serde_json::from_slice(&body) {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!("Plaid webhook body verified but unparseable: {e}");
            return (
                axum::http::StatusCode::BAD_REQUEST,
                Json(serde_json::json!({"error": "Malformed webhook body"})),
            )
                .into_response();
        }
    };

    tracing::info!(
        "Plaid webhook (verified): {} - {} for item {}",
        req.webhook_type,
        req.webhook_code,
        req.item_id
    );

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

    // Look up which institution this item_id belongs to so the
    // background sync touches only the one item Plaid is telling us
    // about — `sync_all_institutions` was correct but wasteful: with
    // a dozen linked banks every webhook used to hit every Plaid API.
    let inst_row = sqlx::query(
        "SELECT id FROM institutions WHERE plaid_item_id = $1",
    )
    .bind(&req.item_id)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten();

    // Only kick a sync for the codes that signal new data. Status-only
    // codes (ITEM_LOGIN_REQUIRED, PENDING_EXPIRATION) already updated
    // sync_status above and don't have anything to pull.
    let should_sync = matches!(
        req.webhook_code.as_str(),
        "SYNC_UPDATES_AVAILABLE"
            | "DEFAULT_UPDATE"
            | "HISTORICAL_UPDATE"
            | "INITIAL_UPDATE"
            | "TRANSACTIONS_REMOVED"
    );

    if should_sync {
        let config = state.config.clone();
        let db = state.db.clone();
        match inst_row.and_then(|r| r.try_get::<uuid::Uuid, _>("id").ok()) {
            Some(inst_id) => {
                tokio::spawn(async move {
                    if let Err(e) =
                        crate::services::sync::sync_one_institution(&db, &config, inst_id).await
                    {
                        tracing::error!(
                            "Plaid webhook background sync for institution {} failed: {}",
                            inst_id,
                            e
                        );
                    }
                });
            }
            None => {
                // Unknown item_id — almost always means Plaid is
                // sending us a webhook for an item that was deleted
                // on our side. Log but don't fall back to a
                // global sync; that would re-emit duplicate work for
                // every linked institution every time a stale
                // webhook lands.
                tracing::warn!(
                    "Plaid webhook for unknown item_id={} (institution probably deleted); skipping sync",
                    req.item_id
                );
            }
        }
    }

    Json(serde_json::json!({"status": "received"})).into_response()
}

/// Delete an institution and all associated data
async fn delete_institution(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    axum::extract::Path(id): axum::extract::Path<uuid::Uuid>,
) -> impl IntoResponse {
    info!("Deleting institution {} for user {}", id, ctx.user_id);

    // Ownership predicate keeps the delete scoped to the caller's
    // institutions. Schema cascading handles accounts/transactions/
    // holdings/balance_snapshots; without this filter, an attacker
    // who knew a victim's institution UUID could nuke their entire
    // tree of financial data.
    let result =
        sqlx::query("DELETE FROM institutions WHERE id = $1 AND user_id = $2")
            .bind(id)
            .bind(ctx.user_id)
            .execute(&state.db)
            .await;

    match result {
        Ok(r) if r.rows_affected() == 0 => StatusCode::NOT_FOUND.into_response(),
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

/// One-shot: call Plaid's `/item/webhook/update` for every institution
/// the caller owns. Used after the operator first sets PLAID_WEBHOOK_URL
/// on a deployment that already has linked items — Plaid binds the
/// webhook URL at link-time, so pre-existing items keep polling forever
/// unless either re-linked or pointed at the new URL via this endpoint.
///
/// Returns a per-institution result so the UI can show a table of
/// "updated / failed / skipped (no Plaid token)" rows.
async fn update_webhooks_all(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Response {
    let (client_id, secret) = match (&state.config.plaid_client_id, &state.config.plaid_secret) {
        (Some(client_id), Some(secret)) => (client_id, secret),
        _ => return json_error(
            StatusCode::SERVICE_UNAVAILABLE,
            "Plaid is not configured",
            Some("Set PLAID_CLIENT_ID and PLAID_SECRET"),
        ),
    };

    let webhook_url = match &state.config.plaid_webhook_url {
        Some(u) if !u.is_empty() => u.clone(),
        _ => return json_error(
            StatusCode::BAD_REQUEST,
            "PLAID_WEBHOOK_URL is not set",
            Some("Set PLAID_WEBHOOK_URL to a public HTTPS URL pointing at /api/institutions/webhook, then retry"),
        ),
    };

    let enc_key = match state.config.encryption_key.as_ref() {
        Some(k) => k,
        None => return json_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Encryption not configured",
            None,
        ),
    };

    let rows = match sqlx::query(
        "SELECT id, name, plaid_access_token_enc FROM institutions \
         WHERE user_id = $1 AND plaid_access_token_enc IS NOT NULL",
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    {
        Ok(rows) => rows,
        Err(e) => return json_error(
            StatusCode::INTERNAL_SERVER_ERROR,
            "Failed to list institutions",
            Some(&e.to_string()),
        ),
    };

    let client = reqwest::Client::new();
    let url = format!("https://{}.plaid.com/item/webhook/update", state.config.plaid_env);

    let mut updated = 0usize;
    let mut failed = 0usize;
    let mut results: Vec<serde_json::Value> = Vec::with_capacity(rows.len());

    for row in rows {
        let id: uuid::Uuid = match row.try_get("id") {
            Ok(v) => v,
            Err(_) => continue,
        };
        let name: String = row.try_get("name").unwrap_or_default();
        let enc_token: Vec<u8> = match row.try_get("plaid_access_token_enc") {
            Ok(t) => t,
            Err(_) => {
                results.push(serde_json::json!({
                    "id": id, "name": name, "ok": false, "reason": "missing token",
                }));
                failed += 1;
                continue;
            }
        };
        let access_token = match encryption::decrypt(enc_key, &enc_token) {
            Ok(t) => t,
            Err(_) => {
                results.push(serde_json::json!({
                    "id": id, "name": name, "ok": false, "reason": "decrypt failed",
                }));
                failed += 1;
                continue;
            }
        };

        let payload = serde_json::json!({
            "client_id": client_id,
            "secret": secret,
            "access_token": access_token,
            "webhook": webhook_url,
        });

        let response = match client.post(&url).json(&payload).send().await {
            Ok(r) => r,
            Err(e) => {
                results.push(serde_json::json!({
                    "id": id, "name": name, "ok": false, "reason": format!("network: {}", e),
                }));
                failed += 1;
                continue;
            }
        };
        let status = response.status();
        let body = response.json::<serde_json::Value>().await.unwrap_or(serde_json::Value::Null);
        if status.is_success() {
            updated += 1;
            results.push(serde_json::json!({ "id": id, "name": name, "ok": true }));
        } else {
            failed += 1;
            results.push(serde_json::json!({
                "id": id, "name": name, "ok": false,
                "reason": body.get("error_message")
                    .and_then(|v| v.as_str())
                    .unwrap_or("plaid error")
                    .to_string(),
            }));
        }
    }

    info!(
        "update-webhook: updated {} institutions, {} failed",
        updated, failed
    );
    Json(serde_json::json!({
        "updated": updated,
        "failed": failed,
        "webhook_url": webhook_url,
        "results": results,
    })).into_response()
}
