import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/dividend_calendar.dart';
import 'package:patrimonio/widgets/portfolio_card.dart';

// WS3 round 4 (redesigned): the 12-month income calendar (contract C4-B)
// as a bar-list with inline tap-to-expand payer breakdown, plus its hook
// inside the dividend-income card. Payloads are canned — the calendar is
// pure presentation, and the card takes the same `fetchOverride` seam as
// the detail sheet (widget tests can't subclass ApiService).

/// `YYYY-MM` key for the month [offset] months after the current one —
/// matching the server's contract of 12 buckets starting at the current
/// month, so the tests hold on any date.
String _monthKey(int offset) {
  final now = DateTime.now();
  final d = DateTime(now.year, now.month + offset);
  return DateFormat('yyyy-MM').format(d);
}

/// Human month-row label the widget derives from the bucket key.
String _monthLabel(int offset) {
  final now = DateTime.now();
  return DateFormat.yMMM().format(DateTime(now.year, now.month + offset));
}

Key _rowKey(int offset) => ValueKey('cal-row-${_monthKey(offset)}');
Key _barKey(int offset) => ValueKey('cal-bar-${_monthKey(offset)}');

Map<String, dynamic> _entry(String symbol, int offset, double amount) => {
      'symbol': symbol,
      'est_date': '${_monthKey(offset)}-14',
      'amount_usd': amount,
    };

/// Canned C4-B `calendar`: a monthly payer O ($10 every month) and a
/// quarterly payer KO ($3.10 in months 0, 3, 6, 9).
List<Map<String, dynamic>> _mixedCalendar() => [
      for (var i = 0; i < 12; i++)
        {
          'month': _monthKey(i),
          'total_usd': i % 3 == 0 ? 13.10 : 10.0,
          'entries': [
            _entry('O', i, 10.0),
            if (i % 3 == 0) _entry('KO', i, 3.10),
          ],
        },
    ];

/// Quarterly-only calendar: months 0/3/6/9 pay, the other 8 are dry.
List<Map<String, dynamic>> _quarterlyCalendar() => [
      for (var i = 0; i < 12; i++)
        {
          'month': _monthKey(i),
          'total_usd': i % 3 == 0 ? 3.10 : 0.0,
          'entries': [if (i % 3 == 0) _entry('KO', i, 3.10)],
        },
    ];

/// First month crowded with five payers (amount-descending, per contract);
/// the rest of the year is dry. The redesign shows ALL of them inline on
/// expansion — no "+N more" overflow.
List<Map<String, dynamic>> _crowdedCalendar() => [
      {
        'month': _monthKey(0),
        'total_usd': 150.0,
        'entries': [
          _entry('VTI', 0, 60.0),
          _entry('VXUS', 0, 40.0),
          _entry('SCHD', 0, 30.0),
          _entry('KO', 0, 15.0),
          _entry('ABBV', 0, 5.0),
        ],
      },
      for (var i = 1; i < 12; i++)
        {'month': _monthKey(i), 'total_usd': 0.0, 'entries': <Map>[]},
    ];

/// Bar-scale fixture: a max month ($100), a half month ($50), a tiny month
/// ($1 → clamped to the 2% sliver) and nine dry months.
List<Map<String, dynamic>> _scaledCalendar() => [
      {
        'month': _monthKey(0),
        'total_usd': 100.0,
        'entries': [_entry('VTI', 0, 100.0)],
      },
      {
        'month': _monthKey(1),
        'total_usd': 50.0,
        'entries': [_entry('KO', 1, 50.0)],
      },
      {
        'month': _monthKey(2),
        'total_usd': 1.0,
        'entries': [_entry('T', 2, 1.0)],
      },
      for (var i = 3; i < 12; i++)
        {'month': _monthKey(i), 'total_usd': 0.0, 'entries': <Map>[]},
    ];

/// All-dry calendar: twelve zero months.
List<Map<String, dynamic>> _emptyCalendar() => [
      for (var i = 0; i < 12; i++)
        {'month': _monthKey(i), 'total_usd': 0.0, 'entries': <Map>[]},
    ];

/// Minimal card payload (income > 0 so the card renders); [calendar] is
/// spliced in only when provided — its absence is the round-3-backend case.
Map<String, dynamic> _cardPayload({List<Map<String, dynamic>>? calendar}) => {
      'projected_annual_income_usd': 132.40,
      'blended_yield_pct': 2.31,
      'fx_stale': false,
      'contributions': [
        {
          'symbol': 'O',
          'annual_income_usd': 120.0,
          'yield_pct': 5.1,
          'per_year': 12,
        },
        {
          'symbol': 'KO',
          'annual_income_usd': 12.40,
          'yield_pct': 2.8,
          'per_year': 4,
        },
      ],
      'upcoming_ex_dates': [
        {
          'symbol': 'KO',
          'est_next_ex_date': '${_monthKey(0)}-14',
          'annual_income_usd': 12.40,
        },
      ],
      'calendar': ?calendar,
    };

Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void _useSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  final usd = NumberFormat.currency(symbol: r'$');

  DividendCalendar calendar(
    List<Map<String, dynamic>> data, {
    double conversionFactor = 1.0,
    NumberFormat? format,
  }) {
    return DividendCalendar(
      calendar: data,
      conversionFactor: conversionFactor,
      currencyFormat: format ?? usd,
    );
  }

  group('DividendCalendar (contract C4-B, bar-list redesign)', () {
    testWidgets('renders all 12 month rows with the honesty caption',
        (tester) async {
      _useSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(_host(calendar(_mixedCalendar())));

      for (var i = 0; i < 12; i++) {
        expect(find.text(_monthLabel(i)), findsOneWidget,
            reason: 'month row $i (${_monthLabel(i)}) missing');
        expect(find.byKey(_rowKey(i)), findsOneWidget);
        expect(find.byKey(_barKey(i)), findsOneWidget);
      }
      // No dry months in this payload — no em-dash totals.
      expect(find.text('—'), findsNothing);
      // Collapsed by default: no payer breakdown lines anywhere.
      expect(find.textContaining('Est. ex-date'), findsNothing);
      // Honesty caption present.
      expect(
        find.text(
            "Estimated from each payer's current rate and cadence — not announced dates."),
        findsOneWidget,
      );
    });

    testWidgets('zero-income months render a muted em-dash, never vanish',
        (tester) async {
      _useSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(_host(calendar(_quarterlyCalendar())));

      // 8 dry months, all still listed with an em-dash total.
      expect(find.text('—'), findsNWidgets(8));
      for (var i = 0; i < 12; i++) {
        expect(find.text(_monthLabel(i)), findsOneWidget);
      }
      // The four paying months carry a bold total.
      expect(find.text(r'$3.10'), findsNWidgets(4));
    });

    testWidgets(
        'all-zero calendar → 12 em-dash rows, no bars, caption kept',
        (tester) async {
      _useSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(_host(calendar(_emptyCalendar())));

      expect(find.text('—'), findsNWidgets(12));
      for (var i = 0; i < 12; i++) {
        final bar =
            tester.widget<FractionallySizedBox>(find.byKey(_barKey(i)));
        expect(bar.widthFactor, 0.0,
            reason: 'zero month $i must have an empty track');
      }
      expect(
        find.text(
            "Estimated from each payer's current rate and cadence — not announced dates."),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'tap expands ALL payers inline; tapping another month collapses '
        'the first (single-expansion invariant)', (tester) async {
      _useSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(_host(calendar(_crowdedCalendar())));

      // Collapsed: no breakdown lines, no overflow chip of any kind.
      expect(find.textContaining('Est. ex-date'), findsNothing);
      expect(find.textContaining('more'), findsNothing);

      await tester.tap(find.byKey(_rowKey(0)));
      await tester.pump();

      // Every one of the 5 payers is visible — symbol, est date, amount.
      for (final symbol in ['VTI', 'VXUS', 'SCHD', 'KO', 'ABBV']) {
        expect(find.text(symbol), findsOneWidget,
            reason: 'expanded payer $symbol missing');
      }
      expect(find.textContaining('Est. ex-date'), findsNWidgets(5));
      for (final amount in [r'$60.00', r'$40.00', r'$30.00', r'$15.00', r'$5.00']) {
        expect(find.text(amount), findsOneWidget,
            reason: 'expanded amount $amount missing');
      }
      // Nothing is collapsed behind a chip/tooltip anymore.
      expect(find.textContaining('more'), findsNothing);
      expect(find.byType(Tooltip), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('only one month expands at a time', (tester) async {
      _useSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(_host(calendar(_mixedCalendar())));

      // Expand month 0 (O + KO): two breakdown lines.
      await tester.tap(find.byKey(_rowKey(0)));
      await tester.pump();
      expect(find.text('KO'), findsOneWidget);
      expect(find.textContaining('Est. ex-date'), findsNWidgets(2));

      // Expand month 1 (O only): month 0 collapses — single line remains.
      await tester.tap(find.byKey(_rowKey(1)));
      await tester.pump();
      expect(find.text('KO'), findsNothing);
      expect(find.textContaining('Est. ex-date'), findsOneWidget);

      // Tapping the open month again collapses everything.
      await tester.tap(find.byKey(_rowKey(1)));
      await tester.pump();
      expect(find.textContaining('Est. ex-date'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'REGRESSION (stagger bug): at 390px every row spans the full '
        'available width — no intrinsic shrink-wrap offsets', (tester) async {
      _useSurface(tester, const Size(390, 844));
      await tester.pumpWidget(_host(calendar(_mixedCalendar())));

      for (var i = 0; i < 12; i++) {
        final size = tester.getSize(find.byKey(_rowKey(i)));
        expect(size.width, 390.0,
            reason: 'row $i must span the full available width');
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('bars share one global scale; zero months are inert',
        (tester) async {
      _useSurface(tester, const Size(1440, 900));
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(calendar(_scaledCalendar())));

      double factor(int i) =>
          tester.widget<FractionallySizedBox>(find.byKey(_barKey(i))).widthFactor!;

      expect(factor(0), 1.0); // max month fills the track
      expect(factor(1), moreOrLessEquals(0.5)); // half-size month
      expect(factor(2), moreOrLessEquals(0.02)); // tiny month clamps to sliver
      expect(factor(3), 0.0); // dry month: empty track

      // The dry month's row is not tappable and carries no button semantics.
      final dryInkWell = tester.widget<InkWell>(find.descendant(
          of: find.byKey(_rowKey(3)), matching: find.byType(InkWell)));
      expect(dryInkWell.onTap, isNull);
      // Merging nodes surface their content via getSemanticsData().
      final dryData =
          tester.getSemantics(find.byKey(_rowKey(3))).getSemanticsData();
      expect(dryData.flagsCollection.isButton, isFalse);
      expect(dryData.hasAction(SemanticsAction.tap), isFalse);

      handle.dispose();
    });

    testWidgets('converts every figure through conversionFactor + format',
        (tester) async {
      _useSurface(tester, const Size(1440, 900));
      final mxn = NumberFormat.currency(symbol: r'MX$');
      await tester.pumpWidget(_host(calendar(
        _quarterlyCalendar(),
        conversionFactor: 20.0,
        format: mxn,
      )));

      // Month totals: 3.10 USD × 20 = MX$62.00 in the four paying months.
      expect(find.text(r'MX$62.00'), findsNWidgets(4));

      // Expanded entry amounts convert too.
      await tester.tap(find.byKey(_rowKey(0)));
      await tester.pump();
      expect(find.text('KO'), findsOneWidget);
      expect(find.text(r'MX$62.00'), findsNWidgets(5));
      // No unconverted USD figure leaks through.
      expect(find.textContaining(RegExp(r'^\$')), findsNothing);
    });

    testWidgets(
        'semantics: calMonthSem label unchanged, expand/collapse hints, '
        'expanded entries announced', (tester) async {
      _useSurface(tester, const Size(1440, 900));
      final handle = tester.ensureSemantics();
      await tester.pumpWidget(_host(calendar(_crowdedCalendar())));

      // Merged collapsed-row label, verbatim round-3 shape. (Merging nodes
      // surface their content via getSemanticsData(), not the raw getters.)
      final row = tester.getSemantics(find.byKey(_rowKey(0))).getSemanticsData();
      expect(
        row.label,
        '${_monthLabel(0)}, \$150.00 expected, VTI, VXUS, SCHD, KO, ABBV',
      );
      expect(row.flagsCollection.isButton, isTrue);
      expect(row.hasAction(SemanticsAction.tap), isTrue);
      expect(row.hint, 'Show payer breakdown');

      // Dry month keeps the empty-month label.
      final dry =
          tester.getSemantics(find.byKey(_rowKey(1))).getSemanticsData();
      expect(dry.label, '${_monthLabel(1)}, no dividends expected');

      await tester.tap(find.byKey(_rowKey(0)));
      await tester.pump();
      expect(
        tester.getSemantics(find.byKey(_rowKey(0))).getSemanticsData().hint,
        'Hide payer breakdown',
      );

      // Expanded payer lines live OUTSIDE the row's excluded node — each
      // line is its own merged node, so screen readers announce it.
      final entryLabel =
          tester.getSemantics(find.text('ABBV')).getSemanticsData().label;
      expect(entryLabel, contains('ABBV'));
      expect(entryLabel, contains(r'$5.00'));
      expect(entryLabel, contains('Est. ex-date'));

      handle.dispose();
    });

    testWidgets(
        'two-column split is driven by the inner CONSTRAINT (>= 720), '
        'not the screen', (tester) async {
      _useSurface(tester, const Size(1440, 900));

      // 800px constraint on the same 1440px screen → two columns of six:
      // month 6 tops the right column, level with month 0.
      await tester.pumpWidget(_host(Center(
        child: SizedBox(width: 800, child: calendar(_mixedCalendar())),
      )));
      expect(
        tester.getTopLeft(find.byKey(_rowKey(6))).dy,
        tester.getTopLeft(find.byKey(_rowKey(0))).dy,
      );
      expect(
        tester.getTopLeft(find.byKey(_rowKey(6))).dx,
        greaterThan(tester.getTopLeft(find.byKey(_rowKey(0))).dx),
      );

      // 600px constraint on the SAME wide screen → single column (the old
      // MediaQuery breakpoint would wrongly have gone wide here).
      await tester.pumpWidget(_host(Center(
        child: SizedBox(width: 600, child: calendar(_mixedCalendar())),
      )));
      expect(
        tester.getTopLeft(find.byKey(_rowKey(6))).dx,
        tester.getTopLeft(find.byKey(_rowKey(0))).dx,
      );
      expect(
        tester.getTopLeft(find.byKey(_rowKey(6))).dy,
        greaterThan(tester.getTopLeft(find.byKey(_rowKey(5))).dy),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('narrow surface stacks a 12-row list without overflow',
        (tester) async {
      _useSurface(tester, const Size(390, 844));
      await tester.pumpWidget(_host(calendar(_mixedCalendar())));

      for (var i = 0; i < 12; i++) {
        expect(find.text(_monthLabel(i)), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  });

  group('DividendIncomeCard calendar hook (C4-B back-compat)', () {
    DividendIncomeCard card(Map<String, dynamic> payload) {
      return DividendIncomeCard(
        apiService: ApiService(),
        conversionFactor: 1.0,
        currencyFormat: usd,
        fetchOverride: () async => payload,
      );
    }

    testWidgets(
        'field absent (round-3 backend) → no toggle, card unchanged',
        (tester) async {
      _useSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(_host(card(_cardPayload())));
      await tester.pump(); // resolve the canned fetch

      // Existing sections intact...
      expect(find.text('Dividend income'), findsOneWidget);
      expect(find.text('Projected annual'), findsOneWidget);
      expect(find.text('Top payers'), findsOneWidget);
      expect(find.text('Upcoming ex-dates'), findsOneWidget);
      // ...and strictly nothing calendar-shaped is rendered.
      expect(find.text('Show 12-month calendar'), findsNothing);
      expect(find.byIcon(Icons.expand_more), findsNothing);
      expect(find.byType(DividendCalendar), findsNothing);
    });

    testWidgets('field empty → still no toggle (C4-B hard rule)',
        (tester) async {
      _useSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(_host(card(_cardPayload(calendar: []))));
      await tester.pump();

      expect(find.text('Show 12-month calendar'), findsNothing);
      expect(find.byType(DividendCalendar), findsNothing);
    });

    testWidgets(
        'field present → toggle expands the calendar and collapses it back',
        (tester) async {
      _useSurface(tester, const Size(1440, 900));
      await tester
          .pumpWidget(_host(card(_cardPayload(calendar: _mixedCalendar()))));
      await tester.pump();

      // Collapsed by default: toggle exists, calendar doesn't.
      final toggle = find.text('Show 12-month calendar');
      expect(toggle, findsOneWidget);
      expect(find.byType(DividendCalendar), findsNothing);

      await tester.tap(toggle);
      await tester.pump();
      expect(find.byType(DividendCalendar), findsOneWidget);
      expect(find.text('Hide 12-month calendar'), findsOneWidget);
      expect(find.text(_monthLabel(0)), findsOneWidget);

      await tester.tap(find.text('Hide 12-month calendar'));
      await tester.pump();
      expect(find.byType(DividendCalendar), findsNothing);
      expect(find.text('Show 12-month calendar'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}
