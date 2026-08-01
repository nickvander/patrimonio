import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/recurrence.dart';

void main() {
  group('advanceCadence', () {
    test('weekly steps 7 days, biweekly 14', () {
      expect(
        advanceCadence(DateTime(2026, 7, 3), 'weekly'),
        DateTime(2026, 7, 10),
      );
      expect(
        advanceCadence(DateTime(2026, 7, 3), 'biweekly'),
        DateTime(2026, 7, 17),
      );
    });

    test('monthly clamps to short months (Jan 31 → Feb 28)', () {
      expect(
        advanceCadence(DateTime(2026, 1, 31), 'monthly'),
        DateTime(2026, 2, 28),
      );
      // Leap year keeps the 29th.
      expect(
        advanceCadence(DateTime(2024, 1, 31), 'monthly'),
        DateTime(2024, 2, 29),
      );
    });

    test('monthly anchor recovers after a short month (no drift)', () {
      // Mirrors the backend rule: stepping Feb 28 with anchor 31 must
      // land on Mar 31, not permanently drift down to the 28th.
      expect(
        advanceCadence(DateTime(2026, 2, 28), 'monthly', anchorDay: 31),
        DateTime(2026, 3, 31),
      );
    });

    test('monthly rolls December into January of the next year', () {
      expect(
        advanceCadence(DateTime(2026, 12, 15), 'monthly'),
        DateTime(2027, 1, 15),
      );
    });

    test('yearly clamps leap day in common years', () {
      expect(
        advanceCadence(DateTime(2024, 2, 29), 'yearly'),
        DateTime(2025, 2, 28),
      );
    });

    test('unknown cadence falls back to monthly', () {
      expect(
        advanceCadence(DateTime(2026, 5, 10), 'fortnightly'),
        DateTime(2026, 6, 10),
      );
    });
  });
}
