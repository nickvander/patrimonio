//! Unified notifications center — the bell panel's inbox.
//!
//! `GET /` lists the caller's `user_notifications` rows (all sources in
//! one list: FX alert crossings, import-staleness reminders, loan payment
//! due reminders) plus the true unread count for the bell badge. Loan due
//! reminders are generated-on-read here (see
//! `services::notifications::record_loan_due_notifications`) — the due
//! window moves with the calendar, so listing the inbox is the natural
//! moment to materialise them; the dedupe key makes that idempotent.
//!
//! `POST /read` stamps `read_at` — either specific ids or everything —
//! so read state follows the account across devices (the old bell kept
//! it in localStorage, where a phone and a laptop disagreed forever).
//!
//! Mounted WITHOUT `require_owner` (next to the account-management
//! routes): notifications are strictly self-scoped (`WHERE user_id = $1`
//! throughout), and a read-only member must be able to mark their own
//! inbox read — that mutates nothing shared.

use axum::{
    extract::{Extension, Query, State},
    routing::{get, post},
    Json, Router,
};
use serde::{Deserialize, Serialize};
use sqlx::Row;
use uuid::Uuid;

use crate::api::session::{internal, ApiError, AuthContext};
use crate::services::notifications::record_loan_due_notifications;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new()
        .route("/", get(list_notifications))
        .route("/read", post(mark_read))
}

#[derive(Serialize)]
struct NotificationView {
    id: String,
    kind: String,
    title: String,
    body: String,
    created_at: String,
    /// RFC3339 timestamp, or null while unread. The client only checks
    /// null-ness; the timestamp is kept for future "read on…" surfaces.
    read_at: Option<String>,
    /// Optional deep-link subject ("loan" + loan id, …). Null for kinds
    /// whose deep link is derivable from `kind` alone (fx_alert,
    /// import_stale).
    link_kind: Option<String>,
    link_id: Option<String>,
}

#[derive(Serialize)]
struct NotificationsResponse {
    notifications: Vec<NotificationView>,
    /// Unread total over the WHOLE inbox, not just the returned page —
    /// the bell badge must not undercount when history exceeds `limit`.
    unread_count: i64,
}

#[derive(Deserialize)]
struct ListQuery {
    /// Page size; clamped 1..=200 (default 100) so a hostile ?limit
    /// can't dump the whole table in one response.
    #[serde(default)]
    limit: Option<i64>,
}

async fn list_notifications(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Query(q): Query<ListQuery>,
) -> Result<Json<NotificationsResponse>, ApiError> {
    // Generated-on-read: materialise loan due reminders inside the lead
    // window before listing, so they appear in the same inbox with real
    // read state. Idempotent via dedupe_key.
    record_loan_due_notifications(&state.db, ctx.user_id)
        .await
        .map_err(internal)?;

    let limit = q.limit.unwrap_or(100).clamp(1, 200);

    let rows = sqlx::query(
        "SELECT id, kind, title, body, created_at, read_at, link_kind, link_id \
         FROM user_notifications \
         WHERE user_id = $1 \
         ORDER BY created_at DESC, id DESC \
         LIMIT $2",
    )
    .bind(ctx.user_id)
    .bind(limit)
    .fetch_all(&state.db)
    .await
    .map_err(internal)?;

    let unread_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM user_notifications WHERE user_id = $1 AND read_at IS NULL",
    )
    .bind(ctx.user_id)
    .fetch_one(&state.db)
    .await
    .map_err(internal)?;

    let mut notifications = Vec::with_capacity(rows.len());
    for r in rows {
        notifications.push(NotificationView {
            id: r.try_get::<Uuid, _>("id").map_err(internal)?.to_string(),
            kind: r.try_get("kind").map_err(internal)?,
            title: r.try_get("title").map_err(internal)?,
            body: r.try_get("body").map_err(internal)?,
            created_at: r
                .try_get::<chrono::DateTime<chrono::Utc>, _>("created_at")
                .map_err(internal)?
                .to_rfc3339(),
            read_at: r
                .try_get::<Option<chrono::DateTime<chrono::Utc>>, _>("read_at")
                .map_err(internal)?
                .map(|d| d.to_rfc3339()),
            link_kind: r.try_get("link_kind").map_err(internal)?,
            link_id: r.try_get("link_id").map_err(internal)?,
        });
    }

    Ok(Json(NotificationsResponse {
        notifications,
        unread_count,
    }))
}

#[derive(Deserialize)]
struct MarkReadRequest {
    /// Specific notification ids to mark read. Ignored when `all` is set.
    #[serde(default)]
    ids: Vec<Uuid>,
    /// Mark the whole inbox read (the "opened the panel" case).
    #[serde(default)]
    all: bool,
}

#[derive(Serialize)]
struct MarkReadResponse {
    /// Rows this call actually transitioned unread → read.
    marked: u64,
    /// Remaining unread total, so the client can re-badge without a
    /// second round-trip.
    unread_count: i64,
}

async fn mark_read(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    Json(payload): Json<MarkReadRequest>,
) -> Result<Json<MarkReadResponse>, ApiError> {
    // Clamp the id list like every other list-shaped input: a hostile
    // 10⁶-element array shouldn't turn into a giant ANY() scan.
    if payload.ids.len() > 500 {
        return Err(ApiError::new(
            axum::http::StatusCode::BAD_REQUEST,
            "Too many ids (max 500)",
        ));
    }

    let marked = if payload.all {
        sqlx::query(
            "UPDATE user_notifications SET read_at = NOW() \
             WHERE user_id = $1 AND read_at IS NULL",
        )
        .bind(ctx.user_id)
        .execute(&state.db)
        .await
        .map_err(internal)?
        .rows_affected()
    } else if payload.ids.is_empty() {
        0
    } else {
        // user_id scoping means ids belonging to someone else silently
        // no-op — no cross-tenant probe surface.
        sqlx::query(
            "UPDATE user_notifications SET read_at = NOW() \
             WHERE user_id = $1 AND read_at IS NULL AND id = ANY($2)",
        )
        .bind(ctx.user_id)
        .bind(&payload.ids)
        .execute(&state.db)
        .await
        .map_err(internal)?
        .rows_affected()
    };

    let unread_count: i64 = sqlx::query_scalar(
        "SELECT COUNT(*) FROM user_notifications WHERE user_id = $1 AND read_at IS NULL",
    )
    .bind(ctx.user_id)
    .fetch_one(&state.db)
    .await
    .map_err(internal)?;

    Ok(Json(MarkReadResponse {
        marked,
        unread_count,
    }))
}
