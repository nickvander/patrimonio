import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/transaction_mutation_refresh.dart'
    show kTxBackendMaxPageSize;
import 'package:patrimonio/widgets/transaction_filters.dart';
import 'package:patrimonio/widgets/transactions_tab.dart';

// TransactionsTab takes plain data + callbacks, so no ApiService is needed
// at all (per MEMORY we do NOT subclass ApiService in widget tests).

/// Synthetic rows, newest first, one per day. `user_description`
/// ("Row i") is what displayLabel shows so finders can target rows.
List<Map<String, dynamic>> _rows(List<({double amount, String? notes})> specs) {
  final today = DateTime.now();
  return [
    for (var i = 0; i < specs.length; i++)
      {
        'id': 'tx-$i',
        'date': DateFormat('yyyy-MM-dd')
            .format(today.subtract(Duration(days: i))),
        'amount': specs[i].amount,
        'currency': 'USD',
        'description': 'COFFEE PLACE $i',
        'user_description': 'Row $i',
        if (specs[i].notes != null) 'user_notes': specs[i].notes,
        'category': 'FOOD_AND_DRINK',
        'account_name': 'Checking $i',
      },
  ];
}

Widget _localizedApp(Widget body) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: body),
    );

/// Dashboard-style host (unbounded height → page-scroll/eager path).
Widget _unboundedHost(Widget tab) =>
    _localizedApp(SingleChildScrollView(primary: false, child: tab));

/// Account-panel-style host (bounded height → virtualised path).
Widget _boundedHost(Widget tab) => _localizedApp(Column(
      children: [
        const SizedBox(height: 120),
        Expanded(child: tab),
      ],
    ));

TransactionsTab _tab(List<dynamic> txs) => TransactionsTab(
      transactions: txs,
      conversionFactor: 1.0,
      currencyFormat: NumberFormat.currency(symbol: r'$'),
      targetCurrency: 'USD',
      usdMxnRate: 0,
    );

/// Dashboard-style paginated parent for the Task 13 tests: owns the loaded
/// window + hasMore exactly like `_DashboardScreenState` does, records the
/// `limit` of every onLoadMore call, and appends `limit ?? initialPage`
/// rows per call (mirroring `_loadMoreTransactions`).
class _PagedHost extends StatefulWidget {
  static const int initialPage = 50;
  final List<Map<String, dynamic>> allRows;
  final List<int?> loadLimits;
  const _PagedHost({
    required this.allRows,
    required this.loadLimits,
  });

  @override
  State<_PagedHost> createState() => _PagedHostState();
}

class _PagedHostState extends State<_PagedHost> {
  late List<dynamic> _loaded =
      widget.allRows.take(_PagedHost.initialPage).toList();
  late bool _hasMore = widget.allRows.length > _loaded.length;

  Future<void> _loadMore({int? limit}) async {
    widget.loadLimits.add(limit);
    final page = limit ?? _PagedHost.initialPage;
    // Yield one event-loop turn like a real network call so the cascade's
    // await/rebuild interleaving matches production.
    await Future<void>.delayed(Duration.zero);
    if (!mounted) return;
    setState(() {
      final next = widget.allRows.skip(_loaded.length).take(page).toList();
      _loaded = [..._loaded, ...next];
      _hasMore = next.length >= page;
    });
  }

  @override
  Widget build(BuildContext context) => TransactionsTab(
        transactions: _loaded,
        conversionFactor: 1.0,
        currencyFormat: NumberFormat.currency(symbol: r'$'),
        targetCurrency: 'USD',
        usdMxnRate: 0,
        onLoadMore: _loadMore,
        hasMore: _hasMore,
      );
}

/// [n] synthetic rows, newest first. [category] lets a test plant a
/// category that only exists deep in unloaded history.
List<Map<String, dynamic>> _pagedRows(int n, {String Function(int)? category}) {
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
        'category': category?.call(i) ?? 'FOOD_AND_DRINK',
        'account_name': 'Checking',
      },
  ];
}

void _setViewSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Type [query] into the toolbar search field and ride out the 120ms
/// debounce so the filter actually commits.
Future<void> _search(WidgetTester tester, String query) async {
  await tester.enterText(find.byType(TextField).first, query);
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  group('Task 8 — search haystack (searchHaystackFor)', () {
    Map<String, dynamic> tx({double amount = 10.0, String? notes}) => {
          'id': 'tx-1',
          'date': '2026-06-01',
          'amount': amount,
          'currency': 'USD',
          'description': 'MISC DEBIT',
          'user_description': 'Team stuff',
          if (notes != null) 'user_notes': notes,
          'category': 'FOOD_AND_DRINK',
          'account_name': 'Checking',
        };

    test('includes user_notes (lowercased) — visible text must be findable',
        () {
      final hay = searchHaystackFor(tx(notes: 'Lunch REIMBURSEMENT for May'));
      expect(hay.contains('lunch reimbursement for may'), isTrue);
      expect(hay.contains('reimburse'), isTrue);
    });

    test('includes the amount as "450.00" and "450" regardless of sign', () {
      for (final signed in [450.0, -450.0]) {
        final parts = searchHaystackFor(tx(amount: signed)).split(' || ');
        expect(parts, contains('450.00'));
        expect(parts, contains('450'));
      }
    });

    test('non-whole amounts: trailing zeros trimmed, cents kept', () {
      final parts = searchHaystackFor(tx(amount: 450.50)).split(' || ');
      expect(parts, contains('450.50'));
      expect(parts, contains('450.5'));
      // "450" still matches via substring, exactly like the search does.
      expect(searchHaystackFor(tx(amount: 450.50)).contains('450'), isTrue);
    });

    test('searching "450" or "450.00" hits a 450.00 transaction', () {
      final hay = searchHaystackFor(tx(amount: -450.0));
      expect(hay.contains('450'), isTrue);
      expect(hay.contains('450.00'), isTrue);
      expect(hay.contains('451'), isFalse);
    });
  });

  group('Task 8 — amount-range predicate (TxFilters.matches)', () {
    Map<String, dynamic> tx(double amount) => {'amount': amount};

    test('only-min: inclusive lower bound on the absolute amount', () {
      const f = TxFilters(minAmount: 100);
      expect(f.isActive, isTrue);
      expect(f.matches(tx(99.99)), isFalse);
      expect(f.matches(tx(100.0)), isTrue);
      expect(f.matches(tx(250.0)), isTrue);
      // Plaid sign convention: inflows are negative — abs() applies.
      expect(f.matches(tx(-250.0)), isTrue);
      expect(f.matches(tx(-50.0)), isFalse);
    });

    test('only-max: inclusive upper bound on the absolute amount', () {
      const f = TxFilters(maxAmount: 100);
      expect(f.isActive, isTrue);
      expect(f.matches(tx(100.0)), isTrue);
      expect(f.matches(tx(100.01)), isFalse);
      expect(f.matches(tx(-99.0)), isTrue);
      expect(f.matches(tx(-101.0)), isFalse);
    });

    test('min+max window combines with the other filters', () {
      const f = TxFilters(minAmount: 100, maxAmount: 200, flow: TxFlow.expense);
      expect(f.matches(tx(150.0)), isTrue); // positive = expense
      expect(f.matches(tx(-150.0)), isFalse); // in window but income
      expect(f.matches(tx(99.0)), isFalse);
      expect(f.matches(tx(201.0)), isFalse);
      expect(f.badgeCount, 2); // amount counts as ONE filter + flow
    });

    test('copyWith(clearAmounts: true) clears both bounds', () {
      const f = TxFilters(minAmount: 100, maxAmount: 200);
      final cleared = f.copyWith(clearAmounts: true);
      expect(cleared.minAmount, isNull);
      expect(cleared.maxAmount, isNull);
      expect(cleared.isActive, isFalse);
    });

    test('parseFilterAmount is lenient; formatFilterAmount is compact', () {
      expect(parseFilterAmount(r' $1,200.50 '), 1200.50);
      expect(parseFilterAmount('-450'), 450.0); // sign discarded (abs filter)
      expect(parseFilterAmount(''), isNull);
      expect(parseFilterAmount('abc'), isNull);
      expect(formatFilterAmount(450.0), '450');
      expect(formatFilterAmount(450.5), '450.50');
    });
  });

  group('Task 8 — search + amount filter in the widget', () {
    testWidgets('typing a note fragment surfaces the noted row only',
        (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(_unboundedHost(_tab(_rows([
        (amount: 10.0, notes: 'lunch reimbursement'),
        (amount: 20.0, notes: null),
        (amount: 30.0, notes: null),
      ]))));

      await _search(tester, 'reimburse');

      expect(find.text('Row 0'), findsOneWidget);
      expect(find.text('Row 1'), findsNothing);
      expect(find.text('Row 2'), findsNothing);
    });

    testWidgets('typing "450" surfaces the 450.00 row regardless of sign',
        (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(_unboundedHost(_tab(_rows([
        (amount: -450.0, notes: null),
        (amount: 20.0, notes: null),
      ]))));

      await _search(tester, '450');
      expect(find.text('Row 0'), findsOneWidget);
      expect(find.text('Row 1'), findsNothing);

      await _search(tester, '450.00');
      expect(find.text('Row 0'), findsOneWidget);
      expect(find.text('Row 1'), findsNothing);
    });

    testWidgets(
        'dialog min/max filters the list, shows a removable chip, and '
        'combines with search', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      final txs = _rows([
        (amount: 15.0, notes: 'team lunch'),
        (amount: 250.0, notes: 'team lunch'),
        (amount: 999.0, notes: null),
      ]);
      await tester.pumpWidget(_unboundedHost(_tab(txs)));

      // Search first so the amount filter has to AND with it.
      await _search(tester, 'team lunch');
      expect(find.text('Row 2'), findsNothing);

      await tester.tap(find.byTooltip('Filter transactions'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Min'), '100');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      // ≥100 ∧ matches "team lunch": only Row 1 (250.00) survives.
      expect(find.text('Row 1'), findsOneWidget);
      expect(find.text('Row 0'), findsNothing);
      expect(find.text('Row 2'), findsNothing);

      // Active-filter chip for the open-ended range, removable like the
      // existing ones — deleting it restores the search-only result.
      expect(find.text('≥ 100'), findsOneWidget);
      // The only Icon inside the chip is its delete affordance (no
      // avatar/checkmark), so byType is robust across M2/M3 defaults.
      await tester.tap(find.descendant(
        of: find.widgetWithText(InputChip, '≥ 100'),
        matching: find.byType(Icon),
      ));
      await tester.pump();
      expect(find.text('Row 0'), findsOneWidget);
      expect(find.text('Row 1'), findsOneWidget);
      expect(find.text('Row 2'), findsNothing);
    });

    testWidgets('min > max is swapped gracefully on Apply', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(_unboundedHost(_tab(_rows([
        (amount: 5.0, notes: null),
        (amount: 50.0, notes: null),
        (amount: 500.0, notes: null),
      ]))));

      await tester.tap(find.byTooltip('Filter transactions'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Min'), '100');
      await tester.enterText(find.widgetWithText(TextField, 'Max'), '10');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();

      // Applied as 10–100, not an empty impossible window.
      expect(find.text('10–100'), findsOneWidget);
      expect(find.text('Row 1'), findsOneWidget); // 50 in window
      expect(find.text('Row 0'), findsNothing); // 5 below
      expect(find.text('Row 2'), findsNothing); // 500 above
    });
  });

  group('Task 10 — zero-match empty state', () {
    testWidgets(
        'no matches shows the empty state; Clear restores the full list '
        '(search + filters, eager path)', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(_unboundedHost(_tab(_rows([
        (amount: 10.0, notes: null),
        (amount: 20.0, notes: null),
        (amount: 30.0, notes: null),
      ]))));

      // An amount filter AND a search that jointly match nothing.
      await tester.tap(find.byTooltip('Filter transactions'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Min'), '5000');
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      await _search(tester, 'zzz-no-such-merchant');

      expect(find.text('No transactions match'), findsOneWidget);
      expect(find.text('Clear filters & search'), findsOneWidget);
      expect(find.text('Showing 0 of 3'), findsOneWidget);
      expect(find.text('Row 0'), findsNothing);

      await tester.tap(find.text('Clear filters & search'));
      await tester.pump();

      // Search text, filter chip and empty state all gone; rows back.
      expect(find.text('No transactions match'), findsNothing);
      expect(find.text('≥ 5000'), findsNothing);
      expect(find.text('Showing 3 of 3'), findsOneWidget);
      expect(find.text('Row 0'), findsOneWidget);
      expect(find.text('Row 1'), findsOneWidget);
      expect(find.text('Row 2'), findsOneWidget);
      // The search field itself was cleared, not just the query state.
      expect(
          tester.widget<TextField>(find.byType(TextField).first).controller!
              .text,
          isEmpty);
    });

    testWidgets('bounded host (virtualised path) renders the same state',
        (tester) async {
      _setViewSize(tester, const Size(800, 600));
      await tester.pumpWidget(_boundedHost(_tab(_rows([
        (amount: 10.0, notes: null),
        (amount: 20.0, notes: null),
      ]))));
      await tester.pump();

      await _search(tester, 'zzz-no-such-merchant');

      expect(find.text('No transactions match'), findsOneWidget);
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('Clear filters & search'));
      await tester.pump();
      expect(find.text('Row 0'), findsOneWidget);
      expect(find.text('Row 1'), findsOneWidget);
    });

    testWidgets(
        'the no-transactions-at-all empty state is untouched (no clear '
        'button there)', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(_unboundedHost(_tab(const [])));
      await tester.pump();

      expect(find.text('No transactions yet'), findsOneWidget);
      expect(find.text('No transactions match'), findsNothing);
      expect(find.text('Clear filters & search'), findsNothing);
    });
  });

  group('Task 13 — whole-history cascade & filter dialog options', () {
    const loadingLabel =
        'Loading your full history so every option is available…';

    // Drives the whole-history cascade to completion with fixed-duration
    // pumps. pumpAndSettle can't be used here: between cascade iterations
    // only the host's fetch timer is pending (no frame scheduled yet), so
    // it would settle early and leave the cascade mid-flight.
    Future<void> pumpCascade(WidgetTester tester, [int frames = 12]) async {
      for (var i = 0; i < frames; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
    }

    testWidgets('search cascade pulls pages at the backend cap, not 50',
        (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      final limits = <int?>[];
      await tester.pumpWidget(_localizedApp(SingleChildScrollView(
        primary: false,
        child: _PagedHost(allRows: _pagedRows(1100), loadLimits: limits),
      )));
      await tester.pump();

      await _search(tester, 'zzz-no-such-merchant');
      await pumpCascade(tester);

      // 1050 unloaded rows at the 500-row backend cap: exactly 3 cascade
      // round-trips (50→550→1050→1100), not the 21 a 50-row page needs.
      expect(
        limits,
        [kTxBackendMaxPageSize, kTxBackendMaxPageSize, kTxBackendMaxPageSize],
      );
      expect(find.text('Showing 0 of 1100'), findsOneWidget);
    });

    testWidgets(
        'opening the filter dialog loads full history exactly once and '
        'surfaces categories that only exist in unloaded pages',
        (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      final limits = <int?>[];
      // 'TRAVEL' only occurs beyond the first page — before this fix it
      // could never be offered (options were computed from loaded rows).
      final rows = _pagedRows(60,
          category: (i) => i >= 50 ? 'TRAVEL' : 'FOOD_AND_DRINK');
      await tester.pumpWidget(_localizedApp(SingleChildScrollView(
        primary: false,
        child: _PagedHost(allRows: rows, loadLimits: limits),
      )));
      await tester.pump();

      await tester.tap(find.byTooltip('Filter transactions'));
      await tester.pump();

      // Cascade in flight: lightweight loading affordance, deep category
      // not offered yet.
      expect(find.text(loadingLabel), findsOneWidget);
      expect(find.text('Travel'), findsNothing);

      await pumpCascade(tester);

      // Exactly ONE full-history pull, at the backend cap.
      expect(limits, [kTxBackendMaxPageSize]);
      expect(find.text(loadingLabel), findsNothing);
      expect(find.text('Travel'), findsOneWidget);

      // Reopen: history already fully loaded — no re-cascade, no spinner,
      // options still complete.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Filter transactions'));
      await tester.pumpAndSettle();

      expect(limits, hasLength(1));
      expect(find.text(loadingLabel), findsNothing);
      expect(find.text('Travel'), findsOneWidget);
    });
  });
}
