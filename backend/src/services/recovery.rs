//! Recovery codes for self-service password reset.
//!
//! On bootstrap (and on explicit regeneration) we generate N codes,
//! display them to the user exactly once, and store only the SHA-256
//! hash. A code redeems for a one-time password reset.
//!
//! Code format: 3 groups of 4 base32 chars separated by hyphens — e.g.
//! `XK4T-9PMQ-7HZL`. 60 bits of entropy, easy to read aloud or copy.

use anyhow::{anyhow, Result};
use rand::{rngs::OsRng, RngCore};
use sha2::{Digest, Sha256};
use sqlx::PgPool;
use uuid::Uuid;

/// How many codes we issue per regeneration. Bitwarden uses 1
/// long code; GitHub/Authy use 10–12 short codes. We split the
/// difference at 8.
pub const CODES_PER_BATCH: usize = 8;

const BASE32_ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZ23456789"; // Crockford-ish, no I/O/1/0

fn random_code() -> String {
    // 12 base32 chars = 60 bits. Group as 4-4-4 with hyphens.
    let mut bytes = [0u8; 12];
    OsRng.fill_bytes(&mut bytes);
    let mut out = String::with_capacity(14);
    for (i, b) in bytes.iter().enumerate() {
        if i == 4 || i == 8 {
            out.push('-');
        }
        out.push(BASE32_ALPHABET[(*b as usize) % BASE32_ALPHABET.len()] as char);
    }
    out
}

fn hash_code(raw: &str) -> Vec<u8> {
    // Normalize so users can paste with or without hyphens, mixed case.
    let normalized: String = raw
        .chars()
        .filter(|c| !c.is_whitespace() && *c != '-')
        .map(|c| c.to_ascii_uppercase())
        .collect();
    Sha256::digest(normalized.as_bytes()).to_vec()
}

/// Replace any unused codes for the user with a freshly generated
/// batch. Returns the plaintext codes (caller must display to user).
pub async fn regenerate(db: &PgPool, user_id: Uuid) -> Result<Vec<String>> {
    // Atomically drop the old set and insert the new one in one txn.
    let mut tx = db.begin().await?;
    sqlx::query("DELETE FROM recovery_codes WHERE user_id = $1 AND used_at IS NULL")
        .bind(user_id)
        .execute(&mut *tx)
        .await
        .map_err(|e| anyhow!("regenerate clear: {e}"))?;

    let mut codes = Vec::with_capacity(CODES_PER_BATCH);
    for _ in 0..CODES_PER_BATCH {
        let code = random_code();
        let hash = hash_code(&code);
        sqlx::query("INSERT INTO recovery_codes (user_id, code_hash) VALUES ($1, $2)")
            .bind(user_id)
            .bind(&hash)
            .execute(&mut *tx)
            .await
            .map_err(|e| anyhow!("regenerate insert: {e}"))?;
        codes.push(code);
    }
    tx.commit().await?;
    Ok(codes)
}

/// Read-only lookup: which user does a given unused code belong to?
/// Used by the recover endpoint to verify the code belongs to the
/// supplied username BEFORE marking it consumed. A wrong username
/// must not burn the code, otherwise an attacker who knows a code
/// could lock the legitimate user out by attempting it against bogus
/// usernames until all 8 codes are consumed.
pub async fn lookup_owner(db: &PgPool, raw_code: &str) -> Result<Option<Uuid>> {
    let hash = hash_code(raw_code);
    let row: Option<(Uuid,)> = sqlx::query_as(
        "SELECT user_id FROM recovery_codes WHERE code_hash = $1 AND used_at IS NULL",
    )
    .bind(&hash)
    .fetch_optional(db)
    .await
    .map_err(|e| anyhow!("lookup_owner: {e}"))?;
    Ok(row.map(|r| r.0))
}

/// Atomically mark a code consumed. The UPDATE's `WHERE used_at IS
/// NULL` clause gives us race-free single-use semantics — two
/// concurrent verifiers can both call this, only one wins.
/// Returns true if this caller was the one who burned the code.
pub async fn consume(db: &PgPool, raw_code: &str, ip: Option<&str>) -> Result<bool> {
    let hash = hash_code(raw_code);
    let result = sqlx::query(
        r#"
        UPDATE recovery_codes
           SET used_at = NOW(), used_ip = $1
         WHERE code_hash = $2 AND used_at IS NULL
        "#,
    )
    .bind(ip)
    .bind(&hash)
    .execute(db)
    .await
    .map_err(|e| anyhow!("consume: {e}"))?;
    Ok(result.rows_affected() > 0)
}

pub async fn unused_count(db: &PgPool, user_id: Uuid) -> Result<i64> {
    let n: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM recovery_codes WHERE user_id = $1 AND used_at IS NULL",
    )
    .bind(user_id)
    .fetch_one(db)
    .await?;
    Ok(n)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn code_format_and_hash_stable_across_normalizations() {
        let h1 = hash_code("ABCD-EFGH-JKLM");
        let h2 = hash_code("abcd efgh jklm");
        let h3 = hash_code("abcdefghjklm");
        assert_eq!(h1, h2);
        assert_eq!(h1, h3);
    }

    #[test]
    fn random_code_has_correct_shape() {
        let c = random_code();
        assert_eq!(c.len(), 14);
        let parts: Vec<&str> = c.split('-').collect();
        assert_eq!(parts.len(), 3);
        for p in parts {
            assert_eq!(p.len(), 4);
            assert!(p.chars().all(|ch| BASE32_ALPHABET.contains(&(ch as u8))));
        }
    }
}
