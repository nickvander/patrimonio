import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/passkeys.dart';
import '../utils/theme_colors.dart';
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
  List<PasskeySummary>? _passkeys;
  List<InviteSummary>? _invites;
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
      // Passkeys are best-effort — older backends that haven't shipped
      // the feature yet would 404 here. Surface the failure quietly
      // (empty list) rather than block the whole screen on it.
      List<PasskeySummary>? passkeys;
      try {
        passkeys = await PasskeyService.instance.list();
      } catch (_) {
        passkeys = const [];
      }
      // Invites list is best-effort too (404 on older backends; empty
      // list otherwise). Loaded in parallel with the rest so the screen
      // doesn't block on it.
      List<InviteSummary>? invites;
      try {
        invites = await _api.listInvites();
      } catch (_) {
        invites = const [];
      }
      if (!mounted) return;
      setState(() {
        _user = user;
        _unusedRecoveryCodes = count;
        _sessions = sessions;
        _passkeys = passkeys;
        _invites = invites;
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

  /// Sign out the device the user is currently on. Equivalent to the
  /// dashboard AppBar's Sign-out icon — surfaced inside the Security
  /// screen because that's where users go looking for it ("manage
  /// sessions" naturally implies "I can end the current one").
  Future<void> _signOutThisDevice() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Sign out of this device?'),
        content: const Text(
          'You will need to enter your password again (and TOTP, if '
          'enabled) to sign back in.',
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
    await AuthService.instance.logout();
    // AuthService emits signedOut → the AuthGate listener in main.dart
    // unmounts the dashboard tree and brings up the login screen; no
    // explicit Navigator pop is needed here.
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
                    if ((_unusedRecoveryCodes ?? 99) < 3)
                      Card(
                        color: context.warning.withValues(alpha: 0.12),
                        shape: RoundedRectangleBorder(
                          side: BorderSide(
                            color: context.warning.withValues(alpha: 0.6),
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: ListTile(
                          leading: Icon(
                            Icons.warning_amber_rounded,
                            color: context.warning,
                          ),
                          title: Text(
                            (_unusedRecoveryCodes ?? 0) == 0
                                ? 'No recovery codes left'
                                : 'Only ${_unusedRecoveryCodes ?? 0} recovery '
                                  'code${(_unusedRecoveryCodes ?? 0) == 1 ? '' : 's'} left',
                            style: TextStyle(
                              color: context.warning,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          subtitle: const Text(
                            'If you lose your authenticator and run out of '
                            'codes you can be locked out. Regenerate now to '
                            'restore a full set of 10.',
                          ),
                          trailing: FilledButton(
                            onPressed: _regenerateRecoveryCodes,
                            child: const Text('Regenerate'),
                          ),
                        ),
                      )
                    else
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
                    _buildPasskeysSection(),
                    const SizedBox(height: 16),
                    _buildInvitesSection(),
                    const SizedBox(height: 16),
                    _buildSessionsSection(),
                  ],
                ),
    );
  }

  /// Mint a one-time invite link + copy the share URL to the
  /// clipboard. The plaintext token is never recoverable after the
  /// mint response, so we show it in a dialog the user can re-copy
  /// before dismissing.
  Future<void> _mintInvite() async {
    try {
      final invite = await _api.createInvite();
      if (!mounted) return;
      await Clipboard.setData(ClipboardData(text: invite.url));
      final expires = DateFormat.yMMMd().add_jm().format(invite.expiresAt.toLocal());
      await showDialog<void>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: const Text('Invite link ready'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Share this URL with the new user. It works for one '
                  'account creation and expires on:',
                ),
                const SizedBox(height: 6),
                Text(expires,
                    style: const TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 12),
                SelectableText(
                  invite.url,
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'Copied to clipboard.',
                  style: TextStyle(
                    fontSize: 11,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: invite.url));
                },
                child: const Text('Copy again'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('Done'),
              ),
            ],
          );
        },
      );
      await _loadInvites();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed: ${e.toString().replaceFirst('Exception: ', '')}')),
      );
    }
  }

  Future<void> _loadInvites() async {
    try {
      final list = await _api.listInvites();
      if (mounted) setState(() => _invites = list);
    } catch (_) {
      // Non-fatal; the rest of the security screen still renders.
    }
  }

  Future<void> _revokeInvite(InviteSummary inv) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Revoke invite?'),
        content: const Text(
          'The link will stop working immediately. You can mint a new '
          'one if you change your mind.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Revoke'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _api.revokeInvite(inv.id);
      await _loadInvites();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Revoke failed: ${e.toString().replaceFirst('Exception: ', '')}')),
      );
    }
  }

  Widget _buildInvitesSection() {
    final invites = _invites ?? const <InviteSummary>[];
    final now = DateTime.now();
    final live = invites.where((i) => !i.used && i.expiresAt.isAfter(now)).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _section('Invite users'),
            TextButton.icon(
              onPressed: _mintInvite,
              icon: const Icon(Icons.add_link, size: 16),
              label: const Text('New invite link'),
            ),
          ],
        ),
        if (invites.isEmpty)
          const Card(
            child: ListTile(
              leading: Icon(Icons.mail_outline),
              title: Text('No invites'),
              subtitle: Text(
                'Generate a one-time link to let another person sign up '
                'for their own Patrimonio account.',
              ),
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (var i = 0; i < invites.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  ListTile(
                    leading: Icon(
                      invites[i].used
                          ? Icons.check_circle_outline
                          : invites[i].expiresAt.isBefore(now)
                              ? Icons.history_toggle_off
                              : Icons.link,
                    ),
                    title: Text(
                      invites[i].used
                          ? 'Redeemed'
                          : invites[i].expiresAt.isBefore(now)
                              ? 'Expired'
                              : 'Active',
                    ),
                    subtitle: Text(
                      invites[i].used && invites[i].usedAt != null
                          ? 'Used ${DateFormat.yMMMd().format(invites[i].usedAt!.toLocal())}'
                          : 'Expires ${DateFormat.yMMMd().add_jm().format(invites[i].expiresAt.toLocal())}',
                    ),
                    trailing: invites[i].used || invites[i].expiresAt.isBefore(now)
                        ? null
                        : IconButton(
                            tooltip: 'Revoke',
                            icon: const Icon(Icons.close),
                            onPressed: () => _revokeInvite(invites[i]),
                          ),
                  ),
                ],
              ],
            ),
          ),
        if (live.length >= 3) ...[
          const SizedBox(height: 4),
          Text(
            'You have ${live.length} active invites — consider revoking unused links.',
            style: TextStyle(fontSize: 11, color: context.textSubtle),
          ),
        ],
      ],
    );
  }

  Widget _buildPasskeysSection() {
    final passkeys = _passkeys ?? const <PasskeySummary>[];
    final supported = PasskeyService.instance.isAvailable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _section('Passkeys'),
            if (supported)
              TextButton.icon(
                onPressed: _registerPasskey,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add device'),
              ),
          ],
        ),
        if (!supported)
          const Card(
            child: ListTile(
              leading: Icon(Icons.fingerprint),
              title: Text('Passkeys not available'),
              subtitle: Text(
                'This browser does not expose the WebAuthn API. Try Chrome, '
                'Safari, or Edge on a recent OS to register a passkey.',
              ),
            ),
          )
        else if (passkeys.isEmpty)
          const Card(
            child: ListTile(
              leading: Icon(Icons.fingerprint),
              title: Text('No passkeys registered'),
              subtitle: Text(
                'Add this device, your phone, or a hardware security key '
                '(YubiKey, Titan, etc.) so you can sign in with biometrics '
                'or a tap instead of a password.',
              ),
            ),
          )
        else
          Card(
            child: Column(
              children: [
                for (var i = 0; i < passkeys.length; i++) ...[
                  if (i > 0) const Divider(height: 1),
                  _PasskeyRow(
                    passkey: passkeys[i],
                    onRemove: () => _removePasskey(passkeys[i]),
                  ),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Future<void> _registerPasskey() async {
    final nickname = await showDialog<String?>(
      context: context,
      builder: (ctx) => const _NicknamePromptDialog(),
    );
    // null = the user cancelled. An empty string means they hit Save
    // without typing anything — still intentional intent to register,
    // the row just shows up unlabelled.
    if (nickname == null) return;

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Confirm with your device biometric…'),
        duration: Duration(seconds: 2),
      ),
    );
    try {
      await PasskeyService.instance.registerNewPasskey(nickname: nickname);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Passkey added.')),
      );
    } on PasskeyException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _removePasskey(PasskeySummary pk) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove this passkey?'),
        content: Text(
          'You will no longer be able to sign in with '
          '"${pk.nickname ?? 'this device'}". This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await PasskeyService.instance.remove(pk.id);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Passkey removed.')),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.toString())));
    }
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
                    // For the current device the per-session "revoke
                    // this session" pathway would race against the
                    // cookie still being on this device. Send a real
                    // logout instead, which clears server-side cookie
                    // + Redis session + local AuthService state.
                    trailing: sessions[i].isCurrent
                        ? TextButton.icon(
                            onPressed: _signOutThisDevice,
                            icon: const Icon(Icons.logout, size: 16),
                            label: const Text('Sign out'),
                          )
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

class _PasskeyRow extends StatelessWidget {
  final PasskeySummary passkey;
  final VoidCallback onRemove;
  const _PasskeyRow({required this.passkey, required this.onRemove});

  String _registered(DateTime t) {
    return 'Registered ${DateFormat.yMMMd().format(t.toLocal())}';
  }

  String? _lastUsed(DateTime? t) {
    if (t == null) return null;
    final diff = DateTime.now().difference(t.toLocal());
    if (diff.inMinutes < 1) return 'Last used just now';
    if (diff.inMinutes < 60) return 'Last used ${diff.inMinutes}m ago';
    if (diff.inHours < 24) return 'Last used ${diff.inHours}h ago';
    if (diff.inDays < 30) return 'Last used ${diff.inDays}d ago';
    return 'Last used ${DateFormat.yMMMd().format(t.toLocal())}';
  }

  @override
  Widget build(BuildContext context) {
    final title = passkey.nickname?.trim().isNotEmpty == true
        ? passkey.nickname!.trim()
        : (passkey.isHardwareKey ? 'Hardware security key' : 'Device passkey');
    // Icon mirrors the authenticator class so the user can tell a phone
    // biometric ("This iPhone") apart from a roaming key ("YubiKey on
    // keychain") at a glance.
    final icon = passkey.isHardwareKey ? Icons.key : Icons.fingerprint;
    final kind = passkey.isHardwareKey ? 'Hardware key' : 'Platform biometric';
    final subtitleParts = <String>[
      kind,
      _registered(passkey.createdAt),
      if (_lastUsed(passkey.lastUsedAt) != null) _lastUsed(passkey.lastUsedAt)!,
    ];
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitleParts.join(' · ')),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Remove passkey',
        onPressed: onRemove,
      ),
    );
  }
}

class _NicknamePromptDialog extends StatefulWidget {
  const _NicknamePromptDialog();

  @override
  State<_NicknamePromptDialog> createState() => _NicknamePromptDialogState();
}

class _NicknamePromptDialogState extends State<_NicknamePromptDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Name this passkey'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text(
            'Optional label so you can tell this passkey apart later. '
            'Examples: "iPhone 15", "Work MacBook", "YubiKey on keychain".',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: 'Device name',
              hintText: 'e.g. iPhone 15',
              border: OutlineInputBorder(),
            ),
            maxLength: 64,
            onSubmitted: (v) =>
                Navigator.pop(context, _controller.text.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: const Text('Continue'),
        ),
      ],
    );
  }
}
