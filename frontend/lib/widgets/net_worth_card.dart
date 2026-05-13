import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../components/date_range_selector.dart';
import '../utils/currency.dart';

class NetWorthCard extends StatelessWidget {
  final double netWorth;
  final List<dynamic> history;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final String reportingCurrency;
  final List<dynamic> sourceBreakdown;
  final DateRange selectedRange;

  const NetWorthCard({
    super.key,
    required this.netWorth,
    required this.history,
    required this.conversionFactor,
    required this.currencyFormat,
    required this.reportingCurrency,
    required this.sourceBreakdown,
    this.selectedRange = DateRange.all,
  });

  /// Filter history data based on the selected date range
  List<dynamic> _filterByRange(List<dynamic> data) {
    if (data.isEmpty || selectedRange == DateRange.all) return data;

    final now = DateTime.now();
    DateTime cutoff;

    switch (selectedRange) {
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

    return data.where((point) {
      final dateStr = point['date']?.toString() ?? '';
      if (dateStr.length < 10) return true;
      final date = DateTime.tryParse(dateStr);
      if (date == null) return true;
      return date.isAfter(cutoff) || date.isAtSameMomentAs(cutoff);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxWidth < 640;
            final filtered = _filterByRange(history);
            final institutions = _topInstitutions(filtered);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(isCompact, institutions),
                const SizedBox(height: 24),
                Expanded(child: _buildChart(filtered, institutions)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(
      bool isCompact, List<MapEntry<String, Color>> institutions) {
    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Total Net Worth ($reportingCurrency)',
          style: const TextStyle(
            color: Colors.white60,
            fontSize: 14,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          currencyFormat.format(netWorth),
          style: TextStyle(
            fontSize: isCompact ? 34 : 42,
            fontWeight: FontWeight.w900,
            color: Colors.white,
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (sourceBreakdown.isNotEmpty) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: sourceBreakdown.map((item) {
              final currency = (item['currency'] ?? '').toString();
              final net = ((item['net'] ?? 0.0) as num).toDouble();
              return Text(
                '${formatCurrencyAmount(net, currency)} source',
                style: const TextStyle(color: Colors.white54, fontSize: 11),
              );
            }).toList(),
          ),
        ],
      ],
    );

    final legend = _buildLegend(institutions);

    if (isCompact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          summary,
          const SizedBox(height: 16),
          legend,
        ],
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: summary),
        const SizedBox(width: 16),
        Flexible(child: legend),
      ],
    );
  }

  /// Palette used to colour per-institution lines. Mirrors the brand
  /// palette used elsewhere in the dashboard.
  static const List<Color> _institutionPalette = [
    Color(0xFF00B0FF), // Azure Blue
    Color(0xFFAB47BC), // Purple
    Color(0xFFFFB300), // Amber
    Color(0xFFFF6E40), // Deep Orange
    Color(0xFF26C6DA), // Cyan
    Color(0xFFEC407A), // Pink
  ];

  /// Returns an ordered list of (institutionName, color) pairs for the
  /// top contributors observed across the provided history.
  List<MapEntry<String, Color>> _topInstitutions(List<dynamic> data,
      {int max = 5}) {
    final maxByInst = <String, double>{};
    for (final raw in data) {
      final map = raw as Map<String, dynamic>;
      final byInst =
          (map['by_institution'] as Map?)?.cast<String, dynamic>() ?? {};
      for (final entry in byInst.entries) {
        final value = (entry.value as num).toDouble().abs();
        final prev = maxByInst[entry.key] ?? 0.0;
        if (value > prev) maxByInst[entry.key] = value;
      }
    }
    final sorted = maxByInst.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top = sorted.take(max).toList();
    return [
      for (var i = 0; i < top.length; i++)
        MapEntry(top[i].key, _institutionPalette[i % _institutionPalette.length]),
    ];
  }

  Widget _buildLegend(List<MapEntry<String, Color>> institutions) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        _legendItem('Total net worth', const Color(0xFF00E676)),
        ...institutions.map((e) => _legendItem(e.key, e.value)),
      ],
    );
  }

  Widget _legendItem(String label, Color color) {
    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
      ],
    );
  }

  Widget _buildChart(
      List<dynamic> filtered, List<MapEntry<String, Color>> institutions) {
    if (history.isEmpty) {
      // Mock historical data if empty - show a flat line for onboarding
      final now = DateTime.now();
      final mockData = List.generate(30, (index) {
        final date = now.subtract(Duration(days: 29 - index));
        return {
          'date': DateFormat('yyyy-MM-dd').format(date),
          'net_worth':
              netWorth / conversionFactor, // backend expects base units
          'by_institution': const <String, dynamic>{},
        };
      });
      return _renderLineChart(mockData, const []);
    }

    return _renderLineChart(filtered, institutions);
  }

  Widget _renderLineChart(
      List<dynamic> data, List<MapEntry<String, Color>> institutions) {
    if (data.isEmpty) return const SizedBox.shrink();

    List<FlSpot> spots = [];
    final institutionSpots = <String, List<FlSpot>>{
      for (final i in institutions) i.key: <FlSpot>[],
    };

    double minY = double.infinity;
    double maxY = -double.infinity;

    final baseValue =
        (data.first['net_worth'] as num).toDouble() * conversionFactor;

    // Performance Optimization: Downsample to ~150 points maximum
    final int step = data.length > 150 ? (data.length / 150).ceil() : 1;

    void processPoint(int i) {
      final point = data[i] as Map<String, dynamic>;
      final val = (point['net_worth'] as num).toDouble() * conversionFactor;
      final x = i.toDouble();
      spots.add(FlSpot(x, val));

      final byInst =
          (point['by_institution'] as Map?)?.cast<String, dynamic>() ?? {};
      for (final inst in institutions) {
        final raw = byInst[inst.key];
        final v = raw is num ? raw.toDouble() * conversionFactor : 0.0;
        institutionSpots[inst.key]!.add(FlSpot(x, v));
        if (v < minY) minY = v;
        if (v > maxY) maxY = v;
      }

      if (val < minY) minY = val;
      if (val > maxY) maxY = val;
    }

    for (int i = 0; i < data.length; i += step) {
      processPoint(i);
    }
    // Always include the most recent data point
    if ((data.length - 1) % step != 0 && data.isNotEmpty) {
      processPoint(data.length - 1);
    }

    // Add some padding to Y axis
    double padding = (maxY - minY) * 0.15;
    if (padding <= 0) padding = baseValue * 0.15 + 1000;
    minY -= padding;
    maxY += padding;

    // Calculate a smart Y-axis interval to avoid duplicate labels
    final yRange = maxY - minY;
    final rawInterval = yRange / 5; // aim for ~5 labels
    // Round to a nice number (1k, 5k, 10k, 25k, 50k, 100k, etc.)
    double yInterval;
    if (rawInterval <= 1000) {
      yInterval = 1000;
    } else if (rawInterval <= 2500) {
      yInterval = 2500;
    } else if (rawInterval <= 5000) {
      yInterval = 5000;
    } else if (rawInterval <= 10000) {
      yInterval = 10000;
    } else if (rawInterval <= 25000) {
      yInterval = 25000;
    } else if (rawInterval <= 50000) {
      yInterval = 50000;
    } else {
      yInterval = (rawInterval / 50000).ceil() * 50000;
    }

    return LineChart(
      LineChartData(
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (touchedSpot) =>
                const Color(0xFF1A1A24).withValues(alpha: 0.9),
            tooltipRoundedRadius: 12,
            getTooltipItems: (touchedSpots) {
              // Only emit a tooltip body once — on the wealth line (the
              // last bar) — and have it include every institution breakdown.
              final wealthBarIndex = institutions.length;
              return touchedSpots.map((spot) {
                if (spot.barIndex != wealthBarIndex) return null;

                final idx = spot.x.toInt().clamp(0, data.length - 1);
                final point = data[idx] as Map<String, dynamic>;
                final dateStr = point['date'].toString();
                final date = DateTime.tryParse(dateStr) ?? DateTime.now();

                final nw = point['net_worth'];
                final ta = point['total_assets'];
                final tl = point['total_liabilities'];
                final byInst = (point['by_institution'] as Map?)
                        ?.cast<String, dynamic>() ??
                    {};

                final children = <TextSpan>[
                  TextSpan(
                    text: '${DateFormat('MMM d, yyyy').format(date)}\n',
                    style: const TextStyle(
                      color: Colors.grey,
                      fontSize: 11,
                      fontWeight: FontWeight.normal,
                    ),
                  ),
                  TextSpan(
                    text:
                        'Net Worth: ${currencyFormat.format((nw as num).toDouble() * conversionFactor)}\n',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ];

                if (ta != null && tl != null) {
                  children.addAll([
                    const TextSpan(
                      text: '───────────────\n',
                      style: TextStyle(color: Colors.white10),
                    ),
                    TextSpan(
                      text:
                          'Assets: ${currencyFormat.format((ta as num).toDouble() * conversionFactor)}\n',
                      style: const TextStyle(
                        color: Color(0xFF00E676),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(
                      text:
                          'Liabilities: ${currencyFormat.format((tl as num).toDouble() * conversionFactor)}\n',
                      style: const TextStyle(
                        color: Colors.redAccent,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ]);
                }

                if (institutions.isNotEmpty) {
                  children.add(const TextSpan(
                    text: '───────────────\n',
                    style: TextStyle(color: Colors.white10),
                  ));
                  for (final inst in institutions) {
                    final raw = byInst[inst.key];
                    if (raw is! num) continue;
                    final value = raw.toDouble() * conversionFactor;
                    children.add(TextSpan(
                      text:
                          '${inst.key}: ${currencyFormat.format(value)}\n',
                      style: TextStyle(
                        color: inst.value,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ));
                  }
                }

                return LineTooltipItem(
                  '',
                  const TextStyle(color: Colors.white),
                  children: children,
                );
              }).toList();
            },
          ),
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: yInterval,
          getDrawingHorizontalLine: (value) =>
              FlLine(color: Colors.white10, strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          show: true,
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: (data.length / 5).clamp(1, 100).toDouble(),
              getTitlesWidget: (value, meta) {
                int index = value.toInt();
                if (index >= 0 && index < data.length) {
                  final dateStr = data[index]['date'].toString();
                  if (dateStr.length >= 10) {
                    final date = DateTime.parse(dateStr);
                    // Adapt format based on range
                    final fmt = selectedRange == DateRange.oneMonth
                        ? DateFormat('MMM d')
                        : DateFormat("MMM ''yy");
                    return Text(
                      fmt.format(date),
                      style: const TextStyle(color: Colors.grey, fontSize: 10),
                    );
                  }
                }
                return const Text('');
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: yInterval,
              getTitlesWidget: (value, meta) {
                // Skip ticks that fall within ~half an interval of either
                // edge — fl_chart can otherwise crowd or clip labels at the
                // very top/bottom of the axis.
                final edgeBuffer = yInterval * 0.5;
                if (value <= minY + edgeBuffer ||
                    value >= maxY - edgeBuffer) {
                  return const SizedBox();
                }
                return Text(
                  NumberFormat.compactSimpleCurrency(
                    name: currencyFormat.currencyName,
                  ).format(value),
                  style: const TextStyle(color: Colors.grey, fontSize: 10),
                );
              },
              reservedSize: 50,
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        minY: minY,
        maxY: maxY,
        lineBarsData: [
          // Per-institution contribution lines (drawn under the wealth line).
          for (final inst in institutions)
            LineChartBarData(
              spots: institutionSpots[inst.key]!,
              isCurved: true,
              color: inst.value.withValues(alpha: 0.7),
              barWidth: 2.5,
              isStrokeCapRound: true,
              dotData: const FlDotData(show: false),
            ),
          // Total net worth (drawn on top so it remains the focal line)
          LineChartBarData(
            spots: spots,
            isCurved: true,
            gradient: const LinearGradient(
              colors: [Color(0xFF00E676), Color(0xFF69F0AE)],
            ),
            barWidth: 4,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF00E676).withValues(alpha: 0.2),
                  const Color(0xFF00E676).withValues(alpha: 0),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
