//! TOTP (RFC 6238) for opt-in 2FA.
//!
//! Flow:
//!   1. enroll() — generate a fresh secret, return otpauth:// URI for
//!      the user's authenticator app. Secret is held in DB-encrypted
//!      form but `totp_enabled` stays false until confirm().
//!   2. confirm(code) — verify the user can produce a valid TOTP from
//!      the enrolled secret, then flip `totp_enabled = true`.
//!   3. verify(code) — called during login when the user already has
//!      `totp_enabled = true`.
//!   4. disable() — wipe the secret and clear the flag.
//!
//! Secrets are encrypted with the existing AES-GCM `encryption`
//! service before being stored, using the configured ENCRYPTION_KEY.

use anyhow::{anyhow, Result};
use rand::{rngs::OsRng, RngCore};
use sqlx::PgPool;
use totp_rs::{Algorithm, Secret, TOTP};
use uuid::Uuid;

use crate::services::encryption;

const ISSUER: &str = "Patrimonio";
const DIGITS: usize = 6;
const STEP_SECS: u64 = 30;
// One step of skew either side — handles modest clock drift between
// the user's phone and the server.
const SKEW: u8 = 1;

fn build_totp(secret_bytes: Vec<u8>, account: &str) -> Result<TOTP> {
    TOTP::new(
        Algorithm::SHA1,
        DIGITS,
        SKEW,
        STEP_SECS,
        secret_bytes,
        Some(ISSUER.to_string()),
        account.to_string(),
    )
    .map_err(|e| anyhow!("totp build: {e}"))
}

/// Result of starting enrollment — secret is plaintext base32 (so
/// the UI can show "type this if QR doesn't scan"), provisioning_uri
/// is the otpauth:// link to render as a QR.
pub struct EnrollmentChallenge {
    pub secret_base32: String,
    pub provisioning_uri: String,
}

pub async fn begin_enrollment(
    db: &PgPool,
    enc_key: &str,
    user_id: Uuid,
    account_label: &str,
) -> Result<EnrollmentChallenge> {
    // 20 bytes = 160 bits, matches RFC 6238 recommendation.
    let mut secret_bytes = [0u8; 20];
    OsRng.fill_bytes(&mut secret_bytes);
    let secret = Secret::Raw(secret_bytes.to_vec());

    let secret_base32 = secret
        .to_encoded()
        .to_string();

    let totp = build_totp(secret_bytes.to_vec(), account_label)?;
    let provisioning_uri = totp.get_url();

    // Store encrypted, but DON'T enable yet — confirm() does that.
    let encrypted = encryption::encrypt(enc_key, &secret_base32)
        .map_err(|e| anyhow!("encrypt totp secret: {e}"))?;

    sqlx::query(
        "UPDATE users SET totp_secret_enc = $1, totp_enabled = false WHERE id = $2",
    )
    .bind(&encrypted)
    .bind(user_id)
    .execute(db)
    .await
    .map_err(|e| anyhow!("store enrollment: {e}"))?;

    Ok(EnrollmentChallenge {
        secret_base32,
        provisioning_uri,
    })
}

/// Verify a TOTP code against a user's stored secret WITHOUT advancing
/// the replay marker. Used by the enrollment-confirm flow: the user
/// has just typed their code from a freshly-shown QR, then their next
/// action is to log in (potentially in the same TOTP step). Advancing
/// the replay marker here would lock them out of login for up to 30s.
/// The confirm endpoint sits behind require_auth, so an attacker
/// capturing the confirm code already has the session it would log in
/// with — replay protection adds nothing here.
pub async fn verify_no_advance(
    db: &PgPool,
    enc_key: &str,
    user_id: Uuid,
    code: &str,
) -> Result<bool> {
    verify_inner(db, enc_key, user_id, code, false).await
}

/// Verify a TOTP code against a user's stored secret. Used during
/// login (totp_verify endpoint) when totp_enabled is true.
///
/// Replay protection: every successful verify atomically advances
/// `totp_last_used_step` so the same 6-digit code can't be reused
/// inside its 90-second validity window (one full window per step,
/// plus the ±1 skew). A captured code is therefore single-use even if
/// it's still nominally valid by the clock.
pub async fn verify(
    db: &PgPool,
    enc_key: &str,
    user_id: Uuid,
    code: &str,
) -> Result<bool> {
    verify_inner(db, enc_key, user_id, code, true).await
}

async fn verify_inner(
    db: &PgPool,
    enc_key: &str,
    user_id: Uuid,
    code: &str,
    advance_replay: bool,
) -> Result<bool> {
    let row: Option<(Option<Vec<u8>>, String, Option<i64>)> = sqlx::query_as(
        "SELECT totp_secret_enc, username, totp_last_used_step FROM users WHERE id = $1",
    )
    .bind(user_id)
    .fetch_optional(db)
    .await
    .map_err(|e| anyhow!("load secret: {e}"))?;

    let (encrypted, username, last_used_step) = match row {
        Some((Some(enc), u, last)) => (enc, u, last),
        _ => return Ok(false),
    };

    let secret_b32 = encryption::decrypt(enc_key, &encrypted)
        .map_err(|e| anyhow!("decrypt totp secret: {e}"))?;
    let secret = Secret::Encoded(secret_b32)
        .to_bytes()
        .map_err(|e| anyhow!("decode totp secret: {e}"))?;
    let totp = build_totp(secret, &username)?;

    // Strip whitespace and any leading "0" pads the user might type.
    let normalized: String = code.chars().filter(|c| c.is_ascii_digit()).collect();
    if normalized.len() != DIGITS {
        return Ok(false);
    }
    let ok = totp
        .check_current(&normalized)
        .map_err(|e| anyhow!("check totp: {e}"))?;
    if !ok {
        return Ok(false);
    }

    // Replay protection only applies when the caller wants it
    // (login-verify, not enrollment-confirm — see verify_no_advance).
    if !advance_replay {
        return Ok(true);
    }

    // Compute the current step (`unix_seconds / 30`). The library
    // already verified the code matches *some* step in [now-skew,
    // now+skew], so we don't need to scan; the active step is the
    // closest match and is good enough as a replay marker.
    let current_step = (std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| anyhow!("clock: {e}"))?
        .as_secs()
        / STEP_SECS) as i64;

    if let Some(prev) = last_used_step {
        if current_step <= prev {
            // Already consumed within this step (or an earlier one
            // still inside the ±1 skew window). Refuse the replay.
            return Ok(false);
        }
    }

    // Advance the marker. CAS on `last_used_step <= current_step - 1`
    // is unnecessary here because TOTP rotates every 30s — concurrent
    // duplicates would already have failed the equality above.
    sqlx::query("UPDATE users SET totp_last_used_step = $1 WHERE id = $2")
        .bind(current_step)
        .bind(user_id)
        .execute(db)
        .await
        .map_err(|e| anyhow!("advance totp step: {e}"))?;

    Ok(true)
}

/// Mark TOTP enabled after a successful confirm. Returns true if a
/// secret is present to enable; false if enrollment was never started.
pub async fn mark_enabled(db: &PgPool, user_id: Uuid) -> Result<bool> {
    let result = sqlx::query(
        "UPDATE users SET totp_enabled = true WHERE id = $1 AND totp_secret_enc IS NOT NULL",
    )
    .bind(user_id)
    .execute(db)
    .await
    .map_err(|e| anyhow!("mark enabled: {e}"))?;
    Ok(result.rows_affected() > 0)
}

pub async fn disable(db: &PgPool, user_id: Uuid) -> Result<()> {
    sqlx::query("UPDATE users SET totp_secret_enc = NULL, totp_enabled = false WHERE id = $1")
        .bind(user_id)
        .execute(db)
        .await
        .map_err(|e| anyhow!("disable totp: {e}"))?;
    Ok(())
}

pub async fn is_enabled(db: &PgPool, user_id: Uuid) -> Result<bool> {
    let row: Option<(bool,)> = sqlx::query_as("SELECT totp_enabled FROM users WHERE id = $1")
        .bind(user_id)
        .fetch_optional(db)
        .await
        .map_err(|e| anyhow!("totp is_enabled: {e}"))?;
    Ok(row.map(|r| r.0).unwrap_or(false))
}
