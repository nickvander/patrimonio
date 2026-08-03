use axum::{
    http::{header, HeaderMap, HeaderName, HeaderValue, StatusCode},
    response::Response,
    routing::get,
    Router,
};
use sqlx::Row;

use crate::services::fx::FX_FALLBACK_USD_MXN;
use crate::AppState;

pub(crate) mod allocation;
pub(crate) mod analytics;
pub(crate) mod dividends;
pub(crate) mod fx_transfers;
pub(crate) mod holdings;
pub(crate) mod overview;
pub(crate) mod realized_gains;
pub(crate) mod since_last_login;
pub(crate) mod spending;
pub(crate) mod subscriptions;
pub(crate) mod transactions;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/overview", get(overview::dashboard_overview))
        .route("/net-worth-history", get(overview::net_worth_history))
        .route(
            "/portfolio-value-history",
            get(overview::portfolio_value_history),
        )
        .route("/holdings", get(holdings::holdings))
        .route("/holdings/export", get(holdings::export_holdings_csv))
        .route("/holdings/lots/export", get(holdings::export_lots_csv))
        .route("/holdings/dividends", get(dividends::portfolio_dividends))
        .route("/dividends/{symbol}", get(dividends::dividend_detail))
        .route("/instruments/{symbol}", get(holdings::instrument_detail))
        // Round 3 (contract C3-A): pin/clear a per-(user, symbol) asset-class
        // override. Same auth/CSRF conventions as the sibling mutations.
        .route(
            "/instruments/{symbol}/asset-class",
            axum::routing::put(holdings::set_asset_class_override),
        )
        .route("/allocation", get(allocation::asset_allocation))
        .route("/trends", get(spending::cash_flow_trends))
        .route("/spending-by-category", get(spending::spending_by_category))
        .route("/spending-insights", get(spending::spending_insights))
        .route("/realized-gains", get(realized_gains::realized_gains))
        .route(
            "/realized-gains/export",
            get(realized_gains::export_realized_gains_csv),
        )
        .route(
            "/account-balance-history",
            get(analytics::account_balance_history),
        )
        .route("/emergency-fund", get(analytics::emergency_fund))
        .route("/benchmark", get(analytics::benchmark_series))
        .route(
            "/benchmark-comparison",
            get(analytics::benchmark_comparison),
        )
        .route("/portfolio-twr", get(analytics::portfolio_twr))
        .route("/credit-utilization", get(overview::credit_utilization))
        .route("/sync-status", get(overview::sync_status))
        .route("/transactions", get(transactions::recent_transactions))
        .route(
            "/transactions/export",
            get(transactions::export_transactions_csv),
        )
        .route(
            "/transactions/manual",
            axum::routing::post(transactions::create_manual_transaction),
        )
        .route("/since-last-login", get(since_last_login::since_last_login))
        .route("/subscriptions", get(subscriptions::detected_subscriptions))
        .route(
            "/subscriptions/ignored",
            get(subscriptions::list_ignored_subscriptions),
        )
        .route(
            "/subscriptions/ignore",
            axum::routing::post(subscriptions::ignore_subscription),
        )
        .route(
            "/subscriptions/ignored/{merchant_key}",
            axum::routing::delete(subscriptions::unignore_subscription),
        )
        .route(
            "/fx-transfers",
            get(fx_transfers::list_fx_transfers).post(fx_transfers::detect_fx_transfers),
        )
        // Static "costs" / "dismissed" segments mounted BEFORE the
        // dynamic /{id} route so axum's matcher prefers them — otherwise
        // /fx-transfers/dismissed could be parsed as id="dismissed"
        // and 400 on the UUID extractor.
        .route("/fx-transfers/costs", get(fx_transfers::fx_transfer_costs))
        .route(
            "/fx-transfers/dismissed",
            get(fx_transfers::list_dismissed_fx_pairs),
        )
        .route(
            "/fx-transfers/dismissed/{id}",
            axum::routing::delete(fx_transfers::restore_dismissed_fx_pair),
        )
        .route(
            "/fx-transfers/{id}",
            axum::routing::delete(fx_transfers::unlink_fx_transfer)
                .patch(fx_transfers::confirm_fx_transfer),
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

/// Build the `X-Total-Count` response header from the window-function total
/// carried on every row of a transactions page.
///
/// Why a header and not a response envelope: shipped Android APKs decode
/// these endpoints' bodies as a bare JSON array — wrapping the body in
/// `{rows, total}` would break every one of them, while an extra header is
/// invisible to old clients and lets new ones show a stable "of N"
/// denominator instead of a total that visibly counts up while pages
/// stream in. A successful empty FIRST page (offset == 0) proves the total
/// is 0, so callers pass `Some(0)` there — without it, a client that just
/// deleted its last rows kept showing a stale "Showing 0 of N". An empty
/// page beyond the end (offset > 0) or a failed best-effort read → no
/// header; the client falls back to its loaded-count heuristic.
pub(crate) fn total_count_headers(total: Option<i64>) -> HeaderMap {
    let mut headers = HeaderMap::new();
    if let Some(total) = total {
        if let Ok(value) = HeaderValue::from_str(&total.to_string()) {
            headers.insert(HeaderName::from_static("x-total-count"), value);
        }
    }
    headers
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

#[cfg(test)]
mod tests {
    use super::*;

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
}
