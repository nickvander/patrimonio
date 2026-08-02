use axum::{
    extract::{Extension, State},
    http::StatusCode,
    Json,
};
use serde::Serialize;
use sqlx::Row;
use tracing::error;

use crate::api::middleware::AuthContext;
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
