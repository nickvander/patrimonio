import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
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

    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: context.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.swap_horiz, size: 18, color: context.tealAccent),
                const SizedBox(width: 8),
                Text(
                  l.cfTransfersTitle,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
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
        ),
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
    // Spot is denominated as USD→MXN in the backend. Invert when the
    // transfer is the reverse direction so we compare apples-to-apples.
    final spot = (spotRaw != null && spotRaw > 0)
        ? (srcCur == 'MXN' && dstCur == 'USD' ? 1.0 / spotRaw : spotRaw)
        : null;
    final delta = (spot != null && spot > 0)
        ? ((implied - spot) / spot) * 100.0
        : null;
    final confirmed = t['user_confirmed'] == true;
    final id = t['id']?.toString() ?? '';
    final srcLabel = (t['source_label'] ?? '').toString();
    final dstLabel = (t['dest_label'] ?? '').toString();
    final srcDate = (t['source_date'] ?? '').toString();

    final money = (double amount, String cur) =>
        NumberFormat.currency(symbol: cur == 'MXN' ? r'MX$' : r'$').format(amount);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
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
                      '${money(srcAmount, srcCur)} $srcCur  →  ${money(dstAmount, dstCur)} $dstCur · $srcDate',
                      style: TextStyle(
                        fontSize: 11,
                        color: context.textSubtle,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
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
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
                    minimumSize: const Size(0, 28),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
        '$sign${pct.toStringAsFixed(1)}%',
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
