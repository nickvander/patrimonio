// The tax screen's phone branch must follow the width the SCREEN was given,
// not the window (skill §4/§5).
//
// `_buildContent` derived `isPhone` from `MediaQuery.sizeOf(context).width`
// while the sibling `stackControls` flag two frames up already read the
// screen's own `LayoutBuilder` constraint at the same ~720 threshold. The
// screen renders inside the dashboard's tab container (16/24px of padding
// plus a 1600px clamp), so the two disagreed in the 720–768px window band:
// the header stacked while the Unrealized / FBAR / Retirement / Income
// sections below it stayed in their wide, always-inline form.
//
// `isPhone` is now that same constraint reading, so both directions are
// pinned here: a narrow screen on a wide surface collapses the sections, and
// a wide screen on a small surface does not.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/screens/tax_planning_screen.dart';

const Map<String, dynamic> _summary = {
  'ordinary_income': 5000.0,
  'wage_income': 4000.0,
  'dividend_income': 600.0,
  'interest_income': 400.0,
  'capital_gains': 150.0,
  'short_term_gains': 200.0,
  'long_term_gains': -50.0,
  'total_taxable': 5150.0,
  'estimated_liability_us': 800.0,
  'estimated_liability_mx': 1100.0,
  'effective_rate_us': 0.15,
  'effective_rate_mx': 0.21,
  'bracket_year_used': 2025,
  'constants_verified': true,
  'gains_from_lots': true,
  'holdings_without_basis': 0,
};

const Map<String, dynamic> _fbar = {
  'peak_aggregate_usd': 12000.0,
  'peak_date': '2025-06-30',
  'threshold_usd': 10000.0,
  'exceeded': true,
  'foreign_accounts': <dynamic>[],
};

/// Hosts the screen at an explicit width, INDEPENDENT of the window: the
/// `OverflowBox` hands it a tight [width] whether that is narrower or wider
/// than the surface. That decoupling is the whole point — sizing the window
/// alone would prove nothing about the constraint.
Widget _host({required double width}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: width,
        maxWidth: width,
        child: TaxPlanningScreen(
          conversionFactor: 1.0,
          currencyFormat: NumberFormat.currency(symbol: r'$', decimalDigits: 0),
          targetCurrency: 'USD',
          usdMxnRate: 18.0,
          summaryFetcher: ({required int year, required String status}) async =>
              _summary,
          transactionsFetcher: ({required int year}) async => const <dynamic>[],
          disposalsFetcher: (int year) async => const <dynamic>[],
          unrealizedFetcher:
              ({required int year, required String status}) async =>
                  const <String, dynamic>{'lots': <dynamic>[]},
          fbarFetcher: (int year) async => _fbar,
          contributionsFetcher: (int year) async => const <String, dynamic>{
            'accounts': <dynamic>[],
          },
          realizedYearsFetcher: () async => const <String, dynamic>{
            'by_year': <dynamic>[],
          },
          settingReader: (key) async => null,
          settingWriter: (key, value) async {},
        ),
      ),
    ),
  ),
);

void _useSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// Number of `ExpansionTile`s on screen. `_buildAssumptions` renders one
/// unconditionally, so the interesting quantity is the DELTA: `_maybeCollapse`
/// adds four more (Unrealized, FBAR, Retirement, Income) on the phone branch.
int _expansionTiles(WidgetTester tester) =>
    find.byType(ExpansionTile).evaluate().length;

void main() {
  testWidgets('a narrow screen on a WIDE window collapses four more sections', (
    tester,
  ) async {
    // Both pumps happen on the SAME 1400px window; only the width handed to
    // the screen changes. The MediaQuery version read 1400 in both and left
    // every section inline.
    _useSurface(tester, const Size(1400, 3000));

    // 900px of screen: wide branch, only the always-on assumptions tile.
    await tester.pumpWidget(_host(width: 900));
    await tester.pumpAndSettle();
    final wide = _expansionTiles(tester);

    // 600px of screen on the same window — what the dashboard's tab container
    // produces on a clamped/split layout.
    await tester.pumpWidget(_host(width: 600));
    await tester.pumpAndSettle();

    expect(
      _expansionTiles(tester),
      wide + 4,
      reason: 'Unrealized, FBAR, Retirement and Income all collapse',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a wide screen on a SMALL window keeps the sections inline', (
    tester,
  ) async {
    // The inverse: 900px of screen on a 500px window. The MediaQuery version
    // read 500 and collapsed four sections a 900px surface had room for.
    _useSurface(tester, const Size(500, 3000));

    await tester.pumpWidget(_host(width: 900));
    await tester.pumpAndSettle();
    final wide = _expansionTiles(tester);

    await tester.pumpWidget(_host(width: 400));
    await tester.pumpAndSettle();
    expect(_expansionTiles(tester), wide + 4);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the branch flips at the screen constraint, not the window', (
    tester,
  ) async {
    _useSurface(tester, const Size(1400, 3000));

    await tester.pumpWidget(_host(width: 720));
    await tester.pumpAndSettle();
    final wide = _expansionTiles(tester);

    await tester.pumpWidget(_host(width: 719));
    await tester.pumpAndSettle();
    expect(
      _expansionTiles(tester),
      wide + 4,
      reason: 'one pixel of the SCREEN, not the window, moves the branch',
    );
    expect(tester.takeException(), isNull);
  });
}
