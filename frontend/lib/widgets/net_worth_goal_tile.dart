import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/preferences.dart';

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
    final goalUsd = Preferences.getGoalAmountUsd();
    final goalYear = Preferences.getGoalYear();
    if (goalUsd == null || goalYear == null || goalUsd <= 0) {
      return const SizedBox.shrink();
    }

    final pct = (netWorthUsd / goalUsd).clamp(0.0, 1.0);
    final pctLabel = (pct * 100).toStringAsFixed(1);
    final yearsRemaining = goalYear - DateTime.now().year;
    final color = pct >= 1.0
        ? const Color(0xFF00E676)
        : pct >= 0.5
            ? const Color(0xFF1DE9B6)
            : const Color(0xFFFFD600);

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
                const Expanded(
                  child: Text(
                    'Net-worth goal',
                    style: TextStyle(
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
              'Hit ${currencyFormat.format(goalUsd * conversionFactor)} by $goalYear · '
              '${yearsRemaining <= 0 ? "due now" : "$yearsRemaining year${yearsRemaining == 1 ? "" : "s"} left"}',
              style: const TextStyle(color: Colors.white60, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: LinearProgressIndicator(
                value: pct,
                backgroundColor: Colors.white.withValues(alpha: 0.06),
                color: color,
                minHeight: 10,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Current: ${currencyFormat.format(netWorthUsd * conversionFactor)}',
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white54,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
