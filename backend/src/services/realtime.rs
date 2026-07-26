//! Per-user websocket broadcast hub.
//!
//! `Realtime` holds a `RwLock<HashMap<user_id, broadcast::Sender>>`.
//! Any handler that mutates a user's data calls
//! `Realtime::publish(user_id, event)` after the write commits; every
//! websocket the user has open (one per browser tab) receives the
//! event and the dashboard refetches the relevant slice.
//!
//! Why broadcast (vs mpsc): a user can have N tabs open. Each tab is
//! its own subscriber. `broadcast` fans the event to all subscribers
//! with O(1) per send. Capacity is 64 — enough for short bursts
//! (a sync emits ~4 events; multiple syncs in a minute are rare); a
//! lagging subscriber gets a `RecvError::Lagged` and just refetches
//! everything, which is the correct recovery anyway.
//!
//! Why per-user-keyed instead of one global channel: a user must
//! never receive another user's invalidations. Routing by user_id
//! at publish time is dead simple and matches the existing
//! ownership predicate model everywhere else.
//!
//! Future: when a second API instance ships, swap the in-process
//! map for a Redis pub/sub backplane keyed `realtime:<user_id>`.
//! The publish/subscribe surface stays the same.

use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::{broadcast, RwLock};
use uuid::Uuid;

/// Coarse event vocabulary. The client doesn't get the new data
/// inline — it gets a "go refetch X" prompt and uses its existing
/// REST flows to actually load the rows. Keeps payloads tiny and
/// avoids re-implementing every response shape over the websocket.
#[derive(Clone, Debug, serde::Serialize)]
#[serde(tag = "event", rename_all = "snake_case")]
pub enum RealtimeEvent {
    /// One or more transactions inserted/updated/deleted. The
    /// dashboard reloads `/dashboard/transactions` + `/dashboard/
    /// overview` so balance + cash-flow widgets reflect the delta.
    TransactionsChanged,
    /// Account list changed (new institution linked, account
    /// renamed, balance edited). Reload `/accounts` + the
    /// overview.
    AccountsChanged,
    /// FX rate refresh. Reload `/fx/latest/USD/MXN` and recompute
    /// reporting-currency views.
    FxRatesUpdated,
    /// A specific institution finished syncing. The name lets the
    /// UI show a short toast ("Chase synced — 3 new transactions")
    /// instead of just a silent refresh.
    SyncComplete { institution: String },
    /// Server→client liveness tick. Carries no data and is **never
    /// published through the hub** — the socket loop emits it on a timer
    /// (see `api::realtime::HEARTBEAT_INTERVAL`). It exists so the client
    /// can tell "quiet" from "dead": a websocket dropped by a sleeping
    /// device or a NAT/proxy timeout often produces no close frame, so
    /// without a periodic frame the client sits on a half-open socket
    /// forever, never reconnecting and never seeing another push.
    ///
    /// It's a text frame rather than a WebSocket Ping because browsers do
    /// not expose ping/pong to JavaScript — a Ping would keep the
    /// connection warm but stay invisible to the web client's watchdog.
    Heartbeat,
}

/// Cloneable handle to the hub. Cheap to clone — only the inner
/// `Arc<RwLock<…>>` is copied. Stored in `AppState`.
#[derive(Clone)]
pub struct Realtime {
    inner: Arc<RwLock<HashMap<Uuid, broadcast::Sender<RealtimeEvent>>>>,
}

impl Realtime {
    pub fn new() -> Self {
        Self {
            inner: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    /// Get-or-create the per-user broadcast channel and return a
    /// receiver. Used by the websocket handler when a new tab
    /// connects.
    pub async fn subscribe(&self, user_id: Uuid) -> broadcast::Receiver<RealtimeEvent> {
        // Fast path: channel exists.
        if let Some(tx) = self.inner.read().await.get(&user_id) {
            return tx.subscribe();
        }
        // Slow path: write-lock and create.
        let mut guard = self.inner.write().await;
        let tx = guard
            .entry(user_id)
            .or_insert_with(|| broadcast::channel(64).0);
        tx.subscribe()
    }

    /// Publish an event to every subscriber for `user_id`. Silent
    /// no-op when nobody is listening — that's the common case
    /// (no tabs open). Callers fire-and-forget after their write
    /// commits.
    pub async fn publish(&self, user_id: Uuid, event: RealtimeEvent) {
        let guard = self.inner.read().await;
        if let Some(tx) = guard.get(&user_id) {
            // send() returns the count of subscribers or
            // SendError(_) when there are zero. We don't care
            // about either — fire and forget.
            let _ = tx.send(event);
        }
    }
}

impl Default for Realtime {
    fn default() -> Self {
        Self::new()
    }
}
