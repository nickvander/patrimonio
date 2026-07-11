import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'projection_test_host.dart';

// F11: the bold chart line is the *average* path (often above the Monte
// Carlo median the a11y summary announces) — the legend and glossary say so.
// F12: with retirement at/after the horizon there is no withdrawal phase, so
// the success-rate tile's caption stops claiming "chance the plan lasts".

void main() {
  testWidgets('en: legend names the average path and the glossary explains it',
      (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost());
    await tester.pumpAndSettle();

    expect(find.text('Projected (average path)'), findsOneWidget);

    await tester.tap(find.text('What do these terms mean?'));
    await tester.pumpAndSettle();
    expect(find.text('The bold projected line'), findsOneWidget);
    expect(
      find.textContaining('median', findRichText: true),
      findsWidgets,
    );
  });

  testWidgets('es: legend and glossary sentence localized', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost(locale: const Locale('es')));
    await tester.pumpAndSettle();

    expect(find.text('Proyectado (trayectoria promedio)'), findsOneWidget);

    await tester.tap(find.text('¿Qué significan estos términos?'));
    await tester.pumpAndSettle();
    expect(find.text('La línea gruesa proyectada'), findsOneWidget);
  });

  testWidgets('F12: retirement == horizon captions the success tile as n/a',
      (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost(
      settingReader: (key) async => key == 'projection_assumptions'
          ? {'years_to_retirement': 30, 'projection_years': 30}
          : null,
    ));
    await tester.pumpAndSettle();

    expect(
      find.text('n/a — no retirement phase in this projection'),
      findsOneWidget,
    );
    expect(find.text('Chance the plan lasts the horizon'), findsNothing);
  });

  testWidgets('F12: a normal retirement phase keeps the standard caption',
      (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost());
    await tester.pumpAndSettle();

    expect(find.text('Chance the plan lasts the horizon'), findsOneWidget);
    expect(
      find.text('n/a — no retirement phase in this projection'),
      findsNothing,
    );
  });
}
