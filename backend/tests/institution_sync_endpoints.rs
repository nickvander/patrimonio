//! HTTP-level integration tests for the institutions sync surface:
//! the `/api/institutions/update-webhook` one-shot and the async manual
//! sync trigger (202 + status stamping).
//!
//! Split out of the former all-in-one `dashboard_endpoints.rs`. Shared
//! harness + fixtures: `tests/common/fixtures.rs`.

mod common;
use common::fixtures::*;

// =====================================================================
// /api/institutions/update-webhook
// =====================================================================

#[tokio::test]
#[serial_test::serial]
async fn update_webhook_503_when_plaid_creds_missing() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/institutions/update-webhook",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::SERVICE_UNAVAILABLE);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["error"], "Plaid is not configured");
}

#[tokio::test]
#[serial_test::serial]
async fn update_webhook_400_when_url_missing() {
    // Plaid creds set, but PLAID_WEBHOOK_URL is None → 400.
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(true, None).await) else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/institutions/update-webhook",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["error"], "PLAID_WEBHOOK_URL is not set");
}

#[tokio::test]
#[serial_test::serial]
async fn update_webhook_200_with_zero_when_no_items_linked() {
    // Plaid creds + URL set, but user has no Plaid items → 200 with
    // updated=0, failed=0 (no Plaid API call attempted).
    let Some((app, pool, _lock)) =
        skip_if_no_db(try_setup(true, Some("https://example.com/api/institutions/webhook")).await)
    else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/institutions/update-webhook",
            None,
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["updated"], 0);
    assert_eq!(body["failed"], 0);
    assert_eq!(
        body["webhook_url"],
        "https://example.com/api/institutions/webhook"
    );
    assert!(body["results"].as_array().unwrap().is_empty());
}

#[tokio::test]
#[serial_test::serial]
async fn update_webhook_unauthenticated_is_401() {
    let Some((app, _pool, _lock)) =
        skip_if_no_db(try_setup(true, Some("https://example.com")).await)
    else {
        return;
    };
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/institutions/update-webhook",
            None,
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
#[serial_test::serial]
async fn update_webhook_without_csrf_header_is_403() {
    let Some((app, pool, _lock)) =
        skip_if_no_db(try_setup(true, Some("https://example.com")).await)
    else {
        return;
    };
    let (token, _user) = bootstrap(&app, &pool).await;

    // Same request as above but missing X-Requested-With. CSRF
    // middleware sits OUTSIDE auth, so this is 403 (not 401).
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/institutions/update-webhook")
                .header(header::COOKIE, cookie_header(&token))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::FORBIDDEN);
}

/// The manual "Sync now" trigger must return immediately (202 Accepted) and
/// run the sync as a detached task — it no longer blocks the request on the
/// whole multi-institution sync. This is what keeps backgrounding the app
/// (which kills the socket) from cancelling the sync or surfacing a
/// "connection abort" error.
#[tokio::test]
async fn manual_sync_trigger_returns_202_immediately() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    // A manual-only institution: nothing to contact upstream, so the detached
    // task finishes trivially — but the endpoint contract (202 + accepted) is
    // the same regardless of what it kicks off.
    seed_inst(&pool, user_id, "manual", "ok").await;

    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/institutions/sync",
            None,
            Some(&cookie),
        ))
        .await
        .unwrap();
    let status = res.status();
    let body = body_json(res.into_body()).await;
    assert_eq!(
        status,
        StatusCode::ACCEPTED,
        "sync trigger must return 202, not block on the sync"
    );
    assert_eq!(body["status"], "accepted");
}

/// Regression: "Sync now" on web 415'd. The browser stamps `text/plain`
/// on a body-less POST, and the old `Option<Json<SyncRequest>>` extractor
/// rejects any present-but-non-JSON Content-Type with 415 Unsupported
/// Media Type. The handler now reads raw bytes and treats an empty body —
/// whatever its Content-Type — as "sync everything", while a non-empty
/// body that isn't valid JSON gets a 400 (never a silent sync-all when
/// the client asked for a subset).
#[tokio::test]
async fn manual_sync_tolerates_empty_non_json_body() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (cookie, user_id) = bootstrap(&app, &pool).await;
    seed_inst(&pool, user_id, "manual", "ok").await;

    // Empty body with Content-Type: text/plain — what a browser sends for
    // the frontend's old body-less POST. Must be accepted, not 415.
    let plain_empty = Request::builder()
        .method(Method::POST)
        .uri("/api/institutions/sync")
        .header("X-Requested-With", "patrimonio")
        .header(header::CONTENT_TYPE, "text/plain")
        .header(header::COOKIE, cookie_header(&cookie))
        .body(Body::empty())
        .unwrap();
    let res = app.clone().oneshot(plain_empty).await.unwrap();
    let status = res.status();
    let body = body_json(res.into_body()).await;
    assert_eq!(
        status,
        StatusCode::ACCEPTED,
        "empty text/plain body must be treated as 'sync everything', not 415"
    );
    assert_eq!(body["status"], "accepted");

    // A non-empty body that isn't JSON is a malformed request — 400, so a
    // broken batch client can't accidentally fan out to every institution.
    let garbage = Request::builder()
        .method(Method::POST)
        .uri("/api/institutions/sync")
        .header("X-Requested-With", "patrimonio")
        .header(header::CONTENT_TYPE, "text/plain")
        .header(header::COOKIE, cookie_header(&cookie))
        .body(Body::from("definitely not json"))
        .unwrap();
    let res = app.clone().oneshot(garbage).await.unwrap();
    assert_eq!(
        res.status(),
        StatusCode::BAD_REQUEST,
        "non-empty non-JSON body must 400, not sync everything"
    );

    // The JSON contract is unchanged: `{"ids": [...]}` still narrows the
    // sync, and the new frontend's explicit `{}` body still means "all".
    let res = app
        .clone()
        .oneshot(req(
            Method::POST,
            "/api/institutions/sync",
            Some(&serde_json::json!({})),
            Some(&cookie),
        ))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::ACCEPTED,
        "explicit empty-JSON body ('{{}}') must be accepted"
    );
}

/// `mark_syncable_syncing` is the synchronous pre-stamp the trigger runs
/// before spawning the detached task, so a client's `/sync-status` poll sees
/// the in-progress state the instant the trigger returns. It must mark only
/// the syncable integration types, only for the calling user, and (with
/// `only_ids`) only the requested subset.
#[tokio::test]
async fn mark_syncable_syncing_scopes_to_syncable_types_and_user() {
    let Some((app, pool, _lock)) = skip_if_no_db(try_setup(false, None).await) else {
        return;
    };
    let (_cookie, user_a) = bootstrap(&app, &pool).await;
    let user_b: uuid::Uuid = sqlx::query_scalar(
        "INSERT INTO users (username, password_hash) VALUES ('other', 'x') RETURNING id",
    )
    .fetch_one(&pool)
    .await
    .expect("seed second user");

    let plaid = seed_inst(&pool, user_a, "plaid", "synced").await;
    let coinbase = seed_inst(&pool, user_a, "coinbase", "error").await;
    let cbo = seed_inst(&pool, user_a, "coinbase_oauth", "reconnect_required").await;
    let bitso = seed_inst(&pool, user_a, "bitso", "synced").await;
    let manual = seed_inst(&pool, user_a, "manual", "manual").await;
    let csv = seed_inst(&pool, user_a, "csv", "manual").await;
    let b_plaid = seed_inst(&pool, user_b, "plaid", "synced").await;

    let marked = patrimonio::services::sync::mark_syncable_syncing(&pool, user_a, &None)
        .await
        .expect("mark syncable");
    assert_eq!(
        marked, 4,
        "only user A's 4 syncable institutions are marked"
    );

    for id in [plaid, coinbase, cbo, bitso] {
        assert_eq!(sync_status_of(&pool, id).await, "syncing");
    }
    // Manual/CSV are never contacted upstream — leave their status alone so
    // they don't get stuck showing "syncing" forever (the engine would never
    // flip them out of it).
    assert_eq!(sync_status_of(&pool, manual).await, "manual");
    assert_eq!(sync_status_of(&pool, csv).await, "manual");
    // Cross-tenant safety: another user's institution is never touched.
    assert_eq!(sync_status_of(&pool, b_plaid).await, "synced");

    // `only_ids` narrows the pre-stamp to the requested subset.
    let marked_one =
        patrimonio::services::sync::mark_syncable_syncing(&pool, user_a, &Some(vec![coinbase]))
            .await
            .expect("mark subset");
    assert_eq!(
        marked_one, 1,
        "only the one requested institution is marked"
    );
}
