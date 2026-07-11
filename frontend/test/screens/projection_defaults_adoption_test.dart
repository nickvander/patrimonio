import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'projection_test_host.dart';

// F3: derived defaults are adopted honestly. A valid tracked contribution
// used to be discarded whenever tracked expenses were $0, and a single month
// of data was extrapolated ×12 into the retirement-spend default with a
// "from your tracked spending" hint. Now: contribution adopts whenever > 0;
// expenses only with >= 3 months of history; and the hints disclose the
// provenance ("based on N months" vs "estimate").

void main() {
  Future<void> pumpWithDefaults(
    WidgetTester tester,
    Map<String, dynamic> defaults, {
    Locale locale = const Locale('en'),
  }) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost(
      defaultsFetcher: () async => defaults,
      locale: locale,
    ));
    await tester.pumpAndSettle();
  }

  group('1 month of data, \$0 expenses', () {
    const defaults = {
      'monthly_contribution': 152.4,
      'annual_expenses': 0.0,
      'annual_income': 1200.0,
      'months_of_data': 1,
    };

    testWidgets('en: contribution adopted, expenses stay at the \$40k '
        'estimate with the estimate hint', (tester) async {
      await pumpWithDefaults(tester, defaults);

      // Contribution slider shows ~$152 with a 1-month provenance hint.
      expect(find.text(r'$152'), findsOneWidget);
      expect(find.text('Based on 1 month of your data'), findsOneWidget);

      // Expenses keep the static default, disclosed as an estimate — never
      // "from your data".
      expect(find.text(r'$40,000'), findsOneWidget);
      expect(find.text('Estimate — adjust to your spending'), findsOneWidget);
      expect(find.textContaining('months of your data'), findsNothing);
    });

    testWidgets('es: same adoption, Spanish hints', (tester) async {
      await pumpWithDefaults(tester, defaults, locale: const Locale('es'));

      expect(find.text(r'$152'), findsOneWidget);
      expect(find.text('Basado en 1 mes de tus datos'), findsOneWidget);
      expect(find.text(r'$40,000'), findsOneWidget);
      expect(
          find.text('Estimación — ajústala a tu gasto'), findsOneWidget);
    });
  });

  group('6 months of data with expenses', () {
    const defaults = {
      'monthly_contribution': 152.4,
      'annual_expenses': 30000.0,
      'annual_income': 2000.0,
      'months_of_data': 6,
    };

    testWidgets('en: both adopted with "based on 6 months" hints',
        (tester) async {
      await pumpWithDefaults(tester, defaults);

      expect(find.text(r'$152'), findsOneWidget);
      expect(find.text(r'$30,000'), findsOneWidget);
      // Both the contribution and the expenses sliders carry the hint.
      expect(find.text('Based on 6 months of your data'), findsNWidgets(2));
      expect(find.text('Estimate — adjust to your spending'), findsNothing);
    });

    testWidgets('es: both adopted with Spanish hints', (tester) async {
      await pumpWithDefaults(tester, defaults, locale: const Locale('es'));

      expect(find.text(r'$152'), findsOneWidget);
      expect(find.text(r'$30,000'), findsOneWidget);
      expect(find.text('Basado en 6 meses de tus datos'), findsNWidgets(2));
      expect(find.text('Estimación — ajústala a tu gasto'), findsNothing);
    });
  });
}
