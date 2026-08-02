//! The API error envelope. `ApiError` is the one and only error
//! `IntoResponse` in the crate: handlers return `Result<_, ApiError>`,
//! and 500s go through `internal()` so the real error is logged while
//! the client sees only a generic message.

use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};

pub struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    pub fn new(status: StatusCode, message: &str) -> Self {
        Self {
            status,
            message: message.to_string(),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = serde_json::json!({ "error": self.message });
        (self.status, Json(body)).into_response()
    }
}

pub(crate) fn internal<E: std::fmt::Display>(e: E) -> ApiError {
    tracing::error!("auth internal error: {}", e);
    ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "Internal server error")
}
