//! HTTP-level integration tests for the auth endpoints.
//!
//! These exercise the router exactly as `main.rs` mounts it — public
//! vs. protected splits, require_auth middleware, CORS posture — by
//! calling routes through `tower::ServiceExt::oneshot`. They need a
//! real Postgres because the services hit sqlx. The DB is selected via
//! `PATRIMONIO_TEST_DATABASE_URL`; if unset, every test in this file
//! is skipped (printed and returns Ok) so `cargo test` stays green for
//! contributors without a DB on hand.
//!
//! Schema is reset between tests using TRUNCATE. The tests share a
//! single Postgres so they MUST run serially — invoke with
//! `cargo test -- --test-threads=1`. Parallel execution leads to one
//! test's TRUNCATE wiping another's data mid-flight and surfaces as
//! random 500s on bootstrap.
//!
//! Easiest invocation from the repo root:  `./scripts/test.sh`

use std::sync::Arc;

use axum::body::{to_bytes, Body};
use axum::http::{header, HeaderValue, Method, Request, StatusCode};
use axum::middleware::from_fn_with_state;
use axum::Router;
use serde_json::Value;
use sqlx::postgres::PgPoolOptions;
use sqlx::PgPool;
use tower::ServiceExt;

use patrimonio::config::AppConfig;
use patrimonio::AppState;

const TEST_DB_VAR: &str = "PATRIMONIO_TEST_DATABASE_URL";
const SESSION_COOKIE: &str = "patrimonio_session";

async fn try_setup() -> Option<(Router, PgPool)> {
    let database_url = std::env::var(TEST_DB_VAR).ok()?;
    let pool = PgPoolOptions::new()
        .max_connections(2)
        .connect(&database_url)
        .await
        .expect("connect to test DB");

    sqlx::migrate!("./migrations")
        .run(&pool)
        .await
        .expect("apply migrations to test DB");

    // Clean slate. Truncate everything the auth flow touches and a few
    // related tables so we don't leave smoke residue.
    sqlx::query("TRUNCATE auth_audit, user_sessions, users RESTART IDENTITY CASCADE")
        .execute(&pool)
        .await
        .expect("truncate auth tables");

    let config = AppConfig {
        database_url: database_url.clone(),
        database_max_connections: 2,
        redis_url: "redis://127.0.0.1:6379".to_string(),
        port: 0,
        plaid_client_id: None,
        plaid_secret: None,
        plaid_env: "sandbox".to_string(),
        exchange_rate_api_key: None,
        encryption_key: None,
        coinbase_client_id: None,
        coinbase_client_secret: None,
        coinbase_redirect_uri: "http://localhost/api/auth/coinbase/callback".to_string(),
        frontend_base_url: "http://localhost:3000".to_string(),
        plaid_redirect_uri: None,
        plaid_webhook_url: None,
        trusted_proxy_cidrs: vec![],
        allowed_origins: vec!["http://localhost:3000".to_string()],
        cookie_secure: false,
        // Empty disables the HIBP network call entirely so the
        // test suite stays offline.
        hibp_api_base: String::new(),
    };

    let redis = redis::Client::open(config.redis_url.clone()).expect("redis client");
    let webauthn = std::sync::Arc::new(
        patrimonio::api::passkeys::build_webauthn(&config.frontend_base_url)
            .expect("webauthn builder"),
    );
    let state = AppState {
        db: pool.clone(),
        redis,
        config: Arc::new(config),
        webauthn,
        realtime: patrimonio::services::realtime::Realtime::new(),
    };

    // Mirror the public/protected split from main.rs so the middleware
    // posture matches production exactly.
    let public = Router::new()
        .nest("/api/auth", patrimonio::api::session::public_router());

    let protected = Router::new()
        .nest("/api/auth", patrimonio::api::session::protected_router())
        .layer(from_fn_with_state(
            state.clone(),
            patrimonio::api::session::require_auth,
        ));

    let app = public.merge(protected).with_state(state);

    Some((app, pool))
}

fn skip_if_no_db<T>(result: Option<T>) -> Option<T> {
    if result.is_none() {
        eprintln!(
            "(skipping: set {TEST_DB_VAR}=postgres://user:pass@host/db to enable auth integration tests)"
        );
    }
    result
}

async fn body_json(body: Body) -> Value {
    let bytes = to_bytes(body, 1024 * 64).await.expect("read body");
    serde_json::from_slice(&bytes).expect("json body")
}

fn set_cookie_value(headers: &axum::http::HeaderMap) -> Option<String> {
    for cookie in headers.get_all(header::SET_COOKIE).iter() {
        let raw = cookie.to_str().ok()?;
        let pair = raw.split(';').next()?.trim();
        if let Some(rest) = pair.strip_prefix(&format!("{SESSION_COOKIE}=")) {
            return Some(rest.to_string());
        }
    }
    None
}

fn cookie_header(token: &str) -> HeaderValue {
    HeaderValue::from_str(&format!("{SESSION_COOKIE}={token}"))
        .expect("valid cookie header")
}

fn json_request(method: Method, uri: &str, body: &Value, cookie: Option<&str>) -> Request<Body> {
    let mut req = Request::builder()
        .method(method)
        .uri(uri)
        .header(header::CONTENT_TYPE, "application/json");
    if let Some(token) = cookie {
        req = req.header(header::COOKIE, cookie_header(token));
    }
    req.body(Body::from(serde_json::to_vec(body).unwrap()))
        .unwrap()
}

fn get_request(uri: &str, cookie: Option<&str>) -> Request<Body> {
    let mut req = Request::builder().method(Method::GET).uri(uri);
    if let Some(token) = cookie {
        req = req.header(header::COOKIE, cookie_header(token));
    }
    req.body(Body::empty()).unwrap()
}

#[tokio::test]
async fn full_auth_lifecycle() {
    let Some((app, pool)) = skip_if_no_db(try_setup().await) else { return };

    // Fresh DB reports needs_bootstrap.
    let res = app
        .clone()
        .oneshot(get_request("/api/auth/status", None))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["needs_bootstrap"], true);
    assert_eq!(body["authenticated"], false);

    // /me without cookie is 401 (middleware short-circuit).
    let res = app
        .clone()
        .oneshot(get_request("/api/auth/me", None))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

    // Short password rejected.
    let res = app
        .clone()
        .oneshot(json_request(
            Method::POST,
            "/api/auth/bootstrap",
            &serde_json::json!({"username": "owner", "password": "tooshort"}),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::BAD_REQUEST);

    // Successful bootstrap returns the user and sets a session cookie.
    let res = app
        .clone()
        .oneshot(json_request(
            Method::POST,
            "/api/auth/bootstrap",
            &serde_json::json!({
                "username": "owner",
                "email": "owner@example.com",
                "password": "correcthorsebatterystaple"
            }),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let token = set_cookie_value(res.headers()).expect("cookie should be set on bootstrap");

    // Second bootstrap is refused.
    let res = app
        .clone()
        .oneshot(json_request(
            Method::POST,
            "/api/auth/bootstrap",
            &serde_json::json!({"username": "other", "password": "correcthorsebatterystaple"}),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::CONFLICT);

    // /me with cookie returns the user.
    let res = app
        .clone()
        .oneshot(get_request("/api/auth/me", Some(&token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let me = body_json(res.into_body()).await;
    assert_eq!(me["username"], "owner");
    assert_eq!(me["totp_enabled"], false);

    // Logout revokes the cookie and emits a Set-Cookie that the
    // browser will actually honor (must repeat Path=/ from the live
    // cookie, otherwise the browser keeps the old one).
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/auth/logout")
                .header(header::COOKIE, cookie_header(&token))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);
    let removal = res
        .headers()
        .get_all(header::SET_COOKIE)
        .iter()
        .filter_map(|h| h.to_str().ok())
        .find(|s| s.starts_with(&format!("{SESSION_COOKIE}=")))
        .expect("logout must emit a Set-Cookie for the session");
    assert!(
        removal.contains("Path=/"),
        "removal Set-Cookie missing Path=/, got: {removal}"
    );

    let res = app
        .clone()
        .oneshot(get_request("/api/auth/me", Some(&token)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

    // Wrong password is rejected.
    let res = app
        .clone()
        .oneshot(json_request(
            Method::POST,
            "/api/auth/login",
            &serde_json::json!({"username": "owner", "password": "wrong-password-attempt"}),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

    // Right password issues a brand new session cookie.
    let res = app
        .clone()
        .oneshot(json_request(
            Method::POST,
            "/api/auth/login",
            &serde_json::json!({"username": "OWNER", "password": "correcthorsebatterystaple"}),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let token2 = set_cookie_value(res.headers()).expect("login cookie");
    assert_ne!(token, token2, "session token must rotate on login");

    // change-password rotates and revokes other sessions.
    let res = app
        .clone()
        .oneshot(json_request(
            Method::POST,
            "/api/auth/change-password",
            &serde_json::json!({
                "current_password": "correcthorsebatterystaple",
                "new_password": "newpassphraselonger"
            }),
            Some(&token2),
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);

    // The old session is no longer accepted.
    let res = app
        .clone()
        .oneshot(get_request("/api/auth/me", Some(&token2)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

    // New password works; old does not.
    let res = app
        .clone()
        .oneshot(json_request(
            Method::POST,
            "/api/auth/login",
            &serde_json::json!({"username": "owner", "password": "correcthorsebatterystaple"}),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

    let res = app
        .clone()
        .oneshot(json_request(
            Method::POST,
            "/api/auth/login",
            &serde_json::json!({"username": "owner", "password": "newpassphraselonger"}),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    // Audit log has bootstrap, login successes, login failure,
    // change_password — at least one of each.
    let counts: Vec<(String, i64)> = sqlx::query_as(
        "SELECT event::TEXT, COUNT(*)::BIGINT FROM auth_audit GROUP BY event ORDER BY event",
    )
    .fetch_all(&pool)
    .await
    .expect("audit count");
    let counts_map: std::collections::HashMap<_, _> = counts.into_iter().collect();
    assert!(counts_map.get("bootstrap").copied().unwrap_or(0) >= 1);
    assert!(counts_map.get("login").copied().unwrap_or(0) >= 3);
    assert!(counts_map.get("change_password").copied().unwrap_or(0) >= 1);
}

#[tokio::test]
async fn session_management_endpoints() {
    let Some((app, _pool)) = skip_if_no_db(try_setup().await) else { return };

    // Bootstrap to create the first session.
    let res = app
        .clone()
        .oneshot(json_request(
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
    let _token_a = set_cookie_value(res.headers()).expect("bootstrap cookie");

    // Log in twice more from different "browsers" — same user, two
    // additional sessions. Each login revokes the previous cookie if
    // the same cookie is presented, so we deliberately don't re-send
    // token_a here.
    let res = app
        .clone()
        .oneshot(json_request(
            Method::POST,
            "/api/auth/login",
            &serde_json::json!({"username": "owner", "password": "correcthorsebatterystaple"}),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let token_b = set_cookie_value(res.headers()).expect("login B cookie");

    let res = app
        .clone()
        .oneshot(json_request(
            Method::POST,
            "/api/auth/login",
            &serde_json::json!({"username": "owner", "password": "correcthorsebatterystaple"}),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let token_c = set_cookie_value(res.headers()).expect("login C cookie");

    // GET /api/auth/sessions from token_b — should return all three
    // sessions, with exactly one flagged as is_current.
    let res = app
        .clone()
        .oneshot(get_request("/api/auth/sessions", Some(&token_b)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    let arr = body.as_array().expect("array");
    assert_eq!(arr.len(), 3, "expected 3 active sessions, got {}", arr.len());
    let current_count = arr
        .iter()
        .filter(|s| s["is_current"].as_bool() == Some(true))
        .count();
    assert_eq!(current_count, 1, "exactly one session must be is_current");
    // Confirm shape: each row has id, created_at, last_seen_at,
    // expires_at, is_current.
    for s in arr {
        assert!(s["id"].is_string());
        assert!(s["created_at"].is_string());
        assert!(s["last_seen_at"].is_string());
        assert!(s["expires_at"].is_string());
        assert!(s["is_current"].is_boolean());
    }

    // Find the session ID owned by token_a (NOT the current one for
    // token_b's view). We can identify it as the only non-current
    // session whose ID is in the list — pick the first non-current.
    let target_session_id = arr
        .iter()
        .find(|s| s["is_current"].as_bool() == Some(false))
        .and_then(|s| s["id"].as_str())
        .expect("at least one non-current session")
        .to_string();

    // Revoke that single session via DELETE /api/auth/sessions/{id}.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::DELETE)
                .uri(format!("/api/auth/sessions/{target_session_id}"))
                .header(header::COOKIE, cookie_header(&token_b))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::NO_CONTENT);

    // The session list now has 2 rows; the revoked id is gone.
    let res = app
        .clone()
        .oneshot(get_request("/api/auth/sessions", Some(&token_b)))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let arr = body.as_array().expect("array");
    assert_eq!(arr.len(), 2);
    assert!(arr.iter().all(|s| s["id"].as_str() != Some(&target_session_id)));

    // Refusing to revoke the current session — even via DELETE — is a
    // 400 so the user has to use /logout instead. (Identify the
    // current session from the list.)
    let res = app
        .clone()
        .oneshot(get_request("/api/auth/sessions", Some(&token_b)))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    let current_id = body
        .as_array()
        .unwrap()
        .iter()
        .find(|s| s["is_current"].as_bool() == Some(true))
        .and_then(|s| s["id"].as_str())
        .expect("current session in list")
        .to_string();

    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::DELETE)
                .uri(format!("/api/auth/sessions/{current_id}"))
                .header(header::COOKIE, cookie_header(&token_b))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(
        res.status(),
        StatusCode::BAD_REQUEST,
        "revoking your own session must require POST /logout"
    );

    // POST /api/auth/sessions/revoke-others from token_b: should
    // revoke token_c, leave token_b alive, and return revoked=1.
    let res = app
        .clone()
        .oneshot(
            Request::builder()
                .method(Method::POST)
                .uri("/api/auth/sessions/revoke-others")
                .header(header::COOKIE, cookie_header(&token_b))
                .body(Body::empty())
                .unwrap(),
        )
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);
    let body = body_json(res.into_body()).await;
    assert_eq!(body["revoked"], 1);

    // token_b still works
    let res = app
        .clone()
        .oneshot(get_request("/api/auth/me", Some(&token_b)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    // token_c no longer works
    let res = app
        .clone()
        .oneshot(get_request("/api/auth/me", Some(&token_c)))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::UNAUTHORIZED);

    // Sessions list now reports exactly 1 entry (the current one).
    let res = app
        .clone()
        .oneshot(get_request("/api/auth/sessions", Some(&token_b)))
        .await
        .unwrap();
    let body = body_json(res.into_body()).await;
    assert_eq!(body.as_array().unwrap().len(), 1);
}

#[tokio::test]
async fn rate_limit_kicks_in_after_repeated_failures() {
    let Some((app, _pool)) = skip_if_no_db(try_setup().await) else { return };

    // Bootstrap a user so the username exists (the limiter keys off
    // failures for that username).
    let res = app
        .clone()
        .oneshot(json_request(
            Method::POST,
            "/api/auth/bootstrap",
            &serde_json::json!({"username": "rl", "password": "correcthorsebatterystaple"}),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::OK);

    // Fire five wrong-password attempts; the sixth should be rate
    // limited. Threshold is 5, so once five failures are in the audit
    // log, the next attempt short-circuits with 429.
    for _ in 0..5 {
        let res = app
            .clone()
            .oneshot(json_request(
                Method::POST,
                "/api/auth/login",
                &serde_json::json!({"username": "rl", "password": "wrong-password-here"}),
                None,
            ))
            .await
            .unwrap();
        assert_eq!(res.status(), StatusCode::UNAUTHORIZED);
    }

    let res = app
        .clone()
        .oneshot(json_request(
            Method::POST,
            "/api/auth/login",
            &serde_json::json!({"username": "rl", "password": "wrong-password-here"}),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::TOO_MANY_REQUESTS);

    // Even a correct password is rejected while rate-limited.
    let res = app
        .clone()
        .oneshot(json_request(
            Method::POST,
            "/api/auth/login",
            &serde_json::json!({"username": "rl", "password": "correcthorsebatterystaple"}),
            None,
        ))
        .await
        .unwrap();
    assert_eq!(res.status(), StatusCode::TOO_MANY_REQUESTS);
}
