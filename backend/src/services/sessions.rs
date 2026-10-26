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
    create_session_inner(
        db,
        user_id,
        user_agent,
        ip,
        false,
        Duration::days(SESSION_TTL_DAYS),
    )
    .await
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
    .map_err(|e| anyhow!("create_session: {e}"))?;

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
    // one-off sqlx row tuple, materialized once at this query_as call site
    #[allow(clippy::type_complexity)]
    let row: Option<(
        Uuid,
        Uuid,
        DateTime<Utc>,
        Option<DateTime<Utc>>,
        bool,
        String,
    )> = sqlx::query_as(
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
    .map_err(|e| anyhow!("validate_and_touch lookup: {e}"))?;

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
    .map_err(|e| anyhow!("validate_and_touch touch: {e}"))?;

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
    .map_err(|e| anyhow!("revoke_by_token: {e}"))?;
    Ok(())
}

pub async fn revoke_all_for_user(db: &PgPool, user_id: Uuid) -> Result<()> {
    sqlx::query(
        "UPDATE user_sessions SET revoked_at = NOW() WHERE user_id = $1 AND revoked_at IS NULL",
    )
    .bind(user_id)
    .execute(db)
    .await
    .map_err(|e| anyhow!("revoke_all_for_user: {e}"))?;
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
    // one-off sqlx row tuple, materialized once at this query_as call site
    #[allow(clippy::type_complexity)]
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
    .map_err(|e| anyhow!("list_active: {e}"))?;

    Ok(rows
        .into_iter()
        .map(
            |(id, created_at, last_seen_at, expires_at, user_agent, ip_address)| ActiveSessionRow {
                id,
                created_at,
                last_seen_at,
                expires_at,
                user_agent,
                ip_address,
            },
        )
        .collect())
}

/// Revoke a single session by its DB id, but only if it belongs to
/// the supplied user. Returns true if a row was actually flipped — the
/// caller can use that to distinguish "not found / not yours" from
/// "already revoked".
pub async fn revoke_by_id_for_user(db: &PgPool, session_id: Uuid, user_id: Uuid) -> Result<bool> {
    let result = sqlx::query(
        "UPDATE user_sessions
            SET revoked_at = NOW()
          WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL",
    )
    .bind(session_id)
    .bind(user_id)
    .execute(db)
    .await
    .map_err(|e| anyhow!("revoke_by_id_for_user: {e}"))?;
    Ok(result.rows_affected() > 0)
}

/// Revoke every live session for the user EXCEPT the one identified
/// by `keep_session_id`. Returns the number of sessions revoked so
/// the UI can report "Signed out of N other devices".
pub async fn revoke_all_except(db: &PgPool, user_id: Uuid, keep_session_id: Uuid) -> Result<u64> {
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
    .map_err(|e| anyhow!("revoke_all_except: {e}"))?;
    Ok(result.rows_affected())
}

// =============================================================================
// Personal Access Tokens (PATs) — `pat_<base64url>`
// =============================================================================

pub const API_TOKEN_PREFIX: &str = "pat_";

pub struct CreatedApiToken {
    pub id: Uuid,
    pub name: String,
    pub token: String,
    pub token_prefix: String,
    pub scope: String,
    pub created_at: DateTime<Utc>,
    pub expires_at: Option<DateTime<Utc>>,
}

pub struct ValidatedApiToken {
    pub token_id: Uuid,
    pub user_id: Uuid,
    pub scope: String,
    /// Effective role threaded into `AuthContext`. A `read_only`-scoped
    /// PAT forces `role = "read_only"` even if the owning user is `"owner"`,
    /// so `require_owner` automatically rejects mutating business routes.
    pub effective_role: String,
}

#[derive(Debug)]
pub struct ApiTokenRow {
    pub id: Uuid,
    pub name: String,
    pub token_prefix: String,
    pub scope: String,
    pub created_at: DateTime<Utc>,
    pub last_used_at: Option<DateTime<Utc>>,
    pub expires_at: Option<DateTime<Utc>>,
}

/// Generate a `pat_<32-byte base64url>` Personal Access Token and store only
/// its 32-byte SHA-256 hash (`token_hash`) plus a 12-char `token_prefix`.
pub async fn create_api_token(
    db: &PgPool,
    user_id: Uuid,
    name: &str,
    scope: &str,
    ttl_days: Option<i64>,
) -> Result<CreatedApiToken> {
    let mut bytes = [0u8; 32];
    OsRng.fill_bytes(&mut bytes);
    let raw = format!("{API_TOKEN_PREFIX}{}", URL_SAFE_NO_PAD.encode(bytes));
    let prefix: String = raw.chars().take(12).collect();
    let hash = hash_token(&raw);
    let expires_at = ttl_days.map(|days| Utc::now() + Duration::days(days));

    let row: (Uuid, DateTime<Utc>) = sqlx::query_as(
        r#"
        INSERT INTO user_api_tokens (user_id, name, token_prefix, token_hash, scope, expires_at)
        VALUES ($1, $2, $3, $4, $5, $6)
        RETURNING id, created_at
        "#,
    )
    .bind(user_id)
    .bind(name)
    .bind(&prefix)
    .bind(&hash)
    .bind(scope)
    .bind(expires_at)
    .fetch_one(db)
    .await
    .map_err(|e| anyhow!("create_api_token: {e}"))?;

    Ok(CreatedApiToken {
        id: row.0,
        name: name.to_string(),
        token: raw,
        token_prefix: prefix,
        scope: scope.to_string(),
        created_at: row.1,
        expires_at,
    })
}

/// Validate a `Bearer pat_...` Personal Access Token and throttle-update its
/// `last_used_at` timestamp (at most once per minute).
pub async fn validate_api_token(db: &PgPool, raw_token: &str) -> Result<Option<ValidatedApiToken>> {
    if !raw_token.starts_with(API_TOKEN_PREFIX) {
        return Ok(None);
    }
    let hash = hash_token(raw_token);

    #[allow(clippy::type_complexity)]
    let row: Option<(
        Uuid,
        Uuid,
        String,
        Option<DateTime<Utc>>,
        Option<DateTime<Utc>>,
        String,
        bool,
    )> = sqlx::query_as(
        r#"
        SELECT t.id, t.user_id, t.scope, t.expires_at, t.revoked_at,
               u.role, u.is_active
        FROM user_api_tokens t
        JOIN users u ON u.id = t.user_id
        WHERE t.token_hash = $1
        "#,
    )
    .bind(&hash)
    .fetch_optional(db)
    .await
    .map_err(|e| anyhow!("validate_api_token lookup: {e}"))?;

    let Some((token_id, user_id, scope, expires_at, revoked_at, user_role, is_active)) = row else {
        return Ok(None);
    };
    if !is_active || revoked_at.is_some() {
        return Ok(None);
    }
    if expires_at.is_some_and(|exp| exp < Utc::now()) {
        return Ok(None);
    }

    sqlx::query(
        r#"
        UPDATE user_api_tokens
           SET last_used_at = NOW()
         WHERE id = $1
           AND (last_used_at IS NULL OR last_used_at < NOW() - INTERVAL '1 minute')
        "#,
    )
    .bind(token_id)
    .execute(db)
    .await
    .map_err(|e| anyhow!("validate_api_token touch: {e}"))?;

    let effective_role = if scope == "read_write" && user_role == "owner" {
        "owner".to_string()
    } else {
        "read_only".to_string()
    };

    Ok(Some(ValidatedApiToken {
        token_id,
        user_id,
        scope,
        effective_role,
    }))
}

pub async fn list_active_api_tokens(db: &PgPool, user_id: Uuid) -> Result<Vec<ApiTokenRow>> {
    #[allow(clippy::type_complexity)]
    let rows: Vec<(
        Uuid,
        String,
        String,
        String,
        DateTime<Utc>,
        Option<DateTime<Utc>>,
        Option<DateTime<Utc>>,
    )> = sqlx::query_as(
        r#"
        SELECT id, name, token_prefix, scope, created_at, last_used_at, expires_at
        FROM user_api_tokens
        WHERE user_id = $1
          AND revoked_at IS NULL
          AND (expires_at IS NULL OR expires_at > NOW())
        ORDER BY created_at DESC
        "#,
    )
    .bind(user_id)
    .fetch_all(db)
    .await
    .map_err(|e| anyhow!("list_active_api_tokens: {e}"))?;

    Ok(rows
        .into_iter()
        .map(
            |(id, name, token_prefix, scope, created_at, last_used_at, expires_at)| ApiTokenRow {
                id,
                name,
                token_prefix,
                scope,
                created_at,
                last_used_at,
                expires_at,
            },
        )
        .collect())
}

pub async fn revoke_api_token_for_user(db: &PgPool, token_id: Uuid, user_id: Uuid) -> Result<bool> {
    let result = sqlx::query(
        r#"
        UPDATE user_api_tokens
           SET revoked_at = NOW()
         WHERE id = $1 AND user_id = $2 AND revoked_at IS NULL
        "#,
    )
    .bind(token_id)
    .bind(user_id)
    .execute(db)
    .await
    .map_err(|e| anyhow!("revoke_api_token_for_user: {e}"))?;
    Ok(result.rows_affected() > 0)
}
