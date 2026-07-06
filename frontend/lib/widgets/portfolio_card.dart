import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/preferences.dart';
import '../utils/currency.dart';
import '../utils/mask_aware_name.dart';
import '../utils/theme_colors.dart';

/// Which slice of the portfolio surface a [PortfolioCard] instance renders.
///
/// The portfolio tab follows the 2026 research flow
/// overview → performance → allocation → signals → holdings. Performance and
/// allocation are their own widgets; the remaining three are slices of the
/// same underlying data (and the same holdings list), so they share one
/// widget driven by this enum. Each instance owns its own state, but reads
/// the same `portfolioData['holdings']`, so there's nothing to keep in sync.
enum PortfolioSection {
  /// Hero total value + change + dual-currency panel + headline KPIs.
  summary,

  /// Thin scannable strip: biggest gainer, biggest loser, concentration flag.
  signals,

  /// Search/toolbar + the holdings table (flat or grouped-by-account).
  holdings,
}

class PortfolioCard extends StatefulWidget {
  /// Which slice of the portfolio this instance renders. Defaults to
  /// [PortfolioSection.holdings] so older single-card call sites keep working.
  final PortfolioSection section;
  final Map<String, dynamic> portfolioData;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final String targetCurrency;
  final double usdMxnRate;
  /// Optional category filter pushed in from the AllocationHeatmap above.
  /// When non-null, only holdings whose category (or sub-category) match
  /// pass through into the table.
  final String? categoryFilter;
  /// Tap handler for clearing the active category filter via a chip on
  /// top of the holdings table.
  final VoidCallback? onClearCategoryFilter;
  /// Externally-driven search override (Cmd-K deep-link). When this prop
  /// changes to a non-empty value, the card's internal search query is
  /// seeded to it so a single holding can be deep-linked from the
  /// palette without user typing.
  final String? searchOverride;

  const PortfolioCard({
    super.key,
    this.section = PortfolioSection.holdings,
    required this.portfolioData,
    required this.conversionFactor,
    required this.currencyFormat,
    required this.targetCurrency,
    required this.usdMxnRate,
    this.categoryFilter,
    this.onClearCategoryFilter,
    this.searchOverride,
  });

  @override
  State<PortfolioCard> createState() => _PortfolioCardState();
}

class _PortfolioCardState extends State<PortfolioCard> {
  int? _sortColumnIndex = 3; // Default sort by Value
  bool _isAscending = false;
  late List<dynamic> _allHoldings;
  late List<dynamic> _holdings;
  String _searchQuery = '';
  bool _groupByAccount = false;
  // Holdings shown before the "show all" expander. Capping the rows that are
  // actually built (vs. a nested scrollable ListView) is what keeps canvaskit
  // from re-rastering the whole table on every page-scroll frame.
  bool _showAllHoldings = false;
  static const _kHoldingsPreview = 12;

  // Mirror for the externally-pushed search query; we track it
  // separately from `_searchQuery` so user typing still wins after a
  // deep-link push and doesn't get re-applied on every rebuild.
  String? _appliedOverride;

  late final TextEditingController _searchController =
      TextEditingController();

  @override
  void initState() {
    super.initState();
    _groupByAccount = Preferences.getGroupByAccount();
    _allHoldings = List.from(widget.portfolioData['holdings'] ?? []);
    _holdings = List.from(_allHoldings);
    _sort(3, false);
    if (widget.searchOverride != null && widget.searchOverride!.isNotEmpty) {
      _searchQuery = widget.searchOverride!;
      _searchController.text = widget.searchOverride!;
      _appliedOverride = widget.searchOverride;
      _applySearch();
    }
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(PortfolioCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.portfolioData != oldWidget.portfolioData ||
        widget.conversionFactor != oldWidget.conversionFactor ||
        widget.categoryFilter != oldWidget.categoryFilter) {
      _allHoldings = List.from(widget.portfolioData['holdings'] ?? []);
      _applySearch();
      _sort(_sortColumnIndex ?? 3, _isAscending);
    }
    // A new override (different from the last one we applied) seeds the
    // search field so the deep-link surfaces the row immediately.
    if (widget.searchOverride != null &&
        widget.searchOverride!.isNotEmpty &&
        widget.searchOverride != _appliedOverride) {
      _searchQuery = widget.searchOverride!;
      _searchController.text = widget.searchOverride!;
      _appliedOverride = widget.searchOverride;
      _applySearch();
      _sort(_sortColumnIndex ?? 3, _isAscending);
    }
  }

  void _applySearch() {
    final q = _searchQuery.toLowerCase().trim();
    final catFilter = widget.categoryFilter?.toLowerCase().trim() ?? '';
    bool matchesCat(Map h) {
      if (catFilter.isEmpty) return true;
      // The allocation card can filter by asset class, account type, or
      // institution; the tapped raw value matches whichever field the
      // holding carries (value spaces don't collide). Keep category /
      // sub_category too for backwards compatibility.
      final ht = (h['holding_type'] ?? '').toString().toLowerCase();
      final at = (h['account_type'] ?? '').toString().toLowerCase();
      final inst = (h['institution_name'] ?? '').toString().toLowerCase();
      final cat = (h['category'] ?? '').toString().toLowerCase();
      final sub = (h['sub_category'] ?? '').toString().toLowerCase();
      return ht == catFilter ||
          at == catFilter ||
          inst == catFilter ||
          cat == catFilter ||
          sub == catFilter;
    }

    final base = _allHoldings.where((h) => matchesCat(h as Map)).toList();
    if (q.isEmpty) {
      _holdings = base;
    } else {
      _holdings = base.where((h) {
        final sym = (h['symbol'] ?? '').toString().toLowerCase();
        final name = (h['name'] ?? '').toString().toLowerCase();
        final inst = (h['institution_name'] ?? '').toString().toLowerCase();
        final acct = (h['account_name'] ?? '').toString().toLowerCase();
        return sym.contains(q) ||
            name.contains(q) ||
            inst.contains(q) ||
            acct.contains(q);
      }).toList();
    }
  }

  void _sort(int columnIndex, bool ascending) {
    setState(() {
      _sortColumnIndex = columnIndex;
      _isAscending = ascending;

      // Cost basis / gain / return can be null when the institution
      // doesn't report a basis. Unknown sorts LAST regardless of
      // direction: the comparator below compares ascending on
      // (possibly swapped) values, so mapping null to +inf when
      // ascending and -inf when descending pins it to the bottom.
      double unknownLast(num? v) => v?.toDouble() ??
          (ascending ? double.infinity : double.negativeInfinity);

      _holdings.sort((a, b) {
        dynamic valA;
        dynamic valB;

        switch (columnIndex) {
          case 0:
            valA = a['symbol']?.toString() ?? '';
            valB = b['symbol']?.toString() ?? '';
            break;
          case 1:
            valA = (a['quantity'] as num?)?.toDouble() ?? 0.0;
            valB = (b['quantity'] as num?)?.toDouble() ?? 0.0;
            break;
          case 2:
            valA = (a['price'] as num?)?.toDouble() ?? 0.0;
            valB = (b['price'] as num?)?.toDouble() ?? 0.0;
            break;
          case 3:
            valA = (a['value'] as num?)?.toDouble() ?? 0.0;
            valB = (b['value'] as num?)?.toDouble() ?? 0.0;
            break;
          case 4:
            valA = unknownLast(a['cost_basis'] as num?);
            valB = unknownLast(b['cost_basis'] as num?);
            break;
          case 5:
            valA = unknownLast(a['gain_loss'] as num?);
            valB = unknownLast(b['gain_loss'] as num?);
            break;
          case 6:
            valA = unknownLast(a['gain_loss_pct'] as num?);
            valB = unknownLast(b['gain_loss_pct'] as num?);
            break;
          default:
            valA = 0;
            valB = 0;
        }

        if (!ascending) {
          final temp = valA;
          valA = valB;
          valB = temp;
        }

        return Comparable.compare(valA as Comparable, valB as Comparable);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    switch (widget.section) {
      case PortfolioSection.summary:
        return _buildSummaryCard(context);
      case PortfolioSection.signals:
        return _buildSignalsCard(context);
      case PortfolioSection.holdings:
        return _buildHoldingsCard(context);
    }
  }

  /// Overview slice: hero total value + change badge, headline KPIs, and the
  /// dual-currency panel.
  Widget _buildSummaryCard(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Use the USD-normalised totals, not `total_value`/`total_gain_loss` which
    // are raw native sums (USD equities + MXN bonds added 1:1 — the backend
    // flags them as "meaningless when mixing USD + MXN"). conversionFactor then
    // scales the USD figure into the display currency.
    final totalValueUsd =
        (widget.portfolioData['total_value_usd'] as num?)?.toDouble() ?? 0.0;
    final totalGainLossUsd =
        (widget.portfolioData['total_gain_loss_usd'] as num?)?.toDouble() ?? 0.0;
    final totalCostBasisUsd =
        (widget.portfolioData['total_cost_basis_usd'] as num?)?.toDouble() ??
        0.0;
    final totalValue = totalValueUsd * widget.conversionFactor;
    final totalGainLoss = totalGainLossUsd * widget.conversionFactor;
    // Percentage is currency-agnostic, but must come from USD figures so the
    // mixed-currency native sums don't skew it.
    final totalGainLossPct =
        totalCostBasisUsd > 0 ? (totalGainLossUsd / totalCostBasisUsd) * 100 : 0.0;

    // The % above is a return on *cost basis*: its numerator/denominator only
    // cover holdings the institution reports a basis for. The value hero above
    // covers ALL holdings, so when some positions have a null basis (e.g. a
    // large GOOG lot from a statement import) the % is NOT a whole-portfolio
    // return. Sum the USD value over the basis-known rows — same predicate the
    // % uses (a holding contributes to total_gain_loss_usd iff gain_loss_usd is
    // non-null) — so the coverage we show reconciles with the % denominator.
    var coveredValueUsd = 0.0;
    var hasNullBasis = false;
    for (final h in _allHoldings) {
      final m = h as Map;
      if ((m['gain_loss_usd'] as num?) != null) {
        coveredValueUsd += (m['value_usd'] as num?)?.toDouble() ?? 0.0;
      } else {
        hasNullBasis = true;
      }
    }
    final coveredValue = coveredValueUsd * widget.conversionFactor;
    // Only worth qualifying the % when coverage is partial — when every holding
    // has a basis the % already describes the whole hero value.
    final showCoverage = hasNullBasis && _allHoldings.isNotEmpty;

    final isPositive = totalGainLoss >= 0;
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;

    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(builder: (context, c) {
              // Shrink the big total-value number so a long "USD 1,234,567.89"
              // still fits a phone-width card without wrapping or ellipsis.
              final heroFontSize = c.maxWidth < 400
                  ? 30.0
                  : c.maxWidth < 520
                      ? 36.0
                      : 42.0;
              final summary = Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.pfInvestmentPortfolio,
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                      color: context.textPrimary,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 20),
                  Text(
                    l.pfTotalValue,
                    style: TextStyle(
                      color: context.textSubtle,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                      letterSpacing: 0.4,
                    ),
                  ),
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      widget.currencyFormat.format(totalValue),
                      style: TextStyle(
                        fontSize: heroFontSize,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -1.0,
                        height: 1.1,
                        color: context.textPrimary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                      maxLines: 1,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color:
                          (isPositive ? context.positive : context.negative)
                              .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          isPositive
                              ? Icons.arrow_upward
                              : Icons.arrow_downward,
                          color: isPositive ? context.positive : context.negative,
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            '${isPositive ? '+' : ''}${widget.currencyFormat.format(totalGainLoss.abs())} (${totalGainLossPct.toStringAsFixed(2)}%)',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                              color:
                                  isPositive ? context.positive : context.negative,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (showCoverage) ...[
                    const SizedBox(height: 6),
                    Text(
                      l.pfReturnCoverage(
                        _compactMoney(coveredValue),
                        _compactMoney(totalValue),
                      ),
                      style: TextStyle(
                        color: context.textSubtle,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                        height: 1.3,
                      ),
                      maxLines: 2,
                    ),
                  ],
                ],
              );
              // The donut-by-holding chart was removed: it duplicated the
              // "Asset distribution" allocation card (two part-to-whole
              // encodings of the same data) and the holdings table. The hero
              // now owns the headline number + change; allocation lives in the
              // one allocation card, per-holding detail in the table below.
              return summary;
            }),
            const SizedBox(height: 24),
            _buildSummaryKpis(),
            const SizedBox(height: 16),
            _buildDualCurrencyPanel(),
          ],
        ),
      ),
    );
  }

  /// Abbreviates a display-currency amount as `$1.53M` / `$160.7K` so the
  /// return-coverage caption stays on one or two short lines. Reuses the
  /// hero formatter's currency symbol (so `$` vs `MXN ` follows the target
  /// currency) and falls back to the full formatter under $1K where an
  /// abbreviation would lose precision without saving space.
  String _compactMoney(double amount) {
    final symbol = widget.currencyFormat.currencySymbol;
    final abs = amount.abs();
    final sign = amount < 0 ? '-' : '';
    String body;
    if (abs >= 1e9) {
      body = '${(abs / 1e9).toStringAsFixed(2)}B';
    } else if (abs >= 1e6) {
      body = '${(abs / 1e6).toStringAsFixed(2)}M';
    } else if (abs >= 1e3) {
      body = '${(abs / 1e3).toStringAsFixed(1)}K';
    } else {
      return widget.currencyFormat.format(amount);
    }
    return '$sign$symbol$body';
  }

  /// Holdings slice: search/toolbar + the holdings table (flat or grouped).
  Widget _buildHoldingsCard(BuildContext context) {
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Theme(
          data: Theme.of(context).copyWith(
            cardTheme: CardThemeData(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
              ),
            ),
            dividerColor: context.hairline,
          ),
          child: _groupByAccount
              ? _buildGroupedHoldings()
              : _buildHoldingsTable(),
        ),
      ),
    );
  }

  /// Side-by-side "Total value" + "Profit / Loss" panel showing BOTH
  /// US Dollars (USD) and Mexican Pesos (MXN). For bi-national users,
  /// the single-currency hero above isn't enough — the same portfolio
  /// looks different in USD vs MXN depending on FX moves, and the
  /// backend now computes both numbers using per-lot historical FX
  /// rates (when `holding_lots` rows exist; current FX otherwise).
  ///
  /// Acronym key (spelled out in the UI label, not assumed):
  ///   USD = United States Dollar
  ///   MXN = Mexican Peso
  ///   P/L = Profit or Loss (also written as "Gain / Loss")
  Widget _buildDualCurrencyPanel() {
    final l = AppLocalizations.of(context);
    final data = widget.portfolioData;
    // Backend exposes these alongside the legacy `total_value` /
    // `total_gain_loss` (which are sums in native currency and don't
    // make sense across mixed USD+MXN portfolios).
    final valUsd = (data['total_value_usd'] as num?)?.toDouble();
    final valMxn = (data['total_value_mxn'] as num?)?.toDouble();
    final costUsd = (data['total_cost_basis_usd'] as num?)?.toDouble();
    final costMxn = (data['total_cost_basis_mxn'] as num?)?.toDouble();
    final glUsd = (data['total_gain_loss_usd'] as num?)?.toDouble();
    final glMxn = (data['total_gain_loss_mxn'] as num?)?.toDouble();
    // Backwards compat: if the backend hasn't been redeployed yet
    // the new fields are absent — skip the panel rather than render
    // half-empty boxes.
    if (valUsd == null || valMxn == null) {
      return const SizedBox.shrink();
    }
    // P/L % from the backend's gain/cost pair: both already exclude
    // holdings with an unknown cost basis, so dividing them keeps the
    // numerator and denominator consistent. (valUsd - costUsd would
    // mix the FULL portfolio value with a partial cost and inflate
    // the percentage.)
    final glPctUsd = (glUsd != null && costUsd != null && costUsd > 0)
        ? (glUsd / costUsd) * 100.0
        : 0.0;
    final glPctMxn = (glMxn != null && costMxn != null && costMxn > 0)
        ? (glMxn / costMxn) * 100.0
        : 0.0;

    final usdFmt = NumberFormat.currency(locale: 'en_US', symbol: '\$');
    final mxnFmt = NumberFormat.currency(locale: 'es_MX', symbol: 'MX\$');

    Widget tile({
      required String currencyTitle,
      required String currencySubtitle,
      required String totalValueStr,
      required double gainLoss,
      required String gainLossStr,
      required double gainLossPct,
    }) {
      final positive = gainLoss >= 0;
      return Expanded(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: context.tint(0.04),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.hairline),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Text(
                    currencyTitle,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: context.textPrimary,
                      letterSpacing: 0.3,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    currencySubtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: context.textSubtle,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                l.pfTotalValue,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: context.textSubtle,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                totalValueStr,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: context.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 8),
              Text(
                l.pfProfitLoss,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  color: context.textSubtle,
                  letterSpacing: 0.4,
                ),
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(
                    positive ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 12,
                    color: positive ? context.positive : context.negative,
                  ),
                  const SizedBox(width: 2),
                  Flexible(
                    child: Text(
                      '${positive ? '+' : ''}$gainLossStr (${gainLossPct.toStringAsFixed(2)}%)',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: positive ? context.positive : context.negative,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    }

    final usdTile = tile(
      currencyTitle: 'USD',
      currencySubtitle: l.pfUsDollar,
      totalValueStr: usdFmt.format(valUsd),
      gainLoss: glUsd ?? 0,
      gainLossStr: usdFmt.format((glUsd ?? 0).abs()),
      gainLossPct: glPctUsd,
    );
    final mxnTile = tile(
      currencyTitle: 'MXN',
      currencySubtitle: l.pfMexicanPeso,
      totalValueStr: mxnFmt.format(valMxn),
      gainLoss: glMxn ?? 0,
      gainLossStr: mxnFmt.format((glMxn ?? 0).abs()),
      gainLossPct: glPctMxn,
    );

    return LayoutBuilder(
      builder: (context, c) {
        final narrow = c.maxWidth < 520;
        if (narrow) {
          // Stack on phone widths — two tiles side-by-side are too
          // squeezed to fit the value + P/L numbers without
          // ellipsising. Vertical stack keeps the comparison readable.
          return Column(
            children: [
              Row(children: [usdTile]),
              const SizedBox(height: 8),
              Row(children: [mxnTile]),
            ],
          );
        }
        return Row(
          children: [
            usdTile,
            const SizedBox(width: 12),
            mxnTile,
          ],
        );
      },
    );
  }

  /// Ticker label for a holding, hiding Plaid `security_id` hashes by
  /// falling back to the security name. Shared by the summary KPIs and the
  /// signals strip.
  String _displayTicker(Map<String, dynamic> h) {
    final sym = (h['symbol'] ?? '').toString();
    final name = (h['name'] ?? '').toString();
    if (sym.length > 8 || (sym != sym.toUpperCase() && sym.length > 4)) {
      return name.isNotEmpty ? name : '—';
    }
    return sym.isEmpty ? (name.isNotEmpty ? name : '?') : sym;
  }

  /// The largest position (by value) plus the biggest gainer / loser by
  /// return %. Computed once and reused by the summary KPIs (top position)
  /// and the signals strip (movers + concentration).
  ({
    Map<String, dynamic>? top,
    Map<String, dynamic>? gainer,
    Map<String, dynamic>? loser,
  }) _computeMovers() {
    Map<String, dynamic>? top;
    Map<String, dynamic>? gainer;
    Map<String, dynamic>? loser;
    for (final h in _allHoldings) {
      // Rank by USD value so a large MXN position isn't ranked above a larger
      // USD one just because its native number is bigger.
      final v = (h['value_usd'] as num?)?.toDouble() ?? 0.0;
      if (top == null ||
          v > ((top['value_usd'] as num?)?.toDouble() ?? 0)) {
        top = h;
      }
      // Null return % means the institution didn't report a cost
      // basis — exclude those from the gainer/loser race instead of
      // letting an unknown masquerade as a 0% performer.
      final pct = (h['gain_loss_pct'] as num?)?.toDouble();
      if (pct == null) continue;
      if (gainer == null ||
          pct > ((gainer['gain_loss_pct'] as num?)?.toDouble() ?? 0)) {
        gainer = h;
      }
      if (loser == null ||
          pct < ((loser['gain_loss_pct'] as num?)?.toDouble() ?? 0)) {
        loser = h;
      }
    }
    return (top: top, gainer: gainer, loser: loser);
  }

  /// Top movers ranked by absolute USD profit / loss (dollar P&L), as
  /// opposed to [_computeMovers] which ranks by return %. A small high-%
  /// gainer on a tiny position can dominate the % race while moving the
  /// portfolio almost nothing; this surfaces the positions that actually
  /// shifted the dollar total. Holdings whose `gain_loss_usd` is null
  /// (institution reported no basis) are skipped — consistent with the
  /// null handling in [_computeMovers]. Returns the top [count] dollar
  /// gainers (gain_loss_usd > 0) descending and the top [count] dollar
  /// losers (gain_loss_usd < 0) ascending.
  ({List<Map<String, dynamic>> gainers, List<Map<String, dynamic>> losers})
      _computeDollarMovers({int count = 3}) {
    final withGl = <Map<String, dynamic>>[];
    for (final h in _allHoldings) {
      final gl = (h['gain_loss_usd'] as num?)?.toDouble();
      if (gl == null) continue;
      withGl.add(h as Map<String, dynamic>);
    }
    final sorted = List<Map<String, dynamic>>.from(withGl)
      ..sort((a, b) {
        final ga = (a['gain_loss_usd'] as num).toDouble();
        final gb = (b['gain_loss_usd'] as num).toDouble();
        return gb.compareTo(ga); // descending: biggest dollar gain first
      });
    final gainers = sorted
        .where((h) => (h['gain_loss_usd'] as num).toDouble() > 0)
        .take(count)
        .toList();
    // Losers: most-negative first. Reverse-iterate the descending list.
    final losers = sorted.reversed
        .where((h) => (h['gain_loss_usd'] as num).toDouble() < 0)
        .take(count)
        .toList();
    return (gainers: gainers, losers: losers);
  }

  /// Headline facts for the overview card: holdings count and top position.
  /// The biggest gainer/loser moved to the dedicated signals strip (which
  /// sits between allocation and holdings in the research flow).
  Widget _buildSummaryKpis() {
    if (_allHoldings.isEmpty) return const SizedBox.shrink();

    final l = AppLocalizations.of(context);
    final cf = widget.conversionFactor;
    final movers = _computeMovers();
    final top = movers.top;

    final tiles = <_KpiTile>[
      _KpiTile(
        label: l.pfHoldings,
        value: '${_allHoldings.length}',
        sub: l.pfAccountsCount(_allHoldings
            .map((h) => (h['account_name'] ?? '').toString())
            .toSet()
            .where((s) => s.isNotEmpty)
            .length),
      ),
      if (top != null)
        _KpiTile(
          label: l.pfTopPosition,
          value: _displayTicker(top),
          // USD-normalised: a native MXN value here read as "$300,000" for a
          // ~$17k position. value_usd → display via the conversion factor.
          sub: widget.currencyFormat
              .format(((top['value_usd'] as num?)?.toDouble() ?? 0.0) * cf),
          accent: context.tealAccent,
        ),
    ];

    return LayoutBuilder(builder: (ctx, c) {
      final perRow = c.maxWidth >= 520 ? 2 : 1;
      final tileWidth = (c.maxWidth - 12 * (perRow - 1)) / perRow;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children:
            tiles.map((t) => SizedBox(width: tileWidth, child: t)).toList(),
      );
    });
  }

  /// Signals slice: a thin, scannable strip surfacing the biggest gainer,
  /// the biggest loser, and a concentration flag when a single position is
  /// >=20% of the portfolio. These were previously buried in the KPI grid;
  /// the research flow wants them as their own quick-glance row between
  /// allocation and the holdings table.
  Widget _buildSignalsCard(BuildContext context) {
    if (_allHoldings.isEmpty) return const SizedBox.shrink();

    final l = AppLocalizations.of(context);
    final movers = _computeMovers();
    final gainer = movers.gainer;
    final loser = movers.loser;
    final top = movers.top;

    final gainerPct = (gainer?['gain_loss_pct'] as num?)?.toDouble() ?? 0.0;
    final loserPct = (loser?['gain_loss_pct'] as num?)?.toDouble() ?? 0.0;

    // Concentration is the single largest position's share of total value.
    // Both sides must be USD-normalised — mixing a native MXN numerator with a
    // mixed-currency denominator produced shares as high as 30x.
    final totalValueUsd =
        (widget.portfolioData['total_value_usd'] as num?)?.toDouble() ?? 0.0;
    final topValue = (top?['value_usd'] as num?)?.toDouble() ?? 0.0;
    final topShare = totalValueUsd > 0 ? topValue / totalValueUsd : 0.0;
    final concentrated = top != null && topShare >= 0.20;

    final chips = <Widget>[
      if (gainer != null && gainerPct > 0)
        _signalChip(
          icon: Icons.trending_up,
          color: context.positive,
          label: l.pfBiggestGainer,
          value: _displayTicker(gainer),
          trailing: '+${gainerPct.toStringAsFixed(2)}%',
        ),
      if (loser != null && loserPct < 0)
        _signalChip(
          icon: Icons.trending_down,
          color: context.negative,
          label: l.pfBiggestLoser,
          value: _displayTicker(loser),
          trailing: '${loserPct.toStringAsFixed(2)}%',
        ),
      if (concentrated)
        _signalChip(
          icon: Icons.warning_amber_rounded,
          color: context.warning,
          label: l.pfConcentrated,
          value: _displayTicker(top),
          trailing: '${(topShare * 100).toStringAsFixed(0)}%',
        ),
    ];

    // Top movers by absolute dollar P&L — the positions that actually
    // shifted the portfolio total (vs. the % race above, which a tiny
    // position can win). Built only when at least one holding reports a
    // basis; otherwise the section stays hidden.
    final dollarMovers = _computeDollarMovers();
    final hasDollarMovers =
        dollarMovers.gainers.isNotEmpty || dollarMovers.losers.isNotEmpty;

    // Nothing worth flagging (no winners/losers, well diversified, no
    // dollar movers) — render nothing rather than an empty card.
    if (chips.isEmpty && !hasDollarMovers) return const SizedBox.shrink();

    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.pfSignalsTitle,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
                color: context.textSubtle,
              ),
            ),
            if (chips.isNotEmpty) ...[
              const SizedBox(height: 10),
              LayoutBuilder(builder: (ctx, c) {
                // Side-by-side on wide screens, stacked on phone widths.
                final perRow = c.maxWidth >= 560 ? chips.length : 1;
                if (perRow == 1) {
                  return Column(
                    children: [
                      for (var i = 0; i < chips.length; i++) ...[
                        if (i > 0) const SizedBox(height: 8),
                        chips[i],
                      ],
                    ],
                  );
                }
                return Row(
                  children: [
                    for (var i = 0; i < chips.length; i++) ...[
                      if (i > 0) const SizedBox(width: 12),
                      Expanded(child: chips[i]),
                    ],
                  ],
                );
              }),
            ],
            if (hasDollarMovers) ...[
              const SizedBox(height: 16),
              _buildDollarMovers(dollarMovers.gainers, dollarMovers.losers),
            ],
          ],
        ),
      ),
    );
  }

  /// "Top movers (by \$)" mini-section: each holding's signed dollar P&L,
  /// scaled to the display currency via the conversion factor. Gainers
  /// (green, descending) and losers (red, most-negative first) sit in two
  /// stacked sub-lists. Empty sides are omitted.
  Widget _buildDollarMovers(
    List<Map<String, dynamic>> gainers,
    List<Map<String, dynamic>> losers,
  ) {
    final l = AppLocalizations.of(context);
    final cf = widget.conversionFactor;

    Widget moverRow(Map<String, dynamic> h, bool positive) {
      final glUsd = (h['gain_loss_usd'] as num).toDouble();
      final disp = glUsd * cf;
      final color = positive ? context.positive : context.negative;
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _displayTicker(h),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${positive ? '+' : ''}${widget.currencyFormat.format(disp)}',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      );
    }

    Widget moverColumn(
      String heading,
      IconData icon,
      Color color,
      List<Map<String, dynamic>> rows,
    ) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Icon(icon, size: 13, color: color),
              const SizedBox(width: 4),
              Text(
                heading,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                  color: context.textSubtle,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          ...rows.map((h) => moverRow(h, color == context.positive)),
        ],
      );
    }

    final columns = <Widget>[
      if (gainers.isNotEmpty)
        moverColumn(
          l.pfTopGainersByValue,
          Icons.trending_up,
          context.positive,
          gainers,
        ),
      if (losers.isNotEmpty)
        moverColumn(
          l.pfTopLosersByValue,
          Icons.trending_down,
          context.negative,
          losers,
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.pfTopMoversByValue,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.4,
            color: context.textSubtle,
          ),
        ),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (ctx, c) {
          // Two columns side-by-side on wide screens, stacked on phone.
          if (c.maxWidth >= 560 && columns.length == 2) {
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: columns[0]),
                const SizedBox(width: 12),
                Expanded(child: columns[1]),
              ],
            );
          }
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (var i = 0; i < columns.length; i++) ...[
                if (i > 0) const SizedBox(height: 12),
                columns[i],
              ],
            ],
          );
        }),
      ],
    );
  }

  /// One compact signal chip: a coloured icon, a small label, the subject
  /// (ticker), and a trailing figure (return % or concentration share).
  Widget _signalChip({
    required IconData icon,
    required Color color,
    required String label,
    required String value,
    required String trailing,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.20)),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                    color: context.textSubtle,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 1),
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            trailing.trim(),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  /// Collapses the holdings list into one section per account, with a
  /// per-account subtotal in the header. Sections are sorted by
  /// account total (descending) so the largest account leads.
  Widget _buildGroupedHoldings() {
    if (_holdings.isEmpty) {
      return _buildHoldingsTable(); // reuse empty state
    }
    final l = AppLocalizations.of(context);
    final byAccount = <String, List<dynamic>>{};
    for (final h in _holdings) {
      final acct = (h['account_name'] ?? l.pfUnknown).toString();
      byAccount.putIfAbsent(acct, () => []).add(h);
    }
    final entries = byAccount.entries.toList()
      ..sort((a, b) {
        final sa = a.value.fold<double>(
            0,
            (s, h) =>
                s + ((h['value'] as num?)?.toDouble() ?? 0.0));
        final sb = b.value.fold<double>(
            0,
            (s, h) =>
                s + ((h['value'] as num?)?.toDouble() ?? 0.0));
        return sb.compareTo(sa);
      });

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildSearchAndToolbar(),
        const SizedBox(height: 12),
        ...entries.map((entry) {
          final acct = entry.key;
          final list = List.from(entry.value);
          list.sort((a, b) {
            final va = ((a['value'] as num?)?.toDouble() ?? 0.0);
            final vb = ((b['value'] as num?)?.toDouble() ?? 0.0);
            return vb.compareTo(va);
          });
          final subtotal = list.fold<double>(
              0,
              (s, h) =>
                  s + ((h['value'] as num?)?.toDouble() ?? 0.0)) *
              widget.conversionFactor;
          final inst =
              (list.first['institution_name'] ?? '').toString();
          return Container(
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: context.tint(0.02),
              borderRadius: BorderRadius.circular(12),
              border:
                  Border.all(color: context.tint(0.05)),
            ),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            maskAwareNameText(
                              acct,
                              TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: context.textPrimary,
                              ),
                            ),
                            if (inst.isNotEmpty)
                              Text(
                                l.pfInstPositions(inst, list.length),
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
                      const SizedBox(width: 12),
                      Text(
                        widget.currencyFormat.format(subtotal),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: context.textPrimary,
                          fontFeatures: [const FontFeature.tabularFigures()],
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(color: context.hairline, height: 1),
                ...list.map((h) => _buildCompactHoldingRow(h)),
              ],
            ),
          );
        }),
      ],
    );
  }

  /// Compact row used by the grouped-by-account view. Single line, no
  /// table chrome — just ticker, qty, value, return.
  Widget _buildCompactHoldingRow(dynamic h) {
    final l = AppLocalizations.of(context);
    final cf = widget.conversionFactor;
    final qty = (h['quantity'] as num?)?.toDouble() ?? 0.0;
    final value = ((h['value'] as num?)?.toDouble() ?? 0.0) * cf;
    // Null when the institution doesn't report a cost basis — render
    // a muted em dash, never a fake green "+0.00%".
    final pct = (h['gain_loss_pct'] as num?)?.toDouble();
    final isGain = (pct ?? 0) >= 0;
    final rawSym = (h['symbol'] ?? '').toString();
    final rawName = (h['name'] ?? '').toString();
    final opaque = rawSym.length > 8 ||
        (rawSym != rawSym.toUpperCase() && rawSym.length > 4);
    final displaySymbol = opaque
        ? (rawName.isNotEmpty ? rawName : '—')
        : (rawSym.isEmpty ? (rawName.isNotEmpty ? rawName : '?') : rawSym);

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Tooltip(
              message: rawName.isNotEmpty ? rawName : displaySymbol,
              waitDuration: const Duration(milliseconds: 600),
              child: Text(
                displaySymbol,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: context.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          Expanded(
            flex: 2,
            child: Text(
              l.pfSharesSuffix(_formatQuantity(qty)),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 12,
                color: context.textMuted,
                fontFeatures: [const FontFeature.tabularFigures()],
              ),
            ),
          ),
          Expanded(
            flex: 3,
            child: Text(
              widget.currencyFormat.format(value),
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: context.textPrimary,
                fontFeatures: [const FontFeature.tabularFigures()],
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 64,
            child: pct == null
                ? Tooltip(
                    message: l.pfCostBasisUnavailable,
                    waitDuration: const Duration(milliseconds: 600),
                    child: Text(
                      '—',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: context.textMuted,
                      ),
                    ),
                  )
                : Text(
                    '${isGain ? '+' : ''}${pct.toStringAsFixed(2)}%',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: isGain ? context.positive : context.negative,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  /// Search field + group/flat toggle. Used by both renderers.
  Widget _buildSearchAndToolbar() {
    final l = AppLocalizations.of(context);
    final totalHoldings = _allHoldings.length;
    final shownHoldings = _holdings.length;
    final accountCount = _allHoldings
        .map((h) => (h['account_name'] ?? '').toString())
        .toSet()
        .where((s) => s.isNotEmpty)
        .length;

    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (widget.categoryFilter != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: InputChip(
                  avatar: const Icon(Icons.filter_alt, size: 16),
                  label: Text(
                      l.pfCategoryFilter(widget.categoryFilter ?? ''),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis),
                  onDeleted: widget.onClearCategoryFilter,
                  backgroundColor: context.tint(0.06),
                ),
              ),
            ),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: TextField(
                controller: _searchController,
                onChanged: (v) => setState(() {
                  _searchQuery = v;
                  _applySearch();
                  _sort(_sortColumnIndex ?? 3, _isAscending);
                }),
                decoration: InputDecoration(
                  hintText: l.pfSearchHint,
                  hintStyle: TextStyle(
                      color: context.textSubtle, fontSize: 13),
                  prefixIcon: Icon(
                    Icons.search,
                    size: 18,
                    color: context.textSubtle,
                  ),
                  filled: true,
                  fillColor: context.tint(0.05),
                  contentPadding: const EdgeInsets.symmetric(
                      vertical: 0, horizontal: 12),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                style: const TextStyle(fontSize: 13),
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _searchQuery.isEmpty
                ? l.pfHoldingsAccountsCount(totalHoldings, accountCount)
                : l.pfShownOfTotal(shownHoldings, totalHoldings),
            style: TextStyle(fontSize: 12, color: context.textSubtle),
          ),
          const SizedBox(width: 12),
          SegmentedButton<bool>(
            segments: [
              ButtonSegment(
                value: false,
                icon: const Icon(Icons.list_alt, size: 14),
                label: Text(l.pfFlat),
              ),
              ButtonSegment(
                value: true,
                icon: const Icon(Icons.account_tree_outlined, size: 14),
                label: Text(l.pfByAccount),
              ),
            ],
            selected: {_groupByAccount},
            onSelectionChanged: (s) {
              setState(() => _groupByAccount = s.first);
              Preferences.setGroupByAccount(s.first);
            },
            style: ButtonStyle(
              visualDensity: VisualDensity.compact,
              textStyle: WidgetStateProperty.all(
                  const TextStyle(fontSize: 12)),
            ),
          ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildHoldingsTable() {
    final l = AppLocalizations.of(context);
    if (_holdings.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildSearchAndToolbar(),
          const SizedBox(height: 12),
          Padding(
            padding: const EdgeInsets.all(48.0),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.show_chart, size: 56, color: Colors.grey.shade700),
                  const SizedBox(height: 16),
                  Text(
                    l.pfNoHoldingsYet,
                    style: TextStyle(
                      fontSize: 16,
                      color: context.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    l.pfNoHoldingsBody,
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade500),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final available = constraints.maxWidth;

        // Rows flow in the page's single scroll view rather than a nested
        // fixed-height ListView+Scrollbar. The old nested same-axis scroll
        // made canvaskit re-raster the inner viewport on every page-scroll
        // frame, stalling the renderer (the "Portfolio freeze"). We instead
        // build only the first N rows by default and let the user expand —
        // details-on-demand, and a much lighter scene.
        final showAll =
            _showAllHoldings || _holdings.length <= _kHoldingsPreview;
        final visibleHoldings =
            showAll ? _holdings : _holdings.sublist(0, _kHoldingsPreview);

        final expander = _holdings.length > _kHoldingsPreview
            ? Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () =>
                      setState(() => _showAllHoldings = !_showAllHoldings),
                  child: Text(showAll
                      ? l.pfHoldingsShowFewer
                      : l.pfHoldingsShowAll(_holdings.length)),
                ),
              )
            : null;

        final Widget body;
        if (available < _kMobileBreakpoint) {
          // Mobile: a 7-column table can't fit a phone without a sideways
          // scroll the thumb can't reach. Collapse each row to the three
          // facts that matter at a glance — name, value, change — and let a
          // tap reveal shares/price/cost/gain (details-on-demand).
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final h in visibleHoldings)
                _MobileHoldingRow(
                  holding: h,
                  format: widget.currencyFormat,
                  targetCurrency: widget.targetCurrency,
                  usdMxnRate: widget.usdMxnRate,
                ),
              ?expander,
            ],
          );
        } else {
          // Use the larger of (natural width, available) so on wide screens
          // we don't leave a giant gap on the right.
          final tableWidth = available > _kTableNaturalWidth
              ? available
              : _kTableNaturalWidth;
          final table = SizedBox(
            width: tableWidth,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildTableHeader(),
                Divider(color: context.hairline, height: 1, thickness: 1),
                ...visibleHoldings.map((h) => SizedBox(
                      height: _kRowHeight,
                      child: _HoldingRowTile(
                        holding: h,
                        format: widget.currencyFormat,
                        targetCurrency: widget.targetCurrency,
                        usdMxnRate: widget.usdMxnRate,
                      ),
                    )),
                ?expander,
              ],
            ),
          );

          // Horizontal scroll only when the viewport is narrower than the
          // table's natural width (but still above the mobile breakpoint).
          body = available < _kTableNaturalWidth
              ? SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: table,
                )
              : table;
        }

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildSearchAndToolbar(),
            const SizedBox(height: 12),
            // Cache the table as its own layer so page-scroll frames don't
            // re-raster every row (a chunk of the old "Portfolio freeze").
            RepaintBoundary(child: body),
          ],
        );
      },
    );
  }

  /// Click-to-sort header row. First click on a new column sorts ascending,
  /// subsequent clicks toggle direction. Matches PaginatedDataTable behavior.
  Widget _buildTableHeader() {
    final l = AppLocalizations.of(context);
    Widget label(String text, int colIndex, {bool numeric = true}) {
      final active = _sortColumnIndex == colIndex;
      return InkWell(
        onTap: () {
          if (_sortColumnIndex == colIndex) {
            _sort(colIndex, !_isAscending);
          } else {
            _sort(colIndex, true);
          }
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 12),
          child: Align(
            alignment:
                numeric ? Alignment.centerRight : Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  text,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: active ? context.textPrimary : context.textMuted,
                  ),
                ),
                if (active) ...[
                  const SizedBox(width: 4),
                  Icon(
                    _isAscending ? Icons.arrow_upward : Icons.arrow_downward,
                    size: 12,
                    color: context.positive,
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    return _tableRow(
      asset: label(l.pfColAsset, 0, numeric: false),
      shares: label(l.pfColShares, 1),
      price: label(l.pfColPrice, 2),
      value: label(l.pfColValue, 3),
      costBasis: label(l.pfColCostBasis, 4),
      gain: label(l.pfColGain, 5),
      returnPct: label(l.pfColReturn, 6),
    );
  }

}

/// Trim trailing zeros and pick a sensible precision based on the
/// magnitude of the share count: integers stay integer, normal lots
/// show 2 decimals, fractional crypto-style holdings keep 4.
String _formatQuantity(double q) {
  if (q == q.roundToDouble() && q.abs() < 1e9) {
    return q.toInt().toString();
  }
  if (q.abs() >= 1) {
    return q
        .toStringAsFixed(2)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
  }
  return q
      .toStringAsFixed(4)
      .replaceAll(RegExp(r'0+$'), '')
      .replaceAll(RegExp(r'\.$'), '');
}

// Layout constants for the virtualized holdings table. Header and body
// share the same column widths so they line up visually as the user
// scrolls. The natural width sits around 1080; below that the table
// scrolls horizontally instead of squeezing columns.
const double _kRowHeight = 60.0;
const double _kTableNaturalWidth = 1080.0;
// Below this viewport width the wide 7-column table collapses to the
// tap-to-expand mobile row (name + value + change).
const double _kMobileBreakpoint = 560.0;
const double _kHMargin = 20.0;
const double _kColShares = 100.0;
const double _kColPrice = 124.0;
const double _kColValue = 152.0;
const double _kColCost = 132.0;
const double _kColGain = 140.0;
const double _kColReturn = 108.0;

/// Shared row layout used by the header and every body row. Asset takes
/// the remaining space; numeric columns are fixed width so values line
/// up vertically.
Widget _tableRow({
  required Widget asset,
  required Widget shares,
  required Widget price,
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
class _HoldingRowTile extends StatefulWidget {
  final dynamic holding;
  final NumberFormat format;
  final String targetCurrency;
  final double usdMxnRate;

  const _HoldingRowTile({
    required this.holding,
    required this.format,
    required this.targetCurrency,
    required this.usdMxnRate,
  });

  @override
  State<_HoldingRowTile> createState() => _HoldingRowTileState();
}

class _HoldingRowTileState extends State<_HoldingRowTile> {
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
    final basisUnavailableMsg =
        AppLocalizations.of(context).pfCostBasisUnavailable;

    final rawSymbol = (h['symbol'] ?? '').toString();
    final rawName = (h['name'] ?? '').toString();
    final acctName = (h['account_name'] ?? '').toString();
    final instName = (h['institution_name'] ?? '').toString();
    // Plaid emits opaque security_ids (e.g. "3mg4qV4JZycPL4qeZgB...") for
    // un-tickered Vanguard mutual funds. Real tickers are short and upper-
    // case; security_ids are long and mixed-case.
    final isOpaqueSecurityId = rawSymbol.length > 8 ||
        (rawSymbol != rawSymbol.toUpperCase() && rawSymbol.length > 4);
    final displaySymbol = isOpaqueSecurityId
        ? (rawName.isNotEmpty ? rawName : '—')
        : (rawSymbol.isEmpty
            ? (rawName.isNotEmpty ? rawName : '?')
            : rawSymbol);
    // Secondary line: security name (when it isn't already the display
    // symbol), institution, and account — joined with bullets. Surfacing
    // `account_name` lets users with positions split across several
    // brokerages tell them apart at a glance.
    final secondaryParts = <String>[
      if (!isOpaqueSecurityId && rawName.isNotEmpty) rawName,
      if (instName.isNotEmpty) instName,
      if (acctName.isNotEmpty && acctName != instName) acctName,
    ];
    final secondaryLabel = secondaryParts.join(' · ');
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
                Text(
                  secondaryLabel,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
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
          _formatQuantity(quantity),
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
              fontFeatures: [const FontFeature.tabularFigures()],
            ),
          ),
      ],
    );

    final valueCell = Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          widget.format.format(value),
          style: const TextStyle(
            fontWeight: FontWeight.w700,
            fontSize: 14,
            fontFeatures: [FontFeature.tabularFigures()],
          ),
        ),
        if (sourceCurrency != widget.targetCurrency)
          Text(
            formatCurrencyAmount(sourceValue, sourceCurrency),
            style: TextStyle(
              fontSize: 10,
              color: context.textFaint,
              fontFeatures: [const FontFeature.tabularFigures()],
            ),
          ),
      ],
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
              widget.format.format(costBasis),
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
              '${isGain ? '+' : ''}${widget.format.format(gainConverted)}',
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
                '${isGain ? '+' : ''}${gainPct.toStringAsFixed(2)}%',
                style: TextStyle(
                  color: isGain ? context.positive : context.negative,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
    );

    final lots = (h['lots'] as List?) ?? const [];
    final hasLots = lots.isNotEmpty;
    // Even without per-lot data, an investment holding that reports a flat
    // cost basis can open the drill-down — it shows the flat basis plus a
    // note that the institution didn't report acquisition dates. Cash-like
    // rows (no lots, no basis) stay non-interactive.
    final canDrillDown = hasLots || costBasisSource != null;

    return MouseRegion(
      cursor: canDrillDown ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: InkWell(
        // Tap-to-expand: fires when there's a lot breakdown OR a flat cost
        // basis to show. Non-investment holdings with neither show no
        // clickable affordance. InkWell (over GestureDetector) makes the
        // row keyboard-focusable and Enter/Space-activatable for
        // screen-reader users.
        onTap: canDrillDown
            ? () => showLotBreakdown(context, widget.holding)
            : null,
        child: Container(
          color:
              _hover ? context.tint(0.05) : Colors.transparent,
          child: _tableRow(
            asset: asset,
            shares: shares,
            price: priceCell,
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
    final title =
        symbol.isNotEmpty ? symbol : (name.isNotEmpty ? name : l.pfHolding);

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
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720, maxHeight: 560),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(24, 22, 16, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l.pfLotBreakdownTitle(title),
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                                color: context.textPrimary,
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
                          Icon(Icons.info_outline,
                              size: 16, color: context.textSubtle),
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
                  else ...[
                  // Column header. Six columns, fixed grid so the body
                  // rows align on a quick scan.
                  Row(
                    children: [
                      _lotHeader(context, l.pfLotAcquired, flex: 3),
                      _lotHeader(context, l.pfLotQty,
                          flex: 2, alignRight: true),
                      _lotHeader(context, l.pfLotCostPerUnit,
                          flex: 3, alignRight: true),
                      _lotHeader(context, l.pfLotCurrentValue,
                          flex: 3, alignRight: true),
                      _lotHeader(context, l.pfLotUsdCost,
                          flex: 3, alignRight: true),
                      _lotHeader(context, l.pfLotTerm, flex: 2, alignRight: true),
                    ],
                  ),
                  Divider(height: 12, color: context.hairline),
                  Flexible(
                    child: ListView.separated(
                      shrinkWrap: true,
                      itemCount: lots.length,
                      separatorBuilder: (_, _) =>
                          Divider(height: 1, color: context.hairline.withValues(alpha: 0.5)),
                      itemBuilder: (_, i) {
                        final lot = lots[i] as Map;
                        final acquired = (lot['acquired_at'] ?? '').toString();
                        DateTime? date;
                        if (acquired.isNotEmpty) {
                          date = DateTime.tryParse(acquired);
                        }
                        final qty = (lot['qty'] as num?)?.toDouble() ?? 0.0;
                        final cpu = (lot['cost_per_unit'] as num?)?.toDouble() ?? 0.0;
                        final ccy = (lot['currency'] ?? 'USD').toString();
                        final usdCost = (lot['usd_cost'] as num?)?.toDouble() ?? 0.0;
                        // Current value of the lot = qty × current native
                        // price. Falls back to an em dash when the price is
                        // missing (0) so we don't render a fake "$0.00".
                        final currentVal = qty * currentPrice;
                        // Long-term = held at least one calendar year. Uses
                        // the calendar rule (now on/after the same M/D one year
                        // later) rather than a 365-day count so it matches the
                        // tax module across leap years. Only computed when the
                        // acquisition date parsed; unknown shows an em dash.
                        final isLongTerm = date != null &&
                            !now.isBefore(DateTime(
                              date.year + 1,
                              date.month,
                              date.day,
                            ));
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Row(
                            children: [
                              _lotCell(
                                context,
                                date != null ? dateFmt.format(date) : acquired,
                                flex: 3,
                              ),
                              _lotCell(
                                context,
                                qty.toStringAsFixed(qty == qty.roundToDouble() ? 0 : 4),
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
                                      : _lotTermBadge(context, isLongTerm),
                                ),
                              ),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _lotHeader(BuildContext context, String text,
      {int flex = 1, bool alignRight = false}) {
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

  Widget _lotCell(BuildContext context, String text,
      {int flex = 1,
      bool alignRight = false,
      bool bold = false,
      bool muted = false}) {
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
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: color,
      ),
    ),
  );
}

/// Phone-width holding row: collapses to the three facts that matter at a
/// glance — name, value, change — and reveals shares / price / cost basis /
/// gain (and a lot breakdown, when lots exist) on tap. Replaces the wide
/// 7-column table below [_kMobileBreakpoint], where a sideways scroll the
/// thumb can't reach isn't a usable interaction.
class _MobileHoldingRow extends StatefulWidget {
  final dynamic holding;
  final NumberFormat format;
  final String targetCurrency;
  final double usdMxnRate;

  const _MobileHoldingRow({
    required this.holding,
    required this.format,
    required this.targetCurrency,
    required this.usdMxnRate,
  });

  @override
  State<_MobileHoldingRow> createState() => _MobileHoldingRowState();
}

class _MobileHoldingRowState extends State<_MobileHoldingRow> {
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
    final value = _conv((h['value'] as num?)?.toDouble() ?? 0.0, sourceCurrency);
    final price = _conv((h['price'] as num?)?.toDouble() ?? 0.0, sourceCurrency);
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
    final isOpaqueSecurityId = rawSymbol.length > 8 ||
        (rawSymbol != rawSymbol.toUpperCase() && rawSymbol.length > 4);
    final displaySymbol = isOpaqueSecurityId
        ? (rawName.isNotEmpty ? rawName : '—')
        : (rawSymbol.isEmpty
            ? (rawName.isNotEmpty ? rawName : '?')
            : rawSymbol);
    final secondaryParts = <String>[
      if (!isOpaqueSecurityId && rawName.isNotEmpty) rawName,
      if (instName.isNotEmpty) instName,
      if (acctName.isNotEmpty && acctName != instName) acctName,
    ];
    final secondaryLabel = secondaryParts.join(' · ');

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
                      if (secondaryLabel.isNotEmpty)
                        Text(
                          secondaryLabel,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
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
                      widget.format.format(value),
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
                        '${isGain ? '+' : ''}${gainPct.toStringAsFixed(2)}%',
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
                _detailRow(l.pfColShares, _formatQuantity(quantity)),
                _detailRow(l.pfColPrice, widget.format.format(price)),
                _detailRow(
                  l.pfColCostBasis,
                  costBasis == null ? '—' : widget.format.format(costBasis),
                  color: costBasis == null ? context.textMuted : null,
                  tooltip: costBasis == null ? l.pfCostBasisUnavailable : null,
                ),
                _detailRow(
                  l.pfColGain,
                  gainConverted == null
                      ? '—'
                      : '${isGain ? '+' : ''}${widget.format.format(gainConverted)}',
                  color: gainConverted == null
                      ? context.textMuted
                      : (isGain ? context.positive : context.negative),
                  tooltip:
                      gainConverted == null ? l.pfCostBasisUnavailable : null,
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

  Widget _detailRow(String label, String value,
      {Color? color, String? tooltip}) {
    Widget valueText = Text(
      value,
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
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 12, color: context.textSubtle),
          ),
          valueText,
        ],
      ),
    );
  }
}

class _KpiTile extends StatelessWidget {
  final String label;
  final String value;
  final String? sub;
  final Color? accent;

  const _KpiTile({
    required this.label,
    required this.value,
    this.sub,
    this.accent,
  });

  @override
  Widget build(BuildContext context) {
    final c = accent ?? context.textSubtle;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: context.tint(0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.tint(0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: c,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                    color: context.textMuted,
                    letterSpacing: 0.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: context.textPrimary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (sub != null) ...[
            const SizedBox(height: 2),
            Text(
              sub!,
              style: TextStyle(
                fontSize: 11,
                color: context.tint(0.55),
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }
}

/// Portfolio-wide dividend income, from `/dashboard/holdings/dividends`.
///
/// Aggregates the per-symbol dividend engine across every active account into
/// a projected annual income, a blended yield-on-value, the top payers, and
/// the next estimated ex-dates. Self-fetching (like [RealizedGainsCard]) and
/// renders nothing when the user holds no dividend payers, so it stays out of
/// the way for cash-only / non-paying portfolios.
class DividendIncomeCard extends StatefulWidget {
  final ApiService apiService;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const DividendIncomeCard({
    super.key,
    required this.apiService,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  @override
  State<DividendIncomeCard> createState() => _DividendIncomeCardState();
}

class _DividendIncomeCardState extends State<DividendIncomeCard> {
  bool _loading = true;
  Map<String, dynamic>? _data;
  // Top payers + upcoming ex-dates are both capped — this is a glanceable
  // income summary, not the full holdings table.
  static const _maxPayers = 5;
  static const _maxExDates = 4;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data = await widget.apiService.getPortfolioDividends();
      if (mounted) setState(() => _data = data);
    } catch (_) {
      // Swallow — the empty/collapsed render handles the failure case.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// USD figure scaled into the display currency, same pattern as the
  /// realized-gains and holdings cards.
  String _money(double usd) =>
      widget.currencyFormat.format(usd * widget.conversionFactor);

  @override
  Widget build(BuildContext context) {
    // Stay invisible until loaded, then hide entirely when the portfolio
    // earns no dividends (no payers / all fetches degraded to zero).
    if (_loading) return const SizedBox.shrink();
    final data = _data;
    if (data == null) return const SizedBox.shrink();

    final income =
        (data['projected_annual_income_usd'] as num?)?.toDouble() ?? 0.0;
    if (income <= 0) return const SizedBox.shrink();

    final l = AppLocalizations.of(context);
    final blendedYield = (data['blended_yield_pct'] as num?)?.toDouble();
    final fxStale = data['fx_stale'] == true;

    // Payers come back income-descending already; keep only the ones that
    // actually pay and cap the list for the glanceable summary.
    final payers = ((data['contributions'] as List<dynamic>?) ?? const [])
        .where((c) =>
            ((c as Map)['annual_income_usd'] as num?)?.toDouble() != null &&
            ((c['annual_income_usd'] as num).toDouble()) > 0)
        .toList();
    final upcoming =
        (data['upcoming_ex_dates'] as List<dynamic>?) ?? const [];

    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.payments_outlined,
                    color: context.tealAccent, size: 18),
                const SizedBox(width: 8),
                Text(
                  l.divCardTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: context.textPrimary,
                  ),
                ),
                if (fxStale) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: l.divFxStaleHint,
                    child: Icon(Icons.error_outline,
                        size: 15, color: context.warning),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _summaryTile(
                    l.divProjectedAnnual,
                    _money(income),
                    context.positive,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _summaryTile(
                    l.divBlendedYield,
                    blendedYield == null
                        ? '—'
                        : '${blendedYield.toStringAsFixed(2)}%',
                    context.textPrimary,
                  ),
                ),
              ],
            ),
            if (payers.isNotEmpty) ...[
              const SizedBox(height: 8),
              Divider(height: 24, color: context.hairline),
              Text(
                l.divTopPayers,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: context.textSubtle,
                ),
              ),
              const SizedBox(height: 8),
              ...payers
                  .take(_maxPayers)
                  .map((c) => _payerRow(c as Map<String, dynamic>)),
            ],
            if (upcoming.isNotEmpty) ...[
              const SizedBox(height: 8),
              Divider(height: 24, color: context.hairline),
              Text(
                l.divUpcomingExDates,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                  color: context.textSubtle,
                ),
              ),
              const SizedBox(height: 8),
              ...upcoming
                  .take(_maxExDates)
                  .map((e) => _exDateRow(e as Map<String, dynamic>)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _summaryTile(String label, String value, Color valueColor) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.tint(0.04),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: TextStyle(color: context.textMuted, fontSize: 12)),
          const SizedBox(height: 6),
          Text(
            value,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: valueColor,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  Widget _payerRow(Map<String, dynamic> c) {
    final l = AppLocalizations.of(context);
    final symbol = c['symbol']?.toString() ?? '';
    final incomeUsd = (c['annual_income_usd'] as num?)?.toDouble() ?? 0.0;
    final yieldPct = (c['yield_pct'] as num?)?.toDouble();
    final perYear = (c['per_year'] as num?)?.toInt() ?? 0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  symbol.isNotEmpty ? symbol : '—',
                  style: TextStyle(
                    color: context.textPrimary,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  yieldPct == null
                      ? l.divPaymentsPerYear(perYear)
                      : '${yieldPct.toStringAsFixed(2)}% · ${l.divPaymentsPerYear(perYear)}',
                  style: TextStyle(color: context.textFaint, fontSize: 11),
                ),
              ],
            ),
          ),
          Text(
            _money(incomeUsd),
            style: TextStyle(
              color: context.textPrimary,
              fontWeight: FontWeight.bold,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _exDateRow(Map<String, dynamic> e) {
    final symbol = e['symbol']?.toString() ?? '';
    final dateStr = e['est_next_ex_date']?.toString() ?? '';
    final parsed = DateTime.tryParse(dateStr);
    final dateLabel =
        parsed == null ? dateStr : DateFormat.yMMMd().format(parsed);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Expanded(
            child: Text(
              symbol.isNotEmpty ? symbol : '—',
              style: TextStyle(
                color: context.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            dateLabel,
            style: TextStyle(
              color: context.textMuted,
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
