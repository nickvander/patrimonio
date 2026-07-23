/// Pure helpers for recurring-rule cadences (MVP: weekly / biweekly /
/// monthly / yearly). Mirrors the backend's expansion rules in
/// `backend/src/api/recurring.rs` — in particular the month-end clamp:
/// a day anchor of 31 lands on Feb 28/29 instead of skipping short
/// months, and recovers to 31 afterwards (no permanent drift down).
library;

/// The cadence values the backend accepts, in display order.
const List<String> kRecurringCadences = [
  'weekly',
  'biweekly',
  'monthly',
  'yearly',
];

int _daysInMonth(int year, int month) {
  // Day 0 of the next month = last day of this month.
  return DateTime(year, month + 1, 0).day;
}

DateTime _clampedDay(int year, int month, int anchorDay) {
  final day = anchorDay.clamp(1, _daysInMonth(year, month));
  return DateTime(year, month, day);
}

/// The occurrence immediately after [date] for [cadence].
///
/// [anchorDay] re-anchors monthly/yearly steps (defaults to `date.day`,
/// which is the backend's default too) so "the 31st" recovers after a
/// short month. Weekly/biweekly step exact 7/14 days and ignore it.
DateTime advanceCadence(DateTime date, String cadence, {int? anchorDay}) {
  final anchor = anchorDay ?? date.day;
  switch (cadence) {
    case 'weekly':
      return date.add(const Duration(days: 7));
    case 'biweekly':
      return date.add(const Duration(days: 14));
    case 'yearly':
      return _clampedDay(date.year + 1, date.month, anchor);
    case 'monthly':
    default:
      final nextMonth = date.month == 12 ? 1 : date.month + 1;
      final year = date.month == 12 ? date.year + 1 : date.year;
      return _clampedDay(year, nextMonth, anchor);
  }
}
