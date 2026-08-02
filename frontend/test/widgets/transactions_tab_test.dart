import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/utils/theme_colors.dart';
import 'package:patrimonio/utils/transactions_tab_logic.dart';
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
        'date': DateFormat(
          'yyyy-MM-dd',
        ).format(today.subtract(Duration(days: i))),
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

Widget _localizedApp(Widget body, {Locale? locale}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: body),
);

/// Dashboard-style host: page-level scroll view → the tab sees an UNBOUNDED
/// height and uses its window-derived inner-list sizing. `primary: false`
/// keeps the host from attaching to the route's PrimaryScrollController,
/// which the tab's inner Scrollbar+ListView pair resolves on the test
/// platform (two attached positions would trip the scrollbar debug assert).
Widget _unboundedHost(Widget tab, {Locale? locale}) => _localizedApp(
  SingleChildScrollView(primary: false, child: tab),
  locale: locale,
);

/// Account-panel-style host: fixed header stub + Expanded slot → the tab
/// sees a BOUNDED height and must size/scroll the rows region from it.
Widget _boundedHost(Widget tab) => _localizedApp(
  Column(
    children: [
      const SizedBox(height: 120),
      Expanded(child: tab),
    ],
  ),
);

TransactionsTab _tab(
  List<dynamic> txs, {
  List<dynamic> accounts = const [],
  List<_Update>? updates,
  List<dynamic> fxTransfers = const [],
  bool hasMore = false,
  bool singleAccountContext = false,
  double? runningBalanceAnchor,
  NumberFormat? currencyFormat,
  String targetCurrency = 'USD',
  double usdMxnRate = 0,
  ({DateTime start, DateTime end})? dateSeed,
  VoidCallback? onDateSeedConsumed,
  String? categorySeed,
  VoidCallback? onCategorySeedConsumed,
  String? accountIdSeed,
  VoidCallback? onAccountSeedConsumed,
  DateTime? createdSinceSeed,
  VoidCallback? onCreatedSinceSeedConsumed,
}) {
  return TransactionsTab(
    transactions: txs,
    accounts: accounts,
    conversionFactor: 1.0,
    currencyFormat: currencyFormat ?? NumberFormat.currency(symbol: r'$'),
    targetCurrency: targetCurrency,
    usdMxnRate: usdMxnRate,
    fxTransfers: fxTransfers,
    hasMore: hasMore,
    singleAccountContext: singleAccountContext,
    runningBalanceAnchor: runningBalanceAnchor,
    dateSeed: dateSeed,
    onDateSeedConsumed: onDateSeedConsumed,
    categorySeed: categorySeed,
    onCategorySeedConsumed: onCategorySeedConsumed,
    accountIdSeed: accountIdSeed,
    onAccountSeedConsumed: onAccountSeedConsumed,
    createdSinceSeed: createdSinceSeed,
    onCreatedSinceSeedConsumed: onCreatedSinceSeedConsumed,
    onUpdate: updates == null
        ? null
        : (
            String id, {
            String? userCategory,
            String? userNotes,
            String? userDescription,
            String? accountId,
          }) async {
            updates.add((
              id: id,
              userCategory: userCategory,
              userNotes: userNotes,
            ));
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
    testWidgets('>50 rows on a short window renders without a clamp crash', (
      tester,
    ) async {
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
    testWidgets('single-account context: rows show the balance line (≈ for '
        'estimates, plain for persisted) and the meta line drops the '
        'account name', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      final txs = _makeTxs(3); // amounts 10, 11, 12 — all inflows (positive)
      txs[1]['balance_after'] = 555.25; // statement-persisted row
      await tester.pumpWidget(
        _unboundedHost(
          _tab(txs, singleAccountContext: true, runningBalanceAnchor: 1000.0),
        ),
      );
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
      'meta line, no balance line',
      (tester) async {
        _setViewSize(tester, const Size(1200, 900));
        final txs = _makeTxs(3);
        txs[1]['balance_after'] = 555.25; // even a persisted value stays hidden
        await tester.pumpWidget(_unboundedHost(_tab(txs)));
        await tester.pump();

        expect(find.text('Food & drink · Checking 0'), findsOneWidget);
        expect(find.textContaining('Bal.'), findsNothing);
        expect(find.textContaining('≈'), findsNothing);
      },
    );
  });

  group('Task B — detail-panel category editor', () {
    testWidgets(
      'prefills the prettified label and a no-edit Save sends nothing',
      (tester) async {
        _setViewSize(tester, const Size(1200, 900));
        final updates = <_Update>[];
        await tester.pumpWidget(
          _unboundedHost(_tab(_makeTxs(3), updates: updates)),
        );

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

        expect(
          find.widgetWithText(TextField, 'Food & drink'),
          findsNothing,
        ); // panel closed
        expect(updates, isEmpty);
      },
    );

    testWidgets(
      'autocomplete suggests categories from other rows and Save sends '
      'only the changed field',
      (tester) async {
        _setViewSize(tester, const Size(1200, 900));
        final updates = <_Update>[];
        await tester.pumpWidget(
          _unboundedHost(_tab(_makeTxs(3), updates: updates)),
        );

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
      },
    );
  });

  group('Task C — bounded host (account panel slot)', () {
    testWidgets(
      'side-panel-sized slot: ≤50 rows scroll inside the slot and the '
      'last row is reachable',
      (tester) async {
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
      },
    );

    testWidgets(
      'phone-sized bottom-sheet slot: >50 rows sized from the slot (not '
      'the window) and the last row is reachable',
      (tester) async {
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
      },
    );
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
      'keeps income/expense styling and no pill',
      (tester) async {
        _setViewSize(tester, const Size(1200, 900));
        final txs = _makeTxs(3);
        // Row 0 is the RECEIVING leg (positive amount = inflow in the
        // storage sign convention) — exactly the case that must NOT render
        // as +green income because it's a transfer. Row 2 is a genuine
        // income row (positive = inflow) for contrast.
        txs[0]['amount'] = 25.0;
        txs[2]['amount'] = 12.0;

        await tester.pumpWidget(
          _unboundedHost(_tab(txs, fxTransfers: link(confirmed: false))),
        );
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
        for (final t in tester.widgetList<Text>(find.textContaining('⇄'))) {
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
      },
    );

    testWidgets('a user-confirmed link renders the pill in the teal '
        '"linked" accent', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(
        _unboundedHost(_tab(_makeTxs(3), fxTransfers: link(confirmed: true))),
      );
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

    testWidgets('rows spanning two months get month landmarks with the correct '
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

    testWidgets('with more pages available only the OLDEST loaded month is '
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
            'date': DateFormat(
              'yyyy-MM-dd',
            ).format(DateTime(monthA.year, monthA.month, day)),
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
            'date': DateFormat(
              'yyyy-MM-dd',
            ).format(DateTime(monthB.year, monthB.month, day)),
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

  group(
    'MXN reporting mode — rows carry the converted ≈ line on every width',
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

      testWidgets('narrow: a USD row in MXN mode shows the ≈ MXN estimate', (
        tester,
      ) async {
        _setViewSize(tester, const Size(420, 900));
        // One USD row of +10.00 → at 20.0 the MXN estimate is 200.00.
        await tester.pumpWidget(_unboundedHost(mxnTab(_makeTxs(1))));
        await tester.pump();

        expect(find.text(r'≈ MX$200.00'), findsOneWidget);
      });

      testWidgets('wide: the estimate is still there (unchanged behavior)', (
        tester,
      ) async {
        _setViewSize(tester, const Size(1200, 900));
        await tester.pumpWidget(_unboundedHost(mxnTab(_makeTxs(1))));
        await tester.pump();

        expect(find.text(r'≈ MX$200.00'), findsOneWidget);
      });

      testWidgets(
        'no estimate when the row is already in the reporting currency',
        (tester) async {
          _setViewSize(tester, const Size(420, 900));
          final txs = _makeTxs(
            1,
          ).map((t) => {...t, 'currency': 'MXN'}).toList();
          await tester.pumpWidget(_unboundedHost(mxnTab(txs)));
          await tester.pump();

          expect(find.textContaining('≈'), findsNothing);
        },
      );

      testWidgets(
        'in-session USD→MXN reporting swap re-converts the month-header '
        'nets (memo invalidates on targetCurrency)',
        (tester) async {
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
              'date': DateFormat(
                'yyyy-MM-dd',
              ).format(DateTime(month.year, month.month, 15)),
              'amount': 100.0,
              'currency': 'USD',
              'description': 'TX m1',
              'user_description': 'Row m1',
              'category': 'FOOD_AND_DRINK',
              'account_name': 'Checking',
            },
            {
              'id': 'm2',
              'date': DateFormat(
                'yyyy-MM-dd',
              ).format(DateTime(month.year, month.month, 10)),
              'amount': -40.0,
              'currency': 'USD',
              'description': 'TX m2',
              'user_description': 'Row m2',
              'category': 'FOOD_AND_DRINK',
              'account_name': 'Checking',
            },
          ];

          // USD mode first: +100 − 40 → +$60.00 net (primes the memo).
          await tester.pumpWidget(
            _unboundedHost(
              _tab(
                txs,
                currencyFormat: NumberFormat.currency(symbol: r'$'),
                targetCurrency: 'USD',
                usdMxnRate: 20.0,
              ),
            ),
          );
          await tester.pump();
          expect(find.text('+\$60.00 net'), findsOneWidget);

          // Swap to MXN reporting — same State, same tx list identity, same
          // rate. The header must show the CONVERTED net (60 × 20 = 1,200),
          // not the stale USD figure relabeled MX$.
          await tester.pumpWidget(_unboundedHost(mxnTab(txs)));
          await tester.pump();
          expect(find.text(r'+MX$1,200.00 net'), findsOneWidget);
          expect(find.text(r'+MX$60.00 net'), findsNothing);
        },
      );
    },
  );

  group('Bell drill-down — one-shot categorySeed (+ dateSeed)', () {
    // A spike drill-down fixture: two rows in the seeded category (one
    // inside the seeded month, one the month before) and one out-of-
    // category row inside the month. Dates are fixed (not now-relative)
    // because the seed pins an absolute window.
    Map<String, dynamic> tx(
      String id,
      String date,
      String categoryDetailed,
      String categoryPrimary,
    ) => {
      'id': id,
      'date': date,
      'amount': -25.0,
      'currency': 'USD',
      'description': 'TX $id',
      'user_description': 'Row $id',
      'category_detailed': categoryDetailed,
      'category': categoryPrimary,
      'account_name': 'Checking',
    };

    List<Map<String, dynamic>> fixture() => [
      tx(
        'gas-jul',
        '2026-07-15',
        'RENT_AND_UTILITIES_GAS_AND_ELECTRICITY',
        'RENT_AND_UTILITIES',
      ),
      tx(
        'food-jul',
        '2026-07-10',
        'FOOD_AND_DRINK_GROCERIES',
        'FOOD_AND_DRINK',
      ),
      tx(
        'gas-jun',
        '2026-06-15',
        'RENT_AND_UTILITIES_GAS_AND_ELECTRICITY',
        'RENT_AND_UTILITIES',
      ),
    ];

    ({DateTime start, DateTime end}) july() =>
        (start: DateTime(2026, 7, 1), end: DateTime(2026, 7, 31));

    testWidgets(
      'both seeds filter the rows, render dismissible chips, and each '
      'consumed callback fires exactly once',
      (tester) async {
        _setViewSize(tester, const Size(1200, 900));
        var dateConsumed = 0, catConsumed = 0;
        await tester.pumpWidget(
          _unboundedHost(
            _tab(
              fixture(),
              categorySeed: 'Gas & electric',
              dateSeed: july(),
              onCategorySeedConsumed: () => catConsumed++,
              onDateSeedConsumed: () => dateConsumed++,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Only the in-category, in-month row survives the seeded filter.
        expect(find.text('Row gas-jul'), findsOneWidget);
        expect(find.text('Row gas-jun'), findsNothing);
        expect(find.text('Row food-jul'), findsNothing);

        // Both filters surface as dismissible chips (the undo affordance).
        expect(
          find.widgetWithText(InputChip, 'Gas & electric'),
          findsOneWidget,
        );
        expect(find.widgetWithText(InputChip, 'Jul 1–Jul 31'), findsOneWidget);

        // One-shot contract: applied once, reported once.
        expect((dateConsumed, catConsumed), (1, 1));
      },
    );

    testWidgets('dismissing the chips restores the hidden rows', (
      tester,
    ) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(
        _unboundedHost(
          _tab(fixture(), categorySeed: 'Gas & electric', dateSeed: july()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Row food-jul'), findsNothing);

      // Drop the category chip: the other July row reappears; the June
      // row stays hidden behind the still-active date window.
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(InputChip, 'Gas & electric'),
          matching: find.byIcon(Icons.clear),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Row food-jul'), findsOneWidget);
      expect(find.text('Row gas-jun'), findsNothing);

      // Drop the date chip too: everything is back.
      await tester.tap(
        find.descendant(
          of: find.widgetWithText(InputChip, 'Jul 1–Jul 31'),
          matching: find.byIcon(Icons.clear),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Row gas-jun'), findsOneWidget);
      expect(find.text('Row gas-jul'), findsOneWidget);
    });

    testWidgets(
      'one-shot regression: a rebuild with the SAME seed values does not '
      're-apply after the user cleared the filters',
      (tester) async {
        _setViewSize(tester, const Size(1200, 900));
        var dateConsumed = 0, catConsumed = 0;
        Widget host() => _unboundedHost(
          _tab(
            fixture(),
            categorySeed: 'Gas & electric',
            dateSeed: july(),
            onCategorySeedConsumed: () => catConsumed++,
            onDateSeedConsumed: () => dateConsumed++,
          ),
        );
        await tester.pumpWidget(host());
        await tester.pumpAndSettle();
        expect(find.text('Row gas-jun'), findsNothing);

        // The user clears everything…
        await tester.tap(find.text('Clear all'));
        await tester.pumpAndSettle();
        expect(find.text('Row gas-jun'), findsOneWidget);

        // …then a dashboard rebuild hands the tab the SAME seed values
        // (records/strings compare equal). They must NOT re-apply.
        await tester.pumpWidget(host());
        await tester.pumpAndSettle();
        expect(find.text('Row gas-jun'), findsOneWidget);
        expect(find.text('Row food-jul'), findsOneWidget);
        expect(find.byType(InputChip), findsNothing);
        expect((dateConsumed, catConsumed), (1, 1));
      },
    );

    testWidgets(
      'a date-only jump (chart month tap) starts from a clean context: no '
      'category chip materializes, and a PRE-EXISTING category filter from '
      'an earlier journey is reset',
      (tester) async {
        _setViewSize(tester, const Size(1200, 900));
        var dateConsumed = 0, catConsumed = 0;
        // Journey 1: a category-seeded drill-down lands (apply + consume).
        await tester.pumpWidget(
          _unboundedHost(
            _tab(
              fixture(),
              categorySeed: 'Gas & electric',
              onCategorySeedConsumed: () => catConsumed++,
              onDateSeedConsumed: () => dateConsumed++,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.widgetWithText(InputChip, 'Gas & electric'),
          findsOneWidget,
        );
        expect((dateConsumed, catConsumed), (0, 1));

        // Journey 2: a date-only jump arrives (the dashboard helper has
        // nulled the consumed category copy and set only the window).
        // Fresh-context rule: the stale category chip is GONE — only the
        // month window is active, so both July rows show.
        await tester.pumpWidget(
          _unboundedHost(
            _tab(
              fixture(),
              dateSeed: july(),
              onCategorySeedConsumed: () => catConsumed++,
              onDateSeedConsumed: () => dateConsumed++,
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Row gas-jul'), findsOneWidget);
        expect(find.text('Row food-jul'), findsOneWidget);
        expect(find.text('Row gas-jun'), findsNothing);
        expect(find.widgetWithText(InputChip, 'Jul 1–Jul 31'), findsOneWidget);
        expect(find.widgetWithText(InputChip, 'Gas & electric'), findsNothing);
        expect((dateConsumed, catConsumed), (1, 1));
      },
    );
  });

  group('Bell largest-move drill-down — one-shot accountIdSeed', () {
    // Two accounts; the seed pins "Cards". Fixed dates, mirroring the
    // category-seed fixture above.
    List<Map<String, dynamic>> fixture() => [
      {
        'id': 'cards-1',
        'date': '2026-07-15',
        'amount': -25.0,
        'currency': 'USD',
        'description': 'TX cards-1',
        'user_description': 'Row cards-1',
        'category': 'GENERAL_MERCHANDISE',
        'account_id': 'acc-cards',
        'account_name': 'Cards',
      },
      {
        'id': 'chk-1',
        'date': '2026-07-14',
        'amount': -30.0,
        'currency': 'USD',
        'description': 'TX chk-1',
        'user_description': 'Row chk-1',
        'category': 'GENERAL_MERCHANDISE',
        'account_id': 'acc-chk',
        'account_name': 'Checking',
      },
    ];

    const accounts = [
      {'id': 'acc-cards', 'name': 'Cards'},
      {'id': 'acc-chk', 'name': 'Checking'},
    ];

    testWidgets(
      'the seed filters to the account, renders a dismissible chip, and '
      'fires the consumed callback exactly once',
      (tester) async {
        _setViewSize(tester, const Size(1200, 900));
        var consumed = 0;
        await tester.pumpWidget(
          _unboundedHost(
            _tab(
              fixture(),
              accounts: accounts,
              accountIdSeed: 'acc-cards',
              onAccountSeedConsumed: () => consumed++,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.text('Row cards-1'), findsOneWidget);
        expect(find.text('Row chk-1'), findsNothing);
        // The chip shows the account NAME (resolved via the accounts
        // list), not the raw id.
        expect(find.widgetWithText(InputChip, 'Cards'), findsOneWidget);
        expect(consumed, 1);
      },
    );

    testWidgets('removing the chip restores the hidden rows', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(
        _unboundedHost(
          _tab(fixture(), accounts: accounts, accountIdSeed: 'acc-cards'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Row chk-1'), findsNothing);

      await tester.tap(
        find.descendant(
          of: find.widgetWithText(InputChip, 'Cards'),
          matching: find.byIcon(Icons.clear),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Row chk-1'), findsOneWidget);
      expect(find.text('Row cards-1'), findsOneWidget);
    });

    testWidgets(
      'one-shot regression: a rebuild with the SAME seed does not re-apply '
      'after the user cleared the filter',
      (tester) async {
        _setViewSize(tester, const Size(1200, 900));
        var consumed = 0;
        Widget host() => _unboundedHost(
          _tab(
            fixture(),
            accounts: accounts,
            accountIdSeed: 'acc-cards',
            onAccountSeedConsumed: () => consumed++,
          ),
        );
        await tester.pumpWidget(host());
        await tester.pumpAndSettle();
        expect(find.text('Row chk-1'), findsNothing);

        // The user clears everything…
        await tester.tap(find.text('Clear all'));
        await tester.pumpAndSettle();
        expect(find.text('Row chk-1'), findsOneWidget);

        // …then a dashboard rebuild hands the tab the SAME seed value.
        // It must NOT re-apply over the user's edit.
        await tester.pumpWidget(host());
        await tester.pumpAndSettle();
        expect(find.text('Row chk-1'), findsOneWidget);
        expect(find.byType(InputChip), findsNothing);
        expect(consumed, 1);
      },
    );
  });

  group('Since-visit drill-down — one-shot createdSinceSeed', () {
    // Sync-time fixture: the "since your last visit" digest counts rows by
    // created_at > anchor, so the drill-down must slice by created_at too.
    // 'late-sync' is the user-repro shape — POSTED days before the anchor's
    // labeled day but SYNCED after it; 'early-sync' posted nearer the
    // anchor but synced before it. A posted-date window gets BOTH wrong.
    // created_at extremes are >14h clear of the anchor instant so the
    // expectations hold in any test-VM timezone.
    List<Map<String, dynamic>> fixture() => [
      {
        'id': 'early-sync',
        'date': '2026-07-30',
        'amount': -30.0,
        'currency': 'USD',
        'description': 'TX early-sync',
        'user_description': 'Row early-sync',
        'category': 'GENERAL_MERCHANDISE',
        'account_name': 'Cards',
        'created_at': '2026-07-29T12:00:00Z',
      },
      {
        'id': 'late-sync',
        'date': '2026-07-28',
        'amount': -25.0,
        'currency': 'USD',
        'description': 'TX late-sync',
        'user_description': 'Row late-sync',
        'category': 'GENERAL_MERCHANDISE',
        'account_name': 'Cards',
        'created_at': '2026-08-02T12:00:00Z',
      },
    ];

    // Local-time anchor (the bell formats the anchor's LOCAL day) so the
    // chip label is deterministic regardless of the test VM's timezone.
    DateTime anchor() => DateTime(2026, 7, 31, 19, 59);

    testWidgets(
      'en: the seed filters by SYNC time (not posted date), renders a '
      'dismissible "New since {date}" chip, and the consumed callback '
      'fires exactly once',
      (tester) async {
        _setViewSize(tester, const Size(1200, 900));
        var consumed = 0;
        await tester.pumpWidget(
          _unboundedHost(
            _tab(
              fixture(),
              createdSinceSeed: anchor(),
              onCreatedSinceSeedConsumed: () => consumed++,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Synced after the anchor → shown, even though it POSTED Jul 28
        // (before the anchor's labeled day). Synced before → hidden, even
        // though it posted Jul 30.
        expect(find.text('Row late-sync'), findsOneWidget);
        expect(find.text('Row early-sync'), findsNothing);

        // Chip pins the l10n placeholder: MMMd of the anchor's local day.
        expect(
          find.widgetWithText(InputChip, 'New since Jul 31'),
          findsOneWidget,
        );
        expect(consumed, 1);

        // × clears just this filter and restores the hidden row.
        await tester.tap(
          find.descendant(
            of: find.widgetWithText(InputChip, 'New since Jul 31'),
            matching: find.byIcon(Icons.clear),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('Row early-sync'), findsOneWidget);
        expect(find.text('Row late-sync'), findsOneWidget);
        expect(find.byType(InputChip), findsNothing);
      },
    );

    testWidgets('es: chip label is "Nuevas desde {date}" with the locale-'
        'formatted day', (tester) async {
      _setViewSize(tester, const Size(1200, 900));
      await tester.pumpWidget(
        _unboundedHost(
          _tab(fixture(), createdSinceSeed: anchor()),
          locale: const Locale('es'),
        ),
      );
      await tester.pumpAndSettle();

      // Computed via the same skeleton the widget uses, so the assertion
      // pins the template + placeholder without pinning CLDR month names.
      final expected = 'Nuevas desde ${DateFormat.MMMd('es').format(anchor())}';
      expect(find.widgetWithText(InputChip, expected), findsOneWidget);
      expect(find.text('Row late-sync'), findsOneWidget);
      expect(find.text('Row early-sync'), findsNothing);
    });

    testWidgets(
      'one-shot regression: a rebuild with the SAME seed instant does not '
      're-apply after the user cleared the filters',
      (tester) async {
        _setViewSize(tester, const Size(1200, 900));
        var consumed = 0;
        Widget host() => _unboundedHost(
          _tab(
            fixture(),
            createdSinceSeed: anchor(),
            onCreatedSinceSeedConsumed: () => consumed++,
          ),
        );
        await tester.pumpWidget(host());
        await tester.pumpAndSettle();
        expect(find.text('Row early-sync'), findsNothing);

        // The user clears everything…
        await tester.tap(find.text('Clear all'));
        await tester.pumpAndSettle();
        expect(find.text('Row early-sync'), findsOneWidget);

        // …then a dashboard rebuild hands the tab the SAME seed instant
        // (DateTime compares by value). It must NOT re-apply.
        await tester.pumpWidget(host());
        await tester.pumpAndSettle();
        expect(find.text('Row early-sync'), findsOneWidget);
        expect(find.byType(InputChip), findsNothing);
        expect(consumed, 1);
      },
    );

    testWidgets(
      'user-repro regression: "+\$2,612.87 on Cards — since Jul 31" → a row '
      'DATED Jul 28 whose created_at is after the (UTC) Aug 1 anchor IS '
      'shown, account seed and all',
      (tester) async {
        _setViewSize(tester, const Size(1200, 900));
        // 7:59pm Jul 31 in Mexico City (UTC-6) — the raw instant is
        // already Aug 1 in UTC. The old code truncated this to a local
        // Aug 1 date window and showed "0 of 2502".
        final utcAnchor = DateTime.utc(2026, 8, 1, 1, 59);
        const accounts = [
          {'id': 'acc-cards', 'name': 'Cards'},
        ];
        final rows = [
          {
            'id': 'cards-late',
            'date': '2026-07-28',
            'amount': -2612.87,
            'currency': 'USD',
            'description': 'TX cards-late',
            'user_description': 'Row cards-late',
            'category': 'GENERAL_MERCHANDISE',
            'account_id': 'acc-cards',
            'account_name': 'Cards',
            'created_at': '2026-08-01T14:00:00Z',
          },
        ];
        await tester.pumpWidget(
          _unboundedHost(
            _tab(
              rows,
              accounts: accounts,
              accountIdSeed: 'acc-cards',
              createdSinceSeed: utcAnchor,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // The row the digest counted is on screen — not an empty list.
        expect(find.text('Row cards-late'), findsOneWidget);
        // Both drill-down chips are present (account + sync-time).
        expect(find.widgetWithText(InputChip, 'Cards'), findsOneWidget);
        final chipLabel =
            'New since ${DateFormat.MMMd().format(utcAnchor.toLocal())}';
        expect(find.widgetWithText(InputChip, chipLabel), findsOneWidget);
      },
    );
  });
}
