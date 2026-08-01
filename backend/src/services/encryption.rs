use aes_gcm::{
    aead::{Aead, KeyInit},
    Aes256Gcm, Nonce,
};
use anyhow::{anyhow, Result};
use rand::{rngs::OsRng, RngCore};

pub fn encrypt(key_hex: &str, plaintext: &str) -> Result<Vec<u8>> {
    let key_bytes = hex::decode(key_hex).map_err(|e| anyhow!("Invalid key hex: {e}"))?;
    if key_bytes.len() != 32 {
        return Err(anyhow!(
            "Encryption key must be exactly 32 bytes (64 hex chars)"
        ));
    }

    let key = aes_gcm::Key::<Aes256Gcm>::from_slice(&key_bytes);
    let cipher = Aes256Gcm::new(key);

    let mut nonce_bytes = [0u8; 12];
    OsRng.fill_bytes(&mut nonce_bytes);
    let nonce = Nonce::from_slice(&nonce_bytes);

    let ciphertext = cipher
        .encrypt(nonce, plaintext.as_bytes())
        .map_err(|e| anyhow!("Encryption error: {e}"))?;

    let mut result = Vec::with_capacity(12 + ciphertext.len());
    result.extend_from_slice(&nonce_bytes);
    result.extend_from_slice(&ciphertext);

    Ok(result)
}

pub fn decrypt(key_hex: &str, encrypted: &[u8]) -> Result<String> {
    if encrypted.len() < 12 {
        return Err(anyhow!("Encrypted payload is too short"));
    }

    let (nonce_bytes, ciphertext) = encrypted.split_at(12);

    let key_bytes = hex::decode(key_hex).map_err(|e| anyhow!("Invalid key hex: {e}"))?;
    let key = aes_gcm::Key::<Aes256Gcm>::from_slice(&key_bytes);
    let cipher = Aes256Gcm::new(key);
    let nonce = Nonce::from_slice(nonce_bytes);

    let plaintext = cipher
        .decrypt(nonce, ciphertext)
        .map_err(|e| anyhow!("Decryption error: {e}"))?;

    String::from_utf8(plaintext).map_err(|e| anyhow!("Invalid UTF-8 in decrypted payload: {e}"))
}
