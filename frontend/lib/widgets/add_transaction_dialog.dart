import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';

/// Dialog for manually entering a transaction — for cash spend, gifts,
/// reimbursements, anything Plaid never sees. Default sign convention
/// matches the rest of the app: amount > 0 = outflow (expense),
/// amount < 0 = inflow (income); the UI hides that with a clearer
/// "Expense / Income" toggle and computes the sign at submit time.
class AddTransactionDialog extends StatefulWidget {
  final List<dynamic> accounts;
  final ApiService apiService;
  final VoidCallback onCreated;

  const AddTransactionDialog({
    super.key,
    required this.accounts,
    required this.apiService,
    required this.onCreated,
  });

  @override
  State<AddTransactionDialog> createState() => _AddTransactionDialogState();
}

class _AddTransactionDialogState extends State<AddTransactionDialog> {
  final _descController = TextEditingController();
  final _amountController = TextEditingController();
  final _categoryController = TextEditingController();
  final _notesController = TextEditingController();
  DateTime _date = DateTime.now();
  bool _isExpense = true;
  String? _accountId;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
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
    final desc = _descController.text.trim();
    if (desc.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Description is required')),
      );
      return;
    }
    final raw = double.tryParse(_amountController.text.trim());
    if (raw == null || raw <= 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Enter a positive amount')),
      );
      return;
    }
    final signed = _isExpense ? raw : -raw;
    final currency =
        (account['currency'] ?? 'USD').toString().toUpperCase();

    setState(() => _saving = true);
    try {
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
      if (!mounted) return;
      Navigator.pop(context);
      widget.onCreated();
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Transaction added')),
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
    final selectedAcct = _selectedAccount();
    final currency =
        (selectedAcct?['currency'] ?? 'USD').toString().toUpperCase();

    return AlertDialog(
      title: const Text('Add transaction'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.accounts.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text(
                    'You need at least one account before you can add a '
                    'transaction.',
                    style: TextStyle(color: Colors.orangeAccent),
                  ),
                ),
              DropdownButtonFormField<String>(
                initialValue: _accountId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Account',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                items: widget.accounts.map<DropdownMenuItem<String>>((a) {
                  final id = a['id']?.toString();
                  final nick = (a['nickname'] ?? '').toString();
                  final name = (a['name'] ?? '').toString();
                  final label = nick.isNotEmpty ? nick : name;
                  return DropdownMenuItem(
                    value: id,
                    child: Text(label, overflow: TextOverflow.ellipsis),
                  );
                }).toList(),
                onChanged: (v) => setState(() => _accountId = v),
              ),
              const SizedBox(height: 12),
              SegmentedButton<bool>(
                segments: const [
                  ButtonSegment(
                    value: true,
                    icon: Icon(Icons.arrow_upward, size: 14),
                    label: Text('Expense'),
                  ),
                  ButtonSegment(
                    value: false,
                    icon: Icon(Icons.arrow_downward, size: 14),
                    label: Text('Income'),
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
                    flex: 2,
                    child: TextField(
                      controller: _amountController,
                      keyboardType: const TextInputType.numberWithOptions(
                          decimal: true),
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(
                            RegExp(r'^[0-9]*\.?[0-9]{0,2}')),
                      ],
                      decoration: InputDecoration(
                        labelText: 'Amount',
                        prefixText: '$currency ',
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    flex: 3,
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
                        decoration: const InputDecoration(
                          labelText: 'Date',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                        child: Text(DateFormat('MMM d, y').format(_date)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descController,
                decoration: const InputDecoration(
                  labelText: 'Description',
                  hintText: 'e.g. Coffee with Sam',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                textCapitalization: TextCapitalization.sentences,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _categoryController,
                decoration: const InputDecoration(
                  labelText: 'Category (optional)',
                  hintText: 'e.g. Restaurants',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _notesController,
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                maxLines: 2,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
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
              : const Text('Add'),
        ),
      ],
    );
  }
}
