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
}) {
  return TransactionsTab(
    transactions: txs,
    conversionFactor: 1.0,
    currencyFormat: NumberFormat.currency(symbol: r'$'),
    targetCurrency: 'USD',
    usdMxnRate: 0,
    fxTransfers: fxTransfers,
    hasMore: hasMore,
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

      // Open-then-Save with zero edits must be a pure no-op: previously it
      // unconditionally wrote userCategory/userNotes, silently converting
      // the auto-category into a user override of the raw enum string.
      await tester.ensureVisible(find.text('Save'));
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(find.text('Save'), findsNothing); // panel closed
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
      // Row 0 is the RECEIVING leg (negative amount = inflow in the
      // Plaid sign convention) — exactly the case that used to render
      // as +green income. Row 2 is a genuine income row for contrast.
      txs[0]['amount'] = -25.0;
      txs[2]['amount'] = -12.0;

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
    /// Month A nets to −\$60 (100 out, 40 in); month B to +\$40
    /// (10 out, 50 in) so both subtotal signs are exercised.
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
      // Month A: 100 out − 40 in → −$60 net; month B: 10 out − 50 in →
      // +$40 net. No "(partial)" suffix when hasMore is false.
      expect(find.text('−\$60.00 net'), findsOneWidget);
      expect(find.text('+\$40.00 net'), findsOneWidget);
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
      expect(find.text('−\$60.00 net'), findsOneWidget);
      expect(find.text('+\$40.00 net (partial)'), findsOneWidget);
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
}
