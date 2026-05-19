import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

class CashFlowTrendsChart extends StatelessWidget {
  final List<Map<String, dynamic>> trends;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  /// Fires with the bar-group's month (YYYY-MM string) when the user
  /// taps a bar. Used by the dashboard to seed a date-range filter on
  /// the Transactions tab — the chart becomes a drill-in surface.
  /// Null = chart stays inert (legacy callers).
  final void Function(String month)? onMonthSelected;

  const CashFlowTrendsChart({
    super.key,
    required this.trends,
    required this.conversionFactor,
    required this.currencyFormat,
    this.onMonthSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: LayoutBuilder(builder: (ctx, outer) {
          // Below ~420 the bars themselves and the bottom-axis "Mar 'yy"
          // labels eat into the chart canvas; trim the chart height and
          // tighten the bar width so 3 month groups still read clearly.
          final isPhone = outer.maxWidth < 420;
          final chartHeight = isPhone ? 200.0 : 250.0;
          final barWidth = isPhone ? 14.0 : 22.0;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final legend = Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    _buildLegendItem(context, context.tealAccent, 'Income'),
                    _buildLegendItem(context, context.pinkAccent, 'Spending'),
                  ],
                );

                if (constraints.maxWidth < 520) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
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
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text(
                          'Cash flow trends',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Tooltip(
                          message:
                              'Internal transfers (between your accounts) and '
                              'credit-card bill payments are excluded so the '
                              'bars reflect actual external income and '
                              'spending.',
                          child: Icon(
                            Icons.info_outline,
                            size: 14,
                            color: context.textFaint,
                          ),
                        ),
                      ],
                    ),
                    legend,
                  ],
                );
              },
            ),
            const SizedBox(height: 24),
            SizedBox(
              height: chartHeight,
              child: Builder(builder: (context) {
                final maxY = _getMaxValue();
                return BarChart(
                BarChartData(
                  alignment: BarChartAlignment.spaceEvenly,
                  groupsSpace: 16,
                  maxY: maxY,
                  barTouchData: BarTouchData(
                    touchTooltipData: BarTouchTooltipData(
                      getTooltipColor: (_) => context.tooltipSurface,
                      getTooltipItem: (group, groupIndex, rod, rodIndex) {
                        // Add a "tap to filter" hint to the bottom of the
                        // tooltip so the click affordance is discoverable —
                        // most users don't expect chart bars to be tappable.
                        final headerLine = rodIndex == 0 ? 'Income' : 'Spending';
                        final amountLine = currencyFormat.format(rod.toY * conversionFactor);
                        final hint = onMonthSelected == null
                            ? ''
                            : '\nTap to view transactions';
                        return BarTooltipItem(
                          '$headerLine\n$amountLine$hint',
                          TextStyle(color: context.tooltipOnSurface),
                        );
                      },
                    ),
                    // Wire bar taps to the filter callback. fl_chart
                    // gives us `groupIndex` (which month group) — we
                    // look that up in `trends` and emit the YYYY-MM
                    // string back to the caller.
                    touchCallback: onMonthSelected == null
                        ? null
                        : (event, response) {
                            // Only act on tap-up events — drags and hovers
                            // should not change the filter.
                            if (event is! FlTapUpEvent) return;
                            final spot = response?.spot;
                            if (spot == null) return;
                            final idx = spot.touchedBarGroupIndex;
                            if (idx < 0 || idx >= trends.length) return;
                            final month = trends[idx]['month'];
                            if (month is String && month.isNotEmpty) {
                              onMonthSelected!(month);
                            }
                          },
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
                                  color: context.textSubtle,
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
                                color: context.textSubtle,
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
                          // Teal gradient → darker variant at the top so the
                          // bar gives the eye somewhere to land. Reads
                          // correctly on white in light mode because
                          // tealAccent already shifts to its darker shade.
                          gradient: LinearGradient(
                            colors: [
                              context.tealAccent,
                              context.tealAccent.withValues(alpha: 0.6),
                            ],
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                          ),
                          width: barWidth,
                          borderRadius: BorderRadius.circular(4),
                          backDrawRodData: BackgroundBarChartRodData(
                            show: true,
                            toY: maxY,
                            color: context.tint(0.05),
                          ),
                        ),
                        BarChartRodData(
                          toY: e.value['spending'],
                          gradient: LinearGradient(
                            colors: [
                              context.pinkAccent,
                              context.negative.withValues(alpha: 0.85),
                            ],
                            begin: Alignment.bottomCenter,
                            end: Alignment.topCenter,
                          ),
                          width: barWidth,
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
        );
        }),
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

  Widget _buildLegendItem(BuildContext context, Color color, String label) {
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
        Text(label, style: TextStyle(fontSize: 12, color: context.textSubtle)),
      ],
    );
  }
}
