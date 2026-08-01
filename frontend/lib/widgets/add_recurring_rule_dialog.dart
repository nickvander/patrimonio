import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/mask_aware_name.dart';
import '../utils/recurrence.dart';
import '../utils/theme_colors.dart';

/// Display label for a cadence value. Shared by this dialog and the
/// recurring management sheet.
String cadenceLabel(AppLocalizations l, String cadence) {
  switch (cadence) {
    case 'weekly':
      return l.recCadenceWeekly;
    case 'biweekly':
      return l.recCadenceBiweekly;
    case 'yearly':
      return l.recCadenceYearly;
    case 'monthly':
    default:
      return l.recCadenceMonthly;
  }
}

/// "Make recurring": create a recurring rule, usually pre-filled from an
/// existing transaction (the tx detail panel's action) — account,
/// description, category, amount and sign come from the transaction, the
/// first due date defaults to the tx date advanced one cadence (the tx
/// itself already covers the current occurrence).
///
/// Expected-only MVP: the rule never posts transactions; it only feeds
/// the cash-flow tab's "expected" card. Sign convention matches the rest
/// of the app (negative = outflow) but the UI shows an Expense/Income
/// toggle and keeps the amount field positive.
class AddRecurringRuleDialog extends StatefulWidget {
  final List<dynamic> accounts;
  final ApiService apiService;
  final VoidCallback onCreated;

  /// Transaction to pre-fill from ("Make recurring"); null starts blank.
  final Map<String, dynamic>? sourceTx;

  const AddRecurringRuleDialog({
    super.key,
    required this.accounts,
    required this.apiService,
    required this.onCreated,
    this.sourceTx,
  });

  @override
  State<AddRecurringRuleDialog> createState() => _AddRecurringRuleDialogState();
}

class _AddRecurringRuleDialogState extends State<AddRecurringRuleDialog> {
  final _formKey = GlobalKey<FormState>();
  final _descController = TextEditingController();
  final _amountController = TextEditingController();
  final _categoryController = TextEditingController();
  String? _accountId;
  bool _isExpense = true;
  String _cadence = 'monthly';
  late DateTime _nextDue;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final tx = widget.sourceTx;
    if (tx != null) {
      final txAccount = tx['account_id']?.toString();
      if (txAccount != null &&
          widget.accounts.any((a) => a['id']?.toString() == txAccount)) {
        _accountId = txAccount;
      }
      _descController.text =
          (tx['user_description'] ??
                  tx['merchant_name'] ??
                  tx['description'] ??
                  '')
              .toString();
      final cat = (tx['user_category'] ?? tx['category'] ?? '').toString();
      if (cat.isNotEmpty) _categoryController.text = cat;
      final amount = (tx['amount'] as num?)?.toDouble() ?? 0;
      _isExpense = amount <= 0;
      if (amount != 0) {
        _amountController.text = amount.abs().toStringAsFixed(2);
      }
      // The source tx covers this occurrence — the rule starts one
      // cadence later.
      final txDate = DateTime.tryParse((tx['date'] ?? '').toString());
      _nextDue = advanceCadence(txDate ?? DateTime.now(), _cadence);
    } else {
      _nextDue = advanceCadence(DateTime.now(), _cadence);
    }
    _accountId ??= widget.accounts.isNotEmpty
        ? widget.accounts.first['id']?.toString()
        : null;
  }

  @override
  void dispose() {
    _descController.dispose();
    _amountController.dispose();
    _categoryController.dispose();
    super.dispose();
  }

  Map<String, dynamic>? _selectedAccount() {
    if (_accountId == null) return null;
    for (final a in widget.accounts) {
      if (a['id']?.toString() == _accountId) {
        return Map<String, dynamic>.from(a as Map);
      }
    }
    return null;
  }

  /// Currency the amount is denominated in: the source transaction's if
  /// pre-filled, else the selected account's. Always shown as a label on
  /// the amount field so USD vs MXN is never ambiguous.
  String _currency() {
    final txCcy = (widget.sourceTx?['currency'] ?? '').toString();
    if (txCcy.isNotEmpty) return txCcy.toUpperCase();
    return (_selectedAccount()?['currency'] ?? 'USD').toString().toUpperCase();
  }

  Future<void> _submit() async {
    if (_accountId == null) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final raw = double.parse(_amountController.text.trim());
    final signed = _isExpense ? -raw : raw;

    setState(() => _saving = true);
    try {
      await widget.apiService.createRecurringRule(
        accountId: _accountId!,
        description: _descController.text.trim(),
        amount: signed,
        currency: _currency(),
        cadence: _cadence,
        nextDueDate: _nextDue,
        category: _categoryController.text.trim().isEmpty
            ? null
            : _categoryController.text.trim(),
      );
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      Navigator.pop(context);
      widget.onCreated();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.recRuleCreated)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.toString().replaceFirst('Exception: ', ''))),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final currency = _currency();

    return AlertDialog(
      title: Text(l.recMakeRecurring),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  l.recExpectedNote,
                  style: TextStyle(fontSize: 12, color: context.textMuted),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: _accountId,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l.dlgTxAccount,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: widget.accounts.map<DropdownMenuItem<String>>((a) {
                    final id = a['id']?.toString();
                    final nick = (a['nickname'] ?? '').toString();
                    final name = (a['name'] ?? '').toString();
                    return DropdownMenuItem(
                      value: id,
                      child: maskAwareNameText(
                        nick.isNotEmpty ? nick : name,
                        const TextStyle(),
                      ),
                    );
                  }).toList(),
                  onChanged: (v) => setState(() => _accountId = v),
                ),
                const SizedBox(height: 12),
                SegmentedButton<bool>(
                  segments: [
                    ButtonSegment(
                      value: true,
                      icon: const Icon(Icons.arrow_downward, size: 14),
                      label: Text(l.dlgTxExpense),
                    ),
                    ButtonSegment(
                      value: false,
                      icon: const Icon(Icons.arrow_upward, size: 14),
                      label: Text(l.dlgTxIncome),
                    ),
                  ],
                  selected: {_isExpense},
                  onSelectionChanged: (s) =>
                      setState(() => _isExpense = s.first),
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _amountController,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                      RegExp(r'^[0-9]*\.?[0-9]{0,2}'),
                    ),
                  ],
                  decoration: InputDecoration(
                    labelText: l.dlgTxAmount,
                    // Always label the amount with its currency code —
                    // USD vs MXN must never be ambiguous.
                    prefixText: '$currency ',
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  validator: (v) {
                    final raw = double.tryParse((v ?? '').trim());
                    if (raw == null) return l.dlgTxAmountRequired;
                    if (raw <= 0) return l.dlgTxAmountPositive;
                    return null;
                  },
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _descController,
                  decoration: InputDecoration(
                    labelText: l.dlgTxDescription,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  textCapitalization: TextCapitalization.sentences,
                  validator: (v) => (v ?? '').trim().isEmpty
                      ? l.dlgTxDescriptionRequired
                      : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _categoryController,
                  decoration: InputDecoration(
                    labelText: l.dlgTxCategory,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _cadence,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: l.recRepeats,
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        items: [
                          for (final c in kRecurringCadences)
                            DropdownMenuItem(
                              value: c,
                              child: Text(cadenceLabel(l, c)),
                            ),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() => _cadence = v);
                        },
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: InkWell(
                        onTap: () async {
                          final picked = await showDatePicker(
                            context: context,
                            initialDate: _nextDue,
                            firstDate: DateTime.now().subtract(
                              const Duration(days: 366),
                            ),
                            lastDate: DateTime.now().add(
                              const Duration(days: 365 * 3),
                            ),
                          );
                          if (picked != null) {
                            setState(() => _nextDue = picked);
                          }
                        },
                        child: InputDecorator(
                          decoration: InputDecoration(
                            labelText: l.recNextDueDate,
                            border: const OutlineInputBorder(),
                            isDense: true,
                          ),
                          child: Text(DateFormat.yMMMd().format(_nextDue)),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: (_saving || _accountId == null) ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l.recCreateRule),
        ),
      ],
    );
  }
}
