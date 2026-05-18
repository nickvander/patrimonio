//! Passkey (FIDO2 / WebAuthn) authentication.
//!
//! Mirrors the structure of `session.rs`:
//!   - register_start / register_finish — authenticated; user adds a new
//!     passkey to their account (e.g. their phone's biometric).
//!   - login_start  / login_finish     — unauthenticated; user signs in
//!     with a previously registered passkey. On success we issue the
//!     same opaque session cookie the password login does.
//!   - list / remove                    — authenticated; manage the
//!     registered passkeys (display name, last-used, delete).
//!
//! The per-flow `PasskeyRegistration` and `PasskeyAuthentication` state
//! objects ride in Redis with a 5-minute TTL keyed by a server-issued
//! random nonce. The client passes the nonce back to the finish step so
//! we can resume the ceremony. Keeping state out of cookies dodges the
//! 4KB cookie size limit and lets us forbid replay by deleting the key
//! the moment we consume it.

use axum::{
    extract::{Extension, Path, State},
    http::{HeaderMap, StatusCode},
    routing::{delete, get, post},
    Json, Router,
};
use axum_extra::extract::cookie::CookieJar;
use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine as _};
use chrono::{DateTime, Utc};
use rand::{rngs::OsRng, RngCore};
use redis::AsyncCommands;
use serde::{Deserialize, Serialize};
use uuid::Uuid;
use webauthn_rs::prelude::{
    CreationChallengeResponse, CredentialID, Passkey, PasskeyAuthentication, PasskeyRegistration,
    PublicKeyCredential, RegisterPublicKeyCredential, RequestChallengeResponse, Url, Uuid as WebauthnUuid,
    Webauthn, WebauthnBuilder,
};

use crate::api::session::{build_session_cookie, client_ip, internal, user_agent, ApiError, AuthContext};
use crate::services::sessions;
use crate::AppState;

const CHALLENGE_TTL_SECONDS: u64 = 300;
const REG_KEY_PREFIX: &str = "webauthn:reg:";
const LOGIN_KEY_PREFIX: &str = "webauthn:login:";

pub fn public_router() -> Router<AppState> {
    Router::new()
        .route("/login/start", post(login_start))
        .route("/login/finish", post(login_finish))
}

pub fn protected_router() -> Router<AppState> {
    Router::new()
        .route("/register/start", post(register_start))
        .route("/register/finish", post(register_finish))
        .route("/", get(list_passkeys))
        .route("/{id}", delete(remove_passkey))
}

// ---------------------------------------------------------------------------
// Webauthn builder.
//
// rp_id is the registrable domain (no scheme, no port) of the frontend.
// rp_origin is the full URL (scheme + host + port). Both come from
// `frontend_base_url` in AppConfig.
//
// For local dev where the user hits 127.0.0.1:3000, WebAuthn rejects
// IP-literal rp_ids — we collapse that to "localhost" so the spec is
// happy. Authenticators will then bind the credential to "localhost".
// ---------------------------------------------------------------------------
pub fn build_webauthn(frontend_base_url: &str) -> anyhow::Result<Webauthn> {
    let parsed = Url::parse(frontend_base_url)
        .map_err(|e| anyhow::anyhow!("invalid FRONTEND_BASE_URL '{}': {}", frontend_base_url, e))?;
    let host = parsed
        .host_str()
        .ok_or_else(|| anyhow::anyhow!("FRONTEND_BASE_URL has no host"))?;
    // IP literals (127.0.0.1, ::1) aren't valid rp_ids per the spec.
    // Browsers accept "localhost" as an exception; the dev origin is
    // already special-cased by Chrome/Firefox/Safari WebAuthn impls.
    let rp_id = match host {
        "127.0.0.1" | "::1" => "localhost",
        other => other,
    };
    // If we rewrote the rp_id we also have to rewrite the origin so the
    // two stay consistent.
    let mut origin = parsed.clone();
    if rp_id == "localhost" && host != "localhost" {
        origin
            .set_host(Some("localhost"))
            .map_err(|e| anyhow::anyhow!("failed to override origin host: {}", e))?;
    }
    let builder = WebauthnBuilder::new(rp_id, &origin)?
        .rp_name("Patrimonio")
        .allow_subdomains(false);
    Ok(builder.build()?)
}

// ---------------------------------------------------------------------------
// Wire types.
//
// All binary blobs (challenge, credential id, public key handle) ride
// the wire as base64url-no-pad strings — which is exactly what the
// browser's WebAuthn JS surface produces and consumes.
// ---------------------------------------------------------------------------

#[derive(Serialize)]
pub struct RegisterStartResponse {
    /// Opaque handle the client passes back to /register/finish so we
    /// can fish the PasskeyRegistration state out of Redis.
    pub nonce: String,
    /// The PublicKeyCredentialCreationOptions structure the browser
    /// feeds into navigator.credentials.create(). webauthn-rs returns
    /// it pre-encoded as base64url under the hood.
    pub options: CreationChallengeResponse,
}

#[derive(Deserialize)]
pub struct RegisterFinishRequest {
    pub nonce: String,
    /// The result the browser gave us from navigator.credentials.create().
    /// Deserialised via serde from the spec-shaped JSON.
    pub credential: RegisterPublicKeyCredential,
    /// Optional human-readable label the user picked ("iPhone 15",
    /// "Yubikey 5C"). Cleaned + length-checked on the server.
    pub nickname: Option<String>,
    /// Browser-reported authenticator class: "platform" (Face ID /
    /// Touch ID / Windows Hello) or "cross-platform" (USB / NFC
    /// hardware key). Display hint only — server never branches on it.
    pub authenticator_attachment: Option<String>,
}

#[derive(Serialize)]
pub struct PasskeySummary {
    pub id: Uuid,
    pub nickname: Option<String>,
    pub created_at: DateTime<Utc>,
    pub last_used_at: Option<DateTime<Utc>>,
    /// "platform" / "cross-platform" / null. Drives the row icon
    /// (phone biometric vs hardware security key) on the Security
    /// screen.
    pub authenticator_attachment: Option<String>,
}

#[derive(Deserialize)]
pub struct LoginStartRequest {
    /// Username to look up. Identical to the password-login field; the
    /// passkey UI can just reuse whatever's typed there.
    pub username: String,
}

#[derive(Serialize)]
pub struct LoginStartResponse {
    pub nonce: String,
    pub options: RequestChallengeResponse,
}

#[derive(Deserialize)]
pub struct LoginFinishRequest {
    pub nonce: String,
    pub credential: PublicKeyCredential,
}

#[derive(Serialize)]
pub struct LoginFinishResponse {
    pub user: crate::api::session::UserView,
}

// ---------------------------------------------------------------------------
// Register: authenticated user adds a passkey.
// ---------------------------------------------------------------------------

async fn register_start(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Result<Json<RegisterStartResponse>, ApiError> {
    // Pull every passkey id this user already registered so the
    // browser knows not to offer to enrol the same authenticator
    // twice (excludeCredentials).
    let existing_ids = sqlx::query_scalar::<_, Vec<u8>>(
        "SELECT credential_id FROM passkey_credentials WHERE user_id = $1",
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;
    let exclude: Vec<CredentialID> = existing_ids.into_iter().map(CredentialID::from).collect();
    let exclude_opt = if exclude.is_empty() { None } else { Some(exclude) };

    // Look up the username so the platform's passkey UI can display
    // something useful ("Save passkey for nick@…") rather than the
    // user's UUID.
    let (username, display_name): (String, Option<String>) = sqlx::query_as(
        "SELECT username, email FROM users WHERE id = $1",
    )
    .bind(ctx.user_id)
    .fetch_one(&state.db)
    .await
    .map_err(internal)?;

    let user_id_webauthn = WebauthnUuid::from_bytes(*ctx.user_id.as_bytes());

    let (options, reg_state) = state
        .webauthn
        .start_passkey_registration(
            user_id_webauthn,
            &username,
            display_name.as_deref().unwrap_or(&username),
            exclude_opt,
        )
        .map_err(|e| ApiError::new(StatusCode::INTERNAL_SERVER_ERROR, &format!("webauthn start: {e}")))?;

    let nonce = random_nonce();
    let key = format!("{REG_KEY_PREFIX}{}:{}", ctx.user_id, nonce);
    store_state(&state, &key, &reg_state).await?;

    Ok(Json(RegisterStartResponse { nonce, options }))
}

async fn register_finish(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Json(body): Json<RegisterFinishRequest>,
) -> Result<Json<PasskeySummary>, ApiError> {
    let key = format!("{REG_KEY_PREFIX}{}:{}", ctx.user_id, body.nonce);
    let reg_state: PasskeyRegistration = take_state(&state, &key).await?;

    let passkey = state
        .webauthn
        .finish_passkey_registration(&body.credential, &reg_state)
        .map_err(|e| ApiError::new(StatusCode::BAD_REQUEST, &format!("webauthn finish: {e}")))?;

    let credential_id: Vec<u8> = passkey.cred_id().as_ref().to_vec();
    let passkey_json = serde_json::to_value(&passkey).map_err(internal)?;
    let nickname = body
        .nickname
        .as_ref()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .map(|s| s.chars().take(64).collect::<String>());
    // Whitelist to known spec values so a malicious client can't seed
    // arbitrary strings into the column the UI renders.
    let attachment = body
        .authenticator_attachment
        .as_deref()
        .and_then(|s| match s {
            "platform" | "cross-platform" => Some(s.to_string()),
            _ => None,
        });

    let id: Uuid = sqlx::query_scalar(
        r#"
        INSERT INTO passkey_credentials
            (user_id, credential_id, passkey_json, nickname, authenticator_attachment)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (credential_id) DO UPDATE
            SET passkey_json             = EXCLUDED.passkey_json,
                nickname                 = COALESCE(EXCLUDED.nickname, passkey_credentials.nickname),
                authenticator_attachment = COALESCE(EXCLUDED.authenticator_attachment,
                                                    passkey_credentials.authenticator_attachment)
        RETURNING id
        "#,
    )
    .bind(ctx.user_id)
    .bind(&credential_id)
    .bind(&passkey_json)
    .bind(&nickname)
    .bind(&attachment)
    .fetch_one(&state.db)
    .await
    .map_err(internal)?;

    let created_at: DateTime<Utc> =
        sqlx::query_scalar("SELECT created_at FROM passkey_credentials WHERE id = $1")
            .bind(id)
            .fetch_one(&state.db)
            .await
            .map_err(internal)?;

    Ok(Json(PasskeySummary {
        id,
        nickname,
        created_at,
        last_used_at: None,
        authenticator_attachment: attachment,
    }))
}

// ---------------------------------------------------------------------------
// Login: unauthenticated user signs in with a previously-registered passkey.
//
// We use the username-first flow (the login screen already has a
// username field). /login/start takes the username, fetches every
// passkey row for that user, and seeds the assertion ceremony with the
// matching allow-list. The browser narrows the platform prompt to
// "this user's saved passkeys" rather than offering every credential
// for the origin.
//
// On finish we look up the credential by raw id (the assertion
// carries it), validate against the saved Passkey blob, bump the
// sign-counter, and issue a fresh session cookie.
//
// To resist user-enumeration, an unknown / inactive username still
// returns a usable-looking challenge; the actual rejection happens at
// /login/finish, where it merges with any other invalid-credential
// path.
// ---------------------------------------------------------------------------

async fn login_start(
    State(state): State<AppState>,
    Json(body): Json<LoginStartRequest>,
) -> Result<Json<LoginStartResponse>, ApiError> {
    let username = body.username.trim().to_string();
    if username.is_empty() {
        return Err(ApiError::new(StatusCode::BAD_REQUEST, "Username required."));
    }

    let user_row: Option<(Uuid, bool)> = sqlx::query_as(
        "SELECT id, is_active FROM users WHERE LOWER(username) = LOWER($1)",
    )
    .bind(&username)
    .fetch_optional(&state.db)
    .await
    .map_err(internal)?;

    let passkeys: Vec<Passkey> = match user_row {
        Some((user_id, true)) => {
            let rows: Vec<serde_json::Value> = sqlx::query_scalar(
                "SELECT passkey_json FROM passkey_credentials WHERE user_id = $1",
            )
            .bind(user_id)
            .fetch_all(&state.db)
            .await
            .map_err(internal)?;
            rows.into_iter()
                .map(serde_json::from_value::<Passkey>)
                .collect::<Result<_, _>>()
                .map_err(internal)?
        }
        _ => Vec::new(),
    };

    if passkeys.is_empty() {
        // Don't leak whether the user exists or just has no passkeys.
        return Err(ApiError::new(
            StatusCode::UNAUTHORIZED,
            "No passkey registered for this account.",
        ));
    }

    let (options, auth_state) = state
        .webauthn
        .start_passkey_authentication(&passkeys)
        .map_err(|e| {
            ApiError::new(
                StatusCode::INTERNAL_SERVER_ERROR,
                &format!("webauthn start: {e}"),
            )
        })?;

    // Stash the username + auth state in Redis so /login/finish can
    // confirm we're authenticating the same identity the user typed.
    let nonce = random_nonce();
    let key = format!("{LOGIN_KEY_PREFIX}{nonce}");
    let envelope = PendingAuth {
        username: username.clone(),
        state: auth_state,
    };
    store_state(&state, &key, &envelope).await?;

    Ok(Json(LoginStartResponse { nonce, options }))
}

#[derive(Serialize, Deserialize)]
struct PendingAuth {
    username: String,
    state: PasskeyAuthentication,
}

async fn login_finish(
    State(state): State<AppState>,
    jar: CookieJar,
    headers: HeaderMap,
    Json(body): Json<LoginFinishRequest>,
) -> Result<(CookieJar, Json<LoginFinishResponse>), ApiError> {
    let ua = user_agent(&headers);
    let ip = client_ip(&headers);

    let key = format!("{LOGIN_KEY_PREFIX}{}", body.nonce);
    let pending: PendingAuth = take_state(&state, &key).await?;

    // Re-resolve the user — Redis is not authoritative and the row may
    // have been deactivated between start and finish.
    let user_row: Option<(Uuid, bool)> = sqlx::query_as(
        "SELECT id, is_active FROM users WHERE LOWER(username) = LOWER($1)",
    )
    .bind(&pending.username)
    .fetch_optional(&state.db)
    .await
    .map_err(internal)?;
    let user_id = match user_row {
        Some((id, true)) => id,
        _ => {
            return Err(ApiError::new(
                StatusCode::UNAUTHORIZED,
                "Invalid passkey.",
            ));
        }
    };

    let result = state
        .webauthn
        .finish_passkey_authentication(&body.credential, &pending.state)
        .map_err(|e| {
            ApiError::new(StatusCode::UNAUTHORIZED, &format!("webauthn finish: {e}"))
        })?;

    // Find the DB row whose credential_id matches what the user just
    // signed with so we can bump last_used_at and rewrite the
    // sign-counter-carrying JSON blob.
    let used_cred_id: &[u8] = result.cred_id().as_ref();
    let row: Option<(Uuid, serde_json::Value)> = sqlx::query_as(
        "SELECT id, passkey_json FROM passkey_credentials
            WHERE user_id = $1 AND credential_id = $2",
    )
    .bind(user_id)
    .bind(used_cred_id)
    .fetch_optional(&state.db)
    .await
    .map_err(internal)?;

    let Some((row_id, json)) = row else {
        return Err(ApiError::new(
            StatusCode::UNAUTHORIZED,
            "Authenticated credential is not registered for this user.",
        ));
    };
    let mut updated_passkey: Passkey = serde_json::from_value(json).map_err(internal)?;
    // update_credential bumps the sign counter and any backup flags
    // that changed since registration. Returns Some(true) if anything
    // changed; we always write back to be safe.
    updated_passkey.update_credential(&result);

    let new_json = serde_json::to_value(&updated_passkey).map_err(internal)?;
    let _ = sqlx::query(
        "UPDATE passkey_credentials
            SET passkey_json = $1,
                last_used_at = NOW()
          WHERE id = $2",
    )
    .bind(&new_json)
    .bind(row_id)
    .execute(&state.db)
    .await;

    // Defence-in-depth: drop any stale session cookie before we issue
    // a new one.
    if let Some(existing) = jar.get(sessions::COOKIE_NAME) {
        let _ = sessions::revoke_by_token(&state.db, existing.value()).await;
    }

    let session = sessions::create_session(&state.db, user_id, ua.as_deref(), ip.as_deref())
        .await
        .map_err(internal)?;

    let _ = sqlx::query(
        "UPDATE users SET previous_login_at = last_login_at, \
                          last_login_at = NOW() WHERE id = $1",
    )
        .bind(user_id)
        .execute(&state.db)
        .await;

    let jar = jar.add(build_session_cookie(&state, session.token, session.expires_at));
    let user = crate::api::session::load_user_view(&state.db, user_id)
        .await
        .map_err(internal)?;

    Ok((jar, Json(LoginFinishResponse { user })))
}

// ---------------------------------------------------------------------------
// List / remove.
// ---------------------------------------------------------------------------

async fn list_passkeys(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Result<Json<Vec<PasskeySummary>>, ApiError> {
    let rows: Vec<(
        Uuid,
        Option<String>,
        DateTime<Utc>,
        Option<DateTime<Utc>>,
        Option<String>,
    )> = sqlx::query_as(
        r#"
        SELECT id, nickname, created_at, last_used_at, authenticator_attachment
        FROM passkey_credentials
        WHERE user_id = $1
        ORDER BY created_at DESC
        "#,
    )
    .bind(ctx.user_id)
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;

    Ok(Json(
        rows.into_iter()
            .map(
                |(id, nickname, created_at, last_used_at, authenticator_attachment)| {
                    PasskeySummary {
                        id,
                        nickname,
                        created_at,
                        last_used_at,
                        authenticator_attachment,
                    }
                },
            )
            .collect(),
    ))
}

async fn remove_passkey(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Path(id): Path<Uuid>,
) -> Result<StatusCode, ApiError> {
    let result = sqlx::query(
        "DELETE FROM passkey_credentials WHERE id = $1 AND user_id = $2",
    )
    .bind(id)
    .bind(ctx.user_id)
    .execute(&state.db)
    .await
    .map_err(internal)?;
    if result.rows_affected() == 0 {
        return Err(ApiError::new(StatusCode::NOT_FOUND, "Passkey not found."));
    }
    Ok(StatusCode::NO_CONTENT)
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn random_nonce() -> String {
    let mut bytes = [0u8; 24];
    OsRng.fill_bytes(&mut bytes);
    URL_SAFE_NO_PAD.encode(bytes)
}

async fn store_state<T: Serialize>(state: &AppState, key: &str, value: &T) -> Result<(), ApiError> {
    let json = serde_json::to_string(value).map_err(internal)?;
    let mut conn = state
        .redis
        .get_multiplexed_async_connection()
        .await
        .map_err(internal)?;
    let _: () = conn
        .set_ex(key, json, CHALLENGE_TTL_SECONDS)
        .await
        .map_err(internal)?;
    Ok(())
}

async fn take_state<T: for<'de> Deserialize<'de>>(
    state: &AppState,
    key: &str,
) -> Result<T, ApiError> {
    let mut conn = state
        .redis
        .get_multiplexed_async_connection()
        .await
        .map_err(internal)?;
    let raw: Option<String> = conn.get(key).await.map_err(internal)?;
    let raw = raw.ok_or_else(|| {
        ApiError::new(
            StatusCode::BAD_REQUEST,
            "Passkey challenge expired or unknown. Restart the flow.",
        )
    })?;
    // Consume the challenge — replay protection.
    let _: i64 = conn.del(key).await.map_err(internal)?;
    serde_json::from_str(&raw).map_err(internal)
}
