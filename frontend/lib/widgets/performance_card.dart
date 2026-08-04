import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../components/date_range_selector.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../theme/buttons.dart';
import '../utils/chart_time_axis.dart';
import '../utils/chart_touch.dart';
import '../utils/currency.dart';
import '../utils/percent_format.dart';
import '../utils/theme_colors.dart';
import 'tracked_lots_sheet.dart';

/// Portfolio performance: investment value over time (a line chart with a
/// range selector) plus the contribution-weighted "vs S&P 500" comparison.
///
/// The two used to be separate cards. They're merged here because they answer
/// the same question — "how is my portfolio doing?" — at the canonical place
/// in the screen hierarchy (overview → performance → allocation → holdings).
///
/// The performance line is a TRUE time-weighted return (cashflows divided out,
/// re-based to the selected range), shown against the S&P 500 indexed over the
/// same dates. This indexed overlay is legitimate precisely because TWR removes
/// contribution timing/size — unlike naively indexing dollar value (or net
/// worth) from ~0, which reports absurd returns by conflating contributions
/// with market gains. When the portfolio can't be priced historically (no
/// quote coverage) it falls back to the dollars-only line with no % (see the
/// note in `_valueSection`). The contribution-weighted "vs S&P" block below is
/// the complementary dollar-weighted read.
class PerformanceCard extends StatefulWidget {
  final ApiService apiService;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  /// The CURRENT total portfolio value in USD — same source as the
  /// portfolio hero (`/dashboard/holdings` `total_value_usd`). The headline
  /// dollar figure prefers this over the last portfolio-history point: after
  /// a partial account sync the trailing history point can cover only the
  /// account(s) that snapshotted that day, so "Portfolio value" showed one
  /// account's balance instead of the true total. Null (parent hasn't
  /// loaded holdings yet / older call sites) falls back to the series.
  final double? totalValueUsd;

  /// Test seams (same convention as `DividendIncomeCard.fetchOverride`:
  /// widget tests can't subclass ApiService). When non-null they replace the
  /// corresponding ApiService fetch; production call sites leave them null.
  final Future<List<dynamic>> Function()? historyFetchOverride;
  final Future<Map<String, dynamic>?> Function()? comparisonFetchOverride;
  final Future<Map<String, dynamic>?> Function()? twrFetchOverride;

  const PerformanceCard({
    super.key,
    required this.apiService,
    required this.conversionFactor,
    required this.currencyFormat,
    this.totalValueUsd,
    this.historyFetchOverride,
    this.comparisonFetchOverride,
    this.twrFetchOverride,
  });

  @override
  State<PerformanceCard> createState() => _PerformanceCardState();
}

/// The picker's curated set of benchmarks. `key` is the API value (matches the
/// backend `BENCHMARKS` table / `benchmark_prices.symbol`); `shortLabel`
/// resolves the localized pill/bar caption for the chosen index.
class _BenchmarkOption {
  final String key;
  final String Function(AppLocalizations) shortLabel;
  const _BenchmarkOption(this.key, this.shortLabel);
}

/// One frame of a touch scrub, already formatted for display: the scrubbed
/// [date], the headline figure at that point, and (TWR chart only) the two
/// return pills. A record, so equality is structural and the header's
/// [ValueListenableBuilder] skips no-op rebuilds.
///
/// [headlineIsMoney] tells the screen-reader announcement what the headline
/// actually is: on the TWR chart it's the portfolio VALUE at the scrubbed
/// date, but it degrades to the return when no `value_usd` can be resolved
/// for that date (see `_valueUsdOn`), and the spoken string must not label a
/// percentage "Portfolio value".
typedef _ScrubReading = ({
  DateTime date,
  String headline,
  bool headlineIsMoney,
  String? you,
  String? bench,
});

/// Inner card width below which the range row's benchmark chip and range
/// segments stop sharing a line (see `_rangeSelector`). The house
/// Row→Column header-stack breakpoint; the pair needs ~465px content-sized,
/// so this also leaves headroom for the widest localized benchmark label.
const double _rangeStackBelow = 520;

/// Minimum `coverage_pct` at which the TWR payload's daily `value_usd` may be
/// shown as the portfolio's value.
///
/// `value_usd` sums only the holdings the backend can price historically, so
/// at 80% coverage it is 80% of a portfolio — a number that would sit under a
/// "Portfolio value" caption while understating by a fifth. The same 0.99 is
/// the threshold at which `_twrBody` stops printing the coverage caption:
/// above it the card already tells the user the series is the whole
/// portfolio, so the two must agree or the card contradicts itself.
const double _twrValueCoverageFloor = 0.99;

final List<_BenchmarkOption> _benchmarkOptions = [
  _BenchmarkOption('SP500', (l) => l.lwPerfBenchSp500),
  _BenchmarkOption('NDX', (l) => l.lwPerfBenchNdx),
  _BenchmarkOption('ACWI', (l) => l.lwPerfBenchAcwi),
  _BenchmarkOption('AGG', (l) => l.lwPerfBenchAgg),
  _BenchmarkOption('MXX', (l) => l.lwPerfBenchMxx),
];

class _PerformanceCardState extends State<PerformanceCard> {
  bool _loading = true;
  List<dynamic> _history = const [];
  Map<String, dynamic>? _comparison;
  Map<String, dynamic>? _twr;
  DateRange _range = DateRange.all;
  // Selected benchmark for both the TWR overlay and the contribution
  // comparison; persisted across rebuilds like _range. Defaults to the S&P 500,
  // which keeps the endpoints' default behavior when nothing is chosen.
  String _benchmark = 'SP500';
  // Phone-only: the money-weighted benchmark block sits behind a tap-to-expand
  // disclosure (collapsed by default). In-memory only — not persisted.
  bool _benchmarkExpanded = false;

  /// The live touch-scrub reading, or null when no finger is on the chart.
  ///
  /// A ValueNotifier rather than setState: a scrub fires on every pointer
  /// move, and only the header (headline + pills) depends on it — rebuilding
  /// the whole card would re-run the series/downsample math ~60x a second
  /// while the finger drags. Disposed in [dispose].
  final ValueNotifier<_ScrubReading?> _scrub = ValueNotifier(null);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _scrub.dispose();
    super.dispose();
  }

  /// Publish a scrub frame (null = the finger lifted). Anything that changes
  /// which series is plotted must call `_setScrub(null)` too, or the header
  /// keeps a reading that no longer belongs to the chart under it.
  void _setScrub(_ScrubReading? reading) => _scrub.value = reading;

  /// The scrubbed-date caption that replaces the headline's subtitle. Same
  /// format the in-chart tooltip used, so the reading is recognizably the
  /// tooltip's content, just relocated.
  String _scrubDate(DateTime date) => DateFormat('MMM d, y').format(date);

  /// The caption under the scrubbed headline.
  ///
  /// When the headline is money the date alone is right: it inherits the
  /// "Portfolio value" caption it replaced. When no value resolves for that
  /// date the headline degrades to the return — and the caption MUST say so.
  /// The slot is the one the owner reads dollars in; letting a percentage
  /// occupy it under an unchanged, date-only caption is a silent change of
  /// meaning ("here's your money on May 1" vs "we can't value May 1"). Naming
  /// the method also disambiguates *which* return, since the pills below
  /// carry the same two numbers.
  String _scrubCaption(AppLocalizations l, _ScrubReading scrub) =>
      scrub.headlineIsMoney
      ? _scrubDate(scrub.date)
      : '${_scrubDate(scrub.date)} · ${l.lwPerfTwrReturn}';

  // Best-effort fetches, routed through the widget's test seams when present.
  Future<List<dynamic>> _fetchHistory() =>
      (widget.historyFetchOverride ??
              () => widget.apiService.getPortfolioValueHistory())()
          .catchError((_) => <dynamic>[]);

  Future<Map<String, dynamic>?> _fetchComparison() =>
      (widget.comparisonFetchOverride ??
              () => widget.apiService.getBenchmarkComparison(
                benchmark: _benchmark,
              ))()
          .catchError((_) => <String, dynamic>{});

  Future<Map<String, dynamic>?> _fetchTwr() =>
      (widget.twrFetchOverride ??
              () => widget.apiService.getPortfolioTwr(benchmark: _benchmark))()
          .catchError((_) => <String, dynamic>{});

  Future<void> _load() async {
    // History + contribution comparison are quick; both best-effort.
    final results = await Future.wait([_fetchHistory(), _fetchComparison()]);
    if (!mounted) return;
    setState(() {
      _history = results[0] as List<dynamic>;
      final c = results[1] as Map<String, dynamic>?;
      _comparison = (c == null || c.isEmpty) ? null : c;
      _loading = false;
    });

    // TWR is loaded separately: on a cold quote cache it triggers a per-symbol
    // Yahoo fetch and can take many seconds, so we paint the card immediately
    // (dollar line) and upgrade to the time-weighted view when it resolves.
    final t = await _fetchTwr();
    if (!mounted) return;
    // The TWR arriving swaps the dollar line for the indexed-return chart, so
    // any in-flight scrub reading is about a series that no longer exists.
    _setScrub(null);
    setState(() {
      _twr = (t == null || t.isEmpty) ? null : t;
    });
  }

  /// Switch the benchmark and refetch the two benchmark-dependent series (the
  /// TWR overlay + the contribution comparison). The portfolio value history is
  /// benchmark-independent, so it's left untouched. The TWR is cleared first so
  /// the card falls back to the dollar line while the new index is fetched
  /// (a cold cache triggers a per-symbol Yahoo pull).
  Future<void> _onBenchmarkChanged(String key) async {
    if (key == _benchmark) return;
    _setScrub(null);
    setState(() {
      _benchmark = key;
      _twr = null;
    });
    final results = await Future.wait([_fetchComparison(), _fetchTwr()]);
    if (!mounted) return;
    setState(() {
      final c = results[0] ?? const {};
      _comparison = c.isEmpty ? null : c;
      final t = results[1];
      _twr = (t == null || t.isEmpty) ? null : t;
    });
  }

  /// Localized short label for the currently selected benchmark (e.g. the pill
  /// caption). Falls back to the S&P 500 label for an unknown key.
  String _benchmarkLabel(AppLocalizations l) {
    return _benchmarkOptions
        .firstWhere(
          (o) => o.key == _benchmark,
          orElse: () => _benchmarkOptions.first,
        )
        .shortLabel(l);
  }

  /// TWR points are available + cover at least a sliver of the portfolio.
  bool get _hasTwr {
    final pts = _twr?['points'];
    return pts is List &&
        pts.length >= 2 &&
        ((_twr?['coverage_pct'] as num?)?.toDouble() ?? 0) > 0;
  }

  String _money(double usd) =>
      widget.currencyFormat.displayMoney(usd * widget.conversionFactor);

  /// A `[{date, value_usd}]` payload reduced to (UTC calendar day → value in
  /// USD), ascending, dropping rows with an unparseable date or a missing
  /// `value_usd`.
  static List<({DateTime day, double valueUsd})> _toValueDays(
    List<dynamic> rows,
  ) {
    final out = <({DateTime day, double valueUsd})>[];
    for (final p in rows) {
      final d = DateTime.tryParse(p['date']?.toString() ?? '');
      final v = (p['value_usd'] as num?)?.toDouble();
      if (d == null || v == null) continue;
      // Normalize to a UTC midnight so a DST-shifted local parse can't slip a
      // row into the previous day (same convention as dedupeDailyCloses).
      out.add((day: DateTime.utc(d.year, d.month, d.day), valueUsd: v));
    }
    out.sort((a, b) => a.day.compareTo(b.day));
    return out;
  }

  /// `_history` (the `balance_snapshots`-backed series) as value-days.
  /// Memoized on the identity of `_history` (which only changes in `_load`)
  /// because a scrub reads it on every pointer move — reparsing thousands of
  /// rows per frame of a drag is exactly what the ValueNotifier-not-setState
  /// scrub design exists to avoid.
  List<({DateTime day, double valueUsd})> _valueDays = const [];
  List<dynamic>? _valueDaysSource;

  List<({DateTime day, double valueUsd})> get _historyValueDays {
    if (identical(_valueDaysSource, _history)) return _valueDays;
    _valueDays = _toValueDays(_history);
    _valueDaysSource = _history;
    return _valueDays;
  }

  /// The TWR payload's own daily valuation (`points[].value_usd`) as
  /// value-days — same memoization, keyed on the identity of the points list.
  ///
  /// WHY THIS EXISTS. `/dashboard/portfolio-value-history` is backed by
  /// `balance_snapshots`, so it starts whenever this install first
  /// snapshotted — on the owner's account that was ~4 weeks of rows against a
  /// TWR chart running back to 2019. Scrubbing ALL / 5Y / 1Y / YTD therefore
  /// resolved no value for ~98% of the chart width and the headline degraded
  /// to a percentage that merely repeated the "Your portfolio" pill — the
  /// original complaint, unfixed. The TWR endpoint already values the
  /// portfolio every single day it plots (that valuation IS what its return
  /// is computed from), so the money is right there in the same payload,
  /// on exactly the dates being scrubbed.
  ///
  /// Gated on [_twrValueCoverageFloor]: `value_usd` sums only the symbols the
  /// backend can price daily, so below full coverage it is a PARTIAL total
  /// and must not be shown under a "Portfolio value" caption. Beneath the
  /// floor we fall through to `_history` (real observed balances) and then to
  /// the honest return fallback.
  List<({DateTime day, double valueUsd})> _twrValueDays = const [];
  Object? _twrValueDaysSource;

  List<({DateTime day, double valueUsd})> get _twrPointValueDays {
    final pts = _twr?['points'];
    final coverage = (_twr?['coverage_pct'] as num?)?.toDouble() ?? 0.0;
    final usable = pts is List && coverage >= _twrValueCoverageFloor
        ? pts
        : const <dynamic>[];
    if (identical(_twrValueDaysSource, usable)) return _twrValueDays;
    _twrValueDays = _toValueDays(usable);
    _twrValueDaysSource = usable;
    return _twrValueDays;
  }

  /// The last value at or before [day] in an ascending value-day list — the
  /// house carry-forward convention. Money is never interpolated between
  /// samples, and never extrapolated BACKWARDS: a [day] preceding the first
  /// row resolves to null, not to the first row's value.
  static double? _carryForward(
    List<({DateTime day, double valueUsd})> rows,
    DateTime day,
  ) {
    var lo = 0;
    var hi = rows.length - 1;
    var found = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (rows[mid].day.isAfter(day)) {
        hi = mid - 1;
      } else {
        found = mid;
        lo = mid + 1;
      }
    }
    return found < 0 ? null : rows[found].valueUsd;
  }

  /// The portfolio value in USD (unconverted) on [date], for the TWR scrub
  /// headline.
  ///
  /// Source order matters. The TWR payload's own daily valuation comes FIRST:
  /// it covers every plotted date (see [_twrPointValueDays]) and it lands on
  /// the same total as the resting headline, so lifting a finger off the
  /// right edge doesn't change the number. `_history` is the fallback for the
  /// coverage-gated case, where the observed account balance is the better
  /// figure anyway.
  ///
  /// Null when neither resolves. Callers must then show something else rather
  /// than invent a figure — and must SAY so (see `_headline`), since a
  /// percentage silently occupying the money slot is the bug this whole path
  /// exists to prevent.
  double? _valueUsdOn(DateTime date) {
    final day = DateTime.utc(date.year, date.month, date.day);
    return _carryForward(_twrPointValueDays, day) ??
        _carryForward(_historyValueDays, day);
  }

  List<dynamic> _filterByRange(List<dynamic> data) {
    if (data.isEmpty || _range == DateRange.all) return data;
    final now = DateTime.now();
    DateTime cutoff;
    switch (_range) {
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
    return data.where((p) {
      final d = DateTime.tryParse(p['date']?.toString() ?? '');
      if (d == null) return true;
      return d.isAfter(cutoff) || d.isAtSameMomentAs(cutoff);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);

    // Benchmark comparison validity.
    final c = _comparison;
    final invested = (c?['invested_usd'] as num?)?.toDouble() ?? 0;
    final lots = (c?['lot_count'] as num?)?.toInt() ?? 0;
    final hasBenchmark = c != null && invested > 0 && lots > 0;

    final hasHistory = _history.length >= 2;
    final showValue = hasHistory || _hasTwr;

    // Nothing to show → don't render an empty card.
    if (!showValue && !hasBenchmark) return const SizedBox.shrink();

    // Every layout decision below is keyed to the width the card was GIVEN,
    // not the window's: this card sits in a tab column that is one-third of a
    // wide dashboard on some screens and full-bleed on others, so the screen
    // width says nothing useful about how much room the plot has.
    return LayoutBuilder(
      builder: (context, constraints) {
        // Touch layout: 16px of padding instead of 24, a 120px plot instead
        // of 150, and the money-weighted benchmark block behind a
        // tap-to-expand disclosure instead of inline.
        final isPhone = constraints.maxWidth < kCompactCardBelow;
        final pad = isPhone ? 16.0 : 24.0;
        // Short plot on touch-width cards — see the scrub notes on the charts
        // below, which assume the 120px box has no room for a tooltip.
        final chartHeight = isPhone ? 120.0 : 150.0;

        return Card(
          elevation: 4,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
          child: Padding(
            padding: EdgeInsets.all(pad),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.show_chart, color: context.tealAccent, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l.lwPerfTitle,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: context.textPrimary,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 18),
                if (showValue)
                  _valueSection(context, l, chartHeight)
                else
                  Text(
                    l.lwPerfNotEnough,
                    style: TextStyle(color: context.textFaint, fontSize: 12),
                  ),
                if (hasBenchmark) ...[
                  if (showValue) ...[
                    const SizedBox(height: 20),
                    Divider(color: context.hairline, height: 1),
                    const SizedBox(height: 16),
                  ],
                  // The TWR "glance" above always shows. On phones the
                  // money-weighted benchmark detail collapses behind a tap-to-
                  // expand disclosure; on wider screens it stays inline.
                  if (isPhone)
                    _benchmarkDisclosure(context, l, c, invested, lots)
                  else
                    _benchmarkSection(context, l, c, invested, lots),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  /// Phone-only collapsible wrapper around [_benchmarkSection]: a tappable
  /// header (insights icon + title via [bmTitle] + chevron) that reveals the
  /// full money-weighted benchmark block on tap. State is in-memory only.
  Widget _benchmarkDisclosure(
    BuildContext context,
    AppLocalizations l,
    Map<String, dynamic> c,
    double invested,
    int lots,
  ) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _benchmarkExpanded = !_benchmarkExpanded),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(
                  Icons.insights_rounded,
                  color: context.tealAccent,
                  size: 18,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.bmTitle,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: context.textPrimary,
                    ),
                  ),
                ),
                Icon(
                  _benchmarkExpanded
                      ? Icons.expand_less_rounded
                      : Icons.expand_more_rounded,
                  color: context.textMuted,
                  size: 22,
                ),
              ],
            ),
          ),
        ),
        if (_benchmarkExpanded) ...[
          const SizedBox(height: 8),
          // The disclosure header above already shows the icon + title, so
          // suppress the section's own heading (subtitle still leads).
          _benchmarkSection(context, l, c, invested, lots, showHeader: false),
        ],
      ],
    );
  }

  /// [chartHeight] is derived from the card's own `LayoutBuilder` constraint
  /// in `build` and passed down — the plot must size to the card, not the
  /// window (see [kCompactCardBelow]).
  Widget _valueSection(
    BuildContext context,
    AppLocalizations l,
    double chartHeight,
  ) {
    // Headline dollar value: the CURRENT total portfolio value pushed in by
    // the parent (same source as the portfolio hero / holdings total).
    // Falling back to the last history point is a last resort only — after
    // a partial sync that trailing point can cover a subset of accounts.
    final headlineValue =
        widget.totalValueUsd ??
        (_history.isNotEmpty
            ? (_history.last['value_usd'] as num?)?.toDouble() ?? 0.0
            : (_twr?['total_value_usd'] as num?)?.toDouble() ?? 0.0);

    // Preferred: an honest time-weighted return (cashflows divided out) plotted
    // against the S&P 500, both indexed to the range start. This is what lets
    // the performance line finally carry a real return — unlike the dollar
    // line, which ramps from ~0 as accounts sync and so can't be %-ed.
    if (_hasTwr) {
      final twrBody = _twrBody(context, l, chartHeight);
      if (twrBody != null) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // The headline is the current portfolio *value* in dollars — the
            // TWR % (which lwPerfTwrReturn correctly names) lives in the pill
            // below, so captioning this figure "Time-weighted return" was a
            // mislabel. During a touch scrub it stays money (the value on the
            // scrubbed date) with the date as its caption; the returns move
            // in the pills (see _headline / the chart's onScrub).
            _headline(
              context,
              l,
              _money(headlineValue),
              l.rgxPerfPortfolioValue,
              // Spoken value list. The money figure is labelled with the same
              // caption it replaces so the announcement can't be mistaken for
              // a third return — and it's omitted entirely in the fallback
              // case, where the headline IS the return and would otherwise be
              // announced as a "portfolio value".
              scrubValues: (s) => [
                if (s.headlineIsMoney)
                  '${l.rgxPerfPortfolioValue} ${s.headline}',
                '${l.lwPerfTwrYou} ${s.you}',
                '${_benchmarkLabel(l)} ${s.bench}',
              ].join(', '),
            ),
            const SizedBox(height: 14),
            twrBody,
            const SizedBox(height: 8),
            _rangeSelector(),
          ],
        );
      }
    }

    // Fallback: dollars-only line. We deliberately DON'T show a first→last %
    // here — early history ramps from ~0 as accounts first sync, conflating
    // contributions with market gains. The honest return is the TWR (above,
    // when priceable) or the contribution-weighted block below.
    final filtered = _filterByRange(_history);
    // Time-proportional x-axis (decision ported from the instrument sheet): x
    // is the day-offset from the first sample, so a multi-week data gap shows
    // as a wide flat span instead of a single step. `close` carries the
    // already-currency-converted value, so the tooltip reads y directly.
    final valuePoints = <({DateTime date, double close})>[];
    for (final p in filtered) {
      final d = DateTime.tryParse(p['date']?.toString() ?? '');
      if (d == null) continue;
      final v = (p['value_usd'] as num?)?.toDouble() ?? 0.0;
      valuePoints.add((date: d, close: v * widget.conversionFactor));
    }
    final dailyValues = dedupeDailyCloses(valuePoints);
    final spots = dayOffsetSpots(dailyValues);
    final valueX0 = dailyValues.isNotEmpty
        ? dailyValues.first.date
        : DateTime.now().toUtc();
    final valueMaxX = spots.isNotEmpty ? spots.last.x : 0.0;
    final firstV = filtered.isNotEmpty
        ? (filtered.first['value_usd'] as num?)?.toDouble() ?? 0.0
        : 0.0;
    final lastV = filtered.isNotEmpty
        ? (filtered.last['value_usd'] as num?)?.toDouble() ?? 0.0
        : 0.0;
    final color = lastV >= firstV ? context.positive : context.negative;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Same partial-sync guard as the TWR branch: prefer the parent's
        // current total over the (possibly incomplete) last series point.
        _headline(
          context,
          l,
          _money(widget.totalValueUsd ?? lastV),
          l.lwPerfValueSubtitle,
        ),
        const SizedBox(height: 14),
        RepaintBoundary(
          child: SizedBox(
            height: chartHeight,
            child: spots.length < 2
                ? const SizedBox.shrink()
                // Transient tooltip (dismisses on finger lift / pointer
                // exit) — the raw LineChart pinned it on mobile web. On
                // TOUCH it draws no tooltip at all (this box is 120px on
                // phones; nothing fits above a fingertip inside it) — the
                // reading goes to the headline via onScrub, and the guide
                // + dot stay as the position feedback.
                : TransientTooltipLineChart(
                    suppressTooltipOnTouch: true,
                    onScrub: (scrub) {
                      if (scrub == null || !scrub.isTouch) {
                        // Mouse/trackpad keep the in-chart popover; the
                        // header must not react to a hover at all.
                        _setScrub(null);
                        return;
                      }
                      final spot = scrub.spots.first;
                      _setScrub((
                        date: valueX0.add(Duration(days: spot.x.round())),
                        // spot.y already carries conversionFactor.
                        headline: widget.currencyFormat.displayMoney(spot.y),
                        headlineIsMoney: true,
                        you: null,
                        bench: null,
                      ));
                    },
                    data: LineChartData(
                      gridData: const FlGridData(show: false),
                      titlesData: const FlTitlesData(show: false),
                      borderData: FlBorderData(show: false),
                      // The x-axis is now DAY-OFFSET-spaced (ported from the
                      // instrument sheet): the touched spot's own x is days
                      // since `valueX0`, so the date comes from that offset —
                      // an index into `filtered` would be wrong across a gap.
                      lineTouchData: standardLineTouch(
                        context,
                        items: (ctx, touchedSpots) {
                          return touchedSpots.map((spot) {
                            final date = valueX0.add(
                              Duration(days: spot.x.round()),
                            );
                            return LineTooltipItem(
                              '',
                              TextStyle(color: ctx.tooltipOnSurface),
                              children: [
                                TextSpan(
                                  text:
                                      '${DateFormat('MMM d, y').format(date)}\n',
                                  style: TextStyle(
                                    color: ctx.tooltipOnSurfaceMuted,
                                    fontSize: 11,
                                    fontWeight: FontWeight.normal,
                                  ),
                                ),
                                // spot.y already carries conversionFactor
                                // (applied when the spots were built above),
                                // so format directly — _money would double-
                                // convert.
                                TextSpan(
                                  text: widget.currencyFormat.displayMoney(
                                    spot.y,
                                  ),
                                  style: TextStyle(
                                    color: ctx.tooltipOnSurface,
                                    fontWeight: FontWeight.bold,
                                    fontSize: 14,
                                    fontFeatures: const [
                                      FontFeature.tabularFigures(),
                                    ],
                                  ),
                                ),
                              ],
                            );
                          }).toList();
                        },
                      ),
                      minX: 0,
                      maxX: valueMaxX,
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          isCurved: true,
                          curveSmoothness: 0.2,
                          color: color,
                          barWidth: 2.5,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            gradient: LinearGradient(
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                              colors: [
                                color.withValues(alpha: 0.22),
                                color.withValues(alpha: 0.0),
                              ],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 8),
        _rangeSelector(),
      ],
    );
  }

  /// The card's headline figure + caption — and, while a finger is scrubbing
  /// the chart, the scrubbed reading instead.
  ///
  /// This is the whole point of the touch treatment: a 120px-tall chart can't
  /// hold a tooltip that clears the hand, so on touch the chart draws none
  /// (guide + dot only) and the numbers surface HERE, ~200px above the plot.
  /// The figure becomes the scrubbed value and the caption becomes its date
  /// (replacing "Portfolio value") — unmistakable, but the same two lines in
  /// the same place, so nothing jumps. It reverts the instant the finger
  /// lifts, because [ChartScrub] publishes null on release.
  ///
  /// [scrubValues] renders the spoken value list for the screen reader when
  /// the reading carries more than the headline (the TWR chart's two returns).
  Widget _headline(
    BuildContext context,
    AppLocalizations l,
    String liveValue,
    String liveSubtitle, {
    String Function(_ScrubReading scrub)? scrubValues,
  }) {
    return ValueListenableBuilder<_ScrubReading?>(
      valueListenable: _scrub,
      builder: (context, scrub, _) {
        final block = _headlineText(
          context,
          scrub?.headline ?? liveValue,
          scrub == null ? liveSubtitle : _scrubCaption(l, scrub),
        );
        if (scrub == null) return block;
        // The scrubbed readout replaces a tooltip that was already invisible
        // to screen readers, so it has to announce itself: one live region
        // carrying date + values, with the visual text excluded so it isn't
        // read twice.
        // gen-l10n orders these alphabetically → (date, values).
        final label = l.lwChartScrubReading(
          _scrubDate(scrub.date),
          scrubValues?.call(scrub) ?? scrub.headline,
        );
        return Semantics(
          container: true,
          liveRegion: true,
          label: label,
          child: ExcludeSemantics(child: block),
        );
      },
    );
  }

  Widget _headlineText(BuildContext context, String value, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: TextStyle(
            fontSize: 24,
            fontWeight: FontWeight.w800,
            color: context.textPrimary,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: TextStyle(color: context.textFaint, fontSize: 11),
        ),
      ],
    );
  }

  /// Benchmark chip + range segments — side by side when the row has the
  /// width for it, stacked when it doesn't.
  ///
  /// WHY IT STACKS. Content-sized, the two never fit a phone: the chip runs
  /// to ~150px (the widest label is "Mundo (ACWI)") and the five-segment
  /// selector to ~315px, so the pair wants ~465px against ~350px of inner
  /// card on a 390pt phone — it overflowed by 35px there and ~65px at 420
  /// (where the selector's own padding steps up from 10 to 16). Below
  /// [_rangeStackBelow] the chip therefore takes its own line and the
  /// selector goes full-bleed underneath — exactly the case
  /// `DateRangeSelector.fill` documents ("the selector is the only thing on
  /// its line"), and the same touch-width-goes-full-bleed rule the action
  /// buttons settled on. All five segments stay on screen and tappable:
  /// filling splits the width equally, so the narrowest supported card still
  /// gives each segment ~68px at the component's 44dp hit height.
  ///
  /// The width is the INNER `LayoutBuilder` constraint, never
  /// `MediaQuery` — this row lives inside a card whose padding and column
  /// width are not the screen's.
  Widget _rangeSelector() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final stacked = constraints.maxWidth < _rangeStackBelow;
        final selector = DateRangeSelector(
          selectedRange: _range,
          fill: stacked,
          // Content-sized segments tighten their padding on a narrow row —
          // hand the component this row's real width so it doesn't have to
          // ask the screen (and can't, from inside a Row: a non-flex child
          // is laid out unbounded).
          availableWidth: constraints.maxWidth,
          onRangeChanged: (r) {
            // A new window replots the series — drop any scrub reading with
            // it so the header can't keep a value from the old one.
            _setScrub(null);
            setState(() => _range = r);
          },
        );
        if (stacked) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [_benchmarkPicker(), const SizedBox(height: 8), selector],
          );
        }
        // Above the breakpoint the chip is `Flexible` rather than fixed, so
        // even a long benchmark label can only ellipsize — it can never
        // push the selector past the edge again.
        return Row(
          children: [
            Flexible(child: _benchmarkPicker()),
            const Spacer(),
            selector,
          ],
        );
      },
    );
  }

  /// Compact benchmark selector for the range row. Mirrors the segmented
  /// range-pill chrome but collapses to a single tappable chip + popup (five
  /// indices won't fit inline next to the date selector). The selection drives
  /// both the TWR overlay and the contribution comparison.
  Widget _benchmarkPicker() {
    final l = AppLocalizations.of(context);
    return PopupMenuButton<String>(
      tooltip: l.lwPerfBenchPickerTooltip,
      onSelected: _onBenchmarkChanged,
      itemBuilder: (context) => [
        for (final o in _benchmarkOptions)
          PopupMenuItem(
            value: o.key,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: _benchmark == o.key
                      ? Icon(Icons.check, size: 18, color: context.positive)
                      : null,
                ),
                Text(o.shortLabel(l)),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: context.tileSurface,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                _benchmarkLabel(l),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.textMuted,
                  fontWeight: FontWeight.bold,
                  fontSize: 12,
                ),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.expand_more, size: 16, color: context.textMuted),
          ],
        ),
      ),
    );
  }

  /// The TWR return pills + indexed your-vs-S&P chart + coverage caption for
  /// the selected range. Returns null when the range is too short to plot.
  /// [chartHeight] comes from the card's `LayoutBuilder` constraint — see
  /// [_valueSection].
  Widget? _twrBody(
    BuildContext context,
    AppLocalizations l,
    double chartHeight,
  ) {
    final pts = (_twr!['points'] as List).cast<dynamic>();
    var filtered = _filterByRange(pts);
    if (filtered.length < 2) return null;
    // Keep the scene light (canvaskit dislikes thousands of spots).
    filtered = _downsample(filtered, 180);

    // Re-base both series to the range's first point so the return is for the
    // selected window: TWR[a,b] = index(b)/index(a) − 1.
    final baseT = (filtered.first['twr'] as num?)?.toDouble() ?? 1.0;
    final baseS = (filtered.first['sp'] as num?)?.toDouble() ?? 1.0;
    // Time-proportional x-axis: x is the day-offset from the first sample so a
    // gap in the series occupies proportional x-range (ported from the
    // instrument sheet). `spByDay` lets the tooltip recover the benchmark value
    // for the hovered day — an index into `spSpots` breaks once x is an offset.
    DateTime dayOf(dynamic p) {
      final d = DateTime.tryParse(p['date']?.toString() ?? '');
      return d == null
          ? DateTime.utc(2000)
          : DateTime.utc(d.year, d.month, d.day);
    }

    final twrX0 = dayOf(filtered.first);
    final yourSpots = <FlSpot>[];
    final spSpots = <FlSpot>[];
    final spByDay = <int, double>{};
    var twrMaxX = 0.0;
    for (var i = 0; i < filtered.length; i++) {
      final xOff = dayOf(filtered[i]).difference(twrX0).inDays.toDouble();
      final t = (filtered[i]['twr'] as num?)?.toDouble() ?? baseT;
      final s = (filtered[i]['sp'] as num?)?.toDouble() ?? baseS;
      final sy = baseS != 0 ? (s / baseS - 1) * 100 : 0.0;
      yourSpots.add(FlSpot(xOff, baseT != 0 ? (t / baseT - 1) * 100 : 0));
      spSpots.add(FlSpot(xOff, sy));
      spByDay[xOff.round()] = sy;
      if (xOff > twrMaxX) twrMaxX = xOff;
    }
    final yourPct = yourSpots.last.y;
    final spPct = spSpots.last.y;
    final coverage = (_twr!['coverage_pct'] as num?)?.toDouble() ?? 1.0;
    final yourColor = yourPct >= 0 ? context.positive : context.negative;
    String pctText(double p) =>
        '${p >= 0 ? '+' : ''}${formatPercent(context, p, digits: 1)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // The pills are the second half of the scrubbed reading: while a
        // finger is down they show the two returns AT the scrubbed date
        // instead of at the end of the window. Same tiles, same places —
        // only the numbers move (and the pill hue stays keyed to the
        // window's own sign, so the header doesn't flash colors mid-drag).
        ValueListenableBuilder<_ScrubReading?>(
          valueListenable: _scrub,
          builder: (context, scrub, _) => Row(
            children: [
              Expanded(
                child: _twrPill(
                  context,
                  l.lwPerfTwrYou,
                  scrub?.you ?? pctText(yourPct),
                  yourColor,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _twrPill(
                  context,
                  _benchmarkLabel(l),
                  scrub?.bench ?? pctText(spPct),
                  context.info,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 14),
        RepaintBoundary(
          child: SizedBox(
            height: chartHeight,
            // Transient tooltip (dismisses on finger lift / pointer exit) —
            // the raw LineChart kept it pinned on mobile web (prod bug). And
            // on TOUCH there is no in-chart tooltip at all: this box is 120px
            // on phones and the 3-line tooltip is ~64 of them, so even pinned
            // to the top of the box it landed under the fingertip (the owner
            // reported it twice). The reading goes to the header above via
            // onScrub; the guide + dot remain as position feedback.
            child: TransientTooltipLineChart(
              suppressTooltipOnTouch: true,
              onScrub: (scrub) {
                if (scrub == null || !scrub.isTouch) {
                  // Mouse/trackpad: the near-spot popover is unchanged and
                  // the header must not react.
                  _setScrub(null);
                  return;
                }
                // The "you" line is barIndex 1 (S&P is drawn under it) and
                // carries the merged reading, exactly like the tooltip body.
                final spot = scrub.spots.firstWhere(
                  (s) => s.barIndex == 1,
                  orElse: () => scrub.spots.first,
                );
                final day = spot.x.round();
                final date = twrX0.add(Duration(days: day));
                final youText = pctText(spot.y);
                // The headline stays MONEY through the scrub — the portfolio
                // value on the scrubbed date, looked up BY DATE (this series
                // is separately range-filtered and downsampled, so an index
                // into it wouldn't line up). The returns are already in the
                // two pills; replacing the dollar total with a third
                // percentage left the card showing no money at all exactly
                // while it was being interrogated. The lookup prefers the TWR
                // payload's own daily valuation, which covers every plotted
                // date — `_history` alone covered only the last few weeks of
                // a chart spanning years (see `_twrPointValueDays`).
                final valueUsd = _valueUsdOn(date);
                _setScrub((
                  date: date,
                  // Still no resolvable value for that date → show the return
                  // rather than a wrong or zero amount, and let `_headline`
                  // caption it as a return so the swap isn't silent.
                  headline: valueUsd == null ? youText : _money(valueUsd),
                  headlineIsMoney: valueUsd != null,
                  you: youText,
                  bench: pctText(spByDay[day] ?? 0.0),
                ));
              },
              data: LineChartData(
                gridData: const FlGridData(show: false),
                titlesData: const FlTitlesData(show: false),
                borderData: FlBorderData(show: false),
                // Day-offset x (same convention as the value chart): the
                // hovered spot's x is days since `twrX0`, so the date comes
                // from that offset and the benchmark value from `spByDay` —
                // indexing into `filtered`/`spSpots` breaks across a gap. One
                // merged tooltip body on the "you" bar (barIndex 1) carrying
                // both series; the benchmark bar returns null (net-worth's
                // only-one-body pattern).
                lineTouchData: standardLineTouch(
                  context,
                  items: (ctx, touchedSpots) {
                    return touchedSpots.map((spot) {
                      if (spot.barIndex != 1) return null;
                      final day = spot.x.round();
                      final date = twrX0.add(Duration(days: day));
                      final benchY = spByDay[day] ?? 0.0;
                      return LineTooltipItem(
                        '',
                        TextStyle(color: ctx.tooltipOnSurface),
                        children: [
                          TextSpan(
                            text: '${DateFormat('MMM d, y').format(date)}\n',
                            style: TextStyle(
                              color: ctx.tooltipOnSurfaceMuted,
                              fontSize: 11,
                              fontWeight: FontWeight.normal,
                            ),
                          ),
                          TextSpan(
                            text: '${l.lwPerfTwrYou} ${pctText(spot.y)}\n',
                            style: TextStyle(
                              color: spot.y >= 0
                                  ? ctx.tooltipPositive
                                  : ctx.tooltipNegative,
                              fontWeight: FontWeight.bold,
                              fontSize: 13,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          TextSpan(
                            text: '${_benchmarkLabel(l)} ${pctText(benchY)}',
                            style: TextStyle(
                              color: ctx.tooltipOnSurfaceMuted,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                        ],
                      );
                    }).toList();
                  },
                ),
                minX: 0,
                maxX: twrMaxX,
                lineBarsData: [
                  // S&P first (drawn under), dashed + muted.
                  LineChartBarData(
                    spots: spSpots,
                    isCurved: true,
                    curveSmoothness: 0.2,
                    color: context.info.withValues(alpha: 0.7),
                    barWidth: 2,
                    dashArray: const [5, 4],
                    dotData: const FlDotData(show: false),
                  ),
                  LineChartBarData(
                    spots: yourSpots,
                    isCurved: true,
                    curveSmoothness: 0.2,
                    color: yourColor,
                    barWidth: 2.5,
                    dotData: const FlDotData(show: false),
                    belowBarData: BarAreaData(
                      show: true,
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          yourColor.withValues(alpha: 0.18),
                          yourColor.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        // Spell out the method so this number reads as distinct from the
        // money-weighted "Investments vs S&P 500" block below — they use
        // different math and windows and are not meant to agree.
        Text(
          l.lwPerfTwrMethodNote,
          style: TextStyle(color: context.textFaint, fontSize: 11),
        ),
        if (coverage < _twrValueCoverageFloor) ...[
          const SizedBox(height: 4),
          Text(
            l.lwPerfTwrCoverage(
              formatPercent(context, coverage * 100, digits: 0),
            ),
            style: TextStyle(color: context.textFaint, fontSize: 11),
          ),
        ],
      ],
    );
  }

  /// One return tile. Takes the percentage ALREADY formatted (via the
  /// caller's `pctText`, i.e. `utils/percent_format.dart` plus the explicit
  /// sign) so the same tile can render either the window's return or the
  /// scrubbed one without duplicating the formatting rule.
  Widget _twrPill(
    BuildContext context,
    String label,
    String pctText,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(color: context.textSubtle, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            pctText,
            style: TextStyle(
              color: color,
              fontSize: 20,
              fontWeight: FontWeight.bold,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  /// Stride-sample a list down to at most [maxPoints], always keeping the last.
  List<dynamic> _downsample(List<dynamic> data, int maxPoints) {
    if (data.length <= maxPoints) return data;
    final step = data.length / maxPoints;
    final out = <dynamic>[];
    for (var i = 0; i < maxPoints; i++) {
      out.add(data[(i * step).floor()]);
    }
    if (!identical(out.last, data.last)) out.add(data.last);
    return out;
  }

  Widget _benchmarkSection(
    BuildContext context,
    AppLocalizations l,
    Map<String, dynamic> c,
    double invested,
    int lots, {
    // When rendered inside the phone disclosure the tappable header already
    // shows the icon + title, so skip the section's own heading to avoid a
    // duplicated title; the subtitle still leads the revealed content.
    bool showHeader = true,
  }) {
    final yourVal = (c['your_value_usd'] as num?)?.toDouble() ?? 0;
    final benchVal = (c['benchmark_value_usd'] as num?)?.toDouble() ?? 0;
    final youPct = (yourVal / invested - 1) * 100;
    final benchPct = (benchVal / invested - 1) * 100;
    final deltaPts = youPct - benchPct;
    final ahead = deltaPts >= 0;
    final maxVal = (yourVal > benchVal ? yourVal : benchVal).clamp(
      1,
      double.infinity,
    );
    final benchLabel = _benchmarkLabel(l);
    String pct(double p) =>
        '${p >= 0 ? '+' : ''}${formatPercent(context, p, digits: 1)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (showHeader) ...[
          Row(
            children: [
              Icon(Icons.insights_rounded, color: context.tealAccent, size: 18),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.bmTitle,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: context.textPrimary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
        ],
        Text(
          l.bmSubtitle,
          style: TextStyle(color: context.textFaint, fontSize: 11),
        ),
        const SizedBox(height: 4),
        // Comprehension caveat: this money-weighted % covers recorded lots
        // only and is dominated by recent purchases, so it legitimately sits
        // far below the all-time TWR pill above — spell that out to prevent
        // the double-take.
        Text(
          l.bmContribCaveat,
          style: TextStyle(color: context.textFaint, fontSize: 11),
        ),
        const SizedBox(height: 18),
        Row(
          children: [
            Expanded(
              child: _returnTile(
                context,
                l.bmContribYou,
                pct(youPct),
                _money(yourVal),
                context.positive,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _returnTile(
                context,
                benchLabel,
                pct(benchPct),
                _money(benchVal),
                context.info,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _bar(
          context,
          l.bmContribYou,
          yourVal,
          maxVal.toDouble(),
          context.positive,
        ),
        const SizedBox(height: 8),
        _bar(context, benchLabel, benchVal, maxVal.toDouble(), context.info),
        const SizedBox(height: 14),
        Text(
          ahead
              ? l.bmAheadPts(deltaPts.abs().toStringAsFixed(1))
              : l.bmBehindPts(deltaPts.abs().toStringAsFixed(1)),
          style: TextStyle(
            color: ahead ? context.positive : context.textMuted,
            fontWeight: FontWeight.w600,
            fontSize: 12.5,
          ),
        ),
        const SizedBox(height: 4),
        _contribNoteLine(context, l, c, invested, lots),
      ],
    );
  }

  /// The "{n} purchases · {amount} invested" footer. When the payload carries
  /// the per-symbol breakdown (`symbols`), the whole line becomes a tap target
  /// (with a visible "see what's tracked" affordance) that opens the
  /// [TrackedLotsSheet] drill-down; on an older backend without the additive
  /// fields it stays the plain caption.
  Widget _contribNoteLine(
    BuildContext context,
    AppLocalizations l,
    Map<String, dynamic> c,
    double invested,
    int lots,
  ) {
    // gen-l10n orders these alphabetically → (count, invested).
    final note = Text(
      l.bmContribNote(lots, _money(invested)),
      style: TextStyle(color: context.textFaint, fontSize: 11),
    );

    final breakdown = TrackedLotsBreakdown.parse(c);
    if (breakdown.isEmpty) return note;

    // MergeSemantics: the note + affordance + chevron announce as ONE button
    // ("118 purchases · $103,436 invested, See what's tracked") with the hint.
    return MergeSemantics(
      child: Semantics(
        button: true,
        hint: l.bmSheetTapHint,
        child: InkWell(
          onTap: () => _openTrackedLotsSheet(breakdown),
          borderRadius: BorderRadius.circular(8),
          child: Container(
            // Comfortable tap target (≥ 44 px) for an otherwise-caption line.
            constraints: const BoxConstraints(minHeight: 44),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Expanded(child: note),
                const SizedBox(width: 8),
                Text(
                  l.bmSeeTracked,
                  style: TextStyle(
                    color: context.tealAccent,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  size: 16,
                  color: context.tealAccent,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Opens the "What's tracked" bottom sheet (same chrome as the dividend
  /// detail sheet). The breakdown is already in hand from the comparison
  /// payload, so the sheet fetches nothing.
  Future<void> _openTrackedLotsSheet(TrackedLotsBreakdown breakdown) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => TrackedLotsSheet(
        breakdown: breakdown,
        conversionFactor: widget.conversionFactor,
        currencyFormat: widget.currencyFormat,
      ),
    );
  }

  Widget _returnTile(
    BuildContext context,
    String label,
    String pct,
    String value,
    Color color,
  ) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(color: context.textSubtle, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Text(
            pct,
            style: TextStyle(
              color: color,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              color: context.textFaint,
              fontSize: 11,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bar(
    BuildContext context,
    String label,
    double value,
    double max,
    Color color,
  ) {
    final frac = (value / max).clamp(0.0, 1.0);
    return Row(
      children: [
        SizedBox(
          width: 86,
          child: Text(
            label,
            style: TextStyle(color: context.textMuted, fontSize: 11),
          ),
        ),
        Expanded(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: Stack(
              children: [
                Container(height: 14, color: context.tileSurface),
                FractionallySizedBox(
                  widthFactor: frac,
                  child: Container(height: 14, color: color),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(width: 10),
        Text(
          _money(value),
          style: TextStyle(
            color: context.textSubtle,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            fontFeatures: const [FontFeature.tabularFigures()],
          ),
        ),
      ],
    );
  }
}
