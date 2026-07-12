import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../utils/chart_touch.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';

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
    final l = AppLocalizations.of(context);
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: LayoutBuilder(builder: (ctx, outer) {
          // Below ~420 the bars themselves and the bottom-axis "Mar 'yy"
          // labels eat into the chart canvas; trim the chart height and
          // tighten the bar width so 3 month groups still read clearly.
          final isPhone = outer.maxWidth < 420;
          final chartHeight = isPhone ? 200.0 : 250.0;
          final barWidth = isPhone ? 14.0 : 22.0;
          // Thin the x-axis month labels so they don't overlap on narrow
          // screens: roughly one label per ~46px (phone) / ~62px (wide) of
          // chart width. With many months this shows every Nth label instead
          // of cramming all of them into the same strip.
          final approxPerLabel = isPhone ? 46.0 : 62.0;
          final count = trends.isEmpty ? 1 : trends.length;
          // Aim for >=2 labels, but a single-month chart only has room for 1 —
          // and int.clamp throws if lowerLimit > upperLimit, so the floor must
          // not exceed `count` (a one-month portfolio would otherwise crash the
          // whole card with "Invalid argument(s): 2").
          final minLabels = count < 2 ? count : 2;
          final maxLabels =
              (outer.maxWidth / approxPerLabel).floor().clamp(minLabels, count);
          final bottomLabelStep = (count / maxLabels).ceil().clamp(1, count);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            LayoutBuilder(
              builder: (context, constraints) {
                final legend = Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  children: [
                    _buildLegendItem(
                        context, context.tealAccent, l.lwTrendsIncome),
                    _buildLegendItem(
                        context, context.pinkAccent, l.lwTrendsSpending),
                  ],
                );

                if (constraints.maxWidth < 520) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l.lwTrendsTitle,
                        style: const TextStyle(
                          fontSize: 16,
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
                    // Flexible + ellipsis: the longer es-MX title
                    // ("Tendencias de flujo de efectivo") plus the legend
                    // otherwise overflow the row by a few px at mid widths
                    // (~520–760). Let the title shrink rather than overflow.
                    Flexible(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              l.lwTrendsTitle,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Tooltip(
                            message: l.lwTrendsInfoTooltip,
                            child: Icon(
                              Icons.info_outline,
                              size: 14,
                              color: context.textFaint,
                            ),
                          ),
                        ],
                      ),
                    ),
                    legend,
                  ],
                );
              },
            ),
            const SizedBox(height: 24),
            // Screen readers can't see the bar geometry or reach the
            // pointer-only hover tooltip, so we mirror the data as text:
            // a one-line summary on the container plus an offstage,
            // focus-order list of per-month income/spending values.
            Semantics(
              container: true,
              label: _semanticSummary(context),
              child: Stack(
                children: [
                  ExcludeSemantics(
                    child: SizedBox(
              height: chartHeight,
              child: Builder(builder: (context) {
                final maxY = _getMaxValue();
                // Transient tooltip (dismisses on finger lift / pointer
                // exit) — the raw BarChart pinned it on mobile web. The
                // tap-to-filter touchCallback below still fires (the
                // wrapper chains it).
                return TransientTooltipBarChart(
                data: BarChartData(
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
                        final headerLine =
                            rodIndex == 0 ? l.lwTrendsIncome : l.lwTrendsSpending;
                        final amountLine = currencyFormat.displayMoney(rod.toY * conversionFactor);
                        final hint = onMonthSelected == null
                            ? ''
                            : '\n${l.lwTrendsTapToView}';
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
                        interval: bottomLabelStep.toDouble(),
                        getTitlesWidget: (value, meta) {
                          final idx = value.toInt();
                          if (idx >= 0 && idx < trends.length) {
                            // Only render every Nth label (plus the last), so
                            // labels never overlap on narrow screens.
                            final isLast = idx == trends.length - 1;
                            if (idx % bottomLabelStep != 0 && !isLast) {
                              return const SizedBox.shrink();
                            }
                            // as String? ?? '': a null month would otherwise
                            // throw and crash the axis builder; the empty
                            // string falls through the try/catch below safely.
                            final monthStr =
                                (trends[idx]['month'] as String?) ?? '';
                            final parts = monthStr.split('-');
                            String label;
                            try {
                              final date = DateTime(
                                int.parse(parts[0]),
                                int.parse(parts[1]),
                              );
                              // "Mar" for most; "Mar '26" (compact 2-digit year)
                              // for January, the first, or the last group.
                              final isFirst = idx == 0;
                              final isJan = parts[1] == '01';
                              label = (isFirst || isLast || isJan)
                                  ? DateFormat("MMM ''yy").format(date)
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
                          // Coerce via num: a whole-number amount arrives from
                          // JSON as an int, and fl_chart's toY wants a double —
                          // passing the raw dynamic throws "int is not a subtype
                          // of double".
                          toY: (e.value['income'] as num? ?? 0).toDouble(),
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
                          toY: (e.value['spending'] as num? ?? 0).toDouble(),
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
                  ),
                  // Offstage but in the semantic tree: per-month values.
                  Positioned.fill(child: _buildSemanticBars(context)),
                ],
              ),
            ),
          ],
        );
        }),
      ),
    );
  }

  /// Human-readable label for `month` ("2026-03" -> "March 2026"),
  /// falling back to the raw string if it doesn't parse.
  String _monthLabel(String month) {
    final parts = month.split('-');
    if (parts.length >= 2) {
      final year = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      if (year != null && m != null && m >= 1 && m <= 12) {
        return DateFormat('MMMM y').format(DateTime(year, m));
      }
    }
    return month;
  }

  String _money(num value) =>
      currencyFormat.displayMoney(value * conversionFactor);

  /// One-line summary spoken for the whole chart: span + latest month's
  /// income and spending.
  String _semanticSummary(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (trends.isEmpty) return l.lwTrendsSemanticNoData;
    final last = trends.last;
    final month = (last['month'] ?? '').toString();
    final income = (last['income'] as num?) ?? 0;
    final spending = (last['spending'] as num?) ?? 0;
    // gen-l10n derives positional params by ALPHABETIZING placeholder names,
    // ignoring template order, so the signature is (count, income, month,
    // spending) — pass income before month or the screen-reader summary reads
    // them swapped ("income <month>, ...").
    return l.lwTrendsSemanticSummary(
      trends.length,
      _money(income),
      _monthLabel(month),
      _money(spending),
    );
  }

  /// Per-month rows that are visually invisible (zero-opacity, ignored by
  /// pointers) but still laid out and therefore present in the semantics
  /// tree — so a screen reader can walk each bar's income/spending values.
  Widget _buildSemanticBars(BuildContext context) {
    final l = AppLocalizations.of(context);
    return IgnorePointer(
      child: Opacity(
        opacity: 0.0,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: trends.map((t) {
            final month = (t['month'] ?? '').toString();
            final income = (t['income'] as num?) ?? 0;
            final spending = (t['spending'] as num?) ?? 0;
            return Semantics(
              // gen-l10n orders these alphabetically → (income, month, spending); pass income first.
              label: l.lwTrendsSemanticMonth(
                  _money(income), _monthLabel(month), _money(spending)),
              child: const SizedBox(height: 1, width: 1),
            );
          }).toList(),
        ),
      ),
    );
  }

  double _getMaxValue() {
    double max = 0;
    for (var t in trends) {
      // num-coerce: JSON whole numbers decode as int, which can't be assigned
      // to a double var and won't compare cleanly against one.
      final income = (t['income'] as num? ?? 0).toDouble();
      final spending = (t['spending'] as num? ?? 0).toDouble();
      if (income > max) max = income;
      if (spending > max) max = spending;
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
