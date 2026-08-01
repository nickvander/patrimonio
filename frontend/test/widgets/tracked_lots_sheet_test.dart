import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/utils/theme_colors.dart';
import 'package:patrimonio/widgets/tracked_lots_sheet.dart';

// The "What's tracked" drill-down behind the benchmark comparison's
// purchases line: per-symbol tracked lots (with the vs-index pts delta) and
// the holdings excluded for lack of recorded lot data.
//
// Parsing is pinned separately from rendering: the fields are ADDITIVE on
// GET /api/dashboard/benchmark-comparison, so an old backend (fields absent)
// must yield an empty breakdown — the card then hides the affordance — and
// never a crash.

String _normSpace(String s) =>
    s.replaceAll('\u00A0', ' ').replaceAll('\u202F', ' ');

Finder _findText(String expected) => find.byWidgetPredicate(
  (w) =>
      w is Text &&
      w.data != null &&
      _normSpace(w.data!) == _normSpace(expected),
);

Map<String, dynamic> _fullPayload() => {
  'invested_usd': 60000.0,
  'lot_count': 13,
  'your_value_usd': 63000.0,
  'benchmark_value_usd': 62800.0,
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

Widget _host(Widget sheet, {Locale? locale}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: sheet),
);

TrackedLotsSheet _sheet(TrackedLotsBreakdown breakdown) => TrackedLotsSheet(
  breakdown: breakdown,
  conversionFactor: 1.0,
  currencyFormat: NumberFormat.currency(symbol: r'$'),
);

void main() {
  group('TrackedLotsBreakdown.parse — tolerant of the additive contract', () {
    test('old backend: fields absent → empty breakdown, no crash', () {
      final b = TrackedLotsBreakdown.parse({
        'invested_usd': 103436.0,
        'lot_count': 118,
        'your_value_usd': 110000.0,
        'benchmark_value_usd': 115000.0,
      });
      expect(b.isEmpty, isTrue);
      expect(b.symbols, isEmpty);
      expect(b.untracked, isEmpty);
      expect(b.untrackedValueUsd, 0);
      expect(TrackedLotsBreakdown.parse(null).isEmpty, isTrue);
    });

    test('full payload parses fields and keeps the server order', () {
      final b = TrackedLotsBreakdown.parse(_fullPayload());
      expect(b.symbols.map((s) => s.symbol), ['VOO', 'AAPL']);
      final voo = b.symbols.first;
      expect(voo.lotCount, 12);
      expect(voo.investedUsd, 40000.0);
      expect(voo.yourValueUsd, 44000.0);
      expect(voo.benchmarkValueUsd, 43000.0);
      expect(voo.firstAcquired, DateTime(2024, 3, 15));
      expect(voo.lastAcquired, DateTime(2026, 6, 1));
      // pts = (your − bench) / invested × 100.
      expect(voo.deltaPts, closeTo(2.5, 1e-9));
      expect(b.symbols.last.deltaPts, closeTo(-4.0, 1e-9));
      expect(b.untracked.single.symbol, 'FXAIX');
      expect(b.untracked.single.valueUsd, 25000.0);
      expect(b.untrackedValueUsd, 25000.0);
    });

    test('missing untracked total falls back to the row sum; zero invested '
        'yields no pts', () {
      final payload = _fullPayload()..remove('untracked_value_usd');
      (payload['untracked'] as List).add({
        'symbol': 'CASH',
        'value_usd': 5000.0,
      });
      final b = TrackedLotsBreakdown.parse(payload);
      expect(b.untrackedValueUsd, closeTo(30000.0, 1e-9));

      const zero = TrackedLotSymbol(
        symbol: 'X',
        lotCount: 0,
        investedUsd: 0,
        yourValueUsd: 0,
        benchmarkValueUsd: 0,
      );
      expect(zero.deltaPts, isNull);
    });
  });

  group('TrackedLotsSheet — rendering (en)', () {
    testWidgets('title, caption, both symbols in order, plurals, first buy, '
        'invested → value, signed pts colors, untracked section', (
      tester,
    ) async {
      final b = TrackedLotsBreakdown.parse(_fullPayload());
      await tester.pumpWidget(_host(_sheet(b)));
      await tester.pumpAndSettle();

      expect(_findText("What's tracked"), findsOneWidget);
      expect(
        _findText(
          'Purchases with recorded lots, compared with buying the '
          'index on the same dates',
        ),
        findsOneWidget,
      );

      expect(
        tester.getTopLeft(find.text('VOO')).dy,
        lessThan(tester.getTopLeft(find.text('AAPL')).dy),
      );

      expect(_findText('12 lots · first buy Mar 2024'), findsOneWidget);
      expect(_findText('1 lot · first buy Jan 2025'), findsOneWidget);

      // displayMoney: ≥ $10k renders without cents.
      expect(_findText(r'$40,000 → $44,000'), findsOneWidget);
      expect(_findText(r'$20,000 → $19,000'), findsOneWidget);

      final ctx = tester.element(find.byType(TrackedLotsSheet));
      final ahead = _findText('+2.5 pts vs index');
      final behind = _findText('-4.0 pts vs index');
      expect(ahead, findsOneWidget);
      expect(behind, findsOneWidget);
      expect(tester.widget<Text>(ahead).style?.color, ctx.positive);
      expect(tester.widget<Text>(behind).style?.color, ctx.negative);

      expect(
        _findText('Not included — no recorded purchase data'),
        findsOneWidget,
      );
      expect(find.text('FXAIX'), findsOneWidget);
      expect(_findText(r'$25,000'), findsOneWidget);
      expect(_findText(r'$25,000 of holdings excluded'), findsOneWidget);
      expect(
        _findText(
          'Add purchase lots to include these holdings in the '
          'comparison.',
        ),
        findsOneWidget,
      );

      expect(tester.takeException(), isNull);
    });

    testWidgets('empty untracked list → no excluded section at all', (
      tester,
    ) async {
      final payload = _fullPayload()
        ..['untracked'] = <dynamic>[]
        ..['untracked_value_usd'] = 0.0;
      final b = TrackedLotsBreakdown.parse(payload);
      await tester.pumpWidget(_host(_sheet(b)));
      await tester.pumpAndSettle();

      expect(_findText("What's tracked"), findsOneWidget);
      expect(
        _findText('Not included — no recorded purchase data'),
        findsNothing,
      );
      expect(find.textContaining('excluded'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('TrackedLotsSheet — rendering (es)', () {
    testWidgets('strings localize: plurals, first buy, pts, untracked', (
      tester,
    ) async {
      final b = TrackedLotsBreakdown.parse(_fullPayload());
      await tester.pumpWidget(_host(_sheet(b), locale: const Locale('es')));
      await tester.pumpAndSettle();

      expect(_findText('Qué está registrado'), findsOneWidget);
      expect(
        _findText(
          'Compras con lotes registrados, comparadas con comprar el '
          'índice en las mismas fechas',
        ),
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

      expect(
        _findText('No incluido — sin datos de compras registradas'),
        findsOneWidget,
      );
      expect(_findText(r'$25,000 de posiciones excluidas'), findsOneWidget);
      expect(
        _findText(
          'Agrega lotes de compra para incluir estas posiciones '
          'en la comparación.',
        ),
        findsOneWidget,
      );

      expect(tester.takeException(), isNull);
    });
  });
}
