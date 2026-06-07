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
/// IMPORTANT: the value line is shown in dollars and is NOT indexed against the
/// S&P. Indexing net-worth/value-from-~0 to the index reports absurd returns
/// (it conflates contributions with market gains), so the honest "vs market"
/// read stays the contribution-weighted block below — never an indexed overlay.
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
  DateRange _range = DateRange.all;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Both are best-effort; whichever resolves shows its section.
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

    // Nothing to show → don't render an empty card.
    if (!hasHistory && !hasBenchmark) return const SizedBox.shrink();

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
              if (hasHistory)
                _valueSection(context, l)
              else
                Text(
                  l.lwPerfNotEnough,
                  style: TextStyle(color: context.textFaint, fontSize: 12),
                ),
              if (hasBenchmark) ...[
                if (hasHistory) ...[
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
    final filtered = _filterByRange(_history);
    final spots = <FlSpot>[];
    for (var i = 0; i < filtered.length; i++) {
      final v = (filtered[i]['value_usd'] as num?)?.toDouble() ?? 0.0;
      spots.add(FlSpot(i.toDouble(), v * widget.conversionFactor));
    }

    final first = filtered.isNotEmpty
        ? (filtered.first['value_usd'] as num?)?.toDouble() ?? 0.0
        : 0.0;
    final last = filtered.isNotEmpty
        ? (filtered.last['value_usd'] as num?)?.toDouble() ?? 0.0
        : 0.0;
    // Line colour follows the overall direction over the range. We deliberately
    // DON'T show a first→last % "return" here: early history ramps from ~0 as
    // accounts first sync, so that % conflates contributions with market gains
    // (the absurd "+13000%" read). The honest return is the contribution-
    // weighted "vs S&P 500" block below.
    final color = last >= first ? context.positive : context.negative;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _money(last),
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
        Text(
          l.lwPerfValueSubtitle,
          style: TextStyle(color: context.textFaint, fontSize: 11),
        ),
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
        Align(
          alignment: Alignment.centerRight,
          child: DateRangeSelector(
            selectedRange: _range,
            onRangeChanged: (r) => setState(() => _range = r),
          ),
        ),
      ],
    );
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
