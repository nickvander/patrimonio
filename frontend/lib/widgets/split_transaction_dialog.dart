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

  const SplitTransactionDialog({
    super.key,
    required this.parentAmount,
    required this.parentCurrency,
    required this.parentLabel,
    required this.parentCategory,
    required this.usdMxnRate,
    required this.targetCurrency,
    required this.reportingFormat,
  });

  @override
  State<SplitTransactionDialog> createState() =>
      _SplitTransactionDialogState();
}

class _SplitTransactionDialogState extends State<SplitTransactionDialog> {
  late List<_SplitDraft> _drafts;

  @override
  void initState() {
    super.initState();
    // Seed two rows. First row pre-filled with half the amount so the
    // user can see the format immediately. Category copied from parent
    // so a quick split doesn't lose the original categorization.
    final half = (widget.parentAmount / 2).toStringAsFixed(2);
    final remainder = (widget.parentAmount - double.parse(half))
        .toStringAsFixed(2);
    _drafts = [
      _SplitDraft(amountText: half, category: widget.parentCategory),
      _SplitDraft(amountText: remainder, category: widget.parentCategory),
    ];
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
      title: const Text('Split transaction'),
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
          child: const Text('Save split'),
        ),
      ],
    );
  }
}
