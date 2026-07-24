import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../utils/currency.dart';
import '../utils/net_worth_delta.dart';
import '../utils/percent_format.dart';
import '../utils/theme_colors.dart';

/// Compact net-worth change badge shown under the dashboard hero total:
/// an arrow, the signed change, the percent move and an HONEST window label
/// ("vs 30d ago" / "vs 7d ago") naming the anchor the delta was actually
/// computed against — never a wished-for window. The caller computes [delta]
/// via [computeNetWorthDelta], the same 30d→7d tolerance-capped fallback the
/// net-worth card's trend chip uses, so the two surfaces can never disagree.
///
/// [NetWorthDelta.amount] is USD; [conversionFactor] scales it to the active
/// reporting currency. The percent is a ratio and thus currency-agnostic.
class NetWorthDeltaBadge extends StatelessWidget {
  final NetWorthDelta delta;
  final NumberFormat currencyFormat;
  final double conversionFactor;

  const NetWorthDeltaBadge({
    super.key,
    required this.delta,
    required this.currencyFormat,
    required this.conversionFactor,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final up = delta.amount >= 0;
    final color = up ? context.positive : context.warning;
    final sign = up ? '+' : '−';
    // Percentage is null when the baseline is unreliable (negative or
    // onboarding-inflated) — show the honest dollar delta alone.
    final pct = delta.percentage;
    final pctLabel = pct == null
        ? ''
        : ' · $sign${formatPercent(context, pct.abs(), digits: 1)}';
    final amount = delta.amount.abs() * conversionFactor;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            '$sign${currencyFormat.displayMoney(amount)}$pctLabel',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 6),
          Text(
            // The label reflects the actual anchor window ('30d' or '7d'),
            // matching the net-worth card's chip copy exactly.
            l.pfDeltaVsAgo(delta.windowLabel),
            style: TextStyle(fontSize: 11, color: context.textFaint),
          ),
        ],
      ),
    );
  }
}
