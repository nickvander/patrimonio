import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';
import 'package:flutter/foundation.dart';
import 'package:web/web.dart' as web;

/// Coarse server-pushed events. Mirrors `services::realtime::RealtimeEvent`
/// in the backend — payloads are intentionally tiny ("go refetch
/// transactions") rather than the actual data, so the existing REST
/// endpoints remain the source of truth.
enum RealtimeEventType {
  transactionsChanged,
  accountsChanged,
  fxRatesUpdated,
  syncComplete,
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
  static String _wsUrl() {
    final loc = web.window.location;
    final host = loc.hostname.isEmpty ? 'localhost' : loc.hostname;
    final scheme = loc.protocol == 'https:' ? 'wss' : 'ws';
    return '$scheme://$host:8080/api/realtime/ws';
  }

  web.WebSocket? _socket;
  StreamController<RealtimeEvent>? _events;
  /// Tracks the next reconnect delay (ms). Reset on a clean open.
  int _backoffMs = 1000;
  /// True after `dispose()` so reconnect attempts halt.
  bool _disposed = false;

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
    if (_socket != null && _socket!.readyState == 1) return; // OPEN
    final url = _wsUrl();
    try {
      final ws = web.WebSocket(url);
      _socket = ws;
      // package:web's WebSocket exposes events both as
      // assignable `on*` properties (which need JSFunction) AND as
      // EventTarget listeners (which take typed Dart callbacks).
      // The listener API is simpler — same lifecycle (the listener
      // is removed when the socket is GC'd alongside it) without
      // the .toJS / type-inference dance.
      ws.addEventListener(
        'open',
        ((web.Event _) {
          _backoffMs = 1000;
          debugPrint('realtime: connected to $url');
        }).toJS,
      );
      ws.addEventListener(
        'message',
        ((web.MessageEvent ev) {
          final raw = ev.data;
          // Text WS frames arrive as JSString. Anything else (Blob,
          // ArrayBuffer) is ignored — we don't send binary frames.
          if (raw.isA<JSString>()) {
            _handleMessage((raw as JSString).toDart);
          }
        }).toJS,
      );
      ws.addEventListener(
        'error',
        ((web.Event _) {
          debugPrint('realtime: socket error');
        }).toJS,
      );
      ws.addEventListener(
        'close',
        ((web.CloseEvent ev) {
          debugPrint(
            'realtime: closed (code=${ev.code} clean=${ev.wasClean}); '
            'reconnecting in ${_backoffMs}ms',
          );
          _scheduleReconnect();
        }).toJS,
      );
    } catch (e) {
      debugPrint('realtime: connect failed: $e');
      _scheduleReconnect();
    }
  }

  void _handleMessage(String raw) {
    if (raw.isEmpty) return;
    try {
      final m = json.decode(raw) as Map<String, dynamic>;
      final type = switch (m['event']) {
        'transactions_changed' => RealtimeEventType.transactionsChanged,
        'accounts_changed' => RealtimeEventType.accountsChanged,
        'fx_rates_updated' => RealtimeEventType.fxRatesUpdated,
        'sync_complete' => RealtimeEventType.syncComplete,
        'resync' => RealtimeEventType.resync,
        _ => RealtimeEventType.unknown,
      };
      _events?.add(RealtimeEvent(
        type: type,
        institution: m['institution']?.toString() ?? '',
      ));
    } catch (e) {
      debugPrint('realtime: bad payload: $e (raw: $raw)');
    }
  }

  void _scheduleReconnect() {
    _socket = null;
    if (_disposed) return;
    final delay = Duration(milliseconds: _backoffMs);
    // Cap at 30s — past that the user has likely noticed something
    // is wrong anyway and the polling fallback (tab-switch refetch)
    // keeps the UI alive.
    _backoffMs = (_backoffMs * 2).clamp(1000, 30000);
    Timer(delay, connect);
  }

  /// Stop reconnecting + close the socket. Call on logout.
  void dispose() {
    _disposed = true;
    try {
      _socket?.close();
    } catch (_) {}
    _socket = null;
    _events?.close();
    _events = null;
  }
}
