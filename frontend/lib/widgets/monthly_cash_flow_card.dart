import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

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

  const MonthlyCashFlowCard({
    super.key,
    required this.trends,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  @override
  Widget build(BuildContext context) {
    if (trends.isEmpty) {
      return _buildEmpty();
    }

    // The API returns months in chronological order; the *last* element is
    // the current month and the previous one is what we compare against.
    final current = trends.last;
    final prior = trends.length >= 2 ? trends[trends.length - 2] : null;

    final income =
        ((current['income'] as num?)?.toDouble() ?? 0.0) * conversionFactor;
    final spending =
        ((current['spending'] as num?)?.toDouble() ?? 0.0) * conversionFactor;
    final net = income - spending;

    double? priorNet;
    if (prior != null) {
      final pi = ((prior['income'] as num?)?.toDouble() ?? 0.0) *
          conversionFactor;
      final ps = ((prior['spending'] as num?)?.toDouble() ?? 0.0) *
          conversionFactor;
      priorNet = pi - ps;
    }

    // Slice up to the last 3 months for the sparkline. If we don't have
    // three months of history we use whatever's available.
    final sparkSource =
        trends.length >= 3 ? trends.sublist(trends.length - 3) : trends;

    final monthLabel = _formatMonth(current['month'] as String?);

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: LayoutBuilder(
          builder: (ctx, c) {
            final isNarrow = c.maxWidth < 560;
            final header = Row(
              children: [
                const Icon(
                  Icons.account_balance_wallet_outlined,
                  size: 18,
                  color: Color(0xFF1DE9B6),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Cash flow this month',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    monthLabel,
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.white54,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            );

            final netLine = _NetLine(
              net: net,
              priorNet: priorNet,
              currencyFormat: currencyFormat,
            );

            final stats = Row(
              children: [
                Expanded(
                  child: _StatBlock(
                    label: 'Income',
                    value: currencyFormat.format(income),
                    accent: const Color(0xFF1DE9B6),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: _StatBlock(
                    label: 'Expense',
                    value: currencyFormat.format(spending),
                    accent: const Color(0xFFFF4081),
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
                  const SizedBox(height: 16),
                  netLine,
                  const SizedBox(height: 16),
                  stats,
                  const SizedBox(height: 16),
                  SizedBox(height: 56, child: spark),
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

  Widget _buildEmpty() {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: const Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          'Cash flow will appear here once a few weeks of transactions are synced.',
          style: TextStyle(color: Colors.white54, fontSize: 13),
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
  final NumberFormat currencyFormat;

  const _NetLine({
    required this.net,
    required this.priorNet,
    required this.currencyFormat,
  });

  @override
  Widget build(BuildContext context) {
    final positive = net >= 0;
    final color =
        positive ? const Color(0xFF00E676) : const Color(0xFFFF4081);
    final delta = priorNet == null ? null : net - priorNet!;

    return Row(
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
              '${delta >= 0 ? '↑' : '↓'} ${currencyFormat.format(delta.abs())} vs last month',
              style: TextStyle(
                fontSize: 11,
                color: delta >= 0
                    ? const Color(0xFF00E676)
                    : const Color(0xFFFF4081),
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
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
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.25)),
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
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              fontFeatures: [FontFeature.tabularFigures()],
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
          'Not enough history yet',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: 11,
          ),
        ),
      );
    }
    // Pad the min/max so a perfectly-flat series doesn't collapse to a line.
    final minV = points.reduce((a, b) => a < b ? a : b);
    final maxV = points.reduce((a, b) => a > b ? a : b);
    final pad = (maxV - minV).abs() * 0.15 + 1;

    final color =
        positive ? const Color(0xFF00E676) : const Color(0xFFFF4081);

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
