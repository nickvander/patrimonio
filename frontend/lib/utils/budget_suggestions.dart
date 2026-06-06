import 'category.dart';

/// One proposed budget for a category, ready to show in the review dialog.
class BudgetSuggestion {
  /// Display label (already prettified, matching how the card groups spend).
  final String label;

  /// Suggested monthly budget in USD (trailing average rounded up to $10).
  final double amount;

  /// Trailing-average monthly spend in USD — used for ranking and to show
  /// "you've averaged $X" context next to the suggestion.
  final double monthlyAvg;

  const BudgetSuggestion(this.label, this.amount, this.monthlyAvg);
}

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
/// Each suggestion's [amount] is the trailing average rounded UP to the next
/// \$10 (USD, the storage unit) so the seeded number reads cleanly and leaves a
/// little headroom over the average. The list is sorted by trailing spend
/// descending, so the most material categories lead — the UI pre-selects the
/// top few and the user picks the rest, rather than dumping every category.
List<BudgetSuggestion> suggestBudgetsFromInsights({
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
  final out = <BudgetSuggestion>[];
  byLabel.forEach((label, avg) {
    if (existing.containsKey(label) || avg < 10.0) return;
    out.add(BudgetSuggestion(label, (avg / 10.0).ceil() * 10.0, avg));
  });
  out.sort((a, b) => b.monthlyAvg.compareTo(a.monthlyAvg));
  return out;
}
