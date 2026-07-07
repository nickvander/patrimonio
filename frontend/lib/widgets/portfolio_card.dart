import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/preferences.dart';
import '../utils/currency.dart';
import '../utils/mask_aware_name.dart';
import '../utils/theme_colors.dart';
import '../utils/url_opener.dart';
import 'dividend_detail_sheet.dart';
import 'instrument_detail_sheet.dart';
import 'skeleton.dart';

/// True when holding [h] passes the allocation-band filter [filter].
///
/// The allocation heatmap emits dimension-prefixed values (contract C3) —
/// `asset:<canonical class>`, `account_type:<raw type>`,
/// `institution:<raw name>` — and each prefix matches ONLY its own field.
/// `asset:` keys on the backend's canonical `asset_class` (contract C2), so
/// a VBTLX-style bond *mutual fund* lands under `asset:bonds` and a holding
/// inside a bonds-typed *account* no longer matches everything. A bare
/// value (no colon before the first space, or an unknown prefix) falls back
/// to the legacy any-field OR so the card keeps filtering if the emitter
/// and parser ship at different times. Matching is case-insensitive.
/// Top-level (not a method) so tests can exercise the parsing directly.
bool holdingMatchesCategoryFilter(Map h, String? filter) {
  final catFilter = (filter ?? '').toLowerCase().trim();
  if (catFilter.isEmpty) return true;
  String field(String key) => (h[key] ?? '').toString().toLowerCase();
  final colon = catFilter.indexOf(':');
  final space = catFilter.indexOf(' ');
  if (colon > 0 && (space == -1 || colon < space)) {
    final value = catFilter.substring(colon + 1).trim();
    switch (catFilter.substring(0, colon)) {
      case 'asset':
        return field('asset_class') == value;
      case 'account_type':
        return field('account_type') == value;
      case 'institution':
        return field('institution_name') == value;
      // Unknown prefix: fall through to the legacy any-field match below.
    }
  }
  return field('holding_type') == catFilter ||
      field('account_type') == catFilter ||
      field('institution_name') == catFilter;
}

/// Human label for the active-filter chip / zero-result state: strips the
/// C3 dimension prefix and title-cases the value ("asset:bonds" → "Bonds",
/// "institution:vanguard" → "Vanguard"). Bare legacy values are only
/// title-cased.
///
/// When [l] is given, `asset:` canonical keys (contract C2) render as the
/// same display names the allocation band shows (the backend's
/// `asset_class_label` mapping) — "asset:equity" must echo the tapped
/// "Stocks & funds" band, not a raw "Equity". Unknown keys keep the
/// title-cased fallback.
String categoryFilterLabel(String filter, [AppLocalizations? l]) {
  var value = filter.trim();
  final colon = value.indexOf(':');
  final space = value.indexOf(' ');
  if (colon > 0 && (space == -1 || colon < space)) {
    final dim = value.substring(0, colon).toLowerCase();
    const dims = {'asset', 'account_type', 'institution'};
    if (dims.contains(dim)) {
      value = value.substring(colon + 1).trim();
      if (dim == 'asset' && l != null) {
        final assetLabel = switch (value.toLowerCase()) {
          'equity' => l.pfFilterAssetEquity,
          'bonds' => l.pfFilterAssetBonds,
          'cash' => l.pfFilterAssetCash,
          'crypto' => l.pfFilterAssetCrypto,
          'real_estate' => l.pfFilterAssetRealEstate,
          'commodities' => l.pfFilterAssetCommodities,
          'other' => l.pfFilterAssetOther,
          _ => null,
        };
        if (assetLabel != null) return assetLabel;
      }
    }
  }
  return value
      .split(' ')
      .map((w) => w.isEmpty ? w : w[0].toUpperCase() + w.substring(1))
      .join(' ');
}

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

  late final TextEditingController _searchController =
      TextEditingController();

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
            (h) => holdingMatchesCategoryFilter(h as Map, widget.categoryFilter))
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
              // A1 (round 3, a11y): the value caption, hero figure and
              // change pills read as ONE labelled node — "Portfolio value
              // $X, all-time +$Y (+Z%), today +$W (+V%)" — instead of four
              // fragments. excludeSemantics folds the inner Texts away;
              // the pills' visual tooltips (overlay-based) are unaffected.
              final allTimeText =
                  '${totalGainLoss > 0 ? '+' : totalGainLoss < 0 ? '-' : ''}${widget.currencyFormat.format(totalGainLoss.abs())} (${totalGainLossPct.toStringAsFixed(2)}%)';
              final dayText = _dayChangeText();
              final heroLabel = [
                l.axPortfolioHero(
                    widget.currencyFormat.format(totalValue), allTimeText),
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
                      style: TextStyle(
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.3,
                        color: context.textPrimary,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const SizedBox(height: 20),
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
                            widget.currencyFormat.format(totalValue),
                            style: TextStyle(
                              fontSize: heroFontSize,
                              fontWeight: FontWeight.w800,
                              letterSpacing: -1.0,
                              height: 1.1,
                              color: context.textPrimary,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ],
                            ),
                            maxLines: 1,
                          ),
                        ),
                        const SizedBox(height: 12),
                        // All-time pill + (when the backend reports it,
                        // contract C-B) a "today" pill with identical
                        // geometry. A Wrap so a 400px-wide card stacks the
                        // two instead of overflowing.
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            _heroChangePill(
                              positive: isPositive,
                              // Explicit sign on the amount: losses must read
                              // "-$500.00", not a red "$500.00" (the abs()
                              // strips the minus, so it's re-applied here).
                              text: allTimeText,
                            ),
                            ?_buildTodayPill(l),
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
  /// can never drift apart.
  String? _dayChangeText() {
    final dayUsd =
        (widget.portfolioData['day_change_usd'] as num?)?.toDouble();
    if (dayUsd == null) return null;
    final dayPct =
        (widget.portfolioData['day_change_pct'] as num?)?.toDouble();
    // Explicit sign per figure: negatives must keep their minus ("-$731.53
    // (-1.41%)"), which the .abs() calls below would otherwise strip.
    final sign = dayUsd > 0 ? '+' : dayUsd < 0 ? '-' : '';
    final converted = dayUsd * widget.conversionFactor;
    final amount = '$sign${widget.currencyFormat.format(converted.abs())}';
    return dayPct == null
        ? amount
        : '$amount (${dayPct > 0 ? '+' : dayPct < 0 ? '-' : ''}${dayPct.abs().toStringAsFixed(2)}%)';
  }

  /// "Today" pill: the portfolio's change since the last stored close
  /// (contract C-B top-level fields). Null when the backend doesn't send
  /// the fields (older server, or nothing is covered) — the pill simply
  /// doesn't render. When coverage is partial or the closes are stale, a
  /// tooltip discloses the as-of date and covered share honestly.
  Widget? _buildTodayPill(AppLocalizations l) {
    final dayUsd =
        (widget.portfolioData['day_change_usd'] as num?)?.toDouble();
    if (dayUsd == null) return null;
    final dayPct =
        (widget.portfolioData['day_change_pct'] as num?)?.toDouble();
    final coverage =
        (widget.portfolioData['day_change_coverage_pct'] as num?)?.toDouble();
    final asOfRaw =
        (widget.portfolioData['day_change_as_of'] ?? '').toString();
    final asOf = DateTime.tryParse(asOfRaw);

    final positive = dayUsd > 0;
    // Flat day: nothing moved (both the amount and the % are zero) — the
    // pill renders neutral (muted, no arrow) instead of a green "+$0.00".
    final flat = dayUsd == 0 && (dayPct ?? 0) == 0;
    final change = _dayChangeText()!;

    final pill = _heroChangePill(
      positive: positive,
      neutral: flat,
      text: l.pfDayPillToday(change),
    );

    // Qualify the figure when it doesn't cover the whole portfolio (401k
    // trust funds without stored closes) or the latest close pre-dates
    // today (weekend / after a refresh gap).
    final today = DateTime.now();
    final isStale = asOf != null &&
        DateTime(asOf.year, asOf.month, asOf.day)
            .isBefore(DateTime(today.year, today.month, today.day));
    final partial = coverage != null && coverage < 99.5;
    if (!isStale && !partial) return pill;
    final dateLabel =
        asOf != null ? DateFormat.yMMMd().format(asOf) : asOfRaw;
    return Tooltip(
      message: l.pfDayPillTooltip(
        dateLabel,
        (coverage ?? 100).toStringAsFixed(0),
      ),
      waitDuration: const Duration(milliseconds: 400),
      child: pill,
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
                      widget.currencyFormat.format(subtotal),
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
                          widget.currencyFormat.format(subtotal),
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                            color: context.textPrimary,
                            fontFeatures: [
                              const FontFeature.tabularFigures()
                            ],
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
    final opaque = rawSym.length > 8 ||
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
          _formatQuantity(qty),
          widget.currencyFormat.format(value),
          pct == null ? '—' : '${isGain ? '+' : ''}${pct.toStringAsFixed(2)}%',
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
                      categoryFilterLabel(widget.categoryFilter ?? '', l)),
                  child: InputChip(
                    avatar: const Icon(Icons.filter_alt, size: 16),
                    label: ExcludeSemantics(
                      child: Text(
                          // Prefix-stripped display value: the raw filter
                          // string is a dimension-scoped key like
                          // "asset:bonds" (contract C3), not a label. `l`
                          // maps asset: keys to the allocation band's
                          // display names.
                          l.pfCategoryFilter(categoryFilterLabel(
                              widget.categoryFilter ?? '', l)),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis),
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
          LayoutBuilder(builder: (context, constraints) {
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
                      ? l.fix3HoldingsAccountsCompact(
                          totalHoldings, accountCount)
                      : l.pfHoldingsAccountsCount(
                          totalHoldings, accountCount),
              maxLines: narrow ? 1 : null,
              overflow: narrow ? TextOverflow.ellipsis : null,
              style: TextStyle(fontSize: 12, color: context.textSubtle),
            );
            final segmented = SegmentedButton<bool>(
              segments: [
                ButtonSegment(
                  value: false,
                  // Narrow: the label alone is the affordance — dropping
                  // the leading icons (plus tighter padding below) is what
                  // keeps both segments fully on-screen at 320–390px.
                  icon: narrow
                      ? null
                      : const Icon(Icons.list_alt, size: 14),
                  label: Text(l.pfFlat),
                ),
                ButtonSegment(
                  value: true,
                  icon: narrow
                      ? null
                      : const Icon(Icons.account_tree_outlined, size: 14),
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
                padding: narrow
                    ? WidgetStateProperty.all(
                        const EdgeInsets.symmetric(horizontal: 8))
                    : null,
                textStyle: WidgetStateProperty.all(
                    const TextStyle(fontSize: 12)),
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
                  if (csvMenu != null) ...[
                    const SizedBox(width: 4),
                    csvMenu,
                  ],
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
          }),
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
                    color: Colors.grey.shade700,
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
                      style:
                          TextStyle(fontSize: 12, color: Colors.grey.shade500),
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
          // Mobile: an 8-column table can't fit a phone without a sideways
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
                        apiService: _apiService,
                        conversionFactor: widget.conversionFactor,
                        onDataRefreshRequested:
                            widget.onDataRefreshRequested,
                      ),
                    )),
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
              ? _EdgeFadedHScroll(child: table)
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

    return _tableRow(
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
// scrolls. The natural width must fit the card's content width at a
// 1440×900 viewport (~1147px) — when the Day column landed it pushed the
// natural width to 1188 and the Return column half-clipped in the default
// view. Below the natural width the table scrolls horizontally instead of
// squeezing columns.
const double _kRowHeight = 60.0;
const double _kTableNaturalWidth = 1144.0;
// Below this viewport width the wide 8-column table collapses to the
// tap-to-expand mobile row (name + value + change).
const double _kMobileBreakpoint = 560.0;
const double _kHMargin = 20.0;
const double _kColShares = 100.0;
const double _kColPrice = 124.0;
const double _kColDay = 86.0;
const double _kColValue = 144.0;
const double _kColCost = 126.0;
const double _kColGain = 132.0;
const double _kColReturn = 108.0;
// Sort indices for the columns whose position shifted when the Day column
// landed between Price (2) and Value. Named so the default-sort call sites
// and the comparator can't drift apart again.
const int _kColIndexDay = 3;
const int _kColIndexValue = 4;

/// Shared row layout used by the header and every body row. Asset takes
/// the remaining space; numeric columns are fixed width so values line
/// up vertically.
Widget _tableRow({
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

/// Horizontal scroller for the too-narrow-for-the-table case: an
/// always-visible 6px scrollbar thumb under the table plus a 16px alpha
/// fade on whichever edge still has clipped content, so a 1024×768 user
/// sees "there's more" instead of a silently cut-off Gain/Return column.
/// Owns its ScrollController (the Scrollbar and the scroll view must share
/// one that isn't the page's PrimaryScrollController).
class _EdgeFadedHScroll extends StatefulWidget {
  final Widget child;

  const _EdgeFadedHScroll({required this.child});

  @override
  State<_EdgeFadedHScroll> createState() => _EdgeFadedHScrollState();
}

class _EdgeFadedHScrollState extends State<_EdgeFadedHScroll> {
  final ScrollController _controller = ScrollController();
  // Content starts scrolled to the leading edge, so before the first
  // metrics arrive only the trailing side fades — this widget is only
  // built when the table is wider than the viewport.
  bool _atStart = true;
  bool _atEnd = false;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onScroll);
  }

  @override
  void dispose() {
    _controller.removeListener(_onScroll);
    _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_controller.hasClients) _apply(_controller.position);
  }

  void _apply(ScrollMetrics m) {
    final atStart = m.pixels <= 1.0;
    final atEnd = m.pixels >= m.maxScrollExtent - 1.0;
    if (atStart == _atStart && atEnd == _atEnd) return;
    // Metrics notifications can arrive during layout, where setState is
    // illegal — defer to the frame's end (one frame of fade lag, invisible).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _atStart = atStart;
        _atEnd = atEnd;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    const opaque = Color(0xFFFFFFFF);
    const transparent = Color(0x00FFFFFF);
    return NotificationListener<ScrollMetricsNotification>(
      // Fires on layout-driven metric changes (resize, rows expanding)
      // that never tick the controller listener.
      onNotification: (n) {
        _apply(n.metrics);
        return false;
      },
      child: Scrollbar(
        controller: _controller,
        thumbVisibility: true,
        thickness: 6,
        child: ShaderMask(
          // dstIn: the child keeps only the alpha of this gradient — a
          // 16px fade-out on the side(s) with more content, theme-agnostic
          // because it never paints a color of its own.
          shaderCallback: (rect) {
            final fade =
                rect.width <= 0 ? 0.0 : (16.0 / rect.width).clamp(0.0, 0.45);
            return LinearGradient(
              begin: Alignment.centerLeft,
              end: Alignment.centerRight,
              colors: [
                _atStart ? opaque : transparent,
                opaque,
                opaque,
                _atEnd ? opaque : transparent,
              ],
              stops: [0.0, fade, 1.0 - fade, 1.0],
            ).createShader(rect);
          },
          blendMode: BlendMode.dstIn,
          child: SingleChildScrollView(
            controller: _controller,
            scrollDirection: Axis.horizontal,
            // Bottom lane for the always-visible thumb so it doesn't sit
            // on the last row's figures.
            padding: const EdgeInsets.only(bottom: 10),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}

/// Secondary line under a holding's ticker — "fund name · institution ·
/// account" — truncating the LEAST identifying segment first.
///
/// The old pre-joined single Text ellipsized end-first, which on phone
/// widths always cut the ACCOUNT — the only part that disambiguates the
/// same fund held in two accounts ("Oracle Corporation · Fidelity NetBen…").
/// Here each segment is its own Text so truncation follows identification
/// value instead of word order:
///
///   1. the fund legal name is the flexible segment — it ellipsizes first;
///   2. the institution ellipsizes second, once the name is fully spent;
///   3. the account is laid out at natural width and only ellipsizes when
///      it ALONE exceeds the row — and a trailing "••1234" mask stays
///      visible even then, via [maskAwareNameText] (same seam as the
///      accounts panel).
///
/// A segment squeezed below a few legible characters is dropped together
/// with its " · " separator rather than rendering orphan "…" noise. The
/// semantics node always carries the full untruncated string, so screen
/// readers (and the web semantics tree) are unaffected by visual clipping.
class _HoldingSubtitle extends StatelessWidget {
  final String name;
  final String institution;
  final String account;
  final TextStyle style;

  const _HoldingSubtitle({
    required this.name,
    required this.institution,
    required this.account,
    required this.style,
  });

  static const String _sep = ' · ';

  @override
  Widget build(BuildContext context) {
    final parts = [name, institution, account].where((s) => s.isNotEmpty);
    if (parts.isEmpty) return const SizedBox.shrink();
    final full = parts.join(_sep);
    return Semantics(
      label: full,
      excludeSemantics: true,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final maxW = constraints.maxWidth;
          if (!maxW.isFinite) {
            // Unbounded width (shouldn't happen in the table/mobile rows):
            // fall back to the legacy single-string rendering.
            return Text(
              full,
              style: style,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            );
          }
          // Text merges its style with the ambient DefaultTextStyle and the
          // MediaQuery text scale — the measuring painter must do the same
          // or the caps would be computed for a different font.
          final effective = DefaultTextStyle.of(context).style.merge(style);
          final scaler = MediaQuery.textScalerOf(context);
          final direction = Directionality.of(context);
          double measure(String s) {
            final painter = TextPainter(
              text: TextSpan(text: s, style: effective),
              textDirection: direction,
              textScaler: scaler,
              maxLines: 1,
            )..layout();
            // Ceil so a segment capped at its own natural width never
            // ellipsizes from sub-pixel rounding.
            final w = painter.width.ceilToDouble();
            painter.dispose();
            return w;
          }

          final sepW = measure(_sep);
          // Below this a segment would show only "…"-noise — drop it.
          final minSeg = measure('MM…');

          // Assign widths in protection order: account > institution >
          // name. Each kept segment also reserves the separator toward the
          // segment after it, so the inflexible children can never sum past
          // maxW (which would paint an overflow instead of ellipsizing).
          var showName = name.isNotEmpty;
          var showInst = institution.isNotEmpty;
          final showAcct = account.isNotEmpty;
          var budget = maxW;
          var acctCap = 0.0;
          var instCap = 0.0;
          if (showAcct) {
            acctCap = math.min(measure(account), budget);
            budget -= acctCap;
          }
          if (showInst) {
            final avail = budget - (showAcct ? sepW : 0.0);
            if (avail >= minSeg || !showAcct) {
              instCap = math.min(measure(institution), math.max(0.0, avail));
              budget = avail - instCap;
            } else {
              showInst = false;
            }
          }
          if (showName && (showInst || showAcct)) {
            // The name is Flexible (it simply absorbs whatever is left);
            // only decide whether that leftover is worth rendering at all.
            if (budget - sepW < minSeg) showName = false;
          }

          Text segment(String text) => Text(
                text,
                style: style,
                maxLines: 1,
                softWrap: false,
                overflow: TextOverflow.ellipsis,
              );
          Text separator() => Text(_sep, style: style, maxLines: 1);

          final children = <Widget>[];
          if (showName) {
            children.add(Flexible(child: segment(name)));
          }
          if (showInst) {
            if (children.isNotEmpty) children.add(separator());
            children.add(ConstrainedBox(
              constraints: BoxConstraints(maxWidth: instCap),
              child: segment(institution),
            ));
          }
          if (showAcct) {
            if (children.isNotEmpty) children.add(separator());
            children.add(ConstrainedBox(
              constraints: BoxConstraints(maxWidth: acctCap),
              child: maskAwareNameText(account, style),
            ));
          }
          return Row(children: children);
        },
      ),
    );
  }
}

/// A single holding row used inside the virtualized ListView. Stateful
/// so that hover-over highlight doesn't have to rebuild the whole table.
class _HoldingRowTile extends StatefulWidget {
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

  const _HoldingRowTile({
    required this.holding,
    required this.format,
    required this.targetCurrency,
    required this.usdMxnRate,
    required this.apiService,
    required this.conversionFactor,
    this.onDataRefreshRequested,
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
    // symbol), institution, and account — bullet-separated. Surfacing
    // `account_name` lets users with positions split across several
    // brokerages tell them apart at a glance, so [_HoldingSubtitle] keeps
    // it visible by truncating the fund name / institution first.
    final subtitleName =
        (!isOpaqueSecurityId && rawName.isNotEmpty) ? rawName : '';
    final subtitleAccount =
        (acctName.isNotEmpty && acctName != instName) ? acctName : '';
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
                _HoldingSubtitle(
                  name: subtitleName,
                  institution: instName,
                  account: subtitleAccount,
                  style: const TextStyle(fontSize: 11, color: Colors.grey),
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
    String signOf(double v) => v > 0 ? '+' : v < 0 ? '-' : '';
    final dayColor = dayFlat
        ? context.textMuted
        : dayPositive
            ? context.positive
            : context.negative;
    final dayUnavailableMsg =
        AppLocalizations.of(context).pfDayUnavailable;
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
                    '${signOf(dayPct)}${dayPct.abs().toStringAsFixed(2)}%',
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: dayColor,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                if (dayConverted != null)
                  Text(
                    '${signOf(dayConverted)}${widget.format.format(dayConverted.abs())}',
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

    // Row tap opens the per-instrument sheet (contract C-F) for anything
    // with a symbol — opaque security_ids included, since the endpoint
    // degrades gracefully for them (stats + accounts, no chart). Only
    // symbol-less rows stay non-interactive. The per-lot dialog is no
    // longer the row-tap target; it stays reachable from the mobile
    // expanded row's Lots button.
    final canOpenSheet = rawSymbol.isNotEmpty;

    return MouseRegion(
      cursor:
          canOpenSheet ? SystemMouseCursors.click : SystemMouseCursors.basic,
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
          color:
              _hover ? context.tint(0.05) : Colors.transparent,
          child: _tableRow(
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
              // M1 (round 3): below ~480px of inner width the 6-column
              // grid wraps its headers ("Acquire d"), ellipsizes dollar
              // values and squashes the LT/ST chips — swap it for stacked
              // two-line rows. The ≥480px grid is untouched.
              child: LayoutBuilder(builder: (_, box) {
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
                            color:
                                context.hairline.withValues(alpha: 0.5)),
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
                        // A1 (round 3, a11y): each lot reads as ONE
                        // sentence — "Acquired Mar 1, 2024, 10 shares at
                        // $88.10 USD, Long-term" — instead of six cells.
                        return Semantics(
                          container: true,
                          label: l.axLotRow(
                            date != null ? dateFmt.format(date) : acquired,
                            qty.toStringAsFixed(
                                qty == qty.roundToDouble() ? 0 : 4),
                            '${formatCurrencyAmount(cpu, ccy)} $ccy',
                            date == null
                                ? '—'
                                : (isLongTerm
                                    ? l.pfLotLongTerm
                                    : l.pfLotShortTerm),
                          ),
                          excludeSemantics: true,
                          child: Padding(
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
                          ),
                        );
                      },
                    ),
                  ),
                  ],
                ],
              );
              }),
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
  final isLongTerm = date != null &&
      !now.isBefore(DateTime(date.year + 1, date.month, date.day));
  // Fractional lots keep their 4-decimal precision ("0.1181 sh").
  final qtyStr =
      qty.toStringAsFixed(qty == qty.roundToDouble() ? 0 : 4);
  final dateLabel = date != null ? dateFmt.format(date) : acquired;
  // No "now" suffix on the current value and 11px below (round-3 polish):
  // three amounts have to share one line at 390px without splitting the
  // "cost $X" pair across rows.
  final line2 = '@ ${formatCurrencyAmount(cpu, ccy)} → '
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
                style:
                    TextStyle(fontSize: 13, color: context.textFaint),
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
    // Same segment split as the desktop table subtitle: the account is the
    // most-protected segment (see [_HoldingSubtitle]) — on a 390px phone it
    // used to be exactly the part the end-first ellipsis cut off.
    final subtitleName =
        (!isOpaqueSecurityId && rawName.isNotEmpty) ? rawName : '';
    final subtitleAccount =
        (acctName.isNotEmpty && acctName != instName) ? acctName : '';
    final hasSubtitle = subtitleName.isNotEmpty ||
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
                        _HoldingSubtitle(
                          name: subtitleName,
                          institution: instName,
                          account: subtitleAccount,
                          style: const TextStyle(
                              fontSize: 11, color: Colors.grey),
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
                // Account + institution in FULL (wrapping, never ellipsized):
                // the compact subtitle above can still truncate long names,
                // and this panel is the only place a phone can read them.
                if (acctName.isNotEmpty)
                  _detailRow(l.txAccount, acctName, wrapValue: true),
                if (instName.isNotEmpty && instName != acctName)
                  _detailRow(l.lwNotifInstitutionFallback, instName,
                      wrapValue: true),
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

  /// [wrapValue]: the value is prose (account / institution name) rather
  /// than a figure — render it in full, soft-wrapping across lines, instead
  /// of the single unconstrained line the numeric rows use.
  Widget _detailRow(String label, String value,
      {Color? color, String? tooltip, bool wrapValue = false}) {
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
        crossAxisAlignment:
            wrapValue ? CrossAxisAlignment.start : CrossAxisAlignment.center,
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
  // Payers preview cap — the glanceable summary shows the top 5 with a
  // "Show all (N)" expander (same pattern as the holdings table) so the
  // remaining payers' income isn't invisible.
  static const _maxPayers = 5;
  bool _showAllPayers = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (!_loading) setState(() => _loading = true);
    // getPortfolioDividends is best-effort and returns null on failure —
    // a null after loading is the card's error state (with retry), not a
    // silent vanish.
    final data = await widget.apiService.getPortfolioDividends();
    if (!mounted) return;
    setState(() {
      _data = data;
      _loading = false;
    });
  }

  /// USD figure scaled into the display currency, same pattern as the
  /// realized-gains and holdings cards.
  String _money(double usd) =>
      widget.currencyFormat.format(usd * widget.conversionFactor);

  @override
  Widget build(BuildContext context) {
    // Fixed-footprint skeleton while loading so the tall card doesn't pop
    // in late and shove the layout; an inline error row (with retry) when
    // the fetch failed; hidden only when the portfolio genuinely earns no
    // dividends.
    if (_loading) return _buildLoadingSkeleton(context);
    final data = _data;
    if (data == null) return _buildErrorCard(context);

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
    // Payment frequency per symbol, for deriving each upcoming ex-date's
    // expected payment amount (annual income ÷ payments/yr).
    final perYearBySymbol = <String, int>{
      for (final c in payers)
        ((c as Map)['symbol'] ?? '').toString():
            (c['per_year'] as num?)?.toInt() ?? 0,
    };

    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // MergeSemantics + header so screen readers announce one
            // "Dividend income" heading for the card (round-1 leftover a).
            MergeSemantics(
              child: Semantics(
                header: true,
                child: Row(
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
              ),
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
              Semantics(
                header: true,
                child: Text(
                  l.divTopPayers,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: context.textSubtle,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              ...(_showAllPayers ? payers : payers.take(_maxPayers))
                  .map((c) => _payerRow(c as Map<String, dynamic>)),
              if (payers.length > _maxPayers)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () =>
                        setState(() => _showAllPayers = !_showAllPayers),
                    child: Text(_showAllPayers
                        ? l.pfDivShowFewerPayers
                        : l.pfDivShowAllPayers(payers.length)),
                  ),
                ),
            ],
            if (upcoming.isNotEmpty) ...[
              const SizedBox(height: 8),
              Divider(height: 24, color: context.hairline),
              Semantics(
                header: true,
                child: Text(
                  l.divUpcomingExDates,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                    color: context.textSubtle,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              // All the entries the API returns, each with the expected
              // payment amount (per-symbol annual income ÷ payments/yr).
              ...upcoming.map((e) =>
                  _exDateRow(e as Map<String, dynamic>, perYearBySymbol)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _summaryTile(String label, String value, Color valueColor) {
    // One merged, labelled node per tile ("Projected annual, $7,900") —
    // without it screen readers read the label and figure as unrelated
    // fragments (round-1 leftover a).
    return MergeSemantics(
      child: Semantics(
        label: '$label, $value',
        excludeSemantics: true,
        child: Container(
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
        ),
      ),
    );
  }

  /// Opens the per-symbol dividend detail sheet (self-fetching, same
  /// bottom-sheet chrome as the lending tab's interest-income drill-down).
  Future<void> _openDividendDetail(String symbol) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DividendDetailSheet(
        apiService: widget.apiService,
        symbol: symbol,
        conversionFactor: widget.conversionFactor,
        currencyFormat: widget.currencyFormat,
      ),
    );
  }

  Widget _payerRow(Map<String, dynamic> c) {
    final l = AppLocalizations.of(context);
    final symbol = c['symbol']?.toString() ?? '';
    final incomeUsd = (c['annual_income_usd'] as num?)?.toDouble() ?? 0.0;
    final yieldPct = (c['yield_pct'] as num?)?.toDouble();
    final perYear = (c['per_year'] as num?)?.toInt() ?? 0;

    // InkWell (over GestureDetector) keeps the row keyboard-focusable and
    // Enter/Space-activatable, matching the holdings-row pattern. The
    // explicit button label merges the fragments into one announcement
    // ("SCHD, $1,200 per year, opens dividend details") while the InkWell
    // keeps contributing the tap action (round-1 leftover a).
    return MergeSemantics(
      child: Semantics(
        button: symbol.isNotEmpty,
        label: l.pfDaySemPayerRow(
          symbol.isNotEmpty ? symbol : '—',
          _money(incomeUsd),
        ),
        child: InkWell(
          onTap: symbol.isEmpty ? null : () => _openDividendDetail(symbol),
          borderRadius: BorderRadius.circular(8),
          child: ExcludeSemantics(
            child: Padding(
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
                          style: TextStyle(
                              color: context.textFaint, fontSize: 11),
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
                  if (symbol.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    Icon(Icons.chevron_right,
                        size: 16, color: context.textFaint),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _exDateRow(Map<String, dynamic> e, Map<String, int> perYearBySymbol) {
    final symbol = e['symbol']?.toString() ?? '';
    final dateStr = e['est_next_ex_date']?.toString() ?? '';
    final parsed = DateTime.tryParse(dateStr);
    final dateLabel =
        parsed == null ? dateStr : DateFormat.yMMMd().format(parsed);
    // Expected payment landing around that date: the symbol's projected
    // annual income split across its payments per year.
    final annualUsd = (e['annual_income_usd'] as num?)?.toDouble() ?? 0.0;
    final perYear = perYearBySymbol[symbol] ?? 0;
    final expectedUsd = perYear > 0 ? annualUsd / perYear : null;
    final expectedLabel = expectedUsd == null ? '—' : _money(expectedUsd);

    // One merged, labelled node per row — "SCHD, estimated ex-date
    // Sep 12, 2026, expected $105.60" (round-1 leftover a).
    return MergeSemantics(
      child: Semantics(
        label: AppLocalizations.of(context).pfDaySemExDateRow(
          symbol.isNotEmpty ? symbol : '—',
          dateLabel,
          expectedLabel,
        ),
        excludeSemantics: true,
        child: Padding(
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
          const SizedBox(width: 12),
          Text(
            expectedLabel,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
        ),
      ),
    );
  }

  /// Fixed-footprint placeholder mirroring the loaded card's layout at its
  /// real heights (header, two summary tiles, the five collapsed payer rows
  /// + show-all button, and the upcoming ex-dates section) so data landing
  /// doesn't shove the page.
  Widget _buildLoadingSkeleton(BuildContext context) {
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SkeletonBox(width: 160, height: 18),
            const SizedBox(height: 16),
            const Row(
              children: [
                Expanded(child: SkeletonBox(height: 72)),
                SizedBox(width: 12),
                Expanded(child: SkeletonBox(height: 72)),
              ],
            ),
            // "Top payers" section: header + the 5 collapsed two-line payer
            // rows (~52px each with their padding) + the show-all button.
            const SizedBox(height: 24),
            const SkeletonBox(width: 100, height: 12),
            const SizedBox(height: 12),
            for (var i = 0; i < 5; i++) ...[
              const SkeletonBox(height: 52),
              if (i < 4) const SizedBox(height: 8),
            ],
            const SizedBox(height: 12),
            const SkeletonBox(width: 90, height: 16),
            // "Upcoming ex-dates" section: header + single-line rows.
            const SizedBox(height: 24),
            const SkeletonBox(width: 100, height: 12),
            const SizedBox(height: 12),
            for (var i = 0; i < 4; i++) ...[
              const SkeletonBox(height: 24),
              if (i < 3) const SizedBox(height: 8),
            ],
          ],
        ),
      ),
    );
  }

  /// Compact inline error row with retry — the card must not silently
  /// vanish when the fetch fails mid-session.
  Widget _buildErrorCard(BuildContext context) {
    final l = AppLocalizations.of(context);
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        child: Row(
          children: [
            Icon(Icons.error_outline, size: 18, color: context.warning),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l.pfDivLoadError,
                style: TextStyle(fontSize: 13, color: context.textMuted),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            TextButton(onPressed: _load, child: Text(l.pfDivRetry)),
          ],
        ),
      ),
    );
  }
}
