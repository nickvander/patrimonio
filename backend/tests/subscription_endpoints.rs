//! HTTP-level integration tests for the dashboard subscriptions
//! endpoint and its ignore/unignore companions.
//!
//! Split out of the former all-in-one `dashboard_endpoints.rs`. Shared
//! harness + fixtures: `tests/common/fixtures.rs`.

mod common;
use common::fixtures::*;

/// Seed a detectable recurring cluster: three equal charges 30 days apart,
/// the newest `newest_days_ago` days back. Three charges at a steady 30-day
/// gap is the minimum shape `detect_recurring_charges` accepts as recurring
/// (`MIN_OCCURRENCES` = 3, median gap inside the 5–62-day cadence band), and
/// a newest charge inside 90 days keeps the cluster `"active"`.
async fn seed_cluster(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    description: &str,
    amount: &str,
    newest_days_ago: i64,
) {
    const CADENCE_DAYS: i64 = 30;
    const CHARGES: i64 = 3;
    let today = chrono::Utc::now().date_naive();
    for i in 0..CHARGES {
        let date = today - chrono::Duration::days(newest_days_ago + CADENCE_DAYS * i);
        seed_tx_dated(
            pool,
            user_id,
            account_id,
            description,
            amount,
            &date.to_string(),
        )
        .await;
    }
}

/// GET the detected-subscriptions card as a JSON array.
async fn subscriptions(app: &Router, token: &str) -> Vec<Value> {
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/subscriptions",
            None,
            Some(token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "subscriptions should 200");
    body_json(res.into_body())
        .await
        .as_array()
        .expect("subscriptions array")
        .clone()
}

fn by_merchant<'a>(items: &'a [Value], merchant: &str) -> Option<&'a Value> {
    items.iter().find(|i| i["merchant"] == merchant)
}

// =====================================================================
// /api/dashboard/subscriptions — the merchant_key contract
// =====================================================================

/// The card must hand the client the SAME key the ignore endpoint consumes.
///
/// Before this, items carried only the display `merchant`, so any client
/// wanting to dismiss a card had to re-implement the detector's
/// normalisation itself — exactly the coupling `merchant_key` was added to
/// `/api/recurring/calendar` to avoid. The proof is the round trip: read
/// `merchant_key` off the response, POST that literal string back to
/// `/ignore`, and watch the cluster disappear. A field-presence assertion
/// alone would still pass if the value were the wrong string.
///
/// The fixture's description is deliberately mixed-case ("Netflix.COM") so
/// the assertion can distinguish the normalised key from the display label.
#[tokio::test]
#[serial_test::serial]
async fn subscription_merchant_key_round_trips_through_the_ignore_endpoint() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user) = bootstrap(&app, &pool).await;
    let (_inst, acct) = seed_account(&pool, user).await;

    // Two live clusters: the one we dismiss, and a control that must
    // survive (otherwise "cluster disappeared" is indistinguishable from
    // "the endpoint went empty").
    seed_cluster(&pool, user, acct, "Netflix.COM", "-15.99", 0).await;
    seed_cluster(&pool, user, acct, "SPOTIFY", "-11.99", 1).await;

    let items = subscriptions(&app, &token).await;
    let netflix = by_merchant(&items, "Netflix.COM")
        .unwrap_or_else(|| panic!("Netflix cluster should be detected: {items:?}"));

    // The key is present, non-empty, and is the NORMALISED form — not the
    // display label the sibling `merchant` field carries.
    let key = netflix["merchant_key"]
        .as_str()
        .unwrap_or_else(|| panic!("merchant_key must be a string: {netflix}"));
    assert!(!key.is_empty(), "merchant_key must be non-empty: {netflix}");
    assert_eq!(
        key, "netflix.com",
        "merchant_key is the detector's lowercased+trimmed key, not the display label: {netflix}"
    );

    // Round trip: echo the server-supplied key straight back into the
    // ignore endpoint. Note the wire field is named `merchant` but the
    // value is the merchant_key — that mismatch is the documented contract.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/dashboard/subscriptions/ignore",
            Some(&serde_json::json!({ "merchant": key })),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);

    // …and the cluster is gone from a subsequent read, while the control
    // cluster is untouched.
    let after = subscriptions(&app, &token).await;
    assert!(
        by_merchant(&after, "Netflix.COM").is_none(),
        "the key read off the response must be exactly what /ignore accepts: {after:?}"
    );
    assert!(
        by_merchant(&after, "SPOTIFY").is_some(),
        "only the dismissed merchant may disappear: {after:?}"
    );

    // Every remaining item still carries a usable key (the field is
    // populated for the whole collection, not just the first row).
    for item in &after {
        assert!(
            item["merchant_key"].as_str().is_some_and(|k| !k.is_empty()),
            "every item carries a non-empty merchant_key: {item}"
        );
    }

    // Un-ignoring with the same key resurfaces the cluster — the key is
    // the single identity across all three subscription routes.
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            &format!("/api/dashboard/subscriptions/ignored/{key}"),
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    let restored = subscriptions(&app, &token).await;
    assert!(
        by_merchant(&restored, "Netflix.COM").is_some(),
        "un-ignore by the same key brings the cluster back: {restored:?}"
    );
}

// =====================================================================
// /api/dashboard/subscriptions/ignore + /ignored
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn subscription_ignore_then_unignore_roundtrip() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    // Ignore (POST). Backend lowercases + trims the key.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/dashboard/subscriptions/ignore",
            Some(&serde_json::json!({"merchant": "  Interest Earned  "})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);

    // List should include the lowercased + trimmed key.
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/subscriptions/ignored",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let rows = body.as_array().unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0]["merchant_key"], "interest earned");

    // Idempotent re-ignore (POST again) is still 204, no duplicate row.
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/dashboard/subscriptions/ignore",
            Some(&serde_json::json!({"merchant": "interest earned"})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    let count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM ignored_subscription_merchants WHERE merchant_key = 'interest earned'",
    )
    .fetch_one(&pool)
    .await
    .unwrap();
    assert_eq!(count, 1);

    // Unignore (DELETE).
    let res = app
        .clone()
        .oneshot(req(
            Method::DELETE,
            "/api/dashboard/subscriptions/ignored/interest%20earned",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/dashboard/subscriptions/ignored",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert_eq!(body.as_array().unwrap().len(), 0);
}

#[tokio::test]
#[serial_test::serial]
async fn subscription_ignore_rejects_empty_key() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/dashboard/subscriptions/ignore",
            Some(&serde_json::json!({"merchant": "   "})),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
}
