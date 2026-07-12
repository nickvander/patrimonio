import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../utils/currency.dart';
import '../utils/percent_format.dart';
import '../utils/theme_colors.dart';

/// One tracked ticker in the "Investments vs S&P 500" comparison — a symbol
/// with recorded purchase lots, as returned in the `symbols` list of
/// GET /api/dashboard/benchmark-comparison.
class TrackedLotSymbol {
  final String symbol;
  final int lotCount;
  final double investedUsd;
  final double yourValueUsd;
  final double benchmarkValueUsd;
  final DateTime? firstAcquired;
  final DateTime? lastAcquired;

  const TrackedLotSymbol({
    required this.symbol,
    required this.lotCount,
    required this.investedUsd,
    required this.yourValueUsd,
    required this.benchmarkValueUsd,
    this.firstAcquired,
    this.lastAcquired,
  });

  static TrackedLotSymbol? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final m = raw.cast<String, dynamic>();
    final symbol = (m['symbol'] ?? '').toString();
    if (symbol.isEmpty) return null;
    return TrackedLotSymbol(
      symbol: symbol,
      lotCount: (m['lot_count'] as num?)?.toInt() ?? 0,
      investedUsd: (m['invested_usd'] as num?)?.toDouble() ?? 0,
      yourValueUsd: (m['your_value_usd'] as num?)?.toDouble() ?? 0,
      benchmarkValueUsd: (m['benchmark_value_usd'] as num?)?.toDouble() ?? 0,
      firstAcquired: DateTime.tryParse((m['first_acquired'] ?? '').toString()),
      lastAcquired: DateTime.tryParse((m['last_acquired'] ?? '').toString()),
    );
  }

  /// Percentage-point gap vs the index for this symbol's lots:
  /// (your return − index return) × 100, both money-weighted over the same
  /// invested dollars. Null when nothing was invested (no meaningful return).
  double? get deltaPts {
    if (investedUsd <= 0) return null;
    return (yourValueUsd - benchmarkValueUsd) / investedUsd * 100;
  }
}

/// A holding excluded from the comparison because it has no recorded
/// purchase lots (`untracked` list of the same endpoint).
class UntrackedHolding {
  final String symbol;
  final double valueUsd;

  const UntrackedHolding({required this.symbol, required this.valueUsd});

  static UntrackedHolding? fromJson(dynamic raw) {
    if (raw is! Map) return null;
    final m = raw.cast<String, dynamic>();
    final symbol = (m['symbol'] ?? '').toString();
    if (symbol.isEmpty) return null;
    return UntrackedHolding(
      symbol: symbol,
      valueUsd: (m['value_usd'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// The per-symbol breakdown behind the benchmark comparison. Parsed
/// tolerantly: the fields are additive to the endpoint, so an older backend
/// simply yields empty lists — the card then hides the drill-down affordance
/// instead of erroring.
class TrackedLotsBreakdown {
  final List<TrackedLotSymbol> symbols;
  final List<UntrackedHolding> untracked;
  final double untrackedValueUsd;

  const TrackedLotsBreakdown({
    required this.symbols,
    required this.untracked,
    required this.untrackedValueUsd,
  });

  bool get isEmpty => symbols.isEmpty;

  static TrackedLotsBreakdown parse(Map<String, dynamic>? comparison) {
    final rawSymbols = comparison?['symbols'];
    final rawUntracked = comparison?['untracked'];
    final symbols = <TrackedLotSymbol>[
      if (rawSymbols is List)
        for (final s in rawSymbols) ?TrackedLotSymbol.fromJson(s),
    ];
    final untracked = <UntrackedHolding>[
      if (rawUntracked is List)
        for (final u in rawUntracked) ?UntrackedHolding.fromJson(u),
    ];
    // Prefer the server's total; fall back to summing the rows so the footer
    // stays honest if only the list is present.
    final total = (comparison?['untracked_value_usd'] as num?)?.toDouble() ??
        untracked.fold<double>(0, (acc, u) => acc + u.valueUsd);
    return TrackedLotsBreakdown(
      symbols: symbols,
      untracked: untracked,
      untrackedValueUsd: total,
    );
  }
}

/// "What's tracked" drill-down for the money-weighted benchmark comparison:
/// which tickers have recorded purchase lots (and how each did vs the index),
/// plus which holdings are excluded for lack of lot data.
///
/// Dumb/injected (house card convention): the performance card already holds
/// the comparison payload, so the sheet receives the parsed [breakdown] and
/// fetches nothing. Same bottom-sheet chrome as [DividendDetailSheet].
class TrackedLotsSheet extends StatelessWidget {
  final TrackedLotsBreakdown breakdown;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const TrackedLotsSheet({
    super.key,
    required this.breakdown,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  String _money(BuildContext context, double usd) =>
      currencyFormat.displayMoney(usd * conversionFactor);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Cap the sheet at most of the viewport; it scrolls within.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.9;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _handle(context),
            _header(context, l),
            Flexible(child: _body(context, l)),
          ],
        ),
      ),
    );
  }

  Widget _handle(BuildContext context) {
    return Container(
      width: 40,
      height: 4,
      margin: const EdgeInsets.only(top: 12, bottom: 4),
      decoration: BoxDecoration(
        color: context.hairline,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }

  Widget _header(BuildContext context, AppLocalizations l) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      child: Row(
        children: [
          Icon(Icons.fact_check_outlined, color: context.tealAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l.bmSheetTitle,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: context.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: l.actionClose,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _body(BuildContext context, AppLocalizations l) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        Text(
          l.bmSheetCaption,
          style: TextStyle(fontSize: 12, color: context.textSubtle),
        ),
        const SizedBox(height: 16),
        _rowsContainer(context, [
          for (final s in breakdown.symbols) _trackedRow(context, l, s),
        ]),
        if (breakdown.untracked.isNotEmpty) ...[
          const SizedBox(height: 24),
          Divider(color: context.hairline, height: 1),
          const SizedBox(height: 16),
          Text(
            l.bmUntrackedHeader,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: context.textMuted,
            ),
          ),
          const SizedBox(height: 8),
          _rowsContainer(context, [
            for (final u in breakdown.untracked) _untrackedRow(context, u),
          ]),
          const SizedBox(height: 8),
          Text(
            l.bmUntrackedTotal(
                _money(context, breakdown.untrackedValueUsd)),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: context.textMuted,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            l.bmUntrackedHint,
            style: TextStyle(fontSize: 11, color: context.textFaint),
          ),
        ],
      ],
    );
  }

  /// The dividend-sheet list chrome: tile surface, hairline border, hairline
  /// dividers between rows.
  Widget _rowsContainer(BuildContext context, List<Widget> rows) {
    return Container(
      decoration: BoxDecoration(
        color: context.tileSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.hairline),
      ),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Divider(
                  height: 1, color: context.hairline.withValues(alpha: 0.5)),
            rows[i],
          ],
        ],
      ),
    );
  }

  Widget _trackedRow(
      BuildContext context, AppLocalizations l, TrackedLotSymbol s) {
    // Locale-aware month-year ("Mar 2024" / "mar 2024") for the first buy.
    final locale = Localizations.localeOf(context).toString();
    final firstBuy = s.firstAcquired == null
        ? null
        : l.bmFirstBuy(DateFormat.yMMM(locale).format(s.firstAcquired!));
    final subtitle = [
      l.bmLots(s.lotCount),
      ?firstBuy,
    ].join(' · ');

    final pts = s.deltaPts;
    final ahead = (pts ?? 0) >= 0;
    // Signed percentage-point delta; the decimal separator goes through the
    // house localizer (same convention as the card's pts strings).
    final ptsText = pts == null
        ? null
        : l.bmPtsVsIndex(localizeNumberString(
            context, '${ahead ? '+' : ''}${pts.toStringAsFixed(1)}'));

    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    s.symbol,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: context.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(fontSize: 11, color: context.textSubtle),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // gen-l10n orders these alphabetically → (invested, value),
                // which happens to match the template order.
                Text(
                  l.bmInvestedToValue(_money(context, s.investedUsd),
                      _money(context, s.yourValueUsd)),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                if (ptsText != null) ...[
                  const SizedBox(height: 2),
                  Text(
                    ptsText,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: ahead ? context.positive : context.negative,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _untrackedRow(BuildContext context, UntrackedHolding u) {
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        child: Row(
          children: [
            Expanded(
              child: Text(
                u.symbol,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: context.textMuted,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Text(
              _money(context, u.valueUsd),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: context.textMuted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
