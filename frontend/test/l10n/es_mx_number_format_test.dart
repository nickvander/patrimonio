import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:patrimonio/utils/app_locale.dart';
import 'package:patrimonio/utils/currency.dart';

// F6a: the app's Spanish is es-MX, but the language toggle stores a bare
// 'es', which Intl used to resolve to Spain-style formatting ("1.000,00 $").
// syncIntlLocale must map bare 'es' → 'es_MX' so currency renders
// Mexico-style ("$1,000.00" / "17.50").

String _normSpace(String s) =>
    s.replaceAll('\u00A0', ' ').replaceAll('\u202F', ' ');

void main() {
  tearDown(() async {
    localeNotifier.value = null;
    await syncIntlLocale(null);
  });

  test('bare es renders Mexico-style currency, not Spain-style', () async {
    await syncIntlLocale(const Locale('es'));
    expect(_normSpace(moneyFormat('USD').format(1000)), r'$1,000.00');
    expect(_normSpace(moneyFormat('USD').format(17.5)), r'$17.50');
    // Regression shape guard: no Spain-style "1.000,00".
    expect(moneyFormat('USD').format(1000), isNot(contains('1.000')));
  });

  test('explicit es_MX is unchanged', () async {
    await syncIntlLocale(const Locale('es', 'MX'));
    expect(Intl.defaultLocale, 'es_MX');
    expect(_normSpace(moneyFormat('USD').format(1000)), r'$1,000.00');
  });

  test('en is untouched', () async {
    await syncIntlLocale(const Locale('en'));
    expect(Intl.defaultLocale, 'en');
    expect(_normSpace(moneyFormat('USD').format(1000)), r'$1,000.00');
  });
}
