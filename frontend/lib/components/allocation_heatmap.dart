import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import '../l10n/app_localizations.dart';
import 'package:intl/intl.dart';

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

/// Render raw backend categories ("mutual fund", "fixed income") as
/// sentence-cased labels with common acronyms preserved (ETF, REIT).
String _displayCategory(String raw, AppLocalizations l) {
  if (raw.isEmpty) return l.lwAllocOtherCategory;
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

class AllocationHeatmap extends StatefulWidget {
  final List<AllocationData> data;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  /// Optional callback fired when the user taps a category band. Lets the
  /// parent filter the holdings table below — wiring is opt-in so the
  /// component remains usable in standalone contexts.
  final ValueChanged<String>? onCategorySelected;

  /// Highlighted category, drawn with a brighter ring so the user can see
  /// which slice is currently driving the active filter.
  final String? activeCategory;

  const AllocationHeatmap({
    super.key,
    required this.data,
    required this.conversionFactor,
    required this.currencyFormat,
    this.onCategorySelected,
    this.activeCategory,
  });

  @override
  State<AllocationHeatmap> createState() => _AllocationHeatmapState();
}

class _AllocationHeatmapState extends State<AllocationHeatmap> {
  // How many holdings each category shows before the "show more" toggle. The
  // full per-holding detail lives in the holdings table below — this card is
  // the allocation glance, so it previews the biggest positions only.
  static const _previewCount = 4;

  // Categories the user has expanded to show all holdings.
  final Set<String> _expanded = {};

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final data = widget.data;
    if (data.isEmpty) return const SizedBox.shrink();

    final totalValue = data.fold<double>(0, (sum, item) => sum + item.value);

    // Group data by category.
    final groupedData = <String, List<AllocationData>>{};
    final categoryColors = <String, Color>{};
    for (var item in data) {
      groupedData.putIfAbsent(item.category, () => []).add(item);
      categoryColors[item.category] = item.color;
    }

    // Sort categories by total value descending.
    final sortedCategories = groupedData.keys.toList()
      ..sort((a, b) {
        final sumA =
            groupedData[a]!.fold<double>(0, (sum, item) => sum + item.value);
        final sumB =
            groupedData[b]!.fold<double>(0, (sum, item) => sum + item.value);
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
                Flexible(
                  child: Text(
                    l.lwAllocTitle,
                    style: const TextStyle(
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
                    l.lwAllocTotal(widget.currencyFormat
                        .format(totalValue * widget.conversionFactor)),
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
            // The "tree-like" horizontal-bar view, one band per category.
            ...sortedCategories.map((cat) {
              final items = groupedData[cat]!;
              final catTotal = items.fold<double>(0, (sum, i) => sum + i.value);
              final catPercentage = totalValue > 0 ? catTotal / totalValue : 0.0;
              final color = categoryColors[cat]!;
              final isActive = widget.activeCategory == cat;
              final canTap = widget.onCategorySelected != null;

              final inner = Padding(
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
                                  _displayCategory(cat, l),
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                    color: context.textPrimary,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              const SizedBox(width: 8),
                              Text(
                                l.lwAllocHoldingsCount(items.length),
                                style: TextStyle(
                                  fontSize: 11,
                                  color: context.textFaint,
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
                    // Main category bar.
                    Stack(
                      children: [
                        Container(
                          height: 12,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: context.hairline,
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
                    if (isActive)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 8),
                        child: Text(
                          l.lwAllocFilteringHint,
                          style: TextStyle(
                            fontSize: 10,
                            color: color,
                            fontStyle: FontStyle.italic,
                          ),
                        ),
                      ),
                    // Top holdings as aligned rows (biggest first), with a
                    // toggle for the rest. Replaces the old inline chip flow
                    // so values line up in a column and the band can't grow
                    // unbounded / duplicate the full holdings table.
                    _holdingsPreview(cat, items, catTotal, color, l),
                  ],
                ),
              );

              final semanticLabel = l.lwAllocSemanticLabel(
                _displayCategory(cat, l),
                '${(catPercentage * 100).toStringAsFixed(1)}%',
                items.length,
              );

              if (!canTap) {
                return Semantics(label: semanticLabel, child: inner);
              }
              return Semantics(
                button: true,
                label: semanticLabel,
                child: InkWell(
                  onTap: () => widget.onCategorySelected!(cat),
                  borderRadius: BorderRadius.circular(12),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    decoration: BoxDecoration(
                      color: isActive
                          ? color.withValues(alpha: 0.06)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: inner,
                  ),
                ),
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _holdingsPreview(
    String cat,
    List<AllocationData> items,
    double catTotal,
    Color color,
    AppLocalizations l,
  ) {
    final sorted = [...items]..sort((a, b) => b.value.compareTo(a.value));
    final expanded = _expanded.contains(cat);
    final visible = expanded ? sorted : sorted.take(_previewCount).toList();
    final remaining = sorted.length - _previewCount;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...visible.map((item) => _holdingRow(item, catTotal)),
        if (remaining > 0)
          // Inner tap target wins the gesture arena over the band's filter
          // InkWell, so expanding doesn't also toggle the category filter.
          InkWell(
            onTap: () => setState(() {
              if (expanded) {
                _expanded.remove(cat);
              } else {
                _expanded.add(cat);
              }
            }),
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
              child: Text(
                expanded ? l.lwAllocShowFewer : l.lwAllocShowMore(remaining),
                style: TextStyle(
                  fontSize: 11.5,
                  color: color,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _holdingRow(AllocationData item, double catTotal) {
    final weight = catTotal > 0 ? item.value / catTotal : 0.0;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3.0, horizontal: 12.0),
      child: Row(
        children: [
          Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.grey.withValues(alpha: 0.5),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 10),
          // Name — clamped to one line so long fund names can't push the
          // value/percent columns out of alignment.
          Expanded(
            child: Text(
              item.subCategory,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12.5,
                color: context.textMuted,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            widget.currencyFormat.format(item.value * widget.conversionFactor),
            style: TextStyle(
              fontSize: 12,
              color: context.textPrimary,
              fontWeight: FontWeight.w600,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 10),
          // Share of this category (drill-down to the band's % of total).
          SizedBox(
            width: 40,
            child: Text(
              '${(weight * 100).toStringAsFixed(0)}%',
              textAlign: TextAlign.right,
              style: TextStyle(
                fontSize: 11,
                color: context.textFaint,
                fontWeight: FontWeight.w600,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
