// Platform seam for a single WebSocket connection, used by [RealtimeService].
//
// The browser exposes `WebSocket` via `dart:js_interop`/`package:web` (web
// only); native uses `dart:io`'s `WebSocket`. Isolating just the socket here
// keeps the reconnect/backoff logic in `realtime_service.dart` platform-neutral
// and lets that file — and everything that imports the dashboard — compile for
// Android.
import 'realtime_socket_stub.dart'
    if (dart.library.js_interop) 'realtime_socket_web.dart'
    if (dart.library.io) 'realtime_socket_io.dart';

abstract class RealtimeSocket {
  /// True while the underlying socket is open.
  bool get isOpen;

  /// Open [url]. Callbacks fire for the socket lifecycle; [onMessage] receives
  /// text frames only (binary frames are ignored — the protocol is text-only).
  void connect(
    String url, {
    required void Function() onOpen,
    required void Function(String data) onMessage,
    required void Function() onClose,
    required void Function() onError,
  });

  void close();
}

RealtimeSocket createRealtimeSocket() => createRealtimeSocketImpl();
