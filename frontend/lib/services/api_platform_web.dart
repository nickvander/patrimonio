// Web implementation of the [ApiService] platform seam.
import 'package:http/http.dart' as http;
import 'package:http/browser_client.dart';
import 'package:web/web.dart' as web;

String currentHost() => web.window.location.hostname.isEmpty
    ? 'localhost'
    : web.window.location.hostname;

/// The API base URL — always same-origin via the nginx `/api` proxy.
///
/// nginx proxies `/api` to the backend regardless of http or https, so the
/// app never needs to reach port 8080 directly. This means forwarding only
/// port 3000 is sufficient: plain-http port-forwarding from another machine,
/// the tunnel, and direct localhost access all work without `:8080` being
/// reachable. Previously this fell back to `http://host:8080` on plain-http,
/// which broke when the browser was on a different machine (port 8080 not
/// forwarded → "failed to fetch").
String apiBaseUrl() => '${web.window.location.origin}/api';

/// WebSocket URL — same-origin, protocol-matched (ws on http, wss on https).
String apiWsUrl() {
  final loc = web.window.location;
  final scheme = loc.protocol == 'https:' ? 'wss' : 'ws';
  return '$scheme://${loc.host}/api/realtime/ws';
}

/// Extra headers every API request should carry, decided by the current host.
///
/// Behind an **ngrok free** tunnel, `ngrok-skip-browser-warning` suppresses the
/// browser interstitial ngrok injects for browser-looking requests — without
/// it, XHRs come back as ngrok's HTML warning page instead of the backend's
/// JSON. No-op (empty) on any non-ngrok host, so normal/self-hosted deploys are
/// unaffected.
Map<String, String> apiExtraHeaders() {
  if (web.window.location.hostname.contains('ngrok')) {
    return const {'ngrok-skip-browser-warning': 'true'};
  }
  return const {};
}

/// Wraps an inner client to stamp [apiExtraHeaders] onto every request, so the
/// ngrok header rides along no matter which ApiService helper made the call.
class _ExtraHeaderClient extends http.BaseClient {
  _ExtraHeaderClient(this._inner);
  final http.Client _inner;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    request.headers.addAll(apiExtraHeaders());
    return _inner.send(request);
  }
}

/// Credentialed client: `withCredentials` is required for the browser to
/// send (and accept) the session cookie on cross-origin XHRs in dev, and
/// is harmless same-origin in production. Wrapped so host-specific headers
/// (e.g. the ngrok skip header) are applied uniformly.
http.Client createApiClient() =>
    _ExtraHeaderClient(BrowserClient()..withCredentials = true);
