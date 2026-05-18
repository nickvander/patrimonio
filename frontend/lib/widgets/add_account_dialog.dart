import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import '../services/api_service.dart';

class AddAccountDialog extends StatefulWidget {
  final VoidCallback onAccountCreated;

  const AddAccountDialog({super.key, required this.onAccountCreated});

  @override
  State<AddAccountDialog> createState() => _AddAccountDialogState();
}

class _AddAccountDialogState extends State<AddAccountDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _balanceController = TextEditingController();

  String _type = 'Checking';
  String _currency = 'USD';
  bool _isSubmitting = false;

  // Grouped type list. Section labels are rendered as disabled
  // entries so the user sees the structure (Cash / Investments / …)
  // without scanning 14 flat items.
  static const _typeGroups = <(String, List<String>)>[
    ('Cash & banking', ['Checking', 'Savings', 'CD']),
    ('Investments', ['Brokerage', 'Investment', 'IRA', '401k']),
    ('Crypto', ['Crypto']),
    ('Real assets', [
      'Real Estate',
      'Vehicle',
      'Private Equity',
      'Collectibles',
      'Other Asset',
    ]),
    ('Liabilities', ['Credit Card', 'Loan', 'Mortgage', 'Other Liability']),
  ];

  static List<String> get _types =>
      _typeGroups.expand((g) => g.$2).toList();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      title: const Text(
        'Add manual account',
        style: TextStyle(fontWeight: FontWeight.bold),
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
                decoration: const InputDecoration(
                  labelText: 'Account name',
                  hintText: 'e.g. My savings, Rental property',
                ),
                validator: (v) => v?.isEmpty ?? true ? 'Required' : null,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _type,
                dropdownColor: Theme.of(context).colorScheme.surface,
                decoration: const InputDecoration(labelText: 'Account type'),
                items: [
                  for (final (label, types) in _typeGroups) ...[
                    // Group header — disabled so it can't be picked but
                    // visually separates the list. Material's
                    // DropdownMenuItem doesn't natively support disabled
                    // headers, so we render with `enabled: false`.
                    DropdownMenuItem<String>(
                      enabled: false,
                      value: null,
                      child: Text(
                        label.toUpperCase(),
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
                decoration: const InputDecoration(labelText: 'Currency'),
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
                  labelText: 'Initial balance',
                  // Currency-aware prefix: don't hardcode `$` regardless of
                  // the selected currency.
                  prefixText: _currency == 'MXN' ? r'$ ' : r'$ ',
                  suffixText: _currency,
                  helperText:
                      'For credit cards / loans, enter the amount owed as a positive number.',
                  helperMaxLines: 2,
                ),
                validator: (v) {
                  final val = double.tryParse(v ?? '');
                  if (val == null) return 'Enter a numeric amount';
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
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isSubmitting ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create account'),
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
      Navigator.pop(context);

      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Account "${_nameController.text}" created!')),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error: $e'), backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }
}
