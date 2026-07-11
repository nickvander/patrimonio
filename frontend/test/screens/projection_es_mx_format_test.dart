import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/utils/app_locale.dart';

import 'projection_test_host.dart';

// F6b: every composed number on the projection screen must be locale-aware —
// the Fisher-relation helper, the years-to-FI values, the tooltip year and
// the y-axis ticks used bare NumberFormat.compact() (no currency) in es.
// Note es here means es-MX (the app's only Spanish locale): CLDR es_MX uses
// period decimals like en, so plain numbers/percents match en while money
// stays $-prefixed Mexico-style — never Spain-style commas ("7,0%",
// "1.000.000 $").

void main() {
  tearDown(() async {
    localeNotifier.value = null;
    await syncIntlLocale(null);
  });

  testWidgets('en: Fisher helper uses period decimals; money is \$-shaped',
      (tester) async {
    await syncIntlLocale(const Locale('en'));
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost(locale: const Locale('en')));
    await tester.pumpAndSettle();

    // Defaults: 7% nominal, 3% inflation → 3.9% real.
    expect(
      find.textContaining('7.0% nominal', findRichText: true),
      findsOneWidget,
    );
    expect(find.textContaining('3.9% real'), findsOneWidget);

    // Years-to-FI (8.5 in the fixture) keeps its period decimal.
    expect(find.textContaining('8.5'), findsWidgets);

    // Y-axis ticks are compact *currency* (was a bare "1.5M").
    final tick = find.byWidgetPredicate((w) =>
        w is Text &&
        w.data != null &&
        RegExp(r'^\$[\d.,]+[KM]$').hasMatch(normSpace(w.data!)));
    expect(tick, findsWidgets);
  });

  testWidgets('es: Fisher helper uses es-MX period decimals; money stays '
      'Mexico-style (\$1,000.00-shaped)', (tester) async {
    // Mirror production: the app locale re-points Intl before widgets build,
    // so the injected currencyFormat is created under es → es_MX.
    await syncIntlLocale(const Locale('es'));
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost(locale: const Locale('es')));
    await tester.pumpAndSettle();

    // Period decimals in the Fisher relation (CLDR es_MX, same as en) — never
    // the Spain-style comma decimal.
    expect(find.textContaining('7.0% nominal'), findsOneWidget);
    expect(find.textContaining('3.9% real'), findsOneWidget);
    expect(find.textContaining('7,0% nominal'), findsNothing);

    // Years-to-FI renders with a period decimal ("8.5").
    expect(find.textContaining('8.5'), findsWidgets);

    // Money is Mexico-style: the FI number reads $1,000,000 — never the
    // Spain-style 1.000.000 $.
    expect(find.text(r'$1,000,000'), findsWidgets);
    final spainStyle = find.byWidgetPredicate((w) =>
        w is Text && w.data != null && w.data!.contains('1.000.000'));
    expect(spainStyle, findsNothing);

    // Y-axis ticks carry the currency symbol in es too — es_MX compact
    // currency renders as e.g. "1.5 M$" (suffix symbol, period decimal).
    final tick = find.byWidgetPredicate((w) =>
        w is Text &&
        w.data != null &&
        RegExp(r'^[\d.,]+\s?[kM]\$$').hasMatch(normSpace(w.data!)));
    expect(tick, findsWidgets);

    // The milestone tile title is the unified "Número FI" (was "Número IF").
    expect(find.text('Número FI'), findsWidgets);
    expect(find.text('Número IF'), findsNothing);
  });
}
