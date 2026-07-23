import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/screens/wealth_projection_screen.dart';

// Shared widget-test host for WealthProjectionScreen. Drives the screen
// through its injected fetcher seams (same pattern as
// tax_planning_screen_test.dart) so tests never subclass ApiService — which
// would pull package:web into the test VM.

/// Deterministic projection fixture: a rising path, a full FIRE-metrics block
/// and a Monte Carlo fan so the chart, the FIRE plan card and the milestone
/// tiles all render with real content. [years] controls the horizon so tests
/// can exercise long projections; [baristaFiNumber] lets F8 tests model the
/// backend's "barista income not configured" shape (== fi_number).
Map<String, dynamic> projectionFixture({
  int years = 30,
  double baristaFiNumber = 700000.0,
}) {
  return {
    'points': [
      for (int y = 0; y <= years; y++)
        {'year': y, 'month': 0, 'balance': 500000.0 + y * 50000.0},
    ],
    'fire_metrics': {
      'fi_number': 1000000.0,
      'coast_fi_number': 400000.0,
      'barista_fi_number': baristaFiNumber,
      'coast_fi_achieved': false,
      'estimated_years_to_fi': 8.5,
      'monthly_income_at_retirement': 3300.0,
    },
    'monte_carlo': {
      'success_rate': 0.92,
      'percentiles': [
        for (int y = 0; y <= years; y++)
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
}

/// Nonzero projected income so the dividend-outlook toggle is enabled.
const Map<String, dynamic> kDividendsFixture = {
  'projected_annual_income_usd': 5000.0,
  'blended_yield_pct': 1.9,
};

/// A projection fetcher that returns [build]'s result for the requested
/// horizon (`years`), so slider-driven refetches stay consistent.
WealthProjectionFetcher fixtureFetcher(
    Map<String, dynamic> Function(int years) build) {
  return ({
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
    bool mxScenario = false,
    double expensesUsdPortion = 0.0,
    double expensesMxnPortion = 0.0,
    double fxAnnualDrift = 0.0,
    double? usdMxnRate,
  }) async =>
      build(years);
}

/// A "Retire in Mexico" response block matching the backend's
/// `MxScenarioResult` shape, for scenario-panel tests.
Map<String, dynamic> mxScenarioFixture({
  double fxRateToday = 17.0,
  double fxRateAtRetirement = 17.0,
  double fxAnnualDrift = 0.0,
}) {
  return {
    'effective_annual_expenses_usd': 40000.0,
    'annual_expenses_usd_portion': 10000.0,
    'annual_expenses_mxn_portion': 510000.0,
    'fx_rate_today': fxRateToday,
    'fx_rate_at_retirement': fxRateAtRetirement,
    'fx_annual_drift': fxAnnualDrift,
    'fi_number_usd': 1000000.0,
    'fi_number_mxn': 1000000.0 * fxRateAtRetirement,
    'monthly_income_at_retirement_usd': 3300.0,
    'monthly_income_at_retirement_mxn': 3300.0 * fxRateAtRetirement,
  };
}

Widget buildProjectionHost({
  WealthProjectionFetcher? projectionFetcher,
  ProjectionDefaultsFetcher? defaultsFetcher,
  PortfolioDividendsFetcher? dividendsFetcher,
  ProjectionSettingReader? settingReader,
  ProjectionSettingWriter? settingWriter,
  Locale? locale,
  double currentNetWorth = 500000.0,
  NumberFormat? currencyFormat,
  double? usdMxnRate,
}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: WealthProjectionScreen(
        currentNetWorth: currentNetWorth,
        conversionFactor: 1.0,
        usdMxnRate: usdMxnRate,
        currencyFormat: currencyFormat ??
            NumberFormat.currency(symbol: r'$', decimalDigits: 0),
        projectionFetcher:
            projectionFetcher ?? fixtureFetcher((y) => projectionFixture(years: y)),
        defaultsFetcher: defaultsFetcher ?? () async => null,
        dividendsFetcher: dividendsFetcher ?? () async => kDividendsFixture,
        settingReader: settingReader ?? (key) async => null,
        settingWriter: settingWriter ?? (key, value) async {},
      ),
    ),
  );
}

/// Sets the simulated window size, restoring the defaults after the test.
void setTestSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Normalizes the whitespace codepoints intl uses (U+00A0 / U+202F) to plain
/// spaces so bilingual assertions don't pin an exact codepoint.
String normSpace(String s) =>
    s.replaceAll('\u00A0', ' ').replaceAll('\u202F', ' ');
