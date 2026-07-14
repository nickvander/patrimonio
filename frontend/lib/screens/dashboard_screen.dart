import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:patrimonio/screens/tax_planning_screen.dart';
import 'package:plaid_flutter/plaid_flutter.dart';

import '../components/allocation_heatmap.dart';
import '../components/date_range_selector.dart';
import '../components/trends_chart.dart';
import '../l10n/app_localizations.dart';
import '../main.dart' show themeModeNotifier;
import '../services/api_service.dart';
import '../services/auth_service.dart';
import '../services/backend_config.dart';
import '../services/plaid_oauth.dart';
import '../services/preferences.dart';
import '../services/realtime_service.dart';
import '../services/transaction_mutation_refresh.dart';
import '../theme/palette.dart';
import '../theme/typography.dart';
import '../utils/account_category.dart';
import '../utils/app_locale.dart';
import '../utils/bar_scroll.dart';
import '../utils/currency.dart';
import '../utils/lending_summary.dart'
    show sumLoansConverted, loansAreMixedCurrency;
import '../utils/percent_format.dart';
import '../utils/supported_banks.dart';
import '../utils/sync_progress.dart';
import '../utils/theme_colors.dart';
import '../utils/transaction_display.dart';
import '../utils/url_opener.dart';
import '../utils/web_env.dart';
import '../widgets/accounts_list_widget.dart';
import '../widgets/add_account_dialog.dart';
import '../widgets/add_crypto_dialog.dart';
import '../widgets/assets_liabilities_bar.dart';
import '../widgets/budgets_card.dart';
import '../widgets/command_palette.dart';
import '../widgets/credit_utilization_card.dart';
import '../widgets/cross_currency_transfers_card.dart';
import '../widgets/debt_payoff_card.dart';
import '../widgets/emergency_fund_card.dart';
import '../widgets/fx_widget.dart';
import '../widgets/lending_tab.dart';
import '../widgets/monthly_cash_flow_card.dart';
import '../widgets/net_worth_card.dart';
import '../widgets/net_worth_goal_tile.dart';
import '../widgets/notifications_panel.dart';
import '../widgets/performance_card.dart';
import '../widgets/portfolio_card.dart';
import '../widgets/realized_gains_card.dart';
import '../widgets/rebalancing_card.dart';
import '../widgets/since_last_login_banner.dart';
import '../widgets/skeleton.dart';
import '../widgets/spending_by_category_card.dart';
import '../widgets/subscriptions_card.dart';
import '../widgets/sync_error_banner.dart';
import '../widgets/sync_status_card.dart';
import '../widgets/transactions_tab.dart';
import '../widgets/upcoming_bills_card.dart';
import 'account_transactions_screen.dart';
import 'connect_bank_screen.dart';
import 'hidden_items_screen.dart';
import 'import_cleanup_screen.dart';
import 'import_screen.dart';
import 'security_screen.dart';
import 'wealth_projection_screen.dart';

/// Stable identity for each top-level section. Navigation, persistence,
/// deep-jumps and the command palette all key off these ids rather than a
/// raw index, so reordering sections or toggling the conditional Lending
/// section can never send the user to the wrong place.
enum NavId {
  overview,
  portfolio,
  transactions,
  cashFlow,
  projections,
  tax,
  lending,
  settings,
}

/// Primary = daily-use, shown directly in the rail / bottom bar.
/// Secondary = occasional, grouped under "More" (and in the rail's lower
/// group). Settings is secondary but always pinned last.
enum NavTier { primary, secondary }

class _NavDest {
  final NavId id;
  final String label; // full label (rail, palette, More sheet)
  final String shortLabel; // compact label for the bottom bar
  final IconData icon;
  // Brightness-resolved accent: a static `BrandPalette` tearoff, so the
  // selected icon/label picks the AA-passing shade for the active theme
  // (the const neon hexes failed contrast on the light rail surface).
  final Color Function(Brightness) accent;
  final NavTier tier;
  const _NavDest(
    this.id,
    this.label,
    this.shortLabel,
    this.icon,
    this.accent,
    this.tier,
  );
}

/// Period the Cash Flow tab's headline cards summarize. Drives a
/// calendar-month window passed to the trends endpoint:
///   thisMonth   -> 1 month  (current)
///   lastMonth   -> 2 months (so the prior month + a vs-comparison are present)
///   threeMonths -> 3 months (aggregated)
///   ytd         -> Jan..current of this year (aggregated)
enum CashFlowPeriod { thisMonth, lastMonth, threeMonths, ytd }

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen> {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  String? _error;

  Map<String, dynamic>? _overview;
  List<dynamic>? _netWorthHistory;
  Map<String, dynamic>? _portfolioData;
  List<dynamic>? _creditData;
  List<dynamic>? _syncData;
  // Sync-error banner snooze: institution ids the user dismissed + until
  // when, persisted in app settings so a known-flaky institution (e.g. one
  // Plaid keeps 500-ing) doesn't nag on every load. A NEW failure re-shows.
  Set<String> _syncBannerSnoozeIds = const {};
  DateTime? _syncBannerSnoozeUntil;
  // The lender's full name for loan agreements (app setting 'lender_name').
  final _lenderNameCtrl = TextEditingController();
  bool _savingLenderName = false;
  // Drives the "refresh while a newly-linked institution is still syncing"
  // backstop (see _scheduleSyncPollIfNeeded). Bounded by _syncPollAttempts.
  Timer? _syncPollTimer;
  int _syncPollAttempts = 0;
  // True while a manual "Sync all accounts" is in flight — drives the inline
  // spinner on the Settings sync button (instead of a blocking SnackBar).
  bool _isSyncing = false;
  // Live progress for the in-flight sync: how many syncable institutions have
  // finished vs the total. Polled from /sync-status while the batch runs so
  // the button shows "Updating… (3 of 7)" and the SyncStatusCard live-updates.
  int _syncDone = 0;
  int _syncTotal = 0;
  Map<String, dynamic>? _setupStatus;
  // When every required check passes, the Launch-setup card collapses to a
  // single "Ready" summary row; this tracks whether the user has expanded it
  // to see the full diagnostic list. When a required check is missing the
  // card is force-expanded regardless (warnings must stay visible).
  bool _setupExpanded = false;
  Map<String, dynamic>? _fxRate;
  List<dynamic>? _transactions;
  List<AllocationData>? _allocationData;
  List<Map<String, dynamic>>? _trendData;
  // Cash Flow tab period selector. [_cashFlowPeriod] is the user's choice;
  // [_cashFlowTrends] is the period-specific series fetched on change. While
  // null (the user hasn't touched the selector) the tab falls back to the
  // shared 12-month [_trendData] and the card shows the latest month — i.e.
  // the historical behavior is unchanged until the user opts into a window.
  CashFlowPeriod _cashFlowPeriod = CashFlowPeriod.thisMonth;
  List<Map<String, dynamic>>? _cashFlowTrends;
  bool _cashFlowLoading = false;
  Map<String, dynamic>? _sinceLastLogin;
  List<dynamic>? _subscriptions;
  List<dynamic>? _ignoredSubscriptions;
  // Accounts the sync auto-archived (closed at the bank — Plaid stopped
  // returning them). Surfaced as a notification so the user can restore or
  // remove them. Best-effort: null when the fetch fails — the bell just omits
  // the archived-account rows.
  List<dynamic>? _archivedAccounts;
  // Per-category MoM-vs-trailing-average spend deltas (spending-insight
  // notifications). Best-effort: null when the fetch fails — the bell just
  // omits the spending-up rows.
  Map<String, dynamic>? _spendingInsights;
  // Opt-in personal-lending module. Server-side per-user setting
  // (app_settings 'lending_enabled'), fetched in _loadAllData. When
  // true, a "Lending" section is inserted into [_destinations] (between
  // Tax planning and Settings). No controller juggling — the section
  // list is just recomputed.
  bool _lendingEnabled = true; // on by default; user can opt out in Settings
  // Upcoming + overdue loan installments for the notifications bell.
  List<dynamic> _loanReminders = const [];
  // Active + closed loans, for the Overview "Lending" glance card. Best-effort:
  // empty when lending is off or the fetch fails — the glance card just hides.
  List<dynamic> _loans = const [];
  // Per-account low-balance thresholds (account id -> native-currency amount),
  // for the notifications bell. Seeded from localStorage, hydrated from backend.
  Map<String, double> _accountAlerts = const {};
  // Notification ids the user has marked as read — the bell badge only lights
  // for ids not in this set. Persisted in localStorage so it survives refresh.
  Set<String> _dismissedNotifs = const {};
  // Whether the mobile Overview "Details" disclosure (stat strip, goal,
  // emergency fund) is expanded. Collapsed by default for a calm Glance view;
  // remembered across visits via Preferences.
  bool _overviewDetailsExpanded = false;
  // Whether the mobile Settings "Connections & sync" disclosure (sync-all,
  // sync-status, FX, modules) is expanded. Collapsed by default so the phone
  // Settings view leads with data sources; remembered across visits.
  bool _managementDetailsExpanded = false;
  // Whether the Management-tab "Auto-archived accounts" section is expanded.
  // Collapsed by default — it's a recovery affordance, not a daily-use list.
  bool _archivedSectionExpanded = false;
  // Scroll-away app bar (compact, non-first-run only): whether the top bar is
  // currently shown. Driven by bubbling UserScrollNotifications through
  // utils/bar_scroll.dart — enter-always + snap semantics. Only flips on
  // scroll-direction changes, never per scrolled pixel.
  bool _appBarVisible = true;
  // Configurable reminder lead time (days before due). Server-stored
  // (app_settings 'lending_reminder_lead_days'), surfaced in the
  // Management-tab Modules card.
  int _lendingReminderLeadDays = 7;
  List<dynamic>? _fxTransfers;
  // Pending date-window seed from a chart-bar tap. When non-null, the
  // TransactionsTab seeds its filters with a custom date range covering
  // the picked month, then clears the override so manual filter edits
  // aren't overwritten on the next dashboard rebuild.
  ({DateTime start, DateTime end})? _txDateSeed;
  DateRange _selectedRange = DateRange.oneYear;
  String _targetCurrency = 'USD'; // Master currency state
  // Active section: an index into [_destinations]. Replaces the old
  // TabController/TabBar. Persisted by NavId name (see _selectSection /
  // initState) so it survives reorders and the conditional Lending
  // section, the same way the date-range pref is stored.
  int _section = 0;
  // Saved section to restore once the lending flag is known (the first
  // _loadAllData resolves it, since Lending may not be in _destinations
  // until then). Cleared after the first apply.
  NavId? _pendingRestore;
  // Sections the user has actually opened. The IndexedStack only mounts
  // these — unvisited sections render as a cheap placeholder, so their
  // one-shot initState fetches (Tax / Projections / Lending) don't fire on
  // boot, and their (chart-heavy) trees aren't built/laid out until first
  // visit. Once visited, a section stays mounted + kept-alive.
  final Set<NavId> _visitedSections = {};
  // Category that the AllocationHeatmap is currently drilled into. When
  // non-null, the PortfolioCard's holdings table filters to that category.
  String? _portfolioCategoryFilter;
  // Anchors the holdings-table card on the Portfolio tab so a heatmap
  // band tap can scroll the (below-the-fold) filtered table into view.
  final GlobalKey _holdingsTableKey = GlobalKey();
  // Anchors the Portfolio tab's DividendIncomeCard so the Overview
  // "Dividends/yr" tile tap can section-switch + ensureVisible it (O1;
  // same pattern as _holdingsTableKey above).
  final GlobalKey _dividendCardKey = GlobalKey();
  // Reaches into the Activity tab's state so the compact-layout FAB
  // (thumb-zone "Add transaction", docked above the bottom nav) can open
  // the same Add-transaction dialog the toolbar '+' does on wide layouts.
  final GlobalKey<TransactionsTabState> _txTabKey =
      GlobalKey<TransactionsTabState>();
  // Portfolio-wide dividend summary (projected annual income + blended
  // yield), fetched best-effort alongside the other overview loads. null
  // (failure) or zero income simply hides the Overview dividends tile.
  Map<String, dynamic>? _portfolioDividends;
  // Cmd-K deep-link search overrides — set by the palette callbacks so
  // the target tab pre-filters to the picked row. They're cleared on
  // any user-driven search change in the target widget.
  String? _portfolioSearchOverride;
  String? _transactionsSearchOverride;
  // Cmd-K row highlight target. Cleared automatically ~2s after being
  // set so the pulse fades back to the normal row chrome.
  String? _highlightedTxId;
  // Pagination — the API returns at most 50 transactions per call. We
  // track whether the latest page filled the limit (so there may be more)
  // and call _loadMoreTransactions() to append the next slice.
  static const int _txPageSize = 50;
  bool _transactionsHasMore = true;

  /// Realtime push channel. Connected at boot, disposed on screen
  /// teardown. Self-reconnects on drop; coarse server-pushed
  /// events trigger a silent _loadAllData refresh.
  final RealtimeService _realtime = RealtimeService();
  StreamSubscription<RealtimeEvent>? _realtimeSub;
  // PlaidLink exposes broadcast streams; each `.listen` adds a subscription
  // that lives forever unless cancelled. Re-listening on every (re)connect
  // leaked listeners — after N reconnects a single Plaid success fired N
  // syncs. Track them so we can cancel before re-listening and on dispose.
  final List<StreamSubscription<dynamic>> _plaidSubs = [];
  // Coalesces bursty data-change pushes into a single dashboard reload.
  Timer? _reloadDebounce;

  @override
  void initState() {
    super.initState();
    // Restore previously selected reporting currency + tab + chart range
    // from localStorage so a refresh doesn't reset the user's context.
    _targetCurrency = _loadSavedCurrency();
    final savedRange = Preferences.getDateRange();
    if (savedRange != null) {
      for (final r in DateRange.values) {
        if (r.name == savedRange) {
          _selectedRange = r;
          break;
        }
      }
    }
    // Lending section is unknown until the setting loads. Remember the
    // saved section id; the first _loadAllData resolves it to an index
    // once _destinations is final (so a saved "Lending" lands correctly).
    _pendingRestore = _navIdFromName(Preferences.getLastSection());
    _section = _indexOfNav(_pendingRestore) ?? 0;
    // Low-balance alert thresholds: instant from localStorage, then reconcile
    // with the backend setting (source of truth across devices).
    _accountAlerts = Preferences.getAccountAlerts();
    _hydrateAccountAlerts();
    _loadSyncBannerSnooze();
    _loadLenderName();
    _dismissedNotifs = Preferences.getDismissedNotifications();
    _overviewDetailsExpanded = Preferences.getOverviewDetailsExpanded();
    _managementDetailsExpanded = Preferences.getManagementDetailsExpanded();
    _loadAllData();
    _checkRedirectStatus();
    _resumePlaidOAuthIfNeeded();
    // Open the realtime channel and route server-pushed
    // invalidations into the existing silent-reload path. The
    // service self-reconnects on drop, so we connect once at boot
    // and forget until logout.
    _realtime.connect();
    _realtimeSub = _realtime.events.listen(_handleRealtimeEvent);
  }

  // Pull low-balance thresholds from the backend setting and merge over the
  // localStorage seed so the bell reflects changes made on other devices.
  Future<void> _hydrateAccountAlerts() async {
    try {
      final raw = await _apiService.getSetting('account_balance_alerts');
      if (!mounted || raw is! Map) return;
      final next = <String, double>{};
      raw.forEach((k, v) {
        final d = v is num ? v.toDouble() : double.tryParse('$v');
        if (d != null && d > 0) next[k.toString()] = d;
      });
      setState(() => _accountAlerts = next);
      Preferences.setAccountAlerts(next);
    } catch (_) {
      // localStorage seed stands.
    }
  }

  // Re-read thresholds from localStorage after the account panel saves one, so
  // the notifications bell reflects the change without a full reload.
  void _reloadAccountAlerts() {
    if (mounted) setState(() => _accountAlerts = Preferences.getAccountAlerts());
  }

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _syncPollTimer?.cancel();
    _realtimeSub?.cancel();
    _cancelPlaidSubs();
    _realtime.dispose();
    _lenderNameCtrl.dispose();
    super.dispose();
  }

  /// Cancel any live PlaidLink subscriptions. Called before re-listening (so a
  /// new connect/reconnect doesn't stack a second handler onto the broadcast
  /// stream) and on dispose.
  void _cancelPlaidSubs() {
    for (final s in _plaidSubs) {
      s.cancel();
    }
    _plaidSubs.clear();
  }

  /// Register PlaidLink success/exit handlers, replacing any previous ones.
  void _listenPlaid(
    void Function(LinkSuccess) onSuccess,
    void Function(LinkExit) onExit,
  ) {
    _cancelPlaidSubs();
    _plaidSubs.add(PlaidLink.onSuccess.listen(onSuccess));
    _plaidSubs.add(PlaidLink.onExit.listen(onExit));
  }

  /// Canonical section catalog, in display order. Lending sits between
  /// Tax planning and Settings; Settings is always last. The accents are
  /// the same brand hues the old tab list + palette used.
  static const List<_NavDest> _allDestinations = [
    _NavDest(NavId.overview, 'Overview', 'Home', Icons.dashboard_outlined,
        BrandPalette.positive, NavTier.primary),
    _NavDest(NavId.portfolio, 'Portfolio', 'Invest', Icons.pie_chart_outline,
        BrandPalette.teal, NavTier.primary),
    _NavDest(NavId.transactions, 'Transactions', 'Activity',
        Icons.receipt_long_outlined, BrandPalette.info, NavTier.primary),
    _NavDest(NavId.cashFlow, 'Cash flow', 'Cash',
        Icons.account_balance_wallet_outlined, BrandPalette.teal,
        NavTier.primary),
    _NavDest(NavId.projections, 'Projections', 'Proj.',
        Icons.trending_up_outlined, BrandPalette.warning, NavTier.secondary),
    _NavDest(NavId.tax, 'Tax planning', 'Tax', Icons.account_balance_outlined,
        BrandPalette.purple, NavTier.secondary),
    _NavDest(NavId.lending, 'Lending', 'Loans', Icons.monetization_on,
        BrandPalette.teal, NavTier.secondary),
    _NavDest(NavId.settings, 'Settings', 'Settings', Icons.settings_outlined,
        BrandPalette.neutral, NavTier.secondary),
  ];

  /// The currently-visible sections. Lending is filtered out unless the
  /// module is enabled; everything else is always present.
  List<_NavDest> get _destinations => [
        for (final d in _allDestinations)
          if (d.id != NavId.lending || _lendingEnabled) d,
      ];

  /// The destination currently on screen. Guarded: `_section` can briefly
  /// point past the list while destinations change (lending toggling off).
  _NavDest get _currentDest {
    final dests = _destinations;
    return (_section >= 0 && _section < dests.length)
        ? dests[_section]
        : dests.first;
  }

  /// Localized full label for a section (rail, More sheet, palette).
  String _navLabel(AppLocalizations l, NavId id) {
    switch (id) {
      case NavId.overview:
        return l.navOverview;
      case NavId.portfolio:
        return l.navPortfolio;
      case NavId.transactions:
        return l.navTransactions;
      case NavId.cashFlow:
        return l.navCashFlow;
      case NavId.projections:
        return l.navProjections;
      case NavId.tax:
        return l.navTaxPlanning;
      case NavId.lending:
        return l.navLending;
      case NavId.settings:
        return l.navSettings;
    }
  }

  /// Localized compact label for the bottom navigation bar.
  String _navShortLabel(AppLocalizations l, NavId id) {
    switch (id) {
      case NavId.overview:
        return l.navShortOverview;
      case NavId.portfolio:
        return l.navShortPortfolio;
      case NavId.transactions:
        return l.navShortTransactions;
      case NavId.cashFlow:
        return l.navShortCashFlow;
      case NavId.projections:
        return l.navShortProjections;
      case NavId.tax:
        return l.navShortTaxPlanning;
      case NavId.lending:
        return l.navShortLending;
      case NavId.settings:
        return l.navShortSettings;
    }
  }

  static NavId? _navIdFromName(String? name) {
    if (name == null) return null;
    for (final v in NavId.values) {
      if (v.name == name) return v;
    }
    return null;
  }

  /// Index of [id] in the live [_destinations], or null if not visible.
  int? _indexOfNav(NavId? id) {
    if (id == null) return null;
    final i = _destinations.indexWhere((d) => d.id == id);
    return i < 0 ? null : i;
  }

  /// Navigate to a section by stable id — robust to reordering and to the
  /// conditional Lending section. No-op if the target isn't visible.
  void _goToNav(NavId id) {
    // Switching tabs always restores the scroll-away app bar — a tab whose
    // list was scrolled deep must not land the user under a hidden bar.
    if (!_appBarVisible) setState(() => _appBarVisible = true);
    final i = _indexOfNav(id);
    if (i != null) _selectSection(i);
  }

  /// Select a section by index into [_destinations] and persist it.
  void _selectSection(int i) {
    if (i < 0 || i >= _destinations.length) return;
    if (i == _section) return;
    setState(() => _section = i);
    _persistSection();
  }

  /// Persist the active section by NavId name. Safe to call any time;
  /// no-op-safe if [_section] is somehow out of range.
  void _persistSection() {
    if (_section < 0 || _section >= _destinations.length) return;
    Preferences.setLastSection(_destinations[_section].id.name);
  }

  /// Apply a freshly-loaded lending_enabled value. Keeps the user on the
  /// same section by id across the flip; if Lending is turning off while
  /// it's the active section, falls back to Overview. Must NOT call
  /// setState itself — callers (_loadAllData, _toggleLending) already wrap
  /// this in their own setState.
  void _applyLendingSetting(bool enabled) {
    if (enabled == _lendingEnabled) return;
    final currentId = (_section >= 0 && _section < _destinations.length)
        ? _destinations[_section].id
        : NavId.overview;
    _lendingEnabled = enabled;
    _section = _indexOfNav(currentId) ?? 0;
  }

  /// Server-pushed event handler. Every event maps to "refetch the
  /// dashboard silently" today — the event payload is coarse on
  /// purpose so we don't have to mirror every response shape over
  /// the websocket. If the dashboard ever grows more refetch
  /// granularity, branch on `e.type` here.
  void _handleRealtimeEvent(RealtimeEvent e) {
    if (!mounted) return;
    debugPrint('realtime: received ${e.type}');
    switch (e.type) {
      case RealtimeEventType.fxRatesUpdated:
        // FX ticks are the most frequent push and only change the
        // displayed USD↔MXN conversion, which every card derives
        // client-side from _fxRate. Refetch JUST the rate instead of
        // re-pulling all ~17 endpoints (the old behaviour re-fetched the
        // entire dashboard on every background rate tick).
        _refreshFxRateOnly();
        return;
      case RealtimeEventType.transactionsChanged:
      case RealtimeEventType.accountsChanged:
      case RealtimeEventType.syncComplete:
      case RealtimeEventType.resync:
      case RealtimeEventType.unknown:
        // These change server-side data feeding many derived figures, so
        // a full cache-bypassing reload is the correct recovery — but
        // coalesce bursts (e.g. a multi-institution sync completing,
        // which fires syncComplete per institution) into ONE reload
        // rather than one per event.
        _reloadDebounce?.cancel();
        _reloadDebounce = Timer(const Duration(milliseconds: 400), () {
          if (mounted) _loadAllData(silent: true, forceRefresh: true);
        });
        return;
    }
  }

  /// Lightweight FX-only refresh for `fxRatesUpdated` pushes: pull the
  /// latest USD/MXN rate (server-forced) and re-render with it, without
  /// touching the other dashboard endpoints. A failure is non-fatal — the
  /// rate self-heals on the next full reload.
  Future<void> _refreshFxRateOnly() async {
    try {
      final fx = await _apiService.getExchangeRate('USD', 'MXN', force: true);
      if (!mounted) return;
      setState(() => _fxRate = fx);
    } catch (_) {}
  }

  /// Open the Add-account dialog directly. Wired into the empty-state CTAs
  /// (Transactions / Accounts) so a fresh user adds an account in one tap
  /// instead of being bounced to Settings to find the control.
  void _openAddAccount() {
    showDialog(
      context: context,
      builder: (_) => AddAccountDialog(onAccountCreated: _loadAllData),
    );
  }

  /// Open the Add-loan dialog pre-filled from an outflow transaction,
  /// linking that transaction as the loan's disbursement. Refreshes the
  /// dashboard on success so the funded transaction drops out of cash flow.
  Future<void> _openCreateLoanFromTx(dynamic tx) async {
    final m = tx as Map;
    final amount = (m['amount'] as num?)?.toDouble() ?? 0;
    final currency = (m['currency'] ?? _targetCurrency).toString();
    final date = DateTime.tryParse((m['date'] ?? '').toString()) ??
        DateTime.now();
    // Best borrower guess: counterparty, then merchant, then description.
    final borrower = [
      (m['counterparty_name'] ?? '').toString(),
      (m['merchant_name'] ?? '').toString(),
      (m['description'] ?? '').toString(),
    ].firstWhere((s) => s.trim().isNotEmpty, orElse: () => '');
    final created = await showCreateLoanFromTransactionDialog(
      context,
      apiService: _apiService,
      people: const [],
      defaultCurrency: _targetCurrency,
      principal: amount.abs(),
      currency: currency == 'MXN' ? 'MXN' : 'USD',
      originationDate: date,
      borrowerName: borrower,
      disbursementTxId: m['id'].toString(),
    );
    if (created == true) {
      await _refreshAfterTransactionMutation();
    }
  }

  /// Onboarding tile: enable the lending module and jump to it. Lending
  /// needs no linked bank account, so enabling it also exits the
  /// account-gated first-run hero (see [_isFirstRun]).
  Future<void> _enableLendingFromOnboarding() async {
    if (!_lendingEnabled) await _toggleLending(true);
    if (!mounted) return;
    _goToNav(NavId.lending);
  }

  /// Onboarding tile: pick a crypto exchange to connect. Coinbase is an
  /// OAuth redirect; Bitso uses the API-key dialog — mirrors the Settings
  /// "Connect crypto exchanges" controls.
  void _openConnectExchange() {
    final l = AppLocalizations.of(context);
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.login, color: Color(0xFF0052FF)),
              title: const Text('Coinbase'),
              subtitle: Text(l.dashConnectViaOauth),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                navigateTo('${_apiService.baseUrl}/auth/coinbase');
              },
            ),
            ListTile(
              leading: Icon(Icons.currency_exchange, color: context.positive),
              title: const Text('Bitso'),
              subtitle: Text(l.dashConnectWithApiKey),
              onTap: () {
                Navigator.of(sheetCtx).pop();
                showDialog(
                  context: context,
                  builder: (_) =>
                      AddCryptoDialog(exchange: 'bitso', onLinked: _loadAllData),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  String _loadSavedCurrency() {
    final saved = Preferences.getCurrency();
    return (saved == 'USD' || saved == 'MXN') ? saved : 'USD';
  }

  // First-run state: the dashboard has loaded successfully but the user has
  // no accounts yet. We swap the entire body for an onboarding hero and hide
  // the tab bar + currency chrome — every tab is empty in this state and
  // would mislead a fresh user into thinking the app is broken.
  bool get _hasAccounts {
    final accounts = _overview?['accounts'] as List?;
    return accounts != null && accounts.isNotEmpty;
  }

  // Lending needs no linked bank account, so a user who has enabled the
  // lending module is NOT a blank first-run user — show them the full
  // dashboard (with the Lending section) instead of the onboarding hero.
  bool get _isFirstRun =>
      !_isLoading && _error == null && !_hasAccounts && !_lendingEnabled;

  // Build the searchable index used by the Cmd-K palette. We do it on
  // demand so the list always reflects the most recent _loadAllData()
  // payload. Each item carries a callback that navigates to the right
  // tab so the palette doesn't have to know the dashboard's layout.
  List<PaletteItem> _buildPaletteItems() {
    final items = <PaletteItem>[];

    // Mirror the currency / FX setup _buildBody does so the account
    // panel that opens from the palette uses the same reporting context.
    final fxRate = (_fxRate?['rate'] as num?)?.toDouble() ?? 1.0;
    final conversionFactor = _targetCurrency == 'MXN' ? fxRate : 1.0;
    // Idiomatic symbol ($/MX$) via the shared helper so the hero number and
    // every card fed this formatter read "$1,234.00" not "USD 1,234.00".
    final currencyFormat = moneyFormat(_targetCurrency);

    // Jump-to-section items, driven by the live destination list so the
    // conditional Lending section appears here exactly when it's visible.
    final l10n = AppLocalizations.of(context);
    for (final d in _destinations) {
      items.add(PaletteItem(
        label: l10n.dashPaletteJumpTo(_navLabel(l10n, d.id)),
        subtitle: d.id == NavId.lending
            ? l10n.dashPaletteSectionLending
            : l10n.dashPaletteSection,
        icon: d.icon,
        accent: d.accent(Theme.of(context).brightness),
        onSelected: () => _goToNav(d.id),
      ));
    }

    final allAccounts = (_overview?['accounts'] as List?) ?? const [];
    for (final raw in allAccounts) {
      final a = raw as Map<String, dynamic>;
      final nick = (a['nickname'] ?? '').toString();
      final name = (a['name'] ?? '').toString();
      final inst = (a['institution_name'] ?? '').toString();
      items.add(PaletteItem(
        label: nick.isNotEmpty ? '$nick (${a['account_type'] ?? ''})' : name,
        subtitle: l10n.dashPaletteAccount(inst),
        icon: Icons.account_balance_wallet_outlined,
        accent: context.tealAccent,
        // Deep-link: open the account-detail side panel directly so the
        // user doesn't have to scroll the accounts column to find it.
        onSelected: () => showAccountTransactionsPanel(
          context,
          account: a,
          allAccounts: allAccounts,
          conversionFactor: conversionFactor,
          currencyFormat: currencyFormat,
          targetCurrency: _targetCurrency,
          usdMxnRate: fxRate,
          onBalanceUpdate: (id, bal) async {
            try {
              await _apiService.updateAccountBalance(id, bal);
              _loadAllData(silent: true);
            } catch (_) {}
          },
          onRenameAccount: (id, nickname) async {
            try {
              await _apiService.renameAccount(id, nickname);
              _loadAllData(silent: true);
            } catch (_) {}
          },
          onAlertsChanged: _reloadAccountAlerts,
        ),
      ));
    }

    for (final raw in ((_portfolioData?['holdings'] as List?) ?? const [])) {
      final h = raw as Map<String, dynamic>;
      final ticker = (h['ticker_symbol'] ?? '').toString();
      final name = (h['name'] ?? '').toString();
      // Pick the most specific token we have for the search seed so the
      // holdings table filters to a single row.
      final seed = ticker.isNotEmpty ? ticker : name;
      items.add(PaletteItem(
        label: ticker.isNotEmpty ? '$ticker — $name' : name,
        subtitle: l10n.dashPaletteHolding,
        icon: Icons.show_chart,
        accent: context.info,
        onSelected: () {
          setState(() => _portfolioSearchOverride = seed);
          _goToNav(NavId.portfolio);
        },
      ));
    }

    // Cap transactions to a recent window so the palette stays snappy
    // even with thousands of rows.
    final txs = _transactions ?? const [];
    for (final raw in txs.take(200)) {
      final t = raw as Map<String, dynamic>;
      final desc = (t['description'] ?? '').toString();
      // Prefer the same label the user sees in the row — so renamed
      // transactions are findable in Cmd-K under their new name, not
      // their original "Miscellaneous Debit" text.
      final label = displayLabel(t);
      final id = t['id']?.toString();
      items.add(PaletteItem(
        label: label,
        subtitle: l10n.dashPaletteTransaction(
            (t['account_name'] ?? '').toString(), (t['date'] ?? '').toString()),
        icon: Icons.receipt_outlined,
        accent: context.warning,
        onSelected: () {
          setState(() {
            _transactionsSearchOverride = desc;
            _highlightedTxId = id;
          });
          _goToNav(NavId.transactions);
          // Clear the pulse after ~2.4s so the row holds for ~1.3s after
          // the 550ms fade-in completes, then takes 550ms to fade back
          // out. Subsequent palette picks can pulse fresh because we
          // gate on the id being the one we just set.
          if (id != null) {
            Future.delayed(const Duration(milliseconds: 2400), () {
              if (!mounted) return;
              if (_highlightedTxId == id) {
                setState(() => _highlightedTxId = null);
              }
            });
          }
        },
      ));
    }

    return items;
  }

  void _openPalette() {
    showDialog(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.5),
      builder: (_) => CommandPaletteDialog(items: _buildPaletteItems()),
    );
  }

  void _setTargetCurrency(String currency) {
    setState(() => _targetCurrency = currency);
    Preferences.setCurrency(currency);
  }

  /// The Overview hero: the net-worth total in the reporting currency with
  /// its native-currency composition bound directly beneath it.
  ///
  /// Previously the total lived as the first tile in the stat row (competing
  /// with Assets/Liabilities/…) and the native split was an orphan strip
  /// floating below all five tiles — so the relationship "this $X is made of
  /// these native pieces" was easy to miss. Pulling the total into its own
  /// hero block and pinning the breakdown under it makes that explicit. The
  /// pills are self-labelling ("USD 9,591.00") and a foreign currency also
  /// shows its reporting-currency worth ("≈ $3,238"), so the pieces visibly
  /// add up to the headline.
  Widget _buildNetWorthHero({
    required NumberFormat currencyFormat,
    required double conversionFactor,
    required double usdMxnRate,
  }) {
    final l = AppLocalizations.of(context);
    final es = Localizations.localeOf(context).languageCode == 'es';
    final accent = context.positive;
    final netWorth =
        ((_overview?['net_worth'] as num?)?.toDouble() ?? 0.0) *
            conversionFactor;
    final targetUpper = _targetCurrency.toUpperCase();

    // Native composition, ordered by converted value (dominant currency
    // first). Each foreign currency carries its reporting-currency worth.
    final entries = ((_overview?['currency_breakdown'] as List?) ?? const [])
        .map((item) => (
              cur: (item['currency'] ?? '').toString().toUpperCase(),
              net: ((item['net'] ?? 0.0) as num).toDouble(),
            ))
        .where((e) => e.cur.isNotEmpty)
        .toList()
      ..sort((a, b) {
        final ca = convertCurrency(a.net,
            from: a.cur, to: _targetCurrency, usdMxnRate: usdMxnRate);
        final cb = convertCurrency(b.net,
            from: b.cur, to: _targetCurrency, usdMxnRate: usdMxnRate);
        return cb.compareTo(ca);
      });

    Widget? composition;
    if (entries.length >= 2) {
      composition = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 14),
          Row(
            children: [
              Text(
                (es ? 'En moneda nativa' : 'Held natively').toUpperCase(),
                style: TextStyle(
                  fontSize: 9,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w700,
                  color: context.textFaint,
                ),
              ),
              // Only foreign legs carry a reporting-currency "≈" — flag a
              // stale FX rate right beside the heading so the user knows
              // those conversions may be off.
              if (entries.any((e) => e.cur != targetUpper))
                ?(() {
                  final badge = _buildFxStaleBadge();
                  return badge == null
                      ? null
                      : Padding(
                          padding: const EdgeInsets.only(left: 8),
                          child: badge,
                        );
                })(),
            ],
          ),
          const SizedBox(height: 6),
          // A3 (round 3, a11y): the composition pills group into one node
          // ("USD 1,234.00 MXN 500.00 ≈ $25.00") instead of one node per
          // pill fragment.
          MergeSemantics(
            child: Wrap(
            spacing: 8,
            runSpacing: 6,
            children: entries.map((e) {
              final isTarget = e.cur == targetUpper;
              final converted = convertCurrency(e.net,
                  from: e.cur, to: _targetCurrency, usdMxnRate: usdMxnRate);
              return Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: context.tileSurface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: context.hairline),
                ),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: displayCurrencyWithCode(e.net, e.cur),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: context.textPrimary,
                        ),
                      ),
                      if (!isTarget)
                        TextSpan(
                          text: '  ≈ ${currencyFormat.displayMoney(converted)}',
                          style: TextStyle(
                            fontWeight: FontWeight.w400,
                            color: context.textFaint,
                          ),
                        ),
                    ],
                    style: const TextStyle(
                      fontSize: 12,
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
                ),
              );
            }).toList(),
            ),
          ),
        ],
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: accent.withValues(alpha: 0.32), width: 1.2),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // A3 (round 3, a11y): label + value + monthly-delta badge merge
          // into one announcement ("Net worth $X, +$Y · +1.2% vs 30d ago")
          // instead of four fragments. The badge's arrow icon carries no
          // semantics, so nothing is double-read.
          MergeSemantics(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.statNetWorth.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                    color: accent,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  currencyFormat.displayMoney(netWorth),
                  style: TextStyle(
                    fontSize: 30,
                    fontWeight: FontWeight.w800,
                    color: context.textPrimary,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                ?_buildNetWorthDeltaBadge(
                  currencyFormat: currencyFormat,
                  conversionFactor: conversionFactor,
                ),
              ],
            ),
          ),
          ?composition,
        ],
      ),
    );
  }

  /// Compact month-over-month change badge shown under the hero total:
  /// an arrow, the signed change and the percent move since ~30 days ago.
  /// Returns null (the badge is omitted) when there isn't enough history to
  /// compute a trustworthy delta — fewer than 2 points, or no point old
  /// enough to compare against — so a brand-new account never shows a
  /// misleading "+0".
  ///
  /// History [net_worth] is stored in USD; [conversionFactor] reports it in
  /// the active currency. The delta is computed in USD then converted, so the
  /// percent (a ratio) is currency-agnostic.
  Widget? _buildNetWorthDeltaBadge({
    required NumberFormat currencyFormat,
    required double conversionFactor,
  }) {
    final l = AppLocalizations.of(context);
    final history = _netWorthHistory ?? const [];
    if (history.length < 2) return null;

    // Latest point is the canonical "now" — the same series the trend chart
    // draws, so the badge agrees with the line's right edge.
    final latest = history.last;
    if (latest is! Map) return null;
    final latestNet = (latest['net_worth'] as num?)?.toDouble();
    final latestDateStr = (latest['date'] ?? '').toString();
    final latestDate = DateTime.tryParse(latestDateStr);
    if (latestNet == null || latestDate == null) return null;

    // Find the point closest to ~30 days before the latest — the comparison
    // anchor. Scanning backwards and keeping the nearest-to-target handles
    // irregular snapshot spacing (gaps, multiple-per-day) gracefully.
    final target = latestDate.subtract(const Duration(days: 30));
    Map? anchor;
    int? bestDistance;
    for (var i = 0; i < history.length - 1; i++) {
      final p = history[i];
      if (p is! Map) continue;
      final d = DateTime.tryParse((p['date'] ?? '').toString());
      final n = (p['net_worth'] as num?)?.toDouble();
      if (d == null || n == null) continue;
      // Only points strictly older than the latest are valid comparisons.
      if (!d.isBefore(latestDate)) continue;
      final dist = (d.difference(target).inDays).abs();
      if (bestDistance == null || dist < bestDistance) {
        bestDistance = dist;
        anchor = p;
      }
    }
    if (anchor == null) return null;
    final anchorNet = (anchor['net_worth'] as num?)?.toDouble();
    if (anchorNet == null) return null;

    final deltaUsd = latestNet - anchorNet;
    final delta = deltaUsd * conversionFactor;
    final up = deltaUsd >= 0;
    final color = up ? context.positive : context.warning;
    // Percent move relative to the anchor. Guard a zero/negative-magnitude
    // base so we never divide by zero or print a nonsensical percent.
    final pctLabel = anchorNet.abs() > 0
        ? ' · ${up ? '+' : '−'}${formatPercent(context, deltaUsd.abs() / anchorNet.abs() * 100, digits: 1)}'
        : '';
    final sign = up ? '+' : '−';
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            up ? Icons.arrow_upward_rounded : Icons.arrow_downward_rounded,
            size: 14,
            color: color,
          ),
          const SizedBox(width: 4),
          Text(
            '$sign${currencyFormat.displayMoney(delta.abs())}$pctLabel',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
          const SizedBox(width: 6),
          Text(
            l.heroDeltaSince30d,
            style: TextStyle(fontSize: 11, color: context.textFaint),
          ),
        ],
      ),
    );
  }

  /// Mobile "Details" disclosure — a tappable header that reveals the
  /// secondary Overview metrics ([children]). Collapsed by default so the
  /// phone Glance stays hero → trend → accounts; expand-state persists.
  Widget _buildOverviewDetails(List<Widget> children) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              setState(
                  () => _overviewDetailsExpanded = !_overviewDetailsExpanded);
              Preferences.setOverviewDetailsExpanded(_overviewDetailsExpanded);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              child: Row(
                children: [
                  Icon(Icons.insights_rounded,
                      color: context.tealAccent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.ovDetailsTitle,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: context.textPrimary,
                          ),
                        ),
                        Text(
                          l.ovDetailsSubtitle,
                          style:
                              TextStyle(fontSize: 11, color: context.textMuted),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _overviewDetailsExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    color: context.textMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_overviewDetailsExpanded) ...[
          const SizedBox(height: 12),
          ...children,
        ],
      ],
    );
  }

  /// Mobile "Connections & sync" disclosure — a tappable header that reveals
  /// the secondary Settings controls ([children]: sync-all button, sync-status
  /// card, FX rate, modules). Collapsed by default so the phone Settings view
  /// leads with the data-source actions; expand-state persists.
  Widget _buildManagementDetails(List<Widget> children) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () {
              setState(() =>
                  _managementDetailsExpanded = !_managementDetailsExpanded);
              Preferences.setManagementDetailsExpanded(
                  _managementDetailsExpanded);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              child: Row(
                children: [
                  Icon(Icons.tune, color: context.tealAccent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          l.mgmtConnectionsTitle,
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: context.textPrimary,
                          ),
                        ),
                        Text(
                          l.mgmtConnectionsSubtitle,
                          style:
                              TextStyle(fontSize: 11, color: context.textMuted),
                        ),
                      ],
                    ),
                  ),
                  Icon(
                    _managementDetailsExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    color: context.textMuted,
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_managementDetailsExpanded) ...[
          const SizedBox(height: 12),
          ...children,
        ],
      ],
    );
  }

  /// payload so no extra API call is needed.
  Widget _buildStatStrip({
    required NumberFormat currencyFormat,
    required double conversionFactor,
    required double usdMxnRate,
  }) {
    final l = AppLocalizations.of(context);
    final overview = _overview ?? const <String, dynamic>{};
    final accounts = (overview['accounts'] as List?) ?? const [];
    final typeBreakdown = (overview['type_breakdown'] as List?) ?? const [];

    final netWorth =
        ((overview['net_worth'] as num?)?.toDouble() ?? 0.0) * conversionFactor;

    // Walk accounts to compute liabilities (credit-type balances treated as
    // positive owed amounts) and the cash / investment subtotals. Uses the
    // shared categorizeAccount() so this stays in sync with the accounts
    // column grouping below.
    double liabilities = 0;
    double cash = 0;
    double investments = 0;
    double realAssets = 0;
    // Same categorizeAccount grouping kept as account lists so a tile tap can
    // open a sheet of exactly the accounts that fed its subtotal. Each row
    // carries the raw account map (for the deep-link) plus its native and
    // reporting-currency balances. The Assets tile is the union of every
    // asset-side category, mirroring `assets = netWorth + liabilities`.
    final liabilityAccounts = <_StatDrilldownRow>[];
    final cashAccounts = <_StatDrilldownRow>[];
    final investmentAccounts = <_StatDrilldownRow>[];
    final realAssetAccounts = <_StatDrilldownRow>[];
    final assetAccounts = <_StatDrilldownRow>[];
    for (final raw in accounts) {
      final acc = raw as Map<String, dynamic>;
      // current_balance is in the account's NATIVE currency — convert it to the
      // reporting currency (don't just × conversionFactor, which assumes USD and
      // left MXN balances at face value, inflating the cash/investment tiles to
      // more than net worth).
      final cur = (acc['currency'] ?? _targetCurrency).toString();
      final native = ((acc['current_balance'] as num?)?.toDouble() ?? 0.0).abs();
      final reported = convertCurrency(
        native,
        from: cur,
        to: _targetCurrency,
        usdMxnRate: usdMxnRate,
      );
      final row = _StatDrilldownRow(
        account: acc,
        nativeBalance: native,
        nativeCurrency: cur,
        reportedBalance: reported,
      );
      switch (categorizeAccount(acc['account_type']?.toString())) {
        case AccountCategory.credit:
        case AccountCategory.loan:
          liabilities += reported;
          liabilityAccounts.add(row);
        case AccountCategory.cash:
          cash += reported;
          cashAccounts.add(row);
          assetAccounts.add(row);
        case AccountCategory.investment:
        case AccountCategory.crypto:
          investments += reported;
          investmentAccounts.add(row);
          assetAccounts.add(row);
        case AccountCategory.realAsset:
          realAssets += reported;
          realAssetAccounts.add(row);
          assetAccounts.add(row);
        case AccountCategory.other:
          // Don't double-count unknowns into cash/investments; they're
          // still in net_worth (computed server-side) so the totals
          // remain consistent. Still an asset, so it joins the Assets sheet.
          assetAccounts.add(row);
          break;
      }
    }

    // If accounts list is empty (unlikely) fall back to type_breakdown totals.
    if (accounts.isEmpty && typeBreakdown.isNotEmpty) {
      for (final raw in typeBreakdown) {
        final item = raw as Map<String, dynamic>;
        final v =
            ((item['total_usd'] as num?)?.toDouble() ?? 0.0) * conversionFactor;
        switch (categorizeAccount(item['account_type']?.toString())) {
          case AccountCategory.cash:
            cash += v.abs();
          case AccountCategory.investment:
          case AccountCategory.crypto:
            investments += v.abs();
          case AccountCategory.credit:
          case AccountCategory.loan:
            liabilities += v.abs();
          case AccountCategory.realAsset:
            realAssets += v.abs();
          case AccountCategory.other:
            break;
        }
      }
    }

    final assets = netWorth + liabilities;

    // Dividends/yr tile inputs (O1): the SAME response fields the Portfolio
    // tab's DividendIncomeCard reads, so the two figures always match to the
    // cent. USD income is converted with the strip's conversionFactor below.
    final dividendIncome =
        (_portfolioDividends?['projected_annual_income_usd'] as num?)
                ?.toDouble() ??
            0.0;
    final dividendYield =
        (_portfolioDividends?['blended_yield_pct'] as num?)?.toDouble();

    // Net worth is no longer a tile here — it's the dedicated hero block
    // (_buildNetWorthHero) directly above this row, with the native-currency
    // composition bound to it. These tiles are the secondary stats that
    // decompose that total.
    final tiles = <_StatTile>[
      _StatTile(
        label: l.statAssets,
        value: currencyFormat.displayMoney(assets),
        // Neutral grey — a calm lead-in to the colour-coded secondary
        // stats so the row reads as a coherent set with a meaningful
        // category cue rather than competing colours.
        accent: context.neutralAccent,
        onTap: assetAccounts.isEmpty
            ? null
            : () => _showStatDrilldown(
                  label: l.statAssets,
                  total: assets,
                  accent: context.neutralAccent,
                  rows: assetAccounts,
                  currencyFormat: currencyFormat,
                  conversionFactor: conversionFactor,
                  usdMxnRate: usdMxnRate,
                ),
      ),
      _StatTile(
        label: l.statLiabilities,
        value: currencyFormat.displayMoney(liabilities),
        accent: context.negative,
        onTap: liabilityAccounts.isEmpty
            ? null
            : () => _showStatDrilldown(
                  label: l.statLiabilities,
                  total: liabilities,
                  accent: context.negative,
                  rows: liabilityAccounts,
                  currencyFormat: currencyFormat,
                  conversionFactor: conversionFactor,
                  usdMxnRate: usdMxnRate,
                ),
      ),
      _StatTile(
        label: l.statCash,
        value: currencyFormat.displayMoney(cash),
        accent: context.info,
        onTap: cashAccounts.isEmpty
            ? null
            : () => _showStatDrilldown(
                  label: l.statCash,
                  total: cash,
                  accent: context.info,
                  rows: cashAccounts,
                  currencyFormat: currencyFormat,
                  conversionFactor: conversionFactor,
                  usdMxnRate: usdMxnRate,
                ),
      ),
      _StatTile(
        label: l.statInvestments,
        value: currencyFormat.displayMoney(investments),
        accent: context.tealAccent,
        // This subtotal is the full balance of investment/brokerage
        // accounts, including any uninvested cash sleeve — so it can sit
        // above the Portfolio tab's total, which sums only security
        // holdings.
        tooltip: l.statInvestmentsCashSleeveNote,
        onTap: investmentAccounts.isEmpty
            ? null
            : () => _showStatDrilldown(
                  label: l.statInvestments,
                  total: investments,
                  accent: context.tealAccent,
                  rows: investmentAccounts,
                  currencyFormat: currencyFormat,
                  conversionFactor: conversionFactor,
                  usdMxnRate: usdMxnRate,
                ),
      ),
      // Dividends/yr tile (O1): projected annual dividend income across the
      // whole portfolio, with the blended yield in the tooltip. Present only
      // when the best-effort fetch succeeded, income is positive, and there
      // are actual holdings — never a dash tile. Tap = jump to the Portfolio
      // tab's Dividend income card (section switch + ensureVisible, same
      // pattern as the allocation band-tap scroll).
      if (dividendIncome > 0 &&
          ((_portfolioData?['holdings'] as List?) ?? const []).isNotEmpty)
        _StatTile(
          label: l.ovw3DividendsPerYear,
          value: currencyFormat.displayMoney(dividendIncome * conversionFactor),
          // Income accent — same styling family as the Investments tile's
          // category cue, but in the "money coming in" green.
          accent: context.positive,
          tooltip: dividendYield == null
              ? l.ovw3DividendsTooltipNoYield
              : l.ovw3DividendsTooltip(dividendYield.toStringAsFixed(2)),
          onTap: () {
            _goToNav(NavId.portfolio);
            _scrollToDividendCard();
          },
        ),
      // Real assets tile shows up only when the user actually has any —
      // a typical brand-new account has none and an empty $0 tile would
      // waste the row's horizontal budget.
      if (realAssets > 0)
        _StatTile(
          label: 'Real assets',
          value: currencyFormat.displayMoney(realAssets),
          accent: context.yellowAccent,
          onTap: realAssetAccounts.isEmpty
              ? null
              : () => _showStatDrilldown(
                    label: 'Real assets',
                    total: realAssets,
                    accent: context.yellowAccent,
                    rows: realAssetAccounts,
                    currencyFormat: currencyFormat,
                    conversionFactor: conversionFactor,
                    usdMxnRate: usdMxnRate,
                  ),
        ),
    ];

    return LayoutBuilder(
      builder: (ctx, c) {
        // Tile widths derived from total available width minus
        // (n-1)×spacing where n is the actual tile count. Earlier the
        // divisor was hard-coded to 5 so a 6th "Real assets" tile
        // overflowed the row on wide screens.
        final n = tiles.length;
        return Wrap(
          spacing: 12,
          runSpacing: 12,
          children: tiles
              .map((t) => SizedBox(
                    // Wide: one row of n tiles. Anything narrower (incl.
                    // phones) is a 2-up grid — full-width stacked tiles made
                    // the strip 4–5 rows tall and crowded the hero.
                    width: c.maxWidth >= 880
                        ? (c.maxWidth - (n - 1) * 12) / n
                        : (c.maxWidth - 12) / 2 - 0.5,
                    child: t,
                  ))
              .toList(),
        );
      },
    );
  }

  /// Bottom-sheet drilldown for an Overview stat tile. Lists the accounts
  /// that fed the tapped tile's subtotal — the exact same categorizeAccount
  /// grouping computed in [_buildStatStrip] — with each account's native
  /// balance and its reporting-currency equivalent. The sheet subtotal is the
  /// passed [total] so it always matches the tile face. Each row deep-links
  /// into [showAccountTransactionsPanel], mirroring the Cmd-K palette wiring.
  void _showStatDrilldown({
    required String label,
    required double total,
    required Color accent,
    required List<_StatDrilldownRow> rows,
    required NumberFormat currencyFormat,
    required double conversionFactor,
    required double usdMxnRate,
  }) {
    final l = AppLocalizations.of(context);
    final allAccounts = (_overview?['accounts'] as List?) ?? const [];

    // Largest holdings first so the sheet reads top-down by reporting-currency
    // weight, matching how a user scans "what's biggest".
    final sorted = [...rows]
      ..sort((a, b) => b.reportedBalance.compareTo(a.reportedBalance));

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (sheetCtx) {
        final maxHeight = MediaQuery.sizeOf(sheetCtx).height * 0.8;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                  child: Row(
                    children: [
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          label.toUpperCase(),
                          style: TextStyle(
                            fontSize: 11,
                            letterSpacing: 1.2,
                            fontWeight: FontWeight.w700,
                            color: context.textSubtle,
                          ),
                        ),
                      ),
                      Text(
                        currencyFormat.displayMoney(total),
                        style: brandDisplayStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: context.textPrimary,
                        ),
                      ),
                    ],
                  ),
                ),
                Divider(height: 1, color: context.hairline),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: EdgeInsets.zero,
                    itemCount: sorted.length,
                    itemBuilder: (ctx, i) {
                      final row = sorted[i];
                      final acc = row.account;
                      final institution =
                          (acc['institution_name'] ?? '').toString();
                      final nickname = (acc['nickname'] ?? '').toString();
                      final name = (acc['name'] ?? '').toString();
                      // Mirror COALESCE(nickname, name): a user-set nickname wins.
                      final displayName = nickname.isNotEmpty ? nickname : name;
                      final title = institution.isEmpty
                          ? displayName
                          : '$institution · $displayName';
                      // Native figure always carries its ISO code so a
                      // dual-currency list is self-labelling; the reporting
                      // equivalent sits beneath only when it actually differs.
                      final nativeStr = displayCurrencyWithCode(
                          row.nativeBalance, row.nativeCurrency);
                      final reportedStr =
                          currencyFormat.displayMoney(row.reportedBalance);
                      final showReported = row.nativeCurrency.toUpperCase() !=
                          _targetCurrency.toUpperCase();
                      return ListTile(
                        leading: Icon(Icons.account_balance_wallet_outlined,
                            size: 20, color: context.textSubtle),
                        title: Text(
                          title,
                          style: TextStyle(
                              fontSize: 14, color: context.textPrimary),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              nativeStr,
                              style: brandDisplayStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                                color: context.textPrimary,
                              ),
                            ),
                            if (showReported)
                              Text(
                                l.statDrilldownApprox(reportedStr),
                                style: TextStyle(
                                    fontSize: 11, color: context.textSubtle),
                              ),
                          ],
                        ),
                        onTap: () {
                          Navigator.of(sheetCtx).pop();
                          showAccountTransactionsPanel(
                            context,
                            account: acc,
                            allAccounts: allAccounts,
                            conversionFactor: conversionFactor,
                            currencyFormat: currencyFormat,
                            targetCurrency: _targetCurrency,
                            usdMxnRate: usdMxnRate,
                            onBalanceUpdate: (id, bal) async {
                              try {
                                await _apiService.updateAccountBalance(id, bal);
                                _loadAllData(silent: true);
                              } catch (_) {}
                            },
                            onRenameAccount: (id, nickname) async {
                              try {
                                await _apiService.renameAccount(id, nickname);
                                _loadAllData(silent: true);
                              } catch (_) {}
                            },
                            onAlertsChanged: _reloadAccountAlerts,
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Per-currency assets/liabilities sub-strip. Decomposes the headline
  /// assets/liabilities tiles by native currency so a dual-currency user can
  /// see "what's in pesos vs dollars" at a glance. Foreign currencies also
  /// carry their reporting-currency equivalent ("≈ $X").
  ///
  /// Reads [overview]['currency_breakdown'] (assets/liabilities/net per
  /// currency, in native units). Returns null when there's only one currency
  /// — the split would just restate the main tiles — so the caller can omit
  /// it entirely.
  /// Small, unobtrusive "approx. — FX rate stale" indicator. Surfaced next
  /// to native-currency figures that carry a reporting-currency equivalent
  /// when the backend marks the latest exchange rate as missing / stale
  /// (overview['fx_stale'] == true). Read null-safely so it renders nothing
  /// when the field is absent or false — older payloads degrade gracefully.
  Widget? _buildFxStaleBadge() {
    if ((_overview?['fx_stale'] == true) != true) return null;
    final l = AppLocalizations.of(context);
    return Tooltip(
      message: l.dashFxStaleTooltip,
      triggerMode: TooltipTriggerMode.tap,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 11, color: context.warning),
          const SizedBox(width: 4),
          Text(
            l.dashFxStaleLabel,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.3,
              color: context.warning,
            ),
          ),
        ],
      ),
    );
  }

  Widget? _buildCurrencySubStrip({
    required NumberFormat currencyFormat,
    required double usdMxnRate,
  }) {
    final l = AppLocalizations.of(context);
    final targetUpper = _targetCurrency.toUpperCase();
    final entries = ((_overview?['currency_breakdown'] as List?) ?? const [])
        .whereType<Map>()
        .map((item) => (
              cur: (item['currency'] ?? '').toString().toUpperCase(),
              assets: ((item['assets'] ?? 0.0) as num).toDouble(),
              liabilities: ((item['liabilities'] ?? 0.0) as num).toDouble(),
            ))
        .where((e) => e.cur.isNotEmpty)
        .toList();
    if (entries.length < 2) return null;

    // Dominant currency (by reporting-currency net exposure) first, so the
    // user's primary holdings lead the list.
    entries.sort((a, b) {
      final ca = convertCurrency(a.assets - a.liabilities,
          from: a.cur, to: _targetCurrency, usdMxnRate: usdMxnRate);
      final cb = convertCurrency(b.assets - b.liabilities,
          from: b.cur, to: _targetCurrency, usdMxnRate: usdMxnRate);
      return cb.abs().compareTo(ca.abs());
    });

    Widget leg(String label, double native, String cur, Color color) {
      final isTarget = cur == targetUpper;
      final converted = convertCurrency(native,
          from: cur, to: _targetCurrency, usdMxnRate: usdMxnRate);
      return Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 11, color: context.textMuted),
            ),
          ),
          Text.rich(
            TextSpan(
              children: [
                TextSpan(
                  text: displayCurrencyWithCode(native, cur),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: color,
                  ),
                ),
                if (!isTarget)
                  TextSpan(
                    text: '  ≈ ${currencyFormat.displayMoney(converted)}',
                    style: TextStyle(
                      fontWeight: FontWeight.w400,
                      color: context.textFaint,
                    ),
                  ),
              ],
              style: const TextStyle(
                fontSize: 11,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: context.tileSurface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                l.ovByCurrency.toUpperCase(),
                style: TextStyle(
                  fontSize: 9,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w700,
                  color: context.textFaint,
                ),
              ),
              ?(() {
                final badge = _buildFxStaleBadge();
                return badge == null
                    ? null
                    : Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: badge,
                      );
              })(),
            ],
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            Text(
              entries[i].cur,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: context.textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            leg(l.statAssets, entries[i].assets, entries[i].cur,
                context.textPrimary),
            const SizedBox(height: 2),
            leg(l.statLiabilities, entries[i].liabilities, entries[i].cur,
                context.negative),
          ],
        ],
      ),
    );
  }

  /// Compact "Lending" glance card for the Overview: total outstanding (across
  /// every active loan, currency-converted), the active-loan count and the
  /// soonest-due / overdue installment. Tapping it jumps to the Lending
  /// section.
  ///
  /// Returns null — so the caller omits it entirely — unless lending is enabled
  /// AND at least one active loan exists. A red dot flags any overdue loan.
  Widget? _buildLendingGlanceCard({
    required NumberFormat currencyFormat,
    required double usdMxnRate,
  }) {
    if (!_lendingEnabled) return null;
    final l = AppLocalizations.of(context);
    final activeLoans = _loans
        .whereType<Map>()
        .where((loan) => (loan['status'] ?? 'active').toString() == 'active')
        .toList();
    if (activeLoans.isEmpty) return null;

    // Show the loans' NATIVE currency when they all share one (e.g. an
    // all-MXN portfolio reads "MXN 178,704", not a "$10,211" conversion) —
    // matching the Lending tab and the rest of the app. Only a genuinely
    // mixed portfolio is converted to the display currency.
    final mixed = loansAreMixedCurrency(activeLoans);
    final summaryCur = mixed
        ? _targetCurrency
        : (activeLoans.first['currency'] ?? _targetCurrency).toString();
    // Total still owed (principal + unpaid interest), matching the loan view.
    final totalOutstanding = sumLoansConverted(
        activeLoans, 'total_owed', summaryCur, usdMxnRate);

    // Soonest reminder is the head of the (due_date ASC) list; overdue means
    // any reminder with days_overdue > 0.
    final reminders = _loanReminders.whereType<Map>().toList();
    final hasOverdue =
        reminders.any((r) => ((r['days_overdue'] as num?)?.toInt() ?? 0) > 0);
    String? soonestLabel;
    if (reminders.isNotEmpty) {
      final next = reminders.first;
      final name = (next['borrower_name'] ?? '').toString();
      final overdueDays = (next['days_overdue'] as num?)?.toInt() ?? 0;
      final untilDays = (next['days_until'] as num?)?.toInt() ?? 0;
      final when = overdueDays > 0
          ? l.lendingGlanceOverdueBy(overdueDays)
          : (untilDays == 0
              ? l.lendingGlanceDueToday
              : l.lendingGlanceDueIn(untilDays));
      soonestLabel = name.isEmpty ? when : '$name · $when';
    }

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: InkWell(
        borderRadius: BorderRadius.circular(20),
        onTap: () => _goToNav(NavId.lending),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.volunteer_activism_outlined,
                      color: context.tealAccent, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.lendingGlanceTitle,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (hasOverdue)
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: context.negative,
                        shape: BoxShape.circle,
                      ),
                    ),
                  Icon(Icons.chevron_right,
                      color: context.textMuted, size: 20),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                displayCurrencyAmount(totalOutstanding, summaryCur),
                style: TextStyle(
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                  color: context.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '${l.lendingGlanceOutstanding} · ${l.lendingGlanceActiveCount(activeLoans.length)}',
                style: TextStyle(fontSize: 12, color: context.textMuted),
              ),
              if (soonestLabel != null) ...[
                const SizedBox(height: 8),
                Text(
                  '${l.lendingGlanceNextDue}: $soonestLabel',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: hasOverdue ? context.warning : context.textSubtle,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Restore an auto-archived account from the Management tab, mirroring the
  /// flow in HiddenItemsScreen: call the API, drop the row locally for instant
  /// feedback, and refresh silently so net worth / accounts reflect it.
  Future<void> _restoreArchivedAccount(String id, String label) async {
    final l = AppLocalizations.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _apiService.restoreAccount(id);
      if (!mounted) return;
      setState(() {
        _archivedAccounts = (_archivedAccounts ?? const [])
            .where((row) => (row as Map)['id'].toString() != id)
            .toList();
      });
      messenger.showSnackBar(
        SnackBar(content: Text(l.accountRestored(label))),
      );
      // Reflect the restored balance in net worth / the accounts list.
      _loadAllData(silent: true);
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(content: Text(l.hiddenRestoreFailed(e.toString()))),
      );
    }
  }

  /// Collapsible "Auto-archived accounts" section for the Management tab.
  /// Lists each account the sync closed (name + institution + archive date)
  /// with a one-click Restore, plus a link to the full Hidden Items screen.
  ///
  /// Returns null — so the caller omits it entirely — when nothing has been
  /// auto-archived.
  Widget? _buildArchivedAccountsSection() {
    final archived = _archivedAccounts ?? const [];
    if (archived.isEmpty) return null;
    final l = AppLocalizations.of(context);

    return Card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: () => setState(
                () => _archivedSectionExpanded = !_archivedSectionExpanded),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Row(
                children: [
                  Icon(Icons.inventory_2_outlined,
                      size: 18, color: context.textMuted),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.mgmtArchivedTitle,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ),
                  Text(
                    '(${archived.length})',
                    style:
                        TextStyle(fontSize: 12, color: context.textSubtle),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    _archivedSectionExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    color: context.textMuted,
                  ),
                ],
              ),
            ),
          ),
          if (_archivedSectionExpanded) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                l.mgmtArchivedIntro,
                style: TextStyle(color: context.textSubtle, fontSize: 12),
              ),
            ),
            for (var i = 0; i < archived.length; i++) ...[
              if (i > 0) Divider(height: 1, color: context.hairline),
              _archivedAccountRow(archived[i] as Map<String, dynamic>),
            ],
            Divider(height: 1, color: context.hairline),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const HiddenItemsScreen()),
                ).then((_) => _loadAllData(silent: true)),
                icon: const Icon(Icons.open_in_new, size: 16),
                label: Text(l.mgmtArchivedManageAll),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _archivedAccountRow(Map<String, dynamic> row) {
    final l = AppLocalizations.of(context);
    final id = (row['id'] ?? '').toString();
    final institution = (row['institution_name'] ?? '').toString();
    final nickname = (row['nickname'] ?? '').toString();
    final name = (row['name'] ?? '').toString();
    // Mirror COALESCE(nickname, name): a user-set nickname wins.
    final displayName = nickname.isNotEmpty ? nickname : name;
    final archivedAt = (row['archived_at'] ?? '').toString();
    final title =
        institution.isEmpty ? displayName : '$institution · $displayName';
    final archivedDate = DateTime.tryParse(archivedAt);
    final subtitle = archivedDate == null
        ? null
        : l.accountClosedOn(DateFormat.yMMMd().format(archivedDate.toLocal()));

    return ListTile(
      dense: true,
      leading: const Icon(Icons.account_balance_outlined, size: 18),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle,
              style: TextStyle(color: context.textSubtle, fontSize: 11),
            ),
      trailing: TextButton.icon(
        onPressed: () => _restoreArchivedAccount(id, displayName),
        icon: const Icon(Icons.refresh, size: 16),
        label: Text(l.accountRestore),
      ),
    );
  }

  /// "Hidden from subscriptions" panel — small card listing every
  /// merchant the user previously dismissed via the × on the
  /// SubscriptionsCard. Each row has an "Unhide" button that DELETEs
  /// the underlying `ignored_subscription_merchants` row so the
  /// detector can resurface the cluster on its next run.
  Widget _buildIgnoredSubscriptionsPanel() {
    final l = AppLocalizations.of(context);
    final ignored = _ignoredSubscriptions ?? const [];
    if (ignored.isEmpty) return const SizedBox.shrink();
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        // Same responsive 16/24 padding as the tab's other cards
        // (e.g. monthly_cash_flow_card.dart).
        padding: EdgeInsets.all(
            MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.visibility_off_outlined,
                    size: 18, color: context.textSubtle),
                const SizedBox(width: 8),
                Text(
                  l.dashHiddenFromSubscriptions,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${ignored.length}',
                  style:
                      TextStyle(fontSize: 12, color: context.textSubtle),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              l.dashHiddenFromSubscriptionsHint,
              style: TextStyle(fontSize: 11, color: context.textSubtle),
            ),
            const SizedBox(height: 8),
            for (final raw in ignored)
              _buildIgnoredRow(raw as Map<String, dynamic>),
          ],
        ),
      ),
    );
  }

  Widget _buildIgnoredRow(Map<String, dynamic> row) {
    final l = AppLocalizations.of(context);
    final key = (row['merchant_key'] ?? '').toString();
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              key,
              style: TextStyle(fontSize: 13, color: context.textPrimary),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton.icon(
            icon: const Icon(Icons.refresh, size: 14),
            label: Text(l.dashUnhide),
            onPressed: () async {
              try {
                await _apiService.unignoreSubscription(key);
                await _refreshSubscriptionLists();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l.dashSubscriptionRestored(key))),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l.dashUnhideFailed(e.toString()))),
                );
              }
            },
          ),
        ],
      ),
    );
  }

  /// Plaid-environment indicator. Returns an empty SizedBox in
  /// production (no chrome to distract), an amber pill labelled
  /// "Modules" card in the Management tab — opt-in feature toggles.
  /// Today just the personal-lending module; the switch persists
  /// server-side (app_settings 'lending_enabled') so it follows the
  /// user across devices, and flipping it adds/removes the Lending tab.
  Widget _buildModulesCard() {
    final l = AppLocalizations.of(context);
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: context.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Column(
          children: [
            SwitchListTile(
              value: _lendingEnabled,
              onChanged: _toggleLending,
              secondary:
                  Icon(Icons.monetization_on, color: context.tealAccent),
              title: Text(l.dashModuleLendingTitle,
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: context.textPrimary)),
              subtitle: Text(
                l.dashModuleLendingSubtitle,
                style: TextStyle(fontSize: 12, color: context.textSubtle),
              ),
            ),
            // Reminder lead-time stepper — only when lending is on.
            if (_lendingEnabled)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
                child: Row(
                  children: [
                    Icon(Icons.notifications_active_outlined,
                        size: 18, color: context.textMuted),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        l.dashRemindBeforeRepayment,
                        style: TextStyle(
                            fontSize: 13, color: context.textPrimary),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline, size: 20),
                      tooltip: l.dashFewerDays,
                      onPressed: _lendingReminderLeadDays <= 0
                          ? null
                          : () => _setReminderLeadDays(
                              _lendingReminderLeadDays - 1),
                    ),
                    Text(l.dashDaysShort(_lendingReminderLeadDays),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: context.textPrimary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        )),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline, size: 20),
                      tooltip: l.dashMoreDays,
                      onPressed: _lendingReminderLeadDays >= 60
                          ? null
                          : () => _setReminderLeadDays(
                              _lendingReminderLeadDays + 1),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// Preferences card on the Settings tab — language + theme. These app-level
  /// settings live here (not only in the AppBar kebab) so the Settings tab is
  /// the single settings home.
  Widget _buildPreferencesCard() => const SettingsPreferencesCard();

  /// Account & security card on the Settings tab: Security, Hidden &
  /// archived items, Server (native builds), and the confirmed sign-out.
  Widget _buildAccountCard() => SettingsAccountSecurityCard(
        // Hiding/unhiding accounts or holdings changes totals — refresh
        // silently, mirroring the kebab's Hidden-items behavior.
        onHiddenItemsClosed: () {
          if (mounted) _loadAllData(silent: true);
        },
        // The card shows the confirmation dialog itself; this fires only
        // after the user confirmed.
        onSignOut: () => AuthService.instance.logout(),
        // Order matters: logout() needs the current server to revoke the
        // session; clear() then flips root_gate to BackendSetupScreen.
        onChangeServer: () async {
          await AuthService.instance.logout();
          await BackendConfig.clear();
        },
      );

  /// Confirmed sign-out, reusing the Security screen's bilingual strings so
  /// every sign-out entry point reads identically. Called by the first-run
  /// AppBar sign-out action (the only bar-level sign-out left post-kebab).
  Future<void> _confirmSignOut() async {
    final confirmed = await confirmSignOutDialog(context);
    if (!confirmed || !mounted) return;
    await AuthService.instance.logout();
    // AuthService emits signedOut → the AuthGate listener in main.dart
    // unmounts the dashboard tree; no explicit navigation needed.
  }

  Future<void> _setReminderLeadDays(int days) async {
    final clamped = days.clamp(0, 60);
    final prev = _lendingReminderLeadDays;
    setState(() => _lendingReminderLeadDays = clamped);
    try {
      await _apiService.putSetting('lending_reminder_lead_days', clamped);
      // Refresh reminders so the bell reflects the new window.
      if (mounted) _loadAllData(silent: true);
    } catch (e) {
      if (!mounted) return;
      setState(() => _lendingReminderLeadDays = prev);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).dashReminderSaveFailed)),
      );
    }
  }

  Future<void> _toggleLending(bool enabled) async {
    // Optimistically recompute the section list, then persist. On
    // failure, revert so the UI doesn't lie about the saved state.
    setState(() => _applyLendingSetting(enabled));
    // _applyLendingSetting may have moved us off the now-hidden Lending
    // section; keep the persisted section pref in step with where we
    // actually landed (otherwise a reload restores a stale section name).
    _persistSection();
    try {
      await _apiService.putSetting('lending_enabled', enabled);
    } catch (e) {
      if (!mounted) return;
      setState(() => _applyLendingSetting(!enabled));
      _persistSection();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).dashSettingSaveFailed)),
      );
    }
  }

  /// `Sandbox` / `Development` otherwise. Reads `plaid_environment`
  /// from `/api/setup/status` (already loaded into _setupStatus).
  Widget _buildEnvChip() {
    final l = AppLocalizations.of(context);
    final env = (_setupStatus?['plaid_environment'] ?? '')
        .toString()
        .toLowerCase()
        .trim();
    if (env.isEmpty || env == 'production') {
      return const SizedBox.shrink();
    }
    final label = env == 'sandbox'
        ? l.dashEnvSandbox
        : env == 'development'
            ? l.dashEnvDev
            : env;
    return Tooltip(
      message: l.dashEnvTooltip(env),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: context.accentSoft(context.warning),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: context.accentBorder(context.warning)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.science_outlined, size: 14, color: context.warning),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: context.warning,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFxBadge({bool compact = false}) {
    final l = AppLocalizations.of(context);
    final rate = (_fxRate?['rate'] as num?)?.toDouble();
    // The pair codes are dynamic (backend sends `base`/`target`); don't hardcode
    // USD/MXN so the pill stays correct if the base/target currency ever changes.
    final base =
        (_fxRate?['base'] ?? _fxRate?['base_currency'] ?? 'USD').toString();
    final target =
        (_fxRate?['target'] ?? _fxRate?['target_currency'] ?? 'MXN').toString();
    final recordedAtRaw = _fxRate?['recorded_at'] as String?;
    final recordedLocal = recordedAtRaw == null
        ? null
        : DateTime.tryParse(recordedAtRaw)?.toLocal();
    final isStale = recordedLocal != null &&
        DateTime.now().difference(recordedLocal).inHours > 24;

    // Bare rate number for the compact pill, e.g. "17.58" — no currency code,
    // since the pair is already shown. Routed through the locale decimal seam
    // (no-op today: es-MX uses period decimals like en).
    final rateBare = rate == null
        ? '—'
        : localizeNumberString(context, rate.toStringAsFixed(2));
    // Money-coded target amount ("MXN 17.58") reused via the currency helper for
    // the spelled-out equation + tooltip, where the code disambiguates.
    final rateMoney = rate == null ? null : formatCurrencyAmount(rate, target);

    // LABEL-1: three designers found the bare "⇄ 17.58" pill cryptic. Compact
    // now labels the pair — "USD/MXN 17.58"; non-compact spells the equation.
    //
    // ⚠ gen-l10n orders placeholders ALPHABETICALLY, not in template order.
    // dashFxPill template is "{base}/{target} {rate}" but its generated
    // signature is dashFxPill(base, RATE, target) — alphabetical (base, rate,
    // target). So `rate` MUST be passed BEFORE `target`; passing template order
    // (base, target, rate) would silently render "USD/17.58 MXN".
    final label = compact || rateMoney == null
        ? l.dashFxPill(base, rateBare, target)
        // dashFxRateEquation is (base, rate) — alphabetical == template order.
        : l.dashFxRateEquation(base, rateMoney);
    final accent = isStale ? context.warning : context.tealAccent;

    final freshness = rate == null
        ? l.dashFxLoading
        : recordedLocal == null
            ? l.dashFxLive
            : (isStale
                ? l.dashFxStaleAt(
                    '${DateFormat('MMM d, y · h:mm a').format(recordedLocal)} '
                    '${recordedLocal.timeZoneName}')
                : l.dashFxUpdatedAt(
                    '${DateFormat('MMM d, y · h:mm a').format(recordedLocal)} '
                    '${recordedLocal.timeZoneName}'));
    // Tooltip / screen-reader label: lead with the full equation
    // ("1 USD = MXN 17.58"), then the freshness/source line the badge already had.
    final tooltip = rateMoney == null
        ? freshness
        : '${l.dashFxRateEquation(base, rateMoney)}\n$freshness';

    return Tooltip(
      message: tooltip,
      // Mirror the fuller equation into the semantics tree so a screen reader
      // announces "1 USD = MXN 17.58 …" rather than the terse visible pill.
      child: Semantics(
        container: true,
        label: tooltip,
        child: ExcludeSemantics(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: context.tint(0.06),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: context.accentBorder(accent)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.swap_horiz, size: 14, color: accent),
                const SizedBox(width: 6),
                Text(
                  label,
                  style: TextStyle(
                    color: accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Compact-width combined currency control: "USD · 17.51" in one tappable
  /// tonal chip (tap toggles the display currency). Replaces two bar
  /// elements from the pre-audit design — the bordered-but-inert FX pill
  /// (button styling, no tap handler) and the sub-30dp _CurrencyToggleButton
  /// — bringing the compact bar to three actions + overflow (the M3
  /// ceiling). Tonal fill, no border: color is reserved for state, warning
  /// when the rate is >24h stale. Wide layouts keep the separate pair.
  Widget _buildCurrencyFxChip() {
    final l = AppLocalizations.of(context);
    // Same payload parse as _buildFxBadge (kept in sync): dynamic pair codes,
    // >24h staleness off recorded_at.
    final rate = (_fxRate?['rate'] as num?)?.toDouble();
    final base =
        (_fxRate?['base'] ?? _fxRate?['base_currency'] ?? 'USD').toString();
    final target =
        (_fxRate?['target'] ?? _fxRate?['target_currency'] ?? 'MXN').toString();
    final recordedAtRaw = _fxRate?['recorded_at'] as String?;
    final recordedLocal = recordedAtRaw == null
        ? null
        : DateTime.tryParse(recordedAtRaw)?.toLocal();
    final isStale = recordedLocal != null &&
        DateTime.now().difference(recordedLocal).inHours > 24;
    final rateBare = rate == null
        ? null
        : localizeNumberString(context, rate.toStringAsFixed(2));
    final label =
        rateBare == null ? _targetCurrency : '$_targetCurrency · $rateBare';
    final fg = isStale ? context.warning : context.textPrimary;
    // Toggle affordance first, then the full rate equation so the tooltip /
    // screen reader explains both of the chip's facts.
    final rateMoney = rate == null ? null : formatCurrencyAmount(rate, target);
    final tooltip = rateMoney == null
        ? l.currencyToggleTooltip(_targetCurrency)
        : '${l.currencyToggleTooltip(_targetCurrency)}\n'
            '${l.dashFxRateEquation(base, rateMoney)}';
    return Tooltip(
      message: tooltip,
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () =>
            _setTargetCurrency(_targetCurrency == 'USD' ? 'MXN' : 'USD'),
        // 48dp touch floor: the visual pill stays compact; the hit area
        // doesn't shrink with it.
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 48, minWidth: 48),
          child: Center(
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: context.tint(0.06),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.currency_exchange, size: 14, color: fg),
                  const SizedBox(width: 6),
                  Text(
                    label,
                    style: TextStyle(
                      color: fg,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.4,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // Full-page welcome shown when the user has not connected any accounts.
  // Lives in the body slot so the AppBar's tab strip can be dropped — every
  // tab is empty in this state and would mislead a fresh user.
  Widget _buildOnboardingHero() {
    final l = AppLocalizations.of(context);
    final plaidReady = _setupStatus?['ready_for_plaid_linking'] == true;

    Widget actionTile({
      required IconData icon,
      required String title,
      required String subtitle,
      required Color accent,
      required VoidCallback? onPressed,
      String? disabledHint,
    }) {
      final enabled = onPressed != null;
      return Material(
        color: Colors.white.withValues(alpha: enabled ? 0.05 : 0.02),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onPressed,
          child: Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: enabled
                    ? context.accentBorder(accent)
                    : context.accentSoft(accent),
              ),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 28, color: accent),
                const SizedBox(height: 12),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: enabled ? context.textPrimary : context.textSubtle,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                Text(
                  enabled
                      ? subtitle
                      : (disabledHint ?? subtitle),
                  style: TextStyle(
                    fontSize: 12,
                    color: enabled ? context.textMuted : context.textFaint,
                    height: 1.4,
                  ),
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
      );
    }

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 720),
          child: Card(
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: LayoutBuilder(
                builder: (ctx, c) {
                  final stack = c.maxWidth < 560;
                  final tiles = [
                    actionTile(
                      icon: Icons.account_balance,
                      title: l.dashLinkUsBank,
                      subtitle: l.dashLinkUsBankSubtitle,
                      accent: context.tealAccent,
                      onPressed: plaidReady
                          ? () {
                              Navigator.push(
                                context,
                                MaterialPageRoute(
                                  builder: (context) => const ConnectBankScreen(),
                                ),
                              ).then((_) => _loadAllData(silent: true));
                            }
                          : null,
                      disabledHint: l.dashLinkUsBankDisabledHint,
                    ),
                    actionTile(
                      icon: Icons.upload_file,
                      title: l.dashImportMxCsvPdf,
                      subtitle: l.dashImportMxCsvPdfSubtitle(
                          supportedMxBanksSentence()),
                      accent: context.info,
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => const ImportScreen(),
                          ),
                        ).then((_) => _loadAllData(silent: true));
                      },
                    ),
                    actionTile(
                      icon: Icons.add_circle_outline,
                      title: l.dashAddManualAccount,
                      subtitle: l.dashAddManualAccountSubtitle,
                      accent: context.positive,
                      onPressed: () {
                        showDialog(
                          context: context,
                          builder: (context) => AddAccountDialog(
                            onAccountCreated: _loadAllData,
                          ),
                        );
                      },
                    ),
                    // Signature features — surfaced at first run so they
                    // aren't hidden behind a Settings toggle / sub-menu.
                    actionTile(
                      icon: Icons.monetization_on,
                      title: l.dashTrackMoneyLent,
                      subtitle: l.dashTrackMoneyLentSubtitle,
                      accent: context.tealAccent,
                      onPressed: _enableLendingFromOnboarding,
                    ),
                    actionTile(
                      icon: Icons.currency_exchange,
                      title: l.dashConnectCryptoExchangeTile,
                      subtitle: l.dashConnectCryptoExchangeTileSubtitle,
                      accent: context.warning,
                      onPressed: _openConnectExchange,
                    ),
                  ];

                  final tileWidth = stack
                      ? c.maxWidth - 48
                      : (c.maxWidth - 48 - 2 * 16) / 3;

                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.savings_outlined,
                        size: 40,
                        color: context.positive,
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l.dashOnboardingWelcome,
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: context.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        l.dashOnboardingSubtitle,
                        style: TextStyle(
                          fontSize: 14,
                          color: context.textMuted,
                          height: 1.4,
                        ),
                      ),
                      const SizedBox(height: 24),
                      Wrap(
                        spacing: 16,
                        runSpacing: 16,
                        children: tiles
                            .map((t) => SizedBox(width: tileWidth, child: t))
                            .toList(),
                      ),
                      const SizedBox(height: 20),
                      Text(
                        l.dashOnboardingAlreadyLinked,
                        style: TextStyle(
                          fontSize: 12,
                          color: context.textFaint,
                          fontStyle: FontStyle.italic,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _checkRedirectStatus() {
    final uri = Uri.parse(currentUrl());
    final status = uri.queryParameters['status'];
    if (status == 'success') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).dashAccountLinkedSuccess),
            backgroundColor: context.positive,
          ),
        );
      });
    } else if (status == 'error') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context).dashAccountLinkFailed),
            backgroundColor: context.negative,
          ),
        );
      });
    }
  }

  /// Plaid OAuth banks bounce the whole tab out to the bank's login and back
  /// to our redirect_uri (carrying `oauth_state_id`). On that cold boot we
  /// re-open Link with the persisted token + the return URL so Plaid can
  /// finish the handshake, then run the same completion the in-tab flow would
  /// have: exchange the public token for a NEW institution, or re-sync for a
  /// reconnect. Non-OAuth links never reach this — they complete in-tab.
  void _resumePlaidOAuthIfNeeded() {
    final pending = pendingPlaidOAuth();
    if (pending == null) return;
    // Clear up front so refreshing the return URL can't replay a spent token.
    clearPlaidOAuth();
    _listenPlaid((event) async {
      try {
        if (pending.mode == 'reconnect') {
          await _apiService.syncInstitutions();
          if (mounted) _loadAllData(silent: true);
        } else {
          await _apiService.exchangePublicToken(
            event.publicToken,
            event.metadata.institution?.name ?? 'Unknown institution',
          );
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content:
                  Text(AppLocalizations.of(context).dashAccountLinkedSuccess),
              backgroundColor: context.positive,
            ),
          );
          _loadAllData(silent: true);
        }
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(AppLocalizations.of(context).dashAccountLinkFailed),
              backgroundColor: context.negative,
            ),
          );
        }
      }
    }, (_) {
      if (mounted) _loadAllData(silent: true);
    });
    // Defer the open until after first frame so the overlay/context are ready.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      resumePlaidLink(pending.token);
    });
  }

  /// Explicit user-initiated refresh ("sync everything" / per-institution
  /// retry). Bypasses the response cache so the user who just asked for
  /// fresh data gets exactly that. Re-prices manual stock holdings
  /// (Oracle etc.) live too — the stock analog of the FX refresh. This is
  /// the ONLY path allowed to hit the external quote API; transaction
  /// mutations go through [_refreshAfterTransactionMutation] instead.
  Future<void> _refreshData() async {
    try {
      await _apiService.refreshAllStockPrices();
    } catch (_) {/* best-effort; data reload still proceeds */}
    await _loadAllData(silent: true, forceRefresh: true);
  }

  /// Targeted refresh after a transaction mutation (categorize / rename /
  /// delete / split / manual add / FX-transfer link). Refetches ONLY the
  /// reads a transaction change can affect — the transaction list (which
  /// also feeds BudgetsCard), the overview (account balances / net worth)
  /// and the monthly trends behind the cash-flow cards. Deliberately NOT
  /// [_refreshData]: that path re-prices every manual stock holding via
  /// the external quote API and re-pulls all ~18 dashboard endpoints,
  /// which made renaming one transaction cost seconds of network.
  /// Investments / holdings / crypto / FX-rate reads never refetch here.
  ///
  /// No forceRefresh needed: the mutation that just ran already cleared
  /// the response cache in ApiService, so these reads are fresh by
  /// construction (see `_invalidateAfterMutation`).
  ///
  /// [includeFxTransfers] adds the FX-transfer pair list for the mutations
  /// that can change it (confirm / unlink / detect).
  Future<void> _refreshAfterTransactionMutation(
      {bool includeFxTransfers = false}) async {
    // Depth-preserving refetch: ask for as many rows as are already loaded
    // (the user may have cascade-loaded pages for a client-side filter),
    // never fewer than one page and never more than the backend honors.
    // Without this, editing a row under an active filter snapped the list
    // back to page 1 and re-triggered the whole-history cascade.
    final refetchLimit = txRefetchLimit(
        loadedCount: _transactions?.length ?? 0, pageSize: _txPageSize);
    try {
      final data = await fetchAfterTransactionMutation(
        getTransactions: (limit) => _apiService.getTransactions(limit: limit),
        getOverview: _apiService.getDashboardOverview,
        getTrends: _apiService.getTrendData,
        getFxTransfers:
            includeFxTransfers ? _apiService.getFxTransfers : null,
        transactionsLimit: refetchLimit,
      );
      if (!mounted) return;
      setState(() {
        _transactions = mergeRefetchedTransactions(
          previous: _transactions ?? const [],
          refetched: data.transactions,
          requestedLimit: refetchLimit,
        );
        // A short page proves we now hold the tail of the table; a full
        // page tells us nothing new, so keep the flag as-is (recomputing
        // `length >= limit` here flipped hasMore back to true on a fully
        // loaded list and re-ran the filter cascade after every edit).
        if (data.transactions.length < refetchLimit) {
          _transactionsHasMore = false;
        }
        _overview = data.overview;
        _trendData = data.trends;
        if (data.fxTransfers != null) _fxTransfers = data.fxTransfers;
      });
    } catch (e) {
      // Same policy as a silent _loadAllData: a transient hiccup right
      // after a mutation must not blank the dashboard — keep the current
      // data on screen and let the next refresh reconcile.
      debugPrint('Post-mutation refresh error: $e');
    }
  }

  /// Trailing calendar-month window for a Cash Flow period. The backend
  /// counts back from the current month: months=1 is the current month,
  /// months=2 adds the prior month, etc.
  ///   thisMonth   -> 1
  ///   lastMonth   -> 2 (current + prior, so the card can headline the prior
  ///                  month AND show a vs-current delta)
  ///   threeMonths -> 3
  ///   ytd         -> months elapsed this year, i.e. current month number
  ///                  (Jan=1 .. so in June it's 6: Jan..Jun inclusive).
  int _monthsForCashFlowPeriod(CashFlowPeriod p) {
    switch (p) {
      case CashFlowPeriod.thisMonth:
        return 1;
      case CashFlowPeriod.lastMonth:
        return 2;
      case CashFlowPeriod.threeMonths:
        return 3;
      case CashFlowPeriod.ytd:
        // Current month number == count of months Jan..now inclusive. Clamp
        // to 1..12 defensively; the backend re-clamps to 1..24 anyway.
        return DateTime.now().month.clamp(1, 12);
    }
  }

  /// The single month BudgetsCard prices a monthly target against for a given
  /// Cash Flow period (item #11). Budgets are MONTHLY targets, so a multi-month
  /// window (3mo/YTD) is judged on its MOST RECENT month — never a sum/average.
  ///   thisMonth / threeMonths / ytd -> current month (window's most recent)
  ///   lastMonth                      -> the prior month (the month that
  ///                                     period headlines)
  /// Returned as a first-of-month DateTime; BudgetsCard reads only year+month.
  DateTime _budgetMonthForCashFlowPeriod(CashFlowPeriod p) {
    final now = DateTime.now();
    switch (p) {
      case CashFlowPeriod.lastMonth:
        // DateTime normalises month 0 → December of the prior year.
        return DateTime(now.year, now.month - 1);
      case CashFlowPeriod.thisMonth:
      case CashFlowPeriod.threeMonths:
      case CashFlowPeriod.ytd:
        return DateTime(now.year, now.month);
    }
  }

  /// Fetch the period-specific trend series for the Cash Flow tab and rebuild.
  /// Leaves [_trendData] (the shared 12-month series) untouched so the rest of
  /// the dashboard is unaffected. The api_service cache key folds in the
  /// month window, so switching periods refetches rather than reusing a stale
  /// series.
  Future<void> _onCashFlowPeriodChanged(CashFlowPeriod period) async {
    setState(() {
      _cashFlowPeriod = period;
      _cashFlowLoading = true;
    });
    final months = _monthsForCashFlowPeriod(period);
    try {
      final raw = await _apiService.getTrendData(months: months);
      if (!mounted) return;
      setState(() {
        _cashFlowTrends =
            raw.map((e) => e as Map<String, dynamic>).toList();
        _cashFlowLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      // Keep whatever's on screen; just clear the spinner.
      setState(() => _cashFlowLoading = false);
      debugPrint('Cash-flow period fetch error: $e');
    }
  }

  /// Compact period chooser pinned to the top of the Cash Flow tab. Mirrors
  /// the SegmentedButton style used elsewhere (e.g. the portfolio Flat/By
  /// account toggle) so it reads as native. Horizontally scrollable so the
  /// four labels never overflow on a phone.
  ///
  /// Below ~420px the compact-density SegmentedButton's segments fall under
  /// the 48dp touch floor and the four labels crowd; phones instead get a
  /// horizontally scrolling row of ChoiceChips — the same pattern as
  /// SpendingByCategoryCard's `_rangeSelector`.
  Widget _buildCashFlowPeriodSelector(AppLocalizations l) {
    if (MediaQuery.sizeOf(context).width < 420) {
      final periods = <(CashFlowPeriod, String)>[
        (CashFlowPeriod.thisMonth, l.cfPeriodThisMonth),
        (CashFlowPeriod.lastMonth, l.cfPeriodLastMonth),
        (CashFlowPeriod.threeMonths, l.cfPeriod3Months),
        (CashFlowPeriod.ytd, l.cfPeriodYtd),
      ];
      return SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < periods.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              ChoiceChip(
                label: Text(periods[i].$2),
                selected: _cashFlowPeriod == periods[i].$1,
                labelStyle: TextStyle(
                  fontSize: 12,
                  color: _cashFlowPeriod == periods[i].$1
                      ? context.positive
                      : context.textMuted,
                  fontWeight: _cashFlowPeriod == periods[i].$1
                      ? FontWeight.bold
                      : FontWeight.normal,
                ),
                showCheckmark: false,
                // Null while a period fetch is in flight — disables the
                // chips the same way the SegmentedButton branch disables
                // onSelectionChanged.
                onSelected: _cashFlowLoading
                    ? null
                    : (_) {
                        final value = periods[i].$1;
                        if (value == _cashFlowPeriod) return;
                        _onCashFlowPeriodChanged(value);
                      },
              ),
            ],
            // Trailing breathing room so the last chip never touches the
            // screen edge mid-scroll.
            const SizedBox(width: 16),
          ],
        ),
      );
    }
    return Align(
      alignment: Alignment.centerLeft,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: SegmentedButton<CashFlowPeriod>(
          segments: [
            ButtonSegment(
              value: CashFlowPeriod.thisMonth,
              label: Text(l.cfPeriodThisMonth),
            ),
            ButtonSegment(
              value: CashFlowPeriod.lastMonth,
              label: Text(l.cfPeriodLastMonth),
            ),
            ButtonSegment(
              value: CashFlowPeriod.threeMonths,
              label: Text(l.cfPeriod3Months),
            ),
            ButtonSegment(
              value: CashFlowPeriod.ytd,
              label: Text(l.cfPeriodYtd),
            ),
          ],
          selected: {_cashFlowPeriod},
          showSelectedIcon: false,
          onSelectionChanged: _cashFlowLoading
              ? null
              : (s) => _onCashFlowPeriodChanged(s.first),
          style: ButtonStyle(
            visualDensity: VisualDensity.compact,
            textStyle:
                WidgetStateProperty.all(const TextStyle(fontSize: 12)),
          ),
        ),
      ),
    );
  }

  /// Targeted refresh after hiding/unhiding a subscription merchant. Only
  /// the two subscription lists can change — re-pricing stocks and
  /// re-pulling the whole dashboard for that was pure waste.
  Future<void> _refreshSubscriptionLists() async {
    final results = await Future.wait([
      _apiService.getSubscriptions().catchError((_) => <dynamic>[]),
      _apiService
          .getIgnoredSubscriptions()
          .catchError((_) => <dynamic>[]),
    ]);
    if (!mounted) return;
    setState(() {
      _subscriptions = results[0];
      _ignoredSubscriptions = results[1];
    });
  }

  /// Append the next page. [limit] overrides the default page size — the
  /// filter cascade in [TransactionsTab] passes the backend's per-request
  /// cap (see [kTxBackendMaxPageSize]) so loading the whole history costs
  /// a handful of round-trips instead of one per 50 rows.
  Future<void> _loadMoreTransactions({int? limit}) async {
    final pageSize = limit ?? _txPageSize;
    final offset = _transactions?.length ?? 0;
    final more =
        await _apiService.getTransactions(limit: pageSize, offset: offset);
    if (!mounted) return;
    setState(() {
      _transactions = [...(_transactions ?? const []), ...more];
      // If the server returned fewer rows than we asked for, we hit the
      // tail of the table — no point offering Load more again.
      _transactionsHasMore = more.length >= pageSize;
    });
  }

  /// State-level reconnect handler so non-tab UI (the sticky sync
  /// banner) can open Plaid Link directly without hopping to the
  /// Management tab first. Mirrors the nested `handleReconnect` used
  /// from the Management tab's row buttons; both feed into the same
  /// `PlaidLink.open()` flow.
  static const _syncBannerSnoozeKey = 'sync_banner_snooze';

  /// Load the persisted sync-banner snooze (institution ids + expiry).
  Future<void> _loadSyncBannerSnooze() async {
    try {
      final raw = await _apiService.getSetting(_syncBannerSnoozeKey);
      if (raw is! Map) return;
      final until = DateTime.tryParse((raw['until'] ?? '').toString());
      final ids = (raw['ids'] as List?)
              ?.map((e) => e.toString())
              .toSet() ??
          <String>{};
      if (!mounted) return;
      setState(() {
        _syncBannerSnoozeUntil = until;
        _syncBannerSnoozeIds = ids;
      });
    } catch (_) {/* absent / unreadable → no snooze */}
  }

  /// Dismiss the sync-error banner for [problemIds] for a week. A NEW
  /// institution failing (an id not in this set) re-shows it immediately.
  Future<void> _snoozeSyncBanner(Set<String> problemIds) async {
    final until = DateTime.now().add(const Duration(days: 7));
    setState(() {
      _syncBannerSnoozeIds = problemIds;
      _syncBannerSnoozeUntil = until;
    });
    try {
      await _apiService.putSetting(_syncBannerSnoozeKey, {
        'until': until.toIso8601String(),
        'ids': problemIds.toList(),
      });
    } catch (_) {/* local dismissal still holds for the session */}
  }

  Future<void> _loadLenderName() async {
    try {
      final raw = await _apiService.getSetting('lender_name');
      if (raw is String && raw.isNotEmpty && mounted) {
        _lenderNameCtrl.text = raw;
      }
    } catch (_) {/* absent → keep empty (agreement falls back to username) */}
  }

  Future<void> _saveLenderName() async {
    setState(() => _savingLenderName = true);
    try {
      await _apiService.putSetting('lender_name', _lenderNameCtrl.text.trim());
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).dashLenderNameSaved)),
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).dashLenderNameSaveFailed)),
        );
      }
    } finally {
      if (mounted) setState(() => _savingLenderName = false);
    }
  }

  Future<void> _handleReconnect(String institutionId) async {
    setState(() => _isLoading = true);
    try {
      final data = await _apiService.getReconnectToken(institutionId);
      final linkToken = data['link_token'];
      _listenPlaid((_) {
        debugPrint('Plaid reconnect success');
        // Defer to the global sync via the public API method so the
        // dashboard data refreshes once tokens roll forward.
        _apiService.syncInstitutions().then((_) {
          if (mounted) _loadAllData(silent: true);
        }).catchError((_) {});
      }, (_) {
        if (mounted) _loadAllData(silent: true);
      });
      // mode:'reconnect' tags the persisted session so an OAuth redirect
      // resumes into a re-sync rather than a new-institution exchange.
      openPlaidLink(linkToken, mode: 'reconnect');
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(AppLocalizations.of(context).dashReconnectFailed(e.toString()))),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// Trigger `POST /api/institutions/update-webhook` to backfill the
  /// configured PLAID_WEBHOOK_URL onto every existing Plaid item, then
  /// show a dialog with the per-row result table. Used by the
  /// plaid_webhook tile in the Management tab's setup card after the
  /// operator first sets PLAID_WEBHOOK_URL on a deployment that
  /// already has linked items.
  Future<void> _pushWebhookToAllInstitutions() async {
    final l = AppLocalizations.of(context);
    setState(() => _isLoading = true);
    try {
      final result = await _apiService.updateWebhooks();
      if (!mounted) return;
      final updated = (result['updated'] as num?)?.toInt() ?? 0;
      final failed = (result['failed'] as num?)?.toInt() ?? 0;
      final results = (result['results'] as List?) ?? const [];
      final url = result['webhook_url']?.toString() ?? '';
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: Text(failed == 0
              ? l.dashWebhookPushed(updated)
              // gen-l10n orders these alphabetically → (failed, updated); pass failed first.
              : l.dashWebhookPartial(failed, updated)),
          content: SizedBox(
            width: 420,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (url.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: SelectableText(
                        url,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ...results.map((raw) {
                    final row = raw as Map<String, dynamic>;
                    final ok = row['ok'] == true;
                    final name = row['name']?.toString() ?? l.dashUnknown;
                    final reason = row['reason']?.toString() ?? '';
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 3),
                      child: Row(
                        children: [
                          Icon(
                            ok ? Icons.check_circle : Icons.error_outline,
                            size: 16,
                            color: ok
                                ? context.positive
                                : context.negative,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              ok ? name : '$name — $reason',
                              style: TextStyle(
                                fontSize: 12,
                                color: ok
                                    ? context.textPrimary
                                    : context.negative,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l.actionClose),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(l.dashPushFailed(e.toString()))),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  /// [forceRefresh] bypasses the ApiService response cache for the heavy
  /// dashboard GETs. We set it on realtime-driven reloads and explicit
  /// user-initiated refreshes (pull-to-refresh) so those paths never serve
  /// stale finance numbers. Ordinary reloads (sub-screen return) ride the
  /// cache; post-mutation reloads are already fresh because every mutation
  /// clears the cache in ApiService.
  Future<void> _loadAllData({
    bool silent = false,
    bool forceRefresh = false,
  }) async {
    if (!silent) {
      setState(() {
        _isLoading = true;
        _error = null;
      });
    } else {
      setState(() => _error = null);
    }

    // Snapshot the current brightness BEFORE we await — using the
    // BuildContext after an async gap trips
    // `use_build_context_synchronously`. The categoryColors map only
    // needs to know which side of the theme to pull from, not the live
    // context.
    final brightness = Theme.of(context).brightness;

    // Depth-preserving reload: silent refreshes (realtime push, sub-screen
    // return) must not snap a deep-loaded transaction list back to page 1
    // — that visibly reset the list and re-triggered the filter cascade.
    final txLimit = txRefetchLimit(
        loadedCount: _transactions?.length ?? 0, pageSize: _txPageSize);

    try {
      final results = await Future.wait([
        _apiService.getDashboardOverview(forceRefresh: forceRefresh),
        _apiService.getNetWorthHistory(forceRefresh: forceRefresh),
        _apiService.getHoldings(forceRefresh: forceRefresh),
        _apiService.getCreditUtilization(forceRefresh: forceRefresh),
        _apiService.getSyncStatus(forceRefresh: forceRefresh),
        _apiService.getSetupStatus(),
        _apiService.getExchangeRate('USD', 'MXN'),
        _apiService.getTransactions(limit: txLimit),
        _apiService.getAllocationData(forceRefresh: forceRefresh),
        _apiService.getTrendData(forceRefresh: forceRefresh),
        // These two are non-blocking — a failure shouldn't take the
        // whole dashboard down. Wrap each Future so it can't propagate.
        _apiService
            .getSinceLastLogin(forceRefresh: forceRefresh)
            .catchError((_) => null),
        _apiService
            .getSubscriptions(forceRefresh: forceRefresh)
            .catchError((_) => <dynamic>[]),
        _apiService
            .getFxTransfers(forceRefresh: forceRefresh)
            .catchError((_) => <dynamic>[]),
        _apiService
            .getIgnoredSubscriptions(forceRefresh: forceRefresh)
            .catchError((_) => <dynamic>[]),
        // Best-effort: a settings failure shouldn't take the dashboard
        // down — just default the module off.
        _apiService.getSetting('lending_enabled').catchError((_) => null),
        // Loan reminders + lead-time setting. Both defensive — empty /
        // default when lending is off or the call fails.
        _apiService
            .getLoanReminders(forceRefresh: forceRefresh)
            .catchError((_) => <dynamic>[]),
        _apiService
            .getSetting('lending_reminder_lead_days')
            .catchError((_) => null),
        // Spending-insight deltas for the notifications bell. Best-effort —
        // a failure just drops the spending-up rows, never the dashboard.
        _apiService
            .getSpendingInsights(forceRefresh: forceRefresh)
            .catchError((_) => <String, dynamic>{}),
        // Auto-archived accounts (closed at the bank) for the notifications
        // bell. Best-effort — a failure just drops the archived-account rows,
        // never the dashboard.
        _apiService.getArchivedAccounts().catchError((_) => <dynamic>[]),
        // Loans for the Overview "Lending" glance card. Best-effort — a
        // failure (or lending being off) just hides the card.
        _apiService.getLoans().catchError((_) => <dynamic>[]),
        // Portfolio-wide dividend income for the Overview "Dividends/yr"
        // tile (O1). Already best-effort (returns null on failure) and
        // served from the backend's cached dividend fan-out — one request,
        // no per-tile quote storm.
        _apiService.getPortfolioDividends(),
      ]);

      debugPrint("All data loaded successfully");

      final allocationRaw = results[8] as List<dynamic>;
      final trendsRaw = results[9] as List<dynamic>;

      setState(() {
        _overview = results[0] as Map<String, dynamic>;
        _netWorthHistory = results[1] as List<dynamic>;
        _portfolioData = results[2] as Map<String, dynamic>;
        _creditData = results[3] as List<dynamic>;
        _syncData = results[4] as List<dynamic>;
        _setupStatus = results[5] as Map<String, dynamic>;
        _fxRate = results[6] as Map<String, dynamic>;
        final refetchedTxs = results[7] as List<dynamic>;
        _transactions = mergeRefetchedTransactions(
          previous: _transactions ?? const [],
          refetched: refetchedTxs,
          requestedLimit: txLimit,
        );
        // If the page came back smaller than what we asked for, the server
        // ran out of rows — there can't be more pages. A full page on a
        // depth-preserving reload tells us nothing new, so keep the flag.
        if (refetchedTxs.length < txLimit) {
          _transactionsHasMore = false;
        }

        _allocationData = _mapAllocationData(allocationRaw, brightness);

        _trendData = trendsRaw.map((e) => e as Map<String, dynamic>).toList();
        _sinceLastLogin = results[10] as Map<String, dynamic>?;
        _subscriptions = results[11] as List<dynamic>;
        _fxTransfers = results[12] as List<dynamic>;
        _ignoredSubscriptions = results[13] as List<dynamic>;
        // Lending module toggle (server-side). The setting stores a
        // raw bool; absent/null = treated as ON (lending is visible by
        // default — the user opts out rather than opting in).
        _applyLendingSetting(results[14] != false);
        // First load: now that the lending flag (and thus the full
        // section list) is known, resolve the saved section. A saved
        // "Lending" that wasn't yet in _destinations lands correctly here.
        if (_pendingRestore != null) {
          _section = _indexOfNav(_pendingRestore) ?? _section;
          _pendingRestore = null;
        }
        _loanReminders = results[15] as List<dynamic>;
        final leadRaw = results[16];
        if (leadRaw is num) {
          _lendingReminderLeadDays = leadRaw.toInt().clamp(0, 60);
        }
        final insightsRaw = results[17];
        _spendingInsights = insightsRaw is Map<String, dynamic> ? insightsRaw : null;
        _archivedAccounts = results[18] as List<dynamic>;
        _loans = results[19] as List<dynamic>;
        _portfolioDividends = results[20] as Map<String, dynamic>?;
        _isLoading = false;
      });

      debugPrint(
        "State updated with Phase 7 data: ${_allocationData?.length} categories, ${_trendData?.length} trend months",
      );

      // A just-linked institution lands in 'syncing' until its background
      // Plaid sync finishes (exchange-token returns first). Keep refreshing
      // until it clears so the new accounts appear on their own.
      _scheduleSyncPollIfNeeded();
    } catch (e, stack) {
      debugPrint("Data load error: $e\n$stack");
      // Only surface the error screen on an EXPLICIT (non-silent) load. A
      // silent background refresh — e.g. the one fired right after deleting
      // an account, while its transactions are still cascading — must not
      // blank the dashboard on a transient hiccup; keep the current data on
      // screen and let the next refresh / realtime event reconcile.
      if (!silent) {
        setState(() {
          _error = e.toString().replaceFirst('Exception: ', '');
          _isLoading = false;
        });
      }
    }
  }

  /// Maps the raw /allocation rows into [AllocationData], resolving each
  /// category's colour for the given theme [brightness]. Shared by
  /// [_loadAllData] and [_refreshPortfolioData] so a targeted portfolio
  /// refresh keeps the exact same colour + asset-class semantics.
  List<AllocationData> _mapAllocationData(
      List<dynamic> raw, Brightness brightness) {
    // Allocation slice colours. Pulled through brand tokens so the
    // pie reads against a white card in light mode without each slice
    // having to be hand-tuned. The 6 categories map 1:1 to the
    // semantic accents already exposed by BrandPalette.
    // Keys are the Title-Cased categories the allocation endpoint emits
    // (INITCAP'd holding_type + the Cash/Crypto union literals). Keep
    // Equity/Mutual Fund here too or those bands fall back to grey.
    final categoryColors = {
      'Cash': BrandPalette.info(brightness),
      'Stocks/ETFs': BrandPalette.teal(brightness),
      'Equity': BrandPalette.teal(brightness),
      'Mutual Fund': BrandPalette.yellow(brightness),
      'Investment': BrandPalette.positive(brightness),
      'Crypto': BrandPalette.purple(brightness),
      'Fixed Income': BrandPalette.positive(brightness),
      'Other': BrandPalette.negative(brightness),
      // C-G: holdings-less investment accounts (balance only). Muted
      // neutral, NOT a category hue — the heatmap renders this band
      // inert/non-tappable (keyed off asset_class == 'unclassified').
      'Unclassified': BrandPalette.neutral(brightness),
    };

    return raw.map((e) {
      // Coerce defensively: a null/omitted sub_category or value (JSON
      // whole numbers also decode as int) would otherwise throw here and
      // crash the allocation-heatmap build — the same class as the
      // trends_chart int-vs-double crash.
      final category = e['category'] as String? ?? '';
      final subCategory = e['sub_category'] as String? ?? '';
      final value = (e['value'] as num? ?? 0).toDouble();
      final quantity = (e['quantity'] as num?)?.toDouble() ?? 0.0;
      // Canonical asset-class key (C2). Defensive: older backends
      // don't send it — null makes the heatmap fall back to emitting
      // the legacy bare category as the filter value.
      // C-G rows (asset_class == 'unclassified': investment accounts
      // with a balance but no holdings rows) pass through here like
      // every other entry; the heatmap renders them as the inert
      // "Unclassified (account balance)" band.
      final assetClassRaw = e['asset_class'];
      final assetClass = assetClassRaw is String && assetClassRaw.isNotEmpty
          ? assetClassRaw
          : null;

      return AllocationData(
        category,
        subCategory,
        value,
        categoryColors[category] ?? context.neutralAccent,
        quantity: quantity,
        assetClassKey: assetClass,
      );
    }).toList();
  }

  /// Scrolls the Portfolio tab's DividendIncomeCard into view (O1 tile
  /// tap-through). Post-frame so a just-mounted Portfolio section has laid
  /// out first; a second corrective pass follows because the self-fetching
  /// cards above (benchmark chart, dividend skeleton → content) can shift
  /// layout right after the first scroll on a cold mount.
  void _scrollToDividendCard({int attempt = 0}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ctx = _dividendCardKey.currentContext;
      if (!mounted || ctx == null) return;
      Scrollable.ensureVisible(
        ctx,
        duration: const Duration(milliseconds: 400),
        curve: Curves.easeInOutCubic,
        // Land the card near the top of the viewport so its header +
        // summary tiles are visible.
        alignment: 0.05,
      );
      if (attempt == 0) {
        Future.delayed(const Duration(milliseconds: 700), () {
          if (mounted) _scrollToDividendCard(attempt: 1);
        });
      }
    });
  }

  /// O3 (contract C3-D): targeted refresh of the holdings table +
  /// allocation heatmap after an in-sheet mutation (asset-class override,
  /// delete/undo) — no full-dashboard reload. forceRefresh bypasses the
  /// ApiService response cache so the re-fetch reflects the mutation
  /// immediately. Best-effort: a transient failure keeps the current data.
  //
  // Re-fetches holdings + allocation after an instrument-sheet change
  // (asset-class override) so the table and bands agree without a reload.
  Future<void> _refreshPortfolioData() async {
    // Snapshot brightness before the await (use_build_context_synchronously),
    // same as _loadAllData.
    final brightness = Theme.of(context).brightness;
    try {
      final results = await Future.wait([
        _apiService.getHoldings(forceRefresh: true),
        _apiService.getAllocationData(forceRefresh: true),
      ]);
      if (!mounted) return;
      setState(() {
        _portfolioData = results[0] as Map<String, dynamic>;
        _allocationData =
            _mapAllocationData(results[1] as List<dynamic>, brightness);
      });
    } catch (e) {
      debugPrint('Portfolio refresh error: $e');
    }
  }

  /// Newly-linked institutions sit in `sync_status == 'syncing'` until their
  /// background Plaid sync finishes — `exchange-token` returns before it does.
  /// While anything is syncing, force-refresh on a short interval so the new
  /// accounts surface without the user hitting "sync all". Bounded so a stuck
  /// institution can't poll forever; the realtime AccountsChanged push covers
  /// the instant case when the websocket is connected (e.g. over the tunnel).
  void _scheduleSyncPollIfNeeded() {
    _syncPollTimer?.cancel();
    final anySyncing = (_syncData ?? const []).any(
        (e) => e is Map && e['sync_status']?.toString() == 'syncing');
    if (!anySyncing) {
      _syncPollAttempts = 0;
      return;
    }
    if (_syncPollAttempts >= 15) return; // ~45s cap, then leave it to the user
    _syncPollAttempts++;
    _syncPollTimer = Timer(const Duration(seconds: 3), () {
      // forceRefresh so the poll sees fresh sync_status + the new accounts,
      // not a cached snapshot.
      if (mounted) _loadAllData(silent: true, forceRefresh: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final isCompact = MediaQuery.sizeOf(context).width < 720;

    // Currency context for AppBar-level surfaces (notifications bell jump-to
    // account panel). Mirrors the per-tab computation used deeper in build.
    final fxRate = (_fxRate?['rate'] as num?)?.toDouble() ?? 1.0;
    final conversionFactor = _targetCurrency == 'MXN' ? fxRate : 1.0;
    final currencyFormat = moneyFormat(_targetCurrency);

    // During the first-run state we strip the chrome: tab bar (every tab
    // would be empty) and currency / FX controls (no balances to convert).
    final firstRun = _isFirstRun;

    // Built once, then either used as-is (wide, first-run) or handed to the
    // scroll-away shell below — the bar's contents never change between the
    // two paths.
    final appBar = AppBar(
          // Compact widths: the slimmed actions row (app-bar audit) leaves
          // room for the current destination's name — same label as the
          // selected bottom-nav item, and a page heading for screen
          // readers. First-run keeps the wordmark (its chrome is hidden,
          // so there's room and no destination to name).
          title: isCompact
              ? Text(
                  firstRun
                      ? 'Patrimonio'
                      : _navShortLabel(
                          AppLocalizations.of(context), _currentDest.id),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                )
              : const FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    'Patrimonio',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
          actions: [
            // First-run hides the dashboard chrome (FX, notifications,
            // currency toggle) because none of it has data yet. Sign
            // out and theme cycle stay so the user can always escape
            // or change brightness.
            if (!firstRun) ...[
              // Touch-reachable entry to the command palette — the
              // ⌘K/Ctrl+K shortcut is keyboard-only, so without this the
              // palette is unreachable on mobile. Gated on !firstRun like
              // the other data-dependent actions (the palette items need
              // loaded data).
              IconButton(
                icon: const Icon(Icons.search),
                tooltip: AppLocalizations.of(context).dashSearchCommandsTooltip,
                onPressed: _openPalette,
              ),
              // Sandbox / Development indicator.
              if (!isCompact) _buildEnvChip(),
              if (!isCompact) const SizedBox(width: 8),
              // FX pill — wide only. On phones the standalone pill was the
              // over-budget 4th+ bar action AND a bordered chip with no tap
              // handler (app-bar audit findings 1-2); the rate now rides
              // inside the combined currency chip below instead.
              if (!isCompact) ...[
                _buildFxBadge(compact: true),
                const SizedBox(width: 8),
              ],
              NotificationsBell(
                dismissedIds: _dismissedNotifs,
                onMarkAllRead: (ids) {
                  setState(() => _dismissedNotifs = ids);
                  Preferences.setDismissedNotifications(ids);
                },
                notifications: deriveNotifications(
                  l: AppLocalizations.of(context),
                  brightness: Theme.of(context).brightness,
                  syncData: _syncData ?? const [],
                  netWorthHistory: _netWorthHistory ?? const [],
                  onJumpToManagement: () => _goToNav(NavId.settings),
                  loanReminders: _loanReminders,
                  // No-op when lending is off (the section isn't visible);
                  // the bell only surfaces loan reminders when it's on.
                  onJumpToLending: () => _goToNav(NavId.lending),
                  accounts: (_overview?['accounts'] as List?) ?? const [],
                  accountAlerts: _accountAlerts,
                  spendingInsights: _spendingInsights,
                  subscriptions: _subscriptions ?? const [],
                  onJumpToSpending: () => _goToNav(NavId.cashFlow),
                  archivedAccounts: _archivedAccounts ?? const [],
                  onJumpToClosedAccounts: () => Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const HiddenItemsScreen())),
                  onJumpToAccount: (account) => showAccountTransactionsPanel(
                    context,
                    account: account,
                    allAccounts:
                        (_overview?['accounts'] as List?) ?? const [],
                    conversionFactor: conversionFactor,
                    currencyFormat: currencyFormat,
                    targetCurrency: _targetCurrency,
                    usdMxnRate: fxRate,
                    onBalanceUpdate: (id, bal) async {
                      try {
                        await _apiService.updateAccountBalance(id, bal);
                        _loadAllData(silent: true);
                      } catch (_) {}
                    },
                    onRenameAccount: (id, nickname) async {
                      try {
                        await _apiService.renameAccount(id, nickname);
                        _loadAllData(silent: true);
                      } catch (_) {}
                    },
                    onAlertsChanged: _reloadAccountAlerts,
                  ),
                ),
              ),
            ],
            // Compact widths get theme selection from the Settings tab
            // instead — five always-on icons crowded a 360px AppBar. During
            // first-run the bottom nav (and thus the Settings tab) is
            // hidden, so the cycle button shows on all widths there.
            if (!isCompact || firstRun) _ThemeCycleButton(),
            // First-run escape hatch: language now lives on the Settings
            // tab, which is hidden with the rest of the nav chrome here —
            // keep the kebab's EN ⇄ ES toggle on the bar so a
            // freshly-registered user can switch locale. Tooltip is the
            // autonym of the language you'd switch TO (deliberately not
            // localized, matching the Settings-tab language picker).
            if (firstRun)
              IconButton(
                icon: const Icon(Icons.translate),
                tooltip:
                    Localizations.localeOf(context).languageCode == 'es'
                        ? 'English'
                        : 'Español',
                onPressed: () {
                  final next =
                      Localizations.localeOf(context).languageCode == 'es'
                          ? 'en'
                          : 'es';
                  // Same persist + live-notify pattern as the Settings
                  // tab's picker.
                  Preferences.setLocale(next);
                  localeNotifier.value = Locale(next);
                },
              ),
            // First-run escape hatch: with the nav chrome hidden there is
            // no other path to sign out, so the bar carries a confirmed
            // sign-out action (never a direct logout).
            if (firstRun)
              IconButton(
                icon: const Icon(Icons.logout),
                tooltip: l.dashSignOut,
                onPressed: _confirmSignOut,
              ),
            if (!firstRun)
              // Compact: one combined "USD · 17.51" chip (48dp target, tap
              // toggles the display currency, carries the FX rate the
              // standalone pill used to show). Wide keeps the separate
              // badge + toggle.
              isCompact
                  ? _buildCurrencyFxChip()
                  : _CurrencyToggleButton(
                      targetCurrency: _targetCurrency,
                      onSwap: () => _setTargetCurrency(
                          _targetCurrency == 'USD' ? 'MXN' : 'USD'),
                    ),
            const SizedBox(width: 8),
          ],
        );
    // Scroll-away app bar (enter-always + snap): compact non-first-run
    // widths wrap the bar in the collapsing shell driven by _appBarVisible.
    // Wide and first-run keep the static bar untouched.
    final PreferredSizeWidget topBar = (isCompact && !firstRun)
        ? _CollapsingAppBar(visible: _appBarVisible, child: appBar)
        : appBar;

    return Shortcuts(
      shortcuts: <LogicalKeySet, Intent>{
        LogicalKeySet(LogicalKeyboardKey.meta, LogicalKeyboardKey.keyK):
            const _OpenPaletteIntent(),
        LogicalKeySet(LogicalKeyboardKey.control, LogicalKeyboardKey.keyK):
            const _OpenPaletteIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          _OpenPaletteIntent: CallbackAction<_OpenPaletteIntent>(
            onInvoke: (_) {
              if (!firstRun) _openPalette();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
              appBar: topBar,
              // Narrow screens get a Material 3 bottom nav bar; wide
              // screens get a left rail (built into the body Row below).
              bottomNavigationBar:
                  (!firstRun && isCompact) ? _buildBottomBar() : null,
              // Thumb-zone creation for the Activity tab: on compact
              // layouts the tab's toolbar '+' is hidden (hostProvidesAddFab)
              // and "Add transaction" moves here, docked above the bottom
              // nav. Wide layouts keep the inline '+' and never show the
              // FAB — both affordances key off the same isCompact signal,
              // so no width shows both. Section lookup mirrors _buildBody's
              // clamped indexing so a transient out-of-range _section can't
              // throw. The tab is mounted whenever its section is selected
              // (IndexedStack marks it visited), so currentState is
              // non-null here; `?.` keeps any edge case a no-op.
              floatingActionButton: (!firstRun &&
                      isCompact &&
                      _destinations[_section.clamp(0, _destinations.length - 1)]
                              .id ==
                          NavId.transactions)
                  ? FloatingActionButton(
                      tooltip: l.txAddTransaction,
                      onPressed: () => _txTabKey.currentState?.openAddDialog(),
                      child: const Icon(Icons.add),
                    )
                  : null,
              // Scroll-away app bar: every tab's scrollables (tab-level
              // SingleChildScrollViews, tabs that own internal scrollables,
              // and the Activity tab's inner virtualised list) bubble
              // UserScrollNotification up to here, so no tab file changes.
              // setState fires only when visibility actually flips — i.e. on
              // scroll-direction changes, never per scrolled pixel. Returning
              // false keeps the notifications bubbling (AppBar lift-on-scroll
              // relies on them too). SyncErrorBanner stays inside the pinned
              // Column — it is an alert and never scrolls away.
              body: NotificationListener<UserScrollNotification>(
                onNotification: (n) {
                  if (isCompact && !firstRun) {
                    final visible = barVisibleAfter(
                      direction: n.direction,
                      axis: n.metrics.axis,
                      pixels: n.metrics.pixels,
                    );
                    if (visible != null && visible != _appBarVisible) {
                      setState(() => _appBarVisible = visible);
                    }
                  }
                  return false;
                },
                child: Column(
                children: [
                  if (!firstRun)
                    SyncErrorBanner(
                      syncData: _syncData ?? const [],
                      onJumpToManagement: () => _goToNav(NavId.settings),
                      // Open Plaid Link directly so a "Chase needs
                      // reconnecting" banner is one click to resolve,
                      // not three (banner → Settings → row button).
                      onReconnect: _handleReconnect,
                      dismissedIds: _syncBannerSnoozeIds,
                      dismissedUntil: _syncBannerSnoozeUntil,
                      onDismiss: _snoozeSyncBanner,
                    ),
                  Expanded(
                    child: (!firstRun && !isCompact)
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              _buildNavRail(),
                              const VerticalDivider(width: 1, thickness: 1),
                              Expanded(child: _buildBody()),
                            ],
                          )
                        : _buildBody(),
                  ),
                ],
                ),
              ),
            ),
          ),
        ),
      );
  }

  Widget _buildBody() {
    final l = AppLocalizations.of(context);
    if (_isLoading) {
      // Skeleton mirrors the Overview tab's actual KPI / cash-flow / body
      // layout so the page doesn't reflow when data arrives. Other tabs
      // are gated behind this load so a single overview skeleton suffices.
      return const OverviewSkeleton();
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: context.negative),
            const SizedBox(height: 16),
            Text(
              l.dashErrorLoading(_error ?? ''),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadAllData, child: Text(l.dashRetry)),
          ],
        ),
      );
    }

    if (_isFirstRun) {
      return _buildOnboardingHero();
    }

    final fxRate = (_fxRate?['rate'] as num?)?.toDouble() ?? 1.0;
    final conversionFactor = _targetCurrency == 'MXN' ? fxRate : 1.0;
    // Idiomatic symbol ($/MX$) via the shared helper so the hero number and
    // every card fed this formatter read "$1,234.00" not "USD 1,234.00".
    final currencyFormat = moneyFormat(_targetCurrency);
    // Same compact signal the Scaffold uses for the bottom bar + FAB, so
    // the Activity tab's hostProvidesAddFab flips in lockstep with the
    // FAB's visibility (no width band shows both '+' affordances or none).
    final isCompact = MediaQuery.sizeOf(context).width < 720;
    Widget buildTabContainer(Widget child,
        {bool scrollable = true, Future<void> Function()? onRefresh}) {
      final padding = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
      // Extra scrollable space at the very bottom so a transient SnackBar
      // (notably the 30s "Syncing…" one) never sits on top of the last
      // interactive controls — e.g. the Link Coinbase / Connect Bitso
      // buttons at the foot of Settings. The user can always scroll those
      // clear of the snackbar instead of having it block the tap target.
      const snackbarClearance = 88.0;
      final content = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1600),
          child: child,
        ),
      );

      if (!scrollable) {
        return Padding(padding: EdgeInsets.all(padding), child: content);
      }
      final scrollView = SingleChildScrollView(
        // Pull-to-refresh needs a scrollable even when the content fits.
        physics: onRefresh != null
            ? const AlwaysScrollableScrollPhysics()
            : null,
        padding: EdgeInsets.fromLTRB(
            padding, padding, padding, padding + snackbarClearance),
        child: content,
      );
      // Mobile-native refresh gesture (mirrors LendingTab). Callers pass the
      // light data refetch, never runSync — a 30s bank sync is too heavy for
      // an accidental overscroll.
      return onRefresh == null
          ? scrollView
          : RefreshIndicator(onRefresh: onRefresh, child: scrollView);
    }

    Widget buildAccountsColumn() {
      return Column(
        children: [
          AccountsListWidget(
            accounts: _overview?['accounts'] ?? [],
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
            targetCurrency: _targetCurrency,
            usdMxnRate: fxRate,
            onAddAccount: _openAddAccount,
            onAlertsChanged: _reloadAccountAlerts,
            onBalanceUpdate: (id, bal) async {
              try {
                await _apiService.updateAccountBalance(id, bal);
                _loadAllData(silent: true);
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text(l.dashUpdateFailed(e.toString()))));
              }
            },
            onDeleteAccount: (id) async {
              try {
                await _apiService.deleteAccount(id);
                _loadAllData(silent: true);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l.dashAccountDeleted)),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l.dashDeleteFailed(e.toString()))),
                );
              }
            },
            onRenameAccount: (id, nickname) async {
              try {
                await _apiService.renameAccount(id, nickname);
                _loadAllData(silent: true);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      nickname.isEmpty
                          ? l.dashNicknameCleared
                          : l.dashRenamedTo(nickname),
                    ),
                  ),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l.dashRenameFailed(e.toString()))),
                );
              }
            },
            onRevalueAccount: (id, bal, notes) async {
              try {
                await _apiService.updateAccountBalance(id, bal, notes: notes);
                _loadAllData(silent: true);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      notes == null || notes.isEmpty
                          ? l.dashRevalued
                          : l.dashRevaluedNoteSaved,
                    ),
                  ),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(l.dashRevalueFailed(e.toString()))),
                );
              }
            },
          ),
          // CreditUtilizationCard self-hides when there are no credit
          // accounts; only spend the gap when it will actually render.
          if ((_creditData ?? const []).isNotEmpty) ...[
            const SizedBox(height: 20),
            CreditUtilizationCard(
              creditData: _creditData ?? [],
              conversionFactor: conversionFactor,
              usdMxnRate: fxRate,
              currencyFormat: currencyFormat,
            ),
          ],
        ],
      );
    }

    Widget buildNetWorthHeader() {
      return LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 520;
          final title = Text(
            l.dashNetWorthHistory,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          );
          final selector = SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DateRangeSelector(
              selectedRange: _selectedRange,
              onRangeChanged: (range) {
                setState(() => _selectedRange = range);
                Preferences.setDateRange(range.name);
              },
            ),
          );

          if (isNarrow) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 12),
                title,
                const SizedBox(height: 12),
                selector,
              ],
            );
          }

          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [title, selector],
          );
        },
      );
    }

    Future<void> runSync() async {
      // Progress shows INLINE on the Sync button (spinner + "Syncing…",
      // disabled), not as a long bottom SnackBar — a 30s snackbar sat on top
      // of the Link Coinbase / Connect Bitso buttons right below it and blocked
      // them. We keep only short (2s) completion/failure toasts, and refresh
      // the data silently when the call returns.
      if (_isSyncing) return;
      // Only Plaid/crypto institutions actually sync (manual/CSV/PDF are
      // skipped server-side), so the total reflects what will really update.
      final total = syncableInstitutionCount(_syncData);
      final startedAt = DateTime.now();
      setState(() {
        _isSyncing = true;
        _syncTotal = total;
        _syncDone = 0;
      });
      final messenger = ScaffoldMessenger.of(context);
      // While the backend syncs institutions concurrently, poll /sync-status
      // so the SyncStatusCard shows each account flip syncing→synced live and
      // the button shows a "(done/total)" count. An institution counts as done
      // once its last_synced_at advances past the moment we kicked off.
      Timer? poll;
      poll = Timer.periodic(const Duration(milliseconds: 1200), (_) async {
        try {
          final fresh = await _apiService.getSyncStatus(forceRefresh: true);
          if (!mounted) return;
          setState(() {
            _syncData = fresh;
            _syncDone = syncedSinceCount(fresh, startedAt);
          });
        } catch (_) {
          // Transient poll failure — keep going; the awaited call below is the
          // source of truth for completion.
        }
      });
      try {
        await _apiService.syncInstitutions();
        if (!mounted) return;
        messenger.showSnackBar(
          SnackBar(
            content: Text(l.dashSyncComplete),
            duration: const Duration(seconds: 2),
          ),
        );
      } catch (e) {
        debugPrint("Sync error: $e");
        if (!mounted) return;
        messenger.showSnackBar(
          SnackBar(content: Text(l.dashSyncFailed(e.toString()))),
        );
      } finally {
        poll.cancel();
        if (mounted) setState(() => _isSyncing = false);
      }
      // Reload without flipping _isLoading — just refresh the data fields.
      await _refreshData();
    }

    // Compact "last synced · Sync now" bar for the Overview, so refreshing
    // isn't buried in Settings. Reuses runSync + the inline _isSyncing state.
    Widget buildSyncBar() {
      DateTime? latest;
      for (final inst in (_syncData ?? const [])) {
        if (inst is Map && inst['last_synced_at'] != null) {
          final dt =
              DateTime.tryParse(inst['last_synced_at'].toString())?.toLocal();
          if (dt != null && (latest == null || dt.isAfter(latest))) {
            latest = dt;
          }
        }
      }
      final whenText = latest == null
          ? l.lwSyncNever
          : DateFormat('MMM d, h:mm a').format(latest);
      return Row(
        children: [
          Icon(Icons.sync, size: 14, color: context.textFaint),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              l.dashSyncedAt(whenText),
              style: TextStyle(fontSize: 12, color: context.textSubtle),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          if (_isSyncing)
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor:
                        AlwaysStoppedAnimation<Color>(context.textMuted),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _syncTotal > 0
                      ? l.dashSyncingProgress(_syncDone, _syncTotal)
                      : l.dashSyncingAll,
                  style: TextStyle(fontSize: 12, color: context.textMuted),
                ),
              ],
            )
          else
            TextButton.icon(
              onPressed: runSync,
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(l.dashSyncNow),
              style: TextButton.styleFrom(
                foregroundColor: context.info,
              ),
            ),
        ],
      );
    }

    Future<void> handleReconnect(String institutionId) async {
      setState(() => _isLoading = true);
      try {
        final data = await _apiService.getReconnectToken(institutionId);
        final linkToken = data['link_token'];

        _listenPlaid((event) {
          debugPrint("Plaid Reconnect Success");
          runSync();
        }, (event) {
          debugPrint("Plaid Reconnect Exit");
          _loadAllData(silent: true);
        });

        openPlaidLink(linkToken, mode: 'reconnect');
      } catch (e) {
        debugPrint("Reconnect error: $e");
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(l.dashReconnectFailed(e.toString()))));
        }
      } finally {
        setState(() => _isLoading = false);
      }
    }

    bool plaidReady() {
      return _setupStatus?['ready_for_plaid_linking'] == true;
    }

    Widget buildSetupStatusCard() {
      final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
      final checks = (_setupStatus?['checks'] as List?) ?? [];
      final blocking = checks
          .where(
            (check) =>
                check is Map &&
                check['configured'] != true &&
                check['severity'] == 'required_for_linking',
          )
          .toList();
      final recommended = checks
          .where(
            (check) =>
                check is Map &&
                check['configured'] != true &&
                check['severity'] == 'recommended',
          )
          .toList();

      // Does the caller have at least one Plaid-backed institution?
      // Used to gate the "Push webhook URL to existing items" action
      // on the plaid_webhook check — pointless to render the button
      // when there's nothing for it to update.
      final plaidInstitutionCount = (_syncData ?? const [])
          .where(
            (inst) =>
                inst is Map &&
                (inst['integration_type']?.toString().toLowerCase() ??
                        '')
                    .contains('plaid'),
          )
          .length;

      // Optional-but-unconfigured checks (FX without an API key, Coinbase
      // without OAuth creds) are non-events — hide them so they never read
      // as a warning. Optional checks still appear once configured, as a
      // green confirmation.
      final visibleChecks = checks.where((raw) {
        if (raw is! Map) return false;
        return raw['configured'] == true || raw['severity'] != 'optional';
      }).toList();

      // When nothing required is missing the card collapses to a single
      // "Ready" row; the full diagnostic list is one tap away. A missing
      // required check force-expands it so the warning can't be hidden.
      final ready = blocking.isEmpty;
      final showDetails = !ready || _setupExpanded;

      return Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: EdgeInsets.all(pad),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    ready
                        ? Icons.verified_user_outlined
                        : Icons.warning_amber_rounded,
                    color: ready ? context.positive : context.warning,
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.dashLaunchSetup,
                      style: const TextStyle(
                          fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ),
                  if (ready) ...[
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: context.positive.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        l.dashSetupReadyPill,
                        style: TextStyle(
                          color: context.positive,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    IconButton(
                      onPressed: () =>
                          setState(() => _setupExpanded = !_setupExpanded),
                      icon: Icon(_setupExpanded
                          ? Icons.expand_less
                          : Icons.expand_more),
                      tooltip: _setupExpanded
                          ? l.dashSetupHideDetails
                          : l.dashSetupShowDetails,
                      visualDensity: VisualDensity.compact,
                      color: context.textMuted,
                    ),
                  ],
                ],
              ),
              if (showDetails) ...[
                const SizedBox(height: 12),
                Text(
                  ready
                      ? l.dashLaunchSetupReady
                      : l.dashLaunchSetupBlocked,
                  style: TextStyle(color: context.textMuted, fontSize: 13),
                ),
                const SizedBox(height: 12),
                ...visibleChecks.map((raw) {
                final check = raw as Map<String, dynamic>;
                final configured = check['configured'] == true;
                final key = check['key']?.toString() ?? '';
                // Per-row trailing action. Today only the plaid_webhook
                // row gets one; designed as a switch so future checks
                // can hook in the same way without growing a wrapper
                // layer per check.
                Widget? trailing;
                if (key == 'plaid_webhook' &&
                    configured &&
                    plaidInstitutionCount > 0) {
                  trailing = TextButton.icon(
                    onPressed: () => _pushWebhookToAllInstitutions(),
                    icon: const Icon(Icons.cloud_upload_outlined, size: 16),
                    label: Text(
                      l.dashPushToInstitutions(plaidInstitutionCount),
                    ),
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                    ),
                  );
                }
                return Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        configured
                            ? Icons.check_circle
                            : check['severity'] == 'optional'
                            ? Icons.radio_button_unchecked
                            : Icons.error_outline,
                        color: configured
                            ? context.positive
                            : check['severity'] == 'optional'
                            ? context.textFaint
                            : context.warning,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              check['label'] ?? '',
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              check['detail'] ?? '',
                              style: TextStyle(
                                color: context.textSubtle,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (trailing != null) ...[
                        const SizedBox(width: 8),
                        trailing,
                      ],
                    ],
                  ),
                );
              }),
              if (recommended.isNotEmpty) ...[
                const SizedBox(height: 12),
                // Dynamic recap of what's still recommended-but-not-set.
                // Lists labels from the recommended set; falls back to a
                // generic line if all the labels happen to be missing.
                Text(
                  l.dashRecommendedBeforeProduction(recommended
                      .map((c) => (c as Map)['label']?.toString() ?? '')
                      .where((s) => s.isNotEmpty)
                      .join(', ')),
                  style: TextStyle(color: context.textSubtle, fontSize: 12),
                ),
              ],
              ],
            ],
          ),
        ),
      );
    }

    Widget buildChartsColumn({required bool compact}) {
      // Same horizontally-scrolling range selector buildNetWorthHeader
      // builds. On compact layouts it moves INSIDE the card, below the
      // chart, so range switching is thumb-reachable and visually bound to
      // the plot it controls.
      final rangeSelector = SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: DateRangeSelector(
          selectedRange: _selectedRange,
          onRangeChanged: (range) {
            setState(() => _selectedRange = range);
            Preferences.setDateRange(range.name);
          },
        ),
      );
      return Column(
        // Stretch, not the default center: children fill the column width
        // instead of centering when one is intrinsically narrower.
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Compact skips the floating 20px header — the card renders its
          // own overline title, and the range selector moves in-card.
          if (!compact) ...[
            buildNetWorthHeader(),
            const SizedBox(height: 12),
          ],
          // The card sizes itself: header at natural height + a
          // guaranteed chart height inside NetWorthCard. Pinning the card
          // to a fixed box here is what squished the chart to a sliver on
          // phones whenever the compact header wrapped taller than
          // budgeted (detailed-mode legend + currency chips).
          NetWorthCard(
            netWorth:
                ((_overview?['net_worth'] as num?)?.toDouble() ?? 0.0) *
                conversionFactor,
            history: _netWorthHistory ?? [],
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
            reportingCurrency: _targetCurrency,
            sourceBreakdown: _overview?['currency_breakdown'] ?? [],
            usdMxnRate: fxRate,
            selectedRange: _selectedRange,
            // The dashboard hero block directly above already shows the
            // net-worth figure — suppress the card's duplicate summary on
            // phones.
            showSummary: !compact,
            rangeSelector: compact ? rangeSelector : null,
          ),
          // Glanceable assets-vs-liabilities split. Skipped during
          // first-run when typeBreakdown is empty (the widget renders
          // a SizedBox.shrink in that case anyway).
          if ((_overview?['type_breakdown'] as List?)?.isNotEmpty ?? false) ...[
            SizedBox(height: compact ? 16 : 12),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: AssetsLiabilitiesBar(
                typeBreakdown: (_overview?['type_breakdown'] as List?) ?? const [],
                conversionFactor: conversionFactor,
              ),
            ),
          ],
        ],
      );
    }

    final overviewTab = buildTabContainer(
      // Pull-to-refresh: the light data refetch (stock re-price + cached
      // reads bypassed) — deliberately NOT runSync's 30s bank sync.
      onRefresh: _refreshData,
      LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 900;
          final stats = _buildStatStrip(
            currencyFormat: currencyFormat,
            conversionFactor: conversionFactor,
            usdMxnRate: fxRate,
          );
          // Per-currency assets/liabilities split — only meaningful (and only
          // rendered) when the user holds more than one currency.
          final currencySubStrip = _buildCurrencySubStrip(
            currencyFormat: currencyFormat,
            usdMxnRate: fxRate,
          );

          final body = isNarrow
              ? Column(
                  children: [
                    // On mobile the net-worth trend is the canonical glance,
                    // so it leads — the long accounts list follows. (On wide
                    // screens they sit side by side, order doesn't matter.)
                    buildChartsColumn(compact: true),
                    const SizedBox(height: 16),
                    buildAccountsColumn(),
                  ],
                )
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Accounts column gets ~1/3 (was 1/4) so account names,
                    // balances and nested vault rows aren't squished — the
                    // charts still have the larger 2/3 share.
                    Expanded(flex: 1, child: buildAccountsColumn()),
                    const SizedBox(width: 24),
                    Expanded(flex: 2, child: buildChartsColumn(compact: false)),
                  ],
                );

          // Net-worth-focused secondary widgets. On wide screens they sit in
          // the main stack; on phones they fold into the "Details" disclosure
          // below so the default Glance view stays hero → trend → accounts.
          final goalTile = NetWorthGoalTile(
            netWorthUsd: (_overview?['net_worth'] as num?)?.toDouble() ?? 0.0,
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
            history: _netWorthHistory ?? const [],
          );
          final emergencyCard = EmergencyFundCard(
            apiService: _apiService,
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
          );
          // Lending glance — only present when lending is on and there's at
          // least one active loan (else null, and omitted entirely).
          final lendingGlance = _buildLendingGlanceCard(
            currencyFormat: currencyFormat,
            usdMxnRate: fxRate,
          );

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // "What changed since your last visit" — pinned above the
              // stat strip so it's the first thing the user sees on
              // return. Suppresses itself when there's nothing new.
              SinceLastLoginBanner(
                summary: _sinceLastLogin,
                currencyFormat: currencyFormat,
                conversionFactor: conversionFactor,
                onJumpToTransactions: (anchor) {
                  // Seed a custom date range from the previous-login
                  // anchor through today so the transactions list is
                  // pre-filtered to exactly the rows the banner is
                  // talking about.
                  setState(() => _txDateSeed = (
                    start: DateTime(anchor.year, anchor.month, anchor.day),
                    end: DateTime.now(),
                  ));
                  _goToNav(NavId.transactions);
                },
                onJumpToManagement: () => _goToNav(NavId.settings),
              ),
              if (_sinceLastLogin != null) const SizedBox(height: 12),
              _buildNetWorthHero(
                currencyFormat: currencyFormat,
                conversionFactor: conversionFactor,
                usdMxnRate: fxRate,
              ),
              const SizedBox(height: 12),
              buildSyncBar(),
              const SizedBox(height: 12),
              if (isNarrow) ...[
                // GLANCE (always visible): trend + accounts. 16px card gaps
                // on phones (house rubric).
                body,
                const SizedBox(height: 16),
                // DETAILS (one tap): stat strip, goal, emergency fund. Folded
                // away by default so the phone view isn't a wall of cards;
                // expand-state is remembered across visits.
                _buildOverviewDetails([
                  stats,
                  if (currencySubStrip != null) ...[
                    const SizedBox(height: 12),
                    currencySubStrip,
                  ],
                  const SizedBox(height: 16),
                  goalTile,
                  const SizedBox(height: 16),
                  emergencyCard,
                  if (lendingGlance != null) ...[
                    const SizedBox(height: 16),
                    lendingGlance,
                  ],
                ]),
              ] else ...[
                stats,
                if (currencySubStrip != null) ...[
                  const SizedBox(height: 12),
                  currencySubStrip,
                ],
                const SizedBox(height: 20),
                goalTile,
                const SizedBox(height: 20),
                emergencyCard,
                if (lendingGlance != null) ...[
                  const SizedBox(height: 20),
                  lendingGlance,
                ],
                const SizedBox(height: 20),
                body,
              ],
            ],
          );
        },
      ),
    );

    // Canonical 2026-research portfolio flow:
    //   overview → performance → allocation → signals → holdings.
    // The overview / signals / holdings slices are sections of one
    // PortfolioCard (same data, same holdings list); performance and
    // allocation are their own widgets between them.
    final portfolioData = _portfolioData ?? {};
    // Inter-card rhythm on the Invest tab: 16px on phones, 24px on wide
    // screens. Screen-level tab layout keys off MediaQuery (the same signal
    // buildTabContainer's padding uses) — the inner-LayoutBuilder rule
    // applies to cards; this Column spans the screen.
    final cardGap = SizedBox(
        height: MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0);
    final portfolioTab = buildTabContainer(
      Column(
        children: [
          // 1 · Overview — hero total value, change, dual-currency, KPIs.
          PortfolioCard(
            section: PortfolioSection.summary,
            portfolioData: portfolioData,
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
            targetCurrency: _targetCurrency,
            usdMxnRate: fxRate,
          ),
          cardGap,
          // 2 · Performance — value-over-time + contribution-weighted return.
          RepaintBoundary(
            child: PerformanceCard(
              apiService: _apiService,
              conversionFactor: conversionFactor,
              currencyFormat: currencyFormat,
              // Current total (same source as the hero above) so the
              // headline never tracks a partial trailing history point.
              totalValueUsd:
                  (portfolioData['total_value_usd'] as num?)?.toDouble(),
            ),
          ),
          cardGap,
          // 3 · Allocation — heatmap with dimension toggle + tap-to-filter.
          if (_allocationData != null) ...[
            // RepaintBoundary so this big card is cached as a layer and
            // doesn't re-raster on every page-scroll frame.
            RepaintBoundary(
              child: AllocationHeatmap(
                data: _allocationData!,
                conversionFactor: conversionFactor,
                currencyFormat: currencyFormat,
                // Fold the old "Asset breakdown" card in as toggle
                // dimensions (one allocation widget, not three).
                typeBreakdown:
                    (_overview?['type_breakdown'] as List?) ?? const [],
                institutionBreakdown:
                    (_overview?['institution_breakdown'] as List?) ?? const [],
                activeCategory: _portfolioCategoryFilter,
                onCategorySelected: (cat) {
                  // Tapping the active band clears the filter — saves a
                  // round-trip through the chip's X button.
                  final clearing = _portfolioCategoryFilter == cat;
                  setState(() {
                    _portfolioCategoryFilter = clearing ? null : cat;
                  });
                  // Setting (not clearing) a filter: the filtered table
                  // sits well below the fold, so scroll it into view or
                  // the tap looks like it did nothing. Post-frame so the
                  // rebuild above has laid out first; the nearest
                  // Scrollable is this tab's SingleChildScrollView
                  // (buildTabContainer).
                  if (!clearing) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      final ctx = _holdingsTableKey.currentContext;
                      if (!mounted || ctx == null) return;
                      Scrollable.ensureVisible(
                        ctx,
                        duration: const Duration(milliseconds: 400),
                        curve: Curves.easeInOutCubic,
                        // Land the table near the top of the viewport so
                        // its header + first rows are visible.
                        alignment: 0.05,
                      );
                    });
                  }
                },
              ),
            ),
            cardGap,
            // 3b · Rebalancing (WS2r4) — drift vs the owner's target
            // percentages: the actionable conclusion OF the allocation view
            // above. The setup-CTA / repair states live inside the widget,
            // so the mount is unconditional whenever allocation data exists.
            RepaintBoundary(
              child: RebalancingCard(
                apiService: _apiService,
                allocationData: _allocationData!,
                conversionFactor: conversionFactor,
                currencyFormat: currencyFormat,
              ),
            ),
            cardGap,
          ],
          // 4 · Signals — biggest gainer / loser + concentration flag.
          PortfolioCard(
            section: PortfolioSection.signals,
            portfolioData: portfolioData,
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
            targetCurrency: _targetCurrency,
            usdMxnRate: fxRate,
          ),
          cardGap,
          // 5 · Holdings — searchable table, drill-down filter from above.
          // Keyed so the allocation band-tap can ensureVisible it.
          PortfolioCard(
            key: _holdingsTableKey,
            section: PortfolioSection.holdings,
            portfolioData: portfolioData,
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
            targetCurrency: _targetCurrency,
            usdMxnRate: fxRate,
            onDataRefreshRequested: _refreshPortfolioData,
            categoryFilter: _portfolioCategoryFilter,
            onClearCategoryFilter: () =>
                setState(() => _portfolioCategoryFilter = null),
            searchOverride: _portfolioSearchOverride,
          ),
          cardGap,
          // 6 · Income — projected dividend income, blended yield, top payers,
          // upcoming ex-dates. Self-fetching; hides for non-paying portfolios.
          // Keyed so the Overview Dividends/yr tile tap can ensureVisible it.
          DividendIncomeCard(
            key: _dividendCardKey,
            apiService: _apiService,
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
          ),
          cardGap,
          RealizedGainsCard(
            apiService: _apiService,
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
          ),
        ],
      ),
    );

    final transactionsTab = buildTabContainer(
      TransactionsTab(
        key: _txTabKey,
        // Compact: creation moves to the Scaffold FAB (thumb zone); the
        // tab hides its toolbar '+' and pads the list clear of the FAB.
        hostProvidesAddFab: isCompact,
        transactions: _transactions ?? [],
        accounts: (_overview?['accounts'] as List?) ?? const [],
        conversionFactor: conversionFactor,
        currencyFormat: currencyFormat,
        targetCurrency: _targetCurrency,
        usdMxnRate: fxRate,
        onAddAccount: _openAddAccount,
        apiService: _apiService,
        onTransactionAdded: () => _refreshAfterTransactionMutation(),
        onLoadMore: _loadMoreTransactions,
        hasMore: _transactionsHasMore,
        searchOverride: _transactionsSearchOverride,
        highlightedTxId: _highlightedTxId,
        dateSeed: _txDateSeed,
        onDateSeedConsumed: () => setState(() => _txDateSeed = null),
        fxTransfers: _fxTransfers ?? const [],
        onConfirmFxTransfer: (id) async {
          try {
            await _apiService.confirmFxTransfer(id);
            await _refreshAfterTransactionMutation(includeFxTransfers: true);
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l.dashConfirmFailed(e.toString()))),
            );
          }
        },
        onUnlinkFxTransfer: (id) async {
          try {
            await _apiService.unlinkFxTransfer(id);
            await _refreshAfterTransactionMutation(includeFxTransfers: true);
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l.dashUnlinkFailed(e.toString()))),
            );
          }
        },
        onSplitTransaction: (parentId, splits) async {
          await _apiService.splitTransaction(parentId, splits);
          await _refreshAfterTransactionMutation();
        },
        onUnsplitTransaction: (parentId) async {
          await _apiService.unsplitTransaction(parentId);
          await _refreshAfterTransactionMutation();
        },
        onReplaceSplits: (parentId, splits) async {
          await _apiService.replaceSplits(parentId, splits);
          await _refreshAfterTransactionMutation();
        },
        onDetectFxTransfers: () async {
          final messenger = ScaffoldMessenger.of(context);
          messenger.showSnackBar(
            SnackBar(content: Text(l.dashScanningTransfers)),
          );
          try {
            final r = await _apiService.detectFxTransfers();
            await _refreshAfterTransactionMutation(includeFxTransfers: true);
            if (!mounted) return;
            messenger.hideCurrentSnackBar();
            messenger.showSnackBar(
              SnackBar(
                content: Text(
                  (r['inserted'] as num? ?? 0) > 0
                      // gen-l10n orders these alphabetically → (checked, inserted); pass checked first.
                      ? l.dashTransfersLinked(
                          (r['checked'] as num? ?? 0).toInt(),
                          (r['inserted'] as num? ?? 0).toInt())
                      : l.dashNoNewTransfers,
                ),
              ),
            );
          } catch (e) {
            if (!mounted) return;
            messenger.hideCurrentSnackBar();
            messenger.showSnackBar(
              SnackBar(content: Text(l.dashDetectionFailed(e.toString()))),
            );
          }
        },
        onUpdate: (id, {userCategory, userNotes, userDescription, accountId}) async {
          try {
            await _apiService.updateTransaction(
              id,
              userCategory: userCategory,
              userNotes: userNotes,
              userDescription: userDescription,
              accountId: accountId,
            );
            await _refreshAfterTransactionMutation();
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l.dashUpdateTransactionFailed(e.toString()))),
            );
          }
        },
        // Batch bulk edits into ONE request + ONE refresh (instead of N
        // per-row PATCHes each force-refreshing the whole dashboard).
        onBulkUpdate: (ids, {userCategory, accountId, userDescription}) async {
          final n = await _apiService.batchUpdateTransactions(
            ids,
            category: userCategory,
            accountId: accountId,
            description: userDescription,
          );
          await _refreshAfterTransactionMutation();
          return n;
        },
        // Bulk delete: ONE request + ONE refresh (instead of N per-row
        // DELETEs). Split parents cascade to their children server-side.
        onBulkDelete: (ids) async {
          await _apiService.batchDeleteTransactions(ids);
          await _refreshAfterTransactionMutation();
        },
        onDelete: (id) async {
          await _apiService.deleteTransaction(id);
          await _refreshAfterTransactionMutation();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(l.dashTransactionDeleted)),
          );
        },
        // Create a loan pre-filled from an outflow, linking it as the
        // disbursement. LendingTab owns loan people; the borrower here is
        // prefilled from the tx, so an empty people list is fine.
        onCreateLoanFromTx: (tx) => _openCreateLoanFromTx(tx),
      ),
    );

    // Dedicated cash-flow page: monthly summary, the bar-chart of
    // recent months, and per-category budgets. These used to crowd the
    // Overview; pulling them out keeps Overview focused on net worth.
    final gap = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    // Effective cash-flow series: the period-specific fetch once the user
    // touches the selector, else the shared 12-month series (current default).
    final cashFlowSeries = _cashFlowTrends ?? _trendData;
    // For single-month periods the card headlines a specific month; for
    // multi-month windows it aggregates and shows a period label instead.
    final bool cfAggregated = _cashFlowTrends != null &&
        (_cashFlowPeriod == CashFlowPeriod.threeMonths ||
            _cashFlowPeriod == CashFlowPeriod.ytd);
    String? cfSelectedMonthIso;
    String? cfPeriodLabel;
    if (_cashFlowTrends != null) {
      if (cfAggregated) {
        cfPeriodLabel = _cashFlowPeriod == CashFlowPeriod.threeMonths
            ? l.cfPeriod3Months
            : l.cfPeriodYtd;
      } else if (_cashFlowPeriod == CashFlowPeriod.lastMonth) {
        // The window is [prior, current]; headline the prior month.
        final series = _cashFlowTrends!;
        if (series.length >= 2) {
          cfSelectedMonthIso = series[series.length - 2]['month'] as String?;
        }
      }
      // thisMonth: leave selectedMonthIso null -> card headlines the latest
      // (only) month in the 1-month window.
    }
    // Cash-flow tab ordering: summary first (period + monthly headline),
    // then actionable cards (budgets, subscriptions + their un-hide panel,
    // upcoming bills), then analytic/occasional ones (category breakdown,
    // FX transfers, debt payoff).
    final cashFlowTab = buildTabContainer(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildCashFlowPeriodSelector(l),
          SizedBox(height: gap),
          MonthlyCashFlowCard(
            trends: cashFlowSeries ?? const [],
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
            selectedMonthIso: cfSelectedMonthIso,
            periodLabel: cfPeriodLabel,
            usdMxnRate: fxRate,
            targetCurrency: _targetCurrency,
          ),
          SizedBox(height: gap),
          BudgetsCard(
            transactions: _transactions ?? const [],
            conversionFactor: conversionFactor,
            usdMxnRate: fxRate,
            currencyFormat: currencyFormat,
            apiService: _apiService,
            // Item #11: a monthly target priced against the selected period's
            // most-recent month. 'This month' resolves to the current month,
            // leaving the pre-#11 behavior (incl. #10 pacing) unchanged.
            periodMonth: _budgetMonthForCashFlowPeriod(_cashFlowPeriod),
          ),
          SizedBox(height: gap),
          if (cashFlowSeries != null) ...[
            CashFlowTrendsChart(
              trends: cashFlowSeries,
              conversionFactor: conversionFactor,
              currencyFormat: currencyFormat,
              // Clicking a month group jumps to Transactions filtered
              // to that month — the cash-flow chart becomes a drill-in.
              onMonthSelected: (monthIso) {
                final parts = monthIso.split('-');
                if (parts.length < 2) return;
                final year = int.tryParse(parts[0]);
                final month = int.tryParse(parts[1]);
                if (year == null || month == null) return;
                final start = DateTime(year, month, 1);
                final end = DateTime(year, month + 1, 0); // last of month
                setState(() => _txDateSeed = (start: start, end: end));
                _goToNav(NavId.transactions);
              },
            ),
            SizedBox(height: gap),
          ],
          // Detected recurring outflows — surfaces what's silently
          // eating the budget every month. Tapping a row seeds the
          // transactions search with the merchant.
          if ((_subscriptions ?? const []).isNotEmpty) ...[
            SubscriptionsCard(
              subscriptions: _subscriptions!,
              conversionFactor: conversionFactor,
              usdMxnRate: fxRate,
              currencyFormat: currencyFormat,
              targetCurrency: _targetCurrency,
              onTapMerchant: (m) {
                setState(() => _transactionsSearchOverride = m);
                _goToNav(NavId.transactions);
              },
              onIgnoreMerchant: (m) async {
                try {
                  await _apiService.ignoreSubscription(m);
                  await _refreshSubscriptionLists();
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l.dashMerchantHidden(m))),
                  );
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l.dashFailedGeneric(e.toString()))),
                  );
                }
              },
            ),
            SizedBox(height: gap),
          ],
          // Hidden-from-subscriptions list, directly below the
          // subscriptions it un-hides. Surfaces only when there's
          // something to un-hide — keeps the cash-flow tab quiet for
          // users who never dismissed anything.
          if ((_ignoredSubscriptions ?? const []).isNotEmpty) ...[
            _buildIgnoredSubscriptionsPanel(),
            SizedBox(height: gap),
          ],
          // Bills derive from the detected subscriptions, so the card (which
          // self-hides without them) and its gap are gated together.
          if ((_subscriptions ?? const []).isNotEmpty) ...[
            UpcomingBillsCard(
              subscriptions: _subscriptions ?? const [],
              conversionFactor: conversionFactor,
              currencyFormat: currencyFormat,
            ),
            SizedBox(height: gap),
          ],
          SpendingByCategoryCard(
            apiService: _apiService,
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
            // Item #11: track the Cash Flow period selector so the category
            // chart's window matches the rest of the tab instead of its own
            // fixed default.
            months: _monthsForCashFlowPeriod(_cashFlowPeriod),
          ),
          SizedBox(height: gap),
          // Cross-currency cash transfers (Wise / Remitly / wires).
          // Lists each detected link with implied vs spot FX, plus
          // Confirm/Unlink inline. Hidden when there are no detected
          // pairs — keeps the cash-flow tab quiet for single-currency
          // users.
          if ((_fxTransfers ?? const []).isNotEmpty) ...[
            CrossCurrencyTransfersCard(
              transfers: _fxTransfers!,
              currencyFormat: currencyFormat,
              onConfirm: (id) async {
                try {
                  await _apiService.confirmFxTransfer(id);
                  await _refreshAfterTransactionMutation(
                      includeFxTransfers: true);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l.dashLinkConfirmed)),
                  );
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l.dashConfirmFailed(e.toString()))),
                  );
                }
              },
              onUnlink: (id) async {
                try {
                  await _apiService.unlinkFxTransfer(id);
                  await _refreshAfterTransactionMutation(
                      includeFxTransfers: true);
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l.dashPairUnlinked)),
                  );
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l.dashUnlinkFailed(e.toString()))),
                  );
                }
              },
            ),
            SizedBox(height: gap),
          ],
          DebtPayoffCard(
            accounts: (_overview?['accounts'] as List?) ?? const [],
            apiService: _apiService,
            conversionFactor: conversionFactor,
            usdMxnRate: fxRate,
            currencyFormat: currencyFormat,
          ),
        ],
      ),
    );

    final projectionsTab = buildTabContainer(
      WealthProjectionScreen(
        currentNetWorth: (_overview?['net_worth'] as num?)?.toDouble() ?? 0.0,
        conversionFactor: conversionFactor,
        currencyFormat: currencyFormat,
      ),
      scrollable: false,
    );

    final taxPlanningTab = buildTabContainer(
      TaxPlanningScreen(
        conversionFactor: conversionFactor,
        currencyFormat: currencyFormat,
        targetCurrency: _targetCurrency,
        usdMxnRate: fxRate,
      ),
      scrollable: false,
    );

    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    final isPhone = MediaQuery.sizeOf(context).width < 720;
    final managementTab = buildTabContainer(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.dashDataSources,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          // All "get data in" actions live in one card so the tab reads as a
          // tidy set of sections (matching Overview/Transactions) instead of
          // bare buttons floating on the background. Banks/manual and crypto
          // are split into labelled sub-groups.
          Card(
            child: Padding(
              padding: EdgeInsets.all(pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.add_link,
                          size: 18, color: context.tealAccent),
                      const SizedBox(width: 8),
                      Text(
                        l.dashAddAccountsTitle,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  LayoutBuilder(builder: (ctx, c) {
                    final isNarrow = c.maxWidth < 520;
                    final tileWidth =
                        isNarrow ? c.maxWidth : (c.maxWidth - 16) / 2;
                    Widget tile(IconData icon, String label,
                        {required Color bg,
                        Color? fg,
                        Color? iconColor,
                        VoidCallback? onPressed}) {
                      final foreground = fg ?? context.textPrimary;
                      return SizedBox(
                        width: tileWidth,
                        child: ElevatedButton.icon(
                          icon: Icon(icon, color: iconColor ?? foreground),
                          label: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          style: ElevatedButton.styleFrom(
                            // Slimmer, flatter tiles — the vertical: 20 + the
                            // default elevation made these read as chunky.
                            padding: const EdgeInsets.symmetric(vertical: 13),
                            elevation: 0,
                            backgroundColor: bg,
                            // Pin foreground so the label stays legible on
                            // every tinted tile (ElevatedButton's default
                            // light-mode tonal grey fades into the tint).
                            foregroundColor: foreground,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                          ),
                          onPressed: onPressed,
                        ),
                      );
                    }

                    Widget subLabel(String text) => Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            text.toUpperCase(),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: context.textSubtle,
                              letterSpacing: 0.6,
                            ),
                          ),
                        );

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        subLabel(l.dashConnectStandardAccounts),
                        Wrap(
                          spacing: 12,
                          runSpacing: 10,
                          children: [
                            tile(
                              Icons.add_link,
                              l.dashLinkPlaidUsBanks,
                              bg: context.accentSoft(context.tealAccent),
                              onPressed: plaidReady()
                                  ? () {
                                      Navigator.push(
                                        context,
                                        MaterialPageRoute(
                                          builder: (context) =>
                                              const ConnectBankScreen(),
                                        ),
                                      ).then(
                                          (_) => _loadAllData(silent: true));
                                    }
                                  : null,
                            ),
                            tile(
                              Icons.upload_file,
                              l.dashImportMxShort,
                              bg: context.hairline,
                              onPressed: () {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (context) => const ImportScreen(),
                                  ),
                                ).then((_) => _loadAllData(silent: true));
                              },
                            ),
                            tile(
                              Icons.add_circle_outline,
                              l.dashAddManualAccountShort,
                              bg: context.hairline,
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (context) => AddAccountDialog(
                                      onAccountCreated: _loadAllData),
                                );
                              },
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        Divider(color: context.hairline, height: 1),
                        const SizedBox(height: 20),
                        subLabel(l.dashConnectCryptoExchanges),
                        Wrap(
                          spacing: 12,
                          runSpacing: 10,
                          children: [
                            tile(
                              Icons.login,
                              l.dashLinkCoinbase,
                              // Coinbase brand blue (#0052FF) with white
                              // text/icon so the brand reads correctly in
                              // light mode too.
                              bg: const Color(0xFF0052FF),
                              fg: Colors.white,
                              onPressed: () {
                                final baseUrl = _apiService.baseUrl;
                                navigateTo('$baseUrl/auth/coinbase');
                              },
                            ),
                            tile(
                              Icons.currency_exchange,
                              l.dashConnectBitso,
                              bg: context.positive.withValues(alpha: 0.12),
                              iconColor: context.positive,
                              onPressed: () {
                                showDialog(
                                  context: context,
                                  builder: (context) => AddCryptoDialog(
                                    exchange: 'bitso',
                                    onLinked: _loadAllData,
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ],
                    );
                  }),
                ],
              ),
            ),
          ),
          SizedBox(height: gap),
          // Your name — used as the lender on loan agreements.
          Card(
            child: Padding(
              padding: EdgeInsets.all(pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.badge_outlined,
                          size: 18, color: context.tealAccent),
                      const SizedBox(width: 8),
                      Text(l.dashLenderNameTitle,
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w700)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(l.dashLenderNameSubtitle,
                      style:
                          TextStyle(fontSize: 12, color: context.textSubtle)),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _lenderNameCtrl,
                          textInputAction: TextInputAction.done,
                          onSubmitted: (_) => _saveLenderName(),
                          decoration: InputDecoration(
                            isDense: true,
                            hintText: l.dashLenderNameHint,
                            border: const OutlineInputBorder(),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      FilledButton(
                        onPressed: _savingLenderName ? null : _saveLenderName,
                        child: _savingLenderName
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2))
                            : Text(l.dashSave),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          SizedBox(height: gap),
          // Data export + import management. Mirrors the add-accounts card so
          // "get data out" reads as a sibling section. CSV/PDF downloads go
          // through the same-origin openUrlSameTab seam (Content-Disposition:
          // attachment, session cookie sent) used by the per-account screen
          // and tax-planning exports — so they work under the nginx /api proxy.
          Card(
            child: Padding(
              padding: EdgeInsets.all(pad),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(Icons.download,
                          size: 18, color: context.tealAccent),
                      const SizedBox(width: 8),
                      Text(
                        l.dashDataExportTitle,
                        style: const TextStyle(
                            fontSize: 16, fontWeight: FontWeight.w700),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    l.dashDataExportSubtitle,
                    style: TextStyle(
                        fontSize: 12, color: context.textSubtle),
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      OutlinedButton.icon(
                        icon: const Icon(Icons.table_chart_outlined),
                        label: Text(l.dashExportTransactionsCsv),
                        onPressed: () => openUrlSameTab(
                            _apiService.exportTransactionsCsvUrl()),
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.receipt_long_outlined),
                        label: Text(l.dashExportTaxCsv),
                        onPressed: () => openUrlSameTab(
                            '${_apiService.baseUrl}/tax/export'),
                      ),
                      OutlinedButton.icon(
                        icon: const Icon(Icons.picture_as_pdf_outlined),
                        label: Text(l.dashExportTaxPdf),
                        onPressed: () => openUrlSameTab(
                            '${_apiService.baseUrl}/tax/export/pdf'),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Divider(color: context.hairline, height: 1),
                  const SizedBox(height: 8),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(Icons.inventory_2_outlined,
                        color: context.tealAccent),
                    title: Text(l.dashImportedBatchesTitle),
                    subtitle: Text(l.dashImportedBatchesSubtitle),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const ImportCleanupScreen(),
                        ),
                      ).then((_) => _loadAllData(silent: true));
                    },
                  ),
                ],
              ),
            ),
          ),
          // Secondary Settings controls (sync-all, sync-status, FX, modules).
          // On phones these fold behind a "Connections & sync" disclosure so
          // the default view leads with the add-account actions; on wide
          // screens they stay inline exactly as before. The setup-status card
          // stays an always-visible sibling below either way.
          ...(() {
            final List<Widget> secondaryControls = <Widget>[
          // "Sync all" acts on already-connected accounts, so it sits with
          // the sync-status / FX monitoring row rather than the add-account
          // actions. Inline spinner instead of a blocking SnackBar.
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              icon: _isSyncing
                  ? SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                            context.textPrimary),
                      ),
                    )
                  : const Icon(Icons.sync),
              label: Text(
                _isSyncing
                    ? (_syncTotal > 0
                        ? l.dashSyncingProgress(_syncDone, _syncTotal)
                        : l.dashSyncingAll)
                    : l.dashSyncAllAccounts,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              style: ElevatedButton.styleFrom(
                padding: const EdgeInsets.symmetric(vertical: 18),
                backgroundColor: context.accentSoft(context.info),
                foregroundColor: context.textPrimary,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              onPressed: _isSyncing ? null : runSync,
            ),
          ),
          const SizedBox(height: 16),
          LayoutBuilder(builder: (ctx, c) {
            // Below ~720px the SyncStatusCard + FxWidget pair gets squeezed
            // into unreadability when forced side-by-side. Stack them.
            final isNarrow = c.maxWidth < 720;
            final sync = SyncStatusCard(
              syncData: _syncData ?? [],
              onRetrySync: runSync,
              onRetrySingle: (id) async {
                try {
                  await _apiService.syncInstitution(id);
                  await _refreshData();
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l.dashRetryFailed(e.toString()))),
                  );
                }
              },
              onRetryBatch: (ids) async {
                try {
                  await _apiService.syncInstitutionsBatch(ids);
                  await _refreshData();
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l.dashRetryFailed(e.toString()))),
                  );
                }
              },
              onReconnect: handleReconnect,
              onDelete: (id) async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: Text(l.dashDeleteInstitutionTitle),
                    content: Text(l.dashDeleteInstitutionBody),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: Text(l.actionCancel)),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: TextButton.styleFrom(
                            foregroundColor: context.negative),
                        child: Text(l.dashDeleteEverything),
                      ),
                    ],
                  ),
                );

                if (confirm == true) {
                  try {
                    await _apiService.deleteInstitution(id);
                    _loadAllData(silent: true);
                  } catch (e) {
                    if (!mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text(l.dashDeleteFailed(e.toString()))));
                  }
                }
              },
            );
            final fx = FxWidget(
              latestRate: _fxRate ?? {},
              onRefresh: () async {
                try {
                  final fresh = await _apiService.getExchangeRate(
                    'USD',
                    'MXN',
                    force: true,
                  );
                  if (!mounted) return;
                  setState(() => _fxRate = fresh);
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l.dashFxRateRefreshed)),
                  );
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(l.dashRefreshFailed(e.toString()))),
                  );
                }
              },
            );
            if (isNarrow) {
              return Column(
                children: [
                  sync,
                  const SizedBox(height: 16),
                  fx,
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: sync),
                const SizedBox(width: 24),
                Expanded(child: fx),
              ],
            );
          }),
          SizedBox(height: gap),
          _buildModulesCard(),
            ];
            if (isPhone) {
              return [
                SizedBox(height: gap),
                _buildManagementDetails(secondaryControls),
              ];
            }
            return [
              const SizedBox(height: 24),
              ...secondaryControls,
            ];
          }()),
          // Auto-archived accounts — a recovery affordance for accounts the
          // sync closed at the bank. Rendered only when something's been
          // archived; collapsed by default.
          ?(() {
            final section = _buildArchivedAccountsSection();
            return section == null
                ? null
                : Padding(
                    padding: EdgeInsets.only(top: gap),
                    child: section,
                  );
          }()),
          SizedBox(height: gap),
          // Deployment diagnostics sit below the data-management sections —
          // they collapse to a single "Ready" row once required checks pass,
          // so they no longer crowd the top of the tab.
          buildSetupStatusCard(),
          // App-level settings close the tab: preferences (language, theme)
          // and account & security (Security, Hidden items, Server, and the
          // deliberately low-prominence confirmed sign-out as the final row).
          SizedBox(height: gap),
          _buildPreferencesCard(),
          SizedBox(height: gap),
          _buildAccountCard(),
        ],
      ),
    );

    final lendingTab = buildTabContainer(
      LendingTab(
        apiService: _apiService,
        targetCurrency: _targetCurrency,
        // USD→MXN spot, so the summary card can convert mixed-currency
        // loans into the active display currency.
        usdMxnRate: fxRate,
        // A loan mutation links/unlinks transactions that are excluded
        // from cash flow — refresh silently so the Cash flow tab + net
        // worth reflect it without a full reload flash.
        onChanged: () => _loadAllData(silent: true),
        // Tap a linked loan payment → jump to its bank transaction, reusing
        // the command-palette deep-link (search seed + highlight pulse).
        onOpenTransaction: (txId, description) {
          setState(() {
            _transactionsSearchOverride = description;
            _highlightedTxId = txId;
          });
          _goToNav(NavId.transactions);
          Future.delayed(const Duration(milliseconds: 2400), () {
            if (!mounted) return;
            if (_highlightedTxId == txId) {
              setState(() => _highlightedTxId = null);
            }
          });
        },
      ),
      // LendingTab owns its scrolling (RefreshIndicator → ListView), so it
      // must NOT be wrapped in the default SingleChildScrollView — a
      // ListView given unbounded height throws a layout error and the whole
      // tab renders blank. Same reason projections/tax-planning opt out.
      scrollable: false,
    );

    // Map each section id to its built body, then render only the
    // visible sections (Lending excluded when off) in _destinations order.
    // IndexedStack keeps every child mounted, so section state + one-shot
    // initState fetches survive switching — same guarantee the old
    // TabBarView + _KeepAliveTab gave, without a controller.
    final sectionBodies = <NavId, Widget>{
      NavId.overview: overviewTab,
      NavId.portfolio: portfolioTab,
      NavId.transactions: transactionsTab,
      NavId.cashFlow: cashFlowTab,
      NavId.projections: projectionsTab,
      NavId.tax: taxPlanningTab,
      NavId.settings: managementTab,
      NavId.lending: lendingTab,
    };
    final dests = _destinations;
    final index = _section.clamp(0, dests.length - 1);
    // The visible section is always mounted; mark it visited so it stays
    // mounted on later builds. (Mutating here is safe — this build already
    // renders it real, so no extra rebuild is needed.)
    _visitedSections.add(dests[index].id);
    return IndexedStack(
      index: index,
      // Expand so non-scrolling sections (Projections / Tax / Lending,
      // which own their scroll) get a bounded height, like the old
      // TabBarView viewport did.
      sizing: StackFit.expand,
      children: [
        for (final d in dests)
          _visitedSections.contains(d.id)
              ? _KeepAliveTab(child: sectionBodies[d.id]!)
              : const SizedBox.shrink(),
      ],
    );
  }

  /// Wide-screen left navigation rail. Primary sections on top, a "More"
  /// group of secondary sections below, and Settings pinned to the
  /// bottom. Selection + persistence go through [_goToNav].
  Widget _buildNavRail() {
    final scheme = Theme.of(context).colorScheme;
    final dests = _destinations;
    final primary = dests.where((d) => d.tier == NavTier.primary).toList();
    final secondary = dests
        .where((d) => d.tier == NavTier.secondary && d.id != NavId.settings)
        .toList();
    final settings = dests.firstWhere((d) => d.id == NavId.settings);
    final selectedId =
        (_section >= 0 && _section < dests.length) ? dests[_section].id : null;
    return Container(
      width: 188,
      color: scheme.surface,
      child: Column(
        children: [
          const SizedBox(height: 8),
          // Scrollable middle so a short window never overflows; Settings
          // stays pinned below the scroll area.
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  for (final d in primary)
                    _railTile(d, d.id == selectedId),
                  if (secondary.isNotEmpty)
                    _railGroupLabel(AppLocalizations.of(context).navMoreGroup),
                  for (final d in secondary)
                    _railTile(d, d.id == selectedId),
                ],
              ),
            ),
          ),
          Divider(height: 1, color: scheme.outlineVariant),
          _railTile(settings, settings.id == selectedId),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _railGroupLabel(String label) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 12, 6),
      child: Row(
        children: [
          Text(
            label.toUpperCase(),
            style: TextStyle(
              fontSize: 11,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(child: Divider(height: 1, color: scheme.outlineVariant)),
        ],
      ),
    );
  }

  Widget _railTile(_NavDest d, bool selected) {
    final scheme = Theme.of(context).colorScheme;
    final accent = d.accent(Theme.of(context).brightness);
    final label = _navLabel(AppLocalizations.of(context), d.id);
    // Expose selection to assistive tech — color/weight alone don't tell a
    // screen-reader user which section is current (the NavigationBar path
    // gets this for free; the hand-rolled rail must opt in).
    return Semantics(
      selected: selected,
      button: true,
      label: label,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        child: Material(
          color: selected
              ? accent.withValues(alpha: 0.14)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => _goToNav(d.id),
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
              child: Row(
                children: [
                  Icon(d.icon,
                      size: 20,
                      color: selected ? accent : scheme.onSurfaceVariant),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight:
                            selected ? FontWeight.w600 : FontWeight.w500,
                        color: selected
                            ? scheme.onSurface
                            : scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Narrow-screen bottom navigation: the primary sections plus a "More"
  /// entry that opens a sheet with the secondary sections + Settings.
  Widget _buildBottomBar() {
    final l = AppLocalizations.of(context);
    final dests = _destinations;
    final primary = dests.where((d) => d.tier == NavTier.primary).toList();
    final current =
        (_section >= 0 && _section < dests.length) ? dests[_section] : dests.first;
    // Highlight the active primary, or "More" (last slot) when a secondary
    // section is showing.
    final primaryIdx = primary.indexWhere((d) => d.id == current.id);
    final selectedIndex = primaryIdx >= 0 ? primaryIdx : primary.length;
    return NavigationBar(
      selectedIndex: selectedIndex,
      onDestinationSelected: (i) {
        if (i < primary.length) {
          _goToNav(primary[i].id);
        } else {
          _openMoreSheet();
        }
      },
      destinations: [
        for (final d in primary)
          NavigationDestination(
              icon: Icon(d.icon), label: _navShortLabel(l, d.id)),
        NavigationDestination(icon: const Icon(Icons.more_horiz), label: l.navMore),
      ],
    );
  }

  void _openMoreSheet() {
    final l = AppLocalizations.of(context);
    final dests = _destinations;
    final secondary = dests.where((d) => d.tier == NavTier.secondary).toList();
    // Same guarded lookup as _buildBottomBar: which destination is showing
    // right now, so the sheet can tint the active row (the NavigationBar
    // highlight, mirrored) instead of presenting six identical tiles.
    final current =
        (_section >= 0 && _section < dests.length) ? dests[_section] : dests.first;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final d in secondary)
              // A3 (round 3, a11y): each More-sheet row is one button node
              // (icon + title merged) instead of a label-less tappable.
              MergeSemantics(
                child: Semantics(
                  button: true,
                  child: ListTile(
                    leading:
                        Icon(d.icon, color: d.accent(Theme.of(context).brightness)),
                    title: Text(_navLabel(l, d.id)),
                    // Soft active-destination tint (ListTile.selected also
                    // exposes the state to assistive tech).
                    selected: d.id == current.id,
                    selectedTileColor: Theme.of(context)
                        .colorScheme
                        .secondaryContainer
                        .withValues(alpha: 0.5),
                    selectedColor:
                        Theme.of(context).colorScheme.onSecondaryContainer,
                    onTap: () {
                      Navigator.of(sheetCtx).pop();
                      _goToNav(d.id);
                    },
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Keeps an IndexedStack child alive across section switches so its State
/// (and any initState API calls — projections, tax planning, etc.) only
/// fires once. IndexedStack already keeps children mounted, but the
/// AutomaticKeepAlive wrapper is retained so nested scroll/keep-alive
/// behaviour is unchanged from the old TabBarView.
class _KeepAliveTab extends StatefulWidget {
  final Widget child;
  const _KeepAliveTab({required this.child});

  @override
  State<_KeepAliveTab> createState() => _KeepAliveTabState();
}

class _KeepAliveTabState extends State<_KeepAliveTab>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return widget.child;
  }
}

class _StatTile extends StatelessWidget {
  final String label;
  final String value;
  final Color accent;

  /// Optional explanatory note. When non-null a small info glyph sits after
  /// the label and surfaces this text on hover / long-press, used e.g. to
  /// explain why the Investments subtotal differs from the Portfolio total.
  final String? tooltip;

  /// Optional drilldown callback. When non-null the tile becomes tappable
  /// (with a chevron affordance) and opens a sheet listing the accounts that
  /// fed the subtotal. Null keeps the tile a plain display-only Container —
  /// today's behaviour for any tile with no accounts behind it.
  final VoidCallback? onTap;

  const _StatTile({
    required this.label,
    required this.value,
    required this.accent,
    this.tooltip,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    // Secondary stat: shared hairline border, tile surface, label in
    // textSubtle with a small accent dot on its leading edge — a category
    // cue without painting the whole label in a loud neon. (The net-worth
    // hero treatment now lives in _buildNetWorthHero, above the row, so
    // these tiles are uniformly secondary.)
    final tile = Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: BoxDecoration(
        color: context.tileSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: accent,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  label.toUpperCase(),
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.2,
                    fontWeight: FontWeight.w700,
                    color: context.textSubtle,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (tooltip != null) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: tooltip!,
                  triggerMode: TooltipTriggerMode.tap,
                  child: Icon(
                    Icons.info_outline,
                    size: 12,
                    color: context.textFaint,
                  ),
                ),
              ],
              // Drilldown affordance: a faint chevron only when the tile is
              // tappable, signalling "tap to see the accounts behind this".
              if (onTap != null) ...[
                const SizedBox(width: 4),
                Icon(
                  Icons.chevron_right,
                  size: 14,
                  color: context.textFaint,
                ),
              ],
            ],
          ),
          const SizedBox(height: 6),
          Text(
            value,
            // JetBrains Mono "ledger" figures — same treatment as the
            // net-worth hero so the dashboard's big numbers share one
            // consistent identity (bundled up to Bold/w700).
            style: brandDisplayStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: context.textPrimary,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );

    // A3 (round 3, a11y): each tile is ONE labelled node — "Assets,
    // $1,234.00" — and tappable tiles announce as buttons. The label uses
    // the un-uppercased text (screen readers spell out all-caps strings on
    // some engines); the inner Texts/tooltip icon are excluded so nothing
    // is read twice.
    final semanticsLabel = '$label, $value';

    // Display-only when there's nothing to drill into — identical to the
    // tile's historical behaviour. Otherwise make the whole tile a tap
    // target with a matching ink ripple (the AppBar currency-swap toggle is
    // a separate widget, so this never swallows that gesture).
    if (onTap == null) {
      return Semantics(
        container: true,
        label: semanticsLabel,
        excludeSemantics: true,
        child: tile,
      );
    }
    return MergeSemantics(
      child: Semantics(
        button: true,
        label: semanticsLabel,
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: ExcludeSemantics(child: tile),
          ),
        ),
      ),
    );
  }
}

/// One account row inside an Overview stat-tile drilldown sheet. Carries the
/// raw account map (so a tap can deep-link into the transactions panel) plus
/// its native and reporting-currency balances, computed once in
/// [_DashboardScreenState._buildStatStrip] using the same convertCurrency
/// math that produced the tile subtotal.
class _StatDrilldownRow {
  final Map<String, dynamic> account;
  final double nativeBalance;
  final String nativeCurrency;
  final double reportedBalance;

  const _StatDrilldownRow({
    required this.account,
    required this.nativeBalance,
    required this.nativeCurrency,
    required this.reportedBalance,
  });
}

/// Intent fired by Cmd-K / Ctrl-K to open the global command palette.
class _OpenPaletteIntent extends Intent {
  const _OpenPaletteIntent();
}

/// Compact reporting-currency pill. Replaces the dual icon-only /
/// labelled-button compound that lived inline in the AppBar — the
/// pill is the same shape regardless of breakpoint so the chrome on
/// the right side of the AppBar stays even.
class _CurrencyToggleButton extends StatelessWidget {
  final String targetCurrency;
  final VoidCallback onSwap;

  const _CurrencyToggleButton({
    required this.targetCurrency,
    required this.onSwap,
  });

  @override
  Widget build(BuildContext context) {
    final active = targetCurrency == 'MXN';
    final accent = active ? context.positive : context.textPrimary;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Tooltip(
        message: AppLocalizations.of(context).currencyToggleTooltip(targetCurrency),
        child: InkWell(
          borderRadius: BorderRadius.circular(20),
          onTap: onSwap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: accent.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: context.accentBorder(accent)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.currency_exchange, size: 14, color: accent),
                const SizedBox(width: 6),
                Text(
                  targetCurrency,
                  style: TextStyle(
                    color: accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.4,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Single-tap theme picker. Tapping cycles system → light → dark →
/// system; long-press still surfaces the explicit picker for users who
/// know exactly which mode they want without cycling.
class _ThemeCycleButton extends StatelessWidget {
  static const _order = [ThemeMode.system, ThemeMode.light, ThemeMode.dark];

  IconData _iconFor(ThemeMode m) => switch (m) {
        ThemeMode.system => Icons.brightness_auto,
        ThemeMode.light => Icons.light_mode_outlined,
        ThemeMode.dark => Icons.dark_mode_outlined,
      };

  String _labelFor(AppLocalizations l, ThemeMode m) => switch (m) {
        ThemeMode.system => l.dashThemeSystem,
        ThemeMode.light => l.dashThemeLight,
        ThemeMode.dark => l.dashThemeDark,
      };

  void _persist(ThemeMode m) => Preferences.setThemeMode(switch (m) {
        ThemeMode.system => 'system',
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
      });

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (ctx, mode, _) {
        return GestureDetector(
          onLongPress: () async {
            final picked = await showMenu<ThemeMode>(
              context: context,
              position: const RelativeRect.fromLTRB(1000, 56, 0, 0),
              items: [
                PopupMenuItem(
                  value: ThemeMode.system,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.brightness_auto),
                    title: Text(l.dashThemeSystemDefault),
                  ),
                ),
                PopupMenuItem(
                  value: ThemeMode.light,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.light_mode_outlined),
                    title: Text(l.dashThemeLightShort),
                  ),
                ),
                PopupMenuItem(
                  value: ThemeMode.dark,
                  child: ListTile(
                    dense: true,
                    leading: const Icon(Icons.dark_mode_outlined),
                    title: Text(l.dashThemeDarkShort),
                  ),
                ),
              ],
            );
            if (picked != null) {
              themeModeNotifier.value = picked;
              _persist(picked);
            }
          },
          child: IconButton(
            tooltip: l.dashThemeTooltip(_labelFor(l, mode)),
            // AnimatedSwitcher fades between the per-mode icons so the
            // tap-cycle reads as a smooth icon swap rather than an
            // instant glyph flip.
            icon: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              transitionBuilder: (child, anim) => FadeTransition(
                opacity: anim,
                child: ScaleTransition(scale: anim, child: child),
              ),
              child: Icon(
                _iconFor(mode),
                key: ValueKey(mode),
              ),
            ),
            onPressed: () {
              final next = _order[(_order.indexOf(mode) + 1) % _order.length];
              themeModeNotifier.value = next;
              _persist(next);
            },
          ),
        );
      },
    );
  }
}

/// Shows the shared sign-out confirmation dialog — the same bilingual strings
/// as the Security screen's "Sign out of this device" — and resolves to true
/// only if the user confirmed. Used by the Settings tab's Account & security
/// card and by the dashboard's own confirmed sign-out; public so widget tests
/// can exercise the flow.
Future<bool> confirmSignOutDialog(BuildContext context) async {
  final l = AppLocalizations.of(context);
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (_) => AlertDialog(
      title: Text(l.secSignOutThisDeviceTitle),
      content: Text(l.secSignOutThisDeviceBody),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(l.actionCancel),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(l.secSignOut),
        ),
      ],
    ),
  );
  return confirmed == true;
}

/// Preferences card on the Settings tab: language (explicit radio picker) and
/// theme (three-way segmented control). Reads/writes the app-global notifiers
/// (localeNotifier, themeModeNotifier) and persists via Preferences — the
/// exact persist+notify pattern the AppBar controls use, so both stay in
/// step. Public (unlike the dashboard's other cards) so widget tests can pump
/// it in isolation — tests never pump the full dashboard screen.
class SettingsPreferencesCard extends StatelessWidget {
  const SettingsPreferencesCard({super.key});

  void _pickLanguage(BuildContext context) {
    final l = AppLocalizations.of(context);
    final current = Localizations.localeOf(context).languageCode;
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(l.dashLanguageLabel),
        // Radio tiles carry their own horizontal padding; shrink the default
        // 24px content inset so they align under the title.
        contentPadding: const EdgeInsets.fromLTRB(8, 16, 8, 0),
        content: RadioGroup<String>(
          groupValue: current,
          onChanged: (code) {
            if (code == null) return;
            // Same persist + live-notify pattern as the AppBar's language
            // toggle: Preferences stores it, localeNotifier re-points intl
            // and rebuilds MaterialApp.
            Preferences.setLocale(code);
            localeNotifier.value = Locale(code);
            Navigator.of(dialogContext).pop();
          },
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Autonyms — deliberately NOT localized: each language names
              // itself so it stays findable from the "wrong" locale.
              RadioListTile<String>(value: 'en', title: Text('English')),
              RadioListTile<String>(
                value: 'es',
                title: Text('Español (México)'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l.actionCancel),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.tune, size: 18, color: context.tealAccent),
                const SizedBox(width: 8),
                Text(
                  l.dashPreferencesTitle,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.translate),
              title: Text(l.dashLanguageLabel),
              subtitle: Text(
                // Autonym of the ACTIVE locale (deliberately not localized).
                Localizations.localeOf(context).languageCode == 'es'
                    ? 'Español (México)'
                    : 'English',
              ),
              onTap: () => _pickLanguage(context),
            ),
            const SizedBox(height: 4),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              // Width decisions off the card's INNER constraint (house
              // convention), not the screen.
              child: LayoutBuilder(builder: (ctx, c) {
                final label = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.brightness_6_outlined),
                    const SizedBox(width: 16),
                    Text(l.dashThemeMenu,
                        style: const TextStyle(fontSize: 16)),
                  ],
                );
                // ValueListenableBuilder keeps the selection in step with
                // theme changes made elsewhere (the wide AppBar's
                // theme-cycle button writes the same notifier). Rendered as
                // an M3 Expressive connected button group (2px gaps, no
                // shared outline, selected segment morphs to a filled
                // fully-rounded pill) — the classic SegmentedButton's
                // outline+checkmark read as dated chrome, and equal-flex
                // segments always fit the card, no scroll guard needed.
                final picker = ValueListenableBuilder<ThemeMode>(
                  valueListenable: themeModeNotifier,
                  builder: (pickerCtx, mode, _) {
                    final scheme = Theme.of(pickerCtx).colorScheme;
                    Widget seg(ThemeMode value, IconData icon, String text,
                        {bool first = false, bool last = false}) {
                      final selected = mode == value;
                      // Outer ends stay pill-round; inner corners sit at 8
                      // until selection morphs the segment fully round.
                      final radius = BorderRadius.horizontal(
                        left: Radius.circular(selected || first ? 22 : 8),
                        right: Radius.circular(selected || last ? 22 : 8),
                      );
                      return Expanded(
                        child: Semantics(
                          selected: selected,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            height: 44,
                            decoration: BoxDecoration(
                              color: selected
                                  ? scheme.secondaryContainer
                                  : pickerCtx.tint(0.05),
                              borderRadius: radius,
                            ),
                            child: Material(
                              type: MaterialType.transparency,
                              child: InkWell(
                                borderRadius: radius,
                                onTap: () {
                                  themeModeNotifier.value = value;
                                  // Same persist mapping as the AppBar
                                  // theme controls.
                                  Preferences.setThemeMode(switch (value) {
                                    ThemeMode.system => 'system',
                                    ThemeMode.light => 'light',
                                    ThemeMode.dark => 'dark',
                                  });
                                },
                                child: Center(
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(icon,
                                          size: 18,
                                          color: selected
                                              ? scheme.onSecondaryContainer
                                              : pickerCtx.textSubtle),
                                      const SizedBox(width: 6),
                                      Flexible(
                                        child: Text(
                                          text,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 13.5,
                                            fontWeight: selected
                                                ? FontWeight.w700
                                                : FontWeight.w600,
                                            color: selected
                                                ? scheme.onSecondaryContainer
                                                : pickerCtx.textSubtle,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      );
                    }

                    return Row(
                      children: [
                        seg(ThemeMode.system, Icons.brightness_auto,
                            l.dashThemeSystemShort, first: true),
                        const SizedBox(width: 2),
                        seg(ThemeMode.light, Icons.light_mode_outlined,
                            l.dashThemeLightShort),
                        const SizedBox(width: 2),
                        seg(ThemeMode.dark, Icons.dark_mode_outlined,
                            l.dashThemeDarkShort, last: true),
                      ],
                    );
                  },
                );
                if (c.maxWidth < 520) {
                  // Narrow: the group gets its own full-width line under
                  // the label.
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Align(alignment: Alignment.centerLeft, child: label),
                      const SizedBox(height: 12),
                      picker,
                    ],
                  );
                }
                return Row(
                  children: [
                    Expanded(child: label),
                    const SizedBox(width: 16),
                    SizedBox(width: 360, child: picker),
                  ],
                );
              }),
            ),
          ],
        ),
      ),
    );
  }
}

/// Account & security card on the Settings tab: Security, Hidden & archived
/// items, Server (native builds only), and the confirmed sign-out as the
/// deliberately low-prominence final row. Dumb/injected per house convention;
/// public so widget tests can pump it in isolation.
class SettingsAccountSecurityCard extends StatelessWidget {
  const SettingsAccountSecurityCard({
    super.key,
    required this.onHiddenItemsClosed,
    required this.onSignOut,
    required this.onChangeServer,
  });

  /// Fired when HiddenItemsScreen pops — hiding/unhiding accounts or
  /// holdings changes totals, so the owner must refresh.
  final VoidCallback onHiddenItemsClosed;

  /// Fired only after the user CONFIRMED the sign-out dialog.
  final VoidCallback onSignOut;

  /// Fired only after the user confirmed the change-server dialog. The owner
  /// runs the logout-then-clear sequence.
  final Future<void> Function() onChangeServer;

  Future<void> _confirmChangeServer(BuildContext context) async {
    final l = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.dashServerChangeTitle),
        content: Text(l.dashServerChangeBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(l.actionCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            // The consequence the user is accepting is the sign-out, so the
            // confirm button reuses the Security screen's sign-out label.
            child: Text(l.secSignOut),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await onChangeServer();
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final scheme = Theme.of(context).colorScheme;
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    return Card(
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.shield_outlined,
                    size: 18, color: context.tealAccent),
                const SizedBox(width: 8),
                Text(
                  l.dashAccountSecurityTitle,
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.shield_outlined),
              title: Text(l.dashSecurity),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const SecurityScreen()),
              ),
            ),
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.visibility_off_outlined),
              title: Text(l.dashHiddenItems),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                      builder: (_) => const HiddenItemsScreen()),
                );
                onHiddenItemsClosed();
              },
            ),
            // Native builds configure the backend URL at first run; this row
            // keeps that setting reachable afterwards. Web derives the URL
            // from its own origin, so there's nothing to change there.
            if (!kIsWeb)
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.dns_outlined),
                title: Text(l.dashServerLabel),
                subtitle: Text(BackendConfig.baseUrl ?? ''),
                onTap: () => _confirmChangeServer(context),
              ),
            const Divider(),
            // Sign out — deliberately the final, low-prominence row, always
            // behind a confirmation.
            ListTile(
              contentPadding: EdgeInsets.zero,
              leading: Icon(Icons.logout, color: scheme.error),
              title:
                  Text(l.dashSignOut, style: TextStyle(color: scheme.error)),
              onTap: () async {
                if (await confirmSignOutDialog(context)) onSignOut();
              },
            ),
          ],
        ),
      ),
    );
  }
}

/// Scroll-away shell for the compact app bar (enter-always + snap semantics).
///
/// Keeps `Scaffold.appBar` instead of migrating tabs to slivers:
/// [preferredSize] stays constant — Scaffold only uses it as a *max*
/// constraint and positions the body by the bar's ACTUAL laid-out height
/// (`_ScaffoldLayout.performLayout` uses `layoutChild(...).height`) — so
/// animating the inner height slides the body up/down smoothly, with the
/// wrapped [AppBar] itself completely untouched. Its default lift-on-scroll
/// surface tint keeps working: the scrolled-under listener registers with the
/// Scaffold's own ScrollNotificationObserver, which wraps this slot too.
///
/// Collapsed, the shell never reaches height 0 on a phone: an opaque strip of
/// exactly the status-bar inset remains (painted in the bar's own background
/// colour), so tab content never renders under the OS status bar.
class _CollapsingAppBar extends StatelessWidget
    implements PreferredSizeWidget {
  const _CollapsingAppBar({required this.visible, required this.child});

  /// Whether the bar is shown. Flipping this triggers the ~200ms snap.
  final bool visible;

  /// The untouched app bar being slid in/out.
  final AppBar child;

  @override
  Size get preferredSize => child.preferredSize;

  @override
  Widget build(BuildContext context) {
    final topInset = MediaQuery.paddingOf(context).top;
    final expanded = child.preferredSize.height + topInset;
    // Implicitly animated — no controller to own or dispose. t runs 1.0
    // (shown) -> 0.0 (collapsed to the status-bar strip); the short easeInOut
    // is the "snap". The bar subtree is passed as `child` so it is NOT
    // rebuilt per animation frame — only this cheap shell is.
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(end: visible ? 1.0 : 0.0),
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      child: child,
      builder: (context, t, bar) {
        return SizedBox(
          height: topInset + (expanded - topInset) * t,
          child: ClipRect(
            child: Stack(
              children: [
                // Bottom-anchored at its full height inside the shrinking
                // clip, so the bar slides up out of view rather than
                // squashing its contents. While hidden it must not be
                // hit-testable through the residual strip.
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  height: expanded,
                  child: IgnorePointer(ignoring: !visible, child: bar!),
                ),
                // Opaque status-bar strip: fades in as the bar leaves so no
                // toolbar content ever sits under the OS status bar, and at
                // rest fully covers the slice of the bar still inside the
                // clip. Uses the bar's themed background (falling back to
                // surface) so the strip blends with it in both themes.
                if (t < 1.0)
                  Positioned(
                    left: 0,
                    right: 0,
                    top: 0,
                    height: topInset,
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: 1.0 - t,
                        child: ColoredBox(
                          color:
                              Theme.of(context).appBarTheme.backgroundColor ??
                                  Theme.of(context).colorScheme.surface,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
