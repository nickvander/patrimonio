import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/theme_colors.dart';

/// Per-exchange copy for the credential dialog. Keyed by the integration
/// type string the dialog is opened with. Keeping label, docs URL, and the
/// example display-name together here means adding Coinbase (or any future
/// exchange) is a one-entry change instead of hunting hardcoded "Bitso"
/// strings through the build method.
class _ExchangeInfo {
  final String label;
  final Uri apiDocsUrl;
  final String exampleName;
  const _ExchangeInfo({
    required this.label,
    required this.apiDocsUrl,
    required this.exampleName,
  });
}

final Map<String, _ExchangeInfo> _exchangeInfo = {
  'bitso': _ExchangeInfo(
    label: 'Bitso',
    apiDocsUrl: Uri.parse('https://bitso.com/api_info'),
    exampleName: 'My Bitso',
  ),
  'coinbase': _ExchangeInfo(
    label: 'Coinbase',
    apiDocsUrl:
        Uri.parse('https://docs.cdp.coinbase.com/coinbase-app/docs/auth/api-key-authentication'),
    exampleName: 'My Coinbase',
  ),
};

class AddCryptoDialog extends StatefulWidget {
  final String exchange; // 'coinbase' or 'bitso'
  final VoidCallback onLinked;

  const AddCryptoDialog({
    super.key,
    required this.exchange,
    required this.onLinked,
  });

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

  // Falls back to Bitso's copy for an unknown exchange so the dialog never
  // renders blank labels; today only bitso/coinbase are wired.
  _ExchangeInfo get _info => _exchangeInfo[widget.exchange] ?? _exchangeInfo['bitso']!;

  @override
  void initState() {
    super.initState();
    _nameController.text = _info.label;
  }

  @override
  void dispose() {
    // This State owns these four controllers; dispose them or every
    // open/close of the add-crypto dialog leaks them.
    _nameController.dispose();
    _apiKeyController.dispose();
    _apiSecretController.dispose();
    _apiPassController.dispose();
    super.dispose();
  }

  Future<void> _openApiDocs() async {
    final url = _info.apiDocsUrl;
    // launchUrl can throw if no handler is registered; surface a hint with
    // the URL as selectable text rather than failing silently — the whole
    // point of this link is to be trustworthy on a credential screen.
    try {
      final ok = await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!ok) throw Exception('no handler');
    } catch (_) {
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(l.dlgCryptoApiKeysTitle(_info.label)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l.dlgCryptoApiKeysFallbackBody(_info.label)),
              const SizedBox(height: 8),
              SelectableText(
                url.toString(),
                style: TextStyle(color: context.info),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l.actionClose),
            ),
          ],
        ),
      );
    }
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
        apiPass: _apiPassController.text.trim().isEmpty
            ? null
            : _apiPassController.text.trim(),
      );

      if (mounted) {
        final l = AppLocalizations.of(context);
        Navigator.of(context).pop();
        widget.onLinked();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.dlgCryptoLinkSuccess(_info.label))),
        );
      }
    } catch (e) {
      if (mounted) {
        final l = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.dlgCryptoLinkError(e.toString())),
            backgroundColor: context.negative,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final isCoinbase = widget.exchange == 'coinbase';
    // Coinbase blue is brand-fixed (it's their logo colour); Bitso
    // uses our brightness-aware positive accent so the icon stays
    // AA-readable in both themes.
    final accentColor = isCoinbase
        ? context.info
        : context.positive;

    return AlertDialog(
      title: Row(
        children: [
          Icon(
            isCoinbase ? Icons.currency_bitcoin : Icons.currency_exchange,
            color: accentColor,
          ),
          const SizedBox(width: 12),
          Text(l.dlgCryptoLinkTitle(_info.label)),
        ],
      ),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l.dlgCryptoIntro(_info.label),
                style: TextStyle(fontSize: 12, color: context.textMuted),
              ),
              const SizedBox(height: 8),
              InkWell(
                onTap: _openApiDocs,
                child: Text(
                  l.dlgCryptoWhereApiKeys,
                  style: TextStyle(
                    fontSize: 12,
                    color: context.positive,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _nameController,
                decoration: InputDecoration(
                  labelText: l.dlgCryptoDisplayName(_info.exampleName),
                  border: const OutlineInputBorder(),
                ),
                validator: (v) => v!.isEmpty ? l.commonRequired : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _apiKeyController,
                decoration: InputDecoration(
                  labelText: l.dlgCryptoApiKey,
                  border: const OutlineInputBorder(),
                ),
                validator: (v) => v!.isEmpty ? l.commonRequired : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _apiSecretController,
                decoration: InputDecoration(
                  labelText: l.dlgCryptoApiSecret,
                  border: const OutlineInputBorder(),
                ),
                obscureText: true,
                validator: (v) => v!.isEmpty ? l.commonRequired : null,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isLoading ? null : () => Navigator.pop(context),
          child: Text(l.actionCancel),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _submit,
          style: ElevatedButton.styleFrom(
            backgroundColor: accentColor,
            foregroundColor: context.textPrimary,
          ),
          child: _isLoading
              ? SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: context.textPrimary,
                  ),
                )
              : Text(l.dlgCryptoLinkAccount),
        ),
      ],
    );
  }
}
