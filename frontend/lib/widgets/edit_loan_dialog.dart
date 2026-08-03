import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../theme/menus.dart';
import '../utils/currency.dart' show currencySymbol;
import '../utils/theme_colors.dart';

/// Mirrors the add-loan dialog's look (same _section / _twoUp / filled
/// inputs) but only exposes the fields the backend PATCH accepts:
/// borrower_name, principal, interest_rate, interest_type, notes.
/// rate_period / term / payment frequency are NOT in UpdateLoanRequest,
/// so they're shown read-only for context. Pops a map of the changed
/// fields (display shape — `principal`/`interest_rate` as numbers,
/// `interest_rate` still a fraction) on success, or null on cancel.
class EditLoanDialog extends StatefulWidget {
  final ApiService apiService;
  final Map<String, dynamic> loan;

  const EditLoanDialog({
    super.key,
    required this.apiService,
    required this.loan,
  });

  @override
  State<EditLoanDialog> createState() => _EditLoanDialogState();
}

class _EditLoanDialogState extends State<EditLoanDialog> {
  late final TextEditingController _borrowerCtrl;
  late final TextEditingController _principalCtrl;
  late final TextEditingController _rateCtrl;
  late final TextEditingController _notesCtrl;
  late String _interestType;
  DateTime? _expectedRepaymentDate;
  bool _submitting = false;

  String get _currency => (widget.loan['currency'] ?? 'USD').toString();

  /// Amount-field prefix for the loan's own currency, taken from the house
  /// [currencySymbol] map (`$ `, `MXN `) rather than hardcoded, so the field
  /// agrees with every other money surface. `trimRight` normalizes the map's
  /// already-spaced entries so the prefix never doubles its space.
  String get _amountPrefix => '${currencySymbol(_currency).trimRight()} ';

  String get _ratePeriod => (widget.loan['rate_period'] ?? 'annual').toString();

  @override
  void initState() {
    super.initState();
    _borrowerCtrl = TextEditingController(
      text: (widget.loan['borrower_name'] ?? '').toString(),
    );
    final principal = (widget.loan['principal'] as num?)?.toDouble() ?? 0;
    _principalCtrl = TextEditingController(
      text: principal == 0 ? '' : _trimZeros(principal),
    );
    // Stored as a fraction; show as a percent (×100), mirroring add-loan.
    final rateFraction =
        (widget.loan['interest_rate'] as num?)?.toDouble() ?? 0;
    _rateCtrl = TextEditingController(
      text: rateFraction == 0 ? '' : _trimZeros(rateFraction * 100),
    );
    _notesCtrl = TextEditingController(
      text: (widget.loan['notes'] ?? '').toString(),
    );
    _interestType = (widget.loan['interest_type'] ?? 'none').toString();
    final erd = widget.loan['expected_repayment_date'];
    _expectedRepaymentDate = erd == null
        ? null
        : DateTime.tryParse(erd.toString());
  }

  Future<void> _pickExpectedDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate:
          _expectedRepaymentDate ??
          DateTime.now().add(const Duration(days: 30)),
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

  /// Format a double for an editable field without a trailing ".0".
  String _trimZeros(double v) {
    final s = v.toStringAsFixed(2);
    return s.endsWith('.00')
        ? s.substring(0, s.length - 3)
        : (s.endsWith('0') ? s.substring(0, s.length - 1) : s);
  }

  @override
  void dispose() {
    _borrowerCtrl.dispose();
    _principalCtrl.dispose();
    _rateCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final contentMaxHeight = (media.size.height - media.viewInsets.bottom - 220)
        .clamp(220.0, 620.0);
    final dialogWidth = media.size.width - 32 < 460
        ? media.size.width - 32
        : 460.0;
    final readOnlyTerms = _termsSummary();

    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(24, 24, 24, 8),
      contentPadding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
      title: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: context.accentSoft(context.tealAccent),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              Icons.edit_outlined,
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
                  AppLocalizations.of(context).lendEditLoanTitle,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                ),
                Text(
                  AppLocalizations.of(context).lendEditLoanSubtitle,
                  style: TextStyle(fontSize: 12, color: context.textMuted),
                ),
              ],
            ),
          ),
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogWidth,
          maxHeight: contentMaxHeight,
        ),
        child: SizedBox(
          width: dialogWidth,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _section(
                  AppLocalizations.of(context).lendSectionBorrowerAmount,
                  [
                    TextField(
                      controller: _borrowerCtrl,
                      decoration: _decoration(
                        AppLocalizations.of(context).lendFieldBorrowerName,
                        icon: Icons.person_outline,
                      ),
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      controller: _principalCtrl,
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      decoration: _decoration(
                        AppLocalizations.of(context).lendFieldAmountLent,
                        prefixText: _amountPrefix,
                        icon: Icons.payments_outlined,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                _section(
                  AppLocalizations.of(context).lendSectionInterestTerms,
                  [
                    DropdownButtonFormField<String>(
                      initialValue: _interestType,
                      isExpanded: true,
                      dropdownColor: houseDropdownColor(context),
                      borderRadius: kMenuRadius,
                      decoration: _decoration(
                        AppLocalizations.of(context).lendFieldInterestType,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'none',
                          child: Text(
                            AppLocalizations.of(context).lendInterestTypeNone,
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'simple',
                          child: Text(
                            AppLocalizations.of(context).lendInterestTypeSimple,
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'amortized',
                          child: Text(
                            AppLocalizations.of(
                              context,
                            ).lendInterestTypeAmortized,
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'interest_only',
                          child: Text(
                            AppLocalizations.of(
                              context,
                            ).lendInterestTypeInterestOnly,
                          ),
                        ),
                        DropdownMenuItem(
                          value: 'compound',
                          child: Text(
                            AppLocalizations.of(
                              context,
                            ).lendInterestTypeCompound,
                          ),
                        ),
                      ],
                      onChanged: (v) =>
                          setState(() => _interestType = v ?? 'none'),
                    ),
                    if (_interestType != 'none') ...[
                      const SizedBox(height: 12),
                      TextField(
                        controller: _rateCtrl,
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        decoration: _decoration(
                          AppLocalizations.of(
                            context,
                          ).lendEditRatePerPeriod(_ratePeriod),
                          hint: AppLocalizations.of(
                            context,
                          ).lendRateHintExample,
                          icon: Icons.percent,
                        ),
                      ),
                    ],
                    if (readOnlyTerms != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        readOnlyTerms,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.textSubtle,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 16),
                _section(
                  AppLocalizations.of(context).lendSectionExpectedRepayment,
                  [_expectedDateField()],
                ),
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
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: Text(AppLocalizations.of(context).actionCancel),
        ),
        FilledButton.icon(
          onPressed: _submitting ? null : _submit,
          icon: _submitting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.check, size: 18),
          label: Text(AppLocalizations.of(context).lendSaveChanges),
        ),
      ],
    );
  }

  /// Read-only summary of the term / payment-frequency fields the PATCH
  /// endpoint doesn't accept, so the user understands why they're not
  /// editable here. Null when the loan is open-ended (nothing to show).
  String? _termsSummary() {
    final term = (widget.loan['term_months'] as num?)?.toInt();
    final freq = widget.loan['payment_frequency']?.toString();
    if (term == null && (freq == null || freq.isEmpty)) return null;
    final l10n = AppLocalizations.of(context);
    final parts = <String>[];
    if (term != null) parts.add(l10n.lendTermsSummaryTermMonths(term));
    if (freq != null && freq.isNotEmpty) {
      parts.add(switch (freq) {
        'monthly' => l10n.lendTermsSummaryMonthlyPayments,
        'weekly' => l10n.lendTermsSummaryWeeklyPayments,
        'lump_sum' => l10n.lendTermsSummaryLumpSumPayment,
        _ => '$freq payments',
      });
    }
    return l10n.lendTermsSummaryFixed(parts.join(' · '));
  }

  /// A titled group of fields in a soft card (mirrors AddLoanDialog).
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

  /// Shared filled, rounded input styling (mirrors AddLoanDialog).
  InputDecoration _decoration(
    String label, {
    String? hint,
    String? prefixText,
    IconData? icon,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      prefixText: prefixText,
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

  Future<void> _submit() async {
    final borrower = _borrowerCtrl.text.trim();
    final principal = double.tryParse(_principalCtrl.text.trim());
    if (borrower.isEmpty) {
      _toast(AppLocalizations.of(context).lendToastEnterBorrowerName);
      return;
    }
    if (principal == null || principal <= 0) {
      _toast(AppLocalizations.of(context).lendToastEnterValidAmount);
      return;
    }
    final interestBearing = _interestType != 'none';
    // Rate entered as a percent; backend wants a fraction (mirrors
    // add-loan). A non-interest loan stores a 0 rate.
    final ratePct = interestBearing
        ? (double.tryParse(_rateCtrl.text.trim()) ?? 0)
        : 0.0;
    final rateFraction = ratePct / 100.0;
    final notes = _notesCtrl.text.trim();

    setState(() => _submitting = true);
    try {
      await widget.apiService.updateLoan(
        widget.loan['id'].toString(),
        const <String, dynamic>{},
        borrowerName: borrower,
        principal: principal,
        interestRate: rateFraction,
        interestType: _interestType,
        // Empty clears the note (COALESCE keeps the old value only on
        // null; we send an explicit empty string to allow clearing).
        notes: notes,
        expectedRepaymentDate: _expectedRepaymentDate,
      );
      if (!mounted) return;
      // Hand the edited values back in the loan's display shape so the
      // detail sheet can update its header optimistically.
      Navigator.pop(context, <String, dynamic>{
        'borrower_name': borrower,
        'principal': principal,
        'interest_rate': rateFraction,
        'interest_type': _interestType,
        'notes': notes,
        if (_expectedRepaymentDate != null)
          'expected_repayment_date': DateFormat(
            'yyyy-MM-dd',
          ).format(_expectedRepaymentDate!),
      });
    } on LoanTermsLockedException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _toast(e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      _toast(AppLocalizations.of(context).lendToastCouldntSaveChanges);
    }
  }

  void _toast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }
}
