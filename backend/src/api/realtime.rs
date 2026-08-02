//! GET /api/realtime/ws — authenticated websocket that streams
//! per-user `RealtimeEvent`s. Frontend's `RealtimeService` subscribes
//! and routes events into the dashboard's existing reload paths.
//!
//! Auth: the route is mounted on the protected router so
//! `require_auth` has already validated the cookie and populated
//! `AuthContext` by the time `ws_handler` runs. The websocket
//! upgrade carries the same cookies as the original GET, so a
//! handshake from a logged-out tab is rejected with 401 before
//! the upgrade.
//!
//! The handler doesn't actively respond to client messages — the
//! channel is one-way, server → client. It does read & discard
//! inbound frames (browser keep-alive pings) so the socket stays
//! alive on the WS layer.

use axum::{
    extract::{
        ws::{Message, WebSocket, WebSocketUpgrade},
        Extension, State,
    },
    response::Response,
    routing::get,
    Router,
};
use tokio::sync::broadcast::error::RecvError;

use crate::api::middleware::AuthContext;
use crate::AppState;

pub fn router() -> Router<AppState> {
    Router::new().route("/ws", get(ws_handler))
}

async fn ws_handler(
    State(state): State<AppState>,
    Extension(ctx): Extension<AuthContext>,
    ws: WebSocketUpgrade,
) -> Response {
    let realtime = state.realtime.clone();
    let user_id = ctx.user_id;
    ws.on_upgrade(move |socket| run_socket(socket, realtime, user_id))
}

/// How often the server emits a `heartbeat` frame on an otherwise idle
/// socket. Two jobs: it lets the client's watchdog distinguish "nothing
/// happened" from "this socket is dead" (see `RealtimeEvent::Heartbeat`),
/// and a failed `send` is how *we* notice a client that vanished without
/// a close frame, so the task and its broadcast subscription get dropped.
///
/// 30s is comfortably under any intermediary idle timeout (prod nginx uses
/// `proxy_read_timeout 3600s`) and gives the client's 90s watchdog three
/// chances before it reconnects.
const HEARTBEAT_INTERVAL: std::time::Duration = std::time::Duration::from_secs(30);

/// Pre-serialized `RealtimeEvent::Heartbeat`. Pinned by a unit test so it
/// can't drift from the enum's serde representation.
const HEARTBEAT_FRAME: &str = r#"{"event":"heartbeat"}"#;

async fn run_socket(
    mut socket: WebSocket,
    realtime: crate::services::realtime::Realtime,
    user_id: uuid::Uuid,
) {
    let mut rx = realtime.subscribe(user_id).await;
    let mut heartbeat = tokio::time::interval(HEARTBEAT_INTERVAL);
    // `interval` fires its first tick immediately; drop it so a fresh
    // socket doesn't open with a redundant frame.
    heartbeat.tick().await;
    loop {
        tokio::select! {
            // Pump server-side events to the client.
            event = rx.recv() => {
                match event {
                    Ok(ev) => {
                        let payload = match serde_json::to_string(&ev) {
                            Ok(s) => s,
                            Err(_) => continue,
                        };
                        if socket.send(Message::Text(payload.into())).await.is_err() {
                            // Client gone. Drop the socket.
                            return;
                        }
                    }
                    Err(RecvError::Lagged(_)) => {
                        // The broadcast buffer overflowed for this
                        // subscriber. Tell the client to do a full
                        // refetch — it's a coarse but always-correct
                        // recovery.
                        let _ = socket
                            .send(Message::Text("{\"event\":\"resync\"}".into()))
                            .await;
                        continue;
                    }
                    Err(RecvError::Closed) => return,
                }
            }
            // Liveness tick on an idle socket. A send error means the
            // client is gone (dropped connection, no close frame), which
            // is the only way we learn about it while nothing is being
            // published — drop the socket and its subscription.
            _ = heartbeat.tick() => {
                if socket.send(Message::Text(HEARTBEAT_FRAME.into())).await.is_err() {
                    return;
                }
            }
            // Drain inbound client messages (pings, browser tab
            // close). We don't act on text/binary frames — the
            // channel is server-push only.
            msg = socket.recv() => {
                match msg {
                    Some(Ok(Message::Close(_))) | None => return,
                    Some(Ok(_)) => continue,
                    Some(Err(_)) => return,
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::services::realtime::RealtimeEvent;

    /// The client's liveness watchdog keys off this exact frame, so the
    /// constant and the enum's serde representation must not drift apart.
    #[test]
    fn heartbeat_frame_matches_the_event_serialization() {
        assert_eq!(
            serde_json::to_string(&RealtimeEvent::Heartbeat).unwrap(),
            HEARTBEAT_FRAME
        );
    }

    /// Three heartbeats fit inside the client's 90s watchdog window, so a
    /// single dropped frame can't trigger a spurious reconnect.
    #[test]
    fn heartbeat_interval_leaves_the_client_margin() {
        assert!(HEARTBEAT_INTERVAL.as_secs() * 3 <= 90);
    }
}
