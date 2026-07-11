import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'projection_test_host.dart';

// U3: when /projections/defaults reports a tracked annual income, a caption
// under the Monthly savings slider relates the CURRENT contribution to it
// ("You're saving about 10% of your income"), live-updating as the slider
// moves, capped at 100%, and hidden entirely without income data.

const _income18288 = {
  'monthly_contribution': 152.4,
  'annual_expenses': 0.0,
  'annual_income': 18288.0,
  'months_of_data': 1,
};

Future<void> _pump(
  WidgetTester tester,
  Map<String, dynamic>? defaults, {
  Locale locale = const Locale('en'),
}) async {
  setTestSize(tester, const Size(1300, 1800));
  await tester.pumpWidget(buildProjectionHost(
    defaultsFetcher: () async => defaults,
    locale: locale,
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(r'en: $152.40/mo against $18,288/yr reads ~10%, and moving the '
      'slider updates it live', (tester) async {
    await _pump(tester, _income18288);

    // 152.4 × 12 ÷ 18,288 = exactly 10%.
    const caption = "You're saving about 10% of your income";
    expect(find.text(caption), findsOneWidget);

    // Drag the savings slider: the caption recomputes from the new value.
    final slider = find.descendant(
      of: find
          .ancestor(
              of: find.text('Monthly savings'),
              matching: find.byType(MergeSemantics))
          .first,
      matching: find.byType(Slider),
    );
    await tester.drag(slider, const Offset(150, 0));
    await tester.pump();
    expect(find.text(caption), findsNothing); // the 10% figure moved on
    expect(find.textContaining('of your income'), findsOneWidget);

    // Flush the debounced commit so no timer outlives the test.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
  });

  testWidgets('caption caps at 100% for an outsized contribution',
      (tester) async {
    await _pump(tester, const {
      'monthly_contribution': 9000.0, // ×12 = $108k on $18,288 income
      'annual_expenses': 0.0,
      'annual_income': 18288.0,
      'months_of_data': 1,
    });

    expect(
      find.text("You're saving about 100% of your income"),
      findsOneWidget,
    );
  });

  testWidgets('no caption without income data', (tester) async {
    await _pump(tester, const {
      'monthly_contribution': 152.4,
      'annual_expenses': 0.0,
      'annual_income': 0.0,
      'months_of_data': 1,
    });
    expect(find.textContaining('of your income'), findsNothing);

    await _pump(tester, null); // defaults endpoint returned nothing
    expect(find.textContaining('of your income'), findsNothing);
  });

  testWidgets('es: the caption localizes', (tester) async {
    await _pump(tester, _income18288, locale: const Locale('es'));

    expect(
      find.text('Estás ahorrando alrededor del 10% de tus ingresos'),
      findsOneWidget,
    );
  });

  testWidgets('restored saved assumptions still get the caption (income is '
      'fetched without adopting defaults)', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost(
      settingReader: (key) async => key == 'projection_assumptions'
          ? {'monthly_contribution': 762.0}
          : null,
      defaultsFetcher: () async => _income18288,
    ));
    await tester.pumpAndSettle();

    // The saved $762 won over the $152.40 tracked default…
    expect(find.text(r'$762'), findsOneWidget);
    expect(find.text(r'$152'), findsNothing);
    // …but the tracked income still powers the caption: 762×12/18288 = 50%.
    expect(
      find.text("You're saving about 50% of your income"),
      findsOneWidget,
    );
  });
}
