//! HTTP-level integration tests for `/api/setup/status` (the Settings
//! "Launch setup" checklist).
//!
//! The frontend localizes each checklist row by the check's stable `key`
//! (see frontend/lib/utils/setup_check_l10n.dart) and only falls back to
//! the server's English `label` for keys it doesn't know. That makes the
//! key set part of the API contract: renaming or dropping a key silently
//! degrades es-MX back to English labels. These tests pin the keys, and
//! pin that `label`/`detail` keep shipping non-empty English strings for
//! backward compat with older frontends.
//!
//! Like the sibling suites, these need a real Postgres reachable via
//! `PATRIMONIO_TEST_DATABASE_URL`; when unset they print a skip note and
//! return (set-but-unreachable PANICS — see tests/common/mod.rs).

use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{Method, Request, StatusCode};
use axum::Router;
use serde_json::Value;
use sqlx::postgres::PgPoolOptions;
use tower::ServiceExt;

use patrimonio::config::AppConfig;
use patrimonio::AppState;

mod common;
use common::TestLockGuard;

const TEST_DB_VAR: &str = "PATRIMONIO_TEST_DATABASE_URL";

/// Build the app with the setup router mounted publicly, mirroring
/// main.rs (the endpoint is deliberately unauthenticated — the login
/// screen reads it before any session exists).
///
/// Unlike the sibling suites there is NO migrate/TRUNCATE here: the
/// endpoint reads only `AppState.config`, never the database, so wiping
/// shared tables would be pure collateral against a concurrently running
/// binary. The advisory lock is still held so this binary doesn't
/// interleave with a sibling's TRUNCATE while sharing the pool's
/// connections.
async fn try_setup(config_tweak: impl FnOnce(&mut AppConfig)) -> Option<(Router, TestLockGuard)> {
    let database_url = std::env::var(TEST_DB_VAR).ok()?;
    let lock = TestLockGuard::acquire(&database_url).await?;
    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect(&database_url)
        .await
        .expect("connect to test DB");

    let mut config = AppConfig {
        database_url: database_url.clone(),
        database_max_connections: 2,
        redis_url: "redis://127.0.0.1:6379".to_string(),
        port: 0,
        plaid_client_id: None,
        plaid_secret: None,
        plaid_env: "sandbox".to_string(),
        exchange_rate_api_key: None,
        encryption_key: Some("a".repeat(32)),
        coinbase_client_id: None,
        coinbase_client_secret: None,
        coinbase_redirect_uri: "http://localhost/api/auth/coinbase/callback".to_string(),
        frontend_base_url: "http://localhost:3000".to_string(),
        plaid_redirect_uri: None,
        plaid_android_package_name: None,
        plaid_webhook_url: None,
        allowed_origins: vec!["http://localhost:3000".to_string()],
        cookie_secure: false,
        trusted_proxy_cidrs: vec![],
        hibp_api_base: String::new(),
        android_apk_cert_sha256: vec![],
        android_package_name: "com.patrimonio.patrimonio".to_string(),
    };
    config_tweak(&mut config);

    let redis = redis::Client::open(config.redis_url.clone()).expect("redis client");
    let webauthn = Arc::new(
        patrimonio::api::passkeys::build_webauthn(
            &config.frontend_base_url,
            &config.android_apk_cert_sha256,
        )
        .expect("webauthn builder"),
    );
    let state = AppState {
        db: pool,
        redis,
        config: Arc::new(config),
        webauthn,
        realtime: patrimonio::services::realtime::Realtime::new(),
    };

    let app = Router::new()
        .nest("/api/setup", patrimonio::api::setup::router())
        .with_state(state);
    Some((app, lock))
}

fn skip_if_no_db<T>(result: Option<T>) -> Option<T> {
    if result.is_none() {
        eprintln!(
            "(skipping: set {TEST_DB_VAR}=postgres://user:pass@host/db to enable setup integration tests)"
        );
    }
    result
}

async fn body_json(body: Body) -> Value {
    let bytes = to_bytes(body, 1024 * 256).await.expect("read body");
    serde_json::from_slice(&bytes).expect("json body")
}

async fn get_status(app: &Router) -> Value {
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::GET)
                .uri("/api/setup/status")
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::OK,
        "setup status should be public and OK"
    );
    body_json(res.into_body()).await
}

/// The stable key contract the frontend's key→l10n mapping depends on.
/// If this list has to change, update setup_check_l10n.dart (and its
/// widget test) in the same commit, or es-MX falls back to English.
const EXPECTED_KEYS: [&str; 6] = [
    "plaid",
    "encryption",
    "fx",
    "coinbase",
    "plaid_webhook",
    "cors",
];

#[tokio::test]
#[serial_test::serial]
async fn setup_status_pins_stable_check_keys() {
    let Some((app, _lock)) = skip_if_no_db(try_setup(|_| {}).await) else {
        return;
    };

    let body = get_status(&app).await;
    let checks = body["checks"].as_array().expect("checks array");

    let keys: Vec<&str> = checks
        .iter()
        .map(|c| c["key"].as_str().expect("each check carries a string key"))
        .collect();
    assert_eq!(
        keys, EXPECTED_KEYS,
        "setup check keys are a frontend-localization contract — \
         renaming/reordering/removing one degrades es-MX to English labels"
    );
}

#[tokio::test]
#[serial_test::serial]
async fn setup_status_keeps_english_labels_for_backward_compat() {
    let Some((app, _lock)) = skip_if_no_db(try_setup(|_| {}).await) else {
        return;
    };

    let body = get_status(&app).await;
    assert!(
        body["ready_for_plaid_linking"].is_boolean(),
        "readiness flag present"
    );
    let checks = body["checks"].as_array().expect("checks array");
    assert_eq!(checks.len(), EXPECTED_KEYS.len());

    for check in checks {
        let key = check["key"].as_str().unwrap_or("<missing>");
        // Older frontends (and unknown-key fallback in current ones)
        // still render the server strings — they must stay non-empty.
        let label = check["label"].as_str().unwrap_or_default();
        let detail = check["detail"].as_str().unwrap_or_default();
        assert!(
            !label.is_empty(),
            "check '{key}' must keep a fallback label"
        );
        assert!(
            !detail.is_empty(),
            "check '{key}' must keep a detail string"
        );
        assert!(
            check["configured"].is_boolean(),
            "check '{key}' configured flag"
        );
        let severity = check["severity"].as_str().unwrap_or_default();
        assert!(
            matches!(
                severity,
                "required_for_linking" | "recommended" | "optional"
            ),
            "check '{key}' has unknown severity '{severity}' — the frontend \
             filters on these exact values"
        );
    }
}

#[tokio::test]
#[serial_test::serial]
async fn setup_status_reflects_configured_plaid() {
    // Keys must stay stable regardless of configuration state — the
    // frontend maps by key before it ever looks at `configured`.
    let Some((app, _lock)) = skip_if_no_db(
        try_setup(|c| {
            c.plaid_client_id = Some("client".to_string());
            c.plaid_secret = Some("secret".to_string());
        })
        .await,
    ) else {
        return;
    };

    let body = get_status(&app).await;
    let checks = body["checks"].as_array().expect("checks array");
    let plaid = checks
        .iter()
        .find(|c| c["key"] == "plaid")
        .expect("plaid check present");
    assert_eq!(plaid["configured"], true);
    assert_eq!(plaid["label"], "Plaid account linking");
}
