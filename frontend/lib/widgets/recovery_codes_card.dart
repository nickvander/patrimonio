import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../utils/theme_colors.dart';

/// The recovery-codes card on the Security screen.
///
/// Shows the amber "you could get locked out" warning ONLY when the user
/// actually has 2FA enabled and is running low on unused codes (< 3). The
/// warning copy is authenticator-centric ("if you lose your authenticator…"),
/// so surfacing it to a user who never enrolled in 2FA — whose code count is
/// low simply because they used codes for password recovery, or regenerated
/// none since — read as a false lockout alarm. Those users get the neutral
/// informational tile instead, which still offers Regenerate.
class RecoveryCodesCard extends StatelessWidget {
  /// Whether the user has TOTP 2FA enabled.
  final bool totpEnabled;

  /// Unused recovery codes remaining; null while still loading.
  final int? unusedCodes;

  /// Invoked by the Regenerate button.
  final VoidCallback onRegenerate;

  const RecoveryCodesCard({
    super.key,
    required this.totpEnabled,
    required this.unusedCodes,
    required this.onRegenerate,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Gate the lockout warning on 2FA being enabled — a user without an
    // authenticator can't be locked out of it. `?? 99` keeps the neutral
    // tile while the count is still loading.
    final showWarning = totpEnabled && (unusedCodes ?? 99) < 3;
    if (showWarning) {
      return Card(
        color: context.warning.withValues(alpha: 0.12),
        shape: RoundedRectangleBorder(
          side: BorderSide(color: context.warning.withValues(alpha: 0.6)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: ListTile(
          leading: Icon(Icons.warning_amber_rounded, color: context.warning),
          title: Text(
            (unusedCodes ?? 0) == 0
                ? l.secNoCodesLeft
                : l.secFewCodesLeft(unusedCodes ?? 0),
            style: TextStyle(
              color: context.warning,
              fontWeight: FontWeight.w600,
            ),
          ),
          subtitle: Text(l.secLowCodesWarningBody),
          trailing: FilledButton(
            onPressed: onRegenerate,
            child: Text(l.secRegenerate),
          ),
        ),
      );
    }
    return Card(
      child: ListTile(
        leading: const Icon(Icons.vpn_key_outlined),
        title: Text(l.secUnusedCodes(unusedCodes ?? 0)),
        subtitle: Text(l.secUnusedCodesSubtitle),
        trailing: TextButton(
          onPressed: onRegenerate,
          child: Text(l.secRegenerate),
        ),
      ),
    );
  }
}
