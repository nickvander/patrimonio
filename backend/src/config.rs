use anyhow::{bail, Result};

/// Application configuration loaded from environment variables
#[derive(Debug, Clone)]
pub struct AppConfig {
    /// PostgreSQL connection string
    pub database_url: String,
    /// Maximum database pool connections
    pub database_max_connections: u32,
    /// Redis connection string
    pub redis_url: String,
    /// Server port
    pub port: u16,
    /// Plaid client ID
    pub plaid_client_id: Option<String>,
    /// Plaid secret key
    pub plaid_secret: Option<String>,
    /// Plaid environment (sandbox, development, production)
    pub plaid_env: String,
    /// Exchange rate API key (optional, free tier works without)
    pub exchange_rate_api_key: Option<String>,
    /// Encryption key for sensitive data (Plaid tokens, etc.)
    pub encryption_key: Option<String>,
    pub coinbase_client_id: Option<String>,
    pub coinbase_client_secret: Option<String>,
    pub coinbase_redirect_uri: String,
    pub frontend_base_url: String,
    pub plaid_redirect_uri: Option<String>,
    /// Android application id, registered under "Allowed Android package
    /// names" in the Plaid dashboard. Sent as `android_package_name` (in
    /// place of `redirect_uri`) when a native Android client requests a
    /// link token: Android OAuth returns into the app via the Plaid SDK,
    /// whereas a web redirect_uri strands the OAuth return in the browser
    /// and the public token is never delivered to the app. Defaults to
    /// this repo's applicationId; override with PLAID_ANDROID_PACKAGE_NAME.
    pub plaid_android_package_name: Option<String>,
    /// Public URL Plaid uses to deliver webhooks for items linked
    /// through this deployment. Set to the externally-reachable HTTPS
    /// URL of the `/api/institutions/webhook` route — e.g.
    /// `https://patrimonio.example.com/api/institutions/webhook`.
    /// When unset, link-token creation omits the `webhook` field so
    /// Plaid silently falls back to polling — which is fine for
    /// sandbox / local dev but burns quota in production.
    pub plaid_webhook_url: Option<String>,
    /// CIDRs whose source IPs are allowed to set X-Forwarded-For /
    /// X-Real-IP on incoming requests. Headers from any other peer are
    /// stripped before reaching the handlers (so a malicious client
    /// can't spoof their IP to evade per-IP rate limiting). Empty in
    /// dev with no upstream proxy. In production, set to the docker
    /// bridge + your reverse-proxy's IP (e.g. `127.0.0.1/32,172.17.0.0/16`).
    pub trusted_proxy_cidrs: Vec<ipnet::IpNet>,
    pub allowed_origins: Vec<String>,
    /// Force the session cookie's `Secure` flag on. Default false; the
    /// cookie is also marked Secure automatically when
    /// `frontend_base_url` is https.
    pub cookie_secure: bool,
    /// Base URL for the HIBP k-anonymity password lookup. Default
    /// `https://api.pwnedpasswords.com` — set empty to disable the
    /// check entirely (tests + air-gapped deployments). Only the
    /// first 5 hex chars of the password's SHA-1 are sent, so the
    /// k-anonymity protocol gives the server only ~20 bits of
    /// information about the password.
    pub hibp_api_base: String,
    /// SHA-256 fingerprint(s) of the Android APK signing certificate(s),
    /// comma-separated. Accepts `apksigner`-style colon-hex
    /// (`E1:EF:25:...`) or plain hex; normalized to lowercase no-colon
    /// hex at load. Feeds TWO things that must agree with the same cert:
    ///  1. extra allowed WebAuthn origins (`android:apk-key-hash:<b64url>`)
    ///     so the native app's passkey ceremonies verify, and
    ///  2. the served `/.well-known/assetlinks.json` fingerprints so
    ///     Android agrees the app may speak for this domain's rp_id.
    ///
    /// Empty (default) = native passkeys off; web passkeys unaffected.
    pub android_apk_cert_sha256: Vec<String>,
    /// Android applicationId the assetlinks.json statement targets.
    pub android_package_name: String,
}

impl AppConfig {
    pub fn from_env() -> Result<Self> {
        let encryption_key = env_non_empty("ENCRYPTION_KEY");
        if let Some(key) = &encryption_key {
            let decoded = hex::decode(key)?;
            if decoded.len() != 32 {
                bail!("ENCRYPTION_KEY must be a 32-byte hex string. Generate one with: openssl rand -hex 32");
            }
        }

        let frontend_base_url = std::env::var("FRONTEND_BASE_URL")
            .unwrap_or_else(|_| "http://localhost:3000".to_string());
        let allowed_origins = std::env::var("ALLOWED_ORIGINS")
            .unwrap_or_else(|_| "http://localhost:3000,http://127.0.0.1:3000".to_string())
            .split(',')
            .map(str::trim)
            .filter(|origin| !origin.is_empty())
            .map(ToOwned::to_owned)
            .collect();

        Ok(Self {
            database_url: std::env::var("DATABASE_URL")
                .unwrap_or_else(|_| "postgres://patrimonio:patrimonio@localhost:5432/patrimonio".to_string()),
            // Default of 5 was too tight — the webapp + daily-snapshot
            // cron + manual sync each consume connections, and one
            // interactive sync alongside a dashboard load can already
            // block the pool. 20 leaves plenty of headroom on a single-
            // instance deployment and stays well under typical Postgres
            // max_connections defaults.
            database_max_connections: std::env::var("DATABASE_MAX_CONNECTIONS")
                .unwrap_or_else(|_| "20".to_string())
                .parse()?,
            redis_url: std::env::var("REDIS_URL")
                .unwrap_or_else(|_| "redis://localhost:6379".to_string()),
            port: std::env::var("PORT")
                .unwrap_or_else(|_| "8080".to_string())
                .parse()?,
            plaid_client_id: std::env::var("PLAID_CLIENT_ID").ok(),
            plaid_secret: std::env::var("PLAID_SECRET").ok(),
            plaid_env: std::env::var("PLAID_ENV")
                .unwrap_or_else(|_| "sandbox".to_string()),
            exchange_rate_api_key: env_non_empty("EXCHANGE_RATE_API_KEY"),
            encryption_key,
            coinbase_client_id: env_non_empty("COINBASE_CLIENT_ID"),
            coinbase_client_secret: env_non_empty("COINBASE_CLIENT_SECRET"),
            coinbase_redirect_uri: std::env::var("COINBASE_REDIRECT_URI")
                .unwrap_or_else(|_| "http://localhost:8080/api/auth/coinbase/callback".to_string()),
            frontend_base_url,
            plaid_redirect_uri: env_non_empty("PLAID_REDIRECT_URI"),
            plaid_android_package_name: env_non_empty("PLAID_ANDROID_PACKAGE_NAME")
                .or_else(|| Some("com.patrimonio.patrimonio".to_string())),
            plaid_webhook_url: env_non_empty("PLAID_WEBHOOK_URL"),
            trusted_proxy_cidrs: parse_cidr_list(
                &std::env::var("TRUSTED_PROXY_CIDRS").unwrap_or_default(),
            ),
            allowed_origins,
            // Default to true (secure-by-default). Local dev over
            // plain http://localhost must explicitly opt out with
            // COOKIE_SECURE=false. session::cookie_secure also flips
            // this on whenever FRONTEND_BASE_URL starts with https://
            // so a typical prod config doesn't need to touch this.
            cookie_secure: std::env::var("COOKIE_SECURE")
                .map(|v| matches!(v.to_lowercase().as_str(), "1" | "true" | "yes" | "on"))
                .unwrap_or(true),
            hibp_api_base: std::env::var("HIBP_API_BASE")
                .unwrap_or_else(|_| "https://api.pwnedpasswords.com".to_string()),
            android_apk_cert_sha256: parse_cert_sha256_list(
                &std::env::var("ANDROID_APK_CERT_SHA256").unwrap_or_default(),
            ),
            android_package_name: std::env::var("ANDROID_PACKAGE_NAME")
                .unwrap_or_else(|_| "com.patrimonio.patrimonio".to_string()),
        })
    }
}

fn env_non_empty(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}

/// Parse a comma-separated CIDR list (e.g. "127.0.0.1/32,172.17.0.0/16")
/// into IpNet values. Invalid entries are silently skipped with a
/// tracing warning so a typo doesn't take the whole server down — the
/// worst case is "no peers are trusted" which means XFF is always
/// stripped, which is the safer side to fail on anyway.
/// Parse a comma-separated list of SHA-256 cert fingerprints into
/// normalized lowercase no-colon hex. Accepts the `apksigner
/// verify --print-certs` colon form and plain hex, either case.
/// Invalid entries are skipped with a warning (same philosophy as
/// parse_cidr_list): the failure mode is "that APK's passkeys don't
/// verify", which is the safe side — never a boot failure over a typo.
fn parse_cert_sha256_list(raw: &str) -> Vec<String> {
    raw.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .filter_map(|s| {
            let norm: String = s
                .chars()
                .filter(|c| *c != ':')
                .collect::<String>()
                .to_lowercase();
            // A SHA-256 digest is exactly 32 bytes = 64 hex chars.
            if norm.len() == 64 && norm.chars().all(|c| c.is_ascii_hexdigit()) {
                Some(norm)
            } else {
                tracing::warn!(
                    "ANDROID_APK_CERT_SHA256: invalid entry '{}' (want 64 hex chars, colons ok)",
                    s
                );
                None
            }
        })
        .collect()
}

fn parse_cidr_list(raw: &str) -> Vec<ipnet::IpNet> {
    raw.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .filter_map(|s| match s.parse::<ipnet::IpNet>() {
            Ok(net) => Some(net),
            Err(e) => {
                tracing::warn!("TRUSTED_PROXY_CIDRS: invalid entry '{}' ({})", s, e);
                None
            }
        })
        .collect()
}
