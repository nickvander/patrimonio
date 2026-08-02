use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::{get, post},
    Extension, Json, Router,
};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use sqlx::Row;
use std::str::FromStr;

use crate::api::error::{internal, ApiError};
use crate::api::middleware::AuthContext;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/latest/{base}/{target}", get(get_latest_rate))
        .route("/history/{base}/{target}", get(get_rate_history))
        .route("/manual", post(post_manual_rate))
        // Per-user alert threshold for the FX center ("notify me when the
        // rate crosses X"). GET is readable by every authenticated user;
        // PUT/DELETE are mutations and thus owner-gated by the business
        // router's require_owner layer.
        .route(
            "/alert/{base}/{target}",
            get(get_fx_alert).put(put_fx_alert).delete(delete_fx_alert),
        )
}

#[derive(Deserialize, Default)]
struct LatestRateQuery {
    /// When `force=true`, bypass the Redis cache and refetch from the
    /// upstream FX provider. Used by the "Refresh now" button so users
    /// can pull a live rate on demand instead of waiting for sync.
    #[serde(default)]
    force: bool,
}

/// Get the latest exchange rate between two currencies
async fn get_latest_rate(
    State(state): State<AppState>,
    Path((base, target)): Path<(String, String)>,
    Query(params): Query<LatestRateQuery>,
) -> Json<ExchangeRateResponse> {
    let cache_key = format!("fx:{}:{}", base.to_uppercase(), target.to_uppercase());

    // 0. A user-entered 'manual' override always wins — same precedence as
    //    latest_usd_mxn_rate, which drives every MXN→USD conversion. Checked
    //    BEFORE the cache and the live fetch so the pinned rate stays visible
    //    here (and its source reads 'manual') even on a force refresh or a warm
    //    cache, and so the FX widget reflects the value the user just saved.
    if let Some(row) = sqlx::query(
        r#"
        SELECT rate, recorded_at
        FROM exchange_rates
        WHERE base_currency = $1 AND target_currency = $2 AND source = 'manual'
        ORDER BY recorded_at DESC
        LIMIT 1
        "#,
    )
    .bind(base.to_uppercase())
    .bind(target.to_uppercase())
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten()
    {
        let manual_rate = row
            .try_get::<rust_decimal::Decimal, _>("rate")
            .ok()
            .map(|d| d.to_string().parse().unwrap_or(0.0))
            .unwrap_or(0.0);
        if manual_rate > 0.0 {
            return Json(ExchangeRateResponse {
                base: base.to_uppercase(),
                target: target.to_uppercase(),
                rate: manual_rate,
                recorded_at: row
                    .try_get::<chrono::DateTime<chrono::Utc>, _>("recorded_at")
                    .ok()
                    .map(|d| d.to_rfc3339())
                    .unwrap_or_default(),
                source: "manual".to_string(),
            });
        }
    }

    // 1. Check Redis Cache (skipped when force=true)
    if !params.force {
        if let Ok(mut conn) = state.redis.get_multiplexed_async_connection().await {
            if let Ok(cached_rate) = redis::cmd("GET")
                .arg(&cache_key)
                .query_async(&mut conn)
                .await
            {
                tracing::debug!("FX cache hit for {}", cache_key);
                return Json(ExchangeRateResponse {
                    base: base.to_uppercase(),
                    target: target.to_uppercase(),
                    rate: cached_rate,
                    recorded_at: chrono::Utc::now().to_rfc3339(),
                    source: "api".to_string(),
                });
            }
        }
    } else {
        tracing::info!("FX force refresh for {}", cache_key);
    }

    // 2. Not in Cache, Fetch from API
    match crate::services::exchange_rate::fetch_and_store_rate(
        &state.db,
        &state.redis,
        &base,
        &target,
    )
    .await
    {
        Ok(rate) => {
            return Json(ExchangeRateResponse {
                base: base.to_uppercase(),
                target: target.to_uppercase(),
                rate,
                recorded_at: chrono::Utc::now().to_rfc3339(),
                source: "api".to_string(),
            });
        }
        Err(e) => {
            tracing::warn!("Failed to fetch live rate, falling back to DB: {}", e);
        }
    }

    // 3. Fallback to DB. A user-entered 'manual' override outranks any 'api'
    //    row (same precedence as latest_usd_mxn_rate) so a corrected rate wins
    //    even when an automated fetch recorded something newer.
    let rate = sqlx::query(
        r#"
        SELECT rate, recorded_at, source
        FROM exchange_rates
        WHERE base_currency = $1 AND target_currency = $2
        ORDER BY (source = 'manual') DESC, recorded_at DESC
        LIMIT 1
        "#,
    )
    .bind(base.to_uppercase())
    .bind(target.to_uppercase())
    .fetch_optional(&state.db)
    .await
    .ok()
    .flatten();

    match rate {
        Some(row) => Json(ExchangeRateResponse {
            base: base.to_uppercase(),
            target: target.to_uppercase(),
            rate: row
                .try_get::<rust_decimal::Decimal, _>("rate")
                .ok()
                .map(|d| d.to_string().parse().unwrap_or(0.0))
                .unwrap_or(0.0),
            recorded_at: row
                .try_get::<chrono::DateTime<chrono::Utc>, _>("recorded_at")
                .ok()
                .map(|d| d.to_rfc3339())
                .unwrap_or_default(),
            source: row
                .try_get::<String, _>("source")
                .unwrap_or_else(|_| "api".to_string()),
        }),
        None => Json(ExchangeRateResponse {
            base: base.to_uppercase(),
            target: target.to_uppercase(),
            rate: 0.0,
            recorded_at: String::new(),
            source: "api".to_string(),
        }),
    }
}

#[derive(Deserialize, Default)]
struct RateHistoryQuery {
    /// Optional trailing window in days (the FX center sparkline requests
    /// 30 or 90). Absent = full history, preserving the original contract.
    days: Option<i64>,
}

/// Get rate history for charting
async fn get_rate_history(
    State(state): State<AppState>,
    Path((base, target)): Path<(String, String)>,
    Query(q): Query<RateHistoryQuery>,
) -> Json<Vec<RatePoint>> {
    // DoS clamp: a hostile ?days= value must not turn into an unbounded
    // interval multiplication. 1..=3650 covers every legitimate chart.
    let days = q.days.map(|d| d.clamp(1, 3650));
    let rows = sqlx::query(
        r#"
        SELECT rate, recorded_at
        FROM exchange_rates
        WHERE base_currency = $1 AND target_currency = $2
          AND ($3::bigint IS NULL OR recorded_at >= NOW() - $3 * INTERVAL '1 day')
        ORDER BY recorded_at ASC
        "#,
    )
    .bind(base.to_uppercase())
    .bind(target.to_uppercase())
    .bind(days)
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| RatePoint {
                rate: r
                    .try_get::<rust_decimal::Decimal, _>("rate")
                    .ok()
                    .map(|d| d.to_string().parse().unwrap_or(0.0))
                    .unwrap_or(0.0),
                timestamp: r
                    .try_get::<chrono::DateTime<chrono::Utc>, _>("recorded_at")
                    .ok()
                    .map(|d| d.to_rfc3339())
                    .unwrap_or_default(),
            })
            .collect(),
    )
}

#[derive(Serialize)]
struct ExchangeRateResponse {
    base: String,
    target: String,
    rate: f64,
    recorded_at: String,
    /// 'api' for the automated open.er-api.com fetch, 'manual' when the freshest
    /// trustworthy row was a user-entered override.
    source: String,
}

#[derive(Deserialize)]
struct ManualRateRequest {
    base: String,
    target: String,
    rate: f64,
}

/// POST /fx/manual — record a user-entered USD/MXN (or any pair) override.
///
/// Inserts a row with `source='manual'`, which `latest_usd_mxn_rate` (and the
/// GET fallback) prefer over the automated 'api' rows. Used to correct a
/// missing/bad upstream rate that would otherwise collapse to the
/// FX_FALLBACK_USD_MXN=20.0 sentinel and corrupt every MXN→USD figure.
async fn post_manual_rate(
    State(state): State<AppState>,
    Json(req): Json<ManualRateRequest>,
) -> Result<Json<ExchangeRateResponse>, (StatusCode, String)> {
    // Reject non-positive / non-finite rates before they can poison the table.
    if !req.rate.is_finite() || req.rate <= 0.0 {
        return Err((
            StatusCode::BAD_REQUEST,
            "rate must be a positive number".to_string(),
        ));
    }

    let base = req.base.to_uppercase();
    let target = req.target.to_uppercase();
    let rate_decimal = Decimal::from_str(&req.rate.to_string()).map_err(|_| {
        (
            StatusCode::BAD_REQUEST,
            "rate must be a positive number".to_string(),
        )
    })?;

    let row = sqlx::query(
        r#"
        INSERT INTO exchange_rates (base_currency, target_currency, rate, recorded_at, source)
        VALUES ($1, $2, $3, NOW(), 'manual')
        ON CONFLICT (base_currency, target_currency, recorded_at) DO UPDATE
        SET rate = EXCLUDED.rate, source = EXCLUDED.source
        RETURNING rate, recorded_at, source
        "#,
    )
    .bind(&base)
    .bind(&target)
    .bind(rate_decimal)
    .fetch_one(&state.db)
    .await
    .map_err(|e| {
        tracing::error!("Failed to store manual exchange rate: {}", e);
        (
            StatusCode::INTERNAL_SERVER_ERROR,
            "failed to store manual rate".to_string(),
        )
    })?;

    // Refresh the Redis cache so the "current" rate read by /latest reflects the
    // override immediately instead of serving the prior cached API value.
    if let Ok(mut conn) = state.redis.get_multiplexed_async_connection().await {
        let cache_key = format!("fx:{base}:{target}");
        let _: Result<(), _> = redis::cmd("SETEX")
            .arg(&cache_key)
            .arg(3600)
            .arg(req.rate)
            .query_async(&mut conn)
            .await;
    }

    tracing::info!(
        "Stored manual exchange rate: 1 {} = {} {}",
        base,
        req.rate,
        target
    );

    Ok(Json(ExchangeRateResponse {
        base,
        target,
        rate: row
            .try_get::<rust_decimal::Decimal, _>("rate")
            .ok()
            .and_then(|d| d.to_string().parse().ok())
            .unwrap_or(req.rate),
        recorded_at: row
            .try_get::<chrono::DateTime<chrono::Utc>, _>("recorded_at")
            .ok()
            .map(|d| d.to_rfc3339())
            .unwrap_or_default(),
        source: row
            .try_get::<String, _>("source")
            .unwrap_or_else(|_| "manual".to_string()),
    }))
}

#[derive(Serialize)]
struct RatePoint {
    rate: f64,
    timestamp: String,
}

// ----- FX alert threshold (FX center) -----

#[derive(Serialize)]
struct FxAlertDto {
    base: String,
    target: String,
    /// Decimal serializes as a JSON number (serde-float feature), matching
    /// the money convention elsewhere.
    threshold: Decimal,
    created_at: String,
    updated_at: String,
    last_notified_at: Option<String>,
}

/// Envelope so "no alert configured" is an explicit `{"alert": null}`
/// instead of a bare null body.
#[derive(Serialize)]
struct FxAlertEnvelope {
    alert: Option<FxAlertDto>,
}

fn alert_dto_from_row(
    row: &sqlx::postgres::PgRow,
    base: &str,
    target: &str,
) -> Result<FxAlertDto, sqlx::Error> {
    Ok(FxAlertDto {
        base: base.to_string(),
        target: target.to_string(),
        threshold: row.try_get("threshold")?,
        created_at: row
            .try_get::<chrono::DateTime<chrono::Utc>, _>("created_at")?
            .to_rfc3339(),
        updated_at: row
            .try_get::<chrono::DateTime<chrono::Utc>, _>("updated_at")?
            .to_rfc3339(),
        last_notified_at: row
            .try_get::<Option<chrono::DateTime<chrono::Utc>>, _>("last_notified_at")?
            .map(|d| d.to_rfc3339()),
    })
}

/// GET /fx/alert/{base}/{target} — the caller's configured threshold, if any.
async fn get_fx_alert(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path((base, target)): Path<(String, String)>,
) -> Result<Json<FxAlertEnvelope>, ApiError> {
    let base = base.to_uppercase();
    let target = target.to_uppercase();
    let row = sqlx::query(
        r#"
        SELECT threshold, created_at, updated_at, last_notified_at
        FROM user_fx_alerts
        WHERE user_id = $1 AND base_currency = $2 AND target_currency = $3
        "#,
    )
    .bind(ctx.user_id)
    .bind(&base)
    .bind(&target)
    .fetch_optional(&state.db)
    .await
    .map_err(internal)?;

    let alert = match row {
        Some(r) => Some(alert_dto_from_row(&r, &base, &target).map_err(internal)?),
        None => None,
    };
    Ok(Json(FxAlertEnvelope { alert }))
}

#[derive(Deserialize)]
struct PutFxAlertRequest {
    threshold: Decimal,
}

/// PUT /fx/alert/{base}/{target} — upsert the caller's alert threshold.
///
/// Changing the threshold resets `last_notified_at`: the old stamp
/// described a different alert.
async fn put_fx_alert(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path((base, target)): Path<(String, String)>,
    Json(req): Json<PutFxAlertRequest>,
) -> Result<Json<FxAlertEnvelope>, ApiError> {
    // Same spirit as post_manual_rate's guard: a non-positive threshold
    // can never be crossed by a real FX rate and only poisons the table.
    // An absurdly large one is equally meaningless — clamp the range.
    if req.threshold <= Decimal::ZERO || req.threshold > Decimal::from(1_000_000) {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "threshold must be a positive number",
        ));
    }
    let base = base.to_uppercase();
    let target = target.to_uppercase();
    let row = sqlx::query(
        r#"
        INSERT INTO user_fx_alerts (user_id, base_currency, target_currency, threshold)
        VALUES ($1, $2, $3, $4)
        ON CONFLICT (user_id, base_currency, target_currency) DO UPDATE
        SET threshold = EXCLUDED.threshold,
            updated_at = NOW(),
            last_notified_at = NULL
        RETURNING threshold, created_at, updated_at, last_notified_at
        "#,
    )
    .bind(ctx.user_id)
    .bind(&base)
    .bind(&target)
    .bind(req.threshold)
    .fetch_one(&state.db)
    .await
    .map_err(internal)?;

    Ok(Json(FxAlertEnvelope {
        alert: Some(alert_dto_from_row(&row, &base, &target).map_err(internal)?),
    }))
}

/// DELETE /fx/alert/{base}/{target} — remove the caller's alert. Idempotent.
async fn delete_fx_alert(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path((base, target)): Path<(String, String)>,
) -> Result<StatusCode, ApiError> {
    sqlx::query(
        r#"
        DELETE FROM user_fx_alerts
        WHERE user_id = $1 AND base_currency = $2 AND target_currency = $3
        "#,
    )
    .bind(ctx.user_id)
    .bind(base.to_uppercase())
    .bind(target.to_uppercase())
    .execute(&state.db)
    .await
    .map_err(internal)?;
    Ok(StatusCode::NO_CONTENT)
}
