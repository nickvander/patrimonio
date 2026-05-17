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
    .map_err(|e| anyhow!("totp build: {}", e))
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
        .map_err(|e| anyhow!("encrypt totp secret: {}", e))?;

    sqlx::query(
        "UPDATE users SET totp_secret_enc = $1, totp_enabled = false WHERE id = $2",
    )
    .bind(&encrypted)
    .bind(user_id)
    .execute(db)
    .await
    .map_err(|e| anyhow!("store enrollment: {}", e))?;

    Ok(EnrollmentChallenge {
        secret_base32,
        provisioning_uri,
    })
}

/// Verify a TOTP code against a user's stored secret. Used both during
/// the confirm step of enrollment and during login when totp_enabled.
pub async fn verify(
    db: &PgPool,
    enc_key: &str,
    user_id: Uuid,
    code: &str,
) -> Result<bool> {
    let row: Option<(Option<Vec<u8>>, String)> =
        sqlx::query_as("SELECT totp_secret_enc, username FROM users WHERE id = $1")
            .bind(user_id)
            .fetch_optional(db)
            .await
            .map_err(|e| anyhow!("load secret: {}", e))?;

    let (encrypted, username) = match row {
        Some((Some(enc), u)) => (enc, u),
        _ => return Ok(false),
    };

    let secret_b32 = encryption::decrypt(enc_key, &encrypted)
        .map_err(|e| anyhow!("decrypt totp secret: {}", e))?;
    let secret = Secret::Encoded(secret_b32)
        .to_bytes()
        .map_err(|e| anyhow!("decode totp secret: {}", e))?;
    let totp = build_totp(secret, &username)?;

    // Strip whitespace and any leading "0" pads the user might type.
    let normalized: String = code.chars().filter(|c| c.is_ascii_digit()).collect();
    if normalized.len() != DIGITS {
        return Ok(false);
    }
    totp.check_current(&normalized)
        .map_err(|e| anyhow!("check totp: {}", e))
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
    .map_err(|e| anyhow!("mark enabled: {}", e))?;
    Ok(result.rows_affected() > 0)
}

pub async fn disable(db: &PgPool, user_id: Uuid) -> Result<()> {
    sqlx::query("UPDATE users SET totp_secret_enc = NULL, totp_enabled = false WHERE id = $1")
        .bind(user_id)
        .execute(db)
        .await
        .map_err(|e| anyhow!("disable totp: {}", e))?;
    Ok(())
}

pub async fn is_enabled(db: &PgPool, user_id: Uuid) -> Result<bool> {
    let row: Option<(bool,)> = sqlx::query_as("SELECT totp_enabled FROM users WHERE id = $1")
        .bind(user_id)
        .fetch_optional(db)
        .await
        .map_err(|e| anyhow!("totp is_enabled: {}", e))?;
    Ok(row.map(|r| r.0).unwrap_or(false))
}
