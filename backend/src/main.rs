use anyhow::Result;
use tokio_cron_scheduler::{Job, JobScheduler};
use axum::{
    extract::State,
    http::{
        header::{AUTHORIZATION, CONTENT_TYPE, COOKIE, SET_COOKIE},
        HeaderValue, Method,
    },
    middleware::from_fn_with_state,
    response::Json,
    routing::get,
    Router,
};
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
                let _ = sqlx::query(
                    r#"
                    INSERT INTO balance_snapshots (account_id, balance, as_of_date, currency, balance_usd)
                    SELECT id, current_balance, $1, currency, current_balance
                    FROM accounts
                    ON CONFLICT (account_id, as_of_date) DO NOTHING
                    "#
                )
                .bind(today)
                .execute(&db).await;
            })
        }).expect("Failed to add cron job")
    ).await.expect("Failed to register job");

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
        .nest("/api/auth/passkeys", patrimonio::api::passkeys::public_router());

    let protected = Router::new()
        .nest("/api/accounts", patrimonio::api::accounts::router())
        .nest("/api/institutions", patrimonio::api::institutions::router())
        .nest("/api/fx", patrimonio::api::exchange_rates::router())
        .nest("/api/dashboard", patrimonio::api::dashboard::router())
        .nest("/api/imports", patrimonio::api::imports::router())
        .nest("/api/projections", patrimonio::api::projections::router())
        .nest("/api/tax", patrimonio::api::tax::router())
        .nest("/api/settings", patrimonio::api::settings::router())
        // /api/auth/me, /logout, /change-password live here so that
        // require_auth populates AuthContext for the handlers.
        .nest("/api/auth", patrimonio::api::session::protected_router())
        // Passkey register/manage endpoints — authenticated.
        .nest(
            "/api/auth/passkeys",
            patrimonio::api::passkeys::protected_router(),
        )
        // Coinbase OAuth lives under /api/auth/coinbase historically.
        // Keep the existing URLs (registered with Coinbase) but require
        // an authenticated session.
        .nest("/api/auth", patrimonio::api::auth::router())
        .layer(from_fn_with_state(
            state.clone(),
            patrimonio::api::session::require_auth,
        ));

    let app = public
        .merge(protected)
        .layer(cors)
        .layer(TraceLayer::new_for_http())
        .with_state(state);

    // Start server
    let addr = format!("0.0.0.0:{}", config.port);
    tracing::info!("Listening on {}", addr);
    let listener = tokio::net::TcpListener::bind(&addr).await?;
    axum::serve(listener, app).await?;

    Ok(())
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
        .allow_headers([CONTENT_TYPE, AUTHORIZATION, COOKIE])
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
