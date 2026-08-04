import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../theme/buttons.dart';
import '../theme/fields.dart';
import '../theme/menus.dart';
import '../theme/palette.dart';
import '../utils/mask_aware_name.dart';
import '../utils/recurrence.dart';
import '../utils/theme_colors.dart';
import 'connected_segments.dart';

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

/// Opens the "Make recurring" panel with the same width split every other
/// house form panel uses (`openAddTransactionPanel`, which this dialog is
/// the twin of): a modal bottom sheet on narrow layouts — thumb-reachable,
/// primary action pinned above the soft keyboard — and the AlertDialog
/// shell on wide.
///
/// Like its twin, the split reads the window width via MediaQuery
/// deliberately: it decides which MODAL to launch over the whole screen,
/// not how to lay out content inside a card, so there is no inner
/// LayoutBuilder constraint to prefer (the sheet's own gutters do come
/// from an inner LayoutBuilder, per the house rule).
///
/// Callers should route through here rather than calling `showDialog`
/// with [AddRecurringRuleDialog] directly, or the two presentations
/// diverge again.
Future<void> openAddRecurringRulePanel(
  BuildContext context, {
  required List<dynamic> accounts,
  required ApiService apiService,
  required VoidCallback onCreated,
  Map<String, dynamic>? sourceTx,
}) {
  Widget panel({required bool asSheet}) => AddRecurringRuleDialog(
    accounts: accounts,
    apiService: apiService,
    onCreated: onCreated,
    sourceTx: sourceTx,
    asSheet: asSheet,
  );
  if (MediaQuery.sizeOf(context).width < kCompactLayoutBelow) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      // Same tone main.dart's cardTheme uses, so the sheet lands on the
      // same surface as the wide-layout dialog shell.
      backgroundColor: BrandPalette.cardSurface(Theme.of(context).brightness),
      builder: (sheetContext) => ConstrainedBox(
        // Cap below full height so it still reads as a sheet; the panel's
        // inner scroll view handles longer content.
        constraints: BoxConstraints(
          maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.9,
        ),
        child: panel(asSheet: true),
      ),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => panel(asSheet: false),
  );
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

  /// True when hosted inside `showModalBottomSheet` (narrow layouts):
  /// renders the sheet shell (header + scrollable body + pinned action
  /// row that stays above the soft keyboard) instead of the AlertDialog
  /// shell. Callers should go through [openAddRecurringRulePanel], which
  /// does the width split.
  final bool asSheet;

  const AddRecurringRuleDialog({
    super.key,
    required this.accounts,
    required this.apiService,
    required this.onCreated,
    this.sourceTx,
    this.asSheet = false,
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

  /// The house field decoration ([houseFieldDecoration]), which this
  /// dialog previously carried as its own private copy of the recipe.
  InputDecoration _fieldDecoration({
    required String labelText,
    String? prefixText,
  }) {
    return houseFieldDecoration(
      context,
      labelText: labelText,
      prefixText: prefixText,
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return widget.asSheet ? _sheetShell(l) : _dialogShell(l);
  }

  /// Wide-layout shell — the AlertDialog presentation (house recipe from
  /// AddTransactionDialog._dialogShell). Right-aligned compact actions
  /// are correct here (pointer surface); only the sheet gets the
  /// full-bleed primary.
  Widget _dialogShell(AppLocalizations l) {
    return AlertDialog(
      // House dialog shell (TxFiltersDialog._dialogShell): card tone +
      // titleLarge so this twin matches the add-transaction dialog.
      backgroundColor: BrandPalette.cardSurface(Theme.of(context).brightness),
      titleTextStyle: Theme.of(context).textTheme.titleLarge,
      title: Text(l.recMakeRecurring),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(child: _form(l)),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: (_saving || _accountId == null) ? null : _submit,
          child: _primaryChild(l),
        ),
      ],
    );
  }

  /// Narrow-layout shell for `showModalBottomSheet`: header + scrollable
  /// body with the action row pinned at the bottom of the sheet. The
  /// viewInsets padding keeps the primary clear of the soft keyboard —
  /// in the centered AlertDialog the actions scrolled out of reach
  /// behind the keyboard at 390px.
  Widget _sheetShell(AppLocalizations l) {
    // Gutters off the sheet's INNER constraint (house rule — never
    // MediaQuery): 16 on phones, 24 once the sheet is wide.
    return LayoutBuilder(
      builder: (context, constraints) {
        final hPad = constraints.maxWidth < 420 ? 16.0 : 24.0;
        return Padding(
          padding: EdgeInsets.only(
            left: hPad,
            right: hPad,
            bottom: 16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DefaultTextStyle(
                // Explicit titleLarge, matching the dialog shell's
                // titleTextStyle so both presentations share one header
                // size.
                style: Theme.of(context).textTheme.titleLarge!,
                child: Text(l.recMakeRecurring),
              ),
              const SizedBox(height: 8),
              // Hairline between the fixed header and the scrollable
              // body: gives the scrolling content a visible edge to
              // slide under.
              Divider(height: 1, color: context.hairline),
              Flexible(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _form(l),
                  ),
                ),
              ),
              Divider(height: 1, color: context.hairline),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(
                    onPressed: _saving ? null : () => Navigator.pop(context),
                    child: Text(l.actionCancel),
                  ),
                  const SizedBox(width: 8),
                  // Full-bleed primary on the touch surface, per the
                  // theme/buttons.dart touch-width rule (>=48dp tall).
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: (_saving || _accountId == null)
                          ? null
                          : _submit,
                      child: _primaryChild(l),
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

  /// Primary-action label shared by both shells: spinner while saving.
  Widget _primaryChild(AppLocalizations l) {
    return _saving
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(l.recCreateRule);
  }

  /// The form fields shared by both shells (the shells provide the
  /// scrolling and the actions).
  Widget _form(AppLocalizations l) {
    final currency = _currency();
    return Form(
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
            dropdownColor: houseDropdownColor(context),
            borderRadius: kMenuRadius,
            decoration: _fieldDecoration(labelText: l.dlgTxAccount),
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
          // House connected button group, matching the
          // add-transaction dialog's Expense/Income toggle.
          ConnectedSegments<bool>(
            segments: [
              ConnectedSegment(
                value: true,
                icon: Icons.arrow_downward,
                label: l.dlgTxExpense,
              ),
              ConnectedSegment(
                value: false,
                icon: Icons.arrow_upward,
                label: l.dlgTxIncome,
              ),
            ],
            selected: _isExpense,
            onSelected: (v) => setState(() => _isExpense = v),
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _amountController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(
                RegExp(r'^[0-9]*\.?[0-9]{0,2}'),
              ),
            ],
            // Always label the amount with its currency code —
            // USD vs MXN must never be ambiguous.
            decoration: _fieldDecoration(
              labelText: l.dlgTxAmount,
              prefixText: '$currency ',
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
            decoration: _fieldDecoration(labelText: l.dlgTxDescription),
            textCapitalization: TextCapitalization.sentences,
            validator: (v) =>
                (v ?? '').trim().isEmpty ? l.dlgTxDescriptionRequired : null,
          ),
          const SizedBox(height: 12),
          TextFormField(
            controller: _categoryController,
            decoration: _fieldDecoration(labelText: l.dlgTxCategory),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  initialValue: _cadence,
                  isExpanded: true,
                  dropdownColor: houseDropdownColor(context),
                  borderRadius: kMenuRadius,
                  decoration: _fieldDecoration(labelText: l.recRepeats),
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
                  // Match the field's own corners so the splash
                  // stays inside.
                  borderRadius: BorderRadius.circular(kHouseFieldRadius),
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
                    decoration: _fieldDecoration(labelText: l.recNextDueDate),
                    child: Text(DateFormat.yMMMd().format(_nextDue)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
