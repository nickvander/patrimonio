use axum::{
    extract::State,
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};

use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_institutions))
        .route("/", post(create_institution))
}

/// List all linked institutions
async fn list_institutions(State(state): State<AppState>) -> Json<Vec<InstitutionResponse>> {
    let rows = sqlx::query_as!(
        InstitutionRow,
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

    Json(rows.into_iter().map(InstitutionResponse::from).collect())
}

/// Manually create an institution (for CSV-imported / Mexican accounts)
async fn create_institution(
    State(state): State<AppState>,
    Json(req): Json<CreateInstitutionRequest>,
) -> Json<InstitutionResponse> {
    let row = sqlx::query_as!(
        InstitutionRow,
        r#"
        INSERT INTO institutions (name, institution_type, country, integration_type)
        VALUES ($1, $2, $3, $4)
        RETURNING id, name, institution_type, country, integration_type,
                  last_synced_at, sync_status, created_at
        "#,
        req.name,
        req.institution_type,
        req.country,
        req.integration_type,
    )
    .fetch_one(&state.db)
    .await
    .expect("Failed to create institution");

    Json(InstitutionResponse::from(row))
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

struct InstitutionRow {
    id: uuid::Uuid,
    name: String,
    institution_type: String,
    country: String,
    integration_type: String,
    last_synced_at: Option<chrono::DateTime<chrono::Utc>>,
    sync_status: Option<String>,
    created_at: Option<chrono::DateTime<chrono::Utc>>,
}

impl From<InstitutionRow> for InstitutionResponse {
    fn from(row: InstitutionRow) -> Self {
        Self {
            id: row.id.to_string(),
            name: row.name,
            institution_type: row.institution_type,
            country: row.country,
            integration_type: row.integration_type,
            last_synced_at: row.last_synced_at.map(|d| d.to_rfc3339()),
            sync_status: row.sync_status.unwrap_or_else(|| "pending".to_string()),
            created_at: row.created_at.map(|d| d.to_rfc3339()).unwrap_or_default(),
        }
    }
}
