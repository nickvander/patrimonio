// Web WebSocket implementation, backed by the browser's native WebSocket.
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'realtime_socket.dart';

class WebRealtimeSocket implements RealtimeSocket {
  web.WebSocket? _socket;

  @override
  bool get isOpen => _socket != null && _socket!.readyState == 1; // OPEN

  @override
  void connect(
    String url, {
    required void Function() onOpen,
    required void Function(String data) onMessage,
    required void Function() onClose,
    required void Function() onError,
  }) {
    final ws = web.WebSocket(url);
    _socket = ws;
    // package:web exposes events as EventTarget listeners taking typed Dart
    // callbacks (simpler than the assignable on* JSFunction properties).
    ws.addEventListener('open', ((web.Event _) => onOpen()).toJS);
    ws.addEventListener(
      'message',
      ((web.MessageEvent ev) {
        final raw = ev.data;
        // Text frames arrive as JSString; ignore Blob/ArrayBuffer.
        if (raw.isA<JSString>()) {
          onMessage((raw as JSString).toDart);
        }
      }).toJS,
    );
    ws.addEventListener('error', ((web.Event _) => onError()).toJS);
    ws.addEventListener('close', ((web.CloseEvent _) => onClose()).toJS);
  }

  @override
  void close() {
    try {
      _socket?.close();
    } catch (_) {/* already closed */}
    _socket = null;
  }
}

RealtimeSocket createRealtimeSocketImpl() => WebRealtimeSocket();
