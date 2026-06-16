import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../components/date_range_selector.dart';
import '../l10n/app_localizations.dart';
import '../services/preferences.dart';
import '../theme/typography.dart';
import '../utils/currency.dart';
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
  });

  @override
  State<NetWorthCard> createState() => _NetWorthCardState();
}

class _NetWorthCardState extends State<NetWorthCard> {
  // The default view is the single green-line "simple" mode — the stacked
  // institution bands compete with the total line and get visually mushy
  // past ~5 institutions. The toggle is persisted so power users who
  // prefer the detailed view don't have to flip it every refresh.
  late bool _detailed = Preferences.getNetWorthDetailed();

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
    final entries = sourceBreakdown
        .map((item) => (
              cur: (item['currency'] ?? '').toString().toUpperCase(),
              net: ((item['net'] ?? 0.0) as num).toDouble(),
            ))
        .where((e) => e.cur.isNotEmpty)
        .toList()
      ..sort((a, b) {
        final ca = convertCurrency(a.net,
            from: a.cur, to: reportingCurrency, usdMxnRate: usdMxnRate);
        final cb = convertCurrency(b.net,
            from: b.cur, to: reportingCurrency, usdMxnRate: usdMxnRate);
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
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isCompact = constraints.maxWidth < 640;
            final filtered = _filterByRange(history);
            // Only compute the per-institution slices when the detailed
            // view is actually being shown — saves a meaningful chunk of
            // work on the simple path.
            final institutions = _detailed
                ? _topInstitutions(context, filtered, max: 4)
                : const <MapEntry<String, Color>>[];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(isCompact, institutions),
                const SizedBox(height: 24),
                Expanded(child: _buildChart(filtered, institutions)),
              ],
            );
          },
        ),
      ),
    );
  }

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

  Widget _buildHeader(
      bool isCompact, List<MapEntry<String, Color>> institutions) {
    final summary = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          AppLocalizations.of(context)
              .pfTotalNetWorthCurrency(reportingCurrency),
          // Inter label above the hero number, kept understated — the big
          // mono number is the star.
          style: brandSectionTitleStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: context.textMuted,
          ).copyWith(letterSpacing: 0.3),
        ),
        const SizedBox(height: 4),
        // FittedBox shrinks the hero number down rather than ellipsing
        // when the card is narrow and the value is long. Avoids the
        // "USD 9,876…" cliff on phones.
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            currencyFormat.format(netWorth),
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
        // Trend chip — "↑ +$X (+Y%) vs 30d ago" — gives a one-line read
        // on whether net worth is moving up or down without making the
        // user scrub the chart. Computed from history; hidden when we
        // don't have a comparable point >= 7 days back.
        Builder(builder: (context) {
          final deltas = _computeMomYoyDeltas(history);
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
            final delta = _computeDelta(history);
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
        }),
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
              final converted = convertCurrency(e.net,
                  from: e.cur, to: reportingCurrency, usdMxnRate: usdMxnRate);
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: context.tint(0.05),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: context.hairline),
                ),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: formatCurrencyWithCode(e.net, e.cur),
                        style: TextStyle(
                          color: context.textSubtle,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      if (!isTarget)
                        TextSpan(
                          text: '  ≈ ${currencyFormat.format(converted)}',
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
        children: [
          summary,
          const SizedBox(height: 16),
          rightSide,
        ],
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

  /// Returns an ordered list of (institutionName, color) pairs for the
  /// top contributors observed across the provided history. Colours come
  /// from `context.chartSeries` so they shift to AA-readable shades on
  /// a white card in light mode while keeping the neon palette in dark.
  List<MapEntry<String, Color>> _topInstitutions(
      BuildContext context, List<dynamic> data,
      {int max = 5}) {
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
        _legendItem(AppLocalizations.of(context).pfTotalNetWorth,
            context.positive),
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
      List<dynamic> filtered, List<MapEntry<String, Color>> institutions) {
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
      return _renderLineChart(mockData, const []);
    }

    return _renderLineChart(filtered, institutions);
  }

  Widget _renderLineChart(
      List<dynamic> data, List<MapEntry<String, Color>> institutions) {
    if (data.isEmpty) return const SizedBox.shrink();

    // For a true "where the total comes from" stacked-area visualisation we
    // build a series of cumulative lines from the top down. Filling each
    // line's BarArea down to the X axis layers the bands such that the
    // strip between cumulative[i] and cumulative[i+1] gets institution i's
    // colour. A trailing "Other" line catches whatever isn't in the top N.
    List<FlSpot> totalSpots = [];
    // cumulativeSpots[level] is the line at cumulativeFromTop level. Level 0
    // is the total, level 1 is total minus inst[0]'s value, etc. The last
    // level is the residual ("Other") which we fill in grey.
    final levels = institutions.length;
    final cumulativeSpots =
        List<List<FlSpot>>.generate(levels + 1, (_) => <FlSpot>[]);

    double minY = double.infinity;
    double maxY = -double.infinity;

    final baseValue =
        (data.first['net_worth'] as num).toDouble() * conversionFactor;

    // Performance Optimization: Downsample to ~150 points maximum
    final int step = data.length > 150 ? (data.length / 150).ceil() : 1;

    void processPoint(int i) {
      final point = data[i] as Map<String, dynamic>;
      final total = (point['net_worth'] as num).toDouble() * conversionFactor;
      final x = i.toDouble();
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

    for (int i = 0; i < data.length; i += step) {
      processPoint(i);
    }
    // Always include the most recent data point
    if ((data.length - 1) % step != 0 && data.isNotEmpty) {
      processPoint(data.length - 1);
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

    return LineChart(
      LineChartData(
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
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.35),
                  strokeWidth: 1,
                ),
                FlDotData(
                  show: true,
                  getDotPainter: (spot, percent, bar, i) =>
                      FlDotCirclePainter(
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
              final wealthBarIndex =
                  institutions.isEmpty ? 0 : institutions.length + 1;
              return touchedSpots.map((spot) {
                if (spot.barIndex != wealthBarIndex) return null;

                final idx = spot.x.toInt().clamp(0, data.length - 1);
                final point = data[idx] as Map<String, dynamic>;
                final dateStr = point['date'].toString();
                final date = DateTime.tryParse(dateStr) ?? DateTime.now();

                final nw = point['net_worth'];
                final ta = point['total_assets'];
                final tl = point['total_liabilities'];
                final byInst = (point['by_institution'] as Map?)
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
                        '${AppLocalizations.of(context).pfTooltipNetWorth(currencyFormat.format((nw as num).toDouble() * conversionFactor))}\n',
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
                          '${AppLocalizations.of(context).pfTooltipAssets(currencyFormat.format((ta as num).toDouble() * conversionFactor))}\n',
                      style: TextStyle(
                        color: context.tooltipPositive,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    TextSpan(
                      text:
                          '${AppLocalizations.of(context).pfTooltipLiabilities(currencyFormat.format((tl as num).toDouble() * conversionFactor))}\n',
                      style: TextStyle(
                        color: context.tooltipNegative,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ]);
                }

                if (institutions.isNotEmpty) {
                  children.add(TextSpan(
                    text: '───────────────\n',
                    style: TextStyle(color: context.tooltipOnSurfaceMuted),
                  ));
                  for (final inst in institutions) {
                    final raw = byInst[inst.key];
                    if (raw is! num) continue;
                    final value = raw.toDouble() * conversionFactor;
                    children.add(TextSpan(
                      text:
                          '${inst.key}: ${currencyFormat.format(value)}\n',
                      style: TextStyle(
                        color: inst.value,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ));
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
              interval: (data.length / 5).clamp(1, 100).toDouble(),
              getTitlesWidget: (value, meta) {
                int index = value.toInt();
                if (index >= 0 && index < data.length) {
                  final dateStr = data[index]['date'].toString();
                  if (dateStr.length >= 10) {
                    final date = DateTime.parse(dateStr);
                    // Adapt format based on range
                    final fmt = selectedRange == DateRange.oneMonth
                        ? DateFormat('MMM d')
                        : DateFormat('MMM y');
                    return Text(
                      fmt.format(date),
                      style: TextStyle(color: context.textSubtle, fontSize: 10),
                    );
                  }
                }
                return const Text('');
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
                if (value <= minY + edgeBuffer ||
                    value >= maxY - edgeBuffer) {
                  return const SizedBox();
                }
                return Text(
                  NumberFormat.compactSimpleCurrency(
                    name: currencyFormat.currencyName,
                  ).format(value),
                  style: TextStyle(color: context.textSubtle, fontSize: 10),
                );
              },
              reservedSize: 50,
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
              belowBarData: BarAreaData(
                show: true,
                color: context.tint(0.05),
              ),
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
  }
}

/// Delta from the latest snapshot back to a reference snapshot — used to
/// drive the "↑ +$X vs 30d ago" chip below the hero number. Returns null
/// when history is too short or contains no comparable point.
_NetWorthDelta? _computeDelta(List<dynamic> history) {
  if (history.length < 2) return null;
  // Parse dates once. Skip points that don't parse or lack net_worth.
  final points = <_DeltaPoint>[];
  for (final raw in history) {
    final m = raw as Map<String, dynamic>;
    final ds = m['date']?.toString();
    if (ds == null) continue;
    final dt = DateTime.tryParse(ds);
    if (dt == null) continue;
    final nw = (m['net_worth'] as num?)?.toDouble();
    if (nw == null) continue;
    points.add(_DeltaPoint(date: dt, value: nw));
  }
  if (points.length < 2) return null;
  points.sort((a, b) => a.date.compareTo(b.date));
  final latest = points.last;

  // Find the most recent snapshot within each window. Prefer 30d, fall
  // back to 7d if we don't have ~a month of history yet. The window
  // tolerance is +/- 5 days so a missing snapshot doesn't kill the chip.
  _DeltaPoint? pick(int targetDaysAgo, int tolerance) {
    final target = latest.date.subtract(Duration(days: targetDaysAgo));
    _DeltaPoint? best;
    int? bestDist;
    for (final p in points) {
      if (p == latest) continue;
      final dist = (p.date.difference(target)).inDays.abs();
      if (dist <= tolerance && (bestDist == null || dist < bestDist)) {
        best = p;
        bestDist = dist;
      }
    }
    return best;
  }

  for (final (days, label) in const [
    (30, '30d'),
    (7, '7d'),
  ]) {
    final ref = pick(days, 5);
    if (ref != null && ref.value != 0) {
      final amount = latest.value - ref.value;
      if (ref.value < 0) {
        // Negative net-worth baseline: a percentage is meaningless here
        // (improving from -50k to -40k isn't "+20%"), but the dollar delta is
        // real — debt-payoff/early-onboarding users deserve to see it. Show
        // the amount, suppress only the %.
        return _NetWorthDelta(
            amount: amount, percentage: null, windowLabel: label);
      }
      final pct = _plausiblePct(amount, ref.value, latest.value);
      // Implausible baseline (onboarding — net worth >3x'd as accounts were
      // added): hide the whole chip, not just the %. A "+$1.5M MoM" is as
      // misleading as "+3905%". Try the next (shorter) window instead.
      if (pct == null) continue;
      return _NetWorthDelta(amount: amount, percentage: pct, windowLabel: label);
    }
  }
  return null;
}

/// Month-over-month and year-over-year deltas vs the same calendar date one
/// month / one year before the latest snapshot. Computed over the FULL history
/// (independent of the chart's range chip) with a +/-5 day tolerance so a
/// missing snapshot doesn't kill the figure. Either may be null when there
/// isn't a comparable point that far back.
({_NetWorthDelta? mom, _NetWorthDelta? yoy}) _computeMomYoyDeltas(
    List<dynamic> history) {
  final points = <_DeltaPoint>[];
  for (final raw in history) {
    final m = raw as Map<String, dynamic>;
    final ds = m['date']?.toString();
    if (ds == null) continue;
    final dt = DateTime.tryParse(ds);
    if (dt == null) continue;
    final nw = (m['net_worth'] as num?)?.toDouble();
    if (nw == null) continue;
    points.add(_DeltaPoint(date: dt, value: nw));
  }
  if (points.length < 2) return (mom: null, yoy: null);
  points.sort((a, b) => a.date.compareTo(b.date));
  final latest = points.last;

  _NetWorthDelta? deltaTo(DateTime targetDate, String label) {
    _DeltaPoint? best;
    int? bestDist;
    for (final p in points) {
      if (identical(p, latest)) continue;
      final dist = p.date.difference(targetDate).inDays.abs();
      if (dist <= 5 && (bestDist == null || dist < bestDist)) {
        best = p;
        bestDist = dist;
      }
    }
    if (best == null || best.value == 0) return null;
    final amount = latest.value - best.value;
    if (best.value < 0) {
      // Negative baseline: show the dollar delta, suppress the meaningless %.
      return _NetWorthDelta(amount: amount, percentage: null, windowLabel: label);
    }
    final pct = _plausiblePct(amount, best.value, latest.value);
    // Onboarding-inflated baseline → hide the chip entirely (no "+$1.5M MoM").
    if (pct == null) return null;
    return _NetWorthDelta(amount: amount, percentage: pct, windowLabel: label);
  }

  final d = latest.date;
  return (
    mom: deltaTo(DateTime(d.year, d.month - 1, d.day), 'MoM'),
    yoy: deltaTo(DateTime(d.year - 1, d.month, d.day), 'YoY'),
  );
}

class _DeltaPoint {
  final DateTime date;
  final double value;
  _DeltaPoint({required this.date, required this.value});
}

class _NetWorthDelta {
  final double amount;
  /// Null when the baseline is unreliable (onboarding inflation — net worth
  /// more than ~tripled over the window because accounts were still being
  /// added). The dollar amount is still shown; the percentage is suppressed
  /// rather than reporting a meaningless "+3905%".
  final double? percentage;
  final String windowLabel;
  _NetWorthDelta({
    required this.amount,
    required this.percentage,
    required this.windowLabel,
  });
}

/// Percentage from a baseline → latest, or null when the baseline is so small
/// relative to the latest that the change is onboarding/data noise, not a real
/// market move (net worth doesn't 3x in a month from returns).
double? _plausiblePct(double amount, double baseline, double latest) {
  if (baseline <= 0) return null;
  if (latest / baseline > 3.0) return null;
  return (amount / baseline) * 100;
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
                        '${pct.toStringAsFixed(periodTag != null ? 1 : 2)}%)';
                final amt =
                    '${isUp ? '+' : '−'}${currencyFormat.format(amount.abs())}';
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
