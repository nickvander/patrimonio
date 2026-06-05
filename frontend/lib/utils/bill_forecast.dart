/// Forward projection of recurring bills, built from the backend's detected
/// subscriptions. Pure + dependency-free so it can be unit-tested.
///
/// Each subscription carries `monthly_usd` (normalized monthly burn),
/// `cadence_days` (gap between charges), `last_charge_date`, and `status`.
/// We step forward from the last charge by the cadence, dropping each
/// projected charge into its calendar-month bucket. A per-charge amount of
/// `monthly_usd * cadence_days / 30.4375` keeps the annual total consistent
/// with the monthly burn while still landing annual renewals in one month.

class BillMonth {
  /// First day of the bucket month.
  final DateTime month;

  /// Projected recurring spend that month, in USD.
  final double totalUsd;

  const BillMonth(this.month, this.totalUsd);
}

const double _avgDaysPerMonth = 30.4375;

List<BillMonth> forecastRecurringBills(
  List<dynamic> subscriptions, {
  required DateTime from,
  int months = 12,
}) {
  final windowStart = DateTime(from.year, from.month);
  final windowEnd = DateTime(from.year, from.month + months); // exclusive
  final totals = List<double>.filled(months, 0.0);

  for (final raw in subscriptions) {
    if (raw is! Map) continue;
    final status = (raw['status']?.toString() ?? 'active');
    if (status != 'active') continue;

    final monthlyUsd = (raw['monthly_usd'] as num?)?.toDouble() ?? 0.0;
    var cadence = (raw['cadence_days'] as num?)?.toInt() ?? 30;
    if (cadence < 1) cadence = 30;
    final lastStr = raw['last_charge_date']?.toString();
    final last = lastStr == null ? null : DateTime.tryParse(lastStr);
    if (monthlyUsd <= 0 || last == null) continue;

    final perCharge = monthlyUsd * cadence / _avgDaysPerMonth;

    var d = last.add(Duration(days: cadence));
    var guard = 0;
    while (d.isBefore(windowEnd) && guard < 5000) {
      guard++;
      if (!d.isBefore(windowStart)) {
        final idx = (d.year - from.year) * 12 + (d.month - from.month);
        if (idx >= 0 && idx < months) totals[idx] += perCharge;
      }
      d = d.add(Duration(days: cadence));
    }
  }

  return [
    for (var i = 0; i < months; i++)
      BillMonth(DateTime(from.year, from.month + i), totals[i]),
  ];
}

/// Convenience: total projected recurring spend over the window (USD).
double forecastTotalUsd(List<BillMonth> forecast) =>
    forecast.fold(0.0, (sum, m) => sum + m.totalUsd);
