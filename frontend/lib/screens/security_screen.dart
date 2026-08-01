import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:qr/qr.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/passkeys.dart';
import '../utils/theme_colors.dart';
import '../widgets/recovery_codes_card.dart';
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
      final l = AppLocalizations.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.secPasswordChangedSnack)));
      // After change-password the server revokes all our sessions —
      // refreshStatus will drop us back to login.
      await AuthService.instance.refreshStatus();
    }
  }

  /// Set a NEW password without the old one, authorised by a fresh passkey
  /// assertion (step-up). Flow: run the assertion → on success show a
  /// new-password dialog (new + confirm only) → POST /set-password. The
  /// server revokes every session on success, so refreshStatus drops us to
  /// login — same end-state as _changePassword.
  Future<void> _setPasswordWithPasskey() async {
    final l = AppLocalizations.of(context);
    // 1. Step-up assertion. The OS passkey prompt appears here; cancelling
    //    or a failed assertion throws PasskeyException — show it and stop,
    //    WITHOUT opening the password dialog.
    final ({Map<String, dynamic> credential, String nonce}) stepUp;
    try {
      stepUp = await PasskeyService.instance.reauthWithPasskey();
    } on UnauthorizedException {
      // Session already gone — let the auth listener route to login.
      await AuthService.instance.refreshStatus();
      return;
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l.secFailedWithReason(e.toString().replaceFirst('Exception: ', '')),
          ),
        ),
      );
      return;
    }
    if (!mounted) return;

    // 2. Collect the new password (no current-password field). The dialog
    //    itself calls /set-password so it can show inline errors (e.g. a
    //    weak/breached password) without closing.
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => _SetPasswordWithPasskeyDialog(
        credential: stepUp.credential,
        nonce: stepUp.nonce,
      ),
    );
    if (result == true && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.secPasswordChangedSnack)));
      // Sessions were revoked server-side — drop back to login.
      await AuthService.instance.refreshStatus();
    }
  }

  Future<void> _regenerateRecoveryCodes() async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.secRegenerateCodesTitle),
        content: Text(l.secRegenerateCodesBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.secGenerateNew),
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
          SnackBar(
            content: Text(
              l.secFailedWithReason(
                e.toString().replaceFirst('Exception: ', ''),
              ),
            ),
          ),
        );
      }
    }
  }

  Future<void> _enrollTotp() async {
    final l = AppLocalizations.of(context);
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
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.secTwoFactorEnabledSnack)));
        await _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l.secFailedWithReason(
                e.toString().replaceFirst('Exception: ', ''),
              ),
            ),
          ),
        );
      }
    }
  }

  Future<void> _disableTotp() async {
    final l = AppLocalizations.of(context);
    final pw = await showDialog<String?>(
      context: context,
      builder: (_) => _PromptPasswordDialog(
        title: l.secDisableTwoFactorTitle,
        message: l.secDisableTwoFactorBody,
      ),
    );
    if (pw == null || !mounted) return;
    try {
      await _api.disableTotp(pw);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.secTwoFactorDisabledSnack)));
        await _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l.secFailedWithReason(
                e.toString().replaceFirst('Exception: ', ''),
              ),
            ),
          ),
        );
      }
    }
  }

  Future<void> _revokeSession(ActiveSession session) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.secSignOutSessionTitle),
        content: Text(l.secSignOutSessionBody(_describeSession(session))),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.secSignOut),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      await _api.revokeSession(session.id);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(l.secSessionSignedOutSnack)));
        await _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l.secFailedWithReason(
                e.toString().replaceFirst('Exception: ', ''),
              ),
            ),
          ),
        );
      }
    }
  }

  /// Sign out the device the user is currently on. Equivalent to the
  /// dashboard AppBar's Sign-out icon — surfaced inside the Security
  /// screen because that's where users go looking for it ("manage
  /// sessions" naturally implies "I can end the current one").
  Future<void> _signOutThisDevice() async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.secSignOutThisDeviceTitle),
        content: Text(l.secSignOutThisDeviceBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.secSignOut),
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
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.secSignOutEverywhereTitle),
        content: Text(l.secSignOutEverywhereBody(others)),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.secSignOutOthers),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    try {
      final n = await _api.revokeOtherSessions();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.secOtherSessionsSignedOutSnack(n))),
        );
        await _load();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              l.secFailedWithReason(
                e.toString().replaceFirst('Exception: ', ''),
              ),
            ),
          ),
        );
      }
    }
  }

  /// One-line label for a session row. We don't ship a full
  /// user-agent parser — most users see strings like "Chrome on
  /// macOS / 73.42.0.1", which is good enough to recognize an
  /// unfamiliar device.
  String _describeSession(ActiveSession s) {
    final l = AppLocalizations.of(context);
    final ua = (s.userAgent ?? '').trim();
    final browser = _browserName(ua);
    final os = _osName(ua);
    final parts = <String>[];
    if (browser.isNotEmpty) parts.add(browser);
    if (os.isNotEmpty) parts.add(l.secOnOs(os));
    if (parts.isEmpty) {
      parts.add(
        ua.isEmpty
            ? l.secUnknownDevice
            : ua.substring(0, ua.length > 40 ? 40 : ua.length),
      );
    }
    if (s.ipAddress != null && s.ipAddress!.isNotEmpty) {
      parts.add('· ${s.ipAddress}');
    }
    return parts.join(' ');
  }

  String _browserName(String ua) {
    final lower = ua.toLowerCase();
    if (lower.contains('edg/')) return 'Edge';
    if (lower.contains('chrome/') && !lower.contains('chromium/')) {
      return 'Chrome';
    }
    if (lower.contains('firefox/')) return 'Firefox';
    if (lower.contains('safari/') && !lower.contains('chrome/')) {
      return 'Safari';
    }
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
    final l = AppLocalizations.of(context);
    final now = DateTime.now();
    final diff = now.difference(t);
    if (diff.inMinutes < 1) return l.secActiveJustNow;
    if (diff.inMinutes < 60) return l.secActiveMinutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return l.secActiveHoursAgo(diff.inHours);
    if (diff.inDays < 30) return l.secActiveDaysAgo(diff.inDays);
    return l.secActiveOnDate(DateFormat.yMMMd().format(t.toLocal()));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Scaffold(
      appBar: AppBar(title: Text(l.secTitle)),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
          ? Center(child: Text(_error!))
          : ListView(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
              children: [
                _section(l.secAccountSection),
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.account_circle_outlined),
                    title: Text(
                      _user?.username ?? '—',
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      (_user?.email != null && _user!.email!.isNotEmpty)
                          ? _user!.email!
                          : l.secAccountNoEmail,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                _section(l.secPasswordSection),
                Card(
                  child: Column(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.lock_outline),
                        title: Text(l.secChangePassword),
                        subtitle: Text(l.secChangePasswordSubtitle),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _changePassword,
                      ),
                      // Passkey-gated set-password: only offered when the
                      // user actually holds a passkey to step up with. A
                      // user who knows their password but has no passkey
                      // simply uses "Change password" above.
                      if ((_passkeys ?? const []).isNotEmpty) ...[
                        const Divider(height: 1),
                        ListTile(
                          leading: const Icon(Icons.key_outlined),
                          title: Text(l.secSetPasswordWithPasskey),
                          subtitle: Text(l.secSetPasswordWithPasskeySubtitle),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _setPasswordWithPasskey,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 16),
                _section(l.secTwoFactorSection),
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
                          ? l.secTotpEnabled
                          : l.secAddAuthenticatorApp,
                    ),
                    subtitle: Text(
                      (_user?.totpEnabled ?? false)
                          ? l.secTotpEnabledSubtitle
                          : l.secAddAuthenticatorSubtitle,
                    ),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: (_user?.totpEnabled ?? false)
                        ? _disableTotp
                        : _enrollTotp,
                  ),
                ),
                const SizedBox(height: 16),
                _section(l.secRecoveryCodesSection),
                // The low/no-codes lockout warning is gated on 2FA
                // being enabled — see RecoveryCodesCard.
                RecoveryCodesCard(
                  totpEnabled: _user?.totpEnabled ?? false,
                  unusedCodes: _unusedRecoveryCodes,
                  onRegenerate: _regenerateRecoveryCodes,
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
    // Ask owner vs read-only BEFORE minting so the role is baked into
    // the token. A read-only redeemer can view everything but every
    // mutating request is 403'd by the backend's require_owner gate.
    final role = await showDialog<String>(
      context: context,
      builder: (_) => const _InviteRoleDialog(),
    );
    if (role == null || !mounted) return;
    final l = AppLocalizations.of(context);
    try {
      final invite = await _api.createInvite(role: role);
      if (!mounted) return;
      await Clipboard.setData(ClipboardData(text: invite.url));
      // Clipboard.setData is another async gap; re-check before using context.
      if (!mounted) return;
      final expires = DateFormat.yMMMd().add_jm().format(
        invite.expiresAt.toLocal(),
      );
      final isReadOnly = role == 'read_only';
      await showDialog<void>(
        context: context,
        builder: (ctx) {
          return AlertDialog(
            title: Text(
              isReadOnly
                  ? l.secReadOnlyInviteReadyTitle
                  : l.secInviteReadyTitle,
            ),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isReadOnly
                      ? l.secReadOnlyInviteReadyBody
                      : l.secInviteReadyBody,
                ),
                const SizedBox(height: 6),
                Text(
                  expires,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 12),
                SelectableText(
                  invite.url,
                  style: const TextStyle(fontSize: 12, fontFamily: 'monospace'),
                ),
                const SizedBox(height: 8),
                Text(
                  l.secCopiedToClipboard,
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
                child: Text(l.secCopyAgain),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text(l.secDone),
              ),
            ],
          );
        },
      );
      await _loadInvites();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            l.secFailedWithReason(e.toString().replaceFirst('Exception: ', '')),
          ),
        ),
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
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.secRevokeInviteTitle),
        content: Text(l.secRevokeInviteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(l.secRevoke),
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
        SnackBar(
          content: Text(
            l.secRevokeFailedWithReason(
              e.toString().replaceFirst('Exception: ', ''),
            ),
          ),
        ),
      );
    }
  }

  Widget _buildInvitesSection() {
    final l = AppLocalizations.of(context);
    final invites = _invites ?? const <InviteSummary>[];
    final now = DateTime.now();
    final live = invites
        .where((i) => !i.used && i.expiresAt.isAfter(now))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _section(l.secInviteUsersSection),
            TextButton.icon(
              onPressed: _mintInvite,
              icon: const Icon(Icons.add_link, size: 16),
              label: Text(l.secNewInviteLink),
            ),
          ],
        ),
        if (invites.isEmpty)
          Card(
            child: ListTile(
              leading: const Icon(Icons.mail_outline),
              title: Text(l.secNoInvites),
              subtitle: Text(l.secNoInvitesSubtitle),
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
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(
                            invites[i].used
                                ? l.secInviteRedeemed
                                : invites[i].expiresAt.isBefore(now)
                                ? l.secInviteExpired
                                : l.secInviteActive,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (invites[i].isReadOnly) ...[
                          const SizedBox(width: 8),
                          _roleChip(l.secReadOnlyChip),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      invites[i].used && invites[i].usedAt != null
                          ? l.secInviteUsedOn(
                              DateFormat.yMMMd().format(
                                invites[i].usedAt!.toLocal(),
                              ),
                            )
                          : l.secInviteExpiresOn(
                              DateFormat.yMMMd().add_jm().format(
                                invites[i].expiresAt.toLocal(),
                              ),
                            ),
                    ),
                    trailing:
                        invites[i].used || invites[i].expiresAt.isBefore(now)
                        ? null
                        : IconButton(
                            tooltip: l.secRevoke,
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
            l.secManyActiveInvitesHint(live.length),
            style: TextStyle(fontSize: 11, color: context.textSubtle),
          ),
        ],
      ],
    );
  }

  Widget _buildPasskeysSection() {
    final l = AppLocalizations.of(context);
    final passkeys = _passkeys ?? const <PasskeySummary>[];
    final supported = PasskeyService.instance.isAvailable;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            _section(l.secPasskeysSection),
            if (supported)
              MenuAnchor(
                alignmentOffset: const Offset(0, 6),
                style: MenuStyle(
                  alignment: AlignmentDirectional.bottomEnd,
                  elevation: const WidgetStatePropertyAll(3),
                  shape: WidgetStatePropertyAll(
                    RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  padding: const WidgetStatePropertyAll(
                    EdgeInsets.symmetric(vertical: 6),
                  ),
                ),
                builder: (context, controller, _) => TextButton.icon(
                  onPressed: () => controller.isOpen
                      ? controller.close()
                      : controller.open(),
                  icon: const Icon(Icons.add, size: 16),
                  label: Text(l.secAdd),
                ),
                menuChildren: [
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.fingerprint, size: 20),
                    onPressed: () => _registerPasskey(),
                    child: Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l.secThisDevice),
                          Text(
                            l.secThisDeviceSubtitle,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ),
                  MenuItemButton(
                    leadingIcon: const Icon(Icons.usb, size: 20),
                    onPressed: () => _registerPasskey(hardwareKeyOnly: true),
                    child: Padding(
                      padding: const EdgeInsets.only(right: 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(l.secSecurityKey),
                          Text(
                            l.secSecurityKeySubtitle,
                            style: const TextStyle(fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
          ],
        ),
        if (!supported)
          Card(
            child: ListTile(
              leading: const Icon(Icons.fingerprint),
              title: Text(l.secPasskeysUnavailable),
              subtitle: Text(l.secPasskeysUnavailableSubtitle),
            ),
          )
        else if (passkeys.isEmpty)
          Card(
            child: ListTile(
              leading: const Icon(Icons.fingerprint),
              title: Text(l.secNoPasskeys),
              subtitle: Text(l.secNoPasskeysSubtitle),
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

  Future<void> _registerPasskey({bool hardwareKeyOnly = false}) async {
    final nickname = await showDialog<String?>(
      context: context,
      builder: (ctx) => const _NicknamePromptDialog(),
    );
    // null = the user cancelled. An empty string means they hit Save
    // without typing anything — still intentional intent to register,
    // the row just shows up unlabelled.
    if (nickname == null) return;

    if (!mounted) return;
    final l = AppLocalizations.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          hardwareKeyOnly
              ? l.secInsertSecurityKeyPrompt
              : l.secConfirmBiometricPrompt,
        ),
        duration: const Duration(seconds: 3),
      ),
    );
    try {
      await PasskeyService.instance.registerNewPasskey(
        nickname: nickname,
        hardwareKeyOnly: hardwareKeyOnly,
      );
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.secPasskeyAddedSnack)));
    } on PasskeyException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.message)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Future<void> _removePasskey(PasskeySummary pk) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.secRemovePasskeyTitle),
        content: Text(
          l.secRemovePasskeyBody(pk.nickname ?? l.secThisDeviceFallback),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.actionCancel),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(l.secRemove),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await PasskeyService.instance.remove(pk.id);
      await _load();
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.secPasskeyRemovedSnack)));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(e.toString())));
    }
  }

  Widget _buildSessionsSection() {
    final l = AppLocalizations.of(context);
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
            _section(l.secActiveSessionsSection),
            if (otherCount > 0)
              TextButton.icon(
                onPressed: _revokeOtherSessions,
                icon: const Icon(Icons.logout, size: 16),
                label: Text(l.secSignOutNOthers(otherCount)),
              ),
          ],
        ),
        if (sessions.isEmpty)
          Card(
            child: ListTile(
              leading: const Icon(Icons.devices_other),
              title: Text(l.secNoActiveSessions),
              subtitle: Text(l.secNoActiveSessionsSubtitle),
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
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: scheme.primaryContainer,
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              l.secThisDeviceBadge,
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onPrimaryContainer,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          )
                        else if (sessions[i].newSinceLastVisit)
                          // Amber pill for any session created since
                          // the user's previous-login anchor. Lets the
                          // user spot "I don't remember logging in
                          // from there" without diving into the audit
                          // log.
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: context.warning.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: context.warning.withValues(alpha: 0.6),
                                width: 1,
                              ),
                            ),
                            child: Text(
                              l.secNewSinceLastVisit,
                              style: TextStyle(
                                fontSize: 11,
                                color: context.warning,
                                fontWeight: FontWeight.w600,
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
                            label: Text(l.secSignOut),
                          )
                        : IconButton(
                            tooltip: l.secSignOutSessionTooltip,
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
    if (lower.contains('mac') ||
        lower.contains('windows') ||
        lower.contains('linux')) {
      return Icons.computer;
    }
    return Icons.devices_other;
  }

  /// Small outlined pill used to flag a read-only invite in the list.
  Widget _roleChip(String label) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.secondaryContainer,
      borderRadius: BorderRadius.circular(12),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.onSecondaryContainer,
      ),
    ),
  );

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
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.secChangePasswordTitle),
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
                decoration: InputDecoration(
                  labelText: l.secCurrentPasswordLabel,
                  border: const OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.isEmpty) ? l.commonRequired : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _next,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l.secNewPasswordLabel,
                  border: const OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.length < 12) ? l.secPasswordTooShort : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirm,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l.secConfirmPasswordLabel,
                  border: const OutlineInputBorder(),
                ),
                validator: (v) =>
                    v == _next.text ? null : l.secPasswordsDoNotMatch,
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
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l.secChangeButton),
        ),
      ],
    );
  }
}

/// New-password dialog for the passkey-gated set-password flow. Reuses the
/// same validation as _ChangePasswordDialog (new ≥ 12 chars, confirm must
/// match) but has NO current-password field — the step-up assertion already
/// authorised the change. The assertion + nonce are passed in and submitted
/// together with the new password.
class _SetPasswordWithPasskeyDialog extends StatefulWidget {
  final Map<String, dynamic> credential;
  final String nonce;
  const _SetPasswordWithPasskeyDialog({
    required this.credential,
    required this.nonce,
  });

  @override
  State<_SetPasswordWithPasskeyDialog> createState() =>
      _SetPasswordWithPasskeyDialogState();
}

class _SetPasswordWithPasskeyDialogState
    extends State<_SetPasswordWithPasskeyDialog> {
  final _formKey = GlobalKey<FormState>();
  final _next = TextEditingController();
  final _confirm = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
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
      await PasskeyService.instance.setPasswordWithPasskey(
        credential: widget.credential,
        nonce: widget.nonce,
        newPassword: _next.text,
      );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.secSetPasswordWithPasskeyTitle),
      content: SizedBox(
        width: 360,
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l.secSetPasswordWithPasskeyBody,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _next,
                obscureText: true,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: l.secNewPasswordLabel,
                  border: const OutlineInputBorder(),
                ),
                validator: (v) =>
                    (v == null || v.length < 12) ? l.secPasswordTooShort : null,
              ),
              const SizedBox(height: 12),
              TextFormField(
                controller: _confirm,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l.secConfirmPasswordLabel,
                  border: const OutlineInputBorder(),
                ),
                validator: (v) =>
                    v == _next.text ? null : l.secPasswordsDoNotMatch,
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
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l.secSetPasswordButton),
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
      setState(
        () => _error = AppLocalizations.of(context).secEnterSixDigitCode,
      );
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
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(l.secEnrollTitle),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.secEnrollSteps),
            const SizedBox(height: 16),
            // Real scannable QR of the otpauth:// URI, on a white card so it
            // reads in either theme. The copyable secret below remains as a
            // manual-entry fallback for apps that can't scan.
            Center(
              child: Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: SizedBox(
                  width: 180,
                  height: 180,
                  child: CustomPaint(
                    painter: _TotpQrPainter(widget.provisioningUri),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
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
                      Text(l.secSetupLinkSecret),
                      TextButton.icon(
                        onPressed: () =>
                            setState(() => _showSecret = !_showSecret),
                        icon: Icon(
                          _showSecret ? Icons.visibility_off : Icons.visibility,
                        ),
                        label: Text(_showSecret ? l.secHide : l.secShow),
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
                      label: Text(l.secCopyOtpauthUri),
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
              decoration: InputDecoration(
                labelText: l.secSixDigitCodeLabel,
                border: const OutlineInputBorder(),
                hintText: '000000',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: scheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: _busy ? null : _confirm,
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l.secEnable),
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
    final l = AppLocalizations.of(context);
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
              decoration: InputDecoration(
                labelText: l.secCurrentPasswordLabel,
                border: const OutlineInputBorder(),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_pw.text),
          child: Text(l.secConfirm),
        ),
      ],
    );
  }
}

class _PasskeyRow extends StatelessWidget {
  final PasskeySummary passkey;
  final VoidCallback onRemove;
  const _PasskeyRow({required this.passkey, required this.onRemove});

  String _registered(AppLocalizations l, DateTime t) {
    return l.secPasskeyRegisteredOn(DateFormat.yMMMd().format(t.toLocal()));
  }

  String? _lastUsed(AppLocalizations l, DateTime? t) {
    if (t == null) return null;
    final diff = DateTime.now().difference(t.toLocal());
    if (diff.inMinutes < 1) return l.secLastUsedJustNow;
    if (diff.inMinutes < 60) return l.secLastUsedMinutesAgo(diff.inMinutes);
    if (diff.inHours < 24) return l.secLastUsedHoursAgo(diff.inHours);
    if (diff.inDays < 30) return l.secLastUsedDaysAgo(diff.inDays);
    return l.secLastUsedOn(DateFormat.yMMMd().format(t.toLocal()));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final title = passkey.nickname?.trim().isNotEmpty == true
        ? passkey.nickname!.trim()
        : (passkey.isHardwareKey
              ? l.secHardwareKeyTitle
              : l.secDevicePasskeyTitle);
    // Icon mirrors the authenticator class so the user can tell a phone
    // biometric ("This iPhone") apart from a roaming key ("YubiKey on
    // keychain") at a glance.
    final icon = passkey.isHardwareKey ? Icons.key : Icons.fingerprint;
    // "Platform passkey" rather than "Platform biometric" — a platform
    // credential isn't necessarily a biometric (it may be a device PIN), and
    // overclaiming "biometric" read as wrong for keys the browser mislabeled.
    final kind = passkey.isHardwareKey
        ? l.secHardwareKeyKind
        : l.secPlatformPasskeyKind;
    final lastUsed = _lastUsed(l, passkey.lastUsedAt);
    final subtitleParts = <String>[
      kind,
      _registered(l, passkey.createdAt),
      if (lastUsed != null) lastUsed,
    ];
    return ListTile(
      leading: Icon(icon),
      title: Text(title),
      subtitle: Text(subtitleParts.join(' · ')),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: l.secRemovePasskeyTooltip,
        onPressed: onRemove,
      ),
    );
  }
}

/// Lets the inviter pick whether a new invite grants full (owner)
/// access or read-only access before the token is minted. Pops the
/// chosen role string ('owner' | 'read_only'), or null on cancel.
class _InviteRoleDialog extends StatefulWidget {
  const _InviteRoleDialog();

  @override
  State<_InviteRoleDialog> createState() => _InviteRoleDialogState();
}

class _InviteRoleDialogState extends State<_InviteRoleDialog> {
  String _role = 'owner';

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.secNewInviteLink),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.secInviteAccessQuestion),
          const SizedBox(height: 8),
          RadioListTile<String>(
            value: 'owner',
            groupValue: _role,
            onChanged: (v) => setState(() => _role = v!),
            contentPadding: EdgeInsets.zero,
            title: Text(l.secFullAccess),
            subtitle: Text(l.secFullAccessSubtitle),
          ),
          RadioListTile<String>(
            value: 'read_only',
            groupValue: _role,
            onChanged: (v) => setState(() => _role = v!),
            contentPadding: EdgeInsets.zero,
            title: Text(l.secReadOnlyAccess),
            subtitle: Text(l.secReadOnlyAccessSubtitle),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_role),
          child: Text(l.secCreateLink),
        ),
      ],
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
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.secNamePasskeyTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l.secNamePasskeyBody),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            autofocus: true,
            decoration: InputDecoration(
              labelText: l.secDeviceNameLabel,
              hintText: l.secDeviceNameHint,
              border: const OutlineInputBorder(),
            ),
            maxLength: 64,
            onSubmitted: (v) => Navigator.pop(context, _controller.text.trim()),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, _controller.text.trim()),
          child: Text(l.secContinue),
        ),
      ],
    );
  }
}

/// Renders a TOTP `otpauth://` URI as a scannable QR. Black modules on a
/// transparent ground — the caller paints the white quiet-zone card so the
/// code scans in either theme. Uses the pure-Dart `qr` package (no runtime
/// fetch, consistent with the bundled-fonts policy).
class _TotpQrPainter extends CustomPainter {
  _TotpQrPainter(this.data)
    : _image = QrImage(
        QrCode.fromData(data: data, errorCorrectLevel: QrErrorCorrectLevel.M),
      );

  final String data;
  final QrImage _image;

  @override
  void paint(Canvas canvas, Size size) {
    final count = _image.moduleCount;
    if (count == 0) return;
    final cell = size.width / count;
    final paint = Paint()
      ..color = Colors.black
      ..isAntiAlias = false
      ..style = PaintingStyle.fill;
    for (var row = 0; row < count; row++) {
      for (var col = 0; col < count; col++) {
        if (_image.isDark(row, col)) {
          // +0.6 overdraw closes hairline seams between adjacent cells.
          canvas.drawRect(
            Rect.fromLTWH(col * cell, row * cell, cell + 0.6, cell + 0.6),
            paint,
          );
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant _TotpQrPainter oldDelegate) =>
      oldDelegate.data != data;
}
