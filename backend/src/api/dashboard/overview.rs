use axum::{
    extract::{Extension, State},
    Json,
};
use serde::Serialize;
use sqlx::Row;
use std::collections::HashMap;

use crate::api::middleware::AuthContext;
use crate::AppState;

use super::*;

/// Dashboard overview: net worth, account breakdown, recent changes —
/// scoped to the authenticated user. Every aggregate filters on
/// `user_id` so a brand-new account from another tenant can never
/// contribute to this user's totals.
pub(super) async fn dashboard_overview(
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
        )
        .bind(ctx.user_id)
        .fetch_all(&state.db),
        // FX rate + staleness flag (missing or >7 days old). Replaces the old
        // silent 20.0 fallback so MXN-converted figures can be badged.
        latest_usd_mxn_rate(&state.db),
        sqlx::query(
            r#"
            SELECT a.id, a.name, a.nickname, a.account_type, a.current_balance, a.currency,
                   a.institution_id,
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
        )
        .bind(ctx.user_id)
        .fetch_all(&state.db),
    );
    let currency_rows = currency_rows.unwrap_or_default();
    let accounts_rows = accounts_rows.unwrap_or_default();

    let currency_breakdown: Vec<CurrencyBreakdown> = currency_rows
        .iter()
        .map(|r| {
            let assets: f64 = r
                .try_get::<rust_decimal::Decimal, _>("assets")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0);
            let liabilities: f64 = r
                .try_get::<rust_decimal::Decimal, _>("liabilities")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0);
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

    let type_breakdown: Vec<TypeBreakdown> = type_rows
        .iter()
        .map(|r| TypeBreakdown {
            account_type: r.get("account_type"),
            count: r.try_get::<i64, _>("count").unwrap_or(0) as i32,
            total: r
                .try_get::<rust_decimal::Decimal, _>("total")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0),
            total_usd: r
                .try_get::<rust_decimal::Decimal, _>("total_usd")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0),
        })
        .collect();

    let institution_breakdown: Vec<InstitutionBreakdown> = institution_rows
        .iter()
        .map(|r| InstitutionBreakdown {
            name: r.get("institution_name"),
            country: r.get("country"),
            account_count: r.try_get::<i64, _>("account_count").unwrap_or(0) as i32,
            total: r
                .try_get::<rust_decimal::Decimal, _>("total")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0),
            total_usd: r
                .try_get::<rust_decimal::Decimal, _>("total_usd")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0),
        })
        .collect();

    let accounts: Vec<AccountDetail> = accounts_rows
        .iter()
        .map(|r| AccountDetail {
            id: r.get::<uuid::Uuid, _>("id").to_string(),
            name: r.get("name"),
            nickname: r.try_get::<Option<String>, _>("nickname").ok().flatten(),
            institution_id: r
                .try_get::<uuid::Uuid, _>("institution_id")
                .map(|u| u.to_string())
                .unwrap_or_default(),
            institution_name: r.get("institution_name"),
            account_type: r.get("account_type"),
            current_balance: r
                .try_get::<rust_decimal::Decimal, _>("current_balance")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0),
            currency: r.get("currency"),
            ticker_symbol: r.get("ticker_symbol"),
            crypto_amount: r
                .try_get::<rust_decimal::Decimal, _>("crypto_amount")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0)),
            clabe: r.try_get::<Option<String>, _>("clabe").ok().flatten(),
            holder_name: r.try_get::<Option<String>, _>("holder_name").ok().flatten(),
            integration_type: r
                .try_get::<String, _>("integration_type")
                .unwrap_or_default(),
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
pub(super) async fn net_worth_history(
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
pub(super) struct PortfolioValuePoint {
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
pub(super) async fn portfolio_value_history(
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

    let mut latest: std::collections::HashMap<uuid::Uuid, f64> = std::collections::HashMap::new();
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

/// Credit card utilization for this user's credit accounts.
pub(super) async fn credit_utilization(
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
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| {
                let balance: f64 = r
                    .try_get::<rust_decimal::Decimal, _>("current_balance")
                    .ok()
                    .map(|d| d.to_string().parse::<f64>().unwrap_or(0.0))
                    .unwrap_or(0.0)
                    .abs();
                let limit: f64 = r
                    .try_get::<rust_decimal::Decimal, _>("credit_limit")
                    .ok()
                    .map(|d| d.to_string().parse().unwrap_or(0.0))
                    .unwrap_or(0.0);
                CreditUtilization {
                    name: r.get("name"),
                    institution_name: r.get("institution_name"),
                    currency: r.try_get("currency").unwrap_or_else(|_| "USD".to_string()),
                    balance,
                    credit_limit: limit,
                    utilization_pct: if limit > 0.0 {
                        (balance / limit) * 100.0
                    } else {
                        0.0
                    },
                }
            })
            .collect(),
    )
}

/// Sync status of this user's institutions.
pub(super) async fn sync_status(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<Vec<SyncStatusEntry>> {
    let rows = sqlx::query(
        r#"
        SELECT id, name, integration_type, sync_status, last_synced_at, country, last_sync_error
        FROM institutions
        WHERE user_id = $1
        ORDER BY name
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| SyncStatusEntry {
                id: r
                    .try_get::<uuid::Uuid, _>("id")
                    .map(|u| u.to_string())
                    .unwrap_or_default(),
                name: r.get("name"),
                integration_type: r.get("integration_type"),
                country: r.get("country"),
                sync_status: r
                    .try_get::<String, _>("sync_status")
                    .unwrap_or_else(|_| "unknown".to_string()),
                last_synced_at: r
                    .try_get::<chrono::DateTime<chrono::Utc>, _>("last_synced_at")
                    .ok()
                    .map(|d| d.to_rfc3339()),
                last_sync_error: r
                    .try_get::<Option<String>, _>("last_sync_error")
                    .ok()
                    .flatten(),
            })
            .collect(),
    )
}

#[derive(Serialize)]
pub(super) struct DashboardOverview {
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
    /// Owning institution's id — the stable key the staleness snooze/mute
    /// settings are stored under (names can be renamed; ids can't).
    institution_id: String,
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
pub(super) struct NetWorthPoint {
    date: String,
    total_assets: f64,
    total_liabilities: f64,
    net_worth: f64,
    /// Per-institution net contribution (assets - liabilities) for this date.
    by_institution: HashMap<String, f64>,
}

#[derive(Serialize)]
pub(super) struct CreditUtilization {
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
pub(super) struct SyncStatusEntry {
    id: String,
    name: String,
    integration_type: String,
    country: String,
    sync_status: String,
    last_synced_at: Option<String>,
    last_sync_error: Option<String>,
}
