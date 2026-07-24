import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/mask_aware_name.dart';
import '../utils/recurrence.dart';
import '../utils/theme_colors.dart';
import 'add_recurring_rule_dialog.dart' show cadenceLabel;

/// Dialog for manually entering a transaction — for cash spend, gifts,
/// reimbursements, anything Plaid never sees. Default sign convention
/// matches the rest of the app: amount < 0 = outflow (expense),
/// amount > 0 = inflow (income). This mirrors the Plaid sync path
/// which negates Plaid's "outflow-positive" amounts on import (see
/// `backend/src/services/sync.rs`). The UI hides that with a clearer
/// "Expense / Income" toggle and computes the sign at submit time.
class AddTransactionDialog extends StatefulWidget {
  final List<dynamic> accounts;
  final ApiService apiService;
  final VoidCallback onCreated;

  /// Category suggestions surfaced via autocomplete on the Category field.
  /// These are hints only — a free-typed value not in the list is still
  /// accepted. The call site supplies the list; defaults to empty so the
  /// dialog compiles/renders fine when no suggestions are wired.
  final List<String> categorySuggestions;

  /// Account preselected in the dropdown. Used by account-scoped hosts
  /// (the per-account transactions panel) so "+ Add transaction" lands on
  /// the account the user is already looking at. Ignored when it doesn't
  /// match any entry in [accounts]; the user can still switch accounts.
  final String? initialAccountId;

  /// Edit mode: the manual transaction (a row map from the transactions
  /// payload, `source == 'manual'`) being edited. When set, every field
  /// pre-fills from the row, the "Repeats" rule option is hidden (a rule
  /// belongs to creation, not correction), and submit PUTs an update to
  /// the existing row instead of creating a new one. Null = add mode.
  final Map<String, dynamic>? editTransaction;

  const AddTransactionDialog({
    super.key,
    required this.accounts,
    required this.apiService,
    required this.onCreated,
    this.categorySuggestions = const [],
    this.initialAccountId,
    this.editTransaction,
  });

  @override
  State<AddTransactionDialog> createState() => _AddTransactionDialogState();
}

class _AddTransactionDialogState extends State<AddTransactionDialog> {
  final _formKey = GlobalKey<FormState>();
  final _descController = TextEditingController();
  final _amountController = TextEditingController();
  final _categoryController = TextEditingController();
  final _categoryFocus = FocusNode();
  final _notesController = TextEditingController();
  DateTime _date = DateTime.now();
  bool _isExpense = true;
  String? _accountId;
  bool _saving = false;

  /// "Repeats" cadence, or null for a one-off transaction. When set, a
  /// recurring rule is created alongside the transaction — expected-only
  /// (it feeds the cash-flow "Recurring" card; nothing auto-posts). The
  /// first due date is the entered date advanced one cadence, since the
  /// transaction being added already covers the current occurrence.
  String? _repeats;

  bool get _isEditing => widget.editTransaction != null;

  @override
  void initState() {
    super.initState();
    final edit = widget.editTransaction;
    if (edit != null) {
      // Pre-fill everything from the row being edited, using the same
      // EFFECTIVE values the list shows (override-first) — the server
      // clears the user_* overrides on save, so what's in the fields is
      // exactly what the row will display afterwards.
      final amt = ((edit['amount'] as num?)?.toDouble() ?? 0.0);
      // Storage sign convention: negative = outflow (expense).
      _isExpense = amt < 0;
      _amountController.text = amt.abs().toStringAsFixed(2);
      final parsedDate = DateTime.tryParse((edit['date'] ?? '').toString());
      if (parsedDate != null) _date = parsedDate;
      final userDesc = (edit['user_description'] ?? '').toString().trim();
      _descController.text = userDesc.isNotEmpty
          ? userDesc
          : (edit['description'] ?? '').toString();
      final userCat = (edit['user_category'] ?? '').toString().trim();
      final rawCat = (edit['category'] ?? '').toString().trim();
      // The backend serializes a NULL category as the "Uncategorized"
      // sentinel in list payloads — don't surface that as an editable
      // value or saving would persist it as a real category.
      _categoryController.text = userCat.isNotEmpty
          ? userCat
          : (rawCat == 'Uncategorized' ? '' : rawCat);
      _notesController.text = (edit['user_notes'] ?? '').toString();
      final acctId = edit['account_id']?.toString();
      if (acctId != null &&
          widget.accounts.any((a) => a['id']?.toString() == acctId)) {
        _accountId = acctId;
        return;
      }
      // Account-scoped payloads omit account_id; fall through to the
      // host's preselect (the panel's own account) / default pick.
    }
    // Caller-preselected account (account-scoped hosts) wins when it
    // actually exists in the list.
    final preferred = widget.initialAccountId;
    if (preferred != null &&
        widget.accounts.any((a) => a['id']?.toString() == preferred)) {
      _accountId = preferred;
      return;
    }
    // Default to the first non-credit account that has a non-null balance.
    for (final a in widget.accounts) {
      final t = (a['account_type'] ?? '').toString().toLowerCase();
      if (t == 'credit' || t == 'credit card') continue;
      _accountId = a['id']?.toString();
      break;
    }
    _accountId ??=
        widget.accounts.isNotEmpty ? widget.accounts.first['id']?.toString() : null;
  }

  @override
  void dispose() {
    _descController.dispose();
    _amountController.dispose();
    _categoryController.dispose();
    _categoryFocus.dispose();
    _notesController.dispose();
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

  Future<void> _submit() async {
    final account = _selectedAccount();
    if (account == null) return;
    // Inline validation lives on the TextFormFields now; gate submit on it.
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final desc = _descController.text.trim();
    final raw = double.parse(_amountController.text.trim());
    // App convention: expense = negative, income = positive.
    final signed = _isExpense ? -raw : raw;
    final currency =
        (account['currency'] ?? 'USD').toString().toUpperCase();

    setState(() => _saving = true);
    try {
      if (_isEditing) {
        await widget.apiService.updateManualTransaction(
          id: widget.editTransaction!['id'].toString(),
          accountId: _accountId!,
          date: _date,
          description: desc,
          amount: signed,
          currency: currency,
          category: _categoryController.text.trim().isEmpty
              ? null
              : _categoryController.text.trim(),
          notes: _notesController.text.trim().isEmpty
              ? null
              : _notesController.text.trim(),
        );
      } else {
        await widget.apiService.createManualTransaction(
          accountId: _accountId!,
          date: _date,
          description: desc,
          amount: signed,
          currency: currency,
          category: _categoryController.text.trim().isEmpty
              ? null
              : _categoryController.text.trim(),
          notes: _notesController.text.trim().isEmpty
              ? null
              : _notesController.text.trim(),
        );
      }
      // The transaction itself is committed; the optional rule is a
      // separate best-effort write. A rule failure must not look like a
      // failed transaction (retrying would double-post), so it reports
      // its own error and the dialog still closes. (Edit mode never sets
      // _repeats — the Repeats field is hidden there.)
      String? ruleError;
      if (_repeats != null) {
        try {
          await widget.apiService.createRecurringRule(
            accountId: _accountId!,
            description: desc,
            amount: signed,
            currency: currency,
            cadence: _repeats!,
            nextDueDate: advanceCadence(_date, _repeats!),
            category: _categoryController.text.trim().isEmpty
                ? null
                : _categoryController.text.trim(),
          );
        } catch (e) {
          ruleError = e.toString().replaceFirst('Exception: ', '');
        }
      }
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      Navigator.pop(context);
      widget.onCreated();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(ruleError ??
                (_isEditing
                    ? l.dlgTxUpdated
                    : _repeats != null
                        ? '${l.dlgTxAdded} · ${l.recRuleCreated}'
                        : l.dlgTxAdded))),
      );
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
    final selectedAcct = _selectedAccount();
    final currency =
        (selectedAcct?['currency'] ?? 'USD').toString().toUpperCase();

    return AlertDialog(
      title: Text(_isEditing ? l.dlgTxEditTitle : l.dlgTxTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.accounts.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text(
                    l.dlgTxNoAccounts,
                    style: TextStyle(color: context.warning),
                  ),
                ),
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
                  final label = nick.isNotEmpty ? nick : name;
                  final acctCurrency =
                      (a['currency'] ?? 'USD').toString().toUpperCase();
                  // The account's native currency rides as its own
                  // non-shrinking token ("Checking · MXN") so picking an
                  // account states the entry currency up front — the long
                  // name ellipsizes, the currency never does.
                  return DropdownMenuItem(
                    value: id,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Flexible(
                          child: maskAwareNameText(label, const TextStyle()),
                        ),
                        Text(
                          ' · $acctCurrency',
                          maxLines: 1,
                          style: TextStyle(color: context.textMuted),
                        ),
                      ],
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
                    // Expense = outflow = money leaving (down), matching the
                    // OUTFLOW arrow on every transaction row and detail panel.
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
              Row(
                children: [
                  Expanded(
                    // Amount is the most cramped field (currency prefix +
                    // digits) — it gets the wider flex; the date can afford
                    // to scale down (FittedBox below).
                    flex: 3,
                    child: TextFormField(
                      controller: _amountController,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'^[0-9]*\.?[0-9]{0,2}')),
                      ],
                      decoration: InputDecoration(
                        labelText: l.dlgTxAmount,
                        prefixText: '$currency ',
                        // Material hides prefixText until the field is
                        // focused or non-empty; force the label to float so
                        // the entry currency is visible from the start.
                        floatingLabelBehavior: FloatingLabelBehavior.always,
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
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 2,
                    child: InkWell(
                      onTap: () async {
                        final picked = await showDatePicker(
                          context: context,
                          initialDate: _date,
                          firstDate:
                              DateTime.now().subtract(const Duration(days: 365 * 5)),
                          lastDate: DateTime.now(),
                        );
                        if (picked != null) setState(() => _date = picked);
                      },
                      child: InputDecorator(
                        decoration: InputDecoration(
                          labelText: l.dlgTxDate,
                          border: const OutlineInputBorder(),
                          isDense: true,
                        ),
                        // Scale down rather than overflow in the narrower
                        // flex on phone widths (390px dialogs).
                        child: FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: AlignmentDirectional.centerStart,
                          child: Text(DateFormat('MMM d, y').format(_date)),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _descController,
                decoration: InputDecoration(
                  labelText: l.dlgTxDescription,
                  hintText: l.dlgTxDescriptionHint,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                textCapitalization: TextCapitalization.sentences,
                validator: (v) =>
                    (v ?? '').trim().isEmpty ? l.dlgTxDescriptionRequired : null,
              ),
              const SizedBox(height: 12),
              _buildCategoryField(l),
              const SizedBox(height: 12),
              TextField(
                controller: _notesController,
                decoration: InputDecoration(
                  labelText: l.dlgTxNotes,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
                maxLines: 2,
              ),
              // "Repeats" — creates a recurring rule alongside the
              // transaction (expected-only; nothing auto-posts). Hidden
              // in edit mode: correcting an existing row shouldn't mint
              // a new rule.
              if (!_isEditing) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String?>(
                  initialValue: _repeats,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: l.recRepeats,
                    border: const OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: [
                    DropdownMenuItem<String?>(
                      value: null,
                      child: Text(l.recRepeatsNever),
                    ),
                    for (final c in kRecurringCadences)
                      DropdownMenuItem<String?>(
                        value: c,
                        child: Text(cadenceLabel(l, c)),
                      ),
                  ],
                  onChanged: (v) => setState(() => _repeats = v),
                ),
              ],
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
          onPressed:
              (_saving || _accountId == null) ? null : _submit,
          child: _saving
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_isEditing ? l.actionSave : l.actionAdd),
        ),
      ],
    );
  }

  /// Category input with type-ahead suggestions. Backed by
  /// [RawAutocomplete] so we can keep the existing [InputDecoration]/
  /// validator and reuse [_categoryController] — the same controller the
  /// submit path reads — as the field's text source. Suggestions are hints
  /// only: a free-typed value not in the list is still accepted.
  Widget _buildCategoryField(AppLocalizations l) {
    return RawAutocomplete<String>(
      textEditingController: _categoryController,
      focusNode: _categoryFocus,
      optionsBuilder: (TextEditingValue value) {
        final query = value.text.trim().toLowerCase();
        if (query.isEmpty) return widget.categorySuggestions;
        return widget.categorySuggestions.where(
          (s) => s.toLowerCase().contains(query),
        );
      },
      fieldViewBuilder:
          (context, controller, focusNode, onFieldSubmitted) {
        return TextFormField(
          controller: controller,
          focusNode: focusNode,
          decoration: InputDecoration(
            labelText: l.dlgTxCategory,
            hintText: l.dlgTxCategoryHint,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onFieldSubmitted: (_) => onFieldSubmitted(),
        );
      },
      optionsViewBuilder: (context, onSelected, options) {
        final opts = options.toList();
        return Align(
          alignment: Alignment.topLeft,
          child: Material(
            elevation: 4,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 200, maxWidth: 420),
              child: ListView.builder(
                padding: EdgeInsets.zero,
                shrinkWrap: true,
                itemCount: opts.length,
                itemBuilder: (context, index) {
                  final option = opts[index];
                  return InkWell(
                    onTap: () => onSelected(option),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      child: Text(option),
                    ),
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }
}
