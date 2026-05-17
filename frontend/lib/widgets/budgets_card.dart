import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../services/preferences.dart';
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

class _BudgetsCardState extends State<BudgetsCard> {
  // Seed from localStorage so first paint is instant. The backend value
  // (canonical) overrides this once the GET resolves.
  late Map<String, double> _budgets = Preferences.getBudgets();

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
    final spend = _monthlySpendByCategory();
    final hasBudgets = _budgets.isNotEmpty;

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
                const Expanded(
                  child: Text(
                    'Budgets this month',
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: () => _openEditor(spend),
                  icon: const Icon(Icons.edit_outlined, size: 16),
                  label: Text(hasBudgets ? 'Edit' : 'Add'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            if (!hasBudgets)
              Text(
                'Set a monthly budget for any category to track spending against it here.',
                style: TextStyle(color: context.textMuted, fontSize: 13),
              )
            else
              ..._budgets.entries.map((e) {
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
                    ],
                  ),
                );
              }),
          ],
        ),
      ),
    );
  }

  Future<void> _openEditor(Map<String, double> spend) async {
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
          title: const Text('Edit monthly budgets'),
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
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Save')),
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
