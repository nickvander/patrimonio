//! The session-auth middleware stack. axum applies `.layer()` bottom-up
//! (last = outermost), and the order is load-bearing:
//! `require_csrf_header` (outer) → `require_auth` (populates
//! `AuthContext`) → `require_owner` (inner, per business router).
//! See the `main.rs` comment before reordering anything.

use axum::{
    extract::{Extension, State},
    http::StatusCode,
    middleware::Next,
    response::{IntoResponse, Response},
};
use axum_extra::extract::cookie::CookieJar;
use uuid::Uuid;

use crate::api::error::ApiError;
use crate::services::sessions;
use crate::AppState;

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
pub async fn require_csrf_header(req: axum::extract::Request, next: Next) -> Response {
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
            ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, "Session check failed").into_response()
        }
    }
}

fn unauthorized() -> Response {
    ApiError::new(StatusCode::UNAUTHORIZED, "Authentication required").into_response()
}
