import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../utils/currency.dart';
import '../utils/percent_format.dart';
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
    final l = AppLocalizations.of(context);
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

    // Card padding off the card's OWN LayoutBuilder constraint, never
    // the window (skill §4/§5): the card is narrower than the screen on
    // every layout that pads or column-clamps its tab.
    return LayoutBuilder(
      builder: (_, outer) {
        final pad = outer.maxWidth < 720 ? 16.0 : 24.0;
        return Card(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: EdgeInsets.all(pad),
            // Width-responsive off the card's OWN constraint (inner
            // LayoutBuilder, per the skill rule), not MediaQuery — the card can
            // be narrower than the screen (outer tab padding, width clamps).
            child: LayoutBuilder(
              builder: (context, c) {
                // House ~420 phone breakpoint: compact chrome — no leading icon,
                // title compressed to a small uppercase overline (the
                // portfolio_card idiom). Wider layouts are unchanged.
                final isPhone = c.maxWidth < 420;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        if (!isPhone) ...[
                          Icon(
                            Icons.autorenew_rounded,
                            size: 18,
                            color: context.purpleAccent,
                          ),
                          const SizedBox(width: 8),
                        ],
                        Text(
                          isPhone
                              ? l.cfSubscriptionsTitle.toUpperCase()
                              : l.cfSubscriptionsTitle,
                          style: isPhone
                              ? TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 0.6,
                                  color: context.textSubtle,
                                )
                              : TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                  color: context.textPrimary,
                                ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            l.cfSubscriptionsActiveCount(active.length) +
                                (stopped.isEmpty
                                    ? ''
                                    : ' · ${l.cfSubscriptionsStoppedCount(stopped.length)}'),
                            style: TextStyle(
                              fontSize: 12,
                              color: context.textSubtle,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Text(
                          l.cfPerMonthApprox(
                            widget.currencyFormat.displayMoney(
                              totalMonthly * widget.conversionFactor,
                            ),
                          ),
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
                      l.cfSubscriptionsSubtitle,
                      style: TextStyle(fontSize: 11, color: context.textSubtle),
                    ),
                    const SizedBox(height: 12),
                    if (active.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Text(
                          l.cfSubscriptionsNoneActive,
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
                                l.cfSubscriptionsStoppedHeader(stopped.length),
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: context.textPrimary,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  l.cfSubscriptionsStoppedHint,
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
                          if (i > 0)
                            Divider(height: 1, color: context.hairline),
                          _row(context, stopped[i], cancelled: true),
                        ],
                    ],
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _row(
    BuildContext context,
    Map<String, dynamic> s, {
    required bool cancelled,
  }) {
    final l = AppLocalizations.of(context);
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
        ? l.cfCadenceWeekly
        : cadence <= 16
        ? l.cfCadenceBiweekly
        : cadence <= 35
        ? l.cfCadenceMonthly
        : l.cfCadenceEveryNDays(cadence);

    // Muted treatment for cancelled rows: lower opacity icon tile,
    // subdued text. The row is still tappable to drill into the
    // historical transactions.
    final accent = cancelled ? context.neutralAccent : context.purpleAccent;
    final primaryColor = cancelled ? context.textSubtle : context.textPrimary;

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
                cancelled ? Icons.history_toggle_off : Icons.repeat_rounded,
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
                    '$cadenceLabel · ${l.cfChargesCount(occurrences)}'
                    '${lastDate == null ? '' : ' · ${l.cfLastCharged(DateFormat('MMM d').format(lastDate))}'}',
                    style: TextStyle(fontSize: 11, color: context.textSubtle),
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
                // Native amount, shown only when the charge isn't already
                // in the reporting currency — otherwise the converted line
                // above silently hides that this is really a MXN 199 charge.
                if (currency.toUpperCase() !=
                    widget.targetCurrency.toUpperCase()) ...[
                  const SizedBox(height: 1),
                  Text(
                    formatCurrencyWithCode(lastAmount, currency),
                    style: TextStyle(
                      fontSize: 11,
                      color: context.textSubtle,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
                Text(
                  cancelled
                      ? l.cfWasPerMonth(
                          widget.currencyFormat.displayMoney(
                            monthlyUsd * widget.conversionFactor,
                          ),
                        )
                      : l.cfPerMonth(
                          widget.currencyFormat.displayMoney(
                            monthlyUsd * widget.conversionFactor,
                          ),
                        ),
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
            if (!cancelled && widget.onIgnoreMerchant != null) ...[
              // Gap separates the dismiss button from the row's own
              // navigation InkWell; default constraints (no compact
              // density) keep the button on the 48dp touch floor.
              const SizedBox(width: 4),
              IconButton(
                tooltip: l.cfNotASubscription,
                iconSize: 16,
                icon: const Icon(Icons.close),
                onPressed: () => widget.onIgnoreMerchant!(merchant),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// The chip's share label: whole-percent for shares ≥ 1% (`"12%"`),
  /// `"<1%"` below — variable precision, so it routes through
  /// [localizePercentString] rather than [formatPercent]'s fixed digits.
  String _shareLabel(BuildContext context, Map<String, dynamic> slice) {
    final pct = ((slice['share'] as num?)?.toDouble() ?? 0.0) * 100;
    return localizePercentString(
      context,
      pct >= 1 ? pct.round().toString() : '<1',
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
    final l = AppLocalizations.of(context);
    final accent = cancelled ? context.neutralAccent : context.purpleAccent;
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
              '${_shareLabel(context, slice)}',
              style: TextStyle(
                fontSize: 11,
                color: accent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        if (hidden > 0)
          Padding(
            padding: const EdgeInsets.only(left: 2),
            child: Text(
              l.cfPlusNMore(hidden),
              style: TextStyle(fontSize: 11, color: context.textSubtle),
            ),
          ),
      ],
    );
  }
}
