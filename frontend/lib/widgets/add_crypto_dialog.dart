import 'package:flutter/material.dart';
import '../services/api_service.dart';

class AddCryptoDialog extends StatefulWidget {
  final String exchange; // 'coinbase' or 'bitso'
  final VoidCallback onLinked;

  const AddCryptoDialog({
    Key? key,
    required this.exchange,
    required this.onLinked,
  }) : super(key: key);

  @override
  State<AddCryptoDialog> createState() => _AddCryptoDialogState();
}

class _AddCryptoDialogState extends State<AddCryptoDialog> {
  final _formKey = GlobalKey<FormState>();
  final _apiService = ApiService();
  
  final _nameController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _apiSecretController = TextEditingController();
  final _apiPassController = TextEditingController();
  
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _nameController.text = widget.exchange == 'coinbase' ? 'Coinbase' : 'Bitso';
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;

    setState(() => _isLoading = true);
    try {
      await _apiService.linkCryptoInstitution(
        name: _nameController.text,
        integrationType: widget.exchange,
        apiKey: _apiKeyController.text.trim(),
        apiSecret: _apiSecretController.text.trim(),
        apiPass: _apiPassController.text.trim().isEmpty ? null : _apiPassController.text.trim(),
      );
      
      if (mounted) {
        Navigator.of(context).pop();
        widget.onLinked();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Successfully linked ${widget.exchange}!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error linking: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final isCoinbase = widget.exchange == 'coinbase';
    final accentColor = isCoinbase ? const Color(0xFF0052FF) : const Color(0xFF00E676);

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            isCoinbase ? Icons.currency_bitcoin : Icons.currency_exchange, 
            color: accentColor
          ),
          const SizedBox(width: 12),
          Text('Link ${isCoinbase ? 'Coinbase' : 'Bitso'}'),
        ],
      ),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Generate a "Read-Only" API key in Bitso settings. We only use this to fetch balances and estimate their value.',
                style: TextStyle(fontSize: 12, color: Colors.white70),
              ),
              const SizedBox(height: 8),
              InkWell(
                onTap: () {
                  // In a real browser, this would open the link
                  // web.window.open('https://bitso.com/api_info', '_blank');
                },
                child: const Text(
                  'Where do I find my API keys? ↗',
                  style: TextStyle(fontSize: 12, color: Color(0xFF00E676), fontWeight: FontWeight.bold),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Display Name (e.g. My Bitso)', border: OutlineInputBorder()),
                validator: (v) => v!.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _apiKeyController,
                decoration: const InputDecoration(labelText: 'API Key', border: OutlineInputBorder()),
                validator: (v) => v!.isEmpty ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _apiSecretController,
                decoration: const InputDecoration(labelText: 'API Secret', border: OutlineInputBorder()),
                obscureText: true,
                validator: (v) => v!.isEmpty ? 'Required' : null,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _submit,
          style: ElevatedButton.styleFrom(backgroundColor: accentColor, foregroundColor: Colors.white),
          child: _isLoading 
            ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
            : const Text('Link Account'),
        ),
      ],
    );
  }
}
