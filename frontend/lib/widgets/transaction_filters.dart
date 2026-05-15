import 'package:flutter/material.dart';
import '../utils/category.dart';

enum TxFlow { all, income, expense }

enum TxStatus { all, pending, settled }

/// Immutable bundle of filter selections applied to the transactions
/// list. Empty when every field is "all" — i.e. the list is unfiltered.
class TxFilters {
  final Set<String> accountIds;
  final Set<String> categories; // prettified category labels
  final TxFlow flow;
  final TxStatus status;

  const TxFilters({
    this.accountIds = const {},
    this.categories = const {},
    this.flow = TxFlow.all,
    this.status = TxStatus.all,
  });

  static const empty = TxFilters();

  bool get isActive =>
      accountIds.isNotEmpty ||
      categories.isNotEmpty ||
      flow != TxFlow.all ||
      status != TxStatus.all;

  /// Count of active filters — drives the badge on the filter button.
  /// Treats account/category sets as a single bucket each (any value vs.
  /// none) so a 4-account selection still reads as "1 filter".
  int get badgeCount {
    var n = 0;
    if (accountIds.isNotEmpty) n++;
    if (categories.isNotEmpty) n++;
    if (flow != TxFlow.all) n++;
    if (status != TxStatus.all) n++;
    return n;
  }

  TxFilters copyWith({
    Set<String>? accountIds,
    Set<String>? categories,
    TxFlow? flow,
    TxStatus? status,
  }) {
    return TxFilters(
      accountIds: accountIds ?? this.accountIds,
      categories: categories ?? this.categories,
      flow: flow ?? this.flow,
      status: status ?? this.status,
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
    return true;
  }
}

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
              child: const Text('Reset'),
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
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop<TxFilters>(context, _draft),
          child: const Text('Apply'),
        ),
      ],
    );
  }

  Widget _sectionLabel(String text) => Text(
        text.toUpperCase(),
        style: const TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: Colors.white54,
          letterSpacing: 0.8,
        ),
      );
}
