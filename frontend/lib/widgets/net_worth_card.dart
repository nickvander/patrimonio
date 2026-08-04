import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../components/date_range_selector.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/preferences.dart';
import '../theme/typography.dart';
import '../utils/chart_time_axis.dart';
import '../utils/chart_touch.dart';
import '../utils/currency.dart';
import '../utils/net_worth_delta.dart';
import '../utils/percent_format.dart';
import '../utils/theme_colors.dart';

class NetWorthCard extends StatefulWidget {
  final double netWorth;
  final List<dynamic> history;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final String reportingCurrency;
  final List<dynamic> sourceBreakdown;

  /// USD↔MXN rate, so a native-currency chip can show its reporting-currency
  /// worth ("MXN 56,344.00 ≈ $3,238") — `conversionFactor` only covers
  /// USD→reporting, not the cross needed for a foreign native amount.
  final double usdMxnRate;
  final DateRange selectedRange;

  /// When false the full summary header (hero number, delta chips, currency
  /// pills) is replaced by a compact overline title — used on phones, where
  /// the dashboard hero block directly above already shows the same figures.
  final bool showSummary;

  /// Optional range selector rendered inside the card, below the chart, so
  /// range switching is thumb-reachable and visually bound to the plot it
  /// controls (phone layout). Null on wide layouts, where the selector lives
  /// in the floating header above the card.
  final Widget? rangeSelector;

  /// Injection seam for the attribution fetch (widget tests fake it with
  /// `extends ApiService` + `@override`). Null → a real [ApiService], so the
  /// dashboard call site needs no change.
  final ApiService? apiService;

  const NetWorthCard({
    super.key,
    required this.netWorth,
    required this.history,
    required this.conversionFactor,
    required this.currencyFormat,
    required this.reportingCurrency,
    required this.sourceBreakdown,
    required this.usdMxnRate,
    this.selectedRange = DateRange.all,
    this.showSummary = true,
    this.rangeSelector,
    this.apiService,
  });

  @override
  State<NetWorthCard> createState() => _NetWorthCardState();
}

/// One frame of a touch scrub on this card's chart, already formatted: the
/// scrubbed [date] and the plotted value at that point (in whatever currency
/// the plotted series is denominated in — the chart formats it, the header
/// only displays it). A record, so equality is structural.
typedef _ScrubReading = ({DateTime date, String value});

class _NetWorthCardState extends State<NetWorthCard> {
  // The default view is the single green-line "simple" mode — the stacked
  // institution bands compete with the total line and get visually mushy
  // past ~5 institutions. The toggle is persisted so power users who
  // prefer the detailed view don't have to flip it every refresh.
  late bool _detailed = Preferences.getNetWorthDetailed();

  // The "since <baseline>: what drove the change" movers section sits under
  // the delta chips and is collapsed by default — it's attribution detail the
  // hero → delta reading order shouldn't be forced through.
  bool _moversExpanded = false;

  /// Attribution fetch seam — the injected fake in tests, a real service in
  /// the app (the dashboard call site passes nothing).
  late final ApiService _api = widget.apiService ?? ApiService();

  /// "Ignore FX moves": when true the chart plots the attribution endpoint's
  /// constant-FX series (every balance revalued at the window-start rate)
  /// instead of the live-FX history. OFF by default, where the existing chart
  /// path (institution bands and all) renders unchanged.
  ///
  /// This is deliberately a BOOLEAN, not a currency picker. Which currency the
  /// card reports in is the global reporting-currency switcher's job (app
  /// bar); a second USD/MXN control here duplicated it and could be set to
  /// contradict the hero number above the chart. Only the constant-FX read is
  /// something the global switcher can't express, so only it survives.
  bool _ignoreFx = false;

  /// `/dashboard/net-worth-attribution` response for the current window
  /// (`flows/market/fx/residual` totals + the window series), or null while
  /// loading / when there's no history to attribute.
  Map<String, dynamic>? _attribution;
  bool _attributionError = false;

  /// The `from|to` window key of the in-flight / loaded attribution, so
  /// rebuilds and no-op didUpdateWidget calls don't refetch, and a stale
  /// response can't clobber a newer window's data.
  String? _attributionKey;

  /// The loaded window series, or null when there's nothing plottable. The
  /// toggle only exists when this does — a control that can't change the
  /// chart is worse than no control.
  List<dynamic>? get _constantFxSeries {
    final series = _attribution?['series'] as List<dynamic>?;
    if (series == null || series.isEmpty) return null;
    return series;
  }

  /// The live touch-scrub reading, or null when no finger is on the chart.
  ///
  /// On touch the chart draws no tooltip (see [_renderLineChart]) and the
  /// reading surfaces in the header instead. A ValueNotifier rather than
  /// setState because a scrub fires on every pointer move and only the header
  /// depends on it — a full card rebuild would re-run the stacked-series and
  /// axis math each frame of the drag. Disposed in [dispose].
  final ValueNotifier<_ScrubReading?> _scrub = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    _loadAttribution();
  }

  @override
  void dispose() {
    _scrub.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(NetWorthCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Range switch or fresh history → the attribution window moved, and any
    // scrub reading belongs to a series that is being replaced.
    _scrub.value = null;
    _loadAttribution();
  }

  /// The attribution window for the currently selected range, as ISO dates:
  /// `to` = the latest snapshot, `from` = the range cutoff (mirroring
  /// `_filterByRange`'s now-anchored cutoffs so the numbers explain the
  /// plotted window), clamped so `from <= to`. Null when there's no history.
  ({String from, String to})? _attributionWindow() {
    final latest = _latestSnapshotDate(history);
    if (latest == null) return null;
    final now = DateTime.now();
    DateTime from;
    switch (selectedRange) {
      case DateRange.oneMonth:
        from = now.subtract(const Duration(days: 30));
        break;
      case DateRange.yearToDate:
        from = DateTime(now.year, 1, 1);
        break;
      case DateRange.oneYear:
        from = now.subtract(const Duration(days: 365));
        break;
      case DateRange.fiveYears:
        from = now.subtract(const Duration(days: 365 * 5));
        break;
      case DateRange.all:
        final first = history.isEmpty
            ? null
            : DateTime.tryParse(history.first['date']?.toString() ?? '');
        from = first ?? latest;
        break;
    }
    if (from.isAfter(latest)) from = latest;
    final df = DateFormat('yyyy-MM-dd');
    return (from: df.format(from), to: df.format(latest));
  }

  Future<void> _loadAttribution() async {
    final win = _attributionWindow();
    if (win == null) return;
    final key = '${win.from}|${win.to}';
    if (key == _attributionKey && !_attributionError) return;
    _attributionKey = key;
    try {
      final data = await _api.getNetWorthAttribution(
        from: win.from,
        to: win.to,
      );
      if (!mounted || _attributionKey != key) return;
      setState(() {
        _attribution = data;
        _attributionError = false;
      });
    } catch (_) {
      if (!mounted || _attributionKey != key) return;
      setState(() {
        _attribution = null;
        _attributionError = true;
        // No series left to plot, so the toggle disappears — don't leave it
        // latched ON with the chart silently back on live FX.
        _ignoreFx = false;
      });
    }
  }

  // The widget body below used to live on the StatelessWidget. To avoid
  // touching every `xxx` → `widget.xxx` access, expose passthroughs.
  double get netWorth => widget.netWorth;
  List<dynamic> get history => widget.history;
  double get conversionFactor => widget.conversionFactor;
  NumberFormat get currencyFormat => widget.currencyFormat;
  String get reportingCurrency => widget.reportingCurrency;
  List<dynamic> get sourceBreakdown => widget.sourceBreakdown;
  double get usdMxnRate => widget.usdMxnRate;
  DateRange get selectedRange => widget.selectedRange;

  /// Native-currency composition, parsed from `sourceBreakdown` and ordered by
  /// reporting-currency value (dominant currency first) — the order the hero
  /// chips render in, so the chart card reads identically to the dashboard.
  List<({String cur, double net})> get _breakdownEntries {
    final entries =
        sourceBreakdown
            .map(
              (item) => (
                cur: (item['currency'] ?? '').toString().toUpperCase(),
                net: ((item['net'] ?? 0.0) as num).toDouble(),
              ),
            )
            .where((e) => e.cur.isNotEmpty)
            .toList()
          ..sort((a, b) {
            final ca = convertCurrency(
              a.net,
              from: a.cur,
              to: reportingCurrency,
              usdMxnRate: usdMxnRate,
            );
            final cb = convertCurrency(
              b.net,
              from: b.cur,
              to: reportingCurrency,
              usdMxnRate: usdMxnRate,
            );
            return cb.compareTo(ca);
          });
    return entries;
  }

  /// Filter history data based on the selected date range
  List<dynamic> _filterByRange(List<dynamic> data) {
    if (data.isEmpty || selectedRange == DateRange.all) return data;

    final now = DateTime.now();
    DateTime cutoff;

    switch (selectedRange) {
      case DateRange.oneMonth:
        cutoff = now.subtract(const Duration(days: 30));
        break;
      case DateRange.yearToDate:
        cutoff = DateTime(now.year, 1, 1);
        break;
      case DateRange.oneYear:
        cutoff = now.subtract(const Duration(days: 365));
        break;
      case DateRange.fiveYears:
        cutoff = now.subtract(const Duration(days: 365 * 5));
        break;
      case DateRange.all:
        return data;
    }

    return data.where((point) {
      final dateStr = point['date']?.toString() ?? '';
      if (dateStr.length < 10) return true;
      final date = DateTime.tryParse(dateStr);
      if (date == null) return true;
      return date.isAfter(cutoff) || date.isAtSameMomentAs(cutoff);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    // House card chrome: radius 20 everywhere, 16px interior on phones
    // (matches accounts_list_widget), 24px on wide screens.
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
            child: LayoutBuilder(
              builder: (context, constraints) {
                final isCompact = constraints.maxWidth < 640;
                // The chart's height is guaranteed, not "whatever the header
                // leaves over": on phones the compact header stacks (hero,
                // delta chips, currency chips, toggle + legend) to 300px+, and
                // an Expanded chart inside a fixed-height card collapsed to a
                // sliver with overlapping y labels. Width-derived, clamped so
                // the plot area stays readable from 320px phones to desktop.
                final chartHeight = (constraints.maxWidth * 0.5).clamp(
                  220.0,
                  280.0,
                );
                final filtered = _filterByRange(history);
                // Only compute the per-institution slices when the detailed
                // view is actually being shown — saves a meaningful chunk of
                // work on the simple path.
                final institutions = _detailed
                    ? _topInstitutions(context, filtered, max: 4)
                    : const <MapEntry<String, Color>>[];
                // "Ignore FX moves" ON: swap the plot for the attribution
                // endpoint's constant-FX series (single line, day-offset x).
                // OFF — and while the series hasn't loaded (or errored) — the
                // default chart path renders exactly as it always has.
                final fxSeries = _constantFxSeries;
                final constantFxPlot = _ignoreFx ? fxSeries : null;
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildHeader(isCompact, institutions),
                    const SizedBox(height: 24),
                    SizedBox(
                      height: chartHeight,
                      // Chart repaints (tooltip scrubbing, touch guides) stay
                      // inside this boundary instead of invalidating the whole
                      // card/scroll layer — noticeably less raster work on
                      // Android while scrubbing.
                      child: RepaintBoundary(
                        child: constantFxPlot != null
                            ? _renderConstantFxChart(
                                constantFxPlot,
                                constraints.maxWidth,
                              )
                            : _buildChart(
                                filtered,
                                institutions,
                                constraints.maxWidth,
                              ),
                      ),
                    ),
                    if (fxSeries != null) ...[
                      const SizedBox(height: 12),
                      _buildIgnoreFxToggle(),
                      if (_ignoreFx) _buildConstantFxCaption(),
                    ],
                    _buildAttributionSection(),
                    // Phone layout: the range selector lives inside the card,
                    // right under the plot it controls (thumb-reachable).
                    if (widget.rangeSelector != null) ...[
                      const SizedBox(height: 12),
                      widget.rangeSelector!,
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

  /// The card's one chart control: "Ignore FX moves" — plot the same history
  /// with every balance held at the window-start rate.
  ///
  /// A single FilterChip, not a segmented control: this is a boolean, and a
  /// two-state control drawn as a segmented group invites a third segment.
  /// The label states the EFFECT, not the mechanism ("constant FX" named an
  /// implementation nobody outside this file uses).
  Widget _buildIgnoreFxToggle() {
    final l = AppLocalizations.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: FilterChip(
        label: Text(l.nwIgnoreFxMoves),
        selected: _ignoreFx,
        onSelected: (v) {
          // The two states plot different series (and, when reporting in MXN,
          // different currencies) — drop any scrub reading with the series it
          // was read off.
          _scrub.value = null;
          setState(() => _ignoreFx = v);
        },
        visualDensity: VisualDensity.compact,
      ),
    );
  }

  /// "MXN revalued at the window-start rate (N MXN/USD)" — the honesty
  /// caption shown while the FX-moves toggle is ON, so the flat peso never
  /// reads as a live conversion. Hidden until the attribution response
  /// supplies r0.
  Widget _buildConstantFxCaption() {
    final rate = (_attribution?['fx_rate_open'] as num?)?.toDouble();
    if (rate == null) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Text(
        // A rate is a plain number, not money — localize the decimal
        // separator only.
        l.nwLensConstantCaption(
          localizeNumberString(context, rate.toStringAsFixed(2)),
        ),
        style: TextStyle(fontSize: 11, color: context.textFaint),
      ),
    );
  }

  /// "Why it changed" — the FX / Market / Flows decomposition of the selected
  /// window's net-worth delta, from `/dashboard/net-worth-attribution`. The
  /// residual folds into an "Other" chip ONLY when nonzero: the backend
  /// guarantees fx + market + flows + residual == delta exactly, so a zero
  /// residual is the common case and hiding it keeps the row honest without
  /// clutter. Values arrive in USD and are scaled to the reporting currency
  /// with the same conversionFactor as everything else on the card.
  Widget _buildAttributionSection() {
    final l = AppLocalizations.of(context);
    if (_attributionError) {
      return Padding(
        padding: const EdgeInsets.only(top: 10),
        child: Text(
          l.nwAttrError,
          style: TextStyle(fontSize: 11, color: context.textFaint),
        ),
      );
    }
    final a = _attribution;
    if (a == null) return const SizedBox.shrink();
    double comp(String key) => ((a[key] ?? 0) as num).toDouble();
    final fx = comp('fx_usd');
    final market = comp('market_usd');
    final flows = comp('flows_usd');
    final residual = comp('residual_usd');
    // Nothing moved (or an empty window): no decomposition to show.
    if (fx == 0 && market == 0 && flows == 0 && residual == 0) {
      return const SizedBox.shrink();
    }
    final items = <({String label, double value})>[
      (label: l.nwAttrFx, value: fx),
      (label: l.nwAttrMarket, value: market),
      (label: l.nwAttrFlows, value: flows),
      if (residual != 0) (label: l.nwAttrOther, value: residual),
    ];
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Semantics(
        container: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.nwAttrTitle.toUpperCase(),
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.6,
                color: context.textSubtle,
              ),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [for (final item in items) _attrChip(item)],
            ),
          ],
        ),
      ),
    );
  }

  /// One attribution component chip: `label +$X` / `label −$X`, hue by sign
  /// (muted for an exactly-zero component, e.g. Market in a pure-flows
  /// month). Mirrors the mover-chip styling one section up.
  Widget _attrChip(({String label, double value}) item) {
    final zero = item.value == 0;
    final up = item.value >= 0;
    final color = zero
        ? context.textMuted
        : (up ? context.positive : context.negative);
    final amount = item.value.abs() * conversionFactor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: zero ? context.tint(0.05) : color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            item.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: context.textSubtle,
            ),
          ),
          const SizedBox(width: 4),
          Text(
            zero
                ? currencyFormat.displayMoney(0)
                : '${up ? '+' : '−'}${currencyFormat.displayMoney(amount)}',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  /// Single-line chart for "ignore FX moves", fed by the attribution
  /// endpoint's `constant_fx_usd` series. Day-offset x (a data gap occupies
  /// its real width — never index-as-x) and the shared `standardLineTouch`
  /// hover; deliberately NOT another inline LineTouchData fork.
  ///
  /// **Every figure here is USD, whatever the reporting currency is.** The
  /// endpoint has no constant-FX series in MXN, so rather than hide the one
  /// genuinely unique read from the users most exposed to peso swings, the
  /// plot labels itself: axis ticks, tooltip, scrub readout and the semantics
  /// summary all carry the ISO code ("USD 1.9K" / "USD 1,970.00") instead of
  /// the reporting-currency format used everywhere else on the card. A bare
  /// "$" is the peso glyph too, so an unlabelled axis would read as pesos.
  Widget _renderConstantFxChart(List<dynamic> series, double chartWidth) {
    final points = dedupeDailyCloses([
      for (final p in series)
        if (p is Map && DateTime.tryParse(p['date']?.toString() ?? '') != null)
          (
            date: DateTime.parse(p['date'].toString()),
            close: ((p['constant_fx_usd'] ?? 0) as num).toDouble(),
          ),
    ]);
    if (points.isEmpty) return const SizedBox.shrink();
    final spots = dayOffsetSpots(points);
    final values = [for (final s in spots) s.y];
    var minY = values.reduce(math.min);
    var maxY = values.reduce(math.max);
    // Fit the axis to the data with padding, like the simple-mode bounds —
    // a short window shouldn't flat-line against a $0 floor.
    var pad = (maxY - minY) * 0.15;
    if (pad <= 0) pad = maxY.abs() * 0.15 + 1000;
    minY -= pad;
    maxY += pad;
    if (minY < 0 && values.every((v) => v >= 0)) minY = 0;
    final spanDays = spots.isEmpty ? 0 : spots.last.x.toInt();
    // Same tick recipe as the default-lens chart (`_dayTickInterval` /
    // `_bottomTickOffsets`), so all three lenses label the same day offsets at
    // the same density — not just plot on the same day-offset x.
    final tickInterval = _dayTickInterval(spanDays, chartWidth);
    final tickDates = [
      for (final x in _bottomTickOffsets(spanDays, tickInterval, chartWidth))
        points.first.date.add(Duration(days: x.round())),
    ];

    final labelFormat = nonRepeatingDateFormat(tickDates, spanDays: spanDays);
    DateTime dateFor(double x) =>
        points.first.date.add(Duration(days: x.toInt()));

    // On touch this chart draws no tooltip — the reading goes to the card
    // header (see `_scrubbable`), clear of the hand; the guide + dot stay.
    final chart = TransientTooltipLineChart(
      suppressTooltipOnTouch: true,
      onScrub: _scrubHandler(
        (spot) => (
          date: dateFor(spot.x),
          // Code-prefixed, like the axis: this series is USD even when the
          // card reports in MXN.
          value: displayCurrencyWithCode(spot.y, 'USD'),
        ),
      ),
      data: LineChartData(
        minY: minY,
        maxY: maxY,
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (value) =>
              FlLine(color: context.hairline, strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: tickInterval,
              getTitlesWidget: (value, meta) {
                // fl_chart always emits both endpoints, so the latest point
                // is always labelled; drop the earlier neighbour that would
                // collide with it.
                if (_suppressTick(value, spanDays, chartWidth)) {
                  return const SizedBox.shrink();
                }
                return SideTitleWidget(
                  meta: meta,
                  child: Text(
                    labelFormat.format(dateFor(value)),
                    style: TextStyle(color: context.textSubtle, fontSize: 10),
                  ),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              getTitlesWidget: (value, meta) {
                if (value <= meta.min || value >= meta.max) {
                  return const SizedBox.shrink();
                }
                return Text(
                  _constantFxTick(value),
                  style: TextStyle(color: context.textSubtle, fontSize: 10),
                );
              },
              reservedSize: _constantFxAxisWidth(minY, maxY),
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: true,
            preventCurveOverShooting: true,
            gradient: LinearGradient(
              colors: [
                context.positive,
                context.positive.withValues(alpha: 0.55),
              ],
            ),
            barWidth: 3.5,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
          ),
        ],
        lineTouchData: standardLineTouch(
          context,
          items: (context, touchedSpots) {
            return touchedSpots.map((spot) {
              return LineTooltipItem(
                '${DateFormat('MMM d, y').format(dateFor(spot.x))}\n'
                '${displayCurrencyWithCode(spot.y, 'USD')}',
                TextStyle(
                  color: context.tooltipOnSurface,
                  fontWeight: FontWeight.bold,
                ),
              );
            }).toList();
          },
        ),
      ),
    );

    // Pointer-only canvas: mirror the latest constant-FX read into the
    // semantics tree, code-prefixed like everything else on this plot.
    return Semantics(
      container: true,
      label:
          '${AppLocalizations.of(context).nwIgnoreFxMoves}: '
          '${displayCurrencyWithCode(points.last.close, 'USD')}',
      child: ExcludeSemantics(child: chart),
    );
  }

  /// One compact y tick for the constant-FX plot: the house [compactMoney]
  /// magnitude with the "$" glyph swapped for the ISO code, so the axis reads
  /// "USD 1.9K". `compactMoney` is still the single source of the locale,
  /// grouping and no-break-space rules — only the glyph changes, because this
  /// axis is USD while the rest of the card may be in pesos.
  /// (The separator is a no-break space, `\u00A0`, matching `compactMoney`'s
  /// own rule: a tick must never wrap inside fl_chart's fixed `reservedSize`.)
  static String _constantFxTick(num value) =>
      compactMoney(value, 'USD').replaceFirst(r'$', 'USD\u00A0');

  /// fl_chart `reservedSize` for that axis. [compactMoneyAxisWidth] measures
  /// the "$" glyph form, so add what swapping it for "USD " costs — otherwise
  /// the widest tick clips ("USD 2." for "USD 2.61K" is a 10x misread).
  static double _constantFxAxisWidth(double minY, double maxY) =>
      compactMoneyAxisWidth(minY, maxY, 'USD') +
      axisTickTextWidth('USD\u00A0') -
      axisTickTextWidth(r'$');

  Widget _buildModeToggle() {
    // Segmented "Simple / Detailed" pill. We keep it small so it sits next
    // to the legend without dominating the header.
    Widget seg(String label, bool active, VoidCallback onTap) {
      // InkWell makes the segment focusable + Enter/Space-activatable;
      // Semantics(button + selected) lets a screen reader announce both
      // the role and which segment is currently active.
      return Semantics(
        button: true,
        selected: active,
        label: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(20),
          // Vertical padding extends the TAP target toward the 48dp floor
          // without growing the visual pill.
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: active
                    ? context.accentSoft(context.positive)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: active ? context.positive : context.textMuted,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          ),
        ),
      );
    }

    final l = AppLocalizations.of(context);
    return Tooltip(
      message: _detailed ? l.pfShowingBands : l.pfShowingLine,
      child: Container(
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: context.tint(0.04),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: context.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            seg(l.pfSimple, !_detailed, () {
              if (_detailed) {
                setState(() => _detailed = false);
                Preferences.setNetWorthDetailed(false);
              }
            }),
            seg(l.pfDetailed, _detailed, () {
              if (!_detailed) {
                setState(() => _detailed = true);
                Preferences.setNetWorthDetailed(true);
              }
            }),
          ],
        ),
      ),
    );
  }

  /// Renders [live] normally, and [scrubbed] while a touch scrub is active.
  ///
  /// The scrubbed branch also announces itself: it replaces an in-chart
  /// tooltip that was invisible to screen readers, so the reading is wrapped
  /// in a live region (with the visual text excluded, or it'd be read twice).
  Widget _scrubbable({
    required Widget live,
    required Widget Function(_ScrubReading scrub) scrubbed,
  }) {
    return ValueListenableBuilder<_ScrubReading?>(
      valueListenable: _scrub,
      builder: (context, scrub, _) {
        if (scrub == null) return live;
        return Semantics(
          container: true,
          liveRegion: true,
          // gen-l10n orders these alphabetically → (date, values).
          label: AppLocalizations.of(context).lwChartScrubReading(
            DateFormat('MMM d, y').format(scrub.date),
            scrub.value,
          ),
          child: ExcludeSemantics(child: scrubbed(scrub)),
        );
      },
    );
  }

  /// Handler for a chart's `onScrub`: publishes touch readings to the header
  /// and clears on release (and on any mouse/trackpad event — a cursor
  /// doesn't occlude what it points at, so desktop keeps the in-chart
  /// popover and the header stays on the live numbers).
  ///
  /// [read] gets the first touched spot; every bar in these charts shares the
  /// same x samples (the stacked bands are cumulative slices of one date
  /// series), so which bar it lands on doesn't change the scrubbed date.
  /// Returning null from [read] clears the header rather than showing a
  /// half-resolved reading.
  void Function(ChartScrub?) _scrubHandler(
    _ScrubReading? Function(LineBarSpot spot) read,
  ) {
    return (scrub) {
      if (scrub == null || !scrub.isTouch || scrub.spots.isEmpty) {
        _scrub.value = null;
        return;
      }
      _scrub.value = read(scrub.spots.first);
    };
  }

  Widget _buildHeader(
    bool isCompact,
    List<MapEntry<String, Color>> institutions,
  ) {
    // Phone chrome: the dashboard hero block directly above this card
    // already shows the net-worth figure, delta and currency pills, so the
    // in-card summary collapses to a small overline title (the fad9351
    // idiom) with the mode toggle / legend on the same row.
    if (!widget.showSummary) {
      final legend = _buildLegend(institutions);
      // FittedBox: the toggle's segmented Row has a fixed intrinsic width,
      // so on a very narrow card (or a long localized title) it scales down
      // instead of overflowing its share of the header row.
      final modeToggle = FittedBox(
        fit: BoxFit.scaleDown,
        child: _buildModeToggle(),
      );
      final rightSide = _detailed
          ? Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [modeToggle, legend],
            )
          : modeToggle;
      return Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Flexible(
            child: _scrubbable(
              live: Semantics(
                container: true,
                header: true,
                child: Text(
                  AppLocalizations.of(
                    context,
                  ).dashNetWorthHistory.toUpperCase(),
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                    color: context.textSubtle,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              // The phone header has no hero to swap (the dashboard block
              // above owns it), so the overline title itself becomes the
              // readout: "JUL 3 · $1,234,567" in the same slot, same
              // baseline — nothing below the finger, nothing reflows.
              scrubbed: (scrub) => Text.rich(
                TextSpan(
                  children: [
                    TextSpan(
                      text: '${DateFormat('MMM d').format(scrub.date)}  ',
                      style: TextStyle(
                        letterSpacing: 0.6,
                        color: context.textSubtle,
                      ),
                    ),
                    TextSpan(
                      text: scrub.value,
                      style: TextStyle(
                        color: context.textPrimary,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ),
          const SizedBox(width: 12),
          // Flexible so the detailed-mode legend wraps within its share of
          // the row instead of overflowing a 320px card.
          Flexible(child: rightSide),
        ],
      );
    }

    // Label + hero number. While a finger scrubs the chart the SAME pair
    // reports the scrubbed point — the value at that date above, the date
    // itself in place of the "Total net worth (USD)" label — so the reading
    // lands ~250px above the plot instead of under the hand. Reverts the
    // instant the finger lifts.
    Widget heroBlock(String label, String value) => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          // Inter label above the hero number, kept understated — the big
          // mono number is the star.
          style: brandSectionTitleStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: context.textMuted,
          ).copyWith(letterSpacing: 0.3),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 4),
        // FittedBox shrinks the hero number down rather than ellipsing
        // when the card is narrow and the value is long. Avoids the
        // "USD 9,876…" cliff on phones.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            value,
            // JetBrains Mono with tabular lining figures — the signature
            // "ledger" hero number. Tabular figures keep digit columns
            // aligned as the value changes.
            style: brandDisplayStyle(
              fontSize: isCompact ? 32 : 42,
              // Bundled up to Bold; w900 would faux-bold (muddy on a mono).
              fontWeight: FontWeight.w700,
              color: context.textPrimary,
            ),
            maxLines: 1,
          ),
        ),
      ],
    );

    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _scrubbable(
          live: heroBlock(
            AppLocalizations.of(
              context,
            ).pfTotalNetWorthCurrency(reportingCurrency),
            currencyFormat.displayMoney(netWorth),
          ),
          scrubbed: (scrub) =>
              heroBlock(DateFormat('MMM d, y').format(scrub.date), scrub.value),
        ),
        // Trend chip — "↑ +$X (+Y%) vs 30d ago" — gives a one-line read
        // on whether net worth is moving up or down without making the
        // user scrub the chart. Computed from history; hidden when we
        // don't have a comparable point >= 7 days back.
        Builder(
          builder: (context) {
            final deltas = computeMomYoyDeltas(history);
            final chips = <Widget>[
              if (deltas.mom != null)
                _DeltaChip(
                  amount: deltas.mom!.amount * conversionFactor,
                  percentage: deltas.mom!.percentage,
                  label: deltas.mom!.windowLabel,
                  periodTag: deltas.mom!.windowLabel,
                  currencyFormat: currencyFormat,
                ),
              if (deltas.yoy != null)
                _DeltaChip(
                  amount: deltas.yoy!.amount * conversionFactor,
                  percentage: deltas.yoy!.percentage,
                  label: deltas.yoy!.windowLabel,
                  periodTag: deltas.yoy!.windowLabel,
                  currencyFormat: currencyFormat,
                ),
            ];
            // Fall back to the legacy 30d/7d chip when we don't yet have a
            // month of history (keeps the early-onboarding read useful).
            if (chips.isEmpty) {
              final delta = computeNetWorthDelta(history);
              if (delta == null) return const SizedBox.shrink();
              return Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _DeltaChip(
                  amount: delta.amount * conversionFactor,
                  percentage: delta.percentage,
                  label: delta.windowLabel,
                  currencyFormat: currencyFormat,
                ),
              );
            }
            return Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(spacing: 8, runSpacing: 6, children: chips),
            );
          },
        ),
        // "Since <baseline>: <total Δ> · <top institution movers>" — the
        // attribution for the MoM delta above. Reuses the same baseline and
        // guards as the chip; collapsed by default.
        _buildMoversSection(),
        if (_breakdownEntries.length >= 2) ...[
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: _breakdownEntries.map((e) {
              // One self-labelling chip per currency, matching the dashboard
              // hero and the accounts list: the native amount always carries
              // its ISO code ("USD 9,591.00"), and a foreign currency also
              // shows its reporting-currency worth ("MXN 56,344.00 ≈ $3,238"),
              // so the chips visibly add up to the hero number above.
              final isTarget = e.cur == reportingCurrency.toUpperCase();
              final converted = convertCurrency(
                e.net,
                from: e.cur,
                to: reportingCurrency,
                usdMxnRate: usdMxnRate,
              );
              return Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: context.tint(0.05),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: context.hairline),
                ),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: displayCurrencyWithCode(e.net, e.cur),
                        style: TextStyle(
                          color: context.textSubtle,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (!isTarget)
                        TextSpan(
                          text: '  ≈ ${currencyFormat.displayMoney(converted)}',
                          style: TextStyle(
                            color: context.textFaint,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                    ],
                    style: const TextStyle(
                      fontSize: 11,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              );
            }).toList(),
          ),
        ],
      ],
    );

    final legend = _buildLegend(institutions);
    final modeToggle = _buildModeToggle();

    // In simple mode the legend collapses to just the toggle. In detailed
    // mode they sit side by side (toggle first, so it's reachable without
    // tabbing past the legend chips).
    final rightSide = _detailed
        ? Wrap(
            spacing: 12,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [modeToggle, legend],
          )
        : modeToggle;

    if (isCompact) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [summary, const SizedBox(height: 16), rightSide],
      );
    }

    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: summary),
        const SizedBox(width: 16),
        Flexible(child: rightSide),
      ],
    );
  }

  /// Expandable "what drove the change" section under the delta chips. Reuses
  /// the MoM baseline (one month before the latest snapshot — the same one the
  /// MoM chip picks) so the reading order stays hero → delta → movers. Diffs
  /// each institution latest-vs-baseline and shows the top 3 by absolute
  /// change. Hidden when there's no plausible MoM delta (which already covers
  /// < 2 snapshots, no comparable point, negative/onboarding-inflated baselines
  /// via `computeMomYoyDeltas`) or no `by_institution` data.
  Widget _buildMoversSection() {
    final mom = computeMomYoyDeltas(history).mom;
    if (mom == null) return const SizedBox.shrink();
    final latestDate = _latestSnapshotDate(history);
    if (latestDate == null) return const SizedBox.shrink();
    // Same target the MoM chip diffs against; the movers helper snaps to the
    // nearest snapshot within +/-5 days, matching `computeMomYoyDeltas`.
    final baselineDate = DateTime(
      latestDate.year,
      latestDate.month - 1,
      latestDate.day,
    );
    final movers = topInstitutionMovers(history, baselineDate);
    if (movers.isEmpty) return const SizedBox.shrink();

    final l = AppLocalizations.of(context);
    final totalAmount = mom.amount * conversionFactor;
    final totalUp = totalAmount >= 0;
    final totalColor = totalUp ? context.positive : context.negative;
    final sinceLabel = l.nwMoversSince(
      DateFormat('MMM d').format(baselineDate),
    );

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Tappable summary row: "Since <date>  ↑ +$X" + expand chevron.
          Tooltip(
            message: l.nwMoversToggleTooltip,
            child: Semantics(
              button: true,
              expanded: _moversExpanded,
              label: l.nwMoversToggleTooltip,
              child: InkWell(
                borderRadius: BorderRadius.circular(8),
                onTap: () => setState(() => _moversExpanded = !_moversExpanded),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        sinceLabel,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: context.textMuted,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Icon(
                        totalUp ? Icons.arrow_upward : Icons.arrow_downward,
                        color: totalColor,
                        size: 13,
                      ),
                      const SizedBox(width: 2),
                      Text(
                        '${totalUp ? '+' : '−'}'
                        '${currencyFormat.displayMoney(totalAmount.abs())}',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w700,
                          color: totalColor,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        _moversExpanded ? Icons.expand_less : Icons.expand_more,
                        color: context.textMuted,
                        size: 16,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          if (_moversExpanded) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: movers.map(_moverChip).toList(),
            ),
          ],
        ],
      ),
    );
  }

  /// A single institution mover: `↑ Institution +$Y`. Up = positive hue,
  /// down = negative. The delta is base-unit and scaled to reporting currency
  /// here, matching the tooltip/hero math elsewhere in the card.
  Widget _moverChip(({String name, double delta}) mover) {
    final up = mover.delta >= 0;
    final color = up ? context.positive : context.negative;
    final amount = mover.delta.abs() * conversionFactor;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            up ? Icons.arrow_upward : Icons.arrow_downward,
            color: color,
            size: 11,
          ),
          const SizedBox(width: 3),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 120),
            child: Text(
              mover.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: context.textSubtle,
              ),
            ),
          ),
          const SizedBox(width: 4),
          Text(
            '${up ? '+' : '−'}${currencyFormat.displayMoney(amount)}',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  /// Returns an ordered list of (institutionName, color) pairs for the
  /// top contributors observed across the provided history. Colours come
  /// from `context.chartSeries` so they shift to AA-readable shades on
  /// a white card in light mode while keeping the neon palette in dark.
  List<MapEntry<String, Color>> _topInstitutions(
    BuildContext context,
    List<dynamic> data, {
    int max = 5,
  }) {
    final maxByInst = <String, double>{};
    for (final raw in data) {
      final map = raw as Map<String, dynamic>;
      final byInst =
          (map['by_institution'] as Map?)?.cast<String, dynamic>() ?? {};
      for (final entry in byInst.entries) {
        final value = (entry.value as num).toDouble().abs();
        final prev = maxByInst[entry.key] ?? 0.0;
        if (value > prev) maxByInst[entry.key] = value;
      }
    }
    final sorted = maxByInst.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final top = sorted.take(max).toList();
    return [
      for (var i = 0; i < top.length; i++)
        MapEntry(top[i].key, context.chartSeries(i)),
    ];
  }

  Widget _buildLegend(List<MapEntry<String, Color>> institutions) {
    return Wrap(
      spacing: 12,
      runSpacing: 8,
      children: [
        _legendItem(
          AppLocalizations.of(context).pfTotalNetWorth,
          context.positive,
        ),
        ...institutions.map((e) => _legendItem(e.key, e.value)),
      ],
    );
  }

  Widget _legendItem(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 4),
        // Institution names can be very long ("Morgan Stanley - StockPlan
        // Connect / Benefit Access"); clamp each chip so the legend stays a
        // line or two and doesn't steal height from the fixed-height chart.
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 110),
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: context.textSubtle),
          ),
        ),
      ],
    );
  }

  Widget _buildChart(
    List<dynamic> filtered,
    List<MapEntry<String, Color>> institutions,
    double chartWidth,
  ) {
    if (history.isEmpty) {
      // Mock historical data if empty - show a flat line for onboarding
      final now = DateTime.now();
      final mockData = List.generate(30, (index) {
        final date = now.subtract(Duration(days: 29 - index));
        return {
          'date': DateFormat('yyyy-MM-dd').format(date),
          'net_worth':
              netWorth / conversionFactor, // backend expects base units
          'by_institution': const <String, dynamic>{},
        };
      });
      return _renderLineChart(mockData, const [], chartWidth);
    }

    return _renderLineChart(filtered, institutions, chartWidth);
  }

  /// History rows paired with their snapshot date, normalized to UTC midnight,
  /// same-day duplicates collapsed to the LAST row, sorted ascending — the
  /// `dedupeDailyCloses` rule from `utils/chart_time_axis.dart`, applied to the
  /// richer rows this chart also reads for tooltips and institution bands.
  /// Rows whose date won't parse have no position on a TIME axis, so they drop.
  static List<({DateTime date, Map<String, dynamic> row})> _datedRows(
    List<dynamic> data,
  ) {
    final byDay = <DateTime, Map<String, dynamic>>{};
    for (final raw in data) {
      if (raw is! Map) continue;
      final date = DateTime.tryParse(raw['date']?.toString() ?? '');
      if (date == null) continue;
      byDay[DateTime.utc(date.year, date.month, date.day)] = raw
          .cast<String, dynamic>();
    }
    final days = byDay.keys.toList()..sort();
    return [for (final d in days) (date: d, row: byDay[d]!)];
  }

  /// Bottom-axis tick interval in DAYS for a time-spaced (day-offset) x axis:
  /// ~1 label per 72px of plot width ("MMM y" labels are wide), whole days so
  /// the tick grid stays exact, never below one day. Same thinning rule the
  /// index-spaced axis used, expressed in the day-offset space that both this
  /// chart and the currency-lens chart now share.
  static double _dayTickInterval(int spanDays, double chartWidth) {
    if (spanDays <= 0) return 1;
    final maxLabels = (chartWidth / 72).floor().clamp(2, spanDays + 1);
    return (spanDays / (maxLabels - 1)).ceil().toDouble();
  }

  /// Whether a tick at day offset [value] should be dropped because it would
  /// paint within ~60px of the final one. fl_chart always emits both endpoints
  /// (`SideTitles.minIncluded`/`maxIncluded`), so the latest snapshot is always
  /// labelled and it is the earlier neighbour that gives way.
  static bool _suppressTick(double value, int spanDays, double plotWidth) {
    if (spanDays <= 0 || value >= spanDays) return false;
    return (spanDays - value) * (plotWidth / spanDays) < 60;
  }

  /// The day offsets the bottom axis will actually label, mirroring what
  /// `getTitlesWidget` renders: multiples of [interval] plus the final
  /// endpoint, minus anything [_suppressTick] drops.
  static List<double> _bottomTickOffsets(
    int spanDays,
    double interval,
    double plotWidth,
  ) {
    if (spanDays <= 0) return const [0.0];
    final out = <double>[];
    for (var x = 0.0; x < spanDays; x += interval) {
      if (_suppressTick(x, spanDays, plotWidth)) continue;
      out.add(x);
    }
    out.add(spanDays.toDouble());
    return out;
  }

  Widget _renderLineChart(
    List<dynamic> data,
    List<MapEntry<String, Color>> institutions,
    double chartWidth,
  ) {
    if (data.isEmpty) return const SizedBox.shrink();

    // TIME-SPACED x, identical to the currency-lens chart's mapping: x is the
    // day offset from the first snapshot, so a sparse March sample sits its
    // real distance from a tightly packed July one. Index-as-x gave the
    // default lens a different horizontal mapping from the MXN / constant-FX
    // lenses, and switching lenses appeared to reshape the same history.
    final rows = _datedRows(data);
    if (rows.isEmpty) return const SizedBox.shrink();
    final firstDate = rows.first.date;
    final spanDays = rows.last.date.difference(firstDate).inDays;
    DateTime dateForOffset(double x) =>
        firstDate.add(Duration(days: x.round()));

    // Bottom-axis label format follows the plotted data's real span, not the
    // selected range chip — then escalates if the ticks at THIS density would
    // still repeat themselves (see `nonRepeatingDateFormat`).
    List<DateTime> ticksFor(double width) => [
      for (final x in _bottomTickOffsets(
        spanDays,
        _dayTickInterval(spanDays, width),
        width,
      ))
        dateForOffset(x),
    ];
    double halfWidestLabel(List<DateTime> ticks, DateFormat f) => ticks.isEmpty
        ? 0.0
        : ticks.map((d) => axisTickTextWidth(f.format(d))).reduce(math.max) / 2;

    // The final tick sits ON the plot's right edge with its label centred
    // there, so half of it hung past the card and was clipped ("Aug 1" read as
    // "Aug"). Reserve half the widest label's width on the right. The left
    // edge needs no such reserve: the y-axis column already gives the first
    // label somewhere to overhang into.
    //
    // Two passes, because the reserve narrows the plot, which changes how many
    // ticks fit, which changes the widest label. Settling it that way rather
    // than iterating keeps it deterministic — and it can only err toward a
    // slightly wider margin, never a clipped label: a narrower plot thins
    // labels further, and fewer, coarser labels are never wider than the ones
    // measured in pass one.
    final firstPass = ticksFor(chartWidth);
    final bottomOverhang = halfWidestLabel(
      firstPass,
      nonRepeatingDateFormat(firstPass, spanDays: spanDays),
    );
    final plotWidth = (chartWidth - bottomOverhang).clamp(1.0, chartWidth);
    final tickInterval = _dayTickInterval(spanDays, plotWidth);
    final bottomLabelFormat = nonRepeatingDateFormat(
      ticksFor(plotWidth),
      spanDays: spanDays,
    );

    // For a true "where the total comes from" stacked-area visualisation we
    // build a series of cumulative lines from the top down. Filling each
    // line's BarArea down to the X axis layers the bands such that the
    // strip between cumulative[i] and cumulative[i+1] gets institution i's
    // colour. A trailing "Other" line catches whatever isn't in the top N.
    final List<FlSpot> totalSpots = [];
    // cumulativeSpots[level] is the line at cumulativeFromTop level. Level 0
    // is the total, level 1 is total minus inst[0]'s value, etc. The last
    // level is the residual ("Other") which we fill in grey.
    final levels = institutions.length;
    final cumulativeSpots = List<List<FlSpot>>.generate(
      levels + 1,
      (_) => <FlSpot>[],
    );

    double minY = double.infinity;
    double maxY = -double.infinity;

    final baseValue =
        (rows.first.row['net_worth'] as num).toDouble() * conversionFactor;

    // Day offset → row index, so the tooltip can still find the sample under
    // the cursor now that x is a date position rather than an index.
    final rowIndexByX = <double, int>{};

    // Performance Optimization: Downsample to ~150 points maximum
    final int step = rows.length > 150 ? (rows.length / 150).ceil() : 1;

    void processPoint(int i) {
      final point = rows[i].row;
      final total = (point['net_worth'] as num).toDouble() * conversionFactor;
      final x = rows[i].date.difference(firstDate).inDays.toDouble();
      rowIndexByX[x] = i;
      totalSpots.add(FlSpot(x, total));

      final byInst =
          (point['by_institution'] as Map?)?.cast<String, dynamic>() ?? {};

      // Top of the stack is the total. Each lower level subtracts the next
      // institution's value. The bottom level is "Other" — what's left.
      double running = total;
      cumulativeSpots[0].add(FlSpot(x, running));
      for (int idx = 0; idx < levels; idx++) {
        final raw = byInst[institutions[idx].key];
        final v = raw is num ? raw.toDouble() * conversionFactor : 0.0;
        running -= v;
        cumulativeSpots[idx + 1].add(FlSpot(x, running));
      }

      if (total < minY) minY = total;
      if (total > maxY) maxY = total;
      // Don't let the running residual push minY below 0 visually; some
      // historical points may have negative residuals if liabilities exceed
      // tracked assets.
      if (running < minY) minY = running;
    }

    for (int i = 0; i < rows.length; i += step) {
      processPoint(i);
    }
    // Always include the most recent data point
    if ((rows.length - 1) % step != 0) {
      processPoint(rows.length - 1);
    }

    // Fit the Y axis. minY/maxY currently hold the raw data extent; the
    // simple-vs-stacked rules live in computeNetWorthYBounds (unit-tested).
    final (fitMinY, fitMaxY) = computeNetWorthYBounds(
      dataMin: minY,
      dataMax: maxY,
      baseValue: baseValue,
      stacked: institutions.isNotEmpty,
    );
    minY = fitMinY;
    maxY = fitMaxY;

    // Calculate a smart Y-axis interval to avoid duplicate labels
    final yRange = maxY - minY;
    final rawInterval = yRange / 5; // aim for ~5 labels
    // Round to a nice number (1k, 5k, 10k, 25k, 50k, 100k, etc.)
    double yInterval;
    if (rawInterval <= 1000) {
      yInterval = 1000;
    } else if (rawInterval <= 2500) {
      yInterval = 2500;
    } else if (rawInterval <= 5000) {
      yInterval = 5000;
    } else if (rawInterval <= 10000) {
      yInterval = 10000;
    } else if (rawInterval <= 25000) {
      yInterval = 25000;
    } else if (rawInterval <= 50000) {
      yInterval = 50000;
    } else {
      yInterval = (rawInterval / 50000).ceil() * 50000;
    }

    // Transient tooltip (dismisses on finger lift / pointer exit) — the raw
    // LineChart's built-in handling kept it pinned on mobile web. The inline
    // LineTouchData below is unchanged; the wrapper owns show/dismiss and,
    // on TOUCH, suppresses the tooltip entirely: this one runs to 8+ lines
    // in detailed mode (~175px of a 220px box), so even pinned to the top of
    // the box it sits under the finger. The reading goes to the header
    // instead; the vertical guide + dot remain as position feedback.
    final chart = TransientTooltipLineChart(
      suppressTooltipOnTouch: true,
      onScrub: _scrubHandler((spot) {
        final idx = rowIndexByX[spot.x];
        if (idx == null) return null;
        final nw = rows[idx].row['net_worth'];
        if (nw is! num) return null;
        return (
          date: rows[idx].date,
          value: currencyFormat.displayMoney(nw.toDouble() * conversionFactor),
        );
      }),
      data: LineChartData(
        lineTouchData: LineTouchData(
          // Snap-to-nearest-x feel: a very large threshold makes the
          // chart always pick the closest sample to the cursor's X
          // regardless of vertical distance. That's the canonical
          // Robinhood / Mint / Personal Capital interaction — the
          // cursor doesn't have to land on the line for a tooltip
          // to fire. Combined with the vertical guide drawn by
          // `getTouchedSpotIndicator` below, hover now feels
          // continuous instead of "you have to find the sample".
          touchSpotThreshold: 100000,
          distanceCalculator: (touchPoint, spotPixelCoordinates) =>
              (touchPoint.dx - spotPixelCoordinates.dx).abs(),
          handleBuiltInTouches: true,
          getTouchedSpotIndicator: (barData, spotIndexes) {
            // Paint a vertical guide line and a ring-bordered dot at
            // each touched spot. Without this the chart had no hover
            // feedback at all unless the cursor landed exactly on a
            // sample, which felt mechanical.
            return spotIndexes.map((idx) {
              return TouchedSpotIndicatorData(
                FlLine(
                  color: Theme.of(
                    context,
                  ).colorScheme.onSurface.withValues(alpha: 0.35),
                  strokeWidth: 1,
                ),
                FlDotData(
                  show: true,
                  getDotPainter: (spot, percent, bar, i) => FlDotCirclePainter(
                    radius: 5,
                    color: barData.color ?? context.positive,
                    strokeWidth: 3,
                    strokeColor: Theme.of(context).colorScheme.surface,
                  ),
                ),
              );
            }).toList();
          },
          touchTooltipData: LineTouchTooltipData(
            // Theme.of(context).colorScheme.inverseSurface is the
            // brightness-opposite of the active surface: dark popovers in
            // light mode, light popovers in dark mode. Matches the
            // Material 3 convention for tooltips / snackbars.
            getTooltipColor: (touchedSpot) => context.tooltipSurface,
            tooltipRoundedRadius: 12,
            getTooltipItems: (touchedSpots) {
              // The wealth line is always the LAST bar in lineBarsData.
              // Only emit a single tooltip body there, listing every
              // institution's contribution for that date.
              final wealthBarIndex = institutions.isEmpty
                  ? 0
                  : institutions.length + 1;
              return touchedSpots.map((spot) {
                if (spot.barIndex != wealthBarIndex) return null;

                // x is a day offset now, not an index — the sample map built
                // alongside the spots is the only correct way back to a row.
                final idx = rowIndexByX[spot.x] ?? 0;
                final point = rows[idx].row;
                final date = rows[idx].date;

                final nw = point['net_worth'];
                final ta = point['total_assets'];
                final tl = point['total_liabilities'];
                final byInst =
                    (point['by_institution'] as Map?)
                        ?.cast<String, dynamic>() ??
                    {};

                // Tooltip background is inverseSurface (dark popover in
                // light mode, light popover in dark mode). All text
                // colours must use onInverseSurface family — using
                // `context.textPrimary` here was the original "light text
                // on light tooltip in dark mode" bug.
                final children = <TextSpan>[
                  TextSpan(
                    text: '${DateFormat('MMM d, y').format(date)}\n',
                    style: TextStyle(
                      color: context.tooltipOnSurfaceMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.normal,
                    ),
                  ),
                  TextSpan(
                    text:
                        '${AppLocalizations.of(context).pfTooltipNetWorth(currencyFormat.displayMoney((nw as num).toDouble() * conversionFactor))}\n',
                    style: TextStyle(
                      color: context.tooltipOnSurface,
                      fontWeight: FontWeight.bold,
                      fontSize: 14,
                    ),
                  ),
                ];

                if (ta != null && tl != null) {
                  children.addAll([
                    TextSpan(
                      text: '───────────────\n',
                      style: TextStyle(color: context.tooltipOnSurfaceMuted),
                    ),
                    // Assets/Liabilities labels keep the brand positive/
                    // negative hues but at the brightness-opposite shade
                    // so they contrast with the inverseSurface tooltip
                    // background. See ThemeColorsExt.tooltipPositive.
                    TextSpan(
                      text:
                          '${AppLocalizations.of(context).pfTooltipAssets(currencyFormat.displayMoney((ta as num).toDouble() * conversionFactor))}\n',
                      style: TextStyle(
                        color: context.tooltipPositive,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(
                      text:
                          '${AppLocalizations.of(context).pfTooltipLiabilities(currencyFormat.displayMoney((tl as num).toDouble() * conversionFactor))}\n',
                      style: TextStyle(
                        color: context.tooltipNegative,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ]);
                }

                if (institutions.isNotEmpty) {
                  children.add(
                    TextSpan(
                      text: '───────────────\n',
                      style: TextStyle(color: context.tooltipOnSurfaceMuted),
                    ),
                  );
                  for (final inst in institutions) {
                    final raw = byInst[inst.key];
                    if (raw is! num) continue;
                    final value = raw.toDouble() * conversionFactor;
                    children.add(
                      TextSpan(
                        text:
                            '${inst.key}: ${currencyFormat.displayMoney(value)}\n',
                        style: TextStyle(
                          color: inst.value,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    );
                  }
                }

                return LineTooltipItem(
                  '',
                  TextStyle(color: context.tooltipOnSurface),
                  children: children,
                );
              }).toList();
            },
          ),
        ),
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          horizontalInterval: yInterval,
          getDrawingHorizontalLine: (value) =>
              FlLine(color: context.hairline, strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          show: true,
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 22,
              interval: tickInterval,
              getTitlesWidget: (value, meta) {
                if (value < 0 || value > spanDays) {
                  return const SizedBox.shrink();
                }
                // Keep the last label; drop any earlier tick that would
                // paint within ~60px of it — a "Jul 2026" tick one step
                // before the end used to collide with the final label.
                if (_suppressTick(value, spanDays, plotWidth)) {
                  return const SizedBox.shrink();
                }
                return Text(
                  bottomLabelFormat.format(dateForOffset(value)),
                  style: TextStyle(color: context.textSubtle, fontSize: 10),
                );
              },
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: yInterval,
              getTitlesWidget: (value, meta) {
                // Skip ticks that fall within ~half an interval of either
                // edge — fl_chart can otherwise crowd or clip labels at the
                // very top/bottom of the axis.
                final edgeBuffer = yInterval * 0.5;
                if (value <= minY + edgeBuffer || value >= maxY - edgeBuffer) {
                  return const SizedBox();
                }
                return Text(
                  // House compact ticks — compactSimpleCurrency shows a bare
                  // "$" for MXN (see compactMoney).
                  compactMoney(value, currencyFormat.currencyName ?? 'USD'),
                  style: TextStyle(color: context.textSubtle, fontSize: 10),
                );
              },
              // Fit the box to the widest possible tick — a fixed 50 wrapped
              // "MXN 6.75M"'s final "M" onto a second line in MXN mode.
              reservedSize: compactMoneyAxisWidth(
                minY,
                maxY,
                currencyFormat.currencyName ?? 'USD',
              ),
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        minY: minY,
        maxY: maxY,
        lineBarsData: [
          // Stacked area: cumulative lines drawn top→down. Each level's
          // belowBarData fill paints from that line down to 0, so each
          // subsequent (lower) line covers the bottom of the prior one,
          // leaving only the band between two consecutive cumulatives
          // visible — which is the contribution of one institution.
          for (int idx = 0; idx < levels; idx++)
            LineChartBarData(
              spots: cumulativeSpots[idx],
              isCurved: true,
              preventCurveOverShooting: true,
              color: institutions[idx].value.withValues(alpha: 0.85),
              barWidth: 1.5,
              isStrokeCapRound: true,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(
                show: true,
                color: institutions[idx].value.withValues(alpha: 0.45),
              ),
            ),
          // Residual "Other" band — drawn last so its fill (grey) covers
          // whatever's between cumulativeSpots[levels] and the X axis.
          if (levels > 0)
            LineChartBarData(
              spots: cumulativeSpots[levels],
              isCurved: true,
              preventCurveOverShooting: true,
              color: context.textFaint,
              barWidth: 1,
              isStrokeCapRound: true,
              dotData: const FlDotData(show: false),
              belowBarData: BarAreaData(show: true, color: context.tint(0.05)),
            ),
          // Total net worth line drawn on top so it remains the focal value.
          LineChartBarData(
            spots: totalSpots,
            isCurved: true,
            preventCurveOverShooting: true,
            // Brand emerald gradient — colour shifts darker in light mode
            // (via context.positive) so the line passes AA on a white card.
            gradient: LinearGradient(
              colors: [
                context.positive,
                context.positive.withValues(alpha: 0.55),
              ],
            ),
            barWidth: 3.5,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
          ),
        ],
      ),
    );

    // The right inset is what stops the final x-label being clipped by the
    // card edge (see `bottomOverhang`): fl_chart has no plot-padding knob, so
    // the whole chart is narrowed instead, which moves the last tick — and its
    // centred label — back inside.
    return Padding(
      padding: EdgeInsets.only(right: bottomOverhang),
      child: chart,
    );
  }
}

/// Latest snapshot date in `history`, or null when none parse. Used to anchor
/// the movers baseline (one month back) the same way `computeMomYoyDeltas`
/// anchors the MoM chip.
DateTime? _latestSnapshotDate(List<dynamic> history) {
  DateTime? latest;
  for (final raw in history) {
    if (raw is! Map) continue;
    final ds = raw['date']?.toString();
    if (ds == null) continue;
    final dt = DateTime.tryParse(ds);
    if (dt == null) continue;
    if (latest == null || dt.isAfter(latest)) latest = dt;
  }
  return latest;
}

/// Per-institution net-worth movers between the baseline snapshot (the one
/// nearest [baselineDate] within +/-5 days — the same selection
/// `computeMomYoyDeltas` uses) and the latest snapshot. Each institution's
/// `by_institution` value is diffed latest-vs-baseline, sorted by absolute
/// change (largest first), and the top 3 are returned. Deltas are in the
/// history's base units (the caller scales to reporting currency).
///
/// Returns an empty list when there are < 2 parseable snapshots, no baseline
/// point within tolerance, or neither endpoint carries `by_institution` data —
/// so the caller can hide the section.
List<({String name, double delta})> topInstitutionMovers(
  List<dynamic> history,
  DateTime baselineDate,
) {
  final points = <({DateTime date, Map<String, dynamic> byInst})>[];
  for (final raw in history) {
    if (raw is! Map<String, dynamic>) continue;
    final ds = raw['date']?.toString();
    if (ds == null) continue;
    final dt = DateTime.tryParse(ds);
    if (dt == null) continue;
    final byInst =
        (raw['by_institution'] as Map?)?.cast<String, dynamic>() ?? {};
    points.add((date: dt, byInst: byInst));
  }
  if (points.length < 2) return const [];
  points.sort((a, b) => a.date.compareTo(b.date));
  final latest = points.last;

  // Nearest baseline point within +/-5 days (matches computeMomYoyDeltas).
  // Records are value types, so skip the latest by index rather than identity.
  ({DateTime date, Map<String, dynamic> byInst})? baseline;
  int? bestDist;
  for (int i = 0; i < points.length - 1; i++) {
    final p = points[i];
    final dist = p.date.difference(baselineDate).inDays.abs();
    if (dist <= 5 && (bestDist == null || dist < bestDist)) {
      baseline = p;
      bestDist = dist;
    }
  }
  if (baseline == null) return const [];

  // No institution data on either endpoint → nothing to attribute.
  if (latest.byInst.isEmpty && baseline.byInst.isEmpty) return const [];

  final names = <String>{...latest.byInst.keys, ...baseline.byInst.keys};
  final movers = <({String name, double delta})>[];
  for (final name in names) {
    final latestVal = (latest.byInst[name] as num?)?.toDouble() ?? 0.0;
    final baseVal = (baseline.byInst[name] as num?)?.toDouble() ?? 0.0;
    final delta = latestVal - baseVal;
    if (delta == 0) continue;
    movers.add((name: name, delta: delta));
  }
  movers.sort((a, b) => b.delta.abs().compareTo(a.delta.abs()));
  return movers.take(3).toList();
}

class _DeltaChip extends StatelessWidget {
  final double amount;
  final double? percentage;
  final String label;
  final NumberFormat currencyFormat;

  /// Optional short period tag rendered as a leading pill (e.g. "MoM" /
  /// "YoY"). When set it replaces the "vs 30d ago" trailing copy.
  final String? periodTag;

  const _DeltaChip({
    required this.amount,
    required this.percentage,
    required this.label,
    required this.currencyFormat,
    this.periodTag,
  });

  @override
  Widget build(BuildContext context) {
    final isUp = amount >= 0;
    final color = isUp ? context.positive : context.negative;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (periodTag != null) ...[
            Text(
              periodTag!,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                color: context.textSubtle,
                letterSpacing: 0.4,
              ),
            ),
            const SizedBox(width: 6),
          ],
          Icon(
            isUp ? Icons.arrow_upward : Icons.arrow_downward,
            color: color,
            size: 14,
          ),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              () {
                final pct = percentage;
                // Suppress the "(+X%)" when the baseline is onboarding noise;
                // the dollar amount alone is the honest read.
                final pctStr = pct == null
                    ? ''
                    : ' (${isUp ? '+' : ''}'
                          '${formatPercent(context, pct, digits: periodTag != null ? 1 : 2)})';
                final amt =
                    '${isUp ? '+' : '−'}${currencyFormat.displayMoney(amount.abs())}';
                return periodTag != null
                    ? '$amt$pctStr'
                    : '$amt$pctStr ${AppLocalizations.of(context).pfDeltaVsAgo(label)}';
              }(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: color,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }
}

/// Y-axis bounds (`(minY, maxY)`) for the net-worth chart. Exposed at the top
/// level so the fit logic can be unit-tested without an fl_chart render.
///
/// - **Simple** (single-line) mode FITS the axis to the data range, so a short
///   window (e.g. 1 month, where net worth moves only a few % of its total)
///   fills the chart instead of flat-lining against a $0 baseline that spans
///   the whole net-worth magnitude.
/// - **Stacked** (detailed) mode grounds the floor at 0 so the band heights
///   read honestly (the area fills paint down to the axis floor).
/// - Neither mode opens empty negative space under an all-positive series: on
///   a wide range (5Y) the large padding could push the fitted floor below 0,
///   so it's clamped back to 0 when the data never goes negative.
(double, double) computeNetWorthYBounds({
  required double dataMin,
  required double dataMax,
  required double baseValue,
  required bool stacked,
}) {
  double minY = dataMin;
  double maxY = dataMax;
  double padding = (maxY - minY) * 0.15;
  if (padding <= 0) padding = baseValue * 0.15 + 1000;
  minY -= padding;
  if (stacked) {
    if (minY > 0) minY = 0;
  } else if (minY < 0 && dataMin >= 0) {
    minY = 0;
  }
  maxY += padding;
  return (minY, maxY);
}
