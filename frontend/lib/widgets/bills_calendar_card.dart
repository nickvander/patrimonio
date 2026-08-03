import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/preferences.dart';
import '../utils/chart_time_axis.dart';
import '../utils/chart_touch.dart';
import '../utils/currency.dart';
import '../utils/theme_colors.dart';
import 'connected_segments.dart';

/// One expected occurrence from `/api/recurring/calendar` — a recurring
/// rule expansion, a loan schedule due, or a detector-inferred cluster,
/// with its matched/paid state.
class BillOccurrence {
  /// `'recurring'` (an explicit `recurring_rules` expansion — the backend
  /// deliberately kept that literal rather than `'rule'`), `'loan'` (a
  /// loan_payments due), or `'detected'` (a `subscription_detect` cluster
  /// projected forward, i.e. INFERRED from transaction history rather than
  /// declared by the user).
  final String source;
  final String description;
  final String? accountName;
  final double amount; // native, signed (negative = outflow)
  final String currency;
  final double amountUsd;
  final DateTime dueDate;
  final String state; // paid|upcoming|late|missed|pending_import

  /// Detected occurrences only: the exact key
  /// `POST /api/dashboard/subscriptions/ignore` expects, so "not a bill"
  /// can be actioned from the agenda without re-deriving the detector's
  /// normalisation. Null for rules and loans.
  final String? merchantKey;

  const BillOccurrence({
    required this.source,
    required this.description,
    required this.accountName,
    required this.amount,
    required this.currency,
    required this.amountUsd,
    required this.dueDate,
    required this.state,
    this.merchantKey,
  });

  /// Inferred rather than declared — drives the distinct marker treatment
  /// and the "Detected charges" toggle.
  bool get isDetected => source == 'detected';

  static BillOccurrence? tryParse(dynamic raw) {
    if (raw is! Map) return null;
    final due = DateTime.tryParse((raw['due_date'] ?? '').toString());
    if (due == null) return null;
    final key = raw['merchant_key']?.toString();
    return BillOccurrence(
      source: (raw['source'] ?? 'recurring').toString(),
      description: (raw['description'] ?? '').toString(),
      accountName: raw['account_name']?.toString(),
      amount: (raw['amount'] as num?)?.toDouble() ?? 0.0,
      currency: (raw['currency'] ?? 'USD').toString(),
      amountUsd: (raw['amount_usd'] as num?)?.toDouble() ?? 0.0,
      dueDate: DateTime.utc(due.year, due.month, due.day),
      state: (raw['state'] ?? 'upcoming').toString(),
      merchantKey: (key == null || key.isEmpty) ? null : key,
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

/// State dot for the grid / agenda / legend.
///
/// **Shape carries the source, color carries the state.** A declared
/// occurrence (an explicit rule or a loan due) is a FILLED disc; a
/// detector-inferred one is a hollow RING of the same accent. That keeps
/// the inferred/declared distinction readable without relying on color at
/// all — which matters here because color is already spent on
/// paid/upcoming/late/pending-import, and because "we guessed this" is a
/// claim the UI must not make silently. The agenda pairs the ring with an
/// icon + "Detected" label; the legend explains the ring.
///
/// [size] is the DECLARED disc's diameter; a detected ring is drawn
/// [kBillDetectedSizeBoost] wider at a [kBillDetectedRingStroke] stroke —
/// see those constants for why the ring is not simply the same box.
Widget billStateDot(
  BuildContext context, {
  required String state,
  required bool detected,
  double size = 7,
}) {
  final color = billStateColor(context, state);
  final diameter = detected ? size + kBillDetectedSizeBoost : size;
  return Container(
    width: diameter,
    height: diameter,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      color: detected ? null : color,
      border: detected
          ? Border.all(color: color, width: kBillDetectedRingStroke)
          : null,
    ),
  );
}

/// Stroke of the hollow detected ring, and how much wider it is drawn than
/// the filled disc it stands beside.
///
/// The grid marker was a 6px circle with a 1.5px border — a 3px hole and a
/// hairline stroke, which the 2026-08-03 calendar rig read as "discernible
/// but subtle" at native 1× (it only became unmistakable at 3×). The grid is
/// the at-a-glance surface, so the ring has to survive one device pixel per
/// logical pixel: 2.0 of stroke around a marker 2.0 wider than the disc puts
/// the grid ring at 8px/2px, i.e. a 4px hole. Both values are whole numbers
/// so the ring lands on device-pixel boundaries at 1× instead of smearing
/// across two rows of pixels, which is most of why 1.5 read as faint.
///
/// Deliberately NOT a color change: shape carries the source (see
/// [billStateDot]) and colour is fully spent on state. And deliberately not
/// louder still — a hollow ring reads as secondary to a solid disc even when
/// it covers more area, which is what keeps a declared bill outranking an
/// inferred one at a glance.
const double kBillDetectedRingStroke = 2.0;
const double kBillDetectedSizeBoost = 2.0;

/// Diameter of a DECLARED day-cell marker. Detected rings render
/// [kBillDetectedSizeBoost] wider, so the cell's marker lane is sized for
/// the sum.
const double _kGridDotSize = 6;

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
///
/// Three occurrence sources land here — explicit `recurring_rules`
/// expansions (`source: "recurring"`), loan schedule dues (`"loan"`), and
/// detector-inferred clusters (`"detected"`). The detected ones show by
/// DEFAULT behind a persisted "Detected charges" toggle; the hide/show
/// decision is display-only, so the card's visibility test still reads the
/// UNFILTERED occurrence list (hiding every detection must never take the
/// toggle that restores them off screen with it).
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

  /// Owner-chosen: detector-inferred charges show by DEFAULT (a calendar of
  /// nothing but loan repayments is what prompted this), with the toggle
  /// below to hide them. Device-local via `Preferences`, not a backend
  /// setting — it's a display choice, and the backend deliberately keeps
  /// projecting them either way.
  bool _showDetected = Preferences.getBillsShowDetected();

  /// True while a "not a bill" POST is in flight — the action buttons
  /// disable so a double-tap can't fire two ignores + two refetches.
  bool _ignoring = false;

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

  /// Any detected occurrence in the fetched window — reads the UNFILTERED
  /// list on purpose, so hiding them doesn't also hide the toggle that
  /// brings them back.
  bool get _hasDetected => _occurrences.any((o) => o.isDetected);

  /// What the grid and agenda render: everything, minus detected charges
  /// when the toggle is off.
  List<BillOccurrence> get _visible => _showDetected
      ? _occurrences
      : _occurrences.where((o) => !o.isDetected).toList();

  Map<DateTime, List<BillOccurrence>> get _byDay {
    final out = <DateTime, List<BillOccurrence>>{};
    for (final o in _visible) {
      out.putIfAbsent(o.dueDate, () => []).add(o);
    }
    return out;
  }

  void _setShowDetected(bool v) {
    if (v == _showDetected) return;
    setState(() => _showDetected = v);
    Preferences.setBillsShowDetected(v);
  }

  /// "Not a bill" on a detected occurrence: tell the detector to stop
  /// clustering this merchant, then refetch so the calendar (and the
  /// projection the backend computes) drop it for real. Explicit rules and
  /// loan dues have no merchant key and never reach here.
  Future<void> _ignoreDetected(BillOccurrence o) async {
    final key = o.merchantKey;
    if (key == null || _ignoring) return;
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _ignoring = true);
    try {
      await widget.apiService.ignoreSubscription(key);
      await _load(forceRefresh: true);
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l.bcNotABillDone(o.description))),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l.dashFailedGeneric(e.toString()))),
      );
    } finally {
      if (mounted) setState(() => _ignoring = false);
    }
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
                if (_hasDetected) ...[
                  SizedBox(height: isPhone ? 8 : 12),
                  _detectedToggle(context, l),
                ],
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

  // ---------- detected-charges toggle ----------

  /// "Detected charges" switch. Default ON; flipping it filters the grid,
  /// the agenda AND the projection curve (which switches to the backend's
  /// `usd - usd_detected` series — no client-side FX or re-summing).
  ///
  /// Label + help text + switch merge into one toggleable semantics node so
  /// the switch isn't an anonymous on/off control (same idiom as the
  /// projection screen's advanced toggles).
  Widget _detectedToggle(BuildContext context, AppLocalizations l) {
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.auto_awesome_rounded, size: 16, color: context.textSubtle),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.bcDetectedToggle,
                  style: TextStyle(fontSize: 13, color: context.textMuted),
                ),
                const SizedBox(height: 2),
                Text(
                  l.bcDetectedHint,
                  style: TextStyle(fontSize: 11, color: context.textFaint),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Switch(
            key: const ValueKey('bc-detected-toggle'),
            value: _showDetected,
            activeThumbColor: context.info,
            onChanged: _setShowDetected,
          ),
        ],
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
    // A dot is drawn as a hollow RING when every occurrence it stands for
    // is detector-inferred, and filled when at least one was declared — so
    // a day whose only bills are guesses never looks like a day with a
    // rule on it.
    final markers = <({String state, bool detected})>[];
    if (items != null) {
      for (final s in _statePriority) {
        if (markers.length >= 3) break;
        final withState = items.where((o) => o.state == s);
        if (withState.isEmpty) continue;
        markers.add((state: s, detected: withState.every((o) => o.isDetected)));
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
              // The lane is sized for the TALLER of the two markers — a
              // detected ring — or the ring would be squeezed into an
              // ellipse by the tight height.
              SizedBox(
                height: _kGridDotSize + kBillDetectedSizeBoost,
                child: markers.isEmpty
                    ? null
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          for (var i = 0; i < markers.length; i++) ...[
                            if (i > 0) const SizedBox(width: 2),
                            billStateDot(
                              context,
                              state: markers[i].state,
                              detected: markers[i].detected,
                              size: _kGridDotSize,
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
    Widget item(String state, String label, {bool detected = false}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        billStateDot(context, state: state, detected: detected),
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
        // The ring legend only earns its space when the grid can actually
        // draw one.
        if (_hasDetected && _showDetected)
          item('upcoming', l.bcDetected, detected: true),
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
          billStateDot(
            context,
            state: o.state,
            detected: o.isDetected,
            size: 8,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        title,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: context.textPrimary,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (o.isDetected) ...[
                      const SizedBox(width: 6),
                      _detectedChip(context, l),
                    ],
                  ],
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
          // Detected-only escape hatch: the detector guessed, and the user
          // gets to say it guessed wrong. Explicit rules / loan dues carry
          // no merchant key and never render this.
          if (o.isDetected && o.merchantKey != null)
            IconButton(
              key: ValueKey('bc-not-a-bill-${o.merchantKey}'),
              tooltip: l.bcNotABill,
              icon: const Icon(Icons.do_not_disturb_on_outlined, size: 18),
              color: context.textMuted,
              visualDensity: VisualDensity.compact,
              onPressed: _ignoring ? null : () => _ignoreDetected(o),
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

  /// The "Detected" mark next to an inferred occurrence's title: outline +
  /// icon + word, so the inferred/declared split survives greyscale, a
  /// color-blind viewer, and a screen reader alike.
  Widget _detectedChip(BuildContext context, AppLocalizations l) {
    return Semantics(
      label: l.bcDetectedSem,
      // container: true or the label merges into the agenda row's node and
      // the "we inferred this" claim stops being separately addressable.
      container: true,
      excludeSemantics: true,
      child: Tooltip(
        message: l.bcDetectedHint,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: context.accentBorder(context.info)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.auto_awesome_rounded, size: 10, color: context.info),
              const SizedBox(width: 3),
              Text(
                l.bcDetected,
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  color: context.info,
                ),
              ),
            ],
          ),
        ),
      ),
    );
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

    final isMxn = _currency == 'MXN';
    final valueKey = isMxn ? 'mxn' : 'usd';
    // Hiding detected charges renders the backend's detected-subtracted
    // series: `usd - usd_detected` (resp. MXN). `usd_detected` is the
    // cumulative detected-only contribution ALREADY INCLUDED in `usd`, and
    // it exists precisely so the client never redoes FX or Decimal math to
    // answer "what would this curve look like without the guesses".
    final detectedKey = isMxn ? 'mxn_detected' : 'usd_detected';

    final points = <({DateTime date, double close})>[];
    for (final p in projection) {
      final d = DateTime.tryParse((p['date'] ?? '').toString());
      if (d == null) continue;
      final v = (p[valueKey] as num?)?.toDouble();
      if (v == null) continue;
      final detected = _showDetected
          ? 0.0
          : ((p[detectedKey] as num?)?.toDouble() ?? 0.0);
      points.add((
        date: DateTime.utc(d.year, d.month, d.day),
        close: v - detected,
      ));
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
    // Honesty guard: the backend computes this suggestion from the
    // detected-INCLUSIVE curve on purpose — it answers "will I actually run
    // dry", not "what is currently on screen". With detected charges hidden
    // that means a shortfall warning whose contributing bills aren't in the
    // grid or the agenda. Neither suppress it (the risk is real) nor show it
    // bare (unexplained warnings destroy trust) — say so.
    final qualified = !_showDetected && _hasDetected;
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
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
                if (qualified) ...[
                  const SizedBox(height: 4),
                  Text(
                    l.bcFxIncludesHidden,
                    key: const ValueKey('bc-fx-hidden-qualifier'),
                    style: TextStyle(fontSize: 11, color: context.textMuted),
                  ),
                ],
              ],
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
