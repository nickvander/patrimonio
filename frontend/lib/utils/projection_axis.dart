import 'dart:math' as math;

/// F7: adaptive x-axis label interval for the wealth-projection chart.
///
/// The chart used a fixed `interval: 5`, which crowds/overlaps labels on a
/// phone with a 50-year horizon and thins them needlessly on wide screens.
/// Budget ~1 label per 56px on narrow plots / 62px on wide ones (the house
/// thinning rule, skill §4 — the narrow budget is deliberately a bit wider
/// than the 46px used elsewhere; it was sized for "Año 50" and now carries
/// U1's 4-digit calendar years, e.g. "2026", which render ~28–30px at the
/// 12px label size, so the budget still leaves a comfortable gap), then
/// round the step up to a clean 5/10/15/…, preferring a step that divides
/// [projectionYears] so the last year keeps its label (the axis is anchored
/// at year 0, so the first always shows).
double projectionYearAxisInterval({
  required double plotWidth,
  required int projectionYears,
}) {
  final perLabel = plotWidth < 500 ? 56.0 : 62.0;
  final maxLabels = math.max(2, (plotWidth / perLabel).floor());
  const steps = [5, 10, 15, 20, 25];
  // First pass: the smallest clean step that both fits the label budget and
  // divides the horizon (keeps the last-year label).
  for (final step in steps) {
    if (projectionYears % step == 0 &&
        projectionYears ~/ step + 1 <= maxLabels) {
      return step.toDouble();
    }
  }
  // Second pass: smallest clean step that fits, even if the last year's
  // label is dropped.
  for (final step in steps) {
    if ((projectionYears / step).ceil() + 1 <= maxLabels) {
      return step.toDouble();
    }
  }
  return steps.last.toDouble();
}
