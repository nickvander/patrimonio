import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../utils/import_staleness.dart';
import '../utils/theme_colors.dart';

/// Gentle dashboard banner for import-only (manual) institutions whose data
/// has gone past the user's staleness threshold: "Banamex data is 42 days
/// old — import a statement", deep-linking to the import screen.
///
/// Sits under [SyncErrorBanner] in the pinned column. Deliberately the
/// info accent, not warning — old data is a nudge, not a failure; the
/// user makes it disappear by importing (or raising the threshold in
/// Settings), so there is no dismiss affordance to manage.
class ImportStalenessBanner extends StatelessWidget {
  /// Stale institutions, most-stale first (see [staleImportInstitutions]).
  final List<StaleImportInstitution> stale;

  /// Opens the import screen.
  final VoidCallback? onImport;

  const ImportStalenessBanner({
    super.key,
    required this.stale,
    this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (stale.isEmpty) return const SizedBox.shrink();

    final worst = stale.first;
    // gen-l10n orders placeholders alphabetically → (days, name), NOT the
    // template order ("{name} … {days}"). days must be passed first.
    final summary = l.impStaleBannerSummary(worst.daysStale, worst.name);
    final more =
        stale.length > 1 ? l.impStaleBannerMore(stale.length - 1) : null;

    final accent = context.info;
    final importButton = TextButton.icon(
      onPressed: onImport,
      icon: const Icon(Icons.upload_file, size: 16),
      label: Text(l.impStaleBannerImport),
    );

    return Container(
      margin: const EdgeInsets.fromLTRB(24, 16, 24, 0),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: context.accentSoft(accent),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.accentBorder(accent)),
      ),
      child: LayoutBuilder(builder: (ctx, c) {
        // Same breakpoint as SyncErrorBanner: below it the action drops to
        // its own line so the summary never fights the button for width.
        final isNarrow = c.maxWidth < 560;
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
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.history_toggle_off, color: accent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(child: summaryText),
                ],
              ),
              if (moreText != null) ...[
                const SizedBox(height: 4),
                moreText,
              ],
              Align(alignment: Alignment.centerRight, child: importButton),
            ],
          );
        }
        return Row(
          children: [
            Icon(Icons.history_toggle_off, color: accent, size: 18),
            const SizedBox(width: 8),
            Flexible(child: summaryText),
            const SizedBox(width: 8),
            Expanded(child: moreText ?? const SizedBox.shrink()),
            importButton,
          ],
        );
      }),
    );
  }
}
