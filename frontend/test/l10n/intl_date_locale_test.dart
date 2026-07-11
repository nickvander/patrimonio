import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:patrimonio/utils/app_locale.dart';

// Verifies the Intl/date-locale wiring (Task 15): syncIntlLocale must point
// `Intl.defaultLocale` at the active app locale and initialize the bundled
// date symbols, so the ~36 DateFormat call sites (transaction date group
// headers, chart axes, …) render in Spanish instead of en_US.
//
// Pure Dart-VM tests — no widget pump, no ApiService, no package:web (see
// MEMORY: patrimonio-flutter-widget-test-web-dep).
void main() {
  // 2024-01-01 was a Monday.
  final monday = DateTime(2024, 1, 1);

  tearDown(() async {
    // Reset shared state so test order doesn't matter.
    localeNotifier.value = null;
    await syncIntlLocale(null);
  });

  test('syncIntlLocale(es) makes DateFormat render Spanish', () async {
    await syncIntlLocale(const Locale('es'));
    // F6: a bare 'es' maps to es_MX so numbers/currency format Mexico-style
    // ($1,000.00), not Spain-style (1.000,00 $).
    expect(Intl.defaultLocale, 'es_MX');
    expect(DateFormat('EEEE').format(monday), 'lunes');
    expect(DateFormat('MMMM').format(monday), 'enero');
  });

  test('syncIntlLocale(en) makes DateFormat render English', () async {
    await syncIntlLocale(const Locale('en'));
    expect(Intl.defaultLocale, 'en');
    expect(DateFormat('EEEE').format(monday), 'Monday');
    expect(DateFormat('MMMM').format(monday), 'January');
  });

  test('locale change via localeNotifier re-points Intl (listener path)',
      () async {
    // Initialize symbols once (resolved synchronously with the bundled
    // date_symbol_data_local data), then flip locales through the notifier
    // exactly like the dashboard language toggle does.
    await syncIntlLocale(const Locale('en'));

    localeNotifier.value = const Locale('es');
    // F6: bare 'es' → es_MX (Mexico-style numbers).
    expect(Intl.defaultLocale, 'es_MX');
    expect(DateFormat('EEEE').format(monday), 'lunes');

    localeNotifier.value = const Locale('en');
    expect(Intl.defaultLocale, 'en');
    expect(DateFormat('EEEE').format(monday), 'Monday');
  });

  test('country-qualified locales use the underscore tag Intl expects',
      () async {
    await syncIntlLocale(const Locale('es', 'MX'));
    expect(Intl.defaultLocale, 'es_MX');
    // es_MX is in the bundled symbol set, so formatting resolves directly.
    expect(DateFormat('EEEE').format(monday), 'lunes');
  });
}
