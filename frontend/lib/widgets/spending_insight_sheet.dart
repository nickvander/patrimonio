import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/preferences.dart';
import '../utils/budget_suggestions.dart';
import '../utils/month_window.dart';
import '../utils/percent_format.dart';
import '../utils/spending_insight.dart';
import '../utils/theme_colors.dart';

/// Spending-spike drill-down sheet, opened by tapping a spending-spike
/// bell row (context-first: the sheet answers "why did this spike?" in
/// place — recent vs average, per-month trend, top merchants — with the
/// raw filtered list one CTA away via [onSeeTransactions]).
///
/// The trend and merchant sections derive client-side from the
/// dashboard's already-loaded transactions — no new endpoint — so they
/// honestly cover only the loaded pages (the merchant empty state says
/// so).
Future<void> showSpendingInsightSheet(
  BuildContext context, {
  required SpendingSpikeInsight insight,
  required List<dynamic> transactions,
  required NumberFormat currencyFormat,
  required double conversionFactor,
  required String targetCurrency,
  required double usdMxnRate,
  required VoidCallback onSeeTransactions,
  ApiService? apiService,
  @visibleForTesting Map<String, double>? budgetsOverride,
  @visibleForTesting
  Future<void> Function(String key, dynamic value)? putSettingOverride,
}) {
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    // M3 sheets center at maxWidth on wide viewports, so one host works
    // phone AND desktop web (the notifications-sheet idiom).
    constraints: const BoxConstraints(maxWidth: 560),
    builder: (sheetCtx) => SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.85,
        ),
        child: SpendingInsightSheet(
          insight: insight,
          transactions: transactions,
          currencyFormat: currencyFormat,
          conversionFactor: conversionFactor,
          targetCurrency: targetCurrency,
          usdMxnRate: usdMxnRate,
          onSeeTransactions: onSeeTransactions,
          apiService: apiService,
          budgetsOverride: budgetsOverride,
          putSettingOverride: putSettingOverride,
        ),
      ),
    ),
  );
}

/// Sheet body. Public so widget tests can pump it via
/// [showSpendingInsightSheet] with injected data; all inputs are plain
/// values + callbacks (cards-are-dumb rule).
class SpendingInsightSheet extends StatefulWidget {
  final SpendingSpikeInsight insight;
  final List<dynamic> transactions;
  final NumberFormat currencyFormat;
  final double conversionFactor;
  final String targetCurrency;
  final double usdMxnRate;

  /// "See all transactions" CTA: the dashboard performs the P0 seeding
  /// (category + month window + banner payload) and switches tabs. The
  /// sheet pops itself first.
  final VoidCallback onSeeTransactions;

  /// Budget persistence backend. The sheet writes through the exact path
  /// the budgets card uses (Preferences.setBudgets + putSetting
  /// 'budgets'); null falls back to localStorage-only, same as the card.
  final ApiService? apiService;

  /// Test seam: the Preferences store is inert on the test VM (the io
  /// backend is gated behind main()'s init), so tests inject the
  /// "existing budgets" map here; null in production reads Preferences.
  @visibleForTesting
  final Map<String, double>? budgetsOverride;

  /// Test seam for the backend save (widget tests don't subclass
  /// ApiService); null in production uses [apiService].putSetting.
  @visibleForTesting
  final Future<void> Function(String key, dynamic value)? putSettingOverride;

  const SpendingInsightSheet({
    super.key,
    required this.insight,
    required this.transactions,
    required this.currencyFormat,
    required this.conversionFactor,
    required this.targetCurrency,
    required this.usdMxnRate,
    required this.onSeeTransactions,
    this.apiService,
    this.budgetsOverride,
    this.putSettingOverride,
  });

  @override
  State<SpendingInsightSheet> createState() => _SpendingInsightSheetState();
}

class _SpendingInsightSheetState extends State<SpendingInsightSheet> {
  /// Existing budgets, keyed by prettified label in USD — the budgets-card
  /// store. Refreshed after a save so the CTA flips Set → Update in place.
  late Map<String, double> _budgets =
      widget.budgetsOverride ?? Preferences.getBudgets();

  /// Number of trend buckets in the mini chart.
  static const int _trendMonths = 6;

  String _money(double usd) =>
      widget.currencyFormat.format(usd * widget.conversionFactor);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final locale = Localizations.localeOf(context).toString();
    final insight = widget.insight;

    // A malformed/absent recent_month (older server) degrades to the
    // current calendar month for the header label and trend window — the
    // sheet still explains the category, it just can't pin the month.
    final window = monthWindow(insight.recentMonth);
    final now = DateTime.now();
    final endMonth = window?.start ?? DateTime(now.year, now.month);
    final monthLabel = DateFormat.yMMMM(locale).format(endMonth);

    final buckets = monthlyCategorySpendUsd(
      widget.transactions,
      categoryLabel: insight.categoryLabel,
      usdMxnRate: widget.usdMxnRate,
      endMonth: endMonth,
      months: _trendMonths,
    );
    final merchants = topMerchantsForCategoryMonth(
      widget.transactions,
      categoryLabel: insight.categoryLabel,
      month: insight.recentMonth,
      usdMxnRate: widget.usdMxnRate,
    );

    final deltaUsd = insight.recentUsd - insight.previousAvgUsd;
    final hasBudget = _budgets.containsKey(insight.categoryLabel);

    return LayoutBuilder(
      builder: (context, outer) {
        final isNarrow = outer.maxWidth < 420;
        final pad = isNarrow ? 16.0 : 24.0;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(pad, 0, pad, pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 1 · Header — category + localized month.
              Text(
                insight.categoryLabel,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: context.textPrimary,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                monthLabel,
                style: TextStyle(fontSize: 13, color: context.textMuted),
              ),
              const SizedBox(height: 16),
              // 2 · Stat block — recent vs previous-average, then the
              // delta line in warning (it IS the alert being explained).
              Wrap(
                spacing: 32,
                runSpacing: 12,
                children: [
                  _stat(
                    l.cfInsightRecentLabel(monthLabel),
                    _money(insight.recentUsd),
                  ),
                  _stat(
                    l.cfInsightAvgLabel(insight.lookbackMonths),
                    _money(insight.previousAvgUsd),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                // gen-l10n orders these alphabetically → (amount, percent).
                l.cfInsightDelta(
                  _money(deltaUsd),
                  formatPercent(context, insight.pctIncrease, digits: 0),
                ),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: context.warning,
                ),
              ),
              const SizedBox(height: 20),
              // 3 · Mini per-month trend, derived from the loaded pages.
              Text(
                l.cfInsightTrendTitle(_trendMonths),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: context.textSubtle,
                ),
              ),
              const SizedBox(height: 8),
              _trendChart(context, l, locale, buckets),
              const SizedBox(height: 20),
              // 4 · Top merchants that month (client-side, loaded pages).
              Text(
                l.cfInsightTopMerchantsTitle(monthLabel),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: context.textSubtle,
                ),
              ),
              const SizedBox(height: 4),
              if (merchants.isEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    l.cfInsightNoMerchantData,
                    style: TextStyle(fontSize: 13, color: context.textMuted),
                  ),
                )
              else
                ...merchants.map(
                  (m) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      m.merchant,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    subtitle: Text(
                      l.cfInsightMerchantTxCount(m.count),
                      style: TextStyle(
                        fontSize: 11.5,
                        color: context.textFaint,
                      ),
                    ),
                    trailing: Text(
                      _money(m.totalUsd),
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              // 5 · CTAs. Wrap so a phone stacks them instead of clipping.
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: () {
                      // Pop first so the tab switch never races the
                      // sheet's own dismissal route.
                      Navigator.of(context).pop();
                      widget.onSeeTransactions();
                    },
                    icon: const Icon(Icons.receipt_long, size: 18),
                    label: Text(l.cfInsightSeeTransactions),
                  ),
                  OutlinedButton.icon(
                    onPressed: _openBudgetDialog,
                    icon: const Icon(Icons.donut_small, size: 18),
                    label: Text(
                      hasBudget
                          ? l.cfInsightUpdateBudget
                          : l.cfInsightSetBudget,
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _stat(String label, String value) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label, style: TextStyle(fontSize: 12, color: context.textSubtle)),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: context.textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }

  /// Mini bar chart of the trailing months. Buckets are CONTIGUOUS and
  /// zero-filled (see monthlyCategorySpendUsd), so index-x bars hide no
  /// gaps. The canvas is pointer-invisible to screen readers; the data is
  /// mirrored as a one-line summary on the container plus an invisible
  /// in-tree per-month list (the trends-chart idiom).
  Widget _trendChart(
    BuildContext context,
    AppLocalizations l,
    String locale,
    List<({DateTime monthStart, double totalUsd})> buckets,
  ) {
    final maxY = buckets.fold(0.0, (m, b) => math.max(m, b.totalUsd));
    return SizedBox(
      height: 140,
      child: LayoutBuilder(
        builder: (context, c) {
          final slot = c.maxWidth / buckets.length;
          // ~1 label per 46px of bar slot; always keep the last (the
          // insight's own month).
          final step = slot <= 0 ? 1 : math.max(1, (46 / slot).ceil());
          final barWidth = math.min(28.0, slot * 0.55);
          return Semantics(
            container: true,
            // gen-l10n orders these alphabetically → (category, months).
            label: l.cfInsightTrendSemantics(
              widget.insight.categoryLabel,
              buckets.length,
            ),
            child: Stack(
              children: [
                ExcludeSemantics(
                  child: BarChart(
                    BarChartData(
                      // Flat-zero data still needs a positive maxY or
                      // fl_chart draws a degenerate axis.
                      maxY: maxY <= 0 ? 1 : maxY * 1.1,
                      barTouchData: BarTouchData(enabled: false),
                      gridData: const FlGridData(show: false),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        leftTitles: const AxisTitles(),
                        rightTitles: const AxisTitles(),
                        topTitles: const AxisTitles(),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 22,
                            getTitlesWidget: (value, meta) {
                              final i = value.toInt();
                              if (i < 0 || i >= buckets.length) {
                                return const SizedBox.shrink();
                              }
                              final isLast = i == buckets.length - 1;
                              if (!isLast && i % step != 0) {
                                return const SizedBox.shrink();
                              }
                              return SideTitleWidget(
                                meta: meta,
                                child: Text(
                                  DateFormat.MMM(
                                    locale,
                                  ).format(buckets[i].monthStart),
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: context.textSubtle,
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      barGroups: [
                        for (var i = 0; i < buckets.length; i++)
                          BarChartGroupData(
                            x: i,
                            barRods: [
                              BarChartRodData(
                                toY: buckets[i].totalUsd,
                                width: barWidth,
                                borderRadius: BorderRadius.circular(4),
                                // The insight's month is the alert; the
                                // rest are baseline context.
                                color: i == buckets.length - 1
                                    ? context.warning
                                    : context.chartSeries(0),
                              ),
                            ],
                          ),
                      ],
                    ),
                  ),
                ),
                // Invisible but in the semantic tree: per-month values —
                // an interpolation of two already-localized strings, so
                // no extra l10n key is needed.
                Positioned.fill(
                  child: IgnorePointer(
                    child: Opacity(
                      opacity: 0.0,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (final b in buckets)
                            Semantics(
                              label:
                                  '${DateFormat.yMMMM(locale).format(b.monthStart)}: ${_money(b.totalUsd)}',
                              child: const SizedBox(
                                width: double.infinity,
                                height: 2,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Single-field budget dialog, prefilled from the trailing average
  /// rounded up to the next $10 (an existing budget wins), shown in the
  /// display currency. Saving merges into the budgets map and persists
  /// through the budgets-card path: Preferences.setBudgets (localStorage
  /// cache) + putSetting('budgets') (canonical backend copy). BudgetsCard
  /// hydrates from this same store on init, so the new budget appears the
  /// next time the card builds — no live push needed.
  Future<void> _openBudgetDialog() async {
    final messenger = ScaffoldMessenger.of(context);
    final l = AppLocalizations.of(context);
    final insight = widget.insight;
    final existingUsd = _budgets[insight.categoryLabel];
    final prefillUsd =
        existingUsd ?? roundBudgetUpToTen(insight.trailingAvgUsd);

    // The dialog owns its TextEditingController (created and disposed in
    // _BudgetDialogState) so it can't be used-after-dispose while the
    // dialog's exit transition is still animating, and it can't leak on
    // cancel either — the budgets-card _openEditor leak lesson, upgraded.
    final entered = await showDialog<String>(
      context: context,
      builder: (_) => _BudgetDialog(
        categoryLabel: insight.categoryLabel,
        lookbackMonths: insight.lookbackMonths,
        prefill: (prefillUsd * widget.conversionFactor).toInt().toString(),
        prefixText: widget.currencyFormat.currencySymbol,
      ),
    );

    if (entered == null || !mounted) return;
    final reported = double.tryParse(entered);
    if (reported == null || reported <= 0) return;
    // Store in USD (the backend storage unit); divide out the display
    // conversion, guarding a zero factor like budgets_card does.
    final usd = widget.conversionFactor == 0
        ? reported
        : reported / widget.conversionFactor;
    final next = {..._budgets, insight.categoryLabel: usd};
    setState(() => _budgets = next);
    Preferences.setBudgets(next);
    // Fire-and-forget backend save; localStorage above is the cache.
    if (widget.putSettingOverride != null) {
      widget.putSettingOverride!('budgets', next).catchError((_) {});
    } else {
      widget.apiService?.putSetting('budgets', next).catchError((_) {});
    }
    messenger.showSnackBar(
      SnackBar(
        // gen-l10n orders these alphabetically → (amount, category).
        content: Text(
          l.cfInsightBudgetSaved(
            widget.currencyFormat.format(usd * widget.conversionFactor),
            insight.categoryLabel,
          ),
        ),
      ),
    );
  }
}

/// Single-field budget editor dialog. Pops the entered text on Save,
/// null on Cancel; owning the controller here (disposed in [dispose])
/// keeps it alive through the dialog's exit animation and guarantees
/// disposal on both paths.
class _BudgetDialog extends StatefulWidget {
  final String categoryLabel;
  final int lookbackMonths;
  final String prefill;
  final String prefixText;

  const _BudgetDialog({
    required this.categoryLabel,
    required this.lookbackMonths,
    required this.prefill,
    required this.prefixText,
  });

  @override
  State<_BudgetDialog> createState() => _BudgetDialogState();
}

class _BudgetDialogState extends State<_BudgetDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.prefill,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.cfInsightBudgetDialogTitle(widget.categoryLabel)),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            controller: _controller,
            autofocus: true,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              prefixText: widget.prefixText,
              hintText: '0',
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l.cfInsightBudgetDialogHint(widget.lookbackMonths),
            style: TextStyle(fontSize: 12, color: context.textMuted),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(l.actionSave),
        ),
      ],
    );
  }
}
