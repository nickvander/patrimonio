import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'projection_test_host.dart';

// F8: with $0 barista income the backend returns barista_fi_number ==
// fi_number, so the old `baristaNumber > 0` gate never showed the setup
// prompt — the Barista chip displayed a $1,000,000 figure identical to Full
// FIRE, a dead end. "Configured" now means the barista number is genuinely
// lower than the full FI number.
// U4: the target-number milestone tile follows the focused plan too — it
// used to pin the Full-FIRE number even with Barista focused, so both the
// plan card AND the tile now show the em-dash/prompt (unconfigured) or the
// lower barista number (configured).

Future<void> _selectChip(WidgetTester tester, String label) async {
  final chip = find.widgetWithText(ChoiceChip, label);
  await tester.ensureVisible(chip);
  await tester.pumpAndSettle();
  await tester.tap(chip);
  await tester.pumpAndSettle();
}

Future<void> _selectBarista(WidgetTester tester) =>
    _selectChip(tester, 'Barista FI');

void main() {
  testWidgets('barista == full FI number: prompt shown, em-dash instead of a '
      'dollar figure — in the plan card AND the milestone tile', (
    tester,
  ) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(
      buildProjectionHost(
        projectionFetcher: fixtureFetcher(
          (y) => projectionFixture(years: y, baristaFiNumber: 1000000.0),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _selectBarista(tester);

    // U4: plan card + tile both read the em-dash and the setup prompt.
    expect(find.text('—'), findsNWidgets(2));
    expect(
      find.textContaining("Set 'Barista / pension income'"),
      findsNWidgets(2),
    );
    // No misleading barista figure anywhere: with Barista focused and
    // unconfigured, the Full-FIRE $1,000,000 is not on screen at all.
    expect(find.text(r'$1,000,000'), findsNothing);
  });

  testWidgets('a genuinely lower barista number renders its figure in the '
      'plan card and the milestone tile', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(
      buildProjectionHost(
        projectionFetcher: fixtureFetcher(
          (y) => projectionFixture(years: y, baristaFiNumber: 700000.0),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _selectBarista(tester);

    // U4: the lower barista number shows twice — plan card + tile.
    expect(find.text(r'$700,000'), findsNWidgets(2));
    expect(find.text('—'), findsNothing);
    expect(find.textContaining("Set 'Barista / pension income'"), findsNothing);
  });

  testWidgets('Full focus (default) still shows the FI number in the tile', (
    tester,
  ) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(
      buildProjectionHost(
        projectionFetcher: fixtureFetcher(
          (y) => projectionFixture(years: y, baristaFiNumber: 1000000.0),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Plan card headline + milestone tile both carry the Full-FIRE number.
    expect(find.text(r'$1,000,000'), findsNWidgets(2));
    expect(find.text('Target net worth'), findsOneWidget);
    expect(find.text('—'), findsNothing);
  });

  testWidgets('Coast focus swings the tile to the Coast FIRE number', (
    tester,
  ) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost());
    await tester.pumpAndSettle();

    await _selectChip(tester, 'Coast FIRE');

    // Plan card + tile both show the $400,000 coast number.
    expect(find.text(r'$400,000'), findsNWidgets(2));
    expect(find.text(r'$1,000,000'), findsNothing);
  });
}
