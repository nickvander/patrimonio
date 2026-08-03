//! HTTP-level integration tests for `GET /api/exports/continuity-dossier` —
//! the printable household continuity dossier.
//!
//! Covers the invariants the feature was specified with: auth required,
//! strict per-user scoping (a second user's accounts never appear), the
//! bilingual lang toggle (es renders Spanish headings), the owner-written
//! instructions round-trip through the generic app-settings store (with
//! HTML-escaping), the latest-snapshot / staleness figures, and — the hard
//! rule — that NO encrypted-column material (`plaid_access_token_enc`,
//! `api_key_enc`/`api_secret_enc`, `totp_secret_enc`) or session-token
//! material ever reaches the rendered HTML.
//!
//! Shared harness + fixtures: `tests/common/fixtures.rs`.

mod common;
use common::fixtures::*;

/// GET the dossier and return `(status, body-as-string)`. The body is HTML,
/// not JSON, so this bypasses the `body_json` helper.
async fn get_dossier(app: &Router, cookie: Option<&str>, lang: &str) -> (StatusCode, String) {
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            &format!("/api/exports/continuity-dossier?lang={lang}"),
            None,
            cookie,
        ))
        .await
        .unwrap();
    let status = res.status();
    let bytes = to_bytes(res.into_body(), 4 * 1024 * 1024)
        .await
        .expect("read dossier body");
    (
        status,
        String::from_utf8(bytes.to_vec()).unwrap_or_default(),
    )
}

/// Seed an institution + account with caller-chosen names (the shared
/// `seed_account` fixture hardcodes "Test Bank"/"Checking", which the
/// scoping test needs to distinguish from the second user's rows).
async fn seed_named_account(
    pool: &PgPool,
    user_id: uuid::Uuid,
    inst_name: &str,
    acct_name: &str,
    country: &str,
    currency: &str,
) -> (uuid::Uuid, uuid::Uuid) {
    let inst_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO institutions (name, institution_type, country, integration_type, sync_status, user_id) \
         VALUES ($1, 'bank', $2, 'manual', 'ok', $3) RETURNING id",
    )
    .bind(inst_name)
    .bind(country)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed institution");
    let acct_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO accounts (institution_id, name, account_type, currency, current_balance, user_id) \
         VALUES ($1, $2, 'depository', $3, 1000.00, $4) RETURNING id",
    )
    .bind(inst_id)
    .bind(acct_name)
    .bind(currency)
    .bind(user_id)
    .fetch_one(pool)
    .await
    .expect("seed account");
    (inst_id, acct_id)
}

/// Seed a balance snapshot with an explicit date + native/USD balances.
async fn seed_snapshot(
    pool: &PgPool,
    user_id: uuid::Uuid,
    account_id: uuid::Uuid,
    as_of: &str,
    currency: &str,
    balance: &str,
    balance_usd: &str,
) {
    sqlx::query(
        "INSERT INTO balance_snapshots (account_id, balance, as_of_date, currency, balance_usd, user_id) \
         VALUES ($1, $2, $3::date, $4, $5, $6)",
    )
    .bind(account_id)
    .bind(Decimal::from_str(balance).unwrap())
    .bind(as_of)
    .bind(currency)
    .bind(Decimal::from_str(balance_usd).unwrap())
    .bind(user_id)
    .execute(pool)
    .await
    .expect("seed snapshot");
}

#[tokio::test]
#[serial_test::serial]
async fn dossier_requires_auth() {
    let Some((app, _pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (status, _body) = get_dossier(&app, None, "en").await;
    assert_eq!(
        status,
        StatusCode::UNAUTHORIZED,
        "dossier must not render without a session"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn dossier_lists_only_the_callers_accounts() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    seed_named_account(&pool, user_id, "Mine Bank", "Mine Checking", "US", "USD").await;

    // A second, fully separate user with their own institution + account.
    let (other_id, other_token) = seed_owner(&pool, "neighbor").await;
    seed_named_account(
        &pool,
        other_id,
        "Rival Credit Union",
        "Rival Savings",
        "US",
        "USD",
    )
    .await;

    let (status, html) = get_dossier(&app, Some(&token), "en").await;
    assert_eq!(status, StatusCode::OK);
    assert!(html.contains("Mine Bank"), "own institution should render");
    assert!(html.contains("Mine Checking"), "own account should render");
    assert!(
        !html.contains("Rival Credit Union") && !html.contains("Rival Savings"),
        "another user's rows must never appear in the dossier"
    );

    // And symmetrically: the neighbor's dossier never shows the owner's rows.
    let (status, html) = get_dossier(&app, Some(&other_token), "en").await;
    assert_eq!(status, StatusCode::OK);
    assert!(html.contains("Rival Credit Union"));
    assert!(
        !html.contains("Mine Bank") && !html.contains("Mine Checking"),
        "scoping must hold in both directions"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn dossier_renders_spanish_headings_for_lang_es() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    seed_account(&pool, user_id).await;

    let (status, html) = get_dossier(&app, Some(&token), "es").await;
    assert_eq!(status, StatusCode::OK);
    assert!(html.contains("Expediente de continuidad del hogar"));
    assert!(html.contains("Instituciones y cuentas"));
    assert!(html.contains("Instrucciones del titular"));
    assert!(html.contains(r#"<html lang="es""#));

    // Default (no/other lang) renders English.
    let (status, html) = get_dossier(&app, Some(&token), "en").await;
    assert_eq!(status, StatusCode::OK);
    assert!(html.contains("Household continuity dossier"));
    assert!(html.contains("Institutions &amp; accounts"));
    assert!(html.contains(r#"<html lang="en""#));
}

#[tokio::test]
#[serial_test::serial]
async fn dossier_never_contains_encrypted_column_material() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (inst_id, _acct) =
        seed_named_account(&pool, user_id, "Plaid Bank", "Linked Checking", "US", "USD").await;

    // Plant distinctive markers in every encrypted column the schema has.
    // If any query in the dossier ever grows a `SELECT *` (or someone adds
    // a token column to the output), this test catches it.
    const PLAID_MARKER: &str = "PLAID-TOKEN-SECRET-MARKER-9f31";
    const API_KEY_MARKER: &str = "CRYPTO-API-KEY-MARKER-77ab";
    const API_SECRET_MARKER: &str = "CRYPTO-API-SECRET-MARKER-c0de";
    const TOTP_MARKER: &str = "TOTP-SECRET-MARKER-4242";
    sqlx::query(
        "UPDATE institutions SET plaid_access_token_enc = $1, plaid_item_id = 'item-xyz', \
         api_key_enc = $2, api_secret_enc = $3 WHERE id = $4",
    )
    .bind(PLAID_MARKER.as_bytes())
    .bind(API_KEY_MARKER.as_bytes())
    .bind(API_SECRET_MARKER.as_bytes())
    .bind(inst_id)
    .execute(&pool)
    .await
    .expect("plant institution secrets");
    sqlx::query("UPDATE users SET totp_secret_enc = $1 WHERE id = $2")
        .bind(TOTP_MARKER.as_bytes())
        .bind(user_id)
        .execute(&pool)
        .await
        .expect("plant totp secret");

    for lang in ["en", "es"] {
        let (status, html) = get_dossier(&app, Some(&token), lang).await;
        assert_eq!(status, StatusCode::OK);
        for marker in [PLAID_MARKER, API_KEY_MARKER, API_SECRET_MARKER, TOTP_MARKER] {
            assert!(
                !html.contains(marker),
                "encrypted-column material leaked into the {lang} dossier: {marker}"
            );
            // BYTEA read through a text path would surface hex-encoded —
            // reject that representation too.
            let hex: String = marker.bytes().map(|b| format!("{b:02x}")).collect();
            assert!(
                !html.to_lowercase().contains(&hex),
                "hex-encoded secret leaked into the {lang} dossier: {marker}"
            );
        }
        // Session/auth material must not appear either.
        assert!(
            !html.contains(&token),
            "session token leaked into the {lang} dossier"
        );
        // Belt-and-suspenders: nothing should even mention the enc columns.
        assert!(
            !html.contains("_enc"),
            "encrypted column name leaked into the {lang} dossier"
        );
    }
}

#[tokio::test]
#[serial_test::serial]
async fn continuity_notes_round_trip_and_are_escaped() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    seed_account(&pool, user_id).await;

    // Before any write, the dossier shows the empty-state hint.
    let (_status, html) = get_dossier(&app, Some(&token), "en").await;
    assert!(html.contains("No instructions written yet"));

    // Save the instructions through the SAME generic settings endpoint the
    // frontend uses (PUT /api/settings/continuity_notes with a JSON string).
    let notes = "Call the notary first — safe deposit box #42.\nThen <script>alert(1)</script>";
    let res = app
        .clone()
        .oneshot(req(
            Method::PUT,
            "/api/settings/continuity_notes",
            Some(&Value::String(notes.to_string())),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK, "settings PUT should succeed");

    // Round-trip read through the settings GET…
    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/settings/continuity_notes",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body, Value::String(notes.to_string()));

    // …and into the rendered dossier, HTML-escaped (no live <script>).
    let (status, html) = get_dossier(&app, Some(&token), "en").await;
    assert_eq!(status, StatusCode::OK);
    assert!(html.contains("Call the notary first — safe deposit box #42."));
    assert!(
        html.contains("&lt;script&gt;alert(1)&lt;/script&gt;"),
        "notes must be HTML-escaped"
    );
    assert!(
        !html.contains("<script>alert(1)</script>"),
        "raw markup from the notes must never render"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn dossier_shows_latest_snapshot_and_staleness_date() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, acct) =
        seed_named_account(&pool, user_id, "Snap Bank", "Snap Checking", "US", "USD").await;
    // Two snapshots: only the NEWEST balance + date may render (last row
    // per account wins — the carry-forward "latest known value" rule).
    seed_snapshot(
        &pool,
        user_id,
        acct,
        "2026-01-05",
        "USD",
        "1234.00",
        "1234.00",
    )
    .await;
    seed_snapshot(
        &pool,
        user_id,
        acct,
        "2026-03-10",
        "USD",
        "2500.00",
        "2500.00",
    )
    .await;

    let (status, html) = get_dossier(&app, Some(&token), "en").await;
    assert_eq!(status, StatusCode::OK);
    assert!(
        html.contains("2,500.00"),
        "latest snapshot balance should render"
    );
    assert!(!html.contains("1,234.00"), "stale balance must not render");
    // The newest snapshot date doubles as the cover page's "Data as of".
    assert!(html.contains("2026-03-10"));
    assert!(html.contains("Data as of"));
}

#[tokio::test]
#[serial_test::serial]
async fn dossier_includes_lending_book_holdings_and_fbar_flag() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    // A foreign (MX) account → FBAR column shows Yes and the FBAR note renders.
    let (_inst, acct) =
        seed_named_account(&pool, user_id, "Banorte", "Cuenta Nómina", "MX", "MXN").await;

    // One holding on the account.
    sqlx::query(
        "INSERT INTO holdings (account_id, symbol, name, quantity, price, value, currency, user_id) \
         VALUES ($1, 'VTI', 'Vanguard Total Market', 10, 250.00, 2500.00, 'USD', $2)",
    )
    .bind(acct)
    .bind(user_id)
    .execute(&pool)
    .await
    .expect("seed holding");

    // One loan with a partial principal repayment: outstanding = 1000 − 250.
    let loan_id: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO loans (user_id, borrower_name, principal, currency, origination_date, status) \
         VALUES ($1, 'Cousin Memo', 1000, 'MXN', '2026-01-15', 'active') RETURNING id",
    )
    .bind(user_id)
    .fetch_one(&pool)
    .await
    .expect("seed loan");
    sqlx::query(
        "INSERT INTO loan_payments (user_id, loan_id, installment_number, scheduled_amount, \
         principal_portion, paid_amount, paid_date, status) \
         VALUES ($1, $2, 1, 250, 250, 250, '2026-02-15', 'paid')",
    )
    .bind(user_id)
    .bind(loan_id)
    .execute(&pool)
    .await
    .expect("seed loan payment");

    let (status, html) = get_dossier(&app, Some(&token), "en").await;
    assert_eq!(status, StatusCode::OK);
    // Holdings summary.
    assert!(html.contains("Holdings summary"));
    assert!(html.contains("VTI"));
    assert!(html.contains("Vanguard Total Market"));
    // Lending book with the derived outstanding figure.
    assert!(html.contains("Personal lending book"));
    assert!(html.contains("Cousin Memo"));
    assert!(html.contains("750.00"), "outstanding = principal − repaid");
    assert!(html.contains("promissory note"));
    // FBAR flag column carries a Yes for the MX account, plus the note.
    assert!(html.contains("foreign/reportable"));
}
