import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

class NetWorthCard extends StatelessWidget {
  final double netWorth;
  final List<dynamic> history;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const NetWorthCard({
    Key? key,
    required this.netWorth,
    required this.history,
    required this.conversionFactor,
    required this.currencyFormat,
  }) : super(key: key);

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
                    const Text('Total Net Worth', style: TextStyle(color: Colors.grey, fontSize: 16)),
                    const SizedBox(height: 4),
                    Text(
                      currencyFormat.format(netWorth),
                      style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
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

    return _renderLineChart(history);
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

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
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
                    return Text(DateFormat('MMM d').format(date), style: const TextStyle(color: Colors.grey, fontSize: 10));
                  }
                }
                return const Text('');
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                return Text(
                  NumberFormat.compactSimpleCurrency(name: currencyFormat.currencyName).format(value),
                  style: const TextStyle(color: Colors.grey, fontSize: 10),
                );
              },
              reservedSize: 40,
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
