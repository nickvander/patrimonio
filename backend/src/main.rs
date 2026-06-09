use anyhow::Result;
use tokio_cron_scheduler::{Job, JobScheduler};
use axum::{
    extract::{ConnectInfo, State},
    http::{
        header::{AUTHORIZATION, CONTENT_TYPE, COOKIE, SET_COOKIE},
        HeaderValue, Method,
    },
    middleware::{from_fn_with_state, Next},
    response::{Json, Response},
    routing::get,
    Router,
};
use std::net::SocketAddr;
use serde::Serialize;
use sqlx::postgres::PgPoolOptions;
use std::sync::Arc;
use tower_http::cors::{AllowOrigin, CorsLayer};
use tower_http::trace::TraceLayer;
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt};

use patrimonio::{config::AppConfig, AppState};

#[tokio::main]
async fn main() -> Result<()> {
    // Initialize tracing (logging)
    tracing_subscriber::registry()
        .with(tracing_subscriber::EnvFilter::try_from_default_env()
            .unwrap_or_else(|_| "patrimonio=debug,tower_http=debug".into()))
        .with(tracing_subscriber::fmt::layer())
        .init();

    // Load configuration
    dotenvy::dotenv().ok();
    let config = AppConfig::from_env()?;

    tracing::info!("Starting Patrimonio API server");

    // Loud warning for the dev-default DB password. Local-dev compose
    // ships with POSTGRES_PASSWORD=patrimonio so the stack comes up
    // one-command; a production deploy that forgot to override gets
    // caught here on the first log scrape.
    if config.database_url.contains(":patrimonio@") {
        tracing::warn!(
            "POSTGRES_PASSWORD is set to the local-dev default. \
             OVERRIDE THIS in any non-dev deployment — set POSTGRES_PASSWORD \
             in your .env and rebuild the postgres volume."
        );
    }
    if !config.cookie_secure && !config.frontend_base_url.starts_with("http://localhost")
        && !config.frontend_base_url.starts_with("http://127.0.0.1") {
        tracing::warn!(
            "COOKIE_SECURE is false but FRONTEND_BASE_URL ({}) is not localhost — \
             session cookies will travel unencrypted. Set COOKIE_SECURE=true.",
            config.frontend_base_url
        );
    }

    // Connect to PostgreSQL
    let db = PgPoolOptions::new()
        .max_connections(config.database_max_connections)
        .connect(&config.database_url)
        .await?;

    // Run database migrations
    tracing::info!("Running database migrations...");
    sqlx::migrate!("./migrations")
        .run(&db)
        .await?;
    tracing::info!("Migrations complete");

    // Connect to Redis
    let redis_client = redis::Client::open(config.redis_url.clone())?;

    // Build the WebAuthn relying-party config from the frontend base
    // URL. We refuse to come up without it — a misconfigured rp_id
    // silently breaks every passkey enrolment, and we'd rather fail
    // fast at boot.
    let webauthn = patrimonio::api::passkeys::build_webauthn(&config.frontend_base_url)?;

    // Build shared state
    let state = AppState {
        db: db.clone(),
        redis: redis_client,
        config: Arc::new(config.clone()),
        webauthn: Arc::new(webauthn),
        realtime: patrimonio::services::realtime::Realtime::new(),
    };
    let cors = build_cors_layer(&config.allowed_origins);

    // Initialize Cron Scheduler for daily balance snapshots
    let sched = JobScheduler::new().await.expect("Failed to create cron scheduler");
    let cron_db = db.clone();

    sched.add(
        Job::new_async("0 0 0 * * *", move |_uuid, mut _l| {
            let db = cron_db.clone();
            Box::pin(async move {
                tracing::info!("Running daily balance snapshot cron...");
                let today = chrono::Utc::now().naive_utc().date();
                // Cron runs without a session — pull user_id straight
                // from the source account so each snapshot inherits its
                // owner without any per-user iteration.
                // balance_usd MUST be FX-converted, not a copy of the native
                // balance — otherwise an MXN account (e.g. a ~$890k MXN cetes
                // portfolio) lands in net worth as ~$890k USD, a ~17x
                // overstatement. Mirror the create-account path: divide a MXN
                // balance by the latest USD→MXN rate; pass USD through; default
                // other currencies 1:1 (no rates yet).
                let _ = sqlx::query(
                    r#"
                    INSERT INTO balance_snapshots (account_id, balance, as_of_date, currency, balance_usd, user_id)
                    SELECT a.id, a.current_balance, $1, a.currency,
                           CASE
                             WHEN a.currency = 'MXN' AND r.rate IS NOT NULL AND r.rate <> 0
                                  THEN ROUND(a.current_balance / r.rate, 2)
                             ELSE a.current_balance
                           END,
                           a.user_id
                    FROM accounts a
                    LEFT JOIN LATERAL (
                        SELECT rate FROM exchange_rates
                        WHERE base_currency = 'USD' AND target_currency = 'MXN'
                        ORDER BY recorded_at DESC LIMIT 1
                    ) r ON TRUE
                    ON CONFLICT (account_id, as_of_date) DO NOTHING
                    "#
                )
                .bind(today)
                .execute(&db).await;
            })
        }).expect("Failed to add cron job")
    ).await.expect("Failed to register job");

    // Nightly holdings price refresh — re-price every manual account's holdings
    // from Yahoo and recompute balances, so a live-priced position (e.g. an HSA
    // fund) tracks the market without waiting for a dashboard load. Runs at
    // 23:00 UTC, AFTER US market close (~21:00 UTC) and BEFORE the midnight
    // snapshot above, so that snapshot captures the day's closing values.
    // Schedule is overridable via HOLDINGS_REFRESH_CRON; set it to "off" to
    // disable (e.g. to spare Yahoo on a machine with no holdings).
    // Unset OR empty (e.g. a blank compose passthrough) falls back to the
    // default schedule — never an empty string, which is an invalid cron.
    let holdings_cron = std::env::var("HOLDINGS_REFRESH_CRON")
        .ok()
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "0 0 23 * * *".to_string());
    if holdings_cron.trim().eq_ignore_ascii_case("off") {
        tracing::info!("Nightly holdings refresh disabled (HOLDINGS_REFRESH_CRON=off)");
    } else {
        let refresh_db = db.clone();
        sched
            .add(
                Job::new_async(holdings_cron.as_str(), move |_uuid, mut _l| {
                    let db = refresh_db.clone();
                    Box::pin(async move {
                        tracing::info!("Running nightly holdings price refresh...");
                        let s = patrimonio::services::holdings::refresh_all_prices(&db).await;
                        tracing::info!(
                            "Nightly holdings refresh complete: {} symbols priced across {} accounts",
                            s.symbols_priced, s.accounts
                        );
                    })
                })
                .expect("Failed to add holdings-refresh cron job"),
            )
            .await
            .expect("Failed to register holdings-refresh job");
    }

    sched.start().await.expect("Failed to start scheduler");

    // ---- routing ----
    //
    // Public routes are open to the world:
    //   - liveness/version probes
    //   - the bootstrap/login/status endpoints that the unauthenticated
    //     UI needs to render its login screen
    //   - the setup config status (used by the same screen)
    //
    // Everything else is gated by `session::require_auth`, including
    // the existing Coinbase OAuth handlers — initiating an OAuth link
    // is a sensitive, account-binding operation and must be done by a
    // logged-in user.

    let public = Router::new()
        .route("/api/health", get(health))
        .route("/api/version", get(version))
        .nest("/api/setup", patrimonio::api::setup::router())
        .nest("/api/auth", patrimonio::api::session::public_router())
        // Passkey login (discoverable; no session needed to start the
        // ceremony). Register endpoints are mounted under the
        // protected router below.
        .nest("/api/auth/passkeys", patrimonio::api::passkeys::public_router())
        // Plaid webhooks. Public because Plaid POSTs with no session
        // cookie. The handler itself refuses to do anything unless a
        // signed `Plaid-Verification` header is present — see
        // institutions::plaid_webhook for the full guard.
        .nest("/api/institutions", patrimonio::api::institutions::webhook_router());

    // Two-tier protected routing for multi-user roles.
    //
    // `business` routes touch financial / business data. Every
    // mutating method (POST/PUT/PATCH/DELETE) on these routes is
    // gated by `require_owner` so read-only users get 403 instead
    // of silently corrupting state.
    //
    // `account_mgmt` routes are auth + own-session management:
    // logout, change-password, passkeys for the current user,
    // recovery codes, totp enroll/verify. Every authenticated user
    // — owner or read-only — must be able to manage their own
    // session, so `require_owner` does NOT apply here.
    //
    // Invite minting lives in `business` because creating an
    // invite materialises a new user; a read-only user spinning
    // up unlimited new accounts would defeat the role split.
    let business = Router::new()
        .nest("/api/accounts", patrimonio::api::accounts::router())
        .nest("/api/institutions", patrimonio::api::institutions::router())
        .nest("/api/fx", patrimonio::api::exchange_rates::router())
        .nest("/api/dashboard", patrimonio::api::dashboard::router())
        .nest("/api/imports", patrimonio::api::imports::router())
        .nest("/api/projections", patrimonio::api::projections::router())
        .nest("/api/tax", patrimonio::api::tax::router())
        .nest("/api/settings", patrimonio::api::settings::router())
        .nest("/api/loans", patrimonio::api::loans::router())
        .nest("/api/auth/invites", patrimonio::api::invites::router())
        // Realtime WS lives here because GETs only — read-only
        // users can subscribe to their own invalidations just like
        // owners. require_owner lets GET/HEAD/OPTIONS through.
        .nest("/api/realtime", patrimonio::api::realtime::router())
        // require_owner sits INSIDE require_auth so AuthContext is
        // populated; from_fn applies bottom-up, so this layer runs
        // AFTER the auth layer set up below at the merge point.
        .layer(axum::middleware::from_fn(
            patrimonio::api::session::require_owner,
        ));

    let account_mgmt = Router::new()
        // /api/auth/me, /logout, /change-password, /totp/*, /sessions/*
        .nest("/api/auth", patrimonio::api::session::protected_router())
        // Passkey register/manage endpoints for the caller's own
        // credentials. A read-only user managing their own passkey
        // doesn't escalate them — they still get 403 from the
        // business routes.
        .nest(
            "/api/auth/passkeys",
            patrimonio::api::passkeys::protected_router(),
        )
        // Coinbase OAuth lives under /api/auth/coinbase historically.
        // Initiating an OAuth link MUTATES (writes the new
        // institution row), so when roles ship this should arguably
        // require_owner — but we keep it here because the existing
        // OAuth redirect URI is publicly registered with Coinbase
        // and rewiring is its own sprint. The eventual
        // exchange-token write is on /api/institutions which IS
        // owner-gated, so the worst a read-only user can do is
        // start an OAuth dance that gets 403'd at the final
        // callback. Worth revisiting.
        .nest("/api/auth", patrimonio::api::auth::router());

    let protected = business
        .merge(account_mgmt)
        // Inner-to-outer: require_owner runs FIRST per-route via
        // business.layer above; then require_auth populates
        // AuthContext; then require_csrf_header gates mutating
        // methods. axum applies layers in reverse so the LAST
        // .layer() is the OUTERMOST middleware.
        .layer(from_fn_with_state(
            state.clone(),
            patrimonio::api::session::require_auth,
        ))
        .layer(axum::middleware::from_fn(
            patrimonio::api::session::require_csrf_header,
        ));

    let app = public
        .merge(protected)
        // App-wide request body cap so a single oversized request can't
        // exhaust memory on this single-instance deploy. The import-upload
        // route raises its own limit to 100 MB via a route-level
        // DefaultBodyLimit (the innermost layer wins), so bulk statement
        // uploads are unaffected; every other endpoint is held to 2 MB.
        .layer(axum::extract::DefaultBodyLimit::max(2 * 1024 * 1024))
        // Sanitise proxy-set headers BEFORE anything else looks at the
        // request. If the TCP peer isn't in TRUSTED_PROXY_CIDRS we strip
        // X-Forwarded-For + X-Real-IP so downstream rate-limiting can't
        // be evaded by a malicious client setting the headers itself.
        // Has to be from_fn (not from_fn_with_state) because the layer
        // applies before the State extractor would resolve.
        .layer(from_fn_with_state(
            state.clone(),
            sanitize_forwarded_headers,
        ))
        .layer(cors)
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    // Start server. `into_make_service_with_connect_info::<SocketAddr>()`
    // is required so the sanitize_forwarded_headers layer can read the
    // TCP peer's address via the ConnectInfo extractor.
    let addr = format!("0.0.0.0:{}", config.port);
    tracing::info!("Listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await?;

    Ok(())
}

/// Strip X-Forwarded-For and X-Real-IP from requests whose TCP peer
/// isn't in `state.config.trusted_proxy_cidrs`. Subsequent handlers
/// can then unconditionally trust those headers when present — the
/// trust check has been moved here, at the edge of the process.
///
/// Empty trusted list: every peer is untrusted, so XFF is always
/// stripped. Local dev with no upstream proxy stays in this state by
/// default, which matches the historical behavior (XFF was honored
/// indiscriminately before; now it's ignored, which is safer).
async fn sanitize_forwarded_headers(
    State(state): State<patrimonio::AppState>,
    ConnectInfo(peer): ConnectInfo<SocketAddr>,
    mut req: axum::extract::Request,
    next: Next,
) -> Response {
    let trusted = state
        .config
        .trusted_proxy_cidrs
        .iter()
        .any(|cidr| cidr.contains(&peer.ip()));
    if !trusted {
        let headers = req.headers_mut();
        headers.remove("x-forwarded-for");
        headers.remove("x-real-ip");
    }
    next.run(req).await
}

fn build_cors_layer(allowed_origins: &[String]) -> CorsLayer {
    // Credentialed cookies require an explicit (non-wildcard) origin
    // and `Access-Control-Allow-Credentials: true`. We refuse `*` here
    // — if you want true wildcard, you have to disable auth too.
    let origins: Vec<HeaderValue> = allowed_origins
        .iter()
        .filter(|origin| *origin != "*")
        .filter_map(|origin| origin.parse::<HeaderValue>().ok())
        .collect();

    if origins.is_empty() {
        tracing::warn!(
            "ALLOWED_ORIGINS produced no usable values; CORS will reject all browser origins. \
             Set ALLOWED_ORIGINS to your frontend URL(s)."
        );
    }

    CorsLayer::new()
        .allow_origin(AllowOrigin::list(origins))
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::PATCH,
            Method::DELETE,
        ])
        .allow_headers([
            CONTENT_TYPE,
            AUTHORIZATION,
            COOKIE,
            // X-Requested-With is the CSRF defence-in-depth header
            // required by the require_csrf_header middleware on every
            // mutating route. CORS has to allow-list it explicitly
            // because it's a non-simple header.
            axum::http::header::HeaderName::from_static("x-requested-with"),
        ])
        .expose_headers([SET_COOKIE])
        .allow_credentials(true)
}

/// Health check endpoint
async fn health(State(state): State<AppState>) -> Json<HealthResponse> {
    let db_ok = sqlx::query("SELECT 1")
        .execute(&state.db)
        .await
        .is_ok();

    Json(HealthResponse {
        status: if db_ok { "ok" } else { "degraded" }.to_string(),
        database: if db_ok { "connected" } else { "disconnected" }.to_string(),
    })
}

/// Version endpoint
async fn version() -> Json<VersionResponse> {
    Json(VersionResponse {
        version: env!("CARGO_PKG_VERSION").to_string(),
        name: "patrimonio".to_string(),
    })
}

#[derive(Serialize)]
struct HealthResponse {
    status: String,
    database: String,
}

#[derive(Serialize)]
struct VersionResponse {
    version: String,
    name: String,
}
