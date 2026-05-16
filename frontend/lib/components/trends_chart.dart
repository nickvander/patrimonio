import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

class CashFlowTrendsChart extends StatelessWidget {
  final List<Map<String, dynamic>> trends;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const CashFlowTrendsChart({
    super.key,
    required this.trends,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final legend = Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    _buildLegendItem(const Color(0xFF1DE9B6), 'Income'),
                    _buildLegendItem(const Color(0xFFFF4081), 'Spending'),
                  ],
                );

                if (constraints.maxWidth < 520) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Cash flow trends',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      legend,
                    ],
                  );
                }

                return Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      'Cash flow trends',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    legend,
                  ],
                );
              },
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: 250,
              child: Builder(builder: (context) {
                final maxY = _getMaxValue();
                return BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceEvenly,
                  groupsSpace: 16,
                  maxY: maxY,
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                        return BarTooltipItem(
                          '${rodIndex == 0 ? "Income" : "Spending"}\n${currencyFormat.format(rod.toY * conversionFactor)}',
                          TextStyle(color: context.textPrimary),
                        );
                      },
                    ),
                  ),
                  titlesData: FlTitlesData(
                    show: true,
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          if (value.toInt() >= 0 &&
                              value.toInt() < trends.length) {
                            final monthStr =
                                trends[value.toInt()]['month']
                                    as String; // e.g. "2026-03"
                            final parts = monthStr.split('-');
                            String label;
                            try {
                              final date = DateTime(
                                int.parse(parts[0]),
                                int.parse(parts[1]),
                              );
                              // Show "Mar" for most, "Mar '26" for Jan or first/last entry
                              final isFirst = value.toInt() == 0;
                              final isLast = value.toInt() == trends.length - 1;
                              final isJan = parts[1] == '01';
                              label = (isFirst || isLast || isJan)
                                  ? DateFormat('MMM y').format(date)
                                  : DateFormat('MMM').format(date);
                            } catch (_) {
                              label = parts.length > 1 ? parts[1] : monthStr;
                            }
                            return SideTitleWidget(
                              meta: meta,
                              child: Text(
                                label,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: Colors.grey,
                                ),
                              ),
                            );
                          }
                          return const SizedBox();
                        },
                      ),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 48,
                        getTitlesWidget: (value, meta) {
                          // Skip zero (visual baseline) and any tick that
                          // sits within 8% of maxY — those get squished
                          // against the top of the chart frame.
                          if (value == 0) return const SizedBox();
                          if (maxY > 0 && value >= maxY * 0.92) {
                            return const SizedBox();
                          }
                          return SideTitleWidget(
                            meta: meta,
                            child: Text(
                              NumberFormat.compactSimpleCurrency(
                                name: currencyFormat.currencyName,
                              ).format(value * conversionFactor),
                              style: TextStyle(
                                fontSize: 10,
                                color: Colors.grey,
                              ),
                              maxLines: 1,
                            ),
                          );
                        },
                      ),
                    ),
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                  ),
                  gridData: const FlGridData(show: false),
                  borderData: FlBorderData(show: false),
                  barGroups: trends.asMap().entries.map((e) {
                    return BarChartGroupData(
                      x: e.key,
                      barRods: [
                        BarChartRodData(
                          toY: e.value['income'],
                          gradient: const LinearGradient(
                            colors: [
                              Color(0xFF1DE9B6),
                              Color(0xFF00BFA5),
                            ], // Neon Teal to Deep Teal
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                          ),
                          width: 22,
                          borderRadius: BorderRadius.circular(4),
                          backDrawRodData: BackgroundBarChartRodData(
                            show: true,
                            toY: maxY,
                            color: context.tint(0.05),
                          ),
                        ),
                        BarChartRodData(
                          toY: e.value['spending'],
                          gradient: const LinearGradient(
                            colors: [
                              Color(0xFFFF4081),
                              Color(0xFFD50000),
                            ], // Bright Pink to Deep Red
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                          ),
                          width: 22,
                          borderRadius: BorderRadius.circular(4),
                          backDrawRodData: BackgroundBarChartRodData(
                            show: true,
                            toY: maxY,
                            color: context.tint(0.05),
                          ),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              );
              }),
            ),
          ],
        ),
      ),
    );
  }

  double _getMaxValue() {
    double max = 0;
    for (var t in trends) {
      if (t['income'] > max) max = t['income'];
      if (t['spending'] > max) max = t['spending'];
    }
    return max == 0 ? 100 : max * 1.2;
  }

  Widget _buildLegendItem(Color color, String label) {
    return Row(
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 12, color: Colors.grey)),
      ],
    );
  }
}
