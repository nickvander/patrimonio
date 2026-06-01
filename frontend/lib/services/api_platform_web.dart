// Web implementation of the [ApiService] platform seam.
import 'package:http/http.dart' as http;
import 'package:http/browser_client.dart';
import 'package:web/web.dart' as web;

String currentHost() => web.window.location.hostname.isEmpty
    ? 'localhost'
    : web.window.location.hostname;

/// The API base URL, derived from how the page is served.
///
/// Behind a TLS proxy / tunnel (the page is on **https**) the API is reached
/// SAME-ORIGIN at `/api` — nginx proxies it to the backend. That keeps the
/// app, its XHRs, and the Plaid OAuth redirect on one https origin, which is
/// what makes OAuth banks work at all (an https page can't call `http://…:8080`
/// — mixed content — and a tunnel only exposes one origin anyway).
///
/// Plain-http localhost dev is left exactly as it was: the split-port
/// `http://<host>:8080` the app has always used (frontend :3000, API :8080).
String apiBaseUrl() {
  final loc = web.window.location;
  if (loc.protocol == 'https:') return '${loc.origin}/api';
  return 'http://${currentHost()}:8080/api';
}

/// WebSocket URL for the realtime channel, mirroring [apiBaseUrl]: same-origin
/// `wss://…/api/realtime/ws` under https, split-port `ws://host:8080/…` on
/// plain-http localhost dev.
String apiWsUrl() {
  final loc = web.window.location;
  if (loc.protocol == 'https:') return 'wss://${loc.host}/api/realtime/ws';
  return 'ws://${currentHost()}:8080/api/realtime/ws';
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
