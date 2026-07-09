import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
// Conditional seam (NOT services/preferences.dart directly): Preferences
// pulls package:web, which doesn't compile on the Dart test VM. See
// services/account_alerts_cache.dart.
import '../services/account_alerts_cache.dart';
import '../services/api_service.dart';
import '../services/transaction_mutation_refresh.dart'
    show mergeRefetchedTransactions, txRefetchLimit;
import '../theme/typography.dart';
import '../utils/account_category.dart';
import '../utils/chart_touch.dart';
import '../utils/currency.dart';
import '../utils/percent_format.dart';
import '../utils/theme_colors.dart';
import '../widgets/account_balance_chart.dart';
import '../widgets/add_holding_dialog.dart';
import '../widgets/add_transaction_dialog.dart';
import '../widgets/clabe_info.dart';
import '../widgets/transactions_tab.dart';

/// Signature of one paged, newest-first fetch of an account's
/// transactions (see [AccountTransactionsScreen.transactionsFetcher]).
typedef AccountTransactionsFetcher = Future<List<dynamic>> Function({
  required int limit,
  required int offset,
});

/// Signature of the single-row PATCH issued from the detail editors
/// (see [AccountTransactionsScreen.transactionUpdater]).
typedef AccountTransactionUpdater = Future<void> Function(
  String id, {
  String? userCategory,
  String? userNotes,
  String? userDescription,
  String? accountId,
});

/// Signature of one fetch of an account's holdings
/// (see [AccountTransactionsScreen.holdingsFetcher]).
typedef AccountHoldingsFetcher = Future<List<dynamic>> Function(
    String accountId);

/// Signature of the (soft) DELETE behind the holding-row close button
/// (see [AccountTransactionsScreen.holdingDeleter]).
typedef AccountHoldingDeleter = Future<void> Function(
    String accountId, String holdingId);

/// Signature of the restore POST behind the delete-undo snackbar
/// (see [AccountTransactionsScreen.holdingRestorer]).
typedef AccountHoldingRestorer = Future<Map<String, dynamic>> Function(
    String accountId, String holdingId);

/// Per-account transaction history. Rendered as the body of a slide-from-
/// right side panel via [showAccountTransactionsPanel] — no Scaffold/AppBar
/// of its own. On narrow viewports the panel collapses to a bottom sheet.
class AccountTransactionsScreen extends StatefulWidget {
  final Map<String, dynamic> account;
  final List<dynamic> allAccounts;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final String targetCurrency;
  final double usdMxnRate;
  final Function(String, double)? onBalanceUpdate;
  /// Optional inline rename action — when wired, the header surfaces a
  /// "Rename" entry in the overflow menu that lets the user set a
  /// nickname without leaving the panel.
  final Future<void> Function(String accountId, String nickname)?
      onRenameAccount;
  /// Fired after a low-balance threshold is saved/removed so the opener
  /// (e.g. the dashboard) can refresh its notifications bell immediately.
  final VoidCallback? onAlertsChanged;
  /// Test seam: one paged, newest-first fetch of this account's
  /// transactions. Production leaves it null and the panel uses
  /// `ApiService.getAccountTransactions` — widget tests inject a fake
  /// here instead of subclassing ApiService (package:web won't compile
  /// on the test VM).
  @visibleForTesting
  final AccountTransactionsFetcher? transactionsFetcher;
  /// Test seam: the single-row PATCH behind the detail editors.
  /// Production leaves it null → `ApiService.updateTransaction`.
  @visibleForTesting
  final AccountTransactionUpdater? transactionUpdater;
  /// Test seams for the holdings list + the delete-undo flow. Production
  /// leaves them null → `ApiService.getAccountHoldings` /
  /// `.deleteHolding` / `.restoreHolding` (same rationale as
  /// [transactionsFetcher]: package:web won't compile on the test VM).
  @visibleForTesting
  final AccountHoldingsFetcher? holdingsFetcher;
  @visibleForTesting
  final AccountHoldingDeleter? holdingDeleter;
  @visibleForTesting
  final AccountHoldingRestorer? holdingRestorer;

  const AccountTransactionsScreen({
    super.key,
    required this.account,
    this.allAccounts = const [],
    required this.conversionFactor,
    required this.currencyFormat,
    required this.targetCurrency,
    required this.usdMxnRate,
    this.onBalanceUpdate,
    this.onRenameAccount,
    this.onAlertsChanged,
    this.transactionsFetcher,
    this.transactionUpdater,
    this.holdingsFetcher,
    this.holdingDeleter,
    this.holdingRestorer,
  });

  @override
  State<AccountTransactionsScreen> createState() =>
      _AccountTransactionsScreenState();
}

class _AccountTransactionsScreenState extends State<AccountTransactionsScreen> {
  final ApiService _apiService = ApiService();
  /// The panel's own nested [ScaffoldMessenger] (see [build]): snackbars
  /// shown through it paint above the panel route instead of being hidden
  /// behind it on the root Scaffold.
  final GlobalKey<ScaffoldMessengerState> _panelMessengerKey =
      GlobalKey<ScaffoldMessengerState>();
  /// The delete-undo currently counting down on the panel messenger, if
  /// any. [dispose] hands it over to the root messenger so closing the
  /// panel mid-countdown never strands the Undo affordance.
  _PendingHoldingUndo? _pendingUndo;
  bool _isLoading = true;
  String? _error;
  List<dynamic>? _transactions;
  // True while the backend may hold rows older than the loaded pages —
  // drives TransactionsTab's "Load more" button + filter cascade.
  bool _hasMore = false;
  // Initial/Load-more page size. Small enough that opening the panel is
  // one cheap request (was a fixed 1,000-row download), large enough
  // that the bounded-host virtualised list has a screenful to show.
  static const int _pageSize = 50;
  List<dynamic> _balanceHistory = const [];
  // Equity holdings (Plaid-synced or manually added by ticker + quantity).
  List<dynamic> _holdings = const [];
  bool _refreshingHoldings = false;
  // Dividend info keyed by symbol (annual rate, yield, est next ex-date, income).
  Map<String, dynamic> _dividends = const {};
  // Low-balance alert thresholds (account id -> native-currency amount).
  Map<String, double> _accountAlerts = const {};

  /// Locally-tracked balance and nickname so this screen can reflect an edit
  /// immediately without writing back into the parent's shared map. The
  /// parent will pick up the real values on its next data refresh.
  late double _currentBalance;
  late String _nickname;

  @override
  void initState() {
    super.initState();
    _currentBalance =
        ((widget.account['current_balance'] as num?)?.toDouble()) ?? 0.0;
    _nickname = (widget.account['nickname'] ?? '').toString();
    _accountAlerts = readCachedAccountAlerts();
    _fetchTransactions();
    _fetchBalanceHistory();
    _fetchHoldings();
    _hydrateAlerts();
  }

  @override
  void dispose() {
    // Round 3 (undo-reachability, part b): a pending delete-undo lives on
    // the panel's nested messenger, which dies with this State — re-show
    // the remaining countdown on the ROOT messenger (captured before the
    // delete's awaits) so the user can still undo after closing the
    // panel. Deferred to a post-frame callback because the tree is locked
    // during unmount: the root messenger's setState can't run here.
    final pending = _pendingUndo;
    _pendingUndo = null;
    if (pending != null) {
      final remaining = pending.expiresAt.difference(DateTime.now());
      if (remaining > Duration.zero) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (pending.rootMessenger.mounted) {
            _showUndoSnackBar(pending.rootMessenger, pending, remaining);
          }
        });
      }
    }
    super.dispose();
  }

  /// Where in-panel notices go: the panel's own messenger while it is
  /// mounted (renders above the panel content), the root messenger as a
  /// fallback during teardown edges.
  ScaffoldMessengerState get _messenger =>
      _panelMessengerKey.currentState ?? ScaffoldMessenger.of(context);

  bool get _isInvestment =>
      categorizeAccount(widget.account['account_type']?.toString()) ==
      AccountCategory.investment;

  /// Holdings can only be hand-edited on a manual account — a Plaid-synced
  /// account's holdings are read-only (the institution owns them).
  bool get _isManualAccount =>
      (widget.account['integration_type'] ?? '').toString() == 'manual';

  /// [syncBalance] is set on holding-mutation paths (add / delete): it
  /// re-derives the header balance from the fresh holdings and clears a
  /// stale dividend estimate when the last payer was removed. The plain
  /// initState load must NOT sync — a holdings-less manual account (a
  /// CETES-style balance-only position) would have its hand-set balance
  /// zeroed just by opening the panel.
  Future<void> _fetchHoldings({bool syncBalance = false}) async {
    if (!_isInvestment) return;
    try {
      final h = await (widget.holdingsFetcher ??
          _apiService.getAccountHoldings)(_accountId);
      if (!mounted) return;
      setState(() => _holdings = h);
      if (syncBalance) _syncBalanceFromHoldings(h);
      if (h.isNotEmpty) {
        _fetchDividends();
      } else if (_dividends.isNotEmpty) {
        // Deleting the last payer used to skip the dividends refresh,
        // leaving a stale map (and a stale "Est. annual income" line)
        // behind. No holdings → no dividend income, no fetch needed.
        setState(() => _dividends = const {});
      }
    } catch (_) {/* best-effort */}
  }

  /// Mirror the backend's `recompute_holding_balance` (manual investment
  /// account balance := Σ holding values, native currency) so the panel
  /// header and — via [AccountTransactionsScreen.onBalanceUpdate] — the
  /// dashboard's accounts list reflect a holding add/remove immediately,
  /// not on the next full app reload.
  void _syncBalanceFromHoldings(List<dynamic> holdings) {
    if (!_isManualAccount) return;
    double total = 0;
    for (final h in holdings) {
      total += (h['value'] is num)
          ? (h['value'] as num).toDouble()
          : double.tryParse('${h['value'] ?? ''}') ?? 0;
    }
    setState(() => _currentBalance = total);
    widget.onBalanceUpdate?.call(_accountId, total);
  }

  Future<void> _fetchDividends() async {
    try {
      final divs = await _apiService.getHoldingsDividends(_accountId);
      if (!mounted) return;
      setState(() => _dividends = {
            for (final d in divs)
              if (d is Map && d['symbol'] != null) d['symbol'].toString(): d,
          });
    } catch (_) {/* best-effort */}
  }

  Future<void> _addHolding() async {
    await showDialog<void>(
      context: context,
      builder: (_) => AddHoldingDialog(
        accountId: _accountId,
        onAdded: () {
          _fetchHoldings(syncBalance: true);
          _fetchBalanceHistory();
        },
      ),
    );
  }

  Future<void> _refreshHoldings() async {
    setState(() => _refreshingHoldings = true);
    try {
      final h = await _apiService.refreshHoldings(_accountId);
      if (mounted) setState(() => _holdings = h);
      // Refreshed prices change the holdings' values — keep the header
      // balance in step with the backend's recompute.
      if (mounted) _syncBalanceFromHoldings(h);
      _fetchDividends();
      _fetchBalanceHistory();
    } catch (_) {
    } finally {
      if (mounted) setState(() => _refreshingHoldings = false);
    }
  }

  Future<void> _hydrateAlerts() async {
    try {
      final raw = await _apiService.getSetting('account_balance_alerts');
      if (!mounted || raw is! Map) return;
      final next = <String, double>{};
      raw.forEach((k, v) {
        final d = v is num ? v.toDouble() : double.tryParse('$v');
        if (d != null && d > 0) next[k.toString()] = d;
      });
      setState(() => _accountAlerts = next);
      writeCachedAccountAlerts(next);
    } catch (_) {
      // localStorage seed stands.
    }
  }

  bool get _alertEligible {
    final cat = categorizeAccount(widget.account['account_type']?.toString());
    return cat != AccountCategory.credit && cat != AccountCategory.loan;
  }

  String get _accountId => widget.account['id'].toString();

  void _showThresholdDialog() {
    final l = AppLocalizations.of(context);
    final currency =
        (widget.account['currency'] ?? 'USD').toString().toUpperCase();
    final existing = _accountAlerts[_accountId];
    // dispose: local controller, else the dialog leaks it. whenComplete fires
    // once the dialog route is fully popped — after every read of controller.text.
    final controller = TextEditingController(
      text: existing == null ? '' : existing.toStringAsFixed(0),
    );
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(l.acctxLowBalanceAlertTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l.acctxLowBalanceAlertBody,
              style: TextStyle(color: context.textMuted, fontSize: 13),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              autofocus: true,
              decoration: InputDecoration(
                labelText: l.acctxThresholdLabel,
                prefixText: r'$ ',
                suffixText: currency,
              ),
            ),
          ],
        ),
        actions: [
          if (existing != null)
            TextButton(
              onPressed: () {
                Navigator.pop(context);
                _saveThreshold(null);
              },
              child: Text(l.acctxRemoveAlert),
            ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () {
              final v = double.tryParse(controller.text);
              Navigator.pop(context);
              if (v != null && v > 0) _saveThreshold(v);
            },
            child: Text(l.actionSave),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  void _saveThreshold(double? value) {
    final next = Map<String, double>.from(_accountAlerts);
    final l = AppLocalizations.of(context);
    if (value == null) {
      next.remove(_accountId);
    } else {
      next[_accountId] = value;
    }
    setState(() => _accountAlerts = next);
    writeCachedAccountAlerts(next);
    _apiService.putSetting('account_balance_alerts', next).catchError((_) {});
    widget.onAlertsChanged?.call();
    // Panel messenger, not root: a root snackbar would be hidden behind
    // this panel route (see build()).
    _messenger.showSnackBar(
      SnackBar(
        content: Text(
            value == null ? l.acctxAlertRemoved : l.acctxAlertSaved),
      ),
    );
  }

  Future<void> _fetchBalanceHistory() async {
    final history =
        await _apiService.getAccountBalanceHistory(widget.account['id'].toString());
    if (mounted) setState(() => _balanceHistory = history);
  }

  @override
  void didUpdateWidget(covariant AccountTransactionsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.account != oldWidget.account) {
      _currentBalance =
          ((widget.account['current_balance'] as num?)?.toDouble()) ?? 0.0;
      _nickname = (widget.account['nickname'] ?? '').toString();
      _fetchBalanceHistory();
    }
  }

  /// One newest-first page from the backend (or the injected test
  /// fetcher). All transaction reads in this screen go through here so
  /// paging, the in-place refetch and the tests share one seam.
  Future<List<dynamic>> _fetchPage({required int limit, required int offset}) {
    final fetcher = widget.transactionsFetcher;
    if (fetcher != null) return fetcher(limit: limit, offset: offset);
    return _apiService.getAccountTransactions(
      _accountId,
      limit: limit,
      offset: offset,
    );
  }

  /// Initial load (and the error-state Retry). This is the ONLY path
  /// that may show the full-body spinner: post-mutation refreshes go
  /// through [_refetchTransactionsInPlace] and paging appends via
  /// [_loadMoreTransactions], both of which keep the list mounted so
  /// scroll position and search/filter state survive.
  Future<void> _fetchTransactions() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final txs = await _fetchPage(limit: _pageSize, offset: 0);
      if (!mounted) return;
      setState(() {
        _transactions = txs;
        _hasMore = txs.length >= _pageSize;
        _isLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  /// Append the next page. [limit] overrides the default page size —
  /// TransactionsTab's whole-history filter cascade passes the backend's
  /// per-request cap so a filter over deep history converges in a few
  /// round-trips. Mirrors the dashboard's `_loadMoreTransactions`.
  Future<void> _loadMoreTransactions({int? limit}) async {
    final pageSize = limit ?? _pageSize;
    final offset = _transactions?.length ?? 0;
    final more = await _fetchPage(limit: pageSize, offset: offset);
    if (!mounted) return;
    setState(() {
      _transactions = [...(_transactions ?? const []), ...more];
      // Fewer rows than asked for = we reached the tail of the account.
      _hasMore = more.length >= pageSize;
    });
  }

  /// Manual-entry dialog preselected on this account. Used by the
  /// zero-transactions empty state; the populated list reaches the same
  /// dialog through TransactionsTab's toolbar "+" (same preselect).
  void _openAddTransactionDialog() {
    showDialog<void>(
      context: context,
      builder: (_) => AddTransactionDialog(
        accounts: widget.allAccounts,
        apiService: _apiService,
        initialAccountId: _accountId,
        onCreated: () {
          _refetchTransactionsInPlace();
          _fetchBalanceHistory();
        },
      ),
    );
  }

  /// Depth-preserving refetch after a mutation (edit / delete / split /
  /// bulk / manual add). Re-covers at least everything already loaded —
  /// capped at the backend's per-request max — and overlays the result
  /// onto the current list, so the panel updates IN PLACE: no full-body
  /// spinner, no list remount, scroll + search/filter state intact.
  /// A transient failure keeps the current rows on screen (same policy
  /// as the dashboard's post-mutation refresh).
  Future<void> _refetchTransactionsInPlace() async {
    final previous = _transactions ?? const [];
    final limit =
        txRefetchLimit(loadedCount: previous.length, pageSize: _pageSize);
    try {
      final refetched = await _fetchPage(limit: limit, offset: 0);
      if (!mounted) return;
      setState(() {
        _transactions = mergeRefetchedTransactions(
          previous: previous,
          refetched: refetched,
          requestedLimit: limit,
        );
        // A short page proves we now hold the account's whole history; a
        // full page tells us nothing new, so leave the flag as-is.
        if (refetched.length < limit) _hasMore = false;
      });
    } catch (e) {
      debugPrint('Account panel post-mutation refresh error: $e');
    }
  }

  void _showRenameDialog() {
    final l = AppLocalizations.of(context);
    // dispose: local controller, else the dialog leaks it.
    final controller = TextEditingController(text: _nickname);
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(l.acctxRenameAccount),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: l.acctxNickname,
            hintText: widget.account['name']?.toString() ?? l.acctxAccountFallback,
          ),
          onSubmitted: (v) {
            Navigator.pop(context);
            final next = v.trim();
            setState(() => _nickname = next);
            widget.onRenameAccount
                ?.call(widget.account['id'].toString(), next);
          },
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(l.actionCancel)),
          FilledButton(
            onPressed: () async {
              final v = controller.text.trim();
              Navigator.pop(context);
              if (mounted) setState(() => _nickname = v);
              await widget.onRenameAccount
                  ?.call(widget.account['id'].toString(), v);
            },
            child: Text(l.actionSave),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  // Derive a small balance-history sparkline from the loaded transactions
  // by walking backward from the current balance. This avoids a new
  // backend endpoint and is "good enough" for the recent 30-day shape.
  Widget _buildBalanceSparkline() {
    final txs = _transactions ?? const [];
    final current = _currentBalance;

    // Walk transactions newest-first. Storage sign convention (backend
    // sync.rs:659): negative = outflow, positive = inflow, so a row's
    // balance-before is balance(date) − amount, i.e. the day before an
    // outflow the balance was higher: balance(date - 1) = balance(date) − amount.
    final sorted = [...txs];
    sorted.sort((a, b) {
      final ad = DateTime.tryParse(a['date']?.toString() ?? '') ?? DateTime(2000);
      final bd = DateTime.tryParse(b['date']?.toString() ?? '') ?? DateTime(2000);
      return bd.compareTo(ad);
    });

    final today = DateTime.now();
    final cutoff = today.subtract(const Duration(days: 30));
    final dailyBalances = <DateTime, double>{today: current};
    var running = current;
    for (final tx in sorted) {
      final d = DateTime.tryParse(tx['date']?.toString() ?? '');
      if (d == null) continue;
      if (d.isBefore(cutoff)) break;
      final amt = ((tx['amount'] as num?)?.toDouble() ?? 0.0);
      running -= amt;
      dailyBalances[DateTime(d.year, d.month, d.day)] = running;
    }

    if (dailyBalances.length < 2) return const SizedBox.shrink();

    final orderedDays = dailyBalances.keys.toList()
      ..sort((a, b) => a.compareTo(b));
    final points = <FlSpot>[
      for (var i = 0; i < orderedDays.length; i++)
        FlSpot(i.toDouble(), dailyBalances[orderedDays[i]]!),
    ];

    final ys = points.map((p) => p.y).toList();
    final minY = ys.reduce((a, b) => a < b ? a : b);
    final maxY = ys.reduce((a, b) => a > b ? a : b);
    final pad = (maxY - minY).abs() * 0.1 + 1;
    final isUp = points.last.y >= points.first.y;
    final color = isUp ? context.positive : context.pinkAccent;

    // The sparkline is derived in the account's NATIVE currency (it walks
    // back from `_currentBalance`), so the tooltip formats with the same
    // helper as the panel header — not the dashboard's display currency.
    final sparkCurrency =
        (widget.account['currency'] ?? widget.targetCurrency).toString();

    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: SizedBox(
        height: 48,
        child: LineChart(
          LineChartData(
            minY: minY - pad,
            maxY: maxY + pad,
            gridData: const FlGridData(show: false),
            titlesData: const FlTitlesData(show: false),
            borderData: FlBorderData(show: false),
            // Index-spaced x: tooltip dates come from `orderedDays[idx]`.
            lineTouchData: standardLineTouch(
              context,
              items: (ctx, touchedSpots) {
                return touchedSpots.map((spot) {
                  final idx =
                      spot.x.toInt().clamp(0, orderedDays.length - 1);
                  return LineTooltipItem(
                    '',
                    TextStyle(color: ctx.tooltipOnSurface),
                    children: [
                      TextSpan(
                        text:
                            '${DateFormat.yMMMd().format(orderedDays[idx])}\n',
                        style: TextStyle(
                          color: ctx.tooltipOnSurfaceMuted,
                          fontSize: 11,
                          fontWeight: FontWeight.normal,
                        ),
                      ),
                      TextSpan(
                        text: formatCurrencyAmount(spot.y, sparkCurrency),
                        style: TextStyle(
                          color: ctx.tooltipOnSurface,
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                          fontFeatures: const [
                            FontFeature.tabularFigures()
                          ],
                        ),
                      ),
                    ],
                  );
                }).toList();
              },
            ),
            lineBarsData: [
              LineChartBarData(
                spots: points,
                isCurved: true,
                curveSmoothness: 0.25,
                color: color,
                barWidth: 2,
                dotData: const FlDotData(show: false),
                belowBarData: BarAreaData(
                  show: true,
                  color: color.withValues(alpha: 0.12),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showEditBalanceDialog() {
    final l = AppLocalizations.of(context);
    final controller = TextEditingController(text: _currentBalance.toString());
    final currency =
        (widget.account['currency'] ?? 'USD').toString().toUpperCase();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(l.acctxUpdateBalanceTitle(
            (widget.account['name'] ?? l.acctxAccountFallback).toString())),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(
              decimal: true, signed: true),
          autofocus: true,
          onSubmitted: (_) {
            final newBalance = double.tryParse(controller.text);
            if (newBalance == null) return;
            Navigator.pop(context);
            setState(() => _currentBalance = newBalance);
            widget.onBalanceUpdate?.call(widget.account['id'], newBalance);
          },
          decoration: InputDecoration(
            labelText: l.acctxCurrentBalance,
            prefixText: r'$ ',
            suffixText: currency,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l.actionCancel),
          ),
          ElevatedButton(
            onPressed: () {
              final newBalance = double.tryParse(controller.text);
              if (newBalance == null) return;
              Navigator.pop(context);
              setState(() => _currentBalance = newBalance);
              widget.onBalanceUpdate?.call(widget.account['id'], newBalance);
            },
            child: Text(l.actionSave),
          ),
        ],
      ),
    ).whenComplete(controller.dispose);
  }

  @override
  Widget build(BuildContext context) {
    // Round 3 (undo-reachability): the panel is a showGeneralDialog route
    // painted ABOVE the app's root Scaffold, so a snackbar shown on the
    // root messenger is covered by the panel and its Undo action can't be
    // reached (the modal barrier also hides it from the semantics tree).
    // Nesting the panel's own ScaffoldMessenger + a transparent Scaffold
    // makes in-panel snackbars (delete-undo, alert saved, edit failed)
    // render INSIDE the panel, above its content. If the panel closes
    // while a delete-undo countdown is still live, [dispose] re-shows the
    // snackbar on the root messenger so the affordance survives.
    return ScaffoldMessenger(
      key: _panelMessengerKey,
      child: Scaffold(
        // Purely structural scaffolding for the messenger: transparent and
        // inset-inert so the panel's visual chrome (rounded container in
        // showAccountTransactionsPanel) is untouched.
        backgroundColor: Colors.transparent,
        resizeToAvoidBottomInset: false,
        body: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            Divider(height: 1, color: context.hairline),
            Expanded(child: _buildBody()),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    final l = AppLocalizations.of(context);
    final balance = _currentBalance.abs();
    final sourceCurrency =
        (widget.account['currency'] ?? widget.targetCurrency).toString();
    final convertedBalance = convertCurrency(
      balance,
      from: sourceCurrency,
      to: widget.targetCurrency,
      usdMxnRate: widget.usdMxnRate,
    );
    final needsConversion = widget.usdMxnRate > 0 &&
        sourceCurrency != widget.targetCurrency;
    final inst = (widget.account['institution_name'] ?? '').toString();
    final name = (widget.account['name'] ?? l.acctxAccountFallback).toString();

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 16, 12, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (inst.isNotEmpty)
                      Text(
                        inst.toUpperCase(),
                        style: TextStyle(
                          fontSize: 11,
                          color: context.textSubtle,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.0,
                        ),
                      ),
                    const SizedBox(height: 4),
                    Text(
                      name,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                // A5 (round 3, a11y): the kebab names its account so several
                // open panels / rows can't announce identically.
                tooltip: l.axAccountActionsFor(name),
                onSelected: (v) {
                  switch (v) {
                    case 'balance':
                      _showEditBalanceDialog();
                    case 'rename':
                      _showRenameDialog();
                    case 'alert':
                      _showThresholdDialog();
                  }
                },
                // A5 (round 3, a11y): MergeSemantics per item so icon +
                // title read as one node (accounts_list pattern).
                itemBuilder: (_) => [
                  PopupMenuItem(
                    value: 'balance',
                    child: MergeSemantics(
                      child: ListTile(
                        dense: true,
                        leading: const Icon(Icons.edit_outlined),
                        title: Text(l.acctxUpdateBalance),
                      ),
                    ),
                  ),
                  if (widget.onRenameAccount != null)
                    PopupMenuItem(
                      value: 'rename',
                      child: MergeSemantics(
                        child: ListTile(
                          dense: true,
                          leading:
                              const Icon(Icons.drive_file_rename_outline),
                          title: Text(l.acctxRenameAccount),
                        ),
                      ),
                    ),
                  if (_alertEligible)
                    PopupMenuItem(
                      value: 'alert',
                      child: MergeSemantics(
                        child: ListTile(
                          dense: true,
                          leading:
                              const Icon(Icons.notifications_active_outlined),
                          title: Text(_accountAlerts.containsKey(_accountId)
                              ? l.acctxEditLowBalanceAlert
                              : l.acctxSetLowBalanceAlert),
                        ),
                      ),
                    ),
                ],
                icon: const Icon(Icons.more_vert, size: 20),
              ),
              IconButton(
                tooltip: l.actionClose,
                icon: const Icon(Icons.close, size: 20),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Native balance as the hero, with the converted estimate stacked
          // cleanly beneath it (was crammed onto the same baseline, which read
          // awkwardly with a long MXN figure).
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // brandDisplayStyle: the shared big-figure treatment
              // (bundled mono, caps at a real w700 instead of the old
              // w900 faux-bold, tabular/lining figures built in).
              Text(
                formatCurrencyAmount(balance, sourceCurrency),
                style: brandDisplayStyle(
                  fontSize: 28,
                  color: context.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (needsConversion)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Text(
                    '≈ ${widget.currencyFormat.format(convertedBalance)}',
                    style: TextStyle(
                      fontSize: 12.5,
                      color: context.textSubtle,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
            ],
          ),
          _buildBalanceSparkline(),
          _buildLowBalanceBanner(),
        ],
      ),
    );
  }

  // Amber heads-up when the balance has fallen to/below the user's threshold.
  Widget _buildLowBalanceBanner() {
    final threshold = _accountAlerts[_accountId];
    if (threshold == null || _currentBalance > threshold) {
      return const SizedBox.shrink();
    }
    final l = AppLocalizations.of(context);
    final currency =
        (widget.account['currency'] ?? widget.targetCurrency).toString();
    final color = context.warning;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child: Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: color, size: 18),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l.acctxLowBalanceBanner(
                    formatCurrencyAmount(threshold, currency)),
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.w600,
                  fontSize: 12.5,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHoldings(String currency) {
    final es = Localizations.localeOf(context).languageCode == 'es';
    final fmt = moneyFormat(currency);
    double total = 0;
    for (final h in _holdings) {
      total += (h['value'] is num)
          ? (h['value'] as num).toDouble()
          : double.tryParse('${h['value']}') ?? 0;
    }
    return Container(
      decoration: BoxDecoration(
        color: context.tileSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.hairline),
      ),
      padding: const EdgeInsets.fromLTRB(14, 10, 6, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              // A5 (round 3, a11y): section header landmark. container:
              // forces the boundary so the flag can't absorb the card.
              Semantics(
                container: true,
                header: true,
                child: Text(
                  es ? 'POSICIONES' : 'HOLDINGS',
                  style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w700,
                      color: context.textSubtle),
                ),
              ),
              const Spacer(),
              if (_holdings.isNotEmpty && _isManualAccount)
                IconButton(
                  tooltip: es ? 'Actualizar precios' : 'Refresh prices',
                  visualDensity: VisualDensity.compact,
                  icon: _refreshingHoldings
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2))
                      : Icon(Icons.refresh, size: 18, color: context.tealAccent),
                  onPressed: _refreshingHoldings ? null : _refreshHoldings,
                ),
              if (_isManualAccount)
                TextButton.icon(
                  onPressed: _addHolding,
                  icon: const Icon(Icons.add, size: 16),
                  label: Text(AppLocalizations.of(context).actionAdd),
                ),
            ],
          ),
          if (_holdings.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(0, 4, 8, 4),
              child: Text(
                _isManualAccount
                    ? (es
                        ? 'Sin posiciones todavía. Agrega acciones por símbolo (ticker).'
                        : 'No holdings yet. Add shares by ticker.')
                    : (es ? 'Sin posiciones.' : 'No holdings.'),
                style: TextStyle(fontSize: 12.5, color: context.textFaint),
              ),
            )
          else ...[
            for (final h in _holdings) _holdingRow(h, fmt, es),
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(children: [
                const Divider(height: 16),
                // A5 (round 3, a11y): totals announce as one node each
                // ("Total $X" / "Est. annual income (dividends) $Y").
                MergeSemantics(
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(es ? 'Total' : 'Total',
                          style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: context.textSubtle)),
                      Text(fmt.format(total),
                          style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: context.textPrimary,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ])),
                    ],
                  ),
                ),
                if (_totalDividendIncome() > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: MergeSemantics(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                              es
                                  ? 'Ingreso anual estimado (dividendos)'
                                  : 'Est. annual income (dividends)',
                              style: TextStyle(
                                  fontSize: 11.5, color: context.tealAccent)),
                          Text(fmt.format(_totalDividendIncome()),
                              style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: context.tealAccent,
                                  fontFeatures: const [
                                    FontFeature.tabularFigures()
                                  ])),
                        ],
                      ),
                    ),
                  ),
              ]),
            ),
          ],
        ],
      ),
    );
  }

  double _totalDividendIncome() {
    double t = 0;
    for (final d in _dividends.values) {
      t += (d is Map ? (d['annual_income'] as num?)?.toDouble() : null) ?? 0;
    }
    return t;
  }

  Widget _dividendLine(String symbol, NumberFormat fmt, bool es) {
    final d = _dividends[symbol];
    final income =
        d == null ? 0.0 : ((d['annual_income'] as num?)?.toDouble() ?? 0.0);
    if (d == null || income <= 0) return const SizedBox.shrink();
    final yieldPct = (d['yield_pct'] as num?)?.toDouble();
    final next = d['est_next_ex_date']?.toString();
    return Padding(
      padding: const EdgeInsets.only(top: 1),
      child: Text(
        [
          'Div: ${fmt.format(income)}${es ? '/año' : '/yr'}',
          if (yieldPct != null) formatPercent(context, yieldPct, digits: 2),
          if (next != null && next.isNotEmpty) '${es ? 'próx.' : 'next'} ~$next',
        ].join('  ·  '),
        style: TextStyle(
            fontSize: 11,
            color: context.tealAccent,
            fontFeatures: const [FontFeature.tabularFigures()]),
      ),
    );
  }

  Widget _holdingRow(dynamic h, NumberFormat fmt, bool es) {
    final l = AppLocalizations.of(context);
    final symbol = (h['symbol'] ?? '').toString();
    final qty = (h['quantity'] is num)
        ? (h['quantity'] as num).toDouble()
        : double.tryParse('${h['quantity']}') ?? 0;
    final price = (h['price'] is num)
        ? (h['price'] as num).toDouble()
        : double.tryParse('${h['price'] ?? ''}');
    final value = (h['value'] is num)
        ? (h['value'] as num).toDouble()
        : double.tryParse('${h['value'] ?? ''}');
    final qtyStr =
        qty == qty.roundToDouble() ? qty.toStringAsFixed(0) : qty.toStringAsFixed(2);
    // A5 (round 3, a11y): the row's facts read as ONE sentence — "VOO, 10
    // shares, $5,085.80, dividend $66.00 per year" — while the delete X
    // stays its own "Remove VOO" button node OUTSIDE the merge.
    final divIncome =
        ((_dividends[symbol]?['annual_income']) as num?)?.toDouble() ?? 0.0;
    final rowLabel = [
      symbol,
      '$qtyStr ${es ? 'acciones' : 'shares'}',
      value != null ? fmt.format(value) : (es ? 'sin precio' : 'no price'),
      if (divIncome > 0) l.axDividendPerYear(fmt.format(divIncome)),
    ].join(', ');
    return Padding(
      padding: const EdgeInsets.only(top: 8, right: 0),
      child: Row(
        children: [
          Expanded(
            child: Semantics(
              container: true,
              label: rowLabel,
              excludeSemantics: true,
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(symbol,
                            style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: context.textPrimary)),
                        Text(
                          '$qtyStr ${es ? 'acciones' : 'shares'}'
                          '${price != null ? ' · ${fmt.format(price)}' : ''}',
                          style: TextStyle(
                              fontSize: 11.5,
                              color: context.textSubtle,
                              fontFeatures: const [
                                FontFeature.tabularFigures()
                              ]),
                        ),
                        _dividendLine(symbol, fmt, es),
                      ],
                    ),
                  ),
                  Text(
                    value != null
                        ? fmt.format(value)
                        : (es ? 'sin precio' : 'no price'),
                    style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: value != null
                            ? context.textPrimary
                            : context.warning,
                        fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
            ),
          ),
          if (_isManualAccount)
            IconButton(
              icon: Icon(Icons.close, size: 15, color: context.textFaint),
              visualDensity: VisualDensity.compact,
              // A5 (round 3, a11y): names its holding — the tooltip is the
              // button's accessible label on web, and a bare "Remove" is
              // ambiguous in a list of rows.
              tooltip: l.axRemoveHolding(symbol),
              onPressed: () => _deleteHolding(h),
            ),
        ],
      ),
    );
  }

  /// Deleting a holding takes its `holding_lots` and `lot_disposals`
  /// (realized-gain tax records) with it, so it must NEVER fire without an
  /// explicit, destructive-styled confirmation. Cancel / Esc / outside-tap
  /// all resolve to "keep it". Round 3 (contract C3-B/C3-E): the backend
  /// delete is now a soft delete, and a 10-second UNDO snackbar follows a
  /// confirmed delete. The snackbar shows on the panel's own nested
  /// messenger (above the panel route — the root messenger is covered by
  /// it); everything the undo needs is captured in a [_PendingHoldingUndo]
  /// that never touches this State, so [dispose] can migrate a live
  /// countdown to the root messenger and the restore keeps working after
  /// the panel is closed.
  Future<void> _deleteHolding(dynamic h) async {
    final l = AppLocalizations.of(context);
    // Both messengers are captured BEFORE any await: the panel messenger
    // hosts the snackbar while the panel is open; the root messenger goes
    // into the pending undo so [dispose] can re-home the countdown.
    final rootMessenger = ScaffoldMessenger.of(context);
    final panelMessenger = _panelMessengerKey.currentState ?? rootMessenger;
    final apiService = _apiService;
    final accountId = _accountId;
    final holdingId = (h['id'] ?? '').toString();
    final symbol = (h['symbol'] ?? '').toString().trim();
    final name = (h['name'] ?? '').toString().trim();
    final label = symbol.isNotEmpty ? symbol : name;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        title: Text(l.acctDeleteHoldingTitle(label)),
        content: Text(
          // Softened round-3 copy: still spells out what goes (holding,
          // lots, tax records) but announces the undo window instead of
          // the old "cannot be undone".
          '${l.acct3DeleteHoldingBody} ${l.acct3UndoHint}',
          style: TextStyle(color: context.textMuted, fontSize: 13),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: context.negative),
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.acctDeleteHoldingConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true) return; // cancel/dismiss → nothing is called
    try {
      await (widget.holdingDeleter ?? apiService.deleteHolding)(
          accountId, holdingId);
    } catch (_) {
      return; // best-effort, same policy as before the undo flow
    }
    if (mounted) {
      // Round-2 A1 plumbing: refreshes rows, header value, est-income and
      // `onBalanceUpdate` toward the dashboard.
      _fetchHoldings(syncBalance: true);
      _fetchBalanceHistory();
    }
    final pending = _PendingHoldingUndo(
      rootMessenger: rootMessenger,
      restore: widget.holdingRestorer ?? apiService.restoreHolding,
      fetchHoldings:
          widget.holdingsFetcher ?? apiService.getAccountHoldings,
      onBalanceUpdate: widget.onBalanceUpdate,
      accountId: accountId,
      holdingId: holdingId,
      deletedText: l.acct3DeletedSnack(label),
      undoText: l.acct3Undo,
      restoreGoneText: l.acct3RestoreGone,
      restoreFailedText: l.acct3RestoreFailed,
      expiresAt: DateTime.now().add(_undoWindow),
    );
    _pendingUndo = pending;
    _showUndoSnackBar(panelMessenger, pending, _undoWindow);
  }

  static const Duration _undoWindow = Duration(seconds: 10);

  /// Shows (or, from [dispose], re-shows on the root messenger) the undo
  /// snackbar for [pending] with [duration] left on its countdown.
  void _showUndoSnackBar(ScaffoldMessengerState messenger,
      _PendingHoldingUndo pending, Duration duration) {
    // One undo window at a time: a second delete replaces the previous
    // snackbar instead of queueing behind its 10-second run.
    messenger.hideCurrentSnackBar();
    final controller = messenger.showSnackBar(
      SnackBar(
        duration: duration,
        content: Text(pending.deletedText),
        action: SnackBarAction(
          label: pending.undoText,
          onPressed: () =>
              _undoDeleteHolding(messenger: messenger, pending: pending),
        ),
      ),
    );
    // Timeout/dismissal ends the undo window. When the panel is being
    // torn down instead, [dispose] already took ownership of
    // `_pendingUndo` (nulled it), so this identical-check is a no-op and
    // the re-homed root snackbar keeps counting.
    controller.closed.then((_) {
      if (identical(_pendingUndo, pending)) _pendingUndo = null;
    });
  }

  /// UNDO handler for [_deleteHolding]'s snackbar. Deliberately
  /// parameterized on the captured messenger + [_PendingHoldingUndo] —
  /// never on `context` — because the panel may already be closed when the
  /// user taps UNDO (the snackbar then lives on the root messenger); only
  /// the in-panel refresh is `mounted`-gated, and the dashboard refresh
  /// runs off the captured callbacks either way. A 404 (typed
  /// [HoldingRestoreGoneException]) means the soft-deleted row was already
  /// purged — the deletion is permanent and the snackbar says so.
  Future<void> _undoDeleteHolding({
    required ScaffoldMessengerState messenger,
    required _PendingHoldingUndo pending,
  }) async {
    try {
      await pending.restore(pending.accountId, pending.holdingId);
      // Tapping the SnackBarAction already dismissed the undo snackbar;
      // this is belt-and-braces for programmatic invocations.
      messenger.hideCurrentSnackBar();
      if (mounted) {
        // Panel still open: full in-panel refresh — rows, header value,
        // est. income; `syncBalance` also pushes `onBalanceUpdate` toward
        // the dashboard.
        _fetchHoldings(syncBalance: true);
        _fetchBalanceHistory();
      } else {
        // Round 3 (stale-balance fix): the panel closed during the
        // countdown, so no State is left to refresh — push the restored
        // account balance straight to the dashboard (Overview accounts
        // list + net worth) using only what the undo captured.
        await pending.pushBalanceToDashboard();
      }
    } on HoldingRestoreGoneException {
      messenger.hideCurrentSnackBar();
      messenger
          .showSnackBar(SnackBar(content: Text(pending.restoreGoneText)));
    } catch (_) {
      messenger
          .showSnackBar(SnackBar(content: Text(pending.restoreFailedText)));
    }
  }

  Widget _buildBody() {
    final l = AppLocalizations.of(context);
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: context.negative),
            const SizedBox(height: 16),
            Text(
              l.acctxLoadError(_error!),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _fetchTransactions,
              child: Text(l.acctxRetry),
            ),
          ],
        ),
      );
    }

    if (_transactions == null || _transactions!.isEmpty) {
      // An investment account (e.g. a manual stock-plan / NetBenefits position)
      // may hold shares but have no cash transactions — show the holdings view
      // instead of a bare "no transactions" message.
      if (_isInvestment) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(24, 8, 16, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [_buildHoldings('USD')],
          ),
        );
      }
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long, size: 64, color: context.textFaint),
            const SizedBox(height: 16),
            Text(
              l.acctxNoTransactionsTitle,
              style: TextStyle(fontSize: 16, color: context.textSubtle),
            ),
            const SizedBox(height: 8),
            Text(
              l.acctxNoTransactionsBody,
              style: TextStyle(color: context.textFaint, fontSize: 12),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            // With zero rows the TransactionsTab (and its toolbar's "+")
            // never mounts, so the empty state carries its own entry
            // point — otherwise an empty account is the one place a
            // manual transaction can't be added from.
            FilledButton.icon(
              onPressed: _openAddTransactionDialog,
              icon: const Icon(Icons.add, size: 18),
              label: Text(l.txAddTransaction),
            ),
          ],
        ),
      );
    }

    final sourceCurrency =
        (widget.account['currency'] ?? widget.targetCurrency).toString();
    return Padding(
      // Left inset matches the header's 24px so the CLABE card + transaction
      // list line up with the account name/balance above (was 16 → an 8px
      // step-in that read as misaligned).
      padding: const EdgeInsets.fromLTRB(24, 8, 16, 16),
      // The builder param is deliberately NOT named `context`: the
      // TransactionsTab callbacks below capture the State's own context
      // (guarded by this State's `mounted`), and shadowing it with the
      // LayoutBuilder's would break that pairing.
      child: LayoutBuilder(builder: (_, constraints) {
        // Everything that sits ABOVE the transactions list (CLABE card,
        // balance chart, holdings). These used to be fixed Column children:
        // on an investment account with a screenful of holdings they
        // consumed the whole panel, squeezing the Expanded transactions
        // list to ~zero height — its rows became unreachable, and a mouse
        // wheel anywhere over this content found no scrollable to act on
        // (only the inner list's drag-scrollbar did anything). Capping the
        // block and giving it its own scroll view guarantees the list
        // keeps real height AND makes wheel/trackpad scrolling work over
        // the holdings/chart region.
        final preList = <Widget>[
          if ((widget.account['clabe'] ?? '').toString().isNotEmpty) ...[
            ClabeInfoCard(
              clabe: widget.account['clabe'].toString(),
              holder: widget.account['holder_name']?.toString(),
            ),
            const SizedBox(height: 12),
          ],
          if (_balanceHistory.length >= 2) ...[
            AccountBalanceChart(
              points: _balanceHistory,
              currency: sourceCurrency,
            ),
            const SizedBox(height: 12),
          ],
          if (_isInvestment && _holdings.isNotEmpty) ...[
            _buildHoldings('USD'),
            const SizedBox(height: 12),
          ],
        ];
        // Leave the transactions list at least ~300px whenever the panel
        // is tall enough; on very short panels fall back to a 35/65 split
        // (clamp bounds stay ordered because 0.35·h ≤ h always).
        final bodyHeight = constraints.maxHeight;
        final preListCap = bodyHeight.isFinite
            ? (bodyHeight - 300.0).clamp(bodyHeight * 0.35, bodyHeight)
            : double.infinity;
        return Column(
          children: [
            if (preList.isNotEmpty)
              ConstrainedBox(
                constraints: BoxConstraints(maxHeight: preListCap),
                child: SingleChildScrollView(
                  child: Column(children: preList),
                ),
              ),
            Expanded(
            child: TransactionsTab(
              transactions: _transactions!,
              accounts: widget.allAccounts,
              conversionFactor: widget.conversionFactor,
              currencyFormat: widget.currencyFormat,
              targetCurrency: widget.targetCurrency,
              usdMxnRate: widget.usdMxnRate,
              // Full action set, mirroring the dashboard's wiring (same
              // ApiService calls, one in-place refetch per mutation).
              // apiService unlocks "+ Add transaction" + CSV export;
              // the Add dialog opens preselected on THIS account, and
              // CSV always confirms because the export covers every
              // account while the panel shows just one.
              apiService: _apiService,
              addTransactionAccountId: _accountId,
              csvExportConfirmAlways: true,
              // Single-account host: drop the redundant per-row account
              // name and show a running "balance after this transaction"
              // instead. The anchor is the panel header's own native-
              // currency balance, so estimates and header always agree.
              singleAccountContext: true,
              runningBalanceAnchor: _currentBalance,
              onTransactionAdded: () {
                _refetchTransactionsInPlace();
                _fetchBalanceHistory();
              },
              onLoadMore: _loadMoreTransactions,
              hasMore: _hasMore,
              onUpdate: (id,
                  {userCategory, userNotes, userDescription, accountId}) async {
                try {
                  final AccountTransactionUpdater update =
                      widget.transactionUpdater ?? _apiService.updateTransaction;
                  await update(
                    id,
                    userCategory: userCategory,
                    userNotes: userNotes,
                    userDescription: userDescription,
                    accountId: accountId,
                  );
                  await _refetchTransactionsInPlace();
                } catch (e) {
                  if (!mounted) return;
                  // Panel messenger, not root: a root snackbar would be
                  // hidden behind this panel route (see build()).
                  _messenger.showSnackBar(
                    SnackBar(content: Text(l.acctxUpdateFailed(e.toString()))),
                  );
                }
              },
              onBulkUpdate: (ids,
                  {userCategory, accountId, userDescription}) async {
                // One batched request → one in-place refresh, exactly like
                // the dashboard (the old panel omitted this, leaving the
                // bulk bar half-functional).
                final n = await _apiService.batchUpdateTransactions(
                  ids,
                  category: userCategory,
                  accountId: accountId,
                  description: userDescription,
                );
                await _refetchTransactionsInPlace();
                return n;
              },
              onBulkDelete: (ids) async {
                for (final id in ids) {
                  await _apiService.deleteTransaction(id);
                }
                await _refetchTransactionsInPlace();
                _fetchBalanceHistory();
              },
              onDelete: (id) async {
                await _apiService.deleteTransaction(id);
                await _refetchTransactionsInPlace();
                _fetchBalanceHistory();
              },
              onSplitTransaction: (parentId, splits) async {
                await _apiService.splitTransaction(parentId, splits);
                await _refetchTransactionsInPlace();
              },
              onUnsplitTransaction: (parentId) async {
                await _apiService.unsplitTransaction(parentId);
                await _refetchTransactionsInPlace();
              },
              onReplaceSplits: (parentId, splits) async {
                await _apiService.replaceSplits(parentId, splits);
                await _refetchTransactionsInPlace();
              },
            ),
            ),
          ],
        );
      }),
    );
  }
}

/// Everything a delete-undo needs to keep working after the panel State is
/// gone: the ROOT messenger (for [_AccountTransactionsScreenState.dispose]
/// to re-home the countdown), the restore + holdings calls, the dashboard
/// balance callback, and pre-localized snackbar strings. Holds NO
/// BuildContext and nothing owned by the State.
class _PendingHoldingUndo {
  _PendingHoldingUndo({
    required this.rootMessenger,
    required this.restore,
    required this.fetchHoldings,
    required this.onBalanceUpdate,
    required this.accountId,
    required this.holdingId,
    required this.deletedText,
    required this.undoText,
    required this.restoreGoneText,
    required this.restoreFailedText,
    required this.expiresAt,
  });

  final ScaffoldMessengerState rootMessenger;
  final AccountHoldingRestorer restore;
  final AccountHoldingsFetcher fetchHoldings;
  final Function(String, double)? onBalanceUpdate;
  final String accountId;
  final String holdingId;
  final String deletedText;
  final String undoText;
  final String restoreGoneText;
  final String restoreFailedText;
  /// End of the undo window — [dispose] only re-homes a countdown that
  /// still has time left.
  final DateTime expiresAt;

  /// Post-restore dashboard refresh for the panel-already-closed case:
  /// re-derives the account balance the way the backend's
  /// `recompute_holding_balance` does (Σ holding values — deletes only
  /// exist on manual investment accounts, cf. `_syncBalanceFromHoldings`)
  /// and pushes it through the captured `onBalanceUpdate` so the Overview
  /// accounts list and net worth reflect the restore immediately.
  Future<void> pushBalanceToDashboard() async {
    final notify = onBalanceUpdate;
    if (notify == null) return;
    try {
      final holdings = await fetchHoldings(accountId);
      double total = 0;
      for (final h in holdings) {
        total += (h['value'] is num)
            ? (h['value'] as num).toDouble()
            : double.tryParse('${h['value'] ?? ''}') ?? 0;
      }
      notify(accountId, total);
    } catch (_) {/* best-effort, like every other balance sync */}
  }
}

/// Desktop-friendly scroll behavior for the account panel ONLY: on top of
/// wheel/trackpad scrolling (which scrollables get for free), allow
/// click-drag scrolling with a mouse/trackpad — the panel is the one place
/// the app stacks several scroll regions in a tight column, so every
/// pointer gesture should move content. Scoped to the panel via the
/// [ScrollConfiguration] below; the rest of the app keeps the default
/// behavior.
class _PanelScrollBehavior extends MaterialScrollBehavior {
  const _PanelScrollBehavior();

  @override
  Set<PointerDeviceKind> get dragDevices => {
        ...super.dragDevices,
        PointerDeviceKind.mouse,
        PointerDeviceKind.trackpad,
      };
}

/// Slide-from-right side panel that shows transactions for one account.
/// On narrow viewports this falls back to a bottom sheet.
Future<void> showAccountTransactionsPanel(
  BuildContext context, {
  required Map<String, dynamic> account,
  List<dynamic> allAccounts = const [],
  required double conversionFactor,
  required NumberFormat currencyFormat,
  required String targetCurrency,
  required double usdMxnRate,
  Function(String, double)? onBalanceUpdate,
  Future<void> Function(String, String)? onRenameAccount,
  VoidCallback? onAlertsChanged,
}) {
  final size = MediaQuery.sizeOf(context);
  final isNarrow = size.width < 700;

  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: AppLocalizations.of(context).acctxDismissBarrier,
    barrierColor: Colors.black.withValues(alpha: 0.4),
    transitionDuration: const Duration(milliseconds: 220),
    pageBuilder: (ctx, anim, secAnim) {
      return Align(
        alignment:
            isNarrow ? Alignment.bottomCenter : Alignment.centerRight,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: isNarrow ? size.width : 560,
            height: isNarrow ? size.height * 0.92 : size.height,
            decoration: BoxDecoration(
              // Theme-aware surface (white in light, charcoal in dark) so the
              // onSurface-derived text tokens keep their contrast. Was a
              // hardcoded dark (#15151E) — dark-on-dark in light mode.
              color: Theme.of(ctx).colorScheme.surface,
              borderRadius: isNarrow
                  ? const BorderRadius.vertical(top: Radius.circular(20))
                  : const BorderRadius.horizontal(left: Radius.circular(20)),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(
                      alpha: Theme.of(ctx).brightness == Brightness.dark
                          ? 0.4
                          : 0.18),
                  blurRadius: 24,
                  offset: const Offset(-4, 0),
                ),
              ],
            ),
            child: ScrollConfiguration(
              behavior: const _PanelScrollBehavior(),
              child: AccountTransactionsScreen(
                account: account,
                allAccounts: allAccounts,
                conversionFactor: conversionFactor,
                currencyFormat: currencyFormat,
                targetCurrency: targetCurrency,
                usdMxnRate: usdMxnRate,
                onBalanceUpdate: onBalanceUpdate,
                onRenameAccount: onRenameAccount,
                onAlertsChanged: onAlertsChanged,
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
