import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/services/transaction_mutation_refresh.dart';

/// These tests run on the plain Dart VM — the refresh orchestration takes
/// plain fetcher closures, so we can pin down the EXACT request set that
/// runs after a transaction mutation without subclassing ApiService (which
/// would pull package:web into the test VM and break it).
///
/// The regression being guarded: a single-transaction edit used to await
/// `refreshAllStockPrices()` (external Yahoo quotes) plus a full
/// ~18-endpoint `_loadAllData(forceRefresh: true)`. The targeted refresh
/// must settle with transactions + overview + trends only (plus the
/// FX-transfer list when explicitly requested).
void main() {
  group('fetchAfterTransactionMutation request set', () {
    test('plain mutation fetches exactly transactions, overview and trends',
        () async {
      final called = <String>[];

      final data = await fetchAfterTransactionMutation(
        getTransactions: () async {
          called.add('transactions');
          return [
            {'id': 't1'}
          ];
        },
        getOverview: () async {
          called.add('overview');
          return {'net_worth': 100};
        },
        getTrends: () async {
          called.add('trends');
          return [
            {'month': '2026-06', 'income': 1.0}
          ];
        },
      );

      // Exactly these three reads — no holdings / crypto / FX-rate /
      // stock-quote fetchers even exist on this path to be called.
      expect(called, unorderedEquals(['transactions', 'overview', 'trends']));
      expect(called, hasLength(3));

      expect(data.transactions, hasLength(1));
      expect(data.overview['net_worth'], 100);
      expect(data.trends, isA<List<Map<String, dynamic>>>());
      expect(data.trends.single['month'], '2026-06');
      // FX transfers weren't requested: null so the caller keeps its
      // current list untouched.
      expect(data.fxTransfers, isNull);
    });

    test('FX-transfer mutations add the transfers read (4 total)', () async {
      final called = <String>[];

      final data = await fetchAfterTransactionMutation(
        getTransactions: () async {
          called.add('transactions');
          return const [];
        },
        getOverview: () async {
          called.add('overview');
          return const {};
        },
        getTrends: () async {
          called.add('trends');
          return const [];
        },
        getFxTransfers: () async {
          called.add('fx-transfers');
          return [
            {'id': 'fx1'}
          ];
        },
      );

      expect(
        called,
        unorderedEquals(['transactions', 'overview', 'trends', 'fx-transfers']),
      );
      expect(data.fxTransfers, hasLength(1));
    });

    test('FX-transfer fetch is best-effort: a failure yields an empty list '
        'instead of failing the whole refresh', () async {
      final data = await fetchAfterTransactionMutation(
        getTransactions: () async => const [],
        getOverview: () async => const {},
        getTrends: () async => const [],
        getFxTransfers: () async => throw Exception('transfer listing down'),
      );
      expect(data.fxTransfers, isEmpty);
    });

    test('a core read failing propagates (caller keeps current data)',
        () async {
      expect(
        () => fetchAfterTransactionMutation(
          getTransactions: () async => throw Exception('boom'),
          getOverview: () async => const {},
          getTrends: () async => const [],
        ),
        throwsException,
      );
    });
  });
}
