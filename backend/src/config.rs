use anyhow::Result;

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
}

impl AppConfig {
    pub fn from_env() -> Result<Self> {
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
            exchange_rate_api_key: std::env::var("EXCHANGE_RATE_API_KEY").ok(),
            encryption_key: std::env::var("ENCRYPTION_KEY").ok(),
            coinbase_client_id: std::env::var("COINBASE_CLIENT_ID").ok(),
            coinbase_client_secret: std::env::var("COINBASE_CLIENT_SECRET").ok(),
            coinbase_redirect_uri: std::env::var("COINBASE_REDIRECT_URI")
                .unwrap_or_else(|_| "http://localhost:8080/api/auth/coinbase/callback".to_string()),
        })
    }
}
