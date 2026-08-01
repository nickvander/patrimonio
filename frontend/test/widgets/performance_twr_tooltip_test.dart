import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/performance_card.dart';

// Prod bug (mobile web): tapping the performance card's TWR chart showed the
// tooltip and it stayed PINNED after the finger lifted — fl_chart's built-in
// touch handling keeps FlTapUpEvent "interested" on web, and a touch pointer
// never emits the FlPointerExitEvent that would clear it. The chart now goes
// through TransientTooltipLineChart (chart_touch.dart), which owns the
// touched-spot state, so the dismissal is observable through the
// LineChartData handed to fl_chart: showingTooltipIndicators + the per-bar
// showingIndicators are non-empty exactly while a spot is scrubbed.
// (Same observation seam as projection_chart_tooltip_test.dart.)

/// A month of TWR points (fixed past dates — DateRange.all applies no
/// now()-relative cutoff), full coverage, so `_hasTwr` selects the TWR chart
/// and it is the card's ONLY LineChart (history empty, comparison null).
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

Widget _host() => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: SingleChildScrollView(
      child: PerformanceCard(
        apiService: ApiService(),
        conversionFactor: 1.0,
        currencyFormat: NumberFormat.currency(symbol: r'$'),
        historyFetchOverride: () async => <dynamic>[],
        comparisonFetchOverride: () async => null,
        twrFetchOverride: () async => _twrFixture(),
      ),
    ),
  ),
);

LineChartData _chartData(WidgetTester tester) =>
    tester.widget<LineChart>(find.byType(LineChart)).data;

bool _tooltipShowing(WidgetTester tester) {
  final data = _chartData(tester);
  return data.showingTooltipIndicators.isNotEmpty &&
      data.lineBarsData.any((bar) => bar.showingIndicators.isNotEmpty);
}

void _useSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

Future<void> _pumpCard(WidgetTester tester) async {
  _useSurface(tester, const Size(1440, 900));
  await tester.pumpWidget(_host());
  await tester.pumpAndSettle();
  expect(find.byType(LineChart), findsOneWidget);
}

void main() {
  testWidgets('TWR chart: hover shows the tooltip, pointer-exit clears it, '
      're-hover brings it back', (tester) async {
    await _pumpCard(tester);
    expect(_tooltipShowing(tester), isFalse);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();

    final center = tester.getCenter(find.byType(LineChart));
    await gesture.moveTo(center);
    await tester.pump();
    expect(
      _tooltipShowing(tester),
      isTrue,
      reason: 'hovering inside the plot must surface a tooltip spot',
    );

    await gesture.moveTo(const Offset(5, 5));
    await tester.pump();
    expect(
      _tooltipShowing(tester),
      isFalse,
      reason: 'pointer-exit must dismiss the tooltip',
    );

    await gesture.moveTo(center);
    await tester.pump();
    expect(
      _tooltipShowing(tester),
      isTrue,
      reason: 'the tooltip must come back on the next hover',
    );
  });

  testWidgets(
    'TWR chart: the tooltip shows while a finger is down and is DISMISSED '
    'when it lifts — even on the web/desktop-like platform where fl_chart '
    'keeps tap-up "interested" (the prod pinned-tooltip bug)',
    (tester) async {
      // macOS stands in for the isDesktopOrWeb branch of fl_chart's
      // isInterestedForInteractions — the same carve-out kIsWeb (mobile web
      // in prod) hits, which is what pinned the tooltip. Reset at the end of
      // the body: the binding's invariant check runs before addTearDown would.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

      await _pumpCard(tester);
      expect(_tooltipShowing(tester), isFalse);

      final center = tester.getCenter(find.byType(LineChart));
      final gesture = await tester.startGesture(center); // touch pointer
      // Past the tap deadline so the press has registered (pan-down fires
      // immediately; tap-down at ~100ms).
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        _tooltipShowing(tester),
        isTrue,
        reason: 'the tooltip must be visible while the finger is down',
      );

      await gesture.up();
      await tester.pump();
      expect(
        _tooltipShowing(tester),
        isFalse,
        reason: 'finger lift must dismiss the tooltip, not leave it pinned',
      );
      // The pinned-tooltip regression specifically: it stays cleared on later
      // frames, not just the release frame.
      await tester.pump(const Duration(milliseconds: 300));
      expect(_tooltipShowing(tester), isFalse);

      debugDefaultTargetPlatformOverride = null;
    },
  );
}
