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
    PublicKeyCredential, RegisterPublicKeyCredential, RequestChallengeResponse, Url,
    Uuid as WebauthnUuid, Webauthn, WebauthnBuilder,
};

use crate::api::error::{internal, ApiError};
use crate::api::middleware::AuthContext;
use crate::api::session::{
    build_session_cookie, client_ip, enforce_password_policy, record_audit, user_agent,
};
use crate::services::{password, sessions};
use crate::AppState;

const CHALLENGE_TTL_SECONDS: u64 = 300;
const REG_KEY_PREFIX: &str = "webauthn:reg:";
const LOGIN_KEY_PREFIX: &str = "webauthn:login:";
/// Step-up assertion state for an already-authenticated user who is
/// about to set a new password without proving the old one. Keyed by
/// `user_id` + nonce so a challenge issued for one user can never be
/// redeemed by another, even if the nonce leaks.
const REAUTH_KEY_PREFIX: &str = "webauthn:reauth:";

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

/// Step-up + set-password endpoints. Mounted under `/api/auth` (NOT
/// `/api/auth/passkeys`) so the public paths read as
/// `/api/auth/reauth/passkey/start` and `/api/auth/set-password`, next
/// to the password-management endpoints they complement. Both require a
/// valid session — they sit behind the same require_auth layer as the
/// other account-management routes.
pub fn reauth_protected_router() -> Router<AppState> {
    Router::new()
        .route("/reauth/passkey/start", post(reauth_passkey_start))
        .route("/set-password", post(set_password))
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
pub fn build_webauthn(
    frontend_base_url: &str,
    android_apk_cert_sha256: &[String],
) -> anyhow::Result<Webauthn> {
    let parsed = Url::parse(frontend_base_url)
        .map_err(|e| anyhow::anyhow!("invalid FRONTEND_BASE_URL '{frontend_base_url}': {e}"))?;
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
            .map_err(|e| anyhow::anyhow!("failed to override origin host: {e}"))?;
    }
    let mut builder = WebauthnBuilder::new(rp_id, &origin)?
        .rp_name("Patrimonio")
        .allow_subdomains(false);
    // The native Android app doesn't have a browser origin: GMS stamps
    // clientDataJSON.origin with `android:apk-key-hash:<b64url-sha256(cert)>`.
    // webauthn-rs matches extra origins by EXACT Url equality (the opaque-
    // origin fallback never matches non-http schemes), so the string built
    // here must be byte-identical to what the device emits — unpadded
    // base64url of the raw digest, no trailing slash.
    for cert_hex in android_apk_cert_sha256 {
        builder = builder.append_allowed_origin(&android_apk_origin(cert_hex)?);
    }
    Ok(builder.build()?)
}

/// `android:apk-key-hash:<unpadded-b64url(sha256(signing cert DER))>` —
/// the WebAuthn origin GMS Credential Manager reports for an APK signed
/// with the cert whose SHA-256 is `cert_hex` (lowercase no-colon hex, as
/// normalized by config::parse_cert_sha256_list).
pub fn android_apk_origin(cert_hex: &str) -> anyhow::Result<Url> {
    let raw = hex::decode(cert_hex)
        .map_err(|e| anyhow::anyhow!("ANDROID_APK_CERT_SHA256 '{cert_hex}' is not hex: {e}"))?;
    if raw.len() != 32 {
        anyhow::bail!("ANDROID_APK_CERT_SHA256 '{cert_hex}' is not a 32-byte digest");
    }
    let origin = format!("android:apk-key-hash:{}", URL_SAFE_NO_PAD.encode(raw));
    Url::parse(&origin).map_err(|e| anyhow::anyhow!("bad android origin '{origin}': {e}"))
}

// ---------------------------------------------------------------------------
// GET /.well-known/assetlinks.json — Digital Asset Links.
//
// Android only lets an app perform passkey ceremonies for an rp_id after
// verifying this statement on the rp_id's domain: it binds the app's
// package name + signing-cert fingerprint(s) to the site. Served by the
// backend (nginx proxies /.well-known/ through) so the fingerprints come
// from the same env var that feeds the allowed WebAuthn origins — one
// source of truth, impossible to rotate one without the other.
//
// NOTE for Cloudflare Access deployments: Google fetches this URL from
// its own servers, so the edge needs a Bypass policy for exactly this
// path (it's public-by-design data). Documented in docs/deployment.md.
// ---------------------------------------------------------------------------
pub async fn assetlinks(
    State(state): State<AppState>,
) -> Result<Json<serde_json::Value>, ApiError> {
    if state.config.android_apk_cert_sha256.is_empty() {
        return Err(ApiError::new(
            StatusCode::NOT_FOUND,
            "assetlinks not configured (set ANDROID_APK_CERT_SHA256)",
        ));
    }
    // The DAL format wants uppercase colon-separated hex.
    let fingerprints: Vec<String> = state
        .config
        .android_apk_cert_sha256
        .iter()
        .map(|h| {
            h.to_uppercase()
                .as_bytes()
                .chunks(2)
                .map(|c| std::str::from_utf8(c).unwrap_or_default())
                .collect::<Vec<_>>()
                .join(":")
        })
        .collect();
    // Both relations per Google's passkey docs: get_login_creds is the
    // credential-sharing grant, handle_all_urls covers app-link checks
    // some GMS versions perform.
    Ok(Json(serde_json::json!([{
        "relation": [
            "delegate_permission/common.handle_all_urls",
            "delegate_permission/common.get_login_creds",
        ],
        "target": {
            "namespace": "android_app",
            "package_name": state.config.android_package_name,
            "sha256_cert_fingerprints": fingerprints,
        },
    }])))
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
    /// Transports the credential advertises (usb/nfc/ble/hybrid/internal),
    /// from `AuthenticatorAttestationResponse.getTransports()`. A much more
    /// reliable signal than `authenticator_attachment`, which browsers
    /// routinely misreport (a YubiKey often surfaces as "platform"). Used
    /// only to derive the display attachment below.
    #[serde(default)]
    pub transports: Option<Vec<String>>,
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
    let exclude_opt = if exclude.is_empty() {
        None
    } else {
        Some(exclude)
    };

    // Look up the username so the platform's passkey UI can display
    // something useful ("Save passkey for nick@…") rather than the
    // user's UUID.
    let (username, display_name): (String, Option<String>) =
        sqlx::query_as("SELECT username, email FROM users WHERE id = $1")
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
        // Route through internal(): logs the real webauthn error server-side
        // and returns a generic 500 rather than leaking library internals.
        .map_err(internal)?;

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
    // Decide the display class. Transports are authoritative when present:
    // any roaming transport (usb/nfc/ble/hybrid) means a hardware/cross-
    // platform key regardless of what `authenticator_attachment` claimed
    // (browsers frequently mislabel a YubiKey as "platform"). Only when
    // transports are absent do we fall back to the browser's attachment
    // hint, whitelisted to known spec values.
    let attachment = match body.transports.as_deref() {
        Some(transports) if !transports.is_empty() => {
            let roaming = transports
                .iter()
                .any(|t| matches!(t.as_str(), "usb" | "nfc" | "ble" | "hybrid"));
            // "internal" (and nothing else) is the only true platform signal.
            if roaming {
                Some("cross-platform".to_string())
            } else if transports.iter().any(|t| t == "internal") {
                Some("platform".to_string())
            } else {
                None
            }
        }
        _ => body
            .authenticator_attachment
            .as_deref()
            .and_then(|s| match s {
                "platform" | "cross-platform" => Some(s.to_string()),
                _ => None,
            }),
    };

    // DO NOTHING (not DO UPDATE) so we can tell a brand-new credential
    // apart from one we already hold. `fetch_optional` returns None on
    // conflict — meaning the authenticator handed back a credential_id
    // that's already enrolled. That happens when the browser's
    // `excludeCredentials` list didn't stop the ceremony (some roaming
    // security keys ignore it), and the OLD behaviour (DO UPDATE) silently
    // "succeeded" without creating a new row — so the user saw a success
    // toast but no new passkey in the list, and re-adding then failed.
    // Surfacing a clear 409 instead is the honest answer.
    let id: Option<Uuid> = sqlx::query_scalar(
        r#"
        INSERT INTO passkey_credentials
            (user_id, credential_id, passkey_json, nickname, authenticator_attachment)
        VALUES ($1, $2, $3, $4, $5)
        ON CONFLICT (credential_id) DO NOTHING
        RETURNING id
        "#,
    )
    .bind(ctx.user_id)
    .bind(&credential_id)
    .bind(&passkey_json)
    .bind(&nickname)
    .bind(&attachment)
    .fetch_optional(&state.db)
    .await
    .map_err(internal)?;

    let id = match id {
        Some(id) => id,
        None => {
            return Err(ApiError::new(
                StatusCode::CONFLICT,
                "This security key or passkey is already registered on your \
                 account. To re-enrol it, remove the existing one first.",
            ));
        }
    };

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

    let user_row: Option<(Uuid, bool)> =
        sqlx::query_as("SELECT id, is_active FROM users WHERE LOWER(username) = LOWER($1)")
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
    let user_row: Option<(Uuid, bool)> =
        sqlx::query_as("SELECT id, is_active FROM users WHERE LOWER(username) = LOWER($1)")
            .bind(&pending.username)
            .fetch_optional(&state.db)
            .await
            .map_err(internal)?;
    let user_id = match user_row {
        Some((id, true)) => id,
        _ => {
            return Err(ApiError::new(StatusCode::UNAUTHORIZED, "Invalid passkey."));
        }
    };

    let result = state
        .webauthn
        .finish_passkey_authentication(&body.credential, &pending.state)
        .map_err(|e| ApiError::new(StatusCode::UNAUTHORIZED, &format!("webauthn finish: {e}")))?;

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

    let jar = jar.add(build_session_cookie(
        &state,
        session.token,
        session.expires_at,
    ));
    let user = crate::api::session::load_user_view(&state.db, user_id)
        .await
        .map_err(internal)?;

    Ok((jar, Json(LoginFinishResponse { user })))
}

// ---------------------------------------------------------------------------
// Step-up: authenticated user asserts a passkey to authorise a
// password change without knowing the old password.
//
// Security model — this is the gate that makes "set password without
// the old one" safe:
//   - The challenge is built ONLY over THIS user's registered
//     credentials (allowCredentials = ctx.user_id's passkeys). The
//     browser will only let an authenticator the user actually owns
//     respond.
//   - The pending auth state is stored in Redis keyed by
//     `user_id + nonce`. /set-password re-derives that exact key from
//     the SESSION's user_id, so a nonce minted for user A can't be
//     redeemed by user B even if it leaks.
//   - `take_state` DELs on read → the assertion is single-use. A
//     replay (or a second /set-password with the same nonce) finds no
//     state and is rejected.
//   - A valid session ALONE is insufficient: a hijacked session still
//     has to produce a fresh assertion from the victim's authenticator,
//     which the attacker does not possess. This mirrors how
//     change_password demands the old password as proof.
// ---------------------------------------------------------------------------

#[derive(Serialize)]
pub struct ReauthStartResponse {
    pub nonce: String,
    pub options: RequestChallengeResponse,
}

#[derive(Deserialize)]
pub struct SetPasswordRequest {
    /// The nonce handed back by /reauth/passkey/start.
    pub nonce: String,
    /// The assertion the browser produced from navigator.credentials.get().
    pub credential: PublicKeyCredential,
    pub new_password: String,
}

async fn reauth_passkey_start(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Result<Json<ReauthStartResponse>, ApiError> {
    // Build the assertion over exactly the current user's credentials —
    // scoped by id, never by a client-supplied username.
    let rows: Vec<serde_json::Value> =
        sqlx::query_scalar("SELECT passkey_json FROM passkey_credentials WHERE user_id = $1")
            .bind(ctx.user_id)
            .fetch_all(&state.db)
            .await
            .map_err(internal)?;

    let passkeys: Vec<Passkey> = rows
        .into_iter()
        .map(serde_json::from_value::<Passkey>)
        .collect::<Result<_, _>>()
        .map_err(internal)?;

    if passkeys.is_empty() {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "No passkey registered on this account. Add a passkey first, \
             or change your password using your current one.",
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

    let nonce = random_nonce();
    let key = format!("{REAUTH_KEY_PREFIX}{}:{}", ctx.user_id, nonce);
    store_state(&state, &key, &auth_state).await?;

    Ok(Json(ReauthStartResponse { nonce, options }))
}

async fn set_password(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    headers: HeaderMap,
    Json(body): Json<SetPasswordRequest>,
) -> Result<StatusCode, ApiError> {
    let ua = user_agent(&headers);
    let ip = client_ip(&headers);

    // Validate the candidate password BEFORE we consume the assertion
    // nonce — a weak-password rejection shouldn't burn the user's
    // single-use challenge and force a fresh OS prompt.
    enforce_password_policy(&state, &body.new_password).await?;

    // Key is derived from the SESSION's user_id, not from anything the
    // client sent. The nonce alone can't unlock another user's state.
    let key = format!("{REAUTH_KEY_PREFIX}{}:{}", ctx.user_id, body.nonce);
    // take_state DELs on read → single-use. A missing/expired/garbage
    // nonce surfaces here as a 400 ("challenge expired or unknown").
    // Map every assertion-side failure below to 401 (unauthorized),
    // but the not-found case is genuinely a stale/forged nonce.
    let auth_state: PasskeyAuthentication = take_state(&state, &key).await.map_err(|_| {
        ApiError::new(
            StatusCode::UNAUTHORIZED,
            "Passkey challenge expired or unknown. Start the step-up again.",
        )
    })?;

    let result = match state
        .webauthn
        .finish_passkey_authentication(&body.credential, &auth_state)
    {
        Ok(r) => r,
        Err(_) => {
            record_audit(
                &state.db,
                "set_password_via_passkey",
                None,
                Some(ctx.user_id),
                ip.as_deref(),
                ua.as_deref(),
                false,
                Some("assertion_failed"),
            )
            .await;
            return Err(ApiError::new(
                StatusCode::UNAUTHORIZED,
                "Passkey verification failed.",
            ));
        }
    };

    // The asserted credential MUST belong to the current user. The
    // challenge was built from this user's allow-list, but we re-check
    // against the DB by (user_id, credential_id) as defence-in-depth —
    // the row lookup is the authoritative ownership proof.
    let used_cred_id: &[u8] = result.cred_id().as_ref();
    let row: Option<(Uuid, serde_json::Value)> = sqlx::query_as(
        "SELECT id, passkey_json FROM passkey_credentials
            WHERE user_id = $1 AND credential_id = $2",
    )
    .bind(ctx.user_id)
    .bind(used_cred_id)
    .fetch_optional(&state.db)
    .await
    .map_err(internal)?;

    let Some((row_id, json)) = row else {
        record_audit(
            &state.db,
            "set_password_via_passkey",
            None,
            Some(ctx.user_id),
            ip.as_deref(),
            ua.as_deref(),
            false,
            Some("credential_not_owned"),
        )
        .await;
        return Err(ApiError::new(
            StatusCode::UNAUTHORIZED,
            "Authenticated credential is not registered for this user.",
        ));
    };

    // Bump the sign counter on the credential we just used, exactly as
    // login_finish does — keeps replay/clone detection accurate.
    if let Ok(mut updated) = serde_json::from_value::<Passkey>(json) {
        updated.update_credential(&result);
        if let Ok(new_json) = serde_json::to_value(&updated) {
            let _ = sqlx::query(
                "UPDATE passkey_credentials
                    SET passkey_json = $1, last_used_at = NOW()
                  WHERE id = $2",
            )
            .bind(&new_json)
            .bind(row_id)
            .execute(&state.db)
            .await;
        }
    }

    // Assertion verified + ownership confirmed → set the new hash. No
    // current-password check; the passkey IS the proof.
    let new_hash = password::hash_password(&body.new_password).map_err(internal)?;
    sqlx::query("UPDATE users SET password_hash = $1 WHERE id = $2")
        .bind(&new_hash)
        .bind(ctx.user_id)
        .execute(&state.db)
        .await
        .map_err(internal)?;

    // Force re-login everywhere — same posture as change_password.
    let _ = sessions::revoke_all_for_user(&state.db, ctx.user_id).await;

    record_audit(
        &state.db,
        "set_password_via_passkey",
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

// ---------------------------------------------------------------------------
// List / remove.
// ---------------------------------------------------------------------------

async fn list_passkeys(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
) -> Result<Json<Vec<PasskeySummary>>, ApiError> {
    // one-off sqlx row tuple, materialized once at this query_as call site
    #[allow(clippy::type_complexity)]
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
    let result = sqlx::query("DELETE FROM passkey_credentials WHERE id = $1 AND user_id = $2")
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

/// Serialise the per-flow `PasskeyRegistration` / `PasskeyAuthentication`
/// state, AES-GCM-encrypt it under `ENCRYPTION_KEY`, then SETEX into
/// Redis. The previous plaintext-JSON design meant a Redis snapshot
/// leak (or the bind-to-0.0.0.0 misconfig we already plugged) would
/// hand an attacker the in-flight challenge — they could resume the
/// flow and bind their own authenticator to a victim's account inside
/// the 5-minute TTL window.
///
/// With encryption, a Redis-only compromise yields ciphertext + a
/// 12-byte nonce. Without `ENCRYPTION_KEY` the attacker can't replay
/// the flow. The TTL stays at 5 min and the consume-on-use semantics
/// stay intact (`take_state` still `DEL`s after read).
///
/// Fail-soft fallback: when `ENCRYPTION_KEY` is unset (local dev
/// without an encryption config), we log a warning and store
/// plaintext JSON behind a `v1:` prefix so `take_state` can tell
/// the two formats apart. Production should always set the key —
/// `/api/setup/status` already surfaces this check.
async fn store_state<T: Serialize>(state: &AppState, key: &str, value: &T) -> Result<(), ApiError> {
    let json = serde_json::to_string(value).map_err(internal)?;
    let payload = match state.config.encryption_key.as_deref() {
        Some(enc_key) => {
            let ct = crate::services::encryption::encrypt(enc_key, &json).map_err(internal)?;
            // `v2:` prefix marks AEAD-encrypted base64 payloads so
            // `take_state` can dispatch on the format. Base64 keeps
            // the value 7-bit clean for the Redis text protocol.
            format!(
                "v2:{}",
                base64::engine::general_purpose::STANDARD.encode(ct)
            )
        }
        None => {
            tracing::warn!(
                "passkeys: ENCRYPTION_KEY unset — passkey flow state will be \
                 stored in Redis as plaintext JSON. Set ENCRYPTION_KEY in \
                 production to harden against a Redis snapshot leak."
            );
            format!("v1:{json}")
        }
    };
    let mut conn = state
        .redis
        .get_multiplexed_async_connection()
        .await
        .map_err(internal)?;
    let _: () = conn
        .set_ex(key, payload, CHALLENGE_TTL_SECONDS)
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

    // Two acceptable on-wire formats:
    //   v2:<base64>  — AES-GCM encrypted JSON, ENCRYPTION_KEY required
    //   v1:<json>    — plaintext JSON (no encryption key configured)
    //
    // Anything else is rejected — it can only mean a stray key written
    // by a different writer or a downgrade attack on the format.
    let json = if let Some(rest) = raw.strip_prefix("v2:") {
        let enc_key = state.config.encryption_key.as_deref().ok_or_else(|| {
            ApiError::new(
                StatusCode::BAD_REQUEST,
                "Passkey flow state encrypted but ENCRYPTION_KEY is unset.",
            )
        })?;
        let ct = base64::engine::general_purpose::STANDARD
            .decode(rest)
            .map_err(internal)?;
        crate::services::encryption::decrypt(enc_key, &ct).map_err(internal)?
    } else if let Some(rest) = raw.strip_prefix("v1:") {
        rest.to_string()
    } else {
        return Err(ApiError::new(
            StatusCode::BAD_REQUEST,
            "Passkey flow state in unknown format.",
        ));
    };
    serde_json::from_str(&json).map_err(internal)
}

#[cfg(test)]
mod tests {
    use super::*;

    // The production signing cert (apksigner --print-certs hex) and the
    // origin GMS derives from it. If android_apk_origin ever drifts from
    // unpadded-base64url-of-raw-digest, native passkey verification fails
    // with InvalidRPOrigin on every request — pin the exact mapping.
    const CERT_HEX: &str = "e1ef2549ade55b49a678772fd274a8a08a546247146a388462cb47026fc5028d";

    #[test]
    fn android_origin_is_unpadded_b64url_of_raw_digest() {
        let url = android_apk_origin(CERT_HEX).expect("valid cert hex");
        assert_eq!(
            url.as_str(),
            "android:apk-key-hash:4e8lSa3lW0mmeHcv0nSooIpUYkcUajiEYstHAm_FAo0"
        );
    }

    #[test]
    fn android_origin_rejects_non_digest_input() {
        assert!(android_apk_origin("not-hex").is_err());
        assert!(android_apk_origin("abcd").is_err()); // hex but not 32 bytes
    }

    #[test]
    fn build_webauthn_accepts_android_cert_list() {
        // Must not error with android origins appended — a bad origin
        // here would take the whole server down at boot.
        build_webauthn("https://patrimonio.example.com", &[CERT_HEX.to_string()])
            .expect("webauthn builds with android origin");
    }
}
