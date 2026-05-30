import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/lending_summary.dart';

void main() {
  group('convertCurrency', () {
    test('same currency is a no-op', () {
      expect(convertCurrency(100, 'USD', 'USD', 18.0), 100);
      expect(convertCurrency(100, 'MXN', 'MXN', 18.0), 100);
      // Case-insensitive.
      expect(convertCurrency(100, 'usd', 'USD', 18.0), 100);
    });

    test('USD → MXN multiplies by the rate', () {
      expect(convertCurrency(100, 'USD', 'MXN', 18.0), 1800);
    });

    test('MXN → USD divides by the rate', () {
      expect(convertCurrency(1800, 'MXN', 'USD', 18.0), 100);
    });

    test('non-positive or non-finite rate falls back to no conversion', () {
      expect(convertCurrency(100, 'USD', 'MXN', 0), 100);
      expect(convertCurrency(100, 'USD', 'MXN', -5), 100);
      expect(convertCurrency(100, 'USD', 'MXN', double.nan), 100);
      expect(convertCurrency(100, 'USD', 'MXN', double.infinity), 100);
    });

    test('unmodelled currency is left as-is', () {
      expect(convertCurrency(100, 'EUR', 'USD', 18.0), 100);
      expect(convertCurrency(100, 'USD', 'EUR', 18.0), 100);
    });
  });

  group('sumLoansConverted', () {
    test('empty list sums to zero', () {
      expect(sumLoansConverted([], 'principal', 'USD', 18.0), 0);
    });

    test('single-currency portfolio sums without conversion', () {
      final loans = [
        {'principal': 100.0, 'currency': 'USD'},
        {'principal': 250.0, 'currency': 'USD'},
      ];
      expect(sumLoansConverted(loans, 'principal', 'USD', 18.0), 350);
    });

    test('mixed-currency portfolio converts each loan to the target', () {
      final loans = [
        {'principal': 100.0, 'currency': 'USD'}, // → 100 USD
        {'principal': 1800.0, 'currency': 'MXN'}, // → 100 USD at 18.0
      ];
      expect(sumLoansConverted(loans, 'principal', 'USD', 18.0), 200);
    });

    test('converts to MXN target', () {
      final loans = [
        {'principal': 100.0, 'currency': 'USD'}, // → 1800 MXN
        {'principal': 1800.0, 'currency': 'MXN'}, // → 1800 MXN
      ];
      expect(sumLoansConverted(loans, 'principal', 'MXN', 18.0), 3600);
    });

    test('missing or non-numeric field counts as zero', () {
      final loans = [
        {'currency': 'USD'}, // no principal
        {'principal': 50.0, 'currency': 'USD'},
        {'principal': 'oops', 'currency': 'USD'}, // not a num
      ];
      expect(sumLoansConverted(loans, 'principal', 'USD', 18.0), 50);
    });

    test('defaults a missing currency to USD', () {
      final loans = [
        {'principal': 100.0}, // currency omitted → USD
      ];
      expect(sumLoansConverted(loans, 'principal', 'MXN', 18.0), 1800);
    });

    test('reads arbitrary fields (outstanding, interest_earned)', () {
      final loans = [
        {'outstanding': 40.0, 'interest_earned': 5.0, 'currency': 'USD'},
        {'outstanding': 18.0, 'interest_earned': 36.0, 'currency': 'MXN'},
      ];
      // outstanding: 40 + (18 / 18) = 41 USD
      expect(sumLoansConverted(loans, 'outstanding', 'USD', 18.0), 41);
      // interest_earned: 5 + (36 / 18) = 7 USD
      expect(
          sumLoansConverted(loans, 'interest_earned', 'USD', 18.0), 7);
    });
  });

  group('loansAreMixedCurrency', () {
    test('empty is not mixed', () {
      expect(loansAreMixedCurrency([]), false);
    });

    test('single currency is not mixed', () {
      expect(
        loansAreMixedCurrency([
          {'currency': 'USD'},
          {'currency': 'USD'},
        ]),
        false,
      );
    });

    test('two currencies is mixed', () {
      expect(
        loansAreMixedCurrency([
          {'currency': 'USD'},
          {'currency': 'MXN'},
        ]),
        true,
      );
    });

    test('missing currency is treated as USD for the mix check', () {
      expect(
        loansAreMixedCurrency([
          {'principal': 1.0}, // → USD
          {'currency': 'USD'},
        ]),
        false,
      );
    });
  });
}
