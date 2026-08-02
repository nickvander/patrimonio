//! AES-256-GCM encryption for secrets at rest.
//!
//! What it protects: the columns that would let a leaked DB snapshot act on
//! the user's behalf — Plaid access tokens
//! (`institutions.plaid_access_token_enc`), crypto-exchange / Coinbase OAuth
//! credentials (`institutions.api_key_enc` / `api_secret_enc` /
//! `api_pass_enc`), TOTP secrets (`users.totp_secret_enc`), and the
//! passkey step-up state blob (`api/passkeys.rs`).
//!
//! Key format: 64 hex chars decoding to exactly 32 bytes (AES-256), supplied
//! via `ENCRYPTION_KEY`. Both `encrypt` AND `decrypt` validate the decoded
//! length up front and return `Err` on a mismatch — `Key::from_slice` PANICS
//! on a wrong-length slice, and while server boot validates the configured
//! key, other callers (`bin/rotate_encryption_key.rs`, future tools) are not
//! guaranteed to have done so.
//!
//! Wire format: `[12-byte nonce][GCM ciphertext + 16-byte tag]`. The nonce is
//! fresh `OsRng` output per encrypt and is prepended to the ciphertext, so
//! the same plaintext encrypts to a different payload every time. Decrypt
//! splits the first 12 bytes back off; any payload shorter than the nonce is
//! rejected as corrupt rather than sliced out of bounds.
//!
//! Key rotation: `src/bin/rotate_encryption_key.rs` is an offline
//! transactional CLI that re-encrypts every row and verifies each one
//! decrypts with the new key before committing (it carries its own copy of
//! these primitives so it can run standalone).

use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use anyhow::{anyhow, Result};
use rand::{rngs::OsRng, RngCore};

/// AES-256 key length in bytes (64 hex chars).
const KEY_BYTES: usize = 32;
/// GCM nonce length in bytes, prepended to every ciphertext.
const NONCE_BYTES: usize = 12;

/// Decode + validate the hex key. Shared by encrypt and decrypt so the two
/// directions can never disagree about what a valid key is.
fn decode_key(key_hex: &str) -> Result<Vec<u8>> {
    let key_bytes = hex::decode(key_hex).map_err(|e| anyhow!("Invalid key hex: {e}"))?;
    if key_bytes.len() != KEY_BYTES {
        return Err(anyhow!(
            "Encryption key must be exactly 32 bytes (64 hex chars)"
        ));
    }
    Ok(key_bytes)
}

pub fn encrypt(key_hex: &str, plaintext: &str) -> Result<Vec<u8>> {
    let key_bytes = decode_key(key_hex)?;

    let key = aes_gcm::Key::<Aes256Gcm>::from_slice(&key_bytes);
    let cipher = Aes256Gcm::new(key);

    let mut nonce_bytes = [0u8; NONCE_BYTES];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, plaintext.as_bytes())
        .map_err(|e| anyhow!("Encryption error: {e}"))?;

    let mut result = Vec::with_capacity(NONCE_BYTES + ciphertext.len());
    result.extend_from_slice(&nonce_bytes);
    result.extend_from_slice(&ciphertext);

    Ok(result)
}

pub fn decrypt(key_hex: &str, encrypted: &[u8]) -> Result<String> {
    if encrypted.len() < NONCE_BYTES {
        return Err(anyhow!("Encrypted payload is too short"));
    }

    let (nonce_bytes, ciphertext) = encrypted.split_at(NONCE_BYTES);

    // Same length validation as encrypt: `Key::from_slice` panics on a
    // wrong-length slice, which would violate the no-panic rule for any
    // caller that didn't pre-validate its key (server boot does; the
    // rotation CLI and future tools might not).
    let key_bytes = decode_key(key_hex)?;
    let key = aes_gcm::Key::<Aes256Gcm>::from_slice(&key_bytes);
    let cipher = Aes256Gcm::new(key);
    let nonce = Nonce::from_slice(nonce_bytes);

    let plaintext = cipher
        .decrypt(nonce, ciphertext)
        .map_err(|e| anyhow!("Decryption error: {e}"))?;

    String::from_utf8(plaintext).map_err(|e| anyhow!("Invalid UTF-8 in decrypted payload: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A valid 32-byte key as 64 hex chars.
    fn key() -> String {
        "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff".to_string()
    }
    /// A different, equally valid key.
    fn other_key() -> String {
        "ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100".to_string()
    }

    #[test]
    fn roundtrip_recovers_the_plaintext() {
        let ct = encrypt(&key(), "access-token-sandbox-123").expect("encrypt");
        // Wire format: 12-byte nonce + ciphertext (= plaintext len) + 16-byte
        // GCM tag.
        assert_eq!(ct.len(), 12 + "access-token-sandbox-123".len() + 16);
        let pt = decrypt(&key(), &ct).expect("decrypt");
        assert_eq!(pt, "access-token-sandbox-123");
    }

    #[test]
    fn same_plaintext_encrypts_differently_each_time() {
        // Random per-encrypt nonce: two encryptions must not produce the
        // same payload (a repeated nonce under GCM is catastrophic).
        let a = encrypt(&key(), "secret").expect("encrypt a");
        let b = encrypt(&key(), "secret").expect("encrypt b");
        assert_ne!(a, b, "nonce reuse: identical payloads for same plaintext");
    }

    #[test]
    fn tampered_ciphertext_fails_to_decrypt() {
        let mut ct = encrypt(&key(), "secret").expect("encrypt");
        // Flip one bit in the last byte (inside the GCM tag) — the AEAD
        // must reject, not return garbage.
        let last = ct.len() - 1;
        ct[last] ^= 0x01;
        assert!(decrypt(&key(), &ct).is_err(), "tampered payload accepted");
    }

    #[test]
    fn truncated_payload_shorter_than_nonce_fails_cleanly() {
        // < 12 bytes can't even contain the nonce; must be an Err, never a
        // slice-out-of-bounds panic.
        for len in 0..12 {
            let short = vec![0u8; len];
            assert!(
                decrypt(&key(), &short).is_err(),
                "{len}-byte payload must be rejected"
            );
        }
    }

    #[test]
    fn wrong_length_key_is_an_err_not_a_panic_on_both_paths() {
        // 16 bytes (32 hex chars) — the historical trap: encrypt already
        // rejected it, but decrypt panicked inside Key::from_slice.
        let short_key = "aa".repeat(16);
        assert!(encrypt(&short_key, "secret").is_err());
        let ct = encrypt(&key(), "secret").expect("encrypt");
        assert!(
            decrypt(&short_key, &ct).is_err(),
            "wrong-length key must return Err from decrypt"
        );
        // Non-hex input fails at decode, same contract.
        assert!(encrypt("not-hex", "secret").is_err());
        assert!(decrypt("not-hex", &ct).is_err());
    }

    #[test]
    fn wrong_key_fails_to_decrypt() {
        let ct = encrypt(&key(), "secret").expect("encrypt");
        assert!(
            decrypt(&other_key(), &ct).is_err(),
            "decrypt under a different key must fail authentication"
        );
    }
}
