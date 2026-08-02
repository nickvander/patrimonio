import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../theme/palette.dart';
import '../utils/category.dart';
import '../utils/theme_colors.dart';
import 'connected_segments.dart';

enum TxFlow { all, income, expense }

enum TxStatus { all, pending, settled }

/// Standard windows surfaced as one-tap chips in the filter dialog. The
/// `custom` value lets the user pick an arbitrary `start`/`end` pair.
enum TxDateRange {
  all,
  today,
  sevenDays,
  thirtyDays,
  ninetyDays,
  ytd,
  oneYear,
  custom,
}

extension TxDateRangeLabel on TxDateRange {
  String labelFor(BuildContext context) {
    final l = AppLocalizations.of(context);
    switch (this) {
      case TxDateRange.all:
        return l.txDateAllTime;
      case TxDateRange.today:
        return l.txDateToday;
      case TxDateRange.sevenDays:
        return l.txDateLast7Days;
      case TxDateRange.thirtyDays:
        return l.txDateLast30Days;
      case TxDateRange.ninetyDays:
        return l.txDateLast90Days;
      case TxDateRange.ytd:
        return l.txDateYtd;
      case TxDateRange.oneYear:
        return l.txDateLastYear;
      case TxDateRange.custom:
        return l.txDateCustomRange;
    }
  }
}

/// Row ordering for the transactions list. `dateNewest` is the default
/// and the only mode that keeps the date-group headers (month landmarks
/// + day headings); every other mode renders a flat, header-less list.
enum TxSort { dateNewest, dateOldest, amountHigh, amountLow, merchant }

/// User-facing label for a [TxSort] mode — shared by the wide toolbar's
/// sort menu, the filter panel's "Sort by" section, and the active-sort
/// chip in the transactions tab.
String txSortLabel(AppLocalizations l, TxSort mode) {
  switch (mode) {
    case TxSort.dateNewest:
      return l.txSortDateNewest;
    case TxSort.dateOldest:
      return l.txSortDateOldest;
    case TxSort.amountHigh:
      return l.txSortAmountHigh;
    case TxSort.amountLow:
      return l.txSortAmountLow;
    case TxSort.merchant:
      return l.txSortMerchant;
  }
}

/// Immutable bundle of filter selections applied to the transactions
/// list. Empty when every field is "all" — i.e. the list is unfiltered.
class TxFilters {
  final Set<String> accountIds;
  final Set<String> categories; // prettified category labels
  final TxFlow flow;
  final TxStatus status;
  final TxDateRange dateRange;
  final DateTime? customStart;
  final DateTime? customEnd;
  // Inclusive amount window applied to the ABSOLUTE amount in the
  // transaction's own currency — "that ~$450 charge" matches whether
  // it was an inflow or an outflow. Either bound may be null (open
  // end). The dialog guarantees min <= max by swapping on Apply.
  final double? minAmount;
  final double? maxAmount;
  // Sync-time cutoff for the since-last-visit drill-down: keep only rows
  // whose `created_at` (the instant the SYNC produced the row) is after
  // this anchor. Deliberately distinct from the posted-date window above —
  // card transactions post days before the sync fetches them, so "new
  // since your last visit" can never be expressed as a date window.
  // Drill-down-only: not editable in the filter dialog, but it renders
  // (and clears) as a chip in the active-filter strip like any filter.
  final DateTime? createdSince;

  const TxFilters({
    this.accountIds = const {},
    this.categories = const {},
    this.flow = TxFlow.all,
    this.status = TxStatus.all,
    this.dateRange = TxDateRange.all,
    this.customStart,
    this.customEnd,
    this.minAmount,
    this.maxAmount,
    this.createdSince,
  });

  static const empty = TxFilters();

  bool get isActive =>
      accountIds.isNotEmpty ||
      categories.isNotEmpty ||
      flow != TxFlow.all ||
      status != TxStatus.all ||
      dateRange != TxDateRange.all ||
      minAmount != null ||
      maxAmount != null ||
      createdSince != null;

  /// Count of active filters — drives the badge on the filter button.
  /// Treats account/category sets as a single bucket each (any value vs.
  /// none) so a 4-account selection still reads as "1 filter".
  int get badgeCount {
    var n = 0;
    if (accountIds.isNotEmpty) n++;
    if (categories.isNotEmpty) n++;
    if (flow != TxFlow.all) n++;
    if (status != TxStatus.all) n++;
    if (dateRange != TxDateRange.all) n++;
    // Min/max are one conceptual "amount" filter, like the sets above.
    if (minAmount != null || maxAmount != null) n++;
    if (createdSince != null) n++;
    return n;
  }

  /// Resolve the active date window into an inclusive (start, end) pair
  /// of day-precision dates. Returns null when the filter is "all".
  ({DateTime start, DateTime end})? resolveDateWindow({DateTime? now}) {
    final today = _stripTime(now ?? DateTime.now());
    switch (dateRange) {
      case TxDateRange.all:
        return null;
      case TxDateRange.today:
        return (start: today, end: today);
      case TxDateRange.sevenDays:
        return (start: today.subtract(const Duration(days: 6)), end: today);
      case TxDateRange.thirtyDays:
        return (start: today.subtract(const Duration(days: 29)), end: today);
      case TxDateRange.ninetyDays:
        return (start: today.subtract(const Duration(days: 89)), end: today);
      case TxDateRange.ytd:
        return (start: DateTime(today.year), end: today);
      case TxDateRange.oneYear:
        return (start: today.subtract(const Duration(days: 365)), end: today);
      case TxDateRange.custom:
        if (customStart == null || customEnd == null) return null;
        return (start: _stripTime(customStart!), end: _stripTime(customEnd!));
    }
  }

  TxFilters copyWith({
    Set<String>? accountIds,
    Set<String>? categories,
    TxFlow? flow,
    TxStatus? status,
    TxDateRange? dateRange,
    DateTime? customStart,
    DateTime? customEnd,
    bool clearCustomDates = false,
    double? minAmount,
    double? maxAmount,
    bool clearAmounts = false,
    DateTime? createdSince,
    bool clearCreatedSince = false,
  }) {
    return TxFilters(
      accountIds: accountIds ?? this.accountIds,
      categories: categories ?? this.categories,
      flow: flow ?? this.flow,
      status: status ?? this.status,
      dateRange: dateRange ?? this.dateRange,
      customStart: clearCustomDates ? null : (customStart ?? this.customStart),
      customEnd: clearCustomDates ? null : (customEnd ?? this.customEnd),
      minAmount: clearAmounts ? null : (minAmount ?? this.minAmount),
      maxAmount: clearAmounts ? null : (maxAmount ?? this.maxAmount),
      createdSince: clearCreatedSince
          ? null
          : (createdSince ?? this.createdSince),
    );
  }

  /// True when the given transaction passes every active filter.
  bool matches(dynamic tx) {
    if (accountIds.isNotEmpty) {
      final id = tx['account_id']?.toString();
      if (id == null || !accountIds.contains(id)) return false;
    }
    if (categories.isNotEmpty) {
      final cat = prettyCategory(
        userCategory: tx['user_category']?.toString(),
        detailed: tx['category_detailed']?.toString(),
        primary: tx['category']?.toString(),
      );
      if (!categories.contains(cat)) return false;
    }
    final amount = (tx['amount'] as num?)?.toDouble() ?? 0.0;
    // Storage sign convention (backend sync.rs:659): negative = outflow
    // (expense), positive = inflow (income).
    if (flow == TxFlow.expense && amount >= 0) return false;
    if (flow == TxFlow.income && amount <= 0) return false;
    // Amount window on the absolute value: the storage sign convention
    // is an implementation detail users searching for "the ~$450 one"
    // shouldn't have to know about.
    final absAmount = amount.abs();
    if (minAmount != null && absAmount < minAmount!) return false;
    if (maxAmount != null && absAmount > maxAmount!) return false;
    final pending = tx['pending'] == true;
    if (status == TxStatus.pending && !pending) return false;
    if (status == TxStatus.settled && pending) return false;

    final window = resolveDateWindow();
    if (window != null) {
      final raw = tx['date']?.toString();
      if (raw == null) return false;
      final parsed = DateTime.tryParse(raw);
      if (parsed == null) return false;
      final day = _stripTime(parsed);
      if (day.isBefore(window.start) || day.isAfter(window.end)) return false;
    }
    if (createdSince != null) {
      // Instant-vs-instant comparison: `created_at` is an RFC3339 UTC
      // timestamp and DateTime comparisons are zone-agnostic, so no local
      // truncation here (truncating is exactly the timezone bug that made
      // a 7:59pm Jul 31 CST anchor read as Aug 1).
      final created = DateTime.tryParse(tx['created_at']?.toString() ?? '');
      if (created != null) {
        if (!created.isAfter(createdSince!)) return false;
      } else {
        // Older backend: no created_at on the row. Approximate with the
        // bank-POSTED date — keep rows posted on/after the anchor's LOCAL
        // day. Imperfect (late-synced rows posted earlier are missed),
        // but honest: better than hiding everything or showing everything.
        final raw = tx['date']?.toString();
        if (raw == null) return false;
        final posted = DateTime.tryParse(raw);
        if (posted == null) return false;
        if (_stripTime(posted).isBefore(_stripTime(createdSince!.toLocal()))) {
          return false;
        }
      }
    }
    return true;
  }
}

DateTime _stripTime(DateTime d) => DateTime(d.year, d.month, d.day);

/// Compact display form for an amount bound: whole numbers drop the
/// decimals ("450"), anything else keeps cents ("450.50"). Shared by
/// the dialog's prefill and the active-filter chip label.
String formatFilterAmount(double v) =>
    v == v.roundToDouble() ? v.toStringAsFixed(0) : v.toStringAsFixed(2);

/// Lenient numeric parse for the amount fields: trims, drops thousands
/// separators and a stray currency sign, and treats anything
/// unparseable (or empty) as "no bound". Sign is discarded — the
/// filter is on the absolute amount.
double? parseFilterAmount(String raw) {
  final t = raw.trim().replaceAll(',', '').replaceAll(r'$', '');
  if (t.isEmpty) return null;
  return double.tryParse(t)?.abs();
}

/// Filter & sort editor — shown as an AlertDialog on wide screens and a
/// modal bottom sheet on narrow (set [asSheet]). Lets the user
/// multi-select accounts and categories, pick flow/status/date/amount,
/// and choose the row ordering. Pops a `(TxFilters, TxSort)` record when
/// the user taps Apply; pops null on Cancel/dismiss.
class TxFiltersDialog extends StatefulWidget {
  final TxFilters initial;

  /// Sort mode the "Sort by" section starts on.
  final TxSort initialSort;

  /// True when hosted inside `showModalBottomSheet` (narrow layouts):
  /// renders the sheet shell (header + scrollable body + pinned action
  /// row) instead of the AlertDialog shell.
  final bool asSheet;

  /// All transactions in the parent list — used to derive the distinct
  /// set of account names and category labels the user can filter by.
  final List<dynamic> transactions;

  /// Accounts list from the dashboard; used so we have nice names even
  /// when no transactions hit a particular account yet.
  final List<dynamic> accounts;

  /// Whole-history load kicked off by the opener (the tab's memoized
  /// cascade). Non-null only when more pages existed at open time: the
  /// dialog shows a lightweight loading row until it completes, then
  /// refreshes its option lists via [liveTransactions]. Null = everything
  /// is already loaded, no affordance shown.
  final Future<void>? historyLoad;

  /// Live re-read of the opener's current transaction list — [transactions]
  /// is a snapshot from open time and won't include pages the cascade
  /// appends while the dialog is up. Falls back to [transactions] when null.
  final List<dynamic> Function()? liveTransactions;

  const TxFiltersDialog({
    super.key,
    required this.initial,
    this.initialSort = TxSort.dateNewest,
    this.asSheet = false,
    required this.transactions,
    required this.accounts,
    this.historyLoad,
    this.liveTransactions,
  });

  @override
  State<TxFiltersDialog> createState() => _TxFiltersDialogState();
}

class _TxFiltersDialogState extends State<TxFiltersDialog> {
  late TxFilters _draft;
  late TxSort _draftSort;
  // Free-typed min/max amount bounds. Parsed only on Apply (and
  // swapped if the user typed them backwards) so half-typed numbers
  // never fight the draft state while editing.
  final TextEditingController _minAmountCtrl = TextEditingController();
  final TextEditingController _maxAmountCtrl = TextEditingController();
  // True while the opener's whole-history cascade is still in flight —
  // drives the loading row under the option sections. Cleared (with an
  // option-list refresh) when the load settles, success or failure.
  bool _loadingHistory = false;

  @override
  void initState() {
    super.initState();
    _draft = widget.initial;
    _draftSort = widget.initialSort;
    if (widget.initial.minAmount != null) {
      _minAmountCtrl.text = formatFilterAmount(widget.initial.minAmount!);
    }
    if (widget.initial.maxAmount != null) {
      _maxAmountCtrl.text = formatFilterAmount(widget.initial.maxAmount!);
    }
    final load = widget.historyLoad;
    if (load != null) {
      _loadingHistory = true;
      load.whenComplete(() {
        if (mounted) setState(() => _loadingHistory = false);
      });
    }
  }

  @override
  void dispose() {
    _minAmountCtrl.dispose();
    _maxAmountCtrl.dispose();
    super.dispose();
  }

  /// Fold the amount fields into the draft and close, returning the
  /// `(filters, sort)` pair. min > max is silently swapped — the user's
  /// intent ("between these two numbers") is unambiguous, so a graceful
  /// fix beats an error.
  void _apply() {
    var lo = parseFilterAmount(_minAmountCtrl.text);
    var hi = parseFilterAmount(_maxAmountCtrl.text);
    if (lo != null && hi != null && lo > hi) {
      final tmp = lo;
      lo = hi;
      hi = tmp;
    }
    Navigator.pop<(TxFilters, TxSort)>(context, (
      TxFilters(
        accountIds: _draft.accountIds,
        categories: _draft.categories,
        flow: _draft.flow,
        status: _draft.status,
        dateRange: _draft.dateRange,
        customStart: _draft.customStart,
        customEnd: _draft.customEnd,
        minAmount: lo,
        maxAmount: hi,
        // Not editable in this dialog (drill-down-only), but it must
        // survive an Apply — dropping it here would silently widen the
        // list the user is looking at.
        createdSince: _draft.createdSince,
      ),
      _draftSort,
    ));
  }

  // Current transaction list: re-read from the opener when it exposes a
  // live getter (rows the whole-history cascade appended after open),
  // otherwise the open-time snapshot.
  List<dynamic> get _txSource =>
      widget.liveTransactions?.call() ?? widget.transactions;

  // Distinct account (id → label) entries from the dashboard accounts
  // payload. Falls back to whatever appears on transactions if accounts
  // is empty (e.g. only manual entries).
  List<MapEntry<String, String>> _accountOptions() {
    final map = <String, String>{};
    for (final a in widget.accounts) {
      final id = a['id']?.toString();
      if (id == null) continue;
      final nick = (a['nickname'] ?? '').toString();
      final name = (a['name'] ?? '').toString();
      map[id] = nick.isNotEmpty ? nick : name;
    }
    if (map.isEmpty) {
      for (final t in _txSource) {
        final id = t['account_id']?.toString();
        if (id == null) continue;
        map.putIfAbsent(id, () => (t['account_name'] ?? 'Unknown').toString());
      }
    }
    final entries = map.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    return entries;
  }

  // Distinct prettified category labels actually present in the list,
  // so we don't ever offer a filter that would produce zero rows. Once
  // the whole-history load completes this naturally covers categories
  // that only occur in older, previously-unloaded pages.
  List<String> _categoryOptions() {
    final set = <String>{};
    for (final t in _txSource) {
      final cat = prettyCategory(
        userCategory: t['user_category']?.toString(),
        detailed: t['category_detailed']?.toString(),
        primary: t['category']?.toString(),
      );
      if (cat.isNotEmpty) set.add(cat);
    }
    final list = set.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return widget.asSheet ? _sheetShell(l) : _dialogShell(l);
  }

  /// Wide-layout shell — the AlertDialog presentation. Right-aligned
  /// compact actions are correct here (pointer surface); only the sheet
  /// gets the full-bleed Apply.
  Widget _dialogShell(AppLocalizations l) {
    return AlertDialog(
      // Same tone main.dart's cardTheme uses, so the dialog matches the
      // sheet shell (and drops the pale-sage seeded container in light).
      backgroundColor: BrandPalette.cardSurface(Theme.of(context).brightness),
      // titleLarge, matching the sheet header — the AlertDialog default
      // (headlineSmall) made the two shells disagree on title size.
      titleTextStyle: Theme.of(context).textTheme.titleLarge,
      title: _titleRow(l),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: SingleChildScrollView(child: _body(l)),
      ),
      actions: _actionButtons(l),
    );
  }

  /// Narrow-layout shell for `showModalBottomSheet`: header + scrollable
  /// body with the action row pinned at the bottom of the sheet. The
  /// viewInsets padding keeps Apply clear of the soft keyboard while the
  /// amount fields are being edited.
  Widget _sheetShell(AppLocalizations l) {
    // Gutters off the sheet's INNER constraint (house rule — never
    // MediaQuery): 16 on phones, 24 once the sheet is wide.
    return LayoutBuilder(
      builder: (context, constraints) {
        final hPad = constraints.maxWidth < 420 ? 16.0 : 24.0;
        return Padding(
          padding: EdgeInsets.only(
            left: hPad,
            right: hPad,
            bottom: 16 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DefaultTextStyle(
                // Explicit titleLarge, matching the dialog shell's
                // titleTextStyle so both presentations share one header
                // size.
                style: Theme.of(context).textTheme.titleLarge!,
                child: _titleRow(l),
              ),
              const SizedBox(height: 8),
              // Hairline between the fixed header and the scrollable body
              // (notifications-panel idiom): gives the scrolling content a
              // visible edge to slide under.
              Divider(height: 1, color: context.hairline),
              Flexible(
                child: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: _body(l),
                  ),
                ),
              ),
              // Same hairline above the pinned action bar, separating it
              // from the content scrolling beneath.
              Divider(height: 1, color: context.hairline),
              const SizedBox(height: 12),
              Row(
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(l.actionCancel),
                  ),
                  const SizedBox(width: 8),
                  // Full-bleed primary on the touch surface, per the
                  // theme/buttons.dart touch-width rule (≥48dp tall).
                  Expanded(
                    child: FilledButton(
                      style: FilledButton.styleFrom(
                        minimumSize: const Size.fromHeight(48),
                      ),
                      onPressed: _apply,
                      child: Text(l.actionApply),
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  /// Header shared by both shells: panel title + a Reset affordance
  /// that appears once anything (filters, amounts, or sort) deviates
  /// from the defaults.
  Widget _titleRow(AppLocalizations l) {
    return Row(
      children: [
        Expanded(child: Text(l.txFilterSort)),
        if (_draft.isActive ||
            _draftSort != TxSort.dateNewest ||
            _minAmountCtrl.text.isNotEmpty ||
            _maxAmountCtrl.text.isNotEmpty)
          TextButton(
            onPressed: () => setState(() {
              _draft = TxFilters.empty;
              _draftSort = TxSort.dateNewest;
              _minAmountCtrl.clear();
              _maxAmountCtrl.clear();
            }),
            child: Text(l.txReset),
          ),
      ],
    );
  }

  /// House tonal chip recipe — same look as the dashboard cash-flow
  /// ChoiceChips and DateRangeSelector: no checkmark (so chip width never
  /// jumps on selection and the Wrap doesn't reflow), no outline, quiet
  /// tileSurface fill, selected state in brand jade via accentSoft (whose
  /// light-mode alpha boost keeps it visible on white;
  /// palette_contrast_test polices the label contrast). Multi-select
  /// FilterChip semantics are untouched — this is presentation only.
  FilterChip _tonalChip({
    required String label,
    required bool selected,
    required ValueChanged<bool> onSelected,
  }) {
    return FilterChip(
      label: Text(label),
      selected: selected,
      showCheckmark: false,
      shape: const StadiumBorder(side: BorderSide.none),
      backgroundColor: context.tileSurface,
      selectedColor: context.accentSoft(context.positive),
      labelStyle: TextStyle(
        color: selected ? context.positive : context.textMuted,
        fontWeight: selected ? FontWeight.bold : FontWeight.normal,
      ),
      onSelected: onSelected,
    );
  }

  List<Widget> _actionButtons(AppLocalizations l) => [
    TextButton(
      onPressed: () => Navigator.pop(context),
      child: Text(l.actionCancel),
    ),
    FilledButton(onPressed: _apply, child: Text(l.actionApply)),
  ];

  /// Filter + sort sections shared by both shells (the shells provide
  /// the scrolling).
  Widget _body(AppLocalizations l) {
    final accountOptions = _accountOptions();
    final categoryOptions = _categoryOptions();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        _sectionLabel(l.txDateRange),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: TxDateRange.values.map((r) {
            final selected = _draft.dateRange == r;
            return _tonalChip(
              label: r.labelFor(context),
              selected: selected,
              onSelected: (_) async {
                if (r == TxDateRange.custom) {
                  final picked = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2000),
                    lastDate: DateTime.now(),
                    initialDateRange:
                        (_draft.customStart != null && _draft.customEnd != null)
                        ? DateTimeRange(
                            start: _draft.customStart!,
                            end: _draft.customEnd!,
                          )
                        : null,
                  );
                  if (picked != null) {
                    setState(
                      () => _draft = _draft.copyWith(
                        dateRange: TxDateRange.custom,
                        customStart: picked.start,
                        customEnd: picked.end,
                      ),
                    );
                  }
                } else {
                  setState(
                    () => _draft = _draft.copyWith(
                      dateRange: r,
                      clearCustomDates: r == TxDateRange.all,
                    ),
                  );
                }
              },
            );
          }).toList(),
        ),
        if (_draft.dateRange == TxDateRange.custom &&
            _draft.customStart != null &&
            _draft.customEnd != null) ...[
          const SizedBox(height: 6),
          Text(
            '${DateFormat('MMM d, y').format(_draft.customStart!)} – '
            '${DateFormat('MMM d, y').format(_draft.customEnd!)}',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
        ],
        const SizedBox(height: 18),
        _sectionLabel(l.txFlow),
        const SizedBox(height: 6),
        // House connected button group (shared with the dashboard theme
        // picker) instead of SegmentedButton — same single-select
        // semantics, same copyWith updates.
        ConnectedSegments<TxFlow>(
          segments: [
            ConnectedSegment(value: TxFlow.all, label: l.txFlowAll),
            ConnectedSegment(value: TxFlow.expense, label: l.txFlowExpense),
            ConnectedSegment(value: TxFlow.income, label: l.txFlowIncome),
          ],
          selected: _draft.flow,
          onSelected: (v) => setState(() => _draft = _draft.copyWith(flow: v)),
        ),
        const SizedBox(height: 18),
        _sectionLabel(l.txStatus),
        const SizedBox(height: 6),
        ConnectedSegments<TxStatus>(
          segments: [
            ConnectedSegment(value: TxStatus.all, label: l.txStatusAll),
            ConnectedSegment(value: TxStatus.settled, label: l.txStatusSettled),
            ConnectedSegment(value: TxStatus.pending, label: l.txStatusPending),
          ],
          selected: _draft.status,
          onSelected: (v) =>
              setState(() => _draft = _draft.copyWith(status: v)),
        ),
        const SizedBox(height: 18),
        _sectionLabel(l.txAmount),
        const SizedBox(height: 6),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _minAmountCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\d.,$]')),
                ],
                // Filled rounded field (house input recipe) — labelText
                // and isDense are load-bearing for the widget tests that
                // find these fields by their label.
                decoration: InputDecoration(
                  labelText: l.txAmountMin,
                  isDense: true,
                  filled: true,
                  fillColor: context.tileSurface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                // setState so the Reset button's visibility tracks
                // the amount fields, not just the chip draft.
                onChanged: (_) => setState(() {}),
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 10),
              child: Text('–'),
            ),
            Expanded(
              child: TextField(
                controller: _maxAmountCtrl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\d.,$]')),
                ],
                decoration: InputDecoration(
                  labelText: l.txAmountMax,
                  isDense: true,
                  filled: true,
                  fillColor: context.tileSurface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          l.txAmountFilterHelp,
          style: TextStyle(color: context.textSubtle, fontSize: 11),
        ),
        if (accountOptions.isNotEmpty) ...[
          const SizedBox(height: 18),
          _sectionLabel(l.txAccounts),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: accountOptions.map((e) {
              final selected = _draft.accountIds.contains(e.key);
              return _tonalChip(
                label: e.value,
                selected: selected,
                onSelected: (v) {
                  final next = {..._draft.accountIds};
                  if (v) {
                    next.add(e.key);
                  } else {
                    next.remove(e.key);
                  }
                  setState(() => _draft = _draft.copyWith(accountIds: next));
                },
              );
            }).toList(),
          ),
        ],
        if (categoryOptions.isNotEmpty) ...[
          const SizedBox(height: 18),
          _sectionLabel(l.txCategories),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: categoryOptions.map((c) {
              final selected = _draft.categories.contains(c);
              return _tonalChip(
                label: c,
                selected: selected,
                onSelected: (v) {
                  final next = {..._draft.categories};
                  if (v) {
                    next.add(c);
                  } else {
                    next.remove(c);
                  }
                  setState(() => _draft = _draft.copyWith(categories: next));
                },
              );
            }).toList(),
          ),
        ],
        if (_loadingHistory) ...[
          const SizedBox(height: 18),
          Row(
            children: [
              const SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l.txFilterLoadingHistory,
                  style: TextStyle(color: context.textMuted, fontSize: 12),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 18),
        _sectionLabel(l.txSortBy),
        const SizedBox(height: 2),
        RadioGroup<TxSort>(
          groupValue: _draftSort,
          onChanged: (v) => setState(() => _draftSort = v ?? TxSort.dateNewest),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final mode in TxSort.values)
                RadioListTile<TxSort>(
                  value: mode,
                  // dense keeps each option at the 48dp minimum
                  // touch target instead of the 56dp default.
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(txSortLabel(l, mode)),
                ),
            ],
          ),
        ),
      ],
    );
  }

  // House overline (matches spending_insight_sheet's section titles and
  // the phone card-overline idiom): 12/w700 subtle caps, gentle tracking.
  Widget _sectionLabel(String text) => Text(
    text.toUpperCase(),
    style: TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w700,
      color: context.textSubtle,
      letterSpacing: 0.4,
    ),
  );
}
