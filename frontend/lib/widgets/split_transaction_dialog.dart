import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';

/// One row in the split editor. Mutable so the parent dialog can
/// track form state across rebuilds.
class _SplitDraft {
  String description;
  String amountText;
  String category;
  _SplitDraft({this.description = '', this.amountText = '', this.category = ''});
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
  });

  @override
  State<SplitTransactionDialog> createState() =>
      _SplitTransactionDialogState();
}

class _SplitTransactionDialogState extends State<SplitTransactionDialog> {
  late List<_SplitDraft> _drafts;

  bool get _isEditing =>
      widget.initialDrafts != null && widget.initialDrafts!.isNotEmpty;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      _drafts = widget.initialDrafts!.map((raw) {
        final amt = (raw['amount'] as num?)?.toDouble() ?? 0.0;
        return _SplitDraft(
          description: (raw['description'] ?? '').toString(),
          amountText: amt.toStringAsFixed(2),
          category: (raw['category'] ?? widget.parentCategory).toString(),
        );
      }).toList();
      // Defensive: a corrupt initialDrafts shouldn't leave us with
      // <2 rows (would block save forever).
      while (_drafts.length < 2) {
        _drafts.add(_SplitDraft(category: widget.parentCategory));
      }
    } else {
      _applyRatio([0.5, 0.5]);
    }
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

  /// Replace `_drafts` with N rows whose amounts follow [ratios].
  /// Trailing row absorbs any cents-of-rounding remainder so the sum
  /// always equals the parent exactly. Description + category are
  /// carried over from existing rows where possible, otherwise blank
  /// / parent-category.
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

    final next = <_SplitDraft>[];
    for (var i = 0; i < n; i++) {
      final existing = i < _drafts.length ? _drafts[i] : null;
      next.add(_SplitDraft(
        description: existing?.description ?? '',
        amountText: allocated[i].toStringAsFixed(2),
        category: existing?.category.isNotEmpty == true
            ? existing!.category
            : widget.parentCategory,
      ));
    }
    setState(() => _drafts = next);
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
    setState(() => _drafts.removeAt(idx));
  }

  @override
  Widget build(BuildContext context) {
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
            child: Text(_isEditing ? 'Edit split' : 'Split transaction'),
          ),
          // Quick-split presets. Reset the row set to the chosen
          // ratio in a single click. "Even" prompts for N via a
          // nested popup. "Custom" keeps current state — useful as
          // a no-op label when the user is just confirming the
          // current values match what they want.
          PopupMenuButton<String>(
            tooltip: 'Quick split',
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
            itemBuilder: (ctx) => const [
              PopupMenuItem(value: '50/50', child: Text('50 / 50')),
              PopupMenuItem(value: '60/40', child: Text('60 / 40')),
              PopupMenuItem(value: '70/30', child: Text('70 / 30')),
              PopupMenuItem(value: '40/30/30', child: Text('40 / 30 / 30')),
              PopupMenuDivider(),
              PopupMenuItem(value: 'even', child: Text('Even split…')),
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
              'Total: ${native.format(widget.parentAmount.abs())} '
              '${widget.parentAmount > 0 ? '(expense)' : '(income)'}',
              style: TextStyle(fontSize: 12, color: context.textSubtle),
            ),
            const SizedBox(height: 10),
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (var i = 0; i < _drafts.length; i++)
                      Padding(
                        // The Key ties each row to its draft index so the
                        // TextFormField's internal state survives ratio
                        // presets — without it, "60/40" would re-create
                        // each row and clear the description fields.
                        key: ValueKey('split-row-${_drafts.length}-$i-'
                            '${_drafts[i].amountText}'),
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            Expanded(
                              flex: 3,
                              child: TextFormField(
                                initialValue: _drafts[i].description,
                                decoration: const InputDecoration(
                                  isDense: true,
                                  labelText: 'Description',
                                  border: OutlineInputBorder(),
                                ),
                                onChanged: (v) =>
                                    setState(() => _drafts[i].description = v),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              flex: 2,
                              child: TextFormField(
                                initialValue: _drafts[i].amountText,
                                decoration: InputDecoration(
                                  isDense: true,
                                  labelText: 'Amount',
                                  suffixText: widget.parentCurrency,
                                  border: const OutlineInputBorder(),
                                ),
                                keyboardType: const TextInputType.numberWithOptions(
                                    decimal: true, signed: true),
                                onChanged: (v) =>
                                    setState(() => _drafts[i].amountText = v),
                              ),
                            ),
                            IconButton(
                              tooltip: 'Remove row',
                              icon: const Icon(Icons.remove_circle_outline, size: 18),
                              onPressed: _drafts.length <= 2 ? null : () => _removeRow(i),
                            ),
                          ],
                        ),
                      ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: TextButton.icon(
                        onPressed: _addRow,
                        icon: const Icon(Icons.add, size: 16),
                        label: const Text('Add row'),
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
                            ? 'Splits match the parent total.'
                            : 'Off by ${native.format(diff.abs())}.',
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
                '≈ ${widget.reportingFormat.format(convertCurrency(sum, from: widget.parentCurrency, to: widget.targetCurrency, usdMxnRate: widget.usdMxnRate).abs())} in ${widget.targetCurrency}',
                style: TextStyle(fontSize: 11, color: context.textSubtle),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: const Text('Cancel'),
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
          child: Text(_isEditing ? 'Save changes' : 'Save split'),
        ),
      ],
    );
  }
}

/// Prompt the user for the number of rows for an "even" split. 2..10
/// is plenty — splits beyond 10 are vanishingly rare and the number
/// keypad keeps the picker compact. Returns null on cancel.
Future<int?> _promptEvenSplitCount(BuildContext context) async {
  var n = 3;
  return showDialog<int>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(builder: (ctx, setLocal) {
        return AlertDialog(
          title: const Text('Split evenly'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Divide the parent amount into $n equal parts.',
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
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, n),
              child: const Text('Apply'),
            ),
          ],
        );
      });
    },
  );
}
