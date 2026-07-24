import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/spending_window.dart';

void main() {
  group('spendingWindowDivisor', () {
    test('divides by the requested window, not months-with-spending', () {
      // Regression (2026-07 audit): $4.50 spent once in a 12-month window
      // showed $6.07/mo because the divisor was the count of months that HAD
      // spending (1, minus the in-progress fraction). The divisor must come
      // from the window length instead.
      final now = DateTime(2026, 7, 22); // July has 31 days.
      final divisor = spendingWindowDivisor(12, now);
      expect(divisor, closeTo(11 + 22 / 31, 1e-9));

      final avg = 4.50 / divisor;
      // total/N-ish (12-month window → roughly total/12), NOT total/1-ish.
      expect(avg, closeTo(4.50 / 12, 0.06));
      // The buggy value was ~6.07 (total / elapsed-fraction-of-one-month).
      expect(avg, lessThan(1.0));
    });

    test('current month counts as its elapsed fraction', () {
      // 1st of a 31-day month: only 1/31 of the current month has elapsed.
      expect(
        spendingWindowDivisor(6, DateTime(2026, 7, 1)),
        closeTo(5 + 1 / 31, 1e-9),
      );
      // Last day of the month: the current month counts as a whole slot.
      expect(
        spendingWindowDivisor(6, DateTime(2026, 7, 31)),
        closeTo(6.0, 1e-9),
      );
      // February (non-leap) has 28 days.
      expect(
        spendingWindowDivisor(3, DateTime(2026, 2, 14)),
        closeTo(2 + 14 / 28, 1e-9),
      );
    });

    test('1-month window divides by the elapsed fraction alone', () {
      expect(
        spendingWindowDivisor(1, DateTime(2026, 7, 22)),
        closeTo(22 / 31, 1e-9),
      );
    });

    test('never returns zero (guards a division)', () {
      expect(spendingWindowDivisor(1, DateTime(2026, 7, 1)), greaterThan(0));
      // Defensive: a nonsensical window still yields a positive divisor.
      expect(spendingWindowDivisor(0, DateTime(2026, 7, 15)), greaterThan(0));
    });
  });
}
