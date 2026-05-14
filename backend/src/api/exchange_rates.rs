use axum::{
    extract::{Path, Query, State},
    routing::get,
    Json, Router,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;

use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/latest/{base}/{target}", get(get_latest_rate))
        .route("/history/{base}/{target}", get(get_rate_history))
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
            });
        }
        Err(e) => {
            tracing::warn!("Failed to fetch live rate, falling back to DB: {}", e);
        }
    }

    // 3. Fallback to DB
    let rate = sqlx::query(
        r#"
        SELECT rate, recorded_at
        FROM exchange_rates
        WHERE base_currency = $1 AND target_currency = $2
        ORDER BY recorded_at DESC
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
        }),
        None => Json(ExchangeRateResponse {
            base: base.to_uppercase(),
            target: target.to_uppercase(),
            rate: 0.0,
            recorded_at: String::new(),
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
}

#[derive(Serialize)]
struct RatePoint {
    rate: f64,
    timestamp: String,
}
