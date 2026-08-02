//! HTTP-level integration tests for `/api/imports/upload` gates
//! (auth / CSRF / empty body) and the `/api/imports/continuity` report.
//! The CSV import de-dup/undo flows live in `import_endpoints.rs`.
//!
//! Split out of the former all-in-one `dashboard_endpoints.rs`. Shared
//! harness + fixtures: `tests/common/fixtures.rs`.

mod common;
use common::fixtures::*;

// =====================================================================
// /api/imports/upload — CSRF gate + auth gate + empty-body shape
// =====================================================================
// These tests exist because the frontend `uploadStatements` silently
// 403-ed for a week — the multipart helper bypassed `_withCsrf` so
// PDFs never reached the handler. The gate-level tests below catch
// that class of regression even without a real PDF fixture.

#[tokio::test]
#[serial_test::serial]
async fn upload_unauthenticated_is_401() {
    let Some((app, _pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    // With CSRF but no session cookie. Should hit require_auth → 401.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/imports/upload")
                .header("X-Requested-With", "patrimonio-test")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
#[serial_test::serial]
async fn upload_without_csrf_is_403() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    // No X-Requested-With → CSRF middleware short-circuits with 403
    // BEFORE the handler runs. This is the exact failure mode the
    // frontend was hitting silently.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/imports/upload")
                .header(header::COOKIE, cookie_header(&token))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);
}

#[tokio::test]
#[serial_test::serial]
async fn upload_with_no_files_is_400() {
    // CSRF + auth pass; multipart parses zero files → 400 "No files
    // were found in the upload request." Single-shot JSON response
    // (not NDJSON) because we never reach the spawn point.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/imports/upload")
                .header(header::COOKIE, cookie_header(&token))
                .header("X-Requested-With", "patrimonio-test")
                // Valid (empty) multipart body — boundary declared,
                // zero parts. Axum's multipart parser accepts the
                // empty body and the handler returns 400 on the
                // post-parse "no files" check.
                .header(
                    header::CONTENT_TYPE,
                    "multipart/form-data; boundary=----testboundary",
                )
                .body(Body::from("------testboundary--\r\n"))
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["status"], "error");
    assert!(body["message"].as_str().unwrap_or("").contains("No files"));
}

// =====================================================================
// /api/imports/continuity — statement-continuity report
// =====================================================================

/// Regression guard for the FBAR-class bug in `continuity_handler`: it
/// selected a nonexistent `a.institution_name`, so the query errored and
/// `.unwrap_or_default()` silently returned an EMPTY report (200, no rows) —
/// statement-continuity warnings never surfaced. Asserts the report is
/// POPULATED with the JOINED institution name for imported data, which the
/// broken (institutions-less) query could never satisfy.
#[tokio::test]
#[serial_test::serial]
async fn continuity_report_lists_imported_accounts_with_institution() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, user_id) = bootstrap(&app, &pool).await;
    let (_inst, account) = seed_account(&pool, user_id).await;
    seed_imported_tx(
        &pool,
        user_id,
        account,
        "2026-01-31",
        "100.00",
        "1100.00",
        "2026-01.pdf",
    )
    .await;
    seed_imported_tx(
        &pool,
        user_id,
        account,
        "2026-02-28",
        "50.00",
        "1150.00",
        "2026-02.pdf",
    )
    .await;

    let res = app
        .clone()
        .oneshot(req(
            Method::GET,
            "/api/imports/continuity",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    let status = res.status();
    let body = body_json(res.into_body()).await;
    assert_eq!(status, StatusCode::OK, "continuity body: {body}");

    let accounts = body["accounts"].as_array().expect("accounts array");
    // Broken query -> errored -> unwrap_or_default -> []. A populated row whose
    // institution_name came from the JOIN is the regression signal.
    assert_eq!(
        accounts.len(),
        1,
        "expected the one imported account, got: {body}"
    );
    assert_eq!(
        accounts[0]["institution_name"],
        serde_json::json!("Test Bank"),
        "{body}"
    );
    assert_eq!(
        accounts[0]["statement_count"],
        serde_json::json!(2),
        "{body}"
    );
}
