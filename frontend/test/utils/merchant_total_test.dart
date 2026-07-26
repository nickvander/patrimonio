import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/merchant_total.dart';

/// Regression cover for the mixed-currency merchant total: the fold used to
/// seed with the open transaction's RAW NATIVE amount while converting every
/// sibling, so the "Total at this merchant" line overstated by the whole
/// unconverted seed — and grew worse with each sibling.
void main() {
  const rate = 17.0; // 1 USD = 17 MXN

  List<dynamic> mxnRows(int n) => List.generate(
        n,
        (_) => <String, dynamic>{'amount': -500.0, 'currency': 'MXN'},
      );

  group('merchantLifetimeTotal', () {
    test('an MXN charge viewed in USD converts the seed too', () {
      // MXN 500 open + two identical priors = MXN 1500 = $88.24.
      final total = merchantLifetimeTotal(
        openConvertedAmount: -500.0 / rate,
        siblings: mxnRows(2),
        targetCurrency: 'USD',
        usdMxnRate: rate,
      );
      expect(total, closeTo(88.24, 0.01));
      // The bug's output, for the record: 500 + 29.41 + 29.41 = 558.82.
      expect(total, lessThan(100), reason: 'must not include a raw MXN seed');
    });

    test('the overstatement does not scale with sibling count', () {
      for (final n in [0, 1, 5]) {
        final total = merchantLifetimeTotal(
          openConvertedAmount: -500.0 / rate,
          siblings: mxnRows(n),
          targetCurrency: 'USD',
          usdMxnRate: rate,
        );
        expect(total, closeTo((500.0 * (n + 1)) / rate, 0.01),
            reason: '$n siblings');
      }
    });

    test('same-currency totals are a plain sum', () {
      final total = merchantLifetimeTotal(
        openConvertedAmount: -12.5,
        siblings: [
          {'amount': -12.5, 'currency': 'USD'},
          {'amount': -25.0, 'currency': 'USD'},
        ],
        targetCurrency: 'USD',
        usdMxnRate: rate,
      );
      expect(total, closeTo(50.0, 0.001));
    });

    test('mirror case: a USD charge viewed in MXN', () {
      final total = merchantLifetimeTotal(
        openConvertedAmount: -20.0 * rate,
        siblings: [
          {'amount': -20.0, 'currency': 'USD'},
        ],
        targetCurrency: 'MXN',
        usdMxnRate: rate,
      );
      expect(total, closeTo(680.0, 0.01));
    });

    test('inflows and outflows both count as spend at the merchant', () {
      final total = merchantLifetimeTotal(
        openConvertedAmount: -10.0,
        siblings: [
          {'amount': 10.0, 'currency': 'USD'},
        ],
        targetCurrency: 'USD',
        usdMxnRate: rate,
      );
      expect(total, closeTo(20.0, 0.001), reason: 'magnitudes, not net');
    });

    test('a row with no currency is assumed to be in the reporting currency',
        () {
      final total = merchantLifetimeTotal(
        openConvertedAmount: -5.0,
        siblings: [
          {'amount': -5.0},
        ],
        targetCurrency: 'USD',
        usdMxnRate: rate,
      );
      expect(total, closeTo(10.0, 0.001));
    });
  });
}
