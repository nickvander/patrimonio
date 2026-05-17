use anyhow::{anyhow, Result};
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use chrono::{DateTime, Duration, Utc};
use rand::{rngs::OsRng, RngCore};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use uuid::Uuid;

/// Cookie name carrying the opaque session token in the browser.
pub const COOKIE_NAME: &str = "patrimonio_session";

/// Sliding session lifetime. Each authenticated request bumps
/// `last_seen_at`; sessions inactive past this window are rejected.
pub const SESSION_TTL_DAYS: i64 = 30;

/// Pending-TOTP sessions are deliberately short-lived. If the user
/// doesn't enter their code quickly the password step has to be
/// repeated.
pub const PENDING_TOTP_TTL_MINUTES: i64 = 5;

/// Generate a 32-byte random token, return (raw_token, sha256_hash).
/// Raw token is the value placed in the cookie; only the hash is stored.
fn generate_token() -> (String, Vec<u8>) {
    let mut bytes = [0u8; 32];
    OsRng.fill_bytes(&mut bytes);
    let raw = URL_SAFE_NO_PAD.encode(bytes);
    let hash = Sha256::digest(raw.as_bytes()).to_vec();
    (raw, hash)
}

fn hash_token(raw: &str) -> Vec<u8> {
    Sha256::digest(raw.as_bytes()).to_vec()
}

pub struct CreatedSession {
    pub token: String,
    pub expires_at: DateTime<Utc>,
}

pub async fn create_session(
    db: &PgPool,
    user_id: Uuid,
    user_agent: Option<&str>,
    ip: Option<&str>,
) -> Result<CreatedSession> {
    create_session_inner(db, user_id, user_agent, ip, false, Duration::days(SESSION_TTL_DAYS)).await
}

/// Issue a short-lived session that is NOT yet accepted by
/// require_auth. Used between the password step and TOTP verification.
pub async fn create_pending_totp_session(
    db: &PgPool,
    user_id: Uuid,
    user_agent: Option<&str>,
    ip: Option<&str>,
) -> Result<CreatedSession> {
    create_session_inner(
        db,
        user_id,
        user_agent,
        ip,
        true,
        Duration::minutes(PENDING_TOTP_TTL_MINUTES),
    )
    .await
}

async fn create_session_inner(
    db: &PgPool,
    user_id: Uuid,
    user_agent: Option<&str>,
    ip: Option<&str>,
    pending_totp: bool,
    ttl: Duration,
) -> Result<CreatedSession> {
    let (raw, hash) = generate_token();
    let expires_at = Utc::now() + ttl;

    sqlx::query(
        r#"
        INSERT INTO user_sessions (user_id, token_hash, expires_at, user_agent, ip_address, pending_totp)
        VALUES ($1, $2, $3, $4, $5, $6)
        "#,
    )
    .bind(user_id)
    .bind(&hash)
    .bind(expires_at)
    .bind(user_agent)
    .bind(ip)
    .bind(pending_totp)
    .execute(db)
    .await
    .map_err(|e| anyhow!("create_session: {}", e))?;

    Ok(CreatedSession {
        token: raw,
        expires_at,
    })
}

pub struct ValidatedSession {
    pub session_id: Uuid,
    pub user_id: Uuid,
    pub pending_totp: bool,
}

/// Look up and refresh a session by its raw cookie token. Returns None
/// if the token is unknown, expired, or revoked. Side-effect: bumps
/// last_seen_at on success.
///
/// Pending-TOTP sessions are returned to the caller; it is the
/// caller's job (e.g. `require_auth`) to refuse them everywhere
/// except the TOTP verify endpoint.
pub async fn validate_and_touch(db: &PgPool, raw_token: &str) -> Result<Option<ValidatedSession>> {
    let hash = hash_token(raw_token);

    let row: Option<(Uuid, Uuid, DateTime<Utc>, Option<DateTime<Utc>>, bool)> = sqlx::query_as(
        r#"
        SELECT id, user_id, expires_at, revoked_at, pending_totp
        FROM user_sessions
        WHERE token_hash = $1
        "#,
    )
    .bind(&hash)
    .fetch_optional(db)
    .await
    .map_err(|e| anyhow!("validate_and_touch lookup: {}", e))?;

    let Some((session_id, user_id, expires_at, revoked_at, pending_totp)) = row else {
        return Ok(None);
    };
    if revoked_at.is_some() {
        return Ok(None);
    }
    if expires_at < Utc::now() {
        return Ok(None);
    }

    sqlx::query("UPDATE user_sessions SET last_seen_at = NOW() WHERE id = $1")
        .bind(session_id)
        .execute(db)
        .await
        .map_err(|e| anyhow!("validate_and_touch touch: {}", e))?;

    Ok(Some(ValidatedSession {
        session_id,
        user_id,
        pending_totp,
    }))
}

pub async fn revoke_by_token(db: &PgPool, raw_token: &str) -> Result<()> {
    let hash = hash_token(raw_token);
    sqlx::query(
        "UPDATE user_sessions SET revoked_at = NOW() WHERE token_hash = $1 AND revoked_at IS NULL",
    )
    .bind(&hash)
    .execute(db)
    .await
    .map_err(|e| anyhow!("revoke_by_token: {}", e))?;
    Ok(())
}

pub async fn revoke_all_for_user(db: &PgPool, user_id: Uuid) -> Result<()> {
    sqlx::query(
        "UPDATE user_sessions SET revoked_at = NOW() WHERE user_id = $1 AND revoked_at IS NULL",
    )
    .bind(user_id)
    .execute(db)
    .await
    .map_err(|e| anyhow!("revoke_all_for_user: {}", e))?;
    Ok(())
}
