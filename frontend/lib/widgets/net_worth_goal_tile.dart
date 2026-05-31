import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../services/preferences.dart';
import '../utils/theme_colors.dart';

/// Compact "where am I against my net-worth goal" tile shown on the
/// Overview tab. Reads the same goal that drives the projections chart
/// overlay, so editing it in either place updates both.
class NetWorthGoalTile extends StatelessWidget {
  /// Net worth in USD (the storage unit) — display multiplies through
  /// the conversion factor.
  final double netWorthUsd;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const NetWorthGoalTile({
    super.key,
    required this.netWorthUsd,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final goalUsd = Preferences.getGoalAmountUsd();
    final goalYear = Preferences.getGoalYear();
    if (goalUsd == null || goalYear == null || goalUsd <= 0) {
      return const SizedBox.shrink();
    }

    final pct = (netWorthUsd / goalUsd).clamp(0.0, 1.0);
    final pctLabel = (pct * 100).toStringAsFixed(1);
    final yearsRemaining = goalYear - DateTime.now().year;
    // Brightness-aware so the goal accent is AA-readable on both
    // surfaces — neon emerald/teal/yellow only pass on dark cards.
    final color = pct >= 1.0
        ? context.positive
        : pct >= 0.5
            ? context.tealAccent
            : context.yellowAccent;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.flag_outlined, color: color, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.pfNetWorthGoal,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '$pctLabel%',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    color: color,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              l.pfGoalHitBy(
                currencyFormat.format(goalUsd * conversionFactor),
                goalYear,
                yearsRemaining <= 0
                    ? l.pfGoalDueNow
                    : l.pfGoalYearsLeft(yearsRemaining),
              ),
              style: TextStyle(color: context.textMuted, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: pct,
                backgroundColor: context.tileSurface,
                color: color,
                minHeight: 10,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l.pfGoalCurrent(
                  currencyFormat.format(netWorthUsd * conversionFactor)),
              style: TextStyle(
                fontSize: 12,
                color: context.textSubtle,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
