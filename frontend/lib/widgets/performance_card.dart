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

class _PerformanceCardState extends State<PerformanceCard> {
  bool _loading = true;
  List<dynamic> _history = const [];
  Map<String, dynamic>? _comparison;
  Map<String, dynamic>? _twr;
  DateRange _range = DateRange.all;

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
          .getBenchmarkComparison()
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
        .getPortfolioTwr()
        .catchError((_) => <String, dynamic>{});
    if (!mounted) return;
    setState(() {
      _twr = (t == null || t.isEmpty) ? null : t;
    });
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

    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.all(24),
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
                _benchmarkSection(context, l, c, invested, lots),
              ],
            ],
          ),
        ),
      ),
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
            height: 150,
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
    return Align(
      alignment: Alignment.centerRight,
      child: DateRangeSelector(
        selectedRange: _range,
        onRangeChanged: (r) => setState(() => _range = r),
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
                child: _twrPill(context, l.lwPerfTwrSp, spPct, context.info)),
          ],
        ),
        const SizedBox(height: 14),
        RepaintBoundary(
          child: SizedBox(
            height: 150,
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
        if (coverage < 0.99) ...[
          const SizedBox(height: 8),
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
    int lots,
  ) {
    final yourVal = (c['your_value_usd'] as num?)?.toDouble() ?? 0;
    final benchVal = (c['benchmark_value_usd'] as num?)?.toDouble() ?? 0;
    final youPct = (yourVal / invested - 1) * 100;
    final benchPct = (benchVal / invested - 1) * 100;
    final deltaPts = youPct - benchPct;
    final ahead = deltaPts >= 0;
    final maxVal =
        (yourVal > benchVal ? yourVal : benchVal).clamp(1, double.infinity);
    String pct(double p) => '${p >= 0 ? '+' : ''}${p.toStringAsFixed(1)}%';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.insights_rounded, color: context.tealAccent, size: 18),
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
                child: _returnTile(context, l.bmContribIndex, pct(benchPct),
                    _money(benchVal), context.info)),
          ],
        ),
        const SizedBox(height: 16),
        _bar(context, l.bmContribYou, yourVal, maxVal.toDouble(), context.positive),
        const SizedBox(height: 8),
        _bar(context, l.bmContribIndex, benchVal, maxVal.toDouble(), context.info),
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
