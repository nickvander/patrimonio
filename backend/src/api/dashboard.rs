use axum::{
    extract::{Extension, Query, State},
    http::{header, StatusCode},
    response::{IntoResponse, Response},
    routing::get,
    Json, Router,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use std::collections::HashMap;
use tracing::error;

use crate::api::session::AuthContext;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/overview", get(dashboard_overview))
        .route("/net-worth-history", get(net_worth_history))
        .route("/holdings", get(holdings))
        .route("/allocation", get(asset_allocation))
        .route("/trends", get(cash_flow_trends))
        .route("/spending-by-category", get(spending_by_category))
        .route("/spending-insights", get(spending_insights))
        .route("/realized-gains", get(realized_gains))
        .route("/account-balance-history", get(account_balance_history))
        .route("/emergency-fund", get(emergency_fund))
        .route("/benchmark", get(benchmark_series))
        .route("/benchmark-comparison", get(benchmark_comparison))
        .route("/credit-utilization", get(credit_utilization))
        .route("/sync-status", get(sync_status))
        .route("/transactions", get(recent_transactions))
        .route("/transactions/export", get(export_transactions_csv))
        .route("/transactions/manual", axum::routing::post(create_manual_transaction))
        .route("/since-last-login", get(since_last_login))
        .route("/subscriptions", get(detected_subscriptions))
        .route(
            "/subscriptions/ignored",
            get(list_ignored_subscriptions),
        )
        .route("/subscriptions/ignore", axum::routing::post(ignore_subscription))
        .route(
            "/subscriptions/ignored/{merchant_key}",
            axum::routing::delete(unignore_subscription),
        )
        .route("/fx-transfers", get(list_fx_transfers).post(detect_fx_transfers))
        // Static "dismissed" segments mounted BEFORE the dynamic
        // /{id} route so axum's matcher prefers them — otherwise
        // /fx-transfers/dismissed could be parsed as id="dismissed"
        // and 400 on the UUID extractor.
        .route("/fx-transfers/dismissed", get(list_dismissed_fx_pairs))
        .route(
            "/fx-transfers/dismissed/{id}",
            axum::routing::delete(restore_dismissed_fx_pair),
        )
        .route(
            "/fx-transfers/{id}",
            axum::routing::delete(unlink_fx_transfer)
                .patch(confirm_fx_transfer),
        )
}

/// Dashboard overview: net worth, account breakdown, recent changes —
/// scoped to the authenticated user. Every aggregate filters on
/// `user_id` so a brand-new account from another tenant can never
/// contribute to this user's totals.
async fn dashboard_overview(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<DashboardOverview> {
    // Phase 1: three independent queries — currency totals, FX rate,
    // and per-account detail — go in parallel. The FX rate is the
    // only global query (exchange rates aren't per-user).
    let (currency_rows, fx_row, accounts_rows) = tokio::join!(
        sqlx::query(
            r#"
            SELECT currency,
                   COALESCE(SUM(CASE WHEN NOT is_liability_account_type(account_type)
                                     THEN current_balance ELSE 0 END), 0) as assets,
                   COALESCE(SUM(CASE WHEN is_liability_account_type(account_type)
                                     THEN ABS(current_balance) ELSE 0 END), 0) as liabilities
            FROM accounts
            WHERE user_id = $1
            GROUP BY currency
            "#
        ).bind(ctx.user_id).fetch_all(&state.db),
        sqlx::query(
            "SELECT rate FROM exchange_rates WHERE base_currency = 'USD' AND target_currency = 'MXN' ORDER BY recorded_at DESC LIMIT 1"
        ).fetch_optional(&state.db),
        sqlx::query(
            r#"
            SELECT a.id, a.name, a.nickname, a.account_type, a.current_balance, a.currency,
                   i.name as institution_name, a.ticker_symbol, a.crypto_amount
            FROM accounts a
            JOIN institutions i ON a.institution_id = i.id
            WHERE a.user_id = $1
            ORDER BY a.account_type, a.name
            "#
        ).bind(ctx.user_id).fetch_all(&state.db),
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
    // on each other — run them concurrently as well. Both filtered to
    // the caller's accounts.
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
            WHERE user_id = $2
            GROUP BY account_type
            "#
        )
        .bind(fx_rate)
        .bind(ctx.user_id)
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
            WHERE a.user_id = $2
            GROUP BY i.name, i.country
            ORDER BY total DESC
            "#
        )
        .bind(fx_rate)
        .bind(ctx.user_id)
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
///
/// The work is done entirely in SQL: a CTE computes per-(date, institution)
/// assets/liabilities, then the outer SELECT collapses to one row per date
/// with `jsonb_object_agg` rolling up the per-institution map. This used to
/// be a Rust BTreeMap walk over O(dates × institutions) rows — fine at
/// laptop scale but quadratic enough that a power user with a year of
/// history and a dozen institutions would feel it on cold cache. Postgres
/// does the same work in one pass, returning ~30-90 rows for a typical
/// window instead of the dense matrix.
async fn net_worth_history(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<NetWorthPoint>> {
    // `COALESCE(name, 'Unknown')` matches the previous Rust fallback for
    // the rare case where institutions.name is somehow blank (the column
    // is NOT NULL today but a defensive default keeps the public JSON
    // contract stable).
    let rows = sqlx::query(
        r#"
        WITH per_inst AS (
            SELECT bs.as_of_date,
                   COALESCE(NULLIF(i.name, ''), 'Unknown') AS institution_name,
                   COALESCE(SUM(CASE WHEN NOT is_liability_account_type(a.account_type)
                                      THEN bs.balance_usd ELSE 0 END), 0) AS inst_assets_usd,
                   COALESCE(SUM(CASE WHEN is_liability_account_type(a.account_type)
                                      THEN ABS(bs.balance_usd) ELSE 0 END), 0) AS inst_liabilities_usd
            FROM balance_snapshots bs
            JOIN accounts a ON bs.account_id = a.id
            JOIN institutions i ON a.institution_id = i.id
            WHERE bs.user_id = $1
            GROUP BY bs.as_of_date, COALESCE(NULLIF(i.name, ''), 'Unknown')
        )
        SELECT as_of_date,
               COALESCE(SUM(inst_assets_usd), 0)::float8                    AS total_assets,
               COALESCE(SUM(inst_liabilities_usd), 0)::float8               AS total_liabilities,
               COALESCE(SUM(inst_assets_usd) - SUM(inst_liabilities_usd), 0)::float8
                                                                            AS net_worth,
               jsonb_object_agg(
                   institution_name,
                   (inst_assets_usd - inst_liabilities_usd)::float8
               )                                                             AS by_institution
        FROM per_inst
        GROUP BY as_of_date
        ORDER BY as_of_date ASC
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.into_iter()
            .filter_map(|r| {
                let date: chrono::NaiveDate = r.try_get("as_of_date").ok()?;
                let total_assets: f64 = r.try_get("total_assets").unwrap_or(0.0);
                let total_liabilities: f64 = r.try_get("total_liabilities").unwrap_or(0.0);
                let net_worth: f64 = r.try_get("net_worth").unwrap_or(0.0);
                // `by_institution` is a jsonb object {institution -> f64}.
                // Read as serde_json::Value, then convert to HashMap so
                // the response shape exactly matches what the BTreeMap-
                // based code used to emit. A malformed payload (shouldn't
                // happen) degrades to an empty map rather than failing
                // the whole request.
                let by_institution: HashMap<String, f64> = r
                    .try_get::<serde_json::Value, _>("by_institution")
                    .ok()
                    .and_then(|v| v.as_object().cloned())
                    .map(|m| {
                        m.into_iter()
                            .filter_map(|(k, v)| v.as_f64().map(|f| (k, f)))
                            .collect()
                    })
                    .unwrap_or_default();
                Some(NetWorthPoint {
                    date: date.to_string(),
                    total_assets,
                    total_liabilities,
                    net_worth,
                    by_institution,
                })
            })
            .collect(),
    )
}

/// All investment holdings for this user across their accounts.
///
/// Each holding is reported in BOTH USD and MXN so a bi-national
/// investor can read their position either way without converting in
/// their head. When `holding_lots` rows exist for a holding, the cost
/// basis is computed by summing each lot's `qty * cost_per_unit`
/// converted at that lot's own `usd_fx_rate` — this is the proper
/// FX-aware basis. When no lots exist (today's default — the lot
/// table is forward-compat infrastructure; `services/sync.rs` doesn't
/// populate it yet) we fall back to `holdings.cost_basis` converted
/// at the current FX rate, which still produces the right number in
/// the native currency and a reasonable approximation in the other.
async fn holdings(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<HoldingsResponse> {
    let fx_row = sqlx::query(
        "SELECT rate FROM exchange_rates WHERE base_currency = 'USD' AND target_currency = 'MXN' ORDER BY recorded_at DESC LIMIT 1"
    )
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten();
    let fx_usd_to_mxn: f64 = fx_row
        .map(|r| r.get::<rust_decimal::Decimal, _>("rate"))
        .and_then(|d| d.to_string().parse::<f64>().ok())
        .unwrap_or(20.0);

    let rows = sqlx::query(
        r#"
        SELECT h.id, h.symbol, h.name, h.quantity, h.price, h.value,
               h.cost_basis, h.currency, h.holding_type,
               COALESCE(NULLIF(a.nickname, ''), a.name) as account_name,
               i.name as institution_name
        FROM holdings h
        JOIN accounts a ON h.account_id = a.id
        JOIN institutions i ON a.institution_id = i.id
        WHERE h.user_id = $1
        ORDER BY h.value DESC NULLS LAST
        "#
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    // Pull any lots for this user in one query, group by holding.
    // Filter zero-qty rows here — those are FIFO-depletion markers
    // (one per sell event) inserted to make re-syncs idempotent.
    // They have no owned shares, so they shouldn't appear in the
    // breakdown or contribute to cost basis.
    let lot_rows = sqlx::query(
        r#"
        SELECT holding_id, qty, cost_per_unit, currency, usd_fx_rate,
               acquired_at
        FROM holding_lots
        WHERE user_id = $1 AND qty > 0
        ORDER BY acquired_at ASC, id ASC
        "#
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    // Two parallel maps: one for the cost-basis computation (the
    // tuple form was already in use downstream), one for the
    // serialised lot breakdown surfaced to the frontend.
    let mut lots_by_holding: HashMap<uuid::Uuid, Vec<(f64, f64, String, f64)>> =
        HashMap::new();
    let mut lot_details_by_holding: HashMap<uuid::Uuid, Vec<HoldingLot>> = HashMap::new();
    for r in &lot_rows {
        let hid: uuid::Uuid = match r.try_get("holding_id") { Ok(v) => v, Err(_) => continue };
        let qty: f64 = r.try_get::<rust_decimal::Decimal, _>("qty").ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
        let cpu: f64 = r.try_get::<rust_decimal::Decimal, _>("cost_per_unit").ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
        let ccy: String = r.try_get("currency").unwrap_or_else(|_| "USD".to_string());
        let fx: f64 = r.try_get::<rust_decimal::Decimal, _>("usd_fx_rate").ok()
            .map(|d| d.to_string().parse().unwrap_or(1.0)).unwrap_or(1.0);
        let acquired_at: String = r
            .try_get::<chrono::NaiveDate, _>("acquired_at")
            .map(|d| d.to_string())
            .unwrap_or_default();
        lots_by_holding
            .entry(hid)
            .or_default()
            .push((qty, cpu, ccy.clone(), fx));
        let native_cost = qty * cpu;
        let usd_cost = match ccy.as_str() {
            "USD" => native_cost,
            "MXN" => if fx > 0.0 { native_cost / fx } else { native_cost },
            _ => native_cost,
        };
        lot_details_by_holding.entry(hid).or_default().push(HoldingLot {
            acquired_at,
            qty,
            cost_per_unit: cpu,
            currency: ccy,
            usd_fx_rate: fx,
            native_cost,
            usd_cost,
        });
    }

    let to_usd = |amount: f64, ccy: &str| -> f64 {
        match ccy {
            "USD" => amount,
            "MXN" => amount / fx_usd_to_mxn,
            _ => amount, // unknown currency — treat as 1:1 to USD for now
        }
    };

    let holdings_list: Vec<HoldingDetail> = rows.iter()
        .map(|r| {
            let id: uuid::Uuid = r.try_get("id").unwrap_or_else(|_| uuid::Uuid::nil());
            let value: f64 = r.try_get::<rust_decimal::Decimal, _>("value")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
            let cost_basis_native: f64 = r.try_get::<rust_decimal::Decimal, _>("cost_basis")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
            let currency: String = r.get("currency");

            // Cost basis in USD: prefer lots (FX-aware) when present;
            // fall back to current-FX conversion of the flat basis.
            let cost_basis_usd = if let Some(lots) = lots_by_holding.get(&id) {
                lots.iter()
                    .map(|(qty, cpu, ccy, fx)| {
                        let native = qty * cpu;
                        // Lot's currency may differ from holding's
                        // currency in edge cases (multi-currency
                        // brokerages); convert via the lot's recorded
                        // historical FX rate.
                        match ccy.as_str() {
                            "USD" => native,
                            "MXN" => if *fx > 0.0 { native / fx } else { native / fx_usd_to_mxn },
                            _ => native,
                        }
                    })
                    .sum::<f64>()
            } else {
                to_usd(cost_basis_native, &currency)
            };

            let value_usd = to_usd(value, &currency);
            let cost_basis_mxn = cost_basis_usd * fx_usd_to_mxn;
            let value_mxn = value_usd * fx_usd_to_mxn;

            HoldingDetail {
                symbol: r.get("symbol"),
                name: r.get("name"),
                quantity: r.try_get::<rust_decimal::Decimal, _>("quantity")
                    .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0),
                price: r.try_get::<rust_decimal::Decimal, _>("price")
                    .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0),
                value,
                cost_basis: cost_basis_native,
                gain_loss: value - cost_basis_native,
                gain_loss_pct: if cost_basis_native > 0.0 {
                    ((value - cost_basis_native) / cost_basis_native) * 100.0
                } else { 0.0 },
                value_usd,
                value_mxn,
                cost_basis_usd,
                cost_basis_mxn,
                gain_loss_usd: value_usd - cost_basis_usd,
                gain_loss_mxn: value_mxn - cost_basis_mxn,
                currency,
                holding_type: r.try_get::<String, _>("holding_type").unwrap_or_default(),
                account_name: r.get("account_name"),
                institution_name: r.get("institution_name"),
                lots: lot_details_by_holding.remove(&id).unwrap_or_default(),
            }
        })
        .collect();

    let total_value: f64 = holdings_list.iter().map(|h| h.value).sum();
    let total_cost: f64 = holdings_list.iter().map(|h| h.cost_basis).sum();
    let total_value_usd: f64 = holdings_list.iter().map(|h| h.value_usd).sum();
    let total_value_mxn: f64 = holdings_list.iter().map(|h| h.value_mxn).sum();
    let total_cost_usd: f64 = holdings_list.iter().map(|h| h.cost_basis_usd).sum();
    let total_cost_mxn: f64 = holdings_list.iter().map(|h| h.cost_basis_mxn).sum();

    Json(HoldingsResponse {
        total_value,
        total_cost_basis: total_cost,
        total_gain_loss: total_value - total_cost,
        total_gain_loss_pct: if total_cost > 0.0 { ((total_value - total_cost) / total_cost) * 100.0 } else { 0.0 },
        total_value_usd,
        total_value_mxn,
        total_cost_basis_usd: total_cost_usd,
        total_cost_basis_mxn: total_cost_mxn,
        total_gain_loss_usd: total_value_usd - total_cost_usd,
        total_gain_loss_mxn: total_value_mxn - total_cost_mxn,
        holdings: holdings_list,
    })
}

/// Credit card utilization for this user's credit accounts.
async fn credit_utilization(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<CreditUtilization>> {
    let rows = sqlx::query(
        r#"
        SELECT a.name, a.current_balance, a.credit_limit,
               i.name as institution_name
        FROM accounts a
        JOIN institutions i ON a.institution_id = i.id
        WHERE a.account_type IN ('credit', 'credit card') AND a.user_id = $1
        ORDER BY i.name, a.name
        "#
    )
    .bind(ctx.user_id)
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

/// Sync status of this user's institutions.
async fn sync_status(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<SyncStatusEntry>> {
    let rows = sqlx::query(
        r#"
        SELECT id, name, integration_type, sync_status, last_synced_at, country, last_sync_error
        FROM institutions
        WHERE user_id = $1
        ORDER BY name
        "#
    )
    .bind(ctx.user_id)
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
    Extension(ctx): Extension<AuthContext>,
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
               t.user_description, t.payment_payee, t.payment_payer,
               t.parent_id,
               t.pending
        FROM transactions t
        JOIN accounts a ON t.account_id = a.id
        WHERE t.user_id = $1
          AND NOT EXISTS (SELECT 1 FROM transactions tc WHERE tc.parent_id = t.id)
        ORDER BY t.date DESC, t.created_at DESC
        LIMIT $2 OFFSET $3
        "#
    )
    .bind(ctx.user_id)
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
                    user_description: r
                        .try_get::<Option<String>, _>("user_description")
                        .ok()
                        .flatten(),
                    payment_payee: r
                        .try_get::<Option<String>, _>("payment_payee")
                        .ok()
                        .flatten(),
                    payment_payer: r
                        .try_get::<Option<String>, _>("payment_payer")
                        .ok()
                        .flatten(),
                    parent_id: r
                        .try_get::<Option<uuid::Uuid>, _>("parent_id")
                        .ok()
                        .flatten()
                        .map(|u| u.to_string()),
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
/// Streams the user's transactions as CSV. Both ends of the pipe
/// are streaming:
///   * The DB query uses `.fetch(...)` (not `.fetch_all`) so sqlx
///     hands us rows one at a time instead of buffering the whole
///     result set in memory.
///   * The response body is an `mpsc::channel` wrapped in a
///     `ReceiverStream` and handed to `axum::body::Body::from_stream`,
///     so each row's bytes leave the server the moment they're
///     formatted — no `String` buffer holding the entire CSV.
///
/// Net effect: a 50k-row export now fits in O(channel_buffer * row_size)
/// memory instead of O(row_count * row_size × ~5 with CSV overhead).
/// Audit P4.
async fn export_transactions_csv(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Response {
    use bytes::Bytes;
    use futures_util::StreamExt;

    let today = chrono::Local::now().format("%Y-%m-%d").to_string();
    let filename = format!("patrimonio-transactions-{}.csv", today);

    // The channel-buffer of 16 lets the writer get ahead of the
    // socket without holding the whole CSV in RAM. Bigger is
    // faster on a fast link, but 16 chunks × ~256 bytes/row is a
    // ~4 KB ceiling — already plenty for a TCP send buffer to
    // drain into.
    let (tx, rx) = tokio::sync::mpsc::channel::<Result<Bytes, std::io::Error>>(16);
    let db = state.db.clone();
    let user_id = ctx.user_id;

    tokio::spawn(async move {
        fn esc(s: &str) -> String {
            format!("\"{}\"", s.replace('"', "\"\""))
        }

        // Header row first. A send failure here means the client
        // already disconnected — abort cleanly without spending DB
        // work on a request nobody is reading.
        if tx
            .send(Ok(Bytes::from_static(
                b"id,date,account,institution,description,merchant,category,category_detailed,payment_channel,amount,currency,source,pending\n",
            )))
            .await
            .is_err()
        {
            return;
        }

        let mut stream = sqlx::query(
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
            WHERE t.user_id = $1
              AND NOT EXISTS (SELECT 1 FROM transactions tc WHERE tc.parent_id = t.id)
            ORDER BY t.date DESC, t.created_at DESC
            "#,
        )
        .bind(user_id)
        .fetch(&db);

        while let Some(row_result) = stream.next().await {
            let row = match row_result {
                Ok(r) => r,
                Err(e) => {
                    error!("export_transactions_csv stream error: {}", e);
                    // Surface the failure to the client as an io
                    // error — axum will close the body with an
                    // error frame and downstream tools (curl, the
                    // browser download) will report the truncation
                    // instead of silently shipping a half CSV.
                    let _ = tx
                        .send(Err(std::io::Error::other(format!(
                            "csv stream: {}",
                            e
                        ))))
                        .await;
                    return;
                }
            };
            let id: uuid::Uuid = row.get("id");
            let date: chrono::NaiveDate = row.get("date");
            let amount: rust_decimal::Decimal = row.get("amount");
            let currency: String = row.get("currency");
            let description: String = row.get("description");
            let category: String = row.get("category");
            let category_detailed: String = row.get("category_detailed");
            let payment_channel: String = row.get("payment_channel");
            let merchant: String = row.get("merchant_name");
            let source: String = row.get("source");
            let pending: bool = row.get("pending");
            let account_name: String = row.get("account_name");
            let institution_name: String = row.get("institution_name");
            let line = format!(
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
            );
            if tx.send(Ok(Bytes::from(line))).await.is_err() {
                // Client dropped. Stop the loop so we don't keep
                // pulling rows that will never ship.
                return;
            }
        }
    });

    let body = axum::body::Body::from_stream(
        tokio_stream::wrappers::ReceiverStream::new(rx),
    );

    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "text/csv; charset=utf-8")
        .header(
            header::CONTENT_DISPOSITION,
            format!("attachment; filename=\"{}\"", filename),
        )
        .body(body)
        .unwrap()
}

#[derive(Deserialize)]
struct CreateManualTransactionRequest {
    account_id: uuid::Uuid,
    date: chrono::NaiveDate,
    description: String,
    /// Negative numbers are outflows (expenses), positive are inflows
    /// (income). Matches the Plaid sync path in
    /// `services/sync.rs`, which negates Plaid's outflow-positive
    /// amounts on import, and `cash_flow_trends` which sums
    /// `amount > 0` as income.
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
    Extension(ctx): Extension<AuthContext>,
    Json(payload): Json<CreateManualTransactionRequest>,
) -> Response {
    // Verify the target account belongs to this caller before
    // creating a transaction against it — otherwise an attacker
    // could plant rows on a victim's account.
    let owns = sqlx::query("SELECT 1 FROM accounts WHERE id = $1 AND user_id = $2")
        .bind(payload.account_id)
        .bind(ctx.user_id)
        .fetch_optional(&state.db)
        .await;
    if !matches!(owns, Ok(Some(_))) {
        return StatusCode::NOT_FOUND.into_response();
    }

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
            (account_id, external_id, date, description, amount, currency, category, source, source_id, user_id)
        VALUES ($1, $2, $3, $4, $5, $6, $7, 'manual', 'manual_add', $8)
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
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await;
    match result {
        Ok(Some(row)) => {
            let id: uuid::Uuid = row.get("id");
            if let Some(notes) = payload.notes.as_ref().filter(|n| !n.is_empty()) {
                let _ = sqlx::query(
                    "UPDATE transactions SET user_notes = $1 WHERE id = $2 AND user_id = $3",
                )
                .bind(notes)
                .bind(id)
                .bind(ctx.user_id)
                .execute(&state.db)
                .await;
            }
            state
                .realtime
                .publish(
                    ctx.user_id,
                    crate::services::realtime::RealtimeEvent::TransactionsChanged,
                )
                .await;
            (StatusCode::CREATED, Json(serde_json::json!({"id": id.to_string()})))
                .into_response()
        }
        Ok(None) => {
            (StatusCode::CONFLICT, "duplicate manual transaction").into_response()
        }
        Err(e) => {
            error!("Failed to insert manual transaction: {}", e);
            (StatusCode::INTERNAL_SERVER_ERROR, "insert failed").into_response()
        }
    }
}

/// Asset allocation by category and sub-category, scoped to caller.
async fn asset_allocation(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<AllocationEntry>> {
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
            WHERE user_id = $2
            UNION ALL
            SELECT 'Cash' as category,
                   name as sub_category,
                   CASE
                       WHEN currency = 'MXN' THEN current_balance / $1::numeric
                       ELSE current_balance
                   END as value_usd,
                   0::numeric as qty
            FROM accounts
            WHERE account_type IN ('checking', 'savings', 'cash', 'cash management', 'cd', 'money market')
              AND user_id = $2
            UNION ALL
            SELECT 'Crypto' as category,
                   name as sub_category,
                   CASE
                       WHEN currency = 'MXN' THEN current_balance / $1::numeric
                       ELSE current_balance
                   END as value_usd,
                   COALESCE(crypto_amount, 0)::numeric as qty
            FROM accounts
            WHERE account_type IN ('crypto')
              AND user_id = $2
        ) sub
        GROUP BY category, sub_category
        ORDER BY value DESC
        "#
    )
    .bind(fx_rate)
    .bind(ctx.user_id)
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

/// Monthly income and spending trends for this user.
async fn cash_flow_trends(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<CashFlowPoint>> {
    let rows = sqlx::query(
        r#"
        WITH latest_fx AS (
            SELECT rate
            FROM exchange_rates
            WHERE base_currency = 'USD' AND target_currency = 'MXN'
            ORDER BY recorded_at DESC
            LIMIT 1
        )
        SELECT TO_CHAR(t.date, 'YYYY-MM') as month,
               -- Convert every amount to USD before summing.
               -- Without this, a MX$20,000 paycheck would be counted
               -- as 20,000 alongside USD amounts, making the income
               -- and spending bars look 15-20x too large for users
               -- with MXN accounts. Fallback rate 20.0 matches the
               -- convention used throughout the dashboard.
               SUM(CASE WHEN t.amount > 0 THEN
                       CASE WHEN a.currency = 'MXN'
                            THEN t.amount / COALESCE((SELECT rate FROM latest_fx), 20.0)
                            ELSE t.amount END
                   ELSE 0 END) as income,
               SUM(CASE WHEN t.amount < 0 THEN
                       CASE WHEN a.currency = 'MXN'
                            THEN ABS(t.amount) / COALESCE((SELECT rate FROM latest_fx), 20.0)
                            ELSE ABS(t.amount) END
                   ELSE 0 END) as spending
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        WHERE t.date >= CURRENT_DATE - INTERVAL '12 months'
          AND t.user_id = $1
          AND NOT EXISTS (SELECT 1 FROM transactions tc WHERE tc.parent_id = t.id)
          -- Exclude internal-transfer noise from the cash-flow view:
          --
          --   TRANSFER_IN_*  / TRANSFER_OUT_* (PFC) — money moving
          --     between the user's own accounts. Counting these as
          --     income or spending double-counts the same dollars on
          --     both sides and makes the monthly card / bar chart
          --     useless right after a bulk import.
          --
          --   LOAN_PAYMENTS_CREDIT_CARD_PAYMENT — paying off a credit
          --     card the app is already tracking. The original purchase
          --     was already counted as spending on the CC; counting
          --     the payment-from-checking again doubles it. Other
          --     LOAN_PAYMENTS_* (mortgage, student, auto) stay
          --     in-scope because the destination account isn't
          --     necessarily tracked.
          AND COALESCE(t.category, '') NOT IN ('TRANSFER_IN', 'TRANSFER_OUT')
          AND COALESCE(t.category_detailed, '') <> 'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT'
          -- Exclude personal-lending legs: a loan disbursement isn't
          -- spending (it's a receivable) and a repayment isn't income
          -- (it's the money coming back). Counting either would
          -- double-distort the cash-flow bars. The partial unique
          -- indexes on these columns make the anti-joins index probes.
          AND NOT EXISTS (SELECT 1 FROM loans l WHERE l.disbursement_tx_id = t.id)
          AND NOT EXISTS (SELECT 1 FROM loan_payments lp WHERE lp.actual_tx_id = t.id)
        GROUP BY month
        ORDER BY month ASC
        "#
    )
    .bind(ctx.user_id)
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

#[derive(Deserialize)]
struct SpendingByCategoryQuery {
    /// Trailing window in months (default 6). Clamped to 1..=24.
    months: Option<i64>,
    /// Max categories returned; the rest fold into "OTHER". Default 8.
    top: Option<i64>,
}

#[derive(Serialize)]
struct CategoryMonthAmount {
    month: String,
    amount: f64,
}

#[derive(Serialize)]
struct CategorySpending {
    /// PFC primary code or the user's manual override (frontend prettifies).
    category: String,
    total: f64,
    monthly: Vec<CategoryMonthAmount>,
}

#[derive(Serialize)]
struct SpendingByCategoryResponse {
    /// Chronological YYYY-MM buckets in the window (only months with data).
    months: Vec<String>,
    categories: Vec<CategorySpending>,
}

/// Per-category spending over the trailing N months — the "where's my money
/// going" view. Same cash-flow hygiene as `cash_flow_trends` (USD-normalized,
/// excludes internal transfers / CC payments / lending legs / split parents),
/// but grouped by category so each month can be broken down. The top-`top`
/// categories by total are returned verbatim; everything else folds into a
/// single "OTHER" bucket so the stacked chart stays legible.
async fn spending_by_category(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<SpendingByCategoryQuery>,
) -> Json<SpendingByCategoryResponse> {
    let months = q.months.unwrap_or(6).clamp(1, 24);
    let top = q.top.unwrap_or(8).clamp(1, 30) as usize;

    let rows = sqlx::query(
        r#"
        WITH latest_fx AS (
            SELECT rate FROM exchange_rates
            WHERE base_currency = 'USD' AND target_currency = 'MXN'
            ORDER BY recorded_at DESC LIMIT 1
        )
        SELECT TO_CHAR(t.date, 'YYYY-MM') AS month,
               COALESCE(NULLIF(t.user_category, ''), t.category, 'UNCATEGORIZED') AS category,
               SUM(CASE WHEN a.currency = 'MXN'
                        THEN ABS(t.amount) / COALESCE((SELECT rate FROM latest_fx), 20.0)
                        ELSE ABS(t.amount) END) AS amount
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        WHERE t.amount < 0
          AND t.date >= (DATE_TRUNC('month', CURRENT_DATE) - make_interval(months => ($2::int - 1)))
          AND t.user_id = $1
          AND NOT EXISTS (SELECT 1 FROM transactions tc WHERE tc.parent_id = t.id)
          AND COALESCE(t.category, '') NOT IN ('TRANSFER_IN', 'TRANSFER_OUT')
          AND COALESCE(t.category_detailed, '') <> 'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT'
          AND NOT EXISTS (SELECT 1 FROM loans l WHERE l.disbursement_tx_id = t.id)
          AND NOT EXISTS (SELECT 1 FROM loan_payments lp WHERE lp.actual_tx_id = t.id)
        GROUP BY TO_CHAR(t.date, 'YYYY-MM'),
                 COALESCE(NULLIF(t.user_category, ''), t.category, 'UNCATEGORIZED')
        ORDER BY month ASC
        "#,
    )
    .bind(ctx.user_id)
    .bind(months as i32)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    // (category -> (month -> amount)) plus per-category totals and the set of
    // months actually present, so the response only carries populated buckets.
    let mut by_cat: HashMap<String, HashMap<String, f64>> = HashMap::new();
    let mut totals: HashMap<String, f64> = HashMap::new();
    let mut month_set: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();

    for r in &rows {
        let month: String = r.get("month");
        let category: String = r.get("category");
        let amount: f64 = r
            .try_get::<rust_decimal::Decimal, _>("amount")
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
            .unwrap_or(0.0);
        month_set.insert(month.clone());
        *totals.entry(category.clone()).or_insert(0.0) += amount;
        *by_cat
            .entry(category)
            .or_default()
            .entry(month)
            .or_insert(0.0) += amount;
    }

    let months_vec: Vec<String> = month_set.into_iter().collect();

    // Rank categories by total; keep the top N, fold the rest into OTHER.
    let mut ranked: Vec<(String, f64)> = totals.iter().map(|(k, v)| (k.clone(), *v)).collect();
    ranked.sort_by(|a, b| b.1.partial_cmp(&a.1).unwrap_or(std::cmp::Ordering::Equal));

    let keep: std::collections::HashSet<String> =
        ranked.iter().take(top).map(|(k, _)| k.clone()).collect();

    // Accumulate OTHER across both totals and per-month so the stacked bars
    // still sum to real monthly spending.
    let mut other_total = 0.0;
    let mut other_monthly: HashMap<String, f64> = HashMap::new();
    let mut categories: Vec<CategorySpending> = Vec::new();

    for (cat, per_month) in &by_cat {
        if keep.contains(cat) {
            let monthly = months_vec
                .iter()
                .map(|m| CategoryMonthAmount {
                    month: m.clone(),
                    amount: *per_month.get(m).unwrap_or(&0.0),
                })
                .collect();
            categories.push(CategorySpending {
                category: cat.clone(),
                total: *totals.get(cat).unwrap_or(&0.0),
                monthly,
            });
        } else {
            other_total += *totals.get(cat).unwrap_or(&0.0);
            for (m, v) in per_month {
                *other_monthly.entry(m.clone()).or_insert(0.0) += *v;
            }
        }
    }

    categories.sort_by(|a, b| b.total.partial_cmp(&a.total).unwrap_or(std::cmp::Ordering::Equal));

    if other_total > 0.0 {
        let monthly = months_vec
            .iter()
            .map(|m| CategoryMonthAmount {
                month: m.clone(),
                amount: *other_monthly.get(m).unwrap_or(&0.0),
            })
            .collect();
        categories.push(CategorySpending {
            category: "OTHER".to_string(),
            total: other_total,
            monthly,
        });
    }

    Json(SpendingByCategoryResponse {
        months: months_vec,
        categories,
    })
}

#[derive(Deserialize)]
struct SpendingInsightsQuery {
    /// Number of trailing *complete* months to average over (the baseline).
    /// The comparison month is the most recent complete calendar month; the
    /// baseline is the `lookback` complete months immediately before it.
    /// Default 3, clamped 1..=12.
    lookback: Option<i64>,
}

#[derive(Serialize)]
struct CategoryInsight {
    // Raw category fields so the frontend can prettify identically to the
    // budgets card / spending screen (prettyCategory prefers user_category,
    // then category_detailed, then category). Returning the codes rather than
    // a pre-formatted label keeps the (locale-aware) labelling in one place.
    #[serde(skip_serializing_if = "Option::is_none")]
    user_category: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    category_detailed: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    category: Option<String>,
    /// Spend in the most recent complete calendar month, USD.
    recent: f64,
    /// Average monthly spend over the `lookback` months *before* `recent`, USD.
    /// 0 when there's no baseline history for the category.
    previous_avg: f64,
    /// Average monthly spend over the recent + baseline window
    /// (`lookback` + 1 complete months), USD. Used to seed budget suggestions.
    trailing_avg: f64,
}

#[derive(Serialize)]
struct SpendingInsightsResponse {
    /// YYYY-MM of the most recent complete calendar month (the comparison month).
    recent_month: String,
    lookback: i64,
    categories: Vec<CategoryInsight>,
}

/// Per-category month-over-month-vs-trailing-average spend deltas. Powers the
/// "groceries up 40% vs your 3-month average" notifications and the budget
/// auto-suggestion. Same cash-flow hygiene as `cash_flow_trends` /
/// `spending_by_category` (USD-normalized, excludes internal transfers, CC
/// payments, lending legs, split parents).
///
/// The comparison month is the most recent **complete** calendar month — the
/// current (partial) month is deliberately excluded so a 6th-of-the-month read
/// doesn't report every category as "down". Each category is grouped on the
/// raw (user_category, category_detailed, category) triple; the frontend
/// collapses those to display labels so the keys line up with the budgets card.
async fn spending_insights(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<SpendingInsightsQuery>,
) -> Json<SpendingInsightsResponse> {
    let lookback = q.lookback.unwrap_or(3).clamp(1, 12);
    // Window = recent + baseline = lookback + 1 complete months.
    let window = lookback + 1;

    // DB-anchored month labels for the window, newest first (n=1 → recent).
    // Anchoring to the DB's CURRENT_DATE (rather than chrono::Utc) keeps the
    // recent/baseline split consistent with the WHERE-clause below across any
    // server/UTC timezone skew at a month boundary.
    let month_rows = sqlx::query(
        r#"
        SELECT gs.n AS n,
               TO_CHAR(DATE_TRUNC('month', CURRENT_DATE) - make_interval(months => gs.n), 'YYYY-MM') AS m
        FROM generate_series(1, $1::int) AS gs(n)
        ORDER BY gs.n
        "#,
    )
    .bind(window as i32)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let window_months: Vec<String> = month_rows.iter().map(|r| r.get::<String, _>("m")).collect();
    let recent_month = window_months.first().cloned().unwrap_or_default();

    let rows = sqlx::query(
        r#"
        WITH latest_fx AS (
            SELECT rate FROM exchange_rates
            WHERE base_currency = 'USD' AND target_currency = 'MXN'
            ORDER BY recorded_at DESC LIMIT 1
        )
        SELECT TO_CHAR(t.date, 'YYYY-MM') AS month,
               t.user_category AS user_category,
               t.category_detailed AS category_detailed,
               t.category AS category,
               SUM(CASE WHEN a.currency = 'MXN'
                        THEN ABS(t.amount) / COALESCE((SELECT rate FROM latest_fx), 20.0)
                        ELSE ABS(t.amount) END) AS amount
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        WHERE t.amount < 0
          AND t.date >= DATE_TRUNC('month', CURRENT_DATE) - make_interval(months => $2::int)
          AND t.date <  DATE_TRUNC('month', CURRENT_DATE)
          AND t.user_id = $1
          AND NOT EXISTS (SELECT 1 FROM transactions tc WHERE tc.parent_id = t.id)
          AND COALESCE(t.category, '') NOT IN ('TRANSFER_IN', 'TRANSFER_OUT')
          AND COALESCE(t.category_detailed, '') <> 'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT'
          AND NOT EXISTS (SELECT 1 FROM loans l WHERE l.disbursement_tx_id = t.id)
          AND NOT EXISTS (SELECT 1 FROM loan_payments lp WHERE lp.actual_tx_id = t.id)
        GROUP BY month, t.user_category, t.category_detailed, t.category
        "#,
    )
    .bind(ctx.user_id)
    .bind(window as i32)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    // Accumulate per (user_category, category_detailed, category) → (month → amount).
    type CatKey = (Option<String>, Option<String>, Option<String>);
    let mut by_cat: HashMap<CatKey, HashMap<String, f64>> = HashMap::new();
    for r in &rows {
        let month: String = r.get("month");
        // Treat an empty-string user_category as absent so it folds in with
        // the NULL group (both prettify to the detailed/primary label).
        let user_category: Option<String> = r
            .try_get::<Option<String>, _>("user_category")
            .ok()
            .flatten()
            .filter(|s| !s.trim().is_empty());
        let category_detailed: Option<String> = r
            .try_get::<Option<String>, _>("category_detailed")
            .ok()
            .flatten()
            .filter(|s| !s.trim().is_empty());
        let category: Option<String> = r
            .try_get::<Option<String>, _>("category")
            .ok()
            .flatten()
            .filter(|s| !s.trim().is_empty());
        let amount: f64 = r
            .try_get::<rust_decimal::Decimal, _>("amount")
            .ok()
            .and_then(|d| d.to_string().parse().ok())
            .unwrap_or(0.0);
        *by_cat
            .entry((user_category, category_detailed, category))
            .or_default()
            .entry(month)
            .or_insert(0.0) += amount;
    }

    let baseline_months = &window_months[1.min(window_months.len())..];
    let lookback_f = lookback as f64;
    let window_f = window as f64;

    let mut categories: Vec<CategoryInsight> = by_cat
        .into_iter()
        .map(|((uc, cd, c), per_month)| {
            let recent = *per_month.get(&recent_month).unwrap_or(&0.0);
            let baseline_sum: f64 =
                baseline_months.iter().map(|m| *per_month.get(m).unwrap_or(&0.0)).sum();
            CategoryInsight {
                user_category: uc,
                category_detailed: cd,
                category: c,
                recent,
                previous_avg: if lookback_f > 0.0 { baseline_sum / lookback_f } else { 0.0 },
                trailing_avg: (recent + baseline_sum) / window_f,
            }
        })
        .collect();

    // Largest trailing spend first — the most material categories lead, which
    // is what both the notification ranking and the budget seed want.
    categories.sort_by(|a, b| {
        b.trailing_avg
            .partial_cmp(&a.trailing_avg)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    Json(SpendingInsightsResponse {
        recent_month,
        lookback,
        categories,
    })
}

#[derive(Deserialize)]
struct BenchmarkQuery {
    /// ISO date (YYYY-MM-DD) to start the series from. Defaults to ~3 years ago.
    from: Option<String>,
}

#[derive(Serialize)]
struct BenchmarkPoint {
    date: String,
    close: f64,
}

#[derive(Serialize)]
struct BenchmarkResponse {
    symbol: String,
    points: Vec<BenchmarkPoint>,
}

/// S&P 500 daily closes for overlaying "net worth vs the market". Lazily
/// refreshes from the free Yahoo feed when stale, then serves from our table.
/// Not user-scoped — the index is the same for everyone — but still behind
/// auth like the rest of the dashboard.
async fn benchmark_series(
    State(state): State<AppState>,
    Extension(_ctx): Extension<AuthContext>,
    Query(q): Query<BenchmarkQuery>,
) -> Json<BenchmarkResponse> {
    use crate::services::benchmark;
    // Best-effort freshness; on failure we still serve whatever is stored.
    let _ = benchmark::ensure_fresh(&state.db).await;

    let from = q
        .from
        .as_deref()
        .and_then(|s| chrono::NaiveDate::parse_from_str(s, "%Y-%m-%d").ok())
        .unwrap_or_else(|| chrono::Utc::now().date_naive() - chrono::Duration::days(365 * 3));

    let points = benchmark::series(&state.db, benchmark::SP500, from)
        .await
        .into_iter()
        .map(|(d, c)| BenchmarkPoint {
            date: d.format("%Y-%m-%d").to_string(),
            close: c,
        })
        .collect();

    Json(BenchmarkResponse {
        symbol: benchmark::SP500.to_string(),
        points,
    })
}

/// Dollar-weighted "you vs the S&P 500" over the user's tracked holding lots.
async fn benchmark_comparison(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<crate::services::benchmark::ContributionComparison> {
    let _ = crate::services::benchmark::ensure_fresh(&state.db).await;
    Json(crate::services::benchmark::contribution_comparison(&state.db, ctx.user_id).await)
}

#[derive(Serialize)]
struct EmergencyFundResponse {
    /// Total liquid cash across checking/savings/cash accounts, USD.
    liquid_cash_usd: f64,
    /// Trailing average monthly spending, USD (same hygiene as cash-flow).
    monthly_spend_usd: f64,
    /// liquid_cash / monthly_spend; 0 when there's no spend signal yet.
    months_covered: f64,
    /// Distinct months of spending data backing the estimate.
    months_of_data: i32,
}

/// Emergency-fund runway: how many months of tracked spending the user's liquid
/// cash would cover. Cash is USD-normalized like the rest of the dashboard;
/// spend reuses the cash-flow exclusions (no transfers / CC payments / lending
/// legs / split parents), annualized over however many months exist.
async fn emergency_fund(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<EmergencyFundResponse> {
    let fx = sqlx::query(
        "SELECT rate FROM exchange_rates WHERE base_currency = 'USD' AND target_currency = 'MXN' \
         ORDER BY recorded_at DESC LIMIT 1",
    )
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten()
    .and_then(|r| r.try_get::<rust_decimal::Decimal, _>("rate").ok())
    .and_then(|d| d.to_string().parse::<f64>().ok())
    .filter(|r| *r > 0.0)
    .unwrap_or(20.0);

    let cash_row = sqlx::query(
        r#"
        SELECT COALESCE(SUM(
            CASE WHEN currency = 'MXN' THEN current_balance / $2::numeric
                 ELSE current_balance END), 0) AS cash
        FROM accounts
        WHERE user_id = $1
          AND account_type IN ('checking', 'savings', 'cash', 'cash management', 'cd', 'money market')
        "#,
    )
    .bind(ctx.user_id)
    .bind(fx)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten();
    let liquid_cash_usd = cash_row
        .and_then(|r| r.try_get::<rust_decimal::Decimal, _>("cash").ok())
        .map(|d| d.to_string().parse().unwrap_or(0.0))
        .unwrap_or(0.0);

    // Trailing spend + month count, mirroring projection_defaults / cash-flow.
    let spend_row = sqlx::query(
        r#"
        WITH latest_fx AS (
            SELECT rate FROM exchange_rates
            WHERE base_currency = 'USD' AND target_currency = 'MXN'
            ORDER BY recorded_at DESC LIMIT 1
        )
        SELECT
            COALESCE(SUM(CASE WHEN a.currency = 'MXN'
                     THEN ABS(t.amount) / COALESCE((SELECT rate FROM latest_fx), 20.0)
                     ELSE ABS(t.amount) END), 0) AS spending,
            COUNT(DISTINCT TO_CHAR(t.date, 'YYYY-MM')) AS months
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        WHERE t.amount < 0
          AND t.date >= CURRENT_DATE - INTERVAL '12 months'
          AND t.user_id = $1
          AND NOT EXISTS (SELECT 1 FROM transactions tc WHERE tc.parent_id = t.id)
          AND COALESCE(t.category, '') NOT IN ('TRANSFER_IN', 'TRANSFER_OUT')
          AND COALESCE(t.category_detailed, '') <> 'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT'
          AND NOT EXISTS (SELECT 1 FROM loans l WHERE l.disbursement_tx_id = t.id)
          AND NOT EXISTS (SELECT 1 FROM loan_payments lp WHERE lp.actual_tx_id = t.id)
        "#,
    )
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten();

    let (spending, months) = match spend_row {
        Some(r) => {
            let s: f64 = r
                .try_get::<rust_decimal::Decimal, _>("spending")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0);
            let m: i64 = r.try_get("months").unwrap_or(0);
            (s, m.max(0))
        }
        None => (0.0, 0),
    };

    let monthly_spend_usd = if months > 0 {
        spending / months as f64
    } else {
        0.0
    };
    let months_covered = if monthly_spend_usd > 0.0 {
        liquid_cash_usd / monthly_spend_usd
    } else {
        0.0
    };

    Json(EmergencyFundResponse {
        liquid_cash_usd,
        monthly_spend_usd,
        months_covered,
        months_of_data: months as i32,
    })
}

#[derive(Deserialize)]
struct AccountBalanceHistoryQuery {
    account_id: String,
}

#[derive(Serialize)]
struct BalancePoint {
    month: String,
    balance: f64,
}

/// Monthly closing balance for one account, derived from the persisted
/// `balance_after` (the statement SALDO captured at import). Returns the latest
/// in-month balance per month, in the account's native currency. Only accounts
/// with statement-imported rows have this data; Plaid-only accounts return [].
async fn account_balance_history(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<AccountBalanceHistoryQuery>,
) -> Json<Vec<BalancePoint>> {
    let account_id = match uuid::Uuid::parse_str(&q.account_id) {
        Ok(id) => id,
        Err(_) => return Json(Vec::new()),
    };

    let rows = sqlx::query(
        r#"
        SELECT DISTINCT ON (TO_CHAR(t.date, 'YYYY-MM'))
               TO_CHAR(t.date, 'YYYY-MM') AS month,
               t.balance_after AS balance
        FROM transactions t
        WHERE t.account_id = $1
          AND t.user_id = $2
          AND t.balance_after IS NOT NULL
        ORDER BY TO_CHAR(t.date, 'YYYY-MM') ASC, t.date DESC, t.id DESC
        "#,
    )
    .bind(account_id)
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| BalancePoint {
                month: r.get("month"),
                balance: r
                    .try_get::<rust_decimal::Decimal, _>("balance")
                    .ok()
                    .map(|d| d.to_string().parse().unwrap_or(0.0))
                    .unwrap_or(0.0),
            })
            .collect(),
    )
}

#[derive(Deserialize)]
struct RealizedGainsQuery {
    /// Optional calendar-year filter on the disposal list (the summary +
    /// by-year chart always cover all history).
    year: Option<i32>,
}

#[derive(Serialize)]
struct RealizedDisposal {
    symbol: String,
    name: String,
    sell_date: String,
    qty_sold: f64,
    proceeds_usd: f64,
    cost_usd: f64,
    realized_pnl_usd: f64,
    /// Holding period in days (null when the source lot was later deleted).
    holding_days: Option<i32>,
    /// IRS long-term threshold: held > 365 days. Null when unknown.
    long_term: Option<bool>,
}

#[derive(Serialize)]
struct RealizedYear {
    year: i32,
    realized_usd: f64,
}

#[derive(Serialize)]
struct RealizedGainsSummary {
    ytd_realized_usd: f64,
    total_realized_usd: f64,
    /// Count of disposal rows in the (optionally year-filtered) list.
    count: i64,
    /// The year filter applied to the list, if any.
    year: Option<i32>,
}

#[derive(Serialize)]
struct RealizedGainsResponse {
    summary: RealizedGainsSummary,
    by_year: Vec<RealizedYear>,
    disposals: Vec<RealizedDisposal>,
}

/// Realized capital gains/losses from `lot_disposals` — the per-sell P&L the
/// FIFO engine crystallizes but the holdings view never surfaces. Each row is
/// one (sell event, depleted lot) pair; `realized_pnl_usd` is pre-computed at
/// sync time. We add USD proceeds/cost for display and a long-term flag (held
/// > 365 days) for tax context, joining the source lot for the acquisition
/// date when it still exists.
async fn realized_gains(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<RealizedGainsQuery>,
) -> Json<RealizedGainsResponse> {
    let dec = |r: &sqlx::postgres::PgRow, col: &str| -> f64 {
        r.try_get::<rust_decimal::Decimal, _>(col)
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
            .unwrap_or(0.0)
    };

    let rows = sqlx::query(
        r#"
        SELECT TO_CHAR(d.sell_date, 'YYYY-MM-DD') AS sell_date,
               d.qty_sold, d.sell_price_per_unit, d.sell_fx_rate,
               d.cost_per_unit, d.cost_fx_rate, d.realized_pnl_usd,
               h.symbol, h.name,
               (d.sell_date - l.acquired_at) AS holding_days
        FROM lot_disposals d
        JOIN holdings h ON h.id = d.holding_id
        LEFT JOIN holding_lots l ON l.id = d.lot_id
        WHERE d.user_id = $1
          AND ($2::int IS NULL OR EXTRACT(YEAR FROM d.sell_date)::int = $2)
        ORDER BY d.sell_date DESC
        LIMIT 500
        "#,
    )
    .bind(ctx.user_id)
    .bind(q.year)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let disposals: Vec<RealizedDisposal> = rows
        .iter()
        .map(|r| {
            let qty = dec(r, "qty_sold");
            let sell_px = dec(r, "sell_price_per_unit");
            let sell_fx = dec(r, "sell_fx_rate");
            let cost_px = dec(r, "cost_per_unit");
            let cost_fx = dec(r, "cost_fx_rate");
            // fx rate is native-units-per-USD (1.0 for USD securities), so
            // divide native amounts by it to land in USD.
            let proceeds_usd = if sell_fx > 0.0 {
                qty * sell_px / sell_fx
            } else {
                qty * sell_px
            };
            let cost_usd = if cost_fx > 0.0 {
                qty * cost_px / cost_fx
            } else {
                qty * cost_px
            };
            let holding_days: Option<i32> = r.try_get("holding_days").ok();
            RealizedDisposal {
                symbol: r.get("symbol"),
                name: r.get("name"),
                sell_date: r.get("sell_date"),
                qty_sold: qty,
                proceeds_usd,
                cost_usd,
                realized_pnl_usd: dec(r, "realized_pnl_usd"),
                holding_days,
                long_term: holding_days.map(|d| d > 365),
            }
        })
        .collect();

    let count = disposals.len() as i64;

    // By-year totals across ALL history (independent of the list filter).
    let year_rows = sqlx::query(
        r#"
        SELECT EXTRACT(YEAR FROM sell_date)::int AS year,
               COALESCE(SUM(realized_pnl_usd), 0) AS total
        FROM lot_disposals
        WHERE user_id = $1
        GROUP BY year
        ORDER BY year ASC
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let by_year: Vec<RealizedYear> = year_rows
        .iter()
        .map(|r| RealizedYear {
            year: r.try_get("year").unwrap_or(0),
            realized_usd: dec(r, "total"),
        })
        .collect();

    let total_realized_usd: f64 = by_year.iter().map(|y| y.realized_usd).sum();

    let ytd_row = sqlx::query(
        r#"
        SELECT COALESCE(SUM(realized_pnl_usd), 0) AS total
        FROM lot_disposals
        WHERE user_id = $1
          AND EXTRACT(YEAR FROM sell_date) = EXTRACT(YEAR FROM CURRENT_DATE)
        "#,
    )
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten();
    let ytd_realized_usd = ytd_row.as_ref().map(|r| dec(r, "total")).unwrap_or(0.0);

    Json(RealizedGainsResponse {
        summary: RealizedGainsSummary {
            ytd_realized_usd,
            total_realized_usd,
            count,
            year: q.year,
        },
        by_year,
        disposals,
    })
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
    /// Totals in the holdings' native currencies summed naively.
    /// Useful when every holding shares one currency; meaningless
    /// when mixing USD + MXN positions, in which case the consumer
    /// should read `total_value_usd` / `total_value_mxn`.
    total_value: f64,
    total_cost_basis: f64,
    total_gain_loss: f64,
    total_gain_loss_pct: f64,
    /// Dual-currency totals — each holding converted via current FX
    /// (or per-lot historical FX when `holding_lots` rows are
    /// available) and summed. Bi-national investors should display
    /// whichever side matches their reporting currency.
    total_value_usd: f64,
    total_value_mxn: f64,
    total_cost_basis_usd: f64,
    total_cost_basis_mxn: f64,
    total_gain_loss_usd: f64,
    total_gain_loss_mxn: f64,
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
    /// Per-holding dual-currency conversions. `value_usd` and
    /// `cost_basis_usd` always agree with the holding's native
    /// number when the security is USD-denominated; for MXN
    /// securities they're computed via current FX. The MXN side is
    /// always derivable from the USD side via current FX, but we
    /// pre-compute both so the frontend doesn't need the FX rate to
    /// render the row.
    value_usd: f64,
    value_mxn: f64,
    cost_basis_usd: f64,
    cost_basis_mxn: f64,
    gain_loss_usd: f64,
    gain_loss_mxn: f64,
    currency: String,
    holding_type: String,
    account_name: String,
    institution_name: String,
    /// Per-lot breakdown when `holding_lots` rows exist for this
    /// holding. Lets power users see WHY the FX-aware cost basis
    /// differs from the naive current-FX number — each lot carries
    /// the historical FX rate at acquisition. Empty for holdings
    /// that pre-date the lot-tracker (institutions not yet
    /// re-synced) or for non-investment rows.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    lots: Vec<HoldingLot>,
}

#[derive(Serialize)]
struct HoldingLot {
    /// Acquisition date (YYYY-MM-DD) of the lot. FIFO order is
    /// implied by the array order — the frontend renders them in
    /// acquired-first order.
    acquired_at: String,
    /// Lot quantity. Always > 0 for active lots; depletion markers
    /// (qty 0) are filtered out before this serialises.
    qty: f64,
    /// Native cost per unit (the share / unit price at acquisition).
    cost_per_unit: f64,
    /// Currency the cost is denominated in — same as the holding for
    /// homogeneous brokerages, can differ for multi-currency accounts.
    currency: String,
    /// USD↔native FX rate that was in effect on `acquired_at`. We
    /// snapshot this at lot creation so future FX moves don't
    /// retroactively shift historical cost basis.
    usd_fx_rate: f64,
    /// Convenience: qty × cost_per_unit (native).
    native_cost: f64,
    /// Convenience: native_cost ÷ usd_fx_rate (or = native_cost when
    /// the lot is already USD).
    usd_cost: f64,
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
    /// User-supplied display label, preferred by `displayLabel` over
    /// every Plaid-side fallback when set.
    #[serde(skip_serializing_if = "Option::is_none")]
    user_description: Option<String>,
    /// Plaid `payment_meta.payee` — for ACH/wire/bill-pay rows where the
    /// bank's `name` is "Miscellaneous Debit" but the payee is the only
    /// useful identifier (e.g. "PG&E", "VERIZON").
    #[serde(skip_serializing_if = "Option::is_none")]
    payment_payee: Option<String>,
    /// Plaid `payment_meta.payer` — symmetric to `payment_payee` for
    /// incoming wires/ACH where Plaid identifies who sent the funds.
    #[serde(skip_serializing_if = "Option::is_none")]
    payment_payer: Option<String>,
    /// When non-null, this transaction is a child of a split. Display
    /// hint only — children aggregate exactly like regular transactions.
    #[serde(skip_serializing_if = "Option::is_none")]
    parent_id: Option<String>,
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

#[derive(Serialize)]
struct SinceLastLogin {
    /// ISO-8601 timestamp of the prior login (the anchor). `None` when
    /// this is the user's very first session — the banner stays hidden
    /// in that case so a fresh user doesn't see "0 since never".
    #[serde(skip_serializing_if = "Option::is_none")]
    previous_login_at: Option<String>,
    /// Count of new transactions across all of this user's accounts
    /// since `previous_login_at`. Counts rows whose `created_at` is
    /// after that timestamp — Plaid sync stamps `created_at` at insert
    /// time so this correctly reflects "what the sync engine has
    /// produced since you were last here," not "what dates the bank
    /// stamped on them."
    new_transactions: i64,
    /// Largest absolute balance move on any single account since the
    /// anchor, in USD. `None` when no two snapshots straddle the anchor
    /// (insufficient history).
    #[serde(skip_serializing_if = "Option::is_none")]
    largest_move: Option<BalanceMove>,
    /// Names of institutions whose `sync_status` flipped to a problem
    /// state since the anchor. Used for "Chase needs reconnecting" call-outs.
    sync_errors: Vec<String>,
}

#[derive(Serialize)]
struct BalanceMove {
    account_name: String,
    delta_usd: f64,
}

/// "What changed since your last visit." Anchors on `users.previous_login_at`
/// (the second-most-recent login). When the user has never logged in twice
/// the entire response is suppressed so a fresh user doesn't see a useless
/// "0 since never" banner.
async fn since_last_login(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<SinceLastLogin> {
    let anchor_row = sqlx::query(
        "SELECT previous_login_at FROM users WHERE id = $1",
    )
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten();

    let anchor: Option<chrono::DateTime<chrono::Utc>> = anchor_row
        .and_then(|r| r.try_get::<chrono::DateTime<chrono::Utc>, _>("previous_login_at").ok());

    let Some(anchor) = anchor else {
        return Json(SinceLastLogin {
            previous_login_at: None,
            new_transactions: 0,
            largest_move: None,
            sync_errors: vec![],
        });
    };

    // 1) New transactions count. We count by `created_at` — what the sync
    //    engine added — rather than by transaction `date`, because Plaid
    //    can backfill old dates and the user would care most about "new
    //    rows that appeared in my list since I was last here."
    let tx_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM transactions t \
         WHERE t.user_id = $1 AND t.created_at > $2 \
           AND NOT EXISTS (SELECT 1 FROM transactions tc WHERE tc.parent_id = t.id)",
    )
    .bind(ctx.user_id)
    .bind(anchor)
    .fetch_one(&state.db)
    .await
    .unwrap_or(0);

    // 2) Largest single-account balance move. Compare each account's
    //    most recent snapshot at or after the anchor against the most
    //    recent one strictly before the anchor. Skip accounts that
    //    don't have a "before" snapshot — for a newly-linked account
    //    we'd otherwise count the whole balance as a "move."
    //
    //    Sign convention: positive delta means net worth went up.
    //    Liability balances are flipped — a credit card going $500 → $1500
    //    is a $1000 increase in what you owe, i.e. -$1000 to net worth.
    let moves = sqlx::query(
        r#"
        WITH before AS (
            SELECT DISTINCT ON (bs.account_id) bs.account_id, bs.balance_usd
            FROM balance_snapshots bs
            WHERE bs.user_id = $1 AND bs.created_at <= $2
            ORDER BY bs.account_id, bs.created_at DESC
        ),
        after AS (
            SELECT DISTINCT ON (bs.account_id) bs.account_id, bs.balance_usd
            FROM balance_snapshots bs
            WHERE bs.user_id = $1 AND bs.created_at > $2
            ORDER BY bs.account_id, bs.created_at DESC
        )
        SELECT
            COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name,
            CASE WHEN is_liability_account_type(a.account_type)
                 THEN -(after.balance_usd - before.balance_usd)
                 ELSE (after.balance_usd - before.balance_usd)
            END AS delta_usd
        FROM after
        JOIN before ON before.account_id = after.account_id
        JOIN accounts a ON a.id = after.account_id
        WHERE a.user_id = $1
        "#,
    )
    .bind(ctx.user_id)
    .bind(anchor)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let largest_move = moves
        .iter()
        .filter_map(|r| {
            let name: String = r.try_get("account_name").ok()?;
            let delta: rust_decimal::Decimal = r.try_get("delta_usd").ok()?;
            let delta_f: f64 = delta.to_string().parse().ok()?;
            Some(BalanceMove {
                account_name: name,
                delta_usd: delta_f,
            })
        })
        .max_by(|a, b| {
            a.delta_usd
                .abs()
                .partial_cmp(&b.delta_usd.abs())
                .unwrap_or(std::cmp::Ordering::Equal)
        })
        // A delta < $1 is noise (rounding, sub-dollar FX drift); hide it.
        .filter(|m| m.delta_usd.abs() >= 1.0);

    // 3) Institutions that have an error or reconnect_required status
    //    whose last sync error landed AFTER the anchor. We approximate
    //    with the row's `last_synced_at` since that's the only timestamp
    //    we keep — a more accurate "errored since" timestamp would
    //    require a separate column.
    let sync_errors: Vec<String> = sqlx::query(
        "SELECT name FROM institutions \
         WHERE user_id = $1 \
           AND sync_status IN ('error', 'reconnect_required') \
           AND (last_synced_at IS NULL OR last_synced_at >= $2)",
    )
    .bind(ctx.user_id)
    .bind(anchor)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default()
    .iter()
    .filter_map(|r| r.try_get::<String, _>("name").ok())
    .collect();

    Json(SinceLastLogin {
        previous_login_at: Some(anchor.to_rfc3339()),
        new_transactions: tx_count,
        largest_move,
        sync_errors,
    })
}

#[derive(Serialize)]
struct DetectedSubscription {
    /// Display label for the merchant. Picked from the same ladder as
    /// the transactions list so renames propagate.
    merchant: String,
    /// Monthly burn in USD (sum of all charges / number-of-months observed).
    /// Always positive — sign is implied (it's a recurring outflow).
    monthly_usd: f64,
    /// Estimated cadence in days between the two most recent charges.
    /// 30 = monthly, 7 = weekly, etc.
    cadence_days: i32,
    /// Date (YYYY-MM-DD) of the most recent charge.
    last_charge_date: String,
    /// Native amount + currency of the most recent charge so the UI
    /// can format it correctly.
    last_amount: f64,
    currency: String,
    /// How many separate charges we saw. >= 3 to qualify as recurring.
    occurrences: i32,
    /// "active" when last charge is within 90 days, "cancelled" when
    /// the cluster qualified as recurring at some point but hasn't
    /// charged in the last 90 days. The frontend renders cancelled
    /// subscriptions in a separate, collapsed "Stopped" section so
    /// the user can audit "did I actually cancel that?".
    status: &'static str,
    /// Per-account distribution within the cluster. Surfaces the
    /// "Apple Pay charged Visa AND a fee landed on Checking" case so
    /// the user can see which channel(s) are paying. Sorted descending
    /// by `total_native`; the largest contributor first.
    by_account: Vec<SubscriptionAccountSlice>,
}

#[derive(Serialize)]
struct SubscriptionAccountSlice {
    /// Account display name (nickname when set, else bank-supplied name).
    account_name: String,
    /// Number of charges that landed on this account in the cluster's
    /// observed window.
    occurrences: i32,
    /// Absolute spend on this account in the cluster's native currency.
    total_native: f64,
    /// Share of the cluster total (0.0–1.0). Lets the frontend draw
    /// a tiny inline bar without recomputing.
    share: f64,
}

/// Detected recurring outflows (subscriptions, bills, gym dues, etc.).
///
/// Heuristic: group every **expense** transaction (amount < 0 in this
/// app's sign convention — see `cash_flow_trends` and the Plaid sync
/// path; outflows are stored as negative, inflows as positive) of the
/// last 12 months by a merchant key + amount band. A cluster qualifies
/// as "recurring" when:
///   * ≥ 3 occurrences,
///   * median gap between consecutive charges is 5–62 days (covers
///     weekly through bi-monthly cadence; one-off bursts are filtered
///     out by the gap floor, annual renewals are filtered out by the
///     gap ceiling — both can be added if anyone asks).
///   * Most recent charge is within 90 days (within 91–548 days the
///     cluster is flagged `status: "cancelled"`; older than that is
///     dropped as noise).
///
/// We deliberately exclude income-shaped rows: a checking account
/// that receives monthly "Interest Earned" credits would otherwise
/// match the recurring shape and surface as a fake subscription.
///
/// Returns sorted by status (active first), then by monthly_usd
/// descending so the most expensive subscriptions surface first.
async fn detected_subscriptions(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<DetectedSubscription>> {
    // Pull the user's dismissed-as-not-subscription set first, so we
    // can skip those keys during clustering. Small table; we hold the
    // whole thing in memory.
    let ignored_rows = sqlx::query(
        "SELECT merchant_key FROM ignored_subscription_merchants WHERE user_id = $1",
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();
    let ignored: std::collections::HashSet<String> = ignored_rows
        .iter()
        .filter_map(|r| r.try_get::<String, _>("merchant_key").ok())
        .collect();
    let rows = sqlx::query(
        r#"
        SELECT
            t.date, t.amount, t.currency, t.account_id,
            t.description, t.merchant_name, t.counterparty_name,
            t.user_description, t.payment_payee,
            COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        WHERE t.user_id = $1
          -- Outflows only. Sign convention: amount < 0 = expense,
          -- amount > 0 = income. Including income would surface
          -- "Interest earned" / "Dividend" / "Salary" as fake
          -- "subscriptions" once their recurring shape clusters.
          AND t.amount < 0
          AND t.date >= CURRENT_DATE - INTERVAL '548 days'
          AND NOT EXISTS (SELECT 1 FROM transactions tc WHERE tc.parent_id = t.id)
        ORDER BY t.date DESC
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    if rows.is_empty() {
        return Json(vec![]);
    }

    // Look up the latest USD/MXN rate once for the monthly_usd
    // normalisation. A MXN-denominated subscription gets reported in
    // USD so the user can compare totals across currencies. If the
    // rate is missing we conservatively skip MXN rows from the USD
    // total — they'll still appear with their native amount.
    let fx_mxn_row = sqlx::query(
        "SELECT rate FROM exchange_rates WHERE base_currency = 'USD' AND target_currency = 'MXN' \
         ORDER BY recorded_at DESC LIMIT 1",
    )
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten();
    let fx_mxn: Option<f64> = fx_mxn_row
        .and_then(|r| r.try_get::<rust_decimal::Decimal, _>("rate").ok())
        .and_then(|d| d.to_string().parse::<f64>().ok())
        .filter(|r| *r > 0.0);

    // Build a key per (normalised merchant, amount band). Amount band
    // is the rounded-to-nearest-dollar value, so a $9.99 / $10.00 /
    // $10.01 Netflix sequence all cluster (banks occasionally vary
    // sub-cent on rolling charges).
    use std::collections::HashMap;
    struct AccountTally {
        display: String,
        count: u32,
        // Absolute spend on this account in the cluster's native
        // currency. Sign is implied by the cluster (outflow).
        total_native: f64,
    }
    struct Cluster {
        merchant: String,
        currency: String,
        // (date_yyyymmdd, amount_native_positive) for every observed
        // charge. Amounts are stored as the *absolute* value of the
        // raw row so downstream math (median gap, monthly average)
        // can stay sign-agnostic.
        events: Vec<(chrono::NaiveDate, f64)>,
        // Per-account spend within the cluster, keyed by account UUID.
        // Used to surface "Apple Pay charged Visa AND a fee landed on
        // Checking" when the same merchant clusters across accounts.
        by_account: HashMap<uuid::Uuid, AccountTally>,
    }
    let mut clusters: HashMap<String, Cluster> = HashMap::new();

    fn merchant_key(
        user_desc: Option<&str>,
        counterparty: Option<&str>,
        merchant: Option<&str>,
        payee: Option<&str>,
        description: &str,
    ) -> String {
        // Mirrors the frontend's display ladder (excluding original
        // description, which is too noisy for clustering — POS reference
        // codes vary per swipe). Lowercase + trim so case doesn't split
        // clusters.
        let raw = user_desc
            .filter(|s| !s.trim().is_empty())
            .or(counterparty.filter(|s| !s.trim().is_empty()))
            .or(merchant.filter(|s| !s.trim().is_empty()))
            .or(payee.filter(|s| !s.trim().is_empty()))
            .unwrap_or(description);
        raw.trim().to_lowercase()
    }

    fn display_merchant(
        user_desc: Option<&str>,
        counterparty: Option<&str>,
        merchant: Option<&str>,
        payee: Option<&str>,
        description: &str,
    ) -> String {
        // Pick the most user-recognisable name for display. Same source
        // ladder as `merchant_key` but preserves the original case.
        user_desc
            .filter(|s| !s.trim().is_empty())
            .or(counterparty.filter(|s| !s.trim().is_empty()))
            .or(merchant.filter(|s| !s.trim().is_empty()))
            .or(payee.filter(|s| !s.trim().is_empty()))
            .unwrap_or(description)
            .trim()
            .to_string()
    }

    for r in &rows {
        let date: chrono::NaiveDate = match r.try_get("date") {
            Ok(d) => d,
            Err(_) => continue,
        };
        let raw_amount: f64 = r
            .try_get::<rust_decimal::Decimal, _>("amount")
            .ok()
            .and_then(|d| d.to_string().parse().ok())
            .unwrap_or(0.0);
        // SQL filter already restricts to amount < 0, but a defensive
        // sign check here keeps the loop honest if the WHERE clause is
        // ever softened. From this point on `amount` is the absolute
        // outflow magnitude — sign is implied by the cluster.
        if raw_amount >= 0.0 {
            continue;
        }
        let amount = raw_amount.abs();
        let currency: String = r.try_get("currency").unwrap_or_else(|_| "USD".into());
        let description: String = r.try_get("description").unwrap_or_default();
        let account_id: uuid::Uuid = match r.try_get("account_id") {
            Ok(id) => id,
            Err(_) => continue,
        };
        let account_name: String = r
            .try_get::<String, _>("account_name")
            .unwrap_or_else(|_| "Account".into());
        let merchant_name: Option<String> =
            r.try_get::<Option<String>, _>("merchant_name").ok().flatten();
        let counterparty_name: Option<String> = r
            .try_get::<Option<String>, _>("counterparty_name")
            .ok()
            .flatten();
        let user_description: Option<String> = r
            .try_get::<Option<String>, _>("user_description")
            .ok()
            .flatten();
        let payment_payee: Option<String> = r
            .try_get::<Option<String>, _>("payment_payee")
            .ok()
            .flatten();

        let key_part = merchant_key(
            user_description.as_deref(),
            counterparty_name.as_deref(),
            merchant_name.as_deref(),
            payment_payee.as_deref(),
            &description,
        );
        // Skip generic strings that we can't meaningfully cluster on —
        // letting them through would lump every "Miscellaneous Debit"
        // row together and report a fake subscription.
        let lower = key_part.as_str();
        let generic_prefixes = [
            "miscellaneous", "ach ", "pos ", "online ", "wire ", "transfer", "debit", "credit",
            "withdrawal", "deposit", "bill payment", "electronic ",
        ];
        if generic_prefixes
            .iter()
            .any(|p| lower == *p || lower.starts_with(p))
        {
            continue;
        }
        // User-dismissed cluster ("this isn't a subscription"). Skip
        // the merchant entirely — the dismissed key matches whatever
        // the detector clustered on at the time, so re-running won't
        // re-surface it unless the underlying tx data changed in a
        // way that produces a different key.
        if ignored.contains(&key_part) {
            continue;
        }
        let band = amount.round() as i64;
        let key = format!("{}::{}", key_part, band);
        let display_name = display_merchant(
            user_description.as_deref(),
            counterparty_name.as_deref(),
            merchant_name.as_deref(),
            payment_payee.as_deref(),
            &description,
        );
        let cluster = clusters.entry(key).or_insert_with(|| Cluster {
            merchant: display_name.clone(),
            currency: currency.clone(),
            events: Vec::new(),
            by_account: HashMap::new(),
        });
        cluster.events.push((date, amount));
        let tally = cluster.by_account.entry(account_id).or_insert(AccountTally {
            display: account_name,
            count: 0,
            total_native: 0.0,
        });
        tally.count += 1;
        tally.total_native += amount;
    }

    let today = chrono::Utc::now().date_naive();
    let mut out = Vec::new();
    for cluster in clusters.values_mut() {
        // Most-recent first; we already pulled rows ORDER BY date DESC
        // but sort again for safety.
        cluster
            .events
            .sort_by(|a, b| b.0.cmp(&a.0));

        if cluster.events.len() < 3 {
            continue;
        }
        let last_charge = cluster.events[0].0;
        let days_since = (today - last_charge).num_days();
        // Either "active" (last charge ≤ 90 days) or "cancelled" (between
        // 91 days and 18 months ago). Clusters older than that are
        // unlikely to be useful audit signal, so drop them entirely.
        let status: &'static str = if days_since <= 90 {
            "active"
        } else if days_since <= 548 {
            "cancelled"
        } else {
            continue;
        };
        // Median gap between consecutive charges. Bail unless median is
        // in the recurring-cadence band.
        let mut gaps: Vec<i64> = cluster
            .events
            .windows(2)
            .map(|w| (w[0].0 - w[1].0).num_days().abs())
            .collect();
        gaps.sort();
        let median_gap = gaps[gaps.len() / 2];
        if median_gap < 5 || median_gap > 62 {
            continue;
        }
        let total: f64 = cluster.events.iter().map(|(_, a)| a).sum();
        let months_observed = (cluster.events.len() as f64 * median_gap as f64) / 30.4375;
        let avg_per_month = if months_observed > 0.0 {
            total / months_observed
        } else {
            total
        };
        let monthly_usd = if cluster.currency.eq_ignore_ascii_case("USD") {
            avg_per_month
        } else if cluster.currency.eq_ignore_ascii_case("MXN") {
            match fx_mxn {
                Some(r) => avg_per_month / r,
                None => 0.0,
            }
        } else {
            avg_per_month
        };
        let last_amount = cluster.events[0].1;

        // Per-account slices: sorted descending by spend, with the
        // share normalised against the cluster total so the frontend
        // doesn't have to redo the math. `total` here is the sum of
        // every tally — same number as `cluster.events.iter().map.sum()`
        // since we feed both from the same loop, but recomputed
        // independently to keep the slice serialisation self-contained.
        let cluster_total: f64 = cluster
            .by_account
            .values()
            .map(|t| t.total_native)
            .sum::<f64>()
            .max(f64::MIN_POSITIVE);
        let mut by_account: Vec<SubscriptionAccountSlice> = cluster
            .by_account
            .values()
            .map(|t| SubscriptionAccountSlice {
                account_name: t.display.clone(),
                occurrences: t.count as i32,
                total_native: t.total_native,
                share: t.total_native / cluster_total,
            })
            .collect();
        by_account.sort_by(|a, b| {
            b.total_native
                .partial_cmp(&a.total_native)
                .unwrap_or(std::cmp::Ordering::Equal)
        });

        out.push(DetectedSubscription {
            merchant: cluster.merchant.clone(),
            monthly_usd,
            cadence_days: median_gap as i32,
            last_charge_date: last_charge.to_string(),
            last_amount,
            currency: cluster.currency.clone(),
            occurrences: cluster.events.len() as i32,
            status,
            by_account,
        });
    }

    // Active first (sorted by monthly spend), then cancelled (sorted by
    // recency of last charge — most recently stopped is most actionable).
    out.sort_by(|a, b| {
        match (a.status, b.status) {
            ("active", "cancelled") => std::cmp::Ordering::Less,
            ("cancelled", "active") => std::cmp::Ordering::Greater,
            ("cancelled", "cancelled") => b.last_charge_date.cmp(&a.last_charge_date),
            _ => b
                .monthly_usd
                .partial_cmp(&a.monthly_usd)
                .unwrap_or(std::cmp::Ordering::Equal),
        }
    });
    out.truncate(40);
    Json(out)
}

// ---------- Cross-currency cash-transfer linking ----------

#[derive(Serialize)]
struct FxTransferEntry {
    id: String,
    source_tx_id: String,
    dest_tx_id: String,
    source_amount: f64,
    source_currency: String,
    dest_amount: f64,
    dest_currency: String,
    implied_fx_rate: f64,
    detection_confidence: i32,
    user_confirmed: bool,
    detected_at: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    matched_keyword: Option<String>,
    /// Display labels for the source/dest legs — the frontend prefers
    /// these over re-deriving them from the transactions list, which
    /// it might not have loaded yet on a deep-link.
    source_label: String,
    dest_label: String,
    /// Date strings (YYYY-MM-DD) so a phone-width modal doesn't have
    /// to format a full timestamp.
    source_date: String,
    dest_date: String,
    /// Best-effort spot USD→MXN rate near the source-date, so the
    /// frontend can render "Wise gave you 19.40, market was 19.62"
    /// without round-tripping back for a /fx/historical lookup per
    /// row. Absent when no rate within ±7 days of the source date
    /// is available (early-bootstrap cases).
    #[serde(skip_serializing_if = "Option::is_none")]
    spot_fx_rate: Option<f64>,
}

/// List every detected (and user-confirmed) cross-currency cash
/// transfer for the caller. Used by the transactions detail modal to
/// show "Linked to" when the user is looking at one leg of a pair.
async fn list_fx_transfers(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<FxTransferEntry>> {
    // We always denominate the "spot rate" as USD→MXN since that's
    // the only currency pair the rates table currently tracks. The
    // frontend handles the direction inversion when the transfer
    // happens to be MXN→USD. Lookup window is ±7 days from the
    // source date — daily rates can be missing on weekends/holidays
    // and 7 days is well inside Wise's typical settlement variance.
    let rows = sqlx::query(
        r#"
        SELECT
            f.id, f.source_tx_id, f.dest_tx_id,
            f.source_amount, f.source_currency,
            f.dest_amount, f.dest_currency,
            f.implied_fx_rate, f.detection_confidence,
            f.user_confirmed, f.detected_at, f.matched_keyword,
            ts.description AS source_desc,
            COALESCE(ts.user_description, ts.counterparty_name, ts.merchant_name, ts.description) AS source_label,
            ts.date AS source_date,
            COALESCE(td.user_description, td.counterparty_name, td.merchant_name, td.description) AS dest_label,
            td.date AS dest_date,
            (
                SELECT er.rate
                FROM exchange_rates er
                WHERE er.base_currency = 'USD'
                  AND er.target_currency = 'MXN'
                  AND er.recorded_at::date BETWEEN ts.date - INTEGER '7'
                                              AND ts.date + INTEGER '7'
                -- date - date is integer (days); ABS over that picks the
                -- nearest row to ts.date without dragging EPOCH/INTERVAL
                -- through type coercion (which silently turned the
                -- subquery into a Postgres error for non-empty pairs).
                ORDER BY ABS(er.recorded_at::date - ts.date) ASC
                LIMIT 1
            ) AS spot_fx_rate
        FROM cash_fx_transfers f
        JOIN transactions ts ON ts.id = f.source_tx_id
        JOIN transactions td ON td.id = f.dest_tx_id
        WHERE f.user_id = $1
        ORDER BY f.detected_at DESC
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| FxTransferEntry {
                id: r.get::<uuid::Uuid, _>("id").to_string(),
                source_tx_id: r.get::<uuid::Uuid, _>("source_tx_id").to_string(),
                dest_tx_id: r.get::<uuid::Uuid, _>("dest_tx_id").to_string(),
                source_amount: r
                    .try_get::<rust_decimal::Decimal, _>("source_amount")
                    .ok()
                    .and_then(|d| d.to_string().parse().ok())
                    .unwrap_or(0.0),
                source_currency: r.get("source_currency"),
                dest_amount: r
                    .try_get::<rust_decimal::Decimal, _>("dest_amount")
                    .ok()
                    .and_then(|d| d.to_string().parse().ok())
                    .unwrap_or(0.0),
                dest_currency: r.get("dest_currency"),
                implied_fx_rate: r
                    .try_get::<rust_decimal::Decimal, _>("implied_fx_rate")
                    .ok()
                    .and_then(|d| d.to_string().parse().ok())
                    .unwrap_or(0.0),
                detection_confidence: r
                    .try_get::<i16, _>("detection_confidence")
                    .unwrap_or(0) as i32,
                user_confirmed: r.try_get("user_confirmed").unwrap_or(false),
                detected_at: r
                    .try_get::<chrono::DateTime<chrono::Utc>, _>("detected_at")
                    .map(|d| d.to_rfc3339())
                    .unwrap_or_default(),
                matched_keyword: r
                    .try_get::<Option<String>, _>("matched_keyword")
                    .ok()
                    .flatten(),
                source_label: r.try_get::<Option<String>, _>("source_label").ok().flatten()
                    .unwrap_or_else(|| r.try_get::<String, _>("source_desc").unwrap_or_default()),
                dest_label: r.try_get::<Option<String>, _>("dest_label").ok().flatten()
                    .unwrap_or_default(),
                source_date: r
                    .try_get::<chrono::NaiveDate, _>("source_date")
                    .map(|d| d.to_string())
                    .unwrap_or_default(),
                dest_date: r
                    .try_get::<chrono::NaiveDate, _>("dest_date")
                    .map(|d| d.to_string())
                    .unwrap_or_default(),
                spot_fx_rate: r
                    .try_get::<Option<rust_decimal::Decimal>, _>("spot_fx_rate")
                    .ok()
                    .flatten()
                    .and_then(|d| d.to_string().parse().ok()),
            })
            .collect(),
    )
}

#[derive(Serialize)]
struct DetectFxResponse {
    checked: usize,
    inserted: usize,
}

/// Run the FX-transfer detector for the caller. Idempotent — repeated
/// runs only ever ADD new links (the unique index dedupes), never
/// re-evaluate confirmed pairs. The detection lives in
/// `services::fx_transfer_link::detect_for_user`; this endpoint is
/// the user-triggered entry point. The sync engine could also call
/// it at the end of every sync, but that's an iteration we defer
/// until users actually find the manual button annoying.
async fn detect_fx_transfers(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<DetectFxResponse> {
    match crate::services::fx_transfer_link::detect_for_user(&state.db, ctx.user_id).await {
        Ok((checked, inserted)) => Json(DetectFxResponse { checked, inserted }),
        Err(e) => {
            error!("fx-transfer detection failed for user {}: {}", ctx.user_id, e);
            Json(DetectFxResponse {
                checked: 0,
                inserted: 0,
            })
        }
    }
}

/// User-confirm an auto-detected link. Sets `user_confirmed = true`
/// so future detection runs leave it alone, and so the UI can show
/// a different visual state.
async fn confirm_fx_transfer(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    axum::extract::Path(id): axum::extract::Path<uuid::Uuid>,
) -> StatusCode {
    let result = sqlx::query(
        "UPDATE cash_fx_transfers SET user_confirmed = TRUE \
         WHERE id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;
    match result {
        Ok(r) if r.rows_affected() == 1 => {
            state
                .realtime
                .publish(
                    ctx.user_id,
                    crate::services::realtime::RealtimeEvent::TransactionsChanged,
                )
                .await;
            StatusCode::OK
        }
        Ok(_) => StatusCode::NOT_FOUND,
        Err(e) => {
            error!("confirm_fx_transfer failed for {}: {}", id, e);
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

/// Remove a link entirely. The two underlying transactions stay
/// put. The pair is ALSO recorded in `dismissed_fx_pairs` so the
/// next detector run won't re-propose it — the user already said
/// "not a transfer." Restoring is a per-row Delete in the Hidden
/// Items screen.
async fn unlink_fx_transfer(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    axum::extract::Path(id): axum::extract::Path<uuid::Uuid>,
) -> StatusCode {
    let mut tx = match state.db.begin().await {
        Ok(t) => t,
        Err(e) => {
            error!("unlink_fx_transfer begin failed for {}: {}", id, e);
            return StatusCode::INTERNAL_SERVER_ERROR;
        }
    };

    // Capture the underlying tx ids BEFORE deleting so we can land
    // the dismissal row. RETURNING saves a separate SELECT and
    // keeps both operations in one statement-level snapshot.
    let row = match sqlx::query(
        "DELETE FROM cash_fx_transfers WHERE id = $1 AND user_id = $2 \
         RETURNING source_tx_id, dest_tx_id",
    )
    .bind(id)
    .bind(ctx.user_id)
    .fetch_optional(&mut *tx)
    .await
    {
        Ok(Some(r)) => r,
        Ok(None) => return StatusCode::NOT_FOUND,
        Err(e) => {
            error!("unlink_fx_transfer delete failed for {}: {}", id, e);
            return StatusCode::INTERNAL_SERVER_ERROR;
        }
    };

    let source_tx_id: uuid::Uuid = match row.try_get("source_tx_id") {
        Ok(v) => v,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR,
    };
    let dest_tx_id: uuid::Uuid = match row.try_get("dest_tx_id") {
        Ok(v) => v,
        Err(_) => return StatusCode::INTERNAL_SERVER_ERROR,
    };

    if let Err(e) = sqlx::query(
        "INSERT INTO dismissed_fx_pairs (user_id, source_tx_id, dest_tx_id) \
         VALUES ($1, $2, $3) ON CONFLICT DO NOTHING",
    )
    .bind(ctx.user_id)
    .bind(source_tx_id)
    .bind(dest_tx_id)
    .execute(&mut *tx)
    .await
    {
        error!("unlink_fx_transfer dismiss insert failed for {}: {}", id, e);
        return StatusCode::INTERNAL_SERVER_ERROR;
    }

    if let Err(e) = tx.commit().await {
        error!("unlink_fx_transfer commit failed for {}: {}", id, e);
        return StatusCode::INTERNAL_SERVER_ERROR;
    }

    state
        .realtime
        .publish(
            ctx.user_id,
            crate::services::realtime::RealtimeEvent::TransactionsChanged,
        )
        .await;
    StatusCode::NO_CONTENT
}

#[derive(Serialize)]
struct DismissedFxPair {
    /// Stable id for the dismissal row — pass back as a DELETE
    /// path parameter to restore.
    id: String,
    /// Display labels for the two legs of the dismissed transfer.
    /// Picked from the underlying transactions list so renames in
    /// the tx list propagate here without a separate sync step.
    source_label: String,
    dest_label: String,
    source_date: String,
    dest_date: String,
    /// Native amount + currency for each leg. The frontend uses
    /// these to render the "Wise USD 1000 → MXN 20000" line.
    source_amount: f64,
    source_currency: String,
    dest_amount: f64,
    dest_currency: String,
    dismissed_at: String,
}

/// List every FX-pair the caller has permanently dismissed. Used by
/// the Hidden Items screen. Joins to `transactions` for the display
/// labels — if either underlying tx has been deleted (Plaid
/// TRANSACTIONS_REMOVED, manual cleanup) the dismissal row was
/// already cascaded away by the FKs, so a missing-tx row never
/// appears here.
async fn list_dismissed_fx_pairs(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<DismissedFxPair>> {
    let rows = sqlx::query(
        r#"
        SELECT d.id, d.dismissed_at,
               s.date AS source_date,
               s.amount AS source_amount,
               s.currency AS source_currency,
               COALESCE(NULLIF(s.user_description, ''), s.description) AS source_label,
               de.date AS dest_date,
               de.amount AS dest_amount,
               de.currency AS dest_currency,
               COALESCE(NULLIF(de.user_description, ''), de.description) AS dest_label
        FROM dismissed_fx_pairs d
        JOIN transactions s  ON s.id  = d.source_tx_id
        JOIN transactions de ON de.id = d.dest_tx_id
        WHERE d.user_id = $1
        ORDER BY d.dismissed_at DESC
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| DismissedFxPair {
                id: r.get::<uuid::Uuid, _>("id").to_string(),
                source_label: r.try_get("source_label").unwrap_or_default(),
                dest_label: r.try_get("dest_label").unwrap_or_default(),
                source_date: r
                    .try_get::<chrono::NaiveDate, _>("source_date")
                    .map(|d| d.to_string())
                    .unwrap_or_default(),
                dest_date: r
                    .try_get::<chrono::NaiveDate, _>("dest_date")
                    .map(|d| d.to_string())
                    .unwrap_or_default(),
                source_amount: r
                    .try_get::<rust_decimal::Decimal, _>("source_amount")
                    .ok()
                    .and_then(|d| d.to_string().parse().ok())
                    .unwrap_or(0.0),
                source_currency: r.try_get("source_currency").unwrap_or_default(),
                dest_amount: r
                    .try_get::<rust_decimal::Decimal, _>("dest_amount")
                    .ok()
                    .and_then(|d| d.to_string().parse().ok())
                    .unwrap_or(0.0),
                dest_currency: r.try_get("dest_currency").unwrap_or_default(),
                dismissed_at: r
                    .try_get::<chrono::DateTime<chrono::Utc>, _>("dismissed_at")
                    .map(|d| d.to_rfc3339())
                    .unwrap_or_default(),
            })
            .collect(),
    )
}

/// Restore a previously-dismissed FX pair — deletes the row so the
/// next detector run is free to surface the pair again. Idempotent:
/// returns 204 even when the row is already gone.
async fn restore_dismissed_fx_pair(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    axum::extract::Path(id): axum::extract::Path<uuid::Uuid>,
) -> StatusCode {
    let result = sqlx::query(
        "DELETE FROM dismissed_fx_pairs WHERE id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await;
    match result {
        Ok(_) => StatusCode::NO_CONTENT,
        Err(e) => {
            error!("restore_dismissed_fx_pair failed for {}: {}", id, e);
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

#[derive(Deserialize)]
struct IgnoreSubscriptionRequest {
    /// Lowercased + trimmed merchant key the user wants the detector
    /// to stop showing. Mirrors the key the detector itself clusters
    /// on, so the frontend can send the same `merchant` value it
    /// rendered.
    merchant: String,
}

/// Mark a detected-subscription cluster as "not a subscription."
/// Lands a row in `ignored_subscription_merchants`; subsequent
/// detector runs skip the key entirely. The user can re-confirm by
/// just letting the cluster come back (we don't expose an
/// "unignore" today — if you actually need to undo, delete the row
/// directly from the DB).
async fn ignore_subscription(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Json(req): Json<IgnoreSubscriptionRequest>,
) -> StatusCode {
    let key = req.merchant.trim().to_lowercase();
    if key.is_empty() {
        return StatusCode::BAD_REQUEST;
    }
    let result = sqlx::query(
        "INSERT INTO ignored_subscription_merchants (user_id, merchant_key) \
         VALUES ($1, $2) ON CONFLICT DO NOTHING",
    )
    .bind(ctx.user_id)
    .bind(&key)
    .execute(&state.db)
    .await;
    match result {
        Ok(_) => StatusCode::NO_CONTENT,
        Err(e) => {
            error!("ignore_subscription failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}

#[derive(Serialize)]
struct IgnoredSubscription {
    merchant_key: String,
    ignored_at: String,
}

/// List every dismissed subscription merchant for this user. Used by
/// the "Manage hidden subscriptions" panel so the user can undo a
/// previous dismiss without manually editing the DB.
async fn list_ignored_subscriptions(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<IgnoredSubscription>> {
    let rows = sqlx::query(
        "SELECT merchant_key, ignored_at FROM ignored_subscription_merchants \
         WHERE user_id = $1 ORDER BY ignored_at DESC",
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .filter_map(|r| {
                let merchant_key = r.try_get::<String, _>("merchant_key").ok()?;
                let ignored_at = r
                    .try_get::<chrono::DateTime<chrono::Utc>, _>("ignored_at")
                    .ok()
                    .map(|d| d.to_rfc3339())
                    .unwrap_or_default();
                Some(IgnoredSubscription {
                    merchant_key,
                    ignored_at,
                })
            })
            .collect(),
    )
}

/// Un-ignore: delete the row so the detector can re-surface this
/// merchant on its next run. Idempotent — returns 204 either way
/// (deleting a non-existent ignore is a no-op).
async fn unignore_subscription(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    axum::extract::Path(merchant_key): axum::extract::Path<String>,
) -> StatusCode {
    let key = merchant_key.trim().to_lowercase();
    if key.is_empty() {
        return StatusCode::BAD_REQUEST;
    }
    let result = sqlx::query(
        "DELETE FROM ignored_subscription_merchants \
         WHERE user_id = $1 AND merchant_key = $2",
    )
    .bind(ctx.user_id)
    .bind(&key)
    .execute(&state.db)
    .await;
    match result {
        Ok(_) => StatusCode::NO_CONTENT,
        Err(e) => {
            error!("unignore_subscription failed: {e}");
            StatusCode::INTERNAL_SERVER_ERROR
        }
    }
}
