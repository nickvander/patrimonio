import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/components/trends_chart.dart';
import 'package:patrimonio/l10n/app_localizations.dart';

// Bar-chart counterpart of performance_twr_tooltip_test.dart: the cash-flow
// trends BarChart's built-in tooltip pinned after a finger lifted on mobile
// web (FlTapUpEvent stays "interested" there and touch pointers emit no exit
// event). The chart now goes through TransientTooltipBarChart
// (chart_touch.dart), which owns the touched-bar state — observable through
// the touched group's showingTooltipIndicators — and chains the chart's own
// tap-to-filter touchCallback, which must keep firing.

Widget _host({ValueChanged<String>? onMonthSelected}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: SingleChildScrollView(
      child: CashFlowTrendsChart(
        // A single month: with BarChartAlignment.spaceEvenly the one
        // group sits at the plot's horizontal center, so the income rod
        // (width 22, first of the pair) is centered ~12px left of it —
        // geometry the touch tests derive positions from.
        trends: const [
          {'month': '2026-05', 'income': 3000.0, 'spending': 2000.0},
        ],
        conversionFactor: 1.0,
        currencyFormat: NumberFormat.currency(symbol: r'$'),
        onMonthSelected: onMonthSelected,
      ),
    ),
  ),
);

BarChartData _chartData(WidgetTester tester) =>
    tester.widget<BarChart>(find.byType(BarChart)).data;

bool _tooltipShowing(WidgetTester tester) => _chartData(
  tester,
).barGroups.any((g) => g.showingTooltipIndicators.isNotEmpty);

/// A point inside the income rod: the plot area excludes the left axis strip
/// (reservedSize) and the bottom label strip, the single group is centered in
/// what remains, and the income bar (83% of plot height — maxY is max·1.2)
/// comfortably covers a point 30px above the plot floor.
Offset _insideIncomeBar(WidgetTester tester) {
  final rect = tester.getRect(find.byType(BarChart));
  final titles = _chartData(tester).titlesData;
  final left = rect.left + titles.leftTitles.sideTitles.reservedSize;
  final bottom = rect.bottom - titles.bottomTitles.sideTitles.reservedSize;
  final plotCenterX = (left + rect.right) / 2;
  return Offset(plotCenterX - 12, bottom - 30);
}

void _useSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets(
    'trends bars: tooltip shows while the finger is down and is DISMISSED '
    'on lift — even on the web/desktop-like platform where fl_chart keeps '
    'tap-up "interested" (the pinned-tooltip bug)',
    (tester) async {
      // macOS stands in for the isDesktopOrWeb branch of fl_chart's
      // isInterestedForInteractions — the same carve-out mobile web hits.
      // Reset at the end of the body: the binding's invariant check runs
      // before addTearDown would.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

      _useSurface(tester, const Size(1000, 900));
      await tester.pumpWidget(_host());
      await tester.pumpAndSettle();
      expect(find.byType(BarChart), findsOneWidget);
      expect(_tooltipShowing(tester), isFalse);

      final gesture = await tester.startGesture(_insideIncomeBar(tester));
      await tester.pump(const Duration(milliseconds: 200));
      expect(
        _tooltipShowing(tester),
        isTrue,
        reason: 'pressing a bar must surface its tooltip',
      );

      await gesture.up();
      await tester.pump();
      expect(
        _tooltipShowing(tester),
        isFalse,
        reason: 'finger lift must dismiss the tooltip, not leave it pinned',
      );
      await tester.pump(const Duration(milliseconds: 300));
      expect(_tooltipShowing(tester), isFalse);

      debugDefaultTargetPlatformOverride = null;
    },
  );

  testWidgets(
    'the chained touchCallback still fires: tapping a bar emits its month '
    'to onMonthSelected and the tooltip is not left pinned',
    (tester) async {
      String? selected;
      _useSurface(tester, const Size(1000, 900));
      await tester.pumpWidget(_host(onMonthSelected: (m) => selected = m));
      await tester.pumpAndSettle();

      await tester.tapAt(_insideIncomeBar(tester));
      await tester.pumpAndSettle();

      expect(
        selected,
        '2026-05',
        reason:
            'TransientTooltipBarChart must chain the tap-to-filter '
            'callback, not swallow it',
      );
      expect(_tooltipShowing(tester), isFalse);
    },
  );
}
