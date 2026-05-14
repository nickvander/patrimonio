use axum::{
    extract::State,
    routing::get,
    Json, Router,
};
use serde::Serialize;
use sqlx::Row;
use std::collections::{BTreeMap, HashMap};

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
}

/// Dashboard overview: net worth, account breakdown, recent changes
async fn dashboard_overview(State(state): State<AppState>) -> Json<DashboardOverview> {
    // Net worth by currency
    let currency_rows = sqlx::query(
        r#"
        SELECT currency,
               COALESCE(SUM(CASE WHEN account_type NOT IN ('credit') THEN current_balance ELSE 0 END), 0) as assets,
               COALESCE(SUM(CASE WHEN account_type = 'credit' THEN ABS(current_balance) ELSE 0 END), 0) as liabilities
        FROM accounts
        GROUP BY currency
        "#
    )
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

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

    // Get latest USD/MXN rate for conversion. Dashboard aggregate totals use USD
    // as their base so the frontend can report them in either USD or MXN.
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

    // Account type breakdown
    let type_rows = sqlx::query(
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
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

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

    // Institution breakdown
    let institution_rows = sqlx::query(
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
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

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

    // Individual Accounts
    let accounts_rows = sqlx::query(
        r#"
        SELECT a.id, a.name, a.nickname, a.account_type, a.current_balance, a.currency,
               i.name as institution_name, a.ticker_symbol, a.crypto_amount
        FROM accounts a
        JOIN institutions i ON a.institution_id = i.id
        ORDER BY a.account_type, a.name
        "#
    )
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

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

/// Recent transactions across all accounts
async fn recent_transactions(State(state): State<AppState>) -> Json<Vec<TransactionEntry>> {
    let rows = sqlx::query(
        r#"
        SELECT t.id, t.account_id,
               COALESCE(NULLIF(a.nickname, ''), a.name) as account_name,
               t.amount, t.currency,
               t.date, t.description, t.category, t.pending
        FROM transactions t
        JOIN accounts a ON t.account_id = a.id
        ORDER BY t.date DESC, t.created_at DESC
        LIMIT 50
        "#
    )
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
                    pending: r.get("pending"),
                }
            })
            .collect(),
    )
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
