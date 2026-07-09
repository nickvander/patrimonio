use axum::{
    extract::{Path, Query, State},
    http::StatusCode,
    routing::{get, post},
    Json, Router,
};
use rust_decimal::Decimal;
use serde::{Deserialize, Serialize};
use sqlx::Row;
use std::str::FromStr;

use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/latest/{base}/{target}", get(get_latest_rate))
        .route("/history/{base}/{target}", get(get_rate_history))
        .route("/manual", post(post_manual_rate))
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
        "#
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
            rate: row.try_get::<rust_decimal::Decimal, _>("rate")
                .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0),
            recorded_at: row.try_get::<chrono::DateTime<chrono::Utc>, _>("recorded_at")
                .ok().map(|d| d.to_rfc3339()).unwrap_or_default(),
            source: row.try_get::<String, _>("source").unwrap_or_else(|_| "api".to_string()),
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

/// Get rate history for charting
async fn get_rate_history(
    State(state): State<AppState>,
    Path((base, target)): Path<(String, String)>,
) -> Json<Vec<RatePoint>> {
    let rows = sqlx::query(
        r#"
        SELECT rate, recorded_at
        FROM exchange_rates
        WHERE base_currency = $1 AND target_currency = $2
        ORDER BY recorded_at ASC
        "#
    )
    .bind(base.to_uppercase())
    .bind(target.to_uppercase())
    .fetch_all(&state.db)
    .await
    .unwrap_or_default();

    Json(
        rows.iter()
            .map(|r| RatePoint {
                rate: r.try_get::<rust_decimal::Decimal, _>("rate")
                    .ok().map(|d| d.to_string().parse().unwrap_or(0.0)).unwrap_or(0.0),
                timestamp: r.try_get::<chrono::DateTime<chrono::Utc>, _>("recorded_at")
                    .ok().map(|d| d.to_rfc3339()).unwrap_or_default(),
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

    tracing::info!("Stored manual exchange rate: 1 {} = {} {}", base, req.rate, target);

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
