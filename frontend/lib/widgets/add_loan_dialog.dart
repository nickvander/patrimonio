import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../theme/menus.dart';
import '../utils/currency.dart' show moneyFormat;
import '../utils/flat_schedule.dart';
import '../utils/lending_summary.dart';
import '../utils/theme_colors.dart';
import 'connected_segments.dart';

/// One editable installment row in the custom-schedule editor. Each row
/// owns its own controllers so an inline edit doesn't rebuild the whole
/// list (and keeps cursor position stable).
class _CustomRow {
  final TextEditingController dateCtrl;
  final TextEditingController amountCtrl;

  _CustomRow(this.dateCtrl, this.amountCtrl);

  factory _CustomRow.of(String date, String amount) => _CustomRow(
    TextEditingController(text: date),
    TextEditingController(text: amount),
  );

  void dispose() {
    dateCtrl.dispose();
    amountCtrl.dispose();
  }
}

class AddLoanDialog extends StatefulWidget {
  final ApiService apiService;
  final List<dynamic> people;
  final String defaultCurrency;

  // Optional prefill — used by "Create loan from this transaction". When
  // [disbursementTxId] is set, the loan is linked to that transaction as
  // its disbursement after creation (and rolled back on a 409 conflict).
  final double? initialPrincipal;
  final String? initialCurrency;
  final DateTime? initialOriginationDate;
  final String? initialBorrowerName;
  final String? disbursementTxId;

  const AddLoanDialog({
    super.key,
    required this.apiService,
    required this.people,
    required this.defaultCurrency,
    this.initialPrincipal,
    this.initialCurrency,
    this.initialOriginationDate,
    this.initialBorrowerName,
    this.disbursementTxId,
  });

  @override
  State<AddLoanDialog> createState() => _AddLoanDialogState();
}

class _AddLoanDialogState extends State<AddLoanDialog> {
  final _principalCtrl = TextEditingController();
  final _rateCtrl = TextEditingController();
  final _termCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  // Latest borrower text, fed by the Autocomplete field's onChanged /
  // onSelected (avoids attaching a controller listener on every
  // fieldViewBuilder rebuild).
  String _borrowerText = '';
  String _currency = 'USD';
  String _interestType = 'none';
  // 'annual' or 'monthly' — the period the entered rate is in. Stored
  // faithfully so "1% / month" stays exact end-to-end.
  String _ratePeriod = 'annual';
  String _paymentFrequency = 'monthly';
  DateTime _originationDate = DateTime.now();
  // Optional "pay back by" date — works for any loan style, including a
  // no-interest open-ended loan that just needs a due date + reminder.
  DateTime? _expectedRepaymentDate;
  bool _submitting = false;
  // When true, the user enters the payment they can make and we solve
  // for the term (instead of entering a term and computing the payment).
  // Only offered for the loan styles where a fixed payment defines a
  // term — see [_supportsSolve].
  bool _setByPayment = false;
  // The per-period payment the borrower can make, for solve-by-payment.
  // Reused as the payment amount in flat-amount mode.
  final _paymentCtrl = TextEditingController();
  // Flat-interest, amount sub-mode: the agreed TOTAL interest (a fixed
  // peso/dollar figure, not a rate). Principal + this = what's owed; the
  // payment amount then determines how many installments.
  final _flatInterestCtrl = TextEditingController();
  // The "Flat interest" style covers two inputs of the SAME loan shape:
  // 'amount' (a fixed total → custom schedule) or 'rate' (a % → the 'simple'
  // backend type). Kept as a sub-toggle so the two don't read as rival tiles.
  String _flatMode = 'amount';
  // The three less-common styles (interest-only, one-payment-at-end, custom)
  // live behind this "More loan types" disclosure so the default view is the
  // three everyday choices.
  bool _showMoreStyles = false;
  // Rate period + payment frequency live behind this expander so the
  // default view isn't a wall of dropdowns.
  bool _showAdvanced = false;

  // ----- Inline validation (Form) -----
  // Errors stay hidden until the first failed submit, then re-validate live
  // so they clear as the user fixes each field.
  final _formKey = GlobalKey<FormState>();
  AutovalidateMode _autovalidate = AutovalidateMode.disabled;
  // Keys on the validated fields so a failed submit can scroll the FIRST
  // invalid field into view and name it in the fallback toast — a
  // below-the-fold "Payment amount" used to fail with only a generic toast
  // and no visible cue.
  final _borrowerFieldKey = GlobalKey<FormFieldState<String>>();
  final _principalFieldKey = GlobalKey<FormFieldState<String>>();
  final _flatInterestFieldKey = GlobalKey<FormFieldState<String>>();
  // Shared by the flat-amount "Payment amount" field and the
  // solve-by-payment "Most they can pay" field — the two are never mounted
  // at the same time.
  final _paymentFieldKey = GlobalKey<FormFieldState<String>>();

  // ----- Custom-schedule mode (_interestType == 'custom') -----
  // The explicit installment rows the user pastes / edits. Each carries its
  // own controllers so an inline edit doesn't rebuild the whole list.
  final List<_CustomRow> _customRows = [];
  final _pasteCtrl = TextEditingController();
  bool _showCustomGenerator = false;
  // Quick-fill generator inputs.
  final _genFirstNCtrl = TextEditingController();
  final _genFirstAmtCtrl = TextEditingController();
  final _genThenAmtCtrl = TextEditingController();
  final _genDayCtrl = TextEditingController();
  DateTime? _genStart;
  DateTime? _genEnd;

  bool get _isCustom => _interestType == 'custom';
  // The merged "Flat interest" tile. Its 'amount' sub-mode submits as a
  // custom schedule (interest inferred); its 'rate' sub-mode submits as the
  // 'simple' backend type — same even-split schedule either way.
  bool get _isFlat => _interestType == 'flat';
  bool get _isFlatAmount => _isFlat && _flatMode == 'amount';
  // The advanced styles hidden behind "More loan types".
  static const _advancedStyles = ['interest_only', 'compound', 'custom'];
  // Backend interest_type for the current UI selection ('flat' is not a real
  // type — rate-mode is 'simple', amount-mode goes through the custom path).
  String get _backendInterestType => _isFlat ? 'simple' : _interestType;

  /// Native-currency symbol for the loan being entered (never the
  /// converted display currency — the preview always speaks the loan's
  /// own money).
  String get _sym => _currency == 'MXN' ? r'MX$' : r'$';

  /// Whether "set the payment, solve for the term" applies to the current
  /// selection. Only standard (amortized) and no-interest loans amortize
  /// from a fixed periodic payment; a lump sum has no recurring payment.
  bool get _supportsSolve =>
      (_interestType == 'amortized' || _interestType == 'none') &&
      _paymentFrequency != 'lump_sum';

  /// Live, approximate projection of this loan's finances for the preview
  /// card. Mirrors the backend schedule formulas (see lending_summary
  /// `projectLoan`); the penny-accurate schedule is still generated
  /// server-side in Decimal once the loan is saved.
  LoanProjection? _projection() => projectLoan(
    principal: double.tryParse(_principalCtrl.text.trim()),
    interestType: _backendInterestType,
    ratePercent: double.tryParse(_rateCtrl.text.trim()),
    ratePeriod: _ratePeriod,
    termMonths: int.tryParse(_termCtrl.text.trim()),
    paymentFrequency: _paymentFrequency,
  );

  String _fmtMoney(double v) => moneyFormat(_currency).format(v);

  @override
  void initState() {
    super.initState();
    final cur = widget.initialCurrency ?? widget.defaultCurrency;
    _currency = cur == 'MXN' ? 'MXN' : 'USD';
    if (widget.initialPrincipal != null && widget.initialPrincipal! > 0) {
      _principalCtrl.text = _trimZeros(widget.initialPrincipal!);
    }
    if (widget.initialOriginationDate != null) {
      _originationDate = widget.initialOriginationDate!;
    }
    if (widget.initialBorrowerName != null) {
      _borrowerText = widget.initialBorrowerName!;
    }
  }

  /// Amount without trailing ".00" so a prefilled principal shows cleanly.
  String _trimZeros(double v) =>
      v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toString();

  @override
  void dispose() {
    _principalCtrl.dispose();
    _rateCtrl.dispose();
    _termCtrl.dispose();
    _paymentCtrl.dispose();
    _flatInterestCtrl.dispose();
    _notesCtrl.dispose();
    _pasteCtrl.dispose();
    _genFirstNCtrl.dispose();
    _genFirstAmtCtrl.dispose();
    _genThenAmtCtrl.dispose();
    _genDayCtrl.dispose();
    for (final r in _customRows) {
      r.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final peopleNames = widget.people
        .map((p) => (p as Map)['name']?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
    final media = MediaQuery.of(context);
    final narrow = media.size.width < 380;
    // Cap content at 460 but never exceed the viewport minus the AlertDialog's
    // 16px-per-side inset, or the dialog overflows off-screen on narrow windows.
    final dialogWidth = media.size.width - 32 < 460
        ? media.size.width - 32
        : 460.0;
    // Height the scrollable content may take. AlertDialog stacks the
    // title (~88) + actions (~64) + inset padding (48) on top of the
    // content, plus any keyboard inset — leave room for all of it so the
    // dialog never runs off a short viewport. Floor keeps it usable on
    // very small screens (content scrolls within this box).
    final contentMaxHeight = (media.size.height - media.viewInsets.bottom - 220)
        .clamp(220.0, 620.0);

    // Presentation-only split: the same title row, scrollable content
    // column, and action buttons render either as the classic AlertDialog
    // (>=720) or as a fullscreen phone form with a pinned save bar. All
    // controllers, state, and validation stay on this State either way.
    final titleRow = Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: context.accentSoft(context.tealAccent),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(
            Icons.monetization_on,
            color: context.tealAccent,
            size: 20,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                AppLocalizations.of(context).lendingAddLoan,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: context.textPrimary,
                ),
              ),
              Text(
                AppLocalizations.of(context).lendAddLoanSubtitle,
                style: TextStyle(fontSize: 12, color: context.textMuted),
              ),
            ],
          ),
        ),
      ],
    );

    final contentColumn = Form(
      key: _formKey,
      autovalidateMode: _autovalidate,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _section(AppLocalizations.of(context).lendSectionBorrowerAmount, [
            Autocomplete<String>(
              initialValue: TextEditingValue(
                text: widget.initialBorrowerName ?? '',
              ),
              optionsBuilder: (value) {
                if (value.text.isEmpty) return peopleNames;
                return peopleNames.where(
                  (n) => n.toLowerCase().contains(value.text.toLowerCase()),
                );
              },
              onSelected: (s) => _borrowerText = s,
              fieldViewBuilder: (ctx, ctrl, focus, _) => TextFormField(
                key: _borrowerFieldKey,
                controller: ctrl,
                focusNode: focus,
                onChanged: (v) => _borrowerText = v,
                validator: (v) => (v ?? '').trim().isEmpty
                    ? AppLocalizations.of(context).lendToastEnterBorrowerName
                    : null,
                decoration: _decoration(
                  AppLocalizations.of(context).lendFieldBorrowerName,
                  hint: 'e.g. Jose Ramirez',
                  icon: Icons.person_outline,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: _principalFieldKey,
              controller: _principalCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
              validator: (v) {
                final p = double.tryParse((v ?? '').trim());
                return (p == null || p <= 0)
                    ? AppLocalizations.of(context).lendToastEnterValidAmount
                    : null;
              },
              decoration: _decoration(
                AppLocalizations.of(context).lendFieldAmountLent,
                prefixText: '$_sym ',
                icon: Icons.payments_outlined,
              ),
            ),
            const SizedBox(height: 12),
            _twoUp(
              narrow,
              DropdownButtonFormField<String>(
                initialValue: _currency,
                isExpanded: true,
                dropdownColor: houseDropdownColor(context),
                borderRadius: kMenuRadius,
                decoration: _decoration(
                  AppLocalizations.of(context).lendFieldCurrency,
                ),
                items: const [
                  DropdownMenuItem(value: 'USD', child: Text('USD')),
                  DropdownMenuItem(value: 'MXN', child: Text('MXN')),
                ],
                onChanged: (v) => setState(() => _currency = v ?? 'USD'),
              ),
              InkWell(
                onTap: _pickDate,
                borderRadius: BorderRadius.circular(10),
                child: InputDecorator(
                  decoration: _decoration(
                    AppLocalizations.of(context).lendFieldLentOn,
                    icon: Icons.event_outlined,
                  ),
                  child: Text(
                    // Locale-aware skeleton — es-MX reads "1 may 2024",
                    // not the US-ordered "may 1, 2024".
                    DateFormat.yMMMd().format(_originationDate),
                    style: TextStyle(color: context.textPrimary),
                  ),
                ),
              ),
            ),
          ]),
          const SizedBox(height: 16),
          _section(AppLocalizations.of(context).lendSectionHowLoanWorks, [
            // Plain-language loan styles replace the cryptic
            // interest-type dropdown — each says how its plan works.
            _loanStyleChooser(),
            if (_isCustom) ...[
              const SizedBox(height: 14),
              _customScheduleEditor(narrow),
            ] else if (_isFlat) ...[
              const SizedBox(height: 14),
              _flatModeToggle(),
              const SizedBox(height: 14),
              if (_flatMode == 'amount')
                _flatAmountFields(narrow)
              else ...[
                // Rate sub-mode: same even-split loan, entered as a %.
                _rateField(),
                const SizedBox(height: 14),
                _termOrPaymentControls(narrow),
                _advancedPanel(narrow),
              ],
            ] else ...[
              if (_interestType != 'none') ...[
                const SizedBox(height: 14),
                _rateField(),
              ],
              const SizedBox(height: 14),
              _termOrPaymentControls(narrow),
              _advancedPanel(narrow),
            ],
          ]),
          const SizedBox(height: 16),
          _section(AppLocalizations.of(context).lendSectionExpectedRepayment, [
            _expectedDateField(),
          ]),
          const SizedBox(height: 16),
          _section(AppLocalizations.of(context).lendSectionNotes, [
            TextField(
              controller: _notesCtrl,
              maxLines: 2,
              decoration: _decoration(
                AppLocalizations.of(context).lendFieldNotes,
                hint: AppLocalizations.of(context).lendFieldNotesHint,
                icon: Icons.notes_outlined,
              ),
            ),
          ]),
          const SizedBox(height: 16),
          _buildPreviewCard(),
        ],
      ),
    );

    final cancelButton = TextButton(
      onPressed: _submitting ? null : () => Navigator.pop(context, false),
      child: Text(AppLocalizations.of(context).actionCancel),
    );
    // The one and only save affordance — both wrappers pin this exact
    // button (same _submit, same spinner state).
    final saveButton = FilledButton.icon(
      onPressed: _submitting ? null : _submit,
      icon: _submitting
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.add, size: 18),
      label: Text(AppLocalizations.of(context).lendingAddLoan),
    );

    // Phones: a fullscreen form (no cramped 620px dialog well) with the
    // header up top, the fields scrolling in between, and the save bar
    // pinned at the bottom of the screen — research rubric principle 11.
    if (media.size.width < 720) {
      return Dialog.fullscreen(
        child: SafeArea(
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(child: titleRow),
                    IconButton(
                      tooltip: MaterialLocalizations.of(
                        context,
                      ).closeButtonTooltip,
                      icon: const Icon(Icons.close),
                      onPressed: _submitting
                          ? null
                          : () => Navigator.pop(context, false),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                  child: contentColumn,
                ),
              ),
              // Pinned save bar. The viewInsets term keeps Save above the
              // keyboard even if this subtree is ever hosted outside a
              // Dialog; inside Dialog.fullscreen it reads 0 because the
              // Dialog itself already pads the route above the keyboard
              // and strips viewInsets from descendants (Builder scopes the
              // lookup to a descendant context for exactly that reason —
              // this State's context still sees the raw inset and would
              // double-pad).
              Builder(
                builder: (ctx) {
                  return Padding(
                    padding: EdgeInsets.fromLTRB(
                      16,
                      8,
                      16,
                      16 + MediaQuery.viewInsetsOf(ctx).bottom,
                    ),
                    child: Row(
                      children: [
                        cancelButton,
                        const SizedBox(width: 12),
                        Expanded(
                          child: SizedBox(height: 48, child: saveButton),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      );
    }

    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      title: titleRow,
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogWidth,
          maxHeight: contentMaxHeight,
        ),
        child: SizedBox(
          width: dialogWidth,
          child: SingleChildScrollView(child: contentColumn),
        ),
      ),
      actions: [cancelButton, saveButton],
    );
  }

  /// A titled group of fields in a soft card, for visual structure.
  Widget _section(String title, List<Widget> children) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(left: 4, bottom: 8),
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
              color: context.textSubtle,
            ),
          ),
        ),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: context.tileSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: children,
          ),
        ),
      ],
    );
  }

  /// Two fields side-by-side on wide screens, stacked on narrow ones.
  Widget _twoUp(bool narrow, Widget a, Widget b) {
    if (narrow) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [a, const SizedBox(height: 12), b],
      );
    }
    return Row(
      children: [
        Expanded(child: a),
        const SizedBox(width: 12),
        Expanded(child: b),
      ],
    );
  }

  /// Shared filled, rounded input styling for the dialog.
  InputDecoration _decoration(
    String label, {
    String? hint,
    String? prefixText,
    String? suffixText,
    IconData? icon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixText: prefixText,
      suffixText: suffixText,
      prefixIcon: icon == null ? null : Icon(icon, size: 18),
      isDense: true,
      filled: true,
      fillColor: context.tint(0.03),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: context.hairline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: context.hairline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: context.tealAccent, width: 1.5),
      ),
    );
  }

  /// The three everyday styles, always visible. "Flat interest" is the
  /// merged rate-or-amount tile (see [_flatMode]).
  List<(String, String, String)> _primaryStyles(AppLocalizations l10n) => [
    ('none', l10n.lendInterestTypeNone, l10n.lendStyleNoInterestDesc),
    ('flat', l10n.lendStyleFlatLabel, l10n.lendStyleFlatDesc),
    ('amortized', l10n.lendStyleStandardLabel, l10n.lendStyleStandardDesc),
  ];

  /// The less-common styles, tucked behind "More loan types".
  List<(String, String, String)> _moreStyles(AppLocalizations l10n) => [
    (
      'interest_only',
      l10n.lendStyleInterestOnlyLabel,
      l10n.lendStyleInterestOnlyDesc,
    ),
    ('compound', l10n.lendStylePayAtEndLabel, l10n.lendStylePayAtEndDesc),
    ('custom', l10n.lendCustomStyleLabel, l10n.lendCustomStyleDesc),
  ];

  Widget _loanStyleChooser() {
    final l10n = AppLocalizations.of(context);
    final primary = _primaryStyles(l10n);
    final more = _moreStyles(l10n);
    // Keep the disclosure open while one of its styles is the selection, so
    // the chosen tile is never hidden.
    final showMore = _showMoreStyles || _advancedStyles.contains(_interestType);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < primary.length; i++) ...[
          if (i > 0) const SizedBox(height: 8),
          _loanStyleTile(
            value: primary[i].$1,
            label: primary[i].$2,
            desc: primary[i].$3,
          ),
        ],
        const SizedBox(height: 8),
        InkWell(
          onTap: () => setState(() => _showMoreStyles = !_showMoreStyles),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              children: [
                Icon(
                  showMore ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: context.textSubtle,
                ),
                const SizedBox(width: 6),
                Text(
                  l10n.lendMoreLoanTypes,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    color: context.textSubtle,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (showMore)
          for (var i = 0; i < more.length; i++) ...[
            _loanStyleTile(
              value: more[i].$1,
              label: more[i].$2,
              desc: more[i].$3,
            ),
            if (i < more.length - 1) const SizedBox(height: 8),
          ],
      ],
    );
  }

  Widget _loanStyleTile({
    required String value,
    required String label,
    required String desc,
  }) {
    final selected = _interestType == value;
    final accent = context.tealAccent;
    return InkWell(
      onTap: () => setState(() {
        _interestType = value;
        // Solve-by-payment only applies to standard / no-interest loans.
        if (!_supportsSolve) _setByPayment = false;
      }),
      borderRadius: BorderRadius.circular(10),
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: selected ? context.accentSoft(accent) : context.tint(0.02),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: selected ? context.accentBorder(accent) : context.hairline,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              selected ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18,
              color: selected ? accent : context.textFaint,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: context.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    desc,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: context.textMuted,
                      height: 1.3,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Either a term field, or — for the styles that amortize from a fixed
  /// payment — a toggle between entering the term and entering the
  /// payment (solving for the term).
  Widget _termOrPaymentControls(bool narrow) {
    final termField = TextField(
      controller: _termCtrl,
      keyboardType: TextInputType.number,
      onChanged: (_) => setState(() {}),
      decoration: _decoration(
        AppLocalizations.of(context).lendFieldTermMonths,
        hint: 'e.g. 12',
        icon: Icons.schedule_outlined,
      ),
    );
    if (!_supportsSolve) return termField;

    final cadence = _paymentFrequency == 'weekly' ? 'week' : 'month';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // House connected button group (shared single-select control).
        ConnectedSegments<bool>(
          segments: [
            ConnectedSegment(
              value: false,
              label: AppLocalizations.of(context).lendSegSetTheTerm,
            ),
            ConnectedSegment(
              value: true,
              label: AppLocalizations.of(context).lendSegSetThePayment,
            ),
          ],
          selected: _setByPayment,
          onSelected: (v) => setState(() => _setByPayment = v),
        ),
        const SizedBox(height: 12),
        if (_setByPayment)
          TextFormField(
            key: _paymentFieldKey,
            controller: _paymentCtrl,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            onChanged: (_) => setState(() {}),
            validator: (v) {
              final p = double.tryParse((v ?? '').trim());
              return (p == null || p <= 0)
                  ? AppLocalizations.of(context).lendErrEnterPayment
                  : null;
            },
            decoration: _decoration(
              AppLocalizations.of(context).lendFieldMostTheyCanPay,
              prefixText: '$_sym ',
              suffixText: '/ $cadence',
              icon: Icons.payments_outlined,
            ),
          )
        else
          termField,
      ],
    );
  }

  /// The interest-rate percent field (shared by the rate-mode of Flat
  /// interest and by the standard / interest-only / compound styles).
  Widget _rateField() {
    return TextField(
      controller: _rateCtrl,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onChanged: (_) => setState(() {}),
      decoration: _decoration(
        AppLocalizations.of(context).lendFieldInterestRate,
        hint: AppLocalizations.of(context).lendRateHintExample,
        icon: Icons.percent,
        suffixText: _ratePeriod == 'monthly'
            ? AppLocalizations.of(context).lendRatePerMonthSuffix
            : AppLocalizations.of(context).lendRatePerYearSuffix,
      ),
    );
  }

  /// The "Flat interest" sub-toggle: enter the interest as a fixed total
  /// amount, or as a percentage rate. Both yield the same even-split
  /// schedule — this keeps them one concept, not two rival tiles.
  Widget _flatModeToggle() {
    final l10n = AppLocalizations.of(context);
    // House connected button group (shared single-select control).
    return ConnectedSegments<String>(
      segments: [
        ConnectedSegment(value: 'amount', label: l10n.lendFlatModeAmount),
        ConnectedSegment(value: 'rate', label: l10n.lendFlatModeRate),
      ],
      selected: _flatMode,
      onSelected: (v) => setState(() => _flatMode = v),
    );
  }

  /// Flat/agreed-interest inputs: a fixed TOTAL interest amount (not a
  /// rate) plus the periodic payment. The schedule is generated client-side
  /// and submitted as a custom schedule; the backend infers the interest as
  /// (Σpayments − principal), so it always matches what's entered here.
  Widget _flatAmountFields(bool narrow) {
    final l10n = AppLocalizations.of(context);
    final cadence = _paymentFrequency == 'weekly' ? 'week' : 'month';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TextFormField(
          key: _flatInterestFieldKey,
          controller: _flatInterestCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() {}),
          // Blank is a valid "no interest" entry; anything typed must parse
          // to a non-negative amount (the old code silently read garbage
          // as 0).
          validator: (v) {
            final t = (v ?? '').trim();
            if (t.isEmpty) return null;
            final i = double.tryParse(t);
            return (i == null || i < 0) ? l10n.lendToastEnterValidAmount : null;
          },
          decoration: _decoration(
            l10n.lendFieldAgreedInterest,
            hint: 'e.g. 2000',
            prefixText: '$_sym ',
            icon: Icons.handshake_outlined,
          ),
        ),
        const SizedBox(height: 14),
        TextFormField(
          key: _paymentFieldKey,
          controller: _paymentCtrl,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          onChanged: (_) => setState(() {}),
          validator: (v) {
            final p = double.tryParse((v ?? '').trim());
            if (p == null || p <= 0) return l10n.lendErrEnterPayment;
            // Mirror the submit-time check: a payment so small the schedule
            // would blow past the installment cap gets flagged here, not
            // via a generic toast after the fact.
            final principal = double.tryParse(_principalCtrl.text.trim());
            final interest =
                double.tryParse(_flatInterestCtrl.text.trim()) ?? 0;
            if (principal != null &&
                principal > 0 &&
                interest >= 0 &&
                _flatScheduleRows(
                  principal: principal,
                  interest: interest,
                  payment: p,
                ).isEmpty) {
              return l10n.lendErrPaymentTooSmall;
            }
            return null;
          },
          decoration: _decoration(
            l10n.lendFieldPaymentAmount,
            hint: 'e.g. 4000',
            prefixText: '$_sym ',
            suffixText: '/ $cadence',
            icon: Icons.payments_outlined,
          ),
        ),
      ],
    );
  }

  /// Rate period + payment frequency, tucked behind an expander so the
  /// default view isn't a wall of dropdowns. Sensible defaults (per year,
  /// monthly) mean most users never open it.
  Widget _advancedPanel(bool narrow) {
    final fields = <Widget>[
      if (_interestType != 'none')
        DropdownButtonFormField<String>(
          initialValue: _ratePeriod,
          isExpanded: true,
          dropdownColor: houseDropdownColor(context),
          borderRadius: kMenuRadius,
          decoration: _decoration(
            AppLocalizations.of(context).lendFieldRateIsPer,
          ),
          items: [
            DropdownMenuItem(
              value: 'annual',
              child: Text(AppLocalizations.of(context).lendRatePeriodYear),
            ),
            DropdownMenuItem(
              value: 'monthly',
              child: Text(AppLocalizations.of(context).lendRatePeriodMonth),
            ),
          ],
          onChanged: (v) => setState(() => _ratePeriod = v ?? 'annual'),
        ),
      DropdownButtonFormField<String>(
        initialValue: _paymentFrequency,
        isExpanded: true,
        dropdownColor: houseDropdownColor(context),
        borderRadius: kMenuRadius,
        decoration: _decoration(
          AppLocalizations.of(context).lendFieldPaymentFrequency,
        ),
        items: [
          DropdownMenuItem(
            value: 'monthly',
            child: Text(AppLocalizations.of(context).cfCadenceMonthly),
          ),
          DropdownMenuItem(
            value: 'weekly',
            child: Text(AppLocalizations.of(context).cfCadenceWeekly),
          ),
          DropdownMenuItem(
            value: 'lump_sum',
            child: Text(AppLocalizations.of(context).lendFreqLumpSum),
          ),
        ],
        onChanged: (v) => setState(() {
          _paymentFrequency = v ?? 'monthly';
          // A lump sum has no recurring payment to solve a term from.
          if (_paymentFrequency == 'lump_sum') _setByPayment = false;
        }),
      ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _showAdvanced = !_showAdvanced),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(
                  _showAdvanced ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: context.textMuted,
                ),
                const SizedBox(width: 6),
                Text(
                  AppLocalizations.of(context).lendAdvancedOptions,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: context.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_showAdvanced)
          for (var i = 0; i < fields.length; i++) ...[
            if (i > 0) const SizedBox(height: 12),
            fields[i],
          ],
      ],
    );
  }

  /// Always-visible projection so the user sees the finances before
  /// saving — including no-interest loans, where it shows the total to
  /// repay. Native currency only (never the converted display value).
  Widget _buildPreviewCard() {
    final accent = context.tealAccent;
    final rows = _isCustom
        ? _customPreviewRows(accent)
        : _isFlatAmount
        ? _flatPreviewRows(accent)
        : (_setByPayment && _supportsSolve)
        ? _solvePreviewRows(accent)
        : _termPreviewRows(accent);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: context.accentSoft(accent),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.accentBorder(accent)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.insights_outlined, size: 16, color: accent),
              const SizedBox(width: 6),
              Text(
                AppLocalizations.of(context).lendPreviewTitle,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: accent,
                ),
              ),
              const Spacer(),
              Text(
                AppLocalizations.of(context).lendPreviewEstimate,
                style: TextStyle(fontSize: 10, color: context.textSubtle),
              ),
            ],
          ),
          const SizedBox(height: 10),
          ...rows,
        ],
      ),
    );
  }

  /// The default preview: given the term, what's the payment + totals.
  List<Widget> _flatPreviewRows(Color accent) {
    final l10n = AppLocalizations.of(context);
    final principal = double.tryParse(_principalCtrl.text.trim()) ?? 0;
    final interest = double.tryParse(_flatInterestCtrl.text.trim()) ?? 0;
    final payment = double.tryParse(_paymentCtrl.text.trim()) ?? 0;
    final total = principal + interest;
    final rows = (payment > 0 && total > 0)
        ? _flatScheduleRows(
            principal: principal,
            interest: interest,
            payment: payment,
          )
        : const <Map<String, dynamic>>[];
    return [
      _previewRow(l10n.lendPreviewTotalToRepay, _fmtMoney(total), bold: true),
      const SizedBox(height: 6),
      _previewRow(l10n.lendCustomPreviewCount(rows.length), _fmtMoney(payment)),
    ];
  }

  List<Widget> _termPreviewRows(Color accent) {
    final proj = _projection();
    if (proj == null) {
      return [
        Text(
          AppLocalizations.of(context).lendPreviewEnterAmount,
          style: TextStyle(fontSize: 13, color: context.textSubtle),
        ),
      ];
    }
    final l10n = AppLocalizations.of(context);
    final cadenceLabel = switch (proj.cadence) {
      'monthly' => '/mo',
      'weekly' => '/wk',
      _ => '',
    };
    // Recurring-payment value: base "amount/cadence", optionally labelled as
    // interest (interest-only loans) and suffixed with the payment count.
    String perPaymentValue() {
      final base = '${_fmtMoney(proj.perPayment!)}$cadenceLabel';
      if (proj.periods == null) return base;
      return proj.balloonPayment != null
          ? l10n.lendPreviewPerPaymentInterest(
              _fmtMoney(proj.perPayment!),
              cadenceLabel,
              proj.periods!,
            )
          : l10n.lendPreviewPerPaymentCount(
              _fmtMoney(proj.perPayment!),
              cadenceLabel,
              proj.periods!,
            );
    }

    return [
      _previewRow(
        l10n.lendPreviewTotalToRepay,
        _fmtMoney(proj.totalRepayment),
        bold: true,
      ),
      const SizedBox(height: 6),
      if (proj.totalInterest > 0.005)
        _previewRow(
          l10n.lendPreviewProjectedInterest,
          _fmtMoney(proj.totalInterest),
          color: accent,
        )
      else
        Text(
          l10n.lendPreviewNoInterest,
          style: TextStyle(fontSize: 12, color: context.textMuted),
        ),
      if (proj.perPayment != null) ...[
        const SizedBox(height: 6),
        _previewRow(
          proj.cadence == 'balloon'
              ? l10n.lendPreviewSinglePayment
              : l10n.lendPreviewPayment,
          proj.cadence == 'balloon'
              ? _fmtMoney(proj.perPayment!)
              // Interest-only loans pay interest periodically, so label the
              // recurring figure as such — otherwise "$125/mo · 12 payments"
              // reads as the whole obligation when it's just the interest.
              : perPaymentValue(),
        ),
        // Interest-only: the principal balloons on the final installment,
        // so the borrower's last payment is the interest PLUS this amount.
        if (proj.balloonPayment != null && proj.balloonPayment! > 0.005) ...[
          const SizedBox(height: 6),
          _previewRow(
            l10n.lendPreviewPrincipalAtMaturity,
            l10n.lendPreviewDueWithFinalPayment(
              _fmtMoney(proj.balloonPayment!),
            ),
          ),
        ],
      ] else ...[
        const SizedBox(height: 6),
        Text(
          l10n.lendPreviewOpenEnded,
          style: TextStyle(fontSize: 12, color: context.textSubtle),
        ),
      ],
    ];
  }

  /// Solve-for-term preview: given the payment the borrower can make, how
  /// many payments it takes, roughly how long, and the total cost.
  List<Widget> _solvePreviewRows(Color accent) {
    final res = solveTermFromPayment(
      principal: double.tryParse(_principalCtrl.text.trim()),
      interestType: _interestType,
      ratePercent: double.tryParse(_rateCtrl.text.trim()),
      ratePeriod: _ratePeriod,
      paymentFrequency: _paymentFrequency,
      targetPayment: double.tryParse(_paymentCtrl.text.trim()),
    );
    final cadence = _paymentFrequency == 'weekly' ? 'wk' : 'mo';
    if (!res.ok) {
      return [
        Text(
          res.reason ??
              AppLocalizations.of(context).lendPreviewEnterPaymentSolve,
          style: TextStyle(fontSize: 13, color: context.textSubtle),
        ),
        if (res.minimumPayment != null) ...[
          const SizedBox(height: 6),
          _previewRow(
            AppLocalizations.of(context).lendPreviewMinimumPayment,
            '${_fmtMoney(res.minimumPayment!)}/$cadence',
            color: accent,
          ),
        ],
      ];
    }
    final l10n = AppLocalizations.of(context);
    final months = res.termMonths!;
    final years = months / 12.0;
    final termLabel = months < 12
        ? l10n.lendTermMonths(months)
        : l10n.lendTermYearsAbbrev(
            years.toStringAsFixed(months % 12 == 0 ? 0 : 1),
          );
    return [
      _previewRow(
        l10n.lendPreviewPaidOffIn,
        l10n.lendPreviewPaidOffValue(res.periods!, termLabel),
        bold: true,
      ),
      const SizedBox(height: 6),
      if (res.totalInterest! > 0.005)
        _previewRow(
          l10n.lendPreviewProjectedInterest,
          _fmtMoney(res.totalInterest!),
          color: accent,
        )
      else
        Text(
          l10n.lendPreviewNoInterest,
          style: TextStyle(fontSize: 12, color: context.textMuted),
        ),
      const SizedBox(height: 6),
      _previewRow(l10n.lendPreviewTotalToRepay, _fmtMoney(res.totalRepayment!)),
    ];
  }

  Widget _previewRow(
    String label,
    String value, {
    bool bold = false,
    Color? color,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(label, style: TextStyle(fontSize: 13, color: context.textMuted)),
        Flexible(
          child: Text(
            value,
            textAlign: TextAlign.right,
            style: TextStyle(
              fontSize: 13,
              fontWeight: bold ? FontWeight.w800 : FontWeight.w600,
              color: color ?? context.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ),
      ],
    );
  }

  // ===================================================================
  // Custom-schedule editor
  // ===================================================================

  /// The paste box + editable row list + quick-fill generator. The rows
  /// are the source of truth for the schedule that's saved on confirm.
  Widget _customScheduleEditor(bool narrow) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.lendCustomPasteTitle,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: context.textSubtle,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _pasteCtrl,
          maxLines: 4,
          minLines: 3,
          style: const TextStyle(
            fontFeatures: [FontFeature.tabularFigures()],
            fontSize: 13,
          ),
          decoration: _decoration(
            l10n.lendCustomPasteTitle,
            hint: l10n.lendCustomPasteHint,
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _parsePaste,
            icon: const Icon(Icons.content_paste_go, size: 16),
            label: Text(
              l10n.lendCustomPasteButton,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ),
        const SizedBox(height: 12),
        // Editable rows.
        Row(
          children: [
            Expanded(
              child: Text(
                l10n.lendCustomRowsTitle,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: context.textSubtle,
                ),
              ),
            ),
            TextButton.icon(
              onPressed: _addCustomRow,
              icon: const Icon(Icons.add, size: 16),
              label: Text(
                l10n.lendCustomAddRow,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        if (_customRows.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              l10n.lendCustomNoRows,
              style: TextStyle(fontSize: 12, color: context.textSubtle),
            ),
          )
        else
          for (var i = 0; i < _customRows.length; i++) _customRowTile(i),
        const SizedBox(height: 8),
        _customGeneratorPanel(narrow),
      ],
    );
  }

  Widget _customRowTile(int index) {
    final l10n = AppLocalizations.of(context);
    final row = _customRows[index];
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 22,
            child: Text(
              '${index + 1}',
              style: TextStyle(fontSize: 12, color: context.textFaint),
            ),
          ),
          Expanded(
            flex: 4,
            child: TextField(
              controller: row.dateCtrl,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 13),
              decoration: _decoration(
                l10n.lendCustomRowDate,
                hint: 'YYYY-MM-DD',
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            flex: 3,
            child: TextField(
              controller: row.amountCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              onChanged: (_) => setState(() {}),
              style: const TextStyle(fontSize: 13),
              decoration: _decoration(
                l10n.lendCustomRowAmount,
                prefixText: '$_sym ',
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 16),
            tooltip: l10n.lendCustomRemoveRow,
            onPressed: () => _removeCustomRow(index),
          ),
        ],
      ),
    );
  }

  Widget _customGeneratorPanel(bool narrow) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () =>
              setState(() => _showCustomGenerator = !_showCustomGenerator),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: [
                Icon(
                  _showCustomGenerator ? Icons.expand_less : Icons.expand_more,
                  size: 18,
                  color: context.textMuted,
                ),
                const SizedBox(width: 6),
                Text(
                  l10n.lendCustomGeneratorTitle,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: context.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
        if (_showCustomGenerator) ...[
          _twoUp(
            narrow,
            TextField(
              controller: _genFirstNCtrl,
              keyboardType: TextInputType.number,
              decoration: _decoration(l10n.lendCustomGenFirstN, hint: '1'),
            ),
            TextField(
              controller: _genFirstAmtCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: _decoration(
                l10n.lendCustomGenFirstAmount,
                prefixText: '$_sym ',
              ),
            ),
          ),
          const SizedBox(height: 12),
          _twoUp(
            narrow,
            TextField(
              controller: _genThenAmtCtrl,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: _decoration(
                l10n.lendCustomGenThenAmount,
                prefixText: '$_sym ',
              ),
            ),
            TextField(
              controller: _genDayCtrl,
              keyboardType: TextInputType.number,
              decoration: _decoration(l10n.lendCustomGenDayOfMonth, hint: '15'),
            ),
          ),
          const SizedBox(height: 12),
          _twoUp(
            narrow,
            InkWell(
              onTap: () => _pickGenDate(true),
              borderRadius: BorderRadius.circular(10),
              child: InputDecorator(
                decoration: _decoration(
                  l10n.lendCustomGenStart,
                  icon: Icons.event_outlined,
                ),
                child: Text(
                  _genStart == null
                      ? '—'
                      : DateFormat.yMMMd().format(_genStart!),
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                ),
              ),
            ),
            InkWell(
              onTap: () => _pickGenDate(false),
              borderRadius: BorderRadius.circular(10),
              child: InputDecorator(
                decoration: _decoration(
                  l10n.lendCustomGenEnd,
                  icon: Icons.event_outlined,
                ),
                child: Text(
                  _genEnd == null ? '—' : DateFormat.yMMMd().format(_genEnd!),
                  style: TextStyle(color: context.textPrimary, fontSize: 13),
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.tonalIcon(
              onPressed: _applyGenerator,
              icon: const Icon(Icons.auto_fix_high, size: 16),
              label: Text(
                l10n.lendCustomGenApply,
                style: const TextStyle(fontSize: 12),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Future<void> _pickGenDate(bool isStart) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: (isStart ? _genStart : _genEnd) ?? _originationDate,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) {
      setState(() {
        if (isStart) {
          _genStart = picked;
        } else {
          _genEnd = picked;
        }
      });
    }
  }

  /// Parse the pasted spreadsheet text into rows. Each non-empty line is
  /// split on a tab or a run of whitespace into a date + amount. Accepts
  /// M/D/YYYY, MM/DD/YYYY and YYYY-MM-DD; strips currency symbols/commas.
  void _parsePaste() {
    final text = _pasteCtrl.text;
    if (text.trim().isEmpty) {
      _toast(AppLocalizations.of(context).lendCustomPasteEmpty);
      return;
    }
    final parsed = <_CustomRow>[];
    for (final rawLine in text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      // Prefer a tab split (spreadsheet paste); fall back to whitespace.
      List<String> parts = line.contains('\t')
          ? line.split('\t')
          : line.split(RegExp(r'\s{2,}|\s+'));
      parts = parts.where((p) => p.trim().isNotEmpty).toList();
      if (parts.length < 2) continue;
      final iso = _normalizeDate(parts[0].trim());
      final amt = _parseAmount(parts.sublist(1).join(' '));
      if (iso == null || amt == null) continue;
      parsed.add(_CustomRow.of(iso, _trimZeros(amt)));
    }
    if (parsed.isEmpty) {
      _toast(AppLocalizations.of(context).lendCustomPasteEmpty);
      return;
    }
    setState(() {
      for (final r in _customRows) {
        r.dispose();
      }
      _customRows
        ..clear()
        ..addAll(parsed);
    });
    _toast(AppLocalizations.of(context).lendCustomPastedN(parsed.length));
  }

  /// Normalize a date token to YYYY-MM-DD, or null if unrecognized.
  String? _normalizeDate(String s) {
    final t = s.trim();
    // Already ISO (YYYY-MM-DD).
    final isoMatch = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})$').firstMatch(t);
    if (isoMatch != null) {
      return _iso(
        int.parse(isoMatch.group(1)!),
        int.parse(isoMatch.group(2)!),
        int.parse(isoMatch.group(3)!),
      );
    }
    // M/D/YYYY or MM/DD/YYYY (US order — matches Google Sheets exports).
    final slash = RegExp(r'^(\d{1,2})/(\d{1,2})/(\d{2,4})$').firstMatch(t);
    if (slash != null) {
      var year = int.parse(slash.group(3)!);
      if (year < 100) year += 2000;
      return _iso(year, int.parse(slash.group(1)!), int.parse(slash.group(2)!));
    }
    return null;
  }

  String _iso(int y, int m, int d) =>
      '${y.toString().padLeft(4, '0')}-${m.toString().padLeft(2, '0')}-${d.toString().padLeft(2, '0')}';

  /// Strip currency symbols / thousands separators and parse the amount.
  double? _parseAmount(String s) {
    final cleaned = s.replaceAll(RegExp(r'[^\d.\-]'), '');
    if (cleaned.isEmpty) return null;
    return double.tryParse(cleaned);
  }

  void _addCustomRow() {
    setState(() => _customRows.add(_CustomRow.of('', '')));
  }

  void _removeCustomRow(int index) {
    setState(() {
      _customRows.removeAt(index).dispose();
    });
  }

  /// Quick-fill: first N payments of X, then Y every month on day D from
  /// START to END. Replaces the current rows. A convenience only — the
  /// user can still fine-tune afterwards.
  void _applyGenerator() {
    final firstN = int.tryParse(_genFirstNCtrl.text.trim()) ?? 0;
    final firstAmt = _parseAmount(_genFirstAmtCtrl.text.trim());
    final thenAmt = _parseAmount(_genThenAmtCtrl.text.trim());
    final day = int.tryParse(_genDayCtrl.text.trim());
    final start = _genStart;
    final end = _genEnd;
    if (thenAmt == null || day == null || start == null || end == null) {
      _toast(AppLocalizations.of(context).lendCustomNeedRows);
      return;
    }
    final rows = <_CustomRow>[];
    // Walk month-by-month on the given day-of-month, from the start month
    // through (inclusive) the end month. The first [firstN] payments use
    // [firstAmt] (when given), the rest use [thenAmt]. Guard the loop at
    // 600 iterations so a bad end date can't spin forever.
    final endMonth = DateTime(end.year, end.month);
    var y = start.year;
    var m = start.month;
    var iter = 0;
    while (iter < 600 && !DateTime(y, m).isAfter(endMonth)) {
      final dim = DateUtils.getDaysInMonth(y, m);
      final d = day > dim ? dim : day;
      final amt = (rows.length < firstN && firstAmt != null)
          ? firstAmt
          : thenAmt;
      rows.add(_CustomRow.of(_iso(y, m, d), _trimZeros(amt)));
      iter++;
      m++;
      if (m > 12) {
        m = 1;
        y++;
      }
    }
    if (rows.isEmpty) {
      _toast(AppLocalizations.of(context).lendCustomNeedRows);
      return;
    }
    setState(() {
      for (final r in _customRows) {
        r.dispose();
      }
      _customRows
        ..clear()
        ..addAll(rows);
    });
  }

  /// Sum of the current custom rows' amounts (parsed; unparseable = 0).
  double _customSum() {
    var sum = 0.0;
    for (final r in _customRows) {
      sum += _parseAmount(r.amountCtrl.text.trim()) ?? 0;
    }
    return sum;
  }

  /// The preview for custom mode: count, sum, and whether it closes to 0.
  List<Widget> _customPreviewRows(Color accent) {
    final l10n = AppLocalizations.of(context);
    final principal = double.tryParse(_principalCtrl.text.trim());
    final sum = _customSum();
    final n = _customRows.length;
    final closes =
        principal != null && (sum - principal).abs() < 0.005 && n > 0;
    return [
      _previewRow(l10n.lendCustomPreviewCount(n), _fmtMoney(sum), bold: true),
      const SizedBox(height: 6),
      _previewRow(l10n.lendCustomPreviewSum, _fmtMoney(sum)),
      const SizedBox(height: 8),
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            closes ? Icons.check_circle : Icons.warning_amber_rounded,
            size: 16,
            color: closes ? context.positive : context.warning,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              closes
                  ? l10n.lendCustomClosesToZero
                  : l10n.lendCustomDoesNotAddUp(
                      _fmtMoney(sum),
                      principal == null ? _fmtMoney(0) : _fmtMoney(principal),
                    ),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: closes ? context.positive : context.warning,
              ),
            ),
          ),
        ],
      ),
    ];
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _originationDate,
      firstDate: DateTime(2000),
      lastDate: DateTime.now().add(const Duration(days: 1)),
    );
    if (picked != null) setState(() => _originationDate = picked);
  }

  // Optional, clearable "pay back by" date. A repayment is in the future, so
  // (unlike "Lent on") the picker allows future dates.
  Future<void> _pickExpectedDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate:
          _expectedRepaymentDate ??
          _originationDate.add(const Duration(days: 30)),
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => _expectedRepaymentDate = picked);
  }

  Widget _expectedDateField() {
    return Row(
      children: [
        Expanded(
          child: InkWell(
            onTap: _pickExpectedDate,
            borderRadius: BorderRadius.circular(10),
            child: InputDecorator(
              decoration: _decoration(
                AppLocalizations.of(context).lendFieldPayBackBy,
                icon: Icons.event_available_outlined,
              ),
              child: Text(
                _expectedRepaymentDate == null
                    ? AppLocalizations.of(context).lendFieldPayBackByHint
                    : DateFormat.yMMMd().format(_expectedRepaymentDate!),
                style: TextStyle(
                  color: _expectedRepaymentDate == null
                      ? context.textFaint
                      : context.textPrimary,
                ),
              ),
            ),
          ),
        ),
        if (_expectedRepaymentDate != null)
          IconButton(
            icon: const Icon(Icons.clear, size: 18),
            tooltip: AppLocalizations.of(context).lendTooltipClearDate,
            onPressed: () => setState(() => _expectedRepaymentDate = null),
          ),
      ],
    );
  }

  /// Runs the inline validators. On failure it (1) shows the inline field
  /// errors and keeps them live, (2) scrolls the FIRST invalid field into
  /// view — the "Payment amount" field sits below the fold on short
  /// viewports — and (3) toasts a fallback message that NAMES the field,
  /// so the failure is loud even if the field is momentarily off-screen.
  bool _validateForm() {
    if (_formKey.currentState?.validate() ?? true) return true;
    setState(() => _autovalidate = AutovalidateMode.onUserInteraction);
    final l10n = AppLocalizations.of(context);
    // Visual (top-to-bottom) order; unmounted fields have no state and are
    // skipped. The payment key serves whichever payment field is mounted.
    final fields = <(GlobalKey<FormFieldState<String>>, String)>[
      (_borrowerFieldKey, l10n.lendFieldBorrowerName),
      (_principalFieldKey, l10n.lendFieldAmountLent),
      (_flatInterestFieldKey, l10n.lendFieldAgreedInterest),
      (
        _paymentFieldKey,
        _isFlatAmount
            ? l10n.lendFieldPaymentAmount
            : l10n.lendFieldMostTheyCanPay,
      ),
    ];
    for (final (key, label) in fields) {
      if (!(key.currentState?.hasError ?? false)) continue;
      final fieldCtx = key.currentContext;
      if (fieldCtx != null) {
        Scrollable.ensureVisible(
          fieldCtx,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeInOut,
          alignment: 0.15,
        );
      }
      _toast(l10n.lendToastCheckField(label));
      break;
    }
    return false;
  }

  Future<void> _submit() async {
    // Inline validation covers every style's shared fields (and the flat
    // payment fields); the per-style submits below keep their own checks
    // only as unreachable backstops.
    if (!_validateForm()) return;
    if (_isCustom) {
      await _submitCustom();
      return;
    }
    if (_isFlatAmount) {
      await _submitFlat();
      return;
    }
    final borrower = _borrowerText.trim();
    final principal = double.tryParse(_principalCtrl.text.trim());
    if (borrower.isEmpty) {
      _toast(AppLocalizations.of(context).lendToastEnterBorrowerName);
      return;
    }
    if (principal == null || principal <= 0) {
      _toast(AppLocalizations.of(context).lendToastEnterValidAmount);
      return;
    }
    setState(() => _submitting = true);
    try {
      // Rate entered as a percent; backend wants a fraction. The period
      // (year/month) is passed through verbatim so it's stored exactly.
      final isNone = _interestType == 'none';
      // Flat-interest rate mode maps to the 'simple' backend type.
      final backendType = _backendInterestType;
      final ratePct = double.tryParse(_rateCtrl.text.trim()) ?? 0;

      // Resolve the term: either typed directly, or solved from the
      // payment the borrower can make. A fixed schedule needs both a term
      // and a frequency; leaving the term blank makes the loan open-ended.
      int? term;
      if (_setByPayment && _supportsSolve) {
        final res = solveTermFromPayment(
          principal: principal,
          interestType: backendType,
          ratePercent: isNone ? 0 : ratePct,
          ratePeriod: _ratePeriod,
          paymentFrequency: _paymentFrequency,
          targetPayment: double.tryParse(_paymentCtrl.text.trim()),
        );
        if (!res.ok) {
          setState(() => _submitting = false);
          _toast(
            res.reason ??
                AppLocalizations.of(context).lendToastEnterPaymentCompute,
          );
          return;
        }
        term = res.termMonths;
      } else {
        term = int.tryParse(_termCtrl.text.trim());
      }

      final loan = await widget.apiService.createLoan(
        borrowerName: borrower,
        principal: principal,
        currency: _currency,
        originationDate: _originationDate,
        interestRate: isNone ? 0 : ratePct / 100.0,
        interestType: backendType,
        ratePeriod: _ratePeriod,
        termMonths: term,
        // A frequency only makes sense alongside a fixed term; without one
        // the loan is open-ended (repayments recorded ad hoc).
        paymentFrequency: term != null ? _paymentFrequency : null,
        notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        expectedRepaymentDate: _expectedRepaymentDate,
      );
      // Prefill flow: also link the funding transaction. Roll the loan back
      // on a 409 so we never leave an orphan loan whose disbursement failed.
      if (widget.disbursementTxId != null) {
        final ok = await _linkDisbursementOrRollback(loan['id'].toString());
        if (!ok) return;
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _toast(AppLocalizations.of(context).lendToastFailedToAddLoan);
    }
  }

  /// Custom-schedule confirm: create the loan (interest_type 'custom'),
  /// push the explicit rows, then optionally link the disbursement. On any
  /// failure after the loan is created, delete it so no empty loan is left.
  Future<void> _submitCustom() async {
    final l10n = AppLocalizations.of(context);
    final borrower = _borrowerText.trim();
    final principal = double.tryParse(_principalCtrl.text.trim());
    if (borrower.isEmpty) {
      _toast(AppLocalizations.of(context).lendToastEnterBorrowerName);
      return;
    }
    if (principal == null || principal <= 0) {
      _toast(AppLocalizations.of(context).lendToastEnterValidAmount);
      return;
    }
    final rows = _customScheduleRows();
    if (rows.isEmpty) {
      _toast(l10n.lendCustomNeedRows);
      return;
    }
    await _createLoanWithSchedule(principal, rows);
  }

  /// Flat/agreed-interest confirm: generate the installment rows from
  /// (principal + agreed interest) / payment, then create the loan as a
  /// custom schedule (same create-then-schedule flow as [_submitCustom]).
  Future<void> _submitFlat() async {
    final l10n = AppLocalizations.of(context);
    final borrower = _borrowerText.trim();
    final principal = double.tryParse(_principalCtrl.text.trim());
    if (borrower.isEmpty) {
      _toast(l10n.lendToastEnterBorrowerName);
      return;
    }
    if (principal == null || principal <= 0) {
      _toast(l10n.lendToastEnterValidAmount);
      return;
    }
    final interest = double.tryParse(_flatInterestCtrl.text.trim()) ?? 0;
    final payment = double.tryParse(_paymentCtrl.text.trim());
    if (interest < 0 || payment == null || payment <= 0) {
      _toast(l10n.lendToastEnterValidAmount);
      return;
    }
    final rows = _flatScheduleRows(
      principal: principal,
      interest: interest,
      payment: payment,
    );
    if (rows.isEmpty) {
      // Payment too small to ever clear the balance (would need > the cap).
      _toast(l10n.lendToastEnterValidAmount);
      return;
    }
    await _createLoanWithSchedule(principal, rows);
  }

  /// Shared create-then-schedule flow for the custom and flat-amount styles:
  /// create the loan (interest_type 'custom'), push the explicit rows, then
  /// optionally link the disbursement. On any failure after the loan is
  /// created, delete it so no empty loan is left behind.
  Future<void> _createLoanWithSchedule(
    double principal,
    List<Map<String, dynamic>> rows,
  ) async {
    final l10n = AppLocalizations.of(context);
    setState(() => _submitting = true);
    String? loanId;
    try {
      final loan = await widget.apiService.createLoan(
        borrowerName: _borrowerText.trim(),
        principal: principal,
        currency: _currency,
        originationDate: _originationDate,
        interestRate: 0,
        interestType: 'custom',
        notes: _notesCtrl.text.trim().isEmpty ? null : _notesCtrl.text.trim(),
        expectedRepaymentDate: _expectedRepaymentDate,
      );
      loanId = loan['id'].toString();
      await widget.apiService.setCustomSchedule(loanId, rows);
      if (widget.disbursementTxId != null) {
        final ok = await _linkDisbursementOrRollback(loanId);
        if (!ok) return;
      }
      if (!mounted) return;
      Navigator.pop(context, true);
    } catch (e) {
      // Roll back the just-created loan so a failed schedule doesn't leave
      // an empty loan behind.
      if (loanId != null) {
        try {
          await widget.apiService.deleteLoan(loanId);
        } catch (_) {}
      }
      if (!mounted) return;
      setState(() => _submitting = false);
      _toast(l10n.lendCustomScheduleFailed(e.toString()));
    }
  }

  /// Build the flat-amount installment rows from the current inputs. Pure
  /// generation lives in [buildFlatSchedule] (unit-tested).
  List<Map<String, dynamic>> _flatScheduleRows({
    required double principal,
    required double interest,
    required double payment,
  }) => buildFlatSchedule(
    principal: principal,
    interest: interest,
    payment: payment,
    origination: _originationDate,
    frequency: _paymentFrequency,
  );

  /// Link [loanId]'s disbursement to the prefilled transaction. Returns true
  /// on success; on a 409 conflict (tx already funds another loan) it deletes
  /// the loan, shows a message and returns false. Any other failure rethrows.
  Future<bool> _linkDisbursementOrRollback(String loanId) async {
    try {
      await widget.apiService.linkDisbursement(
        loanId,
        widget.disbursementTxId!,
      );
      return true;
    } on DisbursementConflictException {
      try {
        await widget.apiService.deleteLoan(loanId);
      } catch (_) {}
      if (!mounted) return false;
      setState(() => _submitting = false);
      _toast(AppLocalizations.of(context).lendDisbursementConflict);
      return false;
    }
  }

  /// The custom rows as the API payload: `{due_date, amount}`, dropping any
  /// row whose date or amount doesn't parse.
  List<Map<String, dynamic>> _customScheduleRows() {
    final rows = <Map<String, dynamic>>[];
    for (final r in _customRows) {
      final iso = _normalizeDate(r.dateCtrl.text.trim());
      final amt = _parseAmount(r.amountCtrl.text.trim());
      if (iso == null || amt == null) continue;
      rows.add({'due_date': iso, 'amount': amt});
    }
    return rows;
  }

  void _toast(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
