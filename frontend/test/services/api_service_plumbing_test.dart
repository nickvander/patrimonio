// Unit tests for ApiService's core plumbing — the verb wrappers, CSRF
// header injection, the 401 → AuthService flow, `_errorFromBody` mapping,
// base-URL joining, and the verb-wrapper ↔ response-cache interaction.
//
// This plumbing was untestable until `ApiService.debugHttpClientOverride`
// (the client test seam): the shared client was a hard-wired
// `createApiClient()` static. All requests here go through
// `package:http/testing.dart`'s MockClient — zero network I/O. The private
// members are exercised through thin public endpoints that add nothing on
// top of the wrapper being pinned (listSessions → _get, revokeOtherSessions
// → _post, confirmFxTransfer → _patch, putFxAlert → _put, revokeSession →
// _delete, getDashboardOverview → _cachedGet).
import 'dart:convert';
import 'dart:ui' show Locale;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/services/auth_service.dart';
import 'package:patrimonio/utils/app_locale.dart';

/// Install a MockClient that records every request and answers via
/// [handler]. Returns the recorded-request list.
List<http.Request> _install(
  http.Response Function(http.Request request) handler,
) {
  final requests = <http.Request>[];
  ApiService.debugHttpClientOverride = MockClient((request) async {
    requests.add(request);
    return handler(request);
  });
  return requests;
}

void main() {
  final api = ApiService();

  setUp(ApiService.clearDashboardCache);

  tearDown(() {
    ApiService.debugHttpClientOverride = null;
    ApiService.clearDashboardCache();
  });

  group('CSRF header injection (X-Requested-With)', () {
    test('POST carries the sentinel even with no caller headers', () async {
      final requests = _install(
        (_) => http.Response(jsonEncode({'revoked': 0}), 200),
      );
      await api.revokeOtherSessions();
      expect(requests.single.method, 'POST');
      expect(requests.single.headers['X-Requested-With'], 'fetch');
    });

    test('PATCH carries the sentinel', () async {
      final requests = _install((_) => http.Response('', 200));
      await api.confirmFxTransfer('tx-1');
      expect(requests.single.method, 'PATCH');
      expect(requests.single.headers['X-Requested-With'], 'fetch');
    });

    test(
      'PUT merges the sentinel with caller headers and keeps the body',
      () async {
        final requests = _install(
          (_) => http.Response(
            jsonEncode({
              'alert': {'threshold': 17.5},
            }),
            200,
          ),
        );
        await api.putFxAlert(base: 'USD', target: 'MXN', threshold: 17.5);
        final req = requests.single;
        expect(req.method, 'PUT');
        expect(req.headers['X-Requested-With'], 'fetch');
        expect(req.headers['Content-Type'], contains('application/json'));
        expect(jsonDecode(req.body), {'threshold': 17.5});
      },
    );

    test('DELETE carries the sentinel', () async {
      final requests = _install((_) => http.Response('', 204));
      await api.revokeSession('sess-1');
      expect(requests.single.method, 'DELETE');
      expect(requests.single.headers['X-Requested-With'], 'fetch');
    });

    test(
      'GET does NOT carry the sentinel (reads need no CSRF proof)',
      () async {
        final requests = _install((_) => http.Response('[]', 200));
        await api.listSessions();
        expect(requests.single.method, 'GET');
        expect(
          requests.single.headers.containsKey('X-Requested-With'),
          isFalse,
        );
      },
    );
  });

  group('base-URL joining', () {
    test('endpoint paths are joined under apiBaseUrl()', () async {
      // Under the Dart test VM the api_platform seam resolves to the io
      // impl with no BackendConfig, so the documented localhost fallback
      // plus the /api prefix is the whole base URL.
      final requests = _install((_) => http.Response('[]', 200));
      await api.listSessions();
      expect(
        requests.single.url,
        Uri.parse('http://localhost:3000/api/auth/sessions'),
      );
    });
  });

  group('401 handling (_maybeUnauthorized)', () {
    test('GET returning 401 throws UnauthorizedException', () async {
      _install((_) => http.Response('', 401));
      await expectLater(
        api.listSessions(),
        throwsA(isA<UnauthorizedException>()),
      );
    });

    test('mutating verbs returning 401 throw UnauthorizedException', () async {
      _install((_) => http.Response('', 401));
      await expectLater(
        api.revokeOtherSessions(),
        throwsA(isA<UnauthorizedException>()),
      );
      await expectLater(
        api.revokeSession('sess-1'),
        throwsA(isA<UnauthorizedException>()),
      );
    });

    test('a 401 while signed in pushes AuthService to signedOut', () async {
      // Sign the singleton in through the real login path (mocked 200).
      _install(
        (_) => http.Response(
          jsonEncode({'id': 'u1', 'username': 'nick', 'totp_enabled': false}),
          200,
        ),
      );
      await AuthService.instance.login('nick', 'pw');
      expect(AuthService.instance.current.phase, AuthPhase.signedIn);

      final emitted = <AuthPhase>[];
      final sub = AuthService.instance.stream.listen(
        (s) => emitted.add(s.phase),
      );
      addTearDown(sub.cancel);

      _install((_) => http.Response('', 401));
      await expectLater(
        api.listSessions(),
        throwsA(isA<UnauthorizedException>()),
      );
      expect(AuthService.instance.current.phase, AuthPhase.signedOut);
      await pumpEventQueue();
      expect(emitted, [AuthPhase.signedOut]);

      // Already signed out: a second 401 still throws but does not
      // re-emit (handleUnauthorized only notifies on the signedIn edge).
      await expectLater(
        api.listSessions(),
        throwsA(isA<UnauthorizedException>()),
      );
      await pumpEventQueue();
      expect(emitted, [AuthPhase.signedOut]);
    });
  });

  group('_errorFromBody', () {
    test('prefers the server {"error": ...} string', () async {
      _install(
        (_) => http.Response(jsonEncode({'error': 'session is sacred'}), 409),
      );
      await expectLater(
        api.revokeSession('sess-1'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            'Exception: session is sacred',
          ),
        ),
      );
    });

    test('malformed body falls back to "<fallback> (<status>)"', () async {
      _install((_) => http.Response('<html>bad gateway</html>', 502));
      await expectLater(
        api.revokeSession('sess-1'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            'Exception: Failed to revoke session (502)',
          ),
        ),
      );
    });

    test('a JSON body without a string "error" key also falls back', () async {
      _install((_) => http.Response(jsonEncode({'detail': 'nope'}), 500));
      await expectLater(
        api.revokeSession('sess-1'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            'Exception: Failed to revoke session (500)',
          ),
        ),
      );
    });

    test(
      'fallback text is localized via _t when the app locale is es',
      () async {
        final previous = localeNotifier.value;
        localeNotifier.value = const Locale('es');
        addTearDown(() => localeNotifier.value = previous);

        _install((_) => http.Response('not json', 500));
        await expectLater(
          api.revokeSession('sess-1'),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              'Exception: No se pudo revocar la sesión (500)',
            ),
          ),
        );
      },
    );
  });

  group('verb wrappers ↔ dashboard cache', () {
    http.Response route(http.Request req) {
      if (req.url.path.endsWith('/dashboard/overview')) {
        return http.Response(jsonEncode({'net_worth': 42}), 200);
      }
      return http.Response(jsonEncode({'revoked': 1}), 200);
    }

    test(
      'a repeated dashboard GET inside the TTL is served from cache',
      () async {
        final requests = _install(route);
        final first = await api.getDashboardOverview();
        final second = await api.getDashboardOverview();
        expect(first['net_worth'], 42);
        expect(second['net_worth'], 42);
        expect(requests, hasLength(1));
      },
    );

    test('forceRefresh bypasses the cached value', () async {
      final requests = _install(route);
      await api.getDashboardOverview();
      await api.getDashboardOverview(forceRefresh: true);
      expect(requests, hasLength(2));
    });

    test('a successful mutation invalidates cached dashboard reads', () async {
      final requests = _install(route);
      await api.getDashboardOverview();
      await api.revokeOtherSessions(); // POST 200 → clearDashboardCache()
      await api.getDashboardOverview();
      // overview + revoke + re-fetched overview
      expect(requests, hasLength(3));
    });

    test('a failed mutation (5xx) leaves the warm cache alone', () async {
      final requests = _install((req) {
        if (req.method == 'POST') return http.Response('boom', 500);
        return route(req);
      });
      await api.getDashboardOverview();
      await expectLater(api.revokeOtherSessions(), throwsA(isA<Exception>()));
      await api.getDashboardOverview();
      // overview + failed revoke; the second overview is a cache hit.
      expect(requests, hasLength(2));
    });
  });
}
