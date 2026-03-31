import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../components/date_range_selector.dart';

class NetWorthCard extends StatelessWidget {
  final double netWorth;
  final List<dynamic> history;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final DateRange selectedRange;

  const NetWorthCard({
    Key? key,
    required this.netWorth,
    required this.history,
    required this.conversionFactor,
    required this.currencyFormat,
    this.selectedRange = DateRange.all,
  }) : super(key: key);

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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Total Net Worth', style: TextStyle(color: Colors.white60, fontSize: 14, fontWeight: FontWeight.w500, letterSpacing: 0.5)),
                    const SizedBox(height: 4),
                    Text(
                      currencyFormat.format(netWorth),
                      style: const TextStyle(
                        fontSize: 42, 
                        fontWeight: FontWeight.w900, 
                        letterSpacing: -1.2,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                _buildBenchmarkLegend(),
              ],
            ),
            const SizedBox(height: 24),
            Expanded(
              child: _buildChart(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBenchmarkLegend() {
    return Row(
      children: [
        _legendItem('Your Wealth', const Color(0xFF00E676)),
        const SizedBox(width: 16),
        _legendItem('S&P 500 Benchmark', Colors.blueAccent.withOpacity(0.5)),
      ],
    );
  }

  Widget _legendItem(String label, Color color) {
    return Row(
      children: [
        Container(width: 12, height: 12, decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        const SizedBox(width: 4),
        Text(label, style: const TextStyle(fontSize: 10, color: Colors.grey)),
      ],
    );
  }

  Widget _buildChart() {
    if (history.isEmpty) {
      // Mock historical data if empty - show a flat line for onboarding
      final now = DateTime.now();
      final mockData = List.generate(30, (index) {
        final date = now.subtract(Duration(days: 29 - index));
        return {
          'date': DateFormat('yyyy-MM-dd').format(date),
          'net_worth': netWorth / conversionFactor, // backend expects base units
        };
      });
      return _renderLineChart(mockData);
    }

    final filtered = _filterByRange(history);
    return _renderLineChart(filtered);
  }

  Widget _renderLineChart(List<dynamic> data) {
    if (data.isEmpty) return const SizedBox.shrink();

    List<FlSpot> spots = [];
    List<FlSpot> benchmarkSpots = [];
    double minY = double.infinity;
    double maxY = -double.infinity;

    final baseValue = (data.first['net_worth'] as num).toDouble() * conversionFactor;
    
    for (int i = 0; i < data.length; i++) {
      final val = (data[i]['net_worth'] as num).toDouble() * conversionFactor;
      spots.add(FlSpot(i.toDouble(), val));
      
      // S&P 500 estimate: 10% annual return -> ~0.026% daily
      final daysSinceStart = i.toDouble();
      final benchmarkVal = baseValue * (1.0 + (0.10 / 365 * daysSinceStart));
      benchmarkSpots.add(FlSpot(i.toDouble(), benchmarkVal));

      if (val < minY) minY = val;
      if (val > maxY) maxY = val;
      if (benchmarkVal < minY) minY = benchmarkVal;
      if (benchmarkVal > maxY) maxY = benchmarkVal;
    }

    // Add some padding to Y axis
    double padding = (maxY - minY) * 0.15;
    if (padding == 0) padding = 1000;
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
            getTooltipColor: (touchedSpot) => const Color(0xFF1A1A24).withOpacity(0.9),
            tooltipRoundedRadius: 12,
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((spot) {
                if (spot.barIndex == 0) return null; // Only show tooltip for main wealth line
                
                final idx = spot.x.toInt().clamp(0, data.length - 1);
                final point = data[idx];
                final dateStr = point['date'].toString();
                final date = DateTime.tryParse(dateStr) ?? DateTime.now();
                
                final nw = point['net_worth'];
                final ta = point['total_assets'];
                final tl = point['total_liabilities'];
                
                final children = <TextSpan>[
                  TextSpan(
                    text: '${DateFormat('MMM d, yyyy').format(date)}\n',
                    style: const TextStyle(color: Colors.grey, fontSize: 11, fontWeight: FontWeight.normal),
                  ),
                  TextSpan(
                    text: 'Net Worth: ${currencyFormat.format((nw as num).toDouble() * conversionFactor)}\n',
                    style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                  ),
                ];
                
                if (ta != null && tl != null) {
                  children.addAll([
                    const TextSpan(
                      text: '───────────────\n',
                      style: TextStyle(color: Colors.white10),
                    ),
                    TextSpan(
                      text: 'Assets: ${currencyFormat.format((ta as num).toDouble() * conversionFactor)}\n',
                      style: const TextStyle(color: Color(0xFF00E676), fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                    TextSpan(
                      text: 'Liabilities: ${currencyFormat.format((tl as num).toDouble() * conversionFactor)}',
                      style: const TextStyle(color: Colors.redAccent, fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ]);
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
          getDrawingHorizontalLine: (value) => FlLine(color: Colors.white10, strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          show: true,
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
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
                    return Text(fmt.format(date), style: const TextStyle(color: Colors.grey, fontSize: 10));
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
                // Skip the very first/last to avoid clipping
                if (value <= minY || value >= maxY) return const SizedBox();
                return Text(
                  NumberFormat.compactSimpleCurrency(name: currencyFormat.currencyName).format(value),
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
          // S&P 500 Benchmark Line (Dash-dot)
          LineChartBarData(
            spots: benchmarkSpots,
            isCurved: true,
            color: Colors.blueAccent.withOpacity(0.3),
            barWidth: 2,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            dashArray: [5, 5],
          ),
          // Your Wealth Line
          LineChartBarData(
            spots: spots,
            isCurved: true,
            gradient: const LinearGradient(colors: [Color(0xFF00E676), Color(0xFF69F0AE)]),
            barWidth: 4,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [const Color(0xFF00E676).withOpacity(0.2), const Color(0xFF00E676).withOpacity(0)],
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
