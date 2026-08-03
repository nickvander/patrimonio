import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../theme/menus.dart';
import '../theme/palette.dart';
import '../utils/currency.dart';
import '../utils/mask_aware_name.dart';
import '../utils/quick_entry_defaults.dart';
import '../utils/theme_colors.dart';
import 'connected_segments.dart';

/// Opens the mobile quick-capture sheet: the short path for a cash spend
/// typed at the counter, as opposed to the Add-transaction panel's full
/// form (description, notes, repeats, edit mode).
///
/// Always a modal bottom sheet — the presentation the compact FAB that
/// launches it already implies — using the same shell recipe the
/// Add-transaction panel proved out (scroll-controlled, safe-area, drag
/// handle, the card tone rather than the seeded M3 container). It is not
/// mobile-ONLY though: the sheet's own inner [LayoutBuilder] caps and
/// centres its content, so opening it on a desktop-width window reads as
/// a form rather than a stretched banner.
///
/// [recentTransactions] is the host's already-loaded transaction list; it
/// is read only to DERIVE defaults (see `utils/quick_entry_defaults.dart`)
/// and never displayed. [onFullForm] is the escape hatch to the full
/// Add-transaction panel — the sheet closes itself first, so the callback
/// can open the panel on the host's own context.
Future<void> openQuickEntrySheet(
  BuildContext context, {
  required List<dynamic> accounts,
  required ApiService apiService,
  required VoidCallback onCreated,
  List<dynamic> recentTransactions = const [],
  List<String> categorySuggestions = const [],
  VoidCallback? onFullForm,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    backgroundColor: BrandPalette.cardSurface(Theme.of(context).brightness),
    builder: (sheetContext) => ConstrainedBox(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.9,
      ),
      child: QuickEntrySheet(
        accounts: accounts,
        apiService: apiService,
        onCreated: onCreated,
        recentTransactions: recentTransactions,
        categorySuggestions: categorySuggestions,
        onFullForm: onFullForm,
      ),
    ),
  );
}

/// Quick capture for a cash transaction: amount first with the keypad
/// already up, then a one-tap category chip, with the account, currency
/// and date pre-filled from what the user actually did last.
///
/// Deliberately NOT a second add-transaction form. It writes through the
/// same `createManualTransaction` endpoint with the same storage sign
/// convention as the full AddTransactionDialog; what it drops is everything that
/// costs a tap and can be corrected later (notes, recurrence, a required
/// description). Anything it cannot express hands off to the full panel
/// via "More options".
///
/// Two design rules it is built to keep:
/// * **Every default is visible and overridable.** The account, the
///   currency, the date and the direction are all rendered as live
///   controls, and the account carries a "Last used" caption when it came
///   from the user's own history rather than a fallback. A fast path that
///   silently guesses wrong is worse than a slow one.
/// * **Saving does not navigate.** A successful write leaves the sheet
///   open, resets only the amount and note, and returns focus to the
///   amount field, so a second expense is one more entry rather than a
///   second trip through the FAB. The confirmation is an inline strip
///   with Undo (see [_undo]) instead of the transactions tab's SnackBar:
///   a `ScaffoldMessenger` SnackBar renders on the Scaffold BELOW this
///   modal route, i.e. behind the sheet, so the house idiom would have
///   put the confirmation somewhere the user cannot see it.
class QuickEntrySheet extends StatefulWidget {
  const QuickEntrySheet({
    super.key,
    required this.accounts,
    required this.apiService,
    required this.onCreated,
    this.recentTransactions = const [],
    this.categorySuggestions = const [],
    this.onFullForm,
  });

  final List<dynamic> accounts;
  final ApiService apiService;

  /// Fired after every write that changes the server (a save AND an
  /// undo), so the host can refresh in place. It must NOT navigate.
  final VoidCallback onCreated;

  /// The host's loaded transactions, read only to derive defaults.
  final List<dynamic> recentTransactions;

  /// All-source category labels (the host's `distinctPrettyCategories`),
  /// used to pad the recency-ordered chips for a user who has not typed
  /// a manual transaction yet.
  final List<String> categorySuggestions;

  /// Escape hatch to the full Add-transaction panel. Hidden when null.
  final VoidCallback? onFullForm;

  @override
  State<QuickEntrySheet> createState() => _QuickEntrySheetState();
}

/// Field values of the entry the Undo button would delete, so undoing
/// puts the user back where they were (a mistyped amount is the reason
/// most people reach for Undo) instead of just erasing the row.
class _UndoableEntry {
  const _UndoableEntry({
    required this.id,
    required this.amountText,
    required this.note,
    required this.isSpend,
  });

  final String id;
  final String amountText;
  final String note;
  final bool isSpend;
}

class _QuickEntrySheetState extends State<QuickEntrySheet> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _amountFocus = FocusNode();
  final _noteController = TextEditingController();
  final _categoryController = TextEditingController();
  final _categoryFocus = FocusNode();

  /// Spending by default — that is what the sheet exists for. Stored as
  /// a NEGATIVE amount; see [_submit].
  bool _isSpend = true;
  DateTime _date = DateTime.now();
  String? _accountId;

  /// The account derived from the user's own last manual entry, or null
  /// when nothing in the history qualified. Only used to decide whether
  /// the "Last used" caption is honest.
  String? _lastUsedAccountId;

  List<String> _chipCategories = const [];
  String? _selectedCategory;

  /// True once the user picks "Other…" — the free-text category field
  /// replaces the chip selection as the source of truth.
  bool _customCategory = false;

  bool _busy = false;

  /// Inline confirmation / error text under the form. Null = hidden.
  String? _notice;
  bool _noticeIsError = false;

  /// The last saved row, while Undo can still reach it. Null whenever
  /// there is nothing to undo — including after a save whose response
  /// carried no id, where the write succeeded but the handle did not.
  _UndoableEntry? _undoable;

  @override
  void initState() {
    super.initState();
    _lastUsedAccountId = lastManualAccountId(
      widget.recentTransactions,
      widget.accounts,
    );
    _accountId = _lastUsedAccountId ?? _firstNonCreditAccountId();
    _chipCategories = recentManualCategories(
      widget.recentTransactions,
      fallback: widget.categorySuggestions,
    );
  }

  @override
  void dispose() {
    _amountController.dispose();
    _amountFocus.dispose();
    _noteController.dispose();
    _categoryController.dispose();
    _categoryFocus.dispose();
    super.dispose();
  }

  /// Same fallback ladder the Add-transaction dialog uses, so the two
  /// flows never disagree about where an entry lands when the user has
  /// no manual history yet.
  String? _firstNonCreditAccountId() {
    for (final a in widget.accounts) {
      if (a is! Map) continue;
      final t = (a['account_type'] ?? '').toString().toLowerCase();
      if (t == 'credit' || t == 'credit card') continue;
      final id = a['id']?.toString();
      if (id != null && id.isNotEmpty) return id;
    }
    for (final a in widget.accounts) {
      if (a is Map && a['id'] != null) return a['id'].toString();
    }
    return null;
  }

  Map<String, dynamic>? _selectedAccount() {
    if (_accountId == null) return null;
    for (final a in widget.accounts) {
      if (a is Map && a['id']?.toString() == _accountId) {
        return Map<String, dynamic>.from(a);
      }
    }
    return null;
  }

  String get _currency =>
      (_selectedAccount()?['currency'] ?? 'USD').toString().toUpperCase();

  String get _effectiveCategory => _customCategory
      ? _categoryController.text.trim()
      : (_selectedCategory ?? '');

  /// The manual endpoint stores a description, and demanding one is
  /// exactly the friction quick entry removes. The note wins when typed;
  /// otherwise the chosen category names the row, and a bare amount falls
  /// back to "Cash" — which is what it is. The field's hint shows the
  /// value that will actually be stored, so the fallback is never a
  /// surprise.
  String _effectiveDescription(AppLocalizations l) {
    final typed = _noteController.text.trim();
    if (typed.isNotEmpty) return typed;
    final category = _effectiveCategory;
    return category.isNotEmpty ? category : l.qeDefaultDescription;
  }

  bool _isToday(DateTime d) {
    final now = DateTime.now();
    return d.year == now.year && d.month == now.month && d.day == now.day;
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime.now().subtract(const Duration(days: 365 * 5)),
      lastDate: DateTime.now(),
    );
    if (picked != null && mounted) setState(() => _date = picked);
  }

  void _openFullForm() {
    final onFullForm = widget.onFullForm;
    if (onFullForm == null) return;
    Navigator.of(context).pop();
    onFullForm();
  }

  Future<void> _submit(AppLocalizations l) async {
    final account = _selectedAccount();
    if (account == null) return;
    if (!(_formKey.currentState?.validate() ?? false)) return;
    final magnitude = double.parse(_amountController.text.trim());
    // STORAGE SIGN CONVENTION — outflow is NEGATIVE (see the doc comment
    // on ApiService.createManualTransaction; this is the opposite of
    // Plaid's raw sign, which is normalized before this layer). Quick
    // entry defaults to "Spent", so the common path must reach the API
    // as a negative amount; getting this backwards would silently
    // corrupt cash-flow and category totals rather than fail loudly.
    final signed = _isSpend ? -magnitude : magnitude;
    final currency = _currency;
    final category = _effectiveCategory;
    final description = _effectiveDescription(l);
    final amountText = _amountController.text.trim();
    final note = _noteController.text;

    setState(() {
      _busy = true;
      _notice = null;
      _undoable = null;
    });
    try {
      final id = await widget.apiService.createManualTransactionReturningId(
        accountId: _accountId!,
        date: _date,
        description: description,
        amount: signed,
        currency: currency,
        category: category.isEmpty ? null : category,
      );
      if (!mounted) return;
      // gen-l10n orders these (amount, label) — the same order the
      // template reads, because the placeholder names were picked so
      // declaration / template / alphabetical order all agree.
      final notice = l.qeSaved(
        formatCurrencyAmount(signed, currency),
        description,
      );
      setState(() {
        _busy = false;
        _notice = notice;
        _noticeIsError = false;
        // No id back means the row is saved but unreachable for Undo;
        // hide the affordance rather than offer one that cannot work.
        _undoable = id == null
            ? null
            : _UndoableEntry(
                id: id,
                amountText: amountText,
                note: note,
                isSpend: _isSpend,
              );
        // Reset only what is entry-specific. Account, category, direction
        // and date stay put — the next expense is usually the same shape.
        _amountController.clear();
        _noteController.clear();
      });
      widget.onCreated();
      _amountFocus.requestFocus();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _notice = e.toString().replaceFirst('Exception: ', '');
        _noticeIsError = true;
      });
    }
  }

  Future<void> _undo(AppLocalizations l) async {
    final entry = _undoable;
    if (entry == null) return;
    setState(() => _busy = true);
    try {
      await widget.apiService.deleteTransaction(entry.id);
      if (!mounted) return;
      setState(() {
        _busy = false;
        _undoable = null;
        _notice = l.qeUndone;
        _noticeIsError = false;
        // Put the user back in front of what they typed, so an Undo
        // prompted by a typo is a correction, not a re-entry.
        _amountController.text = entry.amountText;
        _noteController.text = entry.note;
        _isSpend = entry.isSpend;
      });
      widget.onCreated();
      _amountFocus.requestFocus();
    } catch (_) {
      if (!mounted) return;
      // The row is still there; keep the handle so a retry is possible.
      setState(() {
        _busy = false;
        _notice = l.qeUndoFailed;
        _noticeIsError = true;
      });
    }
  }

  /// House input recipe, byte-for-byte the Add-transaction dialog's:
  /// filled rounded borderless, keeping labelText + isDense (the widget
  /// tests find these fields by their label).
  InputDecoration _fieldDecoration({
    required String labelText,
    String? hintText,
    String? helperText,
    String? prefixText,
    FloatingLabelBehavior? floatingLabelBehavior,
  }) {
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      helperText: helperText,
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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Gutters and the content cap come off the sheet's INNER constraint
    // (house rule — never MediaQuery screen width): 16 on phones, 24 once
    // the sheet is wider, and the form never stretches past 520 so a
    // desktop-width window gets a form, not a banner.
    return LayoutBuilder(
      builder: (context, constraints) {
        final hPad = constraints.maxWidth < 420 ? 16.0 : 24.0;
        return Padding(
          padding: EdgeInsets.only(
            left: hPad,
            right: hPad,
            // Keeps the primary action clear of the soft keyboard, which
            // is up from the moment the sheet opens.
            bottom: 16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Align(
            alignment: Alignment.topCenter,
            // heightFactor 1.0 keeps the sheet hugging its content;
            // without it the Align would expand to the full 90% cap.
            heightFactor: 1.0,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(l),
                  const SizedBox(height: 8),
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
                  if (_notice != null) _noticeStrip(l),
                  const SizedBox(height: 12),
                  FilledButton(
                    style: FilledButton.styleFrom(
                      minimumSize: const Size.fromHeight(48),
                    ),
                    onPressed: (_busy || _accountId == null)
                        ? null
                        : () => _submit(l),
                    child: _busy
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l.actionSave),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _header(AppLocalizations l) {
    return Row(
      children: [
        Expanded(
          child: DefaultTextStyle(
            style: Theme.of(context).textTheme.titleLarge!,
            child: Text(l.qeTitle),
          ),
        ),
        if (widget.onFullForm != null)
          TextButton(
            onPressed: _busy ? null : _openFullForm,
            child: Text(l.qeFullForm),
          ),
      ],
    );
  }

  /// Inline confirmation, standing in for the tab's Undo SnackBar (which
  /// would render behind this modal route). Same contract: it states what
  /// landed and offers exactly one Undo for the most recent action.
  Widget _noticeStrip(AppLocalizations l) {
    final accent = _noticeIsError ? context.warning : context.positive;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: context.tileSurface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(
              _noticeIsError ? Icons.error_outline : Icons.check_circle_outline,
              size: 18,
              color: accent,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _notice!,
                style: TextStyle(color: context.textPrimary),
              ),
            ),
            if (_undoable != null) ...[
              const SizedBox(width: 8),
              TextButton(
                onPressed: _busy ? null : () => _undo(l),
                child: Text(l.txUndo),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _form(AppLocalizations l) {
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
          // "Spent" / "Received", not "Expense" / "Income": quick entry is
          // for money leaving a pocket, and the plain verb is what makes
          // the stored sign legible at the counter. Same house connected
          // group and same arrow semantics as the full dialog.
          ConnectedSegments<bool>(
            segments: [
              ConnectedSegment(
                value: true,
                icon: Icons.arrow_downward,
                label: l.qeSpent,
              ),
              ConnectedSegment(
                value: false,
                icon: Icons.arrow_upward,
                label: l.qeReceived,
              ),
            ],
            selected: _isSpend,
            onSelected: (v) => setState(() => _isSpend = v),
          ),
          const SizedBox(height: 12),
          // Amount first, autofocused: the keypad is up before the sheet
          // has finished settling, so the first thing the user does is
          // type the number they are looking at on the receipt.
          TextFormField(
            controller: _amountController,
            focusNode: _amountFocus,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [
              FilteringTextInputFormatter.allow(
                RegExp(r'^[0-9]*\.?[0-9]{0,2}'),
              ),
            ],
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700),
            decoration: _fieldDecoration(
              labelText: l.dlgTxAmount,
              // The account's own currency, stated up front — Material
              // hides prefixText until focus, so float the label always.
              prefixText: '$_currency ',
              floatingLabelBehavior: FloatingLabelBehavior.always,
            ),
            validator: (v) {
              final raw = double.tryParse((v ?? '').trim());
              if (raw == null) return l.dlgTxAmountRequired;
              if (raw <= 0) return l.dlgTxAmountPositive;
              return null;
            },
          ),
          const SizedBox(height: 12),
          _categoryChips(l),
          const SizedBox(height: 12),
          TextField(
            controller: _noteController,
            textCapitalization: TextCapitalization.sentences,
            // The hint IS the description that will be stored if this is
            // left blank, so the fallback is visible before saving.
            decoration: _fieldDecoration(
              labelText: l.qeNote,
              hintText: _effectiveDescription(l),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 12),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 3, child: _accountField(l)),
              const SizedBox(width: 12),
              Expanded(flex: 2, child: _dateField(l)),
            ],
          ),
        ],
      ),
    );
  }

  /// Most-recently-used categories as one-tap chips instead of a list to
  /// scroll — the chip row IS the feature; a dropdown here would cost the
  /// taps quick entry is trying to remove. "Other…" opens free text, so
  /// the shortcut never becomes a cage.
  Widget _categoryChips(AppLocalizations l) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l.dlgTxCategory,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: context.textSubtle,
          ),
        ),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final c in _chipCategories)
              ChoiceChip(
                label: Text(c),
                selected: !_customCategory && _selectedCategory == c,
                // Explicit so the 32dp chip still carries a ≥48dp touch
                // target on the phone widths this sheet is built for.
                materialTapTargetSize: MaterialTapTargetSize.padded,
                onSelected: (chosen) => setState(() {
                  _customCategory = false;
                  // Re-tapping the selected chip clears it — the only way
                  // back to "no category" once one is picked.
                  _selectedCategory = chosen ? c : null;
                }),
              ),
            ChoiceChip(
              label: Text(l.qeCategoryOther),
              selected: _customCategory,
              materialTapTargetSize: MaterialTapTargetSize.padded,
              onSelected: (chosen) {
                setState(() {
                  _customCategory = chosen;
                  if (chosen) _selectedCategory = null;
                });
                if (chosen) _categoryFocus.requestFocus();
              },
            ),
          ],
        ),
        if (_customCategory) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _categoryController,
            focusNode: _categoryFocus,
            textCapitalization: TextCapitalization.sentences,
            decoration: _fieldDecoration(
              labelText: l.dlgTxCategory,
              hintText: l.dlgTxCategoryHint,
            ),
            onChanged: (_) => setState(() {}),
          ),
        ],
      ],
    );
  }

  /// Account picker, pre-filled with the one the user most recently added
  /// a manual transaction to. The "Last used" helper appears only while
  /// that derived default is still selected, so the caption can never
  /// describe an account the user picked by hand.
  Widget _accountField(AppLocalizations l) {
    final derived =
        _lastUsedAccountId != null && _accountId == _lastUsedAccountId;
    return DropdownButtonFormField<String>(
      initialValue: _accountId,
      isExpanded: true,
      dropdownColor: houseDropdownColor(context),
      borderRadius: kMenuRadius,
      decoration: _fieldDecoration(
        labelText: l.dlgTxAccount,
        helperText: derived ? l.qeLastUsed : null,
      ),
      items: [
        for (final a in widget.accounts)
          if (a is Map)
            DropdownMenuItem<String>(
              value: a['id']?.toString(),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: maskAwareNameText(
                      (a['nickname'] ?? '').toString().isNotEmpty
                          ? a['nickname'].toString()
                          : (a['name'] ?? '').toString(),
                      const TextStyle(),
                    ),
                  ),
                  Text(
                    ' · ${(a['currency'] ?? 'USD').toString().toUpperCase()}',
                    maxLines: 1,
                    style: TextStyle(color: context.textMuted),
                  ),
                ],
              ),
            ),
      ],
      // Currency follows the account, so re-render the amount prefix too.
      onChanged: (v) => setState(() => _accountId = v),
    );
  }

  /// Date, defaulted to today and stated as "Today" rather than a date
  /// the user has to decode — still one tap to change.
  Widget _dateField(AppLocalizations l) {
    final label = _isToday(_date)
        ? l.txDateToday
        : DateFormat.yMMMd(l.localeName).format(_date);
    return InkWell(
      onTap: _busy ? null : _pickDate,
      child: InputDecorator(
        decoration: _fieldDecoration(labelText: l.dlgTxDate),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          alignment: AlignmentDirectional.centerStart,
          child: Text(label),
        ),
      ),
    );
  }
}
