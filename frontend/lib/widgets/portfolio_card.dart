import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/preferences.dart';
import '../theme/buttons.dart';
import '../utils/currency.dart';
import '../utils/mask_aware_name.dart';
import '../utils/movers.dart';
import '../utils/percent_format.dart';
import '../utils/portfolio_filter.dart';
import '../utils/quantity_format.dart';
import '../utils/theme_colors.dart';
import '../utils/url_opener.dart';
import 'connected_segments.dart';
import 'edge_faded_hscroll.dart';
import 'holding_row_tile.dart';
import 'instrument_detail_sheet.dart';
import 'kpi_tile.dart';
import 'mobile_holding_row.dart';

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

  /// Used by the holdings slice for the instrument detail sheet (contract
  /// C-F) and the CSV export URLs (contract C-E). Optional so the existing
  /// call sites keep compiling; when absent the card constructs its own —
  /// ApiService instances are stateless (the HTTP client and response
  /// cache are static and shared across every instance).
  final ApiService? apiService;

  /// Contract C3-D: awaited after the instrument sheet resolves `true`
  /// (the user set or cleared an asset-class override inside it), so the
  /// owner can re-fetch holdings + allocation and the table/bands reflect
  /// the new class without a reload. Null (the default) = no live refresh;
  /// the card compiles and runs standalone.
  final Future<void> Function()? onDataRefreshRequested;

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
    this.apiService,
    this.onDataRefreshRequested,
  });

  @override
  State<PortfolioCard> createState() => _PortfolioCardState();
}

class _PortfolioCardState extends State<PortfolioCard> {
  int? _sortColumnIndex = _kColIndexValue; // Default sort by Value
  bool _isAscending = false;

  /// See [PortfolioCard.apiService] — falls back to a private instance so
  /// call sites that don't pass one still get the sheet + CSV exports.
  late final ApiService _apiService = widget.apiService ?? ApiService();
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

  late final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _groupByAccount = Preferences.getGroupByAccount();
    _allHoldings = List.from(widget.portfolioData['holdings'] ?? []);
    _holdings = List.from(_allHoldings);
    _sort(_kColIndexValue, false);
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
      _sort(_sortColumnIndex ?? _kColIndexValue, _isAscending);
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
      _sort(_sortColumnIndex ?? _kColIndexValue, _isAscending);
    }
  }

  void _applySearch() {
    final q = _searchQuery.toLowerCase().trim();
    final base = _allHoldings
        .where(
          (h) => holdingMatchesCategoryFilter(h as Map, widget.categoryFilter),
        )
        .toList();
    if (q.isEmpty) {
      _holdings = base;
    } else {
      _holdings = base.where((h) {
        final sym = (h['symbol'] ?? '').toString().toLowerCase();
        final name = (h['name'] ?? '').toString().toLowerCase();
        final inst = (h['institution_name'] ?? '').toString().toLowerCase();
        final acct = (h['account_name'] ?? '').toString().toLowerCase();
        // Canonical asset class (contract C2) so typing "bonds" surfaces
        // the bond funds regardless of their ticker or fund name.
        final assetClass = (h['asset_class'] ?? '').toString().toLowerCase();
        return sym.contains(q) ||
            name.contains(q) ||
            inst.contains(q) ||
            acct.contains(q) ||
            assetClass.contains(q);
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
      double unknownLast(num? v) =>
          v?.toDouble() ??
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
          case _kColIndexDay:
            // Day change (contract C-B). Null for cash sleeves and opaque
            // symbols with no stored closes — those sort last in either
            // direction so the movers lead.
            valA = unknownLast(a['day_change_pct'] as num?);
            valB = unknownLast(b['day_change_pct'] as num?);
            break;
          case _kColIndexValue:
            valA = (a['value'] as num?)?.toDouble() ?? 0.0;
            valB = (b['value'] as num?)?.toDouble() ?? 0.0;
            break;
          case 5:
            valA = unknownLast(a['cost_basis'] as num?);
            valB = unknownLast(b['cost_basis'] as num?);
            break;
          case 6:
            valA = unknownLast(a['gain_loss'] as num?);
            valB = unknownLast(b['gain_loss'] as num?);
            break;
          case 7:
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
        (widget.portfolioData['total_gain_loss_usd'] as num?)?.toDouble() ??
        0.0;
    final totalCostBasisUsd =
        (widget.portfolioData['total_cost_basis_usd'] as num?)?.toDouble() ??
        0.0;
    final totalValue = totalValueUsd * widget.conversionFactor;
    final totalGainLoss = totalGainLossUsd * widget.conversionFactor;
    // Percentage is currency-agnostic, but must come from USD figures so the
    // mixed-currency native sums don't skew it.
    final totalGainLossPct = totalCostBasisUsd > 0
        ? (totalGainLossUsd / totalCostBasisUsd) * 100
        : 0.0;

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

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      // Width-responsive off the card's OWN constraint (inner LayoutBuilder,
      // per the skill rule), not MediaQuery — the card can be narrower than
      // the screen (outer tab padding, the 1600px clamp).
      child: LayoutBuilder(
        builder: (context, c) {
          // 688 ≈ the old 720 screen breakpoint minus the outer tab padding.
          final pad = c.maxWidth < 688 ? 16.0 : 24.0;
          // House ~420 phone breakpoint: compact chrome (overline title,
          // tighter section gaps, abbreviated change pills) on phone widths;
          // wider layouts are unchanged.
          final isPhone = c.maxWidth < 420;
          // Shrink the big total-value number so a long "USD 1,234,567.89"
          // still fits a phone-width card without wrapping or ellipsis.
          final heroFontSize = c.maxWidth < 400
              ? 30.0
              : c.maxWidth < 520
              ? 36.0
              : 42.0;
          // A1 (round 3, a11y): the value caption, hero figure and
          // change pills read as ONE labelled node — "Portfolio value
          // $X, all-time +$Y (+Z%), today +$W (+V%)" — instead of four
          // fragments. excludeSemantics folds the inner Texts away;
          // the pills' visual tooltips (overlay-based) are unaffected.
          // Explicit sign on the amount: losses must read "-$500.00", not a
          // red "$500.00" (the abs() strips the minus, so it's re-applied).
          final allTimeSign = totalGainLoss > 0
              ? '+'
              : totalGainLoss < 0
              ? '-'
              : '';
          final allTimeText =
              '$allTimeSign${widget.currencyFormat.displayMoney(totalGainLoss.abs())} (${formatPercent(context, totalGainLossPct, digits: 2)})';
          // Phones abbreviate the pill amount ("+$53.9K (50.36%)") so the
          // all-time + today pills fit ONE Wrap row instead of stacking.
          // Sign handling is identical to the full string above. The a11y
          // heroLabel below keeps the FULL-precision strings — only the
          // visual pill text compacts.
          final allTimePillText = isPhone
              ? '$allTimeSign${_compactMoney(totalGainLoss.abs())} (${formatPercent(context, totalGainLossPct, digits: 2)})'
              : allTimeText;
          final dayText = _dayChangeText();
          final heroLabel = [
            l.axPortfolioHero(
              widget.currencyFormat.displayMoney(totalValue),
              allTimeText,
            ),
            if (dayText != null) l.axHeroToday(dayText),
          ].join(', ');
          final summary = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header landmark so screen readers can jump to the card.
              // `container: true` per the round-2 lesson at the grouped
              // account header: without an explicit boundary the header
              // flag is absorbed by the CARD-level node and the whole
              // card announces as one giant heading.
              Semantics(
                container: true,
                header: true,
                child: Text(
                  l.pfInvestmentPortfolio,
                  // Phones: the bottom-nav tab already names this surface,
                  // so the 22px in-card title compresses to a small overline
                  // and gives that first-viewport space back to the data.
                  style: isPhone
                      ? TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                          color: context.textSubtle,
                        )
                      : TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.3,
                          color: context.textPrimary,
                        ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              SizedBox(height: isPhone ? 12 : 20),
              Semantics(
                container: true,
                label: heroLabel,
                excludeSemantics: true,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
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
                        widget.currencyFormat.displayMoney(totalValue),
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
                    // All-time pill + (when the backend reports it,
                    // contract C-B) a "today" pill with identical
                    // geometry. Phones compact the amounts (above) so
                    // both pills share one row; the Wrap still stacks
                    // them if an extreme value overflows anyway.
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _heroChangePill(
                          positive: isPositive,
                          text: allTimePillText,
                        ),
                        ?_buildTodayPill(l, compact: isPhone),
                      ],
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
          return Padding(
            padding: EdgeInsets.all(pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                summary,
                SizedBox(height: isPhone ? 12 : 24),
                _buildSummaryKpis(),
                SizedBox(height: isPhone ? 12 : 16),
                _buildDualCurrencyPanel(),
              ],
            ),
          );
        },
      ),
    );
  }

  /// Change pill shared by the hero's all-time and "today" figures —
  /// one construction so the two are geometrically identical (12% alpha
  /// fill, 8px radius, 13px w700, tabular figures). [neutral] renders the
  /// flat/zero case honestly: muted color and NO up/down arrow, instead of
  /// a fake green "▲ +0.00%".
  Widget _heroChangePill({
    required bool positive,
    required String text,
    bool neutral = false,
  }) {
    final color = neutral
        ? context.textMuted
        : positive
        ? context.positive
        : context.negative;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (!neutral) ...[
            Icon(
              positive ? Icons.arrow_upward : Icons.arrow_downward,
              color: color,
              size: 14,
            ),
            const SizedBox(width: 4),
          ],
          Flexible(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// Signed day-change text ("-$731.53 (-1.41%)") from the contract C-B
  /// top-level fields, or null when the backend doesn't send them. Shared
  /// by the "today" pill and the hero's merged a11y label (A1) so the two
  /// can never drift apart. [compact] abbreviates the amount through
  /// [_compactMoney] ("-$731.53" → "-$731.53", "-$7,315.30" → "-$7.32K")
  /// for the phone-width pill; the a11y label always passes false so the
  /// spoken figure stays full-precision.
  String? _dayChangeText({bool compact = false}) {
    final dayUsd = (widget.portfolioData['day_change_usd'] as num?)?.toDouble();
    if (dayUsd == null) return null;
    final dayPct = (widget.portfolioData['day_change_pct'] as num?)?.toDouble();
    // Explicit sign per figure: negatives must keep their minus ("-$731.53
    // (-1.41%)"), which the .abs() calls below would otherwise strip.
    final sign = dayUsd > 0
        ? '+'
        : dayUsd < 0
        ? '-'
        : '';
    final converted = dayUsd * widget.conversionFactor;
    final amount =
        '$sign${compact ? _compactMoney(converted.abs()) : widget.currencyFormat.displayMoney(converted.abs())}';
    return dayPct == null
        ? amount
        : '$amount (${dayPct > 0
              ? '+'
              : dayPct < 0
              ? '-'
              : ''}${formatPercent(context, dayPct.abs(), digits: 2)})';
  }

  /// "Today" pill: the portfolio's change since the last stored close
  /// (contract C-B top-level fields). Null when the backend doesn't send
  /// the fields (older server, or nothing is covered) — the pill simply
  /// doesn't render. When coverage is partial or the closes are stale, a
  /// tooltip discloses the as-of date and covered share honestly.
  /// [compact] routes the displayed amount through [_compactMoney] on
  /// phone widths (the tooltip / a11y strings stay full-precision).
  Widget? _buildTodayPill(AppLocalizations l, {bool compact = false}) {
    final dayUsd = (widget.portfolioData['day_change_usd'] as num?)?.toDouble();
    if (dayUsd == null) return null;
    final dayPct = (widget.portfolioData['day_change_pct'] as num?)?.toDouble();
    final coverage = (widget.portfolioData['day_change_coverage_pct'] as num?)
        ?.toDouble();
    final asOfRaw = (widget.portfolioData['day_change_as_of'] ?? '').toString();
    final asOf = DateTime.tryParse(asOfRaw);

    final positive = dayUsd > 0;
    // Flat day: nothing moved (both the amount and the % are zero) — the
    // pill renders neutral (muted, no arrow) instead of a green "+$0.00".
    final flat = dayUsd == 0 && (dayPct ?? 0) == 0;
    final change = _dayChangeText(compact: compact)!;

    final pill = _heroChangePill(
      positive: positive,
      neutral: flat,
      text: l.pfDayPillToday(change),
    );

    // Qualify the figure when it doesn't cover the whole portfolio (401k
    // trust funds without stored closes) or the latest close pre-dates
    // today (weekend / after a refresh gap).
    final today = DateTime.now();
    final isStale =
        asOf != null &&
        DateTime(
          asOf.year,
          asOf.month,
          asOf.day,
        ).isBefore(DateTime(today.year, today.month, today.day));
    final partial = coverage != null && coverage < 99.5;
    if (!isStale && !partial) return pill;
    final dateLabel = asOf != null ? DateFormat.yMMMd().format(asOf) : asOfRaw;
    return Tooltip(
      message: l.pfDayPillTooltip(
        dateLabel,
        (coverage ?? 100).toStringAsFixed(0),
      ),
      waitDuration: const Duration(milliseconds: 400),
      child: pill,
    );
  }

  /// Abbreviates a display-currency amount as `$1.53M` / `$53.9K` so the
  /// return-coverage caption stays on one or two short lines. Formatting goes
  /// through `NumberFormat.compactCurrency` (house rule: never build money
  /// strings by hand), mirroring `moneyFormat`'s name/symbol split so `$` vs
  /// `MXN ` follows the target currency. Falls back to the full formatter
  /// under $1K, where compaction would drop the cents without saving space.
  String _compactMoney(double amount) {
    if (amount.abs() < 1000) return widget.currencyFormat.format(amount);
    return NumberFormat.compactCurrency(
      locale: widget.currencyFormat.locale,
      name: widget.currencyFormat.currencyName,
      symbol: widget.currencyFormat.currencySymbol,
    ).format(amount);
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
                    style: TextStyle(fontSize: 11, color: context.textSubtle),
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
                      '${positive ? '+' : ''}$gainLossStr (${formatPercent(context, gainLossPct, digits: 2)})',
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

    // Phone-width variant: ONE compact single-line row (~48dp) instead of a
    // full 4-row tile. Surface styling matches KpiTile so the row sits
    // visually inside the KPI grid above it. Reads as an FX equivalence
    // ("Total value in pesos  ≈ MX$…"): a plain-language label carries the
    // meaning and the money string alone carries the currency — a code on
    // the left would just repeat the MX$/$ symbol. The P/L is dropped —
    // converted at one spot rate its percentage is identical to the hero
    // pill right above, so repeating it here cost cramped type for no
    // information. The >=520 branch keeps the full side-by-side comparison.
    Widget compactRow({required String label, required String totalValueStr}) {
      return Semantics(
        container: true,
        label: '$label: ≈ $totalValueStr',
        excludeSemantics: true,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: context.tint(0.03),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.tint(0.06)),
          ),
          child: Row(
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: context.textSubtle,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(width: 12),
              // The value claims the rest of the row, right-aligned.
              // FittedBox(scaleDown) — the hero's own idiom — shrinks it
              // slightly when a big MXN figure won't fit at full size:
              // scaled-but-complete money beats digits lost to an ellipsis.
              Expanded(
                flex: 3,
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Text(
                    '≈ $totalValueStr',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: context.textPrimary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    maxLines: 1,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    final usdTile = tile(
      currencyTitle: 'USD',
      currencySubtitle: l.pfUsDollar,
      totalValueStr: usdFmt.displayMoney(valUsd),
      gainLoss: glUsd ?? 0,
      gainLossStr: usdFmt.displayMoney((glUsd ?? 0).abs()),
      gainLossPct: glPctUsd,
    );
    final mxnTile = tile(
      currencyTitle: 'MXN',
      currencySubtitle: l.pfMexicanPeso,
      totalValueStr: mxnFmt.displayMoney(valMxn),
      gainLoss: glMxn ?? 0,
      gainLossStr: mxnFmt.displayMoney((glMxn ?? 0).abs()),
      gainLossPct: glPctMxn,
    );

    return LayoutBuilder(
      builder: (context, c) {
        final narrow = c.maxWidth < 520;
        if (narrow) {
          // Phone widths: the tile matching the display currency repeats
          // the hero's exact figures, so drop it and render only the OTHER
          // currency as one compact row. The >=520 branch keeps BOTH full
          // tiles — the side-by-side comparison is intentional there.
          return widget.targetCurrency == 'MXN'
              ? compactRow(
                  label: l.pfTotalInUsd,
                  totalValueStr: usdFmt.displayMoney(valUsd),
                )
              : compactRow(
                  label: l.pfTotalInMxn,
                  totalValueStr: mxnFmt.displayMoney(valMxn),
                );
        }
        return Row(children: [usdTile, const SizedBox(width: 12), mxnTile]);
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
  })
  _computeMovers() {
    Map<String, dynamic>? top;
    Map<String, dynamic>? gainer;
    Map<String, dynamic>? loser;
    for (final h in _allHoldings) {
      // Rank by USD value so a large MXN position isn't ranked above a larger
      // USD one just because its native number is bigger.
      final v = (h['value_usd'] as num?)?.toDouble() ?? 0.0;
      if (top == null || v > ((top['value_usd'] as num?)?.toDouble() ?? 0)) {
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

  // Dollar-mover ranking (all-time `gain_loss_usd`, today
  // `day_change_usd`) lives in utils/movers.dart (`topDollarMovers`) so
  // the sort/skip-null semantics are unit-testable outside the widget.

  /// Headline facts for the overview card: holdings count and top position.
  /// The biggest gainer/loser moved to the dedicated signals strip (which
  /// sits between allocation and holdings in the research flow).
  Widget _buildSummaryKpis() {
    if (_allHoldings.isEmpty) return const SizedBox.shrink();

    final l = AppLocalizations.of(context);
    final cf = widget.conversionFactor;
    final movers = _computeMovers();
    final top = movers.top;

    final tiles = <KpiTile>[
      KpiTile(
        label: l.pfHoldings,
        value: '${_allHoldings.length}',
        sub: l.pfAccountsCount(
          _allHoldings
              .map((h) => (h['account_name'] ?? '').toString())
              .toSet()
              .where((s) => s.isNotEmpty)
              .length,
        ),
      ),
      if (top != null)
        KpiTile(
          label: l.pfTopPosition,
          value: _displayTicker(top),
          // USD-normalised: a native MXN value here read as "$300,000" for a
          // ~$17k position. value_usd → display via the conversion factor.
          sub: widget.currencyFormat.displayMoney(
            ((top['value_usd'] as num?)?.toDouble() ?? 0.0) * cf,
          ),
          accent: context.tealAccent,
        ),
    ];

    return LayoutBuilder(
      builder: (ctx, c) {
        // 2-up even on phones — KpiTile ellipsizes label/value/sub, so a
        // ~150px tile is overflow-safe, and stacked full-width tiles wasted
        // most of the first viewport on narrow screens. 300, not 320: a 390px
        // phone leaves ~318px here after page (20) + card (16) padding.
        final perRow = c.maxWidth >= 300 ? 2 : 1;
        final tileWidth = (c.maxWidth - 12 * (perRow - 1)) / perRow;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: tiles
              .map((t) => SizedBox(width: tileWidth, child: t))
              .toList(),
        );
      },
    );
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
          trailing: '+${formatPercent(context, gainerPct, digits: 2)}',
        ),
      if (loser != null && loserPct < 0)
        _signalChip(
          icon: Icons.trending_down,
          color: context.negative,
          label: l.pfBiggestLoser,
          value: _displayTicker(loser),
          trailing: formatPercent(context, loserPct, digits: 2),
        ),
      if (concentrated)
        _signalChip(
          icon: Icons.warning_amber_rounded,
          color: context.warning,
          label: l.pfConcentrated,
          value: _displayTicker(top),
          trailing: formatPercent(context, topShare * 100, digits: 0),
        ),
    ];

    // Dollar movers — the positions that actually shifted the portfolio
    // total (vs. the % race above, which a tiny position can win). Two
    // honest time frames: "today" ranks the day change the holdings table
    // already carries per row; "all time" ranks cumulative dollar P&L.
    // Each section only appears when at least one holding reports its
    // figure (day closes present / basis reported).
    final todayMovers = topDollarMovers(_allHoldings, field: 'day_change_usd');
    final allTimeMovers = topDollarMovers(_allHoldings, field: 'gain_loss_usd');
    final hasDollarMovers =
        todayMovers.gainers.isNotEmpty ||
        todayMovers.losers.isNotEmpty ||
        allTimeMovers.gainers.isNotEmpty ||
        allTimeMovers.losers.isNotEmpty;

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
              LayoutBuilder(
                builder: (ctx, c) {
                  // Side-by-side on wide screens, stacked on phone widths.
                  final perRow = c.maxWidth >= kCompactLayoutBelow
                      ? chips.length
                      : 1;
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
                },
              ),
            ],
            if (hasDollarMovers) ...[
              const SizedBox(height: 16),
              _buildDollarMovers(today: todayMovers, allTime: allTimeMovers),
            ],
          ],
        ),
      ),
    );
  }

  /// Dollar-movers mini-section, in two honestly-labelled time frames:
  /// "Top movers today (by \$)" ranks the per-row day change
  /// (`day_change_usd`) and "Best & worst (all time)" ranks cumulative
  /// dollar P&L (`gain_loss_usd`) — the latter used to ship under a "Top
  /// movers" title that implied intraday. Each figure is a signed USD
  /// amount scaled to the display currency via the conversion factor.
  /// Gainers (green, descending) and losers (red, most-negative first)
  /// sit in two sub-lists; empty sides — and empty time frames — are
  /// omitted.
  Widget _buildDollarMovers({
    required ({
      List<Map<String, dynamic>> gainers,
      List<Map<String, dynamic>> losers,
    })
    today,
    required ({
      List<Map<String, dynamic>> gainers,
      List<Map<String, dynamic>> losers,
    })
    allTime,
  }) {
    final l = AppLocalizations.of(context);
    final cf = widget.conversionFactor;

    Widget moverRow(Map<String, dynamic> h, bool positive, String field) {
      final glUsd = (h[field] as num).toDouble();
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
              '${positive ? '+' : ''}${widget.currencyFormat.displayMoney(disp)}',
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
      String field,
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
          ...rows.map((h) => moverRow(h, color == context.positive, field)),
        ],
      );
    }

    // One labelled time frame: a small title, then the gainer/loser
    // columns (side-by-side on wide, stacked on phone).
    Widget timeFrame(
      String title,
      ({List<Map<String, dynamic>> gainers, List<Map<String, dynamic>> losers})
      movers,
      String field,
    ) {
      final columns = <Widget>[
        if (movers.gainers.isNotEmpty)
          moverColumn(
            l.pfTopGainersByValue,
            Icons.trending_up,
            context.positive,
            movers.gainers,
            field,
          ),
        if (movers.losers.isNotEmpty)
          moverColumn(
            l.pfTopLosersByValue,
            Icons.trending_down,
            context.negative,
            movers.losers,
            field,
          ),
      ];

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.4,
              color: context.textSubtle,
            ),
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (ctx, c) {
              // Two columns side-by-side on wide screens, stacked on phone.
              if (c.maxWidth >= kCompactLayoutBelow && columns.length == 2) {
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
            },
          ),
        ],
      );
    }

    final hasToday = today.gainers.isNotEmpty || today.losers.isNotEmpty;
    final hasAllTime = allTime.gainers.isNotEmpty || allTime.losers.isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasToday) timeFrame(l.pfMoversTodayTitle, today, 'day_change_usd'),
        if (hasToday && hasAllTime) const SizedBox(height: 16),
        if (hasAllTime)
          timeFrame(l.pfBestWorstAllTime, allTime, 'gain_loss_usd'),
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
          (s, h) => s + ((h['value'] as num?)?.toDouble() ?? 0.0),
        );
        final sb = b.value.fold<double>(
          0,
          (s, h) => s + ((h['value'] as num?)?.toDouble() ?? 0.0),
        );
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
          final subtotal =
              list.fold<double>(
                0,
                (s, h) => s + ((h['value'] as num?)?.toDouble() ?? 0.0),
              ) *
              widget.conversionFactor;
          final inst = (list.first['institution_name'] ?? '').toString();
          return Container(
            margin: const EdgeInsets.only(bottom: 16),
            decoration: BoxDecoration(
              color: context.tint(0.02),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.tint(0.05)),
            ),
            child: Column(
              children: [
                // One header node per account section so screen readers can
                // jump between accounts and hear the position count +
                // subtotal in one announcement (round-1 leftover b).
                // `container: true` forces an explicit semantics boundary
                // so the heading can never be absorbed into a neighboring
                // node on any platform/engine (round-2 web QA saw the
                // headers missing from the semantics tree while the row
                // nodes landed).
                Semantics(
                  container: true,
                  header: true,
                  label: [
                    acct,
                    if (inst.isNotEmpty) inst,
                    l.pfDaySemPositionsSubtotal(
                      list.length,
                      widget.currencyFormat.displayMoney(subtotal),
                    ),
                  ].join(', '),
                  excludeSemantics: true,
                  child: Padding(
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
                          widget.currencyFormat.displayMoney(subtotal),
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: context.textPrimary,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
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
    final opaque =
        rawSym.length > 8 ||
        (rawSym != rawSym.toUpperCase() && rawSym.length > 4);
    final displaySymbol = opaque
        ? (rawName.isNotEmpty ? rawName : '—')
        : (rawSym.isEmpty ? (rawName.isNotEmpty ? rawName : '?') : rawSym);

    // Grouped rows are tappable like their flat-table siblings: anything
    // with a real symbol opens the instrument detail sheet (contract C-F).
    final canOpenSheet = rawSym.isNotEmpty;

    // One merged, labelled BUTTON node per row — "NVDA, 29.5 shares,
    // $5,085.80, +64.06% return" (round-1 leftover b). Same pattern as the
    // dividend payer rows: the Semantics carries button+label, the InkWell
    // contributes the tap action, and ExcludeSemantics keeps the inner
    // Texts from being announced twice.
    return MergeSemantics(
      child: Semantics(
        button: canOpenSheet,
        label: l.pfDaySemHoldingRow(
          displaySymbol,
          formatQuantity(qty),
          widget.currencyFormat.displayMoney(value),
          pct == null
              ? '—'
              : '${isGain ? '+' : ''}${formatPercent(context, pct, digits: 2)}',
        ),
        child: InkWell(
          onTap: canOpenSheet
              ? () async {
                  final changed = await showInstrumentSheet(
                    context,
                    apiService: _apiService,
                    symbol: rawSym,
                    conversionFactor: widget.conversionFactor,
                    currencyFormat: widget.currencyFormat,
                  );
                  // C3-D: a classification change inside the sheet stales
                  // the holdings + allocation data — hand the refetch to
                  // the owner (round-3 U2).
                  if (changed && mounted) {
                    await widget.onDataRefreshRequested?.call();
                  }
                }
              : null,
          child: ExcludeSemantics(
            child: Padding(
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
                      l.pfSharesSuffix(formatQuantity(qty)),
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.textMuted,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
                  Expanded(
                    flex: 3,
                    child: Text(
                      widget.currencyFormat.displayMoney(value),
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary,
                        fontFeatures: const [FontFeature.tabularFigures()],
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
                            '${isGain ? '+' : ''}${formatPercent(context, pct, digits: 2)}',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                              color: isGain
                                  ? context.positive
                                  : context.negative,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ),
        ),
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
                // A1 (round 3, a11y): without the wrapper the chip's only
                // actionable semantics was the delete icon's bare "Delete"
                // checkbox. The chip now announces "Active filter: Bonds"
                // (inner Text excluded so it isn't read twice) and the
                // delete affordance announces "Clear filter".
                child: Semantics(
                  container: true,
                  label: l.axActiveFilter(
                    categoryFilterLabel(widget.categoryFilter ?? '', l),
                  ),
                  child: InputChip(
                    avatar: const Icon(Icons.filter_alt, size: 16),
                    label: ExcludeSemantics(
                      child: Text(
                        // Prefix-stripped display value: the raw filter
                        // string is a dimension-scoped key like
                        // "asset:bonds" (contract C3), not a label. `l`
                        // maps asset: keys to the allocation band's
                        // display names.
                        l.pfCategoryFilter(
                          categoryFilterLabel(widget.categoryFilter ?? '', l),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    onDeleted: widget.onClearCategoryFilter,
                    deleteButtonTooltipMessage: l.axClearFilter,
                    backgroundColor: context.tint(0.06),
                  ),
                ),
              ),
            ),
          // M2 (round 3): below the mobile breakpoint the single toolbar
          // row clipped the Flat/By-account SegmentedButton at the screen
          // edge. Narrow viewports get TWO rows — a full-width search
          // field, then counter + toggle + CSV — while the desktop
          // single-row layout is built from the exact same pieces and
          // stays pixel-identical.
          LayoutBuilder(
            builder: (context, constraints) {
              final narrow = constraints.maxWidth < _kMobileBreakpoint;
              final searchField = SizedBox(
                height: 36,
                child: TextField(
                  controller: _searchController,
                  onChanged: (v) => setState(() {
                    _searchQuery = v;
                    _applySearch();
                    _sort(_sortColumnIndex ?? _kColIndexValue, _isAscending);
                  }),
                  decoration: InputDecoration(
                    hintText: l.pfSearchHint,
                    hintStyle: TextStyle(
                      color: context.textSubtle,
                      fontSize: 13,
                    ),
                    prefixIcon: Icon(
                      Icons.search,
                      size: 18,
                      color: context.textSubtle,
                    ),
                    filled: true,
                    fillColor: context.tint(0.05),
                    contentPadding: const EdgeInsets.symmetric(
                      vertical: 0,
                      horizontal: 12,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide.none,
                    ),
                  ),
                  style: const TextStyle(fontSize: 13),
                ),
              );
              final counter = Text(
                // Filter-aware counter: with a category filter or a search
                // active it reads "N of M holdings"; unfiltered it reads the
                // full "M holdings · K accounts" — except on the narrow
                // two-row layout, where a compact "M · K accts" keeps BOTH
                // numbers readable at 390px instead of ellipsizing the
                // accounts half mid-word.
                widget.categoryFilter != null || _searchQuery.isNotEmpty
                    ? l.pfFilterShownOfTotal(shownHoldings, totalHoldings)
                    : narrow
                    ? l.fix3HoldingsAccountsCompact(totalHoldings, accountCount)
                    : l.pfHoldingsAccountsCount(totalHoldings, accountCount),
                maxLines: narrow ? 1 : null,
                overflow: narrow ? TextOverflow.ellipsis : null,
                style: TextStyle(fontSize: 12, color: context.textSubtle),
              );
              // House connected button group. ConnectedSegments is built
              // of Expandeds and would otherwise fill the whole Row, so
              // it gets a bounded width; its Flexible labels make the old
              // narrow icon-dropping / compact-density hacks unnecessary.
              final segmented = SizedBox(
                width: 200,
                child: ConnectedSegments<bool>(
                  segments: [
                    ConnectedSegment(value: false, label: l.pfFlat),
                    ConnectedSegment(value: true, label: l.pfByAccount),
                  ],
                  selected: _groupByAccount,
                  onSelected: (v) {
                    // ConnectedSegments re-fires on a re-tap of the
                    // current selection; short-circuit so the preference
                    // write only happens on a real change.
                    if (v == _groupByAccount) return;
                    setState(() => _groupByAccount = v);
                    Preferences.setGroupByAccount(v);
                  },
                ),
              );
              // CSV export (contract C-E): browser-native downloads through
              // the same-origin cookie-auth seam the transactions/tax exports
              // use. Hidden when there's nothing to export.
              final csvMenu = _allHoldings.isNotEmpty
                  ? PopupMenuButton<String>(
                      tooltip: l.pfCsvExportTooltip,
                      icon: Icon(
                        Icons.download_outlined,
                        size: 20,
                        color: context.textMuted,
                      ),
                      onSelected: (path) =>
                          openUrlSameTab('${_apiService.baseUrl}$path'),
                      // A1 (round 3, a11y): MergeSemantics per item so each
                      // menu entry reads as one node (accounts_list pattern).
                      itemBuilder: (_) => [
                        PopupMenuItem(
                          value: '/dashboard/holdings/export',
                          child: MergeSemantics(child: Text(l.pfCsvHoldings)),
                        ),
                        PopupMenuItem(
                          value: '/dashboard/holdings/lots/export',
                          child: MergeSemantics(child: Text(l.pfCsvLots)),
                        ),
                      ],
                    )
                  : null;

              if (!narrow) {
                return Row(
                  children: [
                    Expanded(child: searchField),
                    const SizedBox(width: 12),
                    counter,
                    const SizedBox(width: 12),
                    segmented,
                    if (csvMenu != null) ...[const SizedBox(width: 4), csvMenu],
                  ],
                );
              }
              return Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  searchField,
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: counter),
                      const SizedBox(width: 8),
                      segmented,
                      if (csvMenu != null) ...[
                        const SizedBox(width: 4),
                        csvMenu,
                      ],
                    ],
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  /// Clears whatever narrowed the table to zero rows: the pushed-in
  /// category filter (via the same callback the chip's ✕ uses) and any
  /// typed search query.
  void _clearFilterAndSearch() {
    setState(() {
      _searchQuery = '';
      _searchController.clear();
      _applySearch();
      _sort(_sortColumnIndex ?? _kColIndexValue, _isAscending);
    });
    widget.onClearCategoryFilter?.call();
  }

  Widget _buildHoldingsTable() {
    final l = AppLocalizations.of(context);
    if (_holdings.isEmpty) {
      // Two very different empties: a genuinely empty portfolio gets the
      // onboarding copy; a filter/search that matched nothing must say so
      // and offer a way out — never tell a funded user to "link a
      // brokerage".
      final isFiltered = _allHoldings.isNotEmpty;
      // Quote whatever actually caused the miss: a typed search wins over
      // the category filter (searching "xyz" under a Bonds filter must say
      // no match for "xyz", not for "Bonds").
      final search = _searchQuery.trim();
      final filterLabel = search.isNotEmpty
          ? search
          : widget.categoryFilter != null
          ? categoryFilterLabel(widget.categoryFilter!, l)
          : '';
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
                  Icon(
                    isFiltered ? Icons.filter_alt_off : Icons.show_chart,
                    size: 56,
                    color: context.textFaint,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    isFiltered
                        ? l.pfFilterNoMatches(filterLabel)
                        : l.pfNoHoldingsYet,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 16,
                      color: context.textMuted,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (isFiltered) ...[
                    const SizedBox(height: 12),
                    TextButton.icon(
                      onPressed: _clearFilterAndSearch,
                      icon: const Icon(Icons.clear, size: 16),
                      label: Text(l.pfFilterClear),
                    ),
                  ] else ...[
                    const SizedBox(height: 6),
                    Text(
                      l.pfNoHoldingsBody,
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: context.textSubtle),
                    ),
                  ],
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
        final visibleHoldings = showAll
            ? _holdings
            : _holdings.sublist(0, _kHoldingsPreview);

        final expander = _holdings.length > _kHoldingsPreview
            ? Align(
                alignment: Alignment.centerLeft,
                child: TextButton(
                  onPressed: () =>
                      setState(() => _showAllHoldings = !_showAllHoldings),
                  child: Text(
                    showAll
                        ? l.pfHoldingsShowFewer
                        : l.pfHoldingsShowAll(_holdings.length),
                  ),
                ),
              )
            : null;

        final Widget body;
        if (available < _kMobileBreakpoint) {
          // Mobile: an 8-column table can't fit a phone without a sideways
          // scroll the thumb can't reach. Collapse each row to the three
          // facts that matter at a glance — name, value, change — and let a
          // tap reveal shares/price/cost/gain (details-on-demand).
          body = Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final h in visibleHoldings)
                MobileHoldingRow(
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
                ...visibleHoldings.map(
                  (h) => SizedBox(
                    height: _kRowHeight,
                    child: HoldingRowTile(
                      holding: h,
                      format: widget.currencyFormat,
                      targetCurrency: widget.targetCurrency,
                      usdMxnRate: widget.usdMxnRate,
                      apiService: _apiService,
                      conversionFactor: widget.conversionFactor,
                      onDataRefreshRequested: widget.onDataRefreshRequested,
                    ),
                  ),
                ),
                ?expander,
              ],
            ),
          );

          // Horizontal scroll only when the viewport is narrower than the
          // table's natural width (but still above the mobile breakpoint).
          // Always-visible 6px thumb + 16px edge fade on the clipped side
          // so cut-off columns visibly read as "more content" instead of
          // silently clipping (round-1 leftover f).
          body = available < _kTableNaturalWidth
              ? EdgeFadedHScroll(child: table)
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
            alignment: numeric ? Alignment.centerRight : Alignment.centerLeft,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Flexible+ellipsis so a long header can never overflow its
                // fixed column (locales/fonts vary; the columns are sized
                // for the values, not the widest possible header).
                Flexible(
                  child: Text(
                    text,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: active ? context.textPrimary : context.textMuted,
                    ),
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

    return holdingsTableRow(
      asset: label(l.pfColAsset, 0, numeric: false),
      shares: label(l.pfColShares, 1),
      price: label(l.pfColPrice, 2),
      day: label(l.pfDayColHeader, _kColIndexDay),
      value: label(l.pfColValue, _kColIndexValue),
      costBasis: label(l.pfColCostBasis, 5),
      gain: label(l.pfColGain, 6),
      returnPct: label(l.pfColReturn, 7),
    );
  }
}

// Layout constants for the virtualized holdings table. Header and body
// share the same column widths so they line up visually as the user
// scrolls. The natural width must fit the card's content width at a
// 1440×900 viewport (~1147px) — when the Day column landed it pushed the
// natural width to 1188 and the Return column half-clipped in the default
// view. Below the natural width the table scrolls horizontally instead of
// squeezing columns.
const double _kRowHeight = 60.0;
const double _kTableNaturalWidth = 1144.0;
// Below this viewport width the wide 8-column table collapses to the
// tap-to-expand mobile row (name + value + change) — the shared
// compact-layout threshold.
const double _kMobileBreakpoint = kCompactLayoutBelow;
// Sort indices for the columns whose position shifted when the Day column
// landed between Price (2) and Value. Named so the default-sort call sites
// and the comparator can't drift apart again.
const int _kColIndexDay = 3;
const int _kColIndexValue = 4;
