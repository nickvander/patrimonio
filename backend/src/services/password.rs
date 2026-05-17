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
    let params = Params::new(64 * 1024, 3, 1, None)
        .expect("argon2 params should validate");
    Argon2::new(Algorithm::Argon2id, Version::V0x13, params)
}

pub fn hash_password(password: &str) -> Result<String> {
    let salt = SaltString::generate(&mut OsRng);
    let hash = argon2()
        .hash_password(password.as_bytes(), &salt)
        .map_err(|e| anyhow!("hash_password: {}", e))?;
    Ok(hash.to_string())
}

/// Returns Ok(true) on match, Ok(false) on a definitive mismatch.
/// Errors only when the stored hash is corrupt / unparseable.
pub fn verify_password(password: &str, stored_hash: &str) -> Result<bool> {
    let parsed = PasswordHash::new(stored_hash)
        .map_err(|e| anyhow!("verify_password parse: {}", e))?;
    match argon2().verify_password(password.as_bytes(), &parsed) {
        Ok(()) => Ok(true),
        Err(argon2::password_hash::Error::Password) => Ok(false),
        Err(e) => Err(anyhow!("verify_password: {}", e)),
    }
}

/// Cheap structural password policy. We deliberately stay loose on
/// composition rules (NIST SP 800-63B discourages them) and lean on
/// minimum length.
pub fn validate_password_policy(password: &str) -> Result<()> {
    if password.chars().count() < 12 {
        return Err(anyhow!("Password must be at least 12 characters"));
    }
    if password.chars().count() > 256 {
        return Err(anyhow!("Password must be at most 256 characters"));
    }
    Ok(())
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
}
