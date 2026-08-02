import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../utils/currency.dart';
import '../utils/percent_format.dart';
import '../utils/quantity_format.dart';
import '../utils/theme_colors.dart';
import 'holding_subtitle.dart';
import 'lot_breakdown_sheet.dart';

/// Phone-width holding row: collapses to the three facts that matter at a
/// glance — name, value, change — and reveals shares / price / cost basis /
/// gain (and a lot breakdown, when lots exist) on tap. Replaces the wide
/// 7-column table below [_kMobileBreakpoint], where a sideways scroll the
/// thumb can't reach isn't a usable interaction.
class MobileHoldingRow extends StatefulWidget {
  final dynamic holding;
  final NumberFormat format;
  final String targetCurrency;
  final double usdMxnRate;

  const MobileHoldingRow({
    super.key,
    required this.holding,
    required this.format,
    required this.targetCurrency,
    required this.usdMxnRate,
  });

  @override
  State<MobileHoldingRow> createState() => _MobileHoldingRowState();
}

class _MobileHoldingRowState extends State<MobileHoldingRow> {
  bool _expanded = false;

  double _conv(double v, String from) => convertCurrency(
    v,
    from: from,
    to: widget.targetCurrency,
    usdMxnRate: widget.usdMxnRate,
  );

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final h = widget.holding;
    final sourceCurrency = (h['currency'] ?? widget.targetCurrency).toString();
    final quantity = (h['quantity'] as num?)?.toDouble() ?? 0.0;
    final value = _conv(
      (h['value'] as num?)?.toDouble() ?? 0.0,
      sourceCurrency,
    );
    final price = _conv(
      (h['price'] as num?)?.toDouble() ?? 0.0,
      sourceCurrency,
    );
    // Null = the institution didn't report a cost basis. Render a
    // muted em dash with a tooltip, never a fake green "+0.00%".
    final costBasisSource = (h['cost_basis'] as num?)?.toDouble();
    final costBasis = costBasisSource == null
        ? null
        : _conv(costBasisSource, sourceCurrency);
    final gain = (h['gain_loss'] as num?)?.toDouble();
    final gainConverted = gain == null ? null : _conv(gain, sourceCurrency);
    final gainPct = (h['gain_loss_pct'] as num?)?.toDouble();
    final isGain = (gain ?? 0) >= 0;

    final rawSymbol = (h['symbol'] ?? '').toString();
    final rawName = (h['name'] ?? '').toString();
    final acctName = (h['account_name'] ?? '').toString();
    final instName = (h['institution_name'] ?? '').toString();
    final isOpaqueSecurityId =
        rawSymbol.length > 8 ||
        (rawSymbol != rawSymbol.toUpperCase() && rawSymbol.length > 4);
    final displaySymbol = isOpaqueSecurityId
        ? (rawName.isNotEmpty ? rawName : '—')
        : (rawSymbol.isEmpty
              ? (rawName.isNotEmpty ? rawName : '?')
              : rawSymbol);
    // Same segment split as the desktop table subtitle: the account is the
    // most-protected segment (see [HoldingSubtitle]) — on a 390px phone it
    // used to be exactly the part the end-first ellipsis cut off.
    final subtitleName = (!isOpaqueSecurityId && rawName.isNotEmpty)
        ? rawName
        : '';
    final subtitleAccount = (acctName.isNotEmpty && acctName != instName)
        ? acctName
        : '';
    final hasSubtitle =
        subtitleName.isNotEmpty ||
        instName.isNotEmpty ||
        subtitleAccount.isNotEmpty;

    final lots = (h['lots'] as List?) ?? const [];
    final hasLots = lots.isNotEmpty;
    // A flat-basis holding (no lots) can still open the drill-down to show
    // its flat basis plus the no-acquisition-dates note.
    final canDrillDown = hasLots || costBasisSource != null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          onTap: () => setState(() => _expanded = !_expanded),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
            child: Row(
              children: [
                CircleAvatar(
                  backgroundColor: context.tileSurface,
                  radius: 16,
                  child: Text(
                    displaySymbol.isEmpty
                        ? '?'
                        : displaySymbol.substring(0, 1).toUpperCase(),
                    style: TextStyle(
                      color: context.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        displaySymbol,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (hasSubtitle)
                        HoldingSubtitle(
                          name: subtitleName,
                          institution: instName,
                          account: subtitleAccount,
                          style: TextStyle(
                            fontSize: 11,
                            color: context.textSubtle,
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.format.displayMoney(value),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                    ),
                    const SizedBox(height: 2),
                    if (gainPct == null)
                      Tooltip(
                        message: l.pfCostBasisUnavailable,
                        waitDuration: const Duration(milliseconds: 600),
                        child: Text(
                          '—',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                            color: context.textMuted,
                          ),
                        ),
                      )
                    else
                      Text(
                        '${isGain ? '+' : ''}${formatPercent(context, gainPct, digits: 2)}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: isGain ? context.positive : context.negative,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                  ],
                ),
                Icon(
                  _expanded ? Icons.expand_less : Icons.expand_more,
                  size: 20,
                  color: context.textSubtle,
                ),
              ],
            ),
          ),
        ),
        if (_expanded)
          Padding(
            padding: const EdgeInsets.fromLTRB(56, 0, 4, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Account + institution in FULL (wrapping, never ellipsized):
                // the compact subtitle above can still truncate long names,
                // and this panel is the only place a phone can read them.
                if (acctName.isNotEmpty)
                  _detailRow(l.txAccount, acctName, wrapValue: true),
                if (instName.isNotEmpty && instName != acctName)
                  _detailRow(
                    l.lwNotifInstitutionFallback,
                    instName,
                    wrapValue: true,
                  ),
                _detailRow(l.pfColShares, formatQuantity(quantity)),
                _detailRow(l.pfColPrice, widget.format.format(price)),
                _detailRow(
                  l.pfColCostBasis,
                  costBasis == null
                      ? '—'
                      : widget.format.displayMoney(costBasis),
                  color: costBasis == null ? context.textMuted : null,
                  tooltip: costBasis == null ? l.pfCostBasisUnavailable : null,
                ),
                _detailRow(
                  l.pfColGain,
                  gainConverted == null
                      ? '—'
                      : '${isGain ? '+' : ''}${widget.format.displayMoney(gainConverted)}',
                  color: gainConverted == null
                      ? context.textMuted
                      : (isGain ? context.positive : context.negative),
                  tooltip: gainConverted == null
                      ? l.pfCostBasisUnavailable
                      : null,
                ),
                if (canDrillDown)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      onPressed: () => showLotBreakdown(context, h),
                      icon: const Icon(Icons.receipt_long, size: 16),
                      label: Text(hasLots ? l.pfViewLots : l.pfViewCostBasis),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        visualDensity: VisualDensity.compact,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        Divider(color: context.hairline, height: 1),
      ],
    );
  }

  /// [wrapValue]: the value is prose (account / institution name) rather
  /// than a figure — render it in full, soft-wrapping across lines, instead
  /// of the single unconstrained line the numeric rows use.
  Widget _detailRow(
    String label,
    String value, {
    Color? color,
    String? tooltip,
    bool wrapValue = false,
  }) {
    Widget valueText = Text(
      value,
      softWrap: true,
      textAlign: wrapValue ? TextAlign.end : null,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: color ?? context.textPrimary,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    if (tooltip != null) {
      valueText = Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 600),
        child: valueText,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: wrapValue
            ? CrossAxisAlignment.start
            : CrossAxisAlignment.center,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12, color: context.textSubtle),
          ),
          if (wrapValue)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(left: 16),
                child: valueText,
              ),
            )
          else
            valueText,
        ],
      ),
    );
  }
}
