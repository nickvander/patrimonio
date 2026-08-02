import 'package:flutter/material.dart';

import '../theme/typography.dart';
import '../utils/theme_colors.dart';

class StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color accent;

  /// Optional explanatory note. When non-null a small info glyph sits after
  /// the label and surfaces this text on hover / long-press, used e.g. to
  /// explain why the Investments subtotal differs from the Portfolio total.
  final String? tooltip;

  /// Optional drilldown callback. When non-null the tile becomes tappable
  /// (with a chevron affordance) and opens a sheet listing the accounts that
  /// fed the subtotal. Null keeps the tile a plain display-only Container —
  /// today's behaviour for any tile with no accounts behind it.
  final VoidCallback? onTap;

  const StatTile({
    super.key,
    required this.label,
    required this.value,
    required this.accent,
    this.tooltip,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Secondary stat: shared hairline border, tile surface, label in
    // textSubtle with a small accent dot on its leading edge — a category
    // cue without painting the whole label in a loud neon. (The net-worth
    // hero treatment now lives in _buildNetWorthHero, above the row, so
    // these tiles are uniformly secondary.)
    final tile = Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: context.tileSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                    color: context.textSubtle,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (tooltip != null) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: tooltip!,
                  triggerMode: TooltipTriggerMode.tap,
                  child: Icon(
                    Icons.info_outline,
                    size: 12,
                    color: context.textFaint,
                  ),
                ),
              ],
              // Drilldown affordance: a faint chevron only when the tile is
              // tappable, signalling "tap to see the accounts behind this".
              if (onTap != null) ...[
                const SizedBox(width: 4),
                Icon(Icons.chevron_right, size: 14, color: context.textFaint),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            // JetBrains Mono "ledger" figures — same treatment as the
            // net-worth hero so the dashboard's big numbers share one
            // consistent identity (bundled up to Bold/w700).
            style: brandDisplayStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: context.textPrimary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );

    // A3 (round 3, a11y): each tile is ONE labelled node — "Assets,
    // $1,234.00" — and tappable tiles announce as buttons. The label uses
    // the un-uppercased text (screen readers spell out all-caps strings on
    // some engines); the inner Texts/tooltip icon are excluded so nothing
    // is read twice.
    final semanticsLabel = '$label, $value';

    // Display-only when there's nothing to drill into — identical to the
    // tile's historical behaviour. Otherwise make the whole tile a tap
    // target with a matching ink ripple (the AppBar currency-swap toggle is
    // a separate widget, so this never swallows that gesture).
    if (onTap == null) {
      return Semantics(
        container: true,
        label: semanticsLabel,
        excludeSemantics: true,
        child: tile,
      );
    }
    return MergeSemantics(
      child: Semantics(
        button: true,
        label: semanticsLabel,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: ExcludeSemantics(child: tile),
          ),
        ),
      ),
    );
  }
}
