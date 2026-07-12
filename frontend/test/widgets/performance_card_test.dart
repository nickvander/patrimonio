import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/utils/theme_colors.dart';
import 'package:patrimonio/widgets/performance_card.dart';
import 'package:patrimonio/widgets/tracked_lots_sheet.dart';

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

/// The same payload with the additive per-symbol breakdown (frozen contract):
/// two tracked symbols sorted by invested desc + one untracked holding.
/// VOO: (44000−43000)/40000 × 100 = +2.5 pts ahead of the index.
/// AAPL: (19000−19800)/20000 × 100 = −4.0 pts behind, single lot (=1 plural).
Map<String, dynamic> _comparisonPayloadWithSymbols() => {
      ..._comparisonPayload(),
      'symbols': [
        {
          'symbol': 'VOO',
          'lot_count': 12,
          'invested_usd': 40000.0,
          'your_value_usd': 44000.0,
          'benchmark_value_usd': 43000.0,
          'first_acquired': '2024-03-15',
          'last_acquired': '2026-06-01',
        },
        {
          'symbol': 'AAPL',
          'lot_count': 1,
          'invested_usd': 20000.0,
          'your_value_usd': 19000.0,
          'benchmark_value_usd': 19800.0,
          'first_acquired': '2025-01-10',
          'last_acquired': '2025-01-10',
        },
      ],
      'untracked': [
        {'symbol': 'FXAIX', 'value_usd': 25000.0},
      ],
      'untracked_value_usd': 25000.0,
    };

/// es "NBSP before %"-style codepoints must count as plain spaces so string
/// assertions prove content without pinning the exact whitespace codepoint.
String _normSpace(String s) =>
    s.replaceAll('\u00A0', ' ').replaceAll('\u202F', ' ');


/// Text finder that compares whitespace-normalized content.
Finder _findText(String expected) => find.byWidgetPredicate((w) =>
    w is Text && w.data != null && _normSpace(w.data!) == _normSpace(expected));

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
  PerformanceCard card({Map<String, dynamic>? comparison}) => PerformanceCard(
        apiService: ApiService(),
        conversionFactor: 1.0,
        currencyFormat: NumberFormat.currency(symbol: r'$'),
        historyFetchOverride: () async => <dynamic>[],
        comparisonFetchOverride: () async => comparison ?? _comparisonPayload(),
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

  group('PerformanceCard — tracked-lots drill-down', () {
    Future<void> pumpCard(WidgetTester tester,
        {Locale? locale, Map<String, dynamic>? comparison}) async {
      // Wide surface (>= 720): the money-weighted section renders inline,
      // not behind the phone-only disclosure.
      _useSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(
          _host(card(comparison: comparison), locale: locale));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'purchases line is a button that opens the sheet: symbols sorted, '
        'plurals, signed pts with house colors, untracked total (en)',
        (tester) async {
      final semantics = tester.ensureSemantics();
      await pumpCard(tester, comparison: _comparisonPayloadWithSymbols());

      // Visible affordance on the purchases line, announced as a button
      // with the explanatory hint.
      final affordance = _findText("See what's tracked");
      expect(affordance, findsOneWidget);
      expect(
        tester.getSemantics(affordance),
        isSemantics(
          isButton: true,
          hasTapAction: true,
          hint: 'Shows which tickers have recorded lots and which are '
              'excluded',
        ),
      );

      await tester.tap(affordance);
      await tester.pumpAndSettle();

      expect(find.byType(TrackedLotsSheet), findsOneWidget);
      expect(_findText("What's tracked"), findsOneWidget);
      expect(
        _findText('Purchases with recorded lots, compared with buying the '
            'index on the same dates'),
        findsOneWidget,
      );

      // Both tracked symbols, in the server's invested-desc order.
      expect(find.text('VOO'), findsOneWidget);
      expect(find.text('AAPL'), findsOneWidget);
      expect(tester.getTopLeft(find.text('VOO')).dy,
          lessThan(tester.getTopLeft(find.text('AAPL')).dy));

      // Lot-count plurals + localized first-buy month-year.
      expect(_findText('12 lots · first buy Mar 2024'), findsOneWidget);
      expect(_findText('1 lot · first buy Jan 2025'), findsOneWidget);

      // invested → current value via displayMoney (≥ $10k drops cents).
      expect(_findText(r'$40,000 → $44,000'), findsOneWidget);
      expect(_findText(r'$20,000 → $19,000'), findsOneWidget);

      // Signed pts vs index, house positive/negative colors.
      final sheetCtx = tester.element(find.byType(TrackedLotsSheet));
      final aheadFinder = _findText('+2.5 pts vs index');
      final behindFinder = _findText('-4.0 pts vs index');
      expect(aheadFinder, findsOneWidget);
      expect(behindFinder, findsOneWidget);
      expect(tester.widget<Text>(aheadFinder).style?.color,
          sheetCtx.positive);
      expect(tester.widget<Text>(behindFinder).style?.color,
          sheetCtx.negative);

      // Untracked section: header, row, excluded total, add-lots hint.
      expect(
          _findText('Not included — no recorded purchase data'),
          findsOneWidget);
      expect(find.text('FXAIX'), findsOneWidget);
      expect(_findText(r'$25,000'), findsOneWidget);
      expect(_findText(r'$25,000 of holdings excluded'), findsOneWidget);
      expect(
          _findText('Add purchase lots to include these holdings in the '
              'comparison.'),
          findsOneWidget);

      expect(tester.takeException(), isNull);
      semantics.dispose();
    });

    testWidgets('sheet strings localize (es): plurals, first buy, pts, '
        'untracked', (tester) async {
      await pumpCard(tester,
          locale: const Locale('es'),
          comparison: _comparisonPayloadWithSymbols());

      final affordance = _findText('Ver qué está registrado');
      expect(affordance, findsOneWidget);
      await tester.tap(affordance);
      await tester.pumpAndSettle();

      expect(_findText('Qué está registrado'), findsOneWidget);
      expect(
        _findText('Compras con lotes registrados, comparadas con comprar el '
            'índice en las mismas fechas'),
        findsOneWidget,
      );

      // Month-year via the es date symbols (computed, not hardcoded, so the
      // assertion doesn't pin a CLDR abbreviation style).
      final mar24 = DateFormat.yMMM('es').format(DateTime(2024, 3, 15));
      final jan25 = DateFormat.yMMM('es').format(DateTime(2025, 1, 10));
      expect(_findText('12 lotes · primera compra $mar24'), findsOneWidget);
      expect(_findText('1 lote · primera compra $jan25'), findsOneWidget);

      expect(_findText('+2.5 pts vs índice'), findsOneWidget);
      expect(_findText('-4.0 pts vs índice'), findsOneWidget);

      expect(_findText('No incluido — sin datos de compras registradas'),
          findsOneWidget);
      expect(_findText(r'$25,000 de posiciones excluidas'), findsOneWidget);
      expect(
          _findText('Agrega lotes de compra para incluir estas posiciones '
              'en la comparación.'),
          findsOneWidget);

      expect(tester.takeException(), isNull);
    });

    testWidgets('old backend (no additive fields): line renders with no '
        'affordance and tapping opens nothing', (tester) async {
      await pumpCard(tester); // base payload — no symbols/untracked

      // The purchases line still renders…
      final note = _findText(r'118 purchases · $103,436 invested');
      expect(note, findsOneWidget);
      // …but with the drill-down affordance hidden.
      expect(_findText("See what's tracked"), findsNothing);
      expect(find.byType(TrackedLotsSheet), findsNothing);

      await tester.tap(note, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(find.byType(TrackedLotsSheet), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
