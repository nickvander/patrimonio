import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../utils/currency.dart';
import '../utils/percent_format.dart';
import '../utils/theme_colors.dart';

class AllocationData {
  final String category;
  final String subCategory;
  final double value;
  final Color color;
  final double quantity;

  /// Canonical backend asset-class key (`equity | bonds | cash | crypto |
  /// real_estate | commodities | other`). Null when the backend doesn't
  /// send `asset_class` yet — band taps then fall back to emitting the
  /// legacy bare [category] as the filter value.
  final String? assetClassKey;

  AllocationData(
    this.category,
    this.subCategory,
    this.value,
    this.color, {
    this.quantity = 0,
    this.assetClassKey,
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
  const acronyms = {'ira', 'hsa', 'cd', '401k', 'etf', 'reit'};
  final normalised = raw.replaceAll('_', ' ').replaceAll('-', ' ').trim();
  return normalised
      .split(' ')
      .where((p) => p.isNotEmpty)
      .map((p) {
        // Known acronyms render all-caps regardless of input case
        // ("ira" → "IRA", "401k" → "401K").
        if (acronyms.contains(p.toLowerCase())) return p.toUpperCase();
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

  /// Dimension-prefixed value tapping this band emits to filter the
  /// holdings table (contract C3): `asset:<canonical key>`,
  /// `account_type:<raw type>` or `institution:<raw name>`. A bare
  /// (unprefixed) legacy category is emitted when the backend doesn't
  /// send `asset_class` yet. Empty = not tappable.
  final String filterValue;

  /// Holdings count shown as a chip (asset-class dimension only).
  final int? holdingsCount;

  /// Account count (type / institution dimensions) — semantics only.
  final int? accountsCount;

  /// C-G "Unclassified (account balance)" band: an investment account with
  /// a balance but no holdings rows. Rendered muted and inert — no filter
  /// value (nothing to filter to), no hover/pointer affordance, a tooltip
  /// explaining what it is.
  final bool isUnclassified;

  _Band({
    required this.label,
    required this.value,
    required this.color,
    this.items = const [],
    this.rawCategory,
    this.filterValue = '',
    this.holdingsCount,
    this.accountsCount,
    this.isUnclassified = false,
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

  /// C3 prefix each dimension's bands emit as filter values.
  static String _dimPrefix(int dim) => switch (dim) {
        0 => 'asset:',
        1 => 'account_type:',
        _ => 'institution:',
      };

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

    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;

    return Card(
      elevation: 6,
      shadowColor: Colors.black45,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // A4 (round 3, a11y): title + total announce as ONE header
            // landmark ("Asset distribution, Total $X") so screen readers
            // can jump to the card and hear its headline figure at once.
            MergeSemantics(
              child: Semantics(
                header: true,
                child: Row(
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
                    // Money never ellipsizes mid-digits: mirror the
                    // net-worth hero — FittedBox shrinks the total down
                    // on narrow cards instead of clipping it to
                    // "Total $1,234,5…".
                    Flexible(
                      child: FittedBox(
                        fit: BoxFit.scaleDown,
                        alignment: Alignment.centerRight,
                        child: Text(
                          l.lwAllocTotal(widget.currencyFormat
                              .displayMoney(activeTotal * widget.conversionFactor)),
                          style: TextStyle(
                            fontSize: 14,
                            color: context.textSubtle,
                            fontWeight: FontWeight.w600,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                          textAlign: TextAlign.right,
                          maxLines: 1,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (hasToggle) ...[
              const SizedBox(height: 16),
              _dimensionToggle(dim, hasType, hasInst, l),
            ],
            // Permanent tap affordance / active-filter indicator — the
            // filtered table lives below the fold, so the state has to be
            // readable up here.
            const SizedBox(height: 14),
            _filterStatusRow(bands, l),
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
        // C3 emit side: prefix with the dimension + the backend's
        // canonical asset-class key (C2). If the backend doesn't send
        // `asset_class` yet, fall back to the legacy bare category so
        // tap-to-filter keeps working before the backend merge.
        String? classKey;
        for (final item in items) {
          final k = item.assetClassKey;
          if (k != null && k.isNotEmpty) {
            classKey = k;
            break;
          }
        }
        // C-G: holdings-less investment accounts surface as an inert
        // "Unclassified (account balance)" band — muted neutral (not a
        // category hue), NO filter value (empty ⇒ not tappable: there
        // are no holdings rows behind it), and its items are accounts
        // rather than holdings.
        final isUnclassified = classKey == 'unclassified';
        return _Band(
          label: isUnclassified
              ? l.alloc2UnclassifiedBand
              : _displayCategory(cat, l),
          value: items.fold<double>(0, (s, i) => s + i.value),
          color: isUnclassified ? context.neutralAccent : colors[cat]!,
          items: items,
          rawCategory: cat,
          filterValue: isUnclassified
              ? ''
              : (classKey != null ? 'asset:$classKey' : cat),
          holdingsCount: isUnclassified ? null : items.length,
          accountsCount: isUnclassified ? items.length : null,
          isUnclassified: isUnclassified,
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
      // institution_name); prettify only the display label. C3 emit side:
      // prefix the raw value with its dimension.
      final rawValue = dim == 1
          ? (raw['account_type'] ?? '').toString()
          : (raw['name'] ?? '').toString();
      final label =
          dim == 1 ? _prettyLabel(rawValue, l) : (rawValue.isEmpty ? l.pfOther : rawValue);
      final filterValue = rawValue.isEmpty
          ? ''
          : (dim == 1 ? 'account_type:$rawValue' : 'institution:$rawValue');
      final accounts =
          ((raw['count'] ?? raw['account_count']) as num?)?.toInt();
      bands.add(_Band(
          label: label,
          value: value,
          color: Colors.transparent,
          filterValue: filterValue,
          accountsCount: accounts));
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
          accountsCount: bands[i].accountsCount,
        ),
    ];
  }

  Widget _dimensionToggle(int dim, bool hasType, bool hasInst, AppLocalizations l) {
    Widget chip(String label, int idx) {
      final active = dim == idx;
      // A4 (round 3, a11y): the plain InkWell+Text pill announces as a
      // selectable button ("Group by Asset class"); the visual Text is
      // excluded so it isn't read twice.
      return MergeSemantics(
        child: Semantics(
        button: true,
        selected: active,
        label: l.axGroupBy(label),
        child: InkWell(
        onTap: () {
          // Switching dimension must not leave an invisible
          // cross-dimension filter applied — if the active filter
          // wasn't emitted by the new dimension (prefix mismatch, or a
          // legacy bare value), toggle-clear it via the same callback
          // the bands use.
          final activeFilter = widget.activeCategory;
          if (idx != dim &&
              activeFilter != null &&
              activeFilter.isNotEmpty &&
              !activeFilter.startsWith(_dimPrefix(idx)) &&
              widget.onCategorySelected != null) {
            widget.onCategorySelected!(activeFilter);
          }
          setState(() => _dim = idx);
        },
        borderRadius: BorderRadius.circular(20),
        child: ExcludeSemantics(
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

  /// Always-visible affordance under the header: either the "tap a band
  /// to filter" hint, or — when a filter is applied — its display label
  /// with an inline ✕ that clears it (same toggle callback the bands use).
  Widget _filterStatusRow(List<_Band> bands, AppLocalizations l) {
    final active = widget.activeCategory;
    _Band? match;
    if (active != null && active.isNotEmpty) {
      for (final b in bands) {
        if (b.filterValue == active) {
          match = b;
          break;
        }
      }
    }
    if (match == null) {
      return Row(
        children: [
          // A4 (round 3, a11y): decorative glyph — explicitly excluded.
          ExcludeSemantics(
            child: Icon(Icons.touch_app_outlined,
                size: 14, color: context.textFaint),
          ),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              l.allocTapToFilterHint,
              style: TextStyle(
                fontSize: 11.5,
                color: context.textFaint,
                fontWeight: FontWeight.w500,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      );
    }
    final band = match;
    return Row(
      children: [
        Flexible(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: band.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: band.color.withValues(alpha: 0.4)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: Text(
                    l.allocActiveFilter(band.label),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: band.color,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.onCategorySelected != null) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: () =>
                        widget.onCategorySelected!(band.filterValue),
                    borderRadius: BorderRadius.circular(10),
                    child: Tooltip(
                      message: l.allocClearFilter,
                      child: Semantics(
                        button: true,
                        label: l.allocClearFilter,
                        child: Icon(Icons.close, size: 14, color: band.color),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _bandWidget(_Band b, double total, AppLocalizations l) {
    final pct = total > 0 ? b.value / total : 0.0;
    final isActive = b.filterValue.isNotEmpty && widget.activeCategory == b.filterValue;
    final canTap = b.filterValue.isNotEmpty && widget.onCategorySelected != null;

    // C-G: the Unclassified band is visibly muted — greyed dot, washed bar
    // fill, AND muted title/percent text — so the whole band reads as inert
    // next to the tappable category bands (with only the dot/bar muted the
    // bold title + colored % still looked tappable at rest).
    final dotColor =
        b.isUnclassified ? b.color.withValues(alpha: 0.55) : b.color;
    final barGradient = b.isUnclassified
        ? [b.color.withValues(alpha: 0.45), b.color.withValues(alpha: 0.30)]
        : [b.color, b.color.withValues(alpha: 0.7)];
    final titleColor =
        b.isUnclassified ? context.textMuted : context.textPrimary;
    final pctColor = b.isUnclassified ? context.textMuted : b.color;

    // The band "core" the tap target / semantics blob covers: header row +
    // bar (+ filtering hint). The holdings preview and its "Show N more"
    // expander live OUTSIDE this blob (appended below) so the band's
    // filter action can never swallow the expander.
    final inner = Column(
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
                          BoxDecoration(color: dotColor, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 12),
                    Flexible(
                      child: Text(
                        b.label,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: titleColor,
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
                    formatPercent(context, pct * 100, digits: 1),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      color: pctColor,
                    ),
                  ),
                  Text(
                    widget.currencyFormat
                        .displayMoney(b.value * widget.conversionFactor),
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
                    gradient: LinearGradient(colors: barGradient),
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
        ],
      );

    // Holdings preview + its "Show N more" expander: a SIBLING of the
    // band's tap target / semantics node, never a descendant. Tapping the
    // band filters the table, so if the preview lived inside the InkWell
    // (as it used to), mid-row whitespace clicks and assistive-tech
    // activation on the expander applied the filter instead of expanding.
    // The 8px horizontal padding mirrors the tappable band's container
    // padding so the preview rows keep their previous indentation.
    final preview = (b.items.isNotEmpty && b.rawCategory != null)
        ? Padding(
            padding: const EdgeInsets.only(top: 12, left: 8, right: 8),
            child:
                _holdingsPreview(b.rawCategory!, b.items, b.value, b.color, l),
          )
        : null;

    Widget withPreviewAndMargin(Widget core) {
      return Padding(
        padding: EdgeInsets.only(
            bottom: MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0),
        child: preview == null
            ? core
            : Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [core, preview],
              ),
      );
    }

    // Real counts, never a hardcoded 0: asset-class bands carry their
    // holdings count (items.length); type/institution bands carry the
    // breakdown rows' account count. Bands with neither omit the count.
    final valueLabel =
        '${formatPercent(context, pct * 100, digits: 1)} · ${widget.currencyFormat.displayMoney(b.value * widget.conversionFactor)}';
    final String baseLabel;
    if (b.holdingsCount != null) {
      baseLabel =
          l.allocBandSemanticsHoldings(b.label, valueLabel, b.holdingsCount!);
    } else if (b.accountsCount != null) {
      baseLabel =
          l.allocBandSemanticsAccounts(b.label, valueLabel, b.accountsCount!);
    } else {
      baseLabel = l.allocBandSemanticsNoCount(b.label, valueLabel);
    }
    final semanticLabel =
        canTap ? '$baseLabel, ${l.allocBandFiltersTable}' : baseLabel;

    if (!canTap) {
      // The Unclassified band is deliberately inert: no InkWell (so no
      // hover brightening and the cursor stays the plain arrow), just a
      // tooltip + semantics explaining why tapping wouldn't do anything.
      if (b.isUnclassified) {
        return withPreviewAndMargin(Tooltip(
          message: l.alloc2UnclassifiedTooltip,
          waitDuration: const Duration(milliseconds: 400),
          // The Semantics label below already carries the explanation —
          // don't let Tooltip add a duplicate node.
          excludeFromSemantics: true,
          child: MouseRegion(
            cursor: MouseCursor.defer,
            child: Semantics(
              label: '$baseLabel. ${l.alloc2UnclassifiedTooltip}',
              child: inner,
            ),
          ),
        ));
      }
      return withPreviewAndMargin(Semantics(label: semanticLabel, child: inner));
    }
    return withPreviewAndMargin(Semantics(
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
    ));
  }

  Widget _concentrationBanner(
    BuildContext context,
    AppLocalizations l,
    String holding,
    double share,
  ) {
    final color = context.warning;
    // A4 (round 3, a11y): the banner is one labelled node; the warning
    // glyph is decorative (the text carries the message).
    return MergeSemantics(
      child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          ExcludeSemantics(
            child: Icon(Icons.warning_amber_rounded, color: color, size: 18),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              l.lwAllocConcentration(
                  holding, formatPercent(context, share * 100, digits: 0)),
              style: TextStyle(
                color: color,
                fontWeight: FontWeight.w600,
                fontSize: 12.5,
              ),
            ),
          ),
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
          // The expander is its OWN labelled button node (it used to be an
          // unlabelled InkWell swallowed by the band's filter blob), and its
          // tap target is the whole row — a mid-row whitespace click
          // expands instead of falling through to the band.
          MergeSemantics(
            child: Semantics(
              button: true,
              label:
                  expanded ? l.lwAllocShowFewer : l.lwAllocShowMore(remaining),
              child: InkWell(
                onTap: () => setState(() {
                  if (expanded) {
                    _expanded.remove(cat);
                  } else {
                    _expanded.add(cat);
                  }
                }),
                borderRadius: BorderRadius.circular(6),
                child: ExcludeSemantics(
                  child: SizedBox(
                    width: double.infinity,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          vertical: 6, horizontal: 12),
                      child: Text(
                        expanded
                            ? l.lwAllocShowFewer
                            : l.lwAllocShowMore(remaining),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: color,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
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
              color: context.textSubtle,
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
            widget.currencyFormat.displayMoney(item.value * widget.conversionFactor),
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
              formatPercent(context, weight * 100, digits: 0),
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
