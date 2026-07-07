import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../utils/theme_colors.dart';
import '../utils/url_opener.dart';
import '../l10n/app_localizations.dart';
import 'skeleton.dart';

/// Realized capital gains/losses from `/dashboard/realized-gains`.
///
/// Surfaces the per-sell P&L the FIFO engine crystallizes into `lot_disposals`
/// but the holdings view never shows. While loading it holds its place with a
/// fixed-height skeleton; a failed fetch shows an inline error with retry and
/// no realized sells shows a one-line empty state (the card used to vanish
/// silently in all three cases).
class RealizedGainsCard extends StatefulWidget {
  final ApiService apiService;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const RealizedGainsCard({
    super.key,
    required this.apiService,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  @override
  State<RealizedGainsCard> createState() => _RealizedGainsCardState();
}

class _RealizedGainsCardState extends State<RealizedGainsCard> {
  bool _loading = true;
  bool _failed = false;
  Map<String, dynamic>? _data;
  static const _maxRows = 8;
  // Whether the disposal list shows everything or just the newest _maxRows.
  bool _expanded = false;
  // Year filter driven by the chips row; null = All. While a chip refetch is
  // in flight the card stays mounted and just fades/disables the content
  // below the chips (no full-skeleton flash).
  int? _selectedYear;
  bool _refetching = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final data =
          await widget.apiService.getRealizedGains(year: _selectedYear);
      if (mounted) {
        setState(() {
          _data = data;
          _failed = false;
        });
      }
    } catch (_) {
      // Surfaced as an inline error row with retry (was silently swallowed,
      // which made the whole card vanish on a failed fetch).
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _retry() {
    setState(() {
      _loading = true;
      _failed = false;
    });
    _load();
  }

  /// Chip tap: refetch the disposal list for [year] (null = All) while the
  /// previous data stays on screen, faded. A stale response (user tapped
  /// another chip mid-flight) is dropped.
  Future<void> _selectYear(int? year) async {
    if (year == _selectedYear) return;
    setState(() {
      _selectedYear = year;
      _refetching = true;
      _expanded = false;
    });
    try {
      final data = await widget.apiService.getRealizedGains(year: year);
      if (mounted && _selectedYear == year) {
        setState(() {
          _data = data;
          _failed = false;
        });
      }
    } catch (_) {
      if (mounted && _selectedYear == year) setState(() => _failed = true);
    } finally {
      if (mounted && _selectedYear == year) {
        setState(() => _refetching = false);
      }
    }
  }

  /// Same-origin navigation so the session cookie rides along and the
  /// Content-Disposition: attachment reply downloads without leaving the app
  /// (the pattern tax_planning_screen.dart uses for its exports).
  void _exportCsv() {
    final year = _selectedYear;
    openUrlSameTab(
      '${widget.apiService.baseUrl}/dashboard/realized-gains/export'
      '${year != null ? '?year=$year' : ''}',
    );
  }

  String _money(double usd) =>
      widget.currencyFormat.format(usd * widget.conversionFactor);

  /// Signed money with a leading + on gains, for the P&L column.
  String _signedMoney(double usd) {
    final v = usd * widget.conversionFactor;
    final formatted = widget.currencyFormat.format(v.abs());
    if (v > 0) return '+$formatted';
    if (v < 0) return '-$formatted';
    return formatted;
  }

  Color _pnlColor(double v) =>
      v > 0 ? context.positive : (v < 0 ? context.negative : context.textMuted);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    // Fixed-height skeleton while loading so the ~700px card doesn't pop in
    // late and shove the layout once data lands.
    if (_loading) return _skeletonCard();
    if (_failed) return _errorCard(l);
    final data = _data;
    if (data == null) return const SizedBox.shrink();
    final disposals = (data['disposals'] as List<dynamic>?) ?? const [];
    // Whole-card empty state only when there are no gains at all — a year
    // chip whose year has no disposals keeps the chips row visible and shows
    // an inline message instead.
    if (disposals.isEmpty && _selectedYear == null) return _emptyCard(l);

    final summary = (data['summary'] as Map<String, dynamic>?) ?? const {};
    final ytd = (summary['ytd_realized_usd'] as num?)?.toDouble() ?? 0.0;
    final total = (summary['total_realized_usd'] as num?)?.toDouble() ?? 0.0;
    final currentYear = DateTime.now().year;

    // Chip years: by_year ∪ current year, newest first (by_year always covers
    // full history regardless of the active filter).
    final byYear = (data['by_year'] as List<dynamic>?) ?? const [];
    final years = <int>{currentYear};
    final byYearTotals = <int, double>{};
    for (final row in byYear) {
      if (row is! Map<String, dynamic>) continue;
      final y = (row['year'] as num?)?.toInt();
      if (y == null) continue;
      years.add(y);
      byYearTotals[y] = (row['realized_usd'] as num?)?.toDouble() ?? 0.0;
    }
    final yearChips = years.toList()..sort((a, b) => b.compareTo(a));

    // First tile: the selected year's total from by_year; "All" and the
    // current year fall back to the backend's YTD figure (same number, and
    // it exists even before the first disposal of the year).
    final selYear = _selectedYear;
    final firstTileYear = selYear ?? currentYear;
    final firstTileUsd = (selYear == null || selYear == currentYear)
        ? ytd
        : (byYearTotals[selYear] ?? 0.0);

    // Taxable-vs-total caption (C-C): only when the shown list actually
    // contains a tax-advantaged row AND the backend sent the subtotal —
    // an older backend without C-C simply never shows it.
    final taxable = (summary['taxable_realized_usd'] as num?)?.toDouble();
    final hasAdvantaged =
        disposals.any((d) => d is Map && d['tax_advantaged'] == true);
    final periodTotal = selYear == null ? total : firstTileUsd;

    final visible =
        _expanded ? disposals : disposals.take(_maxRows).toList();

    return _cardShell(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleRow(l, showExport: true),
          const SizedBox(height: 12),
          _yearChipsRow(l, yearChips),
          const SizedBox(height: 12),
          // Everything below the chips fades + goes inert while a year
          // refetch is in flight — the card never re-skeletons on switch.
          AnimatedOpacity(
            opacity: _refetching ? 0.45 : 1.0,
            duration: const Duration(milliseconds: 150),
            child: IgnorePointer(
              ignoring: _refetching,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                          child: _summaryTile(
                              l.rgYearTile(firstTileYear.toString()),
                              firstTileUsd)),
                      const SizedBox(width: 12),
                      Expanded(child: _summaryTile(l.rgAllTime, total)),
                    ],
                  ),
                  // C1 (round 3): the caption row is RESERVED whenever the
                  // backend sent the taxable subtotal and the period has
                  // disposals — an all-taxable year renders a fixed line at
                  // the exact same height instead of dropping the row, so
                  // flipping year chips never shifts the layout below the
                  // tiles. Absent only when `taxable == null` (older
                  // backend) or the shown list is empty.
                  if (taxable != null && disposals.isNotEmpty) ...[
                    const SizedBox(height: 10),
                    hasAdvantaged
                        ? _taxableCaption(l, taxable, periodTotal)
                        : _allTaxableCaption(l),
                  ],
                  const SizedBox(height: 8),
                  Divider(height: 24, color: context.hairline),
                  if (disposals.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        l.rgxNoSalesInYear(firstTileYear.toString()),
                        style: TextStyle(
                            color: context.textFaint, fontSize: 12),
                      ),
                    ),
                  ...visible.map(
                      (d) => _disposalRow(d as Map<String, dynamic>)),
                  if (disposals.length > _maxRows)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: InkWell(
                        onTap: () =>
                            setState(() => _expanded = !_expanded),
                        borderRadius: BorderRadius.circular(6),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              vertical: 6, horizontal: 4),
                          child: Text(
                            _expanded
                                ? l.rgShowFewer
                                : l.rgShowAll(disposals.length),
                            style: TextStyle(
                              fontSize: 12,
                              color: context.tealAccent,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// `All · 2026 · 2025` pill selector. Horizontal scroll keeps long year
  /// lists from wrapping the card.
  Widget _yearChipsRow(AppLocalizations l, List<int> years) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: [
          _yearChip(l.rgxAllYears, _selectedYear == null,
              () => _selectYear(null)),
          for (final y in years) ...[
            const SizedBox(width: 8),
            _yearChip('$y', _selectedYear == y, () => _selectYear(y)),
          ],
        ],
      ),
    );
  }

  Widget _yearChip(String label, bool selected, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(16),
      child: Container(
        height: 32,
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected
              ? context.tealAccent.withValues(alpha: 0.12)
              : context.tint(0.04),
          borderRadius: BorderRadius.circular(16),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: selected ? context.tealAccent : context.textMuted,
          ),
        ),
      ),
    );
  }

  /// "Taxable +$X of +$Y — the rest is inside tax-advantaged accounts",
  /// with the taxable figure emphasized. Reconciles this card with Tax
  /// planning: the backend computes the subtotal with the same
  /// tax-advantaged account-type list Tax planning uses.
  Widget _taxableCaption(
      AppLocalizations l, double taxable, double periodTotal) {
    return Text.rich(
      TextSpan(
        style: TextStyle(fontSize: 11.5, color: context.textMuted),
        children: [
          TextSpan(text: '${l.rgxTaxableCaptionPrefix} '),
          TextSpan(
            text: _signedMoney(taxable),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          TextSpan(
              text:
                  ' ${l.rgxTaxableCaptionSuffix(_signedMoney(periodTotal))}'),
        ],
      ),
    );
  }

  /// C1 variant for an all-taxable period: same Text.rich shape and base
  /// style (11.5px, textMuted) as [_taxableCaption], so the two captions
  /// have identical line metrics and swapping them is a zero-pixel shift.
  Widget _allTaxableCaption(AppLocalizations l) {
    return Text.rich(
      TextSpan(
        style: TextStyle(fontSize: 11.5, color: context.textMuted),
        text: l.rg3AllTaxable,
      ),
    );
  }

  /// Shared Card chrome so the skeleton/error/empty states keep the exact
  /// footprint and styling of the loaded card.
  Widget _cardShell(Widget child) {
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(padding: EdgeInsets.all(pad), child: child),
    );
  }

  /// [showExport] is only true on the loaded card — the skeleton, error and
  /// empty states carry no download affordance.
  Widget _titleRow(AppLocalizations l, {bool showExport = false}) {
    return Row(
      children: [
        Icon(Icons.trending_up_rounded, color: context.tealAccent, size: 18),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            l.rgTitle,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: context.textPrimary,
            ),
          ),
        ),
        if (showExport)
          IconButton(
            onPressed: _exportCsv,
            tooltip: l.rgxExportCsvTooltip,
            icon: Icon(Icons.download_outlined,
                size: 18, color: context.textMuted),
            padding: EdgeInsets.zero,
            constraints:
                const BoxConstraints.tightFor(width: 32, height: 32),
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }

  /// Layout-true placeholder: title line, the two summary tiles, and a few
  /// disposal-row lines, all at their real heights.
  Widget _skeletonCard() {
    return _cardShell(
      const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SkeletonBox(width: 150, height: 18),
          SizedBox(height: 12),
          // Placeholder at the year-chips row's height (32px pills).
          SkeletonBox(
            width: 180,
            height: 32,
            borderRadius: BorderRadius.all(Radius.circular(16)),
          ),
          SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: SkeletonBox(
                  height: 68,
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                ),
              ),
              SizedBox(width: 12),
              Expanded(
                child: SkeletonBox(
                  height: 68,
                  borderRadius: BorderRadius.all(Radius.circular(12)),
                ),
              ),
            ],
          ),
          SizedBox(height: 32),
          SkeletonBox(height: 14),
          SizedBox(height: 18),
          SkeletonBox(height: 14),
          SizedBox(height: 18),
          SkeletonBox(height: 14),
        ],
      ),
    );
  }

  Widget _errorCard(AppLocalizations l) {
    return _cardShell(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleRow(l),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.error_outline, size: 16, color: context.negative),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.rgLoadError,
                  style: TextStyle(color: context.textMuted, fontSize: 12),
                ),
              ),
              TextButton(
                onPressed: _retry,
                child: Text(l.rgRetry),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _emptyCard(AppLocalizations l) {
    return _cardShell(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _titleRow(l),
          const SizedBox(height: 12),
          Text(
            l.rgEmpty,
            style: TextStyle(color: context.textFaint, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _summaryTile(String label, double usd) {
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
            _signedMoney(usd),
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: _pnlColor(usd),
            ),
          ),
        ],
      ),
    );
  }

  Widget _disposalRow(Map<String, dynamic> d) {
    final l = AppLocalizations.of(context);
    final symbol = d['symbol']?.toString() ?? '';
    final name = d['name']?.toString() ?? '';
    final sellDate = d['sell_date']?.toString() ?? '';
    final pnl = (d['realized_pnl_usd'] as num?)?.toDouble() ?? 0.0;
    final proceeds = (d['proceeds_usd'] as num?)?.toDouble() ?? 0.0;
    final longTerm = d['long_term']; // bool or null
    // C-C context fields — absent on an older backend, in which case the row
    // renders exactly as it did in round 1 (no badge, no account).
    final taxAdvantaged = d['tax_advantaged'] == true;
    final account = d['account_name']?.toString() ?? '';

    final parsed = DateTime.tryParse(sellDate);
    final dateLabel =
        parsed == null ? sellDate : DateFormat.yMMMd().format(parsed);
    final subLine = account.isEmpty
        ? '$dateLabel · ${l.rgProceeds} ${_money(proceeds)}'
        : '$dateLabel · $account · ${l.rgProceeds} ${_money(proceeds)}';

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        symbol.isNotEmpty ? symbol : name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    if (longTerm is bool) ...[
                      const SizedBox(width: 8),
                      _termChip(longTerm ? l.rgLongTerm : l.rgShortTerm,
                          longTerm),
                    ],
                    if (taxAdvantaged) ...[
                      const SizedBox(width: 6),
                      Tooltip(
                        message: l.rgxTaxAdvTooltip,
                        child:
                            _pillChip(l.rgxTaxAdvBadge, context.warning),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  subLine,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: context.textFaint, fontSize: 11),
                ),
              ],
            ),
          ),
          Text(
            _signedMoney(pnl),
            style: TextStyle(
              color: _pnlColor(pnl),
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _termChip(String label, bool longTerm) =>
      _pillChip(label, longTerm ? context.info : context.warning);

  Widget _pillChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }
}
