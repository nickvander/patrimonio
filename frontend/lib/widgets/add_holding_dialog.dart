import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/api_service.dart';
import '../utils/theme_colors.dart';

/// Add a manual equity holding (ticker + share quantity) to an account. The
/// backend prices it live from the Yahoo quote cache and folds its value into
/// the account balance. For positions Plaid can't link — e.g. a Fidelity
/// NetBenefits ESPP stake.
class AddHoldingDialog extends StatefulWidget {
  final String accountId;
  final VoidCallback onAdded;

  const AddHoldingDialog({
    super.key,
    required this.accountId,
    required this.onAdded,
  });

  @override
  State<AddHoldingDialog> createState() => _AddHoldingDialogState();
}

class _AddHoldingDialogState extends State<AddHoldingDialog> {
  final _formKey = GlobalKey<FormState>();
  final _symbol = TextEditingController();
  final _qty = TextEditingController();
  final _cost = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _symbol.dispose();
    _qty.dispose();
    _cost.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      await ApiService().createHolding(
        widget.accountId,
        symbol: _symbol.text.trim().toUpperCase(),
        quantity: double.parse(_qty.text.trim()),
        costBasis:
            _cost.text.trim().isEmpty ? null : double.tryParse(_cost.text.trim()),
      );
      widget.onAdded();
      if (!mounted) return;
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(e.toString().replaceFirst('Exception: ', '')),
        backgroundColor: context.negative,
      ));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final es = Localizations.localeOf(context).languageCode == 'es';
    return AlertDialog(
      backgroundColor: Theme.of(context).colorScheme.surface,
      title: Text(es ? 'Agregar posición' : 'Add holding',
          style: const TextStyle(fontWeight: FontWeight.bold)),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _symbol,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z.\-]')),
              ],
              style: TextStyle(color: context.textPrimary),
              decoration: InputDecoration(
                labelText: es ? 'Símbolo (ticker)' : 'Ticker symbol',
                hintText: 'ORCL',
              ),
              validator: (v) => (v == null || v.trim().isEmpty)
                  ? (es ? 'Requerido' : 'Required')
                  : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _qty,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: TextStyle(color: context.textPrimary),
              decoration: InputDecoration(
                labelText: es ? 'Número de acciones' : 'Number of shares',
                hintText: '325',
              ),
              validator: (v) {
                final d = double.tryParse((v ?? '').trim());
                return (d == null || d <= 0)
                    ? (es ? 'Cantidad inválida' : 'Invalid quantity')
                    : null;
              },
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _cost,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              style: TextStyle(color: context.textPrimary),
              decoration: InputDecoration(
                labelText: es
                    ? 'Costo base total (opcional)'
                    : 'Total cost basis (optional)',
                prefixText: r'$ ',
              ),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.bolt, size: 14, color: context.tealAccent),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    es
                        ? 'Se valúa con el precio en vivo (Yahoo Finance).'
                        : 'Valued live from Yahoo Finance.',
                    style: TextStyle(fontSize: 11.5, color: context.textSubtle),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _submitting ? null : () => Navigator.pop(context),
          child: Text(es ? 'Cancelar' : 'Cancel'),
        ),
        ElevatedButton(
          onPressed: _submitting ? null : _submit,
          child: _submitting
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(es ? 'Agregar' : 'Add'),
        ),
      ],
    );
  }
}
