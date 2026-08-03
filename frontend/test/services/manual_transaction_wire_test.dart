// Wire-level pins for the manual-transaction write that quick entry rides
// on. The widget tests assert what the SHEET hands the API layer; these
// assert what the API layer puts on the socket — so a sign flip, a dropped
// currency, or a swallowed id can't hide in between. All I/O goes through
// package:http/testing.dart's MockClient (the ApiService.debugHttpClientOverride
// seam); zero network.
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

  group('createManualTransactionReturningId', () {
    test('a spend goes on the wire NEGATIVE', () async {
      final requests = _install(
        (_) => http.Response(jsonEncode({'id': 'tx-1'}), 201),
      );
      final id = await api.createManualTransactionReturningId(
        accountId: 'acct-cash',
        date: DateTime(2026, 8, 3),
        description: 'Tacos',
        // The sheet signs before it calls; this is the stored value.
        amount: -180.5,
        currency: 'MXN',
        category: 'Tacos',
      );

      expect(id, 'tx-1');
      final req = requests.single;
      expect(req.method, 'POST');
      expect(req.url.path, endsWith('/dashboard/transactions/manual'));
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      expect(body['amount'], -180.5);
      expect(body['account_id'], 'acct-cash');
      expect(body['currency'], 'MXN');
      expect(body['category'], 'Tacos');
      expect(body['description'], 'Tacos');
      // Date is sent as a plain calendar day, zero-padded — no timezone.
      expect(body['date'], '2026-08-03');
      // Nothing typed → the key is omitted rather than sent empty.
      expect(body.containsKey('notes'), isFalse);
    });

    test('an inflow goes on the wire POSITIVE', () async {
      final requests = _install(
        (_) => http.Response(jsonEncode({'id': 'tx-2'}), 201),
      );
      await api.createManualTransactionReturningId(
        accountId: 'acct-cash',
        date: DateTime(2026, 8, 3),
        description: 'Reembolso',
        amount: 180.5,
        currency: 'MXN',
      );
      expect(
        (jsonDecode(requests.single.body) as Map<String, dynamic>)['amount'],
        180.5,
      );
    });

    test('a 201 without a usable id still counts as saved', () async {
      _install((_) => http.Response('', 201));
      // The row is committed; only the Undo handle is unavailable, and
      // the caller must not see that as a failed write.
      expect(
        await api.createManualTransactionReturningId(
          accountId: 'acct-cash',
          date: DateTime(2026, 8, 3),
          description: 'Cash',
          amount: -20,
          currency: 'MXN',
        ),
        isNull,
      );
    });

    test('a 409 duplicate throws rather than reporting success', () async {
      _install((_) => http.Response('duplicate manual transaction', 409));
      expect(
        () => api.createManualTransactionReturningId(
          accountId: 'acct-cash',
          date: DateTime(2026, 8, 3),
          description: 'Cash',
          amount: -20,
          currency: 'MXN',
        ),
        throwsA(isA<Exception>()),
      );
    });
  });

  test('createManualTransaction still posts the identical body', () async {
    // It is now a thin wrapper over the id-returning call; the existing
    // call sites and the `extends ApiService` fakes that override it must
    // keep seeing exactly the same request.
    final requests = _install(
      (_) => http.Response(jsonEncode({'id': 'tx-3'}), 201),
    );
    await api.createManualTransaction(
      accountId: 'acct-cash',
      date: DateTime(2026, 8, 3),
      description: 'Tacos',
      amount: -180.5,
      currency: 'MXN',
      category: 'Tacos',
      notes: 'con todo',
    );
    final body = jsonDecode(requests.single.body) as Map<String, dynamic>;
    expect(body, {
      'account_id': 'acct-cash',
      'date': '2026-08-03',
      'description': 'Tacos',
      'amount': -180.5,
      'currency': 'MXN',
      'category': 'Tacos',
      'notes': 'con todo',
    });
  });
}
