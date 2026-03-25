use axum::{
    extract::{Query, State},
    Json, Router,
    routing::get,
};
use crate::AppState;
use crate::services::projections::{self, ProjectionRequest, ProjectionResponse};

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/calculate", get(calculate_projection))
}

/// Calculate wealth projection based on query parameters
async fn calculate_projection(
    State(_state): State<AppState>,
    Query(payload): Query<ProjectionRequest>,
) -> Json<ProjectionResponse> {
    let result = projections::calculate_projection(&payload);
    Json(result)
}
