import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../utils/currency.dart';
import '../utils/percent_format.dart';
import '../utils/theme_colors.dart';

/// Lists every detected (or user-confirmed) cross-currency cash
/// transfer for the cash-flow tab. Each row shows the two legs of
/// the pair, the implied FX rate Wise/Remitly gave the user, and
/// the day's spot rate for the same currency pair — so the user
/// can see at a glance whether the remittance service paid out
/// above or below market.
///
/// Confirm/Unlink actions are inline. Tapping a row opens nothing
/// — the user can dig further from the regular Transactions tab.
class CrossCurrencyTransfersCard extends StatelessWidget {
  final List<dynamic> transfers;
  final NumberFormat currencyFormat;
  final Future<void> Function(String id)? onConfirm;
  final Future<void> Function(String id)? onUnlink;

  const CrossCurrencyTransfersCard({
    super.key,
    required this.transfers,
    required this.currencyFormat,
    this.onConfirm,
    this.onUnlink,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (transfers.isEmpty) return const SizedBox.shrink();

    // House card idiom (elevation 4 / radius 20 / responsive 16-24 padding),
    // matching monthly_cash_flow_card.dart so the tab's cards read as one set.
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        // Width-responsive off the card's OWN constraint (inner
        // LayoutBuilder, per the skill rule), not MediaQuery — the card can
        // be narrower than the screen (outer tab padding, width clamps).
        child: LayoutBuilder(builder: (context, c) {
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
                  Icon(Icons.swap_horiz, size: 18, color: context.tealAccent),
                  const SizedBox(width: 8),
                ],
                Flexible(
                  child: Text(
                    isPhone
                        ? l.cfTransfersTitle.toUpperCase()
                        : l.cfTransfersTitle,
                    style: isPhone
                        ? TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.6,
                            color: context.textSubtle,
                          )
                        : TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: context.textPrimary,
                          ),
                    // maxLines only on the phone overline; wider layouts
                    // keep the original wrap behaviour pixel-identical.
                    maxLines: isPhone ? 1 : null,
                    overflow: isPhone ? TextOverflow.ellipsis : null,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: context.accentSoft(context.tealAccent),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    '${transfers.length}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: context.tealAccent,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              l.cfTransfersSubtitle,
              style: TextStyle(
                fontSize: 12,
                color: context.textSubtle,
              ),
            ),
            const SizedBox(height: 12),
            ...transfers.map((t) => _buildRow(context, t as Map)),
          ],
          );
        }),
      ),
    );
  }

  Widget _buildRow(BuildContext context, Map t) {
    final l = AppLocalizations.of(context);
    final srcAmount = (t['source_amount'] as num?)?.toDouble() ?? 0;
    final dstAmount = (t['dest_amount'] as num?)?.toDouble() ?? 0;
    final srcCur = (t['source_currency'] ?? '').toString().toUpperCase();
    final dstCur = (t['dest_currency'] ?? '').toString().toUpperCase();
    final implied = (t['implied_fx_rate'] as num?)?.toDouble() ?? 0;
    final spotRaw = (t['spot_fx_rate'] as num?)?.toDouble();
    // Both rates are already MXN-per-USD regardless of transfer direction
    // (backend implied_rate normalises direction; see fx_transfer_link.rs),
    // so they're directly comparable. The old reverse-direction inversion
    // compared USD/MXN against MXN/USD and produced ~+29,000% deltas.
    final spot = (spotRaw != null && spotRaw > 0) ? spotRaw : null;
    final delta = (spot != null && spot > 0)
        ? ((implied - spot) / spot) * 100.0
        : null;
    final confirmed = t['user_confirmed'] == true;
    final id = t['id']?.toString() ?? '';
    final srcLabel = (t['source_label'] ?? '').toString();
    final dstLabel = (t['dest_label'] ?? '').toString();
    final srcDate = (t['source_date'] ?? '').toString();

    // Leg labels + amounts/rate sub-line. The sub-line uses the shared
    // ISO-prefixed formatter (utils/currency.dart) so each leg carries
    // exactly one currency indicator and renders for any code, not just
    // USD/MXN. maxLines + ellipsis keep it from overflowing when stacked
    // full-width on a narrow screen.
    final labelColumn = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$srcLabel  →  $dstLabel',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: context.textPrimary,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          '${formatCurrencyWithCode(srcAmount, srcCur)}  →  '
          '${formatCurrencyWithCode(dstAmount, dstCur)} · $srcDate',
          style: TextStyle(
            fontSize: 11,
            color: context.textSubtle,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );

    // Implied vs spot rate + delta pill. Side-by-side with the label on
    // wide rows; tucked underneath (left-aligned) when stacked.
    Widget rateCluster({required bool stacked}) => Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Column(
              crossAxisAlignment:
                  stacked ? CrossAxisAlignment.start : CrossAxisAlignment.end,
              children: [
                Text(
                  NumberFormat('0.00').format(implied),
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w800,
                    color: context.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (spot != null)
                  Text(
                    l.cfTransfersSpot(NumberFormat('0.00').format(spot)),
                    style: TextStyle(
                      fontSize: 11,
                      color: context.textFaint,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
            if (delta != null) ...[
              const SizedBox(width: 10),
              _buildDeltaPill(context, delta),
            ],
          ],
        );

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Below ~520px the fixed 3-column row runs out of room and the
          // amounts/rate sub-line overflows, so stack the rate cluster
          // underneath the label instead of beside it.
          LayoutBuilder(
            builder: (context, constraints) {
              if (constraints.maxWidth < 520) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    labelColumn,
                    const SizedBox(height: 6),
                    rateCluster(stacked: true),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Expanded(child: labelColumn),
                  const SizedBox(width: 12),
                  rateCluster(stacked: false),
                ],
              );
            },
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              if (!confirmed && onConfirm != null)
                TextButton.icon(
                  onPressed: () => onConfirm!(id),
                  icon: const Icon(Icons.check, size: 14),
                  label: Text(l.cfTransfersConfirm,
                      style: const TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: context.tealAccent,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    // 48dp touch-target floor: these trigger backend writes,
                    // so no shrinkWrap — the default tapTargetSize pads the
                    // 40px visual button out to a 48dp hit area.
                    minimumSize: const Size(48, 40),
                  ),
                ),
              if (confirmed)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: Row(
                    children: [
                      Icon(Icons.verified_outlined,
                          size: 13, color: context.tealAccent),
                      const SizedBox(width: 4),
                      Text(
                        l.cfTransfersConfirmed,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.tealAccent,
                        ),
                      ),
                    ],
                  ),
                ),
              const Spacer(),
              if (onUnlink != null)
                TextButton.icon(
                  onPressed: () => onUnlink!(id),
                  icon: const Icon(Icons.link_off, size: 14),
                  label: Text(l.cfTransfersUnlink,
                      style: const TextStyle(fontSize: 12)),
                  style: TextButton.styleFrom(
                    foregroundColor: context.textSubtle,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    // 48dp touch-target floor: these trigger backend writes,
                    // so no shrinkWrap — the default tapTargetSize pads the
                    // 40px visual button out to a 48dp hit area.
                    minimumSize: const Size(48, 40),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Delta pill: green when Wise paid out above the spot, red when
  /// below. Threshold-free — even a 0.1% miss reads as a sign so the
  /// user can scan a long list and instantly see who got the worse
  /// deal vs the market.
  Widget _buildDeltaPill(BuildContext context, double pct) {
    final positive = pct >= 0;
    final color = positive ? context.positive : context.negative;
    final sign = positive ? '+' : '';
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: context.accentSoft(color),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$sign${formatPercent(context, pct, digits: 1)}',
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }
}
