import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../utils/bill_forecast.dart';
import '../utils/theme_colors.dart';
import '../l10n/app_localizations.dart';

/// 12-month forward projection of recurring bills, built from the already-
/// loaded detected subscriptions (no extra fetch). Surfaces lumpy annual
/// renewals that a flat "monthly subscriptions total" hides. Renders nothing
/// when there are no active recurring charges.
class UpcomingBillsCard extends StatelessWidget {
  /// The dashboard's detected-subscriptions list (USD-normalized).
  final List<dynamic> subscriptions;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  /// Injectable "today" for deterministic tests; defaults to DateTime.now().
  final DateTime? now;

  const UpcomingBillsCard({
    super.key,
    required this.subscriptions,
    required this.conversionFactor,
    required this.currencyFormat,
    this.now,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final today = now ?? DateTime.now();
    final from = DateTime(today.year, today.month);
    final forecast = forecastRecurringBills(subscriptions, from: from);
    final totalUsd = forecastTotalUsd(forecast);

    // Nothing recurring projected → stay out of the way.
    if (totalUsd <= 0) return const SizedBox.shrink();

    final maxMonth = forecast
        .map((m) => m.totalUsd)
        .fold(0.0, (a, b) => a > b ? a : b);

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.event_repeat_rounded,
                    color: context.purpleAccent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.billsTitle,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: context.textPrimary,
                    ),
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      currencyFormat.format(totalUsd * conversionFactor),
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: context.purpleAccent,
                      ),
                    ),
                    Text(
                      l.billsNext12,
                      style:
                          TextStyle(color: context.textFaint, fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(height: 160, child: _chart(context, forecast, maxMonth)),
          ],
        ),
      ),
    );
  }

  Widget _chart(BuildContext context, List<BillMonth> forecast, double maxY) {
    final groups = <BarChartGroupData>[];
    for (var i = 0; i < forecast.length; i++) {
      groups.add(
        BarChartGroupData(
          x: i,
          barRods: [
            BarChartRodData(
              toY: forecast[i].totalUsd * conversionFactor,
              width: 14,
              color: context.purpleAccent,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(4)),
            ),
          ],
        ),
      );
    }

    return BarChart(
      BarChartData(
        alignment: BarChartAlignment.spaceAround,
        maxY: maxY <= 0 ? 1 : maxY * conversionFactor * 1.2,
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
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 40,
              getTitlesWidget: (value, meta) {
                if (value <= meta.min || value >= meta.max) {
                  return const SizedBox.shrink();
                }
                return Text(
                  NumberFormat.compact().format(value),
                  style: TextStyle(color: context.textSubtle, fontSize: 9),
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
                    idx >= forecast.length ||
                    value != idx.toDouble()) {
                  return const SizedBox.shrink();
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    DateFormat.MMM().format(forecast[idx].month),
                    style: TextStyle(color: context.textSubtle, fontSize: 10),
                  ),
                );
              },
            ),
          ),
        ),
        barTouchData: BarTouchData(
          touchTooltipData: BarTouchTooltipData(
            getTooltipColor: (_) => context.tooltipSurface,
            getTooltipItem: (group, groupIndex, rod, rodIndex) {
              final m = forecast[group.x.toInt()].month;
              return BarTooltipItem(
                '${DateFormat.yMMM().format(m)}\n${currencyFormat.format(rod.toY)}',
                TextStyle(
                  color: context.tooltipOnSurface,
                  fontWeight: FontWeight.bold,
                ),
              );
            },
          ),
        ),
        barGroups: groups,
      ),
    );
  }
}
