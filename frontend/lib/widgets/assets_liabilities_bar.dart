import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../utils/percent_format.dart';
import '../utils/theme_colors.dart';

/// Thin horizontal split-bar showing the ratio of assets to liabilities
/// across the user's accounts. Visualizes the same totals the
/// NetWorthCard chart sums, but in a glanceable form that doesn't
/// require reading the chart axis.
///
/// Inputs match what the dashboard's `/api/dashboard/overview` returns
/// in `type_breakdown` — a list of `{account_type, total_usd}` rows.
/// `conversionFactor` is applied so the percentages reflect the
/// reporting currency the user has selected.
class AssetsLiabilitiesBar extends StatelessWidget {
  final List<dynamic> typeBreakdown;
  final double conversionFactor;
  const AssetsLiabilitiesBar({
    super.key,
    required this.typeBreakdown,
    this.conversionFactor = 1.0,
  });

  @override
  Widget build(BuildContext context) {
    if (typeBreakdown.isEmpty) return const SizedBox.shrink();

    final l = AppLocalizations.of(context);
    final assetColor = context.positive;
    final liabilityColor = context.negative;

    double totalAssets = 0;
    double totalLiabilities = 0;
    for (final raw in typeBreakdown) {
      if (raw is! Map) continue;
      final type = (raw['account_type'] ?? '').toString().toLowerCase();
      final valUsd = ((raw['total_usd'] ?? 0.0) as num).toDouble();
      final val = valUsd * conversionFactor;
      // Credit accounts hold negative balances (debt) on the
      // dashboard payload, so we group them with anything else
      // that happens to be negative.
      if (type == 'credit' || val < 0) {
        totalLiabilities += val.abs();
      } else {
        totalAssets += val;
      }
    }

    if (totalAssets == 0 && totalLiabilities == 0) {
      return const SizedBox.shrink();
    }

    final grandTotal = totalAssets + totalLiabilities;
    final assetPct = totalAssets / grandTotal;
    final liabilityPct = totalLiabilities / grandTotal;

    // A bar that would read "Assets 100% / Liabilities 0%" carries no
    // information — suppress it entirely for debt-free portfolios.
    if (liabilityPct < 0.005) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                if (assetPct > 0)
                  Expanded(
                    flex: (assetPct * 1000).round(),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            assetColor,
                            assetColor.withValues(alpha: 0.55),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (liabilityPct > 0)
                  Expanded(
                    flex: (liabilityPct * 1000).round(),
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            liabilityColor,
                            liabilityColor.withValues(alpha: 0.55),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _LegendDot(
              label: l.statAssets,
              color: assetColor,
              pct: assetPct,
            ),
            const SizedBox(width: 16),
            _LegendDot(
              label: l.statLiabilities,
              color: liabilityColor,
              pct: liabilityPct,
            ),
          ],
        ),
      ],
    );
  }
}

class _LegendDot extends StatelessWidget {
  final String label;
  final Color color;
  final double pct;
  const _LegendDot({required this.label, required this.color, required this.pct});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(
          '$label ${formatPercent(context, pct * 100, digits: 0)}',
          style: TextStyle(
            color: Theme.of(context).colorScheme.outline,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}
