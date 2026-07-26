import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

import 'api_platform.dart';
import 'realtime_socket.dart';

/// Coarse server-pushed events. Mirrors `services::realtime::RealtimeEvent`
/// in the backend — payloads are intentionally tiny ("go refetch
/// transactions") rather than the actual data, so the existing REST
/// endpoints remain the source of truth.
enum RealtimeEventType {
  transactionsChanged,
  accountsChanged,
  fxRatesUpdated,
  syncComplete,

  /// Server liveness tick (see `RealtimeEvent::Heartbeat` in the backend).
  /// Carries no data — consumers must NOT refetch on it. Its only job is
  /// to reset [RealtimeService]'s watchdog.
  heartbeat,
  /// Server signalled the per-user broadcast buffer overflowed for
  /// this subscriber — client should refetch everything as the
  /// always-correct recovery.
  resync,
  unknown,
}

class RealtimeEvent {
  final RealtimeEventType type;
  /// Optional institution name for `syncComplete`. Empty string for
  /// every other event type.
  final String institution;

  const RealtimeEvent({
    required this.type,
    this.institution = '',
  });
}

/// Decode one server frame into a [RealtimeEvent]; null when the payload
/// isn't JSON we can read (logged, then ignored — the connection is fine).
///
/// Free function so the wire contract is unit-testable without a socket.
/// The mapping matters more than it looks: an event name that falls
/// through to [RealtimeEventType.unknown] triggers a FULL dashboard reload
/// in the consumer, so a missing case here (notably `heartbeat`, which
/// arrives every 30s) turns a liveness tick into a refetch storm.
RealtimeEvent? parseRealtimeFrame(String raw) {
  try {
    final m = json.decode(raw) as Map<String, dynamic>;
    final type = switch (m['event']) {
      'transactions_changed' => RealtimeEventType.transactionsChanged,
      'accounts_changed' => RealtimeEventType.accountsChanged,
      'fx_rates_updated' => RealtimeEventType.fxRatesUpdated,
      'sync_complete' => RealtimeEventType.syncComplete,
      'heartbeat' => RealtimeEventType.heartbeat,
      'resync' => RealtimeEventType.resync,
      _ => RealtimeEventType.unknown,
    };
    return RealtimeEvent(
      type: type,
      institution: m['institution']?.toString() ?? '',
    );
  } catch (e) {
    debugPrint('realtime: bad payload: $e (raw: $raw)');
    return null;
  }
}

/// Thin wrapper around the browser's native WebSocket. Reconnects
/// with capped exponential backoff (1s → 30s) so a server restart
/// or transient network blip recovers without user action. The
/// stream emits parsed RealtimeEvents; callers map them onto their
/// existing reload paths.
///
/// Single connection per browser tab. The dashboard subscribes
/// once at boot and disposes on logout — there's no per-feature
/// fan-out (the event vocabulary is coarse so one consumer handles
/// every type).
class RealtimeService {
  /// Resolves `ws[s]://<host>:8080/api/realtime/ws` from the current
  /// page's location, mirroring the API base derivation in
  /// `ApiService._baseUrl`.
  static String _wsUrl() => apiWsUrl();

  /// How long the socket may stay silent before we treat it as dead.
  /// The server heartbeats every 30s, so 90s = three missed ticks —
  /// long enough that a slow network can't trigger a spurious reconnect.
  static const Duration _silenceTimeout = Duration(seconds: 90);

  RealtimeSocket? _socket;
  StreamController<RealtimeEvent>? _events;
  /// Tracks the next reconnect delay (ms). Reset on a clean open.
  int _backoffMs = 1000;
  /// True after `dispose()` so reconnect attempts halt.
  bool _disposed = false;
  /// Fires when nothing has arrived for [_silenceTimeout]. A socket
  /// dropped by a sleeping device or a NAT/proxy timeout frequently
  /// produces NO close event — without this the client sits on a
  /// half-open socket believing it's connected, and every server push
  /// (the backstop that reloads the dashboard after an import) is lost
  /// until the user forces a refresh by hand.
  Timer? _watchdog;
  /// Guards against stacking two reconnect timers when the watchdog and
  /// the socket's own onClose both fire for the same drop.
  bool _reconnectPending = false;
  /// True once a socket has opened. Distinguishes the boot connection
  /// (whose data the screen just loaded) from a RE-connection, after which
  /// the client is missing every push sent while the socket was down.
  bool _hasConnected = false;

  /// Broadcast stream — multiple subscribers OK. Dashboard listens
  /// once; routing/filtering happens in its handler.
  Stream<RealtimeEvent> get events {
    _events ??= StreamController<RealtimeEvent>.broadcast();
    return _events!.stream;
  }

  /// Open the websocket. Idempotent — calling twice without
  /// `dispose()` in between is a no-op.
  void connect() {
    if (_disposed) return;
    if (_socket != null && _socket!.isOpen) return;
    _reconnectPending = false;
    final url = _wsUrl();
    try {
      final sock = createRealtimeSocket();
      _socket = sock;
      sock.connect(
        url,
        onOpen: () {
          _backoffMs = 1000;
          _armWatchdog();
          debugPrint('realtime: connected to $url');
          // Events published while the socket was down are gone — the hub
          // has no replay buffer. Tell the consumer to refetch, which is
          // exactly what `resync` already means (the server sends it when
          // a subscriber's broadcast buffer overflows). Without this, a
          // reconnect restores future pushes but leaves whatever changed
          // during the outage invisible until something else reloads.
          if (_hasConnected) {
            _events?.add(const RealtimeEvent(type: RealtimeEventType.resync));
          }
          _hasConnected = true;
        },
        onMessage: _handleMessage,
        onError: () => debugPrint('realtime: socket error'),
        onClose: () {
          debugPrint('realtime: closed; reconnecting in ${_backoffMs}ms');
          _scheduleReconnect();
        },
      );
    } catch (e) {
      debugPrint('realtime: connect failed: $e');
      _scheduleReconnect();
    }
  }

  /// (Re)start the silence timer. Called on open and on every inbound
  /// frame — including heartbeats, which exist precisely so an idle but
  /// healthy socket keeps re-arming this.
  void _armWatchdog() {
    _watchdog?.cancel();
    if (_disposed) return;
    _watchdog = Timer(_silenceTimeout, () {
      debugPrint('realtime: no frames for ${_silenceTimeout.inSeconds}s — '
          'assuming the socket is dead, reconnecting');
      // Drop our reference FIRST so `connect()` doesn't see a socket that
      // still claims to be open, then close (which may or may not fire
      // onClose on a half-open connection — `_reconnectPending` makes the
      // double path harmless).
      final dead = _socket;
      _socket = null;
      try {
        dead?.close();
      } catch (_) {
        // Already gone — the reconnect below is what matters.
      }
      _scheduleReconnect();
    });
  }

  void _handleMessage(String raw) {
    // ANY frame proves the socket is alive, even one we end up ignoring.
    _armWatchdog();
    if (raw.isEmpty) return;
    final event = parseRealtimeFrame(raw);
    if (event == null) return;
    _events?.add(event);
  }

  void _scheduleReconnect() {
    _socket = null;
    _watchdog?.cancel();
    if (_disposed) return;
    // The watchdog closing a half-open socket can make onClose fire too;
    // without this both paths would queue a connect and we'd end up with
    // two live sockets (and duplicated events).
    if (_reconnectPending) return;
    _reconnectPending = true;
    final delay = Duration(milliseconds: _backoffMs);
    // Cap at 30s — past that the dashboard's resume refresh
    // (`didChangeAppLifecycleState`) covers the user coming back to a
    // still-disconnected app, and the reconnect emits `resync` anyway.
    _backoffMs = (_backoffMs * 2).clamp(1000, 30000);
    Timer(delay, connect);
  }

  /// Stop reconnecting + close the socket. Call on logout.
  void dispose() {
    _disposed = true;
    _watchdog?.cancel();
    _watchdog = null;
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
    _events?.close();
    _events = null;
  }
}
