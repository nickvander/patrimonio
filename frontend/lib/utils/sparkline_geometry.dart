/// Pure geometry for the home-screen widget's net-worth sparkline: value
/// series → normalized polyline points. Kept out of the painter so the part
/// that can be wrong in interesting ways (normalization, degenerate series)
/// is unit-testable without rendering anything.
library;

/// Map [values] onto a `width`×`height` canvas, oldest→newest left→right,
/// larger values HIGHER (smaller y — canvas y grows downward).
///
/// [inset] keeps the stroke's cap/joins inside the bitmap: a polyline drawn
/// exactly to the edge clips half its stroke width off.
///
/// Degenerate series follow one rule — claim nothing you don't know:
/// * fewer than 2 points → empty (a dot is not a trend);
/// * all-equal values → a horizontal midline (a flat month IS a flat line,
///   not a divide-by-zero).
List<({double x, double y})> sparklinePoints(
  List<double> values, {
  required double width,
  required double height,
  double inset = 4.0,
}) {
  if (values.length < 2) return const [];
  var min = values.first;
  var max = values.first;
  for (final v in values) {
    if (v < min) min = v;
    if (v > max) max = v;
  }
  final span = max - min;
  final usableW = width - inset * 2;
  final usableH = height - inset * 2;
  final stepX = usableW / (values.length - 1);
  return [
    for (var i = 0; i < values.length; i++)
      (
        x: inset + stepX * i,
        y: span == 0
            ? height / 2
            : inset + usableH * (1 - (values[i] - min) / span),
      ),
  ];
}

/// Thin [values] to at most [maxPoints], always keeping the first and last.
///
/// The widget bitmap is ~600px wide; a year of daily history is 365 segments
/// of under 2px each — invisible detail at real cost (the render runs on
/// every dashboard load). Uniform stride sampling is enough for a glanceable
/// trend; this is explicitly NOT the chart the app draws.
List<double> thinSparkline(List<double> values, {int maxPoints = 60}) {
  assert(maxPoints >= 2, 'a sparkline needs at least its endpoints');
  if (values.length <= maxPoints) return values;
  final stride = (values.length - 1) / (maxPoints - 1);
  return [
    for (var i = 0; i < maxPoints - 1; i++) values[(i * stride).round()],
    values.last,
  ];
}
