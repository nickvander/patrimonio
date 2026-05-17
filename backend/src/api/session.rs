use axum::{
    extract::{Extension, State},
    http::{HeaderMap, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
    routing::{get, post},
    Json, Router,
};
use axum_extra::extract::cookie::{Cookie, CookieJar, SameSite};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use time::Duration as CookieDuration;
use uuid::Uuid;

use crate::services::{password, sessions};
use crate::AppState;

/// Failed login back-off window and per-key threshold. Conservative
/// defaults that are still usable on a typo-fest.
const FAILED_ATTEMPT_WINDOW_SECONDS: i64 = 60;
const FAILED_ATTEMPT_THRESHOLD: i64 = 5;

/// Endpoints reachable without a session cookie. The login screen
/// needs these to render before the user has authenticated.
pub fn public_router() -> Router<AppState> {
    Router::new()
        .route("/login", post(login))
        .route("/bootstrap", post(bootstrap))
        .route("/status", get(status))
}

/// Endpoints that require a valid session cookie. Mount these under
/// the auth middleware so `AuthContext` is populated.
pub fn protected_router() -> Router<AppState> {
    Router::new()
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/change-password", post(change_password))
}

// ----- request / response types -----

#[derive(Deserialize)]
pub struct LoginRequest {
    pub username: String,
    pub password: String,
}

#[derive(Serialize)]
pub struct UserView {
    pub id: Uuid,
    pub username: String,
    pub email: Option<String>,
    pub created_at: DateTime<Utc>,
    pub last_login_at: Option<DateTime<Utc>>,
    pub totp_enabled: bool,
}

#[derive(Serialize)]
pub struct StatusResponse {
    pub needs_bootstrap: bool,
    pub authenticated: bool,
    pub user: Option<UserView>,
}

#[derive(Deserialize)]
pub struct BootstrapRequest {
    pub username: String,
    pub email: Option<String>,
    pub password: String,
}

#[derive(Deserialize)]
pub struct ChangePasswordRequest {
    pub current_password: String,
    pub new_password: String,
}

// ----- handlers -----

async fn status(State(state): State<AppState>, jar: CookieJar) -> Json<StatusResponse> {
    let total = user_count(&state.db).await.unwrap_or(0);
    if total == 0 {
        return Json(StatusResponse {
            needs_bootstrap: true,
            authenticated: false,
            user: None,
        });
    }

    let user = match jar.get(sessions::COOKIE_NAME) {
        Some(cookie) => match sessions::validate_and_touch(&state.db, cookie.value()).await {
            Ok(Some(s)) => load_user_view(&state.db, s.user_id).await.ok(),
            _ => None,
        },
        None => None,
    };

    Json(StatusResponse {
        needs_bootstrap: false,
        authenticated: user.is_some(),
        user,
    })
}

async fn bootstrap(
    State(state): State<AppState>,
    jar: CookieJar,
    headers: HeaderMap,
    Json(body): Json<BootstrapRequest>,
) -> Result<(CookieJar, Json<UserView>), ApiError> {
    let existing = user_count(&state.db).await.map_err(internal)?;
    if existing > 0 {
        return Err(ApiError::new(
            StatusCode::CONFLICT,
            "Bootstrap already complete. Use /api/auth/login.",
        ));
    }

    let username = body.username.trim().to_string();
    if username.is_empty() || username.len() > 64 {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "Username must be 1-64 characters.",
        ));
    }
    let email = body
        .email
        .as_ref()
        .map(|e| e.trim().to_string())
        .filter(|e| !e.is_empty());

    password::validate_password_policy(&body.password)
        .map_err(|e| ApiError::new(StatusCode::BAD_REQUEST, &e.to_string()))?;

    let hash = password::hash_password(&body.password).map_err(internal)?;

    let user_id: Uuid = sqlx::query_scalar(
        r#"
        INSERT INTO users (username, email, password_hash, last_login_at)
        VALUES ($1, $2, $3, NOW())
        RETURNING id
        "#,
    )
    .bind(&username)
    .bind(email.as_deref())
    .bind(&hash)
    .fetch_one(&state.db)
    .await
    .map_err(internal)?;

    let ua = user_agent(&headers);
    let ip = client_ip(&headers);
    record_audit(
        &state.db,
        "bootstrap",
        Some(&username),
        Some(user_id),
        ip.as_deref(),
        ua.as_deref(),
        true,
        None,
    )
    .await;

    let session = sessions::create_session(&state.db, user_id, ua.as_deref(), ip.as_deref())
        .await
        .map_err(internal)?;

    let jar = jar.add(build_session_cookie(&state, session.token, session.expires_at));
    let user = load_user_view(&state.db, user_id).await.map_err(internal)?;
    Ok((jar, Json(user)))
}

async fn login(
    State(state): State<AppState>,
    jar: CookieJar,
    headers: HeaderMap,
    Json(body): Json<LoginRequest>,
) -> Result<(CookieJar, Json<UserView>), ApiError> {
    let username = body.username.trim().to_string();
    let ua = user_agent(&headers);
    let ip = client_ip(&headers);

    if username.is_empty() || body.password.is_empty() {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "Username and password are required.",
        ));
    }

    if rate_limited(&state.db, &username, ip.as_deref()).await {
        record_audit(
            &state.db,
            "login",
            Some(&username),
            None,
            ip.as_deref(),
            ua.as_deref(),
            false,
            Some("rate_limited"),
        )
        .await;
        return Err(ApiError::new(
            StatusCode::TOO_MANY_REQUESTS,
            "Too many failed attempts. Try again shortly.",
        ));
    }

    let row: Option<(Uuid, String, bool)> = sqlx::query_as(
        "SELECT id, password_hash, is_active FROM users WHERE LOWER(username) = LOWER($1)",
    )
    .bind(&username)
    .fetch_optional(&state.db)
    .await
    .map_err(internal)?;

    let Some((user_id, hash, is_active)) = row else {
        record_audit(
            &state.db,
            "login",
            Some(&username),
            None,
            ip.as_deref(),
            ua.as_deref(),
            false,
            Some("unknown_user"),
        )
        .await;
        return Err(invalid_credentials());
    };
    if !is_active {
        record_audit(
            &state.db,
            "login",
            Some(&username),
            Some(user_id),
            ip.as_deref(),
            ua.as_deref(),
            false,
            Some("inactive"),
        )
        .await;
        return Err(invalid_credentials());
    }
    let ok = password::verify_password(&body.password, &hash).map_err(internal)?;
    if !ok {
        record_audit(
            &state.db,
            "login",
            Some(&username),
            Some(user_id),
            ip.as_deref(),
            ua.as_deref(),
            false,
            Some("bad_password"),
        )
        .await;
        return Err(invalid_credentials());
    }

    // Defence-in-depth against session fixation: if the browser still
    // carries a stale session token, revoke it before issuing a new one.
    if let Some(existing) = jar.get(sessions::COOKIE_NAME) {
        let _ = sessions::revoke_by_token(&state.db, existing.value()).await;
    }

    let session = sessions::create_session(&state.db, user_id, ua.as_deref(), ip.as_deref())
        .await
        .map_err(internal)?;

    let _ = sqlx::query("UPDATE users SET last_login_at = NOW() WHERE id = $1")
        .bind(user_id)
        .execute(&state.db)
        .await;

    record_audit(
        &state.db,
        "login",
        Some(&username),
        Some(user_id),
        ip.as_deref(),
        ua.as_deref(),
        true,
        None,
    )
    .await;

    let jar = jar.add(build_session_cookie(&state, session.token, session.expires_at));
    let user = load_user_view(&state.db, user_id).await.map_err(internal)?;
    Ok((jar, Json(user)))
}

async fn logout(
    State(state): State<AppState>,
    jar: CookieJar,
) -> Result<(CookieJar, StatusCode), ApiError> {
    if let Some(cookie) = jar.get(sessions::COOKIE_NAME) {
        let _ = sessions::revoke_by_token(&state.db, cookie.value()).await;
    }
    // The removal cookie's path must match the live cookie's path
    // exactly, or the browser keeps the old one. Without this the
    // server-side session is revoked (so further requests fail auth)
    // but the dead cookie stays in the browser store.
    let mut removal = Cookie::from(sessions::COOKIE_NAME);
    removal.set_path("/");
    let jar = jar.remove(removal);
    Ok((jar, StatusCode::NO_CONTENT))
}

async fn me(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Result<Json<UserView>, ApiError> {
    let user = load_user_view(&state.db, ctx.user_id).await.map_err(internal)?;
    Ok(Json(user))
}

async fn change_password(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    headers: HeaderMap,
    Json(body): Json<ChangePasswordRequest>,
) -> Result<StatusCode, ApiError> {
    password::validate_password_policy(&body.new_password)
        .map_err(|e| ApiError::new(StatusCode::BAD_REQUEST, &e.to_string()))?;

    let hash: String = sqlx::query_scalar("SELECT password_hash FROM users WHERE id = $1")
        .bind(ctx.user_id)
        .fetch_one(&state.db)
        .await
        .map_err(internal)?;

    let ok = password::verify_password(&body.current_password, &hash).map_err(internal)?;
    if !ok {
        return Err(invalid_credentials());
    }

    let new_hash = password::hash_password(&body.new_password).map_err(internal)?;
    sqlx::query("UPDATE users SET password_hash = $1 WHERE id = $2")
        .bind(&new_hash)
        .bind(ctx.user_id)
        .execute(&state.db)
        .await
        .map_err(internal)?;

    // Force re-login everywhere after a password change.
    let _ = sessions::revoke_all_for_user(&state.db, ctx.user_id).await;

    let ua = user_agent(&headers);
    let ip = client_ip(&headers);
    record_audit(
        &state.db,
        "change_password",
        None,
        Some(ctx.user_id),
        ip.as_deref(),
        ua.as_deref(),
        true,
        None,
    )
    .await;

    Ok(StatusCode::NO_CONTENT)
}

// ----- middleware -----

#[derive(Clone, Copy)]
pub struct AuthContext {
    pub user_id: Uuid,
    pub session_id: Uuid,
}

pub async fn require_auth(
    State(state): State<AppState>,
    jar: CookieJar,
    mut req: axum::extract::Request,
    next: Next,
) -> Response {
    let token = match jar.get(sessions::COOKIE_NAME) {
        Some(c) => c.value().to_string(),
        None => return unauthorized(),
    };
    match sessions::validate_and_touch(&state.db, &token).await {
        Ok(Some(s)) => {
            req.extensions_mut().insert(AuthContext {
                user_id: s.user_id,
                session_id: s.session_id,
            });
            next.run(req).await
        }
        Ok(None) => unauthorized(),
        Err(e) => {
            tracing::error!("session lookup failed: {}", e);
            ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "Session check failed")
                .into_response()
        }
    }
}

fn unauthorized() -> Response {
    ApiError::new(StatusCode::UNAUTHORIZED, "Authentication required").into_response()
}

// ----- helpers -----

async fn user_count(db: &PgPool) -> anyhow::Result<i64> {
    let n: i64 = sqlx::query_scalar("SELECT COUNT(*) FROM users")
        .fetch_one(db)
        .await?;
    Ok(n)
}

async fn load_user_view(db: &PgPool, user_id: Uuid) -> anyhow::Result<UserView> {
    let row: (
        Uuid,
        String,
        Option<String>,
        DateTime<Utc>,
        Option<DateTime<Utc>>,
        bool,
    ) = sqlx::query_as(
        r#"
        SELECT id, username, email, created_at, last_login_at, totp_enabled
        FROM users WHERE id = $1
        "#,
    )
    .bind(user_id)
    .fetch_one(db)
    .await?;
    Ok(UserView {
        id: row.0,
        username: row.1,
        email: row.2,
        created_at: row.3,
        last_login_at: row.4,
        totp_enabled: row.5,
    })
}

async fn rate_limited(db: &PgPool, username: &str, ip: Option<&str>) -> bool {
    let window = Utc::now() - chrono::Duration::seconds(FAILED_ATTEMPT_WINDOW_SECONDS);

    let by_user: i64 = sqlx::query_scalar(
        r#"
        SELECT COUNT(*) FROM auth_audit
        WHERE event = 'login' AND success = false
          AND LOWER(username_attempt) = LOWER($1)
          AND occurred_at >= $2
        "#,
    )
    .bind(username)
    .bind(window)
    .fetch_one(db)
    .await
    .unwrap_or(0);

    if by_user >= FAILED_ATTEMPT_THRESHOLD {
        return true;
    }
    if let Some(ip) = ip {
        let by_ip: i64 = sqlx::query_scalar(
            r#"
            SELECT COUNT(*) FROM auth_audit
            WHERE event = 'login' AND success = false
              AND ip_address = $1
              AND occurred_at >= $2
            "#,
        )
        .bind(ip)
        .bind(window)
        .fetch_one(db)
        .await
        .unwrap_or(0);
        if by_ip >= FAILED_ATTEMPT_THRESHOLD * 3 {
            return true;
        }
    }
    false
}

#[allow(clippy::too_many_arguments)]
async fn record_audit(
    db: &PgPool,
    event: &str,
    username: Option<&str>,
    user_id: Option<Uuid>,
    ip: Option<&str>,
    user_agent: Option<&str>,
    success: bool,
    detail: Option<&str>,
) {
    let res = sqlx::query(
        r#"
        INSERT INTO auth_audit (event, username_attempt, user_id, ip_address, user_agent, success, detail)
        VALUES ($1, $2, $3, $4, $5, $6, $7)
        "#,
    )
    .bind(event)
    .bind(username)
    .bind(user_id)
    .bind(ip)
    .bind(user_agent)
    .bind(success)
    .bind(detail)
    .execute(db)
    .await;
    if let Err(e) = res {
        tracing::warn!("failed to write auth_audit row: {}", e);
    }
}

fn user_agent(headers: &HeaderMap) -> Option<String> {
    headers
        .get(axum::http::header::USER_AGENT)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.chars().take(512).collect())
}

fn client_ip(headers: &HeaderMap) -> Option<String> {
    if let Some(fwd) = headers.get("x-forwarded-for").and_then(|v| v.to_str().ok()) {
        if let Some(first) = fwd.split(',').next() {
            let trimmed = first.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    if let Some(real) = headers.get("x-real-ip").and_then(|v| v.to_str().ok()) {
        let trimmed = real.trim();
        if !trimmed.is_empty() {
            return Some(trimmed.to_string());
        }
    }
    None
}

fn build_session_cookie(
    state: &AppState,
    token: String,
    expires_at: DateTime<Utc>,
) -> Cookie<'static> {
    let mut cookie = Cookie::new(sessions::COOKIE_NAME, token);
    cookie.set_http_only(true);
    cookie.set_secure(cookie_secure(&state.config));
    cookie.set_same_site(SameSite::Lax);
    cookie.set_path("/");
    let ttl_seconds = (expires_at - Utc::now()).num_seconds().max(60);
    cookie.set_max_age(CookieDuration::seconds(ttl_seconds));
    cookie
}

fn cookie_secure(config: &crate::config::AppConfig) -> bool {
    config.cookie_secure || config.frontend_base_url.starts_with("https://")
}

fn invalid_credentials() -> ApiError {
    ApiError::new(StatusCode::UNAUTHORIZED, "Invalid username or password.")
}

fn internal<E: std::fmt::Display>(e: E) -> ApiError {
    tracing::error!("auth internal error: {}", e);
    ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "Internal server error")
}

// ----- error envelope -----

pub struct ApiError {
    status: StatusCode,
    message: String,
}

impl ApiError {
    pub fn new(status: StatusCode, message: &str) -> Self {
        Self {
            status,
            message: message.to_string(),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = serde_json::json!({ "error": self.message });
        (self.status, Json(body)).into_response()
    }
}
