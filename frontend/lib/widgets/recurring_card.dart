import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';
import 'add_recurring_rule_dialog.dart' show cadenceLabel;

/// Cash-flow tab card for recurring & scheduled transactions (MVP):
/// shows the EXPECTED upcoming inflows/outflows from the user's active
/// rules for the current period, clearly marked as expected (nothing
/// here is a posted transaction), plus the management list (pause /
/// delete) behind the Manage button.
///
/// Dumb/injected per the house pattern: receives already-fetched data
/// and mutation callbacks; never fetches. Amounts are always labelled
/// with their ISO currency code (USD/MXN) — expected rows from two
/// countries' accounts sit side by side here, so a bare "$" would be
/// ambiguous.
class RecurringCard extends StatelessWidget {
  /// `/api/recurring/upcoming` response: `{from, to, items,
  /// expected_inflows_usd, expected_outflows_usd}`.
  final Map<String, dynamic>? upcoming;

  /// `/api/recurring` management list (active and paused rules).
  final List<dynamic> rules;

  final double conversionFactor;
  final String targetCurrency;

  /// Pause/resume; parent persists and refreshes.
  final Future<void> Function(String id, bool active) onToggleRule;

  /// Delete; parent persists and refreshes.
  final Future<void> Function(String id) onDeleteRule;

  const RecurringCard({
    super.key,
    required this.upcoming,
    required this.rules,
    required this.conversionFactor,
    required this.targetCurrency,
    required this.onToggleRule,
    required this.onDeleteRule,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final items = (upcoming?['items'] as List?) ?? const [];
    final inflowsUsd =
        (upcoming?['expected_inflows_usd'] as num?)?.toDouble() ?? 0;
    final outflowsUsd =
        (upcoming?['expected_outflows_usd'] as num?)?.toDouble() ?? 0;

    // Card padding off the card's OWN LayoutBuilder constraint, never
    // the window (skill §4/§5): the card is narrower than the screen on
    // every layout that pads or column-clamps its tab.
    return LayoutBuilder(
      builder: (_, outer) {
        final pad = outer.maxWidth < 720 ? 16.0 : 24.0;
        return Card(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: EdgeInsets.all(pad),
            // Width-responsive off the card's OWN constraint (inner
            // LayoutBuilder, per the skill rule), not MediaQuery.
            child: LayoutBuilder(
              builder: (context, c) {
                final isPhone = c.maxWidth < 420;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (!isPhone) ...[
                          Icon(
                            Icons.autorenew_rounded,
                            color: context.info,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                        ],
                        Expanded(
                          child: Row(
                            children: [
                              Flexible(
                                child: Text(
                                  isPhone
                                      ? l.recTitle.toUpperCase()
                                      : l.recTitle,
                                  style: isPhone
                                      ? TextStyle(
                                          fontSize: 12,
                                          fontWeight: FontWeight.w700,
                                          letterSpacing: 0.6,
                                          color: context.textSubtle,
                                        )
                                      : TextStyle(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: context.textPrimary,
                                        ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              // "Expected" chip — the card's contract with the
                              // user: these are projections, not postings.
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: context.tint(0.08),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: context.hairline),
                                ),
                                child: Text(
                                  l.recExpectedChip,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.4,
                                    color: context.textSubtle,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        TextButton(
                          onPressed: () => _openManageSheet(context),
                          child: Text(l.recManage),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      l.recExpectedNote,
                      style: TextStyle(fontSize: 11, color: context.textFaint),
                    ),
                    SizedBox(height: isPhone ? 10 : 14),
                    if (rules.isEmpty)
                      Text(
                        l.recNoRules,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.textMuted,
                        ),
                      )
                    else ...[
                      _totalsRow(context, l, isPhone, inflowsUsd, outflowsUsd),
                      SizedBox(height: isPhone ? 10 : 14),
                      if (items.isEmpty)
                        Text(
                          l.recNothingUpcoming,
                          style: TextStyle(
                            fontSize: 12,
                            color: context.textMuted,
                          ),
                        )
                      else
                        Container(
                          width: double.infinity,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: context.tileSurface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: context.hairline),
                          ),
                          child: Column(
                            children: [
                              for (var i = 0; i < items.length; i++) ...[
                                if (i > 0)
                                  Divider(height: 1, color: context.hairline),
                                _itemRow(context, items[i] as Map, isPhone),
                              ],
                            ],
                          ),
                        ),
                    ],
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  /// Header totals: expected in / expected out for the period, converted
  /// to the dashboard's display currency. Code-labelled (per the spec:
  /// every amount carries its currency label).
  Widget _totalsRow(
    BuildContext context,
    AppLocalizations l,
    bool isPhone,
    double inflowsUsd,
    double outflowsUsd,
  ) {
    Widget cell(String label, double usd, Color color, {String sign = ''}) {
      return Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(fontSize: 11, color: context.textFaint),
            ),
            const SizedBox(height: 2),
            Text(
              '$sign${displayCurrencyWithCode(usd * conversionFactor, targetCurrency)}',
              style: TextStyle(
                fontSize: isPhone ? 14 : 16,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      );
    }

    return Row(
      children: [
        cell(l.recExpectedIn, inflowsUsd, context.positive, sign: '+'),
        cell(l.recExpectedOut, outflowsUsd, context.negative, sign: '−'),
      ],
    );
  }

  Widget _itemRow(BuildContext context, Map item, bool isPhone) {
    final amount = (item['amount'] as num?)?.toDouble() ?? 0;
    final currency = (item['currency'] ?? 'USD').toString();
    final due = DateTime.tryParse((item['due_date'] ?? '').toString());
    final description = (item['description'] ?? '').toString();
    final accountName = (item['account_name'] ?? '').toString();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              due == null ? '' : DateFormat.MMMd().format(due),
              style: TextStyle(fontSize: 11, color: context.textSubtle),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  description,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (accountName.isNotEmpty)
                  Text(
                    accountName,
                    style: TextStyle(fontSize: 11, color: context.textFaint),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Native amount, ISO-code-labelled: "USD 1,200.00" / "MXN 500.00".
          Text(
            formatCurrencyWithCode(amount, currency),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: amount >= 0 ? context.positive : context.negative,
            ),
          ),
        ],
      ),
    );
  }

  void _openManageSheet(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) => _ManageRecurringSheet(
        rules: rules,
        onToggleRule: onToggleRule,
        onDeleteRule: onDeleteRule,
      ),
    );
  }
}

/// Management list: every rule, pause/resume switch + delete. Keeps a
/// local mutable copy so toggles feel instant; the parent refreshes the
/// canonical list after each callback resolves.
class _ManageRecurringSheet extends StatefulWidget {
  final List<dynamic> rules;
  final Future<void> Function(String id, bool active) onToggleRule;
  final Future<void> Function(String id) onDeleteRule;

  const _ManageRecurringSheet({
    required this.rules,
    required this.onToggleRule,
    required this.onDeleteRule,
  });

  @override
  State<_ManageRecurringSheet> createState() => _ManageRecurringSheetState();
}

class _ManageRecurringSheetState extends State<_ManageRecurringSheet> {
  late List<Map<String, dynamic>> _rules;
  final Set<String> _busy = {};

  @override
  void initState() {
    super.initState();
    _rules = widget.rules
        .whereType<Map>()
        .map((r) => Map<String, dynamic>.from(r))
        .toList();
  }

  Future<void> _toggle(Map<String, dynamic> rule, bool active) async {
    final id = rule['id'].toString();
    setState(() {
      _busy.add(id);
      rule['active'] = active;
    });
    try {
      await widget.onToggleRule(id, active);
    } catch (e) {
      if (!mounted) return;
      setState(() => rule['active'] = !active); // roll back optimistic flip
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  Future<void> _delete(Map<String, dynamic> rule) async {
    final l = AppLocalizations.of(context);
    final id = rule['id'].toString();
    final description = (rule['description'] ?? '').toString();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.recDeleteConfirmTitle),
        content: Text(l.recDeleteConfirmBody(description)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(l.actionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy.add(id));
    try {
      await widget.onDeleteRule(id);
      if (!mounted) return;
      setState(() => _rules.removeWhere((r) => r['id'].toString() == id));
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.recRuleDeleted)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _busy.remove(id));
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.recManageTitle,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: context.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            if (_rules.isEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Text(
                  l.recNoRules,
                  style: TextStyle(fontSize: 12, color: context.textMuted),
                ),
              )
            else
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _rules.length,
                  separatorBuilder: (_, _) =>
                      Divider(height: 1, color: context.hairline),
                  itemBuilder: (context, i) => _ruleRow(context, l, _rules[i]),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _ruleRow(
    BuildContext context,
    AppLocalizations l,
    Map<String, dynamic> rule,
  ) {
    final id = rule['id'].toString();
    final active = rule['active'] == true;
    final amount = (rule['amount'] as num?)?.toDouble() ?? 0;
    final currency = (rule['currency'] ?? 'USD').toString();
    final cadence = (rule['cadence'] ?? 'monthly').toString();
    final nextDue = DateTime.tryParse(
      (rule['effective_next_due'] ?? rule['next_due_date'] ?? '').toString(),
    );
    final busy = _busy.contains(id);

    final subtitleParts = <String>[
      cadenceLabel(l, cadence),
      if (nextDue != null) l.recNextDue(DateFormat.yMMMd().format(nextDue)),
      if (!active) l.recPaused,
    ];

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  (rule['description'] ?? '').toString(),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    // Paused rules dim so the active set reads at a glance.
                    color: active ? context.textPrimary : context.textSubtle,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  subtitleParts.join(' · '),
                  style: TextStyle(fontSize: 11, color: context.textFaint),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            formatCurrencyWithCode(amount, currency),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: !active
                  ? context.textSubtle
                  : (amount >= 0 ? context.positive : context.negative),
            ),
          ),
          const SizedBox(width: 4),
          // Pause/resume — ≥48dp touch targets.
          Tooltip(
            message: active ? l.recPauseRule : l.recResumeRule,
            child: Switch(
              value: active,
              onChanged: busy ? null : (v) => _toggle(rule, v),
            ),
          ),
          IconButton(
            tooltip: l.actionDelete,
            icon: Icon(Icons.delete_outline, color: context.negative),
            onPressed: busy ? null : () => _delete(rule),
            constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
          ),
        ],
      ),
    );
  }
}
