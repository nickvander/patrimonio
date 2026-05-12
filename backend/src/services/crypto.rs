use anyhow::{anyhow, Result};
use sqlx::{PgPool, Row};
use reqwest::Client;
use hmac::{Hmac, Mac};
use sha2::Sha256;
use chrono::Utc;
use rust_decimal::Decimal;
use std::str::FromStr;
use crate::config::AppConfig;
use crate::services::encryption;
use crate::services::crypto_price::CryptoPriceService;

type HmacSha256 = Hmac<Sha256>;

/// Crypto service for fetching data from exchanges (Coinbase, Bitso)
pub struct CryptoService;

impl CryptoService {
    /// Sync Coinbase using OAuth 2.0
    pub async fn sync_coinbase_oauth(db: &PgPool, config: &AppConfig, inst_id: uuid::Uuid) -> Result<()> {
        let row = sqlx::query("SELECT name, api_key_enc, api_secret_enc FROM institutions WHERE id = $1")
            .bind(inst_id)
            .fetch_one(db).await?;
            
        let name: String = row.get("name");
        let enc_key = config.encryption_key.as_ref().ok_or_else(|| anyhow!("ENCRYPTION_KEY missing"))?;
        
        let mut access_token = encryption::decrypt(enc_key, &row.get::<Vec<u8>, _>("api_key_enc"))?;
        let refresh_token = encryption::decrypt(enc_key, &row.get::<Vec<u8>, _>("api_secret_enc"))?;

        let client = Client::new();
        
        // 1. Try to fetch accounts
        let mut res = client.get("https://api.coinbase.com/v2/accounts")
            .bearer_auth(&access_token)
            .header("CB-Version", "2021-01-01")
            .send().await?;

        // 2. If unauthorized, try to refresh token
        if res.status() == reqwest::StatusCode::UNAUTHORIZED {
            tracing::info!("Coinbase access token expired, attempting refresh for {}", name);
            let client_id = config.coinbase_client_id.as_ref().ok_or_else(|| anyhow!("COINBASE_CLIENT_ID missing"))?;
            let client_secret = config.coinbase_client_secret.as_ref().ok_or_else(|| anyhow!("COINBASE_CLIENT_SECRET missing"))?;
            let refresh_res = client.post("https://api.coinbase.com/oauth/token")
                .form(&[
                    ("grant_type", "refresh_token"),
                    ("refresh_token", &refresh_token),
                    ("client_id", client_id),
                    ("client_secret", client_secret),
                ])
                .send().await?.json::<serde_json::Value>().await?;

            if let Some(new_access) = refresh_res["access_token"].as_str() {
                access_token = new_access.to_string();
                let new_refresh = refresh_res["refresh_token"].as_str().unwrap_or(&refresh_token);
                
                let acc_enc = encryption::encrypt(enc_key, &access_token)?;
                let ref_enc = encryption::encrypt(enc_key, new_refresh)?;

                sqlx::query("UPDATE institutions SET api_key_enc = $1, api_secret_enc = $2 WHERE id = $3")
                    .bind(acc_enc).bind(ref_enc).bind(inst_id).execute(db).await?;
                
                // Retry request
                res = client.get("https://api.coinbase.com/v2/accounts")
                    .bearer_auth(&access_token)
                    .header("CB-Version", "2021-01-01")
                    .send().await?;
            }
        }

        let data = res.json::<serde_json::Value>().await?;
        if let Some(accounts) = data["data"].as_array() {
            for acc in accounts {
                let currency = acc["balance"]["currency"].as_str().unwrap_or("BTC");
                let amount_str = acc["balance"]["amount"].as_str().unwrap_or("0");
                let amount = Decimal::from_str(amount_str).unwrap_or(Decimal::ZERO);
                
                if amount > Decimal::ZERO {
                    let external_id = acc["id"].as_str().unwrap_or("");
                    let acc_name = format!("{} ({})", name, currency);
                    
                    // Estimate value in USD
                    let price = CryptoPriceService::get_spot_price(currency, "USD").await.unwrap_or(Decimal::ZERO);
                    let valuation = amount * price;

                    let existing = sqlx::query("SELECT id FROM accounts WHERE external_id = $1")
                        .bind(external_id).fetch_optional(db).await?;

                    if let Some(r) = existing {
                        let id: uuid::Uuid = r.get("id");
                        sqlx::query(
                            "UPDATE accounts SET crypto_amount = $1, current_balance = $2, updated_at = NOW() WHERE id = $3"
                        )
                        .bind(amount).bind(valuation).bind(id).execute(db).await?;
                    } else {
                        sqlx::query(
                            r#"
                            INSERT INTO accounts (institution_id, external_id, name, account_type, currency, ticker_symbol, crypto_amount, current_balance)
                            VALUES ($1, $2, $3, 'crypto', 'USD', $4, $5, $6)
                            "#
                        )
                        .bind(inst_id).bind(external_id).bind(acc_name).bind(currency).bind(amount).bind(valuation)
                        .execute(db).await?;
                    }
                }
            }
        }

        Ok(())
    }

    /// Sync Bitso using API Keys
    pub async fn sync_bitso(db: &PgPool, config: &AppConfig, inst_id: uuid::Uuid) -> Result<()> {
        let row = sqlx::query("SELECT name, api_key_enc, api_secret_enc FROM institutions WHERE id = $1")
            .bind(inst_id)
            .fetch_one(db).await?;
            
        let name: String = row.get("name");
        let enc_key = config.encryption_key.as_ref().ok_or_else(|| anyhow!("ENCRYPTION_KEY missing"))?;
        
        let api_key = encryption::decrypt(enc_key, &row.get::<Vec<u8>, _>("api_key_enc"))?;
        let api_secret = encryption::decrypt(enc_key, &row.get::<Vec<u8>, _>("api_secret_enc"))?;

        let client = Client::new();
        let timestamp = Utc::now().timestamp().to_string();
        let method = "GET";
        let path = "/v3/balances/";
        
        let message = format!("{}{}{}", timestamp, method, path);
        let mut mac = HmacSha256::new_from_slice(api_secret.as_bytes())?;
        mac.update(message.as_bytes());
        let signature = hex::encode(mac.finalize().into_bytes());

        let auth_header = format!("Bitso {}:{}:{}", api_key, timestamp, signature);

        let res = client.get(format!("https://api.bitso.com{}", path))
            .header("Authorization", auth_header)
            .send().await?.json::<serde_json::Value>().await?;

        if let Some(payload) = res["payload"]["balances"].as_array() {
            for bal_item in payload {
                let currency = bal_item["currency"].as_str().unwrap_or("");
                let total_str = bal_item["total"].as_str().unwrap_or("0");
                let total = Decimal::from_str(total_str).unwrap_or(Decimal::ZERO);
                
                if total > Decimal::ZERO {
                    let external_id = format!("bitso_{}_{}", inst_id, currency);
                    let acc_name = format!("{} ({})", name, currency.to_uppercase());
                    
                    // Estimate value in MXN
                    let price = CryptoPriceService::get_spot_price(currency, "MXN").await.unwrap_or(Decimal::ZERO);
                    let valuation = total * price;

                    let existing = sqlx::query("SELECT id FROM accounts WHERE external_id = $1")
                        .bind(&external_id).fetch_optional(db).await?;

                    if let Some(r) = existing {
                        let id: uuid::Uuid = r.get("id");
                        sqlx::query(
                            "UPDATE accounts SET crypto_amount = $1, current_balance = $2, updated_at = NOW() WHERE id = $3"
                        )
                        .bind(total).bind(valuation).bind(id).execute(db).await?;
                    } else {
                        sqlx::query(
                            r#"
                            INSERT INTO accounts (institution_id, external_id, name, account_type, currency, ticker_symbol, crypto_amount, current_balance)
                            VALUES ($1, $2, $3, 'crypto', 'MXN', $4, $5, $6)
                            "#
                        )
                        .bind(inst_id).bind(external_id).bind(acc_name).bind(currency.to_uppercase()).bind(total).bind(valuation)
                        .execute(db).await?;
                    }
                }
            }
        }

        Ok(())
    }

    /// Legacy sync_coinbase for API key (optional, keeping it simple)
    pub async fn sync_coinbase(db: &PgPool, config: &AppConfig, inst_id: uuid::Uuid) -> Result<()> {
        // We'll just call the OAuth one if it's there or just let it fail if not configured
        // For now, users should use OAuth.
        Self::sync_coinbase_oauth(db, config, inst_id).await
    }
}
