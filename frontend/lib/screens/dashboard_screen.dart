import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:plaid_flutter/plaid_flutter.dart';
import 'package:web/web.dart' as web;
import 'dart:async';
import '../services/api_service.dart';
import '../main.dart' show themeModeNotifier;
import '../utils/app_locale.dart';
import '../l10n/app_localizations.dart';
import '../services/preferences.dart';
import '../services/plaid_oauth.dart';
import '../services/realtime_service.dart';
import '../services/transaction_mutation_refresh.dart';
import '../widgets/net_worth_card.dart';
import '../widgets/assets_liabilities_bar.dart';
import '../widgets/monthly_cash_flow_card.dart';
import '../widgets/budgets_card.dart';
import '../widgets/spending_by_category_card.dart';
import '../widgets/realized_gains_card.dart';
import '../widgets/performance_card.dart';
import '../widgets/upcoming_bills_card.dart';
import '../widgets/debt_payoff_card.dart';
import '../widgets/net_worth_goal_tile.dart';
import '../widgets/emergency_fund_card.dart';
import '../widgets/portfolio_card.dart';
import '../widgets/fx_widget.dart';
import '../widgets/credit_utilization_card.dart';
import '../widgets/sync_status_card.dart';
import '../widgets/cross_currency_transfers_card.dart';
import '../widgets/accounts_list_widget.dart';
import '../widgets/transactions_tab.dart';
import '../widgets/lending_tab.dart';
import '../widgets/add_account_dialog.dart';
import '../widgets/add_crypto_dialog.dart';
import '../widgets/command_palette.dart';
import '../widgets/skeleton.dart';
import '../widgets/sync_error_banner.dart';
import '../widgets/since_last_login_banner.dart';
import '../widgets/subscriptions_card.dart';
import '../widgets/notifications_panel.dart';
import '../theme/palette.dart';
import '../theme/typography.dart';
import '../utils/account_category.dart';
import '../utils/currency.dart';
import '../utils/sync_progress.dart';
import '../utils/supported_banks.dart';
import '../utils/theme_colors.dart';
import '../utils/transaction_display.dart';
import 'account_transactions_screen.dart';
import 'connect_bank_screen.dart';
import 'import_screen.dart';
import 'wealth_projection_screen.dart';
import '../components/date_range_selector.dart';
import '../components/allocation_heatmap.dart';
import '../components/trends_chart.dart';
import 'package:patrimonio/screens/tax_planning_screen.dart';
import '../services/auth_service.dart';
import 'hidden_items_screen.dart';
import 'security_screen.dart';

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
  final Color accent;
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
        Color(0xFF00E676), NavTier.primary),
    _NavDest(NavId.portfolio, 'Portfolio', 'Invest', Icons.pie_chart_outline,
        Color(0xFF1DE9B6), NavTier.primary),
    _NavDest(NavId.transactions, 'Transactions', 'Activity',
        Icons.receipt_long_outlined, Color(0xFF00B0FF), NavTier.primary),
    _NavDest(NavId.cashFlow, 'Cash flow', 'Cash',
        Icons.account_balance_wallet_outlined, Color(0xFF1DE9B6),
        NavTier.primary),
    _NavDest(NavId.projections, 'Projections', 'Proj.',
        Icons.trending_up_outlined, Color(0xFFFFB300), NavTier.secondary),
    _NavDest(NavId.tax, 'Tax planning', 'Tax', Icons.account_balance_outlined,
        Color(0xFFAB47BC), NavTier.secondary),
    _NavDest(NavId.lending, 'Lending', 'Loans', Icons.monetization_on,
        Color(0xFF1DE9B6), NavTier.secondary),
    _NavDest(NavId.settings, 'Settings', 'Settings', Icons.settings_outlined,
        Color(0xFF90A4AE), NavTier.secondary),
  ];

  /// The currently-visible sections. Lending is filtered out unless the
  /// module is enabled; everything else is always present.
  List<_NavDest> get _destinations => [
        for (final d in _allDestinations)
          if (d.id != NavId.lending || _lendingEnabled) d,
      ];

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
                web.window.location.href = '${_apiService.baseUrl}/auth/coinbase';
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
        accent: d.accent,
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
          Text(
            (es ? 'En moneda nativa' : 'Held natively').toUpperCase(),
            style: TextStyle(
              fontSize: 9,
              letterSpacing: 0.8,
              fontWeight: FontWeight.w700,
              color: context.textFaint,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
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
                        text: formatCurrencyWithCode(e.net, e.cur),
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: context.textPrimary,
                        ),
                      ),
                      if (!isTarget)
                        TextSpan(
                          text: '  ≈ ${currencyFormat.format(converted)}',
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
        ],
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 18),
      decoration: BoxDecoration(
        color: accent.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: accent.withValues(alpha: 0.32), width: 1.2),
      ),
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
            currencyFormat.format(netWorth),
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.w800,
              color: context.textPrimary,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          ?composition,
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
      switch (categorizeAccount(acc['account_type']?.toString())) {
        case AccountCategory.credit:
        case AccountCategory.loan:
          liabilities += reported;
        case AccountCategory.cash:
          cash += reported;
        case AccountCategory.investment:
        case AccountCategory.crypto:
          investments += reported;
        case AccountCategory.realAsset:
          realAssets += reported;
        case AccountCategory.other:
          // Don't double-count unknowns into cash/investments; they're
          // still in net_worth (computed server-side) so the totals
          // remain consistent.
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

    // Net worth is no longer a tile here — it's the dedicated hero block
    // (_buildNetWorthHero) directly above this row, with the native-currency
    // composition bound to it. These tiles are the secondary stats that
    // decompose that total.
    final tiles = <_StatTile>[
      _StatTile(
        label: l.statAssets,
        value: currencyFormat.format(assets),
        // Neutral grey — a calm lead-in to the colour-coded secondary
        // stats so the row reads as a coherent set with a meaningful
        // category cue rather than competing colours.
        accent: context.neutralAccent,
      ),
      _StatTile(
        label: l.statLiabilities,
        value: currencyFormat.format(liabilities),
        accent: context.negative,
      ),
      _StatTile(
        label: l.statCash,
        value: currencyFormat.format(cash),
        accent: context.info,
      ),
      _StatTile(
        label: l.statInvestments,
        value: currencyFormat.format(investments),
        accent: context.tealAccent,
      ),
      // Real assets tile shows up only when the user actually has any —
      // a typical brand-new account has none and an empty $0 tile would
      // waste the row's horizontal budget.
      if (realAssets > 0)
        _StatTile(
          label: 'Real assets',
          value: currencyFormat.format(realAssets),
          accent: context.yellowAccent,
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
        padding: const EdgeInsets.all(20),
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
    final recordedAtRaw = _fxRate?['recorded_at'] as String?;
    final recordedLocal = recordedAtRaw == null
        ? null
        : DateTime.tryParse(recordedAtRaw)?.toLocal();
    final isStale = recordedLocal != null &&
        DateTime.now().difference(recordedLocal).inHours > 24;

    // Compact mode drops the "1 USD = " / " MXN" framing so a phone-width
    // AppBar can still show the live rate alongside the currency toggle.
    final label = rate == null
        ? (compact ? '— MXN' : '1 USD = — MXN')
        : compact
            ? NumberFormat('0.00').format(rate)
            : '1 USD = ${NumberFormat('0.00').format(rate)} MXN';
    final accent = isStale ? context.warning : context.tealAccent;

    final tooltip = rate == null
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

    return Tooltip(
      message: tooltip,
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
    final uri = Uri.parse(web.window.location.href);
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
  Widget _buildCashFlowPeriodSelector(AppLocalizations l) {
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
              : l.dashWebhookPartial(updated, failed)),
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
      ]);

      debugPrint("All data loaded successfully");

      final allocationRaw = results[8] as List<dynamic>;
      final trendsRaw = results[9] as List<dynamic>;

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
      };

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

        _allocationData = allocationRaw.map((e) {
          final category = e['category'] as String;
          final subCategory = e['sub_category'] as String;
          final value = (e['value'] as num).toDouble();
          final quantity = (e['quantity'] as num?)?.toDouble() ?? 0.0;

          return AllocationData(
            category,
            subCategory,
            value,
            categoryColors[category] ?? Colors.blueGrey,
            quantity: quantity,
          );
        }).toList();

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
              appBar: AppBar(
          title: const FittedBox(
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
              if (!isCompact) const SizedBox(width: 4),
              // FX pill — keep visible on mobile too; the live USD/MXN
              // rate is the most currency-relevant signal for this user.
              _buildFxBadge(compact: true),
              const SizedBox(width: 4),
              NotificationsBell(
                dismissedIds: _dismissedNotifs,
                onMarkAllRead: (ids) {
                  setState(() => _dismissedNotifs = ids);
                  Preferences.setDismissedNotifications(ids);
                },
                notifications: deriveNotifications(
                  l: AppLocalizations.of(context),
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
            _ThemeCycleButton(),
            if (!firstRun)
              _CurrencyToggleButton(
                targetCurrency: _targetCurrency,
                onSwap: () => _setTargetCurrency(
                    _targetCurrency == 'USD' ? 'MXN' : 'USD'),
              ),
            // Hidden Items, Security, and Sign Out live in a single overflow
            // menu so the AppBar doesn't clip at typical widths. Material 3
            // MenuAnchor anchors the menu to the button and opens it directly
            // beneath (end-aligned for this right-side trigger), with a
            // rounded, elevated M3 surface — cleaner than the old tap-anchored
            // PopupMenuButton.
            Builder(
              builder: (menuCtx) {
                final scheme = Theme.of(menuCtx).colorScheme;
                return MenuAnchor(
                  alignmentOffset: const Offset(0, 6),
                  style: MenuStyle(
                    alignment: AlignmentDirectional.bottomEnd,
                    elevation: const WidgetStatePropertyAll(3),
                    backgroundColor:
                        WidgetStatePropertyAll(scheme.surfaceContainerHigh),
                    surfaceTintColor:
                        WidgetStatePropertyAll(scheme.surfaceTint),
                    shape: WidgetStatePropertyAll(
                      RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    padding: const WidgetStatePropertyAll(
                      EdgeInsets.symmetric(vertical: 6),
                    ),
                  ),
                  builder: (context, controller, _) => IconButton(
                    tooltip: l.navMore,
                    icon: const Icon(Icons.more_vert),
                    onPressed: () => controller.isOpen
                        ? controller.close()
                        : controller.open(),
                  ),
                  menuChildren: [
                    MenuItemButton(
                      leadingIcon:
                          const Icon(Icons.visibility_off_outlined, size: 20),
                      onPressed: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const HiddenItemsScreen()),
                        );
                        if (mounted) _loadAllData(silent: true);
                      },
                      child: Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: Text(l.dashHiddenItems),
                      ),
                    ),
                    MenuItemButton(
                      leadingIcon: const Icon(Icons.shield_outlined, size: 20),
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute(
                            builder: (_) => const SecurityScreen()),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: Text(l.dashSecurity),
                      ),
                    ),
                    // Language toggle (EN ⇄ ES). Shows the language you'd
                    // switch TO, in its own name (autonym). Persists + flips
                    // the app locale live via localeNotifier.
                    MenuItemButton(
                      leadingIcon: const Icon(Icons.translate, size: 20),
                      onPressed: () {
                        final next =
                            Localizations.localeOf(context).languageCode == 'es'
                                ? 'en'
                                : 'es';
                        Preferences.setLocale(next);
                        localeNotifier.value = Locale(next);
                      },
                      child: Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: Text(
                          Localizations.localeOf(context).languageCode == 'es'
                              ? 'English'
                              : 'Español',
                        ),
                      ),
                    ),
                    const Divider(height: 8, indent: 12, endIndent: 12),
                    MenuItemButton(
                      leadingIcon:
                          Icon(Icons.logout, size: 20, color: scheme.error),
                      onPressed: () => AuthService.instance.logout(),
                      child: Padding(
                        padding: const EdgeInsets.only(right: 16),
                        child: Text(l.dashSignOut,
                            style: TextStyle(color: scheme.error)),
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(width: 4),
          ],
        ),
              // Narrow screens get a Material 3 bottom nav bar; wide
              // screens get a left rail (built into the body Row below).
              bottomNavigationBar:
                  (!firstRun && isCompact) ? _buildBottomBar() : null,
              body: Column(
                children: [
                  if (!firstRun)
                    SyncErrorBanner(
                      syncData: _syncData ?? const [],
                      onJumpToManagement: () => _goToNav(NavId.settings),
                      // Open Plaid Link directly so a "Chase needs
                      // reconnecting" banner is one click to resolve,
                      // not three (banner → Settings → row button).
                      onReconnect: _handleReconnect,
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
            const Icon(Icons.error_outline, size: 64, color: Colors.red),
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
    Widget buildTabContainer(Widget child, {bool scrollable = true}) {
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

      return scrollable
          ? SingleChildScrollView(
              padding: EdgeInsets.fromLTRB(
                  padding, padding, padding, padding + snackbarClearance),
              child: content,
            )
          : Padding(padding: EdgeInsets.all(padding), child: content);
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
                visualDensity: VisualDensity.compact,
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

    Widget buildChartsColumn(bool isNarrow) {
      return Column(
        children: [
          buildNetWorthHeader(),
          const SizedBox(height: 12),
          // The card stacks a tall header (value + delta + mode toggle) above
          // an Expanded chart, so the box has to stay tall enough that the
          // plot area doesn't get squished — this is the hero glance on
          // mobile. (A shorter box collapsed the chart to a sliver.)
          SizedBox(
            height: isNarrow ? 380 : 440,
            child: NetWorthCard(
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
            ),
          ),
          // Glanceable assets-vs-liabilities split. Skipped during
          // first-run when typeBreakdown is empty (the widget renders
          // a SizedBox.shrink in that case anyway).
          if ((_overview?['type_breakdown'] as List?)?.isNotEmpty ?? false) ...[
            const SizedBox(height: 12),
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
      LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 900;
          final stats = _buildStatStrip(
            currencyFormat: currencyFormat,
            conversionFactor: conversionFactor,
            usdMxnRate: fxRate,
          );

          final body = isNarrow
              ? Column(
                  children: [
                    // On mobile the net-worth trend is the canonical glance,
                    // so it leads — the long accounts list follows. (On wide
                    // screens they sit side by side, order doesn't matter.)
                    buildChartsColumn(true),
                    const SizedBox(height: 20),
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
                    Expanded(flex: 2, child: buildChartsColumn(false)),
                  ],
                );

          // Net-worth-focused secondary widgets. On wide screens they sit in
          // the main stack; on phones they fold into the "Details" disclosure
          // below so the default Glance view stays hero → trend → accounts.
          final goalTile = NetWorthGoalTile(
            netWorthUsd: (_overview?['net_worth'] as num?)?.toDouble() ?? 0.0,
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
          );
          final emergencyCard = EmergencyFundCard(
            apiService: _apiService,
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
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
                // GLANCE (always visible): trend + accounts.
                body,
                const SizedBox(height: 20),
                // DETAILS (one tap): stat strip, goal, emergency fund. Folded
                // away by default so the phone view isn't a wall of cards;
                // expand-state is remembered across visits.
                _buildOverviewDetails([
                  stats,
                  const SizedBox(height: 20),
                  goalTile,
                  const SizedBox(height: 20),
                  emergencyCard,
                ]),
              ] else ...[
                stats,
                const SizedBox(height: 20),
                goalTile,
                const SizedBox(height: 20),
                emergencyCard,
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
          const SizedBox(height: 24),
          // 2 · Performance — value-over-time + contribution-weighted return.
          RepaintBoundary(
            child: PerformanceCard(
              apiService: _apiService,
              conversionFactor: conversionFactor,
              currencyFormat: currencyFormat,
            ),
          ),
          const SizedBox(height: 24),
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
                onCategorySelected: (cat) => setState(() {
                  // Tapping the active band clears the filter — saves a
                  // round-trip through the chip's X button.
                  _portfolioCategoryFilter =
                      _portfolioCategoryFilter == cat ? null : cat;
                }),
              ),
            ),
            const SizedBox(height: 24),
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
          const SizedBox(height: 24),
          // 5 · Holdings — searchable table, drill-down filter from above.
          PortfolioCard(
            section: PortfolioSection.holdings,
            portfolioData: portfolioData,
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
            targetCurrency: _targetCurrency,
            usdMxnRate: fxRate,
            categoryFilter: _portfolioCategoryFilter,
            onClearCategoryFilter: () =>
                setState(() => _portfolioCategoryFilter = null),
            searchOverride: _portfolioSearchOverride,
          ),
          const SizedBox(height: 24),
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
                      ? l.dashTransfersLinked(
                          (r['inserted'] as num? ?? 0).toInt(),
                          (r['checked'] as num? ?? 0).toInt())
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
          ),
          SizedBox(height: gap),
          if (cashFlowSeries != null)
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
          // Hidden-from-subscriptions list. Surfaces only when there's
          // something to un-hide — keeps the cash-flow tab quiet for
          // users who never dismissed anything.
          if ((_ignoredSubscriptions ?? const []).isNotEmpty)
            _buildIgnoredSubscriptionsPanel(),
          if ((_ignoredSubscriptions ?? const []).isNotEmpty)
            SizedBox(height: gap),
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
          UpcomingBillsCard(
            subscriptions: _subscriptions ?? const [],
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
          ),
          if ((_subscriptions ?? const []).isNotEmpty)
            SizedBox(height: gap),
          SpendingByCategoryCard(
            apiService: _apiService,
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
          ),
          SizedBox(height: gap),
          BudgetsCard(
            transactions: _transactions ?? const [],
            conversionFactor: conversionFactor,
            usdMxnRate: fxRate,
            currencyFormat: currencyFormat,
            apiService: _apiService,
          ),
          SizedBox(height: gap),
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
                            padding: const EdgeInsets.symmetric(vertical: 20),
                            backgroundColor: bg,
                            // Pin foreground so the label stays legible on
                            // every tinted tile (ElevatedButton's default
                            // light-mode tonal grey fades into the tint).
                            foregroundColor: foreground,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
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
                          spacing: 16,
                          runSpacing: 16,
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
                          spacing: 16,
                          runSpacing: 16,
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
                                web.window.location.href =
                                    '$baseUrl/auth/coinbase';
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
          SizedBox(height: gap),
          // Deployment diagnostics sit last — they collapse to a single
          // "Ready" row once required checks pass, so they no longer crowd
          // the top of the tab.
          buildSetupStatusCard(),
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
              ? d.accent.withValues(alpha: 0.14)
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
                      color: selected ? d.accent : scheme.onSurfaceVariant),
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
    final secondary =
        _destinations.where((d) => d.tier == NavTier.secondary).toList();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final d in secondary)
              ListTile(
                leading: Icon(d.icon, color: d.accent),
                title: Text(_navLabel(l, d.id)),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  _goToNav(d.id);
                },
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

  const _StatTile({
    required this.label,
    required this.value,
    required this.accent,
  });

  @override
  Widget build(BuildContext context) {
    // Secondary stat: shared hairline border, tile surface, label in
    // textSubtle with a small accent dot on its leading edge — a category
    // cue without painting the whole label in a loud neon. (The net-worth
    // hero treatment now lives in _buildNetWorthHero, above the row, so
    // these tiles are uniformly secondary.)
    return Container(
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
              Text(
                label.toUpperCase(),
                style: TextStyle(
                  fontSize: 10,
                  letterSpacing: 1.2,
                  fontWeight: FontWeight.w700,
                  color: context.textSubtle,
                ),
              ),
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
  }
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
