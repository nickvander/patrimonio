use anyhow::{anyhow, Result};
use rust_decimal::Decimal;
use serde_json::Value;
use std::str::FromStr;

pub struct CryptoPriceService;

impl CryptoPriceService {
    /// Fetch the latest spot price for a crypto symbol in a target fiat currency.
    pub async fn get_spot_price(symbol: &str, fiat: &str) -> Result<Decimal> {
        let client = reqwest::Client::new();
        let symbol = symbol.to_uppercase();
        let fiat = fiat.to_uppercase();

        if fiat == "USD" {
            let url = format!("https://api.coinbase.com/v2/prices/{symbol}-USD/spot");
            let res = client.get(&url).send().await?.json::<Value>().await?;
            
            if let Some(amount_str) = res["data"]["amount"].as_str() {
                return Decimal::from_str(amount_str).map_err(|e| anyhow!("Invalid decimal: {e}"));
            }
        } else if fiat == "MXN" {
            let book = format!("{}_mxn", symbol.to_lowercase());
            let url = format!("https://api.bitso.com/v3/ticker/?book={book}");
            let res = client.get(&url).send().await?.json::<Value>().await?;
            
            if let Some(last_str) = res["payload"]["last"].as_str() {
                return Decimal::from_str(last_str).map_err(|e| anyhow!("Invalid decimal: {e}"));
            }
        }

        Err(anyhow!("Could not fetch price for {symbol} in {fiat}"))
    }
}
