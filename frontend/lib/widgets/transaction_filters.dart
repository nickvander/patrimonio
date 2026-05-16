import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import 'package:intl/intl.dart';
import '../utils/category.dart';

enum TxFlow { all, income, expense }

enum TxStatus { all, pending, settled }

/// Standard windows surfaced as one-tap chips in the filter dialog. The
/// `custom` value lets the user pick an arbitrary `start`/`end` pair.
enum TxDateRange { all, today, sevenDays, thirtyDays, ninetyDays, ytd, oneYear, custom }

extension TxDateRangeLabel on TxDateRange {
  String get label {
    switch (this) {
      case TxDateRange.all:
        return 'All time';
      case TxDateRange.today:
        return 'Today';
      case TxDateRange.sevenDays:
        return 'Last 7 days';
      case TxDateRange.thirtyDays:
        return 'Last 30 days';
      case TxDateRange.ninetyDays:
        return 'Last 90 days';
      case TxDateRange.ytd:
        return 'Year to date';
      case TxDateRange.oneYear:
        return 'Last year';
      case TxDateRange.custom:
        return 'Custom range';
    }
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

  const TxFilters({
    this.accountIds = const {},
    this.categories = const {},
    this.flow = TxFlow.all,
    this.status = TxStatus.all,
    this.dateRange = TxDateRange.all,
    this.customStart,
    this.customEnd,
  });

  static const empty = TxFilters();

  bool get isActive =>
      accountIds.isNotEmpty ||
      categories.isNotEmpty ||
      flow != TxFlow.all ||
      status != TxStatus.all ||
      dateRange != TxDateRange.all;

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
  }) {
    return TxFilters(
      accountIds: accountIds ?? this.accountIds,
      categories: categories ?? this.categories,
      flow: flow ?? this.flow,
      status: status ?? this.status,
      dateRange: dateRange ?? this.dateRange,
      customStart:
          clearCustomDates ? null : (customStart ?? this.customStart),
      customEnd: clearCustomDates ? null : (customEnd ?? this.customEnd),
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
    if (flow == TxFlow.expense && amount <= 0) return false;
    if (flow == TxFlow.income && amount >= 0) return false;
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
    return true;
  }
}

DateTime _stripTime(DateTime d) => DateTime(d.year, d.month, d.day);

/// Filter editor — shown as a dialog on wide screens, bottom sheet on
/// narrow. Lets the user multi-select accounts and categories and pick
/// flow/status. Returns the new TxFilters when the user taps Apply.
class TxFiltersDialog extends StatefulWidget {
  final TxFilters initial;
  /// All transactions in the parent list — used to derive the distinct
  /// set of account names and category labels the user can filter by.
  final List<dynamic> transactions;
  /// Accounts list from the dashboard; used so we have nice names even
  /// when no transactions hit a particular account yet.
  final List<dynamic> accounts;

  const TxFiltersDialog({
    super.key,
    required this.initial,
    required this.transactions,
    required this.accounts,
  });

  @override
  State<TxFiltersDialog> createState() => _TxFiltersDialogState();
}

class _TxFiltersDialogState extends State<TxFiltersDialog> {
  late TxFilters _draft;

  @override
  void initState() {
    super.initState();
    _draft = widget.initial;
  }

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
      for (final t in widget.transactions) {
        final id = t['account_id']?.toString();
        if (id == null) continue;
        map.putIfAbsent(
            id, () => (t['account_name'] ?? 'Unknown').toString());
      }
    }
    final entries = map.entries.toList()
      ..sort((a, b) => a.value.toLowerCase().compareTo(b.value.toLowerCase()));
    return entries;
  }

  // Distinct prettified category labels actually present in the list,
  // so we don't ever offer a filter that would produce zero rows.
  List<String> _categoryOptions() {
    final set = <String>{};
    for (final t in widget.transactions) {
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
    final accountOptions = _accountOptions();
    final categoryOptions = _categoryOptions();

    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('Filter transactions')),
          if (_draft.isActive)
            TextButton(
              onPressed: () => setState(() => _draft = TxFilters.empty),
              child: Text('Reset'),
            ),
        ],
      ),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480, maxHeight: 560),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _sectionLabel('Date range'),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: TxDateRange.values.map((r) {
                  final selected = _draft.dateRange == r;
                  return FilterChip(
                    label: Text(r.label),
                    selected: selected,
                    onSelected: (_) async {
                      if (r == TxDateRange.custom) {
                        final picked = await showDateRangePicker(
                          context: context,
                          firstDate: DateTime(2000),
                          lastDate: DateTime.now(),
                          initialDateRange: (_draft.customStart != null &&
                                  _draft.customEnd != null)
                              ? DateTimeRange(
                                  start: _draft.customStart!,
                                  end: _draft.customEnd!,
                                )
                              : null,
                        );
                        if (picked != null) {
                          setState(() => _draft = _draft.copyWith(
                                dateRange: TxDateRange.custom,
                                customStart: picked.start,
                                customEnd: picked.end,
                              ));
                        }
                      } else {
                        setState(() => _draft = _draft.copyWith(
                              dateRange: r,
                              clearCustomDates: r == TxDateRange.all,
                            ));
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
              _sectionLabel('Flow'),
              const SizedBox(height: 6),
              SegmentedButton<TxFlow>(
                segments: const [
                  ButtonSegment(value: TxFlow.all, label: Text('All')),
                  ButtonSegment(
                      value: TxFlow.expense, label: Text('Expense')),
                  ButtonSegment(
                      value: TxFlow.income, label: Text('Income')),
                ],
                selected: {_draft.flow},
                onSelectionChanged: (s) =>
                    setState(() => _draft = _draft.copyWith(flow: s.first)),
              ),
              const SizedBox(height: 16),
              _sectionLabel('Status'),
              const SizedBox(height: 6),
              SegmentedButton<TxStatus>(
                segments: const [
                  ButtonSegment(value: TxStatus.all, label: Text('All')),
                  ButtonSegment(
                      value: TxStatus.settled, label: Text('Settled')),
                  ButtonSegment(
                      value: TxStatus.pending, label: Text('Pending')),
                ],
                selected: {_draft.status},
                onSelectionChanged: (s) =>
                    setState(() => _draft = _draft.copyWith(status: s.first)),
              ),
              if (accountOptions.isNotEmpty) ...[
                const SizedBox(height: 18),
                _sectionLabel('Accounts'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: accountOptions.map((e) {
                    final selected = _draft.accountIds.contains(e.key);
                    return FilterChip(
                      label: Text(e.value),
                      selected: selected,
                      onSelected: (v) {
                        final next = {..._draft.accountIds};
                        if (v) {
                          next.add(e.key);
                        } else {
                          next.remove(e.key);
                        }
                        setState(() =>
                            _draft = _draft.copyWith(accountIds: next));
                      },
                    );
                  }).toList(),
                ),
              ],
              if (categoryOptions.isNotEmpty) ...[
                const SizedBox(height: 18),
                _sectionLabel('Categories'),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: categoryOptions.map((c) {
                    final selected = _draft.categories.contains(c);
                    return FilterChip(
                      label: Text(c),
                      selected: selected,
                      onSelected: (v) {
                        final next = {..._draft.categories};
                        if (v) {
                          next.add(c);
                        } else {
                          next.remove(c);
                        }
                        setState(() =>
                            _draft = _draft.copyWith(categories: next));
                      },
                    );
                  }).toList(),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop<TxFilters>(context),
          child: Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop<TxFilters>(context, _draft),
          child: Text('Apply'),
        ),
      ],
    );
  }

  Widget _sectionLabel(String text) => Text(
        text.toUpperCase(),
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: context.textSubtle,
          letterSpacing: 0.8,
        ),
      );
}
