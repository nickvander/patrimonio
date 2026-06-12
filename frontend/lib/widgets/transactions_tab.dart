import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../utils/theme_colors.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../services/transaction_mutation_refresh.dart'
    show kTxBackendMaxPageSize;
import '../l10n/app_localizations.dart';
import '../theme/typography.dart';
import '../utils/category.dart';
import '../utils/category_style.dart';
import '../utils/currency.dart';
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
/// Plaid sign convention or how the row formats the currency.
///
/// Top-level (not a method) so the field list is unit-testable without
/// pumping the tab; [_TransactionsTabState._haystackFor] wraps it with
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
  /// Bulk variant: updates many transactions in ONE request (the batch
  /// endpoint) and refreshes the dashboard ONCE. The old path looped the
  /// per-id [onUpdate], each of which triggered a full dashboard reload —
  /// selecting N rows fired N writes × a full refetch each. Falls back to
  /// the per-id loop when null. Returns the number actually updated.
  final Future<int> Function(List<String> ids,
      {String? userCategory,
      String? accountId,
      String? userDescription})? onBulkUpdate;
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
  final Future<void> Function(String parentId, List<Map<String, dynamic>> splits)?
      onSplitTransaction;
  /// Un-split: delete every child of the given parent. Used from the
  /// detail modal of a split-child (which knows its `parent_id`).
  final Future<void> Function(String parentId)? onUnsplitTransaction;
  /// Atomically replace the children of a split parent (used by the
  /// Edit split flow). Same payload shape as `onSplitTransaction`.
  final Future<void> Function(
    String parentId,
    List<Map<String, dynamic>> splits,
  )? onReplaceSplits;

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
    this.fxTransfers = const [],
    this.onDetectFxTransfers,
    this.onConfirmFxTransfer,
    this.onUnlinkFxTransfer,
    this.onSplitTransaction,
    this.onUnsplitTransaction,
    this.onReplaceSplits,
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
  // True while we're cascade-loading the remaining pages so a client-side
  // filter can see the user's whole history (see _loadAllForFilter).
  bool _autoLoading = false;
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
  final Map<String, String> _haystackCache = {};
  int _haystackCacheIdentity = 0;

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
    _searchDebounce?.cancel();
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
      _inlineEditController.text =
          (tx['user_description'] ?? '').toString();
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.txRenameFailed(e.toString()))),
      );
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
        _filters == _filteredCacheFilters) {
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
    List<dynamic> result;
    if (!hasSearch && !hasFilters) {
      result = txs;
    } else {
      result = <dynamic>[];
      for (final tx in txs) {
        if (hasSearch) {
          final hay = _haystackFor(tx);
          if (!hay.contains(q)) continue;
        }
        if (hasFilters && !_filters.matches(tx)) continue;
        result.add(tx);
      }
    }
    _filteredCache = result;
    _filteredCacheIdentity = identity;
    _filteredCacheQuery = q;
    _filteredCacheFilters = _filters;
    // (cascade-load trigger lives in build(), keyed off the same filter state)
    return result;
  }

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
    final run = _runHistoryCascade(onLoadMore, ignoreFilters)
        .whenComplete(() => _historyCascade = null);
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

  Future<void> _openFilters() async {
    // Make the option lists (categories especially) reflect the user's
    // WHOLE history, not just the pages loaded so far — a category that
    // only occurs in unloaded history was previously impossible to select.
    // This kicks the same memoized cascade the filters themselves use, so
    // reopening the dialog when history is already fully loaded (hasMore
    // false) costs nothing and shows no loading affordance.
    final Future<void>? historyLoad =
        widget.hasMore ? _loadAllForFilter(ignoreFilters: true) : null;
    final result = await showDialog<TxFilters>(
      context: context,
      builder: (_) => TxFiltersDialog(
        initial: _filters,
        transactions: widget.transactions,
        accounts: widget.accounts,
        historyLoad: historyLoad,
        // Live getter: when the cascade completes the dialog re-reads the
        // (by then fully loaded) list so its options refresh in place.
        liveTransactions: () => widget.transactions,
      ),
    );
    if (result != null && mounted) setState(() => _filters = result);
  }

  /// Removable chip strip below the toolbar showing every active filter
  /// in a single horizontal scroll. Tapping the X on a chip clears just
  /// that one; the strip hides entirely when nothing's active.
  Widget _activeFilterChips() {
    if (!_filters.isActive) return const SizedBox.shrink();
    final l = AppLocalizations.of(context);
    final chips = <Widget>[];
    if (_filters.flow != TxFlow.all) {
      chips.add(_filterChip(
        _filters.flow == TxFlow.expense ? l.txFlowExpense : l.txFlowIncome,
        () => setState(() => _filters = _filters.copyWith(flow: TxFlow.all)),
      ));
    }
    if (_filters.status != TxStatus.all) {
      chips.add(_filterChip(
        _filters.status == TxStatus.pending ? l.txStatusPending : l.txStatusSettled,
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
        label = _filters.dateRange.labelFor(context);
      }
      chips.add(_filterChip(
        label,
        () => setState(() => _filters = _filters.copyWith(
              dateRange: TxDateRange.all,
              clearCustomDates: true,
            )),
      ));
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
      chips.add(_filterChip(
        label,
        () => setState(() => _filters = _filters.copyWith(clearAmounts: true)),
      ));
    }
    chips.add(TextButton(
      onPressed: () => setState(() => _filters = TxFilters.empty),
      style: TextButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 8),
        minimumSize: const Size(0, 28),
      ),
      child: Text(l.txClearAll),
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

  /// One-stroke escape hatch from a zero-match dead end: drops the
  /// search text (flushing any pending debounce so a stale keystroke
  /// can't resurrect it) and every filter, amount range included.
  void _clearFiltersAndSearch() {
    _searchDebounce?.cancel();
    setState(() {
      _searchQuery = '';
      _searchController.clear();
      _searchOpenOnNarrow = false;
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
            Icon(Icons.receipt_long_outlined,
                size: 64, color: context.textFaint),
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
                foregroundColor: Colors.black,
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
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: LayoutBuilder(builder: (context, constraints) {
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
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildToolbar(isNarrow),
              _activeFilterChips(),
              const SizedBox(height: 8),
              Text(
                l.txShowingCount(filtered.length, widget.transactions.length),
                style: TextStyle(color: context.textSubtle, fontSize: 12),
              ),
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
                            label: Text(l.txLoadMore),
                          ),
                  ),
                ),
            ],
          );
        }),
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
          label: Text(allSelected ? l.txDeselectAll : l.txSelectAll),
        );

        final categorize = FilledButton.tonalIcon(
          onPressed:
              selectedCount == 0 ? null : () => _bulkCategorize(),
          icon: const Icon(Icons.label_outline, size: 18),
          label: Text(l.txSetCategory),
        );

        final moveAccount = FilledButton.tonalIcon(
          onPressed:
              selectedCount == 0 ? null : () => _bulkMoveAccount(),
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
          label: Text(l.actionDelete, style: TextStyle(color: context.negative)),
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
                rename,
                delete,
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
            rename,
            const SizedBox(width: 8),
            delete,
            const SizedBox(width: 8),
            clear,
          ],
        );
      }),
    );
  }

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
            return suggestions
                .where((s) => s.toLowerCase().contains(q));
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
              child: Text(l.actionCancel)),
          FilledButton(
              onPressed: () => Navigator.pop(dialogCtx, typed.trim()),
              child: Text(l.actionApply)),
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
              child: Text(l.actionCancel)),
          FilledButton(
              onPressed: () =>
                  Navigator.pop(dialogCtx, controller.text.trim()),
              child: Text(l.actionApply)),
        ],
      ),
    );
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
              child: Text(l.actionCancel)),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.negative),
            onPressed: () => Navigator.pop(dialogCtx, true),
            child: Text(l.actionDelete),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text(l.txDeletingN(ids.length))),
    );
    var ok = true;
    try {
      await onBulkDelete(ids);
    } catch (_) {
      ok = false;
    }
    if (!mounted) return;
    setState(() {
      _selectedIds.clear();
      _selectionMode = false;
    });
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(ok
            ? l.txDeletedN(ids.length)
            : l.txDeleteSomeFailed),
      ),
    );
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

  /// Distinct prettified category labels present in the currently
  /// loaded transactions list. Same source the filter dialog uses so
  /// the split-row dropdown stays in sync with what the user actually
  /// has, instead of offering a fixed taxonomy that drifts over time.
  List<String> _distinctCategories() {
    final set = <String>{};
    for (final t in widget.transactions) {
      if (t is! Map) continue;
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.txSplitIntoN(result.length))),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.txSplitFailed(e.toString()))),
      );
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
        .where((row) =>
            row is Map &&
            (row['parent_id'] ?? '').toString() == parentId)
        .toList();
    if (siblings.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.txSplitChildrenNotFound)),
      );
      return;
    }
    final parentAmount = siblings.fold<double>(0.0, (sum, row) {
      final raw = (row as Map)['amount'];
      return sum + ((raw as num?)?.toDouble() ?? 0.0);
    });
    final initialDrafts = siblings.map<Map<String, dynamic>>((row) {
      final m = row as Map;
      return {
        'description': (m['user_description']?.toString().trim().isNotEmpty ??
                false)
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
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.txSplitUpdatedN(result.length))),
      );
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
        return StatefulBuilder(builder: (ctx, setLocal) {
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
                    onChanged: (v) =>
                        setLocal(() => applyToAll = v ?? false),
                    title: Text(
                      l.txAlsoApplyToN(similarIds.length),
                      style: const TextStyle(fontSize: 13),
                    ),
                    subtitle: Text(
                      l.txAlsoApplySubtitle,
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
                child: Text(l.actionCancel),
              ),
              // Clear button only when something is set on the row already
              // — avoids a dead button on transactions that never had an
              // override applied.
              if ((tx['user_description'] ?? '').toString().isNotEmpty)
                TextButton(
                  onPressed: () => Navigator.of(ctx)
                      .pop((text: '', applyToAll: applyToAll)),
                  child: Text(l.txClearOverride),
                ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop((
                  text: controller.text.trim(),
                  applyToAll: applyToAll,
                )),
                child: Text(l.actionSave),
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
                  ? l.txRenamed
                  : l.txRenameFailedShort)
              : (failed == 0
                  ? l.txRenamedN(ids.length)
                  : l.txRenamedNFailed(ids.length - failed, failed)),
        ),
      ),
    );
  }

  // Prefers the batch endpoint (one request + one refresh for the whole
  // selection); falls back to looping the per-id onUpdate only if no bulk
  // handler is wired.
  Future<void> _applyBulkUpdate(
      {String? userCategory, String? accountId, String? userDescription}) async {
    final ids = _selectedIds.toList();
    if (ids.isEmpty) return;
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(content: Text(l.txUpdatingN(ids.length))),
    );

    int updated = 0;
    int failed = 0;
    final onBulk = widget.onBulkUpdate;
    if (onBulk != null) {
      // One batched request → one dashboard refresh.
      try {
        updated = await onBulk(ids,
            userCategory: userCategory,
            accountId: accountId,
            userDescription: userDescription);
        failed = ids.length - updated;
      } catch (_) {
        failed = ids.length;
      }
    } else {
      final onUpdate = widget.onUpdate;
      if (onUpdate == null) return;
      for (final id in ids) {
        try {
          await onUpdate(id,
              userCategory: userCategory,
              accountId: accountId,
              userDescription: userDescription);
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
              : l.txUpdatedNFailed(updated, failed),
        ),
      ),
    );
  }

  /// Header toolbar. On wide screens shows title + inline search. On narrow
  /// screens the search collapses to an icon button that expands into a
  /// full-width input, so the title doesn't fight a 280px search box for
  /// horizontal space.
  Widget _buildToolbar(bool isNarrow) {
    final l = AppLocalizations.of(context);
    if (isNarrow && _searchOpenOnNarrow) {
      return Row(
        children: [
          Expanded(child: _searchField()),
          const SizedBox(width: 8),
          IconButton(
            onPressed: () {
              // Synchronous flush — cancel a pending debounce so the
              // close button doesn't get a stray re-filter fired
              // after the panel has already collapsed.
              _searchDebounce?.cancel();
              setState(() {
                _searchOpenOnNarrow = false;
                _searchQuery = '';
                _searchController.clear();
              });
            },
            icon: const Icon(Icons.close, size: 20),
            tooltip: l.txCloseSearch,
          ),
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Flexible(
          child: Text(
            l.txRecentTransactions,
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
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
                  tooltip: l.txFilterTransactions,
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
                  _selectionMode ? l.txExitSelectionMode : l.txSelectMultiple,
            ),
            if (widget.apiService != null) ...[
              IconButton(
                onPressed: () => _openAddDialog(),
                icon: const Icon(Icons.add, size: 22),
                tooltip: l.txAddTransaction,
              ),
              IconButton(
                onPressed: () => _downloadCsv(),
                icon: const Icon(Icons.file_download_outlined, size: 22),
                // The backend export has no filter parameters, so when a
                // filter/search is active — or the host's list is
                // implicitly scoped (csvExportConfirmAlways) — the
                // affordance says up front that the CSV covers everything
                // (and _downloadCsv asks for confirmation too).
                tooltip: (widget.csvExportConfirmAlways ||
                        _searchQuery.isNotEmpty ||
                        _filters.isActive)
                    ? l.txExportCsvAllNote
                    : l.txExportCsv,
              ),
            ],
            if (widget.onDetectFxTransfers != null)
              IconButton(
                tooltip: l.txScanTransfers,
                icon: const Icon(Icons.swap_horiz, size: 22),
                onPressed: () => widget.onDetectFxTransfers!(),
              ),
            if (isNarrow)
              IconButton(
                onPressed: () =>
                    setState(() => _searchOpenOnNarrow = true),
                icon: const Icon(Icons.search, size: 20),
                tooltip: l.txSearchTransactions,
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
        categorySuggestions: _distinctCategories(),
        initialAccountId: widget.addTransactionAccountId,
      ),
    );
  }

  Future<void> _downloadCsv() async {
    if (widget.apiService == null) return;
    // Export honesty: the backend endpoint exports EVERYTHING — it has
    // no filter/search parameters. When the user is looking at a
    // filtered list (explicit filters, or a host whose list is scoped to
    // one account), confirm that's understood before handing off.
    if (widget.csvExportConfirmAlways ||
        _searchQuery.isNotEmpty ||
        _filters.isActive) {
      final l = AppLocalizations.of(context);
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogCtx) => AlertDialog(
          title: Text(l.txExportAllTitle),
          content: Text(l.txExportAllBody),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogCtx, false),
              child: Text(l.actionCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogCtx, true),
              child: Text(l.txExportAllConfirm),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
    }
    // Hand off to the browser — the backend responds with
    // Content-Disposition: attachment so the browser downloads directly.
    // Routed through the url_opener seam (no-op on the test VM) so this
    // file stays free of a direct package:web import.
    openUrlSameTab(widget.apiService!.exportTransactionsCsvUrl());
  }

  Widget _searchField() {
    return TextField(
      autofocus: _searchOpenOnNarrow,
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
        hintText: AppLocalizations.of(context).searchTransactionsHint,
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
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: _buildGroupedRows(txs, isNarrow),
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
    return Scrollbar(
      thumbVisibility: true,
      child: ListView.builder(
        // No itemExtent — rows can be one or two lines depending
        // on the override / notes presence. Flutter still
        // virtualises by viewport visibility; we just lose the
        // O(1) scroll-to-index optimisation, which we don't need.
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

  List<_TxListItem> _ensureItemPlan(List<dynamic> txs, bool isNarrow) {
    final identity = identityHashCode(txs);
    if (_itemPlanCache != null &&
        _itemPlanCacheFilteredId == identity &&
        _itemPlanCacheNarrow == isNarrow) {
      return _itemPlanCache!;
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
            _TxListItem.header(date: date, isFirst: out.isEmpty || afterMonth));
        lastGroup = key;
      } else {
        out.add(const _TxListItem.divider());
      }
      out.add(_TxListItem.row(tx: tx));
    }
    _itemPlanCache = out;
    _itemPlanCacheFilteredId = identity;
    _itemPlanCacheNarrow = isNarrow;
    return out;
  }

  /// Stable per-calendar-month grouping key ("2026-6").
  String _monthKey(DateTime date) => '${date.year}-${date.month}';

  // Month → net flow (income positive, in the reporting currency) over
  // the rows currently in the list — i.e. loaded AND matching any active
  // filter, exactly what the user sees under the landmark. FX-transfer
  // legs are skipped: money moving between the user's own pockets is
  // neither income nor spending (same rule as the rows' neutral ⇄
  // treatment). Memoized on (list identity, fx identity, usdMxnRate),
  // mirroring _ensureDescIndex / _ensureFxLinkIndex.
  Map<String, double>? _monthNets;
  int _monthNetsTxIdentity = 0;
  int _monthNetsFxIdentity = 0;
  double _monthNetsRate = -1;
  // Oldest (last) loaded calendar month — when the parent says more
  // pages exist, that month's subtotal is honestly flagged "(partial)".
  String? _monthNetsOldestKey;

  Map<String, double> _ensureMonthNets(List<dynamic> txs) {
    final identity = identityHashCode(txs);
    final fxIdentity = identityHashCode(widget.fxTransfers);
    if (_monthNets != null &&
        _monthNetsTxIdentity == identity &&
        _monthNetsFxIdentity == fxIdentity &&
        _monthNetsRate == widget.usdMxnRate) {
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
      // Plaid sign convention: positive = outflow. Net is income-positive.
      next[key] = next[key]! - converted;
    }
    _monthNets = next;
    _monthNetsTxIdentity = identity;
    _monthNetsFxIdentity = fxIdentity;
    _monthNetsRate = widget.usdMxnRate;
    _monthNetsOldestKey = oldest;
    return next;
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
    final netLabel =
        isPartial ? l.txMonthNetPartial(signedNet) : l.txMonthNet(signedNet);
    return Padding(
      padding: EdgeInsets.only(
        top: isFirst ? 4 : 28,
        left: 4,
        right: 4,
      ),
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
    final notes = (tx['user_notes'] ?? '').toString();
    // Same prettified label the row's meta line shows — the registry is
    // keyed on it, so a Spanish import category ("Supermercado") and the
    // Plaid enum ("FOOD_AND_DRINK") both land on a real style instead of
    // the old grey-receipt fallback.
    final catStyle = context.categoryStyle(prettyCategory(
      userCategory: tx['user_category']?.toString(),
      detailed: tx['category_detailed']?.toString(),
      primary: tx['category']?.toString(),
    ));
    final color = catStyle.color;

    final needsConversion =
        widget.usdMxnRate > 0 && sourceCurrency != widget.targetCurrency;

    final id = tx['id']?.toString();
    final isSelected = id != null && _selectedIds.contains(id);

    // FX-transfer leg? null = not linked; true/false = linked and
    // (any-)confirmed / auto-detected only. Drives the TRANSFER pill and
    // the neutral amount treatment — money moving between the user's own
    // pockets must not read as income (+green) or spending.
    final fxConfirmed = id == null ? null : _ensureFxLinkIndex()[id];
    final isFxTransfer = fxConfirmed != null;
    // Pill accent mirrors the detail block's semantics: teal = user-
    // confirmed link, amber = auto-detected (pending confirmation).
    final fxAccent =
        (fxConfirmed ?? false) ? context.tealAccent : context.warning;

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
              child: Icon(
                catStyle.icon,
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
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w600,
                                      fontSize: 14,
                                      height: 1.2,
                                    ),
                                    decoration: InputDecoration(
                                      isDense: true,
                                      contentPadding: const EdgeInsets.symmetric(
                                          horizontal: 6, vertical: 4),
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
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                    fontSize: 14,
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
                              horizontal: 6, vertical: 1),
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
                              horizontal: 6, vertical: 1),
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
                  // Transfer legs swap the +/− sign for ⇄ and render in
                  // neutral textPrimary: the money moved between the
                  // user's own accounts, so neither the green income
                  // treatment nor the expense one applies.
                  Text(
                    isFxTransfer
                        ? '⇄ ${formatCurrencyAmount(sourceAmount.abs(), sourceCurrency)}'
                        : '${isExpense ? '−' : '+'}${formatCurrencyAmount(sourceAmount.abs(), sourceCurrency)}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 14,
                      fontFeatures: const [FontFeature.tabularFigures()],
                      color: (isFxTransfer || isExpense)
                          ? context.textPrimary
                          : context.positive,
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
    final l = AppLocalizations.of(context);
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
    final initialCategoryLabel = hasAnyCategory
        ? prettyCategory(
            userCategory: tx['user_category']?.toString(),
            detailed: tx['category_detailed']?.toString(),
            primary: tx['category']?.toString(),
          )
        : '';
    final initialNotes = (tx['user_notes'] ?? '').toString();
    final catController = TextEditingController(text: initialCategoryLabel);
    final catFocusNode = FocusNode();
    final notesController = TextEditingController(text: initialNotes);
    // Shared suggestion source — the same list the bulk-categorize and
    // add-transaction dialogs feed from, so the type-ahead can't drift
    // into a second divergent taxonomy.
    final categorySuggestions = _distinctCategories();

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
    // ONE accent pair for the binary in/out concept, applied to the hero
    // border, caption and amount alike: inflow = jade positive, outflow =
    // neutral text. The red `negative` token stays reserved for
    // destructive/error affordances and teal for transfer/linked
    // semantics — previously this block mixed four accents (red border +
    // pink caption + neutral amount for an expense; teal border + teal
    // caption + green amount for income).
    final flowAccent = isExpense ? context.textPrimary : context.positive;
    final source = (tx['source'] ?? 'plaid').toString();
    final originalCategory = (tx['category'] ?? '').toString();
    final merchant = (tx['merchant_name'] ?? '').toString();
    final pending = tx['pending'] == true;
    final rawDescription = (tx['description'] ?? '').toString();
    final titleDescription = displayLabel(tx);
    final logoUrl = counterpartyLogo(tx);
    // Hero icon style — same registry the list rows use, keyed on the
    // prettified label (always non-empty: prettyCategory falls back to
    // "Uncategorized"/"Sin categoría", which has its own neutral style).
    final catStyle = context.categoryStyle(prettyCategory(
      userCategory: tx['user_category']?.toString(),
      detailed: tx['category_detailed']?.toString(),
      primary: tx['category']?.toString(),
    ));
    final color = catStyle.color;

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
      barrierLabel: l.txDismiss,
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
                      tooltip: l.actionClose,
                      // Keep a ≥48px touch target (a11y) instead of the
                      // zero-padding/empty-constraints ~20px hit area.
                      constraints: const BoxConstraints(
                          minWidth: 48, minHeight: 48),
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
                                  catStyle.icon,
                                  color: color,
                                  size: 28,
                                ),
                              )
                            : Icon(
                                catStyle.icon,
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
                                      ? l.txRename
                                      : l.txRenamePlusMatching(merchantMatches.length),
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
                        color: flowAccent.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
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
                        const SizedBox(height: 6),
                        // Hero amount in the transaction's NATIVE currency
                        // (this is the real, bank-reported value).
                        // brandDisplayStyle = the bundled JetBrains Mono
                        // display treatment (caps at a real w700 — the
                        // old w900 request synthesised a faux bold Inter
                        // ships no file for) with tabular/lining figures
                        // like every other hero money figure.
                        Text(
                          '${isExpense ? '−' : '+'}${formatCurrencyAmount(sourceAmount.abs(), sourceCurrency)}',
                          style: brandDisplayStyle(
                            fontSize: 32,
                            color: flowAccent,
                          ),
                        ),
                        if (needsConversion) ...[
                          const SizedBox(height: 4),
                          Text(
                            l.txApproxEstimated(
                                widget.currencyFormat.format(convertedAmount.abs())),
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
                      _metaChip(Icons.cloud_download, _sourceLabel(context, source)),
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
                        _metaChip(Icons.hourglass_empty, l.txStatusPending,
                            accent: context.warning),
                    ],
                  ),
                  if (rawDescription != titleDescription) ...[
                    const SizedBox(height: 16),
                    _sectionLabel(l.txRawBankText),
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
                  _sectionLabel(l.txCategoryAndNotes),
                  const SizedBox(height: 8),
                  // Category type-ahead. RawAutocomplete (same pattern
                  // as AddTransactionDialog's category field) so the
                  // save path keeps reading [catController] directly.
                  // Suggestions are hints only — a free-typed value not
                  // in the list is still accepted.
                  RawAutocomplete<String>(
                    textEditingController: catController,
                    focusNode: catFocusNode,
                    optionsBuilder: (TextEditingValue value) {
                      final q = value.text.trim().toLowerCase();
                      if (q.isEmpty) return categorySuggestions;
                      return categorySuggestions
                          .where((s) => s.toLowerCase().contains(q));
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
                                maxHeight: 200, maxWidth: 420),
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
                                        horizontal: 16, vertical: 12),
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
                    controller: notesController,
                    decoration: InputDecoration(
                      labelText: l.txNotes,
                      hintText: l.txNotesHint,
                      border: const OutlineInputBorder(),
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
                    _sectionLabel(l.txRecentAtMerchant),
                    const SizedBox(height: 6),
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        l.txMerchantTotal(
                            widget.currencyFormat.format(merchantTotal),
                            merchantCount),
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
                    _sectionLabel(l.txMoveToDifferentAccount),
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
                            SnackBar(content: Text(l.txMoveFailed(e.toString()))),
                          );
                        }
                      },
                    ),
                  ],
                  // Split / Unsplit affordance. A child row offers
                  // "Unsplit" (restore the parent + delete every
                  // sibling); a regular row offers "Split". Hidden
                  // for the very small set of states that don't make
                  // sense — e.g. a manually-added row that's already
                  // a child (since it has a parent_id) follows the
                  // child branch.
                  if (widget.onSplitTransaction != null ||
                      widget.onUnsplitTransaction != null) ...[
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      children: [
                        if ((tx['parent_id'] ?? '').toString().isEmpty &&
                            widget.onSplitTransaction != null)
                          OutlinedButton.icon(
                            onPressed: () =>
                                _openSplitDialog(tx, sourceCurrency, sourceAmount,
                                    titleDescription, originalCategory),
                            icon: const Icon(Icons.call_split, size: 16),
                            label: Text(l.txSplitThisTransaction),
                          ),
                        if ((tx['parent_id'] ?? '').toString().isNotEmpty &&
                            widget.onSplitTransaction != null &&
                            widget.onUnsplitTransaction != null)
                          OutlinedButton.icon(
                            onPressed: () => _openEditSplitDialog(
                              (tx['parent_id'] ?? '').toString(),
                              sourceCurrency,
                              sourceAmount,
                              titleDescription,
                              originalCategory,
                            ),
                            icon: const Icon(Icons.edit_outlined, size: 16),
                            label: Text(l.txEditSplit),
                          ),
                        if ((tx['parent_id'] ?? '').toString().isNotEmpty &&
                            widget.onUnsplitTransaction != null)
                          OutlinedButton.icon(
                            onPressed: () async {
                              Navigator.of(context).pop();
                              try {
                                await widget.onUnsplitTransaction!(
                                    (tx['parent_id'] ?? '').toString());
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(l.txSplitRemoved)),
                                );
                              } catch (e) {
                                if (!mounted) return;
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(content: Text(l.txUnsplitFailed(e.toString()))),
                                );
                              }
                            },
                            icon: const Icon(Icons.call_merge, size: 16),
                            label: Text(l.txUnsplitRestore),
                          ),
                      ],
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
                                title: Text(l.txDeleteOneTitle),
                                content: Text(l.txDeleteOneBody),
                                actions: [
                                  TextButton(
                                      onPressed: () =>
                                          Navigator.pop(ctx, false),
                                      child: Text(l.actionCancel)),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(ctx, true),
                                    style: TextButton.styleFrom(
                                        foregroundColor: ctx.negative),
                                    child: Text(l.actionDelete),
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
                                        Text(l.txDeleteFailed(e.toString()))),
                              );
                            }
                          },
                          icon: Icon(Icons.delete_outline,
                              size: 16, color: context.negative),
                          label: Text(l.actionDelete,
                              style: TextStyle(color: context.negative)),
                        ),
                      const Spacer(),
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: Text(l.actionClose),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          // Diff each field against its prefill: only
                          // what the user actually edited is sent
                          // (null = "leave alone" in the PATCH). A
                          // no-edit Save must NOT turn the
                          // auto-category into a user override of the
                          // raw enum string.
                          final newCategory = diffEditedField(
                              catController.text, initialCategoryLabel);
                          final newNotes = diffEditedField(
                              notesController.text, initialNotes);
                          Navigator.pop(context);
                          if (newCategory == null && newNotes == null) {
                            return;
                          }
                          widget.onUpdate?.call(
                            tx['id'],
                            userCategory: newCategory,
                            userNotes: newNotes,
                          );
                        },
                        child: Text(l.actionSave),
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
    final l = AppLocalizations.of(context);

    final widgets = <Widget>[
      const SizedBox(height: 20),
      _sectionLabel(l.txLinkedTransfer),
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
              l.txTransferImpliedRate(
                _formatNative(srcAmt, srcCcy),
                _formatNative(dstAmt, dstCcy),
                implied.toStringAsFixed(2),
                dstCcy,
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
          child: Text(l.txMove),
        ),
      ],
    );
  }
}
