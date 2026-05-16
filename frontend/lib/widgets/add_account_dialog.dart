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

  final List<String> _types = [
    'Checking',
    'Savings',
    'CD',
    'Investment',
    'Brokerage',
    'Crypto',
    'IRA',
    '401k',
    'Credit Card',
    'Loan',
    'Mortgage',
    'Real Estate',
    'Other Asset',
    'Other Liability',
  ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A24),
      title: Text(
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
                dropdownColor: const Color(0xFF1A1A24),
                decoration: const InputDecoration(labelText: 'Account type'),
                items: _types
                    .map((t) => DropdownMenuItem(value: t, child: Text(t)))
                    .toList(),
                onChanged: (v) => setState(() => _type = v!),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: _currency,
                dropdownColor: const Color(0xFF1A1A24),
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
          child: Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isSubmitting ? null : _submit,
          child: _isSubmitting
              ? const SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text('Create account'),
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
