// Aliased: intl exports its own (bidi) TextDirection that would otherwise
// shadow the dart:ui one TextPainter needs.
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/utils/currency.dart';

void main() {
  // compactMoneyAxisWidth lays out text via TextPainter.
  TestWidgetsFlutterBinding.ensureInitialized();
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

  group('compactMoney — chart axis ticks', () {
    // The helper joins symbol and magnitude with no-break spaces so fl_chart
    // axis ticks never wrap; normalize them so assertions read naturally.
    String norm(String s) =>
        s.replaceAll('\u00A0', ' ').replaceAll('\u202F', ' ');

    test('MXN uses the house prefix, never intl\'s bare local "\$"', () {
      // Regression: NumberFormat.compactSimpleCurrency(name: 'MXN') renders
      // "$6.74M" — indistinguishable from USD on a chart axis.
      expect(norm(compactMoney(6738101, 'MXN')), 'MXN 6.74M');
      expect(norm(compactMoney(6738101, 'MXN')), isNot(startsWith('\$')));
    });

    test('no stray decimals on sub-1000 ticks (was "\$50.00" next to "\$150")',
        () {
      expect(compactMoney(50, 'USD'), '\$50');
      expect(compactMoney(100, 'USD'), '\$100');
      expect(compactMoney(150, 'USD'), '\$150');
      expect(norm(compactMoney(50, 'MXN')), 'MXN 50');
    });

    test('USD keeps the plain \$ and compact magnitudes', () {
      expect(compactMoney(1530000, 'USD'), '\$1.53M');
      expect(compactMoney(999, 'USD'), '\$999');
    });

    test('sign precedes the symbol, matching moneyFormat', () {
      expect(compactMoney(-1530000, 'USD'), '-\$1.53M');
      expect(norm(compactMoney(-1530000, 'MXN')), '-MXN 1.53M');
    });

    test('unknown code falls back to the ISO prefix', () {
      expect(norm(compactMoney(2500, 'EUR')), 'EUR 2.5K');
    });

    test('es-MX locale keeps the prefix symbol and its compact magnitude', () {
      Intl.withLocale('es_MX', () {
        expect(norm(compactMoney(6738101, 'MXN')), 'MXN 6.74 M');
        expect(norm(compactMoney(1530000, 'USD')), '\$1.53 M');
      });
    });
  });

  group('compactMoneyAxisWidth — y-axis reservedSize', () {
    // Mirror of the helper's own measurement (same style/font/direction), so
    // the assertions compare against exactly what a chart tick lays out as.
    // In the test VM 'Inter' falls back to the Ahem block font, which is why
    // every assertion is relational rather than an absolute pixel count.
    double labelWidth(String text) {
      final painter = TextPainter(
        text: TextSpan(
          text: text,
          style: const TextStyle(fontSize: 10, fontFamily: 'Inter'),
        ),
        textDirection: ui.TextDirection.ltr,
        maxLines: 1,
      )..layout();
      final width = painter.size.width;
      painter.dispose();
      return width;
    }

    test('never narrower than any tick label in the range — MXN K-scale', () {
      // The shipped clip: gridlines at ~MXN 870 / 1.74K / 2.61K rendered in
      // a fixed 48px box as "MXN 87" / "MXN 1.7" / "MXN 2." — a 10x misread.
      final reserved = compactMoneyAxisWidth(0, 3000, 'MXN');
      for (final tick in [870, 1740, 2610, 3000]) {
        final label = compactMoney(tick, 'MXN');
        expect(reserved, greaterThanOrEqualTo(labelWidth(label)),
            reason: 'reserved box must fit "$label"');
      }
    });

    test('covers intermediate ticks the endpoints alone would miss', () {
      // A tick like $9.99K is wider than the round endpoint's "$10K" —
      // the per-decade worst-digit candidates must account for it.
      final reserved = compactMoneyAxisWidth(0, 10200, 'USD');
      for (final tick in [999, 9990, 10200]) {
        final label = compactMoney(tick, 'USD');
        expect(reserved, greaterThanOrEqualTo(labelWidth(label)),
            reason: 'reserved box must fit "$label"');
      }
    });

    test('MXN reservation is wider than USD at the same scale', () {
      // "MXN " is a wider prefix than "$": USD mode must not pay for it.
      expect(compactMoneyAxisWidth(0, 3000, 'MXN'),
          greaterThan(compactMoneyAxisWidth(0, 3000, 'USD')));
      expect(compactMoneyAxisWidth(0, 35000000, 'MXN'),
          greaterThan(compactMoneyAxisWidth(0, 35000000, 'USD')));
    });

    test('a negative extent reserves extra width for the sign', () {
      final signed = compactMoneyAxisWidth(-2500, 2500, 'USD');
      expect(signed, greaterThan(compactMoneyAxisWidth(0, 2500, 'USD')));
      expect(signed, greaterThanOrEqualTo(labelWidth(compactMoney(-2500, 'USD'))));
    });

    test('es-MX compact suffixes (" M") are measured, not assumed', () {
      Intl.withLocale('es_MX', () {
        // es renders "MXN 30 M" (spaced suffix) — wider than en's "MXN 30M".
        final reserved = compactMoneyAxisWidth(0, 35000000, 'MXN');
        for (final tick in [5000000, 17400000, 30000000]) {
          final label = compactMoney(tick, 'MXN');
          expect(reserved, greaterThanOrEqualTo(labelWidth(label)),
              reason: 'reserved box must fit "$label"');
        }
      });
    });

    test('memoized result is stable across repeated calls', () {
      expect(compactMoneyAxisWidth(0, 3000, 'MXN'),
          compactMoneyAxisWidth(0, 3000, 'MXN'));
    });
  });
}
