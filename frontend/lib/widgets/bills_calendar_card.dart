import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/chart_time_axis.dart';
import '../utils/chart_touch.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';
import 'connected_segments.dart';

/// One expected occurrence from `/api/recurring/calendar` — a recurring
/// rule expansion or a loan schedule due, with its matched/paid state.
class BillOccurrence {
  final String source; // 'recurring' | 'loan'
  final String description;
  final String? accountName;
  final double amount; // native, signed (negative = outflow)
  final String currency;
  final double amountUsd;
  final DateTime dueDate;
  final String state; // paid|upcoming|late|missed|pending_import

  const BillOccurrence({
    required this.source,
    required this.description,
    required this.accountName,
    required this.amount,
    required this.currency,
    required this.amountUsd,
    required this.dueDate,
    required this.state,
  });

  static BillOccurrence? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final due = DateTime.tryParse((raw['due_date'] ?? '').toString());
    if (due == null) return null;
    return BillOccurrence(
      source: (raw['source'] ?? 'recurring').toString(),
      description: (raw['description'] ?? '').toString(),
      accountName: raw['account_name']?.toString(),
      amount: (raw['amount'] as num?)?.toDouble() ?? 0.0,
      currency: (raw['currency'] ?? 'USD').toString(),
      amountUsd: (raw['amount_usd'] as num?)?.toDouble() ?? 0.0,
      dueDate: DateTime.utc(due.year, due.month, due.day),
      state: (raw['state'] ?? 'upcoming').toString(),
    );
  }
}

/// Marker/dot color for an occurrence state — the semantic accents only
/// (all AA-checked per brightness).
///
/// `pending_import` is deliberately the WARNING amber, never the error
/// red: on a manual statement-import account the app cannot distinguish
/// "missed" from "not yet imported", and a false red destroys trust
/// (FUTURE.md hard requirement — pinned by a widget test).
Color billStateColor(BuildContext context, String state) {
  switch (state) {
    case 'paid':
      return context.positive;
    case 'late':
    case 'missed':
      return context.negative;
    case 'pending_import':
      return context.warning;
    default: // upcoming
      return context.info;
  }
}

/// Localized short label for a state chip.
String billStateLabel(AppLocalizations l, String state) {
  switch (state) {
    case 'paid':
      return l.bcStatePaid;
    case 'late':
      return l.bcStateLate;
    case 'missed':
      return l.bcStateMissed;
    case 'pending_import':
      return l.bcStatePendingImport;
    default:
      return l.bcStateUpcoming;
  }
}

/// Dot-priority order for a day cell (most urgent first): the cell shows
/// at most three dots, so red must never be crowded out by green.
const List<String> _statePriority = [
  'missed',
  'late',
  'pending_import',
  'upcoming',
  'paid',
];

/// Bills calendar + 1–90-day projected balances (cash-flow tab).
///
/// Self-fetching off `/api/recurring/calendar` (the SpendingByCategoryCard
/// pattern): a compact month grid with per-day state markers, a tap-to-see
/// agenda for the selected day, the per-currency projected cash curve
/// (USD / MXN toggle), and an informational FX-transfer prompt when the
/// backend projects one currency running dry while the other stays
/// positive. Renders nothing while loading or when there are no expected
/// occurrences at all.
class BillsCalendarCard extends StatefulWidget {
  final ApiService apiService;

  /// Forward/backward horizon in days (backend clamps to 1..90).
  final int days;

  /// Injectable "today" for deterministic tests; defaults to the backend's
  /// own `today` field (server-authoritative), then DateTime.now().
  final DateTime? now;

  /// When the identity of this object changes the card refetches — the
  /// dashboard passes its recurring-rules list so a rule mutation
  /// (create/pause/delete) refreshes the calendar too.
  final Object? refreshKey;

  const BillsCalendarCard({
    super.key,
    required this.apiService,
    this.days = 30,
    this.now,
    this.refreshKey,
  });

  @override
  State<BillsCalendarCard> createState() => _BillsCalendarCardState();
}

class _BillsCalendarCardState extends State<BillsCalendarCard> {
  bool _loading = true;
  Map<String, dynamic>? _data;
  List<BillOccurrence> _occurrences = const [];
  DateTime? _selectedDay;
  DateTime? _visibleMonth; // first day of the shown month (UTC)
  String _currency = 'USD';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(BillsCalendarCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.refreshKey, oldWidget.refreshKey)) {
      _load(forceRefresh: true);
    }
  }

  DateTime get _today {
    final injected = widget.now;
    if (injected != null) {
      return DateTime.utc(injected.year, injected.month, injected.day);
    }
    final server = DateTime.tryParse((_data?['today'] ?? '').toString());
    final t = server ?? DateTime.now();
    return DateTime.utc(t.year, t.month, t.day);
  }

  Future<void> _load({bool forceRefresh = false}) async {
    setState(() => _loading = true);
    try {
      final data = await widget.apiService.getRecurringCalendar(
        days: widget.days,
        forceRefresh: forceRefresh,
      );
      if (!mounted) return;
      setState(() {
        _data = data;
        _occurrences = ((data['occurrences'] as List?) ?? const [])
            .map(BillOccurrence.tryParse)
            .whereType<BillOccurrence>()
            .toList();
        final today = _today;
        _selectedDay ??= today;
        _visibleMonth ??= DateTime.utc(today.year, today.month);
      });
    } catch (_) {
      // Leave _data null — the card stays hidden rather than erroring the
      // whole cash-flow tab.
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  // ---------- window helpers ----------

  DateTime? _parseDay(String key) {
    final d = DateTime.tryParse((_data?[key] ?? '').toString());
    return d == null ? null : DateTime.utc(d.year, d.month, d.day);
  }

  Map<DateTime, List<BillOccurrence>> get _byDay {
    final out = <DateTime, List<BillOccurrence>>{};
    for (final o in _occurrences) {
      out.putIfAbsent(o.dueDate, () => []).add(o);
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    if (_loading && _data == null) return const SizedBox.shrink();
    final data = _data;
    if (data == null || _occurrences.isEmpty) return const SizedBox.shrink();

    final l = AppLocalizations.of(context);
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        // Width-responsive off the card's OWN constraint (inner
        // LayoutBuilder, per the skill rule), not MediaQuery.
        child: LayoutBuilder(
          builder: (context, c) {
            final isPhone = c.maxWidth < 420;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    if (!isPhone) ...[
                      Icon(
                        Icons.event_available_rounded,
                        color: context.info,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                    ],
                    Expanded(
                      child: Text(
                        isPhone ? l.bcTitle.toUpperCase() : l.bcTitle,
                        style: isPhone
                            ? TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.6,
                                color: context.textSubtle,
                              )
                            : TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: context.textPrimary,
                              ),
                        maxLines: isPhone ? 1 : null,
                        overflow: isPhone ? TextOverflow.ellipsis : null,
                      ),
                    ),
                  ],
                ),
                SizedBox(height: isPhone ? 12 : 16),
                _monthHeader(context, l),
                const SizedBox(height: 8),
                _weekdayHeader(context, l),
                const SizedBox(height: 4),
                _monthGrid(context, l),
                const SizedBox(height: 8),
                _legend(context, l),
                const SizedBox(height: 12),
                _agenda(context, l),
                SizedBox(height: isPhone ? 16 : 20),
                _projectionSection(context, l, c.maxWidth),
              ],
            );
          },
        ),
      ),
    );
  }

  // ---------- month grid ----------

  Widget _monthHeader(BuildContext context, AppLocalizations l) {
    final month = _visibleMonth ?? DateTime.utc(_today.year, _today.month);
    final from = _parseDay('from');
    final to = _parseDay('to');
    final prevMonth = DateTime.utc(month.year, month.month - 1);
    final nextMonth = DateTime.utc(month.year, month.month + 1);
    // Chevrons clamp to months intersecting the fetched window: the last
    // day of the previous month must be on/after `from`, the first day of
    // the next on/before `to`.
    final canPrev =
        from == null ||
        !DateTime.utc(month.year, month.month, 0).isBefore(from);
    final canNext = to == null || !nextMonth.isAfter(to);
    final locale = l.localeName;
    return Row(
      children: [
        IconButton(
          tooltip: l.bcPrevMonth,
          icon: const Icon(Icons.chevron_left),
          onPressed: canPrev
              ? () => setState(() => _visibleMonth = prevMonth)
              : null,
          visualDensity: VisualDensity.compact,
        ),
        Expanded(
          child: Text(
            toBeginningOfSentenceCase(DateFormat.yMMMM(locale).format(month)),
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w700,
              color: context.textPrimary,
            ),
          ),
        ),
        IconButton(
          tooltip: l.bcNextMonth,
          icon: const Icon(Icons.chevron_right),
          onPressed: canNext
              ? () => setState(() => _visibleMonth = nextMonth)
              : null,
          visualDensity: VisualDensity.compact,
        ),
      ],
    );
  }

  Widget _weekdayHeader(BuildContext context, AppLocalizations l) {
    final firstDayIndex = MaterialLocalizations.of(
      context,
    ).firstDayOfWeekIndex; // 0 = Sunday
    final narrow = DateFormat('EEEEE', l.localeName);
    // 2024-01-07 is a Sunday; offset from it to label each column.
    final sunday = DateTime.utc(2024, 1, 7);
    return Row(
      children: [
        for (var i = 0; i < 7; i++)
          Expanded(
            child: Center(
              child: Text(
                narrow
                    .format(sunday.add(Duration(days: firstDayIndex + i)))
                    .toUpperCase(),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: context.textFaint,
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _monthGrid(BuildContext context, AppLocalizations l) {
    final month = _visibleMonth ?? DateTime.utc(_today.year, _today.month);
    final firstDayIndex = MaterialLocalizations.of(
      context,
    ).firstDayOfWeekIndex; // 0 = Sunday
    final first = DateTime.utc(month.year, month.month, 1);
    final daysInMonth = DateTime.utc(month.year, month.month + 1, 0).day;
    // DateTime.weekday: 1 = Monday .. 7 = Sunday → 0 = Sunday index space.
    final leading = ((first.weekday % 7) - firstDayIndex + 7) % 7;
    final byDay = _byDay;
    final from = _parseDay('from');
    final to = _parseDay('to');

    final cells = <Widget>[];
    for (var i = 0; i < leading; i++) {
      cells.add(const Expanded(child: SizedBox(height: 44)));
    }
    for (var day = 1; day <= daysInMonth; day++) {
      final date = DateTime.utc(month.year, month.month, day);
      final inWindow =
          (from == null || !date.isBefore(from)) &&
          (to == null || !date.isAfter(to));
      cells.add(
        Expanded(child: _dayCell(context, l, date, byDay[date], inWindow)),
      );
    }
    while (cells.length % 7 != 0) {
      cells.add(const Expanded(child: SizedBox(height: 44)));
    }

    return Column(
      children: [
        for (var row = 0; row < cells.length ~/ 7; row++)
          Row(children: cells.sublist(row * 7, row * 7 + 7)),
      ],
    );
  }

  Widget _dayCell(
    BuildContext context,
    AppLocalizations l,
    DateTime date,
    List<BillOccurrence>? items,
    bool inWindow,
  ) {
    final isToday = date == _today;
    final isSelected = date == _selectedDay;
    final count = items?.length ?? 0;
    // At most three dots, urgency-first so red never gets crowded out.
    final states = <String>[];
    if (items != null) {
      for (final s in _statePriority) {
        if (states.length >= 3) break;
        if (items.any((o) => o.state == s)) states.add(s);
      }
    }

    final dateLabel = DateFormat.yMMMd(l.localeName).format(date);
    return Semantics(
      // Explicit placeholders metadata → gen-l10n follows DECLARATION
      // order, pinned to template order by the l10n conventions test:
      // (date, count).
      label: l.bcDaySem(dateLabel, count),
      button: inWindow,
      selected: isSelected,
      excludeSemantics: true,
      container: true,
      child: InkWell(
        key: ValueKey('bc-day-${date.toIso8601String().substring(0, 10)}'),
        borderRadius: BorderRadius.circular(10),
        onTap: inWindow ? () => setState(() => _selectedDay = date) : null,
        child: Container(
          height: 44,
          margin: const EdgeInsets.all(1),
          decoration: isSelected
              ? BoxDecoration(
                  color: context.tileSurface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: context.accentBorder(context.info),
                    width: 1.5,
                  ),
                )
              : isToday
              ? BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: context.hairline),
                )
              : null,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '${date.day}',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isToday || isSelected
                      ? FontWeight.w700
                      : FontWeight.w400,
                  color: !inWindow
                      ? context.textFaint
                      : isToday
                      ? context.info
                      : context.textPrimary,
                ),
              ),
              SizedBox(
                height: 7,
                child: states.isEmpty
                    ? null
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0; i < states.length; i++) ...[
                            if (i > 0) const SizedBox(width: 2),
                            Container(
                              width: 5,
                              height: 5,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: billStateColor(context, states[i]),
                              ),
                            ),
                          ],
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _legend(BuildContext context, AppLocalizations l) {
    Widget item(String state, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: billStateColor(context, state),
          ),
        ),
        const SizedBox(width: 4),
        Text(label, style: TextStyle(fontSize: 10, color: context.textMuted)),
      ],
    );
    return Wrap(
      spacing: 12,
      runSpacing: 4,
      children: [
        item('paid', l.bcStatePaid),
        item('upcoming', l.bcStateUpcoming),
        item('missed', l.bcStateMissed),
        item('pending_import', l.bcStatePendingImport),
      ],
    );
  }

  // ---------- agenda for the selected day ----------

  Widget _agenda(BuildContext context, AppLocalizations l) {
    final selected = _selectedDay ?? _today;
    final items = (_byDay[selected] ?? const <BillOccurrence>[]).toList()
      ..sort((a, b) => a.description.compareTo(b.description));
    if (items.isEmpty) {
      return Text(
        l.bcNothingDue,
        style: TextStyle(fontSize: 12, color: context.textFaint),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [for (final o in items) _agendaRow(context, l, o)],
    );
  }

  Widget _agendaRow(
    BuildContext context,
    AppLocalizations l,
    BillOccurrence o,
  ) {
    final color = billStateColor(context, o.state);
    final isPending = o.state == 'pending_import';
    final title = o.source == 'loan'
        ? l.bcLoanRepayment(o.description)
        : o.description;
    final subtitleParts = <String>[
      if (o.accountName != null && o.accountName!.isNotEmpty) o.accountName!,
      if (isPending) l.bcAwaitingImport,
    ];

    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(shape: BoxShape.circle, color: color),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: context.textPrimary,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitleParts.isNotEmpty)
                  Text(
                    subtitleParts.join(' · '),
                    style: TextStyle(
                      fontSize: 11,
                      // The pending-import subtitle carries the muted amber
                      // of its state — visually distinct from the red
                      // late/missed treatment on purpose.
                      color: isPending ? color : context.textMuted,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                formatCurrencyWithCode(o.amount, o.currency),
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: o.amount > 0 ? context.positive : context.textPrimary,
                ),
              ),
              Text(
                billStateLabel(l, o.state),
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: color,
                ),
              ),
            ],
          ),
        ],
      ),
    );

    // "Awaiting statement import" gets the full explanation on hover/
    // long-press so the muted amber never reads as an unexplained warning.
    return isPending
        ? Tooltip(message: l.bcAwaitingImportHint, child: row)
        : row;
  }

  // ---------- projected balances ----------

  Widget _projectionSection(
    BuildContext context,
    AppLocalizations l,
    double width,
  ) {
    final projection = ((_data?['projection'] as List?) ?? const [])
        .whereType<Map>()
        .toList();
    if (projection.length < 2) return const SizedBox.shrink();

    final points = <({DateTime date, double close})>[];
    for (final p in projection) {
      final d = DateTime.tryParse((p['date'] ?? '').toString());
      if (d == null) continue;
      final v = (p[_currency == 'MXN' ? 'mxn' : 'usd'] as num?)?.toDouble();
      if (v == null) continue;
      points.add((date: DateTime.utc(d.year, d.month, d.day), close: v));
    }
    if (points.length < 2) return const SizedBox.shrink();

    final fx = _data?['fx_transfer_suggestion'];
    final money = moneyFormat(_currency);
    final days = (_data?['days'] as num?)?.toInt() ?? widget.days;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.bcProjectedBalances,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: context.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          l.bcProjectedCaption(days),
          style: TextStyle(fontSize: 11, color: context.textMuted),
        ),
        const SizedBox(height: 12),
        ConnectedSegments<String>(
          segments: const [
            ConnectedSegment(value: 'USD', label: 'USD'),
            ConnectedSegment(value: 'MXN', label: 'MXN'),
          ],
          selected: _currency,
          onSelected: (v) {
            if (v != _currency) setState(() => _currency = v);
          },
        ),
        const SizedBox(height: 12),
        if (fx is Map) _fxBanner(context, l, fx),
        // Chart data mirrored into the semantics tree (custom-painted
        // charts are pointer-only); the canvas itself is excluded.
        Semantics(
          container: true,
          // Explicit placeholders metadata → gen-l10n follows DECLARATION
          // order, pinned to template order by the l10n conventions test:
          // (currency, start, end).
          label: l.bcProjectionSem(
            _currency,
            money.displayMoney(points.first.close),
            money.displayMoney(points.last.close),
          ),
          child: ExcludeSemantics(
            child: SizedBox(
              height: 180,
              child: _projectionChart(context, points, money, width),
            ),
          ),
        ),
      ],
    );
  }

  Widget _fxBanner(BuildContext context, AppLocalizations l, Map fx) {
    final deficit = (fx['deficit_currency'] ?? '').toString();
    final surplus = (fx['surplus_currency'] ?? '').toString();
    final rawDate = DateTime.tryParse((fx['date'] ?? '').toString());
    final dateLabel = rawDate == null
        ? (fx['date'] ?? '').toString()
        : DateFormat.MMMd(l.localeName).format(rawDate);
    final shortfall = (fx['shortfall'] as num?)?.toDouble() ?? 0.0;
    return Container(
      key: const ValueKey('bc-fx-banner'),
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: context.accentSoft(context.info),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.accentBorder(context.info)),
      ),
      child: Row(
        children: [
          Icon(Icons.swap_horiz_rounded, size: 18, color: context.info),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              // Explicit placeholders metadata → gen-l10n follows
              // DECLARATION order, pinned to template order by the l10n
              // conventions test: (surplus, deficit, date, amount).
              l.bcFxPrompt(
                surplus,
                deficit,
                dateLabel,
                formatCurrencyWithCode(shortfall, deficit),
              ),
              style: TextStyle(fontSize: 12, color: context.textPrimary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _projectionChart(
    BuildContext context,
    List<({DateTime date, double close})> rawPoints,
    NumberFormat money,
    double width,
  ) {
    final points = dedupeDailyCloses(rawPoints);
    final spots = dayOffsetSpots(points);
    final first = points.first.date;
    final spanDays = points.last.date.difference(first).inDays;
    final interval = dayOffsetTickInterval(spanDays);
    final tickDates = <DateTime>[
      for (var x = 0.0; x <= spanDays; x += interval)
        first.add(Duration(days: x.round())),
    ];
    final tickFormat = nonRepeatingDateFormat(tickDates, spanDays: spanDays);
    final lineColor = _currency == 'MXN' ? context.tealAccent : context.info;
    // House compact money ticks. `NumberFormat.compactSimpleCurrency` maps MXN
    // to its LOCAL symbol "$", so a peso projection was labelled "$100K" and
    // read as USD at a glance; `compactMoney` pairs the house glyph
    // ("MXN 100K") with a locale-aware magnitude (see utils/currency.dart).
    final tickCurrency = money.currencyName ?? _currency;
    final closes = [for (final s in spots) s.y];
    final tickMin = closes.reduce(math.min);
    final tickMax = closes.reduce(math.max);

    return TransientTooltipLineChart(
      data: LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (v) => FlLine(
            // The zero line is the whole point of this chart — make it
            // legible against the ordinary gridlines.
            color: v == 0 ? context.textFaint : context.hairline,
            strokeWidth: v == 0 ? 1.5 : 1,
          ),
        ),
        borderData: FlBorderData(show: false),
        titlesData: FlTitlesData(
          rightTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          topTitles: const AxisTitles(
            sideTitles: SideTitles(showTitles: false),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              // Fit the box to the widest tick this range can produce in this
              // currency — the wider "MXN " prefix wraps or clips a fixed 46.
              reservedSize: compactMoneyAxisWidth(
                tickMin,
                tickMax,
                tickCurrency,
                fontSize: 9,
              ),
              getTitlesWidget: (value, meta) {
                if (value <= meta.min || value >= meta.max) {
                  return const SizedBox.shrink();
                }
                return Text(
                  compactMoney(value, tickCurrency),
                  style: TextStyle(color: context.textSubtle, fontSize: 9),
                );
              },
            ),
          ),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 24,
              interval: interval,
              getTitlesWidget: (value, meta) {
                final d = first.add(Duration(days: value.round()));
                return SideTitleWidget(
                  meta: meta,
                  child: Text(
                    tickFormat.format(d),
                    style: TextStyle(color: context.textSubtle, fontSize: 9),
                  ),
                );
              },
            ),
          ),
        ),
        lineTouchData: standardLineTouch(
          context,
          items: (ctx, touchedSpots) => touchedSpots.map((s) {
            final d = first.add(Duration(days: s.x.round()));
            return LineTooltipItem(
              '${DateFormat.MMMd(AppLocalizations.of(ctx).localeName).format(d)}\n'
              '${money.displayMoney(s.y)}',
              TextStyle(
                color: ctx.tooltipOnSurface,
                fontWeight: FontWeight.bold,
              ),
            );
          }).toList(),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: spots,
            isCurved: false,
            color: lineColor,
            barWidth: 2,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              color: lineColor.withValues(alpha: 0.08),
            ),
          ),
        ],
      ),
    );
  }
}
