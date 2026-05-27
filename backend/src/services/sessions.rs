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
    /// 'owner' or 'read_only'. Threaded into `AuthContext` so
    /// `require_owner` can 403 mutating requests from read-only
    /// users without re-querying the DB per request.
    pub role: String,
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

    // Join to users to pull the role out in the same round-trip.
    // The role is needed by `require_owner` on every mutating
    // request — fetching it here avoids a per-request lookup.
    let row: Option<(Uuid, Uuid, DateTime<Utc>, Option<DateTime<Utc>>, bool, String)> =
        sqlx::query_as(
            r#"
            SELECT s.id, s.user_id, s.expires_at, s.revoked_at, s.pending_totp,
                   u.role
            FROM user_sessions s
            JOIN users u ON u.id = s.user_id
            WHERE s.token_hash = $1
            "#,
        )
        .bind(&hash)
        .fetch_optional(db)
        .await
        .map_err(|e| anyhow!("validate_and_touch lookup: {}", e))?;

    let Some((session_id, user_id, expires_at, revoked_at, pending_totp, role)) = row else {
        return Ok(None);
    };
    if revoked_at.is_some() {
        return Ok(None);
    }
    if expires_at < Utc::now() {
        return Ok(None);
    }

    // Throttle the write to once per minute. Every authenticated
    // request validates the session, so without the predicate we'd
    // emit one UPDATE per request — write amplification that
    // serializes on the row under load.
    sqlx::query(
        "UPDATE user_sessions
            SET last_seen_at = NOW()
          WHERE id = $1
            AND last_seen_at < NOW() - INTERVAL '1 minute'",
    )
    .bind(session_id)
    .execute(db)
    .await
    .map_err(|e| anyhow!("validate_and_touch touch: {}", e))?;

    Ok(Some(ValidatedSession {
        session_id,
        user_id,
        pending_totp,
        role,
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

/// One row of the "Active sessions" list shown on the Security page.
/// `is_current` is decided by the caller — the session table doesn't
/// know which session ID the requester is presenting.
#[derive(Debug)]
pub struct ActiveSessionRow {
    pub id: Uuid,
    pub created_at: DateTime<Utc>,
    pub last_seen_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub user_agent: Option<String>,
    pub ip_address: Option<String>,
}

/// Return every live (unrevoked, unexpired, non-pending) session for a
/// user, newest-active first. Pending-TOTP sessions are excluded —
/// they're throwaway and would clutter the list during a login flow.
pub async fn list_active(db: &PgPool, user_id: Uuid) -> Result<Vec<ActiveSessionRow>> {
    let rows: Vec<(
        Uuid,
        DateTime<Utc>,
        DateTime<Utc>,
        DateTime<Utc>,
        Option<String>,
        Option<String>,
    )> = sqlx::query_as(
        r#"
        SELECT id, created_at, last_seen_at, expires_at, user_agent, ip_address
        FROM user_sessions
        WHERE user_id = $1
          AND revoked_at IS NULL
          AND expires_at > NOW()
          AND pending_totp = false
        ORDER BY last_seen_at DESC
        "#,
    )
    .bind(user_id)
    .fetch_all(db)
    .await
    .map_err(|e| anyhow!("list_active: {}", e))?;

    Ok(rows
        .into_iter()
        .map(|(id, created_at, last_seen_at, expires_at, user_agent, ip_address)| {
            ActiveSessionRow {
                id,
                created_at,
                last_seen_at,
                expires_at,
                user_agent,
                ip_address,
            }
        })
        .collect())
}

/// Revoke a single session by its DB id, but only if it belongs to
/// the supplied user. Returns true if a row was actually flipped — the
/// caller can use that to distinguish "not found / not yours" from
/// "already revoked".
pub async fn revoke_by_id_for_user(
    db: &PgPool,
    session_id: Uuid,
    user_id: Uuid,
) -> Result<bool> {
    let result = sqlx::query(
        "UPDATE user_sessions
            SET revoked_at = NOW()
          WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL",
    )
    .bind(session_id)
    .bind(user_id)
    .execute(db)
    .await
    .map_err(|e| anyhow!("revoke_by_id_for_user: {}", e))?;
    Ok(result.rows_affected() > 0)
}

/// Revoke every live session for the user EXCEPT the one identified
/// by `keep_session_id`. Returns the number of sessions revoked so
/// the UI can report "Signed out of N other devices".
pub async fn revoke_all_except(
    db: &PgPool,
    user_id: Uuid,
    keep_session_id: Uuid,
) -> Result<u64> {
    let result = sqlx::query(
        "UPDATE user_sessions
            SET revoked_at = NOW()
          WHERE user_id = $1
            AND id <> $2
            AND revoked_at IS NULL",
    )
    .bind(user_id)
    .bind(keep_session_id)
    .execute(db)
    .await
    .map_err(|e| anyhow!("revoke_all_except: {}", e))?;
    Ok(result.rows_affected())
}
