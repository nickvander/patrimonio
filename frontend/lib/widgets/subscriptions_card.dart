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
///
/// The backend tags each row `status: "active" | "cancelled"`. Cancelled
/// rows last charged 91–548 days ago, and surface below the active list
/// in a collapsed "Stopped" section so the user can audit
/// "did I actually cancel that?".
class SubscriptionsCard extends StatefulWidget {
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
  State<SubscriptionsCard> createState() => _SubscriptionsCardState();
}

class _SubscriptionsCardState extends State<SubscriptionsCard> {
  bool _stoppedExpanded = false;

  @override
  Widget build(BuildContext context) {
    if (widget.subscriptions.isEmpty) return const SizedBox.shrink();

    // Partition by status. Rows without an explicit status field fall
    // back to active so older backends keep working.
    final active = <Map<String, dynamic>>[];
    final stopped = <Map<String, dynamic>>[];
    for (final s in widget.subscriptions) {
      final m = s as Map<String, dynamic>;
      final status = (m['status'] ?? 'active').toString();
      if (status == 'cancelled') {
        stopped.add(m);
      } else {
        active.add(m);
      }
    }

    // Total monthly burn — top-of-card summary so the user knows the
    // pile size before diving into individual rows. Cancelled rows are
    // excluded; they're not charging anymore.
    final totalMonthly = active.fold<double>(0.0, (sum, s) {
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
                    '${active.length} active'
                    '${stopped.isEmpty ? '' : ' · ${stopped.length} stopped'}',
                    style: TextStyle(
                      fontSize: 12,
                      color: context.textSubtle,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  '≈ ${widget.currencyFormat.format(totalMonthly * widget.conversionFactor)} / mo',
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
            if (active.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No active subscriptions detected.',
                  style: TextStyle(
                    fontSize: 12,
                    color: context.textSubtle,
                  ),
                ),
              )
            else
              for (var i = 0; i < active.length; i++) ...[
                if (i > 0) Divider(height: 1, color: context.hairline),
                _row(context, active[i], cancelled: false),
              ],
            if (stopped.isNotEmpty) ...[
              const SizedBox(height: 12),
              Divider(height: 1, color: context.hairline),
              InkWell(
                onTap: () => setState(
                  () => _stoppedExpanded = !_stoppedExpanded,
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    children: [
                      Icon(
                        _stoppedExpanded
                            ? Icons.expand_less
                            : Icons.expand_more,
                        size: 18,
                        color: context.textSubtle,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Stopped (${stopped.length})',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          'Last charged > 90 days ago',
                          style: TextStyle(
                            fontSize: 11,
                            color: context.textSubtle,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_stoppedExpanded)
                for (var i = 0; i < stopped.length; i++) ...[
                  if (i > 0) Divider(height: 1, color: context.hairline),
                  _row(context, stopped[i], cancelled: true),
                ],
            ],
          ],
        ),
      ),
    );
  }

  Widget _row(
    BuildContext context,
    Map<String, dynamic> s, {
    required bool cancelled,
  }) {
    final merchant = (s['merchant'] ?? '—').toString();
    final monthlyUsd = (s['monthly_usd'] as num?)?.toDouble() ?? 0.0;
    final cadence = (s['cadence_days'] as num?)?.toInt() ?? 30;
    final lastAmount = (s['last_amount'] as num?)?.toDouble() ?? 0.0;
    final currency = (s['currency'] ?? 'USD').toString();
    final occurrences = (s['occurrences'] as num?)?.toInt() ?? 0;
    final lastDate = DateTime.tryParse(s['last_charge_date'] ?? '');
    final byAccount =
        (s['by_account'] as List?)?.cast<Map<String, dynamic>>() ?? const [];

    final cadenceLabel = cadence <= 8
        ? 'Weekly'
        : cadence <= 16
            ? 'Bi-weekly'
            : cadence <= 35
                ? 'Monthly'
                : 'Every ${cadence}d';

    // Muted treatment for cancelled rows: lower opacity icon tile,
    // subdued text. The row is still tappable to drill into the
    // historical transactions.
    final accent =
        cancelled ? context.neutralAccent : context.purpleAccent;
    final primaryColor =
        cancelled ? context.textSubtle : context.textPrimary;

    return InkWell(
      onTap: widget.onTapMerchant == null
          ? null
          : () => widget.onTapMerchant!(merchant),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: context.accentSoft(accent),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                cancelled
                    ? Icons.history_toggle_off
                    : Icons.repeat_rounded,
                color: accent,
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
                      color: primaryColor,
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
                  // Per-account distribution chips. Hidden when the
                  // cluster only spans one account (single-account is
                  // the common case and the icon's enough context).
                  // For 2+ accounts we surface every slice — the share
                  // is informative even at small sizes.
                  if (byAccount.length > 1) ...[
                    const SizedBox(height: 6),
                    _byAccountChips(context, byAccount, cancelled),
                  ],
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
                  widget.currencyFormat.format(
                    convertCurrency(
                      lastAmount,
                      from: currency,
                      to: widget.targetCurrency,
                      usdMxnRate: widget.usdMxnRate,
                    ),
                  ),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: primaryColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                Text(
                  cancelled
                      ? 'was ${widget.currencyFormat.format(monthlyUsd * widget.conversionFactor)} / mo'
                      : '${widget.currencyFormat.format(monthlyUsd * widget.conversionFactor)} / mo',
                  style: TextStyle(
                    fontSize: 11,
                    color: context.textSubtle,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            // Hide the "× not a subscription" affordance for cancelled
            // rows — they're already historical, dismissing wouldn't add
            // info and the affordance would be confusing ("not a
            // subscription" vs "stopped subscription").
            if (!cancelled && widget.onIgnoreMerchant != null)
              IconButton(
                tooltip: 'Not a subscription — hide this row',
                iconSize: 16,
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.close),
                onPressed: () => widget.onIgnoreMerchant!(merchant),
              ),
          ],
        ),
      ),
    );
  }

  /// Render the per-account distribution as compact chips. Each chip is
  /// `AccountName · NN%`. Caps at 3 chips + "+N more" so a pathological
  /// cluster (e.g. a refund detected across many cards) doesn't blow
  /// out the row height. Sorted by descending share (backend already
  /// orders them that way; we just render in order).
  Widget _byAccountChips(
    BuildContext context,
    List<Map<String, dynamic>> slices,
    bool cancelled,
  ) {
    const maxChips = 3;
    final visible = slices.take(maxChips).toList();
    final hidden = slices.length - visible.length;
    final accent =
        cancelled ? context.neutralAccent : context.purpleAccent;
    return Wrap(
      spacing: 4,
      runSpacing: 4,
      children: [
        for (final slice in visible)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: context.accentSoft(accent),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${slice['account_name'] ?? '—'} · '
              '${((slice['share'] as num?)?.toDouble() ?? 0.0) * 100 >= 1
                  ? (((slice['share'] as num?)?.toDouble() ?? 0.0) * 100).round()
                  : '<1'}%',
              style: TextStyle(
                fontSize: 10,
                color: accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              '+$hidden more',
              style: TextStyle(
                fontSize: 10,
                color: context.textSubtle,
              ),
            ),
          ),
      ],
    );
  }
}
