import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../widgets/recovery_codes_dialog.dart';

/// Account security: change password, manage 2FA, regenerate recovery
/// codes. Reachable from the dashboard's account menu (or directly via
/// route push). All operations require an authenticated session.
class SecurityScreen extends StatefulWidget {
  const SecurityScreen({super.key});

  @override
  State<SecurityScreen> createState() => _SecurityScreenState();
}

class _SecurityScreenState extends State<SecurityScreen> {
  final _api = ApiService();
  bool _loading = true;
  AuthUser? _user;
  int? _unusedRecoveryCodes;
  List<ActiveSession>? _sessions;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      // Refresh the singleton so totp_enabled is up to date right
      // after the user finishes enrollment.
      await AuthService.instance.refreshStatus();
      final user = AuthService.instance.current.user;
      final count = await _api.recoveryCodesCount();
      final sessions = await _api.listSessions();
      if (!mounted) return;
      setState(() {
        _user = user;
        _unusedRecoveryCodes = count;
        _sessions = sessions;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _changePassword() async {
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => const _ChangePasswordDialog(),
    );
    if (result == true && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password changed. Other sessions signed out.')),
      );
      // After change-password the server revokes all our sessions —
      // refreshStatus will drop us back to login.
      await AuthService.instance.refreshStatus();
    }
  }

  Future<void> _regenerateRecoveryCodes() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Regenerate recovery codes?'),
        content: const Text(
          'Your old codes will stop working immediately. Make sure you '
          'save the new ones before closing the dialog.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Generate new'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final codes = await _api.regenerateRecoveryCodes();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => RecoveryCodesDialog(codes: codes),
      );
      await _load();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: ${e.toString().replaceFirst('Exception: ', '')}')),
        );
      }
    }
  }

  Future<void> _enrollTotp() async {
    try {
      final challenge = await _api.beginTotpEnroll();
      if (!mounted) return;
      final ok = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _TotpEnrollDialog(
          secret: challenge.secretBase32,
          provisioningUri: challenge.provisioningUri,
        ),
      );
      if (ok == true && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Two-factor authentication enabled.')),
        );
        await _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: ${e.toString().replaceFirst('Exception: ', '')}')),
        );
      }
    }
  }

  Future<void> _disableTotp() async {
    final pw = await showDialog<String?>(
      context: context,
      builder: (_) => const _PromptPasswordDialog(
        title: 'Disable two-factor authentication?',
        message: 'Enter your password to confirm. Disabling TOTP makes '
            'your account less secure.',
      ),
    );
    if (pw == null || !mounted) return;
    try {
      await _api.disableTotp(pw);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Two-factor authentication disabled.')),
        );
        await _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: ${e.toString().replaceFirst('Exception: ', '')}')),
        );
      }
    }
  }

  Future<void> _revokeSession(ActiveSession session) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign out this session?'),
        content: Text(
          'This will sign out the device "${_describeSession(session)}" '
          'immediately. They will have to enter the password (and TOTP) '
          'to sign in again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _api.revokeSession(session.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Session signed out.')),
        );
        await _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: ${e.toString().replaceFirst('Exception: ', '')}')),
        );
      }
    }
  }

  Future<void> _revokeOtherSessions() async {
    final others = (_sessions ?? const <ActiveSession>[])
        .where((s) => !s.isCurrent)
        .length;
    if (others == 0) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign out everywhere else?'),
        content: Text(
          'This will end $others other session${others == 1 ? '' : 's'} '
          'immediately. This device will stay signed in.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Sign out others'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final n = await _api.revokeOtherSessions();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              n == 1
                  ? '1 other session signed out.'
                  : '$n other sessions signed out.',
            ),
          ),
        );
        await _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed: ${e.toString().replaceFirst('Exception: ', '')}')),
        );
      }
    }
  }

  /// One-line label for a session row. We don't ship a full
  /// user-agent parser — most users see strings like "Chrome on
  /// macOS / 73.42.0.1", which is good enough to recognize an
  /// unfamiliar device.
  String _describeSession(ActiveSession s) {
    final ua = (s.userAgent ?? '').trim();
    final browser = _browserName(ua);
    final os = _osName(ua);
    final parts = <String>[];
    if (browser.isNotEmpty) parts.add(browser);
    if (os.isNotEmpty) parts.add('on $os');
    if (parts.isEmpty) parts.add(ua.isEmpty ? 'Unknown device' : ua.substring(0, ua.length > 40 ? 40 : ua.length));
    if (s.ipAddress != null && s.ipAddress!.isNotEmpty) {
      parts.add('· ${s.ipAddress}');
    }
    return parts.join(' ');
  }

  String _browserName(String ua) {
    final lower = ua.toLowerCase();
    if (lower.contains('edg/')) return 'Edge';
    if (lower.contains('chrome/') && !lower.contains('chromium/')) return 'Chrome';
    if (lower.contains('firefox/')) return 'Firefox';
    if (lower.contains('safari/') && !lower.contains('chrome/')) return 'Safari';
    if (lower.contains('curl/')) return 'curl';
    if (lower.contains('playwright')) return 'Playwright';
    return '';
  }

  String _osName(String ua) {
    final lower = ua.toLowerCase();
    if (lower.contains('iphone') || lower.contains('ipad')) return 'iOS';
    if (lower.contains('android')) return 'Android';
    if (lower.contains('mac os') || lower.contains('macintosh')) return 'macOS';
    if (lower.contains('windows')) return 'Windows';
    if (lower.contains('linux')) return 'Linux';
    return '';
  }

  String _formatLastSeen(DateTime t) {
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return 'Active just now';
    if (diff.inMinutes < 60) return 'Active ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Active ${diff.inHours}h ago';
    if (diff.inDays < 30) return 'Active ${diff.inDays}d ago';
    return 'Active on ${DateFormat.yMMMd().format(t.toLocal())}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Security')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? Center(child: Text(_error!))
              : ListView(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 24, vertical: 16),
                  children: [
                    _section('Password'),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.lock_outline),
                        title: const Text('Change password'),
                        subtitle: const Text(
                          'Sign out of every other session.',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _changePassword,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _section('Two-factor authentication'),
                    Card(
                      child: ListTile(
                        leading: Icon(
                          (_user?.totpEnabled ?? false)
                              ? Icons.verified_user
                              : Icons.shield_outlined,
                          color: (_user?.totpEnabled ?? false)
                              ? Theme.of(context).colorScheme.primary
                              : null,
                        ),
                        title: Text(
                          (_user?.totpEnabled ?? false)
                              ? 'TOTP enabled'
                              : 'Add an authenticator app',
                        ),
                        subtitle: Text(
                          (_user?.totpEnabled ?? false)
                              ? 'You will be asked for a 6-digit code at each sign-in.'
                              : 'Scan a QR code with Authy / Google Authenticator / 1Password.',
                        ),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: (_user?.totpEnabled ?? false)
                            ? _disableTotp
                            : _enrollTotp,
                      ),
                    ),
                    const SizedBox(height: 16),
                    _section('Recovery codes'),
                    Card(
                      child: ListTile(
                        leading: const Icon(Icons.vpn_key_outlined),
                        title: Text(
                          '${_unusedRecoveryCodes ?? 0} unused codes',
                        ),
                        subtitle: const Text(
                          'Regenerate if you lose your saved codes — all '
                          'old codes stop working.',
                        ),
                        trailing: TextButton(
                          onPressed: _regenerateRecoveryCodes,
                          child: const Text('Regenerate'),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    _buildSessionsSection(),
                  ],
                ),
    );
  }

  Widget _buildSessionsSection() {
    final sessions = _sessions ?? const <ActiveSession>[];
    final otherCount = sessions.where((s) => !s.isCurrent).length;
    final scheme = Theme.of(context).colorScheme;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _section('Active sessions'),
            if (otherCount > 0)
              TextButton.icon(
                onPressed: _revokeOtherSessions,
                icon: const Icon(Icons.logout, size: 16),
                label: Text(
                  otherCount == 1
                      ? 'Sign out 1 other'
                      : 'Sign out $otherCount others',
                ),
              ),
          ],
        ),
        if (sessions.isEmpty)
          const Card(
            child: ListTile(
              leading: Icon(Icons.devices_other),
              title: Text('No active sessions'),
              subtitle: Text(
                'You should at least see this device. Refresh to retry.',
              ),
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (var i = 0; i < sessions.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  ListTile(
                    leading: Icon(
                      _iconForUserAgent(sessions[i].userAgent),
                      color: sessions[i].isCurrent ? scheme.primary : null,
                    ),
                    title: Row(
                      children: [
                        Expanded(
                          child: Text(
                            _describeSession(sessions[i]),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (sessions[i].isCurrent)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              'This device',
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onPrimaryContainer,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                      ],
                    ),
                    subtitle: Text(_formatLastSeen(sessions[i].lastSeenAt)),
                    trailing: sessions[i].isCurrent
                        ? null
                        : IconButton(
                            tooltip: 'Sign out this session',
                            icon: const Icon(Icons.close),
                            onPressed: () => _revokeSession(sessions[i]),
                          ),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  IconData _iconForUserAgent(String? ua) {
    final lower = (ua ?? '').toLowerCase();
    if (lower.contains('iphone') || lower.contains('android')) {
      return Icons.smartphone;
    }
    if (lower.contains('ipad')) return Icons.tablet;
    if (lower.contains('mac') || lower.contains('windows') || lower.contains('linux')) {
      return Icons.computer;
    }
    return Icons.devices_other;
  }

  Widget _section(String label) => Padding(
        padding: const EdgeInsets.only(top: 8, bottom: 8),
        child: Text(
          label.toUpperCase(),
          style: Theme.of(context).textTheme.labelSmall?.copyWith(
                letterSpacing: 1.2,
                color: Theme.of(context).colorScheme.outline,
              ),
        ),
      );
}

class _ChangePasswordDialog extends StatefulWidget {
  const _ChangePasswordDialog();

  @override
  State<_ChangePasswordDialog> createState() => _ChangePasswordDialogState();
}

class _ChangePasswordDialogState extends State<_ChangePasswordDialog> {
  final _formKey = GlobalKey<FormState>();
  final _current = TextEditingController();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _current.dispose();
    _next.dispose();
    _confirm.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ApiService().changePassword(_current.text, _next.text);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Change password'),
      content: SizedBox(
        width: 360,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _current,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Current password',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _next,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'New password (12+ characters)',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.length < 12) ? 'At least 12 characters' : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirm,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Confirm',
                  border: OutlineInputBorder(),
                ),
                validator: (v) =>
                    v == _next.text ? null : 'Passwords do not match',
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Change'),
        ),
      ],
    );
  }
}

class _TotpEnrollDialog extends StatefulWidget {
  final String secret;
  final String provisioningUri;
  const _TotpEnrollDialog({
    required this.secret,
    required this.provisioningUri,
  });

  @override
  State<_TotpEnrollDialog> createState() => _TotpEnrollDialogState();
}

class _TotpEnrollDialogState extends State<_TotpEnrollDialog> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  bool _showSecret = false;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _confirm() async {
    final raw = _code.text.trim();
    if (raw.length != 6) {
      setState(() => _error = 'Enter the 6-digit code from your app.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ApiService().confirmTotpEnroll(raw);
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: const Text('Set up two-factor authentication'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              '1. Open your authenticator app (Authy, Google Authenticator, '
              '1Password, etc.).\n'
              '2. Tap "Add account" and choose "Scan QR code" — or paste '
              'the secret below.\n'
              '3. Enter the 6-digit code your app shows.',
            ),
            const SizedBox(height: 16),
            // We render the otpauth:// URI as text + copy button rather
            // than as a QR. Adding a QR library is a bigger lift —
            // copy/paste works on every authenticator app.
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Setup link / secret'),
                      TextButton.icon(
                        onPressed: () =>
                            setState(() => _showSecret = !_showSecret),
                        icon: Icon(_showSecret
                            ? Icons.visibility_off
                            : Icons.visibility),
                        label: Text(_showSecret ? 'Hide' : 'Show'),
                      ),
                    ],
                  ),
                  if (_showSecret) ...[
                    SelectableText(
                      widget.secret,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 14,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 8),
                    TextButton.icon(
                      onPressed: () => Clipboard.setData(
                        ClipboardData(text: widget.provisioningUri),
                      ),
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copy otpauth:// URI'),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _code,
              keyboardType: TextInputType.number,
              inputFormatters: [
                FilteringTextInputFormatter.digitsOnly,
                LengthLimitingTextInputFormatter(6),
              ],
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 24,
                letterSpacing: 8,
                fontFamily: 'monospace',
              ),
              decoration: const InputDecoration(
                labelText: '6-digit code from your app',
                border: OutlineInputBorder(),
                hintText: '000000',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: scheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _confirm,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Enable'),
        ),
      ],
    );
  }
}

class _PromptPasswordDialog extends StatefulWidget {
  final String title;
  final String message;
  const _PromptPasswordDialog({required this.title, required this.message});

  @override
  State<_PromptPasswordDialog> createState() => _PromptPasswordDialogState();
}

class _PromptPasswordDialogState extends State<_PromptPasswordDialog> {
  final _pw = TextEditingController();
  @override
  void dispose() {
    _pw.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.message),
            const SizedBox(height: 12),
            TextField(
              controller: _pw,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Current password',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_pw.text),
          child: const Text('Confirm'),
        ),
      ],
    );
  }
}
