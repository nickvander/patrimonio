import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/bill_forecast.dart';

void main() {
  final from = DateTime(2026, 2); // forecast window: 2026-02 .. 2027-01

  test('monthly subscription lands ~once per month across the window', () {
    final f = forecastRecurringBills(
      [
        {
          'monthly_usd': 10.0,
          'cadence_days': 30,
          'last_charge_date': '2026-01-20',
          'status': 'active',
        },
      ],
      from: from,
      months: 12,
    );

    final total = forecastTotalUsd(f);
    // 12 months of ~$10/mo, allowing for cadence drift (30 vs 30.44 days).
    expect(total, greaterThan(100));
    expect(total, lessThan(135));
    // No month is wildly off — a monthly bill spreads roughly evenly.
    for (final m in f) {
      expect(m.totalUsd, lessThan(25));
    }
  });

  test('annual subscription lands in exactly one month', () {
    // Renews 2026-08-01 (within window); next after that is 2027-08 (outside).
    final f = forecastRecurringBills(
      [
        {
          'monthly_usd': 100.0 / 12.0,
          'cadence_days': 365,
          'last_charge_date': '2025-08-01',
          'status': 'active',
        },
      ],
      from: from,
      months: 12,
    );

    final nonZero = f.where((m) => m.totalUsd > 0.01).toList();
    expect(nonZero.length, 1);
    expect(nonZero.first.month.month, 8); // August
    expect(nonZero.first.totalUsd, closeTo(100.0, 1.5));
  });

  test('cancelled subscriptions are excluded', () {
    final f = forecastRecurringBills(
      [
        {
          'monthly_usd': 50.0,
          'cadence_days': 30,
          'last_charge_date': '2026-01-15',
          'status': 'cancelled',
        },
      ],
      from: from,
      months: 12,
    );
    expect(forecastTotalUsd(f), 0.0);
  });

  test('missing/garbage fields do not throw and contribute nothing', () {
    final f = forecastRecurringBills(
      [
        {'status': 'active'}, // no amount / date
        {
          'monthly_usd': 0.0,
          'last_charge_date': '2026-01-01',
          'status': 'active',
        },
        'not a map',
      ],
      from: from,
      months: 12,
    );
    expect(forecastTotalUsd(f), 0.0);
    expect(f.length, 12);
  });
}
