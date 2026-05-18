//! Plaid webhook signature verification.
//!
//! Plaid signs every webhook with a JWT in the `Plaid-Verification`
//! header. The JWT is ES256 with the following claims:
//!
//! ```json
//! { "iat": 1700000000, "request_body_sha256": "<hex sha-256 of raw body>" }
//! ```
//!
//! The signing key is identified by the JWT header's `kid` field. Keys
//! are fetched on demand from Plaid's `/webhook_verification_key/get`
//! endpoint using the configured client_id/secret and cached in-process
//! (keys rotate slowly — Plaid issues new key IDs but old keys remain
//! valid for several days during the overlap, so per-process caching is
//! safe).
//!
//! Verification rules implemented here:
//!
//! 1. Header `alg` must be ES256 — anything else is rejected.
//! 2. `iat` must be within the last 5 minutes (anti-replay window per
//!    Plaid's documented practice).
//! 3. `request_body_sha256` must equal the hex SHA-256 of the raw
//!    request body the receiver actually saw — this is what binds the
//!    signature to the body so a stolen JWT can't be replayed against
//!    a forged payload.

use std::collections::HashMap;
use std::sync::{LazyLock, RwLock};
use std::time::{Duration, Instant};

use anyhow::{anyhow, bail, Result};
use jsonwebtoken::{decode, decode_header, jwk::Jwk, Algorithm, DecodingKey, Validation};
use sha2::{Digest, Sha256};

use crate::config::AppConfig;

/// Anti-replay window for the `iat` claim. Plaid documents 5 minutes
/// as the recommended ceiling; anything older we treat as a stale
/// (potentially replayed) webhook delivery.
const IAT_MAX_AGE_SECONDS: i64 = 300;

/// In-process TTL for cached signing keys. Lower than Plaid's actual
/// key validity (days/weeks) so a forced re-fetch happens hourly,
/// picking up new keys without restarting the process. Rotation in the
/// middle of the TTL doesn't hurt: a request signed with a newer kid
/// triggers a miss-and-fetch on its first arrival.
const KEY_CACHE_TTL: Duration = Duration::from_secs(3600);

struct CachedKey {
    key: DecodingKey,
    inserted_at: Instant,
}

static KEY_CACHE: LazyLock<RwLock<HashMap<String, CachedKey>>> =
    LazyLock::new(|| RwLock::new(HashMap::new()));

#[derive(serde::Deserialize)]
struct PlaidJwtClaims {
    iat: i64,
    request_body_sha256: String,
}

#[derive(serde::Deserialize)]
struct KeyResponse {
    key: Jwk,
}

/// Verify a Plaid webhook signature. Returns `Ok(())` on success or
/// `Err` with a human-readable reason. Logging is the caller's
/// responsibility — this function never logs the JWT itself (could
/// contain replay value) but does include the kid + signature length
/// in error messages for ops debugging.
pub async fn verify_plaid_webhook(
    config: &AppConfig,
    plaid_verification_jwt: &str,
    raw_body: &[u8],
) -> Result<()> {
    // 1. Inspect the header for the algorithm + key id.
    let header = decode_header(plaid_verification_jwt)
        .map_err(|e| anyhow!("malformed Plaid-Verification JWT header: {e}"))?;
    if header.alg != Algorithm::ES256 {
        bail!("Plaid-Verification JWT uses unexpected alg {:?}", header.alg);
    }
    let kid = header
        .kid
        .ok_or_else(|| anyhow!("Plaid-Verification JWT missing `kid`"))?;

    // 2. Resolve the signing key, hitting cache first.
    let decoding_key = get_or_fetch_key(config, &kid).await?;

    // 3. Validate the signature + decode the claims. Plaid's tokens
    //    don't carry `exp`; we enforce freshness via `iat` ourselves.
    let mut validation = Validation::new(Algorithm::ES256);
    validation.validate_exp = false;
    validation.required_spec_claims.clear();
    let token = decode::<PlaidJwtClaims>(plaid_verification_jwt, &decoding_key, &validation)
        .map_err(|e| anyhow!("Plaid-Verification JWT signature/decode failed: {e}"))?;

    // 4. Enforce the anti-replay window.
    let now = chrono::Utc::now().timestamp();
    let age = now - token.claims.iat;
    if age < -60 {
        bail!("Plaid-Verification JWT iat is in the future by {}s", -age);
    }
    if age > IAT_MAX_AGE_SECONDS {
        bail!(
            "Plaid-Verification JWT is stale (iat age {}s > {}s)",
            age,
            IAT_MAX_AGE_SECONDS
        );
    }

    // 5. Bind the signature to *this* request body by comparing the
    //    JWT claim against the SHA-256 the receiver computed locally.
    let computed = hex::encode(Sha256::digest(raw_body));
    if !constant_time_eq(
        computed.as_bytes(),
        token.claims.request_body_sha256.as_bytes(),
    ) {
        bail!(
            "Plaid-Verification body SHA256 mismatch (claim_len={}, computed_len={})",
            token.claims.request_body_sha256.len(),
            computed.len()
        );
    }

    Ok(())
}

async fn get_or_fetch_key(config: &AppConfig, kid: &str) -> Result<DecodingKey> {
    // Fast path: cached + fresh.
    if let Some(key) = cached_key(kid) {
        return Ok(key);
    }
    let key = fetch_key_from_plaid(config, kid).await?;
    store_key(kid.to_string(), key.clone());
    Ok(key)
}

fn cached_key(kid: &str) -> Option<DecodingKey> {
    let cache = KEY_CACHE.read().ok()?;
    let entry = cache.get(kid)?;
    if entry.inserted_at.elapsed() > KEY_CACHE_TTL {
        return None;
    }
    Some(entry.key.clone())
}

fn store_key(kid: String, key: DecodingKey) {
    let Ok(mut cache) = KEY_CACHE.write() else {
        return; // Pool got poisoned; next request will refetch.
    };
    cache.insert(
        kid,
        CachedKey {
            key,
            inserted_at: Instant::now(),
        },
    );
}

async fn fetch_key_from_plaid(config: &AppConfig, kid: &str) -> Result<DecodingKey> {
    let client_id = config
        .plaid_client_id
        .as_ref()
        .ok_or_else(|| anyhow!("PLAID_CLIENT_ID not configured; cannot verify webhook"))?;
    let secret = config
        .plaid_secret
        .as_ref()
        .ok_or_else(|| anyhow!("PLAID_SECRET not configured; cannot verify webhook"))?;
    let url = format!(
        "https://{}.plaid.com/webhook_verification_key/get",
        config.plaid_env
    );
    let res: KeyResponse = reqwest::Client::new()
        .post(&url)
        .json(&serde_json::json!({
            "client_id": client_id,
            "secret": secret,
            "key_id": kid,
        }))
        .send()
        .await
        .map_err(|e| anyhow!("HTTP error fetching Plaid webhook key {kid}: {e}"))?
        .error_for_status()
        .map_err(|e| anyhow!("Plaid /webhook_verification_key/get returned {e}"))?
        .json()
        .await
        .map_err(|e| anyhow!("malformed Plaid webhook key response for {kid}: {e}"))?;
    DecodingKey::from_jwk(&res.key)
        .map_err(|e| anyhow!("Plaid returned a JWK we can't load ({kid}): {e}"))
}

/// Length-constant equality. The standard `==` on `&[u8]` short-circuits
/// on the first byte difference, leaking a timing oracle for the SHA-256
/// comparison. Hash equality isn't a high-stakes secret here (the SHA is
/// public per-request) but the cost of doing it right is trivial.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut diff: u8 = 0;
    for (x, y) in a.iter().zip(b.iter()) {
        diff |= x ^ y;
    }
    diff == 0
}

#[cfg(test)]
mod tests {
    use super::constant_time_eq;

    #[test]
    fn constant_time_eq_matches_normal_equality() {
        assert!(constant_time_eq(b"hello", b"hello"));
        assert!(!constant_time_eq(b"hello", b"world"));
        assert!(!constant_time_eq(b"hello", b"hellos"));
        assert!(!constant_time_eq(b"", b"x"));
        assert!(constant_time_eq(b"", b""));
    }
}
