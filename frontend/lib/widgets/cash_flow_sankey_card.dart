import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/cash_flow_sankey.dart';
import '../utils/currency.dart';
import '../utils/percent_format.dart';
import '../utils/theme_colors.dart';
import 'skeleton.dart';

/// The cash-flow tab's Sankey: this period's income splitting into spending,
/// investing and what's left — plus an explicit FX-conversion node for money
/// that crossed currencies.
///
/// Assembled entirely from endpoints the tab already calls:
/// `/dashboard/trends` (period income / spending / invested, USD-normalized
/// per row upstream), `/dashboard/spending-by-category` (the outflow
/// breakdown, same window and same hygiene, so the bands reconcile with
/// [MonthlyCashFlowCard]'s figures), the loaded transactions list (income
/// attribution, only when it provably covers the window) and the
/// `cash_fx_transfers` links (the cross-border band).
///
/// `fl_chart` has no Sankey primitive, so the diagram is a [CustomPainter].
/// That means this widget owns everything fl_chart would normally give it:
///
/// * **The readout never renders under the hand.** A tap or drag anywhere on
///   the canvas puts the reading in the card HEADER, above the diagram — the
///   `performance_card` pattern from the chart-touch rules. Nothing is drawn
///   near the touch point except the highlight itself.
/// * **The canvas is invisible to screen readers**, so both diagrams mirror
///   their flows into the semantics tree and the painted surface is wrapped in
///   `ExcludeSemantics`.
/// * **Selection state lives in a [ValueNotifier]** scoped to the header and
///   the canvas, so dragging across flows never re-runs the diagram math.
class CashFlowSankeyCard extends StatefulWidget {
  const CashFlowSankeyCard({
    super.key,
    required this.apiService,
    required this.trends,
    required this.months,
    required this.conversionFactor,
    required this.currencyFormat,
    required this.targetCurrency,
    required this.usdMxnRate,
    this.selectedMonthIso,
    this.periodLabel,
    this.transactions = const <dynamic>[],
    this.fxTransfers = const <dynamic>[],
  });

  final ApiService apiService;

  /// Raw `/dashboard/trends` rows for the tab's current period (USD).
  final List<Map<String, dynamic>> trends;

  /// The tab's period window, in calendar months — drives the
  /// spending-by-category fetch.
  final int months;

  /// Which single month to headline; null → the latest in [trends]. Mirrors
  /// [MonthlyCashFlowCard] exactly.
  final String? selectedMonthIso;

  /// Set for aggregated windows (3 months / YTD) — every month in [trends] is
  /// summed, and this names the window in the header.
  final String? periodLabel;

  final List<dynamic> transactions;
  final List<dynamic> fxTransfers;

  final double conversionFactor;
  final NumberFormat currencyFormat;
  final String targetCurrency;
  final double usdMxnRate;

  @override
  State<CashFlowSankeyCard> createState() => _CashFlowSankeyCardState();
}

class _CashFlowSankeyCardState extends State<CashFlowSankeyCard> {
  Map<String, dynamic>? _categoryData;
  bool _loading = true;

  /// A ValueNotifier, not setState: a drag fires per pointer move and a
  /// setState would rebuild the diagram math on every frame of it.
  final ValueNotifier<_Reading?> _reading = ValueNotifier<_Reading?>(null);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(CashFlowSankeyCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.months != oldWidget.months) _load();
    // Any change to the plotted data invalidates a stale reading — the house
    // rule for a host that renders its own scrub readout.
    if (widget.months != oldWidget.months ||
        widget.selectedMonthIso != oldWidget.selectedMonthIso ||
        widget.periodLabel != oldWidget.periodLabel ||
        widget.targetCurrency != oldWidget.targetCurrency ||
        !identical(widget.trends, oldWidget.trends) ||
        !identical(widget.fxTransfers, oldWidget.fxTransfers)) {
      _reading.value = null;
    }
  }

  @override
  void dispose() {
    _reading.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      // Same `top` as SpendingByCategoryCard so the two cards share one cached
      // GET instead of each paying for a round trip.
      final data = await widget.apiService.getSpendingByCategory(
        months: widget.months,
        top: 6,
      );
      if (mounted) setState(() => _categoryData = data);
    } catch (_) {
      // Keep whatever we had; an absent breakdown degrades to a single
      // honest "Uncategorized" outflow rather than an empty card.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    // Card padding off the card's OWN LayoutBuilder constraint, never
    // the window (skill §4/§5): the card is narrower than the screen on
    // every layout that pads or column-clamps its tab.
    return LayoutBuilder(
      builder: (_, outer) {
        final pad = outer.maxWidth < 720 ? 16.0 : 24.0;
        return Card(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: EdgeInsets.all(pad),
            // Responsive off the card's OWN constraint (house rule), never
            // MediaQuery: the card is narrower than the screen on every layout
            // that pads or column-clamps the tab.
            child: LayoutBuilder(
              builder: (context, c) {
                final isPhone = c.maxWidth < 420;
                final data = buildCashFlowSankey(
                  trends: widget.trends,
                  selectedMonthIso: widget.selectedMonthIso,
                  aggregate: widget.periodLabel != null,
                  categoryData: _categoryData,
                  transactions: widget.transactions,
                  fxTransfers: widget.fxTransfers,
                  conversionFactor: widget.conversionFactor,
                  targetCurrency: widget.targetCurrency,
                  usdMxnRate: widget.usdMxnRate,
                  labels: _labels(l),
                  // Phone widths get fewer nodes, not smaller type: a 30-node
                  // column at 360px is an unreadable comb.
                  maxIncomeSources: isPhone ? 3 : 5,
                  maxCategories: isPhone ? 5 : 8,
                );

                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _header(context, l, isPhone),
                    const SizedBox(height: 10),
                    // The readout lives HERE — above the canvas, permanently
                    // clear of the finger.
                    _readoutBar(context, l, isPhone),
                    const SizedBox(height: 8),
                    if (_loading && _categoryData == null)
                      // Never draw the river with the breakdown still in flight:
                      // every outflow would land in "Uncategorized" for a frame
                      // and then jump. A permanently failed fetch does fall
                      // through to that honest single bucket.
                      const SkeletonBox(height: 180)
                    else if (data.main.isEmpty && data.fx.isEmpty)
                      _empty(context, l)
                    else ...[
                      if (!data.main.isEmpty)
                        _diagram(
                          context: context,
                          l: l,
                          diagram: data.main,
                          diagramId: 'main',
                          width: c.maxWidth,
                          isPhone: isPhone,
                          semanticsLabel: (flows) => l.cfsSemantics(
                            // gen-l10n orders these alphabetically → (flows, total)
                            flows,
                            widget.currencyFormat.format(data.main.total),
                          ),
                        ),
                      if (!data.fx.isEmpty) ...[
                        SizedBox(height: isPhone ? 14 : 18),
                        Divider(height: 1, color: context.hairline),
                        SizedBox(height: isPhone ? 12 : 16),
                        Text(
                          l.cfsFxTitle,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: context.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          l.cfsFxCaption(data.fxTransferCount),
                          style: TextStyle(
                            fontSize: 11,
                            color: context.textSubtle,
                          ),
                        ),
                        const SizedBox(height: 8),
                        _diagram(
                          context: context,
                          l: l,
                          diagram: data.fx,
                          diagramId: 'fx',
                          width: c.maxWidth,
                          isPhone: isPhone,
                          semanticsLabel: l.cfsFxSemantics,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          // The two legs are quoted with their OWN ISO codes and
                          // never added together.
                          l.cfsFxLegs(
                            // gen-l10n orders these alphabetically → (from, to)
                            _nativeLegs(data.fxSent),
                            _nativeLegs(data.fxReceived),
                          ),
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: context.textMuted,
                            fontFeatures: const [
                              ui.FontFeature.tabularFigures(),
                            ],
                          ),
                        ),
                      ],
                    ],
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  CashFlowSankeyLabels _labels(AppLocalizations l) => CashFlowSankeyLabels(
    income: l.cfsNodeIncome,
    otherIncome: l.cfsNodeOtherIncome,
    moneyIn: l.cfsNodeMoneyIn,
    saved: l.cfsNodeSaved,
    invested: l.cfsNodeInvested,
    fromSavings: l.cfsNodeFromSavings,
    fromInvestments: l.cfsNodeFromInvestments,
    uncategorized: l.cfsNodeUncategorized,
    fxConversion: l.cfsFxNode,
  );

  /// "USD 3,000.00 + MXN 1,200.00" — one entry per currency, each formatted
  /// with its own ISO code. Deliberately not a sum.
  String _nativeLegs(Map<String, double> byCurrency) {
    final entries = byCurrency.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return [
      for (final e in entries) formatCurrencyWithCode(e.value, e.key),
    ].join(' + ');
  }

  Widget _header(BuildContext context, AppLocalizations l, bool isPhone) {
    final subtitle = widget.periodLabel == null
        ? l.cfsSubtitle
        : '${widget.periodLabel} · ${l.cfsSubtitle}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            if (!isPhone) ...[
              Icon(Icons.account_tree_outlined, size: 18, color: context.info),
              const SizedBox(width: 8),
            ],
            Expanded(
              child: Text(
                isPhone ? l.cfsTitle.toUpperCase() : l.cfsTitle,
                style: isPhone
                    ? TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: context.textSubtle,
                      )
                    : TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary,
                      ),
                maxLines: isPhone ? 1 : 2,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          subtitle,
          style: TextStyle(fontSize: 12, color: context.textSubtle),
        ),
        const SizedBox(height: 2),
        // The stated unit. Every band width on this card means the same thing
        // because of it.
        Text(
          l.cfsUnitNote(widget.targetCurrency),
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: context.textFaint,
          ),
        ),
      ],
    );
  }

  /// Fixed-height strip directly under the header. Empty state is the tap
  /// hint, so the layout never jumps when a reading arrives.
  Widget _readoutBar(BuildContext context, AppLocalizations l, bool isPhone) {
    return SizedBox(
      key: const Key('cfsReadout'),
      height: 40,
      child: ValueListenableBuilder<_Reading?>(
        valueListenable: _reading,
        builder: (context, reading, _) {
          if (reading == null) {
            return Align(
              alignment: Alignment.centerLeft,
              child: Text(
                l.cfsHint,
                style: TextStyle(fontSize: 12, color: context.textFaint),
              ),
            );
          }
          return Align(
            alignment: Alignment.centerLeft,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${reading.source}  →  ${reading.target}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  '${widget.currencyFormat.format(reading.amount)}'
                  ' · ${formatPercent(context, reading.share, digits: 1)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: context.textMuted,
                    fontFeatures: const [ui.FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _empty(BuildContext context, AppLocalizations l) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 24),
    child: Center(
      child: Text(
        l.cfsEmpty,
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 12, color: context.textMuted),
      ),
    ),
  );

  Widget _diagram({
    required BuildContext context,
    required AppLocalizations l,
    required SankeyDiagram diagram,
    required String diagramId,
    required double width,
    required bool isPhone,
    required String Function(String flows) semanticsLabel,
  }) {
    // Gutters carry the node labels; the bands live between them. Painted
    // text is clipped to its gutter with an ellipsis, so a long merchant name
    // can never overflow the card.
    final gutter = isPhone ? 76.0 : 118.0;
    final nodeWidth = isPhone ? 7.0 : 10.0;
    final nodeGap = isPhone ? 8.0 : 12.0;
    final rows = _busiestColumn(diagram);
    final rowHeight = isPhone ? 34.0 : 40.0;
    final height = (rows * rowHeight).clamp(140.0, isPhone ? 320.0 : 420.0);
    // Deep enough for the middle column's two-line label block to sit ABOVE
    // its bar. The pool node is full height by construction, so a 14px inset
    // forced that block below the bar and — with no clip on a CustomPaint —
    // out of the canvas, on top of the FX caption underneath it.
    final topInset = isPhone ? 30.0 : 34.0;

    final layout = layoutSankey(
      diagram,
      width: width,
      height: height,
      leftGutter: gutter,
      rightGutter: gutter,
      top: topInset,
      nodeWidth: nodeWidth,
      nodeGap: nodeGap,
    );
    final colors = <String, Color>{
      for (final n in diagram.nodes) n.id: _nodeColor(context, n),
    };

    final flows = <String>[
      for (final band in layout.bands.take(12))
        _flowSentence(context, l, diagram, band),
    ].join(' ');

    final canvas = SizedBox(
      key: Key('cfsCanvas-$diagramId'),
      height: height + topInset * 2,
      width: double.infinity,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (d) => _select(diagram, diagramId, layout, d.localPosition),
        onPanStart: (d) => _select(diagram, diagramId, layout, d.localPosition),
        onPanUpdate: (d) =>
            _select(diagram, diagramId, layout, d.localPosition),
        child: MouseRegion(
          onHover: (e) => _select(diagram, diagramId, layout, e.localPosition),
          onExit: (_) => _reading.value = null,
          child: ValueListenableBuilder<_Reading?>(
            valueListenable: _reading,
            builder: (context, reading, _) => CustomPaint(
              size: Size(width, height + topInset * 2),
              painter: SankeyPainter(
                layout: layout,
                diagram: diagram,
                colors: colors,
                selected: reading?.diagramId == diagramId
                    ? reading?.bandIndex
                    : null,
                labelColor: context.textPrimary,
                valueColor: context.textFaint,
                gutter: gutter,
                isPhone: isPhone,
                currency: widget.targetCurrency,
              ),
            ),
          ),
        ),
      ),
    );

    // A painted canvas is invisible to a screen reader: mirror the flows in
    // and exclude the paint.
    return Semantics(
      container: true,
      label: semanticsLabel(flows),
      child: ExcludeSemantics(child: canvas),
    );
  }

  String _flowSentence(
    BuildContext context,
    AppLocalizations l,
    SankeyDiagram diagram,
    SankeyBand band,
  ) {
    final source = diagram.nodeById(band.link.source)?.label ?? '';
    final target = diagram.nodeById(band.link.target)?.label ?? '';
    final share = diagram.total > 0
        ? band.link.value / diagram.total * 100
        : 0.0;
    return l.cfsFlowSemantics(
      // gen-l10n orders these alphabetically → (amount, share, source, target)
      widget.currencyFormat.format(band.link.value),
      formatPercent(context, share, digits: 1),
      source,
      target,
    );
  }

  void _select(
    SankeyDiagram diagram,
    String diagramId,
    SankeyLayout layout,
    Offset point,
  ) {
    final band = sankeyBandAt(layout, point);
    if (band == null) {
      if (_reading.value != null) _reading.value = null;
      return;
    }
    final index = layout.bands.indexOf(band);
    final current = _reading.value;
    if (current != null &&
        current.diagramId == diagramId &&
        current.bandIndex == index) {
      return;
    }
    _reading.value = _Reading(
      diagramId: diagramId,
      bandIndex: index,
      source: diagram.nodeById(band.link.source)?.label ?? '',
      target: diagram.nodeById(band.link.target)?.label ?? '',
      amount: band.link.value,
      share: diagram.total > 0 ? band.link.value / diagram.total * 100 : 0.0,
    );
  }

  int _busiestColumn(SankeyDiagram diagram) {
    final counts = <int, int>{};
    for (final n in diagram.nodes) {
      counts[n.depth] = (counts[n.depth] ?? 0) + 1;
    }
    return counts.values.fold<int>(1, (m, v) => v > m ? v : m);
  }

  Color _nodeColor(BuildContext context, SankeyNode node) {
    switch (node.kind) {
      case SankeyNodeKind.hub:
        return context.neutralAccent;
      case SankeyNodeKind.saved:
        return context.positive;
      case SankeyNodeKind.invested:
        return context.info;
      case SankeyNodeKind.drawdown:
        return context.warning;
      case SankeyNodeKind.fxEndpoint:
        return context.tealAccent;
      case SankeyNodeKind.fxConversion:
        return context.purpleAccent;
      case SankeyNodeKind.incomeSource:
      case SankeyNodeKind.category:
        return context.chartSeries(node.seriesIndex ?? 0);
    }
  }
}

@immutable
class _Reading {
  const _Reading({
    required this.diagramId,
    required this.bandIndex,
    required this.source,
    required this.target,
    required this.amount,
    required this.share,
  });
  final String diagramId;
  final int bandIndex;
  final String source;
  final String target;
  final double amount;

  /// Percentage NUMBER (24.0 == 24%), ready for `formatPercent`.
  final double share;
}

/// The two styles a painted node label is drawn with. [sankeyLabelMetrics]
/// measures through these same functions, so what the geometry pass sizes and
/// what the painter draws can never drift apart.
TextStyle _sankeyNameStyle(bool isPhone, {Color? color}) => TextStyle(
  fontSize: isPhone ? 10 : 11.5,
  fontWeight: FontWeight.w600,
  color: color,
  height: 1.15,
);

TextStyle _sankeyValueStyle(bool isPhone, {Color? color}) => TextStyle(
  fontSize: isPhone ? 9 : 10.5,
  fontWeight: FontWeight.w500,
  color: color,
  height: 1.15,
  fontFeatures: const [ui.FontFeature.tabularFigures()],
);

double _measure(String text, TextStyle style) {
  final tp = TextPainter(
    text: TextSpan(text: text, style: style),
    maxLines: 1,
    // `ui.` qualified: package:intl also exports a `TextDirection`.
    textDirection: ui.TextDirection.ltr,
  )..layout();
  return tp.width;
}

double _lineHeight(TextStyle style) {
  final tp = TextPainter(
    text: TextSpan(text: 'Xg', style: style),
    maxLines: 1,
    textDirection: ui.TextDirection.ltr,
  )..layout();
  return tp.height;
}

/// Real-font measurement for the painted node labels, handed to the pure
/// [layoutSankeyLabels] geometry. Colors are deliberately absent — they don't
/// affect metrics, and this keeps the measuring styles context-free.
SankeyLabelMetrics sankeyLabelMetrics({required bool isPhone}) {
  final name = _sankeyNameStyle(isPhone);
  final value = _sankeyValueStyle(isPhone);
  return SankeyLabelMetrics(
    measureName: (t) => _measure(t, name),
    measureValue: (t) => _measure(t, value),
    nameHeight: _lineHeight(name),
    valueHeight: _lineHeight(value),
  );
}

/// Paints one Sankey diagram.
///
/// Label placement is delegated to [layoutSankeyLabels] — a pure function this
/// class also exposes via [labelPlacements] so tests can assert the real,
/// as-drawn geometry (above all: that no two label blocks overlap).
@visibleForTesting
class SankeyPainter extends CustomPainter {
  SankeyPainter({
    required this.layout,
    required this.diagram,
    required this.colors,
    required this.selected,
    required this.labelColor,
    required this.valueColor,
    required this.gutter,
    required this.isPhone,
    required this.currency,
  });

  final SankeyLayout layout;
  final SankeyDiagram diagram;
  final Map<String, Color> colors;
  final int? selected;
  final Color labelColor;
  final Color valueColor;
  final double gutter;
  final bool isPhone;
  final String currency;

  /// Final strings + non-overlapping rects for every label this painter will
  /// draw at [size].
  List<SankeyLabelPlacement> labelPlacements(Size size) => layoutSankeyLabels(
    diagram: diagram,
    layout: layout,
    canvas: size,
    gutter: gutter,
    currency: currency,
    metrics: sankeyLabelMetrics(isPhone: isPhone),
  );

  @override
  void paint(Canvas canvas, Size size) {
    if (layout.isEmpty) return;
    // A CustomPaint does NOT clip its child painter. Without this, anything
    // the label pass places near an edge escapes the canvas box and draws over
    // the widgets below (this is how the FX value label ended up on top of the
    // "USD … became MXN …" caption). The layout pass keeps every block inside
    // `size` anyway; the clip is the structural guarantee behind it.
    canvas.clipRect(Offset.zero & size);

    for (var i = 0; i < layout.bands.length; i++) {
      final band = layout.bands[i];
      final path = sankeyBandPath(band);
      final from = colors[band.link.source] ?? labelColor;
      final to = colors[band.link.target] ?? labelColor;
      // Dim the field when something is selected so the picked ribbon reads
      // instantly; full opacity for everything when nothing is picked.
      final alpha = selected == null ? 0.42 : (selected == i ? 0.85 : 0.12);
      final bounds = path.getBounds();
      final paint = Paint()
        ..style = PaintingStyle.fill
        ..shader = LinearGradient(
          colors: [
            from.withValues(alpha: alpha),
            to.withValues(alpha: alpha),
          ],
        ).createShader(bounds);
      canvas.drawPath(path, paint);
    }

    for (final node in diagram.nodes) {
      final rect = layout.nodeRects[node.id];
      if (rect == null) continue;
      final color = colors[node.id] ?? labelColor;
      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        Paint()..color = color,
      );
    }

    // Labels last, and as ONE resolved pass over all columns: node rects are
    // value-sized, so centring each block on its own rect overprints the small
    // nodes into mush.
    for (final placement in labelPlacements(size)) {
      _paintPlacement(canvas, placement);
    }
  }

  void _paintPlacement(Canvas canvas, SankeyLabelPlacement placement) {
    final width = placement.rect.width;
    final name = _painter(
      placement.name,
      _sankeyNameStyle(isPhone, color: labelColor),
      width,
      placement.align,
    );
    final amount = _painter(
      placement.value,
      _sankeyValueStyle(isPhone, color: valueColor),
      width,
      placement.align,
    );
    name.paint(canvas, placement.rect.topLeft);
    amount.paint(
      canvas,
      Offset(
        placement.rect.left,
        placement.rect.top + name.height + kSankeyLabelLineGap,
      ),
    );
  }

  TextPainter _painter(
    String text,
    TextStyle style,
    double maxWidth,
    TextAlign align,
  ) {
    final tp = TextPainter(
      text: TextSpan(text: text, style: style),
      maxLines: 1,
      ellipsis: '…',
      textAlign: align,
      // `ui.` qualified: package:intl also exports a `TextDirection`.
      textDirection: ui.TextDirection.ltr,
    )..layout(minWidth: maxWidth, maxWidth: maxWidth);
    return tp;
  }

  @override
  bool shouldRepaint(SankeyPainter old) =>
      old.selected != selected ||
      !identical(old.layout, layout) ||
      old.labelColor != labelColor ||
      old.currency != currency ||
      old.gutter != gutter ||
      old.isPhone != isPhone;
}
