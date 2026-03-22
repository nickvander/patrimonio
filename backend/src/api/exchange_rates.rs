use axum::{
    extract::{Path, State},
    routing::get,
    Json, Router,
};
use serde::Serialize;
use sqlx::Row;

use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/latest/{base}/{target}", get(get_latest_rate))
        .route("/history/{base}/{target}", get(get_rate_history))
}

/// Get the latest exchange rate between two currencies
async fn get_latest_rate(
    State(state): State<AppState>,
    Path((base, target)): Path<(String, String)>,
) -> Json<ExchangeRateResponse> {
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
