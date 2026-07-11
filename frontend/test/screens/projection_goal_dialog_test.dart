import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'projection_test_host.dart';

// F5: the goal dialog used to accept anything ($999,999,999,999 by 2020) and
// both putSetting call sites swallowed failures with catchError((_){}) — the
// goal looked saved but evaporated on refresh. Now: inline validation blocks
// the save, and a failed write surfaces a snackbar.

void main() {
  final nowYear = DateTime.now().year;

  Future<void> openGoalDialog(WidgetTester tester) async {
    final openButton = find.textContaining('Set a target');
    await tester.ensureVisible(openButton.first);
    await tester.pumpAndSettle();
    await tester.tap(openButton.first);
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
  }

  Future<void> enterGoal(
      WidgetTester tester, String amount, String year) async {
    final fields = find.descendant(
        of: find.byType(AlertDialog), matching: find.byType(TextField));
    expect(fields, findsNWidgets(2));
    await tester.enterText(fields.at(0), amount);
    await tester.enterText(fields.at(1), year);
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
  }

  testWidgets('a past year blocks the save with an inline error',
      (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost());
    await tester.pumpAndSettle();

    await openGoalDialog(tester);
    await enterGoal(tester, '1000000', '2020');

    // Dialog stays open with the year error; nothing was saved.
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.text('Enter a year between $nowYear and ${nowYear + 80}'),
      findsOneWidget,
    );
    expect(find.textContaining('Hit '), findsNothing);
  });

  testWidgets('an absurd amount blocks the save with an inline error',
      (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost());
    await tester.pumpAndSettle();

    await openGoalDialog(tester);
    await enterGoal(tester, '999999999999', '${nowYear + 4}');

    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.text('Enter an amount above zero (up to 1 billion)'),
      findsOneWidget,
    );

    // Zero is rejected too.
    await enterGoal(tester, '0', '${nowYear + 4}');
    expect(find.byType(AlertDialog), findsOneWidget);
    expect(
      find.text('Enter an amount above zero (up to 1 billion)'),
      findsOneWidget,
    );
  });

  testWidgets('valid input saves the goal and closes the dialog',
      (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    final writes = <String, dynamic>{};
    await tester.pumpWidget(buildProjectionHost(
      settingWriter: (key, value) async => writes[key] = value,
    ));
    await tester.pumpAndSettle();

    await openGoalDialog(tester);
    await enterGoal(tester, '1000000', '${nowYear + 4}');

    expect(find.byType(AlertDialog), findsNothing);
    expect(
      find.textContaining('Hit \$1,000,000 by ${nowYear + 4}'),
      findsOneWidget,
    );
    expect(writes['net_worth_goal'],
        {'amount_usd': 1000000.0, 'year': nowYear + 4});
    // No failure snackbar.
    expect(find.text("Couldn't save your goal"), findsNothing);
  });

  testWidgets('a failing setting write surfaces the snackbar',
      (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost(
      settingWriter: (key, value) async => throw Exception('offline'),
    ));
    await tester.pumpAndSettle();

    await openGoalDialog(tester);
    await enterGoal(tester, '1000000', '${nowYear + 4}');

    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text("Couldn't save your goal"), findsOneWidget);
  });
}
