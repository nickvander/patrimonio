import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/dividend_calendar.dart';
import 'package:patrimonio/widgets/portfolio_card.dart';

// WS3 round 4: the 12-month income calendar (contract C4-B) and its hook
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

/// Human month-cell label the widget derives from the bucket key.
String _monthLabel(int offset) {
  final now = DateTime.now();
  return DateFormat.yMMM().format(DateTime(now.year, now.month + offset));
}

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

/// First month crowded with five payers (amount-descending, per contract)
/// so the +N-more overflow chip appears; the rest of the year is dry.
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

  group('DividendCalendar (contract C4-B)', () {
    testWidgets('renders all 12 month cells on the wide grid',
        (tester) async {
      _useSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(_host(calendar(_mixedCalendar())));

      for (var i = 0; i < 12; i++) {
        expect(find.text(_monthLabel(i)), findsOneWidget,
            reason: 'month cell $i (${_monthLabel(i)}) missing');
      }
      // Monthly payer appears in every cell, quarterly in 4. (Anchored
      // regex: 'KO · …' would otherwise substring-match 'O · '.)
      expect(find.textContaining(RegExp(r'^O · ')), findsNWidgets(12));
      expect(find.textContaining('KO · '), findsNWidgets(4));
      // No dry months in this payload — no em-dash totals.
      expect(find.text('—'), findsNothing);
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

      // 8 dry months, all still on the grid with an em-dash total.
      expect(find.text('—'), findsNWidgets(8));
      for (var i = 0; i < 12; i++) {
        expect(find.text(_monthLabel(i)), findsOneWidget);
      }
      // The four paying months carry a bold total and a payer chip.
      expect(find.text(r'$3.10'), findsNWidgets(4));
      expect(find.text(r'KO · $3.10'), findsNWidgets(4));
    });

    testWidgets('collapses entries beyond 3 into a +N more chip whose '
        'tooltip lists the rest', (tester) async {
      _useSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(_host(calendar(_crowdedCalendar())));

      // Three visible chips + the overflow chip.
      expect(find.textContaining('VTI · '), findsOneWidget);
      expect(find.textContaining('VXUS · '), findsOneWidget);
      expect(find.textContaining('SCHD · '), findsOneWidget);
      expect(find.textContaining('KO · '), findsNothing);
      expect(find.text('+2 more'), findsOneWidget);

      // The overflow tooltip names every hidden payer with its amount.
      final tooltip = tester.widget<Tooltip>(
        find.ancestor(of: find.text('+2 more'), matching: find.byType(Tooltip)),
      );
      expect(tooltip.message, contains('KO'));
      expect(tooltip.message, contains('ABBV'));
      expect(tooltip.message, contains(r'$15.00'));
      expect(tooltip.message, contains(r'$5.00'));

      // Visible chips carry the est-date tooltip.
      final chipTooltip = tester.widget<Tooltip>(
        find.ancestor(
            of: find.textContaining('VTI · '),
            matching: find.byType(Tooltip)),
      );
      expect(chipTooltip.message, startsWith('Est. ex-date '));
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
      // Chip amounts convert too.
      expect(find.text(r'KO · MX$62.00'), findsNWidgets(4));
      // No unconverted USD figure leaks through.
      expect(find.textContaining(RegExp(r'^\$')), findsNothing);
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
