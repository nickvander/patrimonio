//! Per-user key/value store for app preferences (budgets, goals, etc.).
//!
//! Originally a global single-row-per-key table; migration
//! 2026051805_app_settings_user_id added the per-user dimension so a
//! second invited user can't observe (or overwrite) the first user's
//! budgets / goals. Every read and write here is scoped to
//! `AuthContext.user_id`.
//!
//! The `value` column stays JSONB so per-key shape can evolve without
//! a schema change.

use axum::{
    extract::{Extension, Path, State},
    http::StatusCode,
    routing::get,
    Json, Router,
};
use serde_json::Value;
use sqlx::Row;

use crate::api::session::AuthContext;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new().route("/{key}", get(get_setting).put(put_setting))
}

async fn get_setting(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(key): Path<String>,
) -> Result<Json<Value>, StatusCode> {
    let row = sqlx::query("SELECT value FROM app_settings WHERE key = $1 AND user_id = $2")
        .bind(&key)
        .bind(ctx.user_id)
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
    Extension(ctx): Extension<AuthContext>,
    Path(key): Path<String>,
    Json(body): Json<Value>,
) -> Result<Json<Value>, StatusCode> {
    sqlx::query(
        r#"
        INSERT INTO app_settings (user_id, key, value, updated_at)
        VALUES ($1, $2, $3, NOW())
        ON CONFLICT (user_id, key) DO UPDATE
            SET value = EXCLUDED.value,
                updated_at = NOW()
        "#,
    )
    .bind(ctx.user_id)
    .bind(&key)
    .bind(&body)
    .execute(&state.db)
    .await
    .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;

    Ok(Json(body))
}
