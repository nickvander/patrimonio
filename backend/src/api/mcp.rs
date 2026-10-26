//! Streamable HTTP Model Context Protocol (MCP) endpoint (`POST /api/mcp`).
//!
//! Exposes Patrimonio's MCP JSON-RPC 2.0 server over standard HTTP using the
//! existing `require_auth` middleware (accepting either `Authorization: Bearer pat_...`
//! Personal Access Tokens or an authenticated session cookie).
//!
//! Security model:
//! - Every tool call and resource read is strictly scoped to `AuthContext.user_id`.
//! - Personal Access Tokens default to `scope = "read_only"`, which downgrades
//!   `AuthContext.role` to `"read_only"` in `require_auth`. Consequently,
//!   `ctx.is_owner()` is `false` for all default tokens and write tools
//!   (`reconcile_loan_installment`) are disabled.
//! - Write tools are only enabled when `ctx.is_owner()` is `true` (e.g. an
//!   owner explicitly minted a `read_write` token) AND `PATRIMONIO_MCP_ALLOW_WRITES`
//!   is not set to `"false"` / `"0"`.

use axum::{
    extract::State,
    http::StatusCode,
    response::{IntoResponse, Response},
    routing::post,
    Extension, Json, Router,
};
use serde_json::Value;

use crate::{
    api::{error::ApiError, middleware::AuthContext},
    mcp::{execute_jsonrpc_with_context, JsonRpcRequest, JsonRpcResponse, McpExecutionContext},
    AppState,
};

pub fn router() -> Router<AppState> {
    Router::new().route("/", post(handle_mcp_post))
}

async fn handle_mcp_post(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Json(payload): Json<Value>,
) -> Result<Response, ApiError> {
    let env_writes_disabled = std::env::var("PATRIMONIO_MCP_ALLOW_WRITES")
        .ok()
        .is_some_and(|v| {
            let trimmed = v.trim();
            trimmed.eq_ignore_ascii_case("false") || trimmed == "0"
        });
    let allow_writes = ctx.is_owner() && !env_writes_disabled;

    let exec_ctx = McpExecutionContext {
        pool: &state.db,
        user_id: ctx.user_id,
        allow_writes,
        write_pool: if allow_writes { Some(&state.db) } else { None },
        audit_log_path: None,
    };

    if let Some(batch) = payload.as_array() {
        if batch.is_empty() {
            return Ok((
                StatusCode::BAD_REQUEST,
                Json(JsonRpcResponse::err(
                    Value::Null,
                    -32600,
                    "Invalid Request: empty batch",
                )),
            )
                .into_response());
        }
        let mut responses = Vec::with_capacity(batch.len());
        for item in batch {
            match serde_json::from_value::<JsonRpcRequest>(item.clone()) {
                Ok(req) => {
                    if let Some(resp) = execute_jsonrpc_with_context(&exec_ctx, req).await {
                        responses.push(resp);
                    }
                }
                Err(e) => {
                    responses.push(JsonRpcResponse::err(
                        Value::Null,
                        -32600,
                        format!("Invalid Request: {e}"),
                    ));
                }
            }
        }
        if responses.is_empty() {
            return Ok(StatusCode::ACCEPTED.into_response());
        }
        return Ok((StatusCode::OK, Json(responses)).into_response());
    }

    let req: JsonRpcRequest = serde_json::from_value(payload).map_err(|e| {
        ApiError::new(
            StatusCode::BAD_REQUEST,
            &format!("Invalid MCP JSON-RPC 2.0 request payload: {e}"),
        )
    })?;

    match execute_jsonrpc_with_context(&exec_ctx, req).await {
        Some(resp) => Ok((StatusCode::OK, Json(resp)).into_response()),
        None => Ok(StatusCode::ACCEPTED.into_response()),
    }
}
