use axum::{
    extract::{Extension, Path, State},
    http::{HeaderMap, StatusCode},
    middleware::Next,
    response::{IntoResponse, Response},
    routing::{delete, get, post},
    Json, Router,
};
use axum_extra::extract::cookie::{Cookie, CookieJar, SameSite};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use sqlx::PgPool;
use time::Duration as CookieDuration;
use uuid::Uuid;

use crate::services::{password, recovery, sessions, totp};
use crate::AppState;

/// Failed login back-off window and per-key threshold. Conservative
/// defaults that are still usable on a typo-fest.
const FAILED_ATTEMPT_WINDOW_SECONDS: i64 = 60;
const FAILED_ATTEMPT_THRESHOLD: i64 = 5;

/// Endpoints reachable without a full session cookie. The login
/// screen needs these to render before the user has authenticated.
/// `/totp/verify` also lives here — it reads its own pending-TOTP
/// cookie rather than relying on the require_auth middleware.
pub fn public_router() -> Router<AppState> {
    Router::new()
        .route("/login", post(login))
        .route("/bootstrap", post(bootstrap))
        .route("/register", post(register))
        .route("/status", get(status))
        .route("/recover", post(recover))
        .route("/totp/verify", post(totp_verify))
}

/// Endpoints that require a valid (non-pending) session cookie.
/// Mount these under the auth middleware so `AuthContext` is populated.
pub fn protected_router() -> Router<AppState> {
    Router::new()
        .route("/logout", post(logout))
        .route("/me", get(me))
        .route("/change-password", post(change_password))
        .route("/recovery-codes/regenerate", post(regenerate_recovery_codes))
        .route("/recovery-codes/count", get(recovery_codes_count))
        .route("/totp/enroll", post(totp_enroll))
        .route("/totp/confirm", post(totp_confirm))
        .route("/totp/disable", post(totp_disable))
        .route("/sessions", get(list_sessions))
        .route("/sessions/{id}", delete(revoke_session))
        .route("/sessions/revoke-others", post(revoke_other_sessions))
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
    /// 'owner' or 'read_only'. Lets the frontend hide write
    /// affordances (rename, delete, sync) for read-only sessions
    /// rather than letting the user click and discover a 403.
    pub role: String,
}

#[derive(Serialize)]
pub struct StatusResponse {
    pub needs_bootstrap: bool,
    pub authenticated: bool,
    /// True when the cookie resolves to a pending-TOTP session — i.e.
    /// the user has typed their password and now needs to enter their
    /// TOTP code. The client should route to the TOTP challenge
    /// screen instead of the login screen.
    pub requires_totp: bool,
    pub user: Option<UserView>,
}

#[derive(Deserialize)]
pub struct BootstrapRequest {
    pub username: String,
    pub email: Option<String>,
    pub password: String,
}

#[derive(Deserialize)]
pub struct RegisterRequest {
    pub token: String,
    pub username: String,
    pub email: Option<String>,
    pub password: String,
}

#[derive(Serialize)]
pub struct RegisterResponse {
    pub user: UserView,
    pub recovery_codes: Vec<String>,
}

#[derive(Deserialize)]
pub struct ChangePasswordRequest {
    pub current_password: String,
    pub new_password: String,
}

#[derive(Deserialize)]
pub struct RecoverRequest {
    pub username: String,
    pub code: String,
    pub new_password: String,
}

/// Returned by the bootstrap endpoint and by recovery-codes/regenerate.
/// `codes` are plaintext — this is the only time they're ever returned.
#[derive(Serialize)]
pub struct RecoveryCodesView {
    pub codes: Vec<String>,
}

/// Bootstrap response carries both the new user and their first batch
/// of recovery codes — the client must display these once and warn the
/// user that they will never be shown again.
#[derive(Serialize)]
pub struct BootstrapResponse {
    pub user: UserView,
    pub recovery_codes: Vec<String>,
}

#[derive(Serialize)]
pub struct RecoveryCodesCount {
    pub unused: i64,
}

/// Either we hand back a full UserView (no TOTP, login complete) or
/// we tell the client to walk the user through the second step.
#[derive(Serialize)]
#[serde(untagged)]
pub enum LoginResponse {
    Done(UserView),
    NeedsTotp { requires_totp: bool },
}

#[derive(Deserialize)]
pub struct TotpVerifyRequest {
    pub code: String,
}

#[derive(Deserialize)]
pub struct TotpDisableRequest {
    pub current_password: String,
}

#[derive(Serialize)]
pub struct TotpEnrollment {
    pub secret_base32: String,
    pub provisioning_uri: String,
}

#[derive(Serialize)]
pub struct ActiveSessionView {
    pub id: Uuid,
    pub created_at: DateTime<Utc>,
    pub last_seen_at: DateTime<Utc>,
    pub expires_at: DateTime<Utc>,
    pub user_agent: Option<String>,
    pub ip_address: Option<String>,
    /// True when this row is the session of the requesting cookie —
    /// the UI surfaces it as "this device" and disables the revoke
    /// button so the user doesn't accidentally log themselves out
    /// from this very page.
    pub is_current: bool,
    /// True when `created_at > users.previous_login_at` — i.e. the
    /// session was minted AFTER the second-most-recent login. The
    /// UI flags these with a "new since last visit" pill so the
    /// user can spot a session they don't recognise without
    /// having to scan the audit log.
    pub new_since_last_visit: bool,
}

#[derive(Serialize)]
pub struct RevokeOthersResponse {
    pub revoked: u64,
}

// ----- handlers -----

async fn status(State(state): State<AppState>, jar: CookieJar) -> Json<StatusResponse> {
    let total = user_count(&state.db).await.unwrap_or(0);
    if total == 0 {
        return Json(StatusResponse {
            needs_bootstrap: true,
            authenticated: false,
            requires_totp: false,
            user: None,
        });
    }

    let (user, requires_totp) = match jar.get(sessions::COOKIE_NAME) {
        Some(cookie) => match sessions::validate_and_touch(&state.db, cookie.value()).await {
            Ok(Some(s)) if s.pending_totp => (None, true),
            Ok(Some(s)) => (load_user_view(&state.db, s.user_id).await.ok(), false),
            _ => (None, false),
        },
        None => (None, false),
    };

    Json(StatusResponse {
        needs_bootstrap: false,
        authenticated: user.is_some(),
        requires_totp,
        user,
    })
}

async fn bootstrap(
    State(state): State<AppState>,
    jar: CookieJar,
    headers: HeaderMap,
    Json(body): Json<BootstrapRequest>,
) -> Result<(CookieJar, Json<BootstrapResponse>), ApiError> {
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

    // Generate the first batch of recovery codes — returned ONCE in
    // this response. The frontend must display + warn the user that
    // they will never be shown again.
    let recovery_codes = recovery::regenerate(&state.db, user_id)
        .await
        .map_err(internal)?;

    let jar = jar.add(build_session_cookie(&state, session.token, session.expires_at));
    let user = load_user_view(&state.db, user_id).await.map_err(internal)?;
    Ok((
        jar,
        Json(BootstrapResponse {
            user,
            recovery_codes,
        }),
    ))
}

/// Public registration handler — redeems an invite token, creates a
/// user, signs them in, returns one batch of recovery codes. The
/// invite must be unused and unexpired; ownership of the invite (who
/// minted it) is irrelevant for redemption.
async fn register(
    State(state): State<AppState>,
    jar: CookieJar,
    headers: HeaderMap,
    Json(body): Json<RegisterRequest>,
) -> Result<(CookieJar, Json<RegisterResponse>), ApiError> {
    let username = body.username.trim().to_string();
    if username.is_empty() || username.len() > 64 {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "Username must be 1-64 characters.",
        ));
    }
    if body.token.trim().is_empty() {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "Invite token is required.",
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
    let ua = user_agent(&headers);
    let ip = client_ip(&headers);

    // Insert the user first, then atomically mark the invite as used.
    // Order matters: if we marked the invite used first and the user
    // insert failed (e.g. username conflict), the invite would be
    // burned with no account behind it.
    let user_id_result: Result<Uuid, sqlx::Error> = sqlx::query_scalar(
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
    .await;

    let user_id = match user_id_result {
        Ok(id) => id,
        Err(sqlx::Error::Database(db_err)) if db_err.constraint().is_some() => {
            return Err(ApiError::new(
                StatusCode::CONFLICT,
                "That username is already taken.",
            ));
        }
        Err(e) => return Err(internal(e)),
    };

    // Now consume the invite. If it fails (token invalid / expired /
    // already used), roll back the just-created user — otherwise we'd
    // leave a user-shaped artifact behind for an invalid invite.
    // Returns the role the new user should inherit, copied off the
    // invite_tokens row.
    let invite_role =
        match crate::api::invites::consume_invite(&state.db, body.token.trim(), user_id).await {
            Ok(role) => role,
            Err(reason) => {
                let _ = sqlx::query("DELETE FROM users WHERE id = $1")
                    .bind(user_id)
                    .execute(&state.db)
                    .await;
                return Err(ApiError::new(StatusCode::BAD_REQUEST, reason));
            }
        };

    // Stamp the role onto the freshly-created user. Default for the
    // INSERT above was 'owner'; this UPDATE downgrades read-only
    // invites without leaving a privilege-escalation window
    // (require_owner would still 403 read-only sessions before
    // they could do anything destructive).
    if invite_role != "owner" {
        if let Err(e) = sqlx::query("UPDATE users SET role = $1 WHERE id = $2")
            .bind(&invite_role)
            .bind(user_id)
            .execute(&state.db)
            .await
        {
            // Best-effort rollback: an UPDATE failure here means the
            // new user has the wrong role (owner instead of read-
            // only). Tear them down rather than ship an owner
            // session.
            let _ = sqlx::query("DELETE FROM users WHERE id = $1")
                .bind(user_id)
                .execute(&state.db)
                .await;
            return Err(internal(e));
        }
    }

    record_audit(
        &state.db,
        "register",
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

    let recovery_codes = recovery::regenerate(&state.db, user_id)
        .await
        .map_err(internal)?;

    let jar = jar.add(build_session_cookie(&state, session.token, session.expires_at));
    let user = load_user_view(&state.db, user_id).await.map_err(internal)?;
    Ok((
        jar,
        Json(RegisterResponse {
            user,
            recovery_codes,
        }),
    ))
}

async fn login(
    State(state): State<AppState>,
    jar: CookieJar,
    headers: HeaderMap,
    Json(body): Json<LoginRequest>,
) -> Result<(CookieJar, Json<LoginResponse>), ApiError> {
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

    let row: Option<(Uuid, String, bool, bool)> = sqlx::query_as(
        "SELECT id, password_hash, is_active, totp_enabled FROM users WHERE LOWER(username) = LOWER($1)",
    )
    .bind(&username)
    .fetch_optional(&state.db)
    .await
    .map_err(internal)?;

    let Some((user_id, hash, is_active, totp_enabled)) = row else {
        // Close the timing oracle: run a real Argon2 verify against a
        // fixed dummy hash so the unknown-username path takes the same
        // wall-clock time as the bad-password path. Without this a
        // remote attacker can enumerate valid usernames by clocking
        // /login responses.
        password::dummy_verify();
        // 50-150 ms jitter before responding. Stops a brute-forcer
        // from probing at full HTTP throughput while still below the
        // 5/min hard rate-limit threshold.
        password::random_login_jitter().await;
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
        password::random_login_jitter().await;
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
        password::random_login_jitter().await;
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

    // If the user has TOTP enabled, the password step issues a
    // short-lived pending session. The client is expected to follow up
    // with POST /api/auth/totp/verify before it can hit any data
    // route. require_auth rejects pending sessions everywhere else.
    if totp_enabled {
        let pending = sessions::create_pending_totp_session(
            &state.db,
            user_id,
            ua.as_deref(),
            ip.as_deref(),
        )
        .await
        .map_err(internal)?;

        record_audit(
            &state.db,
            "login_partial",
            Some(&username),
            Some(user_id),
            ip.as_deref(),
            ua.as_deref(),
            true,
            Some("awaiting_totp"),
        )
        .await;

        let jar = jar.add(build_session_cookie(&state, pending.token, pending.expires_at));
        return Ok((jar, Json(LoginResponse::NeedsTotp { requires_totp: true })));
    }

    let session = sessions::create_session(&state.db, user_id, ua.as_deref(), ip.as_deref())
        .await
        .map_err(internal)?;

    // Roll the prior login forward so the dashboard's "since last
    // login" anchor uses the previous session, not the one we're
    // about to create. Done in one statement so a concurrent login
    // can't observe an inconsistent intermediate state.
    let _ = sqlx::query(
        "UPDATE users SET previous_login_at = last_login_at, \
                          last_login_at = NOW() WHERE id = $1",
    )
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
    Ok((jar, Json(LoginResponse::Done(user))))
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

/// Redeem a recovery code to reset the password. Public endpoint, so
/// rate-limited by the existing /login limiter (same username and IP
/// keys) — we don't want it to be the easy path around the limiter.
async fn recover(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<RecoverRequest>,
) -> Result<StatusCode, ApiError> {
    let username = body.username.trim().to_string();
    let ua = user_agent(&headers);
    let ip = client_ip(&headers);

    password::validate_password_policy(&body.new_password)
        .map_err(|e| ApiError::new(StatusCode::BAD_REQUEST, &e.to_string()))?;

    if rate_limited(&state.db, &username, ip.as_deref()).await {
        record_audit(&state.db, "recover", Some(&username), None, ip.as_deref(), ua.as_deref(), false, Some("rate_limited")).await;
        return Err(ApiError::new(
            StatusCode::TOO_MANY_REQUESTS,
            "Too many recent attempts. Try again shortly.",
        ));
    }

    // Look up the user and the code's owner in two read-only queries
    // BEFORE consuming the code. Otherwise an attacker who knew a
    // code but not the username could lock the user out by burning
    // every code through bogus-username attempts.
    let user_row: Option<(Uuid,)> =
        sqlx::query_as("SELECT id FROM users WHERE LOWER(username) = LOWER($1)")
            .bind(&username)
            .fetch_optional(&state.db)
            .await
            .map_err(internal)?;

    let code_owner = recovery::lookup_owner(&state.db, &body.code)
        .await
        .map_err(internal)?;

    let target_user = match (user_row, code_owner) {
        (Some((user_id,)), Some(owner_uid)) if user_id == owner_uid => user_id,
        _ => {
            // Same jitter as the password path — recovery codes are
            // higher-entropy but still finite (10 codes per user), so
            // a high-throughput probe is worth slowing down.
            password::random_login_jitter().await;
            // Log under the `login` event so the rate limiter sees it
            // and exponential lockout applies to recovery attempts too.
            record_audit(&state.db, "login", Some(&username), None, ip.as_deref(), ua.as_deref(), false, Some("recover_invalid")).await;
            return Err(ApiError::new(
                StatusCode::UNAUTHORIZED,
                "Invalid username or recovery code.",
            ));
        }
    };

    // Now race-safely consume the code. If a concurrent caller beat
    // us to it (e.g. browser retry), the UPDATE affects 0 rows and we
    // treat it as already-used.
    let burned = recovery::consume(&state.db, &body.code, ip.as_deref())
        .await
        .map_err(internal)?;
    if !burned {
        record_audit(&state.db, "login", Some(&username), Some(target_user), ip.as_deref(), ua.as_deref(), false, Some("recover_race")).await;
        return Err(ApiError::new(
            StatusCode::UNAUTHORIZED,
            "Recovery code is no longer valid.",
        ));
    }

    let new_hash = password::hash_password(&body.new_password).map_err(internal)?;
    sqlx::query("UPDATE users SET password_hash = $1 WHERE id = $2")
        .bind(&new_hash)
        .bind(target_user)
        .execute(&state.db)
        .await
        .map_err(internal)?;

    // Anyone with a live session before this point should be kicked
    // out — they may be the attacker.
    let _ = sessions::revoke_all_for_user(&state.db, target_user).await;

    record_audit(&state.db, "recover", Some(&username), Some(target_user), ip.as_deref(), ua.as_deref(), true, None).await;
    Ok(StatusCode::NO_CONTENT)
}

async fn regenerate_recovery_codes(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    headers: HeaderMap,
) -> Result<Json<RecoveryCodesView>, ApiError> {
    let codes = recovery::regenerate(&state.db, ctx.user_id)
        .await
        .map_err(internal)?;
    let ua = user_agent(&headers);
    let ip = client_ip(&headers);
    record_audit(
        &state.db,
        "regenerate_recovery_codes",
        None,
        Some(ctx.user_id),
        ip.as_deref(),
        ua.as_deref(),
        true,
        None,
    )
    .await;
    Ok(Json(RecoveryCodesView { codes }))
}

async fn recovery_codes_count(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Result<Json<RecoveryCodesCount>, ApiError> {
    let unused = recovery::unused_count(&state.db, ctx.user_id)
        .await
        .map_err(internal)?;
    Ok(Json(RecoveryCodesCount { unused }))
}

// ----- TOTP -----

async fn totp_enroll(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Result<Json<TotpEnrollment>, ApiError> {
    let enc_key = state
        .config
        .encryption_key
        .as_ref()
        .ok_or_else(|| ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "ENCRYPTION_KEY is not configured; TOTP cannot be enabled.",
        ))?;

    let username: String = sqlx::query_scalar("SELECT username FROM users WHERE id = $1")
        .bind(ctx.user_id)
        .fetch_one(&state.db)
        .await
        .map_err(internal)?;

    let challenge = totp::begin_enrollment(&state.db, enc_key, ctx.user_id, &username)
        .await
        .map_err(internal)?;

    Ok(Json(TotpEnrollment {
        secret_base32: challenge.secret_base32,
        provisioning_uri: challenge.provisioning_uri,
    }))
}

async fn totp_confirm(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    headers: HeaderMap,
    Json(body): Json<TotpVerifyRequest>,
) -> Result<StatusCode, ApiError> {
    let enc_key = state
        .config
        .encryption_key
        .as_ref()
        .ok_or_else(|| ApiError::new(
            StatusCode::SERVICE_UNAVAILABLE,
            "ENCRYPTION_KEY is not configured.",
        ))?;

    // Use the no-advance variant: a valid confirm code MUST also work
    // on the immediately-following login if the user enrols + logs in
    // inside one 30s TOTP step (the most common case in onboarding
    // walkthroughs and tests). Advancing the replay marker here would
    // block that login until the next step rotates.
    let ok = totp::verify_no_advance(&state.db, enc_key, ctx.user_id, &body.code)
        .await
        .map_err(internal)?;
    if !ok {
        return Err(ApiError::new(
            StatusCode::UNAUTHORIZED,
            "Invalid TOTP code. Check your authenticator app and try again.",
        ));
    }
    let flipped = totp::mark_enabled(&state.db, ctx.user_id).await.map_err(internal)?;
    if !flipped {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "Begin enrollment first via /api/auth/totp/enroll.",
        ));
    }

    let ua = user_agent(&headers);
    let ip = client_ip(&headers);
    record_audit(&state.db, "totp_enabled", None, Some(ctx.user_id), ip.as_deref(), ua.as_deref(), true, None).await;
    Ok(StatusCode::NO_CONTENT)
}

async fn totp_disable(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    headers: HeaderMap,
    Json(body): Json<TotpDisableRequest>,
) -> Result<StatusCode, ApiError> {
    // Re-authenticate with the password before disabling — losing
    // TOTP is a major reduction in account security.
    let stored: String = sqlx::query_scalar("SELECT password_hash FROM users WHERE id = $1")
        .bind(ctx.user_id)
        .fetch_one(&state.db)
        .await
        .map_err(internal)?;
    let ok = password::verify_password(&body.current_password, &stored).map_err(internal)?;
    if !ok {
        return Err(invalid_credentials());
    }

    totp::disable(&state.db, ctx.user_id).await.map_err(internal)?;

    let ua = user_agent(&headers);
    let ip = client_ip(&headers);
    record_audit(&state.db, "totp_disabled", None, Some(ctx.user_id), ip.as_deref(), ua.as_deref(), true, None).await;
    Ok(StatusCode::NO_CONTENT)
}

/// Second step of the two-step login: the client holds a pending
/// session cookie from POST /login, posts the TOTP code here, and we
/// rotate to a full session.
async fn totp_verify(
    State(state): State<AppState>,
    jar: CookieJar,
    headers: HeaderMap,
    Json(body): Json<TotpVerifyRequest>,
) -> Result<(CookieJar, Json<UserView>), ApiError> {
    let token = jar
        .get(sessions::COOKIE_NAME)
        .ok_or_else(|| ApiError::new(StatusCode::UNAUTHORIZED, "No pending session."))?
        .value()
        .to_string();

    let validated = sessions::validate_and_touch(&state.db, &token)
        .await
        .map_err(internal)?
        .ok_or_else(|| ApiError::new(StatusCode::UNAUTHORIZED, "Pending session expired."))?;

    if !validated.pending_totp {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "Session is not awaiting TOTP verification.",
        ));
    }

    let enc_key = state.config.encryption_key.as_ref().ok_or_else(|| {
        ApiError::new(StatusCode::SERVICE_UNAVAILABLE, "ENCRYPTION_KEY is not configured.")
    })?;

    let ok = totp::verify(&state.db, enc_key, validated.user_id, &body.code)
        .await
        .map_err(internal)?;

    let ua = user_agent(&headers);
    let ip = client_ip(&headers);

    if !ok {
        // Same rate-limit defence as the password path: 50-150 ms
        // jitter before responding so a brute-forcer can't probe
        // TOTP codes (1 in 1M per attempt) at HTTP throughput.
        password::random_login_jitter().await;
        record_audit(&state.db, "totp_verify", None, Some(validated.user_id), ip.as_deref(), ua.as_deref(), false, Some("bad_code")).await;
        return Err(ApiError::new(
            StatusCode::UNAUTHORIZED,
            "Invalid TOTP code.",
        ));
    }

    // Promote: drop the pending session, mint a full one.
    let _ = sessions::revoke_by_token(&state.db, &token).await;
    let full = sessions::create_session(&state.db, validated.user_id, ua.as_deref(), ip.as_deref())
        .await
        .map_err(internal)?;
    let _ = sqlx::query(
        "UPDATE users SET previous_login_at = last_login_at, \
                          last_login_at = NOW() WHERE id = $1",
    )
        .bind(validated.user_id)
        .execute(&state.db)
        .await;

    record_audit(&state.db, "login", None, Some(validated.user_id), ip.as_deref(), ua.as_deref(), true, Some("totp_ok")).await;

    let jar = jar.add(build_session_cookie(&state, full.token, full.expires_at));
    let user = load_user_view(&state.db, validated.user_id).await.map_err(internal)?;
    Ok((jar, Json(user)))
}

// ----- session management -----

/// Return the list of live sessions for the current user, with one
/// row flagged as `is_current` so the UI can show "this device" and
/// guard against accidentally revoking the active cookie.
async fn list_sessions(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Result<Json<Vec<ActiveSessionView>>, ApiError> {
    let rows = sessions::list_active(&state.db, ctx.user_id)
        .await
        .map_err(internal)?;

    // Anchor for the "new since last visit" badge. None on a fresh
    // user (first login ever) means no session can be "new" yet —
    // every session is the user's very first one. The current
    // session itself is always excluded from the badge logic via
    // `is_current` so the user doesn't see a flag on their own
    // device.
    let anchor: Option<DateTime<Utc>> =
        sqlx::query_scalar("SELECT previous_login_at FROM users WHERE id = $1")
            .bind(ctx.user_id)
            .fetch_optional(&state.db)
            .await
            .ok()
            .flatten();

    let view: Vec<ActiveSessionView> = rows
        .into_iter()
        .map(|r| {
            let is_current = r.id == ctx.session_id;
            let new_since_last_visit = !is_current
                && anchor.is_some_and(|a| r.created_at > a);
            ActiveSessionView {
                id: r.id,
                created_at: r.created_at,
                last_seen_at: r.last_seen_at,
                expires_at: r.expires_at,
                user_agent: r.user_agent,
                ip_address: r.ip_address,
                is_current,
                new_since_last_visit,
            }
        })
        .collect();
    Ok(Json(view))
}

/// Revoke a single session by id. Refuses to revoke the requester's
/// own session — they should use POST /logout for that, which also
/// emits the Set-Cookie removal directive. This is intentionally a
/// no-op rather than an error if the id doesn't exist or doesn't
/// belong to the user, to avoid leaking a session-id-enumeration
/// oracle.
async fn revoke_session(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    headers: HeaderMap,
    Path(target_id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    if target_id == ctx.session_id {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "Use POST /api/auth/logout to sign out of the current session.",
        ));
    }

    let _flipped = sessions::revoke_by_id_for_user(&state.db, target_id, ctx.user_id)
        .await
        .map_err(internal)?;

    let ua = user_agent(&headers);
    let ip = client_ip(&headers);
    record_audit(
        &state.db,
        "revoke_session",
        None,
        Some(ctx.user_id),
        ip.as_deref(),
        ua.as_deref(),
        true,
        Some(&target_id.to_string()),
    )
    .await;

    Ok(StatusCode::NO_CONTENT)
}

/// "Sign out everywhere else" — revoke every other live session for
/// this user but keep the current cookie alive so the user stays
/// signed in on the page that issued the request.
async fn revoke_other_sessions(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    headers: HeaderMap,
) -> Result<Json<RevokeOthersResponse>, ApiError> {
    let revoked = sessions::revoke_all_except(&state.db, ctx.user_id, ctx.session_id)
        .await
        .map_err(internal)?;

    let ua = user_agent(&headers);
    let ip = client_ip(&headers);
    record_audit(
        &state.db,
        "revoke_other_sessions",
        None,
        Some(ctx.user_id),
        ip.as_deref(),
        ua.as_deref(),
        true,
        Some(&format!("revoked={}", revoked)),
    )
    .await;

    Ok(Json(RevokeOthersResponse { revoked }))
}

// ----- middleware -----

#[derive(Clone)]
pub struct AuthContext {
    pub user_id: Uuid,
    pub session_id: Uuid,
    /// 'owner' or 'read_only'. Used by `require_owner` to gate
    /// mutating endpoints. Read endpoints don't consult it — every
    /// authenticated user can see their own data regardless of role.
    pub role: String,
}

impl AuthContext {
    /// Convenience for `require_owner` and any handler that wants
    /// to short-circuit a mutation based on role.
    pub fn is_owner(&self) -> bool {
        self.role == "owner"
    }
}

/// CSRF defence-in-depth.
///
/// Today the session cookie has `SameSite=Lax`, GETs have no side
/// effects, and CORS allow-lists the credentialed origin. Belt-and-
/// suspenders: require `X-Requested-With: fetch` (or any non-empty
/// value) on every mutating method (POST/PUT/PATCH/DELETE). A
/// classic CSRF attacker can't set custom headers from a malicious
/// origin without triggering a preflight, and our CORS layer
/// rejects unknown origins on preflights — so a request that reaches
/// the handler without this header is either misconfigured first-
/// party JS (we add it client-side) or a CSRF attempt.
///
/// Public webhook routes mount BEFORE this layer (in the public
/// router) so Plaid's webhooks aren't broken. The protected router
/// is the only thing this middleware wraps.
pub async fn require_csrf_header(
    req: axum::extract::Request,
    next: Next,
) -> Response {
    use axum::http::Method;
    let m = req.method().clone();
    if matches!(m, Method::GET | Method::HEAD | Method::OPTIONS) {
        return next.run(req).await;
    }
    let ok = req
        .headers()
        .get("x-requested-with")
        .and_then(|v| v.to_str().ok())
        .map(|s| !s.trim().is_empty())
        .unwrap_or(false);
    if !ok {
        return ApiError::new(
            StatusCode::FORBIDDEN,
            "X-Requested-With header required on mutating requests",
        )
        .into_response();
    }
    next.run(req).await
}

/// Gates mutating requests on `role == 'owner'`. Mounted INSIDE
/// `require_auth` so `AuthContext` is populated; GET/HEAD/OPTIONS
/// pass through untouched (read-only users can read anything they
/// own). Apply only to the business sub-router — auth/session/
/// password-management endpoints stay accessible to every
/// authenticated user (a read-only user must be able to log out,
/// change their own password, manage their own passkeys, regenerate
/// their own recovery codes).
pub async fn require_owner(
    Extension(ctx): Extension<AuthContext>,
    req: axum::extract::Request,
    next: Next,
) -> Response {
    use axum::http::Method;
    let m = req.method().clone();
    if matches!(m, Method::GET | Method::HEAD | Method::OPTIONS) {
        return next.run(req).await;
    }
    if ctx.is_owner() {
        return next.run(req).await;
    }
    ApiError::new(
        StatusCode::FORBIDDEN,
        "This account is read-only and cannot modify data. \
         Ask an owner to mint you an owner-role invite if you need write access.",
    )
    .into_response()
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
            // Pending-TOTP sessions can only be used by /totp/verify,
            // which lives in the public router and reads the cookie
            // directly. Anything else they hit must 401 so the client
            // knows to walk through the second factor first.
            if s.pending_totp {
                return ApiError::new(StatusCode::UNAUTHORIZED, "TOTP verification required")
                    .into_response();
            }
            req.extensions_mut().insert(AuthContext {
                user_id: s.user_id,
                session_id: s.session_id,
                role: s.role,
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

pub(crate) async fn load_user_view(db: &PgPool, user_id: Uuid) -> anyhow::Result<UserView> {
    let row: (
        Uuid,
        String,
        Option<String>,
        DateTime<Utc>,
        Option<DateTime<Utc>>,
        bool,
        String,
    ) = sqlx::query_as(
        r#"
        SELECT id, username, email, created_at, last_login_at, totp_enabled, role
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
        role: row.6,
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
        // Exponential backoff on the 429 path. The first attempt over
        // threshold pauses 1 s before responding; each subsequent
        // attempt within the 60 s window doubles up to 30 s. A
        // brute-forcer can no longer probe at HTTP throughput once
        // they cross the line — the throttle scales with their
        // persistence. The legitimate user who mistyped 5× in a row
        // experiences at most a 1 s delay on attempt 6, well under
        // the patience floor.
        backoff_sleep(by_user - FAILED_ATTEMPT_THRESHOLD + 1).await;
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
            backoff_sleep(by_ip - FAILED_ATTEMPT_THRESHOLD * 3 + 1).await;
            return true;
        }
    }
    false
}

/// 1 s → 2 s → 4 s → 8 s → 16 s → 30 s capped exponential backoff.
/// `excess` is the 1-indexed number of attempts past the rate-limit
/// threshold (1 = first over). Used by `rate_limited` to slow the
/// 429 response so a brute-forcer can't probe at HTTP throughput.
async fn backoff_sleep(excess: i64) {
    let exp = std::cmp::min(5_i64, (excess - 1).max(0)) as u32;
    let secs: u64 = std::cmp::min(30, 1u64 << exp);
    tokio::time::sleep(std::time::Duration::from_secs(secs)).await;
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

pub(crate) fn user_agent(headers: &HeaderMap) -> Option<String> {
    headers
        .get(axum::http::header::USER_AGENT)
        .and_then(|v| v.to_str().ok())
        .map(|s| s.chars().take(512).collect())
}

pub(crate) fn client_ip(headers: &HeaderMap) -> Option<String> {
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

pub(crate) fn build_session_cookie(
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

pub(crate) fn internal<E: std::fmt::Display>(e: E) -> ApiError {
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
