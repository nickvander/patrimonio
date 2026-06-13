import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/screens/account_transactions_screen.dart';
import 'package:patrimonio/widgets/transactions_tab.dart';

// The panel host (AccountTransactionsScreen) takes test seams for its
// transaction reads/writes — `transactionsFetcher` / `transactionUpdater` —
// so these tests never subclass ApiService (per MEMORY: package:web breaks
// the test VM). The panel's other initState fetches (balance history,
// alerts hydration) run against the real ApiService, whose calls hit
// flutter_test's mocked HTTP (400) and are best-effort/caught internally.

/// Recorded onUpdate invocation reaching the injected updater.
typedef _Update = ({String id, String? userCategory});

/// In-memory single-account transaction table the fake backend pages over.
/// Newest first, one row per day; `user_description` ("Row i") is what
/// `displayLabel` renders, so finders can target exact rows.
List<Map<String, dynamic>> _makeTable(int n) {
  final today = DateTime.now();
  return [
    for (var i = 0; i < n; i++)
      {
        'id': 'tx-$i',
        'date': DateFormat('yyyy-MM-dd')
            .format(today.subtract(Duration(days: i))),
        'amount': 10.0 + i,
        'currency': 'USD',
        'description': 'MERCHANT $i',
        'user_description': 'Row $i',
        'category': 'FOOD_AND_DRINK',
        'account_name': 'Checking',
      },
  ];
}

/// Fake paged backend: records every (limit, offset) the panel asks for
/// and serves slices of [table], handing out fresh map copies the way a
/// real JSON decode would.
class _FakeBackend {
  _FakeBackend(this.table);

  final List<Map<String, dynamic>> table;
  final List<({int limit, int offset})> calls = [];

  Future<List<dynamic>> fetch({required int limit, required int offset}) async {
    calls.add((limit: limit, offset: offset));
    return [
      for (final t in table.skip(offset).take(limit))
        Map<String, dynamic>.of(t),
    ];
  }
}

const Map<String, dynamic> _account = {
  'id': 'acct-1',
  'name': 'Checking',
  'currency': 'USD',
  'current_balance': 1000.0,
  'account_type': 'depository',
  'integration_type': 'manual',
};

Widget _host(Widget panel) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: panel),
    );

AccountTransactionsScreen _panel({
  required AccountTransactionsFetcher fetcher,
  List<_Update>? updates,
}) {
  return AccountTransactionsScreen(
    account: _account,
    allAccounts: const [_account],
    conversionFactor: 1.0,
    currencyFormat: NumberFormat.currency(symbol: r'$'),
    targetCurrency: 'USD',
    usdMxnRate: 0,
    transactionsFetcher: fetcher,
    transactionUpdater: updates == null
        ? null
        : (String id,
            {String? userCategory,
            String? userNotes,
            String? userDescription,
            String? accountId}) async {
            updates.add((id: id, userCategory: userCategory));
          },
  );
}

void _setViewSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// The Scrollable inside the tab's inner ListView (the search TextField
/// also contains a Scrollable, so plain byType is ambiguous).
Finder _innerListScrollable() => find
    .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
    .first;

void main() {
  group('Account panel — paged loading', () {
    testWidgets('initial load is one ~page (not 1,000 rows); Load more '
        'appends the next offset and hides at the tail', (tester) async {
      _setViewSize(tester, const Size(1000, 900));
      final backend = _FakeBackend(_makeTable(70));

      await tester.pumpWidget(_host(_panel(fetcher: backend.fetch)));
      await tester.pumpAndSettle();

      // First request is a single small page from offset 0.
      expect(backend.calls, hasLength(1));
      expect(backend.calls.single, (limit: 50, offset: 0));
      expect(find.text('Row 0'), findsOneWidget);
      expect(find.text('Showing 50 of 50'), findsOneWidget);

      // 70 > 50 → the backend filled the page, so the panel offers more.
      final loadMore = find.text('Load more');
      expect(loadMore, findsOneWidget);

      await tester.tap(loadMore);
      await tester.pumpAndSettle();

      // Next page picks up exactly where the loaded list ends…
      expect(backend.calls, hasLength(2));
      expect(backend.calls.last, (limit: 50, offset: 50));
      expect(find.text('Showing 70 of 70'), findsOneWidget);
      // …and the short (20-row) page proves the tail was reached.
      expect(find.text('Load more'), findsNothing);
    });

    testWidgets('full-body spinner appears for the initial load only',
        (tester) async {
      _setViewSize(tester, const Size(1000, 900));
      final table = _makeTable(5);
      final gate = Completer<void>();
      Future<List<dynamic>> gatedFetch(
          {required int limit, required int offset}) async {
        await gate.future;
        return [
          for (final t in table.skip(offset).take(limit))
            Map<String, dynamic>.of(t),
        ];
      }

      await tester.pumpWidget(_host(_panel(fetcher: gatedFetch)));
      await tester.pump();

      // While the first page is in flight the body is the spinner.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Row 0'), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Row 0'), findsOneWidget);
    });
  });

  group('Account panel — running balance per row', () {
    testWidgets(
        'rows show "balance after" anchored on the header balance: top row '
        '= current balance, older rows walk back through the amounts',
        (tester) async {
      _setViewSize(tester, const Size(1000, 900));
      // 3 rows, amounts 10/11/12 (all inflows, positive), account balance 1000.
      final table = _makeTable(3);
      // Row 1 carries a statement-persisted balance — exact, no '≈'.
      table[1]['balance_after'] = 555.25;
      final backend = _FakeBackend(table);

      await tester.pumpWidget(_host(_panel(fetcher: backend.fetch)));
      await tester.pumpAndSettle();

      // Top row's balance-after IS the account's current balance
      // (estimated → '≈' prefix, since manual rows persist nothing).
      expect(find.text(r'Bal. ≈ $1,000.00'), findsOneWidget);
      // The persisted statement figure wins and renders plain.
      expect(find.text(r'Bal. $555.25'), findsOneWidget);
      // The row below it re-anchors on the exact figure: the older row's
      // balance predates row 1's inflow of 11 arriving, so 555.25 − 11 = 544.25.
      expect(find.text(r'Bal. ≈ $544.25'), findsOneWidget);

      // Single-account host: the meta line no longer repeats the
      // account name the panel header already shows.
      expect(find.text('Food & drink · Checking'), findsNothing);
    });
  });

  group('Account panel — in-place post-edit refresh', () {
    testWidgets(
        'an edit refetches at loaded depth without remounting the list: '
        'same ScrollPosition object, same offset, no spinner', (tester) async {
      _setViewSize(tester, const Size(1000, 900));
      final backend = _FakeBackend(_makeTable(60));
      final updates = <_Update>[];

      await tester
          .pumpWidget(_host(_panel(fetcher: backend.fetch, updates: updates)));
      await tester.pumpAndSettle();
      expect(find.text('Showing 50 of 50'), findsOneWidget);

      // Scroll partway down the virtualised list and remember exactly
      // where we are — including the ScrollPosition OBJECT, whose
      // identity only survives if the list is never remounted.
      await tester.drag(_innerListScrollable(), const Offset(0, -400));
      await tester.pump();
      final positionBefore =
          tester.state<ScrollableState>(_innerListScrollable()).position;
      final pixelsBefore = positionBefore.pixels;
      expect(pixelsBefore, greaterThan(0));

      // Drive an edit through the exact callback the detail editors use.
      backend.table[3]['user_category'] = 'Coffee';
      final tab = tester.widget<TransactionsTab>(find.byType(TransactionsTab));
      await tab.onUpdate!('tx-3', userCategory: 'Coffee');
      await tester.pump();

      // The PATCH reached the injected updater…
      expect(updates, [(id: 'tx-3', userCategory: 'Coffee')]);
      // …followed by ONE depth-preserving refetch from the top (the old
      // behavior re-downloaded up to 1,000 rows per edit).
      expect(backend.calls, hasLength(2));
      expect(backend.calls.last, (limit: 50, offset: 0));

      // No full-body spinner, no list remount: the refreshed rows landed
      // in the SAME scroll position object at the same offset.
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final positionAfter =
          tester.state<ScrollableState>(_innerListScrollable()).position;
      expect(identical(positionBefore, positionAfter), isTrue,
          reason: 'a remount would have created a new ScrollPosition');
      expect(positionAfter.pixels, pixelsBefore);

      // The refetched data is actually on screen (list still full depth,
      // Load more still offered — hasMore was not clobbered).
      expect(find.text('Showing 50 of 50'), findsOneWidget);
      expect(find.text('Load more'), findsOneWidget);
      await tester.pumpAndSettle();
    });
  });
}
