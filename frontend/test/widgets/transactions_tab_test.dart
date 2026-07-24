import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/utils/theme_colors.dart';
import 'package:patrimonio/widgets/transactions_tab.dart';

// TransactionsTab takes plain data + callbacks, so no ApiService is needed
// at all (per MEMORY we do NOT subclass ApiService in widget tests).

/// Recorded onUpdate invocation — the fields the detail panel's Save sends.
typedef _Update = ({String id, String? userCategory, String? userNotes});

/// [n] synthetic transactions, newest first, one per day.
///
/// Each row's `user_description` ("Row i") is what `displayLabel` shows, so
/// finders can target an exact row. Account names are distinct so each row's
/// meta line ("<category> · Checking i") is a unique tap target that is NOT
/// wrapped in the label's double-tap GestureDetector (whose gesture-arena
/// delay makes single taps on the label flaky to deliver in tests).
List<Map<String, dynamic>> _makeTxs(int n) {
  final today = DateTime.now();
  return [
    for (var i = 0; i < n; i++)
      {
        'id': 'tx-$i',
        'date': DateFormat('yyyy-MM-dd')
            .format(today.subtract(Duration(days: i))),
        'amount': 10.0 + i,
        'currency': 'USD',
        'description': 'COFFEE PLACE $i',
        'user_description': 'Row $i',
        // Row 0 differs so the detail-panel tests can assert both the
        // prettified prefill ("Food & drink") and a cross-row suggestion
        // ("Gas") sourced from _distinctCategories().
        'category': i == 0 ? 'FOOD_AND_DRINK' : 'TRANSPORTATION_GAS',
        'account_name': 'Checking $i',
      },
  ];
}

Widget _localizedApp(Widget body) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: body),
    );

/// Dashboard-style host: page-level scroll view → the tab sees an UNBOUNDED
/// height and uses its window-derived inner-list sizing. `primary: false`
/// keeps the host from attaching to the route's PrimaryScrollController,
/// which the tab's inner Scrollbar+ListView pair resolves on the test
/// platform (two attached positions would trip the scrollbar debug assert).
Widget _unboundedHost(Widget tab) =>
    _localizedApp(SingleChildScrollView(primary: false, child: tab));

/// Account-panel-style host: fixed header stub + Expanded slot → the tab
/// sees a BOUNDED height and must size/scroll the rows region from it.
Widget _boundedHost(Widget tab) => _localizedApp(Column(
      children: [
        const SizedBox(height: 120),
        Expanded(child: tab),
      ],
    ));

TransactionsTab _tab(
  List<dynamic> txs, {
  List<_Update>? updates,
  List<dynamic> fxTransfers = const [],
  bool hasMore = false,
  bool singleAccountContext = false,
  double? runningBalanceAnchor,
  NumberFormat? currencyFormat,
  String targetCurrency = 'USD',
  double usdMxnRate = 0,
}) {
  return TransactionsTab(
    transactions: txs,
    conversionFactor: 1.0,
    currencyFormat: currencyFormat ?? NumberFormat.currency(symbol: r'$'),
    targetCurrency: targetCurrency,
    usdMxnRate: usdMxnRate,
    fxTransfers: fxTransfers,
    hasMore: hasMore,
    singleAccountContext: singleAccountContext,
    runningBalanceAnchor: runningBalanceAnchor,
    onUpdate: updates == null
        ? null
        : (String id,
            {String? userCategory,
            String? userNotes,
            String? userDescription,
            String? accountId}) async {
            updates.add(
                (id: id, userCategory: userCategory, userNotes: userNotes));
          },
  );
}

void _setViewSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Finder for the Scrollable inside the tab's inner ListView (the search
/// TextField also contains a Scrollable, so plain byType is ambiguous).
Finder _innerListScrollable() => find
    .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
    .first;

void main() {
  group('Task A — short-window clamp', () {
    testWidgets('>50 rows on a short window renders without a clamp crash',
        (tester) async {
      // 480 logical px tall: h * 0.78 = 374.4 < the old 400px floor, which
      // made clamp(400, 374.4) throw ArgumentError inside build() and paint
      // the whole region as the red error widget.
      _setViewSize(tester, const Size(800, 480));

      await tester.pumpWidget(_unboundedHost(_tab(_makeTxs(60))));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.text('Row 0'), findsOneWidget);
    });
  });

  group('Task B — detail-panel Save diffing (diffEditedField)', () {
    test('unchanged text returns null → no override is sent', () {
      expect(diffEditedField('Food & drink', 'Food & drink'), isNull);
    });

    test('whitespace-only difference still counts as unchanged', () {
      expect(diffEditedField('  Food & drink ', 'Food & drink'), isNull);
      expect(diffEditedField('', '  '), isNull);
    });

    test('a real edit returns the trimmed value', () {
      expect(diffEditedField(' Groceries ', 'Food & drink'), 'Groceries');
    });

    test('clearing a prefilled field returns the empty string (clear)', () {
      expect(diffEditedField('', 'Food & drink'), '');
    });
  });

  group('Task 14 — running balance (runningBalancesFor)', () {
    Map<String, dynamic> tx(String id, {double? amount, double? balanceAfter}) {
      return {
        'id': id,
        if (amount != null) 'amount': amount,
        if (balanceAfter != null) 'balance_after': balanceAfter,
      };
    }

    test('top-of-list row gets exactly the anchor, marked estimated', () {
      final out = runningBalancesFor([tx('a', amount: 50.0)], anchor: 1000.0);
      expect(out['a'], (value: 1000.0, estimated: true));
    });

    test('walk with mixed signs: inflow (+) lowers older balances, '
        'outflow (−) raises them', () {
      // Newest-first; storage sign convention: positive = inflow,
      // negative = outflow, so balance_before = balance_after − amount.
      final out = runningBalancesFor([
        tx('a', amount: 50.0), // after a: 1000 (anchor)
        tx('b', amount: -20.0), // after b: 1000 − 50   = 950
        tx('c', amount: 10.0), // after c: 950 − (−20) = 970
      ], anchor: 1000.0);
      expect(out['a'], (value: 1000.0, estimated: true));
      expect(out['b'], (value: 950.0, estimated: true));
      expect(out['c'], (value: 970.0, estimated: true));
    });

    test('persisted balance_after wins over the walk and is not marked '
        'estimated', () {
      final out = runningBalancesFor([
        tx('a', amount: 50.0),
        // Walk would say 950 — the statement's own figure must win.
        tx('b', amount: -20.0, balanceAfter: 999.0),
        // …and re-anchor the rows beneath it: 999 − (−20) = 1019.
        tx('c', amount: 10.0),
      ], anchor: 1000.0);
      expect(out['b'], (value: 999.0, estimated: false));
      expect(out['c'], (value: 1019.0, estimated: true));
    });

    test('a row with no amount is a gap: it and everything below get '
        'nothing (no wrong numbers)', () {
      final out = runningBalancesFor([
        tx('a', amount: 50.0),
        tx('b'), // amount missing → walk below is unsound
        tx('c', amount: 10.0),
      ], anchor: 1000.0);
      expect(out['a'], (value: 1000.0, estimated: true));
      expect(out['b'], (value: 950.0, estimated: true));
      expect(out.containsKey('c'), isFalse);
    });

    test('no anchor → no estimates; persisted values still render and '
        're-anchor the rows below', () {
      final out = runningBalancesFor([
        tx('a', amount: 50.0),
        tx('b', amount: -20.0, balanceAfter: 500.0),
        tx('c', amount: 10.0),
      ], anchor: null);
      expect(out.containsKey('a'), isFalse);
      expect(out['b'], (value: 500.0, estimated: false));
      expect(out['c'], (value: 520.0, estimated: true));
    });
  });

  group('Task 14 — running balance + meta line per host context', () {
    testWidgets(
        'single-account context: rows show the balance line (≈ for '
        'estimates, plain for persisted) and the meta line drops the '
        'account name', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      final txs = _makeTxs(3); // amounts 10, 11, 12 — all inflows (positive)
      txs[1]['balance_after'] = 555.25; // statement-persisted row
      await tester.pumpWidget(_unboundedHost(_tab(
        txs,
        singleAccountContext: true,
        runningBalanceAnchor: 1000.0,
      )));
      await tester.pump();

      // Top row = anchor, estimated → '≈' prefix.
      expect(find.text(r'Bal. ≈ $1,000.00'), findsOneWidget);
      // Persisted statement balance renders plain (no '≈') and wins
      // over the walk (which would have said 990.00).
      expect(find.text(r'Bal. $555.25'), findsOneWidget);
      expect(find.textContaining(r'$990.00'), findsNothing);
      // Row below the persisted one re-anchors: it's OLDER, so its
      // balance predates row b's inflow of 11 arriving:
      // 555.25 − 11 = 544.25.
      expect(find.text(r'Bal. ≈ $544.25'), findsOneWidget);

      // Meta line drops the pointless single-account name…
      expect(find.textContaining('Checking'), findsNothing);
      // …but keeps the category segment.
      expect(find.text('Food & drink'), findsOneWidget);
    });

    testWidgets(
        'dashboard (multi-account) context unchanged: account name in the '
        'meta line, no balance line', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      final txs = _makeTxs(3);
      txs[1]['balance_after'] = 555.25; // even a persisted value stays hidden
      await tester.pumpWidget(_unboundedHost(_tab(txs)));
      await tester.pump();

      expect(find.text('Food & drink · Checking 0'), findsOneWidget);
      expect(find.textContaining('Bal.'), findsNothing);
      expect(find.textContaining('≈'), findsNothing);
    });
  });

  group('Task B — detail-panel category editor', () {
    testWidgets(
        'prefills the prettified label and a no-edit Save sends nothing',
        (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      final updates = <_Update>[];
      await tester
          .pumpWidget(_unboundedHost(_tab(_makeTxs(3), updates: updates)));

      // Open the detail panel for row 0 (raw category FOOD_AND_DRINK).
      await tester.tap(find.text('Food & drink · Checking 0'));
      await tester.pumpAndSettle();

      // The editor is seeded with the PRETTIFIED label, never the raw enum.
      expect(find.widgetWithText(TextField, 'Food & drink'), findsOneWidget);
      expect(find.text('FOOD_AND_DRINK'), findsNothing);

      // A clean (unedited) open shows NO Save footer at all — the button
      // only appears once a field actually differs from its prefill, so an
      // open-then-dismiss can never silently convert the auto-category
      // into a user override of the raw enum string.
      expect(find.text('Save'), findsNothing);

      // Typing a real change makes Save appear; reverting it back to the
      // prefill hides it again (diffed, not just "touched").
      final catField = find.widgetWithText(TextField, 'Category');
      await tester.enterText(catField, 'Something else');
      await tester.pumpAndSettle();
      expect(find.text('Save'), findsOneWidget);
      await tester.enterText(catField, 'Food & drink');
      await tester.pumpAndSettle();
      expect(find.text('Save'), findsNothing);

      // Dismiss (wide layout: the leading close X) → nothing is sent.
      await tester.tap(find.byTooltip('Close'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(TextField, 'Food & drink'),
          findsNothing); // panel closed
      expect(updates, isEmpty);
    });

    testWidgets(
        'autocomplete suggests categories from other rows and Save sends '
        'only the changed field', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      final updates = <_Update>[];
      await tester
          .pumpWidget(_unboundedHost(_tab(_makeTxs(3), updates: updates)));

      await tester.tap(find.text('Food & drink · Checking 0'));
      await tester.pumpAndSettle();

      final catField = find.widgetWithText(TextField, 'Category');
      expect(catField, findsOneWidget);
      await tester.ensureVisible(catField);
      await tester.enterText(catField, 'ga');
      await tester.pumpAndSettle();

      // Type-ahead fed by _distinctCategories(): "Gas" comes from the
      // OTHER rows' TRANSPORTATION_GAS, prettified.
      expect(find.text('Gas'), findsOneWidget);
      await tester.tap(find.text('Gas'));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(updates, hasLength(1));
      expect(updates.single.id, 'tx-0');
      expect(updates.single.userCategory, 'Gas');
      // Notes untouched → must be omitted (null = leave alone), not ''.
      expect(updates.single.userNotes, isNull);
    });
  });

  group('Task C — bounded host (account panel slot)', () {
    testWidgets(
        'side-panel-sized slot: ≤50 rows scroll inside the slot and the '
        'last row is reachable', (tester) async {
      _setViewSize(tester, const Size(800, 600));

      // 40 rows: previously the eager Column built ~57px rows straight into
      // the bounded slot — everything below the fold was clipped and
      // unreachable (plus RenderFlex overflow stripes in debug).
      await tester.pumpWidget(_boundedHost(_tab(_makeTxs(40))));
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.scrollUntilVisible(
        find.text('Row 39'),
        300,
        scrollable: _innerListScrollable(),
      );
      expect(find.text('Row 39'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'phone-sized bottom-sheet slot: >50 rows sized from the slot (not '
        'the window) and the last row is reachable', (tester) async {
      _setViewSize(tester, const Size(390, 700));

      await tester.pumpWidget(_boundedHost(_tab(_makeTxs(60))));
      await tester.pump();
      expect(tester.takeException(), isNull);

      await tester.scrollUntilVisible(
        find.text('Row 59'),
        300,
        scrollable: _innerListScrollable(),
      );
      expect(find.text('Row 59'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Task 6 — FX-transfer rows: TRANSFER pill + neutral amount', () {
    /// One auto-detected link between tx-1 (sending leg) and tx-0
    /// (receiving leg). Same map shape the dashboard hands the tab
    /// (cash_fx_transfers rows consumed by _fxTransferBlock).
    List<Map<String, dynamic>> link({required bool confirmed}) => [
          {
            'id': 'fx-1',
            'source_tx_id': 'tx-1',
            'dest_tx_id': 'tx-0',
            'user_confirmed': confirmed,
          },
        ];

    testWidgets(
        'linked rows show the pill and a neutral ⇄ amount; a normal row '
        'keeps income/expense styling and no pill', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      final txs = _makeTxs(3);
      // Row 0 is the RECEIVING leg (positive amount = inflow in the
      // storage sign convention) — exactly the case that must NOT render
      // as +green income because it's a transfer. Row 2 is a genuine
      // income row (positive = inflow) for contrast.
      txs[0]['amount'] = 25.0;
      txs[2]['amount'] = 12.0;

      await tester.pumpWidget(
          _unboundedHost(_tab(txs, fxTransfers: link(confirmed: false))));
      await tester.pump();

      // Both legs — and ONLY the two legs — carry the pill.
      expect(find.text('Transfer'), findsNWidgets(2));

      // Transfer amounts swap the +/− sign for ⇄ and render in neutral
      // textPrimary (receiving leg must NOT be positive-green).
      expect(find.text('⇄ \$25.00'), findsOneWidget); // tx-0, dest leg
      expect(find.text('⇄ \$11.00'), findsOneWidget); // tx-1, source leg
      expect(find.text('+\$25.00'), findsNothing);
      expect(find.text('−\$11.00'), findsNothing);
      final ctx = tester.element(find.text('⇄ \$25.00'));
      for (final t
          in tester.widgetList<Text>(find.textContaining('⇄'))) {
        expect(t.style!.color, ctx.textPrimary);
        expect(t.style!.color, isNot(ctx.positive));
      }

      // Auto-detected (unconfirmed) links use the amber pending accent.
      for (final pill in tester.widgetList<Text>(find.text('Transfer'))) {
        expect(pill.style!.color, ctx.warning);
      }

      // The unlinked income row keeps the +green treatment and the
      // unlinked expense rows are untouched.
      final income = tester.widget<Text>(find.text('+\$12.00'));
      expect(income.style!.color, ctx.positive);
    });

    testWidgets('a user-confirmed link renders the pill in the teal '
        '"linked" accent', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(_unboundedHost(
          _tab(_makeTxs(3), fxTransfers: link(confirmed: true))));
      await tester.pump();

      final pills = find.text('Transfer');
      expect(pills, findsNWidgets(2));
      final ctx = tester.element(pills.first);
      for (final pill in tester.widgetList<Text>(pills)) {
        expect(pill.style!.color, ctx.tealAccent);
      }
    });
  });

  group('Task 7 — date grouping: day labels + month landmarks', () {
    /// "June 2026"-style landmark label, sentence-cased the same way the
    /// widget does it (en is already capitalized; es month names aren't).
    String monthLabel(DateTime d) {
      final raw = DateFormat.yMMMM().format(d);
      return raw[0].toUpperCase() + raw.substring(1);
    }

    /// Rows pinned to two calendar months safely outside the
    /// Today/Yesterday band (2 and 3 months back from the test run date).
    /// Storage sign convention: positive = inflow, negative = outflow, so
    /// month A nets to +\$60 (100 in, 40 out); month B to −\$40
    /// (10 in, 50 out) so both subtotal signs are exercised.
    ({DateTime monthA, DateTime monthB, List<Map<String, dynamic>> txs})
        twoMonths() {
      final now = DateTime.now();
      final monthA = DateTime(now.year, now.month - 2, 1);
      final monthB = DateTime(now.year, now.month - 3, 1);
      Map<String, dynamic> tx(String id, DateTime date, double amount) => {
            'id': id,
            'date': DateFormat('yyyy-MM-dd').format(date),
            'amount': amount,
            'currency': 'USD',
            'description': 'TX $id',
            'user_description': 'Row $id',
            'category': 'FOOD_AND_DRINK',
            'account_name': 'Checking',
          };
      return (
        monthA: monthA,
        monthB: monthB,
        txs: [
          // Newest first, like the API hands them out.
          tx('a1', DateTime(monthA.year, monthA.month, 15), 100.0),
          tx('a2', DateTime(monthA.year, monthA.month, 10), -40.0),
          tx('b1', DateTime(monthB.year, monthB.month, 20), 10.0),
          tx('b2', DateTime(monthB.year, monthB.month, 5), -50.0),
        ],
      );
    }

    testWidgets('a 3-days-ago header shows weekday AND date, not a bare '
        'weekday', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(_unboundedHost(_tab(_makeTxs(5))));
      await tester.pump();

      final d = DateTime.now().subtract(const Duration(days: 3));
      final expected =
          '${DateFormat('EEEE').format(d)}, ${DateFormat.MMMd().format(d)}';
      expect(find.text(expected), findsOneWidget);
      // The old ambiguous bare-weekday header is gone.
      expect(find.text(DateFormat('EEEE').format(d)), findsNothing);
      // Today/Yesterday specials are untouched.
      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Yesterday'), findsOneWidget);
    });

    testWidgets(
        'rows spanning two months get month landmarks with the correct '
        'net subtotals (income positive)', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      final data = twoMonths();
      await tester.pumpWidget(_unboundedHost(_tab(data.txs)));
      await tester.pump();

      expect(find.text(monthLabel(data.monthA)), findsOneWidget);
      expect(find.text(monthLabel(data.monthB)), findsOneWidget);
      // Month A: 100 in − 40 out → +$60 net; month B: 10 in − 50 out →
      // −$40 net. No "(partial)" suffix when hasMore is false.
      expect(find.text('+\$60.00 net'), findsOneWidget);
      expect(find.text('−\$40.00 net'), findsOneWidget);
      expect(find.textContaining('(partial)'), findsNothing);
    });

    testWidgets(
        'with more pages available only the OLDEST loaded month is '
        'flagged partial', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      final data = twoMonths();
      await tester.pumpWidget(_unboundedHost(_tab(data.txs, hasMore: true)));
      await tester.pump();

      // Month A is fully ahead of the pagination boundary → plain net;
      // month B may be cut off mid-month → honest "(partial)" suffix.
      expect(find.text('+\$60.00 net'), findsOneWidget);
      expect(find.text('−\$40.00 net (partial)'), findsOneWidget);
    });

    testWidgets('the virtualised (>50 rows) path gets the same month '
        'landmarks', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      final now = DateTime.now();
      final monthA = DateTime(now.year, now.month - 2, 1);
      final monthB = DateTime(now.year, now.month - 3, 1);
      // 58 rows (30 + 28), newest first — well past the eager threshold
      // so the inner ListView.builder path is exercised.
      final txs = [
        for (var day = 30; day >= 1; day--)
          {
            'id': 'a-$day',
            'date': DateFormat('yyyy-MM-dd')
                .format(DateTime(monthA.year, monthA.month, day)),
            'amount': 1.0,
            'currency': 'USD',
            'description': 'TX a-$day',
            'user_description': 'Row a-$day',
            'category': 'FOOD_AND_DRINK',
            'account_name': 'Checking',
          },
        for (var day = 28; day >= 1; day--)
          {
            'id': 'b-$day',
            'date': DateFormat('yyyy-MM-dd')
                .format(DateTime(monthB.year, monthB.month, day)),
            'amount': 1.0,
            'currency': 'USD',
            'description': 'TX b-$day',
            'user_description': 'Row b-$day',
            'category': 'FOOD_AND_DRINK',
            'account_name': 'Checking',
          },
      ];
      await tester.pumpWidget(_unboundedHost(_tab(txs)));
      await tester.pump();

      // The newest month's landmark leads the list…
      expect(find.text(monthLabel(monthA)), findsOneWidget);
      // …and the older month's landmark is reachable by scrolling the
      // inner virtualised list.
      await tester.scrollUntilVisible(
        find.text(monthLabel(monthB)),
        300,
        scrollable: _innerListScrollable(),
      );
      expect(find.text(monthLabel(monthB)), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('MXN reporting mode — rows carry the converted ≈ line on every width',
      () {
    // Regression: narrow (phone) viewports used to hide the converted
    // estimate under the native amount, so in MXN reporting mode the month
    // headers/nets (reporting currency) sat over USD-only rows with nothing
    // visible to reconcile them against.
    TransactionsTab mxnTab(List<dynamic> txs) => _tab(
          txs,
          currencyFormat: NumberFormat.currency(symbol: r'MX$'),
          targetCurrency: 'MXN',
          usdMxnRate: 20.0,
        );

    testWidgets('narrow: a USD row in MXN mode shows the ≈ MXN estimate',
        (tester) async {
      _setViewSize(tester, const Size(420, 900));
      // One USD row of +10.00 → at 20.0 the MXN estimate is 200.00.
      await tester.pumpWidget(_unboundedHost(mxnTab(_makeTxs(1))));
      await tester.pump();

      expect(find.text(r'≈ MX$200.00'), findsOneWidget);
    });

    testWidgets('wide: the estimate is still there (unchanged behavior)',
        (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(_unboundedHost(mxnTab(_makeTxs(1))));
      await tester.pump();

      expect(find.text(r'≈ MX$200.00'), findsOneWidget);
    });

    testWidgets('no estimate when the row is already in the reporting currency',
        (tester) async {
      _setViewSize(tester, const Size(420, 900));
      final txs = _makeTxs(1)
          .map((t) => {...t, 'currency': 'MXN'})
          .toList();
      await tester.pumpWidget(_unboundedHost(mxnTab(txs)));
      await tester.pump();

      expect(find.textContaining('≈'), findsNothing);
    });

    testWidgets(
        'in-session USD→MXN reporting swap re-converts the month-header '
        'nets (memo invalidates on targetCurrency)', (tester) async {
      // Regression: _ensureMonthNets memoized on (tx identity, fx identity,
      // usdMxnRate) but NOT targetCurrency, so swapping the reporting
      // currency in the app bar (same tx list instance, same rate) kept the
      // cached USD nets and merely relabeled them MXN — headers and the
      // rows' ≈ MXN lines visibly disagreed until a full reload.
      _setViewSize(tester, const Size(1200, 900));
      final now = DateTime.now();
      final month = DateTime(now.year, now.month - 2, 1);
      // Same list instance across both pumps — the swap changes ONLY the
      // reporting currency, exactly like the app-bar toggle.
      final txs = [
        {
          'id': 'm1',
          'date': DateFormat('yyyy-MM-dd')
              .format(DateTime(month.year, month.month, 15)),
          'amount': 100.0,
          'currency': 'USD',
          'description': 'TX m1',
          'user_description': 'Row m1',
          'category': 'FOOD_AND_DRINK',
          'account_name': 'Checking',
        },
        {
          'id': 'm2',
          'date': DateFormat('yyyy-MM-dd')
              .format(DateTime(month.year, month.month, 10)),
          'amount': -40.0,
          'currency': 'USD',
          'description': 'TX m2',
          'user_description': 'Row m2',
          'category': 'FOOD_AND_DRINK',
          'account_name': 'Checking',
        },
      ];

      // USD mode first: +100 − 40 → +$60.00 net (primes the memo).
      await tester.pumpWidget(_unboundedHost(_tab(
        txs,
        currencyFormat: NumberFormat.currency(symbol: r'$'),
        targetCurrency: 'USD',
        usdMxnRate: 20.0,
      )));
      await tester.pump();
      expect(find.text('+\$60.00 net'), findsOneWidget);

      // Swap to MXN reporting — same State, same tx list identity, same
      // rate. The header must show the CONVERTED net (60 × 20 = 1,200),
      // not the stale USD figure relabeled MX$.
      await tester.pumpWidget(_unboundedHost(mxnTab(txs)));
      await tester.pump();
      expect(find.text(r'+MX$1,200.00 net'), findsOneWidget);
      expect(find.text(r'+MX$60.00 net'), findsNothing);
    });
  });
}
