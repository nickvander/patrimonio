//! Simple key/value store for app preferences (budgets, goals, etc.).
//! Single-user today — no auth scoping. Each key holds an opaque JSONB
//! blob; callers define the per-key shape.

use axum::{
    extract::{Path, State},
    http::StatusCode,
    routing::get,
    Json, Router,
};
use serde_json::Value;
use sqlx::Row;

use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new().route("/{key}", get(get_setting).put(put_setting))
}

async fn get_setting(
    State(state): State<AppState>,
    Path(key): Path<String>,
) -> Result<Json<Value>, StatusCode> {
    let row = sqlx::query("SELECT value FROM app_settings WHERE key = $1")
        .bind(&key)
        .fetch_optional(&state.db)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
    match row {
        Some(r) => {
            let v: Value = r
                .try_get("value")
                .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
            Ok(Json(v))
        }
        // Not found is normal — first read for a new key. Return JSON
        // null so the frontend doesn't have to differentiate 404 from
        // "the user genuinely hasn't set this yet".
        None => Ok(Json(Value::Null)),
    }
}

async fn put_setting(
    State(state): State<AppState>,
    Path(key): Path<String>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, StatusCode> {
    sqlx::query(
        r#"
        INSERT INTO app_settings (key, value, updated_at)
        VALUES ($1, $2, NOW())
        ON CONFLICT (key) DO UPDATE
            SET value = EXCLUDED.value,
                updated_at = NOW()
        "#,
    )
    .bind(&key)
    .bind(&body)
    .execute(&state.db)
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    Ok(Json(body))
}
