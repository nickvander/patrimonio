import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/theme_colors.dart';
import 'dividend_detail_sheet.dart';
import 'skeleton.dart';

/// Test seam for [InstrumentDetailSheet]: matches the shape of
/// [ApiService.getInstrumentDetail] so widget tests can feed canned C-A
/// payloads without touching the network (subclassing ApiService is off the
/// table in the test VM). Production callers never set it.
typedef InstrumentDetailFetcher = Future<Map<String, dynamic>> Function(
    String symbol, {String range});

/// Opens the per-holding instrument detail sheet (contract C-F — the
/// holdings-table row tap imports and calls exactly this). Same modal
/// chrome as the dividend detail sheet: scroll-controlled, ~90% max
/// height, surface-colored, rounded top, dismissed by drag / Esc /
/// tapping the barrier. Self-fetching — callers pass context only.
Future<void> showInstrumentSheet(
  BuildContext context, {
  required ApiService apiService,
  required String symbol,
  required double conversionFactor,
  required NumberFormat currencyFormat,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => InstrumentDetailSheet(
      apiService: apiService,
      symbol: symbol,
      conversionFactor: conversionFactor,
      currencyFormat: currencyFormat,
    ),
  );
}

/// Per-instrument drill-down, opened by tapping a holdings-table row.
/// Renders GET /dashboard/instruments/{symbol} (contract C-A):
///   • header: symbol + security name,
///   • the big current price with a day-change chip and an honest
///     `as of <date>` caption when the stored close predates today,
///   • an fl_chart price line (gradient fill, hover tooltip, compact
///     axes) with 1M · 3M · 1Y · Max range chips that refetch,
///   • a stat grid (market value, quantity, cost basis, gain, portfolio
///     weight, asset class) — unknowable stats render an em-dash,
///   • the purchase lots with a totals row,
///   • the accounts holding the symbol (type chip + tax-advantaged badge),
///   • and a link into the sibling [DividendDetailSheet].
///
/// Opaque symbols (401k trusts, CUR:USD) arrive with `prices: []` and null
/// day-change stats; the chart area degrades to a muted empty state while
/// everything else still renders — never an error.
class InstrumentDetailSheet extends StatefulWidget {
  final ApiService apiService;
  final String symbol;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  /// Widget tests inject a canned-payload fetcher here; null in production.
  @visibleForTesting
  final InstrumentDetailFetcher? fetchOverride;

  const InstrumentDetailSheet({
    super.key,
    required this.apiService,
    required this.symbol,
    required this.conversionFactor,
    required this.currencyFormat,
    this.fetchOverride,
  });

  @override
  State<InstrumentDetailSheet> createState() => _InstrumentDetailSheetState();
}

class _InstrumentDetailSheetState extends State<InstrumentDetailSheet> {
  static const double _kChartHeight = 180.0;
  static const List<String> _kRanges = ['1m', '3m', '1y', 'max'];

  Map<String, dynamic> _data = {};
  bool _loading = true;
  String? _error;
  String _range = '1y';

  /// True while a range-chip refetch is in flight. The chart dims instead
  /// of collapsing back to the skeleton so chips swap data without any
  /// layout shift.
  bool _rangeLoading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<Map<String, dynamic>> _fetch(String range) {
    final f = widget.fetchOverride;
    if (f != null) return f(widget.symbol, range: range);
    return widget.apiService.getInstrumentDetail(widget.symbol, range: range);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final data = await _fetch(_range);
      if (!mounted) return;
      setState(() {
        _data = data;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = AppLocalizations.of(context).insLoadError;
        _loading = false;
      });
    }
  }

  /// Range-chip switch: keep the current payload on screen (dimmed chart)
  /// while the new range loads, so there is no layout jump. A failed
  /// refetch restores the previous selection instead of nuking the sheet.
  Future<void> _setRange(String range) async {
    if (range == _range || _rangeLoading) return;
    final previous = _range;
    setState(() {
      _range = range;
      _rangeLoading = true;
    });
    try {
      final data = await _fetch(range);
      if (!mounted || _range != range) return;
      setState(() {
        _data = data;
        _rangeLoading = false;
      });
    } catch (_) {
      if (!mounted || _range != range) return;
      setState(() {
        _range = previous;
        _rangeLoading = false;
      });
    }
  }

  // ---------- formatting helpers ----------

  /// USD figure scaled into the display currency, same pattern as the
  /// dividend sheet and the cards behind it.
  String _money(double usd) =>
      widget.currencyFormat.format(usd * widget.conversionFactor);

  /// Explicitly signed USD figure ("+$1,985.80"); negatives already carry
  /// the sign from the format.
  String _signedMoney(double usd) => usd >= 0 ? '+${_money(usd)}' : _money(usd);

  String _signedPct(double pct, {int digits = 2}) =>
      '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(digits)}%';

  /// Per-unit amounts (price, lot cost) stay in the instrument's native
  /// currency and can be sub-dollar for some funds, so they keep up to
  /// four decimals — mirrors the dividend sheet's per-share helper.
  String _nativeAmount(double v) {
    final currency = (_data['currency'] ?? 'USD').toString();
    final fmt = NumberFormat.currency(
      symbol: currency == 'MXN' ? r'MX$' : r'$',
      decimalDigits: v.abs() < 1 ? 4 : 2,
    );
    return fmt.format(v);
  }

  String _qty(double v) => NumberFormat('#,##0.####').format(v);

  DateTime? _parseDate(dynamic raw) {
    final s = (raw ?? '').toString();
    return s.isEmpty ? null : DateTime.tryParse(s);
  }

  String? _fmtDate(dynamic raw) {
    final d = _parseDate(raw);
    return d == null ? null : DateFormat.yMMMd().format(d);
  }

  /// Canonical asset-class key → the same display name the allocation
  /// bands and filter chips use, so the sheet never invents a new label.
  String _assetClassLabel(AppLocalizations l, String key) {
    switch (key) {
      case 'equity':
        return l.pfFilterAssetEquity;
      case 'bonds':
        return l.pfFilterAssetBonds;
      case 'cash':
        return l.pfFilterAssetCash;
      case 'crypto':
        return l.pfFilterAssetCrypto;
      case 'real_estate':
        return l.pfFilterAssetRealEstate;
      case 'commodities':
        return l.pfFilterAssetCommodities;
      case 'other':
        return l.pfFilterAssetOther;
      default:
        return key;
    }
  }

  /// "roth ira" → "Roth IRA", "brokerage" → "Brokerage" — for the account
  /// type chips. Known acronyms stay upper-cased.
  String _prettyType(String raw) {
    const acronyms = {'ira', 'hsa', '401k', '403b', '457b', 'cd', 'etf'};
    return raw
        .replaceAll('_', ' ')
        .split(' ')
        .where((p) => p.isNotEmpty)
        .map((p) => acronyms.contains(p.toLowerCase())
            ? p.toUpperCase()
            : p[0].toUpperCase() + p.substring(1).toLowerCase())
        .join(' ');
  }

  // ---------- build ----------

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // Cap the sheet at most of the viewport; it scrolls within.
    final maxHeight = MediaQuery.sizeOf(context).height * 0.9;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHandle(),
            _buildHeader(l10n),
            Flexible(child: _buildBody(l10n)),
          ],
        ),
      ),
    );
  }

  Widget _buildHandle() {
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

  Widget _buildHeader(AppLocalizations l10n) {
    final name = (_data['name'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 12),
      child: Row(
        children: [
          Icon(Icons.candlestick_chart_outlined, color: context.tealAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  widget.symbol,
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (name.isNotEmpty)
                  Text(
                    name,
                    style: TextStyle(fontSize: 12, color: context.textSubtle),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: l10n.actionClose,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(AppLocalizations l10n) {
    if (_loading) return _buildSkeleton();
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!,
                textAlign: TextAlign.center,
                style: TextStyle(color: context.textMuted)),
            const SizedBox(height: 12),
            FilledButton(onPressed: _load, child: Text(l10n.pfDivRetry)),
          ],
        ),
      );
    }

    final lots = (_data['lots'] as List?) ?? const [];
    final accounts = (_data['accounts'] as List?) ?? const [];

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        _buildPriceHeadline(l10n),
        const SizedBox(height: 16),
        _buildChartSection(l10n),
        const SizedBox(height: 24),
        _buildStatGrid(l10n),
        if (lots.isNotEmpty) ...[
          const SizedBox(height: 24),
          _buildLots(l10n, lots),
        ],
        if (accounts.isNotEmpty) ...[
          const SizedBox(height: 24),
          _buildAccounts(l10n, accounts),
        ],
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _openDividendDetail,
            icon: const Icon(Icons.payments_outlined, size: 18),
            label: Text('${l10n.insDividendsLink} →'),
          ),
        ),
      ],
    );
  }

  /// Layout-true placeholder mirroring the loaded body — price headline,
  /// chart block + range chips, and two stat-tile rows at their real
  /// heights — so the sheet doesn't shift when data lands.
  Widget _buildSkeleton() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: const [
        SkeletonBox(width: 150, height: 30),
        SizedBox(height: 8),
        SkeletonBox(width: 96, height: 12),
        SizedBox(height: 16),
        SkeletonBox(
          height: _kChartHeight,
          borderRadius: BorderRadius.all(Radius.circular(12)),
        ),
        SizedBox(height: 10),
        Row(
          children: [
            SkeletonBox(width: 46, height: 28),
            SizedBox(width: 8),
            SkeletonBox(width: 46, height: 28),
            SizedBox(width: 8),
            SkeletonBox(width: 46, height: 28),
            SizedBox(width: 8),
            SkeletonBox(width: 46, height: 28),
          ],
        ),
        SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: SkeletonBox(
                height: 62,
                borderRadius: BorderRadius.all(Radius.circular(12)),
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: SkeletonBox(
                height: 62,
                borderRadius: BorderRadius.all(Radius.circular(12)),
              ),
            ),
          ],
        ),
        SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: SkeletonBox(
                height: 62,
                borderRadius: BorderRadius.all(Radius.circular(12)),
              ),
            ),
            SizedBox(width: 12),
            Expanded(
              child: SkeletonBox(
                height: 62,
                borderRadius: BorderRadius.all(Radius.circular(12)),
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ---------- price headline ----------

  Widget _buildPriceHeadline(AppLocalizations l10n) {
    final price = (_data['price'] as num?)?.toDouble();
    final dayPct = (_data['day_change_pct'] as num?)?.toDouble();
    final dayUsd = (_data['day_change_usd'] as num?)?.toDouble();
    final asOf = _parseDate(_data['price_as_of']);
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final stale = asOf != null && asOf.isBefore(today);

    if (price == null && dayPct == null) {
      // Opaque symbol without even a stored quote: the stat grid below
      // still carries the market value, so skip the headline entirely
      // rather than showing a lonely em-dash.
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 10,
          runSpacing: 6,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            if (price != null)
              Text(
                _nativeAmount(price),
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: context.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            if (dayPct != null) _dayChangeChip(dayPct, dayUsd),
          ],
        ),
        if (stale) ...[
          const SizedBox(height: 4),
          Text(
            l10n.insAsOf(DateFormat.MMMd().format(asOf)),
            style: TextStyle(fontSize: 11, color: context.textFaint),
          ),
        ],
      ],
    );
  }

  Widget _dayChangeChip(double pct, double? usd) {
    final up = pct >= 0;
    final color = up ? context.positive : context.negative;
    final text = StringBuffer()
      ..write(up ? '▲ ' : '▼ ')
      ..write(_signedPct(pct));
    if (usd != null) text.write(' · ${_signedMoney(usd)}');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text.toString(),
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: color,
          fontFeatures: const [FontFeature.tabularFigures()],
        ),
      ),
    );
  }

  // ---------- price chart ----------

  List<({DateTime date, double close})> _pricePoints() {
    final raw = (_data['prices'] as List?) ?? const [];
    final points = <({DateTime date, double close})>[];
    for (final entry in raw.whereType<Map>()) {
      final p = entry.cast<String, dynamic>();
      final date = _parseDate(p['date']);
      final close = (p['close'] as num?)?.toDouble();
      if (date != null && close != null) points.add((date: date, close: close));
    }
    return points;
  }

  Widget _buildChartSection(AppLocalizations l10n) {
    final points = _pricePoints();
    final chart = points.length < 2
        ? _emptyChartState(l10n)
        : _priceChart(points);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RepaintBoundary(
          child: SizedBox(
            height: _kChartHeight,
            child: AnimatedOpacity(
              // Dim (never collapse) during a range refetch — no layout shift.
              opacity: _rangeLoading ? 0.35 : 1.0,
              duration: const Duration(milliseconds: 150),
              child: chart,
            ),
          ),
        ),
        const SizedBox(height: 10),
        _rangeChips(l10n),
      ],
    );
  }

  /// The 401k-trust / CUR:USD path: same footprint as the chart so opaque
  /// symbols keep the exact layout, just with a calm placeholder.
  Widget _emptyChartState(AppLocalizations l10n) {
    return Container(
      decoration: BoxDecoration(
        color: context.tileSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.hairline),
      ),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.show_chart, size: 32, color: context.textFaint),
            const SizedBox(height: 8),
            Text(
              l10n.insNoPriceHistory,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: context.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _priceChart(List<({DateTime date, double close})> points) {
    final currency = (_data['currency'] ?? 'USD').toString();
    // Period direction decides the line color, Robinhood-style.
    final color = points.last.close >= points.first.close
        ? context.positive
        : context.negative;

    final spots = <FlSpot>[
      for (var i = 0; i < points.length; i++)
        FlSpot(i.toDouble(), points[i].close),
    ];

    var rawMin = points.first.close;
    var rawMax = points.first.close;
    for (final p in points) {
      if (p.close < rawMin) rawMin = p.close;
      if (p.close > rawMax) rawMax = p.close;
    }
    // Pad the y-window so the line doesn't hug the chart edges; guard the
    // all-flat series (a single close repeated) against a zero interval.
    final pad = (rawMax - rawMin) == 0 ? (rawMax.abs() * 0.05 + 1) : (rawMax - rawMin) * 0.10;
    final minY = rawMin - pad;
    final maxY = rawMax + pad;
    final yInterval = (maxY - minY) / 4;

    // ~4 date labels along the bottom; month+day inside a quarter,
    // month+year beyond it.
    final spanDays = points.last.date.difference(points.first.date).inDays;
    final dateFmt =
        spanDays > 130 ? DateFormat('MMM yy') : DateFormat('MMM d');
    final xInterval =
        ((points.length - 1) / 3).clamp(1, double.infinity).toDouble();

    final compactAxis = NumberFormat.compactSimpleCurrency(name: currency);

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: (spots.length - 1).toDouble(),
        minY: minY,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: yInterval,
          getDrawingHorizontalLine: (value) =>
              FlLine(color: context.tint(0.05), strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          show: true,
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: xInterval,
              getTitlesWidget: (value, meta) {
                final index = value.round();
                if (index < 0 || index >= points.length) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    dateFmt.format(points[index].date),
                    style: TextStyle(color: context.textSubtle, fontSize: 10),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 46,
              interval: yInterval,
              getTitlesWidget: (value, meta) {
                // Skip labels that crowd the top/bottom edge — same guard
                // as the net-worth chart.
                final edgeBuffer = yInterval * 0.4;
                if (value <= minY + edgeBuffer || value >= maxY - edgeBuffer) {
                  return const SizedBox.shrink();
                }
                return Text(
                  compactAxis.format(value),
                  style: TextStyle(color: context.textSubtle, fontSize: 10),
                );
              },
            ),
          ),
        ),
        lineTouchData: LineTouchData(
          // Snap-to-nearest-x hover (the net-worth chart's interaction):
          // the tooltip fires for the closest sample regardless of the
          // cursor's vertical position.
          touchSpotThreshold: 100000,
          distanceCalculator: (touchPoint, spotPixelCoordinates) =>
              (touchPoint.dx - spotPixelCoordinates.dx).abs(),
          handleBuiltInTouches: true,
          getTouchedSpotIndicator: (barData, spotIndexes) {
            return spotIndexes.map((idx) {
              return TouchedSpotIndicatorData(
                FlLine(color: context.tint(0.35), strokeWidth: 1),
                FlDotData(
                  show: true,
                  getDotPainter: (spot, percent, bar, i) => FlDotCirclePainter(
                    radius: 4,
                    color: color,
                    strokeWidth: 2.5,
                    strokeColor: Theme.of(context).colorScheme.surface,
                  ),
                ),
              );
            }).toList();
          },
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (touchedSpot) => context.tooltipSurface,
            tooltipRoundedRadius: 12,
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((spot) {
                final idx = spot.x.round().clamp(0, points.length - 1);
                final p = points[idx];
                return LineTooltipItem(
                  '${DateFormat.yMMMd().format(p.date)}\n',
                  TextStyle(
                    color: context.tooltipOnSurfaceMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.normal,
                  ),
                  children: [
                    TextSpan(
                      text: _nativeAmount(p.close),
                      style: TextStyle(
                        color: context.tooltipOnSurface,
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                );
              }).toList();
            },
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            curveSmoothness: 0.2,
            preventCurveOverShooting: true,
            color: color,
            barWidth: 2.5,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  color.withValues(alpha: 0.22),
                  color.withValues(alpha: 0.0),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _rangeChips(AppLocalizations l10n) {
    String label(String key) {
      switch (key) {
        case '1m':
          return l10n.insRange1m;
        case '3m':
          return l10n.insRange3m;
        case '1y':
          return l10n.insRange1y;
        default:
          return l10n.insRangeMax;
      }
    }

    return Row(
      children: [
        for (final key in _kRanges) ...[
          _rangeChip(key, label(key)),
          if (key != _kRanges.last) const SizedBox(width: 8),
        ],
      ],
    );
  }

  Widget _rangeChip(String key, String label) {
    final selected = _range == key;
    final accent = context.tealAccent;
    return InkWell(
      onTap: selected || _rangeLoading ? null : () => _setRange(key),
      borderRadius: BorderRadius.circular(8),
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? accent.withValues(alpha: 0.12) : context.tint(0.04),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: selected ? accent : context.textMuted,
          ),
        ),
      ),
    );
  }

  // ---------- stat grid ----------

  Widget _buildStatGrid(AppLocalizations l10n) {
    final valueUsd = (_data['value_usd'] as num?)?.toDouble();
    final quantity = (_data['quantity'] as num?)?.toDouble();
    final costBasis = (_data['cost_basis_usd'] as num?)?.toDouble();
    final gainUsd = (_data['gain_loss_usd'] as num?)?.toDouble();
    final gainPct = (_data['gain_loss_pct'] as num?)?.toDouble();
    final weightPct = (_data['portfolio_weight_pct'] as num?)?.toDouble();
    final assetClass = (_data['asset_class'] ?? '').toString();

    final gainText = gainUsd == null
        ? '—'
        : '${_signedMoney(gainUsd)}${gainPct == null ? '' : ' (${_signedPct(gainPct)})'}';
    final gainColor = gainUsd == null
        ? null
        : (gainUsd >= 0 ? context.positive : context.negative);

    final tiles = <Widget>[
      _statTile(l10n.insStatMarketValue,
          valueUsd == null ? '—' : _money(valueUsd)),
      _statTile(
          l10n.insStatQuantity, quantity == null ? '—' : _qty(quantity)),
      _statTile(l10n.insStatCostBasis,
          costBasis == null ? '—' : _money(costBasis)),
      _statTile(l10n.insStatGain, gainText, valueColor: gainColor),
      _statTile(l10n.insStatWeight,
          weightPct == null ? '—' : '${weightPct.toStringAsFixed(2)}%'),
      _assetClassTile(l10n, assetClass),
    ];

    return LayoutBuilder(builder: (ctx, c) {
      const perRow = 2;
      final tileWidth = (c.maxWidth - 12 * (perRow - 1)) / perRow;
      return Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final tile in tiles) SizedBox(width: tileWidth, child: tile),
        ],
      );
    });
  }

  Widget _statTile(String label, String value, {Color? valueColor}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: context.tileSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(fontSize: 11, color: context.textSubtle),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: valueColor ?? context.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  /// Same tile chrome as [_statTile] but the value renders as a chip, so
  /// the asset class visually echoes the allocation bands.
  Widget _assetClassTile(AppLocalizations l10n, String assetClass) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: context.tileSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.insStatAssetClass,
            style: TextStyle(fontSize: 11, color: context.textSubtle),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          if (assetClass.isEmpty)
            Text(
              '—',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: context.textPrimary,
              ),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: context.tealAccent.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                _assetClassLabel(l10n, assetClass),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: context.tealAccent,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  // ---------- purchase lots ----------

  Widget _buildLots(AppLocalizations l10n, List<dynamic> lots) {
    final rows = lots
        .whereType<Map>()
        .map((m) => m.cast<String, dynamic>())
        .toList(growable: false);

    var totalQty = 0.0;
    var totalUsd = 0.0;
    for (final r in rows) {
      totalQty += (r['qty'] as num?)?.toDouble() ?? 0.0;
      totalUsd += (r['usd_cost'] as num?)?.toDouble() ?? 0.0;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(l10n.insLotsSection),
        const SizedBox(height: 8),
        Container(
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
                _lotRow(l10n, rows[i]),
              ],
              Divider(height: 1, color: context.hairline),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '${l10n.insLotsTotal} · ${l10n.pfSharesSuffix(_qty(totalQty))}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: context.textPrimary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    Text(
                      _money(totalUsd),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _lotRow(AppLocalizations l10n, Map<String, dynamic> lot) {
    final date = _fmtDate(lot['acquired_at']) ?? '—';
    final qty = (lot['qty'] as num?)?.toDouble() ?? 0.0;
    final costPerUnit = (lot['cost_per_unit'] as num?)?.toDouble();
    final usdCost = (lot['usd_cost'] as num?)?.toDouble();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: date,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: context.textPrimary,
                    ),
                  ),
                  TextSpan(
                    text:
                        ' · ${l10n.insLotQtyAtPrice(_qty(qty), costPerUnit == null ? '—' : _nativeAmount(costPerUnit))}',
                    style: TextStyle(color: context.textMuted),
                  ),
                ],
              ),
              style: const TextStyle(
                fontSize: 13,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            usdCost == null ? '—' : _money(usdCost),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: context.textMuted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  // ---------- accounts holding the symbol ----------

  Widget _buildAccounts(AppLocalizations l10n, List<dynamic> accounts) {
    final rows =
        accounts.whereType<Map>().map((m) => m.cast<String, dynamic>());

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel(l10n.pfDivDetailAccounts),
        const SizedBox(height: 8),
        Container(
          decoration: BoxDecoration(
            color: context.tileSurface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.hairline),
          ),
          child: Column(
            children: [
              for (final r in rows) _accountRow(l10n, r),
            ],
          ),
        ),
      ],
    );
  }

  Widget _accountRow(AppLocalizations l10n, Map<String, dynamic> r) {
    final name = (r['account_name'] ?? '').toString();
    final type = (r['account_type'] ?? '').toString();
    final taxAdvantaged = r['tax_advantaged'] == true;
    final valueUsd = (r['value_usd'] as num?)?.toDouble();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(
              name.isNotEmpty ? name : '—',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: context.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (type.isNotEmpty) ...[
            const SizedBox(width: 8),
            _smallChip(_prettyType(type), context.textMuted, context.tint(0.06)),
          ],
          if (taxAdvantaged) ...[
            const SizedBox(width: 6),
            _smallChip(l10n.pfDivDetailTaxAdvantaged, context.warning,
                context.warning.withValues(alpha: 0.12)),
          ],
          const SizedBox(width: 10),
          Text(
            valueUsd == null ? '—' : _money(valueUsd),
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: context.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _smallChip(String label, Color fg, Color bg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }

  // ---------- dividends link ----------

  Future<void> _openDividendDetail() {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => DividendDetailSheet(
        apiService: widget.apiService,
        symbol: widget.symbol,
        conversionFactor: widget.conversionFactor,
        currencyFormat: widget.currencyFormat,
      ),
    );
  }

  Widget _sectionLabel(String text) {
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
        color: context.textSubtle,
      ),
    );
  }
}
