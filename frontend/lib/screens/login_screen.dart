import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../services/auth_service.dart';
import '../services/passkeys.dart';
import 'forgot_password_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _password = TextEditingController();
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await AuthService.instance.login(
        _username.text.trim(),
        _password.text,
      );
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  Future<void> _signInWithPasskey() async {
    final username = _username.text.trim();
    if (username.isEmpty) {
      setState(() =>
          _error = AppLocalizations.of(context).authEnterUsernameFirst);
      return;
    }
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      final user =
          await PasskeyService.instance.signInWithPasskey(username: username);
      // The cookie has been set; tell AuthService the user is in.
      // refreshStatus() re-validates against the server and emits the
      // signed-in state for the AuthGate to pick up.
      await AuthService.instance.refreshStatus();
      // Belt-and-braces: if refreshStatus didn't flip to signedIn
      // (e.g. some flake), still surface a meaningful error rather
      // than silently sitting on the login screen.
      if (AuthService.instance.current.phase != AuthPhase.signedIn) {
        setState(() => _error =
            'Signed in as ${user.username} but session refresh failed.');
      }
    } on PasskeyException catch (e) {
      setState(() => _error = e.message);
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
                    l.authSignInToContinue,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _username,
                    autofillHints: const [AutofillHints.username],
                    decoration: InputDecoration(
                      labelText: l.authUsername,
                      border: const OutlineInputBorder(),
                    ),
                    validator: (v) => (v == null || v.trim().isEmpty)
                        ? l.commonRequired
                        : null,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _password,
                    obscureText: true,
                    autofillHints: const [AutofillHints.password],
                    decoration: InputDecoration(
                      labelText: l.authPassword,
                      border: const OutlineInputBorder(),
                    ),
                    validator: (v) =>
                        (v == null || v.isEmpty) ? l.commonRequired : null,
                    onFieldSubmitted: (_) => _submit(),
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
                        : Text(l.authSignIn),
                  ),
                  if (PasskeyService.instance.isAvailable) ...[
                    const SizedBox(height: 8),
                    // Passkey sign-in still needs the username field
                    // because we use the username-first flow (the
                    // server seeds the assertion challenge with that
                    // user's registered credentials). The button is
                    // disabled until something is typed so the user
                    // doesn't get an immediate "Username required"
                    // bounce.
                    OutlinedButton.icon(
                      onPressed: _submitting ? null : _signInWithPasskey,
                      icon: const Icon(Icons.fingerprint, size: 18),
                      label: Text(l.authSignInWithPasskey),
                    ),
                  ],
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _submitting
                        ? null
                        : () => Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const ForgotPasswordScreen(),
                              ),
                            ),
                    child: Text(l.authForgotPassword),
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
