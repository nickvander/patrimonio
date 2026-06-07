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

/// Account-type / institution labels: replace separators, sentence-case,
/// keep short acronyms (IRA, ETF) uppercase.
String _prettyLabel(String raw, AppLocalizations l) {
  if (raw.isEmpty) return l.pfOther;
  final normalised = raw.replaceAll('_', ' ').replaceAll('-', ' ').trim();
  return normalised
      .split(' ')
      .where((p) => p.isNotEmpty)
      .map((p) {
        final upper = p.toUpperCase();
        if (upper == p && p.length <= 4) return p; // already an acronym
        return p[0].toUpperCase() + p.substring(1).toLowerCase();
      })
      .join(' ');
}

/// One renderable allocation band (a category / account-type / institution).
class _Band {
  final String label;
  final double value;
  final Color color;

  /// Holdings inside this band — only populated for the asset-class
  /// dimension, where we show a top-N preview. Empty for type/institution.
  final List<AllocationData> items;

  /// Raw category key for the asset-class dimension — keys the holdings
  /// preview / expand state. Null for type/institution bands.
  final String? rawCategory;

  /// Raw value tapping this band filters the holdings table by (matched
  /// against the holding's holding_type / account_type / institution_name).
  /// Empty = not tappable.
  final String filterValue;

  /// Holdings count shown as a chip (asset-class dimension only).
  final int? holdingsCount;

  _Band({
    required this.label,
    required this.value,
    required this.color,
    this.items = const [],
    this.rawCategory,
    this.filterValue = '',
    this.holdingsCount,
  });
}

/// Single allocation card with a dimension toggle (Asset class · Account
/// type · Institution). Consolidates what used to be three separate cards
/// (the class heatmap, the donut, and the by-type/by-institution breakdown)
/// into one part-to-whole view — the 2026 best-practice "one allocation
/// widget with a dimension control + details on demand".
class AllocationHeatmap extends StatefulWidget {
  final List<AllocationData> data;

  /// `/dashboard/overview` `type_breakdown` rows ({account_type, total_usd,
  /// count}). When non-empty, an "Account type" toggle appears.
  final List<dynamic> typeBreakdown;

  /// `/dashboard/overview` `institution_breakdown` rows ({name, total_usd,
  /// account_count}). When non-empty, an "Institution" toggle appears.
  final List<dynamic> institutionBreakdown;

  final double conversionFactor;
  final NumberFormat currencyFormat;

  /// Fired when any band is tapped — passes the band's raw value to filter
  /// the holdings table (matched against holding_type / account_type /
  /// institution_name, whichever dimension is active).
  final ValueChanged<String>? onCategorySelected;

  /// The currently-applied filter value, so the matching band highlights.
  final String? activeCategory;

  const AllocationHeatmap({
    super.key,
    required this.data,
    required this.conversionFactor,
    required this.currencyFormat,
    this.typeBreakdown = const [],
    this.institutionBreakdown = const [],
    this.onCategorySelected,
    this.activeCategory,
  });

  @override
  State<AllocationHeatmap> createState() => _AllocationHeatmapState();
}

class _AllocationHeatmapState extends State<AllocationHeatmap> {
  static const _previewCount = 4;

  // Categories expanded to show all holdings (asset-class dimension).
  final Set<String> _expanded = {};

  // Active dimension: 0 = asset class, 1 = account type, 2 = institution.
  int _dim = 0;

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final classData = widget.data;
    if (classData.isEmpty) return const SizedBox.shrink();

    final hasType = widget.typeBreakdown.isNotEmpty;
    final hasInst = widget.institutionBreakdown.isNotEmpty;
    final hasToggle = hasType || hasInst;

    // Clamp the active dimension to one that actually has data.
    var dim = _dim;
    if (dim == 1 && !hasType) dim = 0;
    if (dim == 2 && !hasInst) dim = 0;

    // Concentration signal is always computed from the underlying holdings
    // (asset-class data), regardless of which dimension is on screen:
    // >5% notable, >10% real risk, >=20% concentrated.
    AllocationData? topHolding;
    for (final item in classData) {
      if (topHolding == null || item.value > topHolding.value) {
        topHolding = item;
      }
    }
    final classTotal =
        classData.fold<double>(0, (sum, item) => sum + item.value);
    final topShare =
        (topHolding != null && classTotal > 0) ? topHolding.value / classTotal : 0.0;
    final showConcentration = topShare >= 0.20;

    final bands = _bandsFor(dim, l);
    final activeTotal = bands.fold<double>(0, (sum, b) => sum + b.value);

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
                        .format(activeTotal * widget.conversionFactor)),
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
            if (hasToggle) ...[
              const SizedBox(height: 16),
              _dimensionToggle(dim, hasType, hasInst, l),
            ],
            if (showConcentration && topHolding != null) ...[
              const SizedBox(height: 16),
              _concentrationBanner(context, l, topHolding.subCategory, topShare),
            ],
            const SizedBox(height: 24),
            ...bands.map((b) => _bandWidget(b, activeTotal, l)),
          ],
        ),
      ),
    );
  }

  /// Build the bands for the active dimension.
  List<_Band> _bandsFor(int dim, AppLocalizations l) {
    final palette = <Color>[
      context.tealAccent,
      context.info,
      context.yellowAccent,
      context.purpleAccent,
      context.pinkAccent,
      context.positive,
      context.warning,
    ];
    Color paletteAt(int i) => palette[i % palette.length];

    if (dim == 0) {
      final grouped = <String, List<AllocationData>>{};
      final colors = <String, Color>{};
      for (final item in widget.data) {
        grouped.putIfAbsent(item.category, () => []).add(item);
        colors[item.category] = item.color;
      }
      final cats = grouped.keys.toList()
        ..sort((a, b) {
          final sa = grouped[a]!.fold<double>(0, (s, i) => s + i.value);
          final sb = grouped[b]!.fold<double>(0, (s, i) => s + i.value);
          return sb.compareTo(sa);
        });
      return cats.map((cat) {
        final items = grouped[cat]!;
        return _Band(
          label: _displayCategory(cat, l),
          value: items.fold<double>(0, (s, i) => s + i.value),
          color: colors[cat]!,
          items: items,
          rawCategory: cat,
          filterValue: cat,
          holdingsCount: items.length,
        );
      }).toList();
    }

    final rows = dim == 1 ? widget.typeBreakdown : widget.institutionBreakdown;
    final bands = <_Band>[];
    for (final raw in rows) {
      if (raw is! Map) continue;
      final value = ((raw['total_usd'] ?? raw['total'] ?? 0) as num).toDouble();
      if (value <= 0) continue;
      // Keep the RAW value for filtering (matches holdings' account_type /
      // institution_name); prettify only the display label.
      final rawValue = dim == 1
          ? (raw['account_type'] ?? '').toString()
          : (raw['name'] ?? '').toString();
      final label =
          dim == 1 ? _prettyLabel(rawValue, l) : (rawValue.isEmpty ? l.pfOther : rawValue);
      bands.add(_Band(
          label: label, value: value, color: Colors.transparent, filterValue: rawValue));
    }
    bands.sort((a, b) => b.value.compareTo(a.value));
    // Assign palette colors after sorting so the biggest bands lead.
    return [
      for (var i = 0; i < bands.length; i++)
        _Band(
          label: bands[i].label,
          value: bands[i].value,
          color: paletteAt(i),
          filterValue: bands[i].filterValue,
        ),
    ];
  }

  Widget _dimensionToggle(int dim, bool hasType, bool hasInst, AppLocalizations l) {
    Widget chip(String label, int idx) {
      final active = dim == idx;
      return InkWell(
        onTap: () => setState(() => _dim = idx),
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
          decoration: BoxDecoration(
            color: active
                ? context.tealAccent.withValues(alpha: 0.15)
                : context.tileSurface,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: active
                  ? context.tealAccent.withValues(alpha: 0.5)
                  : Colors.transparent,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: active ? FontWeight.w700 : FontWeight.w500,
              color: active ? context.tealAccent : context.textMuted,
            ),
          ),
        ),
      );
    }

    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        chip(l.lwAllocDimClass, 0),
        if (hasType) chip(l.lwAllocDimType, 1),
        if (hasInst) chip(l.lwAllocDimInstitution, 2),
      ],
    );
  }

  Widget _bandWidget(_Band b, double total, AppLocalizations l) {
    final pct = total > 0 ? b.value / total : 0.0;
    final isActive = b.filterValue.isNotEmpty && widget.activeCategory == b.filterValue;
    final canTap = b.filterValue.isNotEmpty && widget.onCategorySelected != null;

    final inner = Padding(
      padding: const EdgeInsets.only(bottom: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration:
                          BoxDecoration(color: b.color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        b.label,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: context.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (b.holdingsCount != null) ...[
                      const SizedBox(width: 8),
                      Text(
                        l.lwAllocHoldingsCount(b.holdingsCount!),
                        style: TextStyle(
                          fontSize: 11,
                          color: context.textFaint,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${(pct * 100).toStringAsFixed(1)}%',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: b.color,
                    ),
                  ),
                  Text(
                    widget.currencyFormat
                        .format(b.value * widget.conversionFactor),
                    style: TextStyle(
                      fontSize: 11,
                      color: context.textFaint,
                      fontWeight: FontWeight.w600,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
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
                widthFactor: pct.clamp(0.0, 1.0),
                child: Container(
                  height: 12,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [b.color, b.color.withValues(alpha: 0.7)],
                    ),
                    borderRadius: BorderRadius.circular(6),
                  ),
                ),
              ),
            ],
          ),
          if (isActive) ...[
            const SizedBox(height: 8),
            Text(
              l.lwAllocFilteringHint,
              style: TextStyle(
                fontSize: 10,
                color: b.color,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
          if (b.items.isNotEmpty && b.rawCategory != null) ...[
            const SizedBox(height: 12),
            _holdingsPreview(b.rawCategory!, b.items, b.value, b.color, l),
          ],
        ],
      ),
    );

    final semanticLabel = l.lwAllocSemanticLabel(
      b.label,
      '${(pct * 100).toStringAsFixed(1)}%',
      b.holdingsCount ?? 0,
    );

    if (!canTap) {
      return Semantics(label: semanticLabel, child: inner);
    }
    return Semantics(
      button: true,
      label: semanticLabel,
      child: InkWell(
        onTap: () => widget.onCategorySelected!(b.filterValue),
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          decoration: BoxDecoration(
            color: isActive
                ? b.color.withValues(alpha: 0.06)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          child: inner,
        ),
      ),
    );
  }

  Widget _concentrationBanner(
    BuildContext context,
    AppLocalizations l,
    String holding,
    double share,
  ) {
    final color = context.warning;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, color: color, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l.lwAllocConcentration(
                  holding, '${(share * 100).toStringAsFixed(0)}%'),
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
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
