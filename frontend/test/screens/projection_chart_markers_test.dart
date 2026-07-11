import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'projection_test_host.dart';

// U1: the headline chart carries structural markers — a dashed vertical line
// at the retirement year (the accumulation→drawdown kink, labelled) and, when
// a goal is set, a dashed vertical at the goal year plus the horizontal goal
// line in a colour clearly distinct from the amber FIRE target. A goal above
// the y-range must NOT rescale the axis (that flattened the chart): it clamps
// to the top edge as a labelled line while the year marker still shows.

LineChartData _chartData(WidgetTester tester) =>
    tester.widget<LineChart>(find.byType(LineChart)).data;

Future<void> _setGoal(WidgetTester tester, String amount, String year) async {
  final openButton = find.textContaining('Set a target');
  await tester.ensureVisible(openButton.first);
  await tester.pumpAndSettle();
  await tester.tap(openButton.first);
  await tester.pumpAndSettle();
  final fields = find.descendant(
      of: find.byType(AlertDialog), matching: find.byType(TextField));
  await tester.enterText(fields.at(0), amount);
  await tester.enterText(fields.at(1), year);
  await tester.tap(find.widgetWithText(FilledButton, 'Save'));
  await tester.pumpAndSettle();
}

void main() {
  final nowYear = DateTime.now().year;

  testWidgets('retirement marker sits at the configured year, labelled, and '
      'is bilingual', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost());
    await tester.pumpAndSettle();

    // Default years-to-retirement is 20.
    final verticals = _chartData(tester).extraLinesData.verticalLines;
    final retire = verticals.where((v) => v.x == 20.0);
    expect(retire, hasLength(1),
        reason: 'expected one vertical marker at x=20 (retirement)');
    expect(retire.single.dashArray, isNotNull); // dashed, not solid
    expect(retire.single.label.show, isTrue);
    expect(retire.single.label.labelResolver(retire.single), 'Retirement');

    // es-MX: the marker label localizes.
    await tester.pumpWidget(buildProjectionHost(locale: const Locale('es')));
    await tester.pumpAndSettle();
    final esVerticals = _chartData(tester).extraLinesData.verticalLines;
    final esRetire = esVerticals.where((v) => v.x == 20.0).single;
    expect(esRetire.label.labelResolver(esRetire), 'Retiro');
  });

  testWidgets('a set goal adds a vertical marker at the goal year and the '
      'goal line colour differs from the FIRE target', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost());
    await tester.pumpAndSettle();

    await _setGoal(tester, '800000', '${nowYear + 10}');

    final data = _chartData(tester);
    // Vertical goal marker at x = goalYear - nowYear = 10 (plus the
    // retirement marker at 20).
    final xs = data.extraLinesData.verticalLines.map((v) => v.x);
    expect(xs, contains(10.0));

    // The dashed goal bar ([3,6]) and the dashed FIRE-target bar ([5,5])
    // exist and use clearly different colours.
    final goalBar = data.lineBarsData
        .singleWhere((b) => b.dashArray?.join(',') == '3,6');
    final targetBar = data.lineBarsData
        .singleWhere((b) => b.dashArray?.join(',') == '5,5');
    expect(goalBar.color, isNotNull);
    expect(goalBar.color, isNot(equals(targetBar.color)));
    // The horizontal goal amount line is at $800k across the horizon.
    expect(goalBar.spots.every((s) => s.y == 800000.0), isTrue);
  });

  testWidgets('an out-of-range goal does not rescale the axis: maxY is '
      'unchanged, the goal clamps to the top edge with a label, and the year '
      'marker still shows', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost());
    await tester.pumpAndSettle();

    final maxYWithoutGoal = _chartData(tester).maxY;
    expect(maxYWithoutGoal, isNotNull);
    // Fixture sanity: p90 tops out at 600k + 30*70k = $2.7M.
    expect(maxYWithoutGoal, 2700000.0);

    // A $500M goal — far above the plot.
    await _setGoal(tester, '500000000', '${nowYear + 5}');

    final data = _chartData(tester);
    // The axis did NOT stretch to the goal.
    expect(data.maxY, maxYWithoutGoal);
    // No goal bar participates in the plot (it would sit above the range) …
    expect(data.lineBarsData.where((b) => b.dashArray?.join(',') == '3,6'),
        isEmpty);
    // … instead a labelled dashed line clamps to the top edge …
    final horizontals = data.extraLinesData.horizontalLines;
    expect(horizontals, hasLength(1));
    expect(horizontals.single.y, maxYWithoutGoal);
    expect(horizontals.single.label.show, isTrue);
    expect(horizontals.single.label.labelResolver(horizontals.single),
        contains('Your goal'));
    // … and the vertical goal-year marker still shows.
    expect(data.extraLinesData.verticalLines.map((v) => v.x), contains(5.0));
  });
}
