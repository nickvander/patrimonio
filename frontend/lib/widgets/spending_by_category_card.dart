import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/category.dart';
import '../utils/chart_touch.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';

/// "Where's my money going?" — per-category spending stacked by month.
///
/// Reads `/dashboard/spending-by-category`, which already applies the same
/// cash-flow hygiene as the income/spend trends (USD-normalized, excludes
/// internal transfers, CC payments and lending legs). Top categories are
/// stacked per month with a "OTHER" rollup; a 3/6/12-month range selector
/// refetches.
class SpendingByCategoryCard extends StatefulWidget {
  final ApiService apiService;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  /// When set (item #11), the chart window is driven by the Cash Flow period
  /// selector instead of the card's own 3/6/12 chips, and those chips are
  /// hidden. Absent → unchanged behavior: the card owns its window via the
  /// built-in range selector (default 6 months).
  final int? months;

  const SpendingByCategoryCard({
    super.key,
    required this.apiService,
    required this.conversionFactor,
    required this.currencyFormat,
    this.months,
  });

  @override
  State<SpendingByCategoryCard> createState() => _SpendingByCategoryCardState();
}

class _SpendingByCategoryCardState extends State<SpendingByCategoryCard> {
  int _months = 6;
  bool _loading = true;
  Map<String, dynamic>? _data;

  // The effective window: the externally driven period (item #11) wins over
  // the card's own range selector when provided.
  int get _effectiveMonths => widget.months ?? _months;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(SpendingByCategoryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Refetch when the cash-flow period selector changes the driven window.
    if (widget.months != oldWidget.months && widget.months != null) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final data = await widget.apiService
          .getSpendingByCategory(months: _effectiveMonths, top: 6);
      if (mounted) setState(() => _data = data);
    } catch (_) {
      // Leave _data as-is; the empty state renders below.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // Stable per-index palette. Index order follows the backend's
  // total-descending category order, so the biggest spender is always green.
  List<Color> _palette(BuildContext context) => [
        context.positive,
        context.tealAccent,
        context.info,
        context.purpleAccent,
        context.pinkAccent,
        context.yellowAccent,
        context.warning,
        context.textFaint, // OTHER rollup tail
      ];

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final months = (_data?['months'] as List<dynamic>?) ?? const [];
    final cats = (_data?['categories'] as List<dynamic>?) ?? const [];
    final isPhone = MediaQuery.sizeOf(context).width < 720;
    final pad = isPhone ? 16.0 : 24.0;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.bar_chart_rounded,
                    color: context.tealAccent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.spendByCatTitle,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: context.textPrimary,
                    ),
                  ),
                ),
                // Hidden when the window is driven by the Cash Flow period
                // selector (item #11) — the two selectors would otherwise
                // disagree on screen.
                if (widget.months == null) _rangeSelector(),
              ],
            ),
            const SizedBox(height: 16),
            if (_loading)
              const SizedBox(
                height: 220,
                child: Center(child: CircularProgressIndicator()),
              )
            else if (months.isEmpty || cats.isEmpty)
              SizedBox(
                height: 180,
                child: Center(
                  child: Text(
                    l.spendByCatEmpty,
                    style: TextStyle(color: context.textMuted),
                    textAlign: TextAlign.center,
                  ),
                ),
              )
            else ...[
              LayoutBuilder(builder: (context, outer) {
                // Bar width and month-label density derive from the inner
                // width (house rule: ~1 label per 46px phone / 62px wide,
                // always keep the last) — hardcoded 22px bars + a label on
                // every month overlapped on narrow phones with 6-12 months.
                final narrow = outer.maxWidth < 420;
                final count = months.isEmpty ? 1 : months.length;
                final minLabels = count < 2 ? count : 2;
                final maxLabels = (outer.maxWidth / (narrow ? 46.0 : 62.0))
                    .floor()
                    .clamp(minLabels, count);
                final labelStep = (count / maxLabels).ceil().clamp(1, count);
                final barWidth = narrow ? 14.0 : 22.0;
                return SizedBox(
                  height: isPhone ? 200.0 : 240.0,
                  child: _buildChart(months, cats,
                      barWidth: barWidth, labelStep: labelStep),
                );
              }),
              const SizedBox(height: 16),
              // The figures next to each category are an average PER MONTH,
              // not the window total — the bare window sum (e.g. 6× a $3k
              // rent) reads as wildly inflated otherwise.
              Text(
                l.spendByCatAvgPerMonth,
                style: TextStyle(color: context.textMuted, fontSize: 11),
              ),
              const SizedBox(height: 8),
              _buildLegend(cats, months.length),
            ],
          ],
        ),
      ),
    );
  }

  Widget _rangeSelector() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [3, 6, 12].map((m) {
        final selected = m == _months;
        return Padding(
          padding: const EdgeInsets.only(left: 6),
          child: ChoiceChip(
            label: Text('${m}M'),
            selected: selected,
            labelStyle: TextStyle(
              fontSize: 12,
              color: selected ? context.positive : context.textMuted,
              fontWeight: selected ? FontWeight.bold : FontWeight.normal,
            ),
            showCheckmark: false,
            onSelected: (_) {
              if (m == _months) return;
              setState(() => _months = m);
              _load();
            },
          ),
        );
      }).toList(),
    );
  }

  Widget _buildChart(List<dynamic> months, List<dynamic> cats,
      {required double barWidth, required int labelStep}) {
    final palette = _palette(context);

    // category -> month -> amount (USD).
    final lookup = <int, Map<String, double>>{};
    for (var i = 0; i < cats.length; i++) {
      final monthly = (cats[i]['monthly'] as List<dynamic>?) ?? const [];
      final m = <String, double>{};
      for (final e in monthly) {
        m[e['month'].toString()] = (e['amount'] as num?)?.toDouble() ?? 0.0;
      }
      lookup[i] = m;
    }

    double maxTotal = 0;
    final groups = <BarChartGroupData>[];
    for (var x = 0; x < months.length; x++) {
      final monthKey = months[x].toString();
      final stack = <BarChartRodStackItem>[];
      var running = 0.0;
      for (var i = 0; i < cats.length; i++) {
        final amt = (lookup[i]?[monthKey] ?? 0.0) * widget.conversionFactor;
        if (amt <= 0) continue;
        stack.add(BarChartRodStackItem(
          running,
          running + amt,
          palette[i % palette.length],
        ));
        running += amt;
      }
      if (running > maxTotal) maxTotal = running;
      groups.add(
        BarChartGroupData(
          x: x,
          barRods: [
            BarChartRodData(
              toY: running,
              width: barWidth,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(4)),
              rodStackItems: stack,
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
        maxY: maxTotal <= 0 ? 1 : maxTotal * 1.15,
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
              reservedSize: 44,
              getTitlesWidget: (value, meta) {
                if (value <= meta.min || value >= meta.max) {
                  return const SizedBox.shrink();
                }
                return Text(
                  NumberFormat.compact().format(value),
                  style: TextStyle(color: context.textSubtle, fontSize: 10),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                final idx = value.toInt();
                if (idx < 0 || idx >= months.length) {
                  return const SizedBox.shrink();
                }
                // Every Nth label plus the last — the axis never overlaps
                // on narrow phones.
                final isLast = idx == months.length - 1;
                if (idx % labelStep != 0 && !isLast) {
                  return const SizedBox.shrink();
                }
                final parsed = DateTime.tryParse('${months[idx]}-01');
                final label = parsed == null
                    ? months[idx].toString()
                    : DateFormat.MMM().format(parsed);
                return Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    label,
                    style: TextStyle(color: context.textSubtle, fontSize: 11),
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
              final monthKey = months[group.x].toString();
              final parsed = DateTime.tryParse('$monthKey-01');
              final header = parsed == null
                  ? monthKey
                  : DateFormat.yMMM().format(parsed);
              // One line per non-zero category, in legend (total-descending)
              // order, colored to match its segment/legend swatch. Reuse the
              // same `lookup` the bars are stacked from.
              final children = <TextSpan>[];
              for (var i = 0; i < cats.length; i++) {
                final amt =
                    (lookup[i]?[monthKey] ?? 0.0) * widget.conversionFactor;
                if (amt <= 0) continue;
                final name =
                    prettyCategory(primary: cats[i]['category']?.toString());
                children.add(TextSpan(
                  text: '\n$name  ${widget.currencyFormat.displayMoney(amt)}',
                  style: TextStyle(
                    color: palette[i % palette.length],
                    fontWeight: FontWeight.normal,
                    fontSize: 12,
                  ),
                ));
              }
              return BarTooltipItem(
                header,
                TextStyle(
                  color: context.tooltipOnSurface,
                  fontWeight: FontWeight.bold,
                ),
                children: children,
              );
            },
          ),
        ),
        barGroups: groups,
      ),
    );
  }

  Widget _buildLegend(List<dynamic> cats, int monthCount) {
    final palette = _palette(context);
    // The most recent month in the window is the current, still-incomplete
    // month. Counting it as a whole month understates the per-month average
    // (a half-elapsed month's spend would be divided across a full slot), so
    // count it as the fraction of the month elapsed so far instead.
    final now = DateTime.now();
    final daysInMonth = DateTime(now.year, now.month + 1, 0).day;
    final currentMonthFraction = now.day / daysInMonth;
    final divisor =
        monthCount > 0 ? (monthCount - 1) + currentMonthFraction : 1.0;
    return Wrap(
      spacing: 16,
      runSpacing: 8,
      children: [
        for (var i = 0; i < cats.length; i++)
          _legendItem(
            palette[i % palette.length],
            prettyCategory(primary: cats[i]['category']?.toString()),
            ((cats[i]['total'] as num?)?.toDouble() ?? 0.0) / divisor,
          ),
      ],
    );
  }

  Widget _legendItem(Color color, String label, double totalUsd) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 10,
          height: 10,
          decoration:
              BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(color: context.textMuted, fontSize: 12),
        ),
        const SizedBox(width: 6),
        Text(
          widget.currencyFormat.displayMoney(totalUsd * widget.conversionFactor),
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
