import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/screens/wealth_projection_screen.dart';

// These tests drive the screen through its injected fetcher seams (the same
// pattern as tax_planning_screen_test.dart), so they never subclass
// ApiService — which would pull package:web into the test VM.

// Deterministic projection fixture: a rising path, a full FIRE-metrics block
// and a Monte Carlo fan so the chart, the FIRE plan card and the milestone
// tiles all render with real content.
final Map<String, dynamic> _projection = {
  'points': [
    for (int y = 0; y <= 30; y++)
      {'year': y, 'month': 0, 'balance': 500000.0 + y * 50000.0},
  ],
  'fire_metrics': {
    'fi_number': 1000000.0,
    'coast_fi_number': 400000.0,
    'barista_fi_number': 700000.0,
    'coast_fi_achieved': false,
    'estimated_years_to_fi': 8.5,
    'monthly_income_at_retirement': 3300.0,
  },
  'monte_carlo': {
    'success_rate': 0.92,
    'percentiles': [
      for (int y = 0; y <= 30; y++)
        {
          'year': y,
          'p10': 400000.0 + y * 30000.0,
          'p25': 450000.0 + y * 40000.0,
          'p50': 500000.0 + y * 50000.0,
          'p75': 550000.0 + y * 60000.0,
          'p90': 600000.0 + y * 70000.0,
        },
    ],
  },
};

// Nonzero projected income so the dividend-outlook toggle is enabled.
const Map<String, dynamic> _dividends = {
  'projected_annual_income_usd': 5000.0,
  'blended_yield_pct': 1.9,
};

Widget _host() {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: WealthProjectionScreen(
        currentNetWorth: 500000.0,
        conversionFactor: 1.0,
        currencyFormat: NumberFormat.currency(symbol: r'$', decimalDigits: 0),
        projectionFetcher: ({
          required double startBalance,
          required double monthlyContribution,
          required double annualReturnRate,
          required double annualExpenses,
          required double withdrawalRate,
          int years = 30,
          double annualInflationRate = 0.03,
          double returnVolatility = 0.13,
          int? yearsToRetirement,
          int monteCarloTrials = 1000,
          double baristaMonthlyIncome = 0.0,
          double annualTaxDrag = 0.0,
          bool withdrawalGuardrails = false,
        }) async =>
            _projection,
        defaultsFetcher: () async => null,
        dividendsFetcher: () async => _dividends,
        settingReader: (key) async => null,
      ),
    ),
  );
}

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  // Round-3 regression (HIGH): at 1440x900 the desktop layout's right column
  // is height-constrained; toggling the dividend income outlook panel ON used
  // to steal the chart's flex space, collapsing the plot to a ~8px sliver and
  // squashing the FIRE milestone tiles. The chart must keep a usable height
  // with the panel both off and on.
  testWidgets(
      'wide 1440x900: chart keeps a usable height with the dividend outlook '
      'panel toggled on', (tester) async {
    _setSize(tester, const Size(1440, 900));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    // Panel off: the classic flex layout is untouched — the chart card keeps
    // its healthy share (~290px card / ~170px plot at this size, same as
    // before the fix).
    expect(find.text('Dividend income outlook'), findsNothing);
    final chartCard = find
        .ancestor(of: find.text('Net worth projection'), matching: find.byType(Card))
        .first;
    expect(tester.getSize(chartCard).height, greaterThanOrEqualTo(260.0));
    expect(tester.getSize(find.byType(LineChart)).height,
        greaterThanOrEqualTo(150.0));

    // Toggle the outlook panel on from the controls column.
    final label = find.text('Show dividend income outlook');
    await tester.ensureVisible(label);
    await tester.pumpAndSettle();
    final toggleRow =
        find.ancestor(of: label, matching: find.byType(MergeSemantics)).first;
    await tester
        .tap(find.descendant(of: toggleRow, matching: find.byType(Switch)));
    await tester.pumpAndSettle();

    // Panel is visible...
    final panelTitle = find.text('Dividend income outlook');
    expect(panelTitle, findsOneWidget);

    // ...and the chart still has a usable render-box height (the defect
    // collapsed it to ~8px here).
    final chart = find.byType(LineChart);
    expect(chart, findsOneWidget);
    expect(tester.getSize(chart).height, greaterThanOrEqualTo(200.0));

    // Reading order preserved: chart, then outlook panel, then FIRE plan.
    final chartTop = tester.getTopLeft(chart).dy;
    final panelTop = tester.getTopLeft(panelTitle).dy;
    final fireTop = tester.getTopLeft(find.text('Your FIRE plan')).dy;
    expect(chartTop, lessThan(panelTop));
    expect(panelTop, lessThan(fireTop));

    // The FIRE milestone tiles are intact too (not squashed away).
    expect(find.text('Success rate'), findsOneWidget);

    // Toggling back off restores the classic flex layout with a full-height
    // chart card.
    await tester
        .tap(find.descendant(of: toggleRow, matching: find.byType(Switch)));
    await tester.pumpAndSettle();
    expect(find.text('Dividend income outlook'), findsNothing);
    expect(tester.getSize(chartCard).height, greaterThanOrEqualTo(260.0));
  });

  testWidgets('tall desktop keeps the flex layout with the panel on',
      (tester) async {
    _setSize(tester, const Size(1440, 1600));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final label = find.text('Show dividend income outlook');
    await tester.ensureVisible(label);
    await tester.pumpAndSettle();
    final toggleRow =
        find.ancestor(of: label, matching: find.byType(MergeSemantics)).first;
    await tester
        .tap(find.descendant(of: toggleRow, matching: find.byType(Switch)));
    await tester.pumpAndSettle();

    expect(find.text('Dividend income outlook'), findsOneWidget);
    expect(tester.getSize(find.byType(LineChart)).height,
        greaterThanOrEqualTo(200.0));
  });
}
