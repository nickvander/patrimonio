import 'package:flutter/material.dart';
import '../services/auth_service.dart';
import '../services/api_service.dart';

/// "Forgot password?" flow. The user supplies their username, an
/// unused recovery code, and a new password. On success they are
/// dropped back to the login screen — NOT signed in — so the new
/// password is exercised at least once.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _formKey = GlobalKey<FormState>();
  final _username = TextEditingController();
  final _code = TextEditingController();
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  bool _submitting = false;
  String? _error;
  bool _done = false;

  @override
  void dispose() {
    _username.dispose();
    _code.dispose();
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
      await ApiService().recover(
        username: _username.text.trim(),
        code: _code.text.trim(),
        newPassword: _password.text,
      );
      // recover() doesn't sign the user in. Tell AuthGate to refresh
      // so it shows the login screen with the new password.
      await AuthService.instance.refreshStatus();
      if (mounted) {
        setState(() => _done = true);
      }
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Reset password')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: _done ? _doneView() : _formView(),
          ),
        ),
      ),
    );
  }

  Widget _doneView() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.check_circle, color: Theme.of(context).colorScheme.primary, size: 48),
        const SizedBox(height: 16),
        Text(
          'Password reset',
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const SizedBox(height: 8),
        const Text(
          'Sign in with your new password. The code you used has been consumed.',
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 24),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Back to sign in'),
        ),
      ],
    );
  }

  Widget _formView() {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Use a recovery code',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            'Enter one of the recovery codes you saved at setup. Each code '
            'is single-use — once redeemed it cannot be reused.',
          ),
          const SizedBox(height: 24),
          TextFormField(
            controller: _username,
            decoration: const InputDecoration(
              labelText: 'Username',
              border: OutlineInputBorder(),
            ),
            validator: (v) =>
                (v == null || v.trim().isEmpty) ? 'Required' : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _code,
            decoration: const InputDecoration(
              labelText: 'Recovery code (e.g. XK4T-9PMQ-7HZL)',
              border: OutlineInputBorder(),
              hintText: 'Hyphens and case are optional',
            ),
            style: const TextStyle(fontFamily: 'monospace', letterSpacing: 1.2),
            validator: (v) {
              final stripped = (v ?? '')
                  .replaceAll(RegExp(r'\s|-'), '')
                  .toUpperCase();
              if (stripped.length != 12) {
                return 'Codes are 12 letters/digits (hyphens optional)';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _password,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'New password (12+ characters)',
              border: OutlineInputBorder(),
            ),
            validator: (v) =>
                (v == null || v.length < 12) ? 'At least 12 characters' : null,
          ),
          const SizedBox(height: 16),
          TextFormField(
            controller: _confirm,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: 'Confirm new password',
              border: OutlineInputBorder(),
            ),
            validator: (v) =>
                v == _password.text ? null : 'Passwords do not match',
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
                : const Text('Reset password'),
          ),
        ],
      ),
    );
  }
}
