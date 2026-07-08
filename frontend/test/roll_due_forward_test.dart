import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/widgets/debt_payoff_card.dart';

void main() {
  group('rollDueForward', () {
    test('a past anchor rolls forward to the next monthly occurrence', () {
      // Anchor on the 5th; today is the 20th → next occurrence is next month.
      final anchor = DateTime(2026, 3, 5);
      final today = DateTime(2026, 7, 20);
      expect(rollDueForward(anchor, today), DateTime(2026, 8, 5));
    });

    test('a future anchor day this month stays in the current month', () {
      final anchor = DateTime(2026, 1, 25);
      final today = DateTime(2026, 7, 20);
      expect(rollDueForward(anchor, today), DateTime(2026, 7, 25));
    });

    test('today counts as due today (not rolled to next month)', () {
      final anchor = DateTime(2026, 4, 8);
      final today = DateTime(2026, 7, 8);
      expect(rollDueForward(anchor, today), DateTime(2026, 7, 8));
    });

    test('end-of-month anchor clamps to shorter months', () {
      // 31st anchor, today in February → clamps to Feb 28 (2026 not leap).
      final anchor = DateTime(2026, 1, 31);
      final today = DateTime(2026, 2, 1);
      expect(rollDueForward(anchor, today), DateTime(2026, 2, 28));
    });

    test('clamp respects leap February (29 days)', () {
      final anchor = DateTime(2024, 1, 31);
      final today = DateTime(2024, 2, 1);
      expect(rollDueForward(anchor, today), DateTime(2024, 2, 29));
    });

    test('rolls across a year boundary', () {
      final anchor = DateTime(2025, 6, 15);
      final today = DateTime(2026, 12, 20);
      expect(rollDueForward(anchor, today), DateTime(2027, 1, 15));
    });
  });
}
