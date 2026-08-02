import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../theme/palette.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';

class AddAccountDialog extends StatefulWidget {
  final VoidCallback onAccountCreated;

  /// Currency the picker starts on. Defaults to USD; the statement import
  /// passes the imported transactions' currency (e.g. MXN for Banamex) so
  /// the new account matches and the confirm currency-guard accepts it.
  final String defaultCurrency;

  /// Optional pre-filled balance (e.g. a statement import suggesting a
  /// starting balance for a new account/cajita). Editable by the user.
  final double? suggestedBalance;

  /// Optional pre-filled account name (e.g. "Nu — Ahorro" for a cajita).
  final String? suggestedName;

  /// Optional pre-selected account type VALUE (e.g. "Bonds" for a cetesdirecto
  /// import — those are fixed-income securities, not a checking account).
  final String? suggestedType;

  /// Optional statement-derived identity to store with the account and show
  /// for copying (e.g. from a Nu / cetesdirecto import).
  final String? suggestedClabe;
  final String? suggestedHolder;

  /// Optional statement-derived bank name ("CetesDirecto", "Nu México"). When
  /// set, the new account is filed under that institution instead of the
  /// generic "Manual" bucket.
  final String? institutionName;

  const AddAccountDialog({
    super.key,
    required this.onAccountCreated,
    this.defaultCurrency = 'USD',
    this.suggestedBalance,
    this.suggestedName,
    this.suggestedType,
    this.suggestedClabe,
    this.suggestedHolder,
    this.institutionName,
  });

  @override
  State<AddAccountDialog> createState() => _AddAccountDialogState();
}

class _AddAccountDialogState extends State<AddAccountDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  // Default to 0 — most accounts (and every statement import, where the
  // balance is set from the imported closing balance) start there.
  final _balanceController = TextEditingController(text: '0');
  // Statement-derived identity, editable so the user can fix a mis-read.
  final _clabeController = TextEditingController();
  final _holderController = TextEditingController();

  String _type = 'Checking';
  late String _currency = widget.defaultCurrency;
  bool _isSubmitting = false;

  /// Whether to show the editable CLABE / holder fields — only when the
  /// dialog was opened from an import that parsed account identity.
  bool get _hasIdentity =>
      (widget.suggestedClabe?.isNotEmpty ?? false) ||
      (widget.suggestedHolder?.isNotEmpty ?? false);

  @override
  void initState() {
    super.initState();
    if (widget.suggestedName != null && widget.suggestedName!.isNotEmpty) {
      _nameController.text = widget.suggestedName!;
    }
    // Pre-fill a suggested starting balance (e.g. a cajita's reconstructed
    // balance from an import). Only positive suggestions; the user edits.
    final sb = widget.suggestedBalance;
    if (sb != null && sb > 0) {
      _balanceController.text = sb.toStringAsFixed(2);
    }
    if (widget.suggestedClabe != null) {
      _clabeController.text = widget.suggestedClabe!;
    }
    if (widget.suggestedHolder != null) {
      _holderController.text = widget.suggestedHolder!;
    }
    // Pre-select the suggested type (e.g. "Bonds" for a cetesdirecto import)
    // when it's one of the known values.
    final st = widget.suggestedType;
    if (st != null && _typeGroups.any((g) => g.$2.contains(st))) {
      _type = st;
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _balanceController.dispose();
    _clabeController.dispose();
    _holderController.dispose();
    super.dispose();
  }

  // Grouped type list. Section labels are rendered as disabled
  // entries so the user sees the structure (Cash / Investments / …)
  // without scanning 14 flat items. The first element of each tuple is a
  // stable group key; the human label is resolved per-build via
  // [_groupLabel] so the section headers can be localized while the
  // account-type VALUES (which are data sent to the API) stay fixed.
  static const _typeGroups = <(String, List<String>)>[
    ('cashBanking', ['Checking', 'Savings', 'CD']),
    (
      'investments',
      ['Brokerage', 'Stock plan', 'Investment', 'Bonds', 'IRA', '401k', 'HSA'],
    ),
    ('crypto', ['Crypto']),
    (
      'realAssets',
      [
        'Real Estate',
        'Vehicle',
        'Private Equity',
        'Collectibles',
        'Other Asset',
      ],
    ),
    ('liabilities', ['Credit Card', 'Loan', 'Mortgage', 'Other Liability']),
  ];

  /// Localised display label for an account-type VALUE. The value stays
  /// English (it's data sent to the API); only the label is translated.
  String _typeLabel(AppLocalizations l, String type) {
    switch (type) {
      case 'Checking':
        return l.acctTypeChecking;
      case 'Savings':
        return l.acctTypeSavings;
      case 'CD':
        return l.acctTypeCD;
      case 'Brokerage':
        return l.acctTypeBrokerage;
      case 'Investment':
        return l.acctTypeInvestment;
      case 'Bonds':
        return l.acctTypeBonds;
      case 'Stock plan':
        return l.acctTypeStockPlan;
      case 'IRA':
        return l.acctTypeIRA;
      case '401k':
        return l.acctType401k;
      case 'Crypto':
        return l.acctTypeCrypto;
      case 'Real Estate':
        return l.acctTypeRealEstate;
      case 'Vehicle':
        return l.acctTypeVehicle;
      case 'Private Equity':
        return l.acctTypePrivateEquity;
      case 'Collectibles':
        return l.acctTypeCollectibles;
      case 'Other Asset':
        return l.acctTypeOtherAsset;
      case 'Credit Card':
        return l.acctTypeCreditCard;
      case 'Loan':
        return l.acctTypeLoan;
      case 'Mortgage':
        return l.acctTypeMortgage;
      case 'Other Liability':
        return l.acctTypeOtherLiability;
      default:
        return type;
    }
  }

  String _groupLabel(AppLocalizations l, String key) {
    switch (key) {
      case 'cashBanking':
        return l.dlgAccountGroupCashBanking;
      case 'investments':
        return l.dlgAccountGroupInvestments;
      case 'crypto':
        return l.dlgAccountGroupCrypto;
      case 'realAssets':
        return l.dlgAccountGroupRealAssets;
      case 'liabilities':
        return l.dlgAccountGroupLiabilities;
      default:
        return key;
    }
  }

  // (Previously exposed a flat List<String> via `_types`; dropped
  // when the grouped DropdownMenuItem layout replaced the flat one.
  // Left as a note rather than re-added — the grouped form is the
  // current source of truth.)

  /// House input recipe (same as AddTransactionDialog): filled rounded
  /// borderless, keeping labelText (this dialog previously used the
  /// default underline idiom — the third input style in the app).
  InputDecoration _fieldDecoration({
    required String labelText,
    String? hintText,
    String? prefixText,
    String? suffixText,
    String? helperText,
    int? helperMaxLines,
  }) {
    return InputDecoration(
      labelText: labelText,
      hintText: hintText,
      prefixText: prefixText,
      suffixText: suffixText,
      helperText: helperText,
      helperMaxLines: helperMaxLines,
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
    return AlertDialog(
      // House dialog shell: card tone (matching every other add dialog)
      // + the theme's titleLarge instead of a bold override.
      backgroundColor: BrandPalette.cardSurface(Theme.of(context).brightness),
      titleTextStyle: Theme.of(context).textTheme.titleLarge,
      title: Text(l.dlgAccountTitle),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                style: TextStyle(color: context.textPrimary),
                autofocus: true,
                decoration: _fieldDecoration(
                  labelText: l.dlgAccountName,
                  hintText: l.dlgAccountNameHint,
                ),
                validator: (v) => v?.isEmpty ?? true ? l.commonRequired : null,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _type,
                dropdownColor: Theme.of(context).colorScheme.surface,
                decoration: _fieldDecoration(labelText: l.dlgAccountType),
                items: [
                  for (final (groupKey, types) in _typeGroups) ...[
                    // Group header — disabled so it can't be picked but
                    // visually separates the list. Material's
                    // DropdownMenuItem doesn't natively support disabled
                    // headers, so we render with `enabled: false`.
                    DropdownMenuItem<String>(
                      enabled: false,
                      value: null,
                      child: Text(
                        _groupLabel(l, groupKey).toUpperCase(),
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.0,
                          color: context.textFaint,
                        ),
                      ),
                    ),
                    ...types.map(
                      (t) => DropdownMenuItem(
                        value: t,
                        child: Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: Text(_typeLabel(l, t)),
                        ),
                      ),
                    ),
                  ],
                ],
                onChanged: (v) {
                  if (v != null) setState(() => _type = v);
                },
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _currency,
                dropdownColor: Theme.of(context).colorScheme.surface,
                decoration: _fieldDecoration(labelText: l.dlgAccountCurrency),
                items: ['USD', 'MXN']
                    .map((c) => DropdownMenuItem(value: c, child: Text(c)))
                    .toList(),
                onChanged: (v) => setState(() => _currency = v!),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _balanceController,
                style: TextStyle(color: context.textPrimary),
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                  signed: true,
                ),
                decoration: _fieldDecoration(
                  labelText: l.dlgAccountInitialBalance,
                  // Currency-aware prefix via the house symbol table —
                  // no hand-rolled `$`/`MXN ` branch (display-only; the
                  // popped values are unchanged).
                  prefixText: currencySymbol(_currency),
                  suffixText: _currency,
                  helperText: l.dlgAccountBalanceHelper,
                  helperMaxLines: 2,
                ),
                validator: (v) {
                  final val = double.tryParse(v ?? '');
                  if (val == null) return l.dlgAccountBalanceInvalid;
                  return null;
                },
              ),
              // Statement-derived identity (holder / CLABE) — editable so a
              // mis-read can be corrected before it's saved on the account.
              if (_hasIdentity) ...[
                const SizedBox(height: 16),
                TextFormField(
                  controller: _holderController,
                  style: TextStyle(color: context.textPrimary),
                  decoration: _fieldDecoration(labelText: l.dlgAccountHolder),
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _clabeController,
                  style: TextStyle(color: context.textPrimary),
                  keyboardType: TextInputType.number,
                  decoration: _fieldDecoration(labelText: l.dlgAccountClabe),
                  validator: (v) {
                    final digits = (v ?? '').replaceAll(RegExp(r'\D'), '');
                    // Optional, but if present must be a full 18-digit CLABE.
                    if (digits.isEmpty || digits.length == 18) return null;
                    return l.dlgAccountClabeInvalid;
                  },
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.pop(context),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: _isSubmitting ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l.dlgAccountCreate),
        ),
      ],
    );
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isSubmitting = true);

    try {
      final apiService = ApiService();
      await apiService.createAccount(
        name: _nameController.text,
        type: _type,
        currency: _currency,
        initialBalance: double.parse(_balanceController.text),
        clabe: _clabeController.text,
        holderName: _holderController.text,
        institutionName: widget.institutionName,
      );

      widget.onAccountCreated();
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      Navigator.pop(context);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.dlgAccountCreated(_nameController.text))),
      );
    } catch (e) {
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l.dlgAccountCreateError(
              e.toString().replaceFirst('Exception: ', ''),
            ),
          ),
          backgroundColor: context.negative,
        ),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }
}
