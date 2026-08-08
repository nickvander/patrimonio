//! HTTP-level integration tests for `/api/dashboard/net-worth-attribution`.
//!
//! The non-negotiable assertion is the sum invariant: for every currency
//! bucket and for the USD totals, `flows + market + fx + residual == delta`
//! EXACTLY — compared in `Decimal` parsed from the response's literal JSON
//! number text, never through f64 epsilon comparisons.
//!
//! Shared harness + fixtures: `tests/common/fixtures.rs`.

mod common;
use common::fixtures::*;

/// Insert one balance snapshot with explicit native + USD balances. The
/// endpoint under test must treat these with carry-forward semantics
/// (nearest-prior row per account), which is exactly what the gap-y
/// seeding below exercises.
async fn seed_snapshot(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    date: &str,
    balance: &str,
    currency: &str,
    balance_usd: &str,
) {
    sqlx::query(
        "INSERT INTO balance_snapshots (account_id, balance, as_of_date, currency, balance_usd, user_id) \
         VALUES ($1, $2::numeric, $3::date, $4, $5::numeric, $6)",
    )
    .bind(account_id)
    .bind(balance)
    .bind(date)
    .bind(currency)
    .bind(balance_usd)
    .bind(user_id)
    .execute(pool)
    .await
    .expect("seed snapshot");
}

/// Insert a USD→MXN rate at an explicit timestamp (the fixtures helper only
/// supports days-ago offsets; these tests need wall-clock-independent dates).
async fn seed_fx_rate_at(pool: &PgPool, rate: &str, recorded_at: &str) {
    sqlx::query(
        "INSERT INTO exchange_rates (base_currency, target_currency, rate, recorded_at) \
         VALUES ('USD', 'MXN', $1::numeric, $2::timestamptz)",
    )
    .bind(rate)
    .bind(recorded_at)
    .execute(pool)
    .await
    .expect("seed fx rate");
}

/// Seed an account with an explicit currency + account type under a fresh
/// institution; returns the account id.
async fn seed_account_typed_currency(
    pool: &PgPool,
    user_id: uuid::Uuid,
    name: &str,
    account_type: &str,
    currency: &str,
) -> uuid::Uuid {
    let inst_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ($1, 'bank', 'US', 'manual', 'ok', $2) RETURNING id",
    )
    .bind(format!("{name} Inst"))
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed institution");
    sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, $2, $3, $4, 0.00, $5) RETURNING id",
    )
    .bind(inst_id)
    .bind(name)
    .bind(account_type)
    .bind(currency)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed account")
}

/// Insert a transaction with explicit date + currency + amount.
async fn seed_tx_dated_currency(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    description: &str,
    amount: &str,
    currency: &str,
    date: &str,
) {
    sqlx::query(
        "INSERT INTO transactions (account_id, date, description, amount, currency, source, user_id) \
         VALUES ($1, $2::date, $3, $4::numeric, $5, 'manual', $6)",
    )
    .bind(account_id)
    .bind(date)
    .bind(description)
    .bind(amount)
    .bind(currency)
    .bind(user_id)
    .execute(pool)
    .await
    .expect("seed dated currency tx");
}

/// Parse a JSON number as `Decimal` from its literal text — the exactness
/// vehicle for the invariant assertions (f64 addition of 2-dp values is not
/// exact; Decimal over the serialized digits is).
fn dec(v: &Value) -> Decimal {
    Decimal::from_str(&v.to_string()).unwrap_or_else(|_| panic!("not a decimal number: {v}"))
}

/// Assert `flows + market + fx + residual == delta` EXACTLY on one object
/// carrying `{prefix}` fields (`""` for the USD totals, `"_native"` /
/// `"_usd"` for per-currency buckets).
fn assert_invariant(obj: &Value, delta_key: &str, keys: [&str; 4], label: &str) {
    let sum = keys.iter().map(|k| dec(&obj[k])).sum::<Decimal>();
    let delta = dec(&obj[delta_key]);
    assert_eq!(
        sum, delta,
        "{label}: flows+market+fx+residual ({sum}) != {delta_key} ({delta}) — components: {obj}"
    );
}

async fn get_attribution(app: &Router, token: &str, from: &str, to: &str) -> Value {
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/dashboard/net-worth-attribution?from={from}&to={to}"),
            None,
            Some(token),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::OK,
        "attribution GET should be 200"
    );
    body_json(res.into_body()).await
}

fn currency_bucket<'a>(body: &'a Value, currency: &str) -> &'a Value {
    body["per_currency"]
        .as_array()
        .expect("per_currency array")
        .iter()
        .find(|c| c["currency"] == currency)
        .unwrap_or_else(|| panic!("no {currency} bucket in {body}"))
}

// =====================================================================
// The sum invariant on a multi-currency, gap-y fixture
// =====================================================================

/// Multi-currency accounts snapshotted on DIFFERENT days (one only before
/// the window — pure carry-forward), mid-window transactions in both
/// currencies, an FX rate move (20 → 25), and a liability account. The
/// decomposition must sum exactly to the observed delta per currency and
/// in USD, with the MXN snapshot-write-rate slop landing in the residual —
/// never silently spread across the named components.
#[tokio::test]
#[serial_test::serial]
async fn attribution_sum_invariant_multi_currency_gapy_snapshots() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;

    // Rate ladder: 20.0 in effect at the window open (2026-02-01) and for
    // the mid-window MXN deposit on 2026-02-15; 25.0 at the close.
    seed_fx_rate_at(&pool, "20.0", "2026-01-10T12:00:00Z").await;
    seed_fx_rate_at(&pool, "25.0", "2026-02-20T12:00:00Z").await;

    let checking =
        seed_account_typed_currency(&pool, user_id, "Checking", "depository", "USD").await;
    let mx_acct = seed_account_typed_currency(&pool, user_id, "Cetes", "investment", "MXN").await;
    let card = seed_account_typed_currency(&pool, user_id, "Card", "credit card", "USD").await;

    // Gap-y snapshots: every account's opening value comes from a row BEFORE
    // 2026-02-01 (nearest-prior carry-forward), and each closes on a
    // different in-window day. A per-date GROUP BY would see no complete day.
    seed_snapshot(
        &pool,
        user_id,
        checking,
        "2026-01-15",
        "1000.00",
        "USD",
        "1000.00",
    )
    .await;
    seed_snapshot(
        &pool,
        user_id,
        checking,
        "2026-02-25",
        "1500.00",
        "USD",
        "1500.00",
    )
    .await;
    // MXN: balance_usd written at the snapshot-cron's rate; the closing row
    // uses 25.0 (21000/25 = 840) so the endpoint-ladder math reconciles via
    // the residual, not by fudging fx/market.
    seed_snapshot(
        &pool,
        user_id,
        mx_acct,
        "2026-01-20",
        "20000.00",
        "MXN",
        "1000.00",
    )
    .await;
    seed_snapshot(
        &pool,
        user_id,
        mx_acct,
        "2026-02-28",
        "21000.00",
        "MXN",
        "840.00",
    )
    .await;
    // Liability: negative native/USD balances; contributes -abs().
    seed_snapshot(
        &pool,
        user_id,
        card,
        "2026-01-31",
        "-500.00",
        "USD",
        "-500.00",
    )
    .await;
    seed_snapshot(
        &pool,
        user_id,
        card,
        "2026-02-26",
        "-580.00",
        "USD",
        "-580.00",
    )
    .await;

    // Mid-window flows: USD income, an MXN deposit (valued at the 2026-02-15
    // nearest-prior rate of 20.0 → $50), and a card purchase.
    seed_tx_dated_currency(
        &pool,
        user_id,
        checking,
        "Paycheck",
        "500.00",
        "USD",
        "2026-02-10",
    )
    .await;
    seed_tx_dated_currency(
        &pool,
        user_id,
        mx_acct,
        "Deposit",
        "1000.00",
        "MXN",
        "2026-02-15",
    )
    .await;
    seed_tx_dated_currency(
        &pool,
        user_id,
        card,
        "Groceries",
        "-80.00",
        "USD",
        "2026-02-20",
    )
    .await;

    let body = get_attribution(&app, &token, "2026-02-01", "2026-03-01").await;

    // --- the invariant, per currency (native AND usd) and on the totals ---
    let usd = currency_bucket(&body, "USD");
    let mxn = currency_bucket(&body, "MXN");
    for (bucket, label) in [(usd, "USD"), (mxn, "MXN")] {
        assert_invariant(
            bucket,
            "delta_native",
            [
                "flows_native",
                "market_native",
                "fx_native",
                "residual_native",
            ],
            &format!("{label} native"),
        );
        assert_invariant(
            bucket,
            "delta_usd",
            ["flows_usd", "market_usd", "fx_usd", "residual_usd"],
            &format!("{label} usd"),
        );
    }
    assert_invariant(
        &body,
        "delta_usd",
        ["flows_usd", "market_usd", "fx_usd", "residual_usd"],
        "USD totals",
    );

    // --- pinned component values (documenting the convention) ---
    // USD bucket: open 1000-500=500, close 1500-580=920, flows 500-80=420,
    // pure flows → market 0, fx 0, residual 0.
    assert_eq!(dec(&usd["delta_usd"]), Decimal::from_str("420").unwrap());
    assert_eq!(dec(&usd["flows_usd"]), Decimal::from_str("420").unwrap());
    assert_eq!(dec(&usd["market_usd"]), Decimal::ZERO);
    assert_eq!(dec(&usd["fx_usd"]), Decimal::ZERO);
    assert_eq!(dec(&usd["residual_usd"]), Decimal::ZERO);

    // MXN native: 20000 → 21000, all of it the deposit → market 0.
    assert_eq!(
        dec(&mxn["delta_native"]),
        Decimal::from_str("1000").unwrap()
    );
    assert_eq!(
        dec(&mxn["flows_native"]),
        Decimal::from_str("1000").unwrap()
    );
    assert_eq!(dec(&mxn["market_native"]), Decimal::ZERO);
    // MXN usd: delta 840-1000 = -160; flows at the tx-date rate 1000/20 = 50;
    // fx on the opening balance 20000/25 - 20000/20 = -200; market 0;
    // residual -160 - 50 - (-200) = -10 — the honest snapshot-write-rate slop.
    assert_eq!(dec(&mxn["delta_usd"]), Decimal::from_str("-160").unwrap());
    assert_eq!(dec(&mxn["flows_usd"]), Decimal::from_str("50").unwrap());
    assert_eq!(dec(&mxn["fx_usd"]), Decimal::from_str("-200").unwrap());
    assert_eq!(dec(&mxn["market_usd"]), Decimal::ZERO);
    assert_eq!(dec(&mxn["residual_usd"]), Decimal::from_str("-10").unwrap());

    // Window-endpoint rates surfaced for the lens caption.
    assert_eq!(dec(&body["fx_rate_open"]), Decimal::from_str("20").unwrap());
    assert_eq!(
        dec(&body["fx_rate_close"]),
        Decimal::from_str("25").unwrap()
    );

    // Lens series: anchored at the window open (carry-forward state — no
    // account snapshotted on 2026-02-01), closing at the carried total.
    let series = body["series"].as_array().expect("series array");
    assert!(!series.is_empty(), "series should not be empty");
    assert_eq!(series[0]["date"], "2026-02-01");
    // Opening: usd 1000 - 500 + 1000(MXN row) = 1500.
    assert_eq!(dec(&series[0]["usd"]), Decimal::from_str("1500").unwrap());
    // Constant-FX lens: MXN revalued at r0 across the whole series — the
    // opening point matches the USD lens at open by construction...
    assert_eq!(
        dec(&series[0]["constant_fx_usd"]),
        Decimal::from_str("1500").unwrap()
    );
    let last = series.last().unwrap();
    assert_eq!(last["date"], "2026-02-28");
    // Closing carried total: 1500 (checking) - 580 (card) + 840 (MXN row).
    assert_eq!(dec(&last["usd"]), Decimal::from_str("1760").unwrap());
    // ...and the closing point ignores the peso slide: 1500 - 580 + 21000/20
    // = 1970, vs the USD lens's 920.
    assert_eq!(
        dec(&last["constant_fx_usd"]),
        Decimal::from_str("1970").unwrap()
    );
}

// =====================================================================
// Empty window
// =====================================================================

/// A window before any data (and a user with data only later) must return
/// all-zero totals, no currency buckets, and an empty series — not an error.
#[tokio::test]
#[serial_test::serial]
async fn attribution_empty_window_returns_zeros() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let acct = seed_account_typed_currency(&pool, user_id, "Checking", "depository", "USD").await;
    // Data exists, but only AFTER the queried window.
    seed_snapshot(
        &pool,
        user_id,
        acct,
        "2026-05-01",
        "1000.00",
        "USD",
        "1000.00",
    )
    .await;

    let body = get_attribution(&app, &token, "2025-01-01", "2025-02-01").await;
    for key in [
        "delta_usd",
        "flows_usd",
        "market_usd",
        "fx_usd",
        "residual_usd",
    ] {
        assert_eq!(dec(&body[key]), Decimal::ZERO, "{key} should be 0");
    }
    assert!(body["per_currency"].as_array().unwrap().is_empty());
    assert!(body["series"].as_array().unwrap().is_empty());
}

// =====================================================================
// User scoping
// =====================================================================

/// Another user's accounts/snapshots/transactions in the same window must
/// not leak into the caller's decomposition (every query is scoped
/// `WHERE user_id = $1`).
#[tokio::test]
#[serial_test::serial]
async fn attribution_scopes_to_the_authenticated_user() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;

    // Caller: one USD account, flat 100 across the window.
    let mine = seed_account_typed_currency(&pool, user_id, "Mine", "depository", "USD").await;
    seed_snapshot(
        &pool,
        user_id,
        mine,
        "2026-01-15",
        "100.00",
        "USD",
        "100.00",
    )
    .await;
    seed_snapshot(
        &pool,
        user_id,
        mine,
        "2026-02-15",
        "100.00",
        "USD",
        "100.00",
    )
    .await;

    // Other tenant: a large MXN account plus in-window flows.
    let (other_id, _other_token) = seed_owner(&pool, "other-tenant").await;
    let theirs = seed_account_typed_currency(&pool, other_id, "Theirs", "depository", "MXN").await;
    seed_snapshot(
        &pool,
        other_id,
        theirs,
        "2026-01-15",
        "90000.00",
        "MXN",
        "4500.00",
    )
    .await;
    seed_snapshot(
        &pool,
        other_id,
        theirs,
        "2026-02-15",
        "990000.00",
        "MXN",
        "49500.00",
    )
    .await;
    seed_tx_dated_currency(
        &pool,
        other_id,
        theirs,
        "Their deposit",
        "900000.00",
        "MXN",
        "2026-02-10",
    )
    .await;

    let body = get_attribution(&app, &token, "2026-02-01", "2026-03-01").await;
    let currencies: Vec<&str> = body["per_currency"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(|c| c["currency"].as_str())
        .collect();
    assert_eq!(currencies, vec!["USD"], "only the caller's currency bucket");
    assert_eq!(dec(&body["delta_usd"]), Decimal::ZERO);
    assert_eq!(dec(&body["flows_usd"]), Decimal::ZERO);
}

// =====================================================================
// Liability account
// =====================================================================

/// A credit-card spend must read as a negative flow explaining the whole
/// (negative) delta — liability balances contribute -abs() at both window
/// endpoints via the shared classifier, so market/fx/residual stay 0.
#[tokio::test]
#[serial_test::serial]
async fn attribution_liability_spend_is_a_negative_flow() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let card = seed_account_typed_currency(&pool, user_id, "Card", "credit card", "USD").await;
    seed_snapshot(
        &pool,
        user_id,
        card,
        "2026-01-31",
        "-1000.00",
        "USD",
        "-1000.00",
    )
    .await;
    seed_snapshot(
        &pool,
        user_id,
        card,
        "2026-02-20",
        "-1080.00",
        "USD",
        "-1080.00",
    )
    .await;
    seed_tx_dated_currency(
        &pool,
        user_id,
        card,
        "Dinner",
        "-80.00",
        "USD",
        "2026-02-10",
    )
    .await;

    let body = get_attribution(&app, &token, "2026-02-01", "2026-03-01").await;
    let usd = currency_bucket(&body, "USD");
    assert_eq!(
        dec(&usd["open_native"]),
        Decimal::from_str("-1000").unwrap()
    );
    assert_eq!(
        dec(&usd["close_native"]),
        Decimal::from_str("-1080").unwrap()
    );
    assert_eq!(dec(&usd["delta_usd"]), Decimal::from_str("-80").unwrap());
    assert_eq!(dec(&usd["flows_usd"]), Decimal::from_str("-80").unwrap());
    assert_eq!(dec(&usd["market_usd"]), Decimal::ZERO);
    assert_eq!(dec(&usd["fx_usd"]), Decimal::ZERO);
    assert_eq!(dec(&usd["residual_usd"]), Decimal::ZERO);
    assert_invariant(
        usd,
        "delta_usd",
        ["flows_usd", "market_usd", "fx_usd", "residual_usd"],
        "liability usd",
    );
}

// =====================================================================
// Parameter validation
// =====================================================================

/// Malformed dates and an inverted window are client errors, not 500s.
#[tokio::test]
#[serial_test::serial]
async fn attribution_rejects_bad_windows() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    for uri in [
        "/api/dashboard/net-worth-attribution?from=nonsense&to=2026-03-01",
        "/api/dashboard/net-worth-attribution?from=2026-03-01&to=2026-02-01",
        "/api/dashboard/net-worth-attribution?from=2026-02-01",
    ] {
        let res = app
            .clone()
            .oneshot(req(Method::GET, uri, None, Some(&token)))
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::BAD_REQUEST, "{uri} should be 400");
    }
}

// =====================================================================
// FX attributability — the window that opens before the rate history
// =====================================================================

/// A window opening BEFORE the oldest stored rate cannot have an FX
/// component computed: `rate_on`'s "latest row of any date" rung hands the
/// same rate back for both endpoints, so `B0/r1 - B0/r0` cancels to exactly
/// `0.00`. That zero is indistinguishable on the wire from a genuinely
/// FX-free window — and it shipped, reading "FX $0.00" to someone holding
/// MXN 970k across a year in which the peso moved 8%.
///
/// The response must now SAY it couldn't attribute, and name where the
/// history starts, so the client can render a dash instead of a figure.
#[tokio::test]
#[serial_test::serial]
async fn attribution_flags_windows_opening_before_the_rate_history() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let mx = seed_account_typed_currency(&pool, user_id, "Banamex", "depository", "MXN").await;

    // Rate history starts 2026-03-22 — exactly the prod shape that surfaced
    // this: a live provider that only ever serves "today".
    seed_fx_rate_at(&pool, "18.00", "2026-03-22T00:00:00Z").await;
    seed_fx_rate_at(&pool, "17.00", "2026-06-01T00:00:00Z").await;

    // Pesos held across the whole span, well before the rates begin.
    seed_snapshot(
        &pool,
        user_id,
        mx,
        "2025-08-01",
        "970000.00",
        "MXN",
        "52000.00",
    )
    .await;
    seed_snapshot(
        &pool,
        user_id,
        mx,
        "2026-07-01",
        "970000.00",
        "MXN",
        "57058.82",
    )
    .await;

    // Window opens before any stored rate → unattributable.
    let before = get_attribution(&app, &token, "2025-08-01", "2026-07-01").await;
    assert_eq!(
        before["fx_attributable"], false,
        "a window opening before the rate history cannot attribute fx"
    );
    assert_eq!(
        before["fx_rates_start"], "2026-03-22",
        "the client needs the date to name in its caption"
    );
    // The zero is still on the wire (the invariant depends on it) — the flag
    // is what stops a client printing it as a finding.
    assert_eq!(dec(&before["fx_usd"]), Decimal::ZERO);

    // Window opening ON the first rate date → attributable, and the two
    // endpoint rates genuinely differ, so fx is a real nonzero number.
    let after = get_attribution(&app, &token, "2026-03-22", "2026-07-01").await;
    assert_eq!(
        after["fx_attributable"], true,
        "opening exactly on the first stored rate is covered"
    );
    assert_ne!(
        dec(&after["fx_usd"]),
        Decimal::ZERO,
        "970k pesos across an 18.00 -> 17.00 move must show an fx component"
    );
}

/// With no stored rates at all there is no history to open after, so nothing
/// is attributable and there is no date to cite.
#[tokio::test]
#[serial_test::serial]
async fn attribution_reports_no_rate_history_at_all() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let mx = seed_account_typed_currency(&pool, user_id, "Banamex", "depository", "MXN").await;
    // Pesos held BEFORE the window opens — otherwise the opening MXN balance
    // is zero and fx is honestly zero regardless of rates (see
    // `attribution_usd_only_window_stays_attributable_without_rates`).
    seed_snapshot(
        &pool,
        user_id,
        mx,
        "2026-03-01",
        "500000.00",
        "MXN",
        "25000.00",
    )
    .await;
    seed_snapshot(
        &pool,
        user_id,
        mx,
        "2026-06-01",
        "500000.00",
        "MXN",
        "25000.00",
    )
    .await;

    let body = get_attribution(&app, &token, "2026-04-01", "2026-06-01").await;
    assert_eq!(body["fx_attributable"], false);
    assert!(
        body["fx_rates_start"].is_null(),
        "no rows means no history date to name"
    );
}

/// A missing opening rate only matters if there were pesos to revalue. A
/// USD-only window has a genuinely zero fx component however the rates
/// resolve, so it stays ATTRIBUTABLE — otherwise every USD-only user gets a
/// permanent dash where an honest $0.00 belongs.
#[tokio::test]
#[serial_test::serial]
async fn attribution_usd_only_window_stays_attributable_without_rates() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let usd = seed_account_typed_currency(&pool, user_id, "Checking", "depository", "USD").await;
    seed_fx_rate_at(&pool, "18.00", "2026-03-22T00:00:00Z").await;
    seed_snapshot(
        &pool,
        user_id,
        usd,
        "2025-08-01",
        "1000.00",
        "USD",
        "1000.00",
    )
    .await;
    seed_snapshot(
        &pool,
        user_id,
        usd,
        "2026-07-01",
        "1500.00",
        "USD",
        "1500.00",
    )
    .await;

    // Window opens long before the rate history, exactly as in the flagged
    // case — but with no MXN at the open there is nothing a rate could change.
    let body = get_attribution(&app, &token, "2025-08-01", "2026-07-01").await;
    assert_eq!(
        body["fx_attributable"], true,
        "no pesos at the open means fx is honestly zero, not unattributable"
    );
    assert_eq!(dec(&body["fx_usd"]), Decimal::ZERO);
}
