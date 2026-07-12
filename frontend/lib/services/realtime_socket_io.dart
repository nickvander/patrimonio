// Native WebSocket implementation, backed by dart:io's WebSocket.
import 'dart:async';
import 'dart:io';

import 'api_platform.dart';
import 'realtime_socket.dart';

class IoRealtimeSocket implements RealtimeSocket {
  WebSocket? _socket;
  StreamSubscription<dynamic>? _sub;
  bool _open = false;

  @override
  bool get isOpen => _open;

  @override
  void connect(
    String url, {
    required void Function() onOpen,
    required void Function(String data) onMessage,
    required void Function() onClose,
    required void Function() onError,
  }) {
    // Carry the session cookie + host-specific headers (Cloudflare Access
    // service token) on the WS handshake. The browser attaches both itself;
    // dart:io's WebSocket attaches neither, so without this the upgrade is
    // rejected as unauthenticated (or bounced to the CF login page).
    final extra = wsHandshakeHeaders();
    WebSocket.connect(url, headers: extra.isEmpty ? null : extra).then((ws) {
      _socket = ws;
      _open = true;
      onOpen();
      _sub = ws.listen(
        (data) {
          if (data is String) onMessage(data);
        },
        onError: (_) => onError(),
        onDone: () {
          _open = false;
          onClose();
        },
        cancelOnError: true,
      );
    }).catchError((Object _) {
      // Connection failed outright — surface as an error + a close so the
      // service schedules a reconnect.
      _open = false;
      onError();
      onClose();
    });
  }

  @override
  void close() {
    _open = false;
    _sub?.cancel();
    try {
      _socket?.close();
    } catch (_) {/* already closed */}
    _socket = null;
  }
}

RealtimeSocket createRealtimeSocketImpl() => IoRealtimeSocket();
