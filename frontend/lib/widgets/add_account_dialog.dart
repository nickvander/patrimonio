import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../utils/theme_colors.dart';
import '../services/api_service.dart';

class AddAccountDialog extends StatefulWidget {
  final VoidCallback onAccountCreated;

  /// Currency the picker starts on. Defaults to USD; the statement import
  /// passes the imported transactions' currency (e.g. MXN for Banamex) so
  /// the new account matches and the confirm currency-guard accepts it.
  final String defaultCurrency;

  const AddAccountDialog({
    super.key,
    required this.onAccountCreated,
    this.defaultCurrency = 'USD',
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

  String _type = 'Checking';
  late String _currency = widget.defaultCurrency;
  bool _isSubmitting = false;

  // Grouped type list. Section labels are rendered as disabled
  // entries so the user sees the structure (Cash / Investments / …)
  // without scanning 14 flat items. The first element of each tuple is a
  // stable group key; the human label is resolved per-build via
  // [_groupLabel] so the section headers can be localized while the
  // account-type VALUES (which are data sent to the API) stay fixed.
  static const _typeGroups = <(String, List<String>)>[
    ('cashBanking', ['Checking', 'Savings', 'CD']),
    ('investments', ['Brokerage', 'Investment', 'IRA', '401k']),
    ('crypto', ['Crypto']),
    ('realAssets', [
      'Real Estate',
      'Vehicle',
      'Private Equity',
      'Collectibles',
      'Other Asset',
    ]),
    ('liabilities', ['Credit Card', 'Loan', 'Mortgage', 'Other Liability']),
  ];

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

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      title: Text(
        l.dlgAccountTitle,
        style: const TextStyle(fontWeight: FontWeight.bold),
      ),
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
                decoration: InputDecoration(
                  labelText: l.dlgAccountName,
                  hintText: l.dlgAccountNameHint,
                ),
                validator: (v) => v?.isEmpty ?? true ? l.commonRequired : null,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _type,
                dropdownColor: Theme.of(context).colorScheme.surface,
                decoration: InputDecoration(labelText: l.dlgAccountType),
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
                    ...types.map((t) => DropdownMenuItem(
                          value: t,
                          child: Padding(
                            padding: const EdgeInsets.only(left: 12),
                            child: Text(t),
                          ),
                        )),
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
                decoration: InputDecoration(labelText: l.dlgAccountCurrency),
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
                decoration: InputDecoration(
                  labelText: l.dlgAccountInitialBalance,
                  // Currency-aware prefix: don't hardcode `$` regardless of
                  // the selected currency.
                  prefixText: _currency == 'MXN' ? r'MX$ ' : r'$ ',
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
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSubmitting ? null : () => Navigator.pop(context),
          child: Text(l.actionCancel),
        ),
        ElevatedButton(
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
        SnackBar(content: Text(l.dlgAccountCreateError(e.toString().replaceFirst('Exception: ', ''))), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }
}
