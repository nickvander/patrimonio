import 'package:intl/intl.dart';

/// Build the installment rows for a flat/agreed-interest loan.
///
/// The borrower owes `principal + interest`; each period pays `payment`
/// (starting one period after [origination]) until the balance is cleared,
/// with the final row taking whatever remains. The backend stores these as a
/// custom schedule and infers the interest as `Σpayments − principal`, so the
/// figures always reconcile to exactly the agreed interest.
///
/// Returns an empty list when the inputs are non-positive, or when `payment`
/// is so small the schedule would exceed [maxInstallments] — the caller
/// surfaces that as "raise the payment".
///
/// [frequency] is `'weekly'` (7-day steps) or anything else (monthly, with the
/// day-of-month clamped to each target month's length).
List<Map<String, dynamic>> buildFlatSchedule({
  required double principal,
  required double interest,
  required double payment,
  required DateTime origination,
  required String frequency,
  int maxInstallments = 600,
}) {
  final total = principal + interest;
  if (payment <= 0 || total <= 0) return const [];
  final rows = <Map<String, dynamic>>[];
  var remaining = total;
  var k = 1;
  while (remaining > 0.005 && k <= maxInstallments) {
    final amt = remaining >= payment ? payment : remaining;
    final due = frequency == 'weekly'
        ? origination.add(Duration(days: 7 * k))
        : _addMonths(origination, k);
    rows.add({
      'due_date': DateFormat('yyyy-MM-dd').format(due),
      'amount': double.parse(amt.toStringAsFixed(2)),
    });
    remaining -= amt;
    k++;
  }
  // Payment too small to ever clear the balance within the cap.
  return remaining > 0.005 ? const [] : rows;
}

/// Add whole months to a date, clamping the day to the target month's length
/// (so a payment anchored on the 31st lands on the 28th/30th).
DateTime _addMonths(DateTime d, int months) {
  final total = d.month - 1 + months;
  final year = d.year + total ~/ 12;
  final month = total % 12 + 1;
  final lastDay = DateTime(year, month + 1, 0).day;
  return DateTime(year, month, d.day > lastDay ? lastDay : d.day);
}
