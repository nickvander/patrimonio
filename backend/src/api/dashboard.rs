use axum::{
    extract::{Query, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use std::collections::{BTreeMap, HashMap};
use tracing::error;

use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/overview", get(dashboard_overview))
        .route("/net-worth-history", get(net_worth_history))
        .route("/holdings", get(holdings))
        .route("/allocation", get(asset_allocation))
        .route("/trends", get(cash_flow_trends))
        .route("/credit-utilization", get(credit_utilization))
        .route("/sync-status", get(sync_status))
        .route("/transactions", get(recent_transactions))
        .route("/transactions/export", get(export_transactions_csv))
        .route("/transactions/manual", axum::routing::post(create_manual_transaction))
}

/// Dashboard overview: net worth, account breakdown, recent changes
async fn dashboard_overview(State(state): State<AppState>) -> Json<DashboardOverview> {
    // Phase 1: three independent queries — currency totals, FX rate,
    // and per-account detail — go in parallel. Originally these were
    // four sequential awaits; the dashboard is the hottest read path
    // so the round-trip win is meaningful.
    let (currency_rows, fx_row, accounts_rows) = tokio::join!(
        sqlx::query(
            r#"
            SELECT currency,
                   COALESCE(SUM(CASE WHEN account_type NOT IN ('credit') THEN current_balance ELSE 0 END), 0) as assets,
                   COALESCE(SUM(CASE WHEN account_type = 'credit' THEN ABS(current_balance) ELSE 0 END), 0) as liabilities
            FROM accounts
            GROUP BY currency
            "#
        ).fetch_all(&state.db),
        sqlx::query(
            "SELECT rate FROM exchange_rates WHERE base_currency = 'USD' AND target_currency = 'MXN' ORDER BY recorded_at DESC LIMIT 1"
        ).fetch_optional(&state.db),
        sqlx::query(
            r#"
            SELECT a.id, a.name, a.nickname, a.account_type, a.current_balance, a.currency,
                   i.name as institution_name, a.ticker_symbol, a.crypto_amount
            FROM accounts a
            JOIN institutions i ON a.institution_id = i.id
            ORDER BY a.account_type, a.name
            "#
        ).fetch_all(&state.db),
    );
    let currency_rows = currency_rows.unwrap_or_default();
    let accounts_rows = accounts_rows.unwrap_or_default();

    let currency_breakdown: Vec<CurrencyBreakdown> = currency_rows.iter()
        .map(|r| {
            let assets: f64 = r.try_get::<rust_decimal::Decimal, _>("assets")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
            let liabilities: f64 = r.try_get::<rust_decimal::Decimal, _>("liabilities")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
            CurrencyBreakdown {
                currency: r.get("currency"),
                assets,
                liabilities,
                net: assets - liabilities,
            }
        })
        .collect();

    // FX rate is needed by both per-type and per-institution queries
    // below; pin its numeric value before phase 2.
    let fx_rate = fx_row
        .ok()
        .flatten()
        .map(|r| r.get::<rust_decimal::Decimal, _>("rate"))
        .and_then(|d| d.to_string().parse::<f64>().ok())
        .unwrap_or(20.0);

    // Phase 2: the two remaining aggregates depend on fx_rate but not
    // on each other — run them concurrently as well.
    let (type_rows, institution_rows) = tokio::join!(
        sqlx::query(
            r#"
            SELECT account_type,
                   COUNT(*) as count,
                   COALESCE(SUM(current_balance), 0) as total,
                   COALESCE(SUM(
                       CASE
                           WHEN currency = 'MXN' THEN current_balance / $1::numeric
                           ELSE current_balance
                       END
                   ), 0) as total_usd
            FROM accounts
            GROUP BY account_type
            "#
        )
        .bind(fx_rate)
        .fetch_all(&state.db),
        sqlx::query(
            r#"
            SELECT i.name as institution_name, i.country,
                   COUNT(*) as account_count,
                   COALESCE(SUM(a.current_balance), 0) as total,
                   COALESCE(SUM(
                       CASE
                           WHEN a.currency = 'MXN' THEN a.current_balance / $1::numeric
                           ELSE a.current_balance
                       END
                   ), 0) as total_usd
            FROM accounts a
            JOIN institutions i ON a.institution_id = i.id
            GROUP BY i.name, i.country
            ORDER BY total DESC
            "#
        )
        .bind(fx_rate)
        .fetch_all(&state.db),
    );
    let type_rows = type_rows.unwrap_or_default();
    let institution_rows = institution_rows.unwrap_or_default();

    let type_breakdown: Vec<TypeBreakdown> = type_rows.iter()
        .map(|r| TypeBreakdown {
            account_type: r.get("account_type"),
            count: r.try_get::<i64, _>("count").unwrap_or(0) as i32,
            total: r.try_get::<rust_decimal::Decimal, _>("total")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0),
            total_usd: r.try_get::<rust_decimal::Decimal, _>("total_usd")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0),
        })
        .collect();

    let institution_breakdown: Vec<InstitutionBreakdown> = institution_rows.iter()
        .map(|r| InstitutionBreakdown {
            name: r.get("institution_name"),
            country: r.get("country"),
            account_count: r.try_get::<i64, _>("account_count").unwrap_or(0) as i32,
            total: r.try_get::<rust_decimal::Decimal, _>("total")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0),
            total_usd: r.try_get::<rust_decimal::Decimal, _>("total_usd")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0),
        })
        .collect();

    let accounts: Vec<AccountDetail> = accounts_rows.iter()
        .map(|r| AccountDetail {
            id: r.get::<uuid::Uuid, _>("id").to_string(),
            name: r.get("name"),
            nickname: r.try_get::<Option<String>, _>("nickname").ok().flatten(),
            institution_name: r.get("institution_name"),
            account_type: r.get("account_type"),
            current_balance: r.try_get::<rust_decimal::Decimal, _>("current_balance")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0),
            currency: r.get("currency"),
            ticker_symbol: r.get("ticker_symbol"),
            crypto_amount: r.try_get::<rust_decimal::Decimal, _>("crypto_amount")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)),
        })
        .collect();

    // Calculate total net worth in USD by converting each currency balance
    let mut total_net_usd = 0.0;

    for c in &currency_breakdown {
        if c.currency == "USD" {
            total_net_usd += c.net;
        } else if c.currency == "MXN" {
            total_net_usd += c.net / fx_rate;
        } else {
            // Default 1:1 for other currencies for now
            total_net_usd += c.net;
        }
    }

    Json(DashboardOverview {
        net_worth: total_net_usd,
        currency_breakdown,
        type_breakdown,
        institution_breakdown,
        accounts,
    })
}

/// Historical net worth data for charting (aggregated from balance_snapshots),
/// broken down by institution so the frontend can render contribution lines.
async fn net_worth_history(State(state): State<AppState>) -> Json<Vec<NetWorthPoint>> {
    // Grouped per (date, institution) so each row carries that institution's
    // assets and liabilities on that date. Empty institution slots simply
    // don't appear and the chart treats them as zero/no-data.
    let rows = sqlx::query(
        r#"
        SELECT bs.as_of_date,
               i.name as institution_name,
               COALESCE(SUM(CASE WHEN a.account_type NOT IN ('credit') THEN bs.balance_usd ELSE 0 END), 0) as inst_assets_usd,
               COALESCE(SUM(CASE WHEN a.account_type = 'credit' THEN ABS(bs.balance_usd) ELSE 0 END), 0) as inst_liabilities_usd
        FROM balance_snapshots bs
        JOIN accounts a ON bs.account_id = a.id
        JOIN institutions i ON a.institution_id = i.id
        GROUP BY bs.as_of_date, i.name
        ORDER BY bs.as_of_date ASC, i.name ASC
        "#
    )
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let mut points: BTreeMap<chrono::NaiveDate, NetWorthPoint> = BTreeMap::new();

    for r in &rows {
        let date = match r.try_get::<chrono::NaiveDate, _>("as_of_date") {
            Ok(d) => d,
            Err(_) => continue,
        };
        let inst: String = r
            .try_get::<String, _>("institution_name")
            .unwrap_or_else(|_| "Unknown".to_string());
        let assets: f64 = r
            .try_get::<rust_decimal::Decimal, _>("inst_assets_usd")
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
            .unwrap_or(0.0);
        let liabilities: f64 = r
            .try_get::<rust_decimal::Decimal, _>("inst_liabilities_usd")
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
            .unwrap_or(0.0);
        let inst_net = assets - liabilities;

        let entry = points.entry(date).or_insert_with(|| NetWorthPoint {
            date: date.to_string(),
            total_assets: 0.0,
            total_liabilities: 0.0,
            net_worth: 0.0,
            by_institution: HashMap::new(),
        });
        entry.total_assets += assets;
        entry.total_liabilities += liabilities;
        entry.net_worth = entry.total_assets - entry.total_liabilities;
        // If an institution has multiple rows on the same date (e.g. ETL
        // duplication), sum rather than overwrite.
        *entry.by_institution.entry(inst).or_insert(0.0) += inst_net;
    }

    Json(points.into_values().collect())
}

/// All investment holdings across all accounts
async fn holdings(State(state): State<AppState>) -> Json<HoldingsResponse> {
    let rows = sqlx::query(
        r#"
        SELECT h.symbol, h.name, h.quantity, h.price, h.value,
               h.cost_basis, h.currency, h.holding_type,
               COALESCE(NULLIF(a.nickname, ''), a.name) as account_name,
               i.name as institution_name
        FROM holdings h
        JOIN accounts a ON h.account_id = a.id
        JOIN institutions i ON a.institution_id = i.id
        ORDER BY h.value DESC NULLS LAST
        "#
    )
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let holdings_list: Vec<HoldingDetail> = rows.iter()
        .map(|r| {
            let value: f64 = r.try_get::<rust_decimal::Decimal, _>("value")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
            let cost_basis: f64 = r.try_get::<rust_decimal::Decimal, _>("cost_basis")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
            HoldingDetail {
                symbol: r.get("symbol"),
                name: r.get("name"),
                quantity: r.try_get::<rust_decimal::Decimal, _>("quantity")
                    .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0),
                price: r.try_get::<rust_decimal::Decimal, _>("price")
                    .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0),
                value,
                cost_basis,
                gain_loss: value - cost_basis,
                gain_loss_pct: if cost_basis > 0.0 { ((value - cost_basis) / cost_basis) * 100.0 } else { 0.0 },
                currency: r.get("currency"),
                holding_type: r.try_get::<String, _>("holding_type").unwrap_or_default(),
                account_name: r.get("account_name"),
                institution_name: r.get("institution_name"),
            }
        })
        .collect();

    let total_value: f64 = holdings_list.iter().map(|h| h.value).sum();
    let total_cost: f64 = holdings_list.iter().map(|h| h.cost_basis).sum();

    Json(HoldingsResponse {
        total_value,
        total_cost_basis: total_cost,
        total_gain_loss: total_value - total_cost,
        total_gain_loss_pct: if total_cost > 0.0 { ((total_value - total_cost) / total_cost) * 100.0 } else { 0.0 },
        holdings: holdings_list,
    })
}

/// Credit card utilization for all credit accounts
async fn credit_utilization(State(state): State<AppState>) -> Json<Vec<CreditUtilization>> {
    let rows = sqlx::query(
        r#"
        SELECT a.name, a.current_balance, a.credit_limit,
               i.name as institution_name
        FROM accounts a
        JOIN institutions i ON a.institution_id = i.id
        WHERE a.account_type IN ('credit', 'credit card')
        ORDER BY i.name, a.name
        "#
    )
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| {
                let balance: f64 = r.try_get::<rust_decimal::Decimal, _>("current_balance")
                    .ok().map(|d| d.to_string().parse::<f64>().unwrap_or(0.0)).unwrap_or(0.0)
                    .abs();
                let limit: f64 = r.try_get::<rust_decimal::Decimal, _>("credit_limit")
                    .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
                CreditUtilization {
                    name: r.get("name"),
                    institution_name: r.get("institution_name"),
                    balance,
                    credit_limit: limit,
                    utilization_pct: if limit > 0.0 { (balance / limit) * 100.0 } else { 0.0 },
                }
            })
            .collect(),
    )
}

/// Sync status of all institutions
async fn sync_status(State(state): State<AppState>) -> Json<Vec<SyncStatusEntry>> {
    let rows = sqlx::query(
        r#"
        SELECT id, name, integration_type, sync_status, last_synced_at, country, last_sync_error
        FROM institutions
        ORDER BY name
        "#
    )
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| SyncStatusEntry {
                id: r.try_get::<uuid::Uuid, _>("id")
                    .map(|u| u.to_string())
                    .unwrap_or_default(),
                name: r.get("name"),
                integration_type: r.get("integration_type"),
                country: r.get("country"),
                sync_status: r.try_get::<String, _>("sync_status")
                    .unwrap_or_else(|_| "unknown".to_string()),
                last_synced_at: r.try_get::<chrono::DateTime<chrono::Utc>, _>("last_synced_at")
                    .ok().map(|d| d.to_rfc3339()),
                last_sync_error: r.try_get::<Option<String>, _>("last_sync_error")
                    .ok().flatten(),
            })
            .collect(),
    )
}

/// Recent transactions across all accounts. `limit` defaults to 50 and is
/// capped at 500 to keep one response cheap; `offset` lets the frontend
/// page through the rest with a 'Load more' button.
#[derive(Deserialize)]
struct TransactionsQuery {
    limit: Option<i64>,
    offset: Option<i64>,
}

async fn recent_transactions(
    State(state): State<AppState>,
    Query(q): Query<TransactionsQuery>,
) -> Json<Vec<TransactionEntry>> {
    let limit = q.limit.unwrap_or(50).clamp(1, 500);
    let offset = q.offset.unwrap_or(0).max(0);
    let rows = sqlx::query(
        r#"
        SELECT t.id, t.account_id,
               COALESCE(NULLIF(a.nickname, ''), a.name) as account_name,
               t.amount, t.currency,
               t.date, t.description, t.category, t.category_detailed,
               t.payment_channel, t.merchant_name,
               t.original_description, t.counterparty_name, t.counterparty_logo_url,
               t.pending
        FROM transactions t
        JOIN accounts a ON t.account_id = a.id
        ORDER BY t.date DESC, t.created_at DESC
        LIMIT $1 OFFSET $2
        "#
    )
    .bind(limit)
    .bind(offset)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| {
                let amount: f64 = r.try_get::<rust_decimal::Decimal, _>("amount")
                    .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
                TransactionEntry {
                    id: r.get::<uuid::Uuid, _>("id").to_string(),
                    account_id: r.get::<uuid::Uuid, _>("account_id").to_string(),
                    account_name: r.get("account_name"),
                    amount,
                    currency: r.get("currency"),
                    date: r.get::<chrono::NaiveDate, _>("date").to_string(),
                    description: r.get("description"),
                    category: r.get("category"),
                    category_detailed: r
                        .try_get::<Option<String>, _>("category_detailed")
                        .ok()
                        .flatten(),
                    payment_channel: r
                        .try_get::<Option<String>, _>("payment_channel")
                        .ok()
                        .flatten(),
                    merchant_name: r
                        .try_get::<Option<String>, _>("merchant_name")
                        .ok()
                        .flatten(),
                    original_description: r
                        .try_get::<Option<String>, _>("original_description")
                        .ok()
                        .flatten(),
                    counterparty_name: r
                        .try_get::<Option<String>, _>("counterparty_name")
                        .ok()
                        .flatten(),
                    counterparty_logo_url: r
                        .try_get::<Option<String>, _>("counterparty_logo_url")
                        .ok()
                        .flatten(),
                    pending: r.get("pending"),
                }
            })
            .collect(),
    )
}

/// CSV export of every transaction across all accounts. Streams the
/// whole table — useful for an annual tax-prep dump. We escape
/// quotes/commas by wrapping every text field in double quotes and
/// doubling any embedded double quote.
async fn export_transactions_csv(
    State(state): State<AppState>,
) -> Response {
    let rows = sqlx::query(
        r#"
        SELECT t.id, t.date, t.amount, t.currency, t.description,
               COALESCE(t.category, '') as category,
               COALESCE(t.category_detailed, '') as category_detailed,
               COALESCE(t.payment_channel, '') as payment_channel,
               COALESCE(t.merchant_name, '') as merchant_name,
               COALESCE(t.source, '') as source,
               t.pending,
               COALESCE(NULLIF(a.nickname, ''), a.name) as account_name,
               COALESCE(i.name, '') as institution_name
        FROM transactions t
        JOIN accounts a ON t.account_id = a.id
        JOIN institutions i ON a.institution_id = i.id
        ORDER BY t.date DESC, t.created_at DESC
        "#
    )
    .fetch_all(&state.db)
    .await;

    let rows = match rows {
        Ok(r) => r,
        Err(e) => {
            error!("Failed to query transactions for export: {}", e);
            return (StatusCode::INTERNAL_SERVER_ERROR, "export failed")
                .into_response();
        }
    };

    fn esc(s: &str) -> String {
        format!("\"{}\"", s.replace('"', "\"\""))
    }

    let mut body = String::with_capacity(rows.len() * 128 + 256);
    body.push_str(
        "id,date,account,institution,description,merchant,category,category_detailed,payment_channel,amount,currency,source,pending\n"
    );
    for r in rows {
        let id: uuid::Uuid = r.get("id");
        let date: chrono::NaiveDate = r.get("date");
        let amount: rust_decimal::Decimal = r.get("amount");
        let currency: String = r.get("currency");
        let description: String = r.get("description");
        let category: String = r.get("category");
        let category_detailed: String = r.get("category_detailed");
        let payment_channel: String = r.get("payment_channel");
        let merchant: String = r.get("merchant_name");
        let source: String = r.get("source");
        let pending: bool = r.get("pending");
        let account_name: String = r.get("account_name");
        let institution_name: String = r.get("institution_name");
        body.push_str(&format!(
            "{},{},{},{},{},{},{},{},{},{},{},{},{}\n",
            id,
            date,
            esc(&account_name),
            esc(&institution_name),
            esc(&description),
            esc(&merchant),
            esc(&category),
            esc(&category_detailed),
            esc(&payment_channel),
            amount,
            currency,
            esc(&source),
            pending,
        ));
    }

    let today = chrono::Local::now().format("%Y-%m-%d").to_string();
    let filename = format!("patrimonio-transactions-{}.csv", today);
    (
        StatusCode::OK,
        [
            (header::CONTENT_TYPE, "text/csv; charset=utf-8".to_string()),
            (
                header::CONTENT_DISPOSITION,
                format!("attachment; filename=\"{}\"", filename),
            ),
        ],
        body,
    )
        .into_response()
}

#[derive(Deserialize)]
struct CreateManualTransactionRequest {
    account_id: uuid::Uuid,
    date: chrono::NaiveDate,
    description: String,
    /// Positive numbers are outflows (expenses), negative are inflows.
    /// Same sign convention the rest of the app already uses for
    /// transactions, so the new row appears correctly in every view.
    amount: rust_decimal::Decimal,
    currency: String,
    #[serde(default)]
    category: Option<String>,
    #[serde(default)]
    notes: Option<String>,
}

/// Add a transaction the user typed in themselves (cash purchases,
/// gifts, anything Plaid never sees). Reuses the same row shape as
/// imported transactions; only the `source` field differentiates them.
async fn create_manual_transaction(
    State(state): State<AppState>,
    Json(payload): Json<CreateManualTransactionRequest>,
) -> Response {
    // Deterministic external_id so a duplicate manual entry (same date /
    // amount / description on the same account) collapses to one row
    // instead of stacking up if the user double-submits.
    let signature = format!(
        "manual:{}:{}:{}",
        payload.date,
        payload.amount,
        payload
            .description
            .to_lowercase()
            .chars()
            .take(50)
            .collect::<String>()
    );
    let result = sqlx::query(
        r#"
        INSERT INTO transactions
            (account_id, external_id, date, description, amount, currency, category, source, source_id)
        VALUES ($1, $2, $3, $4, $5, $6, $7, 'manual', 'manual_add')
        ON CONFLICT (account_id, external_id) DO NOTHING
        RETURNING id
        "#,
    )
    .bind(payload.account_id)
    .bind(&signature)
    .bind(payload.date)
    .bind(&payload.description)
    .bind(payload.amount)
    .bind(&payload.currency)
    .bind(&payload.category)
    .fetch_optional(&state.db)
    .await;
    match result {
        Ok(Some(row)) => {
            let id: uuid::Uuid = row.get("id");
            // If the user added notes, fold them through the same
            // user-override path the inline editor uses.
            if let Some(notes) = payload.notes.as_ref().filter(|n| !n.is_empty()) {
                let _ = sqlx::query(
                    "UPDATE transactions SET user_notes = $1 WHERE id = $2",
                )
                .bind(notes)
                .bind(id)
                .execute(&state.db)
                .await;
            }
            (StatusCode::CREATED, Json(serde_json::json!({"id": id.to_string()})))
                .into_response()
        }
        Ok(None) => {
            // Duplicate (same signature already in the table). Treat as
            // a no-op so the UI snackbar can say "already added".
            (StatusCode::CONFLICT, "duplicate manual transaction").into_response()
        }
        Err(e) => {
            error!("Failed to insert manual transaction: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, "insert failed").into_response()
        }
    }
}

/// Asset allocation by category and sub-category (account/holding)
async fn asset_allocation(State(state): State<AppState>) -> Json<Vec<AllocationEntry>> {
    let fx_rate = sqlx::query(
        "SELECT rate FROM exchange_rates WHERE base_currency = 'USD' AND target_currency = 'MXN' ORDER BY recorded_at DESC LIMIT 1"
    )
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten()
    .map(|r| r.get::<rust_decimal::Decimal, _>("rate"))
    .and_then(|d| d.to_string().parse::<f64>().ok())
    .unwrap_or(20.0);

    let rows = sqlx::query(
        r#"
        SELECT category, sub_category, SUM(value_usd) as value, SUM(qty) as quantity
        FROM (
            -- Holdings: prefer security name when the symbol looks like
            -- an opaque Plaid security_id (long, mixed-case — common for
            -- un-tickered Vanguard funds). Real tickers (<=8 chars,
            -- uppercase) keep displaying as the ticker.
            SELECT COALESCE(holding_type, 'Stocks/ETFs') as category,
                   CASE
                       WHEN symbol IS NULL THEN name
                       WHEN LENGTH(symbol) > 8 OR (symbol <> UPPER(symbol) AND LENGTH(symbol) > 4)
                            THEN COALESCE(NULLIF(name, ''), symbol)
                       ELSE symbol
                   END as sub_category,
                   CASE
                       WHEN currency = 'MXN' THEN value / $1::numeric
                       ELSE value
                   END as value_usd,
                   COALESCE(quantity, 0)::numeric as qty
            FROM holdings
            UNION ALL
            -- Cash accounts
            SELECT 'Cash' as category,
                   name as sub_category,
                   CASE
                       WHEN currency = 'MXN' THEN current_balance / $1::numeric
                       ELSE current_balance
                   END as value_usd,
                   0::numeric as qty
            FROM accounts
            WHERE account_type IN ('checking', 'savings', 'cash', 'cash management', 'cd', 'money market')
            UNION ALL
            -- Crypto accounts
            SELECT 'Crypto' as category,
                   name as sub_category,
                   CASE
                       WHEN currency = 'MXN' THEN current_balance / $1::numeric
                       ELSE current_balance
                   END as value_usd,
                   COALESCE(crypto_amount, 0)::numeric as qty
            FROM accounts
            WHERE account_type IN ('crypto')
        ) sub
        GROUP BY category, sub_category
        ORDER BY value DESC
        "#
    )
    .bind(fx_rate)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| {
                let value: f64 = r.try_get::<rust_decimal::Decimal, _>("value")
                    .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
                let quantity: f64 = r
                    .try_get::<rust_decimal::Decimal, _>("quantity")
                    .ok()
                    .map(|d| d.to_string().parse().unwrap_or(0.0))
                    .unwrap_or(0.0);
                AllocationEntry {
                    category: r.try_get::<String, _>("category").unwrap_or_else(|_| "Other".to_string()),
                    sub_category: r.try_get::<String, _>("sub_category").unwrap_or_else(|_| "Unknown".to_string()),
                    value,
                    quantity,
                }
            })
            .collect(),
    )
}

/// Monthly income and spending trends
async fn cash_flow_trends(State(state): State<AppState>) -> Json<Vec<CashFlowPoint>> {
    let rows = sqlx::query(
        r#"
        SELECT TO_CHAR(date, 'YYYY-MM') as month,
               SUM(CASE WHEN amount > 0 THEN amount ELSE 0 END) as income,
               SUM(CASE WHEN amount < 0 THEN ABS(amount) ELSE 0 END) as spending
        FROM transactions
        WHERE date >= CURRENT_DATE - INTERVAL '12 months'
        GROUP BY month
        ORDER BY month ASC
        "#
    )
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| {
                let income: f64 = r.try_get::<rust_decimal::Decimal, _>("income")
                    .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
                let spending: f64 = r.try_get::<rust_decimal::Decimal, _>("spending")
                    .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
                CashFlowPoint {
                    month: r.get("month"),
                    income,
                    spending,
                }
            })
            .collect(),
    )
}

#[derive(Serialize)]
struct DashboardOverview {
    net_worth: f64,
    currency_breakdown: Vec<CurrencyBreakdown>,
    type_breakdown: Vec<TypeBreakdown>,
    institution_breakdown: Vec<InstitutionBreakdown>,
    accounts: Vec<AccountDetail>,
}

#[derive(Serialize)]
struct AccountDetail {
    id: String,
    name: String,
    /// User-defined nickname that overrides the bank-supplied `name`
    /// in the UI. None when not set.
    #[serde(skip_serializing_if = "Option::is_none")]
    nickname: Option<String>,
    institution_name: String,
    account_type: String,
    current_balance: f64,
    currency: String,
    ticker_symbol: Option<String>,
    crypto_amount: Option<f64>,
}

#[derive(Serialize)]
struct CurrencyBreakdown {
    currency: String,
    assets: f64,
    liabilities: f64,
    net: f64,
}

#[derive(Serialize)]
struct TypeBreakdown {
    account_type: String,
    count: i32,
    total: f64,
    total_usd: f64,
}

#[derive(Serialize)]
struct InstitutionBreakdown {
    name: String,
    country: String,
    account_count: i32,
    total: f64,
    total_usd: f64,
}

#[derive(Serialize)]
struct NetWorthPoint {
    date: String,
    total_assets: f64,
    total_liabilities: f64,
    net_worth: f64,
    /// Per-institution net contribution (assets - liabilities) for this date.
    by_institution: HashMap<String, f64>,
}

#[derive(Serialize)]
struct HoldingsResponse {
    total_value: f64,
    total_cost_basis: f64,
    total_gain_loss: f64,
    total_gain_loss_pct: f64,
    holdings: Vec<HoldingDetail>,
}

#[derive(Serialize)]
struct HoldingDetail {
    symbol: String,
    name: String,
    quantity: f64,
    price: f64,
    value: f64,
    cost_basis: f64,
    gain_loss: f64,
    gain_loss_pct: f64,
    currency: String,
    holding_type: String,
    account_name: String,
    institution_name: String,
}

#[derive(Serialize)]
struct CreditUtilization {
    name: String,
    institution_name: String,
    balance: f64,
    credit_limit: f64,
    utilization_pct: f64,
}

#[derive(Serialize)]
struct SyncStatusEntry {
    id: String,
    name: String,
    integration_type: String,
    country: String,
    sync_status: String,
    last_synced_at: Option<String>,
    last_sync_error: Option<String>,
}

#[derive(Serialize)]
struct TransactionEntry {
    id: String,
    account_id: String,
    account_name: String,
    amount: f64,
    currency: String,
    date: String,
    description: String,
    category: Option<String>,
    /// Plaid's `personal_finance_category.detailed` — much more specific
    /// than `category` (e.g. "LOAN_PAYMENTS_CREDIT_CARD_PAYMENT" vs
    /// just "LOAN_PAYMENTS"). The frontend prefers this when set.
    #[serde(skip_serializing_if = "Option::is_none")]
    category_detailed: Option<String>,
    /// "online" / "in_store" / "other" / "bank" — surfaced as a small
    /// chip alongside the category in the detail panel.
    #[serde(skip_serializing_if = "Option::is_none")]
    payment_channel: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    merchant_name: Option<String>,
    /// Raw bank line — survives when Plaid's cleaned `description`
    /// falls back to "Miscellaneous Debit" or similar generic label.
    #[serde(skip_serializing_if = "Option::is_none")]
    original_description: Option<String>,
    /// Best counterparty from Plaid's enriched `counterparties[]` array.
    /// Preferred over `merchant_name` and `description` for display.
    #[serde(skip_serializing_if = "Option::is_none")]
    counterparty_name: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    counterparty_logo_url: Option<String>,
    pending: bool,
}

#[derive(Serialize)]
struct AllocationEntry {
    category: String,
    sub_category: String,
    value: f64,
    /// Total share count for holdings (0 for cash and crypto-by-value rows).
    quantity: f64,
}

#[derive(Serialize)]
struct CashFlowPoint {
    month: String,
    income: f64,
    spending: f64,
}
