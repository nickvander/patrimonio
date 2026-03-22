use axum::{
    extract::State,
    routing::get,
    Json, Router,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;

use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_institutions).post(create_institution))
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
