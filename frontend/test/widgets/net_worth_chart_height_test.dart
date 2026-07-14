import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/widgets/net_worth_card.dart';

// Regression: on phones the card used to be pinned to a fixed-height box
// (dashboard SizedBox 380) with the chart in an Expanded — whenever the
// compact header wrapped taller than budgeted (delta chips + currency chips
// + detailed-mode legend) the plot collapsed to a ~40px sliver with
// overlapping y-axis labels. The card now sizes itself: header at natural
// height plus a guaranteed, width-derived chart height. These tests pump the
// card in an unbounded-height scroll view (the real dashboard context) on a
// phone-sized surface and pin the rendered LineChart height.

Map<String, dynamic> _point(
        String date, double netWorth, Map<String, double> byInst) =>
    {
      'date': date,
      'net_worth': netWorth,
      'total_assets': netWorth + 500,
      'total_liabilities': 500.0,
      'by_institution': byInst,
    };

/// Sixty daily snapshots across five institutions — enough history for the
/// MoM chip, the movers row, and a two-row detailed legend, i.e. the tallest
/// compact header the dashboard produces.
List<dynamic> _history() => [
      for (var i = 0; i < 60; i++)
        _point(
          DateFormat('yyyy-MM-dd')
              .format(DateTime.utc(2026, 5, 1).add(Duration(days: i))),
          1500000.0 + i * 1000,
          {
            'Morgan Stanley - StockPlan Connect': 600000.0 + i * 400,
            'Vanguard': 400000.0 + i * 300,
            'Fidelity NetBenefits': 300000.0 + i * 200,
            'CetesDirecto': 100000.0 + i * 50,
            'Chase': 100000.0 + i * 50,
          },
        ),
    ];

Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

NetWorthCard _card({bool showSummary = true, Widget? rangeSelector}) =>
    NetWorthCard(
      netWorth: 1550514.0,
      history: _history(),
      conversionFactor: 1.0,
      currencyFormat: NumberFormat.currency(name: 'USD', symbol: r'$'),
      reportingCurrency: 'USD',
      sourceBreakdown: const [
        {'currency': 'USD', 'net': 1493075.0},
        {'currency': 'MXN', 'net': 1005969.0},
      ],
      usdMxnRate: 17.51,
      showSummary: showSummary,
      rangeSelector: rangeSelector,
    );

void _usePhoneSurface(WidgetTester tester, {Size size = const Size(380, 800)}) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  group('NetWorthCard chart height', () {
    testWidgets('simple mode: plot keeps its full height on a narrow phone',
        (tester) async {
      _usePhoneSurface(tester);
      await tester.pumpWidget(_host(_card()));
      await tester.pumpAndSettle();

      final chartSize = tester.getSize(find.byType(LineChart));
      // Guaranteed minimum from the width-derived clamp — the pre-fix
      // sliver was ~40px here.
      expect(chartSize.height, greaterThanOrEqualTo(220.0));
      expect(tester.takeException(), isNull);
    });

    testWidgets(
        'detailed mode: wrapped legend grows the card, never eats the plot',
        (tester) async {
      _usePhoneSurface(tester);
      await tester.pumpWidget(_host(_card()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Detailed'));
      await tester.pumpAndSettle();

      // Legend rendered (total + top institutions) → tallest header case.
      expect(find.text('Vanguard'), findsOneWidget);
      final chartSize = tester.getSize(find.byType(LineChart));
      expect(chartSize.height, greaterThanOrEqualTo(220.0));
      expect(tester.takeException(), isNull);
    });

    testWidgets('wide layout: chart height clamps at 280', (tester) async {
      _usePhoneSurface(tester, size: const Size(1440, 900));
      await tester.pumpWidget(_host(_card()));
      await tester.pumpAndSettle();

      final chartSize = tester.getSize(find.byType(LineChart));
      expect(chartSize.height, 280.0);
      expect(tester.takeException(), isNull);
    });
  });

  group('NetWorthCard compact header (showSummary: false)', () {
    testWidgets(
        'phone branch: overline title replaces the summary hero and the '
        'injected range selector renders below the chart', (tester) async {
      _usePhoneSurface(tester);
      const selectorKey = Key('in-card-range-selector');
      await tester.pumpWidget(_host(_card(
        showSummary: false,
        rangeSelector: const SizedBox(key: selectorKey, height: 44),
      )));
      await tester.pumpAndSettle();

      // Overline title (the fad9351 idiom) instead of the duplicate hero.
      expect(find.text('NET WORTH HISTORY'), findsOneWidget);
      // displayMoney drops cents at this magnitude → "$1,550,514".
      expect(find.text(r'$1,550,514'), findsNothing,
          reason: 'summary hero number must be suppressed — the dashboard '
              'hero block directly above already shows it');

      // Range selector sits inside the card, below the plot.
      final selectorTop = tester.getTopLeft(find.byKey(selectorKey)).dy;
      final chartBottom = tester.getBottomLeft(find.byType(LineChart)).dy;
      expect(selectorTop, greaterThanOrEqualTo(chartBottom));
      expect(tester.takeException(), isNull);
    });

    testWidgets('default (wide) keeps the full summary hero', (tester) async {
      _usePhoneSurface(tester, size: const Size(1440, 900));
      await tester.pumpWidget(_host(_card()));
      await tester.pumpAndSettle();

      expect(find.text(r'$1,550,514'), findsOneWidget);
      expect(find.text('NET WORTH HISTORY'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
