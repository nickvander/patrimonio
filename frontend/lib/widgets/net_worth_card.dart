import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:fl_chart/fl_chart.dart';

class NetWorthCard extends StatelessWidget {
  final double netWorth;
  final List<dynamic> history;

  const NetWorthCard({
    Key? key,
    required this.netWorth,
    required this.history,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final currencyFormat = NumberFormat.simpleCurrency(name: 'USD');

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Total Net Worth',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: Colors.grey,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              currencyFormat.format(netWorth),
              style: const TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.bold,
              ),
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

  Widget _buildChart() {
    List<dynamic> chartHistory = List.from(history);

    // Provide a beautiful empty-state flat line so it doesn't look broken when user has no snapshot history
    if (chartHistory.isEmpty && netWorth > 0) {
      final now = DateTime.now();
      chartHistory = [
        {'date': now.subtract(const Duration(days: 30)).toIso8601String().split('T')[0], 'net_worth': netWorth},
        {'date': now.toIso8601String().split('T')[0], 'net_worth': netWorth},
      ];
    } else if (chartHistory.isEmpty) {
      return const Center(child: Text('No historical data yet. Check back tomorrow!'));
    }

    // Determine min date to use as X axis 0
    DateTime minDate = DateTime.parse(chartHistory.first['date'] as String);
    for (var point in chartHistory) {
      final dt = DateTime.parse(point['date'] as String);
      if (dt.isBefore(minDate)) minDate = dt;
    }

    final spots = chartHistory.map((point) {
      final dt = DateTime.parse(point['date'] as String);
      final x = dt.difference(minDate).inDays.toDouble();
      final y = (point['net_worth'] as num?)?.toDouble() ?? 0.0;
      return FlSpot(x, y);
    }).toList();

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: 10000,
          getDrawingHorizontalLine: (value) {
            return FlLine(
              color: Colors.white10,
              strokeWidth: 1,
              dashArray: [5, 5],
            );
          },
        ),
        titlesData: FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => const Color(0xFF2A2A35),
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((spot) {
                final currencyFormat = NumberFormat.simpleCurrency(name: 'USD');
                return LineTooltipItem(
                  currencyFormat.format(spot.y),
                  const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                );
              }).toList();
            },
          ),
          handleBuiltInTouches: true,
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: const Color(0xFF00E676),
            barWidth: 3,
            isStrokeCapRound: true,
            dotData: FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF00E676).withOpacity(0.3),
                  const Color(0xFF00E676).withOpacity(0.0),
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
