import 'package:flutter_test/flutter_test.dart';

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
}
