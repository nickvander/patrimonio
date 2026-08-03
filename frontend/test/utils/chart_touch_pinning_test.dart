import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/utils/chart_touch.dart';

// Touch-interaction fix (owner repro: Portfolio TWR chart on a phone): the
// scrub tooltip rendered at the touched spot — directly under the finger.
// TransientTooltipLineChart now tracks the active pointer's kind and, for
// touch/stylus, re-applies the tooltip with fl_chart's
// `showOnTopOfTheChartBoxArea: true` so the readout sits pinned at the top
// of the chart box, clear of the finger. Mouse/trackpad keep the near-spot
// popover exactly as before. Observable through the LineChartData handed to
// fl_chart (same seam as performance_twr_tooltip_test.dart).

Widget _host() => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 400,
        height: 300,
        child: Builder(
          builder: (context) => TransientTooltipLineChart(
            data: LineChartData(
              minX: 0,
              maxX: 10,
              minY: 0,
              maxY: 10,
              titlesData: const FlTitlesData(show: false),
              lineBarsData: [
                LineChartBarData(
                  spots: [
                    for (var i = 0; i <= 10; i++)
                      FlSpot(i.toDouble(), i.toDouble()),
                  ],
                ),
              ],
              lineTouchData: standardLineTouch(
                context,
                items: (ctx, touched) => [
                  for (final s in touched)
                    LineTooltipItem('${s.y}', const TextStyle()),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

LineChartData _chartData(WidgetTester tester) =>
    tester.widget<LineChart>(find.byType(LineChart)).data;

bool _pinnedToTop(WidgetTester tester) => _chartData(
  tester,
).lineTouchData.touchTooltipData.showOnTopOfTheChartBoxArea;

bool _tooltipShowing(WidgetTester tester) {
  final data = _chartData(tester);
  return data.showingTooltipIndicators.isNotEmpty &&
      data.lineBarsData.any((bar) => bar.showingIndicators.isNotEmpty);
}

Future<void> _pumpChart(WidgetTester tester) async {
  await tester.pumpWidget(_host());
  await tester.pump();
  expect(find.byType(LineChart), findsOneWidget);
}

void main() {
  testWidgets('touch scrub pins the tooltip to the top of the chart box '
      '(showOnTopOfTheChartBoxArea) — never under the finger', (tester) async {
    // Desktop platform so the platform seed is the hover popover — the
    // pin observed below is then provably driven by the touch events,
    // not the seed. (Reset inline: the binding's invariant check runs
    // before addTearDown would.)
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;

    await _pumpChart(tester);
    expect(_pinnedToTop(tester), isFalse, reason: 'desktop seed: popover');

    final center = tester.getCenter(find.byType(LineChart));
    final gesture = await tester.startGesture(center); // touch pointer
    // Past the tap deadline so the kind-carrying FlTapDownEvent fired
    // (the initial FlPanDownEvent carries no pointer kind).
    await tester.pump(const Duration(milliseconds: 200));
    expect(_tooltipShowing(tester), isTrue);
    expect(
      _pinnedToTop(tester),
      isTrue,
      reason: 'a touch scrub must pin the tooltip to the top of the box',
    );

    // Still pinned while the finger drags across the plot.
    await gesture.moveBy(const Offset(60, 0));
    await tester.pump();
    expect(_tooltipShowing(tester), isTrue);
    expect(_pinnedToTop(tester), isTrue);

    await gesture.up();
    await tester.pump();
    expect(
      _tooltipShowing(tester),
      isFalse,
      reason: 'finger lift still dismisses the transient tooltip',
    );

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('mouse hover keeps the near-spot popover (no top pinning)', (
    tester,
  ) async {
    await _pumpChart(tester);

    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await gesture.addPointer(location: Offset.zero);
    addTearDown(gesture.removePointer);
    await tester.pump();

    await gesture.moveTo(tester.getCenter(find.byType(LineChart)));
    await tester.pump();
    expect(_tooltipShowing(tester), isTrue);
    expect(
      _pinnedToTop(tester),
      isFalse,
      reason: 'mouse hover must keep the near-spot popover exactly as today',
    );
  });

  testWidgets(
    'pointer-kind switch mid-session flips the placement: touch after '
    'mouse pins, mouse after touch un-pins',
    (tester) async {
      await _pumpChart(tester);
      final center = tester.getCenter(find.byType(LineChart));

      // 1. Mouse hover → popover.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await tester.pump();
      await mouse.moveTo(center);
      await tester.pump();
      expect(_tooltipShowing(tester), isTrue);
      expect(_pinnedToTop(tester), isFalse);
      await mouse.moveTo(Offset.zero);
      await tester.pump();
      await mouse.removePointer();
      await tester.pump();

      // 2. Touch scrub on the same chart → pinned to the top.
      final touch = await tester.startGesture(center);
      await tester.pump(const Duration(milliseconds: 200));
      expect(_tooltipShowing(tester), isTrue);
      expect(_pinnedToTop(tester), isTrue);
      await touch.up();
      await tester.pump();

      // 3. Back to the mouse → popover again.
      final mouse2 = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse2.addPointer(location: Offset.zero);
      addTearDown(mouse2.removePointer);
      await tester.pump();
      await mouse2.moveTo(center);
      await tester.pump();
      expect(_tooltipShowing(tester), isTrue);
      expect(_pinnedToTop(tester), isFalse);
    },
  );

  group('lineTooltipPinnedToTop', () {
    test('flips only the pin flag and carries every other field over', () {
      List<LineTooltipItem?> items(List<LineBarSpot> spots) => const [];
      Color color(LineBarSpot spot) => const Color(0xFF123456);
      final base = LineTouchTooltipData(
        tooltipRoundedRadius: 12,
        tooltipPadding: const EdgeInsets.all(7),
        tooltipMargin: 21,
        tooltipHorizontalAlignment: FLHorizontalAlignment.right,
        tooltipHorizontalOffset: 3,
        maxContentWidth: 222,
        getTooltipItems: items,
        getTooltipColor: color,
        fitInsideHorizontally: true,
        fitInsideVertically: true,
        rotateAngle: 1.5,
        tooltipBorder: const BorderSide(width: 2),
      );

      final pinned = lineTooltipPinnedToTop(base, pinned: true);
      expect(pinned.showOnTopOfTheChartBoxArea, isTrue);
      expect(pinned.tooltipRoundedRadius, base.tooltipRoundedRadius);
      expect(pinned.tooltipPadding, base.tooltipPadding);
      expect(pinned.tooltipMargin, base.tooltipMargin);
      expect(
        pinned.tooltipHorizontalAlignment,
        base.tooltipHorizontalAlignment,
      );
      expect(pinned.tooltipHorizontalOffset, base.tooltipHorizontalOffset);
      expect(pinned.maxContentWidth, base.maxContentWidth);
      expect(pinned.getTooltipItems, same(items));
      expect(pinned.getTooltipColor, same(color));
      expect(pinned.fitInsideHorizontally, base.fitInsideHorizontally);
      expect(pinned.fitInsideVertically, base.fitInsideVertically);
      expect(pinned.rotateAngle, base.rotateAngle);
      expect(pinned.tooltipBorder, base.tooltipBorder);
    });

    test('is the identity when the flag already matches', () {
      const base = LineTouchTooltipData();
      expect(lineTooltipPinnedToTop(base, pinned: false), same(base));
      const atTop = LineTouchTooltipData(showOnTopOfTheChartBoxArea: true);
      expect(lineTooltipPinnedToTop(atTop, pinned: true), same(atTop));
    });
  });

  group('chartEventPointerKind', () {
    test('reads the kind from kind-carrying events', () {
      expect(
        chartEventPointerKind(
          FlTapDownEvent(TapDownDetails(kind: PointerDeviceKind.touch)),
        ),
        PointerDeviceKind.touch,
      );
      expect(
        chartEventPointerKind(
          FlTapUpEvent(TapUpDetails(kind: PointerDeviceKind.stylus)),
        ),
        PointerDeviceKind.stylus,
      );
      expect(
        chartEventPointerKind(
          FlPanStartEvent(DragStartDetails(kind: PointerDeviceKind.mouse)),
        ),
        PointerDeviceKind.mouse,
      );
      expect(
        chartEventPointerKind(
          const FlPointerHoverEvent(
            PointerHoverEvent(kind: PointerDeviceKind.trackpad),
          ),
        ),
        PointerDeviceKind.trackpad,
      );
    });

    test('returns null for kind-less events (caller keeps the last kind)', () {
      expect(chartEventPointerKind(FlPanDownEvent(DragDownDetails())), isNull);
      expect(chartEventPointerKind(const FlPanCancelEvent()), isNull);
      expect(chartEventPointerKind(FlPanEndEvent(DragEndDetails())), isNull);
    });

    test('touch and stylus pin; mouse and trackpad do not', () {
      expect(chartTooltipPinsToTop(PointerDeviceKind.touch), isTrue);
      expect(chartTooltipPinsToTop(PointerDeviceKind.stylus), isTrue);
      expect(chartTooltipPinsToTop(PointerDeviceKind.mouse), isFalse);
      expect(chartTooltipPinsToTop(PointerDeviceKind.trackpad), isFalse);
    });
  });
}
