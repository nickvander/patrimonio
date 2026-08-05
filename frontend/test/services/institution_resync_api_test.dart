// Wire-level tests for `ApiService.resyncInstitutionFullHistory` — the
// full-history Plaid re-pull (`POST /institutions/{id}/resync`).
//
// Two things are worth pinning here. First the request itself: the endpoint
// is a POST to the `/resync` path, NOT the neighbouring `/sync` — a typo
// there would silently run an ordinary incremental sync, which is exactly
// the operation that failed to deliver the missing rows in the first place,
// and the UI would report success while recovering nothing.
//
// Second the failure path: the backend answers 400 for a manual/CSV
// institution and 404 for an unknown or foreign id, each with a
// `{"error": ...}` string that says what actually went wrong. Those must
// reach the user verbatim via `_errorFromBody`, not be flattened into
// "failed: 400".
//
// All requests go through `ApiService.debugHttpClientOverride` + MockClient
// (the house test seam) — zero network I/O.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:patrimonio/services/api_service.dart';

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

  group('request shape', () {
    test('POSTs to /institutions/{id}/resync and accepts 202', () async {
      final requests = _install(
        (_) => http.Response(jsonEncode({'status': 'accepted'}), 202),
      );

      await api.resyncInstitutionFullHistory('abc-123');

      final req = requests.single;
      expect(req.method, 'POST');
      expect(req.url.path, endsWith('/institutions/abc-123/resync'));
      // Guard against hitting the plain incremental sync by mistake — the
      // path must not end at `/sync`.
      expect(req.url.path, isNot(endsWith('/institutions/abc-123/sync')));
      // Backend CSRF sentinel, injected by the verb wrapper.
      expect(req.headers['X-Requested-With'], 'fetch');
    });

    test('a 200 from an older backend is still accepted', () async {
      _install((_) => http.Response('', 200));
      await api.resyncInstitutionFullHistory('abc-123');
    });

    test('the id is interpolated, not hardcoded', () async {
      final requests = _install((_) => http.Response('', 202));
      await api.resyncInstitutionFullHistory('other-id');
      expect(
        requests.single.url.path,
        endsWith('/institutions/other-id/resync'),
      );
    });
  });

  group('server errors surface verbatim', () {
    test('400 for a non-Plaid institution keeps the backend message', () async {
      _install(
        (_) => http.Response(
          jsonEncode({
            'error': 'Full re-pull is only available for Plaid institutions',
          }),
          400,
        ),
      );

      expect(
        () => api.resyncInstitutionFullHistory('manual-1'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('only available for Plaid institutions'),
          ),
        ),
      );
    });

    test('404 for an unknown/foreign id keeps the backend message', () async {
      _install(
        (_) =>
            http.Response(jsonEncode({'error': 'Institution not found'}), 404),
      );

      expect(
        () => api.resyncInstitutionFullHistory('nope'),
        throwsA(
          isA<Exception>().having(
            (e) => e.toString(),
            'message',
            contains('Institution not found'),
          ),
        ),
      );
    });

    test(
      'a body with no error string falls back to a status message',
      () async {
        _install((_) => http.Response('<html>502</html>', 502));

        expect(
          () => api.resyncInstitutionFullHistory('abc-123'),
          throwsA(
            isA<Exception>().having(
              (e) => e.toString(),
              'message',
              contains('502'),
            ),
          ),
        );
      },
    );
  });
}
