import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../widgets/recovery_codes_dialog.dart';
import '../l10n/app_localizations.dart';

/// Invite-redemption + account-creation screen.
///
/// Rendered by AuthGate when the URL contains `?invite=<token>` and
/// the user is signed-out. Identical shape to the bootstrap screen but
/// for second-and-later users; the difference is `token` is required
/// here while bootstrap silently uses "the table is empty".
class RegisterScreen extends StatefulWidget {
  final String inviteToken;
  const RegisterScreen({super.key, required this.inviteToken});

  @override
  State<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends State<RegisterScreen> {
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
      final outcome = await ApiService().register(
        token: widget.inviteToken,
        username: _username.text.trim(),
        email: _email.text.trim().isEmpty ? null : _email.text.trim(),
        password: _password.text,
      );
      if (!mounted) return;
      // Show the one-time recovery codes immediately, then drop the
      // ?invite= parameter from the URL (otherwise refreshing the
      // dashboard would re-render the register screen) and let
      // AuthGate refresh into signed-in state.
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => RecoveryCodesDialog(codes: outcome.recoveryCodes),
      );
      await AuthService.instance.refreshStatus();
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
          constraints: const BoxConstraints(maxWidth: 380),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Patrimonio',
                    textAlign: TextAlign.center,
                    style: Theme.of(context)
                        .textTheme
                        .headlineMedium
                        ?.copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l.authCreateAccount,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l.authInviteIntro,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.color
                          ?.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 24),
                  TextFormField(
                    controller: _username,
                    autofillHints: const [AutofillHints.newUsername],
                    decoration: InputDecoration(
                      labelText: l.authUsername,
                      border: const OutlineInputBorder(),
                    ),
                    validator: (v) {
                      final s = (v ?? '').trim();
                      if (s.isEmpty) return l.commonRequired;
                      if (s.length > 64) return l.authUsernameMaxLength;
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _email,
                    autofillHints: const [AutofillHints.email],
                    decoration: InputDecoration(
                      labelText: l.authEmailOptional,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    autofillHints: const [AutofillHints.newPassword],
                    decoration: InputDecoration(
                      labelText: l.authPassword,
                      helperText: l.authPasswordMinHelper,
                      border: const OutlineInputBorder(),
                    ),
                    validator: (v) {
                      if (v == null || v.length < 12) {
                        return l.authPasswordMinHelper;
                      }
                      return null;
                    },
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _confirm,
                    obscureText: true,
                    decoration: InputDecoration(
                      labelText: l.authConfirmPassword,
                      border: const OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        v == _password.text ? null : l.authPasswordsDoNotMatch,
                    onFieldSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: 16),
                  if (_error != null) ...[
                    Text(
                      _error!,
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.error),
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
