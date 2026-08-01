import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../utils/bill_forecast.dart';
import '../utils/chart_touch.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';

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

    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        // Width-responsive off the card's OWN constraint (inner
        // LayoutBuilder, per the skill rule), not MediaQuery — the card can
        // be narrower than the screen (outer tab padding, width clamps).
        child: LayoutBuilder(
          builder: (context, c) {
            // House ~420 phone breakpoint: compact chrome — no leading icon,
            // title compressed to a small uppercase overline (the
            // portfolio_card idiom). Wider layouts are unchanged.
            final isPhone = c.maxWidth < 420;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (!isPhone) ...[
                      Icon(
                        Icons.event_repeat_rounded,
                        color: context.purpleAccent,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        isPhone ? l.billsTitle.toUpperCase() : l.billsTitle,
                        style: isPhone
                            ? TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.6,
                                color: context.textSubtle,
                              )
                            : TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: context.textPrimary,
                              ),
                        // maxLines only on the phone overline; wider layouts
                        // keep the original wrap behaviour pixel-identical.
                        maxLines: isPhone ? 1 : null,
                        overflow: isPhone ? TextOverflow.ellipsis : null,
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          currencyFormat.displayMoney(
                            totalUsd * conversionFactor,
                          ),
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: context.purpleAccent,
                          ),
                        ),
                        Text(
                          l.billsNext12,
                          style: TextStyle(
                            color: context.textFaint,
                            fontSize: 11,
                          ),
                        ),
                        // The 12-month total reads alarmingly large on its own;
                        // the monthly average reframes it as "a year of bills"
                        // rather than a single scary number.
                        Text(
                          l.cfPerMonthApprox(
                            currencyFormat.displayMoney(
                              totalUsd / 12 * conversionFactor,
                            ),
                          ),
                          style: TextStyle(
                            color: context.textFaint,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                // Header→chart gap tightens with the phone overline header.
                SizedBox(height: isPhone ? 12 : 20),
                LayoutBuilder(
                  builder: (context, outer) {
                    // Month-label density off the inner width (~1 per 46px, keep
                    // the last) — a full 12-month forecast rendered a two-line
                    // month+year label under every bar and collided on phones.
                    // 200 tall (was 160): the two-line labels plus y-ticks were
                    // crowding the plot itself.
                    final count = forecast.isEmpty ? 1 : forecast.length;
                    final minLabels = count < 2 ? count : 2;
                    final maxLabels = (outer.maxWidth / 46.0).floor().clamp(
                      minLabels,
                      count,
                    );
                    final labelStep = (count / maxLabels).ceil().clamp(
                      1,
                      count,
                    );
                    return SizedBox(
                      height: 200,
                      child: _chart(context, forecast, maxMonth, labelStep),
                    );
                  },
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _chart(
    BuildContext context,
    List<BillMonth> forecast,
    double maxY,
    int labelStep,
  ) {
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
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(4),
              ),
            ),
          ],
        ),
      );
    }

    // Transient tooltip (dismisses on finger lift / pointer exit) — the raw
    // BarChart's built-in handling kept it pinned on mobile web.
    return TransientTooltipBarChart(
      data: BarChartData(
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
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
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
            // Reserve room for the optional year line under January /
            // the first bucket so a 12-month span that crosses into the
            // next year is unambiguous.
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 30,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx < 0 ||
                    idx >= forecast.length ||
                    value != idx.toDouble()) {
                  return const SizedBox.shrink();
                }
                // Every Nth label plus the last — the two-line month/year
                // labels collided on narrow phones with a 12-month span.
                final isLast = idx == forecast.length - 1;
                if (idx % labelStep != 0 && !isLast) {
                  return const SizedBox.shrink();
                }
                final month = forecast[idx].month;
                // Anchor the year at the first bar and every January so the
                // reader can tell which year each month belongs to without
                // crowding a year under all twelve labels.
                final showYear = idx == 0 || month.month == 1;
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        DateFormat.MMM().format(month),
                        style: TextStyle(
                          color: context.textSubtle,
                          fontSize: 10,
                        ),
                      ),
                      if (showYear)
                        Text(
                          DateFormat.y().format(month),
                          style: TextStyle(
                            color: context.textFaint,
                            fontSize: 9,
                          ),
                        ),
                    ],
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
                '${DateFormat.yMMM().format(m)}\n${currencyFormat.displayMoney(rod.toY)}',
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
