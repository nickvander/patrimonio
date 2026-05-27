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

use crate::api::session::AuthContext;
use crate::services::realtime::RealtimeEvent;
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

async fn run_socket(
    mut socket: WebSocket,
    realtime: crate::services::realtime::Realtime,
    user_id: uuid::Uuid,
) {
    let mut rx = realtime.subscribe(user_id).await;
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
