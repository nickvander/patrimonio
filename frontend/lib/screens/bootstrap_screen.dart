import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../widgets/recovery_codes_dialog.dart';
import '../l10n/app_localizations.dart';

/// First-run screen: create the single owner account. Shown only when
/// the server reports `needs_bootstrap: true`. After success the user
/// is signed in and dropped on the dashboard.
class BootstrapScreen extends StatefulWidget {
  const BootstrapScreen({super.key});

  @override
  State<BootstrapScreen> createState() => _BootstrapScreenState();
}

class _BootstrapScreenState extends State<BootstrapScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _email.dispose();
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final outcome = await AuthService.instance.bootstrap(
        username: _username.text.trim(),
        email: _email.text.trim().isEmpty ? null : _email.text.trim(),
        password: _password.text,
      );
      // Show the recovery codes BEFORE the dashboard renders. The
      // dialog is blocking — the user must explicitly acknowledge
      // saving the codes before they can proceed.
      if (mounted) {
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => RecoveryCodesDialog(codes: outcome.recoveryCodes),
        );
      }
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    l.authWelcomeTitle,
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l.authBootstrapSubtitle,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _username,
                    decoration: InputDecoration(
                      labelText: l.authUsername,
                      border: const OutlineInputBorder(),
                    ),
                    validator: (v) {
                      final value = v?.trim() ?? '';
                      if (value.isEmpty) return l.commonRequired;
                      if (value.length > 64) return l.authUsernameMaxLength;
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _email,
                    decoration: InputDecoration(
                      labelText: l.authEmailOptional,
                      border: const OutlineInputBorder(),
                    ),
                    keyboardType: TextInputType.emailAddress,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: l.authPasswordWithMin,
                      border: const OutlineInputBorder(),
                    ),
                    validator: (v) {
                      if (v == null || v.length < 12) {
                        return l.authPasswordMinHelper;
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _confirm,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: l.authConfirmPassword,
                      border: const OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        v == _password.text ? null : l.authPasswordsDoNotMatch,
                  ),
                  const SizedBox(height: 16),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                    const SizedBox(height: 12),
                  ],
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            height: 18,
                            width: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : Text(l.authCreateAccount),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
