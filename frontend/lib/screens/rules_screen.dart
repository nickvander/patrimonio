import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/theme_colors.dart';
import '../widgets/rule_editor_sheet.dart';

/// Management surface for the user rules engine — list, reorder, pause,
/// edit, preview-retroactive and delete (`work/RULES_ENGINE_DESIGN.md`
/// §5.3). Reached from the Settings tab, next to Hidden items.
///
/// Order is meaning here: rules are evaluated top-down and the FIRST match
/// wins **per action field**, so dragging a tile up is how the user
/// resolves a rule that's being shadowed (its diff reads "0 changes").
/// The drag commits through `PATCH /rules/reorder`.
///
/// Nothing on this screen rewrites history on its own. Toggling, editing,
/// reordering and deleting a rule all leave `transactions` untouched; the
/// only retroactive path is the previewed apply inside [RuleEditorSheet].
class RulesScreen extends StatefulWidget {
  const RulesScreen({super.key, this.api});

  /// Test seam — house `extends ApiService` fake pattern. Production
  /// callers leave it null and get a real service.
  final ApiService? api;

  @override
  State<RulesScreen> createState() => _RulesScreenState();
}

class _RulesScreenState extends State<RulesScreen> {
  late final ApiService _api = widget.api ?? ApiService();

  bool _loading = true;
  String? _error;
  List<UserRule> _rules = const [];

  /// account id → display label, for the account-scope chip. Read from the
  /// dashboard overview (already cached in the common case) rather than a
  /// second bespoke endpoint.
  Map<String, String> _accountNames = const {};

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final rules = await _api.getRules();
      Map<String, String> names = _accountNames;
      if (names.isEmpty) {
        try {
          final overview = await _api.getDashboardOverview();
          final accounts = (overview['accounts'] as List?) ?? const [];
          names = {
            for (final a in accounts)
              (a['id'] ?? '').toString(): _accountLabel(a),
          };
        } catch (_) {
          // Account names are decoration on a scope chip — a rules list
          // that renders without them beats an error page.
        }
      }
      if (!mounted) return;
      setState(() {
        _rules = rules;
        _accountNames = names;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  static String _accountLabel(dynamic a) {
    final nickname = (a['nickname'] ?? '').toString().trim();
    final name = (a['name'] ?? '').toString().trim();
    final institution = (a['institution_name'] ?? '').toString().trim();
    final display = nickname.isNotEmpty ? nickname : name;
    return institution.isEmpty ? display : '$institution · $display';
  }

  Future<void> _openEditor({UserRule? rule}) async {
    final saved = await showRuleEditorSheet(
      context,
      api: _api,
      initial: rule?.toDraft() ?? const RuleDraft(),
      ruleId: rule?.id,
      accountOption: rule?.accountId == null
          ? null
          : RuleScopeAccount(
              rule!.accountId!,
              _accountNames[rule.accountId!] ?? rule.accountId!,
            ),
      currencyOption: rule?.currency,
    );
    if (saved == true && mounted) await _load();
  }

  Future<void> _toggle(UserRule rule, bool active) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    // Optimistic: the toggle is a rule-table write only — it can never
    // change a transaction, so there is nothing to roll back but the pill.
    setState(() {
      _rules = [
        for (final r in _rules)
          if (r.id == rule.id) _withActive(r, active) else r,
      ];
    });
    try {
      await _api.setRuleActive(rule.id, active);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _rules = [
          for (final r in _rules)
            if (r.id == rule.id) _withActive(r, !active) else r,
        ];
      });
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l.ruleToggleFailed(e.toString().replaceFirst('Exception: ', '')),
          ),
        ),
      );
    }
  }

  static UserRule _withActive(UserRule r, bool active) => UserRule(
    id: r.id,
    matchType: r.matchType,
    matchValue: r.matchValue,
    accountId: r.accountId,
    currency: r.currency,
    direction: r.direction,
    amountMin: r.amountMin,
    amountMax: r.amountMax,
    setCategory: r.setCategory,
    setDescription: r.setDescription,
    priority: r.priority,
    active: active,
  );

  /// Wired to `onReorderItem`, whose [newIndex] is ALREADY adjusted for
  /// the removal at [oldIndex] (the deprecated `onReorder` is the one that
  /// makes the caller do that arithmetic) — so there is no `-= 1` here.
  Future<void> _reorder(int oldIndex, int newIndex) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final previous = _rules;
    final next = [..._rules];
    next.insert(newIndex, next.removeAt(oldIndex));
    setState(() => _rules = next);
    try {
      final saved = await _api.reorderRules([for (final r in next) r.id]);
      if (!mounted) return;
      setState(() => _rules = saved);
    } catch (e) {
      if (!mounted) return;
      setState(() => _rules = previous);
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l.ruleReorderFailed(e.toString().replaceFirst('Exception: ', '')),
          ),
        ),
      );
    }
  }

  Future<void> _confirmDelete(UserRule rule) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.ruleDeleteTitle),
        // DEC-028, stated plainly: deleting a rule stops it matching new
        // transactions but never rewinds what it already applied. A
        // dry-runnable revert is deliberately out of MVP scope.
        content: Text(l.ruleDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: ctx.negative),
            child: Text(l.actionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _api.deleteRule(rule.id);
      if (!mounted) return;
      setState(
        () => _rules = [
          for (final r in _rules)
            if (r.id != rule.id) r,
        ],
      );
      messenger.showSnackBar(SnackBar(content: Text(l.ruleDeleted)));
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            l.ruleDeleteFailed(e.toString().replaceFirst('Exception: ', '')),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(l.ruleTitle),
        actions: [
          IconButton(
            tooltip: l.ruleAdd,
            icon: const Icon(Icons.add),
            onPressed: _loading ? null : () => _openEditor(),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : LayoutBuilder(
              builder: (context, constraints) {
                final pad = constraints.maxWidth < 720 ? 16.0 : 24.0;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: EdgeInsets.fromLTRB(pad, 16, pad, 8),
                      child: Text(
                        l.ruleIntro,
                        style: TextStyle(
                          fontSize: 13,
                          color: context.textSubtle,
                        ),
                      ),
                    ),
                    if (_rules.isEmpty)
                      Padding(
                        padding: EdgeInsets.symmetric(horizontal: pad),
                        child: Text(
                          l.ruleEmpty,
                          style: TextStyle(
                            fontSize: 13,
                            color: context.textMuted,
                          ),
                        ),
                      )
                    else
                      Expanded(
                        child: ReorderableListView.builder(
                          padding: EdgeInsets.fromLTRB(pad, 0, pad, 24),
                          itemCount: _rules.length,
                          onReorderItem: _reorder,
                          itemBuilder: (context, i) {
                            final rule = _rules[i];
                            return _RuleTile(
                              key: ValueKey(rule.id),
                              rule: rule,
                              index: i,
                              accountLabel: rule.accountId == null
                                  ? null
                                  : _accountNames[rule.accountId!],
                              onToggle: (v) => _toggle(rule, v),
                              onEdit: () => _openEditor(rule: rule),
                              onDelete: () => _confirmDelete(rule),
                            );
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
    );
  }
}

/// One rule row: generated summary, scope chips, active switch, kebab.
/// Dumb/injected — it renders what it's handed and calls back.
class _RuleTile extends StatelessWidget {
  const _RuleTile({
    super.key,
    required this.rule,
    required this.index,
    required this.accountLabel,
    required this.onToggle,
    required this.onEdit,
    required this.onDelete,
  });

  final UserRule rule;
  final int index;
  final String? accountLabel;
  final ValueChanged<bool> onToggle;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scopes = ruleScopeChipLabels(
      context,
      rule,
      accountLabel: accountLabel,
    );
    return Card(
      elevation: 0,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: context.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ReorderableDragStartListener(
              index: index,
              child: Padding(
                padding: const EdgeInsets.only(top: 10, right: 8),
                child: Icon(
                  Icons.drag_indicator,
                  size: 20,
                  color: context.textFaint,
                ),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 6),
                  Text(
                    ruleSummaryText(context, rule),
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: rule.active
                          ? context.textPrimary
                          : context.textMuted,
                    ),
                  ),
                  if (scopes.isNotEmpty || !rule.active) ...[
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        if (!rule.active) _chip(context, l.rulePaused),
                        for (final s in scopes) _chip(context, s),
                      ],
                    ),
                  ],
                ],
              ),
            ),
            Switch(value: rule.active, onChanged: onToggle),
            PopupMenuButton<String>(
              tooltip: l.ruleMoreActions,
              icon: const Icon(Icons.more_vert, size: 20),
              onSelected: (v) {
                switch (v) {
                  case 'edit':
                  // The editor sheet IS the retroactive-preview surface:
                  // it renders the diff for the current definition as soon
                  // as it opens, so both entries land in the same place —
                  // one named for editing, one for the diff.
                  case 'preview':
                    onEdit();
                    break;
                  case 'delete':
                    onDelete();
                    break;
                }
              },
              itemBuilder: (ctx) => [
                PopupMenuItem(value: 'edit', child: Text(l.ruleActionEdit)),
                PopupMenuItem(
                  value: 'preview',
                  child: Text(l.rulePreviewRetroactive),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(
                    l.actionDelete,
                    style: TextStyle(color: ctx.negative),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _chip(BuildContext context, String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: context.tint(0.06),
      borderRadius: BorderRadius.circular(8),
    ),
    child: Text(
      label,
      style: TextStyle(fontSize: 11, color: context.textMuted),
    ),
  );
}

/// Human summary of a rule: "Description contains “OXXO GAS” →
/// Transportation". Pure (context is only used for l10n), so the wording
/// can be unit-tested in both locales.
String ruleSummaryText(BuildContext context, UserRule rule) {
  final l = AppLocalizations.of(context);
  final matcher = switch (rule.matchType) {
    'merchant_key' => l.ruleMatcherMerchantKey,
    'starts_with' => l.ruleMatcherStartsWith,
    'exact' => l.ruleMatcherExact,
    _ => l.ruleMatcherContains,
  };
  // gen-l10n takes these in metadata declaration order, which the arb
  // declares in template order → (matcher, value).
  final parts = <String>[l.ruleSummaryMatch(matcher, rule.matchValue)];
  if (rule.setCategory != null) {
    parts.add(l.ruleSummaryCategory(rule.setCategory!));
  }
  if (rule.setDescription != null) {
    parts.add(l.ruleSummaryRename(rule.setDescription!));
  }
  return parts.join(' ');
}

/// Scope chips for a rule, in a stable order. Empty when the rule is
/// unrestricted.
List<String> ruleScopeChipLabels(
  BuildContext context,
  UserRule rule, {
  String? accountLabel,
}) {
  final l = AppLocalizations.of(context);
  final nf = NumberFormat.decimalPattern(l.localeName);
  final chips = <String>[];
  if (rule.accountId != null) {
    chips.add(l.ruleScopeAccountChip(accountLabel ?? rule.accountId!));
  }
  if (rule.currency != null) {
    chips.add(l.ruleScopeCurrencyChip(rule.currency!));
  }
  if (rule.direction == 'inflow') chips.add(l.ruleScopeInflowChip);
  if (rule.direction == 'outflow') chips.add(l.ruleScopeOutflowChip);
  final min = rule.amountMin;
  final max = rule.amountMax;
  if (min != null && max != null) {
    // gen-l10n takes these in metadata declaration order, which the arb
    // declares in template order → (min, max).
    chips.add(l.ruleScopeAmountRange(nf.format(min), nf.format(max)));
  } else if (min != null) {
    chips.add(l.ruleScopeAmountFrom(nf.format(min)));
  } else if (max != null) {
    chips.add(l.ruleScopeAmountTo(nf.format(max)));
  }
  return chips;
}
