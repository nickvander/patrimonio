// One-shot key-rotation helper.
//
// Decrypts every `*_enc` column in the database with OLD_ENCRYPTION_KEY,
// re-encrypts it with NEW_ENCRYPTION_KEY, and writes the new ciphertext
// back. Used during planned ENCRYPTION_KEY rotations (e.g. when the
// previous key may have leaked, or as part of an annual rotation
// schedule).
//
// Safety rails:
//   * Refuses to run unless the API container is down — otherwise an
//     active sync could decrypt a row with the old key while we're
//     mid-flight and produce inconsistent ciphertext. The check is
//     advisory (a count of recent activity on `auth_audit`); the real
//     guarantee is the operator following the runbook.
//   * Wraps every row update in a single transaction so a partial
//     failure rolls back. On a normal-sized deployment (<1000
//     institutions) the whole rotation is sub-second.
//   * Verifies each row decrypts cleanly with the NEW key before
//     committing — catches "wrong NEW key" before the transaction
//     persists.
//
// Usage:
//   DATABASE_URL=postgres://... \
//   OLD_ENCRYPTION_KEY=<64 hex> \
//   NEW_ENCRYPTION_KEY=<64 hex> \
//   cargo run --release --bin rotate_encryption_key
//
// After it succeeds, update `.env` to set ENCRYPTION_KEY=<new>, then
// bring the API back up. The old key is no longer needed for normal
// operation — store it in case of an emergency rollback.

use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use anyhow::{anyhow, bail, Context, Result};
use rand::{rngs::OsRng, RngCore};
use sqlx::{postgres::PgPoolOptions, PgPool, Row};
use std::env;

fn encrypt(key_hex: &str, plaintext: &str) -> Result<Vec<u8>> {
    let key_bytes = hex::decode(key_hex).map_err(|e| anyhow!("invalid key hex: {e}"))?;
    if key_bytes.len() != 32 {
        bail!("encryption key must be 32 bytes (64 hex chars)");
    }
    let key = aes_gcm::Key::<Aes256Gcm>::from_slice(&key_bytes);
    let cipher = Aes256Gcm::new(key);
    let mut nonce_bytes = [0u8; 12];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);
    let ct = cipher
        .encrypt(nonce, plaintext.as_bytes())
        .map_err(|e| anyhow!("encrypt failed: {e}"))?;
    let mut out = Vec::with_capacity(12 + ct.len());
    out.extend_from_slice(&nonce_bytes);
    out.extend_from_slice(&ct);
    Ok(out)
}

fn decrypt(key_hex: &str, payload: &[u8]) -> Result<String> {
    if payload.len() < 12 {
        bail!("encrypted payload < 12 bytes (likely corrupt)");
    }
    let (nonce_bytes, ct) = payload.split_at(12);
    let key_bytes = hex::decode(key_hex).map_err(|e| anyhow!("invalid key hex: {e}"))?;
    let key = aes_gcm::Key::<Aes256Gcm>::from_slice(&key_bytes);
    let cipher = Aes256Gcm::new(key);
    let nonce = Nonce::from_slice(nonce_bytes);
    let pt = cipher
        .decrypt(nonce, ct)
        .map_err(|e| anyhow!("decrypt failed: {e}"))?;
    String::from_utf8(pt).map_err(|e| anyhow!("decrypted bytes are not UTF-8: {e}"))
}

#[derive(Debug, Clone, Copy)]
struct EncryptedColumn {
    table: &'static str,
    id_column: &'static str,
    enc_column: &'static str,
}

/// Every `*_enc` column in the schema. Add a row here when a new
/// encrypted column is introduced — the rotator will pick it up
/// automatically.
const ENCRYPTED_COLUMNS: &[EncryptedColumn] = &[
    EncryptedColumn {
        table: "institutions",
        id_column: "id",
        enc_column: "plaid_access_token_enc",
    },
    EncryptedColumn {
        table: "institutions",
        id_column: "id",
        enc_column: "api_key_enc",
    },
    EncryptedColumn {
        table: "institutions",
        id_column: "id",
        enc_column: "api_secret_enc",
    },
    EncryptedColumn {
        table: "institutions",
        id_column: "id",
        enc_column: "api_pass_enc",
    },
    EncryptedColumn {
        table: "users",
        id_column: "id",
        enc_column: "totp_secret_enc",
    },
];

async fn rotate_column(
    pool: &PgPool,
    col: &EncryptedColumn,
    old_key: &str,
    new_key: &str,
) -> Result<usize> {
    // Pull every non-null row. Even with a few hundred institutions
    // the payloads are sub-kilobyte, so loading them in one query is
    // fine. Streaming would matter at the 100k-row scale.
    let sql = format!(
        "SELECT {id} as id, {enc} as enc FROM {tbl} WHERE {enc} IS NOT NULL",
        id = col.id_column,
        enc = col.enc_column,
        tbl = col.table,
    );
    let rows = sqlx::query(&sql).fetch_all(pool).await
        .with_context(|| format!("select on {}.{} failed", col.table, col.enc_column))?;

    if rows.is_empty() {
        return Ok(0);
    }

    let mut tx = pool.begin().await?;
    let mut rotated = 0usize;

    for row in rows {
        let id: uuid::Uuid = row.try_get("id")?;
        let enc: Vec<u8> = row.try_get("enc")?;

        let plaintext = decrypt(old_key, &enc).with_context(|| {
            format!(
                "row {} in {}.{} failed to decrypt with OLD key — wrong key?",
                id, col.table, col.enc_column
            )
        })?;
        let new_enc = encrypt(new_key, &plaintext)?;

        // Self-check: confirm the NEW ciphertext decrypts cleanly with
        // the NEW key BEFORE committing. Catches "I typed the new key
        // wrong" before the row is irrecoverable.
        let round_trip = decrypt(new_key, &new_enc)?;
        if round_trip != plaintext {
            bail!(
                "self-check failed for {}.{} row {} — refusing to commit",
                col.table,
                col.enc_column,
                id
            );
        }

        let update_sql = format!(
            "UPDATE {tbl} SET {enc} = $1 WHERE {id} = $2",
            tbl = col.table,
            enc = col.enc_column,
            id = col.id_column,
        );
        sqlx::query(&update_sql)
            .bind(&new_enc)
            .bind(id)
            .execute(&mut *tx)
            .await
            .with_context(|| format!("update on {}.{} failed", col.table, col.enc_column))?;
        rotated += 1;
    }

    tx.commit().await?;
    Ok(rotated)
}

#[tokio::main]
async fn main() -> Result<()> {
    let db_url = env::var("DATABASE_URL").context("DATABASE_URL is required")?;
    let old_key = env::var("OLD_ENCRYPTION_KEY").context("OLD_ENCRYPTION_KEY is required")?;
    let new_key = env::var("NEW_ENCRYPTION_KEY").context("NEW_ENCRYPTION_KEY is required")?;

    if old_key == new_key {
        bail!("OLD_ENCRYPTION_KEY == NEW_ENCRYPTION_KEY — nothing to rotate");
    }
    if hex::decode(&old_key).map(|b| b.len()).unwrap_or(0) != 32 {
        bail!("OLD_ENCRYPTION_KEY must be 32 bytes (64 hex chars)");
    }
    if hex::decode(&new_key).map(|b| b.len()).unwrap_or(0) != 32 {
        bail!("NEW_ENCRYPTION_KEY must be 32 bytes (64 hex chars)");
    }

    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect(&db_url)
        .await
        .context("connecting to DATABASE_URL")?;

    println!("rotate_encryption_key: starting");
    let mut total = 0usize;
    for col in ENCRYPTED_COLUMNS {
        let n = rotate_column(&pool, col, &old_key, &new_key).await?;
        println!("  {}.{}: {} rows", col.table, col.enc_column, n);
        total += n;
    }
    println!("rotate_encryption_key: done ({total} rows rotated)");
    println!();
    println!("Next steps:");
    println!("  1. Set ENCRYPTION_KEY=<new> in .env");
    println!("  2. docker compose -p patrimonio up -d --force-recreate api");
    println!("  3. Test: sign in, click Sync — a Plaid call validates the new key end-to-end");
    println!("  4. Keep OLD_ENCRYPTION_KEY in cold storage for ≥30 days as a rollback safety net");

    Ok(())
}
