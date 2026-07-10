import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/flat_schedule.dart';

void main() {
  group('buildFlatSchedule', () {
    test('Edgar case: 14000 + 2000 flat, 4000/mo -> 4 even payments', () {
      final rows = buildFlatSchedule(
        principal: 14000,
        interest: 2000,
        payment: 4000,
        origination: DateTime(2026, 7, 10),
        frequency: 'monthly',
      );
      expect(rows.length, 4);
      expect(rows.map((r) => r['amount']).toList(), [4000.0, 4000.0, 4000.0, 4000.0]);
      expect(rows.map((r) => r['due_date']).toList(),
          ['2026-08-10', '2026-09-10', '2026-10-10', '2026-11-10']);
      // Σpayments − principal == the agreed interest.
      final total = rows.fold<double>(0, (a, r) => a + (r['amount'] as double));
      expect(total - 14000, 2000);
    });

    test('uneven: last installment takes the remainder', () {
      final rows = buildFlatSchedule(
        principal: 14000,
        interest: 2000,
        payment: 4500,
        origination: DateTime(2026, 7, 10),
        frequency: 'monthly',
      );
      // 16000 / 4500 -> 4500, 4500, 4500, 2500
      expect(rows.map((r) => r['amount']).toList(), [4500.0, 4500.0, 4500.0, 2500.0]);
      final total = rows.fold<double>(0, (a, r) => a + (r['amount'] as double));
      expect(total, 16000.0);
    });

    test('weekly steps by 7 days', () {
      final rows = buildFlatSchedule(
        principal: 1000,
        interest: 0,
        payment: 500,
        origination: DateTime(2026, 1, 1),
        frequency: 'weekly',
      );
      expect(rows.map((r) => r['due_date']).toList(), ['2026-01-08', '2026-01-15']);
    });

    test('month-end anchor clamps to shorter months', () {
      final rows = buildFlatSchedule(
        principal: 300,
        interest: 0,
        payment: 100,
        origination: DateTime(2026, 1, 31),
        frequency: 'monthly',
      );
      // Jan 31 -> Feb (28), Mar (31), Apr (30)
      expect(rows.map((r) => r['due_date']).toList(),
          ['2026-02-28', '2026-03-31', '2026-04-30']);
    });

    test('zero interest amortizes principal only', () {
      final rows = buildFlatSchedule(
        principal: 12000,
        interest: 0,
        payment: 3000,
        origination: DateTime(2026, 7, 10),
        frequency: 'monthly',
      );
      expect(rows.length, 4);
      final total = rows.fold<double>(0, (a, r) => a + (r['amount'] as double));
      expect(total, 12000.0);
    });

    test('payment too small returns empty (exceeds installment cap)', () {
      final rows = buildFlatSchedule(
        principal: 16000,
        interest: 0,
        payment: 1,
        origination: DateTime(2026, 7, 10),
        frequency: 'monthly',
        maxInstallments: 12,
      );
      expect(rows, isEmpty);
    });

    test('non-positive inputs return empty', () {
      expect(
        buildFlatSchedule(
            principal: 0,
            interest: 0,
            payment: 100,
            origination: DateTime(2026, 1, 1),
            frequency: 'monthly'),
        isEmpty,
      );
      expect(
        buildFlatSchedule(
            principal: 1000,
            interest: 0,
            payment: 0,
            origination: DateTime(2026, 1, 1),
            frequency: 'monthly'),
        isEmpty,
      );
    });
  });
}
