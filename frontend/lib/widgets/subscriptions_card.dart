import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';

/// Detected recurring outflows ("subscriptions") pinned to the Cash
/// Flow tab. Backend does the cluster detection — see
/// `dashboard.rs::detected_subscriptions`. This widget just renders.
///
/// Empty list collapses to nothing — the heuristic needs ≥ 3 occurrences
/// of the same merchant + amount band, so a brand-new user with sparse
/// history sees no card at all rather than an empty pane.
class SubscriptionsCard extends StatelessWidget {
  final List<dynamic> subscriptions;
  /// Conversion factor for the USD-stored `monthly_usd` field.
  /// 1.0 for USD reporting, USD/MXN rate when reporting in MXN.
  final double conversionFactor;
  /// USD/MXN spot used to convert native MXN amounts (and any other
  /// foreign currency) into the reporting currency for display.
  final double usdMxnRate;
  final NumberFormat currencyFormat;
  final String targetCurrency;
  /// Optional callback to seed the transactions tab's search with the
  /// merchant name so the user can drill into the underlying rows.
  final void Function(String merchant)? onTapMerchant;
  /// "This isn't a subscription, stop showing it." Dismisses the row
  /// and POSTs to `/dashboard/subscriptions/ignore` so the detector
  /// skips this merchant on its next run.
  final Future<void> Function(String merchant)? onIgnoreMerchant;

  const SubscriptionsCard({
    super.key,
    required this.subscriptions,
    required this.conversionFactor,
    required this.usdMxnRate,
    required this.currencyFormat,
    required this.targetCurrency,
    this.onTapMerchant,
    this.onIgnoreMerchant,
  });

  @override
  Widget build(BuildContext context) {
    if (subscriptions.isEmpty) return const SizedBox.shrink();
    // Total monthly burn — top-of-card summary so the user knows the
    // pile size before diving into individual rows.
    final totalMonthly = subscriptions.fold<double>(0.0, (sum, s) {
      final v = (s['monthly_usd'] as num?)?.toDouble() ?? 0.0;
      return sum + v;
    });

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
                Icon(
                  Icons.autorenew_rounded,
                  size: 18,
                  color: context.purpleAccent,
                ),
                const SizedBox(width: 8),
                Text(
                  'Recurring charges',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    '${subscriptions.length} detected',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.textSubtle,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '≈ ${currencyFormat.format(totalMonthly * conversionFactor)} / mo',
                  style: TextStyle(
                    fontSize: 13,
                    color: context.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Charges that repeat every 5–62 days. Tap a row to filter '
              'the transactions list.',
              style: TextStyle(fontSize: 11, color: context.textSubtle),
            ),
            const SizedBox(height: 12),
            for (var i = 0; i < subscriptions.length; i++) ...[
              if (i > 0)
                Divider(height: 1, color: context.hairline),
              _row(context, subscriptions[i] as Map<String, dynamic>),
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(BuildContext context, Map<String, dynamic> s) {
    final merchant = (s['merchant'] ?? '—').toString();
    final monthlyUsd = (s['monthly_usd'] as num?)?.toDouble() ?? 0.0;
    final cadence = (s['cadence_days'] as num?)?.toInt() ?? 30;
    final lastAmount = (s['last_amount'] as num?)?.toDouble() ?? 0.0;
    final currency = (s['currency'] ?? 'USD').toString();
    final occurrences = (s['occurrences'] as num?)?.toInt() ?? 0;
    final lastDate = DateTime.tryParse(s['last_charge_date'] ?? '');

    final cadenceLabel = cadence <= 8
        ? 'Weekly'
        : cadence <= 16
            ? 'Bi-weekly'
            : cadence <= 35
                ? 'Monthly'
                : 'Every ${cadence}d';

    return InkWell(
      onTap: onTapMerchant == null ? null : () => onTapMerchant!(merchant),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: context.accentSoft(context.purpleAccent),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                Icons.repeat_rounded,
                color: context.purpleAccent,
                size: 18,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    merchant,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '$cadenceLabel · $occurrences charges'
                    '${lastDate == null ? '' : ' · last ${DateFormat('MMM d').format(lastDate)}'}',
                    style: TextStyle(
                      fontSize: 11,
                      color: context.textSubtle,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  // Convert via reporting currency so $9.99 and $14.99
                  // can be compared at a glance regardless of the
                  // underlying native currency.
                  currencyFormat.format(
                    convertCurrency(
                      lastAmount,
                      from: currency,
                      to: targetCurrency,
                      usdMxnRate: usdMxnRate,
                    ),
                  ),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  '${currencyFormat.format(monthlyUsd * conversionFactor)} / mo',
                  style: TextStyle(
                    fontSize: 11,
                    color: context.textSubtle,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            if (onIgnoreMerchant != null)
              IconButton(
                tooltip: 'Not a subscription — hide this row',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close),
                onPressed: () => onIgnoreMerchant!(merchant),
              ),
          ],
        ),
      ),
    );
  }
}
