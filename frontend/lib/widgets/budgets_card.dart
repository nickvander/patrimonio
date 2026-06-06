import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/preferences.dart';
import '../utils/budget_suggestions.dart';
import '../utils/category.dart';
import '../utils/theme_colors.dart';

/// "How much have I spent this month per budgeted category?" card.
///
/// Budgets live in [Preferences] (localStorage) — no backend schema yet.
/// Spend is derived client-side from the loaded `transactions` list,
/// filtered to the current month and grouped by prettified category.
class BudgetsCard extends StatefulWidget {
  final List<dynamic> transactions;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  /// When provided, budgets sync with the backend `app_settings` row.
  /// Without it the card falls back to localStorage-only.
  final ApiService? apiService;

  const BudgetsCard({
    super.key,
    required this.transactions,
    required this.conversionFactor,
    required this.currencyFormat,
    this.apiService,
  });

  @override
  State<BudgetsCard> createState() => _BudgetsCardState();
}

// How many suggestions start checked in the review dialog (the top N by spend).
const _kSuggestPreselect = 6;
// Budget rows shown before the list collapses behind a "show all" toggle.
const _kBudgetCollapseLimit = 6;

class _BudgetsCardState extends State<BudgetsCard> {
  // Seed from localStorage so first paint is instant. The backend value
  // (canonical) overrides this once the GET resolves.
  late Map<String, double> _budgets = Preferences.getBudgets();
  // Guards the "Suggest" action so a double-tap can't fire two fetches.
  bool _suggesting = false;
  // Expands the budget list past [_kBudgetCollapseLimit] rows.
  bool _showAllBudgets = false;

  @override
  void initState() {
    super.initState();
    _hydrateFromBackend();
  }

  Future<void> _hydrateFromBackend() async {
    final api = widget.apiService;
    if (api == null) return;
    try {
      final raw = await api.getSetting('budgets');
      if (!mounted || raw is! Map) return;
      final next = <String, double>{};
      raw.forEach((k, v) {
        final d = v is num ? v.toDouble() : double.tryParse('$v');
        if (d != null && d > 0) next[k.toString()] = d;
      });
      // Backend wins. Persist to localStorage so the next cold start is
      // still instant if the network is slow.
      setState(() => _budgets = next);
      Preferences.setBudgets(next);
    } catch (_) {
      // Network errors fall back silently to the localStorage seed.
    }
  }

  /// Suggest budgets from the user's trailing-average spend per category
  /// (GET /api/dashboard/spending-insights), then open a review dialog so the
  /// user picks which to add — the most material categories are pre-selected,
  /// the rest are theirs to opt into. Only unbudgeted categories are offered
  /// (existing budgets are never touched); each amount is the trailing average
  /// rounded up to the next $10. Keys are prettified the same way the card
  /// groups spend, so suggested rows track real spending.
  Future<void> _suggestBudgets() async {
    final api = widget.apiService;
    if (api == null || _suggesting) return;
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _suggesting = true);

    List<BudgetSuggestion> suggestions = const [];
    var months = 3;
    try {
      final data = await api.getSpendingInsights();
      months = (data['lookback'] as num?)?.toInt() ?? 3;
      final cats = data['categories'];
      suggestions = suggestBudgetsFromInsights(
        categories: cats is List ? cats : const [],
        existing: _budgets,
      );
    } catch (_) {
      // Leave suggestions empty → handled below.
    } finally {
      if (mounted) setState(() => _suggesting = false);
    }
    if (!mounted) return;
    if (suggestions.isEmpty) {
      messenger.showSnackBar(SnackBar(content: Text(l.cfBudgetsSuggestNone)));
      return;
    }

    final chosen = await _showSuggestDialog(suggestions, months);
    if (chosen == null || chosen.isEmpty) return;

    final next = {
      ..._budgets,
      for (final s in chosen) s.label: s.amount,
    };
    setState(() => _budgets = next);
    Preferences.setBudgets(next);
    // Fire-and-forget backend save; localStorage above is the cache.
    api.putSetting('budgets', next).catchError((_) {});
    messenger.showSnackBar(
      SnackBar(content: Text(l.cfBudgetsSuggestedSnack(chosen.length))),
    );
  }

  /// Review dialog for the suggestions. Returns the chosen subset, or null if
  /// the user cancelled. The top [_kSuggestPreselect] by spend start checked.
  Future<List<BudgetSuggestion>?> _showSuggestDialog(
    List<BudgetSuggestion> suggestions,
    int months,
  ) {
    final l = AppLocalizations.of(context);
    final selected = <String>{
      for (final s in suggestions.take(_kSuggestPreselect)) s.label,
    };

    return showDialog<List<BudgetSuggestion>>(
      context: context,
      builder: (dialogCtx) {
        return StatefulBuilder(
          builder: (dialogCtx, setLocal) {
            return AlertDialog(
              title: Text(l.cfBudgetsSuggestDialogTitle),
              content: SizedBox(
                width: 420,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l.cfBudgetsSuggestDialogSubtitle(months),
                      style: TextStyle(
                          fontSize: 12.5, color: context.textMuted),
                    ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => setLocal(() {
                          if (selected.length == suggestions.length) {
                            selected.clear();
                          } else {
                            selected
                              ..clear()
                              ..addAll(suggestions.map((s) => s.label));
                          }
                        }),
                        child: Text(selected.length == suggestions.length
                            ? l.cfBudgetsSuggestClear
                            : l.cfBudgetsSuggestSelectAll),
                      ),
                    ),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: suggestions.map((s) {
                          final checked = selected.contains(s.label);
                          return CheckboxListTile(
                            dense: true,
                            contentPadding: EdgeInsets.zero,
                            controlAffinity:
                                ListTileControlAffinity.leading,
                            value: checked,
                            onChanged: (v) => setLocal(() {
                              if (v == true) {
                                selected.add(s.label);
                              } else {
                                selected.remove(s.label);
                              }
                            }),
                            title: Text(s.label,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis),
                            subtitle: Text(
                              l.cfBudgetsSuggestAvg(widget.currencyFormat
                                  .format(s.monthlyAvg *
                                      widget.conversionFactor)),
                              style: TextStyle(
                                  fontSize: 11, color: context.textFaint),
                            ),
                            secondary: Text(
                              widget.currencyFormat.format(
                                  s.amount * widget.conversionFactor),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontFeatures: [
                                  FontFeature.tabularFigures()
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: Text(l.actionCancel),
                ),
                FilledButton(
                  onPressed: selected.isEmpty
                      ? null
                      : () => Navigator.pop(
                            dialogCtx,
                            suggestions
                                .where((s) => selected.contains(s.label))
                                .toList(),
                          ),
                  child: Text(l.cfBudgetsSuggestApply(selected.length)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  /// Sum positive-amount transactions in the current month by prettified
  /// category. Skips income (negative amounts) and pending rows.
  Map<String, double> _monthlySpendByCategory() {
    final out = <String, double>{};
    final now = DateTime.now();
    final monthStart = DateTime(now.year, now.month);
    for (final raw in widget.transactions) {
      final m = raw as Map;
      final ds = m['date']?.toString();
      if (ds == null) continue;
      final d = DateTime.tryParse(ds);
      if (d == null || d.isBefore(monthStart)) continue;
      final amount = (m['amount'] as num?)?.toDouble() ?? 0.0;
      if (amount <= 0) continue;
      final cat = prettyCategory(
        userCategory: m['user_category']?.toString(),
        detailed: m['category_detailed']?.toString(),
        primary: m['category']?.toString(),
      );
      out[cat] = (out[cat] ?? 0.0) + amount;
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final spend = _monthlySpendByCategory();
    final hasBudgets = _budgets.isNotEmpty;

    // Budget-vs-actual alert state: how many categories are over budget (and
    // by how much in total) vs merely approaching it (>85%).
    var overCount = 0;
    var overTotalUsd = 0.0;
    var nearCount = 0;
    for (final e in _budgets.entries) {
      final spent = spend[e.key] ?? 0.0;
      if (spent > e.value) {
        overCount++;
        overTotalUsd += spent - e.value;
      } else if (e.value > 0 && spent / e.value > 0.85) {
        nearCount++;
      }
    }

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.donut_small, color: context.tealAccent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.cfBudgetsTitle,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                if (widget.apiService != null)
                  Tooltip(
                    message: l.cfBudgetsSuggestTooltip,
                    child: TextButton.icon(
                      onPressed: _suggesting ? null : _suggestBudgets,
                      icon: _suggesting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_fix_high, size: 16),
                      label: Text(l.cfBudgetsSuggest),
                    ),
                  ),
                TextButton.icon(
                  onPressed: () => _openEditor(spend),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: Text(hasBudgets ? l.cfBudgetsEdit : l.actionAdd),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (hasBudgets && (overCount > 0 || nearCount > 0)) ...[
              _alertBanner(context, l, overCount, overTotalUsd, nearCount),
              const SizedBox(height: 12),
            ],
            if (!hasBudgets)
              Text(
                l.cfBudgetsEmpty,
                style: TextStyle(color: context.textMuted, fontSize: 13),
              )
            else ...[
              ...(_showAllBudgets
                      ? _budgets.entries
                      : _budgets.entries.take(_kBudgetCollapseLimit))
                  .map((e) {
                final cat = e.key;
                final budgetUsd = e.value;
                final spentUsd = spend[cat] ?? 0.0;
                final pct =
                    budgetUsd <= 0 ? 0.0 : (spentUsd / budgetUsd).clamp(0.0, 1.5);
                final over = spentUsd > budgetUsd;
                final color = over
                    ? context.pinkAccent
                    : pct > 0.85
                        ? context.warning
                        : context.positive;
                return Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              cat,
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          // Spent/budget pair can be a 20+ char string at
                          // long currency values; clamp + ellipsise so a
                          // phone-width card doesn't crowd the category
                          // out to a single character.
                          Flexible(
                            child: Text(
                              '${widget.currencyFormat.format(spentUsd * widget.conversionFactor)} '
                              '/ ${widget.currencyFormat.format(budgetUsd * widget.conversionFactor)}',
                              style: TextStyle(
                                fontSize: 12,
                                color: color,
                                fontWeight: FontWeight.w700,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.end,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 6),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: pct > 1.0 ? 1.0 : pct,
                          backgroundColor: context.tileSurface,
                          color: color,
                          minHeight: 8,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        over
                            ? l.cfBudgetsOverBy(widget.currencyFormat.format(
                                (spentUsd - budgetUsd) *
                                    widget.conversionFactor))
                            : l.cfBudgetsLeft(widget.currencyFormat.format(
                                (budgetUsd - spentUsd).clamp(0, double.infinity) *
                                    widget.conversionFactor)),
                        style: TextStyle(
                          fontSize: 10,
                          color: over ? context.pinkAccent : context.textFaint,
                        ),
                      ),
                    ],
                  ),
                );
              }),
              // Collapse a long budget list so the card doesn't dominate the
              // cash-flow tab — show the first few, with a toggle for the rest.
              if (_budgets.length > _kBudgetCollapseLimit)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () =>
                        setState(() => _showAllBudgets = !_showAllBudgets),
                    child: Text(_showAllBudgets
                        ? l.cfBudgetsShowFewer
                        : l.cfBudgetsShowAll(
                            _budgets.length - _kBudgetCollapseLimit)),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // Prominent budget-vs-actual alert. Red when any category is over budget
  // (with the total overage), amber when categories are merely approaching it.
  Widget _alertBanner(
    BuildContext context,
    AppLocalizations l,
    int overCount,
    double overTotalUsd,
    int nearCount,
  ) {
    final isOver = overCount > 0;
    final color = isOver ? context.pinkAccent : context.warning;
    final text = isOver
        ? l.cfBudgetsOverAlert(
            overCount,
            widget.currencyFormat
                .format(overTotalUsd * widget.conversionFactor),
          )
        : l.cfBudgetsNearAlert(nearCount);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(isOver ? Icons.warning_amber_rounded : Icons.info_outline,
              color: color, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _openEditor(Map<String, double> spend) async {
    final l = AppLocalizations.of(context);
    final categories = <String>{
      ..._budgets.keys,
      ...spend.keys,
    }.toList()
      ..sort();
    final controllers = <String, TextEditingController>{};
    for (final c in categories) {
      controllers[c] = TextEditingController(
        text: _budgets[c] == null
            ? ''
            : (_budgets[c]! * widget.conversionFactor).toInt().toString(),
      );
    }

    final saved = await showDialog<bool>(
      context: context,
      builder: (_) {
        return AlertDialog(
          title: Text(l.cfBudgetsDialogTitle),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Expanded(
                  child: ListView(
                    shrinkWrap: true,
                    children: categories.map((c) {
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(child: Text(c)),
                            SizedBox(
                              width: 120,
                              child: TextField(
                                controller: controllers[c],
                                keyboardType: TextInputType.number,
                                decoration: InputDecoration(
                                  prefixText: widget
                                      .currencyFormat.currencySymbol,
                                  hintText: '0',
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(l.actionCancel)),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: Text(l.actionSave)),
          ],
        );
      },
    );

    if (saved != true) return;
    final next = <String, double>{};
    controllers.forEach((cat, ctrl) {
      final reported = double.tryParse(ctrl.text);
      if (reported != null && reported > 0) {
        // Store in USD (backend storage unit); divide out the conversion
        // factor used in display.
        final usd = widget.conversionFactor == 0
            ? reported
            : reported / widget.conversionFactor;
        next[cat] = usd;
      }
    });
    setState(() => _budgets = next);
    Preferences.setBudgets(next);
    // Fire-and-forget backend save; the localStorage write above is the
    // authoritative cache if the network call fails.
    widget.apiService?.putSetting('budgets', next).catchError((_) {});
  }
}
