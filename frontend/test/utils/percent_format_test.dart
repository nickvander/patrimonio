import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/utils/percent_format.dart';

// The helper takes a percentage NUMBER (12.5 → "12.5%"), not a ratio. Both
// shipped locales use the same convention: en and es-MX (CLDR es_MX) write
// period decimals with NO space before `%`. An earlier revision gave es
// Spain-style "12,5 %" (comma decimal + NBSP); these tests pin the es-MX
// behavior so it can't regress. The es assertions normalize any non-breaking
// whitespace (U+00A0 / U+202F) to a plain space first, so a reintroduced NBSP
// before `%` fails the equality regardless of codepoint.
String _normSpace(String s) =>
    s.replaceAll('\u00A0', ' ').replaceAll('\u202F', ' ');

Widget _host(Locale locale, Widget child) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: Builder(builder: (context) => child)),
    );

void main() {
  group('formatPercent (BuildContext)', () {
    testWidgets('en renders unchanged: period decimal, no space', (tester) async {
      await tester.pumpWidget(_host(
        const Locale('en'),
        Builder(
          builder: (context) => Column(children: [
            Text(formatPercent(context, 12.5, digits: 1)),
            Text(formatPercent(context, 64.06, digits: 2)),
            Text(formatPercent(context, 50, digits: 0)),
            Text(formatPercent(context, -5.0, digits: 1)),
          ]),
        ),
      ));
      expect(find.text('12.5%'), findsOneWidget);
      expect(find.text('64.06%'), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('-5.0%'), findsOneWidget);
    });

    testWidgets('es (es-MX) matches en: period decimal, no space before %',
        (tester) async {
      const k1 = Key('es-1'), k2 = Key('es-2');
      await tester.pumpWidget(_host(
        const Locale('es'),
        Builder(
          builder: (context) => Column(children: [
            Text(formatPercent(context, 12.5, digits: 1), key: k1),
            Text(formatPercent(context, 50, digits: 0), key: k2),
          ]),
        ),
      ));
      expect(_normSpace(tester.widget<Text>(find.byKey(k1)).data!), '12.5%');
      expect(_normSpace(tester.widget<Text>(find.byKey(k2)).data!), '50%');
    });
  });

  group('formatPercentLocale (context-less variant)', () {
    test('en matches the old toStringAsFixed output exactly', () {
      expect(formatPercentLocale('en', 12.5, digits: 1), '12.5%');
      expect(formatPercentLocale('en', -5.0, digits: 1), '-5.0%');
    });

    test('es (es-MX) uses period decimal + no space before %', () {
      expect(_normSpace(formatPercentLocale('es', 12.5, digits: 1)), '12.5%');
    });

    test('grouping is off so large percents keep no thousands separator', () {
      // Guards visual parity with the old toStringAsFixed at every site.
      expect(formatPercentLocale('en', 1234.5, digits: 1), '1234.5%');
    });
  });
}
