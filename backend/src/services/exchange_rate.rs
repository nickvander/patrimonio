use anyhow::Result;
use reqwest::Client;
use rust_decimal::Decimal;
use serde::Deserialize;
use sqlx::{PgPool, Row};
use std::str::FromStr;
use std::time::Duration;

/// One hung upstream FX call must not wedge a caller forever (the same
/// failure mode that stuck the manual sync at "12/13" — see
/// services/sync.rs::SYNC_HTTP_TIMEOUT).
const FX_HTTP_TIMEOUT: Duration = Duration::from_secs(15);

/// Hard fallback when `exchange_rates` holds no usable USD/MXN row. Mirrors
/// `api::dashboard::FX_FALLBACK_USD_MXN` and the tail of
/// `services::tax::USD_MXN_ROW_RATE_SQL` — a wrong-ish magnitude beats the
/// alternative (see [`LATEST_USD_MXN_RATE_SQL`]).
pub const FX_FALLBACK_USD_MXN: &str = "20.0";

/// SQL scalar: the USD→MXN rate to convert a *present-day* balance with.
/// Always resolves to a positive number, so a caller can divide by it
/// unconditionally.
///
/// Ladder, matching `api::dashboard::latest_usd_mxn_rate` (the reader every
/// dashboard endpoint uses) so writes and reads can't disagree:
///   1. a user-entered `manual` override — a corrected rate must outrank a
///      bad upstream fetch;
///   2. else the freshest stored rate;
///   3. else the hard fallback.
///
/// `rate > 0` on both queries: a zero row must be skipped, not selected.
///
/// WHY this exists as a shared constant: every `balance_usd` writer used to
/// inline its own `ORDER BY recorded_at DESC LIMIT 1` and then, when that
/// came back NULL or zero, fall through to `ELSE <native balance>` — writing
/// a raw MXN figure into the USD column. A 400,000 MXN account then lands in
/// net worth as $400,000 instead of ~$22,900, and because the snapshot cron
/// is `ON CONFLICT DO NOTHING` and the chart carries values forward, that
/// spike sticks. The fallback rate is off by ~14%; the fallback it replaced
/// was off by ~1750%.
pub const LATEST_USD_MXN_RATE_SQL: &str = r#"COALESCE(
    (SELECT rate FROM exchange_rates
      WHERE base_currency = 'USD' AND target_currency = 'MXN'
        AND rate > 0 AND source = 'manual'
      ORDER BY recorded_at DESC LIMIT 1),
    (SELECT rate FROM exchange_rates
      WHERE base_currency = 'USD' AND target_currency = 'MXN'
        AND rate > 0
      ORDER BY recorded_at DESC LIMIT 1),
    20.0
)"#;

/// Rust-side twin of [`LATEST_USD_MXN_RATE_SQL`], for writers that compute
/// `balance_usd` in Rust rather than in the INSERT. Implemented by running
/// the constant itself, so the two can never drift.
///
/// Guaranteed positive: callers divide by it without a zero check.
pub async fn latest_usd_mxn_rate_for_write(db: &PgPool) -> Decimal {
    let fallback = Decimal::from_str(FX_FALLBACK_USD_MXN).unwrap_or(Decimal::ONE);
    sqlx::query_scalar::<_, Decimal>(&format!("SELECT {LATEST_USD_MXN_RATE_SQL}"))
        .fetch_one(db)
        .await
        .ok()
        .filter(|r| *r > Decimal::ZERO)
        .unwrap_or(fallback)
}

/// Fetches the latest exchange rate from the free ExchangeRate-API
/// and stores it in the database + Redis cache.
///
/// After storing, evaluates every user's FX alert for the pair: if the
/// rate moved across a configured threshold since the previous stored
/// rate, a `user_notifications` row (kind='fx_alert') is recorded for
/// the bell to surface. Alert evaluation is best-effort — a failure
/// there must never break the rate fetch itself.
pub async fn fetch_and_store_rate(
    db: &PgPool,
    redis_client: &redis::Client,
    base: &str,
    target: &str,
) -> Result<f64> {
    let client = Client::builder().timeout(FX_HTTP_TIMEOUT).build()?;

    // Free tier: https://open.er-api.com/v6/latest/{base}
    let url = format!("https://open.er-api.com/v6/latest/{}", base.to_uppercase());
    let resp = client.get(&url).send().await?.json::<ErApiResponse>().await?;

    let rate = resp
        .rates
        .get(&target.to_uppercase())
        .copied()
        .unwrap_or(0.0);

    let rate_decimal = Decimal::from_str(&rate.to_string()).unwrap_or_default();

    // Refuse to store a non-positive rate. `rates.get(target)` defaults to 0.0
    // when the upstream payload omits the pair, and a stored 0 is poison: it
    // becomes the freshest row, every conversion that divides by it is NULL or
    // skipped, and the writers that fall back on a missing rate would record
    // native MXN as USD. `post_manual_rate` already rejects this; the
    // automated path must too.
    if rate_decimal <= Decimal::ZERO {
        anyhow::bail!(
            "upstream returned no usable {}/{} rate (got {rate}); not storing",
            base.to_uppercase(),
            target.to_uppercase()
        );
    }

    // Snapshot the previous stored rate BEFORE inserting the new one —
    // crossing detection is edge-triggered on (prev, new), which also
    // self-debounces: once notified, the rate sits on the new side of the
    // threshold and won't re-trigger until it crosses back.
    let prev_rate: Option<Decimal> = sqlx::query_scalar(
        r#"
        SELECT rate FROM exchange_rates
        WHERE base_currency = $1 AND target_currency = $2
        ORDER BY recorded_at DESC
        LIMIT 1
        "#,
    )
    .bind(base.to_uppercase())
    .bind(target.to_uppercase())
    .fetch_optional(db)
    .await
    .unwrap_or(None);

    // Store in database (runtime query, no compile-time DB check needed)
    sqlx::query(
        r#"
        INSERT INTO exchange_rates (base_currency, target_currency, rate, recorded_at, source)
        VALUES ($1, $2, $3, NOW(), 'api')
        ON CONFLICT (base_currency, target_currency, recorded_at) DO UPDATE
        SET rate = EXCLUDED.rate, source = EXCLUDED.source
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

    // Best-effort alert fan-out; never fail the fetch over it.
    if let (Some(prev), true) = (prev_rate, rate_decimal > Decimal::ZERO) {
        if let Err(e) =
            record_fx_alert_crossings(db, base, target, prev, rate_decimal).await
        {
            tracing::warn!("FX alert evaluation failed for {base}/{target}: {e}");
        }
    }

    tracing::info!("Fetched exchange rate: 1 {} = {} {}", base, rate, target);
    Ok(rate)
}

/// Did the rate cross `threshold` moving from `prev` to `new`?
///
/// Edge-triggered: true only when the two rates sit on opposite sides
/// (landing exactly ON the threshold counts as having reached it from
/// the departing side). Touch-without-leaving (prev == threshold == new)
/// is not a crossing.
pub fn threshold_crossed(prev: Decimal, new: Decimal, threshold: Decimal) -> bool {
    (prev < threshold && new >= threshold) || (prev > threshold && new <= threshold)
}

/// Record a `user_notifications` row for every user whose FX alert
/// threshold was crossed by the move `prev` → `new` on this pair.
///
/// ⚠ The alert SELECT is deliberately NOT scoped to one user: a rate
/// refresh is a system-wide event and must fan out to every user who
/// configured an alert on the pair. Each inserted notification IS
/// user-scoped via the alert row's own user_id.
///
/// Title/body are stored in English with the concrete numbers embedded;
/// the future notifications center can re-render off `kind='fx_alert'`
/// if it wants locale-aware copy.
pub async fn record_fx_alert_crossings(
    db: &PgPool,
    base: &str,
    target: &str,
    prev: Decimal,
    new: Decimal,
) -> Result<usize> {
    if prev == new {
        return Ok(0);
    }
    let base = base.to_uppercase();
    let target = target.to_uppercase();

    let alerts = sqlx::query(
        r#"
        SELECT id, user_id, threshold
        FROM user_fx_alerts
        WHERE base_currency = $1 AND target_currency = $2
        "#,
    )
    .bind(&base)
    .bind(&target)
    .fetch_all(db)
    .await?;

    let mut recorded = 0usize;
    for row in alerts {
        let alert_id: uuid::Uuid = row.try_get("id")?;
        let user_id: uuid::Uuid = row.try_get("user_id")?;
        let threshold: Decimal = row.try_get("threshold")?;
        if !threshold_crossed(prev, new, threshold) {
            continue;
        }

        // Presentation rounding only — comparisons above used full precision.
        let title = format!("{base}/{target} crossed {}", threshold.normalize());
        let body = format!(
            "The {base}/{target} exchange rate moved from {} to {}, crossing your alert threshold of {}.",
            prev.round_dp(4).normalize(),
            new.round_dp(4).normalize(),
            threshold.normalize(),
        );
        sqlx::query(
            r#"
            INSERT INTO user_notifications (user_id, kind, title, body)
            VALUES ($1, 'fx_alert', $2, $3)
            "#,
        )
        .bind(user_id)
        .bind(&title)
        .bind(&body)
        .execute(db)
        .await?;
        sqlx::query("UPDATE user_fx_alerts SET last_notified_at = NOW() WHERE id = $1")
            .bind(alert_id)
            .execute(db)
            .await?;
        recorded += 1;
    }
    Ok(recorded)
}

#[derive(Deserialize)]
struct ErApiResponse {
    rates: std::collections::HashMap<String, f64>,
}

#[cfg(test)]
mod tests {
    use super::threshold_crossed;
    use rust_decimal_macros::dec;

    #[test]
    fn crossing_up_and_down_detected() {
        assert!(threshold_crossed(dec!(17.4), dec!(17.6), dec!(17.5)));
        assert!(threshold_crossed(dec!(17.6), dec!(17.4), dec!(17.5)));
    }

    #[test]
    fn landing_exactly_on_threshold_counts() {
        assert!(threshold_crossed(dec!(17.4), dec!(17.5), dec!(17.5)));
        assert!(threshold_crossed(dec!(17.6), dec!(17.5), dec!(17.5)));
    }

    #[test]
    fn same_side_moves_do_not_trigger() {
        assert!(!threshold_crossed(dec!(17.1), dec!(17.4), dec!(17.5)));
        assert!(!threshold_crossed(dec!(17.9), dec!(17.6), dec!(17.5)));
        // Departing FROM the threshold isn't a new crossing — the arrival
        // already notified.
        assert!(!threshold_crossed(dec!(17.5), dec!(17.6), dec!(17.5)));
        assert!(!threshold_crossed(dec!(17.5), dec!(17.5), dec!(17.5)));
    }
}
