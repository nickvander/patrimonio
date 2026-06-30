import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../components/date_range_selector.dart';
import '../services/api_service.dart';
import '../utils/theme_colors.dart';
import '../l10n/app_localizations.dart';

/// Portfolio performance: investment value over time (a line chart with a
/// range selector) plus the contribution-weighted "vs S&P 500" comparison.
///
/// The two used to be separate cards. They're merged here because they answer
/// the same question — "how is my portfolio doing?" — at the canonical place
/// in the screen hierarchy (overview → performance → allocation → holdings).
///
/// The performance line is a TRUE time-weighted return (cashflows divided out,
/// re-based to the selected range), shown against the S&P 500 indexed over the
/// same dates. This indexed overlay is legitimate precisely because TWR removes
/// contribution timing/size — unlike naively indexing dollar value (or net
/// worth) from ~0, which reports absurd returns by conflating contributions
/// with market gains. When the portfolio can't be priced historically (no
/// quote coverage) it falls back to the dollars-only line with no % (see the
/// note in `_valueSection`). The contribution-weighted "vs S&P" block below is
/// the complementary dollar-weighted read.
class PerformanceCard extends StatefulWidget {
  final ApiService apiService;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const PerformanceCard({
    super.key,
    required this.apiService,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  @override
  State<PerformanceCard> createState() => _PerformanceCardState();
}

/// The picker's curated set of benchmarks. `key` is the API value (matches the
/// backend `BENCHMARKS` table / `benchmark_prices.symbol`); `shortLabel`
/// resolves the localized pill/bar caption for the chosen index.
class _BenchmarkOption {
  final String key;
  final String Function(AppLocalizations) shortLabel;
  const _BenchmarkOption(this.key, this.shortLabel);
}

final List<_BenchmarkOption> _benchmarkOptions = [
  _BenchmarkOption('SP500', (l) => l.lwPerfBenchSp500),
  _BenchmarkOption('NDX', (l) => l.lwPerfBenchNdx),
  _BenchmarkOption('ACWI', (l) => l.lwPerfBenchAcwi),
  _BenchmarkOption('AGG', (l) => l.lwPerfBenchAgg),
  _BenchmarkOption('MXX', (l) => l.lwPerfBenchMxx),
];

class _PerformanceCardState extends State<PerformanceCard> {
  bool _loading = true;
  List<dynamic> _history = const [];
  Map<String, dynamic>? _comparison;
  Map<String, dynamic>? _twr;
  DateRange _range = DateRange.all;
  // Selected benchmark for both the TWR overlay and the contribution
  // comparison; persisted across rebuilds like _range. Defaults to the S&P 500,
  // which keeps the endpoints' default behavior when nothing is chosen.
  String _benchmark = 'SP500';
  // Phone-only: the money-weighted benchmark block sits behind a tap-to-expand
  // disclosure (collapsed by default). In-memory only — not persisted.
  bool _benchmarkExpanded = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // History + contribution comparison are quick; both best-effort.
    final results = await Future.wait([
      widget.apiService
          .getPortfolioValueHistory()
          .catchError((_) => <dynamic>[]),
      widget.apiService
          .getBenchmarkComparison(benchmark: _benchmark)
          .catchError((_) => <String, dynamic>{}),
    ]);
    if (!mounted) return;
    setState(() {
      _history = results[0] as List<dynamic>;
      final c = results[1] as Map<String, dynamic>;
      _comparison = c.isEmpty ? null : c;
      _loading = false;
    });

    // TWR is loaded separately: on a cold quote cache it triggers a per-symbol
    // Yahoo fetch and can take many seconds, so we paint the card immediately
    // (dollar line) and upgrade to the time-weighted view when it resolves.
    final t = await widget.apiService
        .getPortfolioTwr(benchmark: _benchmark)
        .catchError((_) => <String, dynamic>{});
    if (!mounted) return;
    setState(() {
      _twr = (t == null || t.isEmpty) ? null : t;
    });
  }

  /// Switch the benchmark and refetch the two benchmark-dependent series (the
  /// TWR overlay + the contribution comparison). The portfolio value history is
  /// benchmark-independent, so it's left untouched. The TWR is cleared first so
  /// the card falls back to the dollar line while the new index is fetched
  /// (a cold cache triggers a per-symbol Yahoo pull).
  Future<void> _onBenchmarkChanged(String key) async {
    if (key == _benchmark) return;
    setState(() {
      _benchmark = key;
      _twr = null;
    });
    final results = await Future.wait([
      widget.apiService
          .getBenchmarkComparison(benchmark: _benchmark)
          .catchError((_) => <String, dynamic>{}),
      widget.apiService
          .getPortfolioTwr(benchmark: _benchmark)
          .catchError((_) => <String, dynamic>{}),
    ]);
    if (!mounted) return;
    setState(() {
      final c = results[0] ?? const {};
      _comparison = c.isEmpty ? null : c;
      final t = results[1];
      _twr = (t == null || t.isEmpty) ? null : t;
    });
  }

  /// Localized short label for the currently selected benchmark (e.g. the pill
  /// caption). Falls back to the S&P 500 label for an unknown key.
  String _benchmarkLabel(AppLocalizations l) {
    return _benchmarkOptions
        .firstWhere((o) => o.key == _benchmark,
            orElse: () => _benchmarkOptions.first)
        .shortLabel(l);
  }

  /// TWR points are available + cover at least a sliver of the portfolio.
  bool get _hasTwr {
    final pts = _twr?['points'];
    return pts is List &&
        pts.length >= 2 &&
        ((_twr?['coverage_pct'] as num?)?.toDouble() ?? 0) > 0;
  }

  String _money(double usd) =>
      widget.currencyFormat.format(usd * widget.conversionFactor);

  List<dynamic> _filterByRange(List<dynamic> data) {
    if (data.isEmpty || _range == DateRange.all) return data;
    final now = DateTime.now();
    DateTime cutoff;
    switch (_range) {
      case DateRange.oneMonth:
        cutoff = now.subtract(const Duration(days: 30));
        break;
      case DateRange.yearToDate:
        cutoff = DateTime(now.year, 1, 1);
        break;
      case DateRange.oneYear:
        cutoff = now.subtract(const Duration(days: 365));
        break;
      case DateRange.fiveYears:
        cutoff = now.subtract(const Duration(days: 365 * 5));
        break;
      case DateRange.all:
        return data;
    }
    return data.where((p) {
      final d = DateTime.tryParse(p['date']?.toString() ?? '');
      if (d == null) return true;
      return d.isAfter(cutoff) || d.isAtSameMomentAs(cutoff);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);

    // Benchmark comparison validity.
    final c = _comparison;
    final invested = (c?['invested_usd'] as num?)?.toDouble() ?? 0;
    final lots = (c?['lot_count'] as num?)?.toInt() ?? 0;
    final hasBenchmark = c != null && invested > 0 && lots > 0;

    final hasHistory = _history.length >= 2;
    final showValue = hasHistory || _hasTwr;

    // Nothing to show → don't render an empty card.
    if (!showValue && !hasBenchmark) return const SizedBox.shrink();

    final isPhone = MediaQuery.sizeOf(context).width < 720;
    final pad = isPhone ? 16.0 : 24.0;

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
                Icon(Icons.show_chart, color: context.tealAccent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.lwPerfTitle,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: context.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            if (showValue)
              _valueSection(context, l)
            else
              Text(
                l.lwPerfNotEnough,
                style: TextStyle(color: context.textFaint, fontSize: 12),
              ),
            if (hasBenchmark) ...[
              if (showValue) ...[
                const SizedBox(height: 20),
                Divider(color: context.hairline, height: 1),
                const SizedBox(height: 16),
              ],
              // The TWR "glance" above always shows. On phones the
              // money-weighted benchmark detail collapses behind a tap-to-
              // expand disclosure; on wider screens it stays inline.
              if (isPhone)
                _benchmarkDisclosure(context, l, c, invested, lots)
              else
                _benchmarkSection(context, l, c, invested, lots),
            ],
          ],
        ),
      ),
    );
  }

  /// Phone-only collapsible wrapper around [_benchmarkSection]: a tappable
  /// header (insights icon + title via [bmTitle] + chevron) that reveals the
  /// full money-weighted benchmark block on tap. State is in-memory only.
  Widget _benchmarkDisclosure(
    BuildContext context,
    AppLocalizations l,
    Map<String, dynamic> c,
    double invested,
    int lots,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () =>
              setState(() => _benchmarkExpanded = !_benchmarkExpanded),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.insights_rounded,
                    color: context.tealAccent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.bmTitle,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: context.textPrimary,
                    ),
                  ),
                ),
                Icon(
                  _benchmarkExpanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: context.textMuted,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
        if (_benchmarkExpanded) ...[
          const SizedBox(height: 8),
          // The disclosure header above already shows the icon + title, so
          // suppress the section's own heading (subtitle still leads).
          _benchmarkSection(context, l, c, invested, lots, showHeader: false),
        ],
      ],
    );
  }

  Widget _valueSection(BuildContext context, AppLocalizations l) {
    // Headline dollar value: the current portfolio value (last point of the
    // value history; falls back to the TWR total when history is sparse).
    final headlineValue = _history.isNotEmpty
        ? (_history.last['value_usd'] as num?)?.toDouble() ?? 0.0
        : (_twr?['total_value_usd'] as num?)?.toDouble() ?? 0.0;

    // Preferred: an honest time-weighted return (cashflows divided out) plotted
    // against the S&P 500, both indexed to the range start. This is what lets
    // the performance line finally carry a real return — unlike the dollar
    // line, which ramps from ~0 as accounts sync and so can't be %-ed.
    if (_hasTwr) {
      final twrBody = _twrBody(context, l);
      if (twrBody != null) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _headline(context, headlineValue, l.lwPerfTwrReturn),
            const SizedBox(height: 14),
            twrBody,
            const SizedBox(height: 8),
            _rangeSelector(),
          ],
        );
      }
    }

    // Fallback: dollars-only line. We deliberately DON'T show a first→last %
    // here — early history ramps from ~0 as accounts first sync, conflating
    // contributions with market gains. The honest return is the TWR (above,
    // when priceable) or the contribution-weighted block below.
    final filtered = _filterByRange(_history);
    final spots = <FlSpot>[];
    for (var i = 0; i < filtered.length; i++) {
      final v = (filtered[i]['value_usd'] as num?)?.toDouble() ?? 0.0;
      spots.add(FlSpot(i.toDouble(), v * widget.conversionFactor));
    }
    final firstV = filtered.isNotEmpty
        ? (filtered.first['value_usd'] as num?)?.toDouble() ?? 0.0
        : 0.0;
    final lastV = filtered.isNotEmpty
        ? (filtered.last['value_usd'] as num?)?.toDouble() ?? 0.0
        : 0.0;
    final color = lastV >= firstV ? context.positive : context.negative;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _headline(context, lastV, l.lwPerfValueSubtitle),
        const SizedBox(height: 14),
        RepaintBoundary(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).width < 720 ? 120.0 : 150.0,
            child: spots.length < 2
                ? const SizedBox.shrink()
                : LineChart(
                    LineChartData(
                      gridData: const FlGridData(show: false),
                      titlesData: const FlTitlesData(show: false),
                      borderData: FlBorderData(show: false),
                      lineTouchData: const LineTouchData(enabled: false),
                      minX: 0,
                      maxX: (spots.length - 1).toDouble(),
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          isCurved: true,
                          curveSmoothness: 0.2,
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
                  ),
          ),
        ),
        const SizedBox(height: 8),
        _rangeSelector(),
      ],
    );
  }

  Widget _headline(BuildContext context, double valueUsd, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _money(valueUsd),
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: context.textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(subtitle, style: TextStyle(color: context.textFaint, fontSize: 11)),
      ],
    );
  }

  Widget _rangeSelector() {
    return Row(
      children: [
        _benchmarkPicker(),
        const Spacer(),
        DateRangeSelector(
          selectedRange: _range,
          onRangeChanged: (r) => setState(() => _range = r),
        ),
      ],
    );
  }

  /// Compact benchmark selector for the range row. Mirrors the segmented
  /// range-pill chrome but collapses to a single tappable chip + popup (five
  /// indices won't fit inline next to the date selector). The selection drives
  /// both the TWR overlay and the contribution comparison.
  Widget _benchmarkPicker() {
    final l = AppLocalizations.of(context);
    return PopupMenuButton<String>(
      tooltip: l.lwPerfBenchPickerTooltip,
      onSelected: _onBenchmarkChanged,
      itemBuilder: (context) => [
        for (final o in _benchmarkOptions)
          PopupMenuItem(
            value: o.key,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: _benchmark == o.key
                      ? Icon(Icons.check, size: 18, color: context.positive)
                      : null,
                ),
                Text(o.shortLabel(l)),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: Colors.black12,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _benchmarkLabel(l),
              style: TextStyle(
                color: context.textMuted,
                fontWeight: FontWeight.bold,
                fontSize: 12,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.expand_more, size: 16, color: context.textMuted),
          ],
        ),
      ),
    );
  }

  /// The TWR return pills + indexed your-vs-S&P chart + coverage caption for
  /// the selected range. Returns null when the range is too short to plot.
  Widget? _twrBody(BuildContext context, AppLocalizations l) {
    final pts = (_twr!['points'] as List).cast<dynamic>();
    var filtered = _filterByRange(pts);
    if (filtered.length < 2) return null;
    // Keep the scene light (canvaskit dislikes thousands of spots).
    filtered = _downsample(filtered, 180);

    // Re-base both series to the range's first point so the return is for the
    // selected window: TWR[a,b] = index(b)/index(a) − 1.
    final baseT = (filtered.first['twr'] as num?)?.toDouble() ?? 1.0;
    final baseS = (filtered.first['sp'] as num?)?.toDouble() ?? 1.0;
    final yourSpots = <FlSpot>[];
    final spSpots = <FlSpot>[];
    for (var i = 0; i < filtered.length; i++) {
      final t = (filtered[i]['twr'] as num?)?.toDouble() ?? baseT;
      final s = (filtered[i]['sp'] as num?)?.toDouble() ?? baseS;
      yourSpots.add(FlSpot(i.toDouble(), baseT != 0 ? (t / baseT - 1) * 100 : 0));
      spSpots.add(FlSpot(i.toDouble(), baseS != 0 ? (s / baseS - 1) * 100 : 0));
    }
    final yourPct = yourSpots.last.y;
    final spPct = spSpots.last.y;
    final coverage = (_twr!['coverage_pct'] as num?)?.toDouble() ?? 1.0;
    final yourColor = yourPct >= 0 ? context.positive : context.negative;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
                child: _twrPill(context, l.lwPerfTwrYou, yourPct, yourColor)),
            const SizedBox(width: 12),
            Expanded(
                child:
                    _twrPill(context, _benchmarkLabel(l), spPct, context.info)),
          ],
        ),
        const SizedBox(height: 14),
        RepaintBoundary(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).width < 720 ? 120.0 : 150.0,
            child: LineChart(
              LineChartData(
                gridData: const FlGridData(show: false),
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                lineTouchData: const LineTouchData(enabled: false),
                minX: 0,
                maxX: (yourSpots.length - 1).toDouble(),
                lineBarsData: [
                  // S&P first (drawn under), dashed + muted.
                  LineChartBarData(
                    spots: spSpots,
                    isCurved: true,
                    curveSmoothness: 0.2,
                    color: context.info.withValues(alpha: 0.7),
                    barWidth: 2,
                    dashArray: const [5, 4],
                    dotData: const FlDotData(show: false),
                  ),
                  LineChartBarData(
                    spots: yourSpots,
                    isCurved: true,
                    curveSmoothness: 0.2,
                    color: yourColor,
                    barWidth: 2.5,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          yourColor.withValues(alpha: 0.18),
                          yourColor.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Spell out the method so this number reads as distinct from the
        // money-weighted "Investments vs S&P 500" block below — they use
        // different math and windows and are not meant to agree.
        Text(
          l.lwPerfTwrMethodNote,
          style: TextStyle(color: context.textFaint, fontSize: 11),
        ),
        if (coverage < 0.99) ...[
          const SizedBox(height: 4),
          Text(
            l.lwPerfTwrCoverage('${(coverage * 100).round()}%'),
            style: TextStyle(color: context.textFaint, fontSize: 11),
          ),
        ],
      ],
    );
  }

  Widget _twrPill(
      BuildContext context, String label, double pct, Color color) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: context.textSubtle, fontSize: 11)),
          const SizedBox(height: 4),
          Text(
            '${pct >= 0 ? '+' : ''}${pct.toStringAsFixed(1)}%',
            style: TextStyle(
              color: color,
              fontSize: 20,
              fontWeight: FontWeight.bold,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  /// Stride-sample a list down to at most [maxPoints], always keeping the last.
  List<dynamic> _downsample(List<dynamic> data, int maxPoints) {
    if (data.length <= maxPoints) return data;
    final step = data.length / maxPoints;
    final out = <dynamic>[];
    for (var i = 0; i < maxPoints; i++) {
      out.add(data[(i * step).floor()]);
    }
    if (!identical(out.last, data.last)) out.add(data.last);
    return out;
  }

  Widget _benchmarkSection(
    BuildContext context,
    AppLocalizations l,
    Map<String, dynamic> c,
    double invested,
    int lots, {
    // When rendered inside the phone disclosure the tappable header already
    // shows the icon + title, so skip the section's own heading to avoid a
    // duplicated title; the subtitle still leads the revealed content.
    bool showHeader = true,
  }) {
    final yourVal = (c['your_value_usd'] as num?)?.toDouble() ?? 0;
    final benchVal = (c['benchmark_value_usd'] as num?)?.toDouble() ?? 0;
    final youPct = (yourVal / invested - 1) * 100;
    final benchPct = (benchVal / invested - 1) * 100;
    final deltaPts = youPct - benchPct;
    final ahead = deltaPts >= 0;
    final maxVal =
        (yourVal > benchVal ? yourVal : benchVal).clamp(1, double.infinity);
    final benchLabel = _benchmarkLabel(l);
    String pct(double p) => '${p >= 0 ? '+' : ''}${p.toStringAsFixed(1)}%';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeader) ...[
          Row(
            children: [
              Icon(Icons.insights_rounded,
                  color: context.tealAccent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.bmTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: context.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
        ],
        Text(l.bmSubtitle,
            style: TextStyle(color: context.textFaint, fontSize: 11)),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
                child: _returnTile(context, l.bmContribYou, pct(youPct),
                    _money(yourVal), context.positive)),
            const SizedBox(width: 12),
            Expanded(
                child: _returnTile(context, benchLabel, pct(benchPct),
                    _money(benchVal), context.info)),
          ],
        ),
        const SizedBox(height: 16),
        _bar(context, l.bmContribYou, yourVal, maxVal.toDouble(), context.positive),
        const SizedBox(height: 8),
        _bar(context, benchLabel, benchVal, maxVal.toDouble(), context.info),
        const SizedBox(height: 14),
        Text(
          ahead
              ? l.bmAheadPts(deltaPts.abs().toStringAsFixed(1))
              : l.bmBehindPts(deltaPts.abs().toStringAsFixed(1)),
          style: TextStyle(
            color: ahead ? context.positive : context.textMuted,
            fontWeight: FontWeight.w600,
            fontSize: 12.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          l.bmContribNote(lots, _money(invested)),
          style: TextStyle(color: context.textFaint, fontSize: 11),
        ),
      ],
    );
  }

  Widget _returnTile(
      BuildContext context, String label, String pct, String value, Color color) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: TextStyle(color: context.textSubtle, fontSize: 11)),
          const SizedBox(height: 4),
          Text(pct,
              style: TextStyle(
                  color: color, fontSize: 22, fontWeight: FontWeight.bold)),
          const SizedBox(height: 2),
          Text(value,
              style: TextStyle(
                color: context.textFaint,
                fontSize: 11,
                fontFeatures: const [FontFeature.tabularFigures()],
              )),
        ],
      ),
    );
  }

  Widget _bar(BuildContext context, String label, double value, double max,
      Color color) {
    final frac = (value / max).clamp(0.0, 1.0);
    return Row(
      children: [
        SizedBox(
          width: 86,
          child: Text(label,
              style: TextStyle(color: context.textMuted, fontSize: 11)),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              children: [
                Container(height: 14, color: context.tileSurface),
                FractionallySizedBox(
                  widthFactor: frac,
                  child: Container(height: 14, color: color),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          _money(value),
          style: TextStyle(
            color: context.textSubtle,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
