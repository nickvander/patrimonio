import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/utils/app_locale.dart';
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
///
/// [valueUsd] optionally attaches the endpoint's per-day valuation
/// (`points[].value_usd`); [coverage] lets a test drop below the card's
/// coverage floor. Both default to the pre-`value_usd` shape so the original
/// scrub tests keep exercising the `_history` path.
Map<String, dynamic> _twrFixture({
  double Function(int i)? valueUsd,
  double coverage = 1.0,
}) => {
  'points': [
    for (int i = 0; i < 30; i++)
      {
        'date': DateFormat(
          'yyyy-MM-dd',
        ).format(DateTime.utc(2026, 5, 1).add(Duration(days: i))),
        'twr': 1.0 + i * 0.01,
        'sp': 1.0 + i * 0.005,
        if (valueUsd != null) 'value_usd': valueUsd(i),
      },
  ],
  'coverage_pct': coverage,
  'total_value_usd': 250000.0,
};

/// Portfolio value history over the SAME month as the TWR fixture, so a
/// scrubbed TWR date resolves to a dollar value: day i is worth
/// `250000 - (29 - i) * 1000`, i.e. May 1 → $221,000 and May 30 → $250,000
/// (the last point matching the TWR payload's `total_value_usd`, as it does
/// in production).
List<dynamic> _valueHistory() => [
  for (var i = 0; i < 30; i++)
    {
      'date': DateFormat(
        'yyyy-MM-dd',
      ).format(DateTime.utc(2026, 5, 1).add(Duration(days: i))),
      'value_usd': 250000.0 - (29 - i) * 1000,
    },
];

Widget _perfHost({
  Locale? locale,
  List<dynamic>? history,
  NumberFormat? currencyFormat,
  double conversionFactor = 1.0,
  Map<String, dynamic>? twr,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: SingleChildScrollView(
      child: PerformanceCard(
        apiService: ApiService(),
        conversionFactor: conversionFactor,
        currencyFormat: currencyFormat ?? moneyFormat('USD'),
        historyFetchOverride: () async => history ?? _valueHistory(),
        comparisonFetchOverride: () async => null,
        twrFetchOverride: () async => twr ?? _twrFixture(),
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
      // "Portfolio value" caption, the headline is the portfolio VALUE on
      // that date (the owner's complaint about 3afa140 was that the money
      // vanished mid-drag and left three percentages), and the two pills
      // carry the returns AT that date.
      expect(find.text('May 1, 2026'), findsOneWidget);
      expect(find.text('Portfolio value'), findsNothing);
      expect(find.text(r'$250,000'), findsNothing);
      expect(find.text(r'$221,000'), findsOneWidget); // May 1's value_usd
      // ONLY the two pills read +0.0% — the headline is money, not a third
      // percentage.
      expect(find.text('+0.0%'), findsNWidgets(2));
      expect(find.text('+29.0%'), findsNothing);

      // Drag to the LAST sample: May 30 (day 29) → $250,000, +29.0% / +14.5%.
      await gesture.moveTo(_chartEdge(tester, right: true));
      await tester.pump();
      expect(find.text('May 30, 2026'), findsOneWidget);
      expect(find.text(r'$250,000'), findsOneWidget); // headline
      expect(find.text('+29.0%'), findsOneWidget); // "you" pill only
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
      // so the label has to carry the whole reading — money AND both
      // returns, with the money labelled so it can't be misheard as a third
      // percentage.
      expect(
        find.bySemanticsLabel(
          'Chart reading at May 1, 2026: Portfolio value \$221,000, '
          'Your portfolio +0.0%, S&P 500 +0.0%',
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
          RegExp(
            r'^Lectura de la gráfica en May 1, 2026: '
            r'Valor del portafolio \$221,000, Tu portafolio ',
          ),
        ),
        findsOneWidget,
      );

      await gesture.up();
      await tester.pump();
      semantics.dispose();
    });

    testWidgets('with NO resolvable portfolio value for the scrubbed date '
        'the headline falls back to the return — never a bogus amount', (
      tester,
    ) async {
      _useSurface(tester, const Size(700, 1000));
      // Empty history: the TWR chart still plots (its points are their own
      // series) but nothing can be looked up by date.
      await tester.pumpWidget(_perfHost(history: const <dynamic>[]));
      await tester.pumpAndSettle();

      // With no history the resting headline falls back to the TWR payload's
      // total_value_usd.
      expect(find.text(r'$250,000'), findsOneWidget);

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LineChart)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(_chartEdge(tester, right: false));
      await tester.pump();

      // Headline degrades to the return (the pre-fix behavior) rather than
      // rendering $0 or a value from the wrong date — and the caption SAYS
      // it's a return, so the swap out of the money slot isn't silent.
      expect(find.text('May 1, 2026 · Time-weighted return'), findsOneWidget);
      expect(
        find.text('May 1, 2026'),
        findsNothing,
        reason: 'a bare date caption would still read as "your money on May 1"',
      );
      expect(find.text('+0.0%'), findsNWidgets(3)); // headline + both pills
      expect(
        _texts(tester).where((t) => t.contains(r'$')),
        isEmpty,
        reason: 'no money may be fabricated when no value_usd resolves',
      );

      await gesture.up();
      await tester.pump();
      expect(find.text(r'$250,000'), findsOneWidget);
    });

    testWidgets('a date BEFORE the first history row also falls back to the '
        'return (no backwards carry-forward)', (tester) async {
      _useSurface(tester, const Size(700, 1000));
      // History starts a fortnight into the TWR window, so the left edge of
      // the chart (May 1) precedes every row: there is nothing to carry
      // forward FROM.
      await tester.pumpWidget(_perfHost(history: _valueHistory().sublist(15)));
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LineChart)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(_chartEdge(tester, right: false));
      await tester.pump();

      expect(find.text('May 1, 2026 · Time-weighted return'), findsOneWidget);
      expect(find.text('+0.0%'), findsNWidgets(3)); // headline is the return
      expect(
        _texts(tester).where((t) => t.contains(r'$')),
        isEmpty,
        reason: 'a money figure must never be extrapolated backwards',
      );

      await gesture.up();
      await tester.pump();
    });

    testWidgets('a scrubbed date with no exact row carries the nearest PRIOR '
        'value forward instead of interpolating', (tester) async {
      _useSurface(tester, const Size(700, 1000));
      // Only May 1 ($221,000) and May 30 ($250,000) exist. Every date in
      // between must read $221,000 — the carry-forward — not something
      // between the two.
      await tester.pumpWidget(
        _perfHost(history: [_valueHistory().first, _valueHistory().last]),
      );
      await tester.pumpAndSettle();

      final rect = tester.getRect(find.byType(LineChart));
      final gesture = await tester.startGesture(rect.center);
      await tester.pump(const Duration(milliseconds: 200));
      // Mid-chart: a TWR sample around the middle of May — no history row
      // there, so the May 1 row must carry forward.
      await gesture.moveTo(Offset(rect.center.dx + 2, rect.center.dy));
      await tester.pump();

      // Exactly one money string on screen, and it is the May 1 row carried
      // forward verbatim — not an interpolation towards May 30's $250,000.
      expect(_texts(tester).where((t) => t.contains(r'$')).toList(), [
        r'$221,000',
      ]);

      await gesture.up();
      await tester.pump();
    });

    testWidgets('the scrubbed money figure honors the card\'s currency and '
        'conversion factor (es-MX / MXN)', (tester) async {
      await syncIntlLocale(const Locale('es'));
      addTearDown(() async {
        localeNotifier.value = null;
        await syncIntlLocale(null);
      });
      _useSurface(tester, const Size(700, 1000));
      await tester.pumpWidget(
        _perfHost(
          locale: const Locale('es'),
          currencyFormat: moneyFormat('MXN'),
          conversionFactor: 20.0,
        ),
      );
      await tester.pumpAndSettle();

      // Resting headline: $250,000 USD → MXN 5,000,000 (the house glyph for
      // MXN is the ISO prefix, see utils/currency.dart).
      expect(_texts(tester), contains('MXN 5,000,000'));

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LineChart)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(_chartEdge(tester, right: false));
      await tester.pump();

      // May 1: $221,000 USD × 20 → MXN 4,420,000, in the SAME unit as the
      // resting headline (a scrub that skipped conversionFactor would read
      // MXN 221,000).
      expect(_texts(tester), contains('MXN 4,420,000'));
      expect(_texts(tester), isNot(contains('MXN 221,000')));

      await gesture.up();
      await tester.pump();
      expect(_texts(tester), contains('MXN 5,000,000'));
    });
  });

  // ── the scrub's money source spans the whole chart, not just the tail ──
  //
  // The first fix (7d0e9a2) sourced the scrubbed headline from
  // `/dashboard/portfolio-value-history`, which is backed by
  // `balance_snapshots` and so begins whenever the install started
  // snapshotting. On the owner's account that was 22 rows against a TWR chart
  // running back to 2019: on ALL / 5Y / 1Y / YTD the money fallback fired
  // across ~98% of the width and the headline showed a percentage that merely
  // repeated the "Your portfolio" pill — the exact thing the fix existed to
  // prevent, at the ranges they actually use.
  //
  // The endpoint now returns its own per-day valuation on every point, so
  // these tests pin: money everywhere the chart plots, money that beats a
  // stale/short snapshot series, and an honest fallback when the payload
  // can't legitimately be read as the whole portfolio.
  group('performance card — scrubbing money across the full chart span', () {
    // History covering ONLY the last three days of the 30-day window: the
    // shape of the production bug. Days 0–26 have no snapshot at all.
    List<dynamic> shortHistory() => _valueHistory().sublist(27);

    testWidgets('a date the snapshot history never covered still shows money, '
        'sourced from the TWR payload', (tester) async {
      _useSurface(tester, const Size(700, 1000));
      await tester.pumpWidget(
        _perfHost(
          history: shortHistory(),
          // Day i is worth 100,000 + 1,000·i → May 1 = $100,000.
          twr: _twrFixture(valueUsd: (i) => 100000.0 + i * 1000),
        ),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LineChart)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(_chartEdge(tester, right: false));
      await tester.pump();

      // May 1 predates every snapshot row, yet the headline is MONEY — and it
      // is the value the endpoint reported for that day.
      expect(find.text('May 1, 2026'), findsOneWidget);
      expect(find.text(r'$100,000'), findsOneWidget);
      expect(
        find.text('May 1, 2026 · Time-weighted return'),
        findsNothing,
        reason: 'the money branch must not carry the fallback caption',
      );
      // The two pills still carry the returns; the headline is not a third.
      expect(find.text('+0.0%'), findsNWidgets(2));

      await gesture.up();
      await tester.pump();
    });

    testWidgets('the money is a real valuation, not the return applied to '
        "today's total", (tester) async {
      _useSurface(tester, const Size(700, 1000));
      // twr on day 0 is 1.0 (a 0% return), so "total × growth" would print
      // the full $250,000 at May 1. The endpoint's valuation says $100,000 —
      // contributions raised the value without being performance. The
      // headline must be the valuation.
      await tester.pumpWidget(
        _perfHost(
          history: const <dynamic>[],
          twr: _twrFixture(valueUsd: (i) => 100000.0 + i * 1000),
        ),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LineChart)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(_chartEdge(tester, right: false));
      await tester.pump();

      expect(_texts(tester).where((t) => t.contains(r'$')).toList(), [
        r'$100,000',
      ]);

      await gesture.up();
      await tester.pump();
    });

    testWidgets('the whole drag stays money — no percentage sneaks into the '
        'headline anywhere across the span', (tester) async {
      _useSurface(tester, const Size(700, 1000));
      await tester.pumpWidget(
        _perfHost(
          history: shortHistory(),
          twr: _twrFixture(valueUsd: (i) => 100000.0 + i * 1000),
        ),
      );
      await tester.pumpAndSettle();

      final rect = tester.getRect(find.byType(LineChart));
      final gesture = await tester.startGesture(rect.center);
      await tester.pump(const Duration(milliseconds: 200));

      // Walk the full plot width. At every stop the headline must be money
      // (a currency string on screen) and never the return caption.
      for (var i = 0; i <= 20; i++) {
        final dx = rect.left + 2 + (rect.width - 4) * i / 20;
        await gesture.moveTo(Offset(dx, rect.center.dy));
        await tester.pump();
        expect(
          _texts(tester).where((t) => t.contains(r'$')),
          isNotEmpty,
          reason: 'no money at x-fraction ${i / 20}',
        );
        expect(
          _texts(tester).where((t) => t.contains('· Time-weighted return')),
          isEmpty,
          reason: 'unexpected fallback caption at x-fraction ${i / 20}',
        );
      }

      await gesture.up();
      await tester.pump();
    });

    testWidgets('a partially-priced portfolio does NOT pass its partial value '
        'off as the portfolio value', (tester) async {
      _useSurface(tester, const Size(700, 1000));
      // 60% coverage: `value_usd` is 60% of a portfolio. Showing it under the
      // "Portfolio value" caption would understate by 40%, so the card must
      // ignore it — and with no snapshot history either, fall back honestly.
      await tester.pumpWidget(
        _perfHost(
          history: const <dynamic>[],
          twr: _twrFixture(valueUsd: (i) => 100000.0 + i * 1000, coverage: 0.6),
        ),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LineChart)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(_chartEdge(tester, right: false));
      await tester.pump();

      expect(find.text('May 1, 2026 · Time-weighted return'), findsOneWidget);
      expect(
        _texts(tester).where((t) => t.contains(r'$')),
        isEmpty,
        reason: 'a 60%-covered valuation is not the portfolio value',
      );

      await gesture.up();
      await tester.pump();
    });

    testWidgets('below the coverage floor the observed snapshot balance is '
        'used instead of the partial valuation', (tester) async {
      _useSurface(tester, const Size(700, 1000));
      // Same 60% coverage, but now snapshots DO cover May 1 ($221,000). The
      // real observed balance is the better number and must win over both the
      // partial valuation ($100,000) and the return fallback.
      await tester.pumpWidget(
        _perfHost(
          twr: _twrFixture(valueUsd: (i) => 100000.0 + i * 1000, coverage: 0.6),
        ),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LineChart)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(_chartEdge(tester, right: false));
      await tester.pump();

      expect(_texts(tester).where((t) => t.contains(r'$')).toList(), [
        r'$221,000',
      ]);

      await gesture.up();
      await tester.pump();
    });

    testWidgets('the fallback caption is localized (es-MX)', (tester) async {
      _useSurface(tester, const Size(700, 1000));
      await tester.pumpWidget(
        _perfHost(locale: const Locale('es'), history: const <dynamic>[]),
      );
      await tester.pumpAndSettle();

      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(LineChart)),
      );
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(_chartEdge(tester, right: false));
      await tester.pump();

      expect(
        find.text('May 1, 2026 · Rendimiento ponderado por tiempo'),
        findsOneWidget,
      );

      await gesture.up();
      await tester.pump();
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
