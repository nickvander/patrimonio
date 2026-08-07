/// Net-worth delta computation shared by the dashboard hero badge and the
/// net-worth card's trend chips — one implementation so the two surfaces can
/// never disagree about the comparison anchor or the window label.
///
/// History points are the raw `net_worth_history` JSON maps
/// (`{"date": ISO-8601, "net_worth": USD number, ...}`). All amounts are USD;
/// callers scale to the reporting currency. Percentages are ratios and thus
/// currency-agnostic.
library;

/// Delta from the latest snapshot back to a reference snapshot.
class NetWorthDelta {
  /// Signed change in USD (latest − anchor).
  final double amount;

  /// Percent move relative to the anchor, or null when the baseline is
  /// unreliable: negative (a % against negative net worth is meaningless) or
  /// onboarding-inflated (net worth more than ~tripled over the window because
  /// accounts were still being added). The dollar amount is still shown; the
  /// percentage is suppressed rather than reporting a meaningless "+3905%".
  final double? percentage;

  /// The window the anchor actually came from — `'30d'`, `'7d'`, `'MoM'` or
  /// `'YoY'`. This is what makes the chip label honest: it always names the
  /// real anchor, never a wished-for window.
  final String windowLabel;

  const NetWorthDelta({
    required this.amount,
    required this.percentage,
    required this.windowLabel,
  });
}

class _DeltaPoint {
  final DateTime date;
  final double value;
  const _DeltaPoint({required this.date, required this.value});
}

/// Parse raw history maps into dated points, skipping anything that doesn't
/// parse or lacks `net_worth`. Returned sorted ascending by date.
List<_DeltaPoint> _parsePoints(List<dynamic> history) {
  final points = <_DeltaPoint>[];
  for (final raw in history) {
    if (raw is! Map) continue;
    final ds = raw['date']?.toString();
    if (ds == null) continue;
    final dt = DateTime.tryParse(ds);
    if (dt == null) continue;
    final nw = (raw['net_worth'] as num?)?.toDouble();
    if (nw == null) continue;
    points.add(_DeltaPoint(date: dt, value: nw));
  }
  points.sort((a, b) => a.date.compareTo(b.date));
  return points;
}

/// Percentage from a baseline → latest, or null when the baseline is so small
/// relative to the latest that the change is onboarding/data noise, not a real
/// market move (net worth doesn't 3x in a month from returns).
double? _plausiblePct(double amount, double baseline, double latest) {
  if (baseline <= 0) return null;
  if (latest / baseline > 3.0) return null;
  return (amount / baseline) * 100;
}

/// Delta from the latest snapshot back to a reference snapshot — drives the
/// "↑ +$X vs 30d ago" chip/badge. Prefers a ~30d anchor and falls back to ~7d
/// when there isn't a month of history yet; [NetWorthDelta.windowLabel] always
/// reflects the window the anchor was actually found in, so the rendered
/// "vs Xd ago" copy stays honest. Each window has a ±5 day tolerance so a
/// missing snapshot doesn't kill the chip — but a 16-day-old oldest snapshot
/// can never be passed off as "30d ago". Returns null when history is too
/// short or contains no comparable point.
NetWorthDelta? computeNetWorthDelta(List<dynamic> history) {
  final points = _parsePoints(history);
  if (points.length < 2) return null;
  final latest = points.last;

  // Find the snapshot nearest each window's target, within tolerance.
  _DeltaPoint? pick(int targetDaysAgo, int tolerance) {
    final target = latest.date.subtract(Duration(days: targetDaysAgo));
    _DeltaPoint? best;
    int? bestDist;
    for (final p in points) {
      if (identical(p, latest)) continue;
      final dist = (p.date.difference(target)).inDays.abs();
      if (dist <= tolerance && (bestDist == null || dist < bestDist)) {
        best = p;
        bestDist = dist;
      }
    }
    return best;
  }

  for (final (days, label) in const [(30, '30d'), (7, '7d')]) {
    final ref = pick(days, 5);
    if (ref != null && ref.value != 0) {
      final amount = latest.value - ref.value;
      if (ref.value < 0) {
        // Negative net-worth baseline: a percentage is meaningless here
        // (improving from -50k to -40k isn't "+20%"), but the dollar delta is
        // real — debt-payoff/early-onboarding users deserve to see it. Show
        // the amount, suppress only the %.
        return NetWorthDelta(
          amount: amount,
          percentage: null,
          windowLabel: label,
        );
      }
      final pct = _plausiblePct(amount, ref.value, latest.value);
      // Implausible baseline (onboarding — net worth >3x'd as accounts were
      // added): hide the whole chip, not just the %. A "+$1.5M MoM" is as
      // misleading as "+3905%". Try the next (shorter) window instead.
      if (pct == null) continue;
      return NetWorthDelta(amount: amount, percentage: pct, windowLabel: label);
    }
  }
  return null;
}

/// Month-over-month and year-over-year deltas vs the same calendar date one
/// month / one year before the latest snapshot. Computed over the FULL history
/// (independent of the chart's range chip) with a ±5 day tolerance so a
/// missing snapshot doesn't kill the figure. Either may be null when there
/// isn't a comparable point that far back.
({NetWorthDelta? mom, NetWorthDelta? yoy}) computeMomYoyDeltas(
  List<dynamic> history,
) {
  final points = _parsePoints(history);
  if (points.length < 2) return (mom: null, yoy: null);
  final latest = points.last;

  NetWorthDelta? deltaTo(DateTime targetDate, String label) {
    _DeltaPoint? best;
    int? bestDist;
    for (final p in points) {
      if (identical(p, latest)) continue;
      final dist = p.date.difference(targetDate).inDays.abs();
      if (dist <= 5 && (bestDist == null || dist < bestDist)) {
        best = p;
        bestDist = dist;
      }
    }
    if (best == null || best.value == 0) return null;
    final amount = latest.value - best.value;
    if (best.value < 0) {
      // Negative baseline: show the dollar delta, suppress the meaningless %.
      return NetWorthDelta(
        amount: amount,
        percentage: null,
        windowLabel: label,
      );
    }
    final pct = _plausiblePct(amount, best.value, latest.value);
    // Onboarding-inflated baseline → hide the chip entirely (no "+$1.5M MoM").
    if (pct == null) return null;
    return NetWorthDelta(amount: amount, percentage: pct, windowLabel: label);
  }

  final d = latest.date;
  return (
    mom: deltaTo(DateTime(d.year, d.month - 1, d.day), 'MoM'),
    yoy: deltaTo(DateTime(d.year - 1, d.month, d.day), 'YoY'),
  );
}

/// Fraction of the plotted value span that FX movement must reach before the
/// FX-free replot is worth offering. Below this the shifted line traces the
/// live one within a stroke width or two.
const double kFxVisibleShareOfSpan = 0.10;

/// Whether replotting a window with FX held constant would visibly differ from
/// the live-FX line.
///
/// The constant-FX view answers "what would my net worth have done if the peso
/// hadn't moved?" — a question worth a control only when the answer *looks*
/// different. Currency movement displaces the plot by roughly [fxUsd], and the
/// chart's y-axis is fitted to the span of [constantFxUsd], so a displacement
/// under [kFxVisibleShareOfSpan] of that span produces two lines that trace
/// each other. Offering the control regardless is what made pressing it read
/// as doing nothing: on a $1.6M net worth whose window moved $46k, a $639 FX
/// component is 1.4% of the change and invisible on the plot.
///
/// The ratio — rather than an absolute dollar floor — is what keeps offsetting
/// windows honest: FX +$50k against market −$50k nets to a flat delta while
/// having entirely shaped the curve, and it stays offered.
///
/// A flat series (zero span) with any FX movement is the visible extreme: the
/// live line is level and the constant-FX one is not.
bool fxViewIsInformative({
  required double fxUsd,
  required List<double> constantFxUsd,
}) {
  // One point is not a line; nothing to compare a replot against.
  if (constantFxUsd.length < 2 || fxUsd == 0) return false;
  var min = constantFxUsd.first;
  var max = constantFxUsd.first;
  for (final v in constantFxUsd) {
    if (v < min) min = v;
    if (v > max) max = v;
  }
  final span = max - min;
  if (span <= 0) return true;
  return fxUsd.abs() >= span * kFxVisibleShareOfSpan;
}
