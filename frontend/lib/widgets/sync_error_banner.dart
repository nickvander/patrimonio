import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/buttons.dart';
import '../utils/theme_colors.dart';

/// Sticky banner shown above the dashboard body whenever one or more
/// institutions are in `error` or `reconnect_required` state. Toast
/// snackbars disappear too quickly for these conditions — a sticky
/// pill keeps the issue in front of the user until they act on it.
class SyncErrorBanner extends StatelessWidget {
  final List<dynamic> syncData;
  final VoidCallback? onJumpToManagement;
  final Future<void> Function(String institutionId)? onReconnect;

  /// Snooze: institution ids the user dismissed, and until when. While the
  /// snooze is active the banner stays hidden UNLESS a not-yet-dismissed
  /// institution fails — a genuinely new problem still surfaces.
  final Set<String> dismissedIds;
  final DateTime? dismissedUntil;

  /// Called with the current problem institution ids when the user taps ×.
  final void Function(Set<String> problemIds)? onDismiss;

  const SyncErrorBanner({
    super.key,
    required this.syncData,
    this.onJumpToManagement,
    this.onReconnect,
    this.dismissedIds = const {},
    this.dismissedUntil,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final problems = syncData.where((raw) {
      if (raw is! Map) return false;
      final status = raw['sync_status']?.toString();
      return status == 'error' || status == 'reconnect_required';
    }).toList();

    if (problems.isEmpty) return const SizedBox.shrink();

    final problemIds = problems
        .map((p) => (p['id'] ?? '').toString())
        .where((s) => s.isNotEmpty)
        .toSet();
    // Hidden only while the snooze window is active AND every currently-
    // failing institution was among those dismissed.
    final snoozed =
        dismissedUntil != null &&
        DateTime.now().isBefore(dismissedUntil!) &&
        problemIds.isNotEmpty &&
        problemIds.every(dismissedIds.contains);
    if (snoozed) return const SizedBox.shrink();

    final reconnectOnly = problems
        .where((p) => p['sync_status'] == 'reconnect_required')
        .toList();

    // Use the brightness-aware warning accent so the banner reads
    // against both the white light-mode card and the dark surface.
    // Colors.orangeAccent on its own is ~2.1:1 on white — fails AA for
    // body text and reads as washed-out.
    final accent = context.warning;
    return Container(
      margin: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: context.accentSoft(accent),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.accentBorder(accent)),
      ),
      child: LayoutBuilder(
        builder: (ctx, c) {
          final isNarrow = c.maxWidth < kCompactLayoutBelow;
          final names = problems
              .map((p) => (p['name'] ?? '').toString())
              .where((s) => s.isNotEmpty)
              .toList();
          final summary = problems.length == 1
              ? l.lwSyncBannerOneNeedsAttention(names.first)
              : l.lwSyncBannerManyNeedAttention(problems.length);

          final detail = names.length == 1
              ? names.first
              : names.length <= 3
              ? names.join(' · ')
              : '${names.take(2).join(' · ')} +${names.length - 2}';

          // When exactly one institution needs reconnecting, the button
          // says "Reconnect <Name>" so the action is unambiguous. With
          // 2+ we fall back to "Reconnect first" which targets the most
          // recent failure — saves the user one click vs forcing them
          // into the Management tab when every problem is the same kind.
          Widget? reconnectButton;
          if (reconnectOnly.isNotEmpty && onReconnect != null) {
            final target = reconnectOnly.first;
            final targetName = (target['name'] ?? '').toString();
            final label = reconnectOnly.length == 1
                ? (targetName.isEmpty
                      ? l.lwSyncBannerReconnect
                      : l.lwSyncBannerReconnectName(targetName))
                : l.lwSyncBannerReconnectCount(reconnectOnly.length);
            reconnectButton = FilledButton.icon(
              onPressed: () => onReconnect!(target['id'].toString()),
              icon: const Icon(Icons.link, size: 16),
              label: Text(label),
            );
          }
          final actionRow = Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (reconnectButton != null) reconnectButton,
              if (reconnectButton != null) const SizedBox(width: 8),
              TextButton.icon(
                onPressed: onJumpToManagement,
                icon: const Icon(Icons.settings, size: 16),
                label: Text(l.lwSyncBannerOpenSettings),
              ),
              if (onDismiss != null) ...[
                const SizedBox(width: 4),
                IconButton(
                  onPressed: () => onDismiss!(problemIds),
                  icon: const Icon(Icons.close, size: 18),
                  tooltip: l.lwSyncBannerDismiss,
                  visualDensity: VisualDensity.compact,
                  color: context.textSubtle,
                ),
              ],
            ],
          );

          if (isNarrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.warning_amber_rounded, color: accent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        summary,
                        style: TextStyle(
                          color: accent,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  detail,
                  style: TextStyle(color: context.textMuted, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                actionRow,
              ],
            );
          }
          return Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: accent, size: 18),
              const SizedBox(width: 8),
              // Flexible so a long summary + the action buttons (now including
              // the dismiss ×) never overflow a medium-width banner — it
              // ellipsizes instead.
              Flexible(
                child: Text(
                  summary,
                  style: TextStyle(color: accent, fontWeight: FontWeight.w700),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  detail,
                  style: TextStyle(color: context.textMuted, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              actionRow,
            ],
          );
        },
      ),
    );
  }
}
