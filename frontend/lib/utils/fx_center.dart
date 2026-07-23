/// Pure logic for the FX center sheet (opened from the app-bar USD/MXN
/// pill): the linked two-field converter math, extracted here so it can
/// be unit-tested independently of the widget (house rule: testable
/// business logic lives in utils/).
library;

/// Converts the text of one converter field into the text for its linked
/// sibling field.
///
/// - [input] is the raw text the user typed (digits + optional '.'; the
///   fields use the same `[0-9.]` input filter as the manual-rate dialog).
/// - [baseToTarget] true when the edited field holds the base (USD)
///   amount and the returned string is the target (MXN) amount.
///
/// Returns:
/// - `''` when [input] is empty/blank — the sibling clears too,
/// - `null` when [input] is not parseable or [rate] is not usable — the
///   sibling is left untouched (mid-typing states like "1." must not
///   wipe the other field),
/// - the converted amount with [decimals] fraction digits otherwise.
String? linkedFxAmount({
  required String input,
  required double rate,
  required bool baseToTarget,
  int decimals = 2,
}) {
  if (input.trim().isEmpty) return '';
  if (!rate.isFinite || rate <= 0) return null;
  final amount = double.tryParse(input.trim());
  if (amount == null || amount.isNegative) return null;
  final converted = baseToTarget ? amount * rate : amount / rate;
  return converted.toStringAsFixed(decimals);
}

/// Parses one raw `/fx/history` point (`{rate, timestamp}`) into the
/// chart-ready record shape `chart_time_axis` helpers consume. Returns
/// null for malformed rows so a single bad point can't kill the chart.
({DateTime date, double close})? fxHistoryPoint(dynamic raw) {
  if (raw is! Map) return null;
  final rate = (raw['rate'] as num?)?.toDouble();
  final ts = DateTime.tryParse((raw['timestamp'] ?? '').toString());
  if (rate == null || rate <= 0 || ts == null) return null;
  return (date: ts.toLocal(), close: rate);
}

/// The FX pair codes from a `/fx/latest` payload, tolerating both the
/// current (`base`/`target`) and legacy (`*_currency`) field names —
/// same parse the dashboard pill uses.
({String base, String target}) fxPairOf(Map<String, dynamic> latestRate) {
  final base =
      (latestRate['base'] ?? latestRate['base_currency'] ?? 'USD').toString();
  final target =
      (latestRate['target'] ?? latestRate['target_currency'] ?? 'MXN')
          .toString();
  return (base: base, target: target);
}
