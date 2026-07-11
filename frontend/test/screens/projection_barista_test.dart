import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'projection_test_host.dart';

// F8: with $0 barista income the backend returns barista_fi_number ==
// fi_number, so the old `baristaNumber > 0` gate never showed the setup
// prompt — the Barista chip displayed a $1,000,000 figure identical to Full
// FIRE, a dead end. "Configured" now means the barista number is genuinely
// lower than the full FI number.

Future<void> _selectBarista(WidgetTester tester) async {
  final chip = find.widgetWithText(ChoiceChip, 'Barista FI');
  await tester.ensureVisible(chip);
  await tester.pumpAndSettle();
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('barista == full FI number: prompt shown, em-dash instead of a '
      'dollar figure', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost(
      projectionFetcher: fixtureFetcher(
          (y) => projectionFixture(years: y, baristaFiNumber: 1000000.0)),
    ));
    await tester.pumpAndSettle();

    await _selectBarista(tester);

    expect(find.text('—'), findsOneWidget);
    expect(
      find.textContaining("Set 'Barista / pension income'"),
      findsOneWidget,
    );
    // No misleading barista figure: the only $1,000,000 on screen belongs to
    // the FI-number milestone tile.
    expect(find.text(r'$1,000,000'), findsOneWidget);
  });

  testWidgets('a genuinely lower barista number renders its figure',
      (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost(
      projectionFetcher: fixtureFetcher(
          (y) => projectionFixture(years: y, baristaFiNumber: 700000.0)),
    ));
    await tester.pumpAndSettle();

    await _selectBarista(tester);

    expect(find.text(r'$700,000'), findsOneWidget);
    expect(find.text('—'), findsNothing);
    expect(find.textContaining("Set 'Barista / pension income'"), findsNothing);
  });
}
