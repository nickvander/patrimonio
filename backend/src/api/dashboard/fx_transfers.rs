use axum::{
    extract::{Extension, State},
    http::StatusCode,
    Json,
};
use rust_decimal::Decimal;
use serde::Serialize;
use sqlx::Row;
use std::collections::BTreeMap;
use tracing::error;

use crate::api::error::internal;
use crate::api::error::ApiError;
use crate::api::middleware::AuthContext;
use crate::services::fx::FX_FALLBACK_USD_MXN_DEC;
use crate::AppState;

// ---------- Cross-currency cash-transfer linking ----------

#[derive(Serialize)]
pub(super) struct FxTransferEntry {
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
pub(super) async fn list_fx_transfers(
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
                detection_confidence: r.try_get::<i16, _>("detection_confidence").unwrap_or(0)
                    as i32,
                user_confirmed: r.try_get("user_confirmed").unwrap_or(false),
                detected_at: r
                    .try_get::<chrono::DateTime<chrono::Utc>, _>("detected_at")
                    .map(|d| d.to_rfc3339())
                    .unwrap_or_default(),
                matched_keyword: r
                    .try_get::<Option<String>, _>("matched_keyword")
                    .ok()
                    .flatten(),
                source_label: r
                    .try_get::<Option<String>, _>("source_label")
                    .ok()
                    .flatten()
                    .unwrap_or_else(|| r.try_get::<String, _>("source_desc").unwrap_or_default()),
                dest_label: r
                    .try_get::<Option<String>, _>("dest_label")
                    .ok()
                    .flatten()
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
pub(super) struct DetectFxResponse {
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
pub(super) async fn detect_fx_transfers(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Json<DetectFxResponse> {
    match crate::services::fx_transfer_link::detect_for_user(&state.db, ctx.user_id).await {
        Ok((checked, inserted)) => Json(DetectFxResponse { checked, inserted }),
        Err(e) => {
            error!(
                "fx-transfer detection failed for user {}: {}",
                ctx.user_id, e
            );
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
pub(super) async fn confirm_fx_transfer(
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
pub(super) async fn unlink_fx_transfer(
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
pub(super) struct DismissedFxPair {
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
pub(super) async fn list_dismissed_fx_pairs(
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

// ---------- Annual transfer-cost report ----------

/// How far (in days, either direction) from the source-transaction date
/// we search `exchange_rates` for a "market spot" row. Mirrors the ±7-day
/// window `list_fx_transfers` uses for its per-row `spot_fx_rate` — the
/// two must stay in sync so the per-transfer view and the annual report
/// never disagree about which spot a transfer was judged against.
/// ⚠ The literal `7` inside `fx_transfer_costs`'s SQL below is this same
/// number spelled into SQL — change them together.
const SPOT_WINDOW_DAYS: i64 = 7;

/// Provider names the detector's keyword list splits that are really the
/// same company. `matched_keyword` stores the FIRST keyword hit, so a
/// Wise transfer can carry either "WISE" or "TRANSFERWISE" depending on
/// which string the bank put in the description — without this fold the
/// report would show one provider as two buckets.
fn provider_label(matched_keyword: Option<&str>) -> Option<String> {
    let kw = matched_keyword?.trim().to_uppercase();
    if kw.is_empty() {
        return None;
    }
    Some(match kw.as_str() {
        "TRANSFERWISE" => "WISE".to_string(),
        "WESTERNUNION" => "WESTERN UNION".to_string(),
        _ => kw,
    })
}

/// TOTAL cost of one transfer vs the mid-market spot rate, in USD.
/// Positive = the provider's bundled rate+fees left the user worse off
/// than mid-market; a (rare) negative value means better-than-spot.
///
/// `spot` is always denominated USD→MXN (MXN per 1 USD), matching the
/// `exchange_rates` table. No fee-vs-spread split — for deducted-fee
/// providers (Wise) that decomposition is not computable from the two
/// transaction legs, so v1 reports the honest total only.
///
/// Returns `None` when no usable spot rate is available or the currency
/// pair isn't USD↔MXN — the caller counts those rows as "uncosted"
/// instead of guessing.
fn transfer_cost_usd(
    source_currency: &str,
    source_amount: Decimal,
    dest_currency: &str,
    dest_amount: Decimal,
    spot: Option<Decimal>,
) -> Option<Decimal> {
    let spot = spot.filter(|s| *s > Decimal::ZERO)?;
    match (source_currency, dest_currency) {
        // Sent USD, received MXN: at mid-market the pesos received would
        // have cost dest/spot dollars; the difference vs what was sent
        // is the bundled cost.
        ("USD", "MXN") => Some(source_amount - dest_amount / spot),
        // Sent MXN, received USD: the pesos sent were worth source/spot
        // dollars at mid-market; the shortfall vs dollars received is
        // the cost.
        ("MXN", "USD") => Some(source_amount / spot - dest_amount),
        _ => None,
    }
}

/// USD-equivalent of the amount SENT, for the "total moved" figure.
/// Prefers the market spot for the transfer date; falls back to the
/// transfer's own implied rate (the rate the user actually got — a fair
/// stand-in for magnitude), then the hard FX fallback. Non-MXN source
/// currencies are treated as USD-equivalent, the same "trust the native
/// amount" stance as `services/fx.rs`.
fn moved_usd(
    source_currency: &str,
    source_amount: Decimal,
    implied_rate: Decimal,
    spot: Option<Decimal>,
) -> Decimal {
    if source_currency != "MXN" {
        return source_amount;
    }
    let rate = spot
        .filter(|s| *s > Decimal::ZERO)
        .or(Some(implied_rate).filter(|r| *r > Decimal::ZERO))
        .unwrap_or(FX_FALLBACK_USD_MXN_DEC);
    source_amount / rate
}

#[derive(Serialize)]
pub(super) struct FxCostProvider {
    /// Folded detection keyword (WISE, REMITLY, …); `null` is the
    /// "unknown" bucket for keyword-less links (direct wires the
    /// detector matched on window+rate+identity alone).
    provider: Option<String>,
    transfer_count: i64,
    /// Sum of the SENT side converted per-row to USD (never a raw
    /// cross-currency sum).
    total_moved_usd: Decimal,
    /// Sent totals per source currency — each entry only ever sums
    /// same-currency rows, so no FX assumption is baked in.
    moved_by_currency: BTreeMap<String, Decimal>,
    /// Sum of implied-vs-spot deltas in USD over the costed transfers.
    total_cost_usd: Decimal,
    /// Transfers with no `exchange_rates` row within ±`spot_window_days`
    /// of the transfer date — excluded from `total_cost_usd` rather than
    /// costed against a stale rate.
    missing_spot_count: i64,
}

#[derive(Serialize)]
pub(super) struct FxCostYear {
    year: i32,
    transfer_count: i64,
    total_moved_usd: Decimal,
    moved_by_currency: BTreeMap<String, Decimal>,
    total_cost_usd: Decimal,
    missing_spot_count: i64,
    providers: Vec<FxCostProvider>,
}

#[derive(Serialize)]
pub(super) struct FxTransferCostsResponse {
    /// The ±day tolerance of the spot lookup, surfaced so the frontend
    /// can render the "vs nearest rate within ±N days" caveat without
    /// hardcoding it.
    spot_window_days: i64,
    /// Newest year first; providers within a year sorted by cost desc.
    years: Vec<FxCostYear>,
}

/// Annual "what did moving money cost us" report: per calendar year and
/// per provider, the transfer count, total moved (per-source-currency and
/// USD) and the TOTAL cost vs the mid-market spot rate nearest each
/// transfer date. Scoped to the caller; aggregation is Decimal end-to-end.
pub(super) async fn fx_transfer_costs(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Result<Json<FxTransferCostsResponse>, ApiError> {
    // Same nearest-row-within-±7-days spot lookup as `list_fx_transfers`
    // (see the comment there for the date-arithmetic subtlety), plus a
    // `rate > 0` guard so a bad row can't divide a cost into nonsense,
    // and a `recorded_at DESC` tie-break so two equidistant rows resolve
    // deterministically.
    let rows = sqlx::query(
        r#"
        SELECT
            f.source_amount, f.source_currency,
            f.dest_amount, f.dest_currency,
            f.implied_fx_rate, f.matched_keyword,
            ts.date AS source_date,
            (
                SELECT er.rate
                FROM exchange_rates er
                WHERE er.base_currency = 'USD'
                  AND er.target_currency = 'MXN'
                  AND er.rate > 0
                  AND er.recorded_at::date BETWEEN ts.date - INTEGER '7'
                                              AND ts.date + INTEGER '7'
                ORDER BY ABS(er.recorded_at::date - ts.date) ASC,
                         er.recorded_at DESC
                LIMIT 1
            ) AS spot_fx_rate
        FROM cash_fx_transfers f
        JOIN transactions ts ON ts.id = f.source_tx_id
        WHERE f.user_id = $1
        ORDER BY ts.date ASC
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;

    #[derive(Default)]
    struct Agg {
        count: i64,
        moved_usd: Decimal,
        moved_by_currency: BTreeMap<String, Decimal>,
        cost_usd: Decimal,
        missing_spot: i64,
    }

    // Keyed (year, provider). BTreeMap orders None before Some, which is
    // irrelevant here — presentation order is re-sorted below.
    let mut buckets: BTreeMap<(i32, Option<String>), Agg> = BTreeMap::new();

    for r in &rows {
        let source_amount: Decimal = r.try_get("source_amount").map_err(internal)?;
        let source_currency: String = r.try_get("source_currency").map_err(internal)?;
        let dest_amount: Decimal = r.try_get("dest_amount").map_err(internal)?;
        let dest_currency: String = r.try_get("dest_currency").map_err(internal)?;
        let implied_rate: Decimal = r.try_get("implied_fx_rate").map_err(internal)?;
        let matched_keyword: Option<String> = r
            .try_get::<Option<String>, _>("matched_keyword")
            .ok()
            .flatten();
        let source_date: chrono::NaiveDate = r.try_get("source_date").map_err(internal)?;
        let spot: Option<Decimal> = r
            .try_get::<Option<Decimal>, _>("spot_fx_rate")
            .ok()
            .flatten();

        let year = chrono::Datelike::year(&source_date);
        let provider = provider_label(matched_keyword.as_deref());

        let agg = buckets.entry((year, provider)).or_default();
        agg.count += 1;
        agg.moved_usd += moved_usd(&source_currency, source_amount, implied_rate, spot);
        *agg.moved_by_currency
            .entry(source_currency.clone())
            .or_default() += source_amount;
        match transfer_cost_usd(
            &source_currency,
            source_amount,
            &dest_currency,
            dest_amount,
            spot,
        ) {
            Some(cost) => agg.cost_usd += cost,
            None => agg.missing_spot += 1,
        }
    }

    // Roll provider buckets up into years.
    let mut years: BTreeMap<i32, FxCostYear> = BTreeMap::new();
    for ((year, provider), agg) in buckets {
        let y = years.entry(year).or_insert_with(|| FxCostYear {
            year,
            transfer_count: 0,
            total_moved_usd: Decimal::ZERO,
            moved_by_currency: BTreeMap::new(),
            total_cost_usd: Decimal::ZERO,
            missing_spot_count: 0,
            providers: Vec::new(),
        });
        y.transfer_count += agg.count;
        y.total_moved_usd += agg.moved_usd;
        for (ccy, amt) in &agg.moved_by_currency {
            *y.moved_by_currency.entry(ccy.clone()).or_default() += *amt;
        }
        y.total_cost_usd += agg.cost_usd;
        y.missing_spot_count += agg.missing_spot;
        y.providers.push(FxCostProvider {
            provider,
            transfer_count: agg.count,
            total_moved_usd: agg.moved_usd.round_dp(2),
            moved_by_currency: agg
                .moved_by_currency
                .into_iter()
                .map(|(c, v)| (c, v.round_dp(2)))
                .collect(),
            total_cost_usd: agg.cost_usd.round_dp(2),
            missing_spot_count: agg.missing_spot,
        });
    }

    // Presentation: newest year first; within a year the most expensive
    // provider first (count, then name as tie-breaks), rounded to 2dp.
    let mut years: Vec<FxCostYear> = years
        .into_values()
        .map(|mut y| {
            y.total_moved_usd = y.total_moved_usd.round_dp(2);
            y.total_cost_usd = y.total_cost_usd.round_dp(2);
            y.moved_by_currency = y
                .moved_by_currency
                .into_iter()
                .map(|(c, v)| (c, v.round_dp(2)))
                .collect();
            y.providers.sort_by(|a, b| {
                b.total_cost_usd
                    .cmp(&a.total_cost_usd)
                    .then(b.transfer_count.cmp(&a.transfer_count))
                    .then(a.provider.cmp(&b.provider))
            });
            y
        })
        .collect();
    years.sort_by(|a, b| b.year.cmp(&a.year));

    Ok(Json(FxTransferCostsResponse {
        spot_window_days: SPOT_WINDOW_DAYS,
        years,
    }))
}

/// Restore a previously-dismissed FX pair — deletes the row so the
/// next detector run is free to surface the pair again. Idempotent:
/// returns 204 even when the row is already gone.
pub(super) async fn restore_dismissed_fx_pair(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    axum::extract::Path(id): axum::extract::Path<uuid::Uuid>,
) -> StatusCode {
    let result = sqlx::query("DELETE FROM dismissed_fx_pairs WHERE id = $1 AND user_id = $2")
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

#[cfg(test)]
mod tests {
    use super::*;
    use rust_decimal_macros::dec;

    #[test]
    fn provider_label_folds_detector_aliases() {
        assert_eq!(provider_label(Some("WISE")).as_deref(), Some("WISE"));
        // TRANSFERWISE and WESTERNUNION are separate detector keywords for
        // the same companies — the report must not split them into two rows.
        assert_eq!(
            provider_label(Some("TRANSFERWISE")).as_deref(),
            Some("WISE")
        );
        assert_eq!(
            provider_label(Some("WESTERNUNION")).as_deref(),
            Some("WESTERN UNION")
        );
        assert_eq!(provider_label(Some("REMITLY")).as_deref(), Some("REMITLY"));
        // Keyword-less links land in the unknown (None) bucket.
        assert_eq!(provider_label(None), None);
        assert_eq!(provider_label(Some("  ")), None);
    }

    #[test]
    fn cost_usd_to_mxn_is_sent_minus_midmarket_value_of_received() {
        // Sent $1,000, got 19,500 MXN; spot 20.00 → mid-market value of the
        // pesos is $975, so moving the money cost $25 total.
        let cost = transfer_cost_usd("USD", dec!(1000), "MXN", dec!(19500), Some(dec!(20)));
        assert_eq!(cost, Some(dec!(25)));
    }

    #[test]
    fn cost_mxn_to_usd_is_midmarket_value_of_sent_minus_received() {
        // Sent 20,000 MXN (= $1,000 at spot 20.00), received $950 → $50 cost.
        let cost = transfer_cost_usd("MXN", dec!(20000), "USD", dec!(950), Some(dec!(20)));
        assert_eq!(cost, Some(dec!(50)));
    }

    #[test]
    fn cost_is_none_without_a_usable_spot() {
        assert_eq!(
            transfer_cost_usd("USD", dec!(1000), "MXN", dec!(19500), None),
            None
        );
        // Zero/negative spot must be refused, never divided by.
        assert_eq!(
            transfer_cost_usd("USD", dec!(1000), "MXN", dec!(19500), Some(dec!(0))),
            None
        );
        // Non-USD↔MXN pairs are uncosted, not guessed.
        assert_eq!(
            transfer_cost_usd("USD", dec!(1000), "EUR", dec!(900), Some(dec!(20))),
            None
        );
    }

    #[test]
    fn moved_usd_converts_mxn_and_trusts_usd() {
        assert_eq!(moved_usd("USD", dec!(800), dec!(19), None), dec!(800));
        // MXN sent prefers the spot rate…
        assert_eq!(
            moved_usd("MXN", dec!(20000), dec!(19), Some(dec!(20))),
            dec!(1000)
        );
        // …falls back to the transfer's own implied rate when spot is
        // missing (the rate the user actually got)…
        assert_eq!(moved_usd("MXN", dec!(1900), dec!(19), None), dec!(100));
        // …and never divides by a non-positive rate.
        assert_eq!(
            moved_usd("MXN", dec!(2000), dec!(0), None),
            dec!(2000) / FX_FALLBACK_USD_MXN_DEC
        );
    }
}
