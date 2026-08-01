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
    test(
      'plain mutation fetches exactly transactions, overview and trends',
      () async {
        final called = <String>[];

        final data = await fetchAfterTransactionMutation(
          getTransactions: (limit) async {
            called.add('transactions');
            return [
              {'id': 't1'},
            ];
          },
          getOverview: () async {
            called.add('overview');
            return {'net_worth': 100};
          },
          getTrends: () async {
            called.add('trends');
            return [
              {'month': '2026-06', 'income': 1.0},
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
      },
    );

    test('FX-transfer mutations add the transfers read (4 total)', () async {
      final called = <String>[];

      final data = await fetchAfterTransactionMutation(
        getTransactions: (limit) async {
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
            {'id': 'fx1'},
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
        getTransactions: (limit) async => const [],
        getOverview: () async => const {},
        getTrends: () async => const [],
        getFxTransfers: () async => throw Exception('transfer listing down'),
      );
      expect(data.fxTransfers, isEmpty);
    });

    test(
      'a core read failing propagates (caller keeps current data)',
      () async {
        expect(
          () => fetchAfterTransactionMutation(
            getTransactions: (limit) async => throw Exception('boom'),
            getOverview: () async => const {},
            getTrends: () async => const [],
          ),
          throwsException,
        );
      },
    );

    test('transactionsLimit is propagated verbatim to the fetcher '
        '(depth-preserving refetch)', () async {
      final receivedLimits = <int>[];
      await fetchAfterTransactionMutation(
        getTransactions: (limit) async {
          receivedLimits.add(limit);
          return const [];
        },
        getOverview: () async => const {},
        getTrends: () async => const [],
        transactionsLimit: 230,
      );
      expect(receivedLimits, [230]);
    });

    test('transactionsLimit defaults to one standard page (50)', () async {
      final receivedLimits = <int>[];
      await fetchAfterTransactionMutation(
        getTransactions: (limit) async {
          receivedLimits.add(limit);
          return const [];
        },
        getOverview: () async => const {},
        getTrends: () async => const [],
      );
      expect(receivedLimits, [50]);
    });
  });

  group('txRefetchLimit — depth-preserving page size', () {
    test('never below one full page', () {
      expect(txRefetchLimit(loadedCount: 0, pageSize: 50), 50);
      expect(txRefetchLimit(loadedCount: 20, pageSize: 50), 50);
    });

    test('covers the loaded depth exactly when deeper than a page', () {
      expect(txRefetchLimit(loadedCount: 230, pageSize: 50), 230);
    });

    test(
      'caps at the backend clamp so the server never silently truncates',
      () {
        // The constant mirrors `q.limit.unwrap_or(50).clamp(1, 500)` in
        // backend/src/api/dashboard.rs — if the backend cap changes, this
        // constant (and these expectations) must move with it.
        expect(kTxBackendMaxPageSize, 500);
        expect(
          txRefetchLimit(loadedCount: 3000, pageSize: 50),
          kTxBackendMaxPageSize,
        );
      },
    );
  });

  group('mergeRefetchedTransactions — loaded-depth preservation', () {
    List<Map<String, dynamic>> rows(int from, int to) => [
      for (var i = from; i <= to; i++) {'id': 'tx-$i'},
    ];

    test('short refetch (server ran out of rows) is the complete truth — '
        'deleted rows disappear', () {
      final previous = rows(1, 230);
      final refetched = rows(1, 229); // one row deleted server-side
      final merged = mergeRefetchedTransactions(
        previous: previous,
        refetched: refetched,
        requestedLimit: 230,
      );
      expect(merged, same(refetched));
    });

    test('full refetch over a deeper previous list keeps the old tail '
        '(cascade-loaded depth survives a capped refetch)', () {
      final previous = rows(1, 800); // cascade-loaded beyond the cap
      final refetched = rows(1, 500); // capped window
      final merged = mergeRefetchedTransactions(
        previous: previous,
        refetched: refetched,
        requestedLimit: 500,
      );
      expect(merged, hasLength(800));
      expect(merged.first['id'], 'tx-1');
      expect(merged[499]['id'], 'tx-500'); // refetched window
      expect(merged[500]['id'], 'tx-501'); // preserved tail starts here
      expect(merged.last['id'], 'tx-800');
    });

    test('rows added above the window push the old tail down, not out', () {
      // 2 brand-new rows on top: the refetch window now ends 2 rows higher
      // up the old list, so 2 more old rows belong to the preserved tail.
      final previous = rows(1, 600);
      final refetched = [
        {'id': 'new-1'},
        {'id': 'new-2'},
        ...rows(1, 498),
      ];
      final merged = mergeRefetchedTransactions(
        previous: previous,
        refetched: refetched,
        requestedLimit: 500,
      );
      expect(merged, hasLength(602));
      expect(merged.first['id'], 'new-1');
      expect(merged[500]['id'], 'tx-499'); // tail anchored after tx-498
      expect(merged.last['id'], 'tx-600');
    });

    test('full refetch that re-covers everything previously loaded just '
        'replaces it (no duplicate tail)', () {
      final previous = rows(1, 50);
      final refetched = rows(1, 50);
      final merged = mergeRefetchedTransactions(
        previous: previous,
        refetched: refetched,
        requestedLimit: 50,
      );
      expect(merged, same(refetched));
    });
  });
}
