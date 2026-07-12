import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/performance_card.dart';

// The "Investments vs S&P 500" (money-weighted tracked-lots) section of the
// performance card. Data is canned through the card's fetch-override seams —
// widget tests can't subclass ApiService (same convention as
// DividendIncomeCard.fetchOverride).
//
// Pinned here: the bmContribCaveat comprehension caption. The tracked-lots
// figure (recent-buy-dominated, recorded lots only) can legitimately sit far
// below the all-time TWR shown above it, which read as a bug without the
// caveat — so it must render, in both locales, under the section subtitle.

/// Canned GET /benchmark-comparison payload: 118 purchases, ~$103k invested,
/// index ahead — the exact shape `_benchmarkSection` reads.
Map<String, dynamic> _comparisonPayload() => {
      'invested_usd': 103436.0,
      'lot_count': 118,
      'your_value_usd': 110000.0,
      'benchmark_value_usd': 115000.0,
    };

const _caveatEn =
    'Covers only purchases with recorded lots — recent buys weigh most, so '
    'this can sit far below the portfolio return above.';
const _caveatEs =
    'Cubre solo compras con lotes registrados — las compras recientes pesan '
    'más, por lo que puede quedar muy por debajo del rendimiento del '
    'portafolio de arriba.';
const _subtitleEn =
    'Money-weighted, all time — if your contributions had bought the index '
    'on each purchase date';
const _subtitleEs =
    'Ponderado por dinero, todo el periodo — si tus aportaciones hubieran '
    'comprado el índice en cada fecha de compra';

Widget _host(Widget child, {Locale? locale}) => MaterialApp(
      locale: locale,
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
  PerformanceCard card() => PerformanceCard(
        apiService: ApiService(),
        conversionFactor: 1.0,
        currencyFormat: NumberFormat.currency(symbol: r'$'),
        historyFetchOverride: () async => <dynamic>[],
        comparisonFetchOverride: () async => _comparisonPayload(),
        twrFetchOverride: () async => null,
      );

  group('PerformanceCard — bmContribCaveat comprehension caption', () {
    Future<void> pumpAndExpect(
      WidgetTester tester, {
      Locale? locale,
      required String subtitle,
      required String caveat,
    }) async {
      // Wide surface (>= 720): the money-weighted section renders inline,
      // not behind the phone-only disclosure.
      _useSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(_host(card(), locale: locale));
      await tester.pumpAndSettle();

      expect(find.text(subtitle), findsOneWidget,
          reason: 'section subtitle missing');
      final caveatFinder = find.text(caveat);
      expect(caveatFinder, findsOneWidget, reason: 'caveat caption missing');
      // The caveat sits with the explanatory text, directly under the
      // subtitle and above the you-vs-index tiles.
      expect(
        tester.getTopLeft(caveatFinder).dy,
        greaterThan(tester.getTopLeft(find.text(subtitle)).dy),
      );
      expect(tester.takeException(), isNull);
    }

    testWidgets('renders under the comparison subtitle (en)', (tester) async {
      await pumpAndExpect(tester,
          subtitle: _subtitleEn, caveat: _caveatEn);
    });

    testWidgets('renders under the comparison subtitle (es)', (tester) async {
      await pumpAndExpect(tester,
          locale: const Locale('es'), subtitle: _subtitleEs, caveat: _caveatEs);
    });
  });
}
