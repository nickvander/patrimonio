import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// Trim trailing zeros and pick a sensible precision based on the
/// magnitude of the share count (mirrors the formatter in portfolio_card).
String _formatQty(double q) {
  if (q == q.roundToDouble() && q.abs() < 1e9) {
    return q.toInt().toString();
  }
  if (q.abs() >= 1) {
    return q
        .toStringAsFixed(2)
        .replaceAll(RegExp(r'0+$'), '')
        .replaceAll(RegExp(r'\.$'), '');
  }
  return q
      .toStringAsFixed(4)
      .replaceAll(RegExp(r'0+$'), '')
      .replaceAll(RegExp(r'\.$'), '');
}

class AllocationData {
  final String category;
  final String subCategory;
  final double value;
  final Color color;
  final double quantity;

  AllocationData(
    this.category,
    this.subCategory,
    this.value,
    this.color, {
    this.quantity = 0,
  });
}

class AllocationHeatmap extends StatelessWidget {
  final List<AllocationData> data;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const AllocationHeatmap({
    super.key,
    required this.data,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  /// Render raw backend categories ("mutual fund", "fixed income") as
  /// sentence-cased labels with common acronyms preserved (ETF, REIT).
  static String _displayCategory(String raw) {
    if (raw.isEmpty) return 'Other';
    const acronyms = {'etf', 'reit', 'cd', 'ira'};
    return raw
        .split(' ')
        .map((word) {
          if (word.isEmpty) return word;
          if (acronyms.contains(word.toLowerCase())) return word.toUpperCase();
          if (word.contains('/')) {
            // e.g. "stocks/etfs" → "Stocks/ETFs"
            return word
                .split('/')
                .map((p) {
                  if (p.isEmpty) return p;
                  if (acronyms.contains(p.toLowerCase())) return p.toUpperCase();
                  return p[0].toUpperCase() + p.substring(1).toLowerCase();
                })
                .join('/');
          }
          return word[0].toUpperCase() + word.substring(1).toLowerCase();
        })
        .join(' ');
  }

  @override
  Widget build(BuildContext context) {
    if (data.isEmpty) return const SizedBox.shrink();

    final totalValue = data.fold<double>(0, (sum, item) => sum + item.value);

    // Group data by category
    final groupedData = <String, List<AllocationData>>{};
    final categoryColors = <String, Color>{};
    for (var item in data) {
      groupedData.putIfAbsent(item.category, () => []).add(item);
      categoryColors[item.category] = item.color;
    }

    // Sort categories by total value descending
    final sortedCategories = groupedData.keys.toList()
      ..sort((a, b) {
        final sumA = groupedData[a]!.fold<double>(
          0,
          (sum, item) => sum + item.value,
        );
        final sumB = groupedData[b]!.fold<double>(
          0,
          (sum, item) => sum + item.value,
        );
        return sumB.compareTo(sumA);
      });

    return Card(
      elevation: 6,
      shadowColor: Colors.black45,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Flexible(
                  child: Text(
                    'Asset distribution',
                    style: TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    'Total: ${currencyFormat.format(totalValue * conversionFactor)}',
                    style: const TextStyle(
                      fontSize: 14,
                      color: Colors.grey,
                      fontWeight: FontWeight.w600,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            // The "Tree-like" Horizontal Bar View
            ...sortedCategories.map((cat) {
              final items = groupedData[cat]!;
              final catTotal = items.fold<double>(0, (sum, i) => sum + i.value);
              final catPercentage = catTotal / totalValue;
              final color = categoryColors[cat]!;

              return Padding(
                padding: const EdgeInsets.only(bottom: 24.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Expanded(
                          child: Row(
                            children: [
                              Container(
                                width: 12,
                                height: 12,
                                decoration: BoxDecoration(
                                  color: color,
                                  shape: BoxShape.circle,
                                  boxShadow: [
                                    BoxShadow(
                                      color: color.withValues(alpha: 0.4),
                                      blurRadius: 8,
                                      spreadRadius: 1,
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(width: 12),
                              Flexible(
                                child: Text(
                                  _displayCategory(cat),
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                '${items.length} ${items.length == 1 ? "holding" : "holdings"}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white38,
                                  fontWeight: FontWeight.w500,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '${(catPercentage * 100).toStringAsFixed(1)}%',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Main Category Bar
                    Stack(
                      children: [
                        Container(
                          height: 12,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: Colors.white12,
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                        FractionallySizedBox(
                          widthFactor: catPercentage.clamp(0.0, 1.0),
                          child: Container(
                            height: 12,
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: [color, color.withValues(alpha: 0.7)],
                              ),
                              borderRadius: BorderRadius.circular(6),
                              boxShadow: [
                                BoxShadow(
                                  color: color.withValues(alpha: 0.3),
                                  blurRadius: 10,
                                  offset: const Offset(0, 4),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    // Sub-items (the "Tree" detail)
                    Wrap(
                      spacing: 16,
                      runSpacing: 8,
                      children: items.map((item) {
                        return Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 4,
                              height: 4,
                              decoration: BoxDecoration(
                                color: Colors.grey.withValues(alpha: 0.5),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              item.subCategory,
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.white70,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (item.quantity > 0) ...[
                              const SizedBox(width: 4),
                              Text(
                                '· ${_formatQty(item.quantity)} sh',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white38,
                                  fontFeatures: [
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ],
                            const SizedBox(width: 6),
                            Text(
                              currencyFormat.format(
                                item.value * conversionFactor,
                              ),
                              style: const TextStyle(
                                fontSize: 11,
                                color: Colors.white,
                                fontWeight: FontWeight.w600,
                                fontFeatures: [FontFeature.tabularFigures()],
                              ),
                            ),
                          ],
                        );
                      }).toList(),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
