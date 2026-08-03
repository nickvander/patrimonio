import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/utils/currency.dart';
import 'package:patrimonio/widgets/net_worth_card.dart';
import 'package:patrimonio/widgets/performance_card.dart';

// The owner reported TWICE that tapping a chart on a phone puts the tooltip
// under the finger. Pinning it to the top of the chart box (b7cbb85) wasn't
// enough: the performance chart is 120 logical px on phones and a 3-line
// tooltip is ~64 of them, so its bottom edge still landed ~36px above the
// touch point — under the fingertip and hand.
//
// The fix is the Robinhood / Copilot scrub pattern: on TOUCH the chart draws
// no tooltip at all (only the vertical guide + highlighted dot) and the
// scrubbed values surface in the card HEADER, ~200px clear of the hand.
// Mouse/trackpad are untouched — a cursor doesn't occlude what it points at.
//
// These tests drive real synthesized pointers against the two adopting cards
// and read the header off the rendered widget tree.

// ─────────────────────────── performance card ───────────────────────────

/// A month of TWR points on FIXED past dates (DateRange.all applies no
/// now()-relative cutoff), full coverage, so the card renders the TWR chart
/// and it is its ONLY LineChart. twr rises 1%/day and sp 0.5%/day from a
/// base of 1.0, so day N reads exactly +N.0% / +N/2%.
Map<String, dynamic> _twrFixture() => {
  'points': [
    for (int i = 0; i < 30; i++)
      {
        'date': DateFormat(
          'yyyy-MM-dd',
        ).format(DateTime.utc(2026, 5, 1).add(Duration(days: i))),
        'twr': 1.0 + i * 0.01,
        'sp': 1.0 + i * 0.005,
      },
  ],
  'coverage_pct': 1.0,
  'total_value_usd': 250000.0,
};

Widget _perfHost({Locale? locale}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: SingleChildScrollView(
      child: PerformanceCard(
        apiService: ApiService(),
        conversionFactor: 1.0,
        currencyFormat: moneyFormat('USD'),
        historyFetchOverride: () async => <dynamic>[],
        comparisonFetchOverride: () async => null,
        twrFetchOverride: () async => _twrFixture(),
      ),
    ),
  ),
);

// ──────────────────────────── net-worth card ────────────────────────────

class _FakeAttributionApi extends ApiService {
  @override
  Future<Map<String, dynamic>> getNetWorthAttribution({
    required String from,
    required String to,
    bool forceRefresh = false,
  }) async => throw Exception('not needed for the scrub tests');
}

/// A month of daily snapshots on fixed past dates: day i is worth
/// 1500 + 10*i, so a scrub lands on a value the test can name exactly.
List<dynamic> _netWorthHistory() => [
  for (var i = 0; i < 30; i++)
    {
      'date': DateFormat(
        'yyyy-MM-dd',
      ).format(DateTime.utc(2026, 2, 1).add(Duration(days: i))),
      'net_worth': 1500.0 + i * 10,
      'total_assets': 2000.0 + i * 10,
      'total_liabilities': 500.0,
      'by_institution': const <String, dynamic>{},
    },
];

Widget _netWorthHost({required bool showSummary, Locale? locale}) =>
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: NetWorthCard(
            netWorth: 1790.0,
            history: _netWorthHistory(),
            conversionFactor: 1.0,
            currencyFormat: moneyFormat('USD'),
            reportingCurrency: 'USD',
            sourceBreakdown: const [],
            usdMxnRate: 20.0,
            showSummary: showSummary,
            apiService: _FakeAttributionApi(),
          ),
        ),
      ),
    );

// ─────────────────────────────── helpers ────────────────────────────────

LineChartData _chartData(WidgetTester tester) =>
    tester.widget<LineChart>(find.byType(LineChart)).data;

/// The in-chart tooltip: fl_chart paints it from `showingTooltipIndicators`.
bool _tooltipShowing(WidgetTester tester) =>
    _chartData(tester).showingTooltipIndicators.isNotEmpty;

/// The vertical scrub guide + highlighted dot: painted from the per-bar
/// `showingIndicators`, independently of the tooltip. It must SURVIVE the
/// touch treatment — it's the position feedback that replaces the tooltip.
bool _indicatorShowing(WidgetTester tester) =>
    _chartData(tester).lineBarsData.any((b) => b.showingIndicators.isNotEmpty);

void _useSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The chart's left/right edge, inset a hair so the pointer lands inside the
/// plot. The adopting charts disable all axis titles or reserve them
/// symmetrically, and snapping is dx-only with a huge threshold, so the edges
/// resolve to the first / last sample.
Offset _chartEdge(WidgetTester tester, {required bool right}) {
  final rect = tester.getRect(find.byType(LineChart));
  return Offset(right ? rect.right - 2 : rect.left + 2, rect.center.dy);
}

/// es-MX renders NBSP / narrow-NBSP before "%" and inside money; normalize
/// so assertions prove the localization without pinning the exact codepoint.
String _normSpace(String s) =>
    s.replaceAll('\u00A0', ' ').replaceAll('\u202F', ' ');

/// Every rendered Text/Text.rich string, whitespace-normalized.
List<String> _texts(WidgetTester tester) => [
  for (final t in tester.widgetList<Text>(find.byType(Text)))
    _normSpace(t.data ?? t.textSpan?.toPlainText() ?? ''),
];

void main() {
  group('performance card — touch scrub moves the reading to the header', () {
    testWidgets('a touch drag updates the header and draws NO in-chart '
        'tooltip; the guide/dot stay', (tester) async {
      _useSurface(tester, const Size(700, 1000));
      await tester.pumpWidget(_perfHost());
      await tester.pumpAndSettle();

      // Live header: the current portfolio value + its caption, and the two
      // return pills for the whole window (day 29 → +29.0% / +14.5%).
      expect(find.text('Portfolio value'), findsOneWidget);
      expect(find.text(r'$250,000'), findsOneWidget);
      expect(find.text('+29.0%'), findsOneWidget);
      expect(find.text('+14.5%'), findsOneWidget);

      // Press, then drag to the FIRST sample (May 1, +0.0% / +0.0%).
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LineChart)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(_chartEdge(tester, right: false));
      await tester.pump();

      expect(
        _tooltipShowing(tester),
        isFalse,
        reason: 'a finger must never get a tooltip under it',
      );
      expect(
        _indicatorShowing(tester),
        isTrue,
        reason: 'the guide + dot remain as the touch position feedback',
      );
      // Header now reports the scrubbed point: the date replaces the
      // "Portfolio value" caption, the headline and both pills report the
      // values AT that date.
      expect(find.text('May 1, 2026'), findsOneWidget);
      expect(find.text('Portfolio value'), findsNothing);
      expect(find.text(r'$250,000'), findsNothing);
      // headline + "Your portfolio" pill + benchmark pill all read +0.0%.
      expect(find.text('+0.0%'), findsNWidgets(3));
      expect(find.text('+29.0%'), findsNothing);

      // Drag to the LAST sample: May 30 (day 29) → +29.0% / +14.5%.
      await gesture.moveTo(_chartEdge(tester, right: true));
      await tester.pump();
      expect(find.text('May 30, 2026'), findsOneWidget);
      expect(find.text('+29.0%'), findsNWidgets(2)); // headline + "you" pill
      expect(find.text('+14.5%'), findsOneWidget); // benchmark pill

      // Lift: the header reverts to the live values in the same frame — a
      // stale scrub reading must never outlive the gesture.
      await gesture.up();
      await tester.pump();
      expect(find.text('Portfolio value'), findsOneWidget);
      expect(find.text(r'$250,000'), findsOneWidget);
      expect(find.text('May 30, 2026'), findsNothing);
      expect(find.text('+29.0%'), findsOneWidget);
      expect(_indicatorShowing(tester), isFalse);
      expect(_tooltipShowing(tester), isFalse);
    });

    testWidgets('a MOUSE hover still shows the in-chart tooltip and leaves '
        'the header alone', (tester) async {
      _useSurface(tester, const Size(1440, 900));
      await tester.pumpWidget(_perfHost());
      await tester.pumpAndSettle();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await tester.pump();

      await mouse.moveTo(tester.getCenter(find.byType(LineChart)));
      await tester.pump();

      expect(
        _tooltipShowing(tester),
        isTrue,
        reason: 'desktop has no occlusion problem — the popover is unchanged',
      );
      // Header untouched: still the live value + caption, live pills.
      expect(find.text('Portfolio value'), findsOneWidget);
      expect(find.text(r'$250,000'), findsOneWidget);
      expect(find.text('+29.0%'), findsOneWidget);
      expect(find.text('May 1, 2026'), findsNothing);
    });

    testWidgets('the scrubbed reading is announced to screen readers (en)', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      _useSurface(tester, const Size(700, 1000));
      await tester.pumpWidget(_perfHost());
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LineChart)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(_chartEdge(tester, right: false));
      await tester.pump();

      // It replaces a tooltip that was already invisible to screen readers,
      // so the label has to carry the whole reading.
      expect(
        find.bySemanticsLabel(
          'Chart reading at May 1, 2026: Your portfolio +0.0%, S&P 500 +0.0%',
        ),
        findsOneWidget,
      );

      await gesture.up();
      await tester.pump();
      semantics.dispose();
    });

    testWidgets('the scrubbed reading is announced to screen readers (es)', (
      tester,
    ) async {
      final semantics = tester.ensureSemantics();
      _useSurface(tester, const Size(700, 1000));
      await tester.pumpWidget(_perfHost(locale: const Locale('es')));
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LineChart)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(_chartEdge(tester, right: false));
      await tester.pump();

      expect(
        find.bySemanticsLabel(
          RegExp(r'^Lectura de la gráfica en May 1, 2026: Tu portafolio '),
        ),
        findsOneWidget,
      );

      await gesture.up();
      await tester.pump();
      semantics.dispose();
    });
  });

  group('net-worth card — touch scrub moves the reading to the header', () {
    testWidgets('phone header (no in-card summary): the overline title '
        'becomes the scrubbed date + value, no in-chart tooltip', (
      tester,
    ) async {
      _useSurface(tester, const Size(390, 1200));
      await tester.pumpWidget(_netWorthHost(showSummary: false));
      await tester.pumpAndSettle();

      expect(find.text('NET WORTH HISTORY'), findsOneWidget);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LineChart)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(_chartEdge(tester, right: false));
      await tester.pump();

      expect(_tooltipShowing(tester), isFalse);
      expect(_indicatorShowing(tester), isTrue);
      expect(find.text('NET WORTH HISTORY'), findsNothing);
      // Feb 1 → $1,500 (the first snapshot).
      expect(_texts(tester), contains(contains('Feb 1')));
      expect(_texts(tester), contains(contains(r'$1,500')));

      await gesture.up();
      await tester.pump();
      expect(find.text('NET WORTH HISTORY'), findsOneWidget);
      expect(_indicatorShowing(tester), isFalse);
    });

    testWidgets('summary header: the hero number and its label become the '
        'scrubbed value and date, and revert on release', (tester) async {
      _useSurface(tester, const Size(1000, 1400));
      await tester.pumpWidget(_netWorthHost(showSummary: true));
      await tester.pumpAndSettle();

      expect(find.text('Total net worth (USD)'), findsOneWidget);
      expect(find.text(r'$1,790.00'), findsOneWidget);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LineChart)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(_chartEdge(tester, right: false));
      await tester.pump();

      expect(_tooltipShowing(tester), isFalse);
      expect(find.text('Total net worth (USD)'), findsNothing);
      expect(find.text('Feb 1, 2026'), findsOneWidget);
      expect(find.text(r'$1,500.00'), findsOneWidget);

      await gesture.up();
      await tester.pump();
      expect(find.text('Total net worth (USD)'), findsOneWidget);
      expect(find.text(r'$1,790.00'), findsOneWidget);
      expect(find.text('Feb 1, 2026'), findsNothing);
    });

    testWidgets('a MOUSE hover keeps the in-chart tooltip and the live hero', (
      tester,
    ) async {
      _useSurface(tester, const Size(1000, 1400));
      await tester.pumpWidget(_netWorthHost(showSummary: true));
      await tester.pumpAndSettle();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      addTearDown(mouse.removePointer);
      await tester.pump();
      await mouse.moveTo(tester.getCenter(find.byType(LineChart)));
      await tester.pump();

      expect(_tooltipShowing(tester), isTrue);
      expect(find.text('Total net worth (USD)'), findsOneWidget);
      expect(find.text(r'$1,790.00'), findsOneWidget);
      expect(find.text('Feb 1, 2026'), findsNothing);
    });
  });
}
