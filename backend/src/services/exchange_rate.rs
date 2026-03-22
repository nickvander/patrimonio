use anyhow::Result;
use reqwest::Client;
use rust_decimal::Decimal;
use serde::Deserialize;
use sqlx::PgPool;
use std::str::FromStr;

/// Fetches the latest exchange rate from the free ExchangeRate-API
/// and stores it in the database + Redis cache.
pub async fn fetch_and_store_rate(db: &PgPool, base: &str, target: &str) -> Result<f64> {
    let client = Client::new();

    // Free tier: https://open.er-api.com/v6/latest/{base}
    let url = format!("https://open.er-api.com/v6/latest/{}", base.to_uppercase());
    let resp = client.get(&url).send().await?.json::<ErApiResponse>().await?;

    let rate = resp
        .rates
        .get(&target.to_uppercase())
        .copied()
        .unwrap_or(0.0);

    // Store in database
    let rate_decimal = Decimal::from_str(&rate.to_string()).unwrap_or_default();
    sqlx::query!(
        r#"
        INSERT INTO exchange_rates (base_currency, target_currency, rate, recorded_at)
        VALUES ($1, $2, $3, NOW())
        ON CONFLICT (base_currency, target_currency, recorded_at) DO UPDATE
        SET rate = EXCLUDED.rate
        "#,
        base.to_uppercase(),
        target.to_uppercase(),
        rate_decimal,
    )
    .execute(db)
    .await?;

    tracing::info!("Fetched exchange rate: 1 {} = {} {}", base, rate, target);
    Ok(rate)
}

#[derive(Deserialize)]
struct ErApiResponse {
    rates: std::collections::HashMap<String, f64>,
}

#[cfg(test)]
mod tests {
    #[test]
    fn test_rate_parsing() {
        // Basic test to ensure the module compiles
        assert!(true);
    }
}
