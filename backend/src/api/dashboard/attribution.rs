//! Net-worth change attribution: FX vs market vs flows (+ residual).
//!
//! `GET /api/dashboard/net-worth-attribution?from=YYYY-MM-DD&to=YYYY-MM-DD`
//! decomposes the net-worth change over the window into named components,
//! per currency and in USD, such that the sum invariant holds EXACTLY:
//!
//! ```text
//! flows + market + fx + residual == observed delta
//! ```
//!
//! per currency and in USD, in `Decimal` (no epsilon). The residual bucket
//! is the honesty valve — nothing is ever fudged to force the sum.
//!
//! ## Valuation convention (the decomposition identity)
//!
//! Window endpoints use carry-forward semantics (NEVER a per-date GROUP BY —
//! the #1 historical bug class): each account is valued at its nearest
//! snapshot on-or-before the endpoint date, so an account that last synced
//! before `from` still contributes its carried balance to both endpoints.
//! Per currency `c` with opening/closing carried balances `B0`/`B1`
//! (liability accounts contribute `-abs(balance)` via the shared
//! `is_liability_account_type` classifier):
//!
//! * **flows** — net external money in/out: the sum of transactions dated in
//!   `(from, to]` on the currency's accounts (split parents and
//!   INVESTMENT-category rows excluded — an intra-brokerage buy moves cash
//!   into holdings without changing the account's snapshot value, so
//!   counting it would misattribute the offset to "market"). USD value uses
//!   the FX rate of each transaction's date via the shared
//!   `USD_MXN_ROW_RATE_SQL` nearest-prior ladder.
//! * **market** — native-currency value change net of flows:
//!   `B1 - B0 - flows`, valued in USD at the CLOSING rate `r1`.
//! * **fx** — the USD/MXN rate movement applied to the OPENING balance:
//!   `B0/r1 - B0/r0` (zero for USD and USD-equivalent currencies; zero in
//!   native terms — a rate move never changes how many pesos you hold).
//! * **residual** — `delta - flows - market - fx`, where `delta` is the
//!   OBSERVED `balance_usd` change from `balance_snapshots` (the exact
//!   series the net-worth chart draws). It absorbs the honest slop:
//!   snapshot-write-time rates disagreeing with the endpoint-date ladder
//!   rates, tx-date-rate flows vs closing-rate market valuation, and manual
//!   accounts lumping weeks of activity into one import day.
//!
//! Every component is rounded to 2 dp in `Decimal` BEFORE the residual is
//! computed from the rounded values, so the invariant survives serialization
//! exactly. Rate lookups use the dated nearest-prior ladder (on-or-before →
//! latest-any → hard fallback), matching `services/fx.rs`.
//!
//! The response also carries the currency-lens `series` behind the net-worth
//! card's FX-free replot (the USD / MXN segments of the original three-way
//! lens are gone — the global reporting-currency switcher owns those): per
//! snapshot date in the
//! window, the carried net worth in USD (`balance_usd`, matching the chart),
//! in MXN at that date's rate, and in USD with MXN balances revalued at the
//! window-START rate (`constant_fx_usd` — "what my net worth did ignoring
//! the peso").
//!
//! v1 deliberately omits the optional weekly digest via the notifications
//! bell (FUTURE.md marks it optional).

use axum::{
    extract::{Extension, Query, State},
    http::StatusCode,
    Json,
};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use sqlx::Row;
use std::collections::{BTreeMap, HashMap};

use crate::api::error::{internal, ApiError};
use crate::api::middleware::AuthContext;
use crate::services::fx::{AMOUNT_USD_SQL, FX_FALLBACK_USD_MXN_DEC, USD_MXN_ROW_RATE_SQL};
use crate::AppState;

use super::EFFECTIVE_CATEGORY_SQL;

#[derive(Deserialize)]
pub(super) struct AttributionQuery {
    from: String,
    to: String,
}

/// One currency's slice of the decomposition. Native components satisfy
/// `flows + market + fx + residual == delta` exactly (fx is 0 in native
/// terms, so market is definitionally the flow-adjusted remainder and the
/// native residual is 0); USD components satisfy the same invariant against
/// the observed `balance_usd` delta, with the genuine slop in `residual_usd`.
#[derive(Serialize)]
pub(super) struct CurrencyAttribution {
    currency: String,
    open_native: Decimal,
    close_native: Decimal,
    delta_native: Decimal,
    flows_native: Decimal,
    market_native: Decimal,
    fx_native: Decimal,
    residual_native: Decimal,
    delta_usd: Decimal,
    flows_usd: Decimal,
    market_usd: Decimal,
    fx_usd: Decimal,
    residual_usd: Decimal,
}

/// One carried net-worth point for the currency-lens chart.
#[derive(Serialize)]
pub(super) struct LensSeriesPoint {
    date: String,
    /// Sum of carried signed `balance_usd` — byte-comparable to the
    /// net-worth-history chart's value for the same date.
    usd: Decimal,
    /// MXN balances at face value + USD-equivalent balances converted at
    /// this date's nearest-prior rate.
    mxn: Decimal,
    /// USD-equivalent balances at face value + MXN balances revalued at the
    /// window-START rate — the "FX held constant" lens.
    constant_fx_usd: Decimal,
}

#[derive(Serialize)]
pub(super) struct NetWorthAttribution {
    from: String,
    to: String,
    /// Nearest-prior USD→MXN rates at the window endpoints (`r0`, `r1`).
    fx_rate_open: Decimal,
    fx_rate_close: Decimal,
    delta_usd: Decimal,
    flows_usd: Decimal,
    market_usd: Decimal,
    fx_usd: Decimal,
    residual_usd: Decimal,
    /// False when the window OPENS before the stored USD/MXN history starts.
    ///
    /// `fx` is `B0/r1 - B0/r0` — it needs a real opening rate. When `from`
    /// predates every stored row, `rate_on`'s "else the latest row of any
    /// date" rung hands back the SAME rate for both endpoints, the two terms
    /// cancel, and `fx_usd` lands on exactly `0.00` — indistinguishable on
    /// the wire from a genuinely FX-free window, and wrong for a holder of
    /// MXN 970k. The currency effect isn't lost (the observed `delta_usd`
    /// still contains it, so `residual_usd` absorbs it), but it cannot be
    /// ATTRIBUTED, and a client must say so rather than print a confident
    /// `$0.00`. See `fx_rates_start` for the date to name in that message.
    fx_attributable: bool,
    /// Date of the oldest stored USD→MXN row, or null when the table is
    /// empty — the "history starts here" the client cites when
    /// `fx_attributable` is false.
    fx_rates_start: Option<String>,
    per_currency: Vec<CurrencyAttribution>,
    series: Vec<LensSeriesPoint>,
}

/// Signed carried state of one account: liabilities contribute negatively so
/// summing states yields net worth directly (assets − liabilities), matching
/// `net_worth_history`'s flush semantics.
#[derive(Clone)]
struct AcctState {
    currency: String,
    native: Decimal,
    usd: Decimal,
}

/// Nearest-prior USD→MXN rate for `date` from the pre-fetched, date-ascending
/// `(date, rate)` list: latest row on-or-before `date`, else the latest row of
/// any date, else the hard fallback — the same ladder as
/// `USD_MXN_ROW_RATE_SQL`, resolved in Rust because the series needs a rate
/// per snapshot date and N subqueries would be wasteful.
fn rate_on(rates: &[(chrono::NaiveDate, Decimal)], date: chrono::NaiveDate) -> Decimal {
    let idx = rates.partition_point(|(d, _)| *d <= date);
    if idx > 0 {
        rates[idx - 1].1
    } else if let Some((_, r)) = rates.last() {
        *r
    } else {
        FX_FALLBACK_USD_MXN_DEC
    }
}

pub(super) async fn net_worth_attribution(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<AttributionQuery>,
) -> Result<Json<NetWorthAttribution>, ApiError> {
    let from = chrono::NaiveDate::parse_from_str(&q.from, "%Y-%m-%d")
        .map_err(|_| ApiError::new(StatusCode::BAD_REQUEST, "invalid `from` date (YYYY-MM-DD)"))?;
    let to = chrono::NaiveDate::parse_from_str(&q.to, "%Y-%m-%d")
        .map_err(|_| ApiError::new(StatusCode::BAD_REQUEST, "invalid `to` date (YYYY-MM-DD)"))?;
    if from > to {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "`from` must be on or before `to`",
        ));
    }

    // Full stored USD→MXN rate history (small table), date-ascending, zero/
    // negative rows skipped so a bad row can never divide a balance into
    // nonsense. Resolved per-date in Rust via `rate_on`.
    let rate_rows = sqlx::query(
        "SELECT recorded_at::date AS d, rate FROM exchange_rates \
         WHERE base_currency = 'USD' AND target_currency = 'MXN' AND rate > 0 \
         ORDER BY recorded_at ASC",
    )
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;
    let mut rates: Vec<(chrono::NaiveDate, Decimal)> = Vec::with_capacity(rate_rows.len());
    for r in &rate_rows {
        if let (Ok(d), Ok(rate)) = (
            r.try_get::<chrono::NaiveDate, _>("d"),
            r.try_get::<Decimal, _>("rate"),
        ) {
            rates.push((d, rate));
        }
    }
    let r0 = rate_on(&rates, from);
    let r1 = rate_on(&rates, to);
    // Did `from` land on a REAL nearest-prior row, or on the "latest of any
    // date" rung? On that rung r0 == r1 and the fx term cancels to exactly
    // zero; the client must render that as unattributable, not as $0.00.
    let fx_rates_start = rates.first().map(|(d, _)| *d);
    let fx_attributable = fx_rates_start.is_some_and(|start| from >= start);

    // Per-account snapshot rows up to the window close, carried forward in
    // Rust — NOT a per-date GROUP BY (accounts snapshot on different days;
    // a raw per-date aggregate drops infrequently-synced accounts and reads
    // them as growth-from-zero). `ORDER BY as_of_date ASC, id ASC` so the
    // last row for an (account, date) wins instead of double-counting.
    let snap_rows = sqlx::query(
        r#"
        SELECT bs.as_of_date AS d,
               bs.account_id AS account_id,
               bs.balance AS balance,
               COALESCE(bs.balance_usd, 0) AS balance_usd,
               UPPER(a.currency) AS currency,
               is_liability_account_type(a.account_type) AS is_liability
        FROM balance_snapshots bs
        JOIN accounts a ON bs.account_id = a.id
        WHERE bs.user_id = $1 AND a.archived_at IS NULL AND bs.as_of_date <= $2
        ORDER BY bs.as_of_date ASC, bs.id ASC
        "#,
    )
    .bind(ctx.user_id)
    .bind(to)
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;

    let mut carried: HashMap<uuid::Uuid, AcctState> = HashMap::new();
    // Opening state: the carried map as of `from` (captured the first time
    // the walk crosses the boundary; if every snapshot is on-or-before
    // `from`, the final map doubles as the opening state — handled below).
    let mut opening: Option<HashMap<uuid::Uuid, AcctState>> = None;
    let mut series: Vec<LensSeriesPoint> = Vec::new();
    let mut current_date: Option<chrono::NaiveDate> = None;

    // Aggregate the carried states into one lens point for `d`.
    let lens_point = |d: chrono::NaiveDate,
                      carried: &HashMap<uuid::Uuid, AcctState>,
                      rates: &[(chrono::NaiveDate, Decimal)],
                      r0: Decimal|
     -> LensSeriesPoint {
        let rd = rate_on(rates, d);
        let mut usd = Decimal::ZERO;
        let mut mxn = Decimal::ZERO;
        let mut constant = Decimal::ZERO;
        for st in carried.values() {
            usd += st.usd;
            if st.currency == "MXN" {
                mxn += st.native;
                constant += st.native / r0;
            } else {
                // Non-MXN currencies are USD-equivalent (fx = 1), the same
                // "trust the native amount" stance as services/fx.rs.
                mxn += st.native * rd;
                constant += st.native;
            }
        }
        LensSeriesPoint {
            date: d.to_string(),
            usd: usd.round_dp(2),
            mxn: mxn.round_dp(2),
            constant_fx_usd: constant.round_dp(2),
        }
    };

    for r in &snap_rows {
        let Ok(d) = r.try_get::<chrono::NaiveDate, _>("d") else {
            continue;
        };
        let Ok(account_id) = r.try_get::<uuid::Uuid, _>("account_id") else {
            continue;
        };
        if current_date != Some(d) {
            // Crossing the window-open boundary: freeze the opening state.
            if opening.is_none() && d > from {
                opening = Some(carried.clone());
                // The lens series anchors at `from` with the opening state so
                // the constant-FX line visibly starts at the window open even
                // when no account snapshotted exactly that day.
                if !carried.is_empty() {
                    series.push(lens_point(from, &carried, &rates, r0));
                }
            }
            if let Some(prev) = current_date {
                if prev > from {
                    series.push(lens_point(prev, &carried, &rates, r0));
                }
            }
            current_date = Some(d);
        }
        let balance = r.try_get::<Decimal, _>("balance").unwrap_or(Decimal::ZERO);
        let balance_usd = r
            .try_get::<Decimal, _>("balance_usd")
            .unwrap_or(Decimal::ZERO);
        let is_liability = r.try_get::<bool, _>("is_liability").unwrap_or(false);
        let (native, usd) = if is_liability {
            (-balance.abs(), -balance_usd.abs())
        } else {
            (balance, balance_usd)
        };
        carried.insert(
            account_id,
            AcctState {
                currency: r
                    .try_get::<String, _>("currency")
                    .unwrap_or_else(|_| "USD".to_string()),
                native,
                usd,
            },
        );
    }
    // Tail flush: the last date group, and the boundary cases where every
    // snapshot sits on-or-before `from` (opening == closing) or the window
    // holds no snapshot dates at all.
    if let Some(prev) = current_date {
        if prev > from {
            series.push(lens_point(prev, &carried, &rates, r0));
        }
    }
    let opening = opening.unwrap_or_else(|| carried.clone());
    if series.is_empty() && !carried.is_empty() {
        series.push(lens_point(from, &opening, &rates, r0));
        if to > from {
            series.push(lens_point(to, &carried, &rates, r0));
        }
    }
    let closing = carried;

    // Flows: net transaction amounts in (from, to] grouped by ACCOUNT
    // currency (native), with the per-row tx-date FX conversion for the USD
    // figure — never a raw cross-currency sum. Split parents are excluded
    // (their children carry the amounts) and INVESTMENT-category rows are
    // excluded (intra-account cash↔holdings shuffles that don't change the
    // account's snapshot value). Internal same-currency transfer legs are
    // deliberately INCLUDED: they cancel within the currency bucket
    // regardless of category tagging, while a cross-currency transfer
    // correctly shows as money flowing out of one currency and into another.
    let flows_sql = format!(
        r#"
        SELECT UPPER(a.currency) AS currency,
               COALESCE(SUM(t.amount), 0) AS flows_native,
               COALESCE(SUM({AMOUNT_USD_SQL}), 0) AS flows_usd
        FROM transactions t
        JOIN accounts a ON t.account_id = a.id
        CROSS JOIN LATERAL (SELECT {USD_MXN_ROW_RATE_SQL} AS rate) fx
        WHERE t.user_id = $1 AND a.archived_at IS NULL
          AND t.date > $2 AND t.date <= $3
          AND {EFFECTIVE_CATEGORY_SQL} <> 'INVESTMENT'
          AND NOT EXISTS (SELECT 1 FROM transactions tc WHERE tc.parent_id = t.id)
        GROUP BY UPPER(a.currency)
        "#
    );
    let flow_rows = sqlx::query(&flows_sql)
        .bind(ctx.user_id)
        .bind(from)
        .bind(to)
        .fetch_all(&state.db)
        .await
        .map_err(internal)?;

    // Assemble per-currency buckets. BTreeMap for a stable, alphabetical
    // response order.
    #[derive(Default)]
    struct Bucket {
        open_native: Decimal,
        close_native: Decimal,
        open_usd: Decimal,
        close_usd: Decimal,
        flows_native: Decimal,
        flows_usd: Decimal,
    }
    let mut buckets: BTreeMap<String, Bucket> = BTreeMap::new();
    for st in opening.values() {
        let b = buckets.entry(st.currency.clone()).or_default();
        b.open_native += st.native;
        b.open_usd += st.usd;
    }
    for st in closing.values() {
        let b = buckets.entry(st.currency.clone()).or_default();
        b.close_native += st.native;
        b.close_usd += st.usd;
    }
    for r in &flow_rows {
        let currency = r
            .try_get::<String, _>("currency")
            .unwrap_or_else(|_| "USD".to_string());
        let b = buckets.entry(currency).or_default();
        b.flows_native += r
            .try_get::<Decimal, _>("flows_native")
            .unwrap_or(Decimal::ZERO);
        b.flows_usd += r
            .try_get::<Decimal, _>("flows_usd")
            .unwrap_or(Decimal::ZERO);
    }

    // A missing opening rate only COSTS anything when there were pesos to
    // revalue: with no MXN at the window open, `fx` is genuinely zero however
    // the rates resolve, and reporting it as unattributable would put a dash
    // where an honest $0.00 belongs (every USD-only window, forever).
    let mxn_open_native = buckets
        .get("MXN")
        .map(|b| b.open_native)
        .unwrap_or(Decimal::ZERO);
    let fx_attributable = fx_attributable || mxn_open_native == Decimal::ZERO;

    let mut per_currency: Vec<CurrencyAttribution> = Vec::with_capacity(buckets.len());
    let (mut t_delta, mut t_flows, mut t_market, mut t_fx, mut t_residual) = (
        Decimal::ZERO,
        Decimal::ZERO,
        Decimal::ZERO,
        Decimal::ZERO,
        Decimal::ZERO,
    );
    for (currency, b) in buckets {
        // Every component is rounded to 2 dp BEFORE the residuals are
        // derived from the rounded values, so the sum invariant holds
        // exactly on the serialized response, not just internally.
        let open_native = b.open_native.round_dp(2);
        let close_native = b.close_native.round_dp(2);
        let delta_native = close_native - open_native;
        let flows_native = b.flows_native.round_dp(2);
        // Native market is definitionally the flow-adjusted value change
        // (FUTURE.md: "native-currency value change net of flows"); fx is 0
        // in native terms, so the native residual is 0 by construction.
        let market_native = delta_native - flows_native;
        let fx_native = Decimal::ZERO;
        let residual_native = delta_native - flows_native - market_native - fx_native;

        let delta_usd = (b.close_usd - b.open_usd).round_dp(2);
        let flows_usd = b.flows_usd.round_dp(2);
        let is_mxn = currency == "MXN";
        // fx on the OPENING balance; market at the CLOSING rate. Non-MXN
        // currencies are USD-equivalent (fx = 1 → no rate effect).
        let fx_usd = if is_mxn {
            (open_native / r1 - open_native / r0).round_dp(2)
        } else {
            Decimal::ZERO
        };
        let market_usd = if is_mxn {
            (market_native / r1).round_dp(2)
        } else {
            market_native
        };
        let residual_usd = delta_usd - flows_usd - market_usd - fx_usd;

        t_delta += delta_usd;
        t_flows += flows_usd;
        t_market += market_usd;
        t_fx += fx_usd;
        t_residual += residual_usd;

        per_currency.push(CurrencyAttribution {
            currency,
            open_native,
            close_native,
            delta_native,
            flows_native,
            market_native,
            fx_native,
            residual_native,
            delta_usd,
            flows_usd,
            market_usd,
            fx_usd,
            residual_usd,
        });
    }

    Ok(Json(NetWorthAttribution {
        from: from.to_string(),
        to: to.to_string(),
        fx_rate_open: r0,
        fx_rate_close: r1,
        delta_usd: t_delta,
        flows_usd: t_flows,
        market_usd: t_market,
        fx_usd: t_fx,
        residual_usd: t_residual,
        fx_attributable,
        fx_rates_start: fx_rates_start.map(|d| d.to_string()),
        per_currency,
        series,
    }))
}
