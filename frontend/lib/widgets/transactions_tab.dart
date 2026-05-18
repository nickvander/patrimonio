import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import 'package:intl/intl.dart';
import 'package:web/web.dart' as web;
import '../services/api_service.dart';
import '../utils/category.dart';
import '../utils/currency.dart';
import '../utils/transaction_description.dart';
import '../utils/transaction_display.dart';
import 'add_transaction_dialog.dart';
import 'transaction_filters.dart';

class TransactionsTab extends StatefulWidget {
  final List<dynamic> transactions;
  final List<dynamic> accounts;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final String targetCurrency;
  final double usdMxnRate;
  final Function(String id,
      {String? userCategory,
      String? userNotes,
      String? userDescription,
      String? accountId})? onUpdate;
  final Future<void> Function(String id)? onDelete;
  /// Optional callback to jump to the Management tab (used by the empty
  /// state's "Go to Management" button). Wired by the dashboard.
  final VoidCallback? onGoToManagement;
  /// ApiService for the "Add transaction" button + CSV export URL.
  /// Optional so consumers that don't need those actions can omit it.
  final ApiService? apiService;
  /// Invoked after a manual transaction has been added so the parent
  /// can refresh its transaction list.
  final VoidCallback? onTransactionAdded;
  /// Optional pagination hook. When provided, a "Load more" button shows
  /// under the list and fires the callback. The parent is expected to
  /// append the next page to [transactions] and rebuild.
  final Future<void> Function()? onLoadMore;
  /// Whether the parent thinks there are more transactions available.
  /// When false the "Load more" button is hidden.
  final bool hasMore;
  /// Cmd-K deep-link seed. When this changes the tab's search query is
  /// pre-populated so the row the user picked from the palette is
  /// surfaced immediately.
  final String? searchOverride;
  /// Cmd-K row-highlight target. When non-null the matching tx renders
  /// with a transient accent fill so the exact row the user picked is
  /// obvious even when other rows share the same description.
  final String? highlightedTxId;
  /// Date window from a chart-bar tap (cash-flow chart). When non-null
  /// the filter dialog opens pre-seeded to a custom range and the chip
  /// strip shows the picked window. The widget self-applies on the
  /// first didUpdateWidget that sees a new value, then ignores
  /// subsequent dashboard rebuilds with the same seed so manual edits
  /// stick.
  final ({DateTime start, DateTime end})? dateSeed;
  /// Fires after the widget has consumed [dateSeed] so the dashboard
  /// can clear its own copy and stop re-applying it on rebuilds.
  final VoidCallback? onDateSeedConsumed;
  /// Detected cross-currency cash transfers — indexed by source/dest
  /// transaction id in the detail modal to show "Linked to <leg>".
  /// Defaults to empty so older call sites compile without changes.
  final List<dynamic> fxTransfers;
  /// User-triggered scan for FX transfer pairs. Fires from the detail
  /// modal's "Scan for transfers" action. Null = hide that action.
  final Future<void> Function()? onDetectFxTransfers;
  /// Mark an auto-detected link as user-confirmed.
  final Future<void> Function(String id)? onConfirmFxTransfer;
  /// Remove a link entirely. The two underlying transactions stay put.
  final Future<void> Function(String id)? onUnlinkFxTransfer;

  const TransactionsTab({
    super.key,
    required this.transactions,
    this.accounts = const [],
    required this.conversionFactor,
    required this.currencyFormat,
    required this.targetCurrency,
    required this.usdMxnRate,
    this.onUpdate,
    this.onDelete,
    this.onGoToManagement,
    this.apiService,
    this.onTransactionAdded,
    this.onLoadMore,
    this.hasMore = false,
    this.searchOverride,
    this.highlightedTxId,
    this.dateSeed,
    this.onDateSeedConsumed,
    this.fxTransfers = const [],
    this.onDetectFxTransfers,
    this.onConfirmFxTransfer,
    this.onUnlinkFxTransfer,
  });

  @override
  State<TransactionsTab> createState() => _TransactionsTabState();
}

class _TransactionsTabState extends State<TransactionsTab> {
  String _searchQuery = '';
  bool _searchOpenOnNarrow = false;
  TxFilters _filters = TxFilters.empty;
  // Tracks the most recent searchOverride we applied so future rebuilds
  // don't keep re-seeding the input over user edits.
  String? _appliedOverride;
  final TextEditingController _searchController = TextEditingController();
  // Bulk-edit selection state. When _selectionMode is on, rows render a
  // checkbox and tapping a row toggles selection instead of opening the
  // detail sheet. The action bar at the bottom of the list lets the user
  // re-categorise, move accounts, or clear selection in one stroke.
  bool _selectionMode = false;
  final Set<String> _selectedIds = {};
  // Local spinner state while widget.onLoadMore is in-flight so the "Load
  // more" button itself shows feedback without a full-page reload.
  bool _loadingMore = false;

  @override
  void initState() {
    super.initState();
    final seed = widget.searchOverride;
    if (seed != null && seed.isNotEmpty) {
      _searchQuery = seed;
      _searchController.text = seed;
      _appliedOverride = seed;
      _searchOpenOnNarrow = true;
    }
    _maybeApplyDateSeed(widget.dateSeed);
  }

  @override
  void didUpdateWidget(TransactionsTab old) {
    super.didUpdateWidget(old);
    final seed = widget.searchOverride;
    if (seed != null && seed.isNotEmpty && seed != _appliedOverride) {
      setState(() {
        _searchQuery = seed;
        _searchController.text = seed;
        _appliedOverride = seed;
        _searchOpenOnNarrow = true;
      });
    }
    if (widget.dateSeed != null && widget.dateSeed != old.dateSeed) {
      _maybeApplyDateSeed(widget.dateSeed);
    }
  }

  /// Drop a chart-tap date window into the active filters. Pushes the
  /// `onDateSeedConsumed` callback so the dashboard clears its copy
  /// and manual filter edits aren't overwritten on the next rebuild.
  void _maybeApplyDateSeed(({DateTime start, DateTime end})? seed) {
    if (seed == null) return;
    // Schedule for after the current build so initState callers don't
    // setState during the build pass.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _filters = _filters.copyWith(
          dateRange: TxDateRange.custom,
          customStart: seed.start,
          customEnd: seed.end,
        );
      });
      widget.onDateSeedConsumed?.call();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<dynamic> get _filteredTransactions {
    final q = _searchQuery.toLowerCase();
    final hasSearch = q.isNotEmpty;
    final hasFilters = _filters.isActive;
    if (!hasSearch && !hasFilters) return widget.transactions;
    return widget.transactions.where((tx) {
      if (hasSearch) {
        // Filter on the displayed label (post-rename, post-counterparty
        // resolution) so a user-entered rename like "Costco" is searchable.
        // Also matches the raw description so the bank's "AMAZON.COM*9F3B"
        // still finds the row before the user renamed it.
        final label = displayLabel(Map<String, dynamic>.from(tx as Map))
            .toLowerCase();
        final desc = (tx['description'] ?? '').toString().toLowerCase();
        final orig = (tx['original_description'] ?? '').toString().toLowerCase();
        final merchant = (tx['merchant_name'] ?? '').toString().toLowerCase();
        final counterparty =
            (tx['counterparty_name'] ?? '').toString().toLowerCase();
        final payee = (tx['payment_payee'] ?? '').toString().toLowerCase();
        final payer = (tx['payment_payer'] ?? '').toString().toLowerCase();
        final acct = (tx['account_name'] ?? '').toString().toLowerCase();
        final cat = (tx['category'] ?? '').toString().toLowerCase();
        final matches = label.contains(q) ||
            desc.contains(q) ||
            orig.contains(q) ||
            merchant.contains(q) ||
            counterparty.contains(q) ||
            payee.contains(q) ||
            payer.contains(q) ||
            acct.contains(q) ||
            cat.contains(q);
        if (!matches) return false;
      }
      if (hasFilters && !_filters.matches(tx)) return false;
      return true;
    }).toList();
  }

  Future<void> _openFilters() async {
    final result = await showDialog<TxFilters>(
      context: context,
      builder: (_) => TxFiltersDialog(
        initial: _filters,
        transactions: widget.transactions,
        accounts: widget.accounts,
      ),
    );
    if (result != null && mounted) setState(() => _filters = result);
  }

  /// Removable chip strip below the toolbar showing every active filter
  /// in a single horizontal scroll. Tapping the X on a chip clears just
  /// that one; the strip hides entirely when nothing's active.
  Widget _activeFilterChips() {
    if (!_filters.isActive) return const SizedBox.shrink();
    final chips = <Widget>[];
    if (_filters.flow != TxFlow.all) {
      chips.add(_filterChip(
        _filters.flow == TxFlow.expense ? 'Expense' : 'Income',
        () => setState(() => _filters = _filters.copyWith(flow: TxFlow.all)),
      ));
    }
    if (_filters.status != TxStatus.all) {
      chips.add(_filterChip(
        _filters.status == TxStatus.pending ? 'Pending' : 'Settled',
        () => setState(
            () => _filters = _filters.copyWith(status: TxStatus.all)),
      ));
    }
    if (_filters.accountIds.isNotEmpty) {
      final byId = <String, String>{};
      for (final a in widget.accounts) {
        final id = a['id']?.toString();
        if (id == null) continue;
        final nick = (a['nickname'] ?? '').toString();
        final name = (a['name'] ?? '').toString();
        byId[id] = nick.isNotEmpty ? nick : name;
      }
      final names = _filters.accountIds.map((id) => byId[id] ?? id).toList();
      final label = names.length == 1
          ? names.first
          : '${names.first} +${names.length - 1}';
      chips.add(_filterChip(
        label,
        () => setState(() => _filters = _filters.copyWith(accountIds: {})),
      ));
    }
    if (_filters.categories.isNotEmpty) {
      final cats = _filters.categories.toList();
      final label =
          cats.length == 1 ? cats.first : '${cats.first} +${cats.length - 1}';
      chips.add(_filterChip(
        label,
        () => setState(() => _filters = _filters.copyWith(categories: {})),
      ));
    }
    if (_filters.dateRange != TxDateRange.all) {
      // For the custom range, show the actual start–end dates so the chip
      // is informative. For the preset windows, the enum's label suffices.
      String label;
      if (_filters.dateRange == TxDateRange.custom &&
          _filters.customStart != null &&
          _filters.customEnd != null) {
        label =
            '${DateFormat('MMM d').format(_filters.customStart!)}–${DateFormat('MMM d').format(_filters.customEnd!)}';
      } else {
        label = _filters.dateRange.label;
      }
      chips.add(_filterChip(
        label,
        () => setState(() => _filters = _filters.copyWith(
              dateRange: TxDateRange.all,
              clearCustomDates: true,
            )),
      ));
    }
    chips.add(TextButton(
      onPressed: () => setState(() => _filters = TxFilters.empty),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 28),
      ),
      child: const Text('Clear all'),
    ));
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final c in chips) ...[
              c,
              const SizedBox(width: 6),
            ],
          ],
        ),
      ),
    );
  }

  Widget _filterChip(String label, VoidCallback onRemove) {
    return InputChip(
      label: Text(label),
      onDeleted: onRemove,
      visualDensity: VisualDensity.compact,
      labelStyle: const TextStyle(fontSize: 12),
      deleteIconColor: context.textMuted,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.transactions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.receipt_long_outlined,
                size: 64, color: Colors.grey),
            const SizedBox(height: 16),
            Text(
              'No transactions yet',
              style: TextStyle(
                color: context.textMuted,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Link a bank, import a statement, or add an account manually\n'
              'to start seeing activity here.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: widget.onGoToManagement,
              icon: const Icon(Icons.add_link, size: 18),
              label: const Text('Go to Management'),
              style: FilledButton.styleFrom(
                backgroundColor: context.positive,
                foregroundColor: Colors.black,
              ),
            ),
          ],
        ),
      );
    }

    final filtered = _filteredTransactions;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: LayoutBuilder(builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 560;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildToolbar(isNarrow),
              _activeFilterChips(),
              const SizedBox(height: 8),
              Text(
                'Showing ${filtered.length} of ${widget.transactions.length}',
                style: const TextStyle(color: Colors.grey, fontSize: 12),
              ),
              const SizedBox(height: 8),
              if (_selectionMode) _buildBulkActionBar(filtered),
              // Flat list of rows with inline date-group headers
              // (Today / Yesterday / weekday name / "Month d"). Avoids
              // ListView.separated so we can interleave headers between
              // groups without inserting a divider above each header.
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: _buildGroupedRows(filtered, isNarrow),
              ),
              if (widget.onLoadMore != null && widget.hasMore)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Center(
                    child: _loadingMore
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : OutlinedButton.icon(
                            onPressed: () async {
                              setState(() => _loadingMore = true);
                              try {
                                await widget.onLoadMore!.call();
                              } finally {
                                if (mounted) {
                                  setState(() => _loadingMore = false);
                                }
                              }
                            },
                            icon: const Icon(Icons.expand_more, size: 18),
                            label: const Text('Load more'),
                          ),
                  ),
                ),
            ],
          );
        }),
      ),
    );
  }

  // Sticky-ish bulk-action bar that appears under the filter chip strip
  // whenever the user is in selection mode. "Select all" toggles every
  // currently-filtered row, the two action buttons run the multi-update,
  // and "Clear" exits selection mode without doing anything.
  Widget _buildBulkActionBar(List<dynamic> filtered) {
    final filteredIds = <String>[
      for (final t in filtered)
        if (t['id'] != null) t['id'].toString(),
    ];
    final allSelected = filteredIds.isNotEmpty &&
        filteredIds.every(_selectedIds.contains);
    final selectedCount = _selectedIds.length;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding:
          const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: context.positive.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.accentBorder(context.positive)),
      ),
      child: LayoutBuilder(builder: (ctx, c) {
        final isNarrow = c.maxWidth < 560;

        final selectToggle = TextButton.icon(
          onPressed: () => setState(() {
            if (allSelected) {
              _selectedIds.removeAll(filteredIds);
            } else {
              _selectedIds.addAll(filteredIds);
            }
          }),
          icon: Icon(
            allSelected
                ? Icons.indeterminate_check_box_outlined
                : Icons.select_all,
            size: 18,
          ),
          label: Text(allSelected ? 'Deselect all' : 'Select all'),
        );

        final categorize = FilledButton.tonalIcon(
          onPressed:
              selectedCount == 0 ? null : () => _bulkCategorize(),
          icon: const Icon(Icons.label_outline, size: 18),
          label: const Text('Set category'),
        );

        final moveAccount = FilledButton.tonalIcon(
          onPressed:
              selectedCount == 0 ? null : () => _bulkMoveAccount(),
          icon: const Icon(Icons.compare_arrows, size: 18),
          label: const Text('Move account'),
        );

        final clear = TextButton(
          onPressed: () => setState(() {
            _selectionMode = false;
            _selectedIds.clear();
          }),
          child: const Text('Clear'),
        );

        final summary = Text(
          '$selectedCount selected',
          style: TextStyle(
              fontWeight: FontWeight.w700, color: context.positive),
        );

        if (isNarrow) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              summary,
              const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                selectToggle,
                categorize,
                moveAccount,
                clear,
              ]),
            ],
          );
        }
        return Row(
          children: [
            summary,
            const SizedBox(width: 16),
            selectToggle,
            const Spacer(),
            categorize,
            const SizedBox(width: 8),
            moveAccount,
            const SizedBox(width: 8),
            clear,
          ],
        );
      }),
    );
  }

  Future<void> _bulkCategorize() async {
    final controller = TextEditingController();
    final cat = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Set category'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'e.g. Restaurants',
          ),
          onSubmitted: (v) => Navigator.pop(context, v.trim()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(context, controller.text.trim()),
              child: const Text('Apply')),
        ],
      ),
    );
    if (cat == null || cat.isEmpty) return;
    await _applyBulkUpdate(userCategory: cat);
  }

  Future<void> _bulkMoveAccount() async {
    final accId = await showDialog<String>(
      context: context,
      builder: (_) {
        return SimpleDialog(
          title: const Text('Move to account'),
          children: [
            for (final a in widget.accounts)
              SimpleDialogOption(
                onPressed: () =>
                    Navigator.pop(context, a['id']?.toString()),
                child: Text(
                  ((a['nickname'] ?? '').toString().isNotEmpty
                      ? a['nickname'].toString()
                      : (a['name'] ?? '').toString()),
                ),
              ),
          ],
        );
      },
    );
    if (accId == null || accId.isEmpty) return;
    await _applyBulkUpdate(accountId: accId);
  }

  /// Open the rename dialog for a single transaction. Empty string saves
  /// as "clear the override" (sets user_description back to NULL — row
  /// reverts to the auto-picked label). The raw bank description stays
  /// untouched regardless.
  ///
  /// When [similarIds] is non-empty the dialog offers a "also apply to N
  /// other rows that share this raw description" checkbox. Picking it
  /// runs the same PATCH against every id so the user can squash a
  /// cluster of "Miscellaneous Debit" rows in one stroke.
  Future<void> _renameTransaction(
    dynamic tx, {
    List<String> similarIds = const [],
  }) async {
    final onUpdate = widget.onUpdate;
    if (onUpdate == null) return;
    final controller = TextEditingController(
      text: (tx['user_description'] ?? '').toString(),
    );
    // Default: applyToAll is true when there ARE similar rows — most
    // users renaming a generic "Miscellaneous Debit" want it to stick
    // for the whole cluster. They can untick if they want one-off.
    var applyToAll = similarIds.isNotEmpty;
    final result = await showDialog<({String text, bool applyToAll})?>(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(builder: (ctx, setLocal) {
          return AlertDialog(
            title: const Text('Rename transaction'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Display label only. The original bank description is '
                  'preserved and remains visible in this row’s detail '
                  'panel under "Raw bank text".',
                  style: TextStyle(fontSize: 12, color: context.textSubtle),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Display label',
                    hintText: 'e.g. Rent — John',
                    border: OutlineInputBorder(),
                  ),
                ),
                if (similarIds.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: applyToAll,
                    onChanged: (v) =>
                        setLocal(() => applyToAll = v ?? false),
                    title: Text(
                      'Also apply to ${similarIds.length} matching '
                      'transaction${similarIds.length == 1 ? '' : 's'}',
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      'Rows that share this raw bank description.',
                      style: TextStyle(
                          fontSize: 11, color: context.textSubtle),
                    ),
                  ),
                ],
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(null),
                child: const Text('Cancel'),
              ),
              // Clear button only when something is set on the row already
              // — avoids a dead button on transactions that never had an
              // override applied.
              if ((tx['user_description'] ?? '').toString().isNotEmpty)
                TextButton(
                  onPressed: () => Navigator.of(ctx)
                      .pop((text: '', applyToAll: applyToAll)),
                  child: const Text('Clear override'),
                ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop((
                  text: controller.text.trim(),
                  applyToAll: applyToAll,
                )),
                child: const Text('Save'),
              ),
            ],
          );
        });
      },
    );
    if (result == null || !mounted) return;
    // Close the detail modal so the rename takes effect on the
    // refreshed list rather than the stale copy this dialog opened on.
    Navigator.of(context).pop();
    final ids = <String>[
      tx['id'].toString(),
      if (result.applyToAll) ...similarIds,
    ];
    final messenger = ScaffoldMessenger.of(context);
    var failed = 0;
    for (final id in ids) {
      try {
        await onUpdate(id, userDescription: result.text);
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          ids.length == 1
              ? (failed == 0
                  ? 'Renamed'
                  : 'Rename failed')
              : (failed == 0
                  ? 'Renamed ${ids.length} transactions'
                  : 'Renamed ${ids.length - failed} · $failed failed'),
        ),
      ),
    );
  }

  // Per-tx PATCH is the only API we have, so we loop. With ~hundreds of
  // selected rows this is still fast on a desktop network — keep simple.
  Future<void> _applyBulkUpdate(
      {String? userCategory, String? accountId}) async {
    final onUpdate = widget.onUpdate;
    if (onUpdate == null) return;
    final ids = _selectedIds.toList();
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text('Updating ${ids.length} transactions…')),
    );
    var failed = 0;
    for (final id in ids) {
      try {
        await onUpdate(id,
            userCategory: userCategory, accountId: accountId);
      } catch (_) {
        failed++;
      }
    }
    if (!mounted) return;
    setState(() {
      _selectedIds.clear();
      _selectionMode = false;
    });
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          failed == 0
              ? 'Updated ${ids.length} transactions'
              : 'Updated ${ids.length - failed} · $failed failed',
        ),
      ),
    );
  }

  /// Header toolbar. On wide screens shows title + inline search. On narrow
  /// screens the search collapses to an icon button that expands into a
  /// full-width input, so the title doesn't fight a 280px search box for
  /// horizontal space.
  Widget _buildToolbar(bool isNarrow) {
    if (isNarrow && _searchOpenOnNarrow) {
      return Row(
        children: [
          Expanded(child: _searchField()),
          const SizedBox(width: 8),
          IconButton(
            onPressed: () => setState(() {
              _searchOpenOnNarrow = false;
              _searchQuery = '';
            }),
            icon: const Icon(Icons.close, size: 20),
            tooltip: 'Close search',
          ),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Flexible(
          child: Text(
            'Recent transactions',
            style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Filter button with a small dot badge when any filters are
            // active. Always visible — independent of apiService.
            Stack(
              clipBehavior: Clip.none,
              children: [
                IconButton(
                  onPressed: _openFilters,
                  icon: const Icon(Icons.filter_list, size: 22),
                  tooltip: 'Filter transactions',
                ),
                if (_filters.isActive)
                  Positioned(
                    right: 6,
                    top: 6,
                    child: Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: context.positive,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
              ],
            ),
            IconButton(
              onPressed: () => setState(() {
                _selectionMode = !_selectionMode;
                if (!_selectionMode) _selectedIds.clear();
              }),
              icon: Icon(
                _selectionMode ? Icons.close : Icons.checklist,
                size: 22,
                color: _selectionMode ? context.positive : null,
              ),
              tooltip:
                  _selectionMode ? 'Exit selection mode' : 'Select multiple',
            ),
            if (widget.apiService != null) ...[
              IconButton(
                onPressed: () => _openAddDialog(),
                icon: const Icon(Icons.add, size: 22),
                tooltip: 'Add transaction',
              ),
              IconButton(
                onPressed: () => _downloadCsv(),
                icon: const Icon(Icons.file_download_outlined, size: 22),
                tooltip: 'Export CSV',
              ),
            ],
            if (widget.onDetectFxTransfers != null)
              IconButton(
                tooltip: 'Scan for cross-currency transfers (Wise / Remitly / etc.)',
                icon: const Icon(Icons.swap_horiz, size: 22),
                onPressed: () => widget.onDetectFxTransfers!(),
              ),
            if (isNarrow)
              IconButton(
                onPressed: () =>
                    setState(() => _searchOpenOnNarrow = true),
                icon: const Icon(Icons.search, size: 20),
                tooltip: 'Search transactions',
              )
            else
              SizedBox(width: 280, height: 40, child: _searchField()),
          ],
        ),
      ],
    );
  }

  void _openAddDialog() {
    if (widget.apiService == null) return;
    showDialog(
      context: context,
      builder: (_) => AddTransactionDialog(
        accounts: widget.accounts,
        apiService: widget.apiService!,
        onCreated: () => widget.onTransactionAdded?.call(),
      ),
    );
  }

  void _downloadCsv() {
    if (widget.apiService == null) return;
    // Hand off to the browser — the backend responds with
    // Content-Disposition: attachment so the browser downloads directly.
    web.window.open(widget.apiService!.exportTransactionsCsvUrl(), '_self');
  }

  Widget _searchField() {
    return TextField(
      autofocus: _searchOpenOnNarrow,
      controller: _searchController,
      onChanged: (v) => setState(() => _searchQuery = v),
      decoration: InputDecoration(
        hintText: 'Search transactions…',
        hintStyle: TextStyle(color: context.textFaint, fontSize: 13),
        prefixIcon:
            Icon(Icons.search, size: 18, color: context.textFaint),
        filled: true,
        fillColor: context.tint(0.05),
        contentPadding:
            const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
      ),
      style: const TextStyle(fontSize: 13),
    );
  }

  /// Group the filtered transactions into Today / Yesterday / weekday /
  /// "Month d" sections so a long scroll is scannable. Hairline dividers
  /// sit *between* rows within a group but not above the header — that's
  /// why we hand-roll the list instead of using ListView.separated.
  List<Widget> _buildGroupedRows(List<dynamic> txs, bool isNarrow) {
    final out = <Widget>[];
    String? lastGroup;
    for (var i = 0; i < txs.length; i++) {
      final tx = txs[i];
      final dateStr = tx['date'] as String?;
      if (dateStr == null) continue;
      final date = DateTime.parse(dateStr);
      final key = _dateGroupKey(date);
      if (key != lastGroup) {
        out.add(_dateGroupHeader(date, isFirst: lastGroup == null));
        lastGroup = key;
      } else {
        out.add(Divider(
          height: 1,
          thickness: 1,
          color: context.hairline,
          indent: 44, // align with the description column, past the icon
        ));
      }
      out.add(_buildTransactionRow(tx, isNarrow));
    }
    return out;
  }

  /// Stable key for grouping. "today" / "yesterday" / yyyy-mm-dd otherwise.
  String _dateGroupKey(DateTime date) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(date.year, date.month, date.day);
    final diff = today.difference(d).inDays;
    if (diff == 0) return 'today';
    if (diff == 1) return 'yesterday';
    return '${date.year}-${date.month}-${date.day}';
  }

  /// Section heading shown above each date group. Reads "Today" /
  /// "Yesterday" / weekday for the past week, then "Month d" / "Month d,
  /// yyyy" for older dates.
  Widget _dateGroupHeader(DateTime date, {required bool isFirst}) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(date.year, date.month, date.day);
    final diff = today.difference(d).inDays;
    String label;
    if (diff == 0) {
      label = 'Today';
    } else if (diff == 1) {
      label = 'Yesterday';
    } else if (diff > 1 && diff < 7) {
      label = DateFormat('EEEE').format(date);
    } else if (date.year == now.year) {
      label = DateFormat('MMM d').format(date);
    } else {
      label = DateFormat('MMM d, y').format(date);
    }
    return Padding(
      padding: EdgeInsets.only(
        top: isFirst ? 4 : 18,
        bottom: 6,
        left: 4,
        right: 4,
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: context.textSubtle,
          letterSpacing: 0.6,
        ),
      ),
    );
  }

  /// One row in the transactions list. Modern dense layout — 32px icon,
  /// single-line description + meta, right-aligned native-currency amount.
  /// Total row height is ~56px (was 92), so a wall of transactions
  /// actually feels like a scannable list instead of an inbox of cards.
  Widget _buildTransactionRow(dynamic tx, bool isNarrow) {
    final sourceAmount = ((tx['amount'] as num?)?.toDouble() ?? 0.0);
    final sourceCurrency =
        (tx['currency'] ?? widget.targetCurrency).toString();
    final converted = convertCurrency(
      sourceAmount,
      from: sourceCurrency,
      to: widget.targetCurrency,
      usdMxnRate: widget.usdMxnRate,
    );
    final isExpense = sourceAmount > 0;
    final category = tx['user_category'] ?? tx['category'];
    final notes = (tx['user_notes'] ?? '').toString();
    final color = _getCategoryColor(category, tx['description']);

    final needsConversion =
        widget.usdMxnRate > 0 && sourceCurrency != widget.targetCurrency;

    final id = tx['id']?.toString();
    final isSelected = id != null && _selectedIds.contains(id);

    return InkWell(
      onTap: () {
        if (_selectionMode && id != null) {
          setState(() {
            if (isSelected) {
              _selectedIds.remove(id);
            } else {
              _selectedIds.add(id);
            }
          });
        } else {
          _showTransactionDetails(tx);
        }
      },
      onLongPress: () {
        if (id != null) {
          setState(() {
            _selectionMode = true;
            _selectedIds.add(id);
          });
        }
      },
      hoverColor: context.tint(0.03),
      child: AnimatedContainer(
        // Three overlapping signals share this background:
        // selection mode (green, instant flip), Cmd-K row highlight
        // (blue pulse — fades in and out via this AnimatedContainer
        // with an easeInOut curve so the entrance and exit feel
        // symmetric rather than the default linear ColorTween), and
        // the default unhighlighted state (transparent).
        //
        // Using Colors.transparent rather than `null` as the off state
        // guarantees AnimatedContainer interpolates instead of snapping
        // — a null → Color flip would be discontinuous to the lerp.
        duration: const Duration(milliseconds: 550),
        curve: Curves.easeInOut,
        color: isSelected
            ? context.positive.withValues(alpha: 0.1)
            : (id != null && id == widget.highlightedTxId)
                ? context.info.withValues(alpha: 0.2)
                : Colors.transparent,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            if (_selectionMode) ...[
              SizedBox(
                width: 32,
                child: Checkbox(
                  value: isSelected,
                  onChanged: id == null
                      ? null
                      : (v) => setState(() {
                            if (v == true) {
                              _selectedIds.add(id);
                            } else {
                              _selectedIds.remove(id);
                            }
                          }),
                ),
              ),
              const SizedBox(width: 4),
            ],
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                _getCategoryIcon(category, tx['description']),
                color: color,
                size: 16,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    displayLabel(tx),
                    style: const TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      height: 1.2,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _metaLine(tx, notes),
                    style: TextStyle(
                      color: context.textSubtle,
                      fontSize: 11,
                      height: 1.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Right-aligned amount. Bold native currency on top, optional
            // converted estimate below (desktop only — narrow viewports
            // hide it so the description column has breathing room).
            ConstrainedBox(
              constraints: BoxConstraints(maxWidth: isNarrow ? 100 : 140),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${isExpense ? '−' : '+'}${formatCurrencyAmount(sourceAmount.abs(), sourceCurrency)}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: isExpense ? context.textPrimary : context.positive,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (needsConversion && !isNarrow)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        '≈ ${widget.currencyFormat.format(converted.abs())}',
                        style: TextStyle(
                          fontSize: 10,
                          color: context.textFaint,
                          fontFeatures: [const FontFeature.tabularFigures()],
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  if (tx['pending'] == true)
                    Container(
                      margin: const EdgeInsets.only(top: 3),
                      padding: const EdgeInsets.symmetric(
                          horizontal: 5, vertical: 1),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: const Text(
                        'Pending',
                        style: TextStyle(
                          color: Colors.orange,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Compact secondary line. The date is now in the group header above,
  /// so we drop it here and surface category instead — keeping the row
  /// to one line of meta even when there's a user note attached. The
  /// category is run through prettyCategory so Plaid's screaming
  /// "LOAN_PAYMENTS" reads as "Loan payment" / "Credit card payment".
  String _metaLine(dynamic tx, String notes) {
    final account = (tx['account_name'] ?? '').toString();
    final cat = prettyCategory(
      userCategory: tx['user_category']?.toString(),
      detailed: tx['category_detailed']?.toString(),
      primary: tx['category']?.toString(),
    );
    final parts = <String>[
      if (cat.isNotEmpty && cat != 'Uncategorized') cat,
      if (account.isNotEmpty) account,
      if (notes.isNotEmpty) notes,
    ];
    return parts.join(' · ');
  }

  /// Detail modal. Layout (top to bottom):
  /// - Close button
  /// - Big category icon + description title
  /// - Hero amount block (target currency, companion currency, in/out)
  /// - Chip row: Date · Account · Source · Pending
  /// - Raw bank description (if differs from title)
  /// - Editable: Category + Notes
  /// - "Recent at this merchant" — up to 3 other transactions matching description
  /// - Save / Close footer
  void _showTransactionDetails(dynamic tx) {
    final catController = TextEditingController(
      text: (tx['user_category'] ?? tx['category'] ?? '').toString(),
    );
    final notesController = TextEditingController(
      text: (tx['user_notes'] ?? '').toString(),
    );

    final date = DateTime.parse(tx['date'] as String);
    final sourceAmount = ((tx['amount'] as num?)?.toDouble() ?? 0.0);
    final sourceCurrency =
        (tx['currency'] ?? widget.targetCurrency).toString();
    final convertedAmount = convertCurrency(
      sourceAmount,
      from: sourceCurrency,
      to: widget.targetCurrency,
      usdMxnRate: widget.usdMxnRate,
    );
    final needsConversion =
        widget.usdMxnRate > 0 && sourceCurrency != widget.targetCurrency;
    final isExpense = sourceAmount > 0;
    final source = (tx['source'] ?? 'plaid').toString();
    final originalCategory = (tx['category'] ?? '').toString();
    final merchant = (tx['merchant_name'] ?? '').toString();
    final pending = tx['pending'] == true;
    final rawDescription = (tx['description'] ?? '').toString();
    final titleDescription = displayLabel(tx);
    final logoUrl = counterpartyLogo(tx);
    final originalDescription = (tx['original_description'] ?? '').toString();
    final color = _getCategoryColor(
      tx['user_category'] ?? tx['category'],
      rawDescription,
    );

    // All transactions sharing this exact description (excluding the
    // current one). We use the full set to compute lifetime spend at
    // this merchant, then take(3) for the visible recent rows.
    final merchantMatches = widget.transactions.where((other) {
      if (other['id'] == tx['id']) return false;
      return (other['description'] ?? '').toString().trim().toLowerCase() ==
          rawDescription.trim().toLowerCase();
    }).toList();
    final similar = merchantMatches.take(3).toList();
    // Lifetime spend at this merchant (including the current tx),
    // converted to the reporting currency. Use the absolute value
    // since incoming/outgoing share a sign convention we don't need
    // to disambiguate in a single rollup.
    final merchantTotal = merchantMatches.fold<double>(
      sourceAmount.abs(),
      (sum, other) {
        final amt = ((other['amount'] as num?)?.toDouble() ?? 0.0).abs();
        final otherCcy = (other['currency'] ?? widget.targetCurrency)
            .toString();
        return sum +
            convertCurrency(
              amt,
              from: otherCcy,
              to: widget.targetCurrency,
              usdMxnRate: widget.usdMxnRate,
            );
      },
    );
    final merchantCount = merchantMatches.length + 1;

    // Slide-from-right side panel on wide screens, bottom-sheet on narrow.
    // This is the Linear / Notion / Gmail pattern — keeps the underlying
    // list visible (in spirit) instead of slamming a centered modal that
    // reads as a full page.
    final size = MediaQuery.sizeOf(context);
    final isNarrow = size.width < 700;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'Dismiss',
      barrierColor: Colors.black.withValues(alpha: 0.4),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, anim, secAnim) {
        return Align(
          alignment:
              isNarrow ? Alignment.bottomCenter : Alignment.centerRight,
          child: Material(
            color: Colors.transparent,
            child: Container(
              width: isNarrow ? size.width : 480,
              height: isNarrow ? size.height * 0.9 : size.height,
              decoration: BoxDecoration(
                color: Theme.of(ctx).colorScheme.surface,
                borderRadius: isNarrow
                    ? const BorderRadius.vertical(top: Radius.circular(20))
                    : const BorderRadius.horizontal(left: Radius.circular(20)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 24,
                    offset: const Offset(-4, 0),
                  ),
                ],
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      onPressed: () => Navigator.pop(context),
                      tooltip: 'Close',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                    ),
                  ),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      Container(
                        width: 52,
                        height: 52,
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        // Counterparty logo when Plaid sent one, else the
                        // category icon. Logo failures (network drop,
                        // 404, CSP block) silently fall back to the icon.
                        child: logoUrl != null
                            ? Image.network(
                                logoUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Icon(
                                  _getCategoryIcon(
                                    tx['user_category'] ?? tx['category'],
                                    rawDescription,
                                  ),
                                  color: color,
                                  size: 28,
                                ),
                              )
                            : Icon(
                                _getCategoryIcon(
                                  tx['user_category'] ?? tx['category'],
                                  rawDescription,
                                ),
                                color: color,
                                size: 28,
                              ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    titleDescription,
                                    style: const TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.bold,
                                    ),
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                // Rename pencil — opens a dialog to
                                // set/clear the per-row override. The
                                // raw description stays untouched and
                                // remains visible in "Raw bank text"
                                // below.
                                IconButton(
                                  tooltip: merchantMatches.isEmpty
                                      ? 'Rename'
                                      : 'Rename (+${merchantMatches.length} matching)',
                                  iconSize: 18,
                                  visualDensity: VisualDensity.compact,
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () => _renameTransaction(
                                    tx,
                                    similarIds: merchantMatches
                                        .map((m) => m['id'].toString())
                                        .toList(),
                                  ),
                                ),
                              ],
                            ),
                            if (merchant.isNotEmpty &&
                                merchant.toLowerCase() !=
                                    titleDescription.toLowerCase()) ...[
                              const SizedBox(height: 2),
                              Text(
                                merchant,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: context.textSubtle,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 20),
                  // Hero amount block — biggest visual element
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 18, vertical: 16),
                    decoration: BoxDecoration(
                      color: context.tint(0.04),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: (isExpense ? context.negative : context.tealAccent)
                            .withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          isExpense ? 'OUTFLOW' : 'INFLOW',
                          style: TextStyle(
                            fontSize: 10,
                            letterSpacing: 1.2,
                            color: isExpense
                                ? context.pinkAccent
                                : context.tealAccent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        // Hero amount in the transaction's NATIVE currency
                        // (this is the real, bank-reported value).
                        Text(
                          '${isExpense ? '−' : '+'}${formatCurrencyAmount(sourceAmount.abs(), sourceCurrency)}',
                          style: TextStyle(
                            fontSize: 32,
                            fontWeight: FontWeight.w900,
                            color: isExpense
                                ? context.textPrimary
                                : context.positive,
                          ),
                        ),
                        if (needsConversion) ...[
                          const SizedBox(height: 4),
                          Text(
                            '≈ ${widget.currencyFormat.format(convertedAmount.abs())} (estimated)',
                            style: TextStyle(
                              fontSize: 12,
                              color: context.textSubtle,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Metadata chips
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _metaChip(
                        Icons.event,
                        DateFormat('EEE, MMM d, y').format(date),
                      ),
                      if ((tx['account_name'] ?? '').toString().isNotEmpty)
                        _metaChip(Icons.account_balance,
                            tx['account_name'].toString()),
                      _metaChip(Icons.cloud_download, _sourceLabel(source)),
                      // The auto-classified category, prettified from
                      // Plaid's PFC enum codes. Only shown when the user
                      // hasn't already overridden it with a hand-typed
                      // category.
                      if ((tx['user_category'] ?? '').toString().isEmpty &&
                          (originalCategory.isNotEmpty ||
                              (tx['category_detailed'] ?? '')
                                  .toString()
                                  .isNotEmpty))
                        _metaChip(
                          Icons.label_outline,
                          prettyCategory(
                            detailed: tx['category_detailed']?.toString(),
                            primary: tx['category']?.toString(),
                          ),
                        ),
                      // Hide the channel chip when Plaid only knows it's
                      // "other" — that adds noise but no information.
                      // Online / in-store are the useful signal.
                      if (((tx['payment_channel'] ?? '').toString().isNotEmpty) &&
                          (tx['payment_channel'] ?? '').toString() != 'other')
                        _metaChip(
                          _channelIcon(
                              (tx['payment_channel'] ?? '').toString()),
                          _sentence((tx['payment_channel'] ?? '')
                              .toString()
                              .replaceAll('_', ' ')),
                        ),
                      if ((tx['merchant_name'] ?? '')
                              .toString()
                              .isNotEmpty &&
                          (tx['merchant_name'] ?? '').toString() !=
                              titleDescription)
                        _metaChip(Icons.storefront,
                            (tx['merchant_name'] ?? '').toString()),
                      if (pending)
                        _metaChip(Icons.hourglass_empty, 'Pending',
                            accent: Colors.orange),
                    ],
                  ),
                  if (rawDescription != titleDescription) ...[
                    const SizedBox(height: 16),
                    _sectionLabel('Raw bank text'),
                    const SizedBox(height: 4),
                    SelectableText(
                      rawDescription,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.textMuted,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                  const SizedBox(height: 18),
                  _sectionLabel('Category & notes'),
                  const SizedBox(height: 8),
                  TextField(
                    controller: catController,
                    decoration: InputDecoration(
                      labelText: 'Category',
                      hintText: originalCategory.isNotEmpty
                          ? 'e.g. $originalCategory'
                          : null,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: notesController,
                    decoration: const InputDecoration(
                      labelText: 'Notes',
                      hintText: 'Why does this transaction matter?',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    maxLines: 3,
                  ),
                  // Linked cross-currency transfer block — surfaces
                  // when this tx is one leg of a Wise / Remitly / etc.
                  // pair. Confirm / Unlink act on the
                  // cash_fx_transfers row. The block is silent on
                  // rows that don't participate in any link.
                  ..._fxTransferBlock(tx['id']?.toString() ?? ''),
                  if (similar.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _sectionLabel('Recent at this merchant'),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        'Total: ${widget.currencyFormat.format(merchantTotal)} across $merchantCount transactions',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.textMuted,
                          fontFeatures: [const FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                    ...similar.map((other) => _similarRow(other)),
                  ],
                  if (widget.accounts.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _sectionLabel('Move to a different account'),
                    const SizedBox(height: 6),
                    _AccountMover(
                      accounts: widget.accounts,
                      currentAccountId: tx['account_id']?.toString(),
                      onMove: (newAccountId) async {
                        Navigator.pop(context);
                        try {
                          await Future.value(widget.onUpdate?.call(
                            tx['id'],
                            accountId: newAccountId,
                          ));
                        } catch (e) {
                          if (!mounted) return;
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(content: Text('Move failed: $e')),
                          );
                        }
                      },
                    ),
                  ],
                  const SizedBox(height: 20),
                  Row(
                    children: [
                      if (widget.onDelete != null)
                        TextButton.icon(
                          onPressed: () async {
                            final confirm = await showDialog<bool>(
                              context: context,
                              builder: (ctx) => AlertDialog(
                                title: const Text('Delete transaction?'),
                                content: const Text(
                                    'This permanently removes the transaction. To re-import from CSV/PDF you will need to upload the file again.'),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: const Text('Cancel')),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(ctx, true),
                                    style: TextButton.styleFrom(
                                        foregroundColor: Colors.redAccent),
                                    child: const Text('Delete'),
                                  ),
                                ],
                              ),
                            );
                            if (confirm != true) return;
                            if (!mounted) return;
                            Navigator.pop(context);
                            try {
                              await widget.onDelete!(tx['id']);
                            } catch (e) {
                              if (!mounted) return;
                              ScaffoldMessenger.of(context).showSnackBar(
                                SnackBar(
                                    content:
                                        Text('Delete failed: $e')),
                              );
                            }
                          },
                          icon: const Icon(Icons.delete_outline,
                              size: 16, color: Colors.redAccent),
                          label: const Text('Delete',
                              style: TextStyle(color: Colors.redAccent)),
                        ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context);
                          widget.onUpdate?.call(
                            tx['id'],
                            userCategory: catController.text.trim(),
                            userNotes: notesController.text.trim(),
                          );
                        },
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
        );
      },
      transitionBuilder: (ctx, anim, secAnim, child) {
        final tween = Tween<Offset>(
          begin: isNarrow ? const Offset(0, 1) : const Offset(1, 0),
          end: Offset.zero,
        ).chain(CurveTween(curve: Curves.easeOutCubic));
        return SlideTransition(position: anim.drive(tween), child: child);
      },
    );
  }

  /// Detail-modal block for any cross-currency cash transfer this
  /// transaction is part of. Returns an empty list when the tx isn't
  /// linked, so callers can spread it unconditionally.
  ///
  /// Auto-detected links get a "Confirm" button (sets user_confirmed
  /// on the row); confirmed and auto-detected alike get "Unlink"
  /// which removes the link entirely.
  List<Widget> _fxTransferBlock(String txId) {
    if (txId.isEmpty || widget.fxTransfers.isEmpty) {
      return const [];
    }
    final matches = widget.fxTransfers.where((raw) {
      if (raw is! Map) return false;
      return raw['source_tx_id']?.toString() == txId ||
          raw['dest_tx_id']?.toString() == txId;
    }).toList();
    if (matches.isEmpty) return const [];

    final widgets = <Widget>[
      const SizedBox(height: 20),
      _sectionLabel('Linked cross-currency transfer'),
      const SizedBox(height: 6),
    ];
    for (final raw in matches) {
      final m = raw as Map<String, dynamic>;
      final isSource = m['source_tx_id']?.toString() == txId;
      final otherLabel = (isSource
              ? m['dest_label']
              : m['source_label'])
          ?.toString() ??
          '—';
      final otherDate =
          (isSource ? m['dest_date'] : m['source_date'])?.toString() ?? '';
      final implied = (m['implied_fx_rate'] as num?)?.toDouble() ?? 0.0;
      final srcAmt = (m['source_amount'] as num?)?.toDouble() ?? 0.0;
      final dstAmt = (m['dest_amount'] as num?)?.toDouble() ?? 0.0;
      final srcCcy = (m['source_currency'] ?? '').toString();
      final dstCcy = (m['dest_currency'] ?? '').toString();
      final confirmed = m['user_confirmed'] == true;
      final confidence = (m['detection_confidence'] as num?)?.toInt() ?? 0;
      final keyword = (m['matched_keyword'] ?? '').toString();

      final accent = confirmed ? context.tealAccent : context.warning;

      widgets.add(Container(
        margin: const EdgeInsets.only(top: 6),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          color: context.accentSoft(accent),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: context.accentBorder(accent)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.swap_horiz, size: 14, color: accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    isSource
                        ? '→ $otherLabel${otherDate.isEmpty ? '' : ' · $otherDate'}'
                        : '← $otherLabel${otherDate.isEmpty ? '' : ' · $otherDate'}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: context.textPrimary,
                      fontSize: 13,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(
                  confirmed
                      ? 'Confirmed'
                      : 'Auto · $confidence%${keyword.isEmpty ? '' : ' · $keyword'}',
                  style: TextStyle(
                    fontSize: 11,
                    color: accent,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              '${_formatNative(srcAmt, srcCcy)} → ${_formatNative(dstAmt, dstCcy)} '
              '· implied ${implied.toStringAsFixed(2)} $dstCcy/$srcCcy',
              style: TextStyle(
                fontSize: 12,
                color: context.textMuted,
                fontFeatures: const [FontFeature.tabularFigures()],
              ),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (!confirmed && widget.onConfirmFxTransfer != null)
                  TextButton(
                    onPressed: () async {
                      Navigator.of(context).pop();
                      await widget.onConfirmFxTransfer!(m['id'].toString());
                    },
                    child: const Text('Confirm'),
                  ),
                if (widget.onUnlinkFxTransfer != null)
                  TextButton(
                    onPressed: () async {
                      Navigator.of(context).pop();
                      await widget.onUnlinkFxTransfer!(m['id'].toString());
                    },
                    child: Text(
                      'Unlink',
                      style: TextStyle(color: context.negative),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ));
    }
    return widgets;
  }

  /// Format a native-currency amount as "USD 1,234.56". Keeps the
  /// currency code visible so the user can read both legs of a
  /// transfer at a glance.
  String _formatNative(double amount, String currency) {
    final fmt = NumberFormat.currency(name: currency, symbol: '$currency ');
    return fmt.format(amount.abs());
  }

  Widget _sectionLabel(String label) {
    return Text(
      label.toUpperCase(),
      style: TextStyle(
        fontSize: 11,
        color: context.textSubtle,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.0,
      ),
    );
  }

  Widget _metaChip(IconData icon, String label, {Color? accent}) {
    final c = accent ?? context.textMuted;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: c.withValues(alpha: 0.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: c),
          const SizedBox(width: 6),
          Text(label, style: TextStyle(fontSize: 12, color: c)),
        ],
      ),
    );
  }

  String _sourceLabel(String source) {
    switch (source) {
      case 'plaid':
        return 'Synced via Plaid';
      case 'csv':
        return 'Imported (CSV)';
      case 'manual':
        return 'Manual entry';
      default:
        return source.isEmpty ? 'Unknown source' : source;
    }
  }

  /// Icon for Plaid's payment_channel ("online" / "in_store" / "other").
  IconData _channelIcon(String channel) {
    switch (channel.toLowerCase()) {
      case 'online':
        return Icons.shopping_cart_outlined;
      case 'in store':
      case 'in_store':
        return Icons.storefront_outlined;
      case 'other':
        return Icons.swap_horiz;
      default:
        return Icons.help_outline;
    }
  }

  String _sentence(String s) {
    if (s.isEmpty) return s;
    return s[0].toUpperCase() + s.substring(1).toLowerCase();
  }

  Widget _similarRow(dynamic other) {
    final otherDate = DateTime.parse(other['date'] as String);
    final otherSourceAmount =
        ((other['amount'] as num?)?.toDouble() ?? 0.0);
    final otherSourceCurrency =
        (other['currency'] ?? widget.targetCurrency).toString();
    final otherIsExpense = otherSourceAmount > 0;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(Icons.history, size: 14, color: context.textFaint),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${DateFormat('MMM d').format(otherDate)} · ${other['account_name'] ?? ''}',
              style: TextStyle(fontSize: 12, color: context.textMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '${otherIsExpense ? '−' : '+'}${formatCurrencyAmount(otherSourceAmount.abs(), otherSourceCurrency)}',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: otherIsExpense ? context.textPrimary : context.positive,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  NumberFormat get currencyFormat => widget.currencyFormat;

  IconData _getCategoryIcon(String? category, String? description) {
    final cat = (category ?? '').toLowerCase();
    final desc = (description ?? '').toLowerCase();
    // Plaid-style categories
    if (cat.contains('food') ||
        cat.contains('dining') ||
        desc.contains('starbucks') ||
        desc.contains('mcdonald')) {
      return Icons.restaurant;
    }
    if (cat.contains('travel') ||
        desc.contains('airline') ||
        desc.contains('united')) {
      return Icons.flight;
    }
    if (cat.contains('shopping') || desc.contains('amazon')) {
      return Icons.shopping_bag;
    }
    if (cat.contains('transfer') ||
        desc.contains('ach') ||
        desc.contains('wire')) {
      return Icons.sync_alt;
    }
    if (cat.contains('payment') ||
        desc.contains('payment') ||
        desc.contains('credit card')) {
      return Icons.payment;
    }
    if (cat.contains('entertainment') ||
        desc.contains('netflix') ||
        desc.contains('spotify')) {
      return Icons.movie;
    }
    if (cat.contains('recreation') ||
        desc.contains('climbing') ||
        desc.contains('gym')) {
      return Icons.fitness_center;
    }
    if (cat.contains('deposit') || desc.contains('deposit')) {
      return Icons.account_balance;
    }
    if (cat.contains('uber') ||
        desc.contains('uber') ||
        desc.contains('lyft')) {
      return Icons.directions_car;
    }
    if (cat.contains('personal') || cat.contains('service')) {
      return Icons.person;
    }
    return Icons.receipt;
  }

  Color _getCategoryColor(String? category, String? description) {
    final cat = (category ?? '').toLowerCase();
    final desc = (description ?? '').toLowerCase();
    if (cat.contains('food') ||
        cat.contains('dining') ||
        desc.contains('starbucks') ||
        desc.contains('mcdonald')) {
      return Colors.orange;
    }
    if (cat.contains('travel') ||
        desc.contains('airline') ||
        desc.contains('united')) {
      return Colors.blue;
    }
    if (cat.contains('shopping') || desc.contains('amazon')) {
      return Colors.purple;
    }
    if (cat.contains('transfer') ||
        desc.contains('ach') ||
        desc.contains('wire')) {
      return Colors.teal;
    }
    if (cat.contains('payment') ||
        desc.contains('payment') ||
        desc.contains('credit card')) {
      return Colors.green;
    }
    if (cat.contains('entertainment') ||
        desc.contains('netflix') ||
        desc.contains('spotify')) {
      return Colors.pink;
    }
    if (cat.contains('recreation') ||
        desc.contains('climbing') ||
        desc.contains('gym')) {
      return Colors.teal;
    }
    if (cat.contains('deposit') || desc.contains('deposit')) {
      return Colors.blueAccent;
    }
    if (cat.contains('uber') ||
        desc.contains('uber') ||
        desc.contains('lyft')) {
      return Colors.indigo;
    }
    return Colors.grey;
  }
}

/// Small inline picker: shows a dropdown of accounts and reassigns the
/// transaction on selection. Filters out the current account.
class _AccountMover extends StatefulWidget {
  final List<dynamic> accounts;
  final String? currentAccountId;
  final Future<void> Function(String newAccountId) onMove;

  const _AccountMover({
    required this.accounts,
    required this.currentAccountId,
    required this.onMove,
  });

  @override
  State<_AccountMover> createState() => _AccountMoverState();
}

class _AccountMoverState extends State<_AccountMover> {
  String? _selectedId;

  @override
  Widget build(BuildContext context) {
    final candidates = widget.accounts
        .where((a) => a['id']?.toString() != widget.currentAccountId)
        .toList();
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _selectedId,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Reassign to…',
              border: OutlineInputBorder(),
              isDense: true,
            ),
            items: candidates.map<DropdownMenuItem<String>>((a) {
              final id = a['id'].toString();
              final name = (a['name'] ?? 'Account').toString();
              final inst = (a['institution_name'] ?? '').toString();
              return DropdownMenuItem<String>(
                value: id,
                child: Text(
                  inst.isEmpty ? name : '$inst · $name',
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              );
            }).toList(),
            onChanged: (v) => setState(() => _selectedId = v),
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: _selectedId == null ? null : () => widget.onMove(_selectedId!),
          child: const Text('Move'),
        ),
      ],
    );
  }
}
