import 'category.dart';
import 'currency.dart';
import 'month_window.dart';

/// One spending-spike insight from GET /api/dashboard/spending-insights,
/// carried whole from the bell row that surfaced it through every P1
/// surface (the insight detail sheet, the transactions-tab comparison
/// banner) so each renders the SAME figures the row alerted on — no
/// re-derivation, no drift.
class SpendingSpikeInsight {
  /// PRETTIFIED category label — the same string the bell row displayed,
  /// which is what `TxFilters.categories` matches against AND how budgets
  /// are keyed. Never the raw uppercased Plaid code (that would silently
  /// filter to zero rows and orphan the budget).
  final String categoryLabel;

  /// The insight's month, 'YYYY-MM' from the payload's `recent_month`.
  /// May be '' when an older server omitted it — consumers degrade via
  /// [monthWindow]'s null return, never crash.
  final String recentMonth;

  /// Payload `recent`: the category's spend in [recentMonth], USD.
  final double recentUsd;

  /// Payload `previous_avg`: the N-month average EXCLUDING the recent
  /// month — the comparison number the banner and sheet quote.
  final double previousAvgUsd;

  /// Payload `trailing_avg`: the N-month average INCLUDING the recent
  /// month — the budget-prefill number, matching what
  /// `suggestBudgetsFromInsights` (budget_suggestions.dart) seeds from.
  final double trailingAvgUsd;

  /// Payload `lookback`: N, the number of months behind the averages.
  final int lookbackMonths;

  const SpendingSpikeInsight({
    required this.categoryLabel,
    required this.recentMonth,
    required this.recentUsd,
    required this.previousAvgUsd,
    required this.trailingAvgUsd,
    required this.lookbackMonths,
  });

  /// Percentage increase of the recent month over the previous average,
  /// as a percentage NUMBER (45.0 == +45%) ready for `formatPercent`.
  /// Zero-guard: a zero/negative baseline has no meaningful "+X%".
  double get pctIncrease => previousAvgUsd > 0
      ? (recentUsd - previousAvgUsd) / previousAvgUsd * 100
      : 0;
}

/// Whether a transaction row counts as budgetable SPEND — the exclusion
/// predicate extracted from the budgets card so the insight sheet's trend
/// and the card's per-category totals can never disagree.
///
/// Mirrors the backend cash-flow exclusions (dashboard.rs): an internal
/// transfer, an investment buy, or a credit-card payment is not spending.
/// Honors a user re-categorization the same way the backend does
/// (user_category overrides the raw one). Pending rows are skipped
/// (they can still change/vanish), as is income (storage sign convention,
/// backend sync.rs:659: negative = outflow, positive = inflow).
bool isBudgetableSpend(Map tx) {
  if (tx['pending'] == true) return false;
  final amount = (tx['amount'] as num?)?.toDouble() ?? 0.0;
  if (amount >= 0) return false;
  final userCat = tx['user_category']?.toString().trim() ?? '';
  final effCat =
      (userCat.isNotEmpty ? userCat : (tx['category']?.toString() ?? ''))
          .toUpperCase();
  if (effCat == 'TRANSFER_IN' ||
      effCat == 'TRANSFER_OUT' ||
      effCat == 'TRANSFER' ||
      effCat == 'INVESTMENT') {
    return false;
  }
  if ((tx['category_detailed']?.toString() ?? '') ==
      'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT') {
    return false;
  }
  return true;
}

/// Per-month USD spend for one prettified category over the trailing
/// [months] calendar months ending at [endMonth] (year+month read; day
/// ignored).
///
/// Returns EXACTLY [months] CONTIGUOUS buckets, zero-filled for months
/// with no matching rows — the mini trend chart draws index-x bars, so a
/// missing bucket would silently hide a gap (the index-as-x trap from the
/// house chart rules). Each row is converted native→USD per-row via
/// [convertCurrency] before summing (never sum raw mixed-currency
/// amounts), and filtered through [isBudgetableSpend] so the trend agrees
/// with the budgets card.
List<({DateTime monthStart, double totalUsd})> monthlyCategorySpendUsd(
  List<dynamic> transactions, {
  required String categoryLabel,
  required double usdMxnRate,
  required DateTime endMonth,
  int months = 6,
}) {
  final end = DateTime(endMonth.year, endMonth.month);
  final first = DateTime(end.year, end.month - (months - 1));
  final totals = List<double>.filled(months, 0.0);
  for (final raw in transactions) {
    if (raw is! Map) continue;
    if (!isBudgetableSpend(raw)) continue;
    final d = DateTime.tryParse(raw['date']?.toString() ?? '');
    if (d == null) continue;
    final idx = (d.year - first.year) * 12 + (d.month - first.month);
    if (idx < 0 || idx >= months) continue;
    final label = prettyCategory(
      userCategory: raw['user_category']?.toString(),
      detailed: raw['category_detailed']?.toString(),
      primary: raw['category']?.toString(),
    );
    if (label != categoryLabel) continue;
    final amount = (raw['amount'] as num?)?.toDouble() ?? 0.0;
    totals[idx] += convertCurrency(
      amount.abs(),
      from: (raw['currency'] ?? 'USD').toString(),
      to: 'USD',
      usdMxnRate: usdMxnRate,
    );
  }
  return [
    for (var i = 0; i < months; i++)
      (monthStart: DateTime(first.year, first.month + i), totalUsd: totals[i]),
  ];
}

/// Top merchants for one prettified category in one 'YYYY-MM' [month],
/// ranked by USD total descending, capped at [limit].
///
/// Grouping key is the merchant name, falling back to the bank
/// description when Plaid didn't resolve a merchant — same fallback the
/// transaction rows display. Rows pass [isBudgetableSpend] and the same
/// per-row FX conversion as [monthlyCategorySpendUsd]. A malformed
/// [month] returns an empty list (older-server degrade, per
/// [monthWindow]).
List<({String merchant, double totalUsd, int count})>
topMerchantsForCategoryMonth(
  List<dynamic> transactions, {
  required String categoryLabel,
  required String month,
  required double usdMxnRate,
  int limit = 5,
}) {
  final window = monthWindow(month);
  if (window == null) return const [];
  final totals = <String, double>{};
  final counts = <String, int>{};
  for (final raw in transactions) {
    if (raw is! Map) continue;
    if (!isBudgetableSpend(raw)) continue;
    final d = DateTime.tryParse(raw['date']?.toString() ?? '');
    if (d == null || d.isBefore(window.start) || d.isAfter(window.end)) {
      continue;
    }
    final label = prettyCategory(
      userCategory: raw['user_category']?.toString(),
      detailed: raw['category_detailed']?.toString(),
      primary: raw['category']?.toString(),
    );
    if (label != categoryLabel) continue;
    final merchantRaw = raw['merchant_name']?.toString().trim() ?? '';
    final merchant = merchantRaw.isNotEmpty
        ? merchantRaw
        : (raw['description'] ?? '').toString().trim();
    if (merchant.isEmpty) continue;
    final amount = (raw['amount'] as num?)?.toDouble() ?? 0.0;
    totals[merchant] =
        (totals[merchant] ?? 0.0) +
        convertCurrency(
          amount.abs(),
          from: (raw['currency'] ?? 'USD').toString(),
          to: 'USD',
          usdMxnRate: usdMxnRate,
        );
    counts[merchant] = (counts[merchant] ?? 0) + 1;
  }
  final out = [
    for (final m in totals.keys)
      (merchant: m, totalUsd: totals[m]!, count: counts[m]!),
  ]..sort((a, b) => b.totalUsd.compareTo(a.totalUsd));
  return out.take(limit).toList();
}
