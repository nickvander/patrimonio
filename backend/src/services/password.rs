use anyhow::{anyhow, Result};
use argon2::password_hash::{
    rand_core::OsRng, PasswordHash, PasswordHasher, PasswordVerifier, SaltString,
};
use argon2::{Algorithm, Argon2, Params, Version};

/// Argon2id parameters tuned for an interactive web login on commodity
/// hardware. ~64 MiB memory, 3 iterations, 1 lane — comfortably above
/// OWASP's 2024 minimum (m=19 MiB, t=2, p=1) and verifies in well under
/// 100 ms on a modern server.
fn argon2() -> Argon2<'static> {
    let params = Params::new(64 * 1024, 3, 1, None).expect("argon2 params should validate");
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
}

pub fn hash_password(password: &str) -> Result<String> {
    let salt = SaltString::generate(&mut OsRng);
    let hash = argon2()
        .hash_password(password.as_bytes(), &salt)
        .map_err(|e| anyhow!("hash_password: {e}"))?;
    Ok(hash.to_string())
}

/// Returns Ok(true) on match, Ok(false) on a definitive mismatch.
/// Errors only when the stored hash is corrupt / unparseable.
pub fn verify_password(password: &str, stored_hash: &str) -> Result<bool> {
    let parsed =
        PasswordHash::new(stored_hash).map_err(|e| anyhow!("verify_password parse: {e}"))?;
    match argon2().verify_password(password.as_bytes(), &parsed) {
        Ok(()) => Ok(true),
        Err(argon2::password_hash::Error::Password) => Ok(false),
        Err(e) => Err(anyhow!("verify_password: {e}")),
    }
}

/// Run a real Argon2 verify against a fixed dummy hash, then discard
/// the result. Used by /login when the user row was not found, so the
/// "unknown user" path takes the same wall-clock time as the
/// "bad password" path — closes the timing-oracle username enumeration
/// gap. The dummy hash is for the literal password "not-a-real-password"
/// generated at the same Argon2 params we hash with.
pub fn dummy_verify() {
    const DUMMY_HASH: &str =
        "$argon2id$v=19$m=65536,t=3,p=1$YWFhYWFhYWFhYWFhYWFhYQ$AbHfdxZmFw84/oOzg2tBJN1mzGZyVqfb3CFEKCJrSeQ";
    // Best effort: a parse failure (which would only happen if someone
    // edits DUMMY_HASH wrong) silently degrades to "no work performed"
    // — which IS observable, but never on a live build because the
    // string is a literal we control.
    let _ = verify_password("dummy", DUMMY_HASH);
}

/// Random 50–150 ms sleep injected after every failed verify path
/// (unknown user / inactive / bad password / bad TOTP). Closes a
/// rate-limit gap where an attacker holding one valid username could
/// previously spray 5 passwords/minute below the threshold at full
/// HTTP throughput. With the jitter the per-attempt floor is the
/// random delay, so brute-force throughput is gated by network
/// concurrency rather than verify latency.
///
/// Cost to the legitimate user: max 150 ms per typo, which is
/// imperceptible vs. an Argon2 verify already taking 100–200 ms.
pub async fn random_login_jitter() {
    use rand::Rng;
    let ms: u64 = rand::thread_rng().gen_range(50..=150);
    tokio::time::sleep(std::time::Duration::from_millis(ms)).await;
}

/// Cheap structural password policy. We deliberately stay loose on
/// composition rules (NIST SP 800-63B discourages them) and lean on
/// minimum length + a breach-list lookup so a long-but-common pick
/// (`password12345`, `qwerty1234567`) gets rejected.
pub fn validate_password_policy(password: &str) -> Result<()> {
    if password.chars().count() < 12 {
        return Err(anyhow!("Password must be at least 12 characters"));
    }
    if password.chars().count() > 256 {
        return Err(anyhow!("Password must be at most 256 characters"));
    }
    if crate::services::common_passwords::is_common_password(password) {
        return Err(anyhow!(
            "This password appears in known data-breach lists. \
             Pick something less common — a passphrase of four \
             unrelated words is a good default."
        ));
    }
    Ok(())
}

/// HIBP k-anonymity password breach lookup.
///
/// Hashes the password with SHA-1 (the legacy hash HIBP's corpus is
/// indexed on — used here as a corpus index, not a security primitive),
/// sends the first 5 hex chars to `${api_base}/range/${prefix}`, and
/// scans the response for the suffix. When found, returns the
/// breach count from HIBP's corpus; absent = `0`.
///
/// `api_base` empty → check skipped, returns `Ok(0)`. This lets tests
/// + air-gapped deployments bypass the network call without code
///   changes (the config-level `HIBP_API_BASE` is the off-switch).
///
/// On any network error we return `Ok(0)` (fail-open) and log a
/// warning. The decision is deliberate: HIBP being down should NOT
/// block a legitimate registration, and the embedded breach-list
/// (`common_passwords`) still catches the most embarrassing picks
/// regardless. A persistent HIBP outage is visible in the warn logs.
///
/// Timeout: hard 3s ceiling. Hot path is signup / change-password
/// where the user is already waiting on Argon2; an extra 3s worst-case
/// is acceptable, but unbounded would tank the UX if HIBP hangs.
pub async fn check_hibp_breached(password: &str, api_base: &str) -> Result<u64> {
    if api_base.trim().is_empty() {
        return Ok(0);
    }
    use sha1::{Digest, Sha1};
    let mut hasher = Sha1::new();
    hasher.update(password.as_bytes());
    // HIBP corpus is UPPERCASE hex — match exactly so the suffix
    // comparison is byte-equal.
    let digest = hasher.finalize();
    let hex_full = digest
        .iter()
        .map(|b| format!("{b:02X}"))
        .collect::<String>();
    let (prefix, suffix) = hex_full.split_at(5);

    let client = match reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(3))
        .build()
    {
        Ok(c) => c,
        Err(e) => {
            tracing::warn!("HIBP: client build failed ({}); skipping check", e);
            return Ok(0);
        }
    };

    let url = format!("{}/range/{}", api_base.trim_end_matches('/'), prefix);
    let resp = match client
        .get(&url)
        // "Add-Padding" makes HIBP return a fixed-size response so a
        // network observer can't infer the prefix from response size.
        // Free, no auth, recommended in their docs.
        .header("Add-Padding", "true")
        .header("User-Agent", "patrimonio/0.1")
        .send()
        .await
    {
        Ok(r) => r,
        Err(e) => {
            tracing::warn!("HIBP: request failed ({}); failing open", e);
            return Ok(0);
        }
    };
    if !resp.status().is_success() {
        tracing::warn!(
            "HIBP: unexpected status {} from {}; failing open",
            resp.status(),
            url
        );
        return Ok(0);
    }
    let body = match resp.text().await {
        Ok(b) => b,
        Err(e) => {
            tracing::warn!("HIBP: body read failed ({}); failing open", e);
            return Ok(0);
        }
    };

    for line in body.lines() {
        // Line shape: `SUFFIX:count` (35 hex chars + colon + integer).
        // Padding rows (count == 0) are inserted by Add-Padding and
        // safely match nothing since real entries have non-zero counts.
        if let Some((s, c)) = line.split_once(':') {
            if s.eq_ignore_ascii_case(suffix) {
                let count: u64 = c.trim().parse().unwrap_or(0);
                return Ok(count);
            }
        }
    }
    Ok(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip() {
        let hash = hash_password("correct horse battery staple").unwrap();
        assert!(verify_password("correct horse battery staple", &hash).unwrap());
        assert!(!verify_password("wrong password value", &hash).unwrap());
    }

    #[test]
    fn policy_rejects_short() {
        assert!(validate_password_policy("short").is_err());
        assert!(validate_password_policy("aaaaaaaaaaaa").is_ok());
    }

    #[test]
    fn policy_rejects_common_breached() {
        // 12+ chars (passes length) but a top-of-breach-list pick.
        assert!(validate_password_policy("password1234").is_err());
        assert!(validate_password_policy("qwerty123456").is_err());
        assert!(validate_password_policy("Password1234").is_err()); // case-insensitive
    }

    #[test]
    fn policy_accepts_passphrases() {
        // The recommended pattern from the rejection message.
        assert!(validate_password_policy("aurora-fjord-pelican-cordon").is_ok());
        assert!(validate_password_policy("correct horse battery staple").is_ok());
    }

    #[tokio::test]
    async fn hibp_disabled_returns_zero() {
        // Empty api_base is the documented "skip the check" knob.
        // The test passes if no network call is made (a 0 return).
        let count = check_hibp_breached("anything-you-like", "")
            .await
            .expect("disabled hibp lookup should succeed");
        assert_eq!(count, 0);
    }

    #[tokio::test]
    async fn hibp_network_failure_fails_open() {
        // A bogus host is the cheapest way to exercise the
        // network-error path without depending on the live HIBP
        // endpoint. Either DNS resolution or the connect attempt
        // will fail; the helper must return 0 (fail-open).
        let count = check_hibp_breached(
            "anything-you-like",
            "http://hibp-does-not-resolve.invalid.test",
        )
        .await
        .expect("failed-open hibp lookup should still return Ok");
        assert_eq!(count, 0);
    }
}
