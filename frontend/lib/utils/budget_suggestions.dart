import 'category.dart';

/// Build budget suggestions from a `/dashboard/spending-insights` `categories`
/// list. Pure (no I/O) so it's unit-testable independent of the widget and the
/// ApiService.
///
/// For each category group it prettifies the label the same way the budgets
/// card groups spend (so suggested rows track real spending), aggregates the
/// trailing average across groups that map to the same label, then returns one
/// suggestion per label that:
///   * isn't already in [existing] (existing budgets are never overwritten),
///   * has at least \$10 of typical spend, and
///   * isn't an uninformative bucket (Uncategorized / Other).
///
/// Each suggestion is the trailing average rounded UP to the next \$10 (USD,
/// the storage unit) so the seeded number reads cleanly and leaves a little
/// headroom over the average. Amounts in [existing] and the returned map are
/// USD, matching the budgets app_setting storage convention.
Map<String, double> suggestBudgetsFromInsights({
  required List<dynamic> categories,
  required Map<String, double> existing,
}) {
  // Codes with no single actionable merchant/behaviour behind them — not
  // worth seeding a budget for.
  const skip = {'UNCATEGORIZED', 'OTHER', 'OTHER_OTHER'};
  final byLabel = <String, double>{};
  for (final raw in categories) {
    if (raw is! Map) continue;
    final avg = (raw['trailing_avg'] as num?)?.toDouble() ?? 0.0;
    if (avg <= 0) continue;
    final code = (raw['user_category'] ??
            raw['category_detailed'] ??
            raw['category'] ??
            '')
        .toString()
        .trim()
        .toUpperCase();
    if (skip.contains(code)) continue;
    final label = prettyCategory(
      userCategory: raw['user_category']?.toString(),
      detailed: raw['category_detailed']?.toString(),
      primary: raw['category']?.toString(),
    );
    byLabel[label] = (byLabel[label] ?? 0.0) + avg;
  }
  final additions = <String, double>{};
  byLabel.forEach((label, avg) {
    if (existing.containsKey(label) || avg < 10.0) return;
    additions[label] = (avg / 10.0).ceil() * 10.0;
  });
  return additions;
}
