import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/app_locale.dart';
import 'package:patrimonio/utils/loan_dates.dart';

// Regression: the loan card's "Lent … · <date>" meta used to print the raw
// ISO payload string ("2024-05-01") in every locale, and other lending
// dates used a hardcoded US 'MMM d, y' pattern even in es-MX. The helpers
// must render via locale-aware skeletons that follow syncIntlLocale.
//
// Pure Dart-VM tests — no widget pump (see the package:web hazard note in
// test/l10n/intl_date_locale_test.dart, which this mirrors).
void main() {
  tearDown(() async {
    // Reset shared Intl state so test order doesn't matter.
    localeNotifier.value = null;
    await syncIntlLocale(null);
  });

  test('en renders a medium date, not the raw ISO string', () async {
    await syncIntlLocale(const Locale('en'));
    expect(formatIsoDateMedium('2024-05-01'), 'May 1, 2024');
    expect(formatIsoDateShort('2024-05-01'), 'May 1');
  });

  test('es-MX renders day-first Spanish, not ISO or US ordering', () async {
    await syncIntlLocale(const Locale('es'));
    expect(formatIsoDateMedium('2024-05-01'), '1 may 2024');
    expect(formatIsoDateShort('2024-05-01'), '1 may');
  });

  test('unparseable input falls back to the raw string', () async {
    await syncIntlLocale(const Locale('es'));
    expect(formatIsoDateMedium('not-a-date'), 'not-a-date');
    expect(formatIsoDateShort(''), '');
  });
}
