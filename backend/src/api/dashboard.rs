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

use crate::api::session::{internal, ApiError, AuthContext};
use crate::services::tax::USD_MXN_ROW_RATE_SQL;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/overview", get(dashboard_overview))
        .route("/net-worth-history", get(net_worth_history))
        .route("/portfolio-value-history", get(portfolio_value_history))
        .route("/holdings", get(holdings))
        .route("/holdings/export", get(export_holdings_csv))
        .route("/holdings/lots/export", get(export_lots_csv))
        .route("/holdings/dividends", get(portfolio_dividends))
        .route("/dividends/{symbol}", get(dividend_detail))
        .route("/instruments/{symbol}", get(instrument_detail))
        // Round 3 (contract C3-A): pin/clear a per-(user, symbol) asset-class
        // override. Same auth/CSRF conventions as the sibling mutations.
        .route(
            "/instruments/{symbol}/asset-class",
            axum::routing::put(set_asset_class_override),
        )
        .route("/allocation", get(asset_allocation))
        .route("/trends", get(cash_flow_trends))
        .route("/spending-by-category", get(spending_by_category))
        .route("/spending-insights", get(spending_insights))
        .route("/realized-gains", get(realized_gains))
        .route("/realized-gains/export", get(export_realized_gains_csv))
        .route("/account-balance-history", get(account_balance_history))
        .route("/emergency-fund", get(emergency_fund))
        .route("/benchmark", get(benchmark_series))
        .route("/benchmark-comparison", get(benchmark_comparison))
        .route("/portfolio-twr", get(portfolio_twr))
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

/// Latest USD->MXN exchange rate plus a staleness flag.
///
/// The numeric fallback (`FX_FALLBACK_USD_MXN`) is only ever returned when no
/// rate row exists at all; in every other case `rate` is the real recorded
/// rate and `stale` says whether that row is older than 7 days. Callers that
/// surface MXN-converted figures should propagate `stale` so the UI can badge
/// them as approximate instead of silently trusting a possibly-drifted number.
pub(crate) struct FxRateInfo {
    pub rate: f64,
    /// True when the rate is MISSING (fallback used) or older than 7 days.
    pub stale: bool,
}

/// Hard fallback used only when the `exchange_rates` table has no USD/MXN row.
/// Deliberately flagged `stale` so it can never pass for a live rate.
pub(crate) const FX_FALLBACK_USD_MXN: f64 = 20.0;

/// Fetch the freshest USD->MXN rate and decide whether it's trustworthy.
///
/// One query, used by every endpoint that converts MXN→USD, so the
/// missing/stale policy lives in exactly one place.
pub(crate) async fn latest_usd_mxn_rate(db: &sqlx::PgPool) -> FxRateInfo {
    // A user-entered 'manual' override outranks the automated 'api' rows so a
    // corrected rate wins over a stale/bad upstream fetch (which would otherwise
    // collapse to FX_FALLBACK_USD_MXN). Within each source, freshest first.
    let row = sqlx::query(
        "SELECT rate, recorded_at FROM exchange_rates \
         WHERE base_currency = 'USD' AND target_currency = 'MXN' \
         ORDER BY (source = 'manual') DESC, recorded_at DESC LIMIT 1",
    )
    .fetch_optional(db)
    .await
    .ok()
    .flatten();

    match row {
        Some(r) => {
            let rate = r
                .try_get::<rust_decimal::Decimal, _>("rate")
                .ok()
                .and_then(|d| d.to_string().parse::<f64>().ok())
                .filter(|v| *v > 0.0)
                .unwrap_or(FX_FALLBACK_USD_MXN);
            let recorded_at = r.try_get::<chrono::DateTime<chrono::Utc>, _>("recorded_at");
            let stale = match recorded_at {
                Ok(ts) => {
                    let age = chrono::Utc::now().signed_duration_since(ts);
                    age > chrono::Duration::days(7)
                }
                // Couldn't read the timestamp — treat as stale rather than
                // silently trusting it.
                Err(_) => true,
            };
            if stale {
                tracing::warn!(
                    fx_rate = rate,
                    "USD/MXN exchange rate is stale (older than 7 days); MXN figures flagged approximate"
                );
            }
            FxRateInfo { rate, stale }
        }
        None => {
            tracing::warn!(
                fx_rate = FX_FALLBACK_USD_MXN,
                "no USD/MXN exchange rate found; falling back to {FX_FALLBACK_USD_MXN} and flagging stale"
            );
            FxRateInfo {
                rate: FX_FALLBACK_USD_MXN,
                stale: true,
            }
        }
    }
}

/// Shared WHERE-clause fragment for the trailing-12-month "genuine external
/// cash flow" aggregations. Both the emergency-fund spend (this module) and
/// `projections::projection_defaults` filter the identical set: split parents,
/// internal TRANSFER_* legs, credit-card payments, lending disbursement /
/// repayment legs, AND confirmed/high-confidence cash↔FX transfer pairs.
///
/// ⚠ Keep this in lockstep with the consumers. If the exclusion set ever needs
/// to change, change it HERE so the emergency-fund "months of runway" and the
/// projection "monthly contribution" can never silently disagree. Cross-ref:
///   - `dashboard::emergency_fund` (spend side)
///   - `crate::api::projections::projection_defaults` (income + spend side)
///
/// The fragment assumes the query aliases `transactions` as `t`, joins
/// `accounts a`, and binds `user_id` as `$1`. It does NOT include the
/// `t.amount < 0` sign filter — callers add that themselves so the same
/// fragment serves the spend-only and income+spend queries.
/// Effective category for cash-flow classification: a user re-categorization
/// (`user_category`) overrides the raw imported/synced `category`, matching how
/// the tax income predicate (`services::tax` INCOME_PREDICATE_SQL) and the
/// spending labels resolve it. The query must alias transactions as `t`.
pub(crate) const EFFECTIVE_CATEGORY_SQL: &str =
    "UPPER(COALESCE(NULLIF(t.user_category, ''), t.category, ''))";

/// Category values that are neither household income nor spending — internal
/// transfers (Plaid PFC `TRANSFER_IN/OUT` + the app's manual `Transfer`) and
/// securities/investment moves. Use as
/// `{EFFECTIVE_CATEGORY_SQL} NOT IN {NON_CASHFLOW_CATEGORIES_SQL}`.
pub(crate) const NON_CASHFLOW_CATEGORIES_SQL: &str =
    "('TRANSFER_IN', 'TRANSFER_OUT', 'TRANSFER', 'INVESTMENT')";

/// Row-level anti-joins that keep a transaction out of BOTH income and spending
/// regardless of sign: a credit-card payment leg or a tax refund (a return of
/// the user's own money); a positive inflow into a liability/credit-card
/// account (payment / refund / reward — card purchases, being negative, still
/// count as spend); a split parent; a personal-loan disbursement/repayment leg;
/// or a confirmed cross-currency FX transfer pair. The transfer/investment
/// CATEGORY exclusion is applied SEPARATELY (via `EFFECTIVE_CATEGORY_SQL`) so
/// `cash_flow_trends` can still bucket those rows into invested/transferred.
/// The query must alias transactions `t` and accounts `a`.
pub(crate) const CASHFLOW_ROW_ANTI_JOINS_SQL: &str = r#"
          AND COALESCE(t.category_detailed, '') NOT IN ('LOAN_PAYMENTS_CREDIT_CARD_PAYMENT', 'INCOME_TAX_REFUND')
          AND NOT (t.amount > 0 AND is_liability_account_type(a.account_type))
          AND NOT EXISTS (SELECT 1 FROM transactions tc WHERE tc.parent_id = t.id)
          AND NOT EXISTS (SELECT 1 FROM loans l WHERE l.disbursement_tx_id = t.id)
          AND NOT EXISTS (SELECT 1 FROM loan_payments lp WHERE lp.actual_tx_id = t.id)
          AND NOT EXISTS (
              SELECT 1 FROM cash_fx_transfers f
              WHERE (f.source_tx_id = t.id OR f.dest_tx_id = t.id)
                AND (f.user_confirmed OR f.detection_confidence >= 70)
          )
"#;

/// The full WHERE-clause exclusion set for a trailing 12-month cash-flow sum —
/// used by the FIRE projection defaults and the emergency-fund runway. Binds
/// `$1` = user_id. `cash_flow_trends` deliberately does NOT use this: it needs
/// the excluded transfer/investment rows to build its invested/transferred
/// buckets, so it applies the same shared fragments inside its CASEs / WHERE.
pub(crate) fn trailing_cashflow_exclusions_sql() -> String {
    format!(
        "\n          AND t.date >= CURRENT_DATE - INTERVAL '12 months'\n          AND t.user_id = $1\n          AND {EFFECTIVE_CATEGORY_SQL} NOT IN {NON_CASHFLOW_CATEGORIES_SQL}{CASHFLOW_ROW_ANTI_JOINS_SQL}"
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
    let (currency_rows, fx_info, accounts_rows) = tokio::join!(
        sqlx::query(
            r#"
            SELECT currency,
                   COALESCE(SUM(CASE WHEN NOT is_liability_account_type(account_type)
                                     THEN current_balance ELSE 0 END), 0) as assets,
                   COALESCE(SUM(CASE WHEN is_liability_account_type(account_type)
                                     THEN ABS(current_balance) ELSE 0 END), 0) as liabilities
            FROM accounts
            WHERE user_id = $1 AND archived_at IS NULL
            GROUP BY currency
            "#
        ).bind(ctx.user_id).fetch_all(&state.db),
        // FX rate + staleness flag (missing or >7 days old). Replaces the old
        // silent 20.0 fallback so MXN-converted figures can be badged.
        latest_usd_mxn_rate(&state.db),
        sqlx::query(
            r#"
            SELECT a.id, a.name, a.nickname, a.account_type, a.current_balance, a.currency,
                   i.name as institution_name, i.integration_type, a.ticker_symbol, a.crypto_amount,
                   a.clabe, a.holder_name,
                   -- Freshness of import-only accounts: last import confirm /
                   -- manual balance edit (updated_at) or last transaction
                   -- INSERT, whichever is later (GREATEST skips NULLs). NULL
                   -- for synced integrations — their staleness is the sync
                   -- status, and computing the LATERAL there is wasted work.
                   CASE WHEN i.integration_type = 'manual'
                        THEN GREATEST(a.updated_at, tx.last_tx_at)
                   END AS last_data_at
            FROM accounts a
            JOIN institutions i ON a.institution_id = i.id
            LEFT JOIN LATERAL (
                SELECT MAX(t.created_at) AS last_tx_at
                FROM transactions t
                WHERE t.account_id = a.id AND t.user_id = $1
                  AND i.integration_type = 'manual'
            ) tx ON TRUE
            WHERE a.user_id = $1 AND a.archived_at IS NULL
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
    let fx_rate = fx_info.rate;
    let fx_stale = fx_info.stale;

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
            WHERE user_id = $2 AND archived_at IS NULL
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
            WHERE a.user_id = $2 AND a.archived_at IS NULL
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
            clabe: r.try_get::<Option<String>, _>("clabe").ok().flatten(),
            holder_name: r.try_get::<Option<String>, _>("holder_name").ok().flatten(),
            integration_type: r.try_get::<String, _>("integration_type").unwrap_or_default(),
            last_data_at: r
                .try_get::<Option<chrono::DateTime<chrono::Utc>>, _>("last_data_at")
                .ok()
                .flatten()
                .map(|d| d.to_rfc3339()),
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
        fx_rate_used: fx_rate,
        fx_stale,
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
    // Per-account snapshot rows, carried forward — NOT a naive per-date
    // aggregate. Accounts snapshot on different days (an HSA that syncs
    // weekly, a Plaid card that syncs daily), so a date's raw GROUP BY only
    // covers the accounts that happened to snapshot that day. That dropped
    // an infrequently-synced institution out of `by_institution` on most
    // dates, and the movers attribution then read its full balance as
    // "growth from zero" at the baseline. Same fix as portfolio_value_history
    // above: carry each account's most recent snapshot forward, so every
    // emitted point values every account seen so far at its last-known
    // balance. `COALESCE(name, 'Unknown')` keeps the JSON contract stable.
    let rows = sqlx::query(
        r#"
        SELECT bs.as_of_date AS d,
               bs.account_id AS account_id,
               COALESCE(bs.balance_usd, 0)::float8 AS balance_usd,
               is_liability_account_type(a.account_type) AS is_liability,
               COALESCE(NULLIF(i.name, ''), 'Unknown') AS institution_name
        FROM balance_snapshots bs
        JOIN accounts a ON bs.account_id = a.id
        JOIN institutions i ON a.institution_id = i.id
        WHERE bs.user_id = $1 AND a.archived_at IS NULL
        ORDER BY bs.as_of_date ASC, bs.id ASC
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    // account_id -> its last-known (balance_usd, is_liability, institution).
    struct AcctState {
        balance_usd: f64,
        is_liability: bool,
        institution: String,
    }
    let mut latest: HashMap<uuid::Uuid, AcctState> = HashMap::new();
    let mut points: Vec<NetWorthPoint> = Vec::new();
    let mut current_date: Option<chrono::NaiveDate> = None;

    // Aggregate the carried-forward account states into one point.
    let flush = |date: Option<chrono::NaiveDate>,
                 latest: &HashMap<uuid::Uuid, AcctState>,
                 points: &mut Vec<NetWorthPoint>| {
        let Some(d) = date else { return };
        let mut total_assets = 0.0;
        let mut total_liabilities = 0.0;
        let mut by_institution: HashMap<String, f64> = HashMap::new();
        for st in latest.values() {
            // Institution net = assets − liabilities (matches the previous
            // per-inst aggregation: liabilities counted as ABS).
            let contribution = if st.is_liability {
                total_liabilities += st.balance_usd.abs();
                -st.balance_usd.abs()
            } else {
                total_assets += st.balance_usd;
                st.balance_usd
            };
            *by_institution.entry(st.institution.clone()).or_insert(0.0) += contribution;
        }
        points.push(NetWorthPoint {
            date: d.to_string(),
            total_assets,
            total_liabilities,
            net_worth: total_assets - total_liabilities,
            by_institution,
        });
    };

    for r in &rows {
        let Ok(d) = r.try_get::<chrono::NaiveDate, _>("d") else {
            continue;
        };
        let Ok(account_id) = r.try_get::<uuid::Uuid, _>("account_id") else {
            continue;
        };
        if current_date != Some(d) {
            flush(current_date, &latest, &mut points);
            current_date = Some(d);
        }
        // Duplicate snapshots for the same account+date: last row wins
        // (rows are id-ordered), rather than double-counting.
        latest.insert(
            account_id,
            AcctState {
                balance_usd: r.try_get("balance_usd").unwrap_or(0.0),
                is_liability: r.try_get("is_liability").unwrap_or(false),
                institution: r
                    .try_get::<String, _>("institution_name")
                    .unwrap_or_else(|_| "Unknown".to_string()),
            },
        );
    }
    flush(current_date, &latest, &mut points);

    Json(points)
}

#[derive(Serialize)]
struct PortfolioValuePoint {
    date: String,
    value_usd: f64,
}

/// Investment portfolio value over time: per balance-snapshot date, the total
/// USD value of accounts that actually hold investments (any account with at
/// least one `holdings` row). This is deliberately NOT net worth — it excludes
/// cash, liabilities, and non-investment accounts — and it is NOT indexed
/// against any benchmark (see BenchmarkCard: indexing net-worth-from-~0 to the
/// S&P reports absurd returns by conflating contributions with market gains).
/// The honest "vs market" read is the contribution-weighted comparison.
async fn portfolio_value_history(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<PortfolioValuePoint>> {
    // Per-account snapshot rows, NOT a naive per-date SUM. Accounts snapshot
    // on different days (a partial sync refreshes one institution), so a
    // date's raw sum only covers the accounts that happened to snapshot that
    // day — the trailing point after a partial sync read as one account's
    // balance and the performance headline showed e.g. $299k for a $380k
    // portfolio. Instead we carry each account's last-known balance forward:
    // every emitted point is the sum over all accounts seen so far, valuing
    // each at its most recent snapshot on-or-before that date.
    let rows = sqlx::query(
        r#"
        SELECT bs.as_of_date AS d,
               bs.account_id AS account_id,
               COALESCE(bs.balance_usd, 0)::float8 AS value_usd
        FROM balance_snapshots bs
        JOIN accounts a ON bs.account_id = a.id
        WHERE bs.user_id = $1 AND a.archived_at IS NULL
          AND EXISTS (SELECT 1 FROM holdings h
                      WHERE h.account_id = a.id AND h.deleted_at IS NULL)
        ORDER BY bs.as_of_date ASC, bs.id ASC
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let mut latest: std::collections::HashMap<uuid::Uuid, f64> =
        std::collections::HashMap::new();
    let mut points: Vec<PortfolioValuePoint> = Vec::new();
    let mut current_date: Option<chrono::NaiveDate> = None;

    let flush = |date: Option<chrono::NaiveDate>,
                     latest: &std::collections::HashMap<uuid::Uuid, f64>,
                     points: &mut Vec<PortfolioValuePoint>| {
        if let Some(d) = date {
            points.push(PortfolioValuePoint {
                date: d.to_string(),
                value_usd: latest.values().sum(),
            });
        }
    };

    for r in &rows {
        let Ok(d) = r.try_get::<chrono::NaiveDate, _>("d") else {
            continue;
        };
        let Ok(account_id) = r.try_get::<uuid::Uuid, _>("account_id") else {
            continue;
        };
        let value: f64 = r.try_get("value_usd").unwrap_or(0.0);
        if current_date != Some(d) {
            flush(current_date, &latest, &mut points);
            current_date = Some(d);
        }
        // Duplicate snapshots for the same account+date: last row wins
        // (rows are id-ordered), rather than double-counting a SUM.
        latest.insert(account_id, value);
    }
    flush(current_date, &latest, &mut points);

    Json(points)
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
/// Fetch + decode every active-account holding row for `user_id`, with the
/// lots-aware dual-currency cost basis. Shared by the JSON handler and the
/// CSV exporter (contract C-E) so the two can never disagree on a row.
/// Day-change fields are left `None` here; the JSON handler fills them from
/// `benchmark_prices` afterwards (contract C-B).
async fn fetch_holdings_details(
    db: &sqlx::PgPool,
    user_id: uuid::Uuid,
    fx_usd_to_mxn: f64,
) -> Vec<HoldingDetail> {
    let rows = sqlx::query(
        r#"
        SELECT h.id, h.symbol, h.name, h.quantity, h.price, h.value,
               h.cost_basis, h.currency, h.holding_type, a.account_type,
               COALESCE(NULLIF(a.nickname, ''), a.name) as account_name,
               i.name as institution_name
        FROM holdings h
        JOIN accounts a ON h.account_id = a.id
        JOIN institutions i ON a.institution_id = i.id
        WHERE h.user_id = $1 AND a.archived_at IS NULL AND h.deleted_at IS NULL
        ORDER BY h.value DESC NULLS LAST
        "#
    )
    .bind(user_id)
    .fetch_all(db)
    .await
    .unwrap_or_default();

    // Round 3 (C3-A): the user's asset-class overrides, fetched ONCE per
    // request and consulted per row below.
    let overrides = crate::services::holdings::fetch_asset_class_overrides(db, user_id).await;

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
    .bind(user_id)
    .fetch_all(db)
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

    rows.iter()
        .map(|r| {
            let id: uuid::Uuid = r.try_get("id").unwrap_or_else(|_| uuid::Uuid::nil());
            let value: f64 = r.try_get::<rust_decimal::Decimal, _>("value")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0);
            // NULL cost_basis means the institution didn't report a
            // basis (Plaid omits it for many employer plans, statement
            // imports never have one). That is "unknown", which is NOT
            // the same as a true zero-cost position — so it stays
            // Option<f64> all the way to the JSON (null), never 0.0.
            let cost_basis_native: Option<f64> = r
                .try_get::<Option<rust_decimal::Decimal>, _>("cost_basis")
                .ok()
                .flatten()
                .map(|d| d.to_string().parse().unwrap_or(0.0));
            let currency: String = r.get("currency");

            // Cost basis in USD: prefer lots (FX-aware) when present;
            // fall back to current-FX conversion of the flat basis.
            // None when neither lots nor a flat basis exist.
            let cost_basis_usd: Option<f64> = if let Some(lots) = lots_by_holding.get(&id) {
                Some(lots.iter()
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
                    .sum::<f64>())
            } else {
                cost_basis_native.map(|cb| to_usd(cb, &currency))
            };

            let value_usd = to_usd(value, &currency);
            let cost_basis_mxn = cost_basis_usd.map(|cb| cb * fx_usd_to_mxn);
            let value_mxn = value_usd * fx_usd_to_mxn;

            let symbol: String = r.get("symbol");
            let name: String = r.get("name");
            let holding_type: String = r.try_get::<String, _>("holding_type").unwrap_or_default();
            // Canonical asset class (contract C2) — the allocation endpoint
            // classifies with the same function, so a band's key always
            // matches the rows the band should filter to. A user override
            // (C3-A) outranks the heuristic in BOTH places.
            let asset_class = crate::services::holdings::effective_asset_class(
                &overrides,
                &holding_type,
                &symbol,
                &name,
            );

            HoldingDetail {
                symbol,
                name,
                quantity: r.try_get::<rust_decimal::Decimal, _>("quantity")
                    .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0),
                price: r.try_get::<rust_decimal::Decimal, _>("price")
                    .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0),
                value,
                cost_basis: cost_basis_native,
                gain_loss: cost_basis_native.map(|cb| value - cb),
                // Percent return is undefined both when the basis is
                // unknown and when it's a true zero-cost position
                // (division by zero) — null in either case.
                gain_loss_pct: cost_basis_native.and_then(|cb| {
                    if cb > 0.0 { Some(((value - cb) / cb) * 100.0) } else { None }
                }),
                value_usd,
                value_mxn,
                cost_basis_usd,
                cost_basis_mxn,
                gain_loss_usd: cost_basis_usd.map(|cb| value_usd - cb),
                gain_loss_mxn: cost_basis_mxn.map(|cb| value_mxn - cb),
                currency,
                holding_type,
                asset_class,
                account_type: r.try_get::<String, _>("account_type").unwrap_or_default(),
                account_name: r.get("account_name"),
                institution_name: r.get("institution_name"),
                // Filled by the JSON handler from `benchmark_prices` (C-B);
                // stays null for consumers that never compute it (CSV export).
                day_change_usd: None,
                day_change_pct: None,
                price_as_of: None,
                lots: lot_details_by_holding.remove(&id).unwrap_or_default(),
            }
        })
        .collect()
}

/// Day change for one holdings row, derived from its last two stored closes
/// (contract C-B). `closes` is the per-symbol result of [`latest_two_closes`]
/// — newest first. Returns `None` (all three JSON fields null, row excluded
/// from the totals + coverage numerator) for cash sleeves, symbols with fewer
/// than two stored closes, and stale series (latest close more than 7
/// calendar days before `today`).
struct RowDayChange {
    day_change_usd: f64,
    /// Percent (already ×100), native-currency-agnostic since the underlying
    /// ratio comes from the symbol's own close series.
    day_change_pct: f64,
    as_of: chrono::NaiveDate,
}

fn day_change_for_row(
    value_usd: f64,
    is_cash: bool,
    closes: Option<&[(chrono::NaiveDate, f64)]>,
    today: chrono::NaiveDate,
) -> Option<RowDayChange> {
    if is_cash {
        return None;
    }
    let closes = closes?;
    if closes.len() < 2 {
        return None;
    }
    let (d0, c0) = closes[0];
    let (_, c1) = closes[1];
    if today.signed_duration_since(d0) > chrono::Duration::days(7) {
        return None;
    }
    if c1 <= 0.0 {
        return None;
    }
    let pct = (c0 - c1) / c1;
    Some(RowDayChange {
        day_change_usd: value_usd * pct,
        day_change_pct: pct * 100.0,
        as_of: d0,
    })
}

/// Response-level day-change aggregates over the per-row results (C-B).
/// `rows` yields `(value_usd, day_change_usd, price_as_of)` per holding; a
/// row is "covered" when its day change is known.
struct DayChangeTotals {
    day_change_usd: Option<f64>,
    day_change_pct: Option<f64>,
    /// Σ value_usd of covered rows ÷ total value_usd × 100; 0 when none.
    coverage_pct: f64,
    /// Max covered close date (ISO), i.e. the freshest close the totals use.
    as_of: Option<String>,
}

fn day_change_totals<'a, I>(rows: I) -> DayChangeTotals
where
    I: Iterator<Item = (f64, Option<f64>, Option<&'a str>)>,
{
    let mut total_value = 0.0_f64;
    let mut covered_value = 0.0_f64;
    let mut prior_value = 0.0_f64;
    let mut change_sum = 0.0_f64;
    let mut any_covered = false;
    let mut as_of: Option<String> = None;
    for (value_usd, day_change_usd, price_as_of) in rows {
        total_value += value_usd;
        let Some(chg) = day_change_usd else { continue };
        any_covered = true;
        change_sum += chg;
        covered_value += value_usd;
        prior_value += value_usd - chg;
        if let Some(d) = price_as_of {
            if as_of.as_deref().is_none_or(|cur| d > cur) {
                as_of = Some(d.to_string());
            }
        }
    }
    DayChangeTotals {
        day_change_usd: any_covered.then_some(change_sum),
        day_change_pct: if any_covered && prior_value > 0.0 {
            Some(change_sum / prior_value * 100.0)
        } else {
            None
        },
        coverage_pct: if total_value > 0.0 {
            covered_value / total_value * 100.0
        } else {
            0.0
        },
        as_of,
    }
}

/// The two most recent stored closes per symbol (newest first) from
/// `benchmark_prices` — the C-B day-change data path. One query, no network:
/// the nightly refresh + TWR quote cache keep real tickers populated; opaque
/// symbols simply have no rows and degrade to null day changes.
async fn latest_two_closes(
    db: &sqlx::PgPool,
    symbols: &[String],
) -> HashMap<String, Vec<(chrono::NaiveDate, f64)>> {
    if symbols.is_empty() {
        return HashMap::new();
    }
    let rows = sqlx::query(
        r#"
        SELECT symbol, price_date, close
        FROM (
            SELECT symbol, price_date, close,
                   ROW_NUMBER() OVER (PARTITION BY symbol ORDER BY price_date DESC) AS rn
            FROM benchmark_prices
            WHERE symbol = ANY($1)
        ) ranked
        WHERE rn <= 2
        ORDER BY symbol ASC, price_date DESC
        "#,
    )
    .bind(symbols)
    .fetch_all(db)
    .await
    .unwrap_or_default();

    let mut by_symbol: HashMap<String, Vec<(chrono::NaiveDate, f64)>> = HashMap::new();
    for r in &rows {
        let (Ok(symbol), Ok(date)) = (
            r.try_get::<String, _>("symbol"),
            r.try_get::<chrono::NaiveDate, _>("price_date"),
        ) else {
            continue;
        };
        let close = r
            .try_get::<rust_decimal::Decimal, _>("close")
            .ok()
            .and_then(|d| d.to_string().parse::<f64>().ok())
            .unwrap_or(0.0);
        by_symbol.entry(symbol).or_default().push((date, close));
    }
    by_symbol
}

async fn holdings(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<HoldingsResponse> {
    // FX rate + staleness flag (missing or >7 days old). Replaces the old
    // silent 20.0 fallback so MXN-converted portfolio figures can be badged.
    let fx_info = latest_usd_mxn_rate(&state.db).await;
    let fx_usd_to_mxn: f64 = fx_info.rate;
    let fx_stale = fx_info.stale;

    let mut holdings_list = fetch_holdings_details(&state.db, ctx.user_id, fx_usd_to_mxn).await;

    // C-B: day change between the last two STORED closes per symbol — one
    // query over `benchmark_prices`, never a live quote fan-out. Cash sleeves
    // and unresolvable symbols honestly stay null instead of pretending.
    let quote_symbols: Vec<String> = {
        let mut seen = std::collections::HashSet::new();
        holdings_list
            .iter()
            .filter(|h| h.holding_type != "cash" && h.asset_class != "cash")
            .filter(|h| !h.symbol.is_empty())
            .filter(|h| seen.insert(h.symbol.clone()))
            .map(|h| h.symbol.clone())
            .collect()
    };
    let closes_by_symbol = latest_two_closes(&state.db, &quote_symbols).await;
    let today = chrono::Utc::now().date_naive();
    for h in &mut holdings_list {
        let is_cash = h.holding_type == "cash" || h.asset_class == "cash";
        if let Some(rc) = day_change_for_row(
            h.value_usd,
            is_cash,
            closes_by_symbol.get(&h.symbol).map(|v| v.as_slice()),
            today,
        ) {
            h.day_change_usd = Some(rc.day_change_usd);
            h.day_change_pct = Some(rc.day_change_pct);
            h.price_as_of = Some(rc.as_of.to_string());
        }
    }
    let day_totals = day_change_totals(
        holdings_list
            .iter()
            .map(|h| (h.value_usd, h.day_change_usd, h.price_as_of.as_deref())),
    );

    // Total value covers EVERY holding; the gain/loss totals only
    // cover holdings with a KNOWN basis (numerator and denominator
    // alike), so one 401k with an unreported basis doesn't silently
    // drag the portfolio return toward zero.
    let total_value: f64 = holdings_list.iter().map(|h| h.value).sum();
    let total_value_usd: f64 = holdings_list.iter().map(|h| h.value_usd).sum();
    let total_value_mxn: f64 = holdings_list.iter().map(|h| h.value_mxn).sum();

    let total_cost: f64 = holdings_list.iter().filter_map(|h| h.cost_basis).sum();
    let known_value: f64 = holdings_list.iter()
        .filter(|h| h.cost_basis.is_some()).map(|h| h.value).sum();
    let total_cost_usd: f64 = holdings_list.iter().filter_map(|h| h.cost_basis_usd).sum();
    let known_value_usd: f64 = holdings_list.iter()
        .filter(|h| h.cost_basis_usd.is_some()).map(|h| h.value_usd).sum();
    let total_cost_mxn: f64 = holdings_list.iter().filter_map(|h| h.cost_basis_mxn).sum();
    let known_value_mxn: f64 = holdings_list.iter()
        .filter(|h| h.cost_basis_mxn.is_some()).map(|h| h.value_mxn).sum();
    let holdings_without_basis = holdings_list.iter()
        .filter(|h| h.cost_basis.is_none() && h.cost_basis_usd.is_none())
        .count();

    Json(HoldingsResponse {
        total_value,
        total_cost_basis: total_cost,
        total_gain_loss: known_value - total_cost,
        total_gain_loss_pct: if total_cost > 0.0 { ((known_value - total_cost) / total_cost) * 100.0 } else { 0.0 },
        total_value_usd,
        total_value_mxn,
        total_cost_basis_usd: total_cost_usd,
        total_cost_basis_mxn: total_cost_mxn,
        total_gain_loss_usd: known_value_usd - total_cost_usd,
        total_gain_loss_mxn: known_value_mxn - total_cost_mxn,
        holdings_without_basis,
        fx_rate_used: fx_usd_to_mxn,
        fx_stale,
        day_change_usd: day_totals.day_change_usd,
        day_change_pct: day_totals.day_change_pct,
        day_change_coverage_pct: day_totals.coverage_pct,
        day_change_as_of: day_totals.as_of,
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
        SELECT a.name, a.current_balance, a.credit_limit, a.currency,
               i.name as institution_name
        FROM accounts a
        JOIN institutions i ON a.institution_id = i.id
        WHERE a.account_type IN ('credit', 'credit card') AND a.user_id = $1
          AND a.archived_at IS NULL
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
                    currency: r.try_get("currency").unwrap_or_else(|_| "USD".to_string()),
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
///
/// The optional `currency`, `sign`, and `q` filters let a caller scope the
/// list server-side instead of pulling a page and filtering in the client.
/// The loan-repayment picker relies on this: it must search the WHOLE table
/// (a repayment can be older than one page), scoped to the loan's currency
/// (a foreign-currency inflow would be rejected at reconcile time) and to
/// inflows only. Doing that here means the client no longer misses a match
/// that fell outside the newest-N window.
#[derive(Deserialize)]
struct TransactionsQuery {
    limit: Option<i64>,
    offset: Option<i64>,
    /// ISO currency code; scopes the list to that currency when present.
    currency: Option<String>,
    /// `"inflow"` (amount > 0) or `"outflow"` (amount < 0). Any other value
    /// (or absent) applies no sign filter.
    sign: Option<String>,
    /// Case-insensitive substring matched across the transaction's text
    /// columns, in SQL, so a hit is found regardless of recency/paging.
    q: Option<String>,
    /// When true, drop transactions already reconciled to a loan (a linked
    /// repayment or a linked disbursement). The loan payment picker sets it
    /// so it never offers a tx that would only be rejected as "already
    /// linked" on submit.
    exclude_linked: Option<bool>,
}

async fn recent_transactions(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(query): Query<TransactionsQuery>,
) -> Json<Vec<TransactionEntry>> {
    let limit = query.limit.unwrap_or(50).clamp(1, 500);
    let offset = query.offset.unwrap_or(0).max(0);
    // Empty strings arrive from `?currency=&q=` — treat them as absent so
    // the nullable-parameter filters below short-circuit to "no filter".
    let currency = query.currency.filter(|s| !s.trim().is_empty());
    let sign = query.sign.filter(|s| !s.trim().is_empty());
    let search = query.q.filter(|s| !s.trim().is_empty());
    let exclude_linked = query.exclude_linked.unwrap_or(false);
    let rows = sqlx::query(
        r#"
        SELECT t.id, t.account_id,
               COALESCE(NULLIF(a.nickname, ''), a.name) as account_name,
               i.name as institution_name,
               t.amount, t.currency,
               t.date, t.description, t.category, t.category_detailed,
               t.payment_channel, t.merchant_name,
               t.original_description, t.counterparty_name, t.counterparty_logo_url,
               t.user_description, t.payment_payee, t.payment_payer,
               t.parent_id,
               t.pending,
               t.source
        FROM transactions t
        JOIN accounts a ON t.account_id = a.id
        JOIN institutions i ON a.institution_id = i.id
        WHERE t.user_id = $1
          AND NOT EXISTS (SELECT 1 FROM transactions tc WHERE tc.parent_id = t.id)
          AND ($4::text IS NULL OR t.currency = $4)
          -- Unknown/absent sign → no filter; only the two known values bite.
          AND ($5::text IS NULL
               OR $5 NOT IN ('inflow', 'outflow')
               OR ($5 = 'inflow' AND t.amount > 0)
               OR ($5 = 'outflow' AND t.amount < 0))
          AND ($6::text IS NULL
               OR t.description ILIKE '%' || $6 || '%'
               OR t.merchant_name ILIKE '%' || $6 || '%'
               OR t.counterparty_name ILIKE '%' || $6 || '%'
               OR t.original_description ILIKE '%' || $6 || '%')
          -- Hide transactions already reconciled to a loan (either leg) when
          -- the caller asks — the payment picker does, so it can't offer a
          -- tx the reconcile step would reject.
          AND (NOT $7 OR (
                NOT EXISTS (SELECT 1 FROM loan_payments lp WHERE lp.actual_tx_id = t.id)
            AND NOT EXISTS (SELECT 1 FROM loans l WHERE l.disbursement_tx_id = t.id)
          ))
        ORDER BY t.date DESC, t.created_at DESC
        LIMIT $2 OFFSET $3
        "#
    )
    .bind(ctx.user_id)
    .bind(limit)
    .bind(offset)
    .bind(currency)
    .bind(sign)
    .bind(search)
    .bind(exclude_linked)
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
                    institution_name: r
                        .try_get::<Option<String>, _>("institution_name")
                        .ok()
                        .flatten(),
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
                    source: r
                        .try_get::<Option<String>, _>("source")
                        .ok()
                        .flatten(),
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
    let filename = format!("patrimonio-transactions-{today}.csv");

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
                            "csv stream: {e}"
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
            format!("attachment; filename=\"{filename}\""),
        )
        .body(body)
        .unwrap()
}

/// RFC-4180 field quoting for the CSV exporters (contract C-E): wrap every
/// text field in double quotes and double any embedded double quote — same
/// escaping `export_transactions_csv` applies. Numeric/date/bool fields
/// serialise bare; nulls serialise as an empty field.
fn csv_field(s: &str) -> String {
    format!("\"{}\"", s.replace('"', "\"\""))
}

/// The `text/csv` + `Content-Disposition: attachment` response shell every
/// CSV exporter shares (cookie-auth same-tab navigation on the frontend).
fn csv_attachment_response(filename: &str, body: axum::body::Body) -> Response {
    Response::builder()
        .status(StatusCode::OK)
        .header(header::CONTENT_TYPE, "text/csv; charset=utf-8")
        .header(
            header::CONTENT_DISPOSITION,
            format!("attachment; filename=\"{filename}\""),
        )
        .body(body)
        .unwrap()
}

/// C-E: the holdings table as a CSV download. Reuses the JSON handler's row
/// builder (`fetch_holdings_details`) so counts and the lots-aware basis
/// match the endpoint exactly. Holdings are bounded (tens of rows), so the
/// body is assembled in memory — the streaming channel of the transactions
/// exporter buys nothing here while the lots map needs the whole set anyway.
async fn export_holdings_csv(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Response {
    let fx_info = latest_usd_mxn_rate(&state.db).await;
    let list = fetch_holdings_details(&state.db, ctx.user_id, fx_info.rate).await;

    let today = chrono::Local::now().format("%Y-%m-%d").to_string();
    let filename = format!("patrimonio_holdings_{today}.csv");

    // Money (and %) fields serialize at 2dp: the raw f64 Display leaked
    // float noise like `3679.9999999999995` into spreadsheets. CSV-only —
    // the JSON endpoint keeps full precision.
    let money = |v: f64| format!("{v:.2}");
    let opt = |v: Option<f64>| v.map(|x| format!("{x:.2}")).unwrap_or_default();
    let mut csv = String::from(
        "symbol,name,account,institution,account_type,asset_class,quantity,price,currency,value,value_usd,cost_basis_usd,gain_loss_usd,gain_loss_pct\n",
    );
    for h in &list {
        csv.push_str(&format!(
            "{},{},{},{},{},{},{},{},{},{},{},{},{},{}\n",
            csv_field(&h.symbol),
            csv_field(&h.name),
            csv_field(&h.account_name),
            csv_field(&h.institution_name),
            csv_field(&h.account_type),
            csv_field(&h.asset_class),
            h.quantity,
            money(h.price),
            h.currency,
            money(h.value),
            money(h.value_usd),
            opt(h.cost_basis_usd),
            opt(h.gain_loss_usd),
            opt(h.gain_loss_pct),
        ));
    }
    csv_attachment_response(&filename, axum::body::Body::from(csv))
}

/// C-E: every active purchase lot as a CSV download. Same depletion-marker
/// filter (`qty > 0`) and USD-cost math as the JSON endpoint's nested lots.
async fn export_lots_csv(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Response {
    let rows = sqlx::query(
        r#"
        SELECT h.symbol,
               COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name,
               l.acquired_at, l.qty, l.cost_per_unit, l.currency, l.usd_fx_rate
        FROM holding_lots l
        JOIN holdings h ON h.id = l.holding_id
        JOIN accounts a ON a.id = h.account_id
        WHERE l.user_id = $1 AND l.qty > 0 AND a.archived_at IS NULL
          AND h.deleted_at IS NULL
        ORDER BY h.symbol ASC, l.acquired_at ASC, l.id ASC
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let today = chrono::Local::now().format("%Y-%m-%d").to_string();
    let filename = format!("patrimonio_lots_{today}.csv");

    let mut csv = String::from("symbol,account,acquired_at,qty,cost_per_unit,currency,usd_cost\n");
    for r in &rows {
        let dec = |col: &str| -> f64 {
            r.try_get::<rust_decimal::Decimal, _>(col)
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0)
        };
        let qty = dec("qty");
        let cpu = dec("cost_per_unit");
        let fx = dec("usd_fx_rate");
        let currency: String = r.try_get("currency").unwrap_or_else(|_| "USD".to_string());
        let native_cost = qty * cpu;
        // Mirrors the HoldingLot::usd_cost conversion in the JSON handler.
        let usd_cost = match currency.as_str() {
            "USD" => native_cost,
            "MXN" => {
                if fx > 0.0 {
                    native_cost / fx
                } else {
                    native_cost
                }
            }
            _ => native_cost,
        };
        let acquired_at: String = r
            .try_get::<chrono::NaiveDate, _>("acquired_at")
            .map(|d| d.to_string())
            .unwrap_or_default();
        csv.push_str(&format!(
            // Money fields at 2dp — the qty*cpu/fx float math leaked
            // `.9999999999995`-style noise into the export. Quantity stays
            // full precision (fractional crypto/fund lots are meaningful).
            "{},{},{},{},{:.2},{},{:.2}\n",
            csv_field(&r.try_get::<String, _>("symbol").unwrap_or_default()),
            csv_field(&r.try_get::<String, _>("account_name").unwrap_or_default()),
            acquired_at,
            qty,
            cpu,
            currency,
            usd_cost,
        ));
    }
    csv_attachment_response(&filename, axum::body::Body::from(csv))
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

/// Human display label for a canonical asset-class key (contract C2). The
/// frontend renders this; FILTERING keys on the canonical value itself.
fn asset_class_label(key: &str) -> &'static str {
    match key {
        "equity" => "Stocks & funds",
        "bonds" => "Bonds",
        "cash" => "Cash",
        "crypto" => "Crypto",
        "real_estate" => "Real estate",
        "commodities" => "Commodities",
        // Contract C-G: investment-category account balances with no holdings
        // rows — real value the asset-class view would otherwise omit, but
        // with no per-holding detail to classify or filter to.
        "unclassified" => "Unclassified",
        _ => "Other",
    }
}

/// Asset allocation by category and sub-category, scoped to caller.
///
/// Classification happens in Rust via `classify_asset` (contract C2) rather
/// than on the raw `holding_type` in SQL: the type column alone puts a
/// 'mutual fund' bond fund (VBTLX) and 'etf' bond funds (BND/TLT) in the
/// equity band, so a user whose whole bond exposure is funds sees no Bonds
/// band at all. The cash/crypto accounts-union rows (bank balances have no
/// holdings rows) are tagged with their canonical class directly.
async fn asset_allocation(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<AllocationEntry>> {
    // Shared FX path (manual-override precedence + missing/stale policy in
    // one place) — this handler used to run its own inline query with a
    // silent `.unwrap_or(20.0)` fallback that the holdings endpoint had
    // already dropped, so the two portfolio surfaces could value the same
    // MXN balance at different rates.
    let fx_rate = latest_usd_mxn_rate(&state.db).await.rate;

    let rows = sqlx::query(
        r#"
        SELECT kind, holding_type, symbol, name, sub_category, value_usd, qty
        FROM (
            SELECT 'holding' as kind,
                   holding_type,
                   symbol,
                   name,
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
            FROM holdings h
            WHERE user_id = $2
              AND h.deleted_at IS NULL
              AND EXISTS (SELECT 1 FROM accounts a
                          WHERE a.id = h.account_id AND a.archived_at IS NULL)
            UNION ALL
            SELECT 'cash' as kind,
                   NULL as holding_type,
                   NULL as symbol,
                   name,
                   name as sub_category,
                   CASE
                       WHEN currency = 'MXN' THEN current_balance / $1::numeric
                       ELSE current_balance
                   END as value_usd,
                   0::numeric as qty
            FROM accounts
            WHERE account_type IN ('checking', 'savings', 'cash', 'cash management', 'cd', 'money market')
              AND user_id = $2
              AND archived_at IS NULL
            UNION ALL
            SELECT 'crypto' as kind,
                   NULL as holding_type,
                   NULL as symbol,
                   name,
                   name as sub_category,
                   CASE
                       WHEN currency = 'MXN' THEN current_balance / $1::numeric
                       ELSE current_balance
                   END as value_usd,
                   COALESCE(crypto_amount, 0)::numeric as qty
            FROM accounts
            WHERE account_type IN ('crypto')
              AND user_id = $2
              AND archived_at IS NULL
            UNION ALL
            -- Contract C-G: active investment-category accounts with NO
            -- holdings rows (e.g. a CETES account tracked by balance only).
            -- Surfacing the balance as an 'unclassified' band reconciles the
            -- asset-class view with net worth; accounts WITH holdings are
            -- covered by the holdings branch and never double-counted here.
            -- An UNAMBIGUOUS account type maps straight to its asset class:
            -- 'bonds' (CETES Directo — literally Mexican treasury bills) is
            -- bonds, full stop; leaving it 'unclassified' skewed the Bonds
            -- target to a false "on target" and showed an impossible
            -- "classify these holdings" nudge. Ambiguous types ('brokerage',
            -- 'ira', …) could hold anything and stay unclassified.
            SELECT CASE WHEN account_type = 'bonds' THEN 'bonds'
                        ELSE 'unclassified' END as kind,
                   NULL as holding_type,
                   NULL as symbol,
                   name,
                   name as sub_category,
                   CASE
                       WHEN currency = 'MXN' THEN current_balance / $1::numeric
                       ELSE current_balance
                   END as value_usd,
                   0::numeric as qty
            FROM accounts
            WHERE account_type IN ('brokerage', '401k', '403b', '457b', 'ira', 'roth',
                                   'roth 401k', 'hsa', '529', 'pension', 'investment', 'bonds')
              AND user_id = $2
              AND archived_at IS NULL
              -- An account whose only holding is soft-deleted correctly
              -- becomes an unclassified band for the undo window.
              AND NOT EXISTS (SELECT 1 FROM holdings h
                              WHERE h.account_id = accounts.id AND h.deleted_at IS NULL)
        ) sub
        "#
    )
    .bind(fx_rate)
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    // Round 3 (C3-A): the user's overrides, fetched ONCE per request — the
    // same precedence the holdings endpoint applies, so a band's key always
    // matches the rows it filters to.
    let overrides =
        crate::services::holdings::fetch_asset_class_overrides(&state.db, ctx.user_id).await;

    // Classify each row, then group by (canonical class, sub-category). A
    // HashMap keyed on both keeps the same grouping the old SQL GROUP BY
    // gave, with the class computed in Rust.
    let mut grouped: HashMap<(String, String), (f64, f64)> = HashMap::new();
    for r in &rows {
        let kind: String = r.try_get("kind").unwrap_or_default();
        let value: f64 = r
            .try_get::<rust_decimal::Decimal, _>("value_usd")
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
            .unwrap_or(0.0);
        let qty: f64 = r
            .try_get::<rust_decimal::Decimal, _>("qty")
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
            .unwrap_or(0.0);
        let sub_category: String = r
            .try_get::<Option<String>, _>("sub_category")
            .ok()
            .flatten()
            .unwrap_or_else(|| "Unknown".to_string());

        // Accounts-union rows (bank cash, crypto-by-balance) carry their
        // class in `kind`; holdings rows go through the shared classifier
        // (override-aware, C3-A).
        let asset_class: String = match kind.as_str() {
            "cash" => "cash".to_string(),
            "crypto" => "crypto".to_string(),
            // Balance-only account whose type IS an asset class (C-G, e.g.
            // account_type='bonds') — classified in SQL, no holdings row to
            // run through the classifier.
            "bonds" => "bonds".to_string(),
            "unclassified" => "unclassified".to_string(),
            _ => {
                let holding_type: String = r
                    .try_get::<Option<String>, _>("holding_type")
                    .ok()
                    .flatten()
                    .unwrap_or_default();
                let symbol: String = r
                    .try_get::<Option<String>, _>("symbol")
                    .ok()
                    .flatten()
                    .unwrap_or_default();
                let name: String = r
                    .try_get::<Option<String>, _>("name")
                    .ok()
                    .flatten()
                    .unwrap_or_default();
                crate::services::holdings::effective_asset_class(
                    &overrides,
                    &holding_type,
                    &symbol,
                    &name,
                )
            }
        };

        let slot = grouped.entry((asset_class, sub_category)).or_insert((0.0, 0.0));
        slot.0 += value;
        slot.1 += qty;
    }

    let mut entries: Vec<AllocationEntry> = grouped
        .into_iter()
        .map(|((asset_class, sub_category), (value, quantity))| AllocationEntry {
            category: asset_class_label(&asset_class).to_string(),
            asset_class,
            sub_category,
            value,
            quantity,
        })
        .collect();
    entries.sort_by(|a, b| b.value.partial_cmp(&a.value).unwrap_or(std::cmp::Ordering::Equal));
    Json(entries)
}

#[derive(Deserialize)]
struct TrendsQuery {
    /// Trailing window in months (default 12). Clamped to 1..=24 so the
    /// Cash Flow tab's period selector can ask for a tighter window
    /// (This/Last month, 3 months, YTD) without an unbounded scan. Absent
    /// keeps the historical 12-month default so existing callers are
    /// unchanged.
    months: Option<i64>,
}

/// Monthly income and spending trends for this user.
async fn cash_flow_trends(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<TrendsQuery>,
) -> Result<Json<Vec<CashFlowPoint>>, ApiError> {
    let months = q.months.unwrap_or(12).clamp(1, 24);
    // Income/spending count genuine household cash flow only; securities
    // trades (Investment) and internal Transfers are peeled into the
    // `invested` / `transferred` buckets (still keyed on the effective
    // category, so a user re-tag flows through). Every other non-cash-flow
    // row — CC-payment leg / CC inflow, tax refund, loan leg, FX pair, split
    // parent — is dropped by the shared `CASHFLOW_ROW_ANTI_JOINS_SQL` WHERE
    // fragment, which those buckets don't need.
    //
    // FX is PER ROW: each MXN transaction is divided by the USD→MXN rate in
    // effect on its own date (the shared `USD_MXN_ROW_RATE_SQL` rule from
    // services::tax — on-or-before-date rate, else latest, else 20.0). This
    // query previously converted up to 24 months of history at the single
    // LATEST rate; USD/MXN moves several percent over a year, so latest-rate
    // conversion systematically skews every historical month's income/spend
    // bars whenever the peso has trended.
    let sql = format!(
        r#"
        SELECT TO_CHAR(t.date, 'YYYY-MM') as month,
               SUM(CASE WHEN t.amount > 0
                        AND {EFFECTIVE_CATEGORY_SQL} NOT IN {NON_CASHFLOW_CATEGORIES_SQL} THEN
                       CASE WHEN a.currency = 'MXN'
                            THEN t.amount / fx.rate
                            ELSE t.amount END
                   ELSE 0 END) as income,
               SUM(CASE WHEN t.amount < 0
                        AND {EFFECTIVE_CATEGORY_SQL} NOT IN {NON_CASHFLOW_CATEGORIES_SQL} THEN
                       CASE WHEN a.currency = 'MXN'
                            THEN ABS(t.amount) / fx.rate
                            ELSE ABS(t.amount) END
                   ELSE 0 END) as spending,
               -- Net cash moved into investments (buys +, sells -): -amount, USD.
               SUM(CASE WHEN {EFFECTIVE_CATEGORY_SQL} = 'INVESTMENT' THEN
                       CASE WHEN a.currency = 'MXN'
                            THEN -t.amount / fx.rate
                            ELSE -t.amount END
                   ELSE 0 END) as invested,
               -- Net internal transfer flow (in +, out -), USD.
               SUM(CASE WHEN {EFFECTIVE_CATEGORY_SQL} IN ('TRANSFER_IN', 'TRANSFER_OUT', 'TRANSFER') THEN
                       CASE WHEN a.currency = 'MXN'
                            THEN t.amount / fx.rate
                            ELSE t.amount END
                   ELSE 0 END) as transferred
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        CROSS JOIN LATERAL (SELECT {USD_MXN_ROW_RATE_SQL} AS rate) fx
        -- Calendar-month-aligned trailing window: months=1 yields the
        -- current month only, months=2 adds the prior month, etc. (mirrors
        -- spending_by_category). The Cash Flow tab's period selector binds
        -- this so "Last month" / "Last 3 months" / "YTD" each pull just the
        -- months they need while the default (12) is unchanged.
        WHERE t.date >= (DATE_TRUNC('month', CURRENT_DATE) - make_interval(months => ($2::int - 1)))
          AND t.user_id = $1{CASHFLOW_ROW_ANTI_JOINS_SQL}
        GROUP BY month
        ORDER BY month ASC
        "#
    );
    // A DB failure must surface as a logged 500, not as fabricated emptiness:
    // the old `.unwrap_or_default()` made "query blew up" indistinguishable
    // from "user has no transactions", silently rendering an empty chart.
    let rows = sqlx::query(&sql)
        .bind(ctx.user_id)
        .bind(months as i32)
        .fetch_all(&state.db)
        .await
        .map_err(internal)?;

    // Decode failures are bugs, not empty states: every SUM column is built
    // from CASE arms with an ELSE 0, over a non-empty GROUP BY group, so a
    // NULL/type mismatch here means the query changed under us — 500 loudly
    // instead of charting a silent 0.
    let mut points = Vec::with_capacity(rows.len());
    for r in &rows {
        let dec = |col: &str| -> Result<f64, ApiError> {
            let d = r.try_get::<rust_decimal::Decimal, _>(col).map_err(internal)?;
            Ok(d.to_string().parse().unwrap_or(0.0))
        };
        points.push(CashFlowPoint {
            month: r.try_get("month").map_err(internal)?,
            income: dec("income")?,
            spending: dec("spending")?,
            invested: dec("invested")?,
            transferred: dec("transferred")?,
        });
    }
    Ok(Json(points))
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
    /// True when the latest USD/MXN rate is missing or stale (>7d), so the
    /// MXN amounts here were normalized at an approximate fallback rate.
    fx_stale: bool,
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
) -> Result<Json<SpendingByCategoryResponse>, ApiError> {
    let months = q.months.unwrap_or(6).clamp(1, 24);
    let top = q.top.unwrap_or(8).clamp(1, 30) as usize;

    // Same cash-flow hygiene as `cash_flow_trends`, via the shared fragments:
    // drop internal transfers / investment moves (by effective category) and
    // the CC-payment / loan-leg / FX-pair / split-parent rows. The positive-
    // only bits of the anti-join fragment (CC inflow, tax refund) are no-ops
    // here since this sums outflows only.
    //
    // FX is PER ROW (shared `USD_MXN_ROW_RATE_SQL`: on-or-before-date rate,
    // else latest, else 20.0) — up to 24 months of MXN outflows used to be
    // converted at the single latest rate, skewing every historical month's
    // category totals whenever the peso has trended.
    let sql = format!(
        r#"
        SELECT TO_CHAR(t.date, 'YYYY-MM') AS month,
               COALESCE(NULLIF(t.user_category, ''), t.category, 'UNCATEGORIZED') AS category,
               SUM(CASE WHEN a.currency = 'MXN'
                        THEN ABS(t.amount) / fx.rate
                        ELSE ABS(t.amount) END) AS amount
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        CROSS JOIN LATERAL (SELECT {USD_MXN_ROW_RATE_SQL} AS rate) fx
        WHERE t.amount < 0
          AND t.date >= (DATE_TRUNC('month', CURRENT_DATE) - make_interval(months => ($2::int - 1)))
          AND t.user_id = $1
          AND {EFFECTIVE_CATEGORY_SQL} NOT IN {NON_CASHFLOW_CATEGORIES_SQL}{CASHFLOW_ROW_ANTI_JOINS_SQL}
        GROUP BY TO_CHAR(t.date, 'YYYY-MM'),
                 COALESCE(NULLIF(t.user_category, ''), t.category, 'UNCATEGORIZED')
        ORDER BY month ASC
        "#,
    );
    // A DB failure must surface as a logged 500, not as fabricated emptiness:
    // the old `.unwrap_or_default()` made "query blew up" indistinguishable
    // from "no spending in the window", silently rendering an empty chart.
    let rows = sqlx::query(&sql)
        .bind(ctx.user_id)
        .bind(months as i32)
        .fetch_all(&state.db)
        .await
        .map_err(internal)?;

    // (category -> (month -> amount)) plus per-category totals and the set of
    // months actually present, so the response only carries populated buckets.
    let mut by_cat: HashMap<String, HashMap<String, f64>> = HashMap::new();
    let mut totals: HashMap<String, f64> = HashMap::new();
    let mut month_set: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();

    for r in &rows {
        let month: String = r.try_get("month").map_err(internal)?;
        let category: String = r.try_get("category").map_err(internal)?;
        // SUM over a non-empty group of ABS(...) values is never NULL, so a
        // decode failure is a bug — 500 loudly instead of a silent 0 bar.
        let amount: f64 = r
            .try_get::<rust_decimal::Decimal, _>("amount")
            .map_err(internal)?
            .to_string()
            .parse()
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

    Ok(Json(SpendingByCategoryResponse {
        months: months_vec,
        categories,
        fx_stale: latest_usd_mxn_rate(&state.db).await.stale,
    }))
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
    /// True when the latest USD/MXN rate is missing or stale (>7d) — MXN spend
    /// was normalized at an approximate fallback rate.
    fx_stale: bool,
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
) -> Result<Json<SpendingInsightsResponse>, ApiError> {
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
    // A failure here used to `.unwrap_or_default()` into an empty label set,
    // making every insight silently disappear — surface it as a logged 500.
    .map_err(internal)?;

    let window_months: Vec<String> = month_rows
        .iter()
        .map(|r| r.try_get::<String, _>("m").map_err(internal))
        .collect::<Result<_, _>>()?;
    // generate_series(1, window>=2) always yields rows, so `first()` is
    // always Some — the fallback only guards an impossible empty series.
    let recent_month = window_months.first().cloned().unwrap_or_default();

    // Same cash-flow exclusions as the other spend views, via the shared
    // fragments (the positive-only anti-joins are no-ops on this outflow sum).
    //
    // FX is PER ROW (shared `USD_MXN_ROW_RATE_SQL`: on-or-before-date rate,
    // else latest, else 20.0) — the recent-vs-baseline comparison used to
    // convert the whole lookback window at the single latest rate, so a peso
    // move could masquerade as a spending change in every MXN category.
    let sql = format!(
        r#"
        SELECT TO_CHAR(t.date, 'YYYY-MM') AS month,
               t.user_category AS user_category,
               t.category_detailed AS category_detailed,
               t.category AS category,
               SUM(CASE WHEN a.currency = 'MXN'
                        THEN ABS(t.amount) / fx.rate
                        ELSE ABS(t.amount) END) AS amount
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        CROSS JOIN LATERAL (SELECT {USD_MXN_ROW_RATE_SQL} AS rate) fx
        WHERE t.amount < 0
          AND t.date >= DATE_TRUNC('month', CURRENT_DATE) - make_interval(months => $2::int)
          AND t.date <  DATE_TRUNC('month', CURRENT_DATE)
          AND t.user_id = $1
          AND {EFFECTIVE_CATEGORY_SQL} NOT IN {NON_CASHFLOW_CATEGORIES_SQL}{CASHFLOW_ROW_ANTI_JOINS_SQL}
        GROUP BY month, t.user_category, t.category_detailed, t.category
        "#,
    );
    // A DB failure must surface as a logged 500, not as fabricated emptiness:
    // the old `.unwrap_or_default()` made "query blew up" indistinguishable
    // from "no spending in the window" (no insights, no budget suggestions).
    let rows = sqlx::query(&sql)
        .bind(ctx.user_id)
        .bind(window as i32)
        .fetch_all(&state.db)
        .await
        .map_err(internal)?;

    // Accumulate per (user_category, category_detailed, category) → (month → amount).
    type CatKey = (Option<String>, Option<String>, Option<String>);
    let mut by_cat: HashMap<CatKey, HashMap<String, f64>> = HashMap::new();
    for r in &rows {
        let month: String = r.try_get("month").map_err(internal)?;
        // The three category columns are legitimately NULLable — read them as
        // Option (NULL is data, not an error) but still 500 on a genuine
        // decode failure. Treat an empty-string user_category as absent so it
        // folds in with the NULL group (both prettify to the detailed/primary
        // label).
        let user_category: Option<String> = r
            .try_get::<Option<String>, _>("user_category")
            .map_err(internal)?
            .filter(|s| !s.trim().is_empty());
        let category_detailed: Option<String> = r
            .try_get::<Option<String>, _>("category_detailed")
            .map_err(internal)?
            .filter(|s| !s.trim().is_empty());
        let category: Option<String> = r
            .try_get::<Option<String>, _>("category")
            .map_err(internal)?
            .filter(|s| !s.trim().is_empty());
        // SUM over a non-empty group of ABS(...) values is never NULL, so a
        // decode failure is a bug — 500 loudly instead of a silent $0 insight.
        let amount: f64 = r
            .try_get::<rust_decimal::Decimal, _>("amount")
            .map_err(internal)?
            .to_string()
            .parse()
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

    Ok(Json(SpendingInsightsResponse {
        recent_month,
        lookback,
        categories,
        fx_stale: latest_usd_mxn_rate(&state.db).await.stale,
    }))
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

/// Optional `?benchmark=` selector shared by the TWR + contribution-comparison
/// endpoints. Defaults (when absent) to the S&P 500, preserving prior behavior;
/// an unrecognized/illiquid symbol fails soft in the service layer.
#[derive(Deserialize)]
struct BenchmarkSelectQuery {
    benchmark: Option<String>,
}

/// Dollar-weighted "you vs the selected benchmark" over the user's tracked
/// holding lots. `?benchmark=` defaults to the S&P 500 when omitted.
async fn benchmark_comparison(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<BenchmarkSelectQuery>,
) -> Json<crate::services::benchmark::ContributionComparison> {
    Json(
        crate::services::benchmark::contribution_comparison(
            &state.db,
            ctx.user_id,
            q.benchmark.as_deref(),
        )
        .await,
    )
}

/// True time-weighted return: a daily growth index of the investment
/// portfolio (cashflows divided out) + the S&P 500 over the same dates, plus
/// how much of the portfolio we can price historically (`coverage_pct`).
async fn portfolio_twr(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<BenchmarkSelectQuery>,
) -> Json<crate::services::twr::TwrResult> {
    Json(
        crate::services::twr::portfolio_twr(&state.db, ctx.user_id, q.benchmark.as_deref()).await,
    )
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
) -> Result<Json<EmergencyFundResponse>, ApiError> {
    // Shared FX policy for CURRENT balances: real latest rate when present,
    // hard fallback flagged stale (and warn-logged) when missing/old. The
    // latest rate is correct here — a cash balance is a present-day value, so
    // it converts at the present-day rate. Historical spend below deliberately
    // does NOT use this: each transaction converts at its own date's rate.
    let fx = latest_usd_mxn_rate(&state.db).await.rate;

    let cash_row = sqlx::query(
        r#"
        SELECT COALESCE(SUM(
            CASE WHEN currency = 'MXN' THEN current_balance / $2::numeric
                 ELSE current_balance END), 0) AS cash
        FROM accounts
        WHERE user_id = $1
          AND archived_at IS NULL
          -- CDs are excluded: they carry an early-withdrawal penalty, so they
          -- are not the immediately-accessible cash an emergency fund measures.
          AND account_type IN ('checking', 'savings', 'cash', 'cash management', 'money market')
        "#,
    )
    .bind(ctx.user_id)
    .bind(fx)
    // Ungrouped COALESCE(SUM(...), 0) aggregate: always exactly one non-NULL
    // row, even with zero matching accounts — so fetch_one, and any failure
    // is a real DB/decode error. The old `.ok().flatten()` turned "query blew
    // up" into an all-zeros runway indistinguishable from "no cash tracked";
    // now it surfaces as a logged 500 (mirrors projections::projection_defaults).
    .fetch_one(&state.db)
    .await
    .map_err(internal)?;
    let liquid_cash_usd: f64 = cash_row
        .try_get::<rust_decimal::Decimal, _>("cash")
        .map_err(internal)?
        .to_string()
        .parse()
        .unwrap_or(0.0);

    // Trailing spend + month count. The exclusion set is the SHARED fragment
    // (trailing_cashflow_exclusions_sql) used verbatim by
    // `projections::projection_defaults`, so the two trailing-12-mo
    // aggregations can never silently drift.
    //
    // FX is PER ROW: each MXN transaction is divided by the USD→MXN rate in
    // effect on its own date (the shared `USD_MXN_ROW_RATE_SQL` rule from
    // services::tax — on-or-before-date rate, else latest, else 20.0). This
    // trailing-12-month spend used to divide by the single LATEST rate, so a
    // peso trend skewed the runway's monthly-spend denominator. (The cash
    // numerator above correctly keeps the latest rate — it's a current value.)
    let excl = trailing_cashflow_exclusions_sql();
    let spend_sql = format!(
        r#"
        SELECT
            COALESCE(SUM(CASE WHEN a.currency = 'MXN'
                     THEN ABS(t.amount) / fx.rate
                     ELSE ABS(t.amount) END), 0) AS spending,
            COUNT(DISTINCT TO_CHAR(t.date, 'YYYY-MM')) AS months
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        CROSS JOIN LATERAL (SELECT {USD_MXN_ROW_RATE_SQL} AS rate) fx
        WHERE t.amount < 0
        {excl}
        "#,
    );
    // Same shape as the cash query above: ungrouped aggregate → exactly one
    // row, COALESCE/COUNT are never NULL. Zero transactions still decodes as
    // (0, 0) — only genuine DB/decode failures become logged 500s (the old
    // `.ok().flatten()` shipped them as a fabricated all-zeros runway).
    let spend_row = sqlx::query(&spend_sql)
        .bind(ctx.user_id)
        .fetch_one(&state.db)
        .await
        .map_err(internal)?;

    let spending: f64 = spend_row
        .try_get::<rust_decimal::Decimal, _>("spending")
        .map_err(internal)?
        .to_string()
        .parse()
        .unwrap_or(0.0);
    let months: i64 = spend_row.try_get::<i64, _>("months").map_err(internal)?.max(0);

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

    Ok(Json(EmergencyFundResponse {
        liquid_cash_usd,
        monthly_spend_usd,
        months_covered,
        months_of_data: months as i32,
    }))
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

/// Monthly closing balance for one account, in the account's native currency.
///
/// Primary source is the persisted `balance_after` (the statement SALDO captured
/// at import) — the latest in-month balance per month. Accounts imported from
/// statements keep this path unchanged. When an account has **no** `balance_after`
/// history (Plaid-only / manual accounts), we fall back to `balance_snapshots`
/// (the daily historisation net-worth already reads), taking the latest snapshot
/// in each month. Both branches yield the same `{month, balance}` shape, so the
/// chart broadens to snapshot-backed accounts with no client change. Statement
/// accounts never hit the fallback, so nothing double-counts.
async fn account_balance_history(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<AccountBalanceHistoryQuery>,
) -> Json<Vec<BalancePoint>> {
    let account_id = match uuid::Uuid::parse_str(&q.account_id) {
        Ok(id) => id,
        Err(_) => return Json(Vec::new()),
    };

    // Map a `(month TEXT, balance NUMERIC)` row set into the response shape.
    let to_points = |rows: Vec<sqlx::postgres::PgRow>| -> Vec<BalancePoint> {
        rows.iter()
            .map(|r| BalancePoint {
                month: r.get("month"),
                balance: r
                    .try_get::<rust_decimal::Decimal, _>("balance")
                    .ok()
                    .map(|d| d.to_string().parse().unwrap_or(0.0))
                    .unwrap_or(0.0),
            })
            .collect()
    };

    // Primary: statement `balance_after` (unchanged).
    let statement_rows = sqlx::query(
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

    if !statement_rows.is_empty() {
        return Json(to_points(statement_rows));
    }

    // Fallback: latest daily snapshot per month, native `bs.balance`.
    let snapshot_rows = sqlx::query(
        r#"
        SELECT DISTINCT ON (TO_CHAR(bs.as_of_date, 'YYYY-MM'))
               TO_CHAR(bs.as_of_date, 'YYYY-MM') AS month,
               bs.balance                        AS balance
        FROM balance_snapshots bs
        WHERE bs.account_id = $1
          AND bs.user_id    = $2
        ORDER BY TO_CHAR(bs.as_of_date, 'YYYY-MM') ASC, bs.as_of_date DESC
        "#,
    )
    .bind(account_id)
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(to_points(snapshot_rows))
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
    /// Contract C-C: owning account's display name (nickname-aware).
    /// Archived accounts are included — history must keep its context. Null
    /// only if the account row is gone.
    account_name: Option<String>,
    account_type: Option<String>,
    /// Whether the disposal happened inside a tax-advantaged wrapper — the
    /// SAME `TAX_ADVANTAGED_ACCOUNT_TYPES` list Tax planning uses, so the
    /// card's taxable subtotal and the tax module never disagree.
    tax_advantaged: bool,
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

/// Decode one disposal row (the C-C query shape) into its JSON form —
/// shared by the JSON handler and the CSV exporter so the per-row math
/// (FX-aware proceeds/cost, calendar long-term rule) lives in one place.
fn disposal_from_row(r: &sqlx::postgres::PgRow) -> RealizedDisposal {
    let dec = |col: &str| -> f64 {
        r.try_get::<rust_decimal::Decimal, _>(col)
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
            .unwrap_or(0.0)
    };

    let qty = dec("qty_sold");
    let sell_px = dec("sell_price_per_unit");
    let sell_fx = dec("sell_fx_rate");
    let cost_px = dec("cost_per_unit");
    let cost_fx = dec("cost_fx_rate");
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
    // Long-term flag uses the SAME calendar rule as the tax module
    // (TaxCalculator::is_long_term): sold > acquired + 12 calendar
    // months, with checked_add_months clamping Feb-29 → Feb-28. This
    // replaces the old `holding_days > 365` count so the flag agrees
    // across leap years and with the tax-filing buckets. When the
    // source lot is gone (LEFT JOIN → NULL acquired_at) we can't apply
    // the calendar rule, so the flag stays None.
    let acquired_date: Option<chrono::NaiveDate> = r.try_get("acquired_date").ok();
    let sell_date_raw: Option<chrono::NaiveDate> = r.try_get("sell_date_raw").ok();
    let long_term = match (acquired_date, sell_date_raw) {
        (Some(acq), Some(sold)) => acq
            .checked_add_months(chrono::Months::new(12))
            .map(|anniversary| sold > anniversary),
        _ => None,
    };
    let account_type: Option<String> = r
        .try_get::<Option<String>, _>("account_type")
        .ok()
        .flatten();
    let tax_advantaged =
        crate::services::tax::is_tax_advantaged_account_type(account_type.as_deref());
    RealizedDisposal {
        symbol: r.get("symbol"),
        name: r.get("name"),
        account_name: r
            .try_get::<Option<String>, _>("account_name")
            .ok()
            .flatten(),
        account_type,
        tax_advantaged,
        sell_date: r.get("sell_date"),
        qty_sold: qty,
        proceeds_usd,
        cost_usd,
        realized_pnl_usd: dec("realized_pnl_usd"),
        holding_days,
        long_term,
    }
}

/// The disposals query shared by the JSON handler and the CSV exporter
/// (C-C / C-E). `LEFT JOIN accounts` with NO archived filter: a disposal
/// that happened in a since-archived account must keep its context.
const REALIZED_DISPOSALS_SQL: &str = r#"
        SELECT TO_CHAR(d.sell_date, 'YYYY-MM-DD') AS sell_date,
               d.sell_date AS sell_date_raw,
               l.acquired_at AS acquired_date,
               d.qty_sold, d.sell_price_per_unit, d.sell_fx_rate,
               d.cost_per_unit, d.cost_fx_rate, d.realized_pnl_usd,
               h.symbol, h.name,
               COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name,
               a.account_type,
               (d.sell_date - l.acquired_at) AS holding_days
        FROM lot_disposals d
        JOIN holdings h ON h.id = d.holding_id
        LEFT JOIN holding_lots l ON l.id = d.lot_id
        LEFT JOIN accounts a ON a.id = h.account_id
        WHERE d.user_id = $1
          AND h.deleted_at IS NULL
          AND ($2::int IS NULL OR EXTRACT(YEAR FROM d.sell_date)::int = $2)
        ORDER BY d.sell_date DESC
"#;

#[derive(Serialize)]
struct RealizedYear {
    year: i32,
    realized_usd: f64,
}

#[derive(Serialize)]
struct RealizedGainsSummary {
    ytd_realized_usd: f64,
    total_realized_usd: f64,
    /// Contract C-C: Σ `realized_pnl_usd` over the returned (year-filtered)
    /// list's rows that sit in NON-tax-advantaged accounts — the number that
    /// must match Tax planning's taxable figure to the cent.
    taxable_realized_usd: f64,
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
/// sync time. We add USD proceeds/cost for display and a long-term flag
/// (sold > acquired + 12 calendar months, matching the tax module's
/// `is_long_term`) for tax context, joining the source lot for the
/// acquisition date when it still exists.
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

    let rows = sqlx::query(&format!("{REALIZED_DISPOSALS_SQL} LIMIT 500"))
        .bind(ctx.user_id)
        .bind(q.year)
        .fetch_all(&state.db)
        .await
        .unwrap_or_default();

    let disposals: Vec<RealizedDisposal> = rows.iter().map(disposal_from_row).collect();

    let count = disposals.len() as i64;
    // C-C: taxable subtotal over the RETURNED (year-filtered) list only —
    // the card caption pairs it with the same period's total.
    let taxable_realized_usd: f64 = disposals
        .iter()
        .filter(|d| !d.tax_advantaged)
        .map(|d| d.realized_pnl_usd)
        .sum();

    // By-year totals across ALL history (independent of the list filter).
    let year_rows = sqlx::query(
        r#"
        SELECT EXTRACT(YEAR FROM sell_date)::int AS year,
               COALESCE(SUM(realized_pnl_usd), 0) AS total
        FROM lot_disposals
        WHERE user_id = $1
          -- Round 3 soft delete: no holdings join here, so an EXISTS guard.
          AND EXISTS (SELECT 1 FROM holdings h
                      WHERE h.id = lot_disposals.holding_id AND h.deleted_at IS NULL)
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
          -- Round 3 soft delete: no holdings join here, so an EXISTS guard.
          AND EXISTS (SELECT 1 FROM holdings h
                      WHERE h.id = lot_disposals.holding_id AND h.deleted_at IS NULL)
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
            taxable_realized_usd,
            count,
            year: q.year,
        },
        by_year,
        disposals,
    })
}

/// C-E: the realized-gains list as a CSV download — same rows and order as
/// the JSON endpoint (including the C-C account context), but with NO
/// LIMIT-500 truncation: both ends of the pipe stream, cloning
/// `export_transactions_csv`'s channel pattern.
async fn export_realized_gains_csv(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<RealizedGainsQuery>,
) -> Response {
    use bytes::Bytes;
    use futures_util::StreamExt;

    let today = chrono::Local::now().format("%Y-%m-%d").to_string();
    let filename = match q.year {
        Some(y) => format!("patrimonio_realized_gains_{y}_{today}.csv"),
        None => format!("patrimonio_realized_gains_{today}.csv"),
    };

    let (tx, rx) = tokio::sync::mpsc::channel::<Result<Bytes, std::io::Error>>(16);
    let db = state.db.clone();
    let user_id = ctx.user_id;
    let year = q.year;

    tokio::spawn(async move {
        if tx
            .send(Ok(Bytes::from_static(
                b"sell_date,symbol,name,account,account_type,tax_advantaged,qty_sold,proceeds_usd,cost_usd,realized_pnl_usd,holding_days,long_term\n",
            )))
            .await
            .is_err()
        {
            return;
        }

        let mut stream = sqlx::query(REALIZED_DISPOSALS_SQL)
            .bind(user_id)
            .bind(year)
            .fetch(&db);

        while let Some(row_result) = stream.next().await {
            let row = match row_result {
                Ok(r) => r,
                Err(e) => {
                    error!("export_realized_gains_csv stream error: {}", e);
                    let _ = tx
                        .send(Err(std::io::Error::other(format!("csv stream: {e}"))))
                        .await;
                    return;
                }
            };
            let d = disposal_from_row(&row);
            let line = format!(
                // Money fields at 2dp (proceeds/cost/PnL are qty×price float
                // products that otherwise leak `.9999999999995` noise);
                // qty_sold keeps full precision for fractional lots.
                "{},{},{},{},{},{},{},{:.2},{:.2},{:.2},{},{}\n",
                d.sell_date,
                csv_field(&d.symbol),
                csv_field(&d.name),
                csv_field(d.account_name.as_deref().unwrap_or("")),
                csv_field(d.account_type.as_deref().unwrap_or("")),
                d.tax_advantaged,
                d.qty_sold,
                d.proceeds_usd,
                d.cost_usd,
                d.realized_pnl_usd,
                // Empty string for unknowns (deleted source lot), per C-E.
                d.holding_days.map(|v| v.to_string()).unwrap_or_default(),
                d.long_term.map(|v| v.to_string()).unwrap_or_default(),
            );
            if tx.send(Ok(Bytes::from(line))).await.is_err() {
                return;
            }
        }
    });

    let body =
        axum::body::Body::from_stream(tokio_stream::wrappers::ReceiverStream::new(rx));
    csv_attachment_response(&filename, body)
}

#[derive(Serialize)]
struct DashboardOverview {
    net_worth: f64,
    currency_breakdown: Vec<CurrencyBreakdown>,
    type_breakdown: Vec<TypeBreakdown>,
    institution_breakdown: Vec<InstitutionBreakdown>,
    accounts: Vec<AccountDetail>,
    /// USD->MXN rate actually used to convert MXN balances in this response.
    /// When `fx_stale` is true this is the last-known (possibly drifted) or
    /// hard-fallback rate; the UI should badge MXN-derived figures accordingly.
    fx_rate_used: f64,
    /// True when the FX rate is missing or older than 7 days — the converted
    /// MXN→USD figures (net worth, per-type/per-institution USD totals) are
    /// approximate and should be flagged in the UI.
    fx_stale: bool,
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
    /// Mexican CLABE (18-digit interbank number) when known — surfaced so the
    /// account view can show and copy it.
    #[serde(skip_serializing_if = "Option::is_none")]
    clabe: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    holder_name: Option<String>,
    /// "manual" for hand-added / statement-imported accounts, else the bank's
    /// integration (e.g. "plaid"). Lets the UI offer manual-holding editing
    /// only where it's safe (never on a Plaid-synced account).
    integration_type: String,
    /// Import-only (manual) accounts: when data last arrived — the later of
    /// the account row's last update (import confirm / manual balance edit)
    /// and the last transaction INSERT time. RFC3339; None for synced
    /// accounts (their freshness is the institution's sync status). Feeds
    /// the "as of <date>" chip and the dashboard staleness banner.
    /// ⚠ NOT derivable from balance_snapshots — the daily snapshot cron
    /// stamps every account every night, so that timestamp is always fresh.
    #[serde(skip_serializing_if = "Option::is_none")]
    last_data_at: Option<String>,
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
    /// Sum of cost bases over holdings whose basis is KNOWN. Holdings
    /// with an unknown basis (institution didn't report one — NULL in
    /// the DB, no lots) are excluded from `total_cost_basis` and from
    /// both sides of `total_gain_loss` / `total_gain_loss_pct`, while
    /// `total_value` still covers everything. See
    /// `holdings_without_basis` for how many were excluded.
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
    /// Number of holdings excluded from the gain/loss totals because
    /// no cost basis is available (lets the UI caveat the totals).
    holdings_without_basis: usize,
    /// USD->MXN rate used for the dual-currency (USD↔MXN) conversions above.
    fx_rate_used: f64,
    /// True when that FX rate is missing or older than 7 days — the MXN-side
    /// totals are approximate and should be flagged in the UI.
    fx_stale: bool,
    /// Contract C-B: portfolio day change summed over the COVERED rows (rows
    /// whose per-row `day_change_usd` is non-null). Null when no row is
    /// covered — the UI hides the "Today" pill rather than showing $0.
    day_change_usd: Option<f64>,
    /// Σ day change ÷ Σ prior-close value of covered rows × 100.
    day_change_pct: Option<f64>,
    /// Σ value_usd of covered rows ÷ total value_usd × 100 (0 when none) —
    /// lets the header pill carry an honest "covers N% of portfolio" note.
    day_change_coverage_pct: f64,
    /// Max covered close date (YYYY-MM-DD): the "as of" label for the pill.
    day_change_as_of: Option<String>,
    holdings: Vec<HoldingDetail>,
}

#[derive(Serialize)]
struct HoldingDetail {
    symbol: String,
    name: String,
    quantity: f64,
    price: f64,
    value: f64,
    /// None (JSON null) when the institution doesn't report a basis —
    /// e.g. Plaid employer plans, statement-imported holdings. Unknown
    /// is deliberately distinct from a true zero-cost position, which
    /// serialises as a real 0.0.
    cost_basis: Option<f64>,
    gain_loss: Option<f64>,
    /// None when the basis is unknown OR the position is zero-cost
    /// (percent return undefined).
    gain_loss_pct: Option<f64>,
    /// Per-holding dual-currency conversions. `value_usd` and
    /// `cost_basis_usd` always agree with the holding's native
    /// number when the security is USD-denominated; for MXN
    /// securities they're computed via current FX. The MXN side is
    /// always derivable from the USD side via current FX, but we
    /// pre-compute both so the frontend doesn't need the FX rate to
    /// render the row.
    value_usd: f64,
    value_mxn: f64,
    cost_basis_usd: Option<f64>,
    cost_basis_mxn: Option<f64>,
    gain_loss_usd: Option<f64>,
    gain_loss_mxn: Option<f64>,
    currency: String,
    holding_type: String,
    /// Canonical asset class (contract C2):
    /// equity|bonds|cash|crypto|real_estate|commodities|other. Derived from
    /// (holding_type, symbol, name) by `services::holdings::classify_asset`
    /// — same classifier as the allocation endpoint, so tapping an
    /// asset-class band filters to exactly the rows carrying its key.
    asset_class: String,
    /// Owning account's type (e.g. "401k", "brokerage") — lets the frontend
    /// filter the table when an account-type allocation band is tapped.
    account_type: String,
    account_name: String,
    institution_name: String,
    /// Contract C-B: change between the symbol's last two stored closes,
    /// applied to this row's USD value. All three stay null (real JSON
    /// nulls, no skip attrs) for cash sleeves, symbols with fewer than two
    /// stored closes, and closes older than 7 calendar days.
    day_change_usd: Option<f64>,
    day_change_pct: Option<f64>,
    /// Date of the latest stored close backing the day change (YYYY-MM-DD).
    price_as_of: Option<String>,
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
    /// Native currency of the card. Balance/limit are in this currency, so the
    /// client must convert before aggregating a portfolio-wide utilization.
    currency: String,
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
    /// Owning institution (e.g. "Capital One", "Chase"). Surfaced so the
    /// activity list and detail panel can disambiguate generic account
    /// labels like "Checking ••0916" — which on its own reads as an
    /// unknown account.
    #[serde(skip_serializing_if = "Option::is_none")]
    institution_name: Option<String>,
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
    /// Provenance: 'plaid' | 'csv' | 'manual' | 'split' (see the
    /// `transactions.source` column). Deliberately NOT skipped when
    /// absent — the frontend must never have to guess provenance
    /// (assuming 'plaid' put a "Synced via Plaid" chip on hand-typed
    /// rows); a null here renders as an explicit "unknown" state.
    source: Option<String>,
}

#[derive(Serialize)]
struct AllocationEntry {
    /// Human display label ("Bonds", "Stocks & funds") for the band.
    category: String,
    /// Canonical machine key (contract C2) the band filters on:
    /// equity|bonds|cash|crypto|real_estate|commodities|other.
    asset_class: String,
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
    /// Net cash moved into investments this period (buys positive, sells
    /// negative), USD. Peeled out of income/spending so the headline is
    /// clean, but surfaced as context so the money isn't invisible.
    invested: f64,
    /// Net internal transfer flow (money in positive, out negative), USD.
    /// Surfaced as context for the same reason.
    transferred: f64,
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
        WHERE a.user_id = $1 AND a.archived_at IS NULL
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
    // Same non-spend exclusions the cash-flow views apply (via the shared
    // fragments), so a recurring internal transfer, credit-card payment, loan
    // leg, or investment buy doesn't cluster into a phantom "subscription"
    // (honors user re-tags). The positive-only anti-joins are no-ops here.
    let sql = format!(
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
          AND {EFFECTIVE_CATEGORY_SQL} NOT IN {NON_CASHFLOW_CATEGORIES_SQL}{CASHFLOW_ROW_ANTI_JOINS_SQL}
        ORDER BY t.date DESC
        "#,
    );
    let rows = sqlx::query(&sql)
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
        let key = format!("{key_part}::{band}");
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
        cluster.events.sort_by_key(|e| std::cmp::Reverse(e.0));

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
        if !(5..=62).contains(&median_gap) {
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

/// Cap on concurrent live Yahoo dividend fetches. The per-account endpoint
/// hits these serially; the portfolio view fans out across every distinct
/// symbol the user holds, so we bound the in-flight requests to stay polite
/// to the free feed while still beating an N-serial loop.
const DIVIDEND_FETCH_CONCURRENCY: usize = 8;

/// One symbol's contribution to portfolio dividend income.
#[derive(Serialize)]
struct DividendSymbolContribution {
    symbol: String,
    /// Shares held across all of the user's accounts (combined).
    quantity: f64,
    /// Trailing-12-month dividend per share, native currency.
    annual_rate: f64,
    /// Projected annual income for the held quantity, converted to USD.
    annual_income_usd: f64,
    /// Yield on current value (annual_income / value), percent. Null when we
    /// have no price to value the position.
    yield_pct: Option<f64>,
    last_ex_date: Option<String>,
    est_next_ex_date: Option<String>,
    per_year: i32,
}

/// An upcoming estimated ex-dividend date for a held symbol.
#[derive(Serialize)]
struct UpcomingExDate {
    symbol: String,
    est_next_ex_date: String,
    /// Per-symbol projected income (USD) landing around that date.
    annual_income_usd: f64,
}

#[derive(Serialize)]
struct PortfolioDividendsResponse {
    /// Sum of per-symbol projected annual income, in USD.
    projected_annual_income_usd: f64,
    /// Blended yield-on-value: total projected income / total valued holdings,
    /// percent. Null when no priced, dividend-paying position exists.
    blended_yield_pct: Option<f64>,
    /// Per-symbol contributions, dividend payers first, by income descending.
    contributions: Vec<DividendSymbolContribution>,
    /// Every held payer's upcoming estimated ex-date, soonest first — one
    /// entry per payer, NO server-side cap (the old truncate-to-5 silently
    /// dropped the later-quarter dates; the list is bounded by payer count).
    upcoming_ex_dates: Vec<UpcomingExDate>,
    /// True when an MXN position was converted with a missing/stale FX rate.
    fx_stale: bool,
    /// Round 4 (contract C4-B): 12-month income calendar, starting at the
    /// current month (UTC). Additive — everything above is byte-identical
    /// to the round-3 response; consumers that don't know the field ignore
    /// it.
    calendar: Vec<DividendCalendarMonth>,
}

/// One month bucket of the projected dividend calendar (contract C4-B).
#[derive(Serialize)]
struct DividendCalendarMonth {
    /// `YYYY-MM`, UTC; the 12 buckets are chronological from the current month.
    month: String,
    /// Sum of the month's entries, rounded to cents (USD).
    total_usd: f64,
    /// Per-symbol projected payments, sorted `amount_usd` descending.
    entries: Vec<DividendCalendarEntry>,
}

/// One projected per-symbol payment inside a calendar month (contract C4-B).
#[derive(Serialize)]
struct DividendCalendarEntry {
    symbol: String,
    /// Estimated ex-date (YYYY-MM-DD).
    est_date: String,
    /// `annual_income_usd / per_year`, rounded to cents (USD — already
    /// FX-converted per sleeve upstream).
    amount_usd: f64,
}

/// The ONE date-stepping implementation shared by the detail endpoint's
/// `schedule` (see `build_dividend_detail`) and the calendar (C4-B): up to
/// `per_year` dates at `est_next + k*round(365/per_year)` days, pruned to
/// those within `horizon_days` of `est_next`. Empty for non-payers
/// (`per_year <= 0`) and missing/unparsable estimates.
fn projected_ex_dates(
    per_year: i32,
    est_next: Option<&str>,
    horizon_days: i64,
) -> Vec<chrono::NaiveDate> {
    if per_year <= 0 {
        return Vec::new();
    }
    let Some(start) =
        est_next.and_then(|d| chrono::NaiveDate::parse_from_str(d, "%Y-%m-%d").ok())
    else {
        return Vec::new();
    };
    let step = (365.0 / per_year as f64).round() as i64;
    (0..per_year as i64)
        .map(|k| start + chrono::Duration::days(step * k))
        .filter(|d| (*d - start).num_days() < horizon_days)
        .collect()
}

/// Contract C4-B: bucket every payer's projected payments into exactly 12
/// chronological `YYYY-MM` months starting at `today`'s month (UTC). Pure so
/// the bucketing, rounding, and ordering are unit-testable offline. Symbols
/// with `per_year == 0` (non-payers, failed fetches, unresolvable) and
/// zero-income payers contribute nothing; a projected date landing outside
/// the window (an annual payer's next date > 12 months out) is dropped —
/// the acknowledged small delta vs `projected_annual_income_usd`.
fn build_dividend_calendar(
    contributions: &[DividendSymbolContribution],
    today: chrono::NaiveDate,
) -> Vec<DividendCalendarMonth> {
    use chrono::Datelike;
    // 12 month keys from the current month; index for O(1) bucketing.
    let month_keys: Vec<String> = (0..12)
        .map(|i| {
            let m0 = today.year() * 12 + today.month0() as i32 + i;
            format!("{:04}-{:02}", m0.div_euclid(12), m0.rem_euclid(12) + 1)
        })
        .collect();
    let index: HashMap<&str, usize> =
        month_keys.iter().enumerate().map(|(i, k)| (k.as_str(), i)).collect();

    let mut buckets: Vec<Vec<DividendCalendarEntry>> =
        (0..12).map(|_| Vec::new()).collect();
    for c in contributions {
        if c.per_year <= 0 || c.annual_income_usd <= 0.0 {
            continue;
        }
        let amount = ((c.annual_income_usd / c.per_year as f64) * 100.0).round() / 100.0;
        for date in projected_ex_dates(c.per_year, c.est_next_ex_date.as_deref(), 365) {
            let key = format!("{:04}-{:02}", date.year(), date.month());
            if let Some(&i) = index.get(key.as_str()) {
                buckets[i].push(DividendCalendarEntry {
                    symbol: c.symbol.clone(),
                    est_date: date.to_string(),
                    amount_usd: amount,
                });
            }
        }
    }

    month_keys
        .into_iter()
        .zip(buckets)
        .map(|(month, mut entries)| {
            entries.sort_by(|a, b| {
                b.amount_usd.partial_cmp(&a.amount_usd).unwrap_or(std::cmp::Ordering::Equal)
            });
            let total_usd =
                (entries.iter().map(|e| e.amount_usd).sum::<f64>() * 100.0).round() / 100.0;
            DividendCalendarMonth { month, total_usd, entries }
        })
        .collect()
}

/// Every payer's upcoming estimated ex-date (est date >= `today`, ISO),
/// soonest first. Deliberately uncapped — the round-1 truncate-to-5 was
/// exactly what cut the September/October entries out of the upcoming list.
/// Pure so the no-cap behaviour is unit-testable offline.
fn upcoming_ex_dates(
    contributions: &[DividendSymbolContribution],
    today: &str,
) -> Vec<UpcomingExDate> {
    let mut upcoming: Vec<UpcomingExDate> = contributions
        .iter()
        .filter(|c| c.annual_income_usd > 0.0)
        .filter_map(|c| {
            c.est_next_ex_date
                .as_ref()
                .filter(|d| d.as_str() >= today)
                .map(|d| UpcomingExDate {
                    symbol: c.symbol.clone(),
                    est_next_ex_date: d.clone(),
                    annual_income_usd: c.annual_income_usd,
                })
        })
        .collect();
    upcoming.sort_by(|a, b| a.est_next_ex_date.cmp(&b.est_next_ex_date));
    upcoming
}

/// Portfolio-wide dividend income: aggregates the per-symbol dividend engine
/// across every active account the user holds, so the Portfolio tab can show
/// projected annual income, a blended yield-on-value, the top payers, the
/// next estimated ex-dates, and (round 4, C4-B) the 12-month income calendar.
/// Uses the Redis-cached fetch (`dividends::fetch_dividends_cached`, C4-C)
/// and fans the lookups out with bounded concurrency; a single symbol's
/// fetch failure degrades only that symbol's income to zero, never the
/// whole response.
async fn portfolio_dividends(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<PortfolioDividendsResponse> {
    let fx_info = latest_usd_mxn_rate(&state.db).await;
    let fx_usd_to_mxn = fx_info.rate;
    let mut fx_stale_used = false;

    // Combine quantity (and the latest seen price) per (symbol, currency)
    // across every active, non-cash holding. Grouping by currency too — not
    // one arbitrary MAX(currency)/MAX(price) per symbol — keeps a position
    // held in both a USD and an MXN account convertible per sleeve; the
    // sleeves merge back into one per-symbol contribution below. Cash-sleeve
    // rows are fixed at 1.00 and never pay a dividend, so they're filtered
    // out before the fan-out.
    let rows = sqlx::query(
        r#"
        SELECT h.symbol,
               h.currency,
               COALESCE(SUM(h.quantity), 0) AS quantity,
               MAX(h.price) AS price
        FROM holdings h
        JOIN accounts a ON h.account_id = a.id
        WHERE h.user_id = $1
          AND a.archived_at IS NULL
          AND h.deleted_at IS NULL
          AND COALESCE(h.holding_type, '') <> 'cash'
          AND h.symbol IS NOT NULL AND h.symbol <> ''
        GROUP BY h.symbol, h.currency
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    struct Pos {
        symbol: String,
        quantity: f64,
        price: Option<f64>,
        currency: String,
    }
    let positions: Vec<Pos> = rows
        .iter()
        .map(|r| {
            let quantity = r
                .try_get::<rust_decimal::Decimal, _>("quantity")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0);
            let price = r
                .try_get::<Option<rust_decimal::Decimal>, _>("price")
                .ok()
                .flatten()
                .map(|d| d.to_string().parse().unwrap_or(0.0));
            Pos {
                symbol: r.get("symbol"),
                quantity,
                price,
                currency: r.try_get("currency").unwrap_or_else(|_| "USD".to_string()),
            }
        })
        .collect();

    // Fan out the live dividend lookups with BOUNDED concurrency (mirrors the
    // sync batch's buffer_unordered pattern) instead of awaiting them one at a
    // time. Each future returns its symbol + the dividend tuple (or None on a
    // fetch error) so a single failure degrades only that symbol. Dedupe
    // first — a symbol held in two currencies is two positions but one fetch.
    use futures_util::StreamExt;
    let symbols: Vec<String> = {
        let mut seen = std::collections::HashSet::new();
        positions
            .iter()
            .filter(|p| seen.insert(p.symbol.clone()))
            .map(|p| p.symbol.clone())
            .collect()
    };
    let redis = &state.redis;
    let fetched: HashMap<String, (f64, Option<String>, Option<String>, i32)> =
        futures_util::stream::iter(symbols.into_iter().map(|symbol| {
            async move {
                // Same engine the per-account endpoint uses, now behind the
                // round-4 Redis envelope cache (C4-C) — the concurrency bound
                // mostly gates cold-cache fills. Map a fetch error to None so
                // it degrades to zero income for this symbol only.
                let info = match crate::services::dividends::fetch_dividends_cached(
                    redis, &symbol, false,
                )
                .await
                {
                    Ok(i) => Some((
                        i.annual_rate,
                        i.last_ex_date,
                        i.est_next_ex_date,
                        i.per_year,
                    )),
                    Err(_) => None,
                };
                (symbol, info)
            }
        }))
        .buffer_unordered(DIVIDEND_FETCH_CONCURRENCY)
        .collect::<Vec<_>>()
        .await
        .into_iter()
        .filter_map(|(sym, info)| info.map(|i| (sym, i)))
        .collect();

    let to_usd = |amount: f64, ccy: &str| -> f64 {
        match ccy {
            "USD" => amount,
            "MXN" => {
                if fx_usd_to_mxn > 0.0 {
                    amount / fx_usd_to_mxn
                } else {
                    amount
                }
            }
            _ => amount,
        }
    };

    let mut contributions: Vec<DividendSymbolContribution> = Vec::new();
    let mut total_income_usd = 0.0_f64;
    let mut total_valued_usd = 0.0_f64;

    // Merge the per-(symbol, currency) sleeves back into ONE contribution
    // per symbol: each sleeve converts its own income/value to USD before
    // the sums, so the per-symbol income is exactly the sum of the
    // correctly-converted per-account incomes.
    let mut symbol_order: Vec<&str> = Vec::new();
    let mut sleeves: HashMap<&str, Vec<&Pos>> = HashMap::new();
    for p in &positions {
        let entry = sleeves.entry(p.symbol.as_str()).or_default();
        if entry.is_empty() {
            symbol_order.push(p.symbol.as_str());
        }
        entry.push(p);
    }

    for symbol in symbol_order {
        // Missing tuple = fetch failed for this symbol: degrade to zero income
        // for it alone, but still surface the row so the position isn't hidden.
        let (annual_rate, last_ex_date, est_next_ex_date, per_year) =
            fetched.get(symbol).cloned().unwrap_or((0.0, None, None, 0));

        let mut quantity = 0.0_f64;
        let mut income_usd = 0.0_f64;
        let mut valued_usd = 0.0_f64;
        let mut priced = false;
        for p in &sleeves[symbol] {
            quantity += p.quantity;
            let income_native = annual_rate * p.quantity;
            income_usd += to_usd(income_native, &p.currency);
            if p.currency == "MXN" && income_native != 0.0 && fx_info.stale {
                fx_stale_used = true;
            }
            // Only priced sleeves feed the yield-on-value denominators.
            if let Some(px) = p.price.filter(|px| *px > 0.0) {
                valued_usd += to_usd(px * p.quantity, &p.currency);
                priced = true;
            }
        }

        let annual_income_usd = (income_usd * 100.0).round() / 100.0;
        // Income / value — identical to the old rate/price form for a
        // single-currency position, and well-defined when the symbol is
        // valued in two currencies.
        let yield_pct = if priced && valued_usd > 0.0 {
            Some(((annual_income_usd / valued_usd * 100.0) * 100.0).round() / 100.0)
        } else {
            None
        };

        total_valued_usd += valued_usd;
        total_income_usd += annual_income_usd;

        contributions.push(DividendSymbolContribution {
            symbol: symbol.to_string(),
            quantity,
            annual_rate,
            annual_income_usd,
            yield_pct,
            last_ex_date,
            est_next_ex_date,
            per_year,
        });
    }

    // Payers first, then by income descending; non-payers (zero income) sink
    // to the bottom while still being available to the frontend if it wants
    // the full list.
    contributions.sort_by(|a, b| {
        b.annual_income_usd
            .partial_cmp(&a.annual_income_usd)
            .unwrap_or(std::cmp::Ordering::Equal)
    });

    // ALL upcoming estimated ex-dates among held payers, soonest first — one
    // row per payer, uncapped (the list is bounded by payer count). ISO date
    // strings sort lexicographically, so a plain string sort/compare is
    // chronological; drop estimates already in the past (a payer whose last
    // dividend is older than one pay-interval estimates a date that has
    // already passed).
    let today_date = chrono::Utc::now().date_naive();
    let today = today_date.format("%Y-%m-%d").to_string();
    let upcoming = upcoming_ex_dates(&contributions, &today);

    // Round 4 (C4-B): 12-month projected income calendar, from the same
    // contributions the upcoming list reads.
    let calendar = build_dividend_calendar(&contributions, today_date);

    let total_income_usd = (total_income_usd * 100.0).round() / 100.0;
    let blended_yield_pct = if total_valued_usd > 0.0 && total_income_usd > 0.0 {
        Some(((total_income_usd / total_valued_usd * 100.0) * 100.0).round() / 100.0)
    } else {
        None
    };

    Json(PortfolioDividendsResponse {
        projected_annual_income_usd: total_income_usd,
        blended_yield_pct,
        contributions,
        upcoming_ex_dates: upcoming,
        fx_stale: fx_stale_used,
        calendar,
    })
}

/// One account's share of a position, for the dividend detail sheet (lets
/// the frontend badge Roth/IRA context per account).
#[derive(Serialize)]
struct DividendDetailAccount {
    account_id: String,
    account_name: String,
    account_type: String,
    quantity: f64,
}

/// One projected payment in the next-12-months schedule.
#[derive(Serialize)]
struct DividendScheduleEntry {
    /// Estimated ex-date (YYYY-MM-DD).
    est_date: String,
    /// Expected payment for the whole held position, USD.
    est_amount_usd: f64,
}

/// Per-symbol dividend detail (contract C1) — consumed by the Portfolio
/// tab's click-through sheet. Every nullable stays a real JSON `null` (no
/// skip attrs): the frontend is built against the full field set.
#[derive(Serialize)]
struct DividendDetailResponse {
    symbol: String,
    name: String,
    /// Native currency of the (dominant) position.
    currency: String,
    /// Shares held across all of the user's accounts.
    quantity: f64,
    /// Latest per-share price (native currency); null when unpriced.
    price: Option<f64>,
    market_value_usd: f64,
    /// Null when no account reports a basis (all-or-nothing: a partial
    /// basis would silently overstate yield-on-cost).
    cost_basis_usd: Option<f64>,
    /// Forward annual dividend per share, native currency.
    rate_per_share_annual: f64,
    per_year: i32,
    /// Expected USD payment per distribution for the whole position
    /// (= rate/per_year × quantity, converted).
    per_payment_amount: f64,
    annual_income_usd: f64,
    /// Income / market value, percent (0 when unvalued).
    yield_pct: f64,
    yield_on_cost_pct: Option<f64>,
    last_ex_date: Option<String>,
    est_next_ex_date: Option<String>,
    accounts: Vec<DividendDetailAccount>,
    /// Raw ~2y Yahoo event history, ascending by ex-date.
    history: Vec<crate::services::dividends::DividendEvent>,
    /// Next 12 months: `per_year` payments starting at `est_next_ex_date`,
    /// spaced 365/per_year days.
    schedule: Vec<DividendScheduleEntry>,
    /// Contract C-D: dividend payments that actually LANDED in the user's
    /// accounts, newest first (≤40). Conservatively matched (see
    /// `fetch_dividend_payments`) — may under-report, never mis-attributes.
    /// Empty when nothing matches; never an error.
    payments: Vec<DividendPayment>,
}

/// One real dividend transaction matched to this symbol (contract C-D).
#[derive(Serialize)]
struct DividendPayment {
    /// Transaction date (YYYY-MM-DD).
    date: String,
    amount_usd: f64,
    /// Receiving account's display name (nickname-aware).
    account_name: String,
}

/// Postgres regex matching `symbol` as a whole word (`\m…\M`), or `None`
/// when the symbol contains characters outside `[A-Za-z0-9.-]` — opaque
/// symbols (`CUR:USD`, 401k trust names with spaces) skip transaction
/// matching entirely rather than risk a malformed or over-broad pattern
/// (veto #8: conservative by design).
fn dividend_symbol_word_pattern(symbol: &str) -> Option<String> {
    let sym = symbol.trim();
    if sym.is_empty()
        || !sym
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || c == '.' || c == '-')
    {
        return None;
    }
    // Escape the two permitted non-alphanumerics ('.' would otherwise match
    // any character; '-' is escaped for belt-and-braces clarity).
    let escaped: String = sym
        .chars()
        .flat_map(|c| {
            if c.is_ascii_alphanumeric() {
                vec![c]
            } else {
                vec!['\\', c]
            }
        })
        .collect();
    Some(format!(r"\m{escaped}\M"))
}

/// The C-D payment-history query: positive transactions in the accounts
/// that hold the symbol, tagged `INCOME_DIVIDENDS` (or "dividend"-worded)
/// AND naming the ticker as a whole word. Deliberately conservative — a
/// broker description without the ticker won't match (under-reporting),
/// but a row can never be attributed to the wrong symbol or account.
async fn fetch_dividend_payments(
    db: &sqlx::PgPool,
    user_id: uuid::Uuid,
    holding_account_ids: &[uuid::Uuid],
    symbol: &str,
    fx_usd_to_mxn: f64,
) -> Vec<DividendPayment> {
    let Some(pattern) = dividend_symbol_word_pattern(symbol) else {
        return Vec::new();
    };
    if holding_account_ids.is_empty() {
        return Vec::new();
    }
    let rows = sqlx::query(
        r#"
        SELECT t.date, t.amount, t.currency,
               COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name
        FROM transactions t
        JOIN accounts a ON a.id = t.account_id
        WHERE a.user_id = $1
          AND t.account_id = ANY($2)
          AND t.amount > 0
          AND (UPPER(COALESCE(t.category_detailed, '')) = 'INCOME_DIVIDENDS'
               OR t.description ~* '\mdividend(o|s|os)?\M')
          AND t.description ~* $3
        ORDER BY t.date DESC
        LIMIT 40
        "#,
    )
    .bind(user_id)
    .bind(holding_account_ids)
    .bind(&pattern)
    .fetch_all(db)
    .await
    .unwrap_or_default();

    rows.iter()
        .map(|r| {
            let amount: f64 = r
                .try_get::<rust_decimal::Decimal, _>("amount")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0);
            let currency: String = r.try_get("currency").unwrap_or_else(|_| "USD".to_string());
            let amount_usd = match currency.as_str() {
                "USD" => amount,
                "MXN" => {
                    if fx_usd_to_mxn > 0.0 {
                        amount / fx_usd_to_mxn
                    } else {
                        amount
                    }
                }
                _ => amount,
            };
            DividendPayment {
                date: r
                    .try_get::<chrono::NaiveDate, _>("date")
                    .map(|d| d.to_string())
                    .unwrap_or_default(),
                amount_usd: (amount_usd * 100.0).round() / 100.0,
                account_name: r.try_get("account_name").unwrap_or_default(),
            }
        })
        .collect()
}

/// One of the user's holdings rows for the requested symbol (plus its
/// owning account), already decoded — input to `build_dividend_detail`.
struct DetailPosition {
    symbol: String,
    name: String,
    quantity: f64,
    price: Option<f64>,
    value: f64,
    cost_basis: Option<f64>,
    currency: String,
    account_id: String,
    account_name: String,
    account_type: String,
}

/// Assemble the C1 response from the user's rows + the (possibly empty)
/// dividend info. Pure so the shape and math are unit-testable offline.
/// `positions` must be non-empty, ordered by value descending — the first
/// row donates the representative name/price/currency.
fn build_dividend_detail(
    positions: &[DetailPosition],
    info: &crate::services::dividends::DividendInfo,
    fx_usd_to_mxn: f64,
    payments: Vec<DividendPayment>,
) -> DividendDetailResponse {
    let to_usd = |amount: f64, ccy: &str| -> f64 {
        match ccy {
            "USD" => amount,
            "MXN" => {
                if fx_usd_to_mxn > 0.0 {
                    amount / fx_usd_to_mxn
                } else {
                    amount
                }
            }
            _ => amount,
        }
    };
    let round2 = |v: f64| (v * 100.0).round() / 100.0;

    let first = &positions[0];
    let quantity: f64 = positions.iter().map(|p| p.quantity).sum();
    let market_value_usd = round2(positions.iter().map(|p| to_usd(p.value, &p.currency)).sum());

    // Basis is all-or-nothing: summing only the accounts that report one
    // would divide full income by a partial basis and overstate
    // yield-on-cost.
    let cost_basis_usd: Option<f64> = if positions.iter().all(|p| p.cost_basis.is_some()) {
        Some(round2(
            positions
                .iter()
                .map(|p| to_usd(p.cost_basis.unwrap_or(0.0), &p.currency))
                .sum(),
        ))
    } else {
        None
    };

    // Income converts per position (each row in its own currency), same as
    // the portfolio-wide endpoint.
    let annual_income_usd = round2(
        positions
            .iter()
            .map(|p| to_usd(info.annual_rate * p.quantity, &p.currency))
            .sum(),
    );
    let per_payment_amount = if info.per_year > 0 {
        ((annual_income_usd / info.per_year as f64) * 10000.0).round() / 10000.0
    } else {
        0.0
    };

    let yield_pct = if market_value_usd > 0.0 {
        round2(annual_income_usd / market_value_usd * 100.0)
    } else {
        0.0
    };
    let yield_on_cost_pct = cost_basis_usd
        .filter(|cb| *cb > 0.0)
        .map(|cb| round2(annual_income_usd / cb * 100.0));

    // Projection: per_year payments from est_next_ex_date, one cadence step
    // apart, each the expected per-payment amount. Empty for non-payers and
    // Yahoo-unresolvable symbols. Round 4: the stepping is the shared
    // `projected_ex_dates` — the SAME implementation the C4-B calendar uses,
    // so the two can never drift.
    let schedule: Vec<DividendScheduleEntry> =
        projected_ex_dates(info.per_year, info.est_next_ex_date.as_deref(), 365)
            .into_iter()
            .map(|d| DividendScheduleEntry {
                est_date: d.to_string(),
                est_amount_usd: per_payment_amount,
            })
            .collect();

    DividendDetailResponse {
        symbol: first.symbol.clone(),
        name: first.name.clone(),
        currency: first.currency.clone(),
        quantity,
        price: first.price,
        market_value_usd,
        cost_basis_usd,
        rate_per_share_annual: info.annual_rate,
        per_year: info.per_year,
        per_payment_amount,
        annual_income_usd,
        yield_pct,
        yield_on_cost_pct,
        last_ex_date: info.last_ex_date.clone(),
        est_next_ex_date: info.est_next_ex_date.clone(),
        accounts: positions
            .iter()
            .map(|p| DividendDetailAccount {
                account_id: p.account_id.clone(),
                account_name: p.account_name.clone(),
                account_type: p.account_type.clone(),
                quantity: p.quantity,
            })
            .collect(),
        history: info.history.clone(),
        schedule,
        payments,
    }
}

/// Contract C4-D query: `?refresh=true` bypasses the cache's fresh windows
/// (a live fetch happens even inside the 12 h window) while keeping the
/// stale-on-failure fallback. Absent/false → cached behavior.
#[derive(Deserialize)]
struct DividendDetailQuery {
    refresh: Option<bool>,
}

/// GET /dividends/{symbol} — dividend detail for one held symbol (contract
/// C1). Matched case-insensitively against the caller's non-cash holdings;
/// 404 when they hold no such symbol. A held symbol Yahoo can't resolve
/// (401k trust units, `CUR:USD` pseudo-symbols) still answers 200 with
/// zeroed rates and empty history/schedule — never a 500.
async fn dividend_detail(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    axum::extract::Path(symbol): axum::extract::Path<String>,
    Query(q): Query<DividendDetailQuery>,
) -> Response {
    let rows = sqlx::query(
        r#"
        SELECT h.symbol, h.name, h.quantity, h.price, h.value, h.cost_basis,
               h.currency, a.id AS account_id, a.account_type,
               COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name
        FROM holdings h
        JOIN accounts a ON h.account_id = a.id
        WHERE h.user_id = $1
          AND a.archived_at IS NULL
          AND h.deleted_at IS NULL
          AND COALESCE(h.holding_type, '') <> 'cash'
          AND UPPER(h.symbol) = UPPER($2)
        ORDER BY h.value DESC NULLS LAST
        "#,
    )
    .bind(ctx.user_id)
    .bind(&symbol)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    if rows.is_empty() {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "unknown symbol"})),
        )
            .into_response();
    }

    let dec_f64 = |r: &sqlx::postgres::PgRow, col: &str| -> Option<f64> {
        r.try_get::<Option<rust_decimal::Decimal>, _>(col)
            .ok()
            .flatten()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
    };
    let positions: Vec<DetailPosition> = rows
        .iter()
        .map(|r| DetailPosition {
            symbol: r.get("symbol"),
            name: r.get("name"),
            quantity: dec_f64(r, "quantity").unwrap_or(0.0),
            price: dec_f64(r, "price").filter(|p| *p > 0.0),
            value: dec_f64(r, "value").unwrap_or(0.0),
            cost_basis: dec_f64(r, "cost_basis"),
            currency: r.try_get("currency").unwrap_or_else(|_| "USD".to_string()),
            account_id: r
                .try_get::<uuid::Uuid, _>("account_id")
                .map(|u| u.to_string())
                .unwrap_or_default(),
            account_name: r.get("account_name"),
            account_type: r.try_get::<String, _>("account_type").unwrap_or_default(),
        })
        .collect();

    // Use the stored casing for the Yahoo lookup, not the caller's. A fetch
    // error degrades to the zeroed non-payer info — same policy as the
    // portfolio fan-out. Round 4: Redis-cached (C4-C); `?refresh=true`
    // bypasses the fresh windows (C4-D).
    let canonical_symbol = positions[0].symbol.clone();
    let info = crate::services::dividends::fetch_dividends_cached(
        &state.redis,
        &canonical_symbol,
        q.refresh.unwrap_or(false),
    )
    .await
    .unwrap_or_else(|_| crate::services::dividends::DividendInfo::none(&canonical_symbol));

    let fx_info = latest_usd_mxn_rate(&state.db).await;

    // C-D: real payments, matched only within the accounts that hold the
    // symbol (already fetched above).
    let holding_account_ids: Vec<uuid::Uuid> = rows
        .iter()
        .filter_map(|r| r.try_get::<uuid::Uuid, _>("account_id").ok())
        .collect();
    let payments = fetch_dividend_payments(
        &state.db,
        ctx.user_id,
        &holding_account_ids,
        &canonical_symbol,
        fx_info.rate,
    )
    .await;

    Json(build_dividend_detail(&positions, &info, fx_info.rate, payments)).into_response()
}

// =====================================================================
// Instrument detail (contract C-A)
// =====================================================================

/// One account's share of the position, for the instrument sheet.
#[derive(Serialize)]
struct InstrumentAccount {
    account_id: String,
    account_name: String,
    account_type: String,
    /// `services::tax::is_tax_advantaged_account_type` — the same list Tax
    /// planning uses.
    tax_advantaged: bool,
    quantity: f64,
    value_usd: f64,
}

/// One active purchase lot (depletion markers already filtered out).
#[derive(Serialize)]
struct InstrumentLot {
    acquired_at: String,
    qty: f64,
    cost_per_unit: f64,
    currency: String,
    usd_cost: f64,
}

/// One daily close of the instrument's stored price series.
#[derive(Serialize)]
struct InstrumentPricePoint {
    date: String,
    close: f64,
}

/// Per-symbol instrument detail (contract C-A) — consumed by the Portfolio
/// tab's instrument sheet. Every nullable stays a real JSON `null` (no skip
/// attrs): the frontend is built against the full field set.
#[derive(Serialize)]
struct InstrumentDetailResponse {
    symbol: String,
    name: String,
    /// Native currency of the (dominant) position.
    currency: String,
    /// Canonical asset class (contract C2), same classifier as holdings —
    /// reflects a user override (C3-A) when one exists.
    asset_class: String,
    /// C3-A: `"override"` when `asset_class` comes from the user's pinned
    /// classification, `"heuristic"` otherwise.
    asset_class_source: &'static str,
    /// C3-A extension: the `classify_asset` heuristic result regardless of
    /// any override — lets the sheet label its "Automatic — <class>" revert
    /// row while an override is active. Equals `asset_class` when
    /// `asset_class_source == "heuristic"`.
    asset_class_heuristic: &'static str,
    /// Shares held across all of the user's active accounts.
    quantity: f64,
    /// Latest per-share price (native currency); null when unpriced.
    price: Option<f64>,
    value_usd: f64,
    /// Null when any account's basis is unknown (all-or-nothing: a partial
    /// basis would silently misstate the gain).
    cost_basis_usd: Option<f64>,
    gain_loss_usd: Option<f64>,
    gain_loss_pct: Option<f64>,
    /// Symbol value ÷ total portfolio (holdings) value × 100.
    portfolio_weight_pct: f64,
    /// C-B day-change rules applied to the aggregate position: null for
    /// cash sleeves, <2 stored closes, or a stale (>7 day) latest close.
    day_change_usd: Option<f64>,
    day_change_pct: Option<f64>,
    price_as_of: Option<String>,
    accounts: Vec<InstrumentAccount>,
    lots: Vec<InstrumentLot>,
    /// Stored daily closes over the requested range, ascending. Empty for
    /// opaque/unresolvable symbols — never an error.
    prices: Vec<InstrumentPricePoint>,
}

/// One of the user's holdings rows for the requested symbol, already
/// decoded — input to `build_instrument_detail`. The per-holding USD basis
/// is pre-computed by the handler with the SAME lots-aware logic the
/// holdings endpoint uses.
struct InstrumentPosition {
    symbol: String,
    name: String,
    holding_type: String,
    quantity: f64,
    price: Option<f64>,
    value: f64,
    cost_basis_usd: Option<f64>,
    currency: String,
    account_id: String,
    account_name: String,
    account_type: String,
}

/// Inclusive start date for the requested chart range. Unknown/absent
/// values fail soft to the 1-year default.
fn instrument_range_start(range: Option<&str>, today: chrono::NaiveDate) -> chrono::NaiveDate {
    match range.unwrap_or("1y") {
        "1m" => today - chrono::Duration::days(31),
        "3m" => today - chrono::Duration::days(92),
        "max" => chrono::NaiveDate::from_ymd_opt(2000, 1, 1).unwrap(),
        _ => today - chrono::Duration::days(365),
    }
}

/// Assemble the C-A response from the user's rows + lots + stored prices.
/// Pure so the shape and math are unit-testable offline. `positions` must be
/// non-empty, ordered by value descending — the first row donates the
/// representative name/price/currency. `closes` is the symbol's last two
/// stored closes (newest first), when available.
#[allow(clippy::too_many_arguments)] // pure builder: the args ARE the contract inputs
fn build_instrument_detail(
    positions: &[InstrumentPosition],
    lots: Vec<InstrumentLot>,
    prices: &[(chrono::NaiveDate, f64)],
    closes: Option<&[(chrono::NaiveDate, f64)]>,
    asset_class_override: Option<&str>,
    total_portfolio_value_usd: f64,
    fx_usd_to_mxn: f64,
    today: chrono::NaiveDate,
) -> InstrumentDetailResponse {
    let to_usd = |amount: f64, ccy: &str| -> f64 {
        match ccy {
            "USD" => amount,
            "MXN" => {
                if fx_usd_to_mxn > 0.0 {
                    amount / fx_usd_to_mxn
                } else {
                    amount
                }
            }
            _ => amount,
        }
    };
    let round2 = |v: f64| (v * 100.0).round() / 100.0;

    let first = &positions[0];
    let quantity: f64 = positions.iter().map(|p| p.quantity).sum();
    let value_usd = round2(positions.iter().map(|p| to_usd(p.value, &p.currency)).sum());

    // Basis is all-or-nothing, same rationale as the dividend detail: a
    // partial basis would misstate the aggregate gain.
    let cost_basis_usd: Option<f64> = if positions.iter().all(|p| p.cost_basis_usd.is_some()) {
        Some(round2(
            positions.iter().map(|p| p.cost_basis_usd.unwrap_or(0.0)).sum(),
        ))
    } else {
        None
    };
    let gain_loss_usd = cost_basis_usd.map(|cb| round2(value_usd - cb));
    let gain_loss_pct = cost_basis_usd
        .filter(|cb| *cb > 0.0)
        .map(|cb| round2((value_usd - cb) / cb * 100.0));

    // C3-A precedence: the user's pinned class outranks the heuristic; the
    // source field tells the sheet which one it is showing. The heuristic is
    // always emitted too, so the sheet can label its "Automatic — <class>"
    // revert row while an override is active.
    let asset_class_heuristic = crate::services::holdings::classify_asset(
        &first.holding_type,
        &first.symbol,
        &first.name,
    );
    let (asset_class, asset_class_source) = match asset_class_override {
        Some(c) => (c.to_string(), "override"),
        None => (asset_class_heuristic.to_string(), "heuristic"),
    };
    let is_cash = first.holding_type == "cash" || asset_class == "cash";
    let day = day_change_for_row(value_usd, is_cash, closes, today);

    let portfolio_weight_pct = if total_portfolio_value_usd > 0.0 {
        round2(value_usd / total_portfolio_value_usd * 100.0)
    } else {
        0.0
    };

    InstrumentDetailResponse {
        symbol: first.symbol.clone(),
        name: first.name.clone(),
        currency: first.currency.clone(),
        asset_class,
        asset_class_source,
        asset_class_heuristic,
        quantity,
        price: first.price,
        value_usd,
        cost_basis_usd,
        gain_loss_usd,
        gain_loss_pct,
        portfolio_weight_pct,
        day_change_usd: day.as_ref().map(|d| round2(d.day_change_usd)),
        day_change_pct: day.as_ref().map(|d| round2(d.day_change_pct)),
        price_as_of: day.as_ref().map(|d| d.as_of.to_string()),
        accounts: positions
            .iter()
            .map(|p| InstrumentAccount {
                account_id: p.account_id.clone(),
                account_name: p.account_name.clone(),
                account_type: p.account_type.clone(),
                tax_advantaged: crate::services::tax::is_tax_advantaged_account_type(Some(
                    &p.account_type,
                )),
                quantity: p.quantity,
                value_usd: round2(to_usd(p.value, &p.currency)),
            })
            .collect(),
        lots,
        prices: prices
            .iter()
            .map(|(d, c)| InstrumentPricePoint {
                date: d.to_string(),
                close: *c,
            })
            .collect(),
    }
}

#[derive(Deserialize)]
struct InstrumentQuery {
    /// Chart range: 1m | 3m | 1y (default) | max.
    range: Option<String>,
}

/// GET /instruments/{symbol} — instrument detail for one held symbol
/// (contract C-A). Matched case-insensitively against the caller's
/// active-account holdings; 404 when they hold no such symbol. Opaque
/// symbols (401k trust units, `CUR:USD`) still answer 200 with empty
/// `prices` and null day-change stats — never a 500. Prices come from the
/// stored `benchmark_prices` series after a best-effort 4-day-gated
/// refresh, and ONLY for ticker-shaped symbols (no doomed Yahoo lookups
/// for trust-fund names).
async fn instrument_detail(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    axum::extract::Path(symbol): axum::extract::Path<String>,
    Query(q): Query<InstrumentQuery>,
) -> Response {
    let fx_info = latest_usd_mxn_rate(&state.db).await;
    let fx_usd_to_mxn = fx_info.rate;

    let rows = sqlx::query(
        r#"
        SELECT h.id, h.symbol, h.name, h.quantity, h.price, h.value, h.cost_basis,
               h.currency, COALESCE(h.holding_type, '') AS holding_type,
               a.id AS account_id, a.account_type,
               COALESCE(NULLIF(a.nickname, ''), a.name) AS account_name
        FROM holdings h
        JOIN accounts a ON h.account_id = a.id
        WHERE h.user_id = $1
          AND a.archived_at IS NULL
          AND h.deleted_at IS NULL
          AND UPPER(h.symbol) = UPPER($2)
        ORDER BY h.value DESC NULLS LAST
        "#,
    )
    .bind(ctx.user_id)
    .bind(&symbol)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    if rows.is_empty() {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "unknown symbol"})),
        )
            .into_response();
    }

    // Active lots for these holdings — both the per-lot breakdown and the
    // lots-preferred (FX-aware) cost basis, mirroring the holdings handler.
    let holding_ids: Vec<uuid::Uuid> = rows
        .iter()
        .filter_map(|r| r.try_get::<uuid::Uuid, _>("id").ok())
        .collect();
    let lot_rows = sqlx::query(
        r#"
        SELECT holding_id, qty, cost_per_unit, currency, usd_fx_rate, acquired_at
        FROM holding_lots
        WHERE user_id = $1 AND holding_id = ANY($2) AND qty > 0
        ORDER BY acquired_at ASC, id ASC
        "#,
    )
    .bind(ctx.user_id)
    .bind(&holding_ids)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    let mut lots: Vec<InstrumentLot> = Vec::new();
    let mut lot_basis_by_holding: HashMap<uuid::Uuid, f64> = HashMap::new();
    for r in &lot_rows {
        let hid: uuid::Uuid = match r.try_get("holding_id") {
            Ok(v) => v,
            Err(_) => continue,
        };
        let dec = |col: &str| -> f64 {
            r.try_get::<rust_decimal::Decimal, _>(col)
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0)
        };
        let qty = dec("qty");
        let cpu = dec("cost_per_unit");
        let fx = dec("usd_fx_rate");
        let ccy: String = r.try_get("currency").unwrap_or_else(|_| "USD".to_string());
        let native_cost = qty * cpu;
        // Same conversion as the holdings handler's lots-preferred basis:
        // the lot's own historical FX rate, current-FX fallback.
        let usd_cost = match ccy.as_str() {
            "USD" => native_cost,
            "MXN" => {
                if fx > 0.0 {
                    native_cost / fx
                } else {
                    native_cost / fx_usd_to_mxn
                }
            }
            _ => native_cost,
        };
        *lot_basis_by_holding.entry(hid).or_insert(0.0) += usd_cost;
        lots.push(InstrumentLot {
            acquired_at: r
                .try_get::<chrono::NaiveDate, _>("acquired_at")
                .map(|d| d.to_string())
                .unwrap_or_default(),
            qty,
            cost_per_unit: cpu,
            currency: ccy,
            usd_cost,
        });
    }

    let dec_f64 = |r: &sqlx::postgres::PgRow, col: &str| -> Option<f64> {
        r.try_get::<Option<rust_decimal::Decimal>, _>(col)
            .ok()
            .flatten()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
    };
    let positions: Vec<InstrumentPosition> = rows
        .iter()
        .map(|r| {
            let currency: String = r.try_get("currency").unwrap_or_else(|_| "USD".to_string());
            let hid: uuid::Uuid = r.try_get("id").unwrap_or_else(|_| uuid::Uuid::nil());
            // Lots-preferred USD basis; flat-basis fallback at current FX —
            // exactly the holdings handler's policy.
            let cost_basis_usd = lot_basis_by_holding.get(&hid).copied().or_else(|| {
                dec_f64(r, "cost_basis").map(|cb| match currency.as_str() {
                    "USD" => cb,
                    "MXN" => {
                        if fx_usd_to_mxn > 0.0 {
                            cb / fx_usd_to_mxn
                        } else {
                            cb
                        }
                    }
                    _ => cb,
                })
            });
            InstrumentPosition {
                symbol: r.get("symbol"),
                name: r.get("name"),
                holding_type: r.try_get("holding_type").unwrap_or_default(),
                quantity: dec_f64(r, "quantity").unwrap_or(0.0),
                price: dec_f64(r, "price").filter(|p| *p > 0.0),
                value: dec_f64(r, "value").unwrap_or(0.0),
                cost_basis_usd,
                currency,
                account_id: r
                    .try_get::<uuid::Uuid, _>("account_id")
                    .map(|u| u.to_string())
                    .unwrap_or_default(),
                account_name: r.get("account_name"),
                account_type: r.try_get::<String, _>("account_type").unwrap_or_default(),
            }
        })
        .collect();

    // Denominator for the portfolio weight: every active-account holding,
    // converted with the same MXN policy as the holdings handler.
    let total_portfolio_value_usd: f64 = sqlx::query(
        r#"
        SELECT COALESCE(SUM(
            CASE WHEN h.currency = 'MXN' THEN h.value / $1::numeric ELSE h.value END
        ), 0) AS total
        FROM holdings h
        JOIN accounts a ON h.account_id = a.id
        WHERE h.user_id = $2 AND a.archived_at IS NULL AND h.deleted_at IS NULL
        "#,
    )
    .bind(fx_usd_to_mxn)
    .bind(ctx.user_id)
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten()
    .and_then(|r| r.try_get::<rust_decimal::Decimal, _>("total").ok())
    .and_then(|d| d.to_string().parse::<f64>().ok())
    .unwrap_or(0.0);

    // Round 3 (C3-A): the caller's override for this one symbol — a single
    // indexed PK lookup, passed into the pure builder as Option<&str>.
    let asset_class_override: Option<String> = sqlx::query_scalar(
        "SELECT asset_class FROM asset_class_overrides WHERE user_id = $1 AND symbol = $2",
    )
    .bind(ctx.user_id)
    .bind(positions[0].symbol.trim().to_uppercase())
    .fetch_optional(&state.db)
    .await
    .unwrap_or(None);

    // Stored price series — ticker-shaped symbols only. `ensure_symbol_fresh`
    // is best-effort (4-day gate, tolerates network failure when cached data
    // exists); opaque symbols skip straight to the empty-series degradation.
    let today = chrono::Utc::now().date_naive();
    let canonical_symbol = positions[0].symbol.clone();
    let (prices, closes_by_symbol) =
        if crate::services::twr::looks_like_ticker(&canonical_symbol) {
            let _ = crate::services::benchmark::ensure_symbol_fresh(
                &state.db,
                &canonical_symbol,
                &canonical_symbol,
            )
            .await;
            let from = instrument_range_start(q.range.as_deref(), today);
            (
                crate::services::benchmark::series(&state.db, &canonical_symbol, from).await,
                latest_two_closes(&state.db, std::slice::from_ref(&canonical_symbol)).await,
            )
        } else {
            (Vec::new(), HashMap::new())
        };
    let closes = closes_by_symbol
        .get(&canonical_symbol)
        .map(|v| v.as_slice());

    Json(build_instrument_detail(
        &positions,
        lots,
        &prices,
        closes,
        asset_class_override.as_deref(),
        total_portfolio_value_usd,
        fx_usd_to_mxn,
        today,
    ))
    .into_response()
}

/// Contract C3-A request body: `{"asset_class": "bonds"}` sets an override,
/// `{"asset_class": null}` clears it back to the heuristic.
#[derive(Deserialize)]
struct AssetClassOverrideRequest {
    asset_class: Option<String>,
}

/// PUT /instruments/{symbol}/asset-class — pin (UPSERT) or clear (DELETE) the
/// caller's asset-class override for a held symbol (contract C3-A). Keyed
/// per (user, UPPER(TRIM(symbol))) in `asset_class_overrides`, NOT on the
/// holdings row — import/sync churns holdings rows, and a classification is a
/// property of the instrument, so one edit covers every account holding it.
async fn set_asset_class_override(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    axum::extract::Path(symbol): axum::extract::Path<String>,
    Json(payload): Json<AssetClassOverrideRequest>,
) -> Response {
    // Validate BEFORE the held check so a bogus class is always 422, even
    // for a symbol the caller doesn't hold.
    if let Some(ref class) = payload.asset_class {
        if !crate::services::holdings::ASSET_CLASSES.contains(&class.as_str()) {
            return (
                StatusCode::UNPROCESSABLE_ENTITY,
                Json(serde_json::json!({"error": "invalid asset class"})),
            )
                .into_response();
        }
    }

    // Same case-insensitive active-holdings match as `instrument_detail`; the
    // top-value row donates the representative type/name for the heuristic
    // fallback in the response.
    let row = sqlx::query(
        r#"
        SELECT h.symbol, h.name, COALESCE(h.holding_type, '') AS holding_type
        FROM holdings h
        JOIN accounts a ON h.account_id = a.id
        WHERE h.user_id = $1
          AND a.archived_at IS NULL
          AND h.deleted_at IS NULL
          AND UPPER(h.symbol) = UPPER($2)
        ORDER BY h.value DESC NULLS LAST
        LIMIT 1
        "#,
    )
    .bind(ctx.user_id)
    .bind(&symbol)
    .fetch_optional(&state.db)
    .await
    .unwrap_or(None);

    let Some(row) = row else {
        return (
            StatusCode::NOT_FOUND,
            Json(serde_json::json!({"error": "unknown symbol"})),
        )
            .into_response();
    };
    let held_symbol: String = row.get("symbol");
    let held_name: String = row.try_get("name").unwrap_or_default();
    let held_type: String = row.try_get("holding_type").unwrap_or_default();
    // Overrides are stored normalized — the same UPPER(TRIM) key every
    // classify site looks up.
    let key = held_symbol.trim().to_uppercase();

    let write = match payload.asset_class.as_deref() {
        Some(class) => {
            sqlx::query(
                "INSERT INTO asset_class_overrides (user_id, symbol, asset_class, updated_at) \
                 VALUES ($1, $2, $3, now()) \
                 ON CONFLICT (user_id, symbol) \
                 DO UPDATE SET asset_class = EXCLUDED.asset_class, updated_at = now()",
            )
            .bind(ctx.user_id)
            .bind(&key)
            .bind(class)
            .execute(&state.db)
            .await
        }
        None => {
            sqlx::query("DELETE FROM asset_class_overrides WHERE user_id = $1 AND symbol = $2")
                .bind(ctx.user_id)
                .bind(&key)
                .execute(&state.db)
                .await
        }
    };
    if let Err(e) = write {
        error!("Failed to write asset-class override for {key}: {e}");
        return StatusCode::INTERNAL_SERVER_ERROR.into_response();
    }

    // Echo the now-effective classification: the override when set, the
    // heuristic after a clear.
    let (asset_class, source) = match payload.asset_class {
        Some(class) => (class, "override"),
        None => (
            crate::services::holdings::classify_asset(&held_type, &held_symbol, &held_name)
                .to_string(),
            "heuristic",
        ),
    };
    Json(serde_json::json!({
        "symbol": key,
        "asset_class": asset_class,
        "asset_class_source": source,
    }))
    .into_response()
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::dividends::{DividendEvent, DividendInfo};

    /// The C1 contract shape, field for field, for a quarterly payer. The
    /// frontend sheet is built against exactly this JSON.
    #[test]
    fn dividend_detail_matches_contract_c1_for_quarterly_payer() {
        let positions = vec![DetailPosition {
            symbol: "NVDA".to_string(),
            name: "NVIDIA Corp".to_string(),
            quantity: 29.5,
            price: Some(172.40),
            value: 5085.80,
            cost_basis: Some(3100.00),
            currency: "USD".to_string(),
            account_id: "6e9c1a4e-0000-0000-0000-000000000001".to_string(),
            account_name: "Robinhood".to_string(),
            account_type: "brokerage".to_string(),
        }];
        let info = DividendInfo {
            symbol: "NVDA".to_string(),
            annual_rate: 0.04,
            last_amount: 0.01,
            last_ex_date: Some("2026-06-11".to_string()),
            est_next_ex_date: Some("2026-09-10".to_string()),
            per_year: 4,
            history: vec![
                DividendEvent { ex_date: "2024-08-28".to_string(), amount_per_share: 0.01 },
                DividendEvent { ex_date: "2026-06-11".to_string(), amount_per_share: 0.01 },
            ],
        };

        let got =
            serde_json::to_value(build_dividend_detail(&positions, &info, 20.0, Vec::new()))
                .unwrap();
        let want = serde_json::json!({
            "symbol": "NVDA",
            "name": "NVIDIA Corp",
            "currency": "USD",
            "quantity": 29.5,
            "price": 172.40,
            "market_value_usd": 5085.80,
            "cost_basis_usd": 3100.00,
            "rate_per_share_annual": 0.04,
            "per_year": 4,
            "per_payment_amount": 0.295,
            "annual_income_usd": 1.18,
            "yield_pct": 0.02,
            "yield_on_cost_pct": 0.04,
            "last_ex_date": "2026-06-11",
            "est_next_ex_date": "2026-09-10",
            "accounts": [
                {
                    "account_id": "6e9c1a4e-0000-0000-0000-000000000001",
                    "account_name": "Robinhood",
                    "account_type": "brokerage",
                    "quantity": 29.5
                }
            ],
            "history": [
                {"ex_date": "2024-08-28", "amount_per_share": 0.01},
                {"ex_date": "2026-06-11", "amount_per_share": 0.01}
            ],
            "schedule": [
                {"est_date": "2026-09-10", "est_amount_usd": 0.295},
                {"est_date": "2026-12-10", "est_amount_usd": 0.295},
                {"est_date": "2027-03-11", "est_amount_usd": 0.295},
                {"est_date": "2027-06-10", "est_amount_usd": 0.295}
            ],
            "payments": []
        });
        assert_eq!(got, want);
    }

    /// A held symbol Yahoo can't resolve (401k trust units, CUR:USD): 200
    /// with zeroed rates, nulls, and empty history/schedule — never a 500.
    #[test]
    fn dividend_detail_unresolvable_symbol_degrades_to_nulls_and_empties() {
        let positions = vec![DetailPosition {
            symbol: "VANG TARGET RET 2045".to_string(),
            name: "Vanguard Target Retirement 2045 Trust".to_string(),
            quantity: 100.0,
            price: None,
            value: 0.0,
            cost_basis: None,
            currency: "USD".to_string(),
            account_id: "6e9c1a4e-0000-0000-0000-000000000002".to_string(),
            account_name: "Employer 401k".to_string(),
            account_type: "401k".to_string(),
        }];
        let info = DividendInfo::none("VANG TARGET RET 2045");

        let got =
            serde_json::to_value(build_dividend_detail(&positions, &info, 20.0, Vec::new()))
                .unwrap();
        assert_eq!(got["per_year"], 0);
        assert_eq!(got["rate_per_share_annual"], 0.0);
        assert_eq!(got["annual_income_usd"], 0.0);
        assert_eq!(got["yield_pct"], 0.0);
        // Nullables are real JSON nulls, not absent keys.
        assert!(got["price"].is_null());
        assert!(got["cost_basis_usd"].is_null());
        assert!(got["yield_on_cost_pct"].is_null());
        assert!(got["last_ex_date"].is_null());
        assert!(got["est_next_ex_date"].is_null());
        assert_eq!(got["history"], serde_json::json!([]));
        assert_eq!(got["schedule"], serde_json::json!([]));
        assert_eq!(got["accounts"][0]["account_type"], "401k");
    }

    /// Same symbol held in USD and MXN accounts: each sleeve converts in its
    /// own currency before the sums (B5).
    #[test]
    fn dividend_detail_converts_each_currency_sleeve_separately() {
        let positions = vec![
            DetailPosition {
                symbol: "ACME".to_string(),
                name: "Acme Corp".to_string(),
                quantity: 10.0,
                price: Some(100.0),
                value: 1000.0,
                cost_basis: Some(800.0),
                currency: "USD".to_string(),
                account_id: "a".to_string(),
                account_name: "US broker".to_string(),
                account_type: "brokerage".to_string(),
            },
            DetailPosition {
                symbol: "ACME".to_string(),
                name: "Acme Corp".to_string(),
                quantity: 10.0,
                price: Some(2000.0),
                value: 20000.0,
                cost_basis: Some(16000.0),
                currency: "MXN".to_string(),
                account_id: "b".to_string(),
                account_name: "MX broker".to_string(),
                account_type: "brokerage".to_string(),
            },
        ];
        let info = DividendInfo {
            symbol: "ACME".to_string(),
            annual_rate: 4.0,
            last_amount: 1.0,
            last_ex_date: Some("2026-06-01".to_string()),
            est_next_ex_date: Some("2026-08-31".to_string()),
            per_year: 4,
            history: Vec::new(),
        };

        let got =
            serde_json::to_value(build_dividend_detail(&positions, &info, 20.0, Vec::new()))
                .unwrap();
        // 1000 USD + 20000 MXN / 20 = 2000 USD.
        assert_eq!(got["market_value_usd"], 2000.0);
        // Income: 40 USD + 40 MXN / 20 = 42 USD; NOT 80 (both as USD) nor
        // 4 (both as MXN) — the old MAX(currency) bug's two failure modes.
        assert_eq!(got["annual_income_usd"], 42.0);
        // Basis: 800 USD + 16000 MXN / 20 = 1600 USD.
        assert_eq!(got["cost_basis_usd"], 1600.0);
        assert_eq!(got["quantity"], 20.0);
        assert_eq!(got["accounts"].as_array().unwrap().len(), 2);
    }

    // =================================================================
    // C-B — day change from stored closes
    // =================================================================

    fn day(y: i32, m: u32, d: u32) -> chrono::NaiveDate {
        chrono::NaiveDate::from_ymd_opt(y, m, d).unwrap()
    }

    /// Cash sleeves never carry a day change, even with a fresh series.
    #[test]
    fn day_change_null_for_cash_row() {
        let closes = [(day(2026, 7, 2), 1.0), (day(2026, 7, 1), 1.0)];
        assert!(day_change_for_row(200.0, true, Some(&closes), day(2026, 7, 6)).is_none());
    }

    /// One stored close (or none) is not enough to compute a change.
    #[test]
    fn day_change_null_for_single_close_or_missing_series() {
        let one = [(day(2026, 7, 2), 171.7)];
        assert!(day_change_for_row(1000.0, false, Some(&one), day(2026, 7, 6)).is_none());
        assert!(day_change_for_row(1000.0, false, None, day(2026, 7, 6)).is_none());
    }

    /// A latest close more than 7 calendar days old is stale — null rather
    /// than presenting a week-old move as "today".
    #[test]
    fn day_change_null_for_stale_close() {
        let stale = [(day(2026, 6, 28), 102.0), (day(2026, 6, 27), 100.0)];
        assert!(day_change_for_row(1000.0, false, Some(&stale), day(2026, 7, 6)).is_none());
        // Exactly 7 days old is still acceptable (weekend + holiday runs).
        let edge = [(day(2026, 6, 29), 102.0), (day(2026, 6, 28), 100.0)];
        assert!(day_change_for_row(1000.0, false, Some(&edge), day(2026, 7, 6)).is_some());
    }

    /// pct = (c0 − c1)/c1 in the symbol's native currency; the row's USD
    /// change scales its USD value by that same ratio.
    #[test]
    fn day_change_math_from_last_two_closes() {
        let closes = [(day(2026, 7, 2), 102.0), (day(2026, 7, 1), 100.0)];
        let rc = day_change_for_row(1000.0, false, Some(&closes), day(2026, 7, 6)).unwrap();
        assert!((rc.day_change_pct - 2.0).abs() < 1e-9);
        assert!((rc.day_change_usd - 20.0).abs() < 1e-9);
        assert_eq!(rc.as_of, day(2026, 7, 2));
    }

    /// Coverage counts ONLY rows with a known day change; the top-level pct
    /// divides by the covered rows' prior value; as_of is the max covered
    /// close date.
    #[test]
    fn day_change_totals_coverage_and_pct_math() {
        // Covered: 1020 (chg +20, as-of Jul 2), 510 (chg +10, as-of Jul 1).
        // Uncovered: a 470 trust row → coverage = 1530/2000 = 76.5%.
        let rows = vec![
            (1020.0, Some(20.0), Some("2026-07-02")),
            (510.0, Some(10.0), Some("2026-07-01")),
            (470.0, None, None),
        ];
        let t = day_change_totals(rows.into_iter());
        assert!((t.day_change_usd.unwrap() - 30.0).abs() < 1e-9);
        // Prior value = (1020-20) + (510-10) = 1500 → 30/1500 = 2%.
        assert!((t.day_change_pct.unwrap() - 2.0).abs() < 1e-9);
        assert!((t.coverage_pct - 76.5).abs() < 1e-9);
        assert_eq!(t.as_of.as_deref(), Some("2026-07-02"));
    }

    /// No covered rows: null totals, 0 coverage — the UI hides the pill.
    #[test]
    fn day_change_totals_null_when_nothing_covered() {
        let rows = vec![(470.0, None, None), (200.0, None, None)];
        let t = day_change_totals(rows.into_iter());
        assert!(t.day_change_usd.is_none());
        assert!(t.day_change_pct.is_none());
        assert!((t.coverage_pct - 0.0).abs() < 1e-9);
        assert!(t.as_of.is_none());
    }

    // =================================================================
    // C-A — instrument detail
    // =================================================================

    /// The C-A contract shape, field for field, for a held ticker. The
    /// frontend instrument sheet is built against exactly this JSON.
    #[test]
    fn instrument_detail_matches_contract_c_a_for_held_ticker() {
        let positions = vec![InstrumentPosition {
            symbol: "NVDA".to_string(),
            name: "NVIDIA Corp".to_string(),
            holding_type: "equity".to_string(),
            quantity: 29.5,
            price: Some(172.40),
            value: 5085.80,
            cost_basis_usd: Some(3100.00),
            currency: "USD".to_string(),
            account_id: "6e9c1a4e-0000-0000-0000-000000000001".to_string(),
            account_name: "Robinhood".to_string(),
            account_type: "brokerage".to_string(),
        }];
        let lots = vec![InstrumentLot {
            acquired_at: "2024-03-01".to_string(),
            qty: 10.0,
            cost_per_unit: 88.10,
            currency: "USD".to_string(),
            usd_cost: 881.00,
        }];
        let prices = vec![(day(2026, 7, 1), 170.0), (day(2026, 7, 2), 171.7)];
        // Newest first, +1.0% day move.
        let closes = [(day(2026, 7, 2), 171.7), (day(2026, 7, 1), 170.0)];

        let got = serde_json::to_value(build_instrument_detail(
            &positions,
            lots,
            &prices,
            Some(&closes),
            None,
            1_525_740.0,
            20.0,
            day(2026, 7, 6),
        ))
        .unwrap();
        let want = serde_json::json!({
            "symbol": "NVDA",
            "name": "NVIDIA Corp",
            "currency": "USD",
            "asset_class": "equity",
            "asset_class_source": "heuristic",
            "asset_class_heuristic": "equity",
            "quantity": 29.5,
            "price": 172.40,
            "value_usd": 5085.80,
            "cost_basis_usd": 3100.00,
            "gain_loss_usd": 1985.80,
            "gain_loss_pct": 64.06,
            "portfolio_weight_pct": 0.33,
            "day_change_usd": 50.86,
            "day_change_pct": 1.0,
            "price_as_of": "2026-07-02",
            "accounts": [
                {
                    "account_id": "6e9c1a4e-0000-0000-0000-000000000001",
                    "account_name": "Robinhood",
                    "account_type": "brokerage",
                    "tax_advantaged": false,
                    "quantity": 29.5,
                    "value_usd": 5085.80
                }
            ],
            "lots": [
                {"acquired_at": "2024-03-01", "qty": 10.0, "cost_per_unit": 88.10,
                 "currency": "USD", "usd_cost": 881.00}
            ],
            "prices": [
                {"date": "2026-07-01", "close": 170.0},
                {"date": "2026-07-02", "close": 171.7}
            ]
        });
        assert_eq!(got, want);
    }

    /// An opaque symbol (401k trust units): 200 with empty prices and null
    /// price/basis/day-change stats — everything else still renders. The
    /// 401k account is flagged tax-advantaged via the tax module's list.
    #[test]
    fn instrument_detail_opaque_symbol_degrades_to_empty_prices_and_nulls() {
        let positions = vec![InstrumentPosition {
            symbol: "VANG TARGET RET 2045".to_string(),
            name: "Vanguard Target Retirement 2045 Trust".to_string(),
            holding_type: String::new(),
            quantity: 100.0,
            price: None,
            value: 12000.0,
            cost_basis_usd: None,
            currency: "USD".to_string(),
            account_id: "6e9c1a4e-0000-0000-0000-000000000002".to_string(),
            account_name: "Employer 401k".to_string(),
            account_type: "401k".to_string(),
        }];

        let got = serde_json::to_value(build_instrument_detail(
            &positions,
            Vec::new(),
            &[],
            None,
            None,
            24000.0,
            20.0,
            day(2026, 7, 6),
        ))
        .unwrap();
        assert_eq!(got["symbol"], "VANG TARGET RET 2045");
        // Name/type default classifies trust units as equity (round-1 C2).
        assert_eq!(got["asset_class"], "equity");
        assert_eq!(got["asset_class_source"], "heuristic");
        assert_eq!(got["asset_class_heuristic"], "equity");
        assert_eq!(got["value_usd"], 12000.0);
        assert_eq!(got["portfolio_weight_pct"], 50.0);
        // Nullables are real JSON nulls, not absent keys.
        assert!(got["price"].is_null());
        assert!(got["cost_basis_usd"].is_null());
        assert!(got["gain_loss_usd"].is_null());
        assert!(got["gain_loss_pct"].is_null());
        assert!(got["day_change_usd"].is_null());
        assert!(got["day_change_pct"].is_null());
        assert!(got["price_as_of"].is_null());
        assert_eq!(got["prices"], serde_json::json!([]));
        assert_eq!(got["lots"], serde_json::json!([]));
        assert_eq!(got["accounts"][0]["tax_advantaged"], true);
    }

    /// C3-A: a pre-fetched override outranks the heuristic in the pure
    /// builder and flips the source field; None keeps round-2 output intact.
    #[test]
    fn instrument_detail_override_wins_and_flags_source() {
        let positions = vec![InstrumentPosition {
            symbol: "VBTLX".to_string(),
            name: "Vanguard Total Bond Market Index Fund".to_string(),
            holding_type: "mutual fund".to_string(),
            quantity: 100.0,
            price: Some(9.85),
            value: 985.0,
            cost_basis_usd: Some(1000.0),
            currency: "USD".to_string(),
            account_id: "6e9c1a4e-0000-0000-0000-000000000003".to_string(),
            account_name: "IRA".to_string(),
            account_type: "ira".to_string(),
        }];
        let got = serde_json::to_value(build_instrument_detail(
            &positions,
            Vec::new(),
            &[],
            None,
            Some("other"),
            985.0,
            20.0,
            day(2026, 7, 6),
        ))
        .unwrap();
        assert_eq!(got["asset_class"], "other");
        assert_eq!(got["asset_class_source"], "override");
        // The heuristic is still reported so the sheet can offer
        // "Automatic — Bonds" as the revert row (VBTLX is a known bond fund).
        assert_eq!(got["asset_class_heuristic"], "bonds");
    }

    /// Range keys map to sensible window starts; unknown fails soft to 1y.
    #[test]
    fn instrument_range_start_windows() {
        let today = day(2026, 7, 6);
        assert_eq!(instrument_range_start(Some("1m"), today), day(2026, 6, 5));
        assert_eq!(instrument_range_start(Some("3m"), today), day(2026, 4, 5));
        assert_eq!(instrument_range_start(Some("1y"), today), day(2025, 7, 6));
        assert_eq!(instrument_range_start(Some("max"), today), day(2000, 1, 1));
        assert_eq!(instrument_range_start(None, today), day(2025, 7, 6));
        assert_eq!(instrument_range_start(Some("bogus"), today), day(2025, 7, 6));
    }

    // =================================================================
    // C-D — conservative payment matching (regex gate)
    // =================================================================

    /// Ticker-shaped symbols produce a whole-word pattern with regex
    /// metacharacters escaped.
    #[test]
    fn dividend_symbol_pattern_escapes_safe_symbols() {
        assert_eq!(
            dividend_symbol_word_pattern("SCHD").as_deref(),
            Some(r"\mSCHD\M")
        );
        assert_eq!(
            dividend_symbol_word_pattern("BRK.B").as_deref(),
            Some(r"\mBRK\.B\M")
        );
        assert_eq!(
            dividend_symbol_word_pattern("BF-B").as_deref(),
            Some(r"\mBF\-B\M")
        );
    }

    /// Symbols with characters outside [A-Za-z0-9.-] (pseudo-symbols, trust
    /// names) skip transaction matching entirely — `[]`, never a bad regex.
    #[test]
    fn dividend_symbol_pattern_rejects_unsafe_symbols() {
        assert!(dividend_symbol_word_pattern("CUR:USD").is_none());
        assert!(dividend_symbol_word_pattern("VANG TARGET RET 2045").is_none());
        assert!(dividend_symbol_word_pattern("").is_none());
        assert!(dividend_symbol_word_pattern("A|B").is_none());
    }

    // =================================================================
    // C-E — CSV quoting
    // =================================================================

    /// RFC-4180: fields are always quoted; embedded quotes double; commas
    /// and quotes survive a round-trip.
    #[test]
    fn csv_field_quotes_commas_and_quotes() {
        assert_eq!(csv_field("Acme, Inc"), "\"Acme, Inc\"");
        assert_eq!(csv_field("Bob's \"Fund\""), "\"Bob's \"\"Fund\"\"\"");
        assert_eq!(csv_field(""), "\"\"");
        assert_eq!(csv_field("plain"), "\"plain\"");
    }

    // =================================================================
    // B3 — upcoming ex-dates are uncapped
    // =================================================================

    /// Ten payers spanning Jul–Oct: ALL ten surface (the old truncate(5)
    /// cut exactly the September/October rows), ascending, past dates and
    /// non-payers dropped.
    #[test]
    fn upcoming_ex_dates_uncapped_ascending_and_future_only() {
        let mk = |sym: &str, date: Option<&str>, income: f64| DividendSymbolContribution {
            symbol: sym.to_string(),
            quantity: 1.0,
            annual_rate: 1.0,
            annual_income_usd: income,
            yield_pct: None,
            last_ex_date: None,
            est_next_ex_date: date.map(str::to_string),
            per_year: 4,
        };
        let contributions = vec![
            mk("A", Some("2026-07-10"), 10.0),
            mk("B", Some("2026-07-24"), 10.0),
            mk("C", Some("2026-08-05"), 10.0),
            mk("D", Some("2026-08-19"), 10.0),
            mk("E", Some("2026-09-02"), 10.0),
            mk("F", Some("2026-09-16"), 10.0),
            mk("G", Some("2026-09-30"), 10.0),
            mk("H", Some("2026-10-08"), 10.0),
            mk("I", Some("2026-10-21"), 10.0),
            mk("J", Some("2026-10-29"), 10.0),
            // Dropped: estimate already past / zero projected income.
            mk("PAST", Some("2026-06-30"), 10.0),
            mk("NOPAY", Some("2026-09-09"), 0.0),
        ];
        let upcoming = upcoming_ex_dates(&contributions, "2026-07-06");
        assert_eq!(upcoming.len(), 10, "no server-side cap");
        assert!(upcoming
            .windows(2)
            .all(|w| w[0].est_next_ex_date <= w[1].est_next_ex_date));
        assert!(upcoming
            .iter()
            .any(|u| u.est_next_ex_date.starts_with("2026-09")));
        assert!(upcoming.iter().all(|u| u.symbol != "PAST" && u.symbol != "NOPAY"));
    }

    // =================================================================
    // Round 4 B4 — shared date-stepping + the C4-B calendar
    // =================================================================

    /// Builder for calendar-test contributions.
    fn contribution(
        symbol: &str,
        annual_income_usd: f64,
        per_year: i32,
        est_next: Option<&str>,
    ) -> DividendSymbolContribution {
        DividendSymbolContribution {
            symbol: symbol.to_string(),
            quantity: 1.0,
            annual_rate: annual_income_usd,
            annual_income_usd,
            yield_pct: None,
            last_ex_date: None,
            est_next_ex_date: est_next.map(str::to_string),
            per_year,
        }
    }

    /// The stepping fn: `per_year` dates one cadence step apart, empty for
    /// non-payers and missing estimates, pruned by the horizon.
    #[test]
    fn projected_ex_dates_steps_and_prunes() {
        // Quarterly: 4 dates, 91 days apart.
        let dates = projected_ex_dates(4, Some("2026-09-10"), 365);
        assert_eq!(
            dates,
            vec![day(2026, 9, 10), day(2026, 12, 10), day(2027, 3, 11), day(2027, 6, 10)]
        );
        // Non-payer / missing / unparsable estimate: empty.
        assert!(projected_ex_dates(0, Some("2026-09-10"), 365).is_empty());
        assert!(projected_ex_dates(4, None, 365).is_empty());
        assert!(projected_ex_dates(4, Some("not-a-date"), 365).is_empty());
        // A tighter horizon prunes the later steps.
        assert_eq!(projected_ex_dates(4, Some("2026-09-10"), 100).len(), 2);
    }

    /// The detail endpoint's `schedule` and the calendar step through the
    /// SAME fn — for identical inputs their dates agree exactly.
    #[test]
    fn detail_schedule_and_calendar_dates_agree() {
        let info = DividendInfo {
            symbol: "KO".to_string(),
            annual_rate: 2.0,
            last_amount: 0.5,
            last_ex_date: Some("2026-06-12".to_string()),
            est_next_ex_date: Some("2026-09-12".to_string()),
            per_year: 4,
            history: Vec::new(),
        };
        let positions = vec![DetailPosition {
            symbol: "KO".to_string(),
            name: "Coca-Cola".to_string(),
            quantity: 10.0,
            price: Some(70.0),
            value: 700.0,
            cost_basis: None,
            currency: "USD".to_string(),
            account_id: "a".to_string(),
            account_name: "Broker".to_string(),
            account_type: "brokerage".to_string(),
        }];
        let detail = build_dividend_detail(&positions, &info, 20.0, Vec::new());
        let schedule_dates: Vec<String> =
            detail.schedule.iter().map(|s| s.est_date.clone()).collect();

        let contributions = vec![contribution("KO", 20.0, 4, Some("2026-09-12"))];
        let calendar = build_dividend_calendar(&contributions, day(2026, 7, 6));
        let calendar_dates: Vec<String> = calendar
            .iter()
            .flat_map(|m| m.entries.iter().map(|e| e.est_date.clone()))
            .collect();
        assert_eq!(schedule_dates, calendar_dates);
    }

    /// Quarterly payer: 4 entries in 4 distinct months, summing to the
    /// annual income (±1¢ rounding); always exactly 12 chronological months.
    #[test]
    fn calendar_quarterly_payer_four_months_summing_to_annual() {
        let contributions = vec![contribution("KO", 400.0, 4, Some("2026-07-14"))];
        let calendar = build_dividend_calendar(&contributions, day(2026, 7, 6));

        assert_eq!(calendar.len(), 12);
        assert_eq!(calendar[0].month, "2026-07");
        assert_eq!(calendar[11].month, "2027-06");
        assert!(calendar.windows(2).all(|w| w[0].month < w[1].month));

        let paying: Vec<&DividendCalendarMonth> =
            calendar.iter().filter(|m| !m.entries.is_empty()).collect();
        assert_eq!(paying.len(), 4);
        assert_eq!(
            paying.iter().map(|m| m.month.as_str()).collect::<Vec<_>>(),
            vec!["2026-07", "2026-10", "2027-01", "2027-04"]
        );
        let total: f64 = calendar.iter().map(|m| m.total_usd).sum();
        assert!((total - 400.0).abs() < 0.01 + 1e-9);
        assert_eq!(paying[0].entries[0].amount_usd, 100.0);
        assert_eq!(paying[0].entries[0].est_date, "2026-07-14");
    }

    /// Monthly payer fills all 12 buckets; annual payer fills exactly 1.
    #[test]
    fn calendar_monthly_fills_twelve_annual_fills_one() {
        let contributions = vec![
            contribution("O", 120.0, 12, Some("2026-07-10")),
            contribution("ANN", 50.0, 1, Some("2027-03-01")),
        ];
        let calendar = build_dividend_calendar(&contributions, day(2026, 7, 6));
        assert!(calendar.iter().all(|m| m.entries.iter().any(|e| e.symbol == "O")));
        let ann_months: Vec<&str> = calendar
            .iter()
            .filter(|m| m.entries.iter().any(|e| e.symbol == "ANN"))
            .map(|m| m.month.as_str())
            .collect();
        assert_eq!(ann_months, vec!["2027-03"]);
        let total: f64 = calendar.iter().map(|m| m.total_usd).sum();
        assert!((total - 170.0).abs() < 0.01 + 1e-9);
    }

    /// Non-payers (`per_year == 0` — failed fetches, unresolvable symbols)
    /// contribute nothing; a payer-free portfolio still gets 12 empty months.
    #[test]
    fn calendar_zero_per_year_contributes_nothing() {
        let contributions = vec![
            contribution("VANG TARGET RET 2045", 0.0, 0, None),
            contribution("CUR:USD", 0.0, 0, Some("2026-08-01")),
        ];
        let calendar = build_dividend_calendar(&contributions, day(2026, 7, 6));
        assert_eq!(calendar.len(), 12);
        assert!(calendar.iter().all(|m| m.entries.is_empty() && m.total_usd == 0.0));
    }

    /// The acknowledged delta vs `projected_annual_income_usd`: an annual
    /// payer whose next date falls past the 12-month window contributes
    /// nothing — every other payer's income lands in full.
    #[test]
    fn calendar_drops_only_payments_outside_the_window() {
        let contributions = vec![
            contribution("KO", 400.0, 4, Some("2026-07-14")),
            // Window is 2026-07 .. 2027-06; this annual estimate is 2027-07.
            contribution("FAR", 50.0, 1, Some("2027-07-01")),
        ];
        let calendar = build_dividend_calendar(&contributions, day(2026, 7, 6));
        let total: f64 = calendar.iter().map(|m| m.total_usd).sum();
        assert!((total - 400.0).abs() < 0.01 + 1e-9);
        assert!(calendar.iter().all(|m| m.entries.iter().all(|e| e.symbol != "FAR")));
    }

    /// Entries within a month sort by amount descending; the December
    /// year-rollover buckets correctly.
    #[test]
    fn calendar_entries_sorted_by_amount_descending() {
        let contributions = vec![
            contribution("SMALL", 40.0, 4, Some("2026-09-13")),
            contribution("BIG", 400.0, 4, Some("2026-09-12")),
        ];
        let calendar = build_dividend_calendar(&contributions, day(2026, 7, 6));
        let sept = calendar.iter().find(|m| m.month == "2026-09").unwrap();
        assert_eq!(
            sept.entries.iter().map(|e| e.symbol.as_str()).collect::<Vec<_>>(),
            vec!["BIG", "SMALL"]
        );
        assert_eq!(sept.total_usd, 110.0);
        // Quarterly from September crosses the year boundary: 2026-12 pays.
        assert!(calendar.iter().any(|m| m.month == "2026-12" && !m.entries.is_empty()));
    }

    // =================================================================
    // Round 4 B5 — shape-freeze: the full portfolio response snapshot
    // =================================================================

    /// The complete `PortfolioDividendsResponse` JSON from fixed inputs —
    /// a quarterly + monthly + unresolvable mix. Every round-3 field is
    /// byte-identical; the ONLY addition vs the round-3 shape is
    /// `calendar` (asserted explicitly on the key set below).
    #[test]
    fn portfolio_dividends_response_shape_freeze() {
        let contributions = vec![
            contribution_full("O", 12.0, 3.0, 36.0, Some(5.0), Some("2026-07-01"), Some("2026-07-15"), 12),
            contribution_full("KO", 10.0, 2.0, 20.0, Some(2.86), Some("2026-06-13"), Some("2026-09-12"), 4),
            contribution_full("VANG TARGET RET 2045", 100.0, 0.0, 0.0, None, None, None, 0),
        ];
        let today = day(2026, 7, 6);
        let response = PortfolioDividendsResponse {
            projected_annual_income_usd: 56.0,
            blended_yield_pct: Some(4.0),
            upcoming_ex_dates: upcoming_ex_dates(&contributions, "2026-07-06"),
            calendar: build_dividend_calendar(&contributions, today),
            contributions,
            fx_stale: false,
        };
        let got = serde_json::to_value(&response).unwrap();

        // The no-behavior-change promise, key for key: round-3 top-level
        // keys plus exactly ONE addition.
        let round3_keys = [
            "projected_annual_income_usd",
            "blended_yield_pct",
            "contributions",
            "upcoming_ex_dates",
            "fx_stale",
        ];
        let mut got_keys: Vec<&str> =
            got.as_object().unwrap().keys().map(String::as_str).collect();
        got_keys.sort_unstable();
        let mut want_keys: Vec<&str> =
            round3_keys.iter().copied().chain(std::iter::once("calendar")).collect();
        want_keys.sort_unstable();
        assert_eq!(got_keys, want_keys, "exactly one added key: `calendar`");

        let want = serde_json::json!({
            "projected_annual_income_usd": 56.0,
            "blended_yield_pct": 4.0,
            "contributions": [
                {"symbol": "O", "quantity": 12.0, "annual_rate": 3.0,
                 "annual_income_usd": 36.0, "yield_pct": 5.0,
                 "last_ex_date": "2026-07-01", "est_next_ex_date": "2026-07-15",
                 "per_year": 12},
                {"symbol": "KO", "quantity": 10.0, "annual_rate": 2.0,
                 "annual_income_usd": 20.0, "yield_pct": 2.86,
                 "last_ex_date": "2026-06-13", "est_next_ex_date": "2026-09-12",
                 "per_year": 4},
                {"symbol": "VANG TARGET RET 2045", "quantity": 100.0,
                 "annual_rate": 0.0, "annual_income_usd": 0.0, "yield_pct": null,
                 "last_ex_date": null, "est_next_ex_date": null, "per_year": 0}
            ],
            "upcoming_ex_dates": [
                {"symbol": "O", "est_next_ex_date": "2026-07-15", "annual_income_usd": 36.0},
                {"symbol": "KO", "est_next_ex_date": "2026-09-12", "annual_income_usd": 20.0}
            ],
            "fx_stale": false,
            "calendar": [
                {"month": "2026-07", "total_usd": 3.0, "entries": [
                    {"symbol": "O", "est_date": "2026-07-15", "amount_usd": 3.0}]},
                {"month": "2026-08", "total_usd": 3.0, "entries": [
                    {"symbol": "O", "est_date": "2026-08-14", "amount_usd": 3.0}]},
                {"month": "2026-09", "total_usd": 8.0, "entries": [
                    {"symbol": "KO", "est_date": "2026-09-12", "amount_usd": 5.0},
                    {"symbol": "O", "est_date": "2026-09-13", "amount_usd": 3.0}]},
                {"month": "2026-10", "total_usd": 3.0, "entries": [
                    {"symbol": "O", "est_date": "2026-10-13", "amount_usd": 3.0}]},
                {"month": "2026-11", "total_usd": 3.0, "entries": [
                    {"symbol": "O", "est_date": "2026-11-12", "amount_usd": 3.0}]},
                {"month": "2026-12", "total_usd": 8.0, "entries": [
                    {"symbol": "KO", "est_date": "2026-12-12", "amount_usd": 5.0},
                    {"symbol": "O", "est_date": "2026-12-12", "amount_usd": 3.0}]},
                {"month": "2027-01", "total_usd": 3.0, "entries": [
                    {"symbol": "O", "est_date": "2027-01-11", "amount_usd": 3.0}]},
                {"month": "2027-02", "total_usd": 3.0, "entries": [
                    {"symbol": "O", "est_date": "2027-02-10", "amount_usd": 3.0}]},
                {"month": "2027-03", "total_usd": 8.0, "entries": [
                    {"symbol": "KO", "est_date": "2027-03-13", "amount_usd": 5.0},
                    {"symbol": "O", "est_date": "2027-03-12", "amount_usd": 3.0}]},
                {"month": "2027-04", "total_usd": 3.0, "entries": [
                    {"symbol": "O", "est_date": "2027-04-11", "amount_usd": 3.0}]},
                {"month": "2027-05", "total_usd": 3.0, "entries": [
                    {"symbol": "O", "est_date": "2027-05-11", "amount_usd": 3.0}]},
                {"month": "2027-06", "total_usd": 8.0, "entries": [
                    {"symbol": "KO", "est_date": "2027-06-12", "amount_usd": 5.0},
                    {"symbol": "O", "est_date": "2027-06-10", "amount_usd": 3.0}]}
            ]
        });
        assert_eq!(got, want);
    }

    /// Fully-specified contribution for the shape-freeze snapshot.
    #[allow(clippy::too_many_arguments)]
    fn contribution_full(
        symbol: &str,
        quantity: f64,
        annual_rate: f64,
        annual_income_usd: f64,
        yield_pct: Option<f64>,
        last_ex_date: Option<&str>,
        est_next_ex_date: Option<&str>,
        per_year: i32,
    ) -> DividendSymbolContribution {
        DividendSymbolContribution {
            symbol: symbol.to_string(),
            quantity,
            annual_rate,
            annual_income_usd,
            yield_pct,
            last_ex_date: last_ex_date.map(str::to_string),
            est_next_ex_date: est_next_ex_date.map(str::to_string),
            per_year,
        }
    }
}
