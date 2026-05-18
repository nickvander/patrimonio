import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import 'package:intl/intl.dart';

class CreditUtilizationCard extends StatefulWidget {
  final List<dynamic> creditData;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const CreditUtilizationCard({
    super.key,
    required this.creditData,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  @override
  State<CreditUtilizationCard> createState() => _CreditUtilizationCardState();
}

class _CreditUtilizationCardState extends State<CreditUtilizationCard> {
  static const int _collapsedLimit = 3;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    // Read the props through `widget.` (StatefulWidget body).
    final creditData = widget.creditData;
    if (creditData.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Center(
            child: Text(
              'No credit accounts found.',
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ),
      );
    }

    final totalBalance = creditData.fold<double>(
      0.0,
      (sum, item) => sum + ((item['balance'] ?? 0.0) as num).toDouble(),
    );
    final totalLimit = creditData.fold<double>(
      0.0,
      (sum, item) => sum + ((item['credit_limit'] ?? 0.0) as num).toDouble(),
    );
    final totalUtilization = totalLimit > 0
        ? (totalBalance / totalLimit) * 100
        : 0.0;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'CREDIT UTILIZATION',
                  style: TextStyle(
                    fontSize: 11,
                    color: context.textSubtle,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2,
                  ),
                ),
                Text(
                  '${totalUtilization.toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: totalUtilization > 30
                        ? context.warning
                        : context.positive,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: LinearProgressIndicator(
                value: (totalUtilization / 100).clamp(0.0, 1.0),
                backgroundColor: context.hairline,
                color: totalUtilization > 30
                    ? context.warning
                    : context.positive,
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 24),
            ..._buildCreditRows(),
          ],
        ),
      ),
    );
  }

  /// Sort by utilization (highest first) and cap at `_collapsedLimit`
  /// unless the user has expanded the list. Caps prevent a portfolio of
  /// 10+ credit cards from dominating the Overview tab.
  List<Widget> _buildCreditRows() {
    final creditData = widget.creditData;
    final conversionFactor = widget.conversionFactor;
    final currencyFormat = widget.currencyFormat;

    final sorted = [...creditData]..sort((a, b) {
        double util(dynamic x) {
          final balance = ((x['balance'] ?? 0.0) as num).toDouble();
          final limit = ((x['credit_limit'] ?? 0.0) as num).toDouble();
          return limit > 0 ? balance / limit : 0.0;
        }
        return util(b).compareTo(util(a));
      });

    final visible = _expanded || sorted.length <= _collapsedLimit
        ? sorted
        : sorted.take(_collapsedLimit).toList();

    final rows = <Widget>[];
    for (final item in visible) {
      final balance = ((item['balance'] ?? 0.0) as num).toDouble();
      final limit = ((item['credit_limit'] ?? 0.0) as num).toDouble();
      final util = limit > 0 ? (balance / limit) * 100 : 0.0;
      rows.add(Padding(
        padding: const EdgeInsets.only(bottom: 16.0),
        child: Column(
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        item['name'] ?? 'Credit account',
                        style: const TextStyle(fontWeight: FontWeight.w500),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        item['institution_name'] ?? '',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.textSubtle,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Text(
                  '${currencyFormat.format(balance * conversionFactor)} / ${currencyFormat.format(limit * conversionFactor)}',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                value: (util / 100).clamp(0.0, 1.0),
                backgroundColor: context.hairline,
                color: util > 30
                    ? context.warning.withValues(alpha: 0.7)
                    : context.positive.withValues(alpha: 0.7),
                minHeight: 4,
              ),
            ),
          ],
        ),
      ));
    }

    if (sorted.length > _collapsedLimit) {
      final hidden = sorted.length - _collapsedLimit;
      rows.add(Center(
        child: TextButton.icon(
          onPressed: () => setState(() => _expanded = !_expanded),
          icon: Icon(
            _expanded ? Icons.expand_less : Icons.expand_more,
            size: 18,
          ),
          label: Text(_expanded
              ? 'Show fewer'
              : 'Show $hidden more ${hidden == 1 ? "card" : "cards"}'),
          style: TextButton.styleFrom(foregroundColor: context.textMuted),
        ),
      ));
    }

    return rows;
  }
}
