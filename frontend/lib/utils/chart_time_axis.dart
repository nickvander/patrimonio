import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

/// Pure helpers for a time-proportional (day-offset) chart x-axis.
///
/// Copied verbatim from `widgets/instrument_detail_sheet.dart` (which introduced
/// them in `ca4ca8d`) so `performance_card.dart` can share them without editing
/// that file. Follow-up: the instrument sheet could later dedupe onto this.

/// Collapses same-day duplicate closes — the LAST close for a calendar day
/// wins — and normalizes each date to a UTC midnight so day-offset math is
/// exact (local-midnight arithmetic can slip a day across DST changes).
/// Output is sorted ascending regardless of input order.
List<({DateTime date, double close})> dedupeDailyCloses(
    List<({DateTime date, double close})> points) {
  final byDay = <DateTime, double>{};
  for (final p in points) {
    byDay[DateTime.utc(p.date.year, p.date.month, p.date.day)] = p.close;
  }
  final days = byDay.keys.toList()..sort();
  return [for (final d in days) (date: d, close: byDay[d]!)];
}

/// Maps (already-deduped) points to day-offset spots from the first date:
/// `x = days since points.first.date`. This is what makes the x-axis
/// time-proportional — a 3-month hole in the data occupies 3 months of
/// x-range instead of one sample step.
List<FlSpot> dayOffsetSpots(List<({DateTime date, double close})> points) {
  if (points.isEmpty) return const [];
  final x0 = points.first.date;
  return [
    for (final p in points)
      FlSpot(p.date.difference(x0).inDays.toDouble(), p.close),
  ];
}

/// Bottom-axis tick interval in days: ~4 labels across the span, never
/// below one day (so a 2-point / 2-day series still gets valid ticks).
double dayOffsetTickInterval(int spanDays) =>
    (spanDays / 3).clamp(1, double.infinity).toDouble();

/// The coarsest date format that still tells [tickDates] apart — i.e. one
/// under which no two ADJACENT ticks render the same string.
///
/// Picking a format from the axis's total span (the rule this replaces: under
/// 120 days → "MMM d", else "MMM y") measures the wrong thing. What decides
/// whether two labels collide is the gap BETWEEN ticks, and a 140-day span
/// sampled daily puts seven ticks inside one month — which is how a 1Y
/// net-worth chart came to print "Jul 2026" seven times in a row.
///
/// [spanDays] still sets the *preference*, because a two-month chart reads
/// better as "Mar 15" than "Mar 2026"; it just no longer gets the last word.
/// Adjacent-only comparison is deliberate: on a multi-year axis "Jul 2026" may
/// legitimately reappear years later, and forcing every label globally unique
/// would push the whole axis to a needlessly precise format.
DateFormat nonRepeatingDateFormat(List<DateTime> tickDates, {int? spanDays}) {
  final ladder = <DateFormat>[
    if (spanDays == null || spanDays >= 120) DateFormat('MMM y'),
    DateFormat('MMM d'),
    // Same month-day in two different years — the last way "MMM d" can repeat
    // on an ALL range that happens to tick on the same calendar day.
    DateFormat('MMM d, y'),
  ];
  for (final format in ladder) {
    final labels = [for (final d in tickDates) format.format(d)];
    var repeats = false;
    for (var i = 1; i < labels.length; i++) {
      if (labels[i] == labels[i - 1]) {
        repeats = true;
        break;
      }
    }
    if (!repeats) return format;
  }
  return ladder.last;
}
