import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme/buttons.dart';
import '../utils/import_staleness.dart';
import '../utils/theme_colors.dart';

/// Gentle dashboard banner for import-only (manual) institutions whose data
/// has gone past the user's staleness threshold: "Banamex data is 42 days
/// old — import a statement", deep-linking to the import screen.
///
/// Sits under [SyncErrorBanner] in the pinned column. Deliberately the
/// info accent, not warning — old data is a nudge, not a failure. The ×
/// snoozes the CURRENTLY listed institutions for 7 days (persisted
/// server-side, see the dashboard's snooze handler); an institution that
/// goes stale later still banners immediately.
class ImportStalenessBanner extends StatelessWidget {
  /// Stale institutions, most-stale first, already filtered for snoozes
  /// and mutes (see [staleImportInstitutions]).
  final List<StaleImportInstitution> stale;

  /// Opens the import screen.
  final VoidCallback? onImport;

  /// Called with the institutions currently shown when the user taps ×.
  /// The parent persists a 7-day snooze for exactly this set.
  final void Function(List<StaleImportInstitution> shown)? onDismiss;

  const ImportStalenessBanner({
    super.key,
    required this.stale,
    this.onImport,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (stale.isEmpty) return const SizedBox.shrink();

    final worst = stale.first;
    // gen-l10n orders placeholders alphabetically → (days, name), NOT the
    // template order ("{name} … {days}"). days must be passed first.
    final summary = l.impStaleBannerSummary(worst.daysStale, worst.name);
    final more = stale.length > 1
        ? l.impStaleBannerMore(stale.length - 1)
        : null;

    final accent = context.info;
    final importButton = TextButton.icon(
      onPressed: onImport,
      icon: const Icon(Icons.upload_file, size: 16),
      label: Text(l.impStaleBannerImport),
    );
    // Dismiss × — a corner affordance, never a peer of the action button.
    // Tooltip spells out that it snoozes rather than resolves. [compact]
    // shrinks it to sit inline on the wide single-row layout; phones get
    // the full-size (48dp floor) target in the top-right corner.
    IconButton? dismissButton({required bool compact}) => onDismiss == null
        ? null
        : IconButton(
            onPressed: () => onDismiss!(stale),
            icon: Icon(Icons.close, size: compact ? 18 : 20),
            tooltip: l.impStaleBannerDismiss,
            visualDensity: compact
                ? VisualDensity.compact
                : VisualDensity.standard,
            color: context.textSubtle,
          );

    return Container(
      margin: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      decoration: BoxDecoration(
        color: context.accentSoft(accent),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.accentBorder(accent)),
      ),
      child: LayoutBuilder(
        builder: (ctx, c) {
          // Same breakpoint as SyncErrorBanner: below it the action drops to
          // its own line so the summary never fights the button for width.
          final isNarrow = c.maxWidth < kCompactLayoutBelow;
          final summaryText = Text(
            summary,
            style: TextStyle(color: accent, fontWeight: FontWeight.w700),
            maxLines: isNarrow ? 2 : 1,
            overflow: TextOverflow.ellipsis,
          );
          final moreText = more == null
              ? null
              : Text(
                  more,
                  style: TextStyle(color: context.textMuted, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                );

          if (isNarrow) {
            final dismiss = dismissButton(compact: false);
            // Corner ×: the container's right/top padding shrinks so the
            // full-size target hugs the corner without inflating the banner.
            return Padding(
              padding: EdgeInsets.fromLTRB(
                16,
                dismiss == null ? 12 : 6,
                dismiss == null ? 16 : 4,
                8,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Icon(Icons.history_toggle_off, color: accent, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: summaryText),
                      ?dismiss,
                    ],
                  ),
                  if (moreText != null)
                    Padding(
                      // Align under the summary text (icon 18 + gap 8), not
                      // the banner edge, so the block reads as one message.
                      padding: const EdgeInsets.only(left: 26, top: 2),
                      child: moreText,
                    ),
                  Align(
                    alignment: Alignment.centerRight,
                    child: Padding(
                      padding: EdgeInsets.only(right: dismiss == null ? 0 : 12),
                      child: importButton,
                    ),
                  ),
                ],
              ),
            );
          }
          final dismiss = dismissButton(compact: true);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(Icons.history_toggle_off, color: accent, size: 18),
                const SizedBox(width: 8),
                Flexible(child: summaryText),
                const SizedBox(width: 8),
                Expanded(child: moreText ?? const SizedBox.shrink()),
                importButton,
                if (dismiss != null) ...[const SizedBox(width: 4), dismiss],
              ],
            ),
          );
        },
      ),
    );
  }
}
