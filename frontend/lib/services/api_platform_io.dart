// Native (Android / iOS / desktop / Dart test VM) implementation of the
// [ApiService] platform seam.
//
// Unlike the web build, a native app has no page origin and no browser cookie
// jar. Two things differ from `api_platform_web.dart`:
//
//   1. The backend URL comes from [BackendConfig] (set on the Settings screen),
//      not from `window.location`.
//   2. The session cookie (`patrimonio_session`, HttpOnly + Lax) is persisted
//      by a hand-rolled cookie client, because `package:http` on native drops
//      `Set-Cookie` and never re-sends `Cookie`. HttpOnly does NOT block this —
//      that flag only hides the cookie from *browser* JavaScript; a native HTTP
//      client can freely read the response header.
//
// This file is also what `flutter test` compiles (the Dart VM has `dart:io`).
// Tests inject fakes and never hit the network, so the localhost fallback and
// the unused cookie client are harmless there.
import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'backend_config.dart';

/// Placeholder used before the user has configured a backend (and in the test
/// VM, where the real network path is never exercised).
const _unconfigured = 'http://localhost:3000';

String get _origin => BackendConfig.baseUrl ?? _unconfigured;

String currentHost() {
  final host = Uri.tryParse(_origin)?.host;
  return (host == null || host.isEmpty) ? 'localhost' : host;
}

/// The API base URL — the configured origin plus the `/api` prefix the backend
/// mounts every route under.
String apiBaseUrl() => '$_origin/api';

/// WebSocket URL for realtime events — protocol-matched to the origin's scheme
/// (wss for https, ws for http).
String apiWsUrl() {
  final uri = Uri.parse(_origin);
  final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
  final authority = uri.hasPort ? '${uri.host}:${uri.port}' : uri.host;
  return '$scheme://$authority/api/realtime/ws';
}

/// Extra headers every API request should carry.
///
/// When the deployment sits behind Cloudflare Access, a native app can't do the
/// interactive browser login — instead a CF **service token** (configured on
/// the backend-setup screen, stored via [BackendConfig]) is sent on every
/// request and a Service-Auth policy at the edge lets it through. Empty for
/// deployments that don't use Cloudflare Access.
Map<String, String> apiExtraHeaders() {
  if (BackendConfig.hasCfAccessToken) {
    return {
      'CF-Access-Client-Id': BackendConfig.cfAccessClientId!,
      'CF-Access-Client-Secret': BackendConfig.cfAccessClientSecret!,
    };
  }
  return const {};
}

/// Headers for the realtime WebSocket handshake. The browser attaches the
/// session cookie to a `WebSocket(url)` upgrade automatically; `dart:io`'s
/// WebSocket does not, so on native the stored session cookie (and the
/// Cloudflare Access token, when configured) must ride along explicitly or the
/// backend rejects the upgrade as unauthenticated.
Map<String, String> wsHandshakeHeaders() {
  final headers = <String, String>{...apiExtraHeaders()};
  if (_sharedJar.isNotEmpty) {
    headers['Cookie'] =
        _sharedJar.values.map((c) => '${c.name}=${c.value}').join('; ');
  }
  return headers;
}

/// A credentialed client for native: it captures the session cookie from
/// `Set-Cookie` and re-sends it on every request, standing in for the browser
/// cookie jar that `BrowserClient..withCredentials` gives us on the web.
http.Client createApiClient() => _CookieClient();

/// One process-wide cookie jar shared by every [_CookieClient] instance —
/// like a browser, all clients (ApiService's, PasskeyService's) see the same
/// session, and [wsHandshakeHeaders] can hand the cookie to the WebSocket.
final Map<String, Cookie> _sharedJar = {};

/// Minimal cookie-persisting HTTP client built on `dart:io`'s [HttpClient],
/// which parses `Set-Cookie`/`Cookie` correctly (unlike the comma-joined header
/// string `package:http` exposes). The jar is process-global (see [_sharedJar])
/// so the session survives for the life of the app process.
class _CookieClient extends http.BaseClient {
  final HttpClient _inner = HttpClient();
  final Map<String, Cookie> _jar = _sharedJar;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final ioReq = await _inner.openUrl(request.method, request.url);
    ioReq.followRedirects = request.followRedirects;
    ioReq.maxRedirects = request.maxRedirects;
    ioReq.persistentConnection = request.persistentConnection;

    // Copy headers, but let HttpClient own content-length and host so we don't
    // fight it over framing.
    request.headers.forEach((name, value) {
      final lower = name.toLowerCase();
      if (lower == 'content-length' || lower == 'host') return;
      ioReq.headers.set(name, value);
    });

    // Host-specific headers (the Cloudflare Access service token) ride on
    // every request — mirrors the web impl's _ExtraHeaderClient wrapper.
    apiExtraHeaders().forEach(ioReq.headers.set);

    // Attach every stored cookie (single backend → no domain/path matching
    // needed).
    if (_jar.isNotEmpty) {
      ioReq.cookies.addAll(_jar.values);
    }

    final body = await request.finalize().toBytes();
    if (body.isNotEmpty) {
      ioReq.add(body);
    }

    final ioResp = await ioReq.close();

    // Update the jar from Set-Cookie. An empty value or a non-positive Max-Age
    // is the server telling us to drop it (e.g. logout's removal cookie).
    for (final cookie in ioResp.cookies) {
      final expired = cookie.maxAge != null && cookie.maxAge! <= 0;
      if (cookie.value.isEmpty || expired) {
        _jar.remove(cookie.name);
      } else {
        _jar[cookie.name] = cookie;
      }
    }

    final headers = <String, String>{};
    ioResp.headers.forEach((name, values) {
      headers[name] = values.join(',');
    });

    return http.StreamedResponse(
      ioResp,
      ioResp.statusCode,
      contentLength:
          ioResp.contentLength == -1 ? null : ioResp.contentLength,
      request: request,
      headers: headers,
      isRedirect: ioResp.isRedirect,
      persistentConnection: ioResp.persistentConnection,
      reasonPhrase: ioResp.reasonPhrase,
    );
  }

  @override
  void close() {
    _inner.close(force: true);
    super.close();
  }
}
