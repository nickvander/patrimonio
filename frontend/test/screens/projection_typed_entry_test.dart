import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/screens/wealth_projection_screen.dart';

import 'projection_test_host.dart';

// U2: tapping a money slider's value label opens a numeric-entry dialog
// (same StatefulWidget pattern as the goal dialog). A typed value that
// exceeds the slider's drag range grows the max to accommodate it, the
// annual-expenses floor is now $4,000, and commits route through the same
// debounced persist+refetch path as a slider drag. The hydration clamps
// accept the widened range so persisted typed values round-trip.

WealthProjectionFetcher _countingFetcher(List<int> counter) {
  return ({
    required double startBalance,
    required double monthlyContribution,
    required double annualReturnRate,
    required double annualExpenses,
    required double withdrawalRate,
    int years = 30,
    double annualInflationRate = 0.03,
    double returnVolatility = 0.13,
    int? yearsToRetirement,
    int monteCarloTrials = 1000,
    double baristaMonthlyIncome = 0.0,
    double annualTaxDrag = 0.0,
    bool withdrawalGuardrails = false,
  }) async {
    counter.add(1);
    return projectionFixture(years: years);
  };
}

/// The Slider widget belonging to the control labelled [label].
Slider _sliderFor(WidgetTester tester, String label) {
  final finder = find.descendant(
    of: find
        .ancestor(of: find.text(label), matching: find.byType(MergeSemantics))
        .first,
    matching: find.byType(Slider),
  );
  return tester.widget<Slider>(finder);
}

Future<void> _tapValueLabel(WidgetTester tester, String value) async {
  final label = find.text(value);
  await tester.ensureVisible(label.first);
  await tester.pumpAndSettle();
  await tester.tap(label.first);
  await tester.pumpAndSettle();
  expect(find.byType(AlertDialog), findsOneWidget);
}

Future<void> _typeAndSave(WidgetTester tester, String value) async {
  final field = find.descendant(
      of: find.byType(AlertDialog), matching: find.byType(TextField));
  await tester.enterText(field, value);
  await tester.tap(find.widgetWithText(FilledButton, 'Save'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('typing 12500 into Monthly savings commits it, grows the '
      'slider max and refetches exactly once', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    final fetches = <int>[];
    final writes = <String, dynamic>{};
    await tester.pumpWidget(buildProjectionHost(
      projectionFetcher: _countingFetcher(fetches),
      settingWriter: (key, value) async => writes[key] = value,
    ));
    await tester.pumpAndSettle();
    expect(fetches.length, 1); // initial load

    await _tapValueLabel(tester, r'$1,000'); // default contribution
    await _typeAndSave(tester, '12500');

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(r'$12,500'), findsOneWidget);
    expect(_sliderFor(tester, 'Monthly savings').max,
        greaterThanOrEqualTo(12500.0));

    // F14 path: one debounced persist + refetch.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(fetches.length, 2);
    final blob = writes['projection_assumptions'] as Map<String, dynamic>?;
    expect(blob, isNotNull);
    expect(blob!['monthly_contribution'], 12500.0);
  });

  testWidgets('invalid input (negative, garbage) shows the inline error and '
      'does not commit', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    final fetches = <int>[];
    await tester.pumpWidget(
        buildProjectionHost(projectionFetcher: _countingFetcher(fetches)));
    await tester.pumpAndSettle();

    await _tapValueLabel(tester, r'$1,000');

    const error = r'Enter an amount between $0 and $1,000,000,000';
    await _typeAndSave(tester, '-50');
    expect(find.byType(AlertDialog), findsOneWidget); // still open
    expect(find.text(error), findsOneWidget);

    await _typeAndSave(tester, 'garbage');
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(find.text(error), findsOneWidget);

    // Cancel: nothing committed, no refetch.
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text(r'$1,000'), findsOneWidget); // unchanged
    expect(fetches.length, 1); // just the initial load
  });

  testWidgets(r'annual expenses accepts a typed 4500 (new $4,000 floor) and '
      'rejects a value below the floor', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    final writes = <String, dynamic>{};
    await tester.pumpWidget(buildProjectionHost(
      settingWriter: (key, value) async => writes[key] = value,
    ));
    await tester.pumpAndSettle();

    // Below the floor first: inline error, no commit.
    await _tapValueLabel(tester, r'$40,000'); // default expenses
    await _typeAndSave(tester, '3000');
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.text(r'Enter an amount between $4,000 and $1,000,000,000'),
      findsOneWidget,
    );

    await _typeAndSave(tester, '4500');
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(r'$4,500'), findsOneWidget);
    expect(_sliderFor(tester, 'Annual expenses').min, 4000.0);

    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    final blob = writes['projection_assumptions'] as Map<String, dynamic>?;
    expect(blob!['annual_expenses'], 4500.0);
  });

  testWidgets('a hydrated blob with monthly_contribution 12500 restores '
      '12500 — not clamped to the old 10000 slider max', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost(
      settingReader: (key) async => key == 'projection_assumptions'
          ? {'monthly_contribution': 12500.0}
          : null,
    ));
    await tester.pumpAndSettle();

    expect(find.text(r'$12,500'), findsOneWidget);
    expect(find.text(r'$10,000'), findsNothing);
    expect(_sliderFor(tester, 'Monthly savings').max,
        greaterThanOrEqualTo(12500.0));
  });
}
