import 'package:flutter/material.dart';
import '../services/api_service.dart';

class AddAccountDialog extends StatefulWidget {
  final VoidCallback onAccountCreated;

  const AddAccountDialog({Key? key, required this.onAccountCreated}) : super(key: key);

  @override
  _AddAccountDialogState createState() => _AddAccountDialogState();
}

class _AddAccountDialogState extends State<AddAccountDialog> {
  final _formKey = GlobalKey<FormState>();
  final _nameController = TextEditingController();
  final _balanceController = TextEditingController();
  
  String _type = 'Checking';
  String _currency = 'USD';
  bool _isSubmitting = false;

  final List<String> _types = [
    'Checking', 'Savings', 'CD', 'Investment', 'Brokerage', 'Crypto', 'IRA', '401k', 
    'Credit Card', 'Loan', 'Mortgage', 'Real Estate', 'Other Asset', 'Other Liability'
  ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1A1A24),
      title: const Text('Add Manual Account', style: TextStyle(fontWeight: FontWeight.bold)),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _nameController,
                style: const TextStyle(color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Account Name',
                  hintText: 'e.g. My Savings, Rental Property',
                ),
                validator: (v) => v?.isEmpty ?? true ? 'Required' : null,
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: _type,
                dropdownColor: const Color(0xFF1A1A24),
                decoration: const InputDecoration(labelText: 'Account Type'),
                items: _types.map((t) => DropdownMenuItem(value: t, child: Text(t))).toList(),
                onChanged: (v) => setState(() => _type = v!),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                value: _currency,
                dropdownColor: const Color(0xFF1A1A24),
                decoration: const InputDecoration(labelText: 'Currency'),
                items: ['USD', 'MXN'].map((c) => DropdownMenuItem(value: c, child: Text(c))).toList(),
                onChanged: (v) => setState(() => _currency = v!),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _balanceController,
                style: const TextStyle(color: Colors.white),
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: InputDecoration(
                  labelText: 'Initial Balance',
                  prefixText: '\$ ',
                ),
                validator: (v) {
                  final val = double.tryParse(v ?? '');
                  if (val == null) return 'Invalid balance';
                  
                  // For assets, balance should typically be positive. 
                  // For liabilities (Credit Card, Loan, Mortgage), it can be positive or negative 
                  // depending on how the user thinks about it, but we usually store them as negative 
                  // or handle them in the UI. 
                  // Let's just ensure it's a number for now, but maybe add a warning/check.
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
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2)) 
              : const Text('Create Account'),
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
