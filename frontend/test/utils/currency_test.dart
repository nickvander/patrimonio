import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/utils/currency.dart';

void main() {
  group('formatCurrencyAmount — idiomatic symbols', () {
    test('USD uses a leading \$ with thousands + 2 decimals', () {
      expect(formatCurrencyAmount(1234.0, 'USD'), '\$1,234.00');
    });

    test('MXN uses a leading MXN code', () {
      expect(formatCurrencyAmount(47651.01, 'MXN'), 'MXN 47,651.01');
    });

    test('lower-case code is normalised', () {
      expect(formatCurrencyAmount(1234.0, 'usd'), '\$1,234.00');
    });

    test('unknown code falls back to the ISO prefix', () {
      // No symbol entry → "EUR 10.00" rather than a blank/symbol-less value.
      expect(formatCurrencyAmount(10.0, 'EUR'), 'EUR 10.00');
    });

    test('negative amounts keep the sign', () {
      expect(formatCurrencyAmount(-1234.56, 'USD'), '-\$1,234.56');
    });

    test('zero renders with the symbol and two decimals', () {
      expect(formatCurrencyAmount(0.0, 'USD'), '\$0.00');
    });

    test('large MXN values group correctly', () {
      expect(formatCurrencyAmount(12345678.9, 'MXN'), 'MXN 12,345,678.90');
    });
  });

  group('formatCurrencyWithCode — self-labelling for mixed lists', () {
    test('USD gets an explicit code, not a bare \$', () {
      // In a per-currency breakdown "$9,591" is ambiguous; "USD 9,591.00" isn't.
      expect(formatCurrencyWithCode(9591.0, 'USD'), 'USD 9,591.00');
    });

    test('MXN keeps its code prefix', () {
      expect(formatCurrencyWithCode(56344.0, 'MXN'), 'MXN 56,344.00');
    });

    test('lower-case code is normalised', () {
      expect(formatCurrencyWithCode(10.0, 'usd'), 'USD 10.00');
    });

    test('negative amounts keep the sign', () {
      expect(formatCurrencyWithCode(-1234.56, 'USD'), '-USD 1,234.56');
    });
  });

  group('displayMoney — cents drop at the whole-money threshold', () {
    test('just under the threshold keeps cents', () {
      expect(displayCurrencyAmount(9999.99, 'USD'), '\$9,999.99');
    });

    test('exactly the threshold drops cents', () {
      expect(displayCurrencyAmount(10000.0, 'USD'), '\$10,000');
    });

    test('large amounts round to the nearest whole unit', () {
      expect(displayCurrencyAmount(385783.67, 'USD'), '\$385,784');
      expect(displayCurrencyAmount(1000000.0, 'USD'), '\$1,000,000');
    });

    test('negatives use the magnitude for the threshold and keep the sign',
        () {
      // Rounds half away from zero (NumberFormat's own rounding), so
      // -12,345.67 → -$12,346.
      expect(displayCurrencyAmount(-12345.67, 'USD'), '-\$12,346');
      expect(displayCurrencyAmount(-9999.99, 'USD'), '-\$9,999.99');
    });

    test('small amounts are byte-identical to formatCurrencyAmount', () {
      expect(displayCurrencyAmount(1234.56, 'USD'),
          formatCurrencyAmount(1234.56, 'USD'));
      expect(displayCurrencyAmount(0.0, 'USD'), '\$0.00');
    });

    test('threshold applies to the displayed (converted) magnitude — MXN', () {
      // ~$600 USD is ~MXN 11,000: cents drop in MXN even though the USD
      // rendering of the same balance would keep them.
      expect(displayCurrencyAmount(11000.5, 'MXN'), 'MXN 11,001');
      expect(displayCurrencyAmount(599.99, 'USD'), '\$599.99');
    });

    test('withCode variant follows the same rule', () {
      expect(displayCurrencyWithCode(56344.18, 'MXN'), 'MXN 56,344');
      expect(displayCurrencyWithCode(9591.25, 'USD'), 'USD 9,591.25');
    });

    test('es-MX locale keeps Mexico conventions (comma groups, dot decimal)',
        () {
      final es = NumberFormat.currency(
          locale: 'es_MX', name: 'USD', symbol: '\$');
      expect(es.displayMoney(1234567.89), '\$1,234,568');
      expect(es.displayMoney(9999.99), '\$9,999.99');
    });
  });
}
