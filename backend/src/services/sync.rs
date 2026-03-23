use anyhow::Result;
use sqlx::{PgPool, Row};
use reqwest::Client;
use crate::config::AppConfig;
use crate::services::encryption;

/// Sync engine — Expands Plaid data pulling for all linked institutions.
pub async fn sync_all_institutions(db: &PgPool, config: &AppConfig) -> Result<()> {
    tracing::info!("Sync engine: starting sync for all institutions");
    let client = Client::new();

    let rows = sqlx::query(
        "SELECT id, name, plaid_access_token_enc FROM institutions WHERE integration_type = 'plaid'"
    )
    .fetch_all(db)
    .await?;

    for row in rows {
        let inst_id: uuid::Uuid = row.get("id");
        let inst_name: String = row.get("name");
        let enc_token: Option<Vec<u8>> = row.try_get("plaid_access_token_enc").unwrap_or(None);

        if enc_token.is_none() {
            continue;
        }

        let enc_key = config.encryption_key.as_ref().expect("ENCRYPTION_KEY required");
        let access_token = match encryption::decrypt(enc_key, &enc_token.unwrap()) {
            Ok(t) => t,
            Err(e) => {
                tracing::error!("Failed to decrypt token for {}: {}", inst_name, e);
                continue;
            }
        };

        // 1. Fetch Accounts & Balances
        let url = format!("https://{}.plaid.com/accounts/balance/get", config.plaid_env);
        let res = client.post(&url)
            .json(&serde_json::json!({
                "client_id": config.plaid_client_id,
                "secret": config.plaid_secret,
                "access_token": access_token
            }))
            .send().await?.json::<serde_json::Value>().await?;

        if let Some(accounts) = res["accounts"].as_array() {
            for acc in accounts {
                let name = acc["name"].as_str().unwrap_or("Unknown");
                let external_id = acc["account_id"].as_str().unwrap_or("");
                let subtype = acc["subtype"].as_str().unwrap_or("checking");
                let current_bal = acc["balances"]["current"].as_f64();
                let available_bal = acc["balances"]["available"].as_f64();

                let existing = sqlx::query("SELECT id FROM accounts WHERE external_id = $1")
                    .bind(external_id)
                    .fetch_optional(db).await?;

                if existing.is_some() {
                    sqlx::query("UPDATE accounts SET current_balance = $1, available_balance = $2, updated_at = NOW() WHERE external_id = $3")
                        .bind(current_bal)
                        .bind(available_bal)
                        .bind(external_id)
                        .execute(db).await?;
                } else {
                    sqlx::query(
                        r#"
                        INSERT INTO accounts (institution_id, external_id, name, account_type, currency, current_balance, available_balance)
                        VALUES ($1, $2, $3, $4, 'USD', $5, $6)
                        "#
                    )
                    .bind(inst_id)
                    .bind(external_id)
                    .bind(name)
                    .bind(subtype)
                    .bind(current_bal)
                    .bind(available_bal)
                    .execute(db).await?;
                }
            }
        }

        // 2. Fetch Transactions (/transactions/sync)
        let tx_url = format!("https://{}.plaid.com/transactions/sync", config.plaid_env);
        if let Ok(tx_res) = client.post(&tx_url)
            .json(&serde_json::json!({
                "client_id": config.plaid_client_id,
                "secret": config.plaid_secret,
                "access_token": access_token
            }))
            .send().await {
            if let Ok(tx_val) = tx_res.json::<serde_json::Value>().await {
                if let Some(added) = tx_val["added"].as_array() {
                    for tx in added {
                        let acc_ext_id = tx["account_id"].as_str().unwrap_or("");
                        let tx_ext_id = tx["transaction_id"].as_str().unwrap_or("");
                        let date_str = tx["date"].as_str().unwrap_or("1970-01-01");
                        let date = chrono::NaiveDate::parse_from_str(date_str, "%Y-%m-%d").unwrap_or_default();
                        let name = tx["name"].as_str().unwrap_or("Unknown");
                        let amount = tx["amount"].as_f64().unwrap_or(0.0);
                        
                        let internal_acc = sqlx::query("SELECT id FROM accounts WHERE external_id = $1")
                            .bind(acc_ext_id)
                            .fetch_optional(db).await.unwrap_or(None);

                        if let Some(acc_row) = internal_acc {
                            let acc_id: uuid::Uuid = acc_row.get("id");
                            // Simply insert (assuming external_id is unique enough for MVP)
                            let _ = sqlx::query(
                                r#"
                                INSERT INTO transactions (account_id, external_id, date, description, amount)
                                VALUES ($1, $2, $3, $4, $5)
                                "#
                            )
                            .bind(acc_id).bind(tx_ext_id).bind(date).bind(name).bind(amount)
                            .execute(db).await;
                        }
                    }
                }
            }
        }

        // 3. Fetch Investments (/investments/holdings/get)
        let hold_url = format!("https://{}.plaid.com/investments/holdings/get", config.plaid_env);
        if let Ok(hold_res) = client.post(&hold_url)
            .json(&serde_json::json!({
                "client_id": config.plaid_client_id,
                "secret": config.plaid_secret,
                "access_token": access_token
            }))
            .send().await {
            if let Ok(hold_val) = hold_res.json::<serde_json::Value>().await {
                if let Some(holdings) = hold_val["holdings"].as_array() {
                    for h in holdings {
                        let acc_ext_id = h["account_id"].as_str().unwrap_or("");
                        let qty = h["quantity"].as_f64().unwrap_or(0.0);
                        let cost = h["institution_price"].as_f64().unwrap_or(0.0);
                        let val = h["institution_value"].as_f64().unwrap_or(0.0);

                        let internal_acc = sqlx::query("SELECT id FROM accounts WHERE external_id = $1")
                            .bind(acc_ext_id)
                            .fetch_optional(db).await.unwrap_or(None);

                        if let Some(acc_row) = internal_acc {
                            let acc_id: uuid::Uuid = acc_row.get("id");
                            let _ = sqlx::query(
                                r#"
                                INSERT INTO holdings (account_id, symbol, name, quantity, price, value, cost_basis)
                                VALUES ($1, 'SEC', 'Investment', $2, $3, $4, $5)
                                "#
                            )
                            .bind(acc_id).bind(qty).bind(cost).bind(val).bind(cost)
                            .execute(db).await;
                        }
                    }
                }
            }
        }

        let _ = sqlx::query("UPDATE institutions SET last_synced_at = NOW(), sync_status = 'synced' WHERE id = $1")
            .bind(inst_id)
            .execute(db).await;

        tracing::info!("Successfully synced accounts & balances for {}", inst_name);
    }
    Ok(())
}
