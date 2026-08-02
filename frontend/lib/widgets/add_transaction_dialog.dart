import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../theme/menus.dart';
import '../theme/palette.dart';
import '../utils/mask_aware_name.dart';
import '../utils/recurrence.dart';
import '../utils/theme_colors.dart';
import 'add_recurring_rule_dialog.dart' show cadenceLabel;
import 'connected_segments.dart';

/// Opens the Add/Edit-transaction panel with the same width split the
/// filter editor proved out (transactions_tab._openFilters): a modal
/// bottom sheet on narrow layouts (thumb-reachable, primary action
/// pinned above the soft keyboard) and the AlertDialog shell on wide.
/// ALL hosts route through this helper so add and edit mode can never
/// diverge in presentation.
///
/// The split reads the window width via MediaQuery deliberately: this
/// decides which MODAL to launch over the whole screen, not how to lay
/// out content inside a card, so there is no inner LayoutBuilder
/// constraint to prefer (the sheet's gutters do come from its own inner
/// LayoutBuilder, per the house rule). 560 matches the transactions
/// tab's narrow breakpoint, which hosts this flow's filter twin.
Future<void> openAddTransactionPanel(
  BuildContext context, {
  required List<dynamic> accounts,
  required ApiService apiService,
  required VoidCallback onCreated,
  List<String> categorySuggestions = const [],
  String? initialAccountId,
  Map<String, dynamic>? editTransaction,
}) {
  Widget panel({required bool asSheet}) => AddTransactionDialog(
    accounts: accounts,
    apiService: apiService,
    onCreated: onCreated,
    categorySuggestions: categorySuggestions,
    initialAccountId: initialAccountId,
    editTransaction: editTransaction,
    asSheet: asSheet,
  );
  if (MediaQuery.sizeOf(context).width < 560) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      // Same tone main.dart's cardTheme uses — kills the pale-sage
      // seeded container in light mode and lands the dark sheet on the
      // same surface as the wide-layout dialog shell.
      backgroundColor: BrandPalette.cardSurface(Theme.of(context).brightness),
      builder: (sheetContext) => ConstrainedBox(
        // Cap the sheet below full height so it still reads as a sheet;
        // the panel's inner scroll view handles longer content.
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

  /// True when hosted inside `showModalBottomSheet` (narrow layouts):
  /// renders the sheet shell (header + scrollable body + pinned action
  /// row that stays above the soft keyboard) instead of the AlertDialog
  /// shell. Callers should go through [openAddTransactionPanel], which
  /// does the width split.
  final bool asSheet;

  const AddTransactionDialog({
    super.key,
    required this.accounts,
    required this.apiService,
    required this.onCreated,
    this.categorySuggestions = const [],
    this.initialAccountId,
    this.editTransaction,
    this.asSheet = false,
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
    _accountId ??= widget.accounts.isNotEmpty
        ? widget.accounts.first['id']?.toString()
        : null;
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
    final currency = (account['currency'] ?? 'USD').toString().toUpperCase();

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
          content: Text(
            ruleError ??
                (_isEditing
                    ? l.dlgTxUpdated
                    : _repeats != null
                    ? '${l.dlgTxAdded} · ${l.recRuleCreated}'
                    : l.dlgTxAdded),
          ),
        ),
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
    return widget.asSheet ? _sheetShell(l) : _dialogShell(l);
  }

  /// Wide-layout shell — the AlertDialog presentation (house recipe from
  /// TxFiltersDialog._dialogShell). Right-aligned compact actions are
  /// correct here (pointer surface); only the sheet gets the full-bleed
  /// primary.
  Widget _dialogShell(AppLocalizations l) {
    return AlertDialog(
      // Same tone main.dart's cardTheme uses, so the dialog matches the
      // sheet shell (and drops the pale-sage seeded container in light).
      backgroundColor: BrandPalette.cardSurface(Theme.of(context).brightness),
      // titleLarge, matching the sheet header — the AlertDialog default
      // (headlineSmall) made the two shells disagree on title size.
      titleTextStyle: Theme.of(context).textTheme.titleLarge,
      title: Text(_isEditing ? l.dlgTxEditTitle : l.dlgTxTitle),
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
  /// viewInsets padding keeps the Add button clear of the soft keyboard
  /// while any field is being edited — in the old centered AlertDialog
  /// the actions scrolled out of reach behind the keyboard at 390px.
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
                child: Text(_isEditing ? l.dlgTxEditTitle : l.dlgTxTitle),
              ),
              const SizedBox(height: 8),
              // Hairline between the fixed header and the scrollable body
              // (filter-sheet idiom): gives the scrolling content a
              // visible edge to slide under.
              Divider(height: 1, color: context.hairline),
              Flexible(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _form(l),
                  ),
                ),
              ),
              // Same hairline above the pinned action bar, separating it
              // from the content scrolling beneath.
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
                  // theme/buttons.dart touch-width rule (≥48dp tall).
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

  /// Primary-action label shared by both shells: spinner while saving,
  /// Save in edit mode, Add otherwise.
  Widget _primaryChild(AppLocalizations l) {
    return _saving
        ? const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          )
        : Text(_isEditing ? l.actionSave : l.actionAdd);
  }

  /// House input recipe (filter-panel amount fields): filled rounded
  /// borderless, KEEPING labelText + isDense — the widget tests find
  /// these fields by their label.
  InputDecoration _fieldDecoration({
    required String labelText,
    String? hintText,
    String? prefixText,
    FloatingLabelBehavior? floatingLabelBehavior,
  }) {
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      prefixText: prefixText,
      floatingLabelBehavior: floatingLabelBehavior,
      isDense: true,
      filled: true,
      fillColor: context.tileSurface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
    );
  }

  /// The form fields shared by both shells (the shells provide the
  /// scrolling and the actions).
  Widget _form(AppLocalizations l) {
    final selectedAcct = _selectedAccount();
    final currency = (selectedAcct?['currency'] ?? 'USD')
        .toString()
        .toUpperCase();

    return Form(
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
            dropdownColor: houseDropdownColor(context),
            borderRadius: kMenuRadius,
            decoration: _fieldDecoration(labelText: l.dlgTxAccount),
            items: widget.accounts.map<DropdownMenuItem<String>>((a) {
              final id = a['id']?.toString();
              final nick = (a['nickname'] ?? '').toString();
              final name = (a['name'] ?? '').toString();
              final label = nick.isNotEmpty ? nick : name;
              final acctCurrency = (a['currency'] ?? 'USD')
                  .toString()
                  .toUpperCase();
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
          // House connected button group (shared with the filter panel)
          // instead of SegmentedButton — same single-select semantics
          // (a re-tap of the current value just re-sets it, a no-op).
          ConnectedSegments<bool>(
            segments: [
              ConnectedSegment(
                value: true,
                // Expense = outflow = money leaving (down), matching the
                // OUTFLOW arrow on every transaction row and detail panel.
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
                    decimal: true,
                  ),
                  inputFormatters: [
                    FilteringTextInputFormatter.allow(
                      RegExp(r'^[0-9]*\.?[0-9]{0,2}'),
                    ),
                  ],
                  decoration: _fieldDecoration(
                    labelText: l.dlgTxAmount,
                    prefixText: '$currency ',
                    // Material hides prefixText until the field is
                    // focused or non-empty; force the label to float so
                    // the entry currency is visible from the start.
                    floatingLabelBehavior: FloatingLabelBehavior.always,
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
                      firstDate: DateTime.now().subtract(
                        const Duration(days: 365 * 5),
                      ),
                      lastDate: DateTime.now(),
                    );
                    if (picked != null) setState(() => _date = picked);
                  },
                  child: InputDecorator(
                    decoration: _fieldDecoration(labelText: l.dlgTxDate),
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
            decoration: _fieldDecoration(
              labelText: l.dlgTxDescription,
              hintText: l.dlgTxDescriptionHint,
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
            decoration: _fieldDecoration(labelText: l.dlgTxNotes),
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
              dropdownColor: houseDropdownColor(context),
              borderRadius: kMenuRadius,
              decoration: _fieldDecoration(labelText: l.recRepeats),
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
      fieldViewBuilder: (context, controller, focusNode, onFieldSubmitted) {
        return TextFormField(
          controller: controller,
          focusNode: focusNode,
          decoration: _fieldDecoration(
            labelText: l.dlgTxCategory,
            hintText: l.dlgTxCategoryHint,
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
            // House popup surface: the card tone + the 12px radius the
            // restyled inputs use, instead of the stock square Material.
            color: BrandPalette.cardSurface(Theme.of(context).brightness),
            borderRadius: BorderRadius.circular(12),
            clipBehavior: Clip.antiAlias,
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
                        horizontal: 16,
                        vertical: 12,
                      ),
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
