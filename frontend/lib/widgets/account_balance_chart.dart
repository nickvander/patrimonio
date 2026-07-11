import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';

/// Monthly closing-balance line for one account, from `/dashboard/
/// account-balance-history` (derived from the persisted statement
/// `balance_after`). Values are in the account's native [currency]; the
/// caller only renders this when there are >= 2 points.
class AccountBalanceChart extends StatelessWidget {
  /// Each entry: {month: "YYYY-MM", balance: num} in native currency.
  final List<dynamic> points;
  final String currency;

  const AccountBalanceChart({
    super.key,
    required this.points,
    required this.currency,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    final spots = <FlSpot>[];
    for (var i = 0; i < points.length; i++) {
      final b = (points[i]['balance'] as num?)?.toDouble() ?? 0.0;
      spots.add(FlSpot(i.toDouble(), b));
    }
    final values = spots.map((s) => s.y).toList();
    final minY = values.reduce((a, b) => a < b ? a : b);
    final maxY = values.reduce((a, b) => a > b ? a : b);
    // Pad the range so a near-flat series isn't a line jammed against an edge.
    final span = (maxY - minY).abs();
    final pad = span < 1 ? (maxY.abs() * 0.1 + 1) : span * 0.15;

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.show_chart_rounded,
                    color: context.tealAccent, size: 16),
                const SizedBox(width: 6),
                Text(
                  l.acctxBalanceOverTime,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 130,
              child: LineChart(
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
                    rightTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    topTitles: const AxisTitles(
                        sideTitles: SideTitles(showTitles: false)),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 44,
                        getTitlesWidget: (value, meta) {
                          if (value <= meta.min || value >= meta.max) {
                            return const SizedBox.shrink();
                          }
                          return Text(
                            NumberFormat.compact().format(value),
                            style: TextStyle(
                                color: context.textSubtle, fontSize: 9),
                          );
                        },
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        getTitlesWidget: (value, meta) {
                          final idx = value.toInt();
                          if (idx < 0 ||
                              idx >= points.length ||
                              value != idx.toDouble()) {
                            return const SizedBox.shrink();
                          }
                          final m = points[idx]['month']?.toString() ?? '';
                          final parsed = DateTime.tryParse('$m-01');
                          final label = parsed == null
                              ? m
                              : DateFormat.MMM().format(parsed);
                          return Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(
                              label,
                              style: TextStyle(
                                  color: context.textSubtle, fontSize: 10),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      isCurved: true,
                      color: context.tealAccent,
                      barWidth: 3,
                      isStrokeCapRound: true,
                      dotData: const FlDotData(show: false),
                      belowBarData: BarAreaData(
                        show: true,
                        gradient: LinearGradient(
                          colors: [
                            context.tealAccent.withValues(alpha: 0.25),
                            context.tealAccent.withValues(alpha: 0.0),
                          ],
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                        ),
                      ),
                    ),
                  ],
                  lineTouchData: LineTouchData(
                    handleBuiltInTouches: true,
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipColor: (_) => context.tooltipSurface,
                      getTooltipItems: (touchedSpots) {
                        return touchedSpots.map((spot) {
                          final idx = spot.x.toInt();
                          final m = (idx >= 0 && idx < points.length)
                              ? points[idx]['month']?.toString() ?? ''
                              : '';
                          return LineTooltipItem(
                            '$m\n${displayCurrencyAmount(spot.y, currency)}',
                            TextStyle(
                              color: context.tooltipOnSurface,
                              fontWeight: FontWeight.bold,
                            ),
                          );
                        }).toList();
                      },
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
