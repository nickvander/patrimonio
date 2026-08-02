import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';

/// Modal showing the per-lot FIFO breakdown for a holding — each lot's
/// acquisition date, qty, native cost-per-unit, the USD/MXN FX rate at
/// acquisition, and the USD cost. Answers the power-user question "why does
/// my MXN P&L differ from a naive current-FX conversion of my native cost
/// basis?" — the FX rate column shows exactly what's different. Top-level so
/// both the desktop row and the mobile collapsed row can open it.
void showLotBreakdown(BuildContext context, dynamic h) {
  final l = AppLocalizations.of(context);
  final lots = ((h['lots'] as List?) ?? const []).cast<dynamic>();
  final symbol = (h['symbol'] ?? '').toString();
  final name = (h['name'] ?? '').toString();
  final title = symbol.isNotEmpty
      ? symbol
      : (name.isNotEmpty ? name : l.pfHolding);

  final dateFmt = DateFormat('MMM d, y');
  final usdFmt = NumberFormat.currency(locale: 'en_US', symbol: r'$');
  // Current native price per unit, used to derive each lot's current
  // value (qty × price). Holdings that pre-date the price refresh, or
  // cash-like rows, may report 0 — in that case the current-value cell
  // falls back to an em dash rather than a misleading "$0.00".
  final currentPrice = (h['price'] as num?)?.toDouble() ?? 0.0;
  // Long-term threshold: a lot held > 365 days qualifies for long-term
  // capital-gains treatment. Compared against the lot's acquisition date.
  final now = DateTime.now();

  // No lots: institution (e.g. a Plaid investment account) reported a
  // flat cost basis with no acquisition dates. Show that flat basis with
  // a tooltip explaining why the per-lot grid is empty, instead of an
  // empty modal.
  final hasLots = lots.isNotEmpty;
  final flatBasisUsd = (h['cost_basis_usd'] as num?)?.toDouble();

  showDialog<void>(
    context: context,
    builder: (ctx) {
      return Dialog(
        backgroundColor: Theme.of(ctx).colorScheme.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720, maxHeight: 560),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 22, 16, 16),
            // M1 (round 3): below ~480px of inner width the 6-column
            // grid wraps its headers ("Acquire d"), ellipsizes dollar
            // values and squashes the LT/ST chips — swap it for stacked
            // two-line rows. The ≥480px grid is untouched.
            child: LayoutBuilder(
              builder: (_, box) {
                final narrowLots = box.maxWidth < 480;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // A1 (round 3, a11y): dialog title as a header
                              // landmark.
                              Semantics(
                                header: true,
                                child: Text(
                                  l.pfLotBreakdownTitle(title),
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                    color: context.textPrimary,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                l.pfLotBreakdownSubtitle,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: context.textSubtle,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          icon: const Icon(Icons.close),
                          tooltip: l.actionClose,
                          onPressed: () => Navigator.pop(ctx),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    if (!hasLots)
                      // No per-lot data — show the flat basis the institution
                      // did report, with a tooltip explaining the gap.
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(
                          children: [
                            Icon(
                              Icons.info_outline,
                              size: 16,
                              color: context.textSubtle,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Tooltip(
                                message: l.pfLotsUnavailableTooltip,
                                child: Text(
                                  flatBasisUsd == null
                                      ? l.pfLotsUnavailable
                                      : '${l.pfFlatCostBasis}: ${usdFmt.format(flatBasisUsd)}',
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: context.textSubtle,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    else if (narrowLots)
                      // Two-line stacked rows (no column headers): line 1 =
                      // "Mar 1, 2024 · 10 sh" + term chip, line 2 = per-unit
                      // → current value · USD cost. Same figures and
                      // fallbacks as the wide grid.
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: lots.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            color: context.hairline.withValues(alpha: 0.5),
                          ),
                          itemBuilder: (_, i) => _narrowLotRow(
                            context,
                            l,
                            lots[i] as Map,
                            currentPrice: currentPrice,
                            dateFmt: dateFmt,
                            usdFmt: usdFmt,
                            now: now,
                          ),
                        ),
                      )
                    else ...[
                      // Column header. Six columns, fixed grid so the body
                      // rows align on a quick scan.
                      Row(
                        children: [
                          _lotHeader(context, l.pfLotAcquired, flex: 3),
                          _lotHeader(
                            context,
                            l.pfLotQty,
                            flex: 2,
                            alignRight: true,
                          ),
                          _lotHeader(
                            context,
                            l.pfLotCostPerUnit,
                            flex: 3,
                            alignRight: true,
                          ),
                          _lotHeader(
                            context,
                            l.pfLotCurrentValue,
                            flex: 3,
                            alignRight: true,
                          ),
                          _lotHeader(
                            context,
                            l.pfLotUsdCost,
                            flex: 3,
                            alignRight: true,
                          ),
                          _lotHeader(
                            context,
                            l.pfLotTerm,
                            flex: 2,
                            alignRight: true,
                          ),
                        ],
                      ),
                      Divider(height: 12, color: context.hairline),
                      Flexible(
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: lots.length,
                          separatorBuilder: (_, _) => Divider(
                            height: 1,
                            color: context.hairline.withValues(alpha: 0.5),
                          ),
                          itemBuilder: (_, i) {
                            final lot = lots[i] as Map;
                            final acquired = (lot['acquired_at'] ?? '')
                                .toString();
                            DateTime? date;
                            if (acquired.isNotEmpty) {
                              date = DateTime.tryParse(acquired);
                            }
                            final qty = (lot['qty'] as num?)?.toDouble() ?? 0.0;
                            final cpu =
                                (lot['cost_per_unit'] as num?)?.toDouble() ??
                                0.0;
                            final ccy = (lot['currency'] ?? 'USD').toString();
                            final usdCost =
                                (lot['usd_cost'] as num?)?.toDouble() ?? 0.0;
                            // Current value of the lot = qty × current native
                            // price. Falls back to an em dash when the price is
                            // missing (0) so we don't render a fake "$0.00".
                            final currentVal = qty * currentPrice;
                            // Long-term = held at least one calendar year. Uses
                            // the calendar rule (now on/after the same M/D one year
                            // later) rather than a 365-day count so it matches the
                            // tax module across leap years. Only computed when the
                            // acquisition date parsed; unknown shows an em dash.
                            final isLongTerm =
                                date != null &&
                                !now.isBefore(
                                  DateTime(date.year + 1, date.month, date.day),
                                );
                            // A1 (round 3, a11y): each lot reads as ONE
                            // sentence — "Acquired Mar 1, 2024, 10 shares at
                            // $88.10 USD, Long-term" — instead of six cells.
                            return Semantics(
                              container: true,
                              label: l.axLotRow(
                                date != null ? dateFmt.format(date) : acquired,
                                qty.toStringAsFixed(
                                  qty == qty.roundToDouble() ? 0 : 4,
                                ),
                                '${formatCurrencyAmount(cpu, ccy)} $ccy',
                                date == null
                                    ? '—'
                                    : (isLongTerm
                                          ? l.pfLotLongTerm
                                          : l.pfLotShortTerm),
                              ),
                              excludeSemantics: true,
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    _lotCell(
                                      context,
                                      date != null
                                          ? dateFmt.format(date)
                                          : acquired,
                                      flex: 3,
                                    ),
                                    _lotCell(
                                      context,
                                      qty.toStringAsFixed(
                                        qty == qty.roundToDouble() ? 0 : 4,
                                      ),
                                      flex: 2,
                                      alignRight: true,
                                    ),
                                    _lotCell(
                                      context,
                                      '${formatCurrencyAmount(cpu, ccy)} $ccy',
                                      flex: 3,
                                      alignRight: true,
                                    ),
                                    _lotCell(
                                      context,
                                      currentPrice > 0
                                          ? '${formatCurrencyAmount(currentVal, ccy)} $ccy'
                                          : '—',
                                      flex: 3,
                                      alignRight: true,
                                      muted: currentPrice <= 0,
                                    ),
                                    _lotCell(
                                      context,
                                      usdFmt.format(usdCost),
                                      flex: 3,
                                      alignRight: true,
                                      bold: true,
                                    ),
                                    Expanded(
                                      flex: 2,
                                      child: Align(
                                        alignment: Alignment.centerRight,
                                        child: date == null
                                            ? Text(
                                                '—',
                                                style: TextStyle(
                                                  fontSize: 13,
                                                  color: context.textFaint,
                                                ),
                                              )
                                            : _lotTermBadge(
                                                context,
                                                isLongTerm,
                                              ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
          ),
        ),
      );
    },
  );
}

/// One stacked lot row for the narrow (<480px) lot-breakdown layout (M1):
///   line 1 — `Mar 1, 2024 · 10 sh` (w600) with the LT/ST chip
///            right-aligned;
///   line 2 — `@ $88.10 → $1,720.00 · cost $881.00` (muted 11px):
///            native per-unit and current value, USD cost — the same
///            figures and em-dash fallbacks as the wide 6-column grid,
///            compact enough to stay on one line at 390px.
/// Rows keep a 12px vertical rhythm (6px padding each side of the
/// hairline separator).
Widget _narrowLotRow(
  BuildContext context,
  AppLocalizations l,
  Map lot, {
  required double currentPrice,
  required DateFormat dateFmt,
  required NumberFormat usdFmt,
  required DateTime now,
}) {
  final acquired = (lot['acquired_at'] ?? '').toString();
  final date = acquired.isEmpty ? null : DateTime.tryParse(acquired);
  final qty = (lot['qty'] as num?)?.toDouble() ?? 0.0;
  final cpu = (lot['cost_per_unit'] as num?)?.toDouble() ?? 0.0;
  final ccy = (lot['currency'] ?? 'USD').toString();
  final usdCost = (lot['usd_cost'] as num?)?.toDouble() ?? 0.0;
  final currentVal = qty * currentPrice;
  // Same calendar long-term rule as the wide grid (leap-year safe).
  final isLongTerm =
      date != null &&
      !now.isBefore(DateTime(date.year + 1, date.month, date.day));
  // Fractional lots keep their 4-decimal precision ("0.1181 sh").
  final qtyStr = qty.toStringAsFixed(qty == qty.roundToDouble() ? 0 : 4);
  final dateLabel = date != null ? dateFmt.format(date) : acquired;
  // No "now" suffix on the current value and 11px below (round-3 polish):
  // three amounts have to share one line at 390px without splitting the
  // "cost $X" pair across rows.
  final line2 =
      '@ ${formatCurrencyAmount(cpu, ccy)} → '
      '${currentPrice > 0 ? formatCurrencyAmount(currentVal, ccy) : '—'}'
      ' · ${l.pf3LotCost(usdFmt.format(usdCost))}';
  // A1 (round 3, a11y): same one-sentence node as the wide grid's rows so
  // both layouts announce identically.
  return Semantics(
    container: true,
    label: l.axLotRow(
      dateLabel,
      qtyStr,
      '${formatCurrencyAmount(cpu, ccy)} $ccy',
      date == null ? '—' : (isLongTerm ? l.pfLotLongTerm : l.pfLotShortTerm),
    ),
    excludeSemantics: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '$dateLabel · ${l.pf3LotQtyShares(qtyStr)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              if (date == null)
                Text(
                  '—',
                  style: TextStyle(fontSize: 13, color: context.textFaint),
                )
              else
                _lotTermBadge(context, isLongTerm),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            line2,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              color: context.textMuted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    ),
  );
}

Widget _lotHeader(
  BuildContext context,
  String text, {
  int flex = 1,
  bool alignRight = false,
}) {
  return Expanded(
    flex: flex,
    child: Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: context.textSubtle,
          letterSpacing: 0.4,
        ),
      ),
    ),
  );
}

Widget _lotCell(
  BuildContext context,
  String text, {
  int flex = 1,
  bool alignRight = false,
  bool bold = false,
  bool muted = false,
}) {
  return Expanded(
    flex: flex,
    child: Align(
      alignment: alignRight ? Alignment.centerRight : Alignment.centerLeft,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 13,
          fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
          color: muted ? context.textFaint : context.textPrimary,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    ),
  );
}

/// Small pill flagging whether a lot is long-term (held > 365 days, eligible
/// for long-term capital-gains treatment) or short-term. Uses the positive
/// token for long-term (the favourable tax case) and a muted neutral tone
/// for short-term so the eye lands on the long-term lots.
Widget _lotTermBadge(BuildContext context, bool isLongTerm) {
  final l = AppLocalizations.of(context);
  final color = isLongTerm ? context.positive : context.textSubtle;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(4),
    ),
    child: Text(
      isLongTerm ? l.pfLotLongTerm : l.pfLotShortTerm,
      style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: color),
    ),
  );
}
