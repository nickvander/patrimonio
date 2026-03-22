use anyhow::Result;
use reqwest::Client;
use rust_decimal::Decimal;
use serde::Deserialize;
use sqlx::PgPool;
use std::str::FromStr;

/// Fetches the latest exchange rate from the free ExchangeRate-API
/// and stores it in the database + Redis cache.
pub async fn fetch_and_store_rate(
    db: &PgPool,
    redis_client: &redis::Client,
    base: &str,
    target: &str,
) -> Result<f64> {
    let client = Client::new();

    // Free tier: https://open.er-api.com/v6/latest/{base}
    let url = format!("https://open.er-api.com/v6/latest/{}", base.to_uppercase());
    let resp = client.get(&url).send().await?.json::<ErApiResponse>().await?;

    let rate = resp
        .rates
        .get(&target.to_uppercase())
        .copied()
        .unwrap_or(0.0);

    // Store in database (runtime query, no compile-time DB check needed)
    let rate_decimal = Decimal::from_str(&rate.to_string()).unwrap_or_default();
    sqlx::query(
        r#"
        INSERT INTO exchange_rates (base_currency, target_currency, rate, recorded_at)
        VALUES ($1, $2, $3, NOW())
        ON CONFLICT (base_currency, target_currency, recorded_at) DO UPDATE
        SET rate = EXCLUDED.rate
        "#
    )
    .bind(base.to_uppercase())
    .bind(target.to_uppercase())
    .bind(rate_decimal)
    .execute(db)
    .await?;

    // Store in Redis with TTL (e.g., 1 hour = 3600 seconds)
    if let Ok(mut conn) = redis_client.get_multiplexed_async_connection().await {
        let cache_key = format!("fx:{}:{}", base.to_uppercase(), target.to_uppercase());
        let _: Result<(), _> = redis::cmd("SETEX")
            .arg(&cache_key)
            .arg(3600)
            .arg(rate)
            .query_async(&mut conn)
            .await;
    }

    tracing::info!("Fetched exchange rate: 1 {} = {} {}", base, rate, target);
    Ok(rate)
}

#[derive(Deserialize)]
struct ErApiResponse {
    rates: std::collections::HashMap<String, f64>,
}
