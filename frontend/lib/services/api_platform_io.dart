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
import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
    headers['Cookie'] = _sharedJar.values
        .map((c) => '${c.name}=${c.value}')
        .join('; ');
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

// ---------------------------------------------------------------------------
// Session persistence — survive app restarts/updates like a browser does.
//
// The browser keeps the session cookie (Max-Age 30d) across restarts for
// free; the in-memory jar above forgets it, which forced a re-login after
// every APK update. On Android/iOS the jar is mirrored into Keystore-backed
// secure storage (flutter_secure_storage) — NOT shared_preferences, because
// the cookie is a full-access credential for a finance backend.
//
// Same init()-gating pattern as preferences_storage_io: nothing reads or
// writes the platform plugin until main() calls [initSessionPersistence],
// so the Dart test VM (which compiles this file) keeps the old inert
// in-memory behaviour and widget tests stay isolated.
// ---------------------------------------------------------------------------

const _secureStorage = FlutterSecureStorage(aOptions: AndroidOptions());
const _cookieStoreKey = 'patrimonio_session_cookies';
bool _persistenceEnabled = false;

/// Restore any persisted session cookies into the process jar, and enable
/// mirroring of future jar changes. Call once from `main()` before the first
/// API request. No-op on desktop and under `flutter test` (only mobile
/// platforms get a keystore; everything else keeps the in-memory jar).
Future<void> initSessionPersistence() async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  _persistenceEnabled = true;
  try {
    final raw = await _secureStorage.read(key: _cookieStoreKey);
    if (raw == null || raw.isEmpty) return;
    for (final cookie in decodePersistedCookies(raw, DateTime.now())) {
      _sharedJar[cookie.name] = cookie;
    }
  } catch (_) {
    // Corrupted payload or keystore unavailable (e.g. restored backup on a
    // new device) — start signed out rather than crash the boot path.
  }
}

/// Drop the session everywhere: the in-memory jar AND the secure store.
/// Called on logout, on a 401 (the server no longer honours the session),
/// and on "change server" (a cookie for the old backend must not leak to
/// the next one).
Future<void> clearPersistedSession() async {
  _sharedJar.clear();
  if (!_persistenceEnabled) return;
  try {
    await _secureStorage.delete(key: _cookieStoreKey);
  } catch (_) {
    // Best-effort: worst case a stale (already-revoked) cookie is restored
    // next boot and the server rejects it with a 401 → login screen anyway.
  }
}

/// Mirror the current jar into secure storage. Fire-and-forget: losing a
/// write only costs an extra login after the next restart.
void _persistJar() {
  if (!_persistenceEnabled) return;
  if (_sharedJar.isEmpty) {
    _secureStorage.delete(key: _cookieStoreKey).catchError((_) {});
    return;
  }
  _secureStorage
      .write(key: _cookieStoreKey, value: encodeJarCookies(_sharedJar.values))
      .catchError((_) {});
}

/// Serialize cookies for persistence. A cookie that only carries `Max-Age`
/// (the backend's session cookie does) gets an absolute expiry stamped now,
/// so restores can drop it once it has lapsed. Visible for testing.
String encodeJarCookies(Iterable<Cookie> cookies) {
  final now = DateTime.now().toUtc();
  return jsonEncode([
    for (final c in cookies)
      {
        'name': c.name,
        'value': c.value,
        if (c.expires != null)
          'expires': c.expires!.toUtc().toIso8601String()
        else if (c.maxAge != null)
          'expires': now.add(Duration(seconds: c.maxAge!)).toIso8601String(),
      },
  ]);
}

/// Parse a persisted payload back into cookies, silently dropping entries
/// that are malformed or already expired at [now]. Visible for testing.
List<Cookie> decodePersistedCookies(String raw, DateTime now) {
  final result = <Cookie>[];
  final Object? decoded;
  try {
    decoded = jsonDecode(raw);
  } on FormatException {
    return result;
  }
  if (decoded is! List) return result;
  for (final entry in decoded) {
    if (entry is! Map) continue;
    final name = entry['name'];
    final value = entry['value'];
    if (name is! String || value is! String || name.isEmpty) continue;
    DateTime? expires;
    final rawExpires = entry['expires'];
    if (rawExpires is String) {
      expires = DateTime.tryParse(rawExpires);
      if (expires != null && expires.isBefore(now.toUtc())) continue;
    }
    final cookie = Cookie(name, value);
    if (expires != null) cookie.expires = expires;
    result.add(cookie);
  }
  return result;
}

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
    if (ioResp.cookies.isNotEmpty) {
      for (final cookie in ioResp.cookies) {
        final expired = cookie.maxAge != null && cookie.maxAge! <= 0;
        if (cookie.value.isEmpty || expired) {
          _jar.remove(cookie.name);
        } else {
          _jar[cookie.name] = cookie;
        }
      }
      // Mirror every jar change (login's new cookie, logout's removal) into
      // secure storage so the session survives an app restart/update.
      _persistJar();
    }

    final headers = <String, String>{};
    ioResp.headers.forEach((name, values) {
      headers[name] = values.join(',');
    });

    return http.StreamedResponse(
      ioResp,
      ioResp.statusCode,
      contentLength: ioResp.contentLength == -1 ? null : ioResp.contentLength,
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
