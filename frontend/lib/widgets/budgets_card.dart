import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/preferences.dart';
import '../utils/budget_suggestions.dart';
import '../utils/category.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';

/// "How much have I spent this month per budgeted category?" card.
///
/// Budgets live in [Preferences] (localStorage) — no backend schema yet.
/// Spend is derived client-side from the loaded `transactions` list,
/// filtered to the current month and grouped by prettified category.
class BudgetsCard extends StatefulWidget {
  final List<dynamic> transactions;
  final double conversionFactor;
  /// USD<->MXN spot rate. Budgets are stored in USD, but transactions carry
  /// their native currency, so spend must be normalised to USD before it can
  /// be compared against a budget. `conversionFactor` can't do this (it's 1.0
  /// for USD-display users even when their transactions are in MXN).
  final double usdMxnRate;
  final NumberFormat currencyFormat;
  /// When provided, budgets sync with the backend `app_settings` row.
  /// Without it the card falls back to localStorage-only.
  final ApiService? apiService;

  /// The single month to price budgets against (item #11). Budgets are MONTHLY
  /// targets, so a multi-month cash-flow window (3mo/YTD) is compared to its
  /// MOST RECENT single month — never a sum/average across months. Any day in
  /// the target month works; only year+month are read. Defaults to the current
  /// month (today) when absent, preserving the pre-#11 behavior.
  final DateTime? periodMonth;

  const BudgetsCard({
    super.key,
    required this.transactions,
    required this.conversionFactor,
    required this.usdMxnRate,
    required this.currencyFormat,
    this.apiService,
    this.periodMonth,
  });

  @override
  State<BudgetsCard> createState() => _BudgetsCardState();
}

// How many suggestions start checked in the review dialog (the top N by spend).
const _kSuggestPreselect = 6;
// Budget rows shown before the list collapses behind a "show all" toggle.
const _kBudgetCollapseLimit = 6;
// Spend must exceed this multiple of the prorated expected-to-date budget to
// count as "on track to exceed" — tolerates normal early-month lumpiness.
const _kPaceTolerance = 1.15;

// Per-category budget tier, worst-first in severity. `pacing` ("on track to
// exceed") sits between `near` and `ok`: under the full-month budget, but
// running ahead of the prorated expected-to-date threshold.
enum _BudgetState { over, near, pacing, ok }

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
                                  .displayMoney(s.monthlyAvg *
                                      widget.conversionFactor)),
                              style: TextStyle(
                                  fontSize: 11, color: context.textFaint),
                            ),
                            secondary: Text(
                              widget.currencyFormat.displayMoney(
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

  /// The single month budgets are priced against. Item #11 threads the
  /// most-recent month of the selected cash-flow window in via
  /// [BudgetsCard.periodMonth]; absent it (and pre-#11) this is the current
  /// month. Normalised to a first-of-month DateTime — only year+month matter.
  DateTime get _targetMonthStart {
    final m = widget.periodMonth ?? DateTime.now();
    return DateTime(m.year, m.month);
  }

  /// True only when the priced month IS the current calendar month. Day-of-
  /// month pacing (#10) is meaningless for a fully-elapsed past month, so it's
  /// gated to this (item #11): a closed month is judged on full-month spend.
  bool get _isCurrentMonth {
    final now = DateTime.now();
    final t = _targetMonthStart;
    return t.year == now.year && t.month == now.month;
  }

  /// Sum outflow transactions in the priced month ([_targetMonthStart]) by
  /// prettified category, normalised to USD (the unit budgets are stored in).
  /// Storage sign convention (backend sync.rs:659): negative = outflow,
  /// positive = inflow — so spend is the negative rows, summed as their
  /// absolute value. Skips income (positive amounts) and pending rows.
  ///
  /// Budgets are MONTHLY targets, so even for a multi-month cash-flow window
  /// this scopes to a SINGLE month (the window's most recent) — never summing
  /// or averaging a monthly target across months.
  Map<String, double> _monthlySpendByCategory() {
    final out = <String, double>{};
    final monthStart = _targetMonthStart;
    // Exclusive upper bound: first day of the month after the priced month.
    final monthEnd = DateTime(monthStart.year, monthStart.month + 1);
    for (final raw in widget.transactions) {
      final m = raw as Map;
      if (m['pending'] == true) continue;
      final ds = m['date']?.toString();
      if (ds == null) continue;
      final d = DateTime.tryParse(ds);
      if (d == null || d.isBefore(monthStart) || !d.isBefore(monthEnd)) {
        continue;
      }
      final amount = (m['amount'] as num?)?.toDouble() ?? 0.0;
      if (amount >= 0) continue;
      // Mirror the backend cash-flow exclusions (dashboard.rs): an internal
      // transfer, an investment buy, or a credit-card payment is not spending,
      // so it must not eat into a budget. Honor a user re-categorization the
      // same way the backend now does (user_category overrides the raw one).
      // (The rarer loan-leg / FX-pair anti-joins need server-side data; those
      // would require driving this card off the /spending-by-category endpoint.)
      final userCat = m['user_category']?.toString().trim() ?? '';
      final effCat =
          (userCat.isNotEmpty ? userCat : (m['category']?.toString() ?? ''))
              .toUpperCase();
      if (effCat == 'TRANSFER_IN' ||
          effCat == 'TRANSFER_OUT' ||
          effCat == 'TRANSFER' ||
          effCat == 'INVESTMENT') {
        continue;
      }
      if ((m['category_detailed']?.toString() ?? '') ==
          'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT') {
        continue;
      }
      // Budgets are USD; convert each row from its native currency so a
      // MXN grocery run isn't compared 1:1 against a USD budget.
      final spentUsd = convertCurrency(
        amount.abs(),
        from: (m['currency'] ?? 'USD').toString(),
        to: 'USD',
        usdMxnRate: widget.usdMxnRate,
      );
      final cat = prettyCategory(
        userCategory: m['user_category']?.toString(),
        detailed: m['category_detailed']?.toString(),
        primary: m['category']?.toString(),
      );
      out[cat] = (out[cat] ?? 0.0) + spentUsd;
    }
    return out;
  }

  // How far through the priced month we are, as a fraction in (0, 1].
  // Drives the prorated expected-to-date budget threshold. Item #11: pacing
  // only makes sense for the in-progress current month — a closed past month
  // (3mo/YTD windows price against a fully-elapsed month) returns 1.0 so the
  // expected-to-date equals the full-month budget and the pacing tier can't
  // fire. The pace marker is also hidden for non-current months below.
  double _monthPaceFraction() {
    if (!_isCurrentMonth) return 1.0;
    final now = DateTime.now();
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    return (now.day / daysInMonth).clamp(0.0, 1.0);
  }

  // Spend-vs-budget state for a single category. `_BudgetState.pacing` is the
  // new "on track to exceed" tier: not yet over the full-month budget, but
  // running materially ahead of the prorated expected-to-date threshold.
  _BudgetState _budgetStateFor(double spentUsd, double budgetUsd, double pace) {
    if (budgetUsd <= 0) return _BudgetState.ok;
    if (spentUsd > budgetUsd) return _BudgetState.over;
    if (spentUsd / budgetUsd > 0.85) return _BudgetState.near;
    final expectedToDate = budgetUsd * pace;
    // 115% of the prorated expectation: tolerate normal lumpiness, flag a
    // genuine run-rate problem (e.g. 60% spent on the 5th). Guarded by an
    // early-month floor — at least ~20% through the month AND at least 25% of
    // the budget already spent — so a single early purchase (pace≈0.03 on day 1)
    // can't trip the "on track to exceed" tier.
    const kPaceMinElapsed = 0.2;
    const kPaceMinSpentFraction = 0.25;
    if (pace >= kPaceMinElapsed &&
        spentUsd > budgetUsd * kPaceMinSpentFraction &&
        expectedToDate > 0 &&
        spentUsd > expectedToDate * _kPaceTolerance) {
      return _BudgetState.pacing;
    }
    return _BudgetState.ok;
  }

  Color _budgetStateColor(BuildContext context, _BudgetState state) {
    switch (state) {
      case _BudgetState.over:
        return context.pinkAccent;
      case _BudgetState.near:
        return context.warning;
      case _BudgetState.pacing:
        return context.warning;
      case _BudgetState.ok:
        return context.positive;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final spend = _monthlySpendByCategory();
    final hasBudgets = _budgets.isNotEmpty;
    final pace = _monthPaceFraction();
    // Pacing (the expected-to-date marker + "on track to exceed" tier) only
    // applies to the in-progress current month (item #11). For a closed month
    // priced by a 3mo/YTD window, hide the marker — it would pin to the far
    // right and read as a full-month threshold, which is misleading.
    final showPaceMarker = _isCurrentMonth;

    // Budget-vs-actual alert state: how many categories are over budget (and
    // by how much in total), merely approaching it (>85%), or on track to
    // exceed by month-end (ahead of the prorated expected-to-date threshold).
    var overCount = 0;
    var overTotalUsd = 0.0;
    var nearCount = 0;
    var pacingCount = 0;
    for (final e in _budgets.entries) {
      final spent = spend[e.key] ?? 0.0;
      switch (_budgetStateFor(spent, e.value, pace)) {
        case _BudgetState.over:
          overCount++;
          overTotalUsd += spent - e.value;
        case _BudgetState.near:
          nearCount++;
        case _BudgetState.pacing:
          pacingCount++;
        case _BudgetState.ok:
          break;
      }
    }

    final isPhone = MediaQuery.sizeOf(context).width < 720;
    final pad = isPhone ? 16.0 : 24.0;
    // Show fewer rows before the "show all" toggle on phones so the card
    // doesn't dominate the cash-flow tab; desktop keeps the full limit.
    final collapseLimit = isPhone ? 4 : _kBudgetCollapseLimit;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: EdgeInsets.all(pad),
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
                  // NB: use a glyph that's actually in this build's bundled
                  // MaterialIcons font. The "magic/idea" icons
                  // (auto_awesome_outlined, auto_fix_high, lightbulb_outline)
                  // render blank here — their glyphs aren't present in the
                  // SDK font this image builds with — whereas the classic set
                  // (add_circle_outline, edit_outlined, donut_small) render
                  // fine. add_circle_outline reads as "add budgets".
                  TextButton.icon(
                    onPressed: _suggesting ? null : _suggestBudgets,
                    icon: const Icon(Icons.add_circle_outline, size: 16),
                    label: Text(l.cfBudgetsSuggest),
                  ),
                TextButton.icon(
                  onPressed: () => _openEditor(spend),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: Text(hasBudgets ? l.cfBudgetsEdit : l.actionAdd),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (hasBudgets &&
                (overCount > 0 || nearCount > 0 || pacingCount > 0)) ...[
              _alertBanner(
                  context, l, overCount, overTotalUsd, nearCount, pacingCount),
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
                      : _budgets.entries.take(collapseLimit))
                  .map((e) {
                final cat = e.key;
                final budgetUsd = e.value;
                final spentUsd = spend[cat] ?? 0.0;
                final pct =
                    budgetUsd <= 0 ? 0.0 : (spentUsd / budgetUsd).clamp(0.0, 1.5);
                final state = _budgetStateFor(spentUsd, budgetUsd, pace);
                final over = state == _BudgetState.over;
                final color = _budgetStateColor(context, state);
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
                              '${widget.currencyFormat.displayMoney(spentUsd * widget.conversionFactor)} '
                              '/ ${widget.currencyFormat.displayMoney(budgetUsd * widget.conversionFactor)}',
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
                      // Bar with a thin "expected-to-date" pace marker: where
                      // a category should be if spend were even across the
                      // month. Spend bar pushing past the marker is the
                      // "on track to exceed" signal the colour/label echo.
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: Stack(
                          children: [
                            LinearProgressIndicator(
                              value: pct > 1.0 ? 1.0 : pct,
                              backgroundColor: context.tileSurface,
                              color: color,
                              minHeight: 8,
                            ),
                            if (showPaceMarker)
                              Positioned.fill(
                                child: LayoutBuilder(
                                  builder: (context, constraints) {
                                    return Align(
                                      alignment:
                                          Alignment(pace * 2 - 1, 0),
                                      child: Container(
                                        width: 2,
                                        height: 8,
                                        color: context.textMuted
                                            .withValues(alpha: 0.55),
                                      ),
                                    );
                                  },
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        over
                            ? l.cfBudgetsOverBy(widget.currencyFormat.displayMoney(
                                (spentUsd - budgetUsd) *
                                    widget.conversionFactor))
                            : state == _BudgetState.pacing
                                ? l.cfBudgetsPacingToExceed
                                : l.cfBudgetsLeft(widget.currencyFormat.displayMoney(
                                    (budgetUsd - spentUsd)
                                            .clamp(0, double.infinity) *
                                        widget.conversionFactor)),
                        style: TextStyle(
                          fontSize: 10,
                          color: over
                              ? context.pinkAccent
                              : state == _BudgetState.pacing
                                  ? context.warning
                                  : context.textFaint,
                        ),
                      ),
                    ],
                  ),
                );
              }),
              // Collapse a long budget list so the card doesn't dominate the
              // cash-flow tab — show the first few, with a toggle for the rest.
              if (_budgets.length > collapseLimit)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () =>
                        setState(() => _showAllBudgets = !_showAllBudgets),
                    child: Text(_showAllBudgets
                        ? l.cfBudgetsShowFewer
                        : l.cfBudgetsShowAll(
                            _budgets.length - collapseLimit)),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }

  // Prominent budget-vs-actual alert. Red when any category is over budget
  // (with the total overage), amber when categories are merely approaching it
  // or are on track to exceed by month-end (the prorated pace tier).
  Widget _alertBanner(
    BuildContext context,
    AppLocalizations l,
    int overCount,
    double overTotalUsd,
    int nearCount,
    int pacingCount,
  ) {
    final isOver = overCount > 0;
    final color = isOver ? context.pinkAccent : context.warning;
    final String text;
    if (isOver) {
      text = l.cfBudgetsOverAlert(
        overCount,
        widget.currencyFormat.displayMoney(overTotalUsd * widget.conversionFactor),
      );
    } else if (nearCount > 0) {
      text = l.cfBudgetsNearAlert(nearCount);
    } else {
      text = l.cfBudgetsPacingAlert(pacingCount);
    }
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

    // Snapshot the entered text, then dispose the per-category controllers
    // on BOTH the save and cancel paths — this method owns them, so without
    // this they leak (categories × number of times the editor is opened).
    final entered = {
      for (final entry in controllers.entries) entry.key: entry.value.text
    };
    for (final ctrl in controllers.values) {
      ctrl.dispose();
    }

    if (saved != true) return;
    final next = <String, double>{};
    entered.forEach((cat, text) {
      final reported = double.tryParse(text);
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
