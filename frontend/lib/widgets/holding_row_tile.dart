import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/currency.dart';
import '../utils/percent_format.dart';
import '../utils/quantity_format.dart';
import '../utils/theme_colors.dart';
import 'holding_subtitle.dart';
import 'instrument_detail_sheet.dart';

const double _kHMargin = 20.0;
const double _kColShares = 100.0;
const double _kColPrice = 124.0;
const double _kColDay = 86.0;
const double _kColValue = 144.0;
const double _kColCost = 126.0;
const double _kColGain = 132.0;
const double _kColReturn = 108.0;

/// Shared row layout used by the header and every body row. Asset takes
/// the remaining space; numeric columns are fixed width so values line
/// up vertically.
Widget holdingsTableRow({
  required Widget asset,
  required Widget shares,
  required Widget price,
  required Widget day,
  required Widget value,
  required Widget costBasis,
  required Widget gain,
  required Widget returnPct,
}) {
  return Padding(
    padding: const EdgeInsets.symmetric(horizontal: _kHMargin),
    child: Row(
      children: [
        Expanded(child: asset),
        SizedBox(width: _kColShares, child: shares),
        SizedBox(width: _kColPrice, child: price),
        SizedBox(width: _kColDay, child: day),
        SizedBox(width: _kColValue, child: value),
        SizedBox(width: _kColCost, child: costBasis),
        SizedBox(width: _kColGain, child: gain),
        SizedBox(width: _kColReturn, child: returnPct),
      ],
    ),
  );
}

/// A single holding row used inside the virtualized ListView. Stateful
/// so that hover-over highlight doesn't have to rebuild the whole table.
class HoldingRowTile extends StatefulWidget {
  final dynamic holding;
  final NumberFormat format;
  final String targetCurrency;
  final double usdMxnRate;

  /// For the instrument detail sheet the row opens on tap (contract C-F).
  final ApiService apiService;

  /// USD → display-currency factor, forwarded to the sheet so its figures
  /// follow the page's currency toggle.
  final double conversionFactor;

  /// See [PortfolioCard.onDataRefreshRequested] (contract C3-D) — awaited
  /// when the sheet reports a classification change.
  final Future<void> Function()? onDataRefreshRequested;

  const HoldingRowTile({
    super.key,
    required this.holding,
    required this.format,
    required this.targetCurrency,
    required this.usdMxnRate,
    required this.apiService,
    required this.conversionFactor,
    this.onDataRefreshRequested,
  });

  @override
  State<HoldingRowTile> createState() => _HoldingRowTileState();
}

class _HoldingRowTileState extends State<HoldingRowTile> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final h = widget.holding;
    // Null cost_basis / gain_loss / gain_loss_pct means the
    // institution doesn't report a basis (Plaid employer plans,
    // statement imports). Those render a muted em dash with an
    // explanatory tooltip — never a fake "+0.00%" in gain-green.
    final gain = (h['gain_loss'] as num?)?.toDouble();
    final gainPct = (h['gain_loss_pct'] as num?)?.toDouble();
    final quantity = (h['quantity'] as num?)?.toDouble() ?? 0.0;
    final sourceCurrency = (h['currency'] ?? widget.targetCurrency).toString();
    final sourcePrice = (h['price'] as num?)?.toDouble() ?? 0.0;
    final sourceValue = (h['value'] as num?)?.toDouble() ?? 0.0;
    final costBasisSource = (h['cost_basis'] as num?)?.toDouble();
    final price = convertCurrency(
      sourcePrice,
      from: sourceCurrency,
      to: widget.targetCurrency,
      usdMxnRate: widget.usdMxnRate,
    );
    final value = convertCurrency(
      sourceValue,
      from: sourceCurrency,
      to: widget.targetCurrency,
      usdMxnRate: widget.usdMxnRate,
    );
    final costBasis = costBasisSource == null
        ? null
        : convertCurrency(
            costBasisSource,
            from: sourceCurrency,
            to: widget.targetCurrency,
            usdMxnRate: widget.usdMxnRate,
          );
    final gainConverted = gain == null
        ? null
        : convertCurrency(
            gain,
            from: sourceCurrency,
            to: widget.targetCurrency,
            usdMxnRate: widget.usdMxnRate,
          );
    final isGain = (gain ?? 0) >= 0;
    final basisUnavailableMsg = AppLocalizations.of(
      context,
    ).pfCostBasisUnavailable;

    final rawSymbol = (h['symbol'] ?? '').toString();
    final rawName = (h['name'] ?? '').toString();
    final acctName = (h['account_name'] ?? '').toString();
    final instName = (h['institution_name'] ?? '').toString();
    // Plaid emits opaque security_ids (e.g. "3mg4qV4JZycPL4qeZgB...") for
    // un-tickered Vanguard mutual funds. Real tickers are short and upper-
    // case; security_ids are long and mixed-case.
    final isOpaqueSecurityId =
        rawSymbol.length > 8 ||
        (rawSymbol != rawSymbol.toUpperCase() && rawSymbol.length > 4);
    final displaySymbol = isOpaqueSecurityId
        ? (rawName.isNotEmpty ? rawName : '—')
        : (rawSymbol.isEmpty
              ? (rawName.isNotEmpty ? rawName : '?')
              : rawSymbol);
    // Secondary line: security name (when it isn't already the display
    // symbol), institution, and account — bullet-separated. Surfacing
    // `account_name` lets users with positions split across several
    // brokerages tell them apart at a glance, so [HoldingSubtitle] keeps
    // it visible by truncating the fund name / institution first.
    final subtitleName = (!isOpaqueSecurityId && rawName.isNotEmpty)
        ? rawName
        : '';
    final subtitleAccount = (acctName.isNotEmpty && acctName != instName)
        ? acctName
        : '';
    final avatarChar = displaySymbol.isEmpty
        ? '?'
        : displaySymbol.substring(0, 1).toUpperCase();

    final asset = Padding(
      padding: const EdgeInsets.only(right: 12),
      child: Row(
        children: [
          CircleAvatar(
            backgroundColor: context.tileSurface,
            radius: 16,
            child: Text(
              avatarChar,
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
              mainAxisAlignment: MainAxisAlignment.center,
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
                HoldingSubtitle(
                  name: subtitleName,
                  institution: instName,
                  account: subtitleAccount,
                  style: TextStyle(fontSize: 11, color: context.textSubtle),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final shares = Row(
      mainAxisAlignment: MainAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.baseline,
      textBaseline: TextBaseline.alphabetic,
      children: [
        Text(
          formatQuantity(quantity),
          style: const TextStyle(
            fontSize: 14,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        const SizedBox(width: 4),
        Text(
          AppLocalizations.of(context).pfShares,
          style: TextStyle(fontSize: 11, color: context.textFaint),
        ),
      ],
    );

    final priceCell = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          widget.format.format(price),
          style: const TextStyle(
            fontSize: 14,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        if (sourceCurrency != widget.targetCurrency)
          Text(
            formatCurrencyAmount(sourcePrice, sourceCurrency),
            style: TextStyle(
              fontSize: 10,
              color: context.textFaint,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
      ],
    );

    final valueCell = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          widget.format.displayMoney(value),
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        if (sourceCurrency != widget.targetCurrency)
          Text(
            displayCurrencyAmount(sourceValue, sourceCurrency),
            style: TextStyle(
              fontSize: 10,
              color: context.textFaint,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
      ],
    );

    // Day change (contract C-B): % since the last stored close, with the
    // absolute move as a muted sub-line. The backend sends the absolute in
    // USD (value_usd × native pct), so it converts from USD — not from the
    // holding's native currency like the other cells. Null (cash sleeve,
    // opaque symbol, stale closes, older backend) renders a muted em dash.
    final dayPct = (h['day_change_pct'] as num?)?.toDouble();
    final dayUsd = (h['day_change_usd'] as num?)?.toDouble();
    final dayConverted = dayUsd == null
        ? null
        : convertCurrency(
            dayUsd,
            from: 'USD',
            to: widget.targetCurrency,
            usdMxnRate: widget.usdMxnRate,
          );
    // Sign per figure: a loss must render "-1.41% / -$731.53" — the shared
    // sign used to come from `dayPositive` alone ('' for negatives) while
    // the values were .abs()'d, which silently dropped every minus sign.
    // A flat (exactly zero) day renders neutral: muted text, no fake green.
    final dayPositive = (dayPct ?? dayUsd ?? 0) > 0;
    final dayFlat = (dayPct ?? 0) == 0 && (dayUsd ?? 0) == 0;
    String signOf(double v) => v > 0
        ? '+'
        : v < 0
        ? '-'
        : '';
    final dayColor = dayFlat
        ? context.textMuted
        : dayPositive
        ? context.positive
        : context.negative;
    final dayUnavailableMsg = AppLocalizations.of(context).pfDayUnavailable;
    final dayCell = Align(
      alignment: Alignment.centerRight,
      child: dayPct == null && dayConverted == null
          ? Tooltip(
              message: dayUnavailableMsg,
              waitDuration: const Duration(milliseconds: 600),
              child: Text(
                '—',
                style: TextStyle(fontSize: 14, color: context.textMuted),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (dayPct != null)
                  Text(
                    '${signOf(dayPct)}${formatPercent(context, dayPct.abs(), digits: 2)}',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: dayColor,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                if (dayConverted != null)
                  Text(
                    '${signOf(dayConverted)}${widget.format.displayMoney(dayConverted.abs())}',
                    style: TextStyle(
                      fontSize: 11,
                      color: context.textMuted,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
              ],
            ),
    );

    final costBasisCell = Align(
      alignment: Alignment.centerRight,
      child: costBasis == null
          ? Tooltip(
              message: basisUnavailableMsg,
              waitDuration: const Duration(milliseconds: 600),
              child: Text(
                '—',
                style: TextStyle(fontSize: 14, color: context.textMuted),
              ),
            )
          : Text(
              widget.format.displayMoney(costBasis),
              style: TextStyle(
                fontSize: 14,
                color: context.textMuted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
    );

    final gainCell = Align(
      alignment: Alignment.centerRight,
      child: gainConverted == null
          ? Tooltip(
              message: basisUnavailableMsg,
              waitDuration: const Duration(milliseconds: 600),
              child: Text(
                '—',
                style: TextStyle(fontSize: 14, color: context.textMuted),
              ),
            )
          : Text(
              '${isGain ? '+' : ''}${widget.format.displayMoney(gainConverted)}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: isGain ? context.positive : context.negative,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
    );

    // pct can be null for a KNOWN zero-cost basis too (return % is
    // undefined); only claim "unavailable" when the basis really is.
    final returnDash = Text(
      '—',
      style: TextStyle(fontSize: 13, color: context.textMuted),
    );
    final returnCell = Align(
      alignment: Alignment.centerRight,
      child: gainPct == null
          ? (gain == null
                ? Tooltip(
                    message: basisUnavailableMsg,
                    waitDuration: const Duration(milliseconds: 600),
                    child: returnDash,
                  )
                : returnDash)
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: (isGain ? context.positive : context.negative)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                '${isGain ? '+' : ''}${formatPercent(context, gainPct, digits: 2)}',
                style: TextStyle(
                  color: isGain ? context.positive : context.negative,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
    );

    // Row tap opens the per-instrument sheet (contract C-F) for anything
    // with a symbol — opaque security_ids included, since the endpoint
    // degrades gracefully for them (stats + accounts, no chart). Only
    // symbol-less rows stay non-interactive. The per-lot dialog is no
    // longer the row-tap target; it stays reachable from the mobile
    // expanded row's Lots button.
    final canOpenSheet = rawSymbol.isNotEmpty;

    return MouseRegion(
      cursor: canOpenSheet
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        // InkWell (over GestureDetector) makes the row keyboard-focusable
        // and Enter/Space-activatable for screen-reader users.
        onTap: canOpenSheet
            ? () async {
                final changed = await showInstrumentSheet(
                  context,
                  apiService: widget.apiService,
                  symbol: rawSymbol,
                  conversionFactor: widget.conversionFactor,
                  currencyFormat: widget.format,
                );
                // C3-D: bubble the sheet's classification change to the
                // owner so holdings + allocation refetch live (round-3 U2).
                if (changed && mounted) {
                  await widget.onDataRefreshRequested?.call();
                }
              }
            : null,
        child: Container(
          color: _hover ? context.tint(0.05) : Colors.transparent,
          child: holdingsTableRow(
            asset: asset,
            shares: shares,
            price: priceCell,
            day: dayCell,
            value: valueCell,
            costBasis: costBasisCell,
            gain: gainCell,
            returnPct: returnCell,
          ),
        ),
      ),
    );
  }
}
