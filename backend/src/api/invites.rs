//! Invitation-based registration.
//!
//! After the bootstrap user is created, new accounts arrive only by
//! redeeming a one-time `invite_tokens` row. Mint endpoint requires an
//! authenticated session; redeem endpoint is public (it has to be —
//! the redeemer has no account yet).
//!
//! Token shape: 32 random bytes, URL-safe base64-encoded (43 chars).
//! Only the SHA-256 hash is stored — the plaintext is shown once in
//! the mint response and embedded in the share URL.

use axum::{
    extract::{Extension, Path, State},
    http::StatusCode,
    routing::{delete, get},
    Json, Router,
};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use chrono::{DateTime, Duration, Utc};
use rand::{rngs::OsRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use sqlx::Row;
use uuid::Uuid;

use crate::api::session::AuthContext;
use crate::AppState;

const DEFAULT_EXPIRY_HOURS: i64 = 72;
const MAX_EXPIRY_HOURS: i64 = 24 * 14; // 2 weeks
const TOKEN_BYTES: usize = 32;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_invites).post(create_invite))
        .route("/{id}", delete(revoke_invite))
}

#[derive(Deserialize, Default)]
struct CreateInviteRequest {
    #[serde(default)]
    expires_in_hours: Option<i64>,
    #[serde(default)]
    note: Option<String>,
    /// 'owner' or 'read_only'. Default 'owner' preserves the
    /// historical invite contract. The CHECK constraint on
    /// `invite_tokens.role` enforces the enum at the DB level so
    /// a typo here turns into a 500 rather than a silent
    /// privilege.
    #[serde(default)]
    role: Option<String>,
}

#[derive(Serialize)]
struct CreateInviteResponse {
    id: String,
    /// The plaintext token. Shown ONCE — never recoverable after this
    /// response. The redemption URL embeds it for convenience.
    token: String,
    /// Pre-built share URL: `<frontend_base_url>/?invite=<token>`.
    url: String,
    expires_at: String,
}

#[derive(Serialize)]
struct InviteSummary {
    id: String,
    created_at: String,
    expires_at: String,
    used: bool,
    used_at: Option<String>,
    note: Option<String>,
    /// Role the redeemer will get. Lets the inviter audit which
    /// pending invites are read-only vs owner so they can revoke
    /// the wrong ones before someone redeems.
    role: String,
}

async fn create_invite(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    body: Option<Json<CreateInviteRequest>>,
) -> Result<Json<CreateInviteResponse>, (StatusCode, Json<serde_json::Value>)> {
    let req = body.map(|b| b.0).unwrap_or_default();
    let hours = req
        .expires_in_hours
        .unwrap_or(DEFAULT_EXPIRY_HOURS)
        .clamp(1, MAX_EXPIRY_HOURS);
    let expires_at = Utc::now() + Duration::hours(hours);

    // 32 bytes of OS randomness, URL-safe-encoded so it survives as a
    // query-string param without %-encoding gymnastics.
    let mut raw = [0u8; TOKEN_BYTES];
    OsRng.fill_bytes(&mut raw);
    let token = URL_SAFE_NO_PAD.encode(raw);
    let token_hash = Sha256::digest(token.as_bytes()).to_vec();

    let note = req.note.as_deref().filter(|n| !n.trim().is_empty());

    // Validate role explicitly so a typo returns a useful 400
    // instead of a CHECK-constraint 500 from the DB.
    let role = req.role.as_deref().unwrap_or("owner");
    if role != "owner" && role != "read_only" {
        return Err((
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({
                "error": format!("role must be 'owner' or 'read_only', got {:?}", role)
            })),
        ));
    }

    let row = sqlx::query(
        r#"
        INSERT INTO invite_tokens (token_hash, created_by_user_id, expires_at, note, role)
        VALUES ($1, $2, $3, $4, $5)
        RETURNING id, expires_at
        "#,
    )
    .bind(&token_hash)
    .bind(ctx.user_id)
    .bind(expires_at)
    .bind(note)
    .bind(role)
    .fetch_one(&state.db)
    .await
    .map_err(|e| {
        tracing::error!("Failed to insert invite_token: {}", e);
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": "Failed to mint invite"})),
        )
    })?;

    let id: Uuid = row.get("id");
    let stored_expires: DateTime<Utc> = row.get("expires_at");
    let url = format!(
        "{}/?invite={}",
        state.config.frontend_base_url.trim_end_matches('/'),
        token,
    );

    tracing::info!(
        "User {} minted invite {} (expires {})",
        ctx.user_id,
        id,
        stored_expires
    );

    Ok(Json(CreateInviteResponse {
        id: id.to_string(),
        token,
        url,
        expires_at: stored_expires.to_rfc3339(),
    }))
}

async fn list_invites(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<InviteSummary>> {
    let rows = sqlx::query(
        r#"
        SELECT id, created_at, expires_at, used_at, note, role
        FROM invite_tokens
        WHERE created_by_user_id = $1
        ORDER BY created_at DESC
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| {
                let used_at: Option<DateTime<Utc>> = r.try_get("used_at").ok().flatten();
                InviteSummary {
                    id: r.get::<Uuid, _>("id").to_string(),
                    created_at: r.get::<DateTime<Utc>, _>("created_at").to_rfc3339(),
                    expires_at: r.get::<DateTime<Utc>, _>("expires_at").to_rfc3339(),
                    used: used_at.is_some(),
                    used_at: used_at.map(|t| t.to_rfc3339()),
                    note: r.try_get::<Option<String>, _>("note").ok().flatten(),
                    role: r
                        .try_get::<String, _>("role")
                        .unwrap_or_else(|_| "owner".to_string()),
                }
            })
            .collect(),
    )
}

async fn revoke_invite(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<Uuid>,
) -> StatusCode {
    // Revoke = delete. Already-redeemed invites are kept (used_at row
    // is a record of who joined when), so we filter to live ones only.
    let result = sqlx::query(
        "DELETE FROM invite_tokens WHERE id = $1 AND created_by_user_id = $2 AND used_at IS NULL",
    )
    .bind(id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;
    match result {
        Ok(r) if r.rows_affected() == 0 => StatusCode::NOT_FOUND,
        Ok(_) => StatusCode::NO_CONTENT,
        Err(e) => {
            tracing::error!("Failed to revoke invite: {}", e);
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

/// Verify + atomically consume an invite token. Returns the role
/// the redeemer should inherit ('owner' or 'read_only') so the
/// caller (register handler in `session.rs`) can stamp it onto the
/// new user. Uses constant-time SHA-256 lookup (`token_hash` is the
/// UNIQUE index).
pub async fn consume_invite(
    db: &sqlx::PgPool,
    plaintext_token: &str,
    redeeming_user_id: Uuid,
) -> Result<String, &'static str> {
    let token_hash = Sha256::digest(plaintext_token.as_bytes()).to_vec();
    let row = sqlx::query(
        r#"
        UPDATE invite_tokens
        SET used_at = NOW(), used_by_user_id = $2
        WHERE token_hash = $1
          AND used_at IS NULL
          AND expires_at > NOW()
        RETURNING id, role
        "#,
    )
    .bind(&token_hash)
    .bind(redeeming_user_id)
    .fetch_optional(db)
    .await
    .map_err(|e| {
        tracing::error!("invite consume db error: {}", e);
        "DB error"
    })?;
    let row = match row {
        Some(r) => r,
        None => return Err("Invalid, expired, or already-used invite token."),
    };
    let role: String = row.try_get("role").unwrap_or_else(|_| "owner".to_string());
    Ok(role)
}
