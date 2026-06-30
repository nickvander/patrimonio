import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../l10n/app_localizations.dart';
import '../utils/theme_colors.dart';

/// Compact "what hit my accounts this month" card pinned to the Overview.
///
/// Trends are passed in already aggregated by month (ascending). The card
/// surfaces the *current* month's income vs expense and a small sparkline
/// of net cash flow across the last three months so the user can see the
/// shape of recent activity at a glance.
class MonthlyCashFlowCard extends StatelessWidget {
  final List<Map<String, dynamic>> trends;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  /// Which month's figures to headline (YYYY-MM). When null the card shows
  /// the latest month in [trends] — the historical behavior. The Cash Flow
  /// tab's period selector passes the prior month's iso for "Last month" so
  /// the inflow/outflow/net describe that month rather than the latest.
  final String? selectedMonthIso;

  /// Optional period name shown in the header (e.g. "Last 3 months") so the
  /// figure isn't ambiguous when it doesn't cover a single calendar month.
  /// When null the card names the displayed month itself.
  final String? periodLabel;

  const MonthlyCashFlowCard({
    super.key,
    required this.trends,
    required this.conversionFactor,
    required this.currencyFormat,
    this.selectedMonthIso,
    this.periodLabel,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (trends.isEmpty) {
      return _buildEmpty(context);
    }

    // The API returns months in chronological order. By default we headline
    // the *last* element (current month) and compare against the previous
    // one. When the period selector aggregates a multi-month window
    // (periodLabel set) we sum the whole series instead, so the figure
    // matches the named period.
    final aggregate = periodLabel != null;

    // Index of the month to headline when not aggregating: the one matching
    // selectedMonthIso, else the latest.
    int currentIdx = trends.length - 1;
    if (selectedMonthIso != null) {
      final i = trends.indexWhere((m) => m['month'] == selectedMonthIso);
      if (i >= 0) currentIdx = i;
    }

    double income;
    double spending;
    double? priorNet;
    // Prior month's income, kept alongside priorNet so the savings-rate
    // delta can be computed (prior rate = priorNet / priorIncome). Null
    // whenever priorNet is null (aggregate window or no prior month).
    double? priorIncome;

    if (aggregate) {
      // Sum every month in the fetched window.
      double inc = 0.0;
      double spend = 0.0;
      for (final m in trends) {
        inc += (m['income'] as num?)?.toDouble() ?? 0.0;
        spend += (m['spending'] as num?)?.toDouble() ?? 0.0;
      }
      income = inc * conversionFactor;
      spending = spend * conversionFactor;
      // No single "prior period" to compare an aggregate against — omit the
      // vs-prior delta rather than show a misleading month-over-month number.
      priorNet = null;
      priorIncome = null;
    } else {
      final current = trends[currentIdx];
      final prior = currentIdx >= 1 ? trends[currentIdx - 1] : null;
      income =
          ((current['income'] as num?)?.toDouble() ?? 0.0) * conversionFactor;
      spending =
          ((current['spending'] as num?)?.toDouble() ?? 0.0) *
              conversionFactor;
      if (prior != null) {
        final pi =
            ((prior['income'] as num?)?.toDouble() ?? 0.0) * conversionFactor;
        final ps =
            ((prior['spending'] as num?)?.toDouble() ?? 0.0) *
                conversionFactor;
        priorNet = pi - ps;
        priorIncome = pi;
      }
    }
    final net = income - spending;

    // Slice up to the last 3 months for the sparkline. If we don't have
    // three months of history we use whatever's available.
    final sparkSource =
        trends.length >= 3 ? trends.sublist(trends.length - 3) : trends;

    // Header subtitle: the named period when aggregating, else the headlined
    // month. Keeps the figure unambiguous either way.
    final monthLabel = periodLabel ??
        _formatMonth(trends[currentIdx]['month'] as String?);

    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: LayoutBuilder(
          builder: (ctx, c) {
            final isNarrow = c.maxWidth < 560;
            final header = Row(
              children: [
                Icon(
                  Icons.account_balance_wallet_outlined,
                  size: 18,
                  color: context.tealAccent,
                ),
                const SizedBox(width: 8),
                Text(
                  l.cfMonthlyTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    monthLabel,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.textSubtle,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                // Hover hint so the user understands why the numbers
                // don't equal "sum of every transaction this month."
                // Without this, a bulk-import month looks suspicious.
                Tooltip(
                  message: l.cfMonthlyExcludesTooltip,
                  child: Icon(
                    Icons.info_outline,
                    size: 14,
                    color: context.textFaint,
                  ),
                ),
              ],
            );

            final netLine = _NetLine(
              net: net,
              priorNet: priorNet,
              income: income,
              priorIncome: priorIncome,
              currencyFormat: currencyFormat,
            );

            final stats = Row(
              children: [
                Expanded(
                  child: _StatBlock(
                    label: l.cfIncome,
                    value: currencyFormat.format(income),
                    accent: context.tealAccent,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StatBlock(
                    label: l.cfExpense,
                    value: currencyFormat.format(spending),
                    accent: context.pinkAccent,
                  ),
                ),
              ],
            );

            final spark = _NetSparkline(
              points: sparkSource
                  .map((m) =>
                      (((m['income'] as num?)?.toDouble() ?? 0.0) -
                              ((m['spending'] as num?)?.toDouble() ?? 0.0)) *
                          conversionFactor)
                  .toList(growable: false),
              positive: net >= 0,
            );

            if (isNarrow) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  header,
                  const SizedBox(height: 12),
                  netLine,
                  const SizedBox(height: 12),
                  stats,
                  const SizedBox(height: 12),
                  SizedBox(height: 48, child: spark),
                ],
              );
            }

            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                header,
                const SizedBox(height: 16),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 3,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          netLine,
                          const SizedBox(height: 12),
                          stats,
                        ],
                      ),
                    ),
                    const SizedBox(width: 24),
                    Expanded(
                      flex: 2,
                      child: SizedBox(height: 80, child: spark),
                    ),
                  ],
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildEmpty(BuildContext context) {
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Text(
          AppLocalizations.of(context).cfMonthlyEmpty,
          style: TextStyle(color: context.textSubtle, fontSize: 13),
        ),
      ),
    );
  }

  String _formatMonth(String? raw) {
    if (raw == null) return '';
    final parts = raw.split('-');
    if (parts.length < 2) return raw;
    try {
      final dt = DateTime(int.parse(parts[0]), int.parse(parts[1]));
      return DateFormat('MMMM y').format(dt);
    } catch (_) {
      return raw;
    }
  }
}

class _NetLine extends StatelessWidget {
  final double net;
  final double? priorNet;
  final double income;
  final double? priorIncome;
  final NumberFormat currencyFormat;

  const _NetLine({
    required this.net,
    required this.priorNet,
    required this.income,
    required this.priorIncome,
    required this.currencyFormat,
  });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final positive = net >= 0;
    final color = positive ? context.positive : context.pinkAccent;
    final delta = priorNet == null ? null : net - priorNet!;

    // Savings rate = net / income, only meaningful when income is positive.
    // (A month with no income can't have a savings *rate* — dividing by zero
    // or a negative would print nonsense, so we omit the chip entirely.)
    final double? rate = income > 0 ? net / income : null;
    // Prior month's rate, used for the vs-prior delta in basis-point terms.
    // Only available on single-month windows where priorIncome > 0.
    final double? priorRate = (priorIncome != null && priorIncome! > 0)
        ? priorNet! / priorIncome!
        : null;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              (positive ? '+' : '−') + currencyFormat.format(net.abs()),
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w800,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(width: 8),
            if (delta != null) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  l.cfVsLastMonth(
                      '${delta >= 0 ? '↑' : '↓'} ${currencyFormat.format(delta.abs())}'),
                  style: TextStyle(
                    fontSize: 11,
                    color: delta >= 0 ? context.positive : context.pinkAccent,
                    fontWeight: FontWeight.w600,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
        if (rate != null) ...[
          const SizedBox(height: 4),
          _SavingsRateLine(rate: rate, priorRate: priorRate),
        ],
      ],
    );
  }
}

/// Savings rate (net / income) shown under the headline net figure, with an
/// optional vs-prior-month delta in percentage points. Color follows the
/// settled positive/negative convention — a positive rate (the user kept
/// money) reads green, a negative rate (they outspent income) reads pink.
class _SavingsRateLine extends StatelessWidget {
  final double rate;
  final double? priorRate;

  const _SavingsRateLine({required this.rate, this.priorRate});

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final positive = rate >= 0;
    final color = positive ? context.positive : context.pinkAccent;
    final pctLabel = '${(rate * 100).toStringAsFixed(1)}%';

    // Delta in percentage points vs the prior month. Omitted on aggregate
    // windows / when there's no comparable prior month (priorRate null).
    final deltaPts =
        priorRate == null ? null : (rate - priorRate!) * 100;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Text(
          l.cfSavingsRate(pctLabel),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: color,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        if (deltaPts != null) ...[
          const SizedBox(width: 6),
          Text(
            '${deltaPts >= 0 ? '↑' : '↓'} ${deltaPts.abs().toStringAsFixed(1)} ${l.cfPtsAbbrev}',
            style: TextStyle(
              fontSize: 11,
              color: deltaPts >= 0 ? context.positive : context.pinkAccent,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ],
    );
  }
}

class _StatBlock extends StatelessWidget {
  final String label;
  final String value;
  final Color accent;

  const _StatBlock({
    required this.label,
    required this.value,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: context.tileSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.accentSoft(accent)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 10,
              letterSpacing: 1.1,
              fontWeight: FontWeight.w700,
              color: accent.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: context.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _NetSparkline extends StatelessWidget {
  final List<double> points;
  final bool positive;

  const _NetSparkline({required this.points, required this.positive});

  @override
  Widget build(BuildContext context) {
    if (points.length < 2) {
      return Center(
        child: Text(
          AppLocalizations.of(context).cfNotEnoughHistory,
          style: TextStyle(
            color: context.textFaint,
            fontSize: 11,
          ),
        ),
      );
    }
    // Pad the min/max so a perfectly-flat series doesn't collapse to a line.
    final minV = points.reduce((a, b) => a < b ? a : b);
    final maxV = points.reduce((a, b) => a > b ? a : b);
    final pad = (maxV - minV).abs() * 0.15 + 1;

    final color = positive ? context.positive : context.pinkAccent;

    return LineChart(
      LineChartData(
        minX: 0,
        maxX: (points.length - 1).toDouble(),
        minY: minV - pad,
        maxY: maxV + pad,
        gridData: const FlGridData(show: false),
        titlesData: const FlTitlesData(show: false),
        borderData: FlBorderData(show: false),
        lineTouchData: const LineTouchData(enabled: false),
        lineBarsData: [
          LineChartBarData(
            spots: [
              for (var i = 0; i < points.length; i++)
                FlSpot(i.toDouble(), points[i]),
            ],
            isCurved: true,
            curveSmoothness: 0.25,
            color: color,
            barWidth: 2.2,
            isStrokeCapRound: true,
            dotData: FlDotData(
              show: true,
              getDotPainter: (spot, a, b, c) {
                final isLast = spot.x == (points.length - 1).toDouble();
                return FlDotCirclePainter(
                  radius: isLast ? 3.5 : 0,
                  color: color,
                  strokeWidth: 0,
                );
              },
            ),
            belowBarData: BarAreaData(
              show: true,
              color: color.withValues(alpha: 0.12),
            ),
          ),
        ],
      ),
    );
  }
}
