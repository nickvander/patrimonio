import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';

/// One row in the split editor. Mutable so the parent dialog can
/// track form state across rebuilds.
///
/// Each draft owns its text controllers and a stable [id] (used as the
/// row's ValueKey) so that editing an amount never recreates the row's
/// widget subtree — recreating it would drop focus on every keystroke.
class _SplitDraft {
  static int _nextId = 0;

  /// Stable identity for the row's ValueKey. Never reused within a
  /// dialog session, so rows keep their element (and focus) across
  /// inserts/removals/presets.
  final int id;
  final TextEditingController descriptionController;
  final TextEditingController amountController;
  String category;

  _SplitDraft({String description = '', String amountText = '', this.category = ''})
      : id = _nextId++,
        descriptionController = TextEditingController(text: description),
        amountController = TextEditingController(text: amountText);

  String get description => descriptionController.text;
  String get amountText => amountController.text;

  void dispose() {
    descriptionController.dispose();
    amountController.dispose();
  }
}

/// Editor for splitting a parent transaction into N children. Validates
/// in real time that the child amounts sum (within 1¢) to the parent's
/// amount; the Save button stays disabled until they match.
///
/// Returns the list of children on save, null on cancel.
///
/// Two modes:
/// * **Create**: `initialDrafts` is null. Dialog seeds two empty 50/50
///   rows. Save fires `POST /transactions/{id}/splits`.
/// * **Edit**: `initialDrafts` is the existing child set. Dialog
///   pre-populates with current splits. Caller is expected to do
///   unsplit-then-resplit on Save (the backend rejects splitting an
///   already-split parent).
class SplitTransactionDialog extends StatefulWidget {
  /// Parent transaction's amount. Same sign convention as the rest of
  /// the app (amount > 0 = expense / outflow).
  final double parentAmount;
  final String parentCurrency;
  /// Hint shown above the editor: the parent's display label.
  final String parentLabel;
  /// Defaulted into every new split row (and pre-filled on the first
  /// two seeded rows) — usually the parent's category.
  final String parentCategory;
  /// USD/MXN rate so the helper line at the bottom can show the
  /// reporting-currency equivalent of the running total when reporting
  /// currency differs from the parent's.
  final double usdMxnRate;
  final String targetCurrency;
  final NumberFormat reportingFormat;
  /// Pre-populated splits — supplied when re-opening for an edit.
  /// Each entry: `{'description': String, 'amount': double,
  /// 'category': String?}`. When null/empty, the dialog seeds
  /// the default 50/50 pair.
  final List<Map<String, dynamic>>? initialDrafts;
  /// Categories the user already has in the transactions list,
  /// used to populate a per-row dropdown so the user doesn't have
  /// to retype "Groceries" exactly. When empty the dropdown is
  /// hidden (the dialog falls back to inheriting the parent's
  /// category like it did before).
  final List<String> availableCategories;

  const SplitTransactionDialog({
    super.key,
    required this.parentAmount,
    required this.parentCurrency,
    required this.parentLabel,
    required this.parentCategory,
    required this.usdMxnRate,
    required this.targetCurrency,
    required this.reportingFormat,
    this.initialDrafts,
    this.availableCategories = const [],
  });

  @override
  State<SplitTransactionDialog> createState() =>
      _SplitTransactionDialogState();
}

class _SplitTransactionDialogState extends State<SplitTransactionDialog> {
  final List<_SplitDraft> _drafts = [];

  bool get _isEditing =>
      widget.initialDrafts != null && widget.initialDrafts!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      _drafts.addAll(widget.initialDrafts!.map((raw) {
        final amt = (raw['amount'] as num?)?.toDouble() ?? 0.0;
        return _SplitDraft(
          description: (raw['description'] ?? '').toString(),
          amountText: amt.toStringAsFixed(2),
          category: (raw['category'] ?? widget.parentCategory).toString(),
        );
      }));
      // Defensive: a corrupt initialDrafts shouldn't leave us with
      // <2 rows (would block save forever).
      while (_drafts.length < 2) {
        _drafts.add(_SplitDraft(category: widget.parentCategory));
      }
    } else {
      _applyRatio([0.5, 0.5]);
    }
  }

  @override
  void dispose() {
    for (final d in _drafts) {
      d.dispose();
    }
    super.dispose();
  }

  /// A draft's controllers can't be disposed while its row is still
  /// mounted (the TextFormField detaches its listeners on unmount), so
  /// defer disposal to after the rebuild that removes the row.
  void _disposeAfterFrame(_SplitDraft draft) {
    WidgetsBinding.instance.addPostFrameCallback((_) => draft.dispose());
  }

  double _sum() {
    var total = 0.0;
    for (final d in _drafts) {
      total += double.tryParse(d.amountText) ?? 0.0;
    }
    return total;
  }

  bool get _sumMatches {
    return (_sum() - widget.parentAmount).abs() < 0.011;
  }

  bool get _canSave {
    if (_drafts.length < 2) return false;
    for (final d in _drafts) {
      if (d.description.trim().isEmpty) return false;
      final amt = double.tryParse(d.amountText);
      if (amt == null || amt == 0) return false;
      // Same sign as parent.
      if ((amt > 0) != (widget.parentAmount > 0)) return false;
    }
    return _sumMatches;
  }

  /// Resize `_drafts` to N rows whose amounts follow [ratios].
  /// Trailing row absorbs any cents-of-rounding remainder so the sum
  /// always equals the parent exactly. Existing rows (and therefore
  /// their descriptions, categories and focus) are kept in place —
  /// only the amount text is rewritten, via the row's controller, so
  /// no widgets are recreated.
  void _applyRatio(List<double> ratios) {
    final n = ratios.length;
    final allocated = <double>[];
    for (var i = 0; i < n - 1; i++) {
      allocated.add(
        double.parse((widget.parentAmount * ratios[i]).toStringAsFixed(2)),
      );
    }
    final remainder = widget.parentAmount -
        allocated.fold<double>(0.0, (a, b) => a + b);
    allocated.add(double.parse(remainder.toStringAsFixed(2)));

    setState(() {
      while (_drafts.length > n) {
        _disposeAfterFrame(_drafts.removeLast());
      }
      while (_drafts.length < n) {
        _drafts.add(_SplitDraft(category: widget.parentCategory));
      }
      for (var i = 0; i < n; i++) {
        if (_drafts[i].category.trim().isEmpty) {
          _drafts[i].category = widget.parentCategory;
        }
        _drafts[i].amountController.text = allocated[i].toStringAsFixed(2);
      }
    });
  }

  /// Distribute the parent's amount evenly across [n] rows. Carries
  /// description / category from existing rows; trailing row gets the
  /// rounding remainder.
  void _applyEven(int n) {
    if (n < 2) return;
    _applyRatio(List<double>.filled(n, 1.0 / n));
  }

  void _addRow() {
    // Default the new row's amount to the remaining gap so a single
    // click adds a row that completes the split. Useful when the user
    // pastes a known amount + just needs the rest as one bucket.
    final gap = (widget.parentAmount - _sum()).toStringAsFixed(2);
    setState(() {
      _drafts.add(_SplitDraft(
        amountText: gap == '-0.00' ? '0.00' : gap,
        category: widget.parentCategory,
      ));
    });
  }

  void _removeRow(int idx) {
    if (_drafts.length <= 2) return;
    setState(() => _disposeAfterFrame(_drafts.removeAt(idx)));
  }

  /// Build a small dropdown of the categories the user already has
  /// in their transactions list. Includes a "Same as parent" sentinel
  /// at the top so a row can opt out of overriding the category, and
  /// preserves a custom value not in the list (e.g. carried over from
  /// initialDrafts) as a one-off option so it isn't silently lost.
  Widget _categoryDropdown(int rowIdx) {
    final l = AppLocalizations.of(context);
    final draft = _drafts[rowIdx];
    final current = draft.category.trim();
    final isInList = current.isEmpty ||
        current == widget.parentCategory ||
        widget.availableCategories.contains(current);
    final items = <DropdownMenuItem<String>>[
      DropdownMenuItem(
        value: widget.parentCategory,
        child: Text(
          widget.parentCategory.isEmpty
              ? l.txSplitSameAsParentUncategorised
              : l.txSplitSameAsParent(widget.parentCategory),
          style: const TextStyle(fontSize: 13),
        ),
      ),
      for (final c in widget.availableCategories)
        if (c != widget.parentCategory)
          DropdownMenuItem(
            value: c,
            child: Text(c, style: const TextStyle(fontSize: 13)),
          ),
      // Preserve a value that came from initialDrafts but isn't in the
      // current category list (e.g. the parent's old category that
      // never re-appeared after a rename).
      if (!isInList)
        DropdownMenuItem(
          value: current,
          child: Text(
            l.txSplitExistingCategory(current),
            style: const TextStyle(fontSize: 13),
          ),
        ),
    ];
    return DropdownButtonFormField<String>(
      value: current.isEmpty ? widget.parentCategory : current,
      isDense: true,
      decoration: InputDecoration(
        isDense: true,
        labelText: l.txCategory,
        border: const OutlineInputBorder(),
      ),
      style: TextStyle(
        fontSize: 13,
        color: Theme.of(context).colorScheme.onSurface,
      ),
      items: items,
      onChanged: (v) => setState(() => draft.category = v ?? ''),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final sum = _sum();
    final diff = widget.parentAmount - sum;
    final native = NumberFormat.currency(
      name: widget.parentCurrency,
      symbol: '${widget.parentCurrency} ',
    );

    return AlertDialog(
      title: Row(
        children: [
          Expanded(
            child: Text(_isEditing ? l.txEditSplit : l.txSplitTransactionTitle),
          ),
          // Quick-split presets. Reset the row set to the chosen
          // ratio in a single click. "Even" prompts for N via a
          // nested popup. "Custom" keeps current state — useful as
          // a no-op label when the user is just confirming the
          // current values match what they want.
          PopupMenuButton<String>(
            tooltip: l.txQuickSplit,
            icon: const Icon(Icons.tune, size: 18),
            onSelected: (value) async {
              switch (value) {
                case '50/50':
                  _applyRatio([0.5, 0.5]);
                  break;
                case '60/40':
                  _applyRatio([0.6, 0.4]);
                  break;
                case '70/30':
                  _applyRatio([0.7, 0.3]);
                  break;
                case '40/30/30':
                  _applyRatio([0.4, 0.3, 0.3]);
                  break;
                case 'even':
                  final n = await _promptEvenSplitCount(context);
                  if (n != null) _applyEven(n);
                  break;
              }
            },
            itemBuilder: (ctx) => [
              const PopupMenuItem(value: '50/50', child: Text('50 / 50')),
              const PopupMenuItem(value: '60/40', child: Text('60 / 40')),
              const PopupMenuItem(value: '70/30', child: Text('70 / 30')),
              const PopupMenuItem(value: '40/30/30', child: Text('40 / 30 / 30')),
              const PopupMenuDivider(),
              PopupMenuItem(value: 'even', child: Text(l.txSplitEven)),
            ],
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.parentLabel,
              style: TextStyle(
                fontSize: 13,
                color: context.textMuted,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              l.txSplitTotal(
                native.format(widget.parentAmount.abs()),
                widget.parentAmount > 0 ? l.txSplitExpenseTag : l.txSplitIncomeTag,
              ),
              style: TextStyle(fontSize: 12, color: context.textSubtle),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var i = 0; i < _drafts.length; i++)
                      Padding(
                        // The Key ties each row to its draft's stable id
                        // so the row's element (and focus) survives
                        // rebuilds, ratio presets and row removal. It
                        // must NOT depend on the live text — that would
                        // recreate the subtree on every keystroke and
                        // drop focus.
                        key: ValueKey('split-row-${_drafts[i].id}'),
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  flex: 3,
                                  child: TextFormField(
                                    controller: _drafts[i].descriptionController,
                                    decoration: InputDecoration(
                                      isDense: true,
                                      labelText: l.txSplitDescription,
                                      border: const OutlineInputBorder(),
                                    ),
                                    // Text lives in the controller; the
                                    // setState only refreshes _canSave.
                                    onChanged: (_) => setState(() {}),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Expanded(
                                  flex: 2,
                                  child: TextFormField(
                                    controller: _drafts[i].amountController,
                                    decoration: InputDecoration(
                                      isDense: true,
                                      labelText: l.txSplitAmount,
                                      suffixText: widget.parentCurrency,
                                      border: const OutlineInputBorder(),
                                    ),
                                    keyboardType: const TextInputType.numberWithOptions(
                                        decimal: true, signed: true),
                                    // Text lives in the controller; the
                                    // setState refreshes the sum banner
                                    // and _canSave.
                                    onChanged: (_) => setState(() {}),
                                  ),
                                ),
                                IconButton(
                                  tooltip: l.txSplitRemoveRow,
                                  icon: const Icon(Icons.remove_circle_outline, size: 18),
                                  onPressed: _drafts.length <= 2 ? null : () => _removeRow(i),
                                ),
                              ],
                            ),
                            // Category dropdown — only shown when the
                            // parent's transactions list has any categories
                            // to pick from. The empty value lets the row
                            // inherit the parent's category at insert
                            // time, matching the previous behaviour.
                            if (widget.availableCategories.isNotEmpty)
                              Padding(
                                padding: const EdgeInsets.only(top: 4, right: 48),
                                child: _categoryDropdown(i),
                              ),
                          ],
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _addRow,
                        icon: const Icon(Icons.add, size: 16),
                        label: Text(l.txSplitAddRow),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            // Live total + delta hint. Green when matched; red when not.
            DecoratedBox(
              decoration: BoxDecoration(
                color: context.accentSoft(
                    _sumMatches ? context.positive : context.negative),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                child: Row(
                  children: [
                    Icon(
                      _sumMatches ? Icons.check_circle_outline : Icons.warning_amber_rounded,
                      size: 16,
                      color: _sumMatches ? context.positive : context.negative,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _sumMatches
                            ? l.txSplitMatches
                            : l.txSplitOffBy(native.format(diff.abs())),
                        style: TextStyle(
                          fontSize: 12,
                          color: _sumMatches ? context.positive : context.negative,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    Text(
                      '${native.format(sum.abs())} / ${native.format(widget.parentAmount.abs())}',
                      style: TextStyle(
                        fontSize: 12,
                        color: context.textMuted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (widget.targetCurrency != widget.parentCurrency &&
                widget.usdMxnRate > 0) ...[
              const SizedBox(height: 4),
              Text(
                l.txSplitApproxIn(
                  widget.reportingFormat.format(convertCurrency(sum,
                          from: widget.parentCurrency,
                          to: widget.targetCurrency,
                          usdMxnRate: widget.usdMxnRate)
                      .abs()),
                  widget.targetCurrency,
                ),
                style: TextStyle(fontSize: 11, color: context.textSubtle),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: _canSave
              ? () {
                  final out = _drafts
                      .map((d) => {
                            'description': d.description.trim(),
                            'amount': double.tryParse(d.amountText) ?? 0.0,
                            if (d.category.trim().isNotEmpty)
                              'category': d.category.trim(),
                          })
                      .toList();
                  Navigator.pop(context, out);
                }
              : null,
          child: Text(_isEditing ? l.txSplitSaveChanges : l.txSplitSave),
        ),
      ],
    );
  }
}

/// Prompt the user for the number of rows for an "even" split. 2..10
/// is plenty — splits beyond 10 are vanishingly rare and the number
/// keypad keeps the picker compact. Returns null on cancel.
Future<int?> _promptEvenSplitCount(BuildContext context) async {
  final l = AppLocalizations.of(context);
  var n = 3;
  return showDialog<int>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: Text(l.txSplitEvenlyTitle),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l.txSplitEvenlyBody(n),
                style: const TextStyle(fontSize: 13),
              ),
              const SizedBox(height: 8),
              Slider(
                value: n.toDouble(),
                min: 2,
                max: 10,
                divisions: 8,
                label: '$n',
                onChanged: (v) => setLocal(() => n = v.round()),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, null),
              child: Text(l.actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, n),
              child: Text(l.actionApply),
            ),
          ],
        );
      });
    },
  );
}
