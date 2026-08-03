import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/utils/chart_touch.dart';

// The shared half of the "don't put the tooltip under the finger" fix.
// Pinning the tooltip to the top of the chart box (chart_touch_pinning_test)
// is not enough for a SHORT chart — the performance card's plot is 120px on
// phones and a 3-line tooltip is ~64 of them, so it still lands under the
// hand. TransientTooltipLineChart therefore also offers the Robinhood /
// Copilot scrub: `suppressTooltipOnTouch` draws no in-chart tooltip for
// touch/stylus, and `onScrub` hands the reading to the host so it can render
// it in its header. Mouse/trackpad must be byte-identical to before.

class _Probe {
  final List<ChartScrub?> events = [];
  void call(ChartScrub? scrub) => events.add(scrub);
}

Widget _host({required _Probe probe, required bool suppressTooltipOnTouch}) =>
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 300,
            child: Builder(
              builder: (context) => TransientTooltipLineChart(
                suppressTooltipOnTouch: suppressTooltipOnTouch,
                onScrub: probe.call,
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

bool _tooltipShowing(WidgetTester tester) =>
    _chartData(tester).showingTooltipIndicators.isNotEmpty;

bool _indicatorShowing(WidgetTester tester) =>
    _chartData(tester).lineBarsData.any((b) => b.showingIndicators.isNotEmpty);

void main() {
  testWidgets('suppressTooltipOnTouch: a finger gets the guide + dot but no '
      'tooltip, and onScrub publishes the reading instead', (tester) async {
    // Desktop seed, so anything observed below is driven by the real touch
    // events rather than the platform guess.
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final probe = _Probe();
    await tester.pumpWidget(_host(probe: probe, suppressTooltipOnTouch: true));
    await tester.pump();

    final center = tester.getCenter(find.byType(LineChart));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 200));

    expect(_indicatorShowing(tester), isTrue, reason: 'guide + dot remain');
    expect(
      _tooltipShowing(tester),
      isFalse,
      reason: 'no tooltip under a finger',
    );
    expect(probe.events.last?.isTouch, isTrue);
    expect(probe.events.last?.spots, isNotEmpty);

    // Release publishes null in the same frame — a host can't keep a stale
    // reading after the finger lifts.
    await gesture.up();
    await tester.pump();
    expect(probe.events.last, isNull);
    expect(_indicatorShowing(tester), isFalse);

    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('suppressTooltipOnTouch leaves MOUSE hover untouched: the '
      'near-spot popover still renders, and the scrub is flagged non-touch', (
    tester,
  ) async {
    final probe = _Probe();
    await tester.pumpWidget(_host(probe: probe, suppressTooltipOnTouch: true));
    await tester.pump();

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await tester.pump();
    await mouse.moveTo(tester.getCenter(find.byType(LineChart)));
    await tester.pump();

    expect(_tooltipShowing(tester), isTrue);
    expect(_indicatorShowing(tester), isTrue);
    expect(
      probe.events.last?.isTouch,
      isFalse,
      reason: 'hosts key off this to leave their header on the live values',
    );
  });

  testWidgets('without suppressTooltipOnTouch a touch scrub still renders the '
      'tooltip (pinned to the top of the box) — the default is unchanged', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final probe = _Probe();
    await tester.pumpWidget(_host(probe: probe, suppressTooltipOnTouch: false));
    await tester.pump();

    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(LineChart)),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(_tooltipShowing(tester), isTrue);
    expect(
      _chartData(
        tester,
      ).lineTouchData.touchTooltipData.showOnTopOfTheChartBoxArea,
      isTrue,
    );

    await gesture.up();
    await tester.pump();
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('onScrub is deduplicated: holding still on one spot notifies '
      'once, and the end-of-scrub null is published once', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final probe = _Probe();
    await tester.pumpWidget(_host(probe: probe, suppressTooltipOnTouch: true));
    await tester.pump();

    final center = tester.getCenter(find.byType(LineChart));
    final gesture = await tester.startGesture(center);
    await tester.pump(const Duration(milliseconds: 200));
    final afterPress = probe.events.length;
    // Sub-pixel wiggles that stay on the same sample must not re-notify —
    // a host rebuild per pointer event is what the ValueNotifier avoids.
    await gesture.moveBy(const Offset(1, 0));
    await tester.pump();
    await gesture.moveBy(const Offset(0, 1));
    await tester.pump();
    expect(probe.events.length, afterPress);

    await gesture.up();
    await tester.pump();
    expect(probe.events.last, isNull);
    final afterRelease = probe.events.length;
    await tester.pump(const Duration(milliseconds: 300));
    expect(
      probe.events.length,
      afterRelease,
      reason: 'the cleared state must not keep re-notifying',
    );

    debugDefaultTargetPlatformOverride = null;
  });
}
