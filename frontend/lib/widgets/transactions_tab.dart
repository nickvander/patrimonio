import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/transaction_mutation_refresh.dart'
    show kTxBackendMaxPageSize;
import '../theme/typography.dart';
import '../utils/category.dart';
import '../utils/category_style.dart';
import '../utils/currency.dart';
import '../utils/mask_aware_name.dart';
import '../utils/merchant_total.dart';
import '../utils/theme_colors.dart';
import '../utils/transaction_display.dart';
import '../utils/url_opener.dart';
import 'add_transaction_dialog.dart';
import 'split_transaction_dialog.dart';
import 'transaction_filters.dart';

/// Detail-panel Save diffing: returns the trimmed edited text when it
/// genuinely differs from the prefilled [initial] value, or null when
/// the field is unchanged so the caller omits it from the PATCH
/// entirely (null = "leave this column alone" in
/// `ApiService.updateTransaction`).
///
/// The comparison is against the exact prefill — for the category field
/// that's the PRETTIFIED label the editor was seeded with, so opening a
/// transaction and pressing Save without edits never converts the
/// auto-category into a user override of the raw Plaid enum string.
/// Clearing a prefilled field IS a change and returns '' (the backend
/// treats an empty string as "clear the override").
///
/// Top-level (not a method) so the no-op-Save behavior is unit-testable
/// without pumping the detail panel.
String? diffEditedField(String edited, String initial) {
  final next = edited.trim();
  return next == initial.trim() ? null : next;
}

/// Trailing ".00" / "0" trimmer for the haystack's plain amount form.
/// Hoisted so [searchHaystackFor] doesn't rebuild the RegExp per row.
final RegExp _trailingZeros = RegExp(r'\.?0+$');

/// Lowercased search haystack for one transaction: every text field a
/// user can see on the row or in its detail panel — including
/// `user_notes`, which is rendered right in the row's meta line — plus
/// the amount in plain numeric forms. The amount is the absolute value
/// as both "450.00" and "450" (trailing zeros trimmed), so searching
/// "450" or "450.00" finds a 450.00 transaction regardless of the
/// storage sign convention (negative = outflow; see backend
/// services/sync.rs:659) or how the row formats the currency.
///
/// Top-level (not a method) so the field list is unit-testable without
/// pumping the tab; [TransactionsTabState._haystackFor] wraps it with
/// the per-list-identity memoization.
String searchHaystackFor(Map<String, dynamic> tx) {
  final label = displayLabel(tx).toLowerCase();
  final parts = <String>[
    label,
    (tx['description'] ?? '').toString().toLowerCase(),
    (tx['original_description'] ?? '').toString().toLowerCase(),
    (tx['merchant_name'] ?? '').toString().toLowerCase(),
    (tx['counterparty_name'] ?? '').toString().toLowerCase(),
    (tx['payment_payee'] ?? '').toString().toLowerCase(),
    (tx['payment_payer'] ?? '').toString().toLowerCase(),
    (tx['account_name'] ?? '').toString().toLowerCase(),
    (tx['category'] ?? '').toString().toLowerCase(),
    (tx['user_notes'] ?? '').toString().toLowerCase(),
  ];
  final amount = (tx['amount'] as num?)?.toDouble();
  if (amount != null) {
    final fixed = amount.abs().toStringAsFixed(2); // "450.00"
    parts.add(fixed);
    // "450" for 450.00, "450.5" for 450.50 — contains() already lets
    // a "450" query hit "450.00", but the trimmed form also lets a
    // "450 " style exact token read naturally in the haystack.
    final plain = fixed.replaceFirst(_trailingZeros, '');
    if (plain.isNotEmpty && plain != fixed) parts.add(plain);
  }
  // Single concatenated string — one .contains() call covers
  // every field. Separator is a 4-char printable sequence that
  // users virtually never type into a search field, so cross-
  // field false positives are negligible while git keeps treating
  // the file as plain text.
  return parts.join(' || ');
}

/// Per-row "balance after this transaction" for the single-account
/// panel, keyed by transaction id.
///
/// The input list must be newest-first and contiguous from the top of
/// the account's history — exactly what the per-account fetch returns
/// (it always pages from offset 0), so the loaded window satisfies
/// this by construction.
///
/// Per row:
/// - A persisted `balance_after` (statement imports carry the bank's
///   own SALDO column) always wins — it's exact — and re-anchors the
///   walk for the older rows beneath it.
/// - Otherwise the value is ESTIMATED by walking down from [anchor]
///   (the account's current native-currency balance): the top row's
///   balance-after IS the anchor, and each step down removes the newer
///   row's amount (storage sign convention, see backend
///   services/sync.rs:659: negative = outflow, positive = inflow, so
///   `balance_after = balance_before + amount`, i.e.
///   `balance_before = balance_after − amount`). No anchor → no
///   estimates.
/// - A row whose amount is missing/unparseable breaks the walk: every
///   row below it gets NO estimate (persisted values still show, and
///   re-anchor) — better to show nothing than a wrong number.
///
/// Top-level (not a method) so the arithmetic is unit-testable without
/// pumping the tab; the widget wraps it with identity-keyed memoization.
Map<String, ({double value, bool estimated})> runningBalancesFor(
  List<dynamic> transactions, {
  double? anchor,
}) {
  final out = <String, ({double value, bool estimated})>{};
  // Balance after the CURRENT row as we walk down the list; null once
  // the walk has become unsound (no anchor yet, or a gap above).
  double? running = anchor;
  for (final tx in transactions) {
    if (tx is! Map) {
      running = null;
      continue;
    }
    final id = tx['id']?.toString();
    final persisted = (tx['balance_after'] as num?)?.toDouble();
    final amount = (tx['amount'] as num?)?.toDouble();
    if (persisted != null) {
      if (id != null && id.isNotEmpty) {
        out[id] = (value: persisted, estimated: false);
      }
      // Exact statement balance re-anchors the walk below.
      running = persisted;
    } else if (running != null && id != null && id.isNotEmpty) {
      out[id] = (value: running, estimated: true);
    }
    // Step down: the next (older) row's balance-after is this row's
    // balance-before, i.e. balance_after − amount (a negative outflow
    // REDUCED the balance, so before it the balance was higher). An
    // unparseable amount poisons everything below.
    running = (running == null || amount == null) ? null : running - amount;
  }
  return out;
}

class TransactionsTab extends StatefulWidget {
  final List<dynamic> transactions;
  final List<dynamic> accounts;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final String targetCurrency;
  final double usdMxnRate;
  final Function(
    String id, {
    String? userCategory,
    String? userNotes,
    String? userDescription,
    String? accountId,
  })?
  onUpdate;

  /// Bulk variant: updates many transactions in ONE request (the batch
  /// endpoint) and refreshes the dashboard ONCE. The old path looped the
  /// per-id [onUpdate], each of which triggered a full dashboard reload —
  /// selecting N rows fired N writes × a full refetch each. Falls back to
  /// the per-id loop when null. Returns the number actually updated.
  final Future<int> Function(
    List<String> ids, {
    String? userCategory,
    String? accountId,
    String? userDescription,
  })?
  onBulkUpdate;

  /// Bulk delete: deletes every id then refreshes the dashboard once.
  /// Wired by the dashboard; null disables the bulk-delete action.
  final Future<void> Function(List<String> ids)? onBulkDelete;
  final Future<void> Function(String id)? onDelete;

  /// Opens the Add-account dialog directly (used by the no-data empty
  /// state's "Add an account" button) so a fresh user isn't bounced to
  /// Settings to hunt for it. Wired by the dashboard.
  final VoidCallback? onAddAccount;

  /// ApiService for the "Add transaction" button + CSV export URL.
  /// Optional so consumers that don't need those actions can omit it.
  final ApiService? apiService;

  /// Account preselected in the Add-transaction dialog. Account-scoped
  /// hosts (the per-account panel) pass their account id so the dialog
  /// opens on the account the user is already looking at.
  final String? addTransactionAccountId;

  /// Force the "this export covers ALL transactions" confirmation on CSV
  /// export even when no search/filter is active. The backend export has
  /// no account parameter, so an account-scoped host shows a list that is
  /// implicitly filtered — exporting silently would be dishonest there.
  final bool csvExportConfirmAlways;

  /// Invoked after a manual transaction has been added so the parent
  /// can refresh its transaction list.
  final VoidCallback? onTransactionAdded;

  /// Optional pagination hook. When provided, a "Load more" button shows
  /// under the list and fires the callback. The parent is expected to
  /// append the next page to [transactions] and rebuild. [limit] overrides
  /// the parent's default page size — the whole-history cascade passes the
  /// backend's per-request cap so it finishes in a handful of round-trips;
  /// the "Load more" button omits it and gets the ordinary page.
  final Future<void> Function({int? limit})? onLoadMore;

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

  /// Category drill-down seed (a bell spending-spike tap). A PRETTIFIED
  /// category label — the same string `TxFilters.categories` matches
  /// against — dropped into the category filter with the same one-shot
  /// semantics as [dateSeed]: applied once, then user edits stick.
  final String? categorySeed;

  /// Fires after the widget has consumed [categorySeed]. Deliberately
  /// separate from [onDateSeedConsumed] — a date-only caller (chart
  /// month tap) must not half-clear category state, and vice versa.
  final VoidCallback? onCategorySeedConsumed;

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

  /// Split a parent into children. `splits` is a list of maps
  /// `{description, amount, [category]}`. Server validates the sum
  /// matches the parent and rejects with a useful error otherwise.
  final Future<void> Function(
    String parentId,
    List<Map<String, dynamic>> splits,
  )?
  onSplitTransaction;

  /// Un-split: delete every child of the given parent. Used from the
  /// detail modal of a split-child (which knows its `parent_id`).
  final Future<void> Function(String parentId)? onUnsplitTransaction;

  /// Atomically replace the children of a split parent (used by the
  /// Edit split flow). Same payload shape as `onSplitTransaction`.
  final Future<void> Function(
    String parentId,
    List<Map<String, dynamic>> splits,
  )?
  onReplaceSplits;

  /// Single-account host mode (the per-account panel). Every row in
  /// that panel belongs to the same account, so the meta line drops
  /// the redundant account name and the row instead shows a running
  /// "balance after this transaction" under the amount (persisted
  /// statement balances exactly; otherwise estimated from
  /// [runningBalanceAnchor] — see [runningBalancesFor]). The dashboard
  /// (multi-account) leaves this false: account name stays, no balance.
  final bool singleAccountContext;

  /// The account's current balance in its NATIVE currency — the same
  /// figure the panel header shows. Anchors the estimated running
  /// balances for rows without a persisted `balance_after`. Null
  /// disables estimation (persisted values still render).
  final double? runningBalanceAnchor;

  /// "Create loan from this transaction" — shown in the detail panel for
  /// an outflow. The dashboard implements this by opening the prefilled
  /// Add-loan dialog (principal = |amount|, currency, date, borrower from
  /// the tx, disbursement linked to this tx). Null hides the action.
  final void Function(dynamic tx)? onCreateLoanFromTx;

  /// "Make recurring" — shown in the detail panel's overflow menu. The
  /// dashboard opens the Add-recurring-rule dialog pre-filled from the
  /// tx (account, description, amount, currency, category). Null hides
  /// the action.
  final void Function(dynamic tx)? onMakeRecurring;

  /// The host renders its own Add-transaction affordance (the dashboard's
  /// compact-layout FAB, wired to [TransactionsTabState.openAddDialog] via
  /// a GlobalKey). When true the toolbar hides its inline '+' and the
  /// transaction list gains bottom padding so the FAB never occludes the
  /// last row. Defaults to false — every existing host keeps the inline '+'.
  final bool hostProvidesAddFab;

  const TransactionsTab({
    super.key,
    required this.transactions,
    this.accounts = const [],
    required this.conversionFactor,
    required this.currencyFormat,
    required this.targetCurrency,
    required this.usdMxnRate,
    this.onUpdate,
    this.onBulkUpdate,
    this.onBulkDelete,
    this.onDelete,
    this.onAddAccount,
    this.apiService,
    this.addTransactionAccountId,
    this.csvExportConfirmAlways = false,
    this.onTransactionAdded,
    this.onLoadMore,
    this.hasMore = false,
    this.searchOverride,
    this.highlightedTxId,
    this.dateSeed,
    this.onDateSeedConsumed,
    this.categorySeed,
    this.onCategorySeedConsumed,
    this.fxTransfers = const [],
    this.onDetectFxTransfers,
    this.onConfirmFxTransfer,
    this.onUnlinkFxTransfer,
    this.onSplitTransaction,
    this.onUnsplitTransaction,
    this.onReplaceSplits,
    this.singleAccountContext = false,
    this.runningBalanceAnchor,
    this.onCreateLoanFromTx,
    this.onMakeRecurring,
    this.hostProvidesAddFab = false,
  });

  @override
  State<TransactionsTab> createState() => TransactionsTabState();
}

// Row ordering: the public `TxSort` enum lives in transaction_filters.dart
// (the filter panel edits it alongside the filters).

class TransactionsTabState extends State<TransactionsTab> {
  String _searchQuery = '';
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
  // Active row ordering (see the sort menu in _buildToolbar). Only
  // TxSort.dateNewest keeps the grouped (month/day header) view; every
  // other mode renders a flat, header-less list (see _ensureItemPlan).
  TxSort _sortMode = TxSort.dateNewest;
  // Deferred-delete buffer for the Undo affordance. Ids in here are
  // hidden from the displayed/filtered list immediately on delete, but
  // the actual onDelete/onBulkDelete call is only committed when the
  // Undo SnackBar times out (see _scheduleDeleteCommit). Undo just drops
  // the ids back out of the set (the rows reappear) and cancels the
  // pending commit timer. Survives across single + bulk deletes.
  final Set<String> _pendingDeleteIds = {};
  Timer? _pendingDeleteTimer;
  // Local spinner state while widget.onLoadMore is in-flight so the "Load
  // more" button itself shows feedback without a full-page reload.
  bool _loadingMore = false;
  // True while we're cascade-loading the remaining pages so a client-side
  // filter can see the user's whole history (see _loadAllForFilter).
  bool _autoLoading = false;
  // True while a "Select all" is waiting on _loadAllForFilter to pull in
  // the unloaded matches before selecting them (see _toggleSelectAll).
  // Shows a spinner on the toggle so the count doesn't briefly mislead.
  bool _selectAllLoading = false;
  // True inline rename: when set, the row with this tx id renders a
  // TextField in place of the label. Double-click on the label or R
  // while hovering opens the editor. Enter saves, Esc cancels (so
  // does losing focus). Only one row at a time can be inline-edited.
  String? _inlineEditingTxId;
  final TextEditingController _inlineEditController = TextEditingController();
  final FocusNode _inlineEditFocus = FocusNode();
  // Tracks the most recently mouse-hovered row id so the R keyboard
  // shortcut at the tab level knows which row to enter inline-edit on.
  // Cleared on mouse exit so R does nothing when the cursor isn't
  // over a row.
  String? _hoveredTxId;
  // Index keyed on the lowercased-trimmed raw bank description.
  // Built once in didUpdateWidget when widget.transactions changes
  // identity, queried in O(1) by _similarTransactionIds. Without
  // this every right-click on a "MISC DEBIT" cluster member did a
  // full O(N) scan; with thousands of rows that's perceptible.
  Map<String, List<String>>? _descIndex;
  int _descIndexIdentity = 0;
  // 120ms debounce on the search field. Every keystroke schedules
  // (or replaces) a timer; only when the user stops typing for the
  // debounce window do we commit to _searchQuery and trigger a
  // filter rebuild. Without this, typing "rent" was 4 full re-
  // filters of every row; with it, one.
  Timer? _searchDebounce;
  static const _searchDebounceMs = 120;
  // Cache for `_filteredTransactions`. Identity-keyed on the
  // underlying list plus the active search / filter state. As long
  // as none of the three change, the getter returns the cached
  // list without re-walking thousands of rows. The lowercased per-
  // tx haystack is itself cached on _haystackCache so we don't
  // re-lowercase 9 fields every keystroke either.
  List<dynamic>? _filteredCache;
  int _filteredCacheIdentity = 0;
  // Sentinel that won't match a real search query (real ones are
  // always lowercased + non-empty). Forces a first-run rebuild.
  String _filteredCacheQuery = '__init__';
  TxFilters _filteredCacheFilters = TxFilters.empty;
  // Cache invalidators for the two new filtered-list inputs: the chosen
  // sort mode and the count of pending-delete ids (a count change is the
  // only way the hidden set affects the result — a delete adds an id, an
  // undo removes one). The sort sentinel forces a first-run rebuild.
  TxSort? _filteredCacheSort;
  int _filteredCachePendingDeleteCount = 0;
  final Map<String, String> _haystackCache = {};
  int _haystackCacheIdentity = 0;
  // Cache for the single-account running balances. Computed over the
  // FULL unfiltered list (a filtered view would skip rows and corrupt
  // the walk), identity-keyed on the list + the anchor so a rebuild
  // with the same page set is a map lookup, not an O(n) re-walk.
  Map<String, ({double value, bool estimated})>? _balancesCache;
  int _balancesCacheIdentity = 0;
  double? _balancesCacheAnchor;

  /// Running balances keyed by tx id (empty outside
  /// [TransactionsTab.singleAccountContext]). See [runningBalancesFor].
  Map<String, ({double value, bool estimated})> get _runningBalances {
    if (!widget.singleAccountContext) return const {};
    final identity = identityHashCode(widget.transactions);
    final anchor = widget.runningBalanceAnchor;
    final cached = _balancesCache;
    if (cached != null &&
        _balancesCacheIdentity == identity &&
        _balancesCacheAnchor == anchor) {
      return cached;
    }
    final next = runningBalancesFor(widget.transactions, anchor: anchor);
    _balancesCache = next;
    _balancesCacheIdentity = identity;
    _balancesCacheAnchor = anchor;
    return next;
  }

  @override
  void initState() {
    super.initState();
    final seed = widget.searchOverride;
    if (seed != null && seed.isNotEmpty) {
      _searchQuery = seed;
      _searchController.text = seed;
      _appliedOverride = seed;
    }
    _maybeApplySeeds(
      dateSeed: widget.dateSeed,
      categorySeed: widget.categorySeed,
    );
  }

  @override
  void didUpdateWidget(TransactionsTab oldWidget) {
    super.didUpdateWidget(oldWidget);
    final seed = widget.searchOverride;
    if (seed != null && seed.isNotEmpty && seed != _appliedOverride) {
      setState(() {
        _searchQuery = seed;
        _searchController.text = seed;
        _appliedOverride = seed;
      });
    }
    // One-shot: each seed re-applies only when it CHANGED from the
    // previous widget — a dashboard rebuild carrying the same value
    // (or a value the user has since edited away) is ignored.
    final dateChanged =
        widget.dateSeed != null && widget.dateSeed != oldWidget.dateSeed;
    final categoryChanged =
        widget.categorySeed != null &&
        widget.categorySeed != oldWidget.categorySeed;
    if (dateChanged || categoryChanged) {
      _maybeApplySeeds(
        dateSeed: dateChanged ? widget.dateSeed : null,
        categorySeed: categoryChanged ? widget.categorySeed : null,
      );
    }
  }

  /// Drop drill-down seeds (a chart-tap date window and/or a bell-tap
  /// category label) into the active filters, both in ONE setState so a
  /// dependent fetch can never observe half-applied filters. Pushes the
  /// per-seed consumed callbacks so the dashboard clears its copies and
  /// manual filter edits aren't overwritten on the next rebuild.
  void _maybeApplySeeds({
    ({DateTime start, DateTime end})? dateSeed,
    String? categorySeed,
  }) {
    if (dateSeed == null && categorySeed == null) return;
    // Schedule for after the current build so initState callers don't
    // setState during the build pass.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        if (dateSeed != null) {
          _filters = _filters.copyWith(
            dateRange: TxDateRange.custom,
            customStart: dateSeed.start,
            customEnd: dateSeed.end,
          );
        }
        if (categorySeed != null) {
          _filters = _filters.copyWith(categories: {categorySeed});
        }
      });
      if (dateSeed != null) widget.onDateSeedConsumed?.call();
      if (categorySeed != null) widget.onCategorySeedConsumed?.call();
    });
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _pendingDeleteTimer?.cancel();
    // The widget is going away with an Undo window still open: honor the
    // delete (the rows were already hidden — the user's intent was to
    // delete) by firing the commit without touching the now-defunct UI.
    final pendingCommit = _pendingDeleteCommit;
    if (pendingCommit != null) {
      _pendingDeleteCommit = null;
      // Fire-and-forget: no setState/SnackBar — this State is dead.
      pendingCommit();
    }
    _searchController.dispose();
    _inlineEditController.dispose();
    _inlineEditFocus.dispose();
    super.dispose();
  }

  /// Enter inline-edit mode for one row. Pre-fills the controller
  /// with the row's existing `user_description`, requests focus on
  /// the field so the user can start typing immediately. No-op when
  /// onUpdate isn't wired (the surface is read-only).
  void _startInlineEdit(dynamic tx) {
    if (widget.onUpdate == null) return;
    final id = tx['id']?.toString();
    if (id == null || id.isEmpty) return;
    setState(() {
      _inlineEditingTxId = id;
      _inlineEditController.text = (tx['user_description'] ?? '').toString();
    });
    // requestFocus after the rebuild so the new TextField is mounted.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _inlineEditFocus.requestFocus();
      _inlineEditController.selection = TextSelection(
        baseOffset: 0,
        extentOffset: _inlineEditController.text.length,
      );
    });
  }

  /// Commit the inline-edit text via the parent widget's onUpdate
  /// hook. Empty text clears the override (the rename endpoint
  /// already treats '' as a clear directive). Always exits edit
  /// mode, success or failure — the dialog flow is still available
  /// for the bulk-apply-to-N case.
  Future<void> _commitInlineEdit(dynamic tx) async {
    final id = tx['id']?.toString();
    if (id == null) {
      _cancelInlineEdit();
      return;
    }
    final text = _inlineEditController.text.trim();
    final onUpdate = widget.onUpdate;
    setState(() => _inlineEditingTxId = null);
    if (onUpdate == null) return;
    final l = AppLocalizations.of(context);
    try {
      await onUpdate(id, userDescription: text);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          duration: const Duration(seconds: 2),
          content: Text(text.isEmpty ? l.txOverrideCleared : l.txRenamed),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.txRenameFailed(e.toString()))));
    }
  }

  void _cancelInlineEdit() {
    if (_inlineEditingTxId == null) return;
    setState(() => _inlineEditingTxId = null);
  }

  /// Handler for the R keyboard shortcut at the tab level. Fires
  /// inline edit on the most-recently hovered row. Bails when the
  /// user is already typing in any TextField (so R inside the search
  /// box doesn't trigger a rename).
  KeyEventResult _onTabKey(FocusNode _, KeyEvent ev) {
    if (ev is! KeyDownEvent) return KeyEventResult.ignored;
    if (ev.logicalKey != LogicalKeyboardKey.keyR) {
      return KeyEventResult.ignored;
    }
    // Don't hijack R when the focus is already inside an editable
    // text widget. `primaryFocus` is the leaf — walk up looking for
    // an EditableText ancestor.
    final pf = FocusManager.instance.primaryFocus;
    if (pf?.context?.findAncestorWidgetOfExactType<EditableText>() != null) {
      return KeyEventResult.ignored;
    }
    final hovered = _hoveredTxId;
    if (hovered == null) return KeyEventResult.ignored;
    // Find the tx for this id and trigger.
    final tx = widget.transactions.firstWhere(
      (t) => (t['id']?.toString() ?? '') == hovered,
      orElse: () => null,
    );
    if (tx == null) return KeyEventResult.ignored;
    _startInlineEdit(tx);
    return KeyEventResult.handled;
  }

  List<dynamic> get _filteredTransactions {
    final txs = widget.transactions;
    final identity = identityHashCode(txs);
    final q = _searchQuery.toLowerCase();
    // Cache check: same source list + same query + same filters →
    // return the previous result. Avoids re-walking N rows + re-
    // allocating a fresh List on every setState (hover, selection
    // toggle, inline-edit state flip).
    if (_filteredCache != null &&
        identity == _filteredCacheIdentity &&
        q == _filteredCacheQuery &&
        _filters == _filteredCacheFilters &&
        _sortMode == _filteredCacheSort &&
        _pendingDeleteIds.length == _filteredCachePendingDeleteCount) {
      return _filteredCache!;
    }
    // Clear the per-tx haystack cache when the underlying list
    // identity changes — different list, different tx instances,
    // stale strings.
    if (identity != _haystackCacheIdentity) {
      _haystackCache.clear();
      _haystackCacheIdentity = identity;
    }
    final hasSearch = q.isNotEmpty;
    final hasFilters = _filters.isActive;
    final hasPendingDelete = _pendingDeleteIds.isNotEmpty;
    List<dynamic> result;
    if (!hasSearch && !hasFilters && !hasPendingDelete) {
      result = txs;
    } else {
      result = <dynamic>[];
      for (final tx in txs) {
        // Deferred-delete rows are hidden the moment the user deletes
        // them, before the commit lands, so the Undo SnackBar can put
        // them back without a re-fetch (see _scheduleDeleteCommit).
        if (hasPendingDelete &&
            _pendingDeleteIds.contains(tx['id']?.toString())) {
          continue;
        }
        if (hasSearch) {
          final hay = _haystackFor(tx);
          if (!hay.contains(q)) continue;
        }
        if (hasFilters && !_filters.matches(tx)) continue;
        result.add(tx);
      }
    }
    // The source list is always newest-first (the default view), so the
    // dateNewest sort is a no-op; every other mode re-orders a fresh copy
    // (never mutate `txs` — it's the parent's list, also feeding the
    // running-balance walk). The flat (header-less) rendering for the
    // non-default modes is handled in _ensureItemPlan.
    result = _applySort(result);
    _filteredCache = result;
    _filteredCacheIdentity = identity;
    _filteredCacheQuery = q;
    _filteredCacheFilters = _filters;
    _filteredCacheSort = _sortMode;
    _filteredCachePendingDeleteCount = _pendingDeleteIds.length;
    // (cascade-load trigger lives in build(), keyed off the same filter state)
    return result;
  }

  /// Re-order [rows] per [_sortMode]. The source list is already
  /// newest-first, so `dateNewest` returns it untouched (no copy);
  /// every other mode sorts a defensive copy — `rows` may be the
  /// parent's list (the no-filter fast path) and must never be mutated
  /// in place. Amount sort is by ABSOLUTE magnitude (a spend/income
  /// view cares about size, not sign — a −5,000 expense and a +5,000
  /// paycheck are both "big"); ties keep newest-first as a stable
  /// secondary key.
  List<dynamic> _applySort(List<dynamic> rows) {
    switch (_sortMode) {
      case TxSort.dateNewest:
        return rows;
      case TxSort.dateOldest:
        return rows.reversed.toList();
      case TxSort.amountHigh:
        final out = List<dynamic>.from(rows);
        out.sort((a, b) => _absAmount(b).compareTo(_absAmount(a)));
        return out;
      case TxSort.amountLow:
        final out = List<dynamic>.from(rows);
        out.sort((a, b) => _absAmount(a).compareTo(_absAmount(b)));
        return out;
      case TxSort.merchant:
        final out = List<dynamic>.from(rows);
        out.sort((a, b) => _merchantKey(a).compareTo(_merchantKey(b)));
        return out;
    }
  }

  double _absAmount(dynamic tx) =>
      ((tx['amount'] as num?)?.toDouble() ?? 0).abs();

  /// Lowercased label used to order the Merchant (A–Z) sort — the same
  /// display label the row shows, so the alphabetisation matches what
  /// the user reads.
  String _merchantKey(dynamic tx) =>
      displayLabel(Map<String, dynamic>.from(tx as Map)).toLowerCase();

  /// Cascade-load the remaining pages so a client-side filter/search (and
  /// the filter dialog's option lists) can see the user's whole history.
  /// Each round-trip requests [kTxBackendMaxPageSize] rows — the most the
  /// backend will honor per call — instead of the default 50-row page, so
  /// e.g. 3,000 rows costs ≤7 round-trips rather than 60.
  ///
  /// Runs at most one cascade at a time: while one is in flight every
  /// caller gets the same future back (the filter dialog awaits it for its
  /// loading affordance), and once history is fully loaded `hasMore` is
  /// false so re-entering is a completed-future no-op. The filter-driven
  /// cascade stops early if the filter is cleared mid-flight;
  /// [ignoreFilters] (the dialog-open path) loads to the end regardless,
  /// since the dialog needs the full option set either way.
  Future<void> _loadAllForFilter({bool ignoreFilters = false}) {
    final inFlight = _historyCascade;
    if (inFlight != null) return inFlight;
    final onLoadMore = widget.onLoadMore;
    if (onLoadMore == null || !widget.hasMore) return Future<void>.value();
    // Clear the memo via whenComplete (always async) rather than inside
    // _runHistoryCascade's own finally: an async body runs synchronously
    // up to its first await, so a body that bails out immediately would
    // otherwise null the field BEFORE this assignment and leave a stale
    // completed future memoized forever.
    final run = _runHistoryCascade(
      onLoadMore,
      ignoreFilters,
    ).whenComplete(() => _historyCascade = null);
    _historyCascade = run;
    return run;
  }

  Future<void>? _historyCascade;

  Future<void> _runHistoryCascade(
    Future<void> Function({int? limit}) onLoadMore,
    bool ignoreFilters,
  ) async {
    _autoLoading = true;
    if (mounted) setState(() {});
    try {
      while (mounted &&
          widget.hasMore &&
          (ignoreFilters || _searchQuery.isNotEmpty || _filters.isActive)) {
        await onLoadMore(limit: kTxBackendMaxPageSize);
        // The parent setState()s the new page in, but this State's `widget`
        // (transactions/hasMore) only updates when that rebuild lands. Wait
        // for the frame before re-reading the loop condition — otherwise
        // the final iteration overshoots on stale props and fires one
        // extra, always-empty request per cascade.
        await WidgetsBinding.instance.endOfFrame;
      }
    } catch (_) {
      // A failed page load just stops the cascade: the user keeps whatever
      // is loaded and the next filter change / dialog open retries. Never
      // rethrow — callers (the build trigger, the dialog's whenComplete
      // chain) don't await this future for errors, so a throw here would
      // surface as an unhandled async exception.
    } finally {
      if (mounted) setState(() => _autoLoading = false);
    }
  }

  /// Lowercased haystack for one tx: the searchable fields joined
  /// with a separator (see [searchHaystackFor]) + memoized. We
  /// previously re-lowercased every field per row on every keystroke;
  /// now each row is lowercased at most once per list-identity.
  String _haystackFor(dynamic tx) {
    if (tx is! Map) return '';
    final id = tx['id']?.toString();
    if (id != null) {
      final cached = _haystackCache[id];
      if (cached != null) return cached;
    }
    final hay = searchHaystackFor(Map<String, dynamic>.from(tx));
    if (id != null) _haystackCache[id] = hay;
    return hay;
  }

  Future<void> _openFilters({required bool isNarrow}) async {
    // Make the option lists (categories especially) reflect the user's
    // WHOLE history, not just the pages loaded so far — a category that
    // only occurs in unloaded history was previously impossible to select.
    // This kicks the same memoized cascade the filters themselves use, so
    // reopening the dialog when history is already fully loaded (hasMore
    // false) costs nothing and shows no loading affordance.
    final Future<void>? historyLoad = widget.hasMore
        ? _loadAllForFilter(ignoreFilters: true)
        : null;
    Widget panel({required bool asSheet}) => TxFiltersDialog(
      initial: _filters,
      initialSort: _sortMode,
      asSheet: asSheet,
      transactions: widget.transactions,
      accounts: widget.accounts,
      historyLoad: historyLoad,
      // Live getter: when the cascade completes the panel re-reads the
      // (by then fully loaded) list so its options refresh in place.
      liveTransactions: () => widget.transactions,
    );
    // Narrow hosts get a modal bottom sheet (thumb-reachable, standard
    // mobile idiom); wide keeps the AlertDialog. Both pop the same
    // (filters, sort) record from the shared panel body.
    final (TxFilters, TxSort)? result;
    if (isNarrow) {
      result = await showModalBottomSheet<(TxFilters, TxSort)>(
        context: context,
        isScrollControlled: true,
        useSafeArea: true,
        showDragHandle: true,
        builder: (sheetContext) => ConstrainedBox(
          // Cap the sheet below full height so it still reads as a sheet;
          // the panel's inner scroll view handles longer content.
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(sheetContext).height * 0.9,
          ),
          child: panel(asSheet: true),
        ),
      );
    } else {
      result = await showDialog<(TxFilters, TxSort)>(
        context: context,
        builder: (_) => panel(asSheet: false),
      );
    }
    if (result == null || !mounted) return;
    final (filters, sort) = result;
    setState(() {
      _filters = filters;
      _sortMode = sort;
    });
  }

  /// Removable chip strip below the toolbar showing every active filter
  /// (and a non-default sort) in a single horizontal scroll. Tapping the
  /// X on a chip clears just that one; the strip hides entirely when
  /// nothing's active.
  Widget _activeFilterChips(bool isNarrow) {
    if (!_filters.isActive && _sortMode == TxSort.dateNewest) {
      return const SizedBox.shrink();
    }
    final l = AppLocalizations.of(context);
    final chips = <Widget>[];
    if (_filters.flow != TxFlow.all) {
      chips.add(
        _filterChip(
          _filters.flow == TxFlow.expense ? l.txFlowExpense : l.txFlowIncome,
          () => setState(() => _filters = _filters.copyWith(flow: TxFlow.all)),
        ),
      );
    }
    if (_filters.status != TxStatus.all) {
      chips.add(
        _filterChip(
          _filters.status == TxStatus.pending
              ? l.txStatusPending
              : l.txStatusSettled,
          () => setState(
            () => _filters = _filters.copyWith(status: TxStatus.all),
          ),
        ),
      );
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
      chips.add(
        _filterChip(
          label,
          () => setState(() => _filters = _filters.copyWith(accountIds: {})),
        ),
      );
    }
    if (_filters.categories.isNotEmpty) {
      final cats = _filters.categories.toList();
      final label = cats.length == 1
          ? cats.first
          : '${cats.first} +${cats.length - 1}';
      chips.add(
        _filterChip(
          label,
          () => setState(() => _filters = _filters.copyWith(categories: {})),
        ),
      );
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
        label = _filters.dateRange.labelFor(context);
      }
      chips.add(
        _filterChip(
          label,
          () => setState(
            () => _filters = _filters.copyWith(
              dateRange: TxDateRange.all,
              clearCustomDates: true,
            ),
          ),
        ),
      );
    }
    if (_filters.minAmount != null || _filters.maxAmount != null) {
      // "450–1,000"-style window, "≥ 450" / "≤ 450" when one end is
      // open. Numbers + comparison glyphs read the same in en/es, so
      // no extra l10n template is needed for the chip itself.
      final lo = _filters.minAmount;
      final hi = _filters.maxAmount;
      final String label;
      if (lo != null && hi != null) {
        label = '${formatFilterAmount(lo)}–${formatFilterAmount(hi)}';
      } else if (lo != null) {
        label = '≥ ${formatFilterAmount(lo)}';
      } else {
        label = '≤ ${formatFilterAmount(hi!)}';
      }
      chips.add(
        _filterChip(
          label,
          () =>
              setState(() => _filters = _filters.copyWith(clearAmounts: true)),
        ),
      );
    }
    // Sort isn't a filter, but a non-default order changes what the list
    // shows just as visibly (headers disappear, rows re-order) — surface
    // it in the same strip so it's one tap to see and one tap to undo.
    if (_sortMode != TxSort.dateNewest) {
      chips.add(
        _filterChip(
          txSortLabel(l, _sortMode),
          () => setState(() => _sortMode = TxSort.dateNewest),
        ),
      );
    }
    chips.add(
      TextButton(
        onPressed: () => setState(() {
          _filters = TxFilters.empty;
          _sortMode = TxSort.dateNewest;
        }),
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: const Size(0, 28),
        ),
        child: Text(l.txClearAll),
      ),
    );
    // On a phone the horizontal scroll buried the right-most chips and
    // "Clear all" off-screen with no cue, so narrow widths wrap onto
    // multiple lines keeping every chip (and the clear) reachable. Wide
    // screens keep the single-line scroll — chips rarely overflow there.
    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 4),
      child: isNarrow
          ? Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: chips,
            )
          : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final c in chips) ...[c, const SizedBox(width: 6)],
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

  /// One-stroke escape hatch from a zero-match dead end: drops the
  /// search text (flushing any pending debounce so a stale keystroke
  /// can't resurrect it) and every filter, amount range included.
  void _clearFiltersAndSearch() {
    _searchDebounce?.cancel();
    setState(() {
      _searchQuery = '';
      _searchController.clear();
      _filters = TxFilters.empty;
    });
  }

  /// Centered state for "filters/search matched nothing" — styled like
  /// the no-transactions-at-all empty state (icon, title, body, one
  /// action) but the action clears filters + search instead of adding
  /// an account. Only reachable when the source list is non-empty.
  Widget _noMatchesState() {
    final l = AppLocalizations.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off, size: 64, color: context.textFaint),
            const SizedBox(height: 16),
            Text(
              l.txNoMatchesTitle,
              style: TextStyle(
                color: context.textMuted,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l.txNoMatchesBody,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.textMuted),
            ),
            const SizedBox(height: 20),
            OutlinedButton.icon(
              onPressed: _clearFiltersAndSearch,
              icon: const Icon(Icons.filter_alt_off_outlined, size: 18),
              label: Text(l.txClearFiltersSearch),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    if (widget.transactions.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              Icons.receipt_long_outlined,
              size: 64,
              color: context.textFaint,
            ),
            const SizedBox(height: 16),
            Text(
              l.txEmptyTitle,
              style: TextStyle(
                color: context.textMuted,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              l.txEmptyBody,
              textAlign: TextAlign.center,
              style: TextStyle(color: context.textMuted),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: widget.onAddAccount,
              icon: const Icon(Icons.add_link, size: 18),
              label: Text(l.txAddAccount),
              style: FilledButton.styleFrom(
                backgroundColor: context.positive,
                foregroundColor: context.onAccent(context.positive),
              ),
            ),
          ],
        ),
      );
    }

    final filtered = _filteredTransactions;

    // Filtering/search is client-side over the loaded pages. If a filter is
    // active but more pages exist, an account/category whose activity sits
    // below the loaded window wrongly shows nothing (the "Nu — Cuenta: no
    // results" bug). Pull in the rest once so the filter sees everything.
    if (!_autoLoading &&
        widget.hasMore &&
        (_searchQuery.isNotEmpty || _filters.isActive)) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _loadAllForFilter());
    }

    return Focus(
      // Tab-level R-key shortcut: opens inline rename on the most-
      // recently hovered row. Skipped automatically when focus is
      // inside any EditableText (search field, inline-edit field,
      // etc.) so the key types normally in those contexts.
      autofocus: false,
      onKeyEvent: _onTabKey,
      child: Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isNarrow = constraints.maxWidth < 560;
            // Bounded-host mode: when the parent hands us a finite height
            // (e.g. the account panel's Expanded slot, side panel or
            // bottom sheet), the rows region must fill the remaining
            // space and scroll internally — an eager Column would
            // overflow the slot and clip rows below the fold, and the
            // window-height SizedBox would ignore the panel's actual
            // size. The dashboard hosts us inside a page-level
            // SingleChildScrollView (unbounded height), which keeps the
            // existing page-scroll behavior there.
            final boundedHost = constraints.maxHeight.isFinite;
            return Padding(
              // Tighter gutters on phone so the row's title/amount columns
              // aren't starved: a constant 24px pad on a ~390px screen left
              // the description column only ~140px and forced premature
              // ellipsis on even short merchant names. Desktop keeps 24.
              padding: EdgeInsets.all(isNarrow ? 12.0 : 24.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _buildToolbar(isNarrow),
                  // Persistent search on narrow: a full-width row of its own
                  // right under the toolbar (wide keeps the inline 280px
                  // field in the toolbar). Always visible — no toggle to
                  // discover, and closing nothing means the query survives.
                  if (isNarrow) ...[
                    const SizedBox(height: 8),
                    SizedBox(height: 40, child: _searchField()),
                  ],
                  _activeFilterChips(isNarrow),
                  const SizedBox(height: 8),
                  Text(
                    l.txShowingCount(
                      filtered.length,
                      widget.transactions.length,
                    ),
                    style: TextStyle(color: context.textSubtle, fontSize: 12),
                  ),
                  // With any filter/search active, summarise the FULL filtered
                  // (cascade-loaded) set — net + outflow + inflow in the
                  // reporting currency — so the user doesn't have to do CSV math.
                  if ((_searchQuery.isNotEmpty || _filters.isActive) &&
                      filtered.isNotEmpty)
                    _buildFilteredSummary(filtered),
                  const SizedBox(height: 8),
                  if (_selectionMode) _buildBulkActionBar(filtered),
                  // Flat list of rows with inline date-group headers
                  // (Today / Yesterday / weekday name / "Month d").
                  //
                  // Performance: for >50 rows, swap the eager `Column` for
                  // a bounded `ListView.builder` that virtualises out-of-
                  // view rows. The bounded SizedBox is the trade — the
                  // tx list scrolls inside the card rather than as part
                  // of the page — but it's the only way Flutter avoids
                  // building every row up front. Short lists keep the
                  // page-scroll feel.
                  //
                  // In a bounded host the list instead takes whatever
                  // height remains in the slot (Expanded) and always
                  // virtualises, so every row — even on a ≤50-row account
                  // — is reachable by scrolling inside the panel.
                  //
                  // Zero matches with a non-empty source list can only mean
                  // the active search/filters excluded everything (the
                  // unfiltered getter returns the source list as-is), so
                  // instead of dead space + "Showing 0 of N" we render a
                  // centered no-match state with a one-tap way out. Both
                  // hosts get it: the bounded path centers it in the
                  // Expanded slot, the eager/virtualised path inline.
                  if (filtered.isEmpty)
                    boundedHost
                        ? Expanded(child: _noMatchesState())
                        : _noMatchesState()
                  else if (boundedHost)
                    Expanded(child: _buildVirtualisedList(filtered, isNarrow))
                  else
                    _buildRowsRegion(filtered, isNarrow, constraints),
                  if (widget.onLoadMore != null && widget.hasMore)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Center(
                        child: (_loadingMore || _autoLoading)
                            ? const SizedBox(
                                height: 20,
                                width: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
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
                                label: Text(l.txLoadMore),
                              ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  // Sticky-ish bulk-action bar that appears under the filter chip strip
  // whenever the user is in selection mode. "Select all" toggles every
  // currently-filtered row, the two action buttons run the multi-update,
  // and "Clear" exits selection mode without doing anything.
  Widget _buildBulkActionBar(List<dynamic> filtered) {
    final l = AppLocalizations.of(context);
    final filteredIds = <String>[
      for (final t in filtered)
        if (t['id'] != null) t['id'].toString(),
    ];
    final allSelected =
        filteredIds.isNotEmpty && filteredIds.every(_selectedIds.contains);
    final selectedCount = _selectedIds.length;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: context.positive.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.accentBorder(context.positive)),
      ),
      child: LayoutBuilder(
        builder: (ctx, c) {
          final isNarrow = c.maxWidth < 560;

          final selectToggle = TextButton.icon(
            onPressed: _selectAllLoading
                ? null
                : () => _toggleSelectAll(allSelected),
            icon: _selectAllLoading
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : Icon(
                    allSelected
                        ? Icons.indeterminate_check_box_outlined
                        : Icons.select_all,
                    size: 18,
                  ),
            label: Text(allSelected ? l.txDeselectAll : l.txSelectAll),
          );

          final categorize = FilledButton.tonalIcon(
            onPressed: selectedCount == 0 ? null : () => _bulkCategorize(),
            icon: const Icon(Icons.label_outline, size: 18),
            label: Text(l.txSetCategory),
          );

          final moveAccount = FilledButton.tonalIcon(
            onPressed: selectedCount == 0 ? null : () => _bulkMoveAccount(),
            icon: const Icon(Icons.compare_arrows, size: 18),
            label: Text(l.txMoveAccount),
          );

          final rename = FilledButton.tonalIcon(
            onPressed: selectedCount == 0 ? null : () => _bulkRename(),
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: Text(l.txRename),
          );

          final delete = FilledButton.tonalIcon(
            onPressed: (selectedCount == 0 || widget.onBulkDelete == null)
                ? null
                : () => _bulkDelete(),
            icon: Icon(Icons.delete_outline, size: 18, color: context.negative),
            label: Text(
              l.actionDelete,
              style: TextStyle(color: context.negative),
            ),
          );

          final clear = TextButton(
            onPressed: () => setState(() {
              _selectionMode = false;
              _selectedIds.clear();
            }),
            child: Text(l.txClear),
          );

          final summary = Text(
            l.txSelectedCount(selectedCount),
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: context.positive,
            ),
          );

          if (isNarrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                summary,
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    selectToggle,
                    categorize,
                    moveAccount,
                    rename,
                    delete,
                    clear,
                  ],
                ),
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
              rename,
              const SizedBox(width: 8),
              delete,
              const SizedBox(width: 8),
              clear,
            ],
          );
        },
      ),
    );
  }

  /// "Select all" / "Deselect all" handler. Deselect just drops the
  /// currently-filtered ids. Select, when more pages match the active
  /// filter than are loaded (hasMore), first cascades in the whole
  /// filtered history via _loadAllForFilter so bulk actions cover every
  /// match — not just the loaded window — and the count is truthful;
  /// then it selects every filtered id. When nothing more is loadable it
  /// behaves as before (select the loaded matches synchronously).
  Future<void> _toggleSelectAll(bool allSelected) async {
    if (allSelected) {
      setState(() => _selectedIds.removeAll(_idsOf(_filteredTransactions)));
      return;
    }
    if (widget.hasMore && widget.onLoadMore != null) {
      setState(() => _selectAllLoading = true);
      try {
        await _loadAllForFilter();
      } finally {
        if (mounted) setState(() => _selectAllLoading = false);
      }
      if (!mounted) return;
    }
    // Re-read the (now fully loaded) filtered set so the selection
    // reflects every match, not the pre-cascade window.
    setState(() => _selectedIds.addAll(_idsOf(_filteredTransactions)));
  }

  /// String ids of the rows in [rows] (skipping any without an id).
  List<String> _idsOf(List<dynamic> rows) => [
    for (final t in rows)
      if (t['id'] != null) t['id'].toString(),
  ];

  Future<void> _bulkCategorize() async {
    final l = AppLocalizations.of(context);
    final suggestions = _distinctCategories();
    var typed = '';
    final cat = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(l.txSetCategory),
        content: Autocomplete<String>(
          // Suggest from the categories already in use so the user
          // doesn't fragment them ("Restaurant" vs "Restaurants"); a
          // free-typed value not in the list is still accepted.
          optionsBuilder: (value) {
            final q = value.text.trim().toLowerCase();
            if (q.isEmpty) return suggestions;
            return suggestions.where((s) => s.toLowerCase().contains(q));
          },
          onSelected: (s) => typed = s,
          fieldViewBuilder: (ctx, controller, focusNode, onSubmit) {
            return TextField(
              controller: controller,
              focusNode: focusNode,
              autofocus: true,
              decoration: InputDecoration(hintText: l.txCategoryHint),
              onChanged: (v) => typed = v,
              onSubmitted: (v) => Navigator.pop(dialogCtx, v.trim()),
            );
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, typed.trim()),
            child: Text(l.actionApply),
          ),
        ],
      ),
    );
    if (cat == null || cat.isEmpty) return;
    await _applyBulkUpdate(userCategory: cat);
  }

  Future<void> _bulkRename() async {
    final l = AppLocalizations.of(context);
    final controller = TextEditingController();
    final count = _selectedIds.length;
    final name = await showDialog<String>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(l.txRenameNTitle(count)),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l.txNewDescription,
            hintText: l.txRenameHint,
          ),
          onSubmitted: (v) => Navigator.pop(dialogCtx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogCtx, controller.text.trim()),
            child: Text(l.actionApply),
          ),
        ],
      ),
    );
    // dispose: local controller, else the dialog leaks it. controller.text was
    // already captured into `name` inside the dialog.
    controller.dispose();
    if (name == null || name.isEmpty) return;
    await _applyBulkUpdate(userDescription: name);
  }

  Future<void> _bulkDelete() async {
    final onBulkDelete = widget.onBulkDelete;
    if (onBulkDelete == null) return;
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: Text(l.txDeleteNTitle(ids.length)),
        content: Text(l.txBulkDeleteBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx, false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.negative),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(l.actionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    // Optimistic hide + Undo: the rows vanish now (they're added to the
    // pending set, which _filteredTransactions subtracts) but the actual
    // onBulkDelete only fires when the Undo window lapses. Selection mode
    // exits immediately so the action bar's count doesn't strand the
    // already-hidden rows. The commit re-uses onBulkDelete for the whole
    // batch in one call.
    setState(() {
      _selectedIds.clear();
      _selectionMode = false;
    });
    _initiateDeferredDelete(
      ids,
      l.txDeletedN(ids.length),
      () => onBulkDelete(ids),
      l.txDeleteSomeFailed,
    );
  }

  /// Single-row deferred delete (from the detail panel's overflow
  /// Delete). Mirrors the bulk path: hide now, Undo SnackBar, commit
  /// onDelete after the window. Public-ish so the panel can route its
  /// delete through the tab's one Undo buffer.
  void _deferredDeleteSingle(dynamic id, AppLocalizations l) {
    final onDelete = widget.onDelete;
    if (onDelete == null || id == null) return;
    final idStr = id.toString();
    _initiateDeferredDelete([idStr], l.txDeletedOne, () async {
      await onDelete(id);
    }, l.txDeleteOneFailed);
  }

  /// Hold-callback for the in-flight deferred delete: deletes the
  /// [_pendingDeleteIds] when the Undo window lapses. Null when nothing
  /// is pending.
  Future<void> Function()? _pendingDeleteCommit;
  String? _pendingDeleteFailMsg;

  /// Begin a deferred (undoable) delete for [ids]: hide the rows now,
  /// pop an Undo SnackBar, and arm a timer that commits [commit] after
  /// the window unless the user taps Undo. [committedMsg] is shown once
  /// the delete actually lands; [failMsg] if it throws.
  ///
  /// If a previous deferred delete is still pending, it's flushed
  /// (committed immediately) first — Undo only ever applies to the most
  /// recent action, and the older rows are already hidden, so silently
  /// committing them keeps the displayed list honest.
  void _initiateDeferredDelete(
    List<String> ids,
    String committedMsg,
    Future<void> Function() commit,
    String failMsg,
  ) {
    // Flush any prior pending batch so its hidden rows actually delete
    // (no Undo can reach them anymore) before we overwrite the buffer.
    _commitPendingDeletesNow();
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    setState(() => _pendingDeleteIds.addAll(ids));
    _pendingDeleteCommit = commit;
    _pendingDeleteFailMsg = failMsg;
    final pendingThisRound = ids.toSet();
    _pendingDeleteTimer?.cancel();
    _pendingDeleteTimer = Timer(const Duration(seconds: 6), () {
      _commitPendingDeletesNow(committedMsg: committedMsg);
    });
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text(committedMsg),
        action: SnackBarAction(
          label: l.txUndo,
          onPressed: () => _undoPendingDelete(pendingThisRound),
        ),
      ),
    );
  }

  /// Undo the still-pending delete batch: drop [ids] back out of the
  /// hidden set (the rows reappear) and cancel the commit timer so the
  /// onDelete/onBulkDelete call never fires.
  void _undoPendingDelete(Set<String> ids) {
    _pendingDeleteTimer?.cancel();
    _pendingDeleteTimer = null;
    _pendingDeleteCommit = null;
    _pendingDeleteFailMsg = null;
    if (!mounted) {
      _pendingDeleteIds.removeAll(ids);
      return;
    }
    setState(() => _pendingDeleteIds.removeAll(ids));
  }

  /// Commit the pending delete now (the Undo window lapsed, or a new
  /// delete is superseding this one). Fires the held commit callback,
  /// clears the buffer, and — when [committedMsg] is given (the timer
  /// path) — surfaces success/failure. A no-op when nothing is pending,
  /// so it's safe to call defensively. Idempotent: the commit callback
  /// is nulled before the await so a second call can't double-delete.
  void _commitPendingDeletesNow({String? committedMsg}) {
    final commit = _pendingDeleteCommit;
    if (commit == null) return;
    final failMsg = _pendingDeleteFailMsg;
    final committedIds = _pendingDeleteIds.toSet();
    _pendingDeleteTimer?.cancel();
    _pendingDeleteTimer = null;
    _pendingDeleteCommit = null;
    _pendingDeleteFailMsg = null;
    // Keep the rows hidden through the commit — they're gone for good
    // either way; we only re-show them on Undo (which already nulled the
    // commit, so we never reach here for an undone batch).
    () async {
      var ok = true;
      try {
        await commit();
      } catch (_) {
        ok = false;
      }
      if (!mounted) {
        _pendingDeleteIds.removeAll(committedIds);
        return;
      }
      setState(() => _pendingDeleteIds.removeAll(committedIds));
      if (committedMsg != null && !ok && failMsg != null) {
        final messenger = ScaffoldMessenger.of(context);
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(SnackBar(content: Text(failMsg)));
      }
    }();
  }

  Future<void> _bulkMoveAccount() async {
    final l = AppLocalizations.of(context);
    final accId = await showDialog<String>(
      context: context,
      builder: (_) {
        return SimpleDialog(
          title: Text(l.txMoveToAccount),
          children: [
            for (final a in widget.accounts)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(context, a['id']?.toString()),
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

  /// Distinct prettified category labels present in the currently
  /// loaded transactions list. Same source the filter dialog uses so
  /// the split-row dropdown stays in sync with what the user actually
  /// has, instead of offering a fixed taxonomy that drifts over time.
  /// Delegates to the shared util so the dashboard's Home quick-add
  /// FAB offers the identical list when this tab isn't mounted.
  List<String> _distinctCategories() =>
      distinctPrettyCategories(widget.transactions);

  /// Open the split editor for [tx]. On save, fires
  /// `widget.onSplitTransaction` with the parent id and the children
  /// list; the dashboard refreshes the list which causes the parent
  /// to disappear (replaced by its children).
  Future<void> _openSplitDialog(
    dynamic tx,
    String sourceCurrency,
    double sourceAmount,
    String parentLabel,
    String parentCategory,
  ) async {
    final onSplit = widget.onSplitTransaction;
    if (onSplit == null) return;

    final result = await showDialog<List<Map<String, dynamic>>?>(
      context: context,
      builder: (_) => SplitTransactionDialog(
        parentAmount: sourceAmount,
        parentCurrency: sourceCurrency,
        parentLabel: parentLabel,
        parentCategory: parentCategory,
        usdMxnRate: widget.usdMxnRate,
        targetCurrency: widget.targetCurrency,
        reportingFormat: widget.currencyFormat,
        availableCategories: _distinctCategories(),
      ),
    );
    if (result == null || result.isEmpty) return;
    if (!mounted) return;
    // Close the detail modal so the refreshed list (which hides the
    // parent) is the visible state.
    Navigator.of(context).pop();
    final l = AppLocalizations.of(context);
    try {
      await onSplit(tx['id'].toString(), result);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.txSplitIntoN(result.length))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.txSplitFailed(e.toString()))));
    }
  }

  /// Re-open the split editor pre-populated with the parent's existing
  /// children. Saves via the atomic `PUT /splits` endpoint when the
  /// dashboard wired up `onReplaceSplits` — single round-trip, no
  /// race window. Falls back to unsplit-then-resplit when only the
  /// legacy POST + DELETE handlers are available (older backends or
  /// embeddings that don't expose the PUT route).
  ///
  /// Sibling lookup is done client-side against `widget.transactions`.
  /// For typical splits (2-5 children) this works — the list page
  /// size is much larger than that. If pagination ever cuts off some
  /// siblings, the safeguard is the sum-check inside the dialog: the
  /// Save button stays disabled until the rows sum to the parent
  /// amount, so a partial preload becomes visible immediately.
  Future<void> _openEditSplitDialog(
    String parentId,
    String childCurrency,
    double childAmount,
    String parentLabel,
    String parentCategory,
  ) async {
    final onSplit = widget.onSplitTransaction;
    final onUnsplit = widget.onUnsplitTransaction;
    final onReplace = widget.onReplaceSplits;
    if (onSplit == null || onUnsplit == null) return;
    final l = AppLocalizations.of(context);

    final siblings = widget.transactions
        .where(
          (row) =>
              row is Map && (row['parent_id'] ?? '').toString() == parentId,
        )
        .toList();
    if (siblings.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.txSplitChildrenNotFound)));
      return;
    }
    final parentAmount = siblings.fold<double>(0.0, (sum, row) {
      final raw = (row as Map)['amount'];
      return sum + ((raw as num?)?.toDouble() ?? 0.0);
    });
    final initialDrafts = siblings.map<Map<String, dynamic>>((row) {
      final m = row as Map;
      return {
        'description':
            (m['user_description']?.toString().trim().isNotEmpty ?? false)
            ? m['user_description']
            : (m['description'] ?? ''),
        'amount': (m['amount'] as num?)?.toDouble() ?? 0.0,
        'category': (m['user_category'] ?? m['category'] ?? parentCategory)
            .toString(),
      };
    }).toList();

    final result = await showDialog<List<Map<String, dynamic>>?>(
      context: context,
      builder: (_) => SplitTransactionDialog(
        parentAmount: parentAmount,
        parentCurrency: childCurrency,
        parentLabel: parentLabel,
        parentCategory: parentCategory,
        usdMxnRate: widget.usdMxnRate,
        targetCurrency: widget.targetCurrency,
        reportingFormat: widget.currencyFormat,
        initialDrafts: initialDrafts,
        availableCategories: _distinctCategories(),
      ),
    );
    if (result == null || result.isEmpty) return;
    if (!mounted) return;
    Navigator.of(context).pop();
    try {
      if (onReplace != null) {
        // Atomic path — single PUT replaces children in one DB tx.
        await onReplace(parentId, result);
      } else {
        // Legacy two-step path: tear down the existing children, then
        // create the new set. On a failure between the two the parent
        // appears restored in the list — recoverable by re-opening the
        // parent's "Split" action.
        await onUnsplit(parentId);
        await onSplit(parentId, result);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.txSplitUpdatedN(result.length))));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.txEditSplitFailed(e.toString()))),
      );
    }
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
  /// IDs of every transaction in the currently-loaded list that
  /// shares the given row's raw bank description (excluding the row
  /// itself). Same predicate the detail modal uses for the
  /// "also apply to N matching" bulk-rename checkbox.
  List<String> _similarTransactionIds(dynamic tx) {
    final rawDescription = (tx['description'] ?? '').toString().trim();
    if (rawDescription.isEmpty) return const [];
    final key = rawDescription.toLowerCase();
    final index = _ensureDescIndex();
    final cluster = index[key];
    if (cluster == null || cluster.isEmpty) return const [];
    final selfId = tx['id']?.toString();
    // Exclude the row itself from the cluster — the rename dialog's
    // "also apply to N matching" count and the bulk-apply loop both
    // expect "other" rows only.
    if (selfId == null) return cluster;
    return cluster.where((id) => id != selfId).toList(growable: false);
  }

  /// Build (or rebuild) the description→ids index when the
  /// underlying list changes identity. Identity-keyed so a parent
  /// rebuild that hands us the SAME List instance is free.
  Map<String, List<String>> _ensureDescIndex() {
    final txs = widget.transactions;
    final identity = identityHashCode(txs);
    if (_descIndex != null && identity == _descIndexIdentity) {
      return _descIndex!;
    }
    final next = <String, List<String>>{};
    for (final tx in txs) {
      if (tx is! Map) continue;
      final raw = (tx['description'] ?? '').toString().trim();
      if (raw.isEmpty) continue;
      final id = tx['id']?.toString();
      if (id == null) continue;
      next.putIfAbsent(raw.toLowerCase(), () => <String>[]).add(id);
    }
    _descIndex = next;
    _descIndexIdentity = identity;
    return next;
  }

  // O(1) "is this row one leg of an FX-transfer link?" lookup for the
  // list rows. Keyed on transaction id; the value is true when at least
  // one of the row's links is user-confirmed (so a tx that appears in a
  // confirmed AND an auto-detected link reads as confirmed). Identity-
  // keyed on widget.fxTransfers — same memoization pattern as
  // _ensureDescIndex — so rebuilding rows never re-walks the links list
  // unless the dashboard handed us a new one.
  Map<String, bool>? _fxLinkIndex;
  int _fxLinkIndexIdentity = 0;

  Map<String, bool> _ensureFxLinkIndex() {
    final links = widget.fxTransfers;
    final identity = identityHashCode(links);
    if (_fxLinkIndex != null && identity == _fxLinkIndexIdentity) {
      return _fxLinkIndex!;
    }
    final next = <String, bool>{};
    for (final raw in links) {
      if (raw is! Map) continue;
      final confirmed = raw['user_confirmed'] == true;
      for (final key in const ['source_tx_id', 'dest_tx_id']) {
        final id = raw[key]?.toString();
        if (id == null || id.isEmpty) continue;
        next[id] = (next[id] ?? false) || confirmed;
      }
    }
    _fxLinkIndex = next;
    _fxLinkIndexIdentity = identity;
    return next;
  }

  Future<void> _renameTransaction(
    dynamic tx, {
    List<String> similarIds = const [],
  }) async {
    final onUpdate = widget.onUpdate;
    if (onUpdate == null) return;
    final l = AppLocalizations.of(context);
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
        return StatefulBuilder(
          builder: (ctx, setLocal) {
            return AlertDialog(
              title: Text(l.txRenameTransaction),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l.txRenameDisplayLabelHelp,
                    style: TextStyle(fontSize: 12, color: context.textSubtle),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    autofocus: true,
                    decoration: InputDecoration(
                      labelText: l.txDisplayLabel,
                      hintText: l.txDisplayLabelHint,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  if (similarIds.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: applyToAll,
                      onChanged: (v) => setLocal(() => applyToAll = v ?? false),
                      title: Text(
                        l.txAlsoApplyToN(similarIds.length),
                        style: const TextStyle(fontSize: 13),
                      ),
                      subtitle: Text(
                        l.txAlsoApplySubtitle,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.textSubtle,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(null),
                  child: Text(l.actionCancel),
                ),
                // Clear button only when something is set on the row already
                // — avoids a dead button on transactions that never had an
                // override applied.
                if ((tx['user_description'] ?? '').toString().isNotEmpty)
                  TextButton(
                    onPressed: () => Navigator.of(
                      ctx,
                    ).pop((text: '', applyToAll: applyToAll)),
                    child: Text(l.txClearOverride),
                  ),
                FilledButton(
                  onPressed: () => Navigator.of(
                    ctx,
                  ).pop((text: controller.text.trim(), applyToAll: applyToAll)),
                  child: Text(l.actionSave),
                ),
              ],
            );
          },
        );
      },
    );
    // dispose: local controller, else the dialog leaks it. controller.text was
    // already captured into `result` inside the dialog.
    controller.dispose();
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
              ? (failed == 0 ? l.txRenamed : l.txRenameFailedShort)
              : (failed == 0
                    ? l.txRenamedN(ids.length)
                    // gen-l10n orders these alphabetically → (failed, ok); pass failed first.
                    : l.txRenamedNFailed(failed, ids.length - failed)),
        ),
      ),
    );
  }

  // Prefers the batch endpoint (one request + one refresh for the whole
  // selection); falls back to looping the per-id onUpdate only if no bulk
  // handler is wired.
  Future<void> _applyBulkUpdate({
    String? userCategory,
    String? accountId,
    String? userDescription,
  }) async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(SnackBar(content: Text(l.txUpdatingN(ids.length))));

    int updated = 0;
    int failed = 0;
    final onBulk = widget.onBulkUpdate;
    if (onBulk != null) {
      // One batched request → one dashboard refresh.
      try {
        updated = await onBulk(
          ids,
          userCategory: userCategory,
          accountId: accountId,
          userDescription: userDescription,
        );
        failed = ids.length - updated;
      } catch (_) {
        failed = ids.length;
      }
    } else {
      final onUpdate = widget.onUpdate;
      if (onUpdate == null) return;
      for (final id in ids) {
        try {
          await onUpdate(
            id,
            userCategory: userCategory,
            accountId: accountId,
            userDescription: userDescription,
          );
          updated++;
        } catch (_) {
          failed++;
        }
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
              ? l.txUpdatedN(updated)
              // gen-l10n orders these alphabetically → (failed, ok); pass failed first.
              : l.txUpdatedNFailed(failed, updated),
        ),
      ),
    );
  }

  /// Sort menu (wide layout only — narrow folds sort into the filter
  /// sheet). An M3 Badge dot marks any non-default order; a check marks
  /// the active option. Selecting a mode just flips _sortMode — the
  /// filtering pipeline re-sorts and the item plan switches between the
  /// grouped (newest-first only) and flat (every other mode) layouts.
  Widget _buildSortMenu(AppLocalizations l) {
    return PopupMenuButton<TxSort>(
      tooltip: l.txSortBy,
      icon: Badge(
        isLabelVisible: _sortMode != TxSort.dateNewest,
        smallSize: 8,
        child: const Icon(Icons.sort, size: 22),
      ),
      onSelected: (mode) => setState(() => _sortMode = mode),
      itemBuilder: (context) => [
        for (final mode in TxSort.values)
          PopupMenuItem(
            value: mode,
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: _sortMode == mode
                      ? Icon(Icons.check, size: 18, color: context.positive)
                      : null,
                ),
                Text(txSortLabel(l, mode)),
              ],
            ),
          ),
      ],
    );
  }

  /// Header toolbar. Wide screens show title + filter/sort/actions +
  /// inline search. Narrow screens keep exactly three inline actions —
  /// combined filter&sort, add, overflow — and the persistent search
  /// field renders on its own full-width row below the toolbar (see the
  /// build method), so search no longer replaces the whole toolbar.
  Widget _buildToolbar(bool isNarrow) {
    final l = AppLocalizations.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            l.navTransactions,
            // Slightly smaller on narrow; with only three inline actions
            // the title fits a phone sheet without ellipsizing.
            style: TextStyle(
              fontSize: isNarrow ? 22 : 24,
              fontWeight: FontWeight.bold,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Filter & sort. Narrow: ONE combined button that opens the
            // filter+sort bottom sheet, with an M3 count badge totalling
            // the active filters plus a non-default sort. Wide: separate
            // filter-dialog button and sort menu sharing the same Badge
            // idiom. Always visible — independent of apiService.
            if (isNarrow)
              IconButton(
                onPressed: () => _openFilters(isNarrow: true),
                icon: Badge.count(
                  count:
                      _filters.badgeCount +
                      (_sortMode != TxSort.dateNewest ? 1 : 0),
                  isLabelVisible:
                      _filters.isActive || _sortMode != TxSort.dateNewest,
                  child: const Icon(Icons.tune, size: 22),
                ),
                tooltip: l.txFilterSort,
              )
            else ...[
              IconButton(
                onPressed: () => _openFilters(isNarrow: false),
                icon: Badge.count(
                  count: _filters.badgeCount,
                  isLabelVisible: _filters.isActive,
                  child: const Icon(Icons.tune, size: 22),
                ),
                tooltip: l.txFilterTransactions,
              ),
              // Sort control (wide only — narrow folds sort into the
              // filter sheet). A Badge dot marks a non-default order.
              _buildSortMenu(l),
            ],
            // On narrow widths the secondary actions (select-multiple, CSV
            // export, FX-transfer scan) collapse into an overflow menu so
            // the "Transactions" title keeps enough room. Filter&sort +
            // add stay inline as the primary actions (search lives on its
            // own row below the toolbar).
            if (!isNarrow)
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
                tooltip: _selectionMode
                    ? l.txExitSelectionMode
                    : l.txSelectMultiple,
              ),
            // Hidden when the host provides its own FAB (compact dashboard)
            // so there's never a duplicate creation affordance.
            if (widget.apiService != null && !widget.hostProvidesAddFab)
              IconButton(
                onPressed: () => openAddDialog(),
                icon: const Icon(Icons.add, size: 22),
                tooltip: l.txAddTransaction,
              ),
            if (!isNarrow && widget.apiService != null)
              IconButton(
                onPressed: () => _downloadCsv(),
                icon: const Icon(Icons.file_download_outlined, size: 22),
                // When a filter/search is active — or the host's list is
                // implicitly scoped (csvExportConfirmAlways) — the export
                // is now generated client-side from the filtered rows, so
                // the affordance says it covers the current view; only the
                // unfiltered case hits the full server export.
                tooltip:
                    (widget.csvExportConfirmAlways ||
                        _searchQuery.isNotEmpty ||
                        _filters.isActive)
                    ? l.txExportCsvFiltered
                    : l.txExportCsv,
              ),
            if (!isNarrow && widget.onDetectFxTransfers != null)
              IconButton(
                tooltip: l.txScanTransfers,
                icon: const Icon(Icons.swap_horiz, size: 22),
                onPressed: () => widget.onDetectFxTransfers!(),
              ),
            if (isNarrow) ...[
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_vert, size: 22),
                tooltip: l.txMoreActions,
                onSelected: (value) {
                  switch (value) {
                    case 'select':
                      setState(() {
                        _selectionMode = !_selectionMode;
                        if (!_selectionMode) _selectedIds.clear();
                      });
                      break;
                    case 'csv':
                      _downloadCsv();
                      break;
                    case 'fx':
                      widget.onDetectFxTransfers?.call();
                      break;
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'select',
                    child: Row(
                      children: [
                        Icon(
                          _selectionMode ? Icons.close : Icons.checklist,
                          size: 20,
                        ),
                        const SizedBox(width: 12),
                        Flexible(
                          child: Text(
                            _selectionMode
                                ? l.txExitSelectionMode
                                : l.txSelectMultiple,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.apiService != null)
                    PopupMenuItem(
                      value: 'csv',
                      // Short label in the menu — the verbose "…matching your
                      // filter" wording stays on the wide-layout tooltip; here
                      // it overflowed the item off the screen edge.
                      child: Row(
                        children: [
                          const Icon(Icons.file_download_outlined, size: 20),
                          const SizedBox(width: 12),
                          Flexible(child: Text(l.txExportCsv)),
                        ],
                      ),
                    ),
                  if (widget.onDetectFxTransfers != null)
                    PopupMenuItem(
                      value: 'fx',
                      child: Row(
                        children: [
                          const Icon(Icons.swap_horiz, size: 20),
                          const SizedBox(width: 12),
                          Flexible(child: Text(l.txScanTransfers)),
                        ],
                      ),
                    ),
                ],
              ),
            ] else
              SizedBox(width: 280, height: 40, child: _searchField()),
          ],
        ),
      ],
    );
  }

  /// Opens the Add-transaction dialog. Public so a host that provides its
  /// own creation affordance (the dashboard's compact-layout FAB, via a
  /// `GlobalKey<TransactionsTabState>`) can trigger the exact same flow.
  void openAddDialog() {
    if (widget.apiService == null) return;
    showDialog(
      context: context,
      builder: (_) => AddTransactionDialog(
        accounts: widget.accounts,
        apiService: widget.apiService!,
        onCreated: () => widget.onTransactionAdded?.call(),
        categorySuggestions: _distinctCategories(),
        initialAccountId: widget.addTransactionAccountId,
      ),
    );
  }

  /// Opens the Add-transaction dialog in EDIT mode for a manual row
  /// (`source == 'manual'`): every field pre-filled from the row, submit
  /// PUTs an update against it. Reuses [AddTransactionDialog] so the
  /// edit form can never drift from the add form. Fired from the detail
  /// panel's "Edit transaction" overflow action (manual rows only — the
  /// server enforces this too with a 403).
  void _openEditManualDialog(dynamic tx) {
    if (widget.apiService == null) return;
    showDialog(
      context: context,
      builder: (_) => AddTransactionDialog(
        accounts: widget.accounts,
        apiService: widget.apiService!,
        onCreated: () => widget.onTransactionAdded?.call(),
        categorySuggestions: _distinctCategories(),
        // Account-scoped payloads omit account_id — the host's own
        // account preselect covers that case, same as the add flow.
        initialAccountId: widget.addTransactionAccountId,
        editTransaction: Map<String, dynamic>.from(tx as Map),
      ),
    );
  }

  Future<void> _downloadCsv() async {
    if (widget.apiService == null) return;
    // A filter/search — or a host whose list is implicitly scoped to one
    // account (csvExportConfirmAlways) — means "everything" is the wrong
    // answer. In that case build the CSV CLIENT-SIDE from the filtered
    // rows so the export matches exactly what the user is looking at; no
    // "covers everything" confirmation, because it no longer does.
    final scoped =
        widget.csvExportConfirmAlways ||
        _searchQuery.isNotEmpty ||
        _filters.isActive;
    if (scoped) {
      await _exportFilteredCsv();
      return;
    }
    // Unfiltered, unscoped: keep the server-side full export untouched.
    // Hand off to the browser — the backend responds with
    // Content-Disposition: attachment so the browser downloads directly.
    // Routed through the url_opener seam (no-op on the test VM) so this
    // file stays free of a direct package:web import.
    openUrlSameTab(widget.apiService!.exportTransactionsCsvUrl());
  }

  /// Client-side CSV of the currently-filtered rows. First cascades in
  /// the full filtered history (reusing the Feature-3 / filter cascade)
  /// so the export isn't truncated to the loaded page window, then
  /// serialises the rows and hands a `data:` URL to the browser via the
  /// same url_opener seam (no backend changes, no package:web import
  /// here). Columns mirror the server export.
  Future<void> _exportFilteredCsv() async {
    final l = AppLocalizations.of(context);
    if (widget.hasMore && widget.onLoadMore != null) {
      try {
        await _loadAllForFilter();
      } catch (_) {
        // A partial load still exports what's loaded — better than
        // nothing; the cascade swallows its own errors anyway.
      }
      if (!mounted) return;
    }
    final rows = _filteredTransactions;
    if (rows.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.txExportNoRows)));
      return;
    }
    final csv = _buildCsv(rows);
    // data: URL — utf-8, URL-encoded so commas/newlines/non-ASCII in the
    // descriptions survive. The browser treats it as a download because
    // there's no navigable document; on the test VM openUrlSameTab is a
    // no-op (the seam), so this stays test-safe.
    final dataUrl = 'data:text/csv;charset=utf-8,${Uri.encodeComponent(csv)}';
    openUrlSameTab(dataUrl);
  }

  /// Serialise [rows] to a CSV string with the same column set as the
  /// server export: date, account, description, merchant, category,
  /// amount, currency, pending. Each field is RFC-4180 quoted.
  String _buildCsv(List<dynamic> rows) {
    final buf = StringBuffer();
    buf.writeln(
      'date,account,description,merchant,category,'
      'amount,currency,pending',
    );
    for (final tx in rows) {
      final cells = <String>[
        (tx['date'] ?? '').toString(),
        (tx['account_name'] ?? '').toString(),
        displayLabel(Map<String, dynamic>.from(tx as Map)),
        (tx['merchant_name'] ?? '').toString(),
        (tx['category'] ?? '').toString(),
        ((tx['amount'] as num?)?.toString()) ?? '',
        (tx['currency'] ?? '').toString(),
        (tx['pending'] == true) ? 'true' : 'false',
      ];
      buf.writeln(cells.map(_csvCell).join(','));
    }
    return buf.toString();
  }

  /// RFC-4180 cell: wrap in double quotes when the value contains a
  /// comma, quote, or newline, doubling any embedded quotes.
  String _csvCell(String v) {
    if (v.contains(',') ||
        v.contains('"') ||
        v.contains('\n') ||
        v.contains('\r')) {
      return '"${v.replaceAll('"', '""')}"';
    }
    return v;
  }

  Widget _searchField() {
    final l = AppLocalizations.of(context);
    return TextField(
      controller: _searchController,
      // Debounced. See _searchDebounce field comment for rationale.
      // When the user clears via the X button below we flush
      // synchronously instead of waiting for the timer.
      onChanged: (v) {
        _searchDebounce?.cancel();
        _searchDebounce = Timer(
          const Duration(milliseconds: _searchDebounceMs),
          () {
            if (!mounted) return;
            if (v != _searchQuery) setState(() => _searchQuery = v);
          },
        );
      },
      decoration: InputDecoration(
        hintText: l.searchTransactionsHint,
        hintStyle: TextStyle(color: context.textFaint, fontSize: 13),
        prefixIcon: Icon(Icons.search, size: 18, color: context.textFaint),
        // Inline clear affordance — appears only when there's text so the
        // user doesn't have to backspace the whole query. Flushes the
        // pending debounce synchronously so no stray re-filter fires
        // after the field is already empty. This is the only clear path
        // now that the field is persistent on narrow (no close button).
        suffixIcon: ValueListenableBuilder<TextEditingValue>(
          valueListenable: _searchController,
          builder: (context, value, _) {
            if (value.text.isEmpty) return const SizedBox.shrink();
            return IconButton(
              icon: Icon(Icons.close, size: 18, color: context.textFaint),
              tooltip: l.txClear,
              onPressed: () {
                _searchDebounce?.cancel();
                _searchController.clear();
                setState(() => _searchQuery = '');
              },
            );
          },
        ),
        filled: true,
        fillColor: context.tint(0.05),
        contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
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
  /// Dispatch between eager `Column` (≤50 rows, page scrolls
  /// naturally) and a bounded `ListView.builder` (the virtualised
  /// path, used at scale). The threshold isn't tuned hard — under
  /// ~50 rows the Column's allocations are negligible and the
  /// page-scroll UX is friendlier; above that, the build cost of
  /// every row dominates and inner-list scrolling is the lesser
  /// evil.
  ///
  /// Unbounded-host path only (dashboard page scroll). Bounded hosts
  /// (the account side panel / bottom sheet) bypass this entirely and
  /// put [_buildVirtualisedList] in an Expanded, sized by the host's
  /// own constraints rather than the window height.
  Widget _buildRowsRegion(
    List<dynamic> txs,
    bool isNarrow,
    BoxConstraints constraints,
  ) {
    const eagerThreshold = 50;
    if (txs.length <= eagerThreshold) {
      return Padding(
        // Clearance so a host-provided FAB (compact dashboard) never sits
        // on top of the last row. Mirrors _buildVirtualisedList's padding.
        padding: EdgeInsets.only(
          bottom: widget.hostProvidesAddFab ? 88.0 : 0.0,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _buildGroupedRows(txs, isNarrow),
        ),
      );
    }
    // Viewport-relative height so the inner list always shows a
    // few screenfuls without dominating the page. The 400px floor
    // prevents a degenerate tiny window — but only when the viewport
    // can actually fit it: on short windows (h * 0.78 < 400) the
    // floor drops to the ceiling so clamp's bounds stay ordered.
    // (lo > hi throws ArgumentError, which used to paint the whole
    // tab as the red error widget on any window under ~513px.)
    final h = MediaQuery.sizeOf(context).height;
    final hi = h * 0.78;
    final lo = hi < 400.0 ? hi : 400.0;
    final listHeight = (h - 280).clamp(lo, hi);
    return SizedBox(
      height: listHeight,
      child: _buildVirtualisedList(txs, isNarrow),
    );
  }

  /// The virtualised inner list: scrollbar + `ListView.builder` over
  /// the precomputed item plan. The caller decides the height — a
  /// window-derived SizedBox on the (unbounded) dashboard, or an
  /// Expanded slot in a bounded host.
  Widget _buildVirtualisedList(List<dynamic> txs, bool isNarrow) {
    final items = _ensureItemPlan(txs, isNarrow);
    // A forced-visible thumb is a pointer affordance: on touch platforms
    // the persistent bar paints on top of the rows' amount column, so let
    // those fall back to the transient auto-hiding thumb.
    final platform = Theme.of(context).platform;
    final isTouch =
        platform == TargetPlatform.android ||
        platform == TargetPlatform.iOS ||
        platform == TargetPlatform.fuchsia;
    return Scrollbar(
      thumbVisibility: !isTouch,
      child: ListView.builder(
        // No itemExtent — rows can be one or two lines depending
        // on the override / notes presence. Flutter still
        // virtualises by viewport visibility; we just lose the
        // O(1) scroll-to-index optimisation, which we don't need.
        //
        // Bottom clearance so a host-provided FAB (compact dashboard)
        // never occludes the last row when scrolled to the end.
        padding: EdgeInsets.only(
          bottom: widget.hostProvidesAddFab ? 88.0 : 0.0,
        ),
        itemCount: items.length,
        itemBuilder: (context, i) => _planItemWidget(items[i], isNarrow, txs),
      ),
    );
  }

  /// Eager (≤50 rows) path: same item plan as the virtualised list,
  /// materialised into a plain Column. One grouping algorithm, two hosts —
  /// month landmarks and day headers can never drift between them.
  List<Widget> _buildGroupedRows(List<dynamic> txs, bool isNarrow) {
    return [
      for (final item in _ensureItemPlan(txs, isNarrow))
        _planItemWidget(item, isNarrow, txs),
    ];
  }

  /// One plan item → one widget. Shared by the virtualised builder and
  /// the eager Column so both render the exact same grouping.
  Widget _planItemWidget(_TxListItem item, bool isNarrow, List<dynamic> txs) {
    switch (item.kind) {
      case 0:
        return _dateGroupHeader(item.date!, isFirst: item.isFirst);
      case 2:
        return Divider(
          height: 1,
          thickness: 1,
          color: context.hairline,
          indent: 44, // align with the description column, past the icon
        );
      case 3:
        return _monthGroupHeader(item.date!, txs, isFirst: item.isFirst);
      default:
        return _buildTransactionRow(item.tx, isNarrow);
    }
  }

  /// Flat index→item plan shared by both list paths (virtualised
  /// ListView.builder and the eager Column). Each item is one of:
  ///   • month header — calendar-month landmark ("June 2026" + net)
  ///   • day header   — a date-group heading ("Today", etc.)
  ///   • row          — one transaction
  ///   • divider      — separator between rows in the same group
  ///
  /// Precomputed once per (filtered list identity, isNarrow) so the
  /// builder can return one widget per index in O(1) without re-
  /// scanning the date groups.
  List<_TxListItem>? _itemPlanCache;
  int _itemPlanCacheFilteredId = 0;
  bool _itemPlanCacheNarrow = false;
  TxSort? _itemPlanCacheSort;

  List<_TxListItem> _ensureItemPlan(List<dynamic> txs, bool isNarrow) {
    final identity = identityHashCode(txs);
    if (_itemPlanCache != null &&
        _itemPlanCacheFilteredId == identity &&
        _itemPlanCacheNarrow == isNarrow &&
        _itemPlanCacheSort == _sortMode) {
      return _itemPlanCache!;
    }
    // Any sort other than the default (newest-first) breaks the
    // contiguous-by-date assumption the month/day headers rely on, so
    // those modes render a FLAT list: just rows, hairline-separated, no
    // headers. (A divider between every row keeps the row rhythm the
    // grouped view has between same-day rows.)
    if (_sortMode != TxSort.dateNewest) {
      final flat = <_TxListItem>[];
      for (var i = 0; i < txs.length; i++) {
        if (i > 0) flat.add(const _TxListItem.divider());
        flat.add(_TxListItem.row(tx: txs[i]));
      }
      _itemPlanCache = flat;
      _itemPlanCacheFilteredId = identity;
      _itemPlanCacheNarrow = isNarrow;
      _itemPlanCacheSort = _sortMode;
      return flat;
    }
    final out = <_TxListItem>[];
    String? lastGroup;
    // Calendar month of the last emitted month landmark. Stays null
    // through the Today/Yesterday band so the list never opens with a
    // redundant "June 2026" banner above "Today" — the first landmark
    // appears at the first day group outside that band.
    String? lastMonthKey;
    for (var i = 0; i < txs.length; i++) {
      final tx = txs[i];
      final dateStr = tx['date'] as String?;
      if (dateStr == null) continue;
      final date = DateTime.parse(dateStr);
      final key = _dateGroupKey(date);
      if (key != lastGroup) {
        var afterMonth = false;
        if (key != 'today' && key != 'yesterday') {
          final monthKey = _monthKey(date);
          if (monthKey != lastMonthKey) {
            out.add(_TxListItem.monthHeader(date: date, isFirst: out.isEmpty));
            lastMonthKey = monthKey;
            afterMonth = true;
          }
        }
        // A day header straight under its month landmark hugs it
        // (isFirst spacing) instead of opening a second air gap.
        out.add(
          _TxListItem.header(date: date, isFirst: out.isEmpty || afterMonth),
        );
        lastGroup = key;
      } else {
        out.add(const _TxListItem.divider());
      }
      out.add(_TxListItem.row(tx: tx));
    }
    _itemPlanCache = out;
    _itemPlanCacheFilteredId = identity;
    _itemPlanCacheNarrow = isNarrow;
    _itemPlanCacheSort = _sortMode;
    return out;
  }

  /// Stable per-calendar-month grouping key ("2026-6").
  String _monthKey(DateTime date) => '${date.year}-${date.month}';

  // Month → net flow (income positive, in the reporting currency) over
  // the rows currently in the list — i.e. loaded AND matching any active
  // filter, exactly what the user sees under the landmark. FX-transfer
  // legs are skipped: money moving between the user's own pockets is
  // neither income nor spending (same rule as the rows' neutral ⇄
  // treatment). Memoized on (list identity, fx identity, usdMxnRate,
  // targetCurrency), mirroring _ensureDescIndex / _ensureFxLinkIndex.
  // targetCurrency is part of the key so the in-session reporting-currency
  // swap invalidates the cached nets (they'd otherwise stay in the old
  // currency, merely relabeled).
  Map<String, double>? _monthNets;
  int _monthNetsTxIdentity = 0;
  int _monthNetsFxIdentity = 0;
  double _monthNetsRate = -1;
  String _monthNetsCurrency = '';
  // Oldest (last) loaded calendar month — when the parent says more
  // pages exist, that month's subtotal is honestly flagged "(partial)".
  String? _monthNetsOldestKey;

  Map<String, double> _ensureMonthNets(List<dynamic> txs) {
    final identity = identityHashCode(txs);
    final fxIdentity = identityHashCode(widget.fxTransfers);
    if (_monthNets != null &&
        _monthNetsTxIdentity == identity &&
        _monthNetsFxIdentity == fxIdentity &&
        _monthNetsRate == widget.usdMxnRate &&
        _monthNetsCurrency == widget.targetCurrency) {
      return _monthNets!;
    }
    final fxIndex = _ensureFxLinkIndex();
    final next = <String, double>{};
    String? oldest;
    for (final tx in txs) {
      final dateStr = tx['date'] as String?;
      if (dateStr == null) continue;
      final key = _monthKey(DateTime.parse(dateStr));
      // Every loaded month gets an entry (a transfers-only month nets
      // to 0.00 rather than missing); rows are newest-first, so the
      // last write is the oldest loaded month.
      next.putIfAbsent(key, () => 0.0);
      oldest = key;
      final id = tx['id']?.toString();
      if (id != null && fxIndex.containsKey(id)) continue; // transfer leg
      final amount = (tx['amount'] as num?)?.toDouble() ?? 0.0;
      final converted = convertCurrency(
        amount,
        from: (tx['currency'] ?? widget.targetCurrency).toString(),
        to: widget.targetCurrency,
        usdMxnRate: widget.usdMxnRate,
      );
      // Storage sign convention (backend sync.rs:659): negative =
      // outflow, positive = inflow — so the income-positive net is a
      // plain sum of amounts (transfer legs excluded above).
      next[key] = next[key]! + converted;
    }
    _monthNets = next;
    _monthNetsTxIdentity = identity;
    _monthNetsFxIdentity = fxIdentity;
    _monthNetsRate = widget.usdMxnRate;
    _monthNetsCurrency = widget.targetCurrency;
    _monthNetsOldestKey = oldest;
    return next;
  }

  /// Summary line under "Showing X of Y", shown only while a filter/search
  /// is active. Reports net + outflow + inflow over the full filtered set
  /// (cascade-loaded, not just the rendered page) in the reporting currency.
  /// Net is colored via the positive/negative tokens (income-positive); the
  /// outflow/inflow breakdown is muted so the net stays the headline.
  Widget _buildFilteredSummary(List<dynamic> filtered) {
    final l = AppLocalizations.of(context);
    final totals = _filteredTotals(filtered);
    final signedNet =
        '${totals.net < 0 ? '−' : '+'}${widget.currencyFormat.format(totals.net.abs())}';
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Wrap(
        spacing: 12,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: '${l.txFilteredNet} ',
                  style: TextStyle(color: context.textSubtle, fontSize: 12),
                ),
                TextSpan(
                  text: signedNet,
                  style: TextStyle(
                    color: totals.net < 0 ? context.negative : context.positive,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
          Text(
            l.txFilteredOutflow(widget.currencyFormat.format(totals.outflow)),
            style: TextStyle(
              color: context.textSubtle,
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          Text(
            l.txFilteredInflow(widget.currencyFormat.format(totals.inflow)),
            style: TextStyle(
              color: context.textSubtle,
              fontSize: 12,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  /// Net / outflow / inflow over an arbitrary set of rows in the reporting
  /// currency. Same rules as _ensureMonthNets: per-row currency conversion
  /// and FX-transfer-leg exclusion (money moving between the user's own
  /// pockets is neither income nor spending), and the storage sign
  /// convention (negative = outflow, positive = inflow). Used for the
  /// filtered-set summary under "Showing X of Y" — outflow is reported as a
  /// positive magnitude, net is income-positive.
  ({double net, double outflow, double inflow}) _filteredTotals(
    List<dynamic> txs,
  ) {
    final fxIndex = _ensureFxLinkIndex();
    var outflow = 0.0;
    var inflow = 0.0;
    for (final tx in txs) {
      final id = tx['id']?.toString();
      if (id != null && fxIndex.containsKey(id)) continue; // transfer leg
      final amount = (tx['amount'] as num?)?.toDouble() ?? 0.0;
      final converted = convertCurrency(
        amount,
        from: (tx['currency'] ?? widget.targetCurrency).toString(),
        to: widget.targetCurrency,
        usdMxnRate: widget.usdMxnRate,
      );
      if (converted < 0) {
        outflow += -converted;
      } else {
        inflow += converted;
      }
    }
    return (net: inflow - outflow, outflow: outflow, inflow: inflow);
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
  /// "Yesterday", then weekday + date for the past week ("Monday, Jun 8"
  /// — a bare "Monday" never says WHICH Monday), then a short date for
  /// older groups. The locale-skeleton constructors (MMMd/yMMMd) follow
  /// the active locale's day/month order ("Jun 8" vs "8 jun"), which
  /// works now that Intl.defaultLocale is initialised at startup.
  Widget _dateGroupHeader(DateTime date, {required bool isFirst}) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final d = DateTime(date.year, date.month, date.day);
    final diff = today.difference(d).inDays;
    final l = AppLocalizations.of(context);
    String label;
    if (diff == 0) {
      label = l.txDateToday;
    } else if (diff == 1) {
      label = l.txDateYesterday;
    } else if (diff > 1 && diff < 7) {
      label =
          '${DateFormat('EEEE').format(date)}, ${DateFormat.MMMd().format(date)}';
    } else if (date.year == now.year) {
      label = DateFormat.MMMd().format(date);
    } else {
      label = DateFormat.yMMMd().format(date);
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

  /// Calendar-month landmark inserted where the list crosses into a new
  /// month: "June 2026" on the left, the month's net flow over the rows
  /// shown below it on the right ("−\$1,234.56 net"). One tier above the
  /// day headers (larger, textMuted vs textSubtle, hairline underline)
  /// so hundreds of "Jun 3"-style micro-sections finally get structure —
  /// and the list can answer "what did June cost me?" at a glance.
  Widget _monthGroupHeader(
    DateTime date,
    List<dynamic> txs, {
    required bool isFirst,
  }) {
    final l = AppLocalizations.of(context);
    final key = _monthKey(date);
    final net = _ensureMonthNets(txs)[key] ?? 0.0;
    // The oldest loaded month may be cut off by pagination; when the
    // parent says more pages exist its subtotal is flagged "(partial)".
    final isPartial = widget.hasMore && key == _monthNetsOldestKey;
    // yMMMM follows the locale ("June 2026" / "junio de 2026"); Spanish
    // month names are lowercase, so sentence-case the heading.
    var label = DateFormat.yMMMM().format(date);
    if (label.isNotEmpty) {
      label = label[0].toUpperCase() + label.substring(1);
    }
    final signedNet =
        '${net < 0 ? '−' : '+'}${widget.currencyFormat.format(net.abs())}';
    final netLabel = isPartial
        ? l.txMonthNetPartial(signedNet)
        : l.txMonthNet(signedNet);
    return Padding(
      padding: EdgeInsets.only(top: isFirst ? 4 : 28, left: 4, right: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.baseline,
            textBaseline: TextBaseline.alphabetic,
            children: [
              Expanded(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: context.textMuted,
                    letterSpacing: 0.4,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 12),
              Text(
                netLabel,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: context.textSubtle,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Divider(height: 1, thickness: 1, color: context.hairline),
        ],
      ),
    );
  }

  /// One row in the transactions list. Modern dense layout — 32px icon,
  /// single-line description + meta, right-aligned native-currency amount.
  /// Total row height is ~56px (was 92), so a wall of transactions
  /// actually feels like a scannable list instead of an inbox of cards.
  Widget _buildTransactionRow(dynamic tx, bool isNarrow) {
    final l = AppLocalizations.of(context);
    // Phone screens bump the row's type up a notch for legibility; the
    // denser desktop sizing is unchanged. Paired with the tighter card
    // gutters on narrow, the title/amount columns have room to grow.
    final titleSize = isNarrow ? 15.0 : 14.0;
    final metaSize = isNarrow ? 12.0 : 11.0;
    final amountSize = isNarrow ? 15.0 : 14.0;
    final sourceAmount = ((tx['amount'] as num?)?.toDouble() ?? 0.0);
    final sourceCurrency = (tx['currency'] ?? widget.targetCurrency).toString();
    final converted = convertCurrency(
      sourceAmount,
      from: sourceCurrency,
      to: widget.targetCurrency,
      usdMxnRate: widget.usdMxnRate,
    );
    // Storage sign convention (backend sync.rs:659): negative = outflow,
    // positive = inflow.
    final isExpense = sourceAmount < 0;
    final notes = (tx['user_notes'] ?? '').toString();
    // Same prettified label the row's meta line shows — the registry is
    // keyed on it, so a Spanish import category ("Supermercado") and the
    // Plaid enum ("FOOD_AND_DRINK") both land on a real style instead of
    // the old grey-receipt fallback.
    final catStyle = context.categoryStyle(
      prettyCategory(
        userCategory: tx['user_category']?.toString(),
        detailed: tx['category_detailed']?.toString(),
        primary: tx['category']?.toString(),
      ),
    );
    final color = catStyle.color;

    final needsConversion =
        widget.usdMxnRate > 0 && sourceCurrency != widget.targetCurrency;

    final id = tx['id']?.toString();
    final isSelected = id != null && _selectedIds.contains(id);

    // Single-account panel only: "balance after this transaction" —
    // exact when the statement import persisted it, '≈'-estimated from
    // the current balance otherwise, absent when neither is sound.
    final balanceAfter = id == null ? null : _runningBalances[id];

    // FX-transfer leg? null = not linked; true/false = linked and
    // (any-)confirmed / auto-detected only. Drives the TRANSFER pill and
    // the neutral amount treatment — money moving between the user's own
    // pockets must not read as income (+green) or spending.
    final fxConfirmed = id == null ? null : _ensureFxLinkIndex()[id];
    final isFxTransfer = fxConfirmed != null;
    // Pill accent mirrors the detail block's semantics: teal = user-
    // confirmed link, amber = auto-detected (pending confirmation).
    final fxAccent = (fxConfirmed ?? false)
        ? context.tealAccent
        : context.warning;

    return MouseRegion(
      // Tracks the currently-hovered row id so the R keyboard
      // shortcut at the tab level knows which row to enter inline-
      // edit on. Cleared on exit so R does nothing when the cursor
      // sits in the empty space below the list.
      onEnter: (_) {
        if (id != null) _hoveredTxId = id;
      },
      onExit: (_) {
        if (_hoveredTxId == id) _hoveredTxId = null;
      },
      child: InkWell(
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
        // Right-click on web (Flutter maps secondary tap to right-click)
        // opens the quick rename dialog directly — skips the detail
        // modal hop. The dialog itself is the existing
        // `_renameTransaction` which is already a lightweight 1-field
        // form, so this is purely about cutting clicks for power users
        // cleaning up "Miscellaneous Debit"-style clusters.
        onSecondaryTap: widget.onUpdate == null
            ? null
            : () {
                if (id == null || _selectionMode) return;
                // Compute the "similar rows" set the same way the
                // detail modal does so the bulk-apply checkbox appears
                // when this row is part of a cluster.
                final similarIds = _similarTransactionIds(tx);
                _renameTransaction(tx, similarIds: similarIds);
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
                child: Icon(catStyle.icon, color: color, size: 16),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          // When this row is the inline-edit target, swap
                          // the Text for a TextField bound to the
                          // controller. Enter saves via _commitInlineEdit,
                          // Esc cancels via the Focus key handler. Tapping
                          // outside (TapRegion) also cancels — clicking
                          // anywhere else in the list is a clearer "I
                          // changed my mind" signal than implicit blur.
                          child: _inlineEditingTxId == (tx['id']?.toString())
                              ? Focus(
                                  onKeyEvent: (node, ev) {
                                    if (ev is KeyDownEvent &&
                                        ev.logicalKey ==
                                            LogicalKeyboardKey.escape) {
                                      _cancelInlineEdit();
                                      return KeyEventResult.handled;
                                    }
                                    return KeyEventResult.ignored;
                                  },
                                  child: TapRegion(
                                    onTapOutside: (_) => _cancelInlineEdit(),
                                    child: TextField(
                                      controller: _inlineEditController,
                                      focusNode: _inlineEditFocus,
                                      autofocus: true,
                                      onSubmitted: (_) => _commitInlineEdit(tx),
                                      style: TextStyle(
                                        fontWeight: FontWeight.w600,
                                        fontSize: titleSize,
                                        height: 1.2,
                                      ),
                                      decoration: InputDecoration(
                                        isDense: true,
                                        contentPadding:
                                            const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 4,
                                            ),
                                        border: const OutlineInputBorder(),
                                        hintText: l.txInlineEditHint,
                                      ),
                                    ),
                                  ),
                                )
                              : GestureDetector(
                                  // Double-click on the label drops into
                                  // inline-edit mode. Single-tap still
                                  // bubbles to the row's onTap (detail
                                  // modal) because GestureDetector only
                                  // intercepts the double-tap gesture.
                                  onDoubleTap: widget.onUpdate == null
                                      ? null
                                      : () => _startInlineEdit(tx),
                                  child: Text(
                                    displayLabel(tx),
                                    style: TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: titleSize,
                                      height: 1.2,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                        ),
                        // "Split" pill on rows that are a child of a split.
                        // Cheap visual cue so the user can tell the $50
                        // grocery line is actually a leg of a larger ATM
                        // withdrawal, not a standalone $50 charge. The
                        // parent itself is filtered out of the list at
                        // the SQL layer (NOT EXISTS subquery).
                        if ((tx['parent_id'] ?? '').toString().isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: context.accentSoft(context.tealAccent),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              l.txSplitPill,
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: context.tealAccent,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                        // "Transfer" pill on rows that are one leg of a
                        // detected FX-transfer pair — the linkage was only
                        // visible inside the detail panel, so the receiving
                        // leg read as income in the list.
                        if (isFxTransfer) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1,
                            ),
                            decoration: BoxDecoration(
                              color: context.accentSoft(fxAccent),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              l.txTransferPill,
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w700,
                                color: fxAccent,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _metaLine(tx, notes),
                      style: TextStyle(
                        color: context.textSubtle,
                        fontSize: metaSize,
                        height: 1.3,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Right-aligned amount. Bold native currency on top, converted
              // reporting-currency estimate below whenever the row's native
              // currency differs from the reporting currency — on EVERY width.
              // (Narrow used to hide the estimate for breathing room, but the
              // month headers/nets are in the reporting currency, so in MXN
              // mode a phone showed MXN headers over USD-only rows with no
              // visible way to reconcile them.)
              ConstrainedBox(
                constraints: BoxConstraints(maxWidth: isNarrow ? 128 : 140),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Transfer legs swap the +/− sign for ⇄ and render in
                    // neutral textPrimary: the money moved between the
                    // user's own accounts, so neither the green income
                    // treatment nor the expense one applies.
                    //
                    // FittedBox(scaleDown) so a large native figure (e.g. a
                    // 7-digit MXN sum in the narrow 128px box) shrinks to fit
                    // rather than ellipsizing to a meaningless "−$1,234…".
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerRight,
                      child: Text(
                        isFxTransfer
                            ? '⇄ ${formatCurrencyAmount(sourceAmount.abs(), sourceCurrency)}'
                            : '${isExpense ? '−' : '+'}${formatCurrencyAmount(sourceAmount.abs(), sourceCurrency)}',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: amountSize,
                          fontFeatures: const [FontFeature.tabularFigures()],
                          color: (isFxTransfer || isExpense)
                              ? context.textPrimary
                              : context.positive,
                        ),
                        maxLines: 1,
                      ),
                    ),
                    if (needsConversion)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Text(
                          '≈ ${widget.currencyFormat.format(converted.abs())}',
                          style: TextStyle(
                            fontSize: 10,
                            color: context.textFaint,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    // Running balance (single-account panel only), in the
                    // account's NATIVE currency — same formatter as the
                    // amount above it, never the converted estimate.
                    // Statement-persisted balances render plain; client-
                    // side estimates carry a '≈' and a tooltip that says
                    // where the figure comes from.
                    if (balanceAfter != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Tooltip(
                          message: balanceAfter.estimated
                              ? l.txBalanceAfterEstimatedTooltip
                              : l.txBalanceAfterTooltip,
                          child: Text(
                            l.txBalanceAfter(
                              '${balanceAfter.estimated ? '≈ ' : ''}'
                              '${formatCurrencyAmount(balanceAfter.value, sourceCurrency)}',
                            ),
                            style: TextStyle(
                              fontSize: 10,
                              color: context.textSubtle,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ),
                    if (tx['pending'] == true)
                      Container(
                        margin: const EdgeInsets.only(top: 3),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 5,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: context.warning.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          l.txStatusPending,
                          style: TextStyle(
                            color: context.warning,
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
      ),
    );
  }

  /// Account label with its owning institution prefixed, so a generic
  /// Plaid name like "Checking ••0916" reads as "Capital One · Checking
  /// ••0916" instead of an unidentifiable account. The institution is
  /// dropped when it's empty or already embedded in the account name
  /// (e.g. "Chase Sapphire") to avoid "Chase · Chase Sapphire".
  String _accountLabel(dynamic tx) {
    final account = (tx['account_name'] ?? '').toString();
    final inst = (tx['institution_name'] ?? '').toString();
    if (account.isEmpty) return inst;
    if (inst.isEmpty || account.toLowerCase().contains(inst.toLowerCase())) {
      return account;
    }
    return '$inst · $account';
  }

  /// Compact secondary line. The date is now in the group header above,
  /// so we drop it here and surface category instead — keeping the row
  /// to one line of meta even when there's a user note attached. The
  /// category is run through prettyCategory so Plaid's screaming
  /// "LOAN_PAYMENTS" reads as "Loan payment" / "Credit card payment".
  ///
  /// In a single-account host every row's account is the one the panel
  /// header already names, so the account segment is dropped there (the
  /// row shows the running balance under the amount instead).
  String _metaLine(dynamic tx, String notes) {
    final account = widget.singleAccountContext ? '' : _accountLabel(tx);
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

  /// Detail / edit panel. Thin wrapper that hosts the stateful
  /// [_TransactionDetailPanel] inside a slide-in side panel (wide) or
  /// bottom sheet (narrow). All the field surfacing, editing, grouping
  /// and the controller lifecycle live in that widget; this method only
  /// owns the dialog chrome and the in/out animation so the controllers
  /// get a proper `dispose()` (the previous inline version leaked a
  /// TextEditingController + FocusNode on every open).
  void _showTransactionDetails(dynamic tx) {
    final l = AppLocalizations.of(context);
    // Slide-from-right side panel on wide screens, bottom-sheet on narrow.
    // This is the Linear / Notion / Gmail pattern — keeps the underlying
    // list visible (in spirit) instead of slamming a centered modal that
    // reads as a full page.
    final size = MediaQuery.sizeOf(context);
    final isNarrow = size.width < 700;

    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: l.txDismiss,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      transitionDuration: const Duration(milliseconds: 220),
      pageBuilder: (ctx, anim, secAnim) {
        // Esc dismisses the panel. showGeneralDialog (unlike showDialog)
        // doesn't bind it for free, and Esc-to-close is a desktop reflex;
        // it's a harmless no-op on touch.
        return CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.escape): () =>
                Navigator.of(ctx).pop(),
          },
          child: Focus(
            autofocus: true,
            child: Builder(
              builder: (ctx) {
                // Read size/insets fresh (inside a Builder so it rebuilds on
                // keyboard show/hide): the narrow bottom sheet must lift above
                // the soft keyboard when the notes/category field is focused,
                // instead of hiding the pinned Save button behind it.
                final mq = MediaQuery.of(ctx);
                final insets = mq.viewInsets.bottom;
                final screen = mq.size;
                final sheetMax = screen.height - insets - 24;
                final sheetWanted = screen.height * 0.9;
                return Align(
                  alignment: isNarrow
                      ? Alignment.bottomCenter
                      : Alignment.centerRight,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: isNarrow ? insets : 0),
                    child: Material(
                      color: Colors.transparent,
                      child: Container(
                        width: isNarrow ? screen.width : 480,
                        // Narrow: hug the content (the panel column is
                        // mainAxisSize.min) and cap at ~90% / keyboard-safe
                        // height so long content scrolls instead of growing.
                        height: isNarrow ? null : screen.height,
                        constraints: isNarrow
                            ? BoxConstraints(
                                maxHeight: sheetWanted < sheetMax
                                    ? sheetWanted
                                    : sheetMax,
                              )
                            : null,
                        // The surface color lives on a Material (not the
                        // BoxDecoration) so the category-editor autocomplete's
                        // ListTiles paint their background/ink on a Material
                        // ancestor; newer Flutter asserts when a colored
                        // DecoratedBox sits between a ListTile and its Material.
                        clipBehavior: Clip.antiAlias,
                        decoration: BoxDecoration(
                          borderRadius: isNarrow
                              ? const BorderRadius.vertical(
                                  top: Radius.circular(20),
                                )
                              : const BorderRadius.horizontal(
                                  left: Radius.circular(20),
                                ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.4),
                              blurRadius: 24,
                              offset: const Offset(-4, 0),
                            ),
                          ],
                        ),
                        child: Material(
                          color: Theme.of(ctx).colorScheme.surface,
                          child: _TransactionDetailPanel(
                            state: this,
                            tx: tx,
                            isNarrow: isNarrow,
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
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
    final l = AppLocalizations.of(context);

    final widgets = <Widget>[
      const SizedBox(height: 20),
      _sectionLabel(l.txLinkedTransfer),
      const SizedBox(height: 6),
    ];
    for (final raw in matches) {
      final m = raw as Map<String, dynamic>;
      final isSource = m['source_tx_id']?.toString() == txId;
      final otherLabel =
          (isSource ? m['dest_label'] : m['source_label'])?.toString() ?? '—';
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

      widgets.add(
        Container(
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
                        ? l.txConfirmed
                        : (keyword.isEmpty
                              ? l.txAutoConfidence(confidence)
                              : l.txAutoConfidenceKeyword(confidence, keyword)),
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
                // gen-l10n orders these alphabetically → (dstAmount, dstCurrency, rate, srcAmount, srcCurrency).
                l.txTransferImpliedRate(
                  _formatNative(dstAmt, dstCcy),
                  dstCcy,
                  implied.toStringAsFixed(2),
                  _formatNative(srcAmt, srcCcy),
                  srcCcy,
                ),
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
                      child: Text(l.txConfirm),
                    ),
                  if (widget.onUnlinkFxTransfer != null)
                    TextButton(
                      onPressed: () async {
                        Navigator.of(context).pop();
                        await widget.onUnlinkFxTransfer!(m['id'].toString());
                      },
                      child: Text(
                        l.txUnlink,
                        style: TextStyle(color: context.negative),
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      );
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

  String _sourceLabel(BuildContext context, String source) {
    final l = AppLocalizations.of(context);
    switch (source) {
      case 'plaid':
        return l.txSourcePlaid;
      case 'csv':
        return l.txSourceCsv;
      case 'manual':
        return l.txSourceManual;
      default:
        return source.isEmpty ? l.txSourceUnknown : source;
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
    final otherSourceAmount = ((other['amount'] as num?)?.toDouble() ?? 0.0);
    final otherSourceCurrency = (other['currency'] ?? widget.targetCurrency)
        .toString();
    // Storage sign convention (backend sync.rs:659): negative = outflow.
    final otherIsExpense = otherSourceAmount < 0;

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
}

/// Stateful body of the transaction detail / edit panel.
///
/// Owns the editor controllers + focus node (and disposes them — the
/// previous inline `showGeneralDialog` builder created them in a method
/// and never freed them, leaking on every open) and the "More details"
/// disclosure state. Reaches back into the hosting
/// [TransactionsTabState] for the shared helpers (`_fxTransferBlock`,
/// `_metaChip`, `_renameTransaction`, the split/move flows, the suggestion
/// list, …) and the `widget.*` callbacks, so the editing behaviour is
/// byte-for-byte the same as before — only the layout is regrouped.
class _TransactionDetailPanel extends StatefulWidget {
  final TransactionsTabState state;
  final dynamic tx;
  // Narrow = bottom sheet (mobile); wide = right-docked side panel
  // (desktop/web). Drives the dismiss affordance: drag handle + swipe on
  // narrow, top-right X on wide.
  final bool isNarrow;

  const _TransactionDetailPanel({
    required this.state,
    required this.tx,
    required this.isNarrow,
  });

  @override
  State<_TransactionDetailPanel> createState() =>
      _TransactionDetailPanelState();
}

class _TransactionDetailPanelState extends State<_TransactionDetailPanel> {
  late final TextEditingController _catController;
  late final FocusNode _catFocusNode;
  late final TextEditingController _notesController;

  late final String _initialCategoryLabel;
  late final String _initialNotes;
  late final List<String> _categorySuggestions;

  TransactionsTabState get _state => widget.state;
  dynamic get tx => widget.tx;

  @override
  void initState() {
    super.initState();
    // Prefill the category editor with the PRETTIFIED label — the same
    // string the list row shows — never the raw Plaid enum
    // ("FOOD_AND_DRINK"). The Save handler diffs the field against this
    // exact prefill (see [diffEditedField]), so open-then-Save with no
    // edits sends nothing instead of silently converting the
    // auto-category into a user override of the raw enum string.
    final hasAnyCategory =
        (tx['user_category'] ?? '').toString().trim().isNotEmpty ||
        (tx['category'] ?? '').toString().trim().isNotEmpty ||
        (tx['category_detailed'] ?? '').toString().trim().isNotEmpty;
    _initialCategoryLabel = hasAnyCategory
        ? prettyCategory(
            userCategory: tx['user_category']?.toString(),
            detailed: tx['category_detailed']?.toString(),
            primary: tx['category']?.toString(),
          )
        : '';
    _initialNotes = (tx['user_notes'] ?? '').toString();
    _catController = TextEditingController(text: _initialCategoryLabel);
    _catFocusNode = FocusNode();
    _notesController = TextEditingController(text: _initialNotes);
    // Shared suggestion source — the same list the bulk-categorize and
    // add-transaction dialogs feed from, so the type-ahead can't drift
    // into a second divergent taxonomy.
    _categorySuggestions = _state._distinctCategories();
  }

  @override
  void dispose() {
    _catController.dispose();
    _catFocusNode.dispose();
    _notesController.dispose();
    super.dispose();
  }

  /// Pop the hosting dialog route. Uses the panel's own context so it
  /// targets the showGeneralDialog route regardless of where the state
  /// context sits in the tree.
  void _close() => Navigator.of(context).pop();

  /// Quiet label → value row for the compact "Details" group. Distinct
  /// from the equal-weight `_metaChip` cloud: the label is de-emphasised
  /// and the value carries the weight, so the group scans as a small
  /// table instead of a pill soup.
  Widget _detailRow(
    IconData icon,
    String label,
    String value, {
    Color? valueColor,
    bool maskAware = false,
  }) {
    final valueStyle = TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w600,
      color: valueColor ?? context.textPrimary,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 7),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 15, color: context.textFaint),
          const SizedBox(width: 10),
          Text(
            label,
            style: TextStyle(fontSize: 13, color: context.textSubtle),
          ),
          const SizedBox(width: 12),
          Expanded(
            // maskAware: single-line, keeps a trailing "••1234" account mask
            // visible under truncation; Align preserves the right-edge fit
            // since maskAwareNameText's Row doesn't stretch.
            child: maskAware
                ? Align(
                    alignment: Alignment.centerRight,
                    child: maskAwareNameText(value, valueStyle),
                  )
                : Text(
                    value,
                    textAlign: TextAlign.end,
                    style: valueStyle,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final s = _state;
    final isNarrow = widget.isNarrow;
    // Vertical rhythm: the phone bottom sheet compacts the big gaps so a
    // typical transaction lands around half-screen; the wide side panel
    // keeps its roomier 18px rhythm.
    final sectionGap = isNarrow ? 12.0 : 18.0;

    final date = DateTime.parse(tx['date'] as String);
    final sourceAmount = ((tx['amount'] as num?)?.toDouble() ?? 0.0);
    final sourceCurrency = (tx['currency'] ?? s.widget.targetCurrency)
        .toString();
    final convertedAmount = convertCurrency(
      sourceAmount,
      from: sourceCurrency,
      to: s.widget.targetCurrency,
      usdMxnRate: s.widget.usdMxnRate,
    );
    final needsConversion =
        s.widget.usdMxnRate > 0 && sourceCurrency != s.widget.targetCurrency;
    // Storage sign convention (backend sync.rs:659): negative = outflow,
    // positive = inflow.
    final isExpense = sourceAmount < 0;
    // ONE accent pair for the binary in/out concept: inflow = jade
    // positive, outflow = neutral text. The red `negative` token stays
    // reserved for destructive affordances; teal for transfer/linked.
    final flowAccent = isExpense ? context.textPrimary : context.positive;
    // Provenance comes only from the payload — an absent/null source
    // renders as the explicit "unknown" state, never assumed 'plaid'
    // (that assumption once stamped "Synced via Plaid" on hand-typed
    // rows).
    final source = (tx['source'] ?? '').toString();
    final originalCategory = (tx['category'] ?? '').toString();
    final merchant = (tx['merchant_name'] ?? '').toString();
    final pending = tx['pending'] == true;
    final rawDescription = (tx['description'] ?? '').toString();
    final titleDescription = displayLabel(tx);
    final logoUrl = counterpartyLogo(tx);
    // Hero icon style — same registry the list rows use, keyed on the
    // prettified label (always non-empty).
    final catStyle = context.categoryStyle(
      prettyCategory(
        userCategory: tx['user_category']?.toString(),
        detailed: tx['category_detailed']?.toString(),
        primary: tx['category']?.toString(),
      ),
    );
    final color = catStyle.color;
    final channel = (tx['payment_channel'] ?? '').toString();

    // All transactions sharing this exact description (excluding the
    // current one). Used for lifetime spend + recent rows.
    final merchantMatches = s.widget.transactions.where((other) {
      if (other['id'] == tx['id']) return false;
      return (other['description'] ?? '').toString().trim().toLowerCase() ==
          rawDescription.trim().toLowerCase();
    }).toList();
    final similar = merchantMatches.take(3).toList();
    // Seeded with the CONVERTED amount — see [merchantLifetimeTotal] for the
    // mixed-currency overstatement this replaced.
    final merchantTotal = merchantLifetimeTotal(
      openConvertedAmount: convertedAmount,
      siblings: merchantMatches,
      targetCurrency: s.widget.targetCurrency,
      usdMxnRate: s.widget.usdMxnRate,
    );
    final merchantCount = merchantMatches.length + 1;

    // Original auto-categorization (Plaid), independent of any user
    // override. Only worth a row when the user HAS overridden it with a
    // different label — otherwise the Category field above already shows
    // the identical prettified string and the row is pure duplication.
    final userCat = (tx['user_category'] ?? '').toString().trim();
    final autoCategoryLabel =
        (originalCategory.isNotEmpty ||
            (tx['category_detailed'] ?? '').toString().isNotEmpty)
        ? prettyCategory(
            detailed: tx['category_detailed']?.toString(),
            primary: tx['category']?.toString(),
          )
        : null;
    final hasChannel = channel.isNotEmpty && channel != 'other';

    // Whether the overflow ("More actions") kebab has anything to show.
    final canMove = s.widget.accounts.isNotEmpty && s.widget.onUpdate != null;
    final isChild = (tx['parent_id'] ?? '').toString().isNotEmpty;
    final canSplit = !isChild && s.widget.onSplitTransaction != null;
    final canEditSplit =
        isChild &&
        s.widget.onSplitTransaction != null &&
        s.widget.onUnsplitTransaction != null;
    final canUnsplit = isChild && s.widget.onUnsplitTransaction != null;
    final canDelete = s.widget.onDelete != null;
    // Only an outflow can fund a loan (money left the account).
    final canCreateLoan =
        s.widget.onCreateLoanFromTx != null && sourceAmount < 0;
    final canMakeRecurring = s.widget.onMakeRecurring != null;
    // Full edit (amount/date/direction/account/…) — ONLY for hand-typed
    // rows: the user is the source of truth there, whereas synced /
    // imported facts belong to the bank (the server enforces the same
    // rule with a 403). Split children are excluded — their amounts are
    // bound to the parent; that path is the split editor.
    final canEditManual =
        source == 'manual' &&
        !isChild &&
        s.widget.apiService != null &&
        s.widget.accounts.isNotEmpty;
    final hasOverflow =
        canEditManual ||
        canMove ||
        canSplit ||
        canEditSplit ||
        canUnsplit ||
        canCreateLoan ||
        canMakeRecurring ||
        canDelete;

    Widget detailRows() {
      // Date is folded into the hero block, so it is intentionally
      // omitted here to avoid showing it twice.
      final rows = <Widget>[
        if ((tx['account_name'] ?? '').toString().isNotEmpty)
          _detailRow(
            Icons.account_balance,
            l.txAccount,
            s._accountLabel(tx),
            maskAware: true,
          ),
        if (autoCategoryLabel != null &&
            userCat.isNotEmpty &&
            autoCategoryLabel != userCat)
          _detailRow(Icons.label_outline, l.txAutoCategory, autoCategoryLabel),
        if (pending)
          _detailRow(
            Icons.hourglass_empty,
            l.txStatus,
            l.txStatusPending,
            valueColor: context.warning,
          ),
      ];
      if (rows.isEmpty) return const SizedBox.shrink();
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        decoration: BoxDecoration(
          color: context.tileSurface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.hairline),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0) Divider(height: 1, color: context.hairline),
              rows[i],
            ],
          ],
        ),
      );
    }

    // Overflow kebab + rename/edit action, shared by both layouts: the
    // wide side panel keeps them in the dedicated header row; the narrow
    // bottom sheet folds them into the hero row (the header row there
    // held only X/kebab/edit, and X duplicates handle/swipe/barrier).
    Widget overflowButton() {
      return PopupMenuButton<String>(
        tooltip: l.txMoreActions,
        icon: const Icon(Icons.more_horiz, size: 22),
        onSelected: (value) {
          switch (value) {
            case 'editManual':
              // Close the detail panel first — the edit rewrites the very
              // fields the panel is showing, so a stale panel behind the
              // dialog would misrepresent the row after save.
              _close();
              s._openEditManualDialog(tx);
              break;
            case 'split':
              s._openSplitDialog(
                tx,
                sourceCurrency,
                sourceAmount,
                titleDescription,
                originalCategory,
              );
              break;
            case 'editSplit':
              s._openEditSplitDialog(
                (tx['parent_id'] ?? '').toString(),
                sourceCurrency,
                sourceAmount,
                titleDescription,
                originalCategory,
              );
              break;
            case 'unsplit':
              _unsplit(l);
              break;
            case 'move':
              _showMoveSheet(l);
              break;
            case 'createLoan':
              _close();
              s.widget.onCreateLoanFromTx?.call(tx);
              break;
            case 'makeRecurring':
              _close();
              s.widget.onMakeRecurring?.call(tx);
              break;
            case 'delete':
              _confirmDelete(l);
              break;
          }
        },
        itemBuilder: (ctx) => [
          if (canEditManual)
            PopupMenuItem(
              value: 'editManual',
              child: _menuRow(Icons.edit_note, l.txEditTransaction),
            ),
          if (canSplit)
            PopupMenuItem(
              value: 'split',
              child: _menuRow(Icons.call_split, l.txSplitThisTransaction),
            ),
          if (canEditSplit)
            PopupMenuItem(
              value: 'editSplit',
              child: _menuRow(Icons.edit_outlined, l.txEditSplit),
            ),
          if (canUnsplit)
            PopupMenuItem(
              value: 'unsplit',
              child: _menuRow(Icons.call_merge, l.txUnsplitRestore),
            ),
          if (canMove)
            PopupMenuItem(
              value: 'move',
              child: _menuRow(
                Icons.drive_file_move_outlined,
                l.txMoveToDifferentAccount,
              ),
            ),
          if (canCreateLoan)
            PopupMenuItem(
              value: 'createLoan',
              child: _menuRow(
                Icons.monetization_on_outlined,
                l.txCreateLoanFromTx,
              ),
            ),
          if (canMakeRecurring)
            PopupMenuItem(
              value: 'makeRecurring',
              child: _menuRow(Icons.autorenew_rounded, l.recMakeRecurring),
            ),
          if (canDelete)
            PopupMenuItem(
              value: 'delete',
              child: _menuRow(
                Icons.delete_outline,
                l.actionDelete,
                color: context.negative,
              ),
            ),
        ],
      );
    }

    Widget editButton() {
      return IconButton(
        tooltip: merchantMatches.isEmpty
            ? l.txRename
            : l.txRenamePlusMatching(merchantMatches.length),
        iconSize: 20,
        icon: const Icon(Icons.edit_outlined),
        onPressed: () => s._renameTransaction(
          tx,
          similarIds: merchantMatches.map((m) => m['id'].toString()).toList(),
        ),
        constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
      );
    }

    return Padding(
      // Narrow sheet uses a tighter frame (SafeArea below already covers
      // the home indicator); wide side panel keeps the roomy 24s.
      padding: isNarrow
          ? const EdgeInsets.fromLTRB(20, 8, 20, 12)
          : const EdgeInsets.fromLTRB(24, 16, 24, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // -- Header chrome ---------------------------------------------
          // Wide (side panel): Close (X) sits on the LEADING (left) edge of
          // the header — on its own, away from the overflow/rename actions
          // on the right, so it unmistakably reads as "close" and sits
          // right next to the scrim a user instinctively clicks; Esc works
          // too. Narrow (bottom sheet): no header row — dismissal is the
          // drag handle / swipe-down / barrier, and the kebab + edit
          // actions ride the hero row instead, saving ~48px of chrome.
          if (isNarrow)
            Center(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onVerticalDragEnd: (d) {
                  if ((d.primaryVelocity ?? 0) > 250) _close();
                },
                child: Container(
                  width: 36,
                  height: 4,
                  margin: const EdgeInsets.only(top: 4, bottom: 12),
                  decoration: BoxDecoration(
                    color: context.hairline,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          if (!isNarrow)
            Row(
              children: [
                // Primary dismiss — isolated on the leading edge.
                IconButton(
                  icon: const Icon(Icons.close, size: 22),
                  onPressed: _close,
                  tooltip: l.actionClose,
                  constraints: const BoxConstraints(
                    minWidth: 48,
                    minHeight: 48,
                  ),
                ),
                const Spacer(),
                if (hasOverflow) overflowButton(),
                if (s.widget.onUpdate != null) editButton(),
              ],
            ),
          // -- Scrollable body -------------------------------------------
          Flexible(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // -- Hero: logo + title + subtitle -------------------
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
                        child: logoUrl != null
                            ? Image.network(
                                logoUrl,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) =>
                                    Icon(catStyle.icon, color: color, size: 28),
                              )
                            : Icon(catStyle.icon, color: color, size: 28),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              titleDescription,
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                            ),
                            // Merchant subtitle (only when it adds info
                            // over the title) — the single place the
                            // merchant name appears now (the duplicate
                            // storefront chip was removed).
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
                      // Narrow: the kebab + edit actions ride the hero row
                      // (there is no dedicated header row on the sheet).
                      if (isNarrow) ...[
                        if (hasOverflow) overflowButton(),
                        if (s.widget.onUpdate != null) editButton(),
                      ],
                    ],
                  ),
                  SizedBox(height: sectionGap),
                  // -- Hero amount block -------------------------------
                  Container(
                    width: double.infinity,
                    padding: EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: isNarrow ? 10 : 16,
                    ),
                    decoration: BoxDecoration(
                      color: context.tint(0.04),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: flowAccent.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              isExpense ? l.txOutflow : l.txInflow,
                              style: TextStyle(
                                fontSize: 10,
                                letterSpacing: 1.2,
                                color: flowAccent,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const Spacer(),
                            // Date folded into the hero — keeps the
                            // most-glanced fact next to the amount.
                            Text(
                              DateFormat('MMM d, y').format(date),
                              style: TextStyle(
                                fontSize: 11,
                                color: context.textSubtle,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ],
                        ),
                        SizedBox(height: isNarrow ? 2 : 6),
                        Text(
                          '${isExpense ? '−' : '+'}${formatCurrencyAmount(sourceAmount.abs(), sourceCurrency)}',
                          style: brandDisplayStyle(
                            fontSize: isNarrow ? 24 : 32,
                            color: flowAccent,
                          ),
                        ),
                        if (needsConversion) ...[
                          const SizedBox(height: 4),
                          Text(
                            l.txApproxEstimated(
                              s.widget.currencyFormat.format(
                                convertedAmount.abs(),
                              ),
                            ),
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
                  SizedBox(height: sectionGap),
                  // -- Primary editable: Category then Notes -----------
                  RawAutocomplete<String>(
                    textEditingController: _catController,
                    focusNode: _catFocusNode,
                    optionsBuilder: (TextEditingValue value) {
                      final q = value.text.trim().toLowerCase();
                      if (q.isEmpty) return _categorySuggestions;
                      return _categorySuggestions.where(
                        (c) => c.toLowerCase().contains(q),
                      );
                    },
                    fieldViewBuilder:
                        (ctx, controller, focusNode, onFieldSubmitted) {
                          return TextField(
                            controller: controller,
                            focusNode: focusNode,
                            decoration: InputDecoration(
                              labelText: l.txCategory,
                              hintText: l.txCategoryHint,
                              border: const OutlineInputBorder(),
                              isDense: true,
                            ),
                            onSubmitted: (_) => onFieldSubmitted(),
                          );
                        },
                    optionsViewBuilder: (ctx, onSelected, options) {
                      final opts = options.toList();
                      return Align(
                        alignment: Alignment.topLeft,
                        child: Material(
                          elevation: 4,
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxHeight: 200,
                              maxWidth: 420,
                            ),
                            child: ListView.builder(
                              padding: EdgeInsets.zero,
                              shrinkWrap: true,
                              itemCount: opts.length,
                              itemBuilder: (ctx, index) {
                                final option = opts[index];
                                return InkWell(
                                  onTap: () => onSelected(option),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 12,
                                    ),
                                    child: Text(option),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _notesController,
                    decoration: InputDecoration(
                      labelText: l.txNotes,
                      hintText: l.txNotesHint,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                    minLines: 1,
                    maxLines: 4,
                  ),
                  SizedBox(height: isNarrow ? 12 : 16),
                  // -- Compact Details group ---------------------------
                  detailRows(),
                  // -- Linked FX transfer (inline, high-signal) --------
                  ...s._fxTransferBlock(tx['id']?.toString() ?? ''),
                  // -- More details disclosure -------------------------
                  const SizedBox(height: 12),
                  Theme(
                    data: Theme.of(
                      context,
                    ).copyWith(dividerColor: Colors.transparent),
                    child: ExpansionTile(
                      tilePadding: EdgeInsets.zero,
                      childrenPadding: const EdgeInsets.only(bottom: 8),
                      expandedCrossAxisAlignment: CrossAxisAlignment.start,
                      title: Text(
                        l.txMoreDetails,
                        style: TextStyle(
                          fontSize: 11,
                          color: context.textSubtle,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.0,
                        ),
                      ),
                      children: [
                        if (rawDescription != titleDescription) ...[
                          // Manual rows hold the user's own words, not
                          // bank data — neutral copy, not "raw bank text".
                          s._sectionLabel(
                            source == 'manual'
                                ? l.txOriginalText
                                : l.txRawBankText,
                          ),
                          const SizedBox(height: 4),
                          SelectableText(
                            rawDescription,
                            style: TextStyle(
                              fontSize: 12,
                              color: context.textMuted,
                              fontFamily: 'monospace',
                            ),
                          ),
                          const SizedBox(height: 12),
                        ],
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            // Icon mirrors provenance: hand-typed rows
                            // get a pencil, imports a file, synced rows
                            // the cloud — a cloud on a manual row would
                            // re-assert the "synced" claim the label
                            // just corrected.
                            s._metaChip(switch (source) {
                              'manual' => Icons.edit_outlined,
                              'csv' => Icons.upload_file_outlined,
                              'plaid' => Icons.cloud_download,
                              _ => Icons.help_outline,
                            }, s._sourceLabel(context, source)),
                            if (hasChannel)
                              s._metaChip(
                                s._channelIcon(channel),
                                s._sentence(channel.replaceAll('_', ' ')),
                              ),
                          ],
                        ),
                        if (similar.isNotEmpty) ...[
                          const SizedBox(height: 14),
                          s._sectionLabel(l.txRecentAtMerchant),
                          const SizedBox(height: 6),
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: Text(
                              l.txMerchantTotal(
                                s.widget.currencyFormat.format(merchantTotal),
                                merchantCount,
                              ),
                              style: TextStyle(
                                fontSize: 12,
                                color: context.textMuted,
                                fontFeatures: const [
                                  FontFeature.tabularFigures(),
                                ],
                              ),
                            ),
                          ),
                          ...similar.map((other) => s._similarRow(other)),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
          // -- Footer: one unambiguous primary commit -------------------
          // Dismissal is owned by the chrome — X / Esc / barrier (desktop),
          // drag handle / swipe-down / barrier (mobile) — so the old
          // secondary "Close" next to Save (which read as cancel-vs-save but
          // never actually reverted) is gone. SafeArea keeps Save clear of
          // the home indicator on mobile.
          //
          // Save only appears once a field is actually dirty (diffed with
          // the same helper the handler uses), so a read-only open shows
          // no footer at all. Dismissal still discards — deliberately NOT
          // commit-on-dismiss.
          ListenableBuilder(
            listenable: Listenable.merge([_catController, _notesController]),
            builder: (context, _) {
              final dirty =
                  diffEditedField(_catController.text, _initialCategoryLabel) !=
                      null ||
                  diffEditedField(_notesController.text, _initialNotes) != null;
              if (!dirty) {
                // Keep the home-indicator inset even without the button.
                return SafeArea(
                  top: false,
                  bottom: isNarrow,
                  child: const SizedBox.shrink(),
                );
              }
              return Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 12),
                  SafeArea(
                    top: false,
                    bottom: isNarrow,
                    child: SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: () {
                          // Diff each field against its prefill: only what
                          // the user actually edited is sent (null = "leave
                          // alone").
                          final newCategory = diffEditedField(
                            _catController.text,
                            _initialCategoryLabel,
                          );
                          final newNotes = diffEditedField(
                            _notesController.text,
                            _initialNotes,
                          );
                          _close();
                          if (newCategory == null && newNotes == null) {
                            return;
                          }
                          s.widget.onUpdate?.call(
                            tx['id'],
                            userCategory: newCategory,
                            userNotes: newNotes,
                          );
                        },
                        child: Text(l.actionSave),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _menuRow(IconData icon, String label, {Color? color}) {
    final c = color ?? context.textPrimary;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: c),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: c)),
      ],
    );
  }

  /// Unsplit via the overflow menu — mirrors the old inline button.
  Future<void> _unsplit(AppLocalizations l) async {
    final onUnsplit = _state.widget.onUnsplitTransaction;
    if (onUnsplit == null) return;
    _close();
    try {
      await onUnsplit((tx['parent_id'] ?? '').toString());
      if (!_state.mounted) return;
      ScaffoldMessenger.of(
        _state.context,
      ).showSnackBar(SnackBar(content: Text(l.txSplitRemoved)));
    } catch (e) {
      if (!_state.mounted) return;
      ScaffoldMessenger.of(
        _state.context,
      ).showSnackBar(SnackBar(content: Text(l.txUnsplitFailed(e.toString()))));
    }
  }

  /// Delete via the overflow menu — confirm dialog then `onDelete`.
  Future<void> _confirmDelete(AppLocalizations l) async {
    if (_state.widget.onDelete == null) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l.txDeleteOneTitle),
        content: Text(l.txDeleteOneBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(l.actionCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: ctx.negative),
            child: Text(l.actionDelete),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    if (!mounted) return;
    _close();
    // Hand the actual delete to the tab's deferred-delete buffer so the
    // row hides immediately and an Undo SnackBar offers a 6s reversal,
    // matching the bulk path. (The detail panel itself is gone by now —
    // the SnackBar + Undo live on the tab's ScaffoldMessenger.)
    if (!_state.mounted) return;
    _state._deferredDeleteSingle(tx['id'], l);
  }

  /// Move-to-account via the overflow menu. Opens a small bottom sheet
  /// hosting the existing `_AccountMover` picker (kept verbatim).
  void _showMoveSheet(AppLocalizations l) {
    final s = _state;
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Theme.of(context).colorScheme.surface,
      builder: (sheetCtx) {
        return Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            20,
            20,
            20 + MediaQuery.viewInsetsOf(sheetCtx).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              s._sectionLabel(l.txMoveToDifferentAccount),
              const SizedBox(height: 12),
              _AccountMover(
                accounts: s.widget.accounts,
                currentAccountId: tx['account_id']?.toString(),
                onMove: (newAccountId) async {
                  Navigator.pop(sheetCtx);
                  _close();
                  try {
                    await Future.value(
                      s.widget.onUpdate?.call(
                        tx['id'],
                        accountId: newAccountId,
                      ),
                    );
                  } catch (e) {
                    if (!s.mounted) return;
                    ScaffoldMessenger.of(s.context).showSnackBar(
                      SnackBar(content: Text(l.txMoveFailed(e.toString()))),
                    );
                  }
                },
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Sealed-style discriminated union for the flat virtualised list.
/// Three shapes; the fields that aren't relevant for a given kind
/// are null. Plain class instead of a Dart 3 sealed/sum because
/// we want it to compile against older analyzer pin-pointing.
class _TxListItem {
  /// 0 = day header, 1 = row, 2 = divider, 3 = month landmark header.
  /// Indexed for cheap == checks.
  final int kind;
  final DateTime? date;
  final bool isFirst;
  final dynamic tx;
  const _TxListItem._(this.kind, {this.date, this.isFirst = false, this.tx});
  const _TxListItem.header({required DateTime date, required bool isFirst})
    : this._(0, date: date, isFirst: isFirst);
  const _TxListItem.row({required dynamic tx}) : this._(1, tx: tx);
  const _TxListItem.divider() : this._(2);
  const _TxListItem.monthHeader({required DateTime date, required bool isFirst})
    : this._(3, date: date, isFirst: isFirst);
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
    final l = AppLocalizations.of(context);
    final candidates = widget.accounts
        .where((a) => a['id']?.toString() != widget.currentAccountId)
        .toList();
    return Row(
      children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _selectedId,
            isExpanded: true,
            decoration: InputDecoration(
              labelText: l.txReassignTo,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
            items: candidates.map<DropdownMenuItem<String>>((a) {
              final id = a['id'].toString();
              final name = (a['name'] ?? 'Account').toString();
              final inst = (a['institution_name'] ?? '').toString();
              return DropdownMenuItem<String>(
                value: id,
                child: maskAwareNameText(
                  inst.isEmpty ? name : '$inst · $name',
                  const TextStyle(),
                ),
              );
            }).toList(),
            onChanged: (v) => setState(() => _selectedId = v),
          ),
        ),
        const SizedBox(width: 8),
        ElevatedButton(
          onPressed: _selectedId == null
              ? null
              : () => widget.onMove(_selectedId!),
          child: Text(l.txMove),
        ),
      ],
    );
  }
}
