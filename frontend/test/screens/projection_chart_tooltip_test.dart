import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'projection_test_host.dart';

// U6: the chart's hover tooltip used to stay pinned after the pointer left
// the chart area (fl_chart's built-in handleBuiltInTouches state never
// cleared live). The screen now owns the touch state and clears it on
// pointer-exit, which is observable through the LineChartData the screen
// hands to fl_chart: showingTooltipIndicators + the per-bar
// showingIndicators are non-empty exactly while a spot is hovered.

LineChartData _chartData(WidgetTester tester) =>
    tester.widget<LineChart>(find.byType(LineChart)).data;

bool _tooltipShowing(WidgetTester tester) {
  final data = _chartData(tester);
  return data.showingTooltipIndicators.isNotEmpty &&
      data.lineBarsData.any((bar) => bar.showingIndicators.isNotEmpty);
}

Future<TestGesture> _mouse(WidgetTester tester) async {
  final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
  await gesture.addPointer(location: Offset.zero);
  addTearDown(gesture.removePointer);
  await tester.pump();
  return gesture;
}

void main() {
  testWidgets('hovering the chart shows the tooltip state; moving the '
      'pointer out of the chart clears it', (tester) async {
    setTestSize(tester, const Size(1400, 1000));
    await tester.pumpWidget(buildProjectionHost());
    await tester.pumpAndSettle();

    expect(find.byType(LineChart), findsOneWidget);
    expect(_tooltipShowing(tester), isFalse); // nothing hovered yet

    final gesture = await _mouse(tester);
    await gesture.moveTo(tester.getCenter(find.byType(LineChart)));
    await tester.pump();
    expect(
      _tooltipShowing(tester),
      isTrue,
      reason: 'hovering inside the plot must surface a tooltip spot',
    );

    // Leave the chart entirely (the screen header, far from the plot).
    await gesture.moveTo(const Offset(10, 10));
    await tester.pump();
    expect(
      _tooltipShowing(tester),
      isFalse,
      reason: 'pointer-exit must dismiss the tooltip, not leave it pinned',
    );
    // And the pinned-tooltip regression specifically: it stays cleared on
    // later frames, not just the exit frame.
    await tester.pump(const Duration(milliseconds: 300));
    expect(_tooltipShowing(tester), isFalse);
  });

  testWidgets('the tooltip comes back on the next hover after an exit', (
    tester,
  ) async {
    setTestSize(tester, const Size(1400, 1000));
    await tester.pumpWidget(buildProjectionHost());
    await tester.pumpAndSettle();

    final gesture = await _mouse(tester);
    final center = tester.getCenter(find.byType(LineChart));
    await gesture.moveTo(center);
    await tester.pump();
    expect(_tooltipShowing(tester), isTrue);

    await gesture.moveTo(const Offset(10, 10));
    await tester.pump();
    expect(_tooltipShowing(tester), isFalse);

    await gesture.moveTo(center);
    await tester.pump();
    expect(_tooltipShowing(tester), isTrue);
  });
}
