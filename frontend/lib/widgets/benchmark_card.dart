import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../utils/theme_colors.dart';
import '../l10n/app_localizations.dart';

/// "Net worth vs S&P 500" — overlays the user's net-worth trajectory against
/// the index, both indexed to 100 at the start of the shared window, so the
/// shapes are directly comparable regardless of scale. Honest label: net worth
/// includes contributions, so this is a "tracking the market?" glance, not a
/// pure time-weighted return. Renders nothing until both series are available.
class BenchmarkCard extends StatefulWidget {
  final ApiService apiService;

  /// The dashboard's net-worth history: [{date: "YYYY-MM-DD", net_worth: num}].
  final List<dynamic> netWorthHistory;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const BenchmarkCard({
    super.key,
    required this.apiService,
    required this.netWorthHistory,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  @override
  State<BenchmarkCard> createState() => _BenchmarkCardState();
}

class _Series {
  final List<FlSpot> you;
  final List<FlSpot> market;
  final double youReturnPct;
  final double marketReturnPct;
  _Series(this.you, this.market, this.youReturnPct, this.marketReturnPct);
}

class _BenchmarkCardState extends State<BenchmarkCard> {
  bool _loading = true;
  List<dynamic> _benchmark = const [];
  Map<String, dynamic>? _comparison;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant BenchmarkCard old) {
    super.didUpdateWidget(old);
    if (old.netWorthHistory.length != widget.netWorthHistory.length &&
        _benchmark.isEmpty) {
      _load();
    }
  }

  Future<void> _load() async {
    final nw = _parsed(widget.netWorthHistory, 'net_worth');
    if (nw.isEmpty) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    final from = _iso(nw.first.key);
    try {
      final results = await Future.wait([
        widget.apiService.getBenchmarkSeries(from: from),
        widget.apiService.getBenchmarkComparison(),
      ]);
      if (mounted) {
        setState(() {
          _benchmark =
              (results[0]?['points'] as List<dynamic>?) ?? const [];
          _comparison = results[1];
          _loading = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// The contribution-weighted comparison block, shown when we have tracked
  /// lots. Returns null when there's nothing to show.
  Widget? _contributionBlock() {
    final c = _comparison;
    if (c == null) return null;
    final invested = (c['invested_usd'] as num?)?.toDouble() ?? 0;
    final lots = (c['lot_count'] as num?)?.toInt() ?? 0;
    if (invested <= 0 || lots <= 0) return null;
    final yourVal = (c['your_value_usd'] as num?)?.toDouble() ?? 0;
    final benchVal = (c['benchmark_value_usd'] as num?)?.toDouble() ?? 0;
    final youPct = (yourVal / invested - 1) * 100;
    final benchPct = (benchVal / invested - 1) * 100;
    final l = AppLocalizations.of(context);
    final fmt = widget.currencyFormat;

    String pct(double p) => '${p >= 0 ? '+' : ''}${p.toStringAsFixed(1)}%';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Divider(height: 28, color: context.hairline),
        Text(
          l.bmContribTitle,
          style: TextStyle(
              color: context.textMuted,
              fontSize: 12,
              fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: _contribStat(
                  l.bmContribYou, pct(youPct), context.positive),
            ),
            Expanded(
              child:
                  _contribStat(l.bmContribIndex, pct(benchPct), context.info),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          l.bmContribNote(
              lots, fmt.format(invested * widget.conversionFactor)),
          style: TextStyle(color: context.textFaint, fontSize: 11),
        ),
      ],
    );
  }

  Widget _contribStat(String label, String value, Color color) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: TextStyle(color: context.textSubtle, fontSize: 11)),
        const SizedBox(height: 2),
        Text(
          value,
          style: TextStyle(
              color: color, fontSize: 18, fontWeight: FontWeight.bold),
        ),
      ],
    );
  }

  List<MapEntry<DateTime, double>> _parsed(List<dynamic> raw, String key) {
    final out = <MapEntry<DateTime, double>>[];
    for (final r in raw) {
      if (r is! Map) continue;
      final d = DateTime.tryParse(r['date']?.toString() ?? '');
      final v = (r[key] as num?)?.toDouble();
      if (d != null && v != null && v != 0) out.add(MapEntry(d, v));
    }
    out.sort((a, b) => a.key.compareTo(b.key));
    return out;
  }

  String _iso(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Index both series to 100 at the first net-worth date and align on day-
  /// offset x. Returns null when there isn't enough overlap to compare.
  _Series? _build() {
    final nw = _parsed(widget.netWorthHistory, 'net_worth');
    final sp = _parsed(_benchmark, 'close');
    if (nw.length < 2 || sp.length < 2) return null;

    final start = nw.first.key;
    final nwStart = nw.first.value;
    // First S&P point on/after the net-worth start; fall back to the earliest.
    final spStartEntry =
        sp.firstWhere((e) => !e.key.isBefore(start), orElse: () => sp.first);
    final spStart = spStartEntry.value;
    if (nwStart == 0 || spStart == 0) return null;

    double x(DateTime d) => d.difference(start).inDays.toDouble();

    final you = [
      for (final e in nw) FlSpot(x(e.key), e.value / nwStart * 100),
    ];
    final market = [
      for (final e in sp)
        if (!e.key.isBefore(start)) FlSpot(x(e.key), e.value / spStart * 100),
    ];
    if (market.length < 2) return null;

    return _Series(
      you,
      market,
      you.last.y - 100,
      market.last.y - 100,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final s = _build();
    if (s == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);

    final ahead = s.youReturnPct >= s.marketReturnPct;
    final gap = (s.youReturnPct - s.marketReturnPct).abs();

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
                  _legendDot(context.positive, l.bmYou, s.youReturnPct),
                  const SizedBox(width: 12),
                  _legendDot(context.info, l.bmSp500, s.marketReturnPct),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                l.bmSubtitle,
                style: TextStyle(color: context.textFaint, fontSize: 11),
              ),
              const SizedBox(height: 18),
              SizedBox(height: 180, child: _chart(s)),
              const SizedBox(height: 10),
              Text(
                ahead
                    ? l.bmAhead('${gap.toStringAsFixed(1)}%')
                    : l.bmBehind('${gap.toStringAsFixed(1)}%'),
                style: TextStyle(
                  color: ahead ? context.positive : context.textMuted,
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                ),
              ),
              ?_contributionBlock(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _legendDot(Color color, String label, double pct) {
    final sign = pct >= 0 ? '+' : '';
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 9,
          height: 9,
          decoration:
              BoxDecoration(color: color, borderRadius: BorderRadius.circular(2)),
        ),
        const SizedBox(width: 5),
        Text(
          '$label $sign${pct.toStringAsFixed(1)}%',
          style: TextStyle(
              color: context.textSubtle,
              fontSize: 12,
              fontWeight: FontWeight.w600),
        ),
      ],
    );
  }

  Widget _chart(_Series s) {
    final all = [...s.you, ...s.market];
    final minY = all.map((p) => p.y).reduce((a, b) => a < b ? a : b);
    final maxY = all.map((p) => p.y).reduce((a, b) => a > b ? a : b);
    final pad = ((maxY - minY) * 0.1).clamp(2.0, double.infinity);

    LineChartBarData line(List<FlSpot> spots, Color c, {bool fill = false}) =>
        LineChartBarData(
          spots: spots,
          isCurved: true,
          color: c,
          barWidth: fill ? 3 : 2,
          dotData: const FlDotData(show: false),
          belowBarData: fill
              ? BarAreaData(
                  show: true,
                  gradient: LinearGradient(
                    colors: [
                      c.withValues(alpha: 0.18),
                      c.withValues(alpha: 0.0),
                    ],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                )
              : null,
        );

    return LineChart(
      LineChartData(
        minY: minY - pad,
        maxY: maxY + pad,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (v) =>
              FlLine(color: context.hairline, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 34,
              getTitlesWidget: (value, meta) {
                if (value <= meta.min || value >= meta.max) {
                  return const SizedBox.shrink();
                }
                return Text(
                  value.toStringAsFixed(0),
                  style: TextStyle(color: context.textSubtle, fontSize: 9),
                );
              },
            ),
          ),
        ),
        lineBarsData: [
          line(s.market, context.info),
          line(s.you, context.positive, fill: true),
        ],
        lineTouchData: const LineTouchData(enabled: false),
      ),
    );
  }
}
