import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/currency.dart';
import '../utils/percent_format.dart';
import '../utils/theme_colors.dart';
import 'dividend_calendar.dart';
import 'dividend_detail_sheet.dart';
import 'skeleton.dart';

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

  /// Test seam: widget tests inject a canned-payload fetcher here (the
  /// test VM can't subclass ApiService); null in production. Same
  /// convention as [DividendDetailSheet.fetchOverride].
  @visibleForTesting
  final Future<Map<String, dynamic>?> Function()? fetchOverride;

  const DividendIncomeCard({
    super.key,
    required this.apiService,
    required this.conversionFactor,
    required this.currencyFormat,
    this.fetchOverride,
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
  // 12-month income calendar expander (contract C4-B). Collapsed by
  // default so the card's resting footprint is unchanged; the toggle
  // itself only exists when the backend sends a non-empty `calendar`.
  bool _showCalendar = false;

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
    final data =
        await (widget.fetchOverride ??
            widget.apiService.getPortfolioDividends)();
    if (!mounted) return;
    setState(() {
      _data = data;
      _loading = false;
    });
  }

  /// USD figure scaled into the display currency, same pattern as the
  /// realized-gains and holdings cards.
  String _money(double usd) =>
      widget.currencyFormat.displayMoney(usd * widget.conversionFactor);

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
        .where(
          (c) =>
              ((c as Map)['annual_income_usd'] as num?)?.toDouble() != null &&
              ((c['annual_income_usd'] as num).toDouble()) > 0,
        )
        .toList();
    final upcoming = (data['upcoming_ex_dates'] as List<dynamic>?) ?? const [];
    // 12-month projected income calendar (additive C4-B field). Absent or
    // empty — an older backend, or nothing projected — renders NOTHING
    // (no toggle): the card must stay pixel-identical against a round-3
    // backend during a staggered deploy.
    final calendar = (data['calendar'] as List<dynamic>?) ?? const [];
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
                    Icon(
                      Icons.payments_outlined,
                      color: context.tealAccent,
                      size: 18,
                    ),
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
                        child: Icon(
                          Icons.error_outline,
                          size: 15,
                          color: context.warning,
                        ),
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
                        : formatPercent(context, blendedYield, digits: 2),
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
              ...(_showAllPayers ? payers : payers.take(_maxPayers)).map(
                (c) => _payerRow(c as Map<String, dynamic>),
              ),
              if (payers.length > _maxPayers)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () =>
                        setState(() => _showAllPayers = !_showAllPayers),
                    child: Text(
                      _showAllPayers
                          ? l.pfDivShowFewerPayers
                          : l.pfDivShowAllPayers(payers.length),
                    ),
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
              ...upcoming.map(
                (e) => _exDateRow(e as Map<String, dynamic>, perYearBySymbol),
              ),
            ],
            if (calendar.isNotEmpty) ...[
              const SizedBox(height: 8),
              Divider(height: 24, color: context.hairline),
              // Same expander pattern as the payers "Show all" toggle
              // above — a plain TextButton and a plain conditional, no
              // bespoke animation.
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () =>
                      setState(() => _showCalendar = !_showCalendar),
                  icon: Icon(
                    _showCalendar ? Icons.expand_less : Icons.expand_more,
                    size: 18,
                  ),
                  label: Text(
                    _showCalendar ? l.calHideCalendar : l.calShowCalendar,
                  ),
                ),
              ),
              if (_showCalendar) ...[
                const SizedBox(height: 8),
                DividendCalendar(
                  calendar: calendar,
                  conversionFactor: widget.conversionFactor,
                  currencyFormat: widget.currencyFormat,
                ),
              ],
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
              Text(
                label,
                style: TextStyle(color: context.textMuted, fontSize: 12),
              ),
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
                              : '${formatPercent(context, yieldPct, digits: 2)} · ${l.divPaymentsPerYear(perYear)}',
                          style: TextStyle(
                            color: context.textFaint,
                            fontSize: 11,
                          ),
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
                    Icon(
                      Icons.chevron_right,
                      size: 16,
                      color: context.textFaint,
                    ),
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
    final dateLabel = parsed == null
        ? dateStr
        : DateFormat.yMMMd().format(parsed);
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
