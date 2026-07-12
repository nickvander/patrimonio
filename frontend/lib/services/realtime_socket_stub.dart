// Fallback socket for platforms with neither dart:io nor js_interop. Never
// selected in practice (web resolves to the web impl, everything else to io),
// but kept as a safe no-op so the seam always resolves.
import 'realtime_socket.dart';

class _NoopSocket implements RealtimeSocket {
  @override
  bool get isOpen => false;

  @override
  void connect(
    String url, {
    required void Function() onOpen,
    required void Function(String data) onMessage,
    required void Function() onClose,
    required void Function() onError,
  }) {}

  @override
  void close() {}
}

RealtimeSocket createRealtimeSocketImpl() => _NoopSocket();
