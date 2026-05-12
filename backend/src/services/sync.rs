use anyhow::Result;
use sqlx::{PgPool, Row};
use reqwest::Client;
use crate::config::AppConfig;
use crate::services::encryption;
use std::collections::HashMap;

/// Sync engine — Expands Plaid data pulling for all linked institutions.
pub async fn sync_all_institutions(db: &PgPool, config: &AppConfig) -> Result<()> {
    tracing::info!("Sync engine: starting sync for all institutions");
    let client = Client::new();

    let rows = sqlx::query(
        "SELECT id, name, integration_type, plaid_access_token_enc, plaid_transactions_cursor FROM institutions"
    )
    .fetch_all(db)
    .await?;

    for row in rows {
        let inst_id: uuid::Uuid = row.get("id");
        let inst_name: String = row.get("name");
        let integration_type: String = row.get("integration_type");
        update_sync_status(db, inst_id, "syncing").await;
        let mut sync_ok = true;

        match integration_type.as_str() {
            "plaid" => {
                let enc_token: Option<Vec<u8>> = row.try_get("plaid_access_token_enc").unwrap_or(None);
                if enc_token.is_none() {
                    update_sync_status(db, inst_id, "pending").await;
                    continue;
                }

                let Some(enc_key) = config.encryption_key.as_ref() else {
                    update_sync_status(db, inst_id, "setup_required").await;
                    tracing::error!("Cannot sync {}: ENCRYPTION_KEY required", inst_name);
                    continue;
                };
                let access_token = match encryption::decrypt(enc_key, &enc_token.unwrap()) {
                    Ok(t) => t,
                    Err(e) => {
                        tracing::error!("Failed to decrypt token for {}: {}", inst_name, e);
                        update_sync_status(db, inst_id, "error").await;
                        continue;
                    }
                };
                let (Some(client_id), Some(secret)) = (&config.plaid_client_id, &config.plaid_secret) else {
                    update_sync_status(db, inst_id, "setup_required").await;
                    tracing::error!("Cannot sync {}: Plaid credentials required", inst_name);
                    continue;
                };

                // 1. Fetch Accounts & Balances
                let url = format!("https://{}.plaid.com/accounts/balance/get", config.plaid_env);
                let res = client.post(&url)
                    .json(&serde_json::json!({
                        "client_id": client_id,
                        "secret": secret,
                        "access_token": access_token
                    }))
                    .send().await?.json::<serde_json::Value>().await?;

                if let Some(status) = plaid_error_status(&res) {
                    update_sync_status(db, inst_id, status).await;
                    tracing::error!("Plaid balance sync failed for {}: {:?}", inst_name, res);
                    continue;
                }

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
                                .bind(current_bal).bind(available_bal).bind(external_id)
                                .execute(db).await?;
                        } else {
                            sqlx::query(
                                r#"
                                INSERT INTO accounts (institution_id, external_id, name, account_type, currency, current_balance, available_balance)
                                VALUES ($1, $2, $3, $4, 'USD', $5, $6)
                                "#
                            )
                            .bind(inst_id).bind(external_id).bind(name).bind(subtype).bind(current_bal).bind(available_bal)
                            .execute(db).await?;
                        }
                    }
                }

                // 2. Fetch Transactions (/transactions/sync)
                let tx_url = format!("https://{}.plaid.com/transactions/sync", config.plaid_env);
                let mut cursor: Option<String> = row.try_get("plaid_transactions_cursor").unwrap_or(None);
                loop {
                    let mut payload = serde_json::json!({
                        "client_id": client_id,
                        "secret": secret,
                        "access_token": access_token
                    });
                    if let Some(cursor_value) = &cursor {
                        payload["cursor"] = serde_json::Value::String(cursor_value.clone());
                    }

                    let tx_val = client.post(&tx_url)
                        .json(&payload)
                        .send()
                        .await?
                        .json::<serde_json::Value>()
                        .await?;

                    if let Some(status) = plaid_error_status(&tx_val) {
                        update_sync_status(db, inst_id, status).await;
                        tracing::error!("Plaid transaction sync failed for {}: {:?}", inst_name, tx_val);
                        sync_ok = false;
                        break;
                    }

                    for key in ["added", "modified"] {
                        if let Some(transactions) = tx_val[key].as_array() {
                            for tx in transactions {
                                upsert_plaid_transaction(db, tx).await?;
                            }
                        }
                    }

                    if let Some(removed) = tx_val["removed"].as_array() {
                        for tx in removed {
                            if let Some(tx_ext_id) = tx["transaction_id"].as_str() {
                                sqlx::query("DELETE FROM transactions WHERE external_id = $1")
                                    .bind(tx_ext_id)
                                    .execute(db)
                                    .await?;
                            }
                        }
                    }

                    if let Some(next_cursor) = tx_val["next_cursor"].as_str() {
                        cursor = Some(next_cursor.to_string());
                    }
                    if !tx_val["has_more"].as_bool().unwrap_or(false) {
                        break;
                    }
                }
                if let Some(cursor) = cursor {
                    sqlx::query("UPDATE institutions SET plaid_transactions_cursor = $1 WHERE id = $2")
                        .bind(cursor)
                        .bind(inst_id)
                        .execute(db)
                        .await?;
                }
                if !sync_ok {
                    continue;
                }

                // 3. Fetch Investments (/investments/holdings/get)
                let hold_url = format!("https://{}.plaid.com/investments/holdings/get", config.plaid_env);
                if let Ok(hold_res) = client.post(&hold_url)
                    .json(&serde_json::json!({
                        "client_id": client_id,
                        "secret": secret,
                        "access_token": access_token
                    }))
                    .send().await {
                    if let Ok(hold_val) = hold_res.json::<serde_json::Value>().await {
                        if let Some(status) = plaid_error_status(&hold_val) {
                            update_sync_status(db, inst_id, status).await;
                            tracing::error!("Plaid holdings sync failed for {}: {:?}", inst_name, hold_val);
                            sync_ok = false;
                        }
                        let securities = plaid_security_lookup(&hold_val);
                        if let Some(holdings) = hold_val["holdings"].as_array() {
                            for h in holdings {
                                let acc_ext_id = h["account_id"].as_str().unwrap_or("");
                                let external_id = h["security_id"].as_str().unwrap_or("");
                                if external_id.is_empty() {
                                    continue;
                                }
                                let security = securities.get(external_id);
                                let symbol = security
                                    .map(|s| s.symbol.as_str())
                                    .filter(|symbol| !symbol.is_empty())
                                    .unwrap_or(external_id);
                                let name = security
                                    .map(|s| s.name.as_str())
                                    .filter(|name| !name.is_empty())
                                    .unwrap_or(symbol);
                                let holding_type = security
                                    .map(|s| s.security_type.as_str())
                                    .filter(|security_type| !security_type.is_empty())
                                    .unwrap_or("Investment");
                                let qty = h["quantity"].as_f64().unwrap_or(0.0);
                                let price = h["institution_price"].as_f64().unwrap_or(0.0);
                                let val = h["institution_value"].as_f64().unwrap_or(0.0);
                                let cost_basis = h["cost_basis"].as_f64().unwrap_or(val);

                                let internal_acc = sqlx::query("SELECT id FROM accounts WHERE external_id = $1")
                                    .bind(acc_ext_id)
                                    .fetch_optional(db).await.unwrap_or(None);

                                if let Some(acc_row) = internal_acc {
                                    let acc_id: uuid::Uuid = acc_row.get("id");
                                    let _ = sqlx::query(
                                        r#"
                                        INSERT INTO holdings (account_id, external_id, symbol, name, quantity, price, value, cost_basis, holding_type)
                                        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
                                        ON CONFLICT (account_id, external_id) WHERE external_id IS NOT NULL
                                        DO UPDATE SET
                                            symbol = EXCLUDED.symbol,
                                            name = EXCLUDED.name,
                                            quantity = EXCLUDED.quantity,
                                            price = EXCLUDED.price,
                                            value = EXCLUDED.value,
                                            cost_basis = EXCLUDED.cost_basis,
                                            holding_type = EXCLUDED.holding_type,
                                            updated_at = NOW()
                                        "#
                                    )
                                    .bind(acc_id)
                                    .bind(external_id)
                                    .bind(symbol)
                                    .bind(name)
                                    .bind(qty)
                                    .bind(price)
                                    .bind(val)
                                    .bind(cost_basis)
                                    .bind(holding_type)
                                    .execute(db).await;
                                }
                            }
                        }
                    }
                }
            },
            "coinbase" => {
                if let Err(e) = crate::services::crypto::CryptoService::sync_coinbase(db, config, inst_id).await {
                    tracing::error!("Failed to sync Coinbase for {}: {}", inst_name, e);
                    update_sync_status(db, inst_id, "error").await;
                    sync_ok = false;
                }
            },
            "coinbase_oauth" => {
                if let Err(e) = crate::services::crypto::CryptoService::sync_coinbase_oauth(db, config, inst_id).await {
                    tracing::error!("Failed to sync Coinbase OAuth for {}: {}", inst_name, e);
                    update_sync_status(db, inst_id, "error").await;
                    sync_ok = false;
                }
            },
            "bitso" => {
                if let Err(e) = crate::services::crypto::CryptoService::sync_bitso(db, config, inst_id).await {
                    tracing::error!("Failed to sync Bitso for {}: {}", inst_name, e);
                    update_sync_status(db, inst_id, "error").await;
                    sync_ok = false;
                }
            },
            "manual" | "csv" | "pdf" => {
                update_sync_status(db, inst_id, "manual").await;
                continue;
            },
            _ => {
                tracing::warn!("Unknown integration type: {} for {}", integration_type, inst_name);
                update_sync_status(db, inst_id, "error").await;
                sync_ok = false;
            },
        }

        if sync_ok {
            let _ = sqlx::query("UPDATE institutions SET last_synced_at = NOW(), sync_status = 'synced' WHERE id = $1")
                .bind(inst_id)
                .execute(db).await;
        }
            
        tracing::info!("Successfully synced {}", inst_name);
    }
    Ok(())
}

async fn update_sync_status(db: &PgPool, inst_id: uuid::Uuid, status: &str) {
    let _ = sqlx::query("UPDATE institutions SET sync_status = $1 WHERE id = $2")
        .bind(status)
        .bind(inst_id)
        .execute(db)
        .await;
}

fn plaid_error_status(payload: &serde_json::Value) -> Option<&'static str> {
    let error_code = payload["error_code"].as_str()?;
    match error_code {
        "ITEM_LOGIN_REQUIRED" | "ITEM_LOCKED" | "USER_PERMISSION_REVOKED" | "PENDING_EXPIRATION" => {
            Some("reconnect_required")
        }
        "PRODUCT_NOT_READY" => Some("pending"),
        _ => Some("error"),
    }
}

async fn upsert_plaid_transaction(db: &PgPool, tx: &serde_json::Value) -> Result<()> {
    let acc_ext_id = tx["account_id"].as_str().unwrap_or("");
    let tx_ext_id = tx["transaction_id"].as_str().unwrap_or("");
    if acc_ext_id.is_empty() || tx_ext_id.is_empty() {
        return Ok(());
    }

    let date_str = tx["date"].as_str().unwrap_or("1970-01-01");
    let date = chrono::NaiveDate::parse_from_str(date_str, "%Y-%m-%d")?;
    let name = tx["name"].as_str().unwrap_or("Unknown");
    // Plaid reports outflows as positive; the app models spending as negative.
    let amount = -tx["amount"].as_f64().unwrap_or(0.0);
    let currency = tx["iso_currency_code"].as_str().unwrap_or("USD");
    let merchant_name = tx["merchant_name"].as_str();
    let pending = tx["pending"].as_bool().unwrap_or(false);
    let legacy_category = tx["category"]
        .as_array()
        .and_then(|items| items.first())
        .and_then(|item| item.as_str());
    let category = tx["personal_finance_category"]["primary"]
        .as_str()
        .or(legacy_category);

    let internal_acc = sqlx::query("SELECT id FROM accounts WHERE external_id = $1")
        .bind(acc_ext_id)
        .fetch_optional(db)
        .await?;

    if let Some(acc_row) = internal_acc {
        let acc_id: uuid::Uuid = acc_row.get("id");
        sqlx::query(
            r#"
            INSERT INTO transactions (account_id, external_id, date, description, amount, currency, category, merchant_name, pending)
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            ON CONFLICT (account_id, external_id)
            DO UPDATE SET
                date = EXCLUDED.date,
                description = EXCLUDED.description,
                amount = EXCLUDED.amount,
                currency = EXCLUDED.currency,
                category = EXCLUDED.category,
                merchant_name = EXCLUDED.merchant_name,
                pending = EXCLUDED.pending
            "#
        )
        .bind(acc_id)
        .bind(tx_ext_id)
        .bind(date)
        .bind(name)
        .bind(amount)
        .bind(currency)
        .bind(category)
        .bind(merchant_name)
        .bind(pending)
        .execute(db)
        .await?;
    }

    Ok(())
}

#[derive(Debug)]
struct SecurityInfo {
    symbol: String,
    name: String,
    security_type: String,
}

fn plaid_security_lookup(payload: &serde_json::Value) -> HashMap<String, SecurityInfo> {
    let mut securities = HashMap::new();

    if let Some(items) = payload["securities"].as_array() {
        for item in items {
            let Some(id) = item["security_id"].as_str() else {
                continue;
            };
            let symbol = item["ticker_symbol"]
                .as_str()
                .or_else(|| item["cusip"].as_str())
                .or_else(|| item["sedol"].as_str())
                .unwrap_or(id)
                .to_string();
            let name = item["name"].as_str().unwrap_or(&symbol).to_string();
            let security_type = item["type"].as_str().unwrap_or("Investment").to_string();

            securities.insert(id.to_string(), SecurityInfo {
                symbol,
                name,
                security_type,
            });
        }
    }

    securities
}
