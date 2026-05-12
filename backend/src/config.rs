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
    pub allowed_origins: Vec<String>,
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
            database_max_connections: std::env::var("DATABASE_MAX_CONNECTIONS")
                .unwrap_or_else(|_| "5".to_string())
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
            allowed_origins,
        })
    }
}

fn env_non_empty(name: &str) -> Option<String> {
    std::env::var(name)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
}
