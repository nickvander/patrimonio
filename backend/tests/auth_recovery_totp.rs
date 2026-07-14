//! Integration tests for the recovery-codes and TOTP flows.
//! Layout mirrors `auth_endpoints.rs` — same DB selection via
//! `PATRIMONIO_TEST_DATABASE_URL`, same router-wiring helper. Skipped
//! cleanly when no test DB is available.

use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{header, HeaderValue, Method, Request, StatusCode};
use axum::middleware::from_fn_with_state;
use axum::Router;
use rand::Rng;
use serde_json::Value;
use sqlx::postgres::PgPoolOptions;
use tower::ServiceExt;

use patrimonio::config::AppConfig;
use patrimonio::AppState;

mod common;
use common::TestLockGuard;

const TEST_DB_VAR: &str = "PATRIMONIO_TEST_DATABASE_URL";
const SESSION_COOKIE: &str = "patrimonio_session";

async fn try_setup() -> Option<(Router, TestLockGuard)> {
    let database_url = std::env::var(TEST_DB_VAR).ok()?;
    // Cross-binary serialisation against the shared test DB. See
    // tests/common/mod.rs for the rationale.
    let lock = TestLockGuard::acquire(&database_url).await?;
    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect(&database_url)
        .await
        .expect("connect test DB");

    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .expect("apply migrations");

    sqlx::query("TRUNCATE auth_audit, user_sessions, users, recovery_codes RESTART IDENTITY CASCADE")
        .execute(&pool)
        .await
        .expect("truncate");

    // TOTP requires ENCRYPTION_KEY. Synthesise a random 32-byte hex
    // for the test run so encrypt/decrypt actually works.
    let mut key_bytes = [0u8; 32];
    rand::thread_rng().fill(&mut key_bytes);
    let enc_hex = hex::encode(key_bytes);

    let config = AppConfig {
        database_url: database_url.clone(),
        database_max_connections: 2,
        redis_url: "redis://127.0.0.1:6379".to_string(),
        port: 0,
        plaid_client_id: None,
        plaid_secret: None,
        plaid_env: "sandbox".to_string(),
        exchange_rate_api_key: None,
        encryption_key: Some(enc_hex),
        coinbase_client_id: None,
        coinbase_client_secret: None,
        coinbase_redirect_uri: "http://localhost/api/auth/coinbase/callback".to_string(),
        frontend_base_url: "http://localhost:3000".to_string(),
        plaid_redirect_uri: None,
        plaid_android_package_name: None,
        plaid_webhook_url: None,
        trusted_proxy_cidrs: vec![],
        allowed_origins: vec!["http://localhost:3000".to_string()],
        cookie_secure: false,
        hibp_api_base: String::new(),
        android_apk_cert_sha256: vec![],
        android_package_name: "com.patrimonio.patrimonio".to_string(),
    };

    let redis = redis::Client::open(config.redis_url.clone()).expect("redis");
    let webauthn = std::sync::Arc::new(
        patrimonio::api::passkeys::build_webauthn(&config.frontend_base_url, &config.android_apk_cert_sha256)
            .expect("webauthn builder"),
    );
    let state = AppState {
        db: pool.clone(),
        redis,
        config: Arc::new(config),
        webauthn,
        realtime: patrimonio::services::realtime::Realtime::new(),
    };

    let public = Router::new()
        .nest("/api/auth", patrimonio::api::session::public_router());
    let protected = Router::new()
        .nest("/api/auth", patrimonio::api::session::protected_router())
        .layer(from_fn_with_state(
            state.clone(),
            patrimonio::api::session::require_auth,
        ));
    Some((public.merge(protected).with_state(state), lock))
}

fn skip_if_no_db<T>(r: Option<T>) -> Option<T> {
    if r.is_none() {
        eprintln!(
            "(skipping: set {TEST_DB_VAR}=postgres://user:pass@host/db to enable these tests)"
        );
    }
    r
}

async fn body_json(b: Body) -> Value {
    let bytes = to_bytes(b, 1024 * 64).await.expect("body");
    serde_json::from_slice(&bytes).expect("json")
}

fn cookie_header(token: &str) -> HeaderValue {
    HeaderValue::from_str(&format!("{SESSION_COOKIE}={token}")).unwrap()
}

fn set_cookie_value(headers: &axum::http::HeaderMap) -> Option<String> {
    for c in headers.get_all(header::SET_COOKIE).iter() {
        let raw = c.to_str().ok()?;
        let pair = raw.split(';').next()?.trim();
        if let Some(rest) = pair.strip_prefix(&format!("{SESSION_COOKIE}=")) {
            // Empty value = removal directive.
            if !rest.is_empty() {
                return Some(rest.to_string());
            }
        }
    }
    None
}

fn json_req(method: Method, uri: &str, body: &Value, cookie: Option<&str>) -> Request<Body> {
    let mut b = Request::builder()
        .method(method)
        .uri(uri)
        .header(header::CONTENT_TYPE, "application/json");
    if let Some(t) = cookie {
        b = b.header(header::COOKIE, cookie_header(t));
    }
    b.body(Body::from(serde_json::to_vec(body).unwrap())).unwrap()
}

fn get_req(uri: &str, cookie: Option<&str>) -> Request<Body> {
    let mut b = Request::builder().method(Method::GET).uri(uri);
    if let Some(t) = cookie {
        b = b.header(header::COOKIE, cookie_header(t));
    }
    b.body(Body::empty()).unwrap()
}

async fn bootstrap_and_login(app: &Router) -> (String, Vec<String>) {
    let res = app
        .clone()
        .oneshot(json_req(
            Method::POST,
            "/api/auth/bootstrap",
            &serde_json::json!({
                "username": "owner",
                "password": "correcthorsebatterystaple"
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let token = set_cookie_value(res.headers()).expect("bootstrap cookie");
    let body = body_json(res.into_body()).await;
    let codes: Vec<String> = body["recovery_codes"]
        .as_array()
        .expect("codes array")
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    assert_eq!(codes.len(), 8, "bootstrap should hand back exactly 8 codes");
    (token, codes)
}

// ---------- recovery codes ----------

#[tokio::test]
#[serial_test::serial]
async fn recovery_code_redeems_and_resets_password() {
    let Some((app, _lock)) = skip_if_no_db(try_setup().await) else { return };
    let (_token, codes) = bootstrap_and_login(&app).await;

    // Wrong username + right code → 401.
    let res = app
        .clone()
        .oneshot(json_req(
            Method::POST,
            "/api/auth/recover",
            &serde_json::json!({
                "username": "wrong-user",
                "code": codes[0],
                "new_password": "another-strong-pass-1"
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

    // Right username + wrong code → 401.
    let res = app
        .clone()
        .oneshot(json_req(
            Method::POST,
            "/api/auth/recover",
            &serde_json::json!({
                "username": "owner",
                "code": "ZZZZ-ZZZZ-ZZZZ",
                "new_password": "another-strong-pass-1"
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

    // Right username + right code → 204 and the password is reset.
    let res = app
        .clone()
        .oneshot(json_req(
            Method::POST,
            "/api/auth/recover",
            &serde_json::json!({
                "username": "owner",
                "code": codes[0],
                "new_password": "another-strong-pass-1"
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);

    // Old password no longer works.
    let res = app
        .clone()
        .oneshot(json_req(
            Method::POST,
            "/api/auth/login",
            &serde_json::json!({"username": "owner", "password": "correcthorsebatterystaple"}),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

    // New password works.
    let res = app
        .clone()
        .oneshot(json_req(
            Method::POST,
            "/api/auth/login",
            &serde_json::json!({"username": "owner", "password": "another-strong-pass-1"}),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    // The redeemed code cannot be reused.
    let res = app
        .clone()
        .oneshot(json_req(
            Method::POST,
            "/api/auth/recover",
            &serde_json::json!({
                "username": "owner",
                "code": codes[0],
                "new_password": "third-pass-not-allowed-12345"
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
#[serial_test::serial]
async fn regenerate_invalidates_old_codes() {
    let Some((app, _lock)) = skip_if_no_db(try_setup().await) else { return };
    let (token, original_codes) = bootstrap_and_login(&app).await;

    // Regenerate via the authenticated endpoint.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/auth/recovery-codes/regenerate")
                .header(header::COOKIE, cookie_header(&token))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let new_codes: Vec<String> = body["codes"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_string())
        .collect();
    assert_eq!(new_codes.len(), 8);
    assert!(
        new_codes.iter().all(|c| !original_codes.contains(c)),
        "regenerated set should not overlap with originals"
    );

    // Any original code now fails — the unused set was replaced.
    let res = app
        .clone()
        .oneshot(json_req(
            Method::POST,
            "/api/auth/recover",
            &serde_json::json!({
                "username": "owner",
                "code": original_codes[3],
                "new_password": "should-not-work-because-regenerated"
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

    // A new code does work.
    let res = app
        .clone()
        .oneshot(json_req(
            Method::POST,
            "/api/auth/recover",
            &serde_json::json!({
                "username": "owner",
                "code": new_codes[0],
                "new_password": "after-regenerate-pass-works"
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
}

// ---------- TOTP ----------

/// Helper: read the current TOTP code for a known secret. We do this
/// in tests instead of relying on a fixed code so the test doesn't
/// depend on system time.
fn current_totp_for(secret_b32: &str) -> String {
    use totp_rs::{Algorithm, Secret, TOTP};
    let bytes = Secret::Encoded(secret_b32.to_string()).to_bytes().unwrap();
    let totp = TOTP::new(
        Algorithm::SHA1,
        6,
        1,
        30,
        bytes,
        Some("Patrimonio".to_string()),
        "owner".to_string(),
    )
    .unwrap();
    totp.generate_current().unwrap()
}

#[tokio::test]
#[serial_test::serial]
async fn totp_enroll_confirm_then_login_requires_two_steps() {
    let Some((app, _lock)) = skip_if_no_db(try_setup().await) else { return };
    let (token, _codes) = bootstrap_and_login(&app).await;

    // Start enrollment — get secret + provisioning URI.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/auth/totp/enroll")
                .header(header::COOKIE, cookie_header(&token))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let secret = body["secret_base32"].as_str().unwrap().to_string();
    assert!(
        body["provisioning_uri"]
            .as_str()
            .unwrap()
            .starts_with("otpauth://totp/Patrimonio:owner"),
        "URI must start with otpauth://totp/<issuer>:<account>"
    );

    // Wrong code refused.
    let res = app
        .clone()
        .oneshot(json_req(
            Method::POST,
            "/api/auth/totp/confirm",
            &serde_json::json!({"code": "000000"}),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

    // Right code flips totp_enabled.
    let code = current_totp_for(&secret);
    let res = app
        .clone()
        .oneshot(json_req(
            Method::POST,
            "/api/auth/totp/confirm",
            &serde_json::json!({"code": code}),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);

    // /me reports totp_enabled true.
    let res = app
        .clone()
        .oneshot(get_req("/api/auth/me", Some(&token)))
        .await
        .unwrap();
    let me = body_json(res.into_body()).await;
    assert_eq!(me["totp_enabled"], true);

    // Fresh login: password alone now returns requires_totp.
    let res = app
        .clone()
        .oneshot(json_req(
            Method::POST,
            "/api/auth/login",
            &serde_json::json!({
                "username": "owner",
                "password": "correcthorsebatterystaple"
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let pending_token = set_cookie_value(res.headers()).expect("pending cookie");
    let body = body_json(res.into_body()).await;
    assert_eq!(body["requires_totp"], true, "login must signal TOTP needed");

    // Pending session is refused everywhere except /totp/verify.
    let res = app
        .clone()
        .oneshot(get_req("/api/auth/me", Some(&pending_token)))
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::UNAUTHORIZED,
        "pending-TOTP session must not reach /me"
    );

    // Wrong TOTP code on verify → 401.
    let res = app
        .clone()
        .oneshot(json_req(
            Method::POST,
            "/api/auth/totp/verify",
            &serde_json::json!({"code": "000000"}),
            Some(&pending_token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

    // Right code: pending session is consumed, full session minted.
    let code = current_totp_for(&secret);
    let res = app
        .clone()
        .oneshot(json_req(
            Method::POST,
            "/api/auth/totp/verify",
            &serde_json::json!({"code": code}),
            Some(&pending_token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let full_token = set_cookie_value(res.headers()).expect("full cookie");
    assert_ne!(full_token, pending_token);

    // Full session reaches /me.
    let res = app
        .clone()
        .oneshot(get_req("/api/auth/me", Some(&full_token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    // The old pending cookie is dead.
    let res = app
        .clone()
        .oneshot(get_req("/api/auth/me", Some(&pending_token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
}

#[tokio::test]
#[serial_test::serial]
async fn totp_disable_requires_password() {
    let Some((app, _lock)) = skip_if_no_db(try_setup().await) else { return };
    let (token, _codes) = bootstrap_and_login(&app).await;

    // Enroll + confirm so totp_enabled is true.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/auth/totp/enroll")
                .header(header::COOKIE, cookie_header(&token))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    let secret = body_json(res.into_body()).await["secret_base32"]
        .as_str()
        .unwrap()
        .to_string();
    let code = current_totp_for(&secret);
    let res = app
        .clone()
        .oneshot(json_req(
            Method::POST,
            "/api/auth/totp/confirm",
            &serde_json::json!({"code": code}),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);

    // Wrong password → 401.
    let res = app
        .clone()
        .oneshot(json_req(
            Method::POST,
            "/api/auth/totp/disable",
            &serde_json::json!({"current_password": "not-the-password"}),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

    // Right password → 204, and /me reports totp_enabled false.
    let res = app
        .clone()
        .oneshot(json_req(
            Method::POST,
            "/api/auth/totp/disable",
            &serde_json::json!({"current_password": "correcthorsebatterystaple"}),
            Some(&token),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    let res = app
        .clone()
        .oneshot(get_req("/api/auth/me", Some(&token)))
        .await
        .unwrap();
    let me = body_json(res.into_body()).await;
    assert_eq!(me["totp_enabled"], false);
}
