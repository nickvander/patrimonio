use anyhow::Result;
use sqlx::{PgPool, Row};
use reqwest::Client;
use crate::config::AppConfig;
use crate::services::encryption;
use std::collections::HashMap;
use futures_util::stream::StreamExt;

/// Max institutions synced at once. Bounds Plaid rate-limit exposure
/// (each institution can fan out several Plaid HTTP calls) and caps the
/// number of DB-pool connections the concurrent batch holds at any one
/// time. Keep modest — 5 is comfortably under typical pool sizes while
/// still collapsing a multi-institution sync from N round-trips of
/// latency to ~N/5.
const SYNC_CONCURRENCY: usize = 5;

/// Plain-data snapshot of one `institutions` row, read off the
/// `sqlx::Row` BEFORE the concurrent boundary so no non-`Send`/borrowed
/// row state is held across an `.await` inside a spawned future.
struct InstRow {
    id: uuid::Uuid,
    user_id: uuid::Uuid,
    name: String,
    integration_type: String,
    enc_token: Option<Vec<u8>>,
    cursor: Option<String>,
}

/// Sync every institution in the database, regardless of owner. Used
/// by the cron-scheduled refresh; the per-institution loop pulls
/// `user_id` off each row and stamps it onto inserted accounts,
/// transactions, balance snapshots, and holdings, so multi-user data
/// never crosses tenants even when the engine runs untethered to a
/// session.
pub async fn sync_all_institutions(db: &PgPool, config: &AppConfig) -> Result<()> {
    sync_institutions(db, config, None, None).await
}

/// Sync engine variant scoped to a single user. Used by the manual
/// "Sync all accounts" button on the dashboard — the caller's session
/// supplies `user_id`, and the engine skips every institution that
/// doesn't belong to them.
pub async fn sync_user_institutions(
    db: &PgPool,
    config: &AppConfig,
    user_id: uuid::Uuid,
    only_ids: Option<Vec<uuid::Uuid>>,
) -> Result<()> {
    sync_institutions(db, config, Some(user_id), only_ids).await
}

/// Sync engine variant scoped to a single institution. Kept as a thin
/// wrapper for callers that already verified ownership. New code
/// should prefer `sync_user_institutions(.., Some(vec![id]))` so the
/// engine itself enforces the per-user filter.
pub async fn sync_one_institution(
    db: &PgPool,
    config: &AppConfig,
    id: uuid::Uuid,
) -> Result<()> {
    sync_institutions(db, config, None, Some(vec![id])).await
}

/// Internal sync loop.
///
/// * `user_filter` — when `Some`, only institutions owned by this user
///   are touched. The cron-scheduled run passes `None`.
/// * `only_ids` — when `Some`, narrows the run to those institution ids.
///   Combined with `user_filter`, foreign ids are silently filtered out.
pub async fn sync_institutions(
    db: &PgPool,
    config: &AppConfig,
    user_filter: Option<uuid::Uuid>,
    only_ids: Option<Vec<uuid::Uuid>>,
) -> Result<()> {
    tracing::info!(
        "Sync engine: starting sync for {} (user_filter={})",
        match &only_ids {
            Some(ids) => format!("{} institution(s)", ids.len()),
            None => "all institutions".to_string(),
        },
        user_filter
            .map(|u| u.to_string())
            .unwrap_or_else(|| "<all>".to_string()),
    );
    let client = Client::new();

    let rows = match (&only_ids, &user_filter) {
        (Some(ids), Some(uid)) => sqlx::query(
            "SELECT id, name, integration_type, plaid_access_token_enc, plaid_transactions_cursor, user_id \
             FROM institutions WHERE id = ANY($1) AND user_id = $2"
        )
        .bind(ids)
        .bind(uid)
        .fetch_all(db)
        .await?,
        (Some(ids), None) => sqlx::query(
            "SELECT id, name, integration_type, plaid_access_token_enc, plaid_transactions_cursor, user_id \
             FROM institutions WHERE id = ANY($1)"
        )
        .bind(ids)
        .fetch_all(db)
        .await?,
        (None, Some(uid)) => sqlx::query(
            "SELECT id, name, integration_type, plaid_access_token_enc, plaid_transactions_cursor, user_id \
             FROM institutions WHERE user_id = $1"
        )
        .bind(uid)
        .fetch_all(db)
        .await?,
        (None, None) => sqlx::query(
            "SELECT id, name, integration_type, plaid_access_token_enc, plaid_transactions_cursor, user_id FROM institutions"
        )
        .fetch_all(db)
        .await?,
    };

    // Read each row into a plain `InstRow` BEFORE the concurrent
    // boundary so the borrowed `sqlx::Row` is never held across an
    // `.await` inside a spawned future.
    let insts: Vec<InstRow> = rows
        .into_iter()
        .map(|row| InstRow {
            id: row.get("id"),
            user_id: row.get("user_id"),
            name: row.get("name"),
            integration_type: row.get("integration_type"),
            enc_token: row.try_get("plaid_access_token_enc").unwrap_or(None),
            cursor: row.try_get("plaid_transactions_cursor").unwrap_or(None),
        })
        .collect();

    // Run institutions with BOUNDED concurrency. `db`/`config`/`client`
    // are shared by reference across the futures (PgPool + reqwest::Client
    // are Sync); they're only awaited within this scope. A single
    // institution's failure is isolated inside `sync_one_inst` and never
    // aborts the batch.
    futures_util::stream::iter(
        insts
            .into_iter()
            .map(|inst| sync_one_inst(db, config, &client, inst)),
    )
    .buffer_unordered(SYNC_CONCURRENCY)
    .collect::<Vec<()>>()
    .await;

    run_fx_sweep(db, user_filter).await;

    Ok(())
}

/// Sync a single institution. This is exactly what one iteration of the
/// old sequential loop did, lifted into an async helper so the batch can
/// run institutions concurrently.
///
/// Error isolation: the fallible work runs in an inner `async` block
/// returning `anyhow::Result<bool>` (the bool is the old `sync_ok`). A
/// propagated `?` error no longer aborts the whole sync — it surfaces
/// here as `Err`, and unless a more specific status
/// (reconnect_required / pending / setup_required / manual / …) was
/// already stamped, we mark the institution `error`. The existing
/// `continue`-style skips become early `return Ok(...)` from the inner
/// block.
async fn sync_one_inst(db: &PgPool, config: &AppConfig, client: &Client, inst: InstRow) {
    let inst_id = inst.id;
    let inst_user_id = inst.user_id;
    let inst_name = inst.name.clone();
    let integration_type = inst.integration_type.clone();
    let enc_token = inst.enc_token.clone();
    let initial_cursor = inst.cursor.clone();

    update_sync_status(db, inst_id, "syncing", None).await;

    // Inner fallible block. Returns the old `sync_ok` flag on success;
    // any `?` here is caught below instead of aborting the batch.
    let result: Result<bool> = async {
        let mut sync_ok = true;

        match integration_type.as_str() {
            "plaid" => {
                if enc_token.is_none() {
                    update_sync_status(db, inst_id, "pending", None).await;
                    return Ok(false);
                }

                let Some(enc_key) = config.encryption_key.as_ref() else {
                    update_sync_status(db, inst_id, "setup_required", Some("Encryption key missing")).await;
                    tracing::error!("Cannot sync {}: ENCRYPTION_KEY required", inst_name);
                    return Ok(false);
                };
                let access_token = match encryption::decrypt(enc_key, enc_token.as_ref().unwrap()) {
                    Ok(t) => t,
                    Err(e) => {
                        tracing::error!("Failed to decrypt token for {}: {}", inst_name, e);
                        update_sync_status(db, inst_id, "error", Some(&e.to_string())).await;
                        return Ok(false);
                    }
                };
                let (Some(client_id), Some(secret)) = (&config.plaid_client_id, &config.plaid_secret) else {
                    update_sync_status(db, inst_id, "setup_required", Some("Plaid credentials missing")).await;
                    tracing::error!("Cannot sync {}: Plaid credentials required", inst_name);
                    return Ok(false);
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
                    let error_msg = res["error_message"].as_str().unwrap_or("Unknown Plaid error");
                    update_sync_status(db, inst_id, status, Some(error_msg)).await;
                    tracing::error!("Plaid balance sync failed for {}: {:?}", inst_name, res);
                    return Ok(false);
                }

                if let Some(accounts) = res["accounts"].as_array() {
                    for acc in accounts {
                        let external_id = acc["account_id"].as_str().unwrap_or("");
                        let subtype = acc["subtype"].as_str().unwrap_or("checking");
                        let mask = acc["mask"].as_str().unwrap_or("");
                        // Friendly display name. Prefer Plaid's official name;
                        // otherwise rewrite a generic "<broad type> Account
                        // <mask>" (some banks — e.g. Capital One — return
                        // "depository Account 0916" from the broad `type`, not
                        // the subtype) or an empty/"Unknown" name into
                        // "<Subtype> ••<mask>" ("Checking ••0916").
                        let pretty_subtype = subtype
                            .split(' ')
                            .map(|w| {
                                let mut ch = w.chars();
                                match ch.next() {
                                    Some(f) => {
                                        f.to_uppercase().collect::<String>() + ch.as_str()
                                    }
                                    None => String::new(),
                                }
                            })
                            .collect::<Vec<_>>()
                            .join(" ");
                        let official = acc["official_name"]
                            .as_str()
                            .map(str::trim)
                            .filter(|s| !s.is_empty());
                        let plaid_name = acc["name"]
                            .as_str()
                            .map(str::trim)
                            .filter(|s| !s.is_empty());
                        let is_generic = plaid_name.is_none_or(|n| {
                            let l = n.to_lowercase();
                            l == "unknown"
                                || [
                                    "depository",
                                    "credit",
                                    "investment",
                                    "loan",
                                    "brokerage",
                                    "other",
                                ]
                                .iter()
                                .any(|b| l.starts_with(&format!("{b} account")))
                        });
                        let name: String = if let Some(o) = official {
                            o.to_string()
                        } else if is_generic {
                            if mask.is_empty() {
                                format!("{pretty_subtype} account")
                            } else {
                                format!("{pretty_subtype} \u{2022}\u{2022}{mask}")
                            }
                        } else {
                            plaid_name.unwrap().to_string()
                        };
                        let current_bal = acc["balances"]["current"].as_f64();
                        let available_bal = acc["balances"]["available"].as_f64();
                        // Plaid returns the credit line in balances.limit for
                        // credit cards (null for most depository accounts and
                        // for issuers that don't expose it). Drives the credit-
                        // utilization card.
                        let credit_limit = acc["balances"]["limit"].as_f64();

                        // Look up account scoped to this institution +
                        // owner. external_id is Plaid-issued and shouldn't
                        // collide across users, but the ownership predicate
                        // is cheap defence.
                        let existing = sqlx::query(
                            "SELECT id FROM accounts WHERE external_id = $1 AND user_id = $2"
                        )
                            .bind(external_id)
                            .bind(inst_user_id)
                            .fetch_optional(db).await?;

                        if existing.is_some() {
                            // COALESCE keeps a previously-fetched limit when a
                            // later sync returns null (Plaid is sometimes
                            // inconsistent about populating it).
                            sqlx::query(
                                "UPDATE accounts SET current_balance = $1, available_balance = $2, credit_limit = COALESCE($3, credit_limit), updated_at = NOW() WHERE external_id = $4 AND user_id = $5"
                            )
                                .bind(current_bal).bind(available_bal).bind(credit_limit).bind(external_id).bind(inst_user_id)
                                .execute(db).await?;
                        } else {
                            sqlx::query(
                                r#"
                                INSERT INTO accounts (institution_id, external_id, name, account_type, currency, current_balance, available_balance, credit_limit, user_id)
                                VALUES ($1, $2, $3, $4, 'USD', $5, $6, $7, $8)
                                "#
                            )
                            .bind(inst_id).bind(external_id).bind(&name).bind(subtype).bind(current_bal).bind(available_bal).bind(credit_limit).bind(inst_user_id)
                            .execute(db).await?;
                        }

                        // Persist today's balance into balance_snapshots so
                        // net_worth_history actually contains Plaid accounts.
                        // user_id propagates from the institution row above.
                        if let Some(bal) = current_bal {
                            let _ = sqlx::query(
                                r#"
                                INSERT INTO balance_snapshots (account_id, balance, as_of_date, currency, balance_usd, user_id)
                                SELECT id, $1, CURRENT_DATE, 'USD', $1, $3 FROM accounts WHERE external_id = $2 AND user_id = $3
                                ON CONFLICT (account_id, as_of_date)
                                DO UPDATE SET balance = EXCLUDED.balance, balance_usd = EXCLUDED.balance_usd, created_at = NOW()
                                "#
                            )
                            .bind(bal)
                            .bind(external_id)
                            .bind(inst_user_id)
                            .execute(db)
                            .await;
                        }
                    }
                }

                // 2. Fetch Transactions (/transactions/sync)
                let tx_url = format!("https://{}.plaid.com/transactions/sync", config.plaid_env);
                let mut cursor: Option<String> = initial_cursor;
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
                        let error_msg = tx_val["error_message"].as_str().unwrap_or("Unknown Plaid error");
                        update_sync_status(db, inst_id, status, Some(error_msg)).await;
                        tracing::error!("Plaid transaction sync failed for {}: {:?}", inst_name, tx_val);
                        sync_ok = false;
                        break;
                    }

                    for key in ["added", "modified"] {
                        if let Some(transactions) = tx_val[key].as_array() {
                            for tx in transactions {
                                upsert_plaid_transaction(db, tx, inst_user_id).await?;
                            }
                        }
                    }

                    if let Some(removed) = tx_val["removed"].as_array() {
                        for tx in removed {
                            if let Some(tx_ext_id) = tx["transaction_id"].as_str() {
                                sqlx::query(
                                    "DELETE FROM transactions WHERE external_id = $1 AND user_id = $2"
                                )
                                    .bind(tx_ext_id)
                                    .bind(inst_user_id)
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
                    return Ok(false);
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
                        // Items without the investments product (credit cards,
                        // plain depository) return a soft error here. Skip it —
                        // don't taint the institution: the accounts/balance pass
                        // already imported the card/bank accounts; there are just
                        // no holdings to fetch. Only real errors set the status.
                        let soft_no_investments = matches!(
                            hold_val["error_code"].as_str(),
                            Some("INVALID_PRODUCT")
                                | Some("PRODUCTS_NOT_SUPPORTED")
                                | Some("PRODUCT_NOT_ENABLED")
                                | Some("NO_INVESTMENT_ACCOUNTS")
                        );
                        if soft_no_investments {
                            tracing::info!(
                                "Plaid holdings skipped for {} ({}) — no investment accounts",
                                inst_name,
                                hold_val["error_code"].as_str().unwrap_or("")
                            );
                        } else if let Some(status) = plaid_error_status(&hold_val) {
                            let error_msg = hold_val["error_message"].as_str().unwrap_or("Unknown Plaid error");
                            update_sync_status(db, inst_id, status, Some(error_msg)).await;
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
                                // Plaid omits cost_basis for many employer plans
                                // (e.g. 401k). Store SQL NULL — NOT the current
                                // value — so the API can distinguish "unknown
                                // basis" from a real zero-gain position. The
                                // upsert below overwrites with EXCLUDED.cost_basis,
                                // so previously-poisoned rows (basis == value)
                                // self-heal to NULL on the next sync.
                                let cost_basis: Option<f64> = h["cost_basis"].as_f64();

                                let internal_acc = sqlx::query(
                                    "SELECT id FROM accounts WHERE external_id = $1 AND user_id = $2"
                                )
                                    .bind(acc_ext_id)
                                    .bind(inst_user_id)
                                    .fetch_optional(db).await.unwrap_or(None);

                                if let Some(acc_row) = internal_acc {
                                    let acc_id: uuid::Uuid = acc_row.get("id");
                                    let _ = sqlx::query(
                                        r#"
                                        INSERT INTO holdings (account_id, external_id, symbol, name, quantity, price, value, cost_basis, holding_type, user_id)
                                        VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
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
                                    .bind(inst_user_id)
                                    .execute(db).await;
                                }
                            }
                        }
                    }
                }

                // 4. Fetch Investment Transactions (/investments/transactions/get)
                //
                // This is the lot-tracking pass. Plaid's investments
                // transactions feed gives us buy/sell/dividend events
                // we can map to `holding_lots` rows. Each `buy`
                // creates a lot at the transaction's price + that
                // date's USD/MXN FX rate; each `sell` FIFO-depletes
                // the oldest lots so the dual-currency P&L on the
                // dashboard reflects true historical cost basis
                // instead of the current-FX approximation.
                //
                // We use a 1-year lookback per call. Plaid paginates
                // via offset; the deterministic `transaction_id` ->
                // `source_id` mapping plus the partial unique index
                // on (holding_id, source_id) means re-syncing the
                // same window is idempotent.
                let inv_url = format!(
                    "https://{}.plaid.com/investments/transactions/get",
                    config.plaid_env
                );
                let inv_end = chrono::Utc::now().date_naive();
                let inv_start = inv_end - chrono::Duration::days(365);
                let mut inv_offset: i64 = 0;
                let inv_count: i64 = 250; // Plaid's max
                loop {
                    let inv_payload = serde_json::json!({
                        "client_id": client_id,
                        "secret": secret,
                        "access_token": access_token,
                        "start_date": inv_start.to_string(),
                        "end_date": inv_end.to_string(),
                        "options": { "count": inv_count, "offset": inv_offset },
                    });
                    let inv_res = client.post(&inv_url).json(&inv_payload).send().await;
                    let Ok(inv_resp) = inv_res else {
                        tracing::warn!(
                            "Plaid investments/transactions HTTP error for {}; skipping lot sync",
                            inst_name
                        );
                        break;
                    };
                    let inv_val: serde_json::Value = match inv_resp.json().await {
                        Ok(v) => v,
                        Err(e) => {
                            tracing::warn!(
                                "Plaid investments/transactions JSON parse error for {}: {}",
                                inst_name, e
                            );
                            break;
                        }
                    };
                    // Some Items don't have the investments product
                    // enabled; that returns a soft error we just
                    // skip (don't taint the institution status —
                    // the holdings call already succeeded).
                    if let Some(err_code) = inv_val["error_code"].as_str() {
                        match err_code {
                            "INVALID_PRODUCT"
                            | "PRODUCTS_NOT_SUPPORTED"
                            | "PRODUCT_NOT_READY" => {
                                tracing::info!(
                                    "Plaid investments/transactions skipped for {} ({})",
                                    inst_name, err_code
                                );
                            }
                            _ => {
                                tracing::warn!(
                                    "Plaid investments/transactions error for {}: {:?}",
                                    inst_name, inv_val
                                );
                            }
                        }
                        break;
                    }
                    let Some(events) = inv_val["investment_transactions"].as_array() else {
                        break;
                    };
                    for ev in events {
                        if let Err(e) = process_investment_event(db, ev, inst_user_id).await {
                            // Per-event errors don't taint the
                            // whole sync; log and move on.
                            tracing::warn!(
                                "investment event {} skipped: {}",
                                ev["investment_transaction_id"].as_str().unwrap_or("?"),
                                e
                            );
                        }
                    }
                    let total: i64 = inv_val["total_investment_transactions"]
                        .as_i64()
                        .unwrap_or(0);
                    inv_offset += events.len() as i64;
                    if inv_offset >= total || events.is_empty() {
                        break;
                    }
                }
            },
            "coinbase" => {
                if let Err(e) = crate::services::crypto::CryptoService::sync_coinbase(db, config, inst_id, inst_user_id).await {
                    tracing::error!("Failed to sync Coinbase for {}: {}", inst_name, e);
                    update_sync_status(db, inst_id, "error", Some(&e.to_string())).await;
                    sync_ok = false;
                }
            },
            "coinbase_oauth" => {
                if let Err(e) = crate::services::crypto::CryptoService::sync_coinbase_oauth(db, config, inst_id, inst_user_id).await {
                    tracing::error!("Failed to sync Coinbase OAuth for {}: {}", inst_name, e);
                    update_sync_status(db, inst_id, "error", Some(&e.to_string())).await;
                    sync_ok = false;
                }
            },
            "bitso" => {
                if let Err(e) = crate::services::crypto::CryptoService::sync_bitso(db, config, inst_id, inst_user_id).await {
                    tracing::error!("Failed to sync Bitso for {}: {}", inst_name, e);
                    update_sync_status(db, inst_id, "error", Some(&e.to_string())).await;
                    sync_ok = false;
                }
            },
            "manual" | "csv" | "pdf" => {
                update_sync_status(db, inst_id, "manual", None).await;
                return Ok(false);
            },
            _ => {
                tracing::warn!("Unknown integration type: {} for {}", integration_type, inst_name);
                update_sync_status(db, inst_id, "error", Some("Unknown integration type")).await;
                sync_ok = false;
            },
        }

        Ok(sync_ok)
    }
    .await;

    match result {
        Ok(true) => {
            let _ = sqlx::query("UPDATE institutions SET last_synced_at = NOW(), sync_status = 'synced', last_sync_error = NULL WHERE id = $1")
                .bind(inst_id)
                .execute(db).await;
            tracing::info!("Successfully synced {}", inst_name);
        }
        Ok(false) => {
            // A specific status (pending / setup_required / manual /
            // reconnect_required / error / …) was already stamped by the
            // inner block; nothing more to do.
        }
        Err(e) => {
            // A propagated `?` (e.g. a Plaid HTTP/JSON failure or a DB
            // error) bubbled out instead of aborting the whole batch.
            // Mark this institution `error` unless a more specific
            // status was already set, and never touch the others.
            tracing::error!("Sync failed for {}: {}", inst_name, e);
            update_sync_status(db, inst_id, "error", Some(&e.to_string())).await;
        }
    }
}

/// Per-user FX-transfer detection sweep, run ONCE after the whole
/// concurrent institution batch finishes (not per-institution).
async fn run_fx_sweep(db: &PgPool, user_filter: Option<uuid::Uuid>) {
    // Per-user FX-transfer detection sweep. Runs once after every
    // institution belonging to a given user has finished syncing —
    // this is where new candidate pairs first become visible
    // (the USD-out and the MXN-in only land in the same window once
    // both their institutions have run /transactions/sync). Failures
    // here are logged but don't fail the sync itself.
    //
    // For the broader "all institutions" run we collect distinct
    // user_ids from the rows we processed and run detection once
    // per user. Detection itself is idempotent (the unique pair
    // index dedupes), so re-running on every sync is safe — the only
    // cost is the candidate scan, which is bounded to the last 90
    // days and is sub-second on small accounts.
    let user_ids: Vec<uuid::Uuid> = match user_filter {
        Some(uid) => vec![uid],
        None => {
            let rows = sqlx::query("SELECT DISTINCT user_id FROM institutions")
                .fetch_all(db)
                .await
                .unwrap_or_default();
            rows.iter()
                .filter_map(|r| r.try_get::<uuid::Uuid, _>("user_id").ok())
                .collect()
        }
    };
    for uid in user_ids {
        match crate::services::fx_transfer_link::detect_for_user(db, uid).await {
            Ok((checked, inserted)) => {
                if inserted > 0 {
                    tracing::info!(
                        "fx_transfer_link: user {} - {}/{} new links from {} candidates",
                        uid, inserted, inserted, checked
                    );
                }
            }
            Err(e) => tracing::warn!("fx_transfer_link: user {} sweep failed: {}", uid, e),
        }
    }
}

async fn update_sync_status(db: &PgPool, inst_id: uuid::Uuid, status: &str, error: Option<&str>) {
    let _ = sqlx::query("UPDATE institutions SET sync_status = $1, last_sync_error = $2 WHERE id = $3")
        .bind(status)
        .bind(error)
        .bind(inst_id)
        .execute(db)
        .await;
}

fn plaid_error_status(payload: &serde_json::Value) -> Option<&'static str> {
    let error_code = payload["error_code"].as_str()?;
    match error_code {
        // NO_ACCOUNTS surfaces when Plaid loses visibility on an Item's accounts
        // (e.g. Vanguard MFA expiry). Surfacing it as reconnect_required gives
        // the user a clear "Reconnect" action rather than a generic error.
        "ITEM_LOGIN_REQUIRED" | "ITEM_LOCKED" | "USER_PERMISSION_REVOKED"
        | "PENDING_EXPIRATION" | "NO_ACCOUNTS" => Some("reconnect_required"),
        "PRODUCT_NOT_READY" => Some("pending"),
        _ => Some("error"),
    }
}

async fn upsert_plaid_transaction(
    db: &PgPool,
    tx: &serde_json::Value,
    user_id: uuid::Uuid,
) -> Result<()> {
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
    // Plaid's Personal Finance Category taxonomy has two levels:
    //   primary  — coarse bucket, e.g. "LOAN_PAYMENTS"
    //   detailed — specific, e.g. "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT"
    // The detailed enum is *much* more useful in the UI, so we store
    // both. Legacy `category[0]` is kept as a fallback for older items
    // that pre-date the PFC taxonomy.
    let category = tx["personal_finance_category"]["primary"]
        .as_str()
        .or(legacy_category);
    let category_detailed = tx["personal_finance_category"]["detailed"].as_str();
    let payment_channel = tx["payment_channel"].as_str();
    // Plaid Production enrichment that prior schema ignored. `original_description`
    // is the raw bank line — keeps the specifics when Plaid's cleaned `name` is
    // a generic fallback ("Miscellaneous Debit"). `counterparties[]` is Plaid's
    // enriched merchant-entity list; pick the highest-confidence entry so the
    // UI gets a real merchant + logo when `merchant_name` is null.
    let original_description = tx["original_description"].as_str();
    let (counterparty_name, counterparty_logo_url) = best_counterparty(&tx["counterparties"]);
    // `payment_meta.payee` / `payer` are the only useful identifiers on
    // ACH transfers, wires, and bill-pay rows where `name` is generic
    // ("Miscellaneous Debit") and both merchant + counterparty are null.
    // Trim whitespace; empty/whitespace-only stays None so the display
    // ladder skips past it cleanly.
    let payment_payee = tx["payment_meta"]["payee"]
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty());
    let payment_payer = tx["payment_meta"]["payer"]
        .as_str()
        .map(str::trim)
        .filter(|s| !s.is_empty());

    // Account lookup scoped by user — accidental cross-tenant external_id
    // collisions are silently ignored rather than letting Plaid data from
    // one user land in another user's account.
    let internal_acc =
        sqlx::query("SELECT id FROM accounts WHERE external_id = $1 AND user_id = $2")
            .bind(acc_ext_id)
            .bind(user_id)
            .fetch_optional(db)
            .await?;

    if let Some(acc_row) = internal_acc {
        let acc_id: uuid::Uuid = acc_row.get("id");
        sqlx::query(
            r#"
            INSERT INTO transactions (
                account_id, external_id, date, description, amount, currency,
                category, category_detailed, payment_channel, merchant_name,
                pending, source, original_description, counterparty_name,
                counterparty_logo_url, payment_payee, payment_payer, user_id
            )
            VALUES (
                $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, 'plaid',
                $12, $13, $14, $15, $16, $17
            )
            ON CONFLICT (account_id, external_id)
            DO UPDATE SET
                date = EXCLUDED.date,
                description = EXCLUDED.description,
                amount = EXCLUDED.amount,
                currency = EXCLUDED.currency,
                category = EXCLUDED.category,
                category_detailed = EXCLUDED.category_detailed,
                payment_channel = EXCLUDED.payment_channel,
                merchant_name = EXCLUDED.merchant_name,
                pending = EXCLUDED.pending,
                original_description = EXCLUDED.original_description,
                counterparty_name = EXCLUDED.counterparty_name,
                counterparty_logo_url = EXCLUDED.counterparty_logo_url,
                payment_payee = COALESCE(EXCLUDED.payment_payee, transactions.payment_payee),
                payment_payer = COALESCE(EXCLUDED.payment_payer, transactions.payment_payer)
            "#
        )
        .bind(acc_id)
        .bind(tx_ext_id)
        .bind(date)
        .bind(name)
        .bind(amount)
        .bind(currency)
        .bind(category)
        .bind(category_detailed)
        .bind(payment_channel)
        .bind(merchant_name)
        .bind(pending)
        .bind(original_description)
        .bind(counterparty_name.as_deref())
        .bind(counterparty_logo_url.as_deref())
        .bind(payment_payee)
        .bind(payment_payer)
        .bind(user_id)
        .execute(db)
        .await?;
    }

    Ok(())
}

/// Pick the most authoritative counterparty from Plaid's `counterparties[]`
/// array. Prefer VERY_HIGH/HIGH confidence and the MERCHANT type (over
/// FINANCIAL_INSTITUTION, PAYMENT_APP, MARKETPLACE, etc., which are
/// usually middlemen rather than the entity the user recognises).
/// Returns (name, logo_url) — either can be None even when a counterparty
/// exists, since Plaid doesn't always include a logo.
fn best_counterparty(arr: &serde_json::Value) -> (Option<String>, Option<String>) {
    let Some(items) = arr.as_array() else {
        return (None, None);
    };
    if items.is_empty() {
        return (None, None);
    }
    fn score(cp: &serde_json::Value) -> i32 {
        let conf = cp["confidence_level"].as_str().unwrap_or("");
        let kind = cp["type"].as_str().unwrap_or("");
        let conf_score = match conf {
            "VERY_HIGH" => 30,
            "HIGH" => 20,
            "MEDIUM" => 10,
            _ => 0,
        };
        // Type is the PRIMARY sort key — its weights are spaced wider than
        // the 0..30 confidence range so a real MERCHANT always beats an
        // aggregator/middleman, even a VERY_HIGH-confidence one. This is
        // what makes "SQ *COFFEESHOP" surface as the coffee shop rather
        // than "Square": Square is a payment_app (base 0 + VERY_HIGH 30 =
        // 30) while the shop is a merchant (base 100 + e.g. MEDIUM 10 =
        // 110). Confidence only breaks ties within the same type.
        let type_base = match kind {
            "merchant" | "MERCHANT" => 100,
            "marketplace" | "MARKETPLACE" => 60,
            // Middlemen the user doesn't think of as "the merchant":
            // payment processors (Square/Stripe/PayPal/Toast), the issuing
            // bank, and payroll/income sources. Demoted below the neutral
            // baseline so any typed merchant wins.
            "payment_app" | "PAYMENT_APP"
            | "financial_institution" | "FINANCIAL_INSTITUTION"
            | "income_source" | "INCOME_SOURCE" => 0,
            // Untyped / unknown entries sit between merchants and known
            // middlemen — better than a processor, worse than a named shop.
            _ => 40,
        };
        type_base + conf_score
    }
    let best = items
        .iter()
        .filter(|cp| cp["name"].as_str().is_some_and(|n| !n.trim().is_empty()))
        .max_by_key(|cp| score(cp));
    let Some(best) = best else {
        return (None, None);
    };
    let name = best["name"].as_str().map(|s| s.trim().to_string());
    let logo = best["logo_url"]
        .as_str()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty());
    (name, logo)
}

#[cfg(test)]
mod counterparty_tests {
    use super::best_counterparty;
    use serde_json::json;

    #[test]
    fn empty_array_returns_none() {
        assert_eq!(best_counterparty(&json!([])), (None, None));
        assert_eq!(best_counterparty(&serde_json::Value::Null), (None, None));
    }

    #[test]
    fn picks_very_high_over_low_confidence() {
        let arr = json!([
            {"name": "Stripe", "type": "payment_app", "confidence_level": "LOW"},
            {"name": "Patagonia", "type": "merchant", "confidence_level": "VERY_HIGH",
             "logo_url": "https://cdn.example/patagonia.png"},
            {"name": "Visa", "type": "financial_institution", "confidence_level": "MEDIUM"},
        ]);
        let (name, logo) = best_counterparty(&arr);
        assert_eq!(name.as_deref(), Some("Patagonia"));
        assert_eq!(logo.as_deref(), Some("https://cdn.example/patagonia.png"));
    }

    #[test]
    fn prefers_merchant_over_high_confidence_payment_app() {
        // The "Square vs Coffeeshop" case: the aggregator carries higher
        // Plaid confidence, but the user recognises the shop. The merchant
        // must win despite lower confidence.
        let arr = json!([
            {"name": "Square", "type": "payment_app", "confidence_level": "VERY_HIGH"},
            {"name": "Coffeeshop", "type": "merchant", "confidence_level": "MEDIUM"},
        ]);
        assert_eq!(best_counterparty(&arr).0.as_deref(), Some("Coffeeshop"));
    }

    #[test]
    fn falls_back_to_payment_app_when_no_merchant() {
        // No merchant in the array — we still surface something rather than
        // dropping the counterparty entirely.
        let arr = json!([
            {"name": "PayPal", "type": "payment_app", "confidence_level": "HIGH"},
        ]);
        assert_eq!(best_counterparty(&arr).0.as_deref(), Some("PayPal"));
    }

    #[test]
    fn skips_empty_name_entries() {
        let arr = json!([
            {"name": "", "confidence_level": "VERY_HIGH"},
            {"name": "Trader Joe's", "confidence_level": "HIGH"},
        ]);
        assert_eq!(best_counterparty(&arr).0.as_deref(), Some("Trader Joe's"));
    }

    #[test]
    fn missing_logo_is_none() {
        let arr = json!([{"name": "Local Cafe", "confidence_level": "HIGH"}]);
        let (name, logo) = best_counterparty(&arr);
        assert_eq!(name.as_deref(), Some("Local Cafe"));
        assert_eq!(logo, None);
    }
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

/// Map one Plaid `investment_transaction` into a lot insert or a
/// FIFO sell depletion. Dispatch by `type`:
///
///   * `buy` (and `transfer` with positive qty into the account,
///     and `dividend` with the reinvestment subtype) → new lot
///   * `sell` → FIFO depletion across this user's existing lots
///     for the same security
///   * cash `dividend` / `interest` → persisted as an income
///     `transactions` row (see `upsert_investment_income_event`):
///     investment-account cash events do NOT flow through the regular
///     /transactions/sync product, so without this they'd vanish and
///     the 1099-DIV line would silently read $0 (T6)
///   * everything else → skip (fees, deposits/withdrawals don't
///     change shares and aren't income)
///
/// Idempotency: the partial unique index on
/// `(holding_id, source_id)` means re-syncing the same window
/// silently no-ops new-lot inserts that have already happened.
/// For sells, the deduplication is more interesting — we use a
/// `holding_lots` row with `source_id` and `qty = 0 - depleted_qty`
/// (a "sell marker") so re-running sees the marker and skips
/// re-applying the depletion. Without this guard, every re-sync
/// would FIFO-deplete the same sell twice and wipe genuine lots.
/// `pub` (rather than private like the rest of the lot pipeline) so the
/// integration suite can feed it Plaid-shaped payloads directly — there is
/// no HTTP seam in front of the sync engine to test through.
pub async fn process_investment_event(
    db: &PgPool,
    ev: &serde_json::Value,
    user_id: uuid::Uuid,
) -> Result<()> {
    let source_id = ev["investment_transaction_id"]
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("missing investment_transaction_id"))?;
    let tx_type = ev["type"].as_str().unwrap_or("");
    let subtype = ev["subtype"].as_str().unwrap_or("");

    // T6: cash dividends / brokerage interest are income, not lot events —
    // persist them as transactions rows and stop here. This must run BEFORE
    // the security-id guard below: interest events routinely carry a null
    // `security_id` (the cash sleeve has no security) and would otherwise be
    // silently dropped.
    if upsert_investment_income_event(db, ev, user_id).await? {
        return Ok(());
    }

    let security_external_id = ev["security_id"].as_str().unwrap_or("");
    let account_external_id = ev["account_id"].as_str().unwrap_or("");
    if security_external_id.is_empty() || account_external_id.is_empty() {
        return Ok(());
    }
    let date_str = ev["date"].as_str().unwrap_or("");
    let acquired_at = chrono::NaiveDate::parse_from_str(date_str, "%Y-%m-%d")
        .map_err(|e| anyhow::anyhow!("bad date {}: {}", date_str, e))?;
    let quantity = ev["quantity"].as_f64().unwrap_or(0.0);
    let amount = ev["amount"].as_f64().unwrap_or(0.0);
    let price = ev["price"].as_f64().unwrap_or_else(|| {
        if quantity.abs() > 0.0 { (amount / quantity).abs() } else { 0.0 }
    });
    let currency = ev["iso_currency_code"]
        .as_str()
        .or_else(|| ev["unofficial_currency_code"].as_str())
        .unwrap_or("USD")
        .to_string();

    // Classify the event. Plaid's enum is inconsistent over time —
    // accept both lowercased + word variants.
    let is_buy = matches!(tx_type, "buy") || matches!(subtype, "buy");
    let is_dividend_reinvest = matches!(subtype, "dividend reinvestment" | "reinvestment");
    let is_sell = matches!(tx_type, "sell") || matches!(subtype, "sell");

    if !(is_buy || is_sell || is_dividend_reinvest) {
        return Ok(());
    }

    // Look up the holding + account scoped to user.
    let holding_row = sqlx::query(
        r#"
        SELECT h.id as holding_id, a.id as account_id
        FROM holdings h
        JOIN accounts a ON h.account_id = a.id
        WHERE h.external_id = $1 AND a.external_id = $2 AND h.user_id = $3
        "#,
    )
    .bind(security_external_id)
    .bind(account_external_id)
    .bind(user_id)
    .fetch_optional(db)
    .await?;
    let Some(row) = holding_row else {
        // Sometimes the investment_transactions feed mentions
        // securities we haven't yet seen in /holdings/get (recently
        // sold positions, fractional residue). Skip silently — the
        // next holdings sync will create the row, then re-running
        // this lot sync will pick up the historical buys via
        // source_id idempotency.
        return Ok(());
    };
    let holding_id: uuid::Uuid = row.get("holding_id");
    let account_id: uuid::Uuid = row.get("account_id");

    if is_buy || is_dividend_reinvest {
        let usd_fx_rate = lookup_usd_fx_rate(db, &currency, acquired_at).await;
        sqlx::query(
            r#"
            INSERT INTO holding_lots (
                holding_id, account_id, user_id,
                acquired_at, qty, cost_per_unit, currency, usd_fx_rate,
                source_id
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9)
            ON CONFLICT (holding_id, source_id) WHERE source_id IS NOT NULL
            DO NOTHING
            "#,
        )
        .bind(holding_id)
        .bind(account_id)
        .bind(user_id)
        .bind(acquired_at)
        .bind(quantity.abs())
        .bind(price.abs())
        .bind(&currency)
        .bind(usd_fx_rate)
        .bind(source_id)
        .execute(db)
        .await?;
        return Ok(());
    }

    // sell: FIFO-deplete this holding's lots. Use a sell-marker
    // row keyed on source_id for idempotency, so re-runs skip.
    let marker_seen = sqlx::query(
        "SELECT 1 FROM holding_lots WHERE holding_id = $1 AND source_id = $2"
    )
    .bind(holding_id)
    .bind(source_id)
    .fetch_optional(db)
    .await?;
    if marker_seen.is_some() {
        return Ok(()); // Already processed this sell.
    }
    let mut remaining = quantity.abs();
    let sell_fx_rate = lookup_usd_fx_rate(db, &currency, acquired_at).await;
    let sell_price = price.abs();
    // Sell-side USD price-per-unit. For USD-denominated securities
    // the FX is 1.0 so this is a no-op; for MXN it's the price
    // divided by today's USD/MXN. Used to compute realized P&L per
    // lot below.
    let sell_usd_pps = if sell_fx_rate > 0.0 {
        sell_price / sell_fx_rate
    } else {
        sell_price
    };
    let lots = sqlx::query(
        r#"
        SELECT id, qty, cost_per_unit, currency, usd_fx_rate
        FROM holding_lots
        WHERE holding_id = $1 AND user_id = $2 AND qty > 0
        ORDER BY acquired_at ASC, id ASC
        "#,
    )
    .bind(holding_id)
    .bind(user_id)
    .fetch_all(db)
    .await?;
    for lot in lots {
        if remaining <= 0.0 { break; }
        let lot_id: uuid::Uuid = lot.get("id");
        let lot_qty: f64 = lot
            .try_get::<rust_decimal::Decimal, _>("qty")
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
            .unwrap_or(0.0);
        let lot_cpu: f64 = lot
            .try_get::<rust_decimal::Decimal, _>("cost_per_unit")
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
            .unwrap_or(0.0);
        // Currency from the lot is conceptually relevant but operationally
        // unused — `lot_fx` already encodes the conversion. Read it for
        // future per-currency logic; prefix _ silences unused warning.
        let _lot_ccy: String = lot.try_get("currency").unwrap_or_else(|_| "USD".to_string());
        let lot_fx: f64 = lot
            .try_get::<rust_decimal::Decimal, _>("usd_fx_rate")
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(1.0))
            .unwrap_or(1.0);
        let consume = remaining.min(lot_qty);
        let new_qty = lot_qty - consume;
        sqlx::query("UPDATE holding_lots SET qty = $1 WHERE id = $2")
            .bind(new_qty)
            .bind(lot_id)
            .execute(db)
            .await?;
        // Realized P&L per lot, in USD: (qty * sell_usd_pps) - (qty * cost_usd_pps).
        // The cost side uses the lot's historical FX rate; the sell
        // side uses today's. Matches the accounting convention where
        // the gain is "what you got minus what you paid", both
        // measured in USD at the time of each event.
        let cost_usd_pps = if lot_fx > 0.0 { lot_cpu / lot_fx } else { lot_cpu };
        let realized_pnl_usd = consume * (sell_usd_pps - cost_usd_pps);
        // Idempotent insert: re-running this sell with the same
        // (user_id, sell_source_id, lot_id) is a no-op. The
        // sell-marker check above already short-circuits the depletion
        // loop, but if THAT fails for some reason (DB hiccup mid-
        // sync), this clause guarantees no double-counting.
        let _ = sqlx::query(
            r#"
            INSERT INTO lot_disposals (
                user_id, holding_id, account_id, lot_id,
                sell_source_id, qty_sold, sell_price_per_unit,
                sell_currency, sell_fx_rate, sell_date,
                cost_per_unit, cost_fx_rate, realized_pnl_usd
            )
            VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
            ON CONFLICT (user_id, sell_source_id, lot_id) DO NOTHING
            "#,
        )
        .bind(user_id)
        .bind(holding_id)
        .bind(account_id)
        .bind(lot_id)
        .bind(source_id)
        .bind(consume)
        .bind(sell_price)
        .bind(&currency)
        .bind(sell_fx_rate)
        .bind(acquired_at)
        .bind(lot_cpu)
        .bind(lot_fx)
        .bind(realized_pnl_usd)
        .execute(db)
        .await;
        remaining -= consume;
    }
    // Drop the sell marker so a re-sync doesn't double-deplete.
    // qty = 0 makes the marker invisible to the cost-basis read
    // path; we tag it with the same currency / fx for completeness.
    // Reuse sell_fx_rate so we don't redo the lookup.
    let marker_fx = sell_fx_rate;
    sqlx::query(
        r#"
        INSERT INTO holding_lots (
            holding_id, account_id, user_id,
            acquired_at, qty, cost_per_unit, currency, usd_fx_rate,
            source_id
        )
        VALUES ($1, $2, $3, $4, 0, $5, $6, $7, $8)
        ON CONFLICT (holding_id, source_id) WHERE source_id IS NOT NULL
        DO NOTHING
        "#,
    )
    .bind(holding_id)
    .bind(account_id)
    .bind(user_id)
    .bind(acquired_at)
    .bind(price.abs())
    .bind(&currency)
    .bind(marker_fx)
    .bind(source_id)
    .execute(db)
    .await?;
    Ok(())
}

/// T6: persist a Plaid investment **cash-income** event (cash dividend or
/// brokerage interest) as a `transactions` row. Returns `Ok(true)` when the
/// event was recognized as cash income (whether or not a row was written —
/// e.g. unknown account), `Ok(false)` when it's not an income event and the
/// caller should continue with the lot pipeline.
///
/// Plaid vocabulary handled (see the enum notes in process_investment_event:
/// it's inconsistent over time, so we match the subtype words):
///   * type `cash`, subtype `dividend`  → `INCOME` / `INCOME_DIVIDENDS`
///   * type `cash`, subtype `interest`  → `INCOME` / `INCOME_INTEREST_EARNED`
///   * subtype `dividend reinvestment` / `reinvestment` → NOT income here;
///     reinvestments change shares and stay on the lot path.
///   * type `fee` (account/management fees, margin expense, …) → deliberately
///     ignored for now: fees are a possible future deduction/expense line,
///     not income. Revisit when brokerage-fee tracking lands.
///
/// The category strings are the exact PFC-detailed values the rest of the
/// app already understands (sync.rs stores them from /transactions/sync;
/// frontend/lib/utils/category.dart pretty-prints them), so these rows flow
/// through the tax income predicate, cash flow, and category UI unchanged.
///
/// Idempotency: `external_id` = Plaid's `investment_transaction_id` under
/// the existing `UNIQUE (account_id, external_id)` constraint — the same
/// dedup scheme `upsert_plaid_transaction` uses — so re-syncing the same
/// window upserts in place rather than duplicating rows.
///
/// Sign convention: Plaid's investments feed reports amounts positive when
/// cash LEAVES the account, and the app stores inflows as positive (see
/// `upsert_plaid_transaction`), so the amount is negated: a received
/// dividend (negative in Plaid) lands as a positive inflow, which is what
/// the tax income predicate (`amount > 0`) and cash-flow views expect. A
/// reversal/clawback keeps its sign and correctly shows as an outflow.
pub async fn upsert_investment_income_event(
    db: &PgPool,
    ev: &serde_json::Value,
    user_id: uuid::Uuid,
) -> Result<bool> {
    let tx_type = ev["type"].as_str().unwrap_or("");
    let subtype = ev["subtype"].as_str().unwrap_or("");

    // Reinvested dividends are share events, not cash income.
    if matches!(subtype, "dividend reinvestment" | "reinvestment") {
        return Ok(false);
    }
    // Fees are not income — skipped for now (see doc comment).
    if tx_type == "fee" {
        return Ok(false);
    }
    let category_detailed = match subtype {
        "dividend" => "INCOME_DIVIDENDS",
        "interest" => "INCOME_INTEREST_EARNED",
        // Tolerate older feeds that used a bare type with no subtype.
        "" if tx_type == "dividend" => "INCOME_DIVIDENDS",
        "" if tx_type == "interest" => "INCOME_INTEREST_EARNED",
        _ => return Ok(false),
    };

    let source_id = ev["investment_transaction_id"]
        .as_str()
        .ok_or_else(|| anyhow::anyhow!("missing investment_transaction_id"))?;
    let account_external_id = ev["account_id"].as_str().unwrap_or("");
    if account_external_id.is_empty() {
        return Ok(true); // recognized but unaddressable; nothing to write
    }
    let date_str = ev["date"].as_str().unwrap_or("");
    let date = chrono::NaiveDate::parse_from_str(date_str, "%Y-%m-%d")
        .map_err(|e| anyhow::anyhow!("bad date {}: {}", date_str, e))?;
    // Negate per the sign convention in the doc comment above.
    let amount = -ev["amount"].as_f64().unwrap_or(0.0);
    let currency = ev["iso_currency_code"]
        .as_str()
        .or_else(|| ev["unofficial_currency_code"].as_str())
        .unwrap_or("USD");
    let description = ev["name"].as_str().filter(|s| !s.trim().is_empty()).unwrap_or(
        if category_detailed == "INCOME_DIVIDENDS" { "Dividend" } else { "Interest" },
    );

    // Account lookup scoped by user — same cross-tenant guard as
    // upsert_plaid_transaction. Unknown account: skip silently (the next
    // accounts sync creates it; re-running this window then writes the row).
    let internal_acc =
        sqlx::query("SELECT id FROM accounts WHERE external_id = $1 AND user_id = $2")
            .bind(account_external_id)
            .bind(user_id)
            .fetch_optional(db)
            .await?;
    let Some(acc_row) = internal_acc else {
        return Ok(true);
    };
    let acc_id: uuid::Uuid = acc_row.get("id");

    sqlx::query(
        r#"
        INSERT INTO transactions (
            account_id, external_id, date, description, amount, currency,
            category, category_detailed, pending, source, user_id
        )
        VALUES ($1, $2, $3, $4, $5, $6, 'INCOME', $7, FALSE, 'plaid', $8)
        ON CONFLICT (account_id, external_id)
        DO UPDATE SET
            date = EXCLUDED.date,
            description = EXCLUDED.description,
            amount = EXCLUDED.amount,
            currency = EXCLUDED.currency,
            category = EXCLUDED.category,
            category_detailed = EXCLUDED.category_detailed
        "#,
    )
    .bind(acc_id)
    .bind(source_id)
    .bind(date)
    .bind(description)
    .bind(amount)
    .bind(currency)
    .bind(category_detailed)
    .bind(user_id)
    .execute(db)
    .await?;

    Ok(true)
}

/// Look up the USD/<security currency> conversion in effect on the
/// given date. Returns 1.0 for USD securities (no conversion needed).
/// For MXN securities we read the latest `exchange_rates` row dated
/// on or before `acquired_at`; if none exists (fresh deployment with
/// no FX history), fall back to the most recent rate (still better
/// than 1.0 — at least the magnitudes line up).
async fn lookup_usd_fx_rate(
    db: &PgPool,
    currency: &str,
    acquired_at: chrono::NaiveDate,
) -> f64 {
    if currency.eq_ignore_ascii_case("USD") {
        return 1.0;
    }
    if !currency.eq_ignore_ascii_case("MXN") {
        // Unknown currency. The caller will treat fx=1.0 as "trust
        // the native amount", which is at least directionally OK.
        return 1.0;
    }
    let row = sqlx::query(
        r#"
        SELECT rate FROM exchange_rates
        WHERE base_currency = 'USD' AND target_currency = 'MXN'
          AND recorded_at <= ($1::date + INTERVAL '1 day')
        ORDER BY recorded_at DESC LIMIT 1
        "#,
    )
    .bind(acquired_at)
    .fetch_optional(db)
    .await
    .ok()
    .flatten();
    if let Some(r) = row {
        if let Ok(d) = r.try_get::<rust_decimal::Decimal, _>("rate") {
            if let Ok(v) = d.to_string().parse::<f64>() {
                if v > 0.0 {
                    return v;
                }
            }
        }
    }
    // Fallback: most-recent rate of any kind.
    let r = sqlx::query(
        "SELECT rate FROM exchange_rates WHERE base_currency = 'USD' AND target_currency = 'MXN' ORDER BY recorded_at DESC LIMIT 1"
    )
    .fetch_optional(db)
    .await
    .ok()
    .flatten();
    r.and_then(|r| r.try_get::<rust_decimal::Decimal, _>("rate").ok())
        .and_then(|d| d.to_string().parse::<f64>().ok())
        .filter(|v| *v > 0.0)
        .unwrap_or(20.0) // hard fallback at the ballpark
}
