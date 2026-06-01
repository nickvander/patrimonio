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
import '../widgets/net_worth_card.dart';
import '../widgets/assets_liabilities_bar.dart';
import '../widgets/monthly_cash_flow_card.dart';
import '../widgets/budgets_card.dart';
import '../widgets/net_worth_goal_tile.dart';
import '../widgets/accounts_breakdown_card.dart';
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
  Map<String, dynamic>? _setupStatus;
  Map<String, dynamic>? _fxRate;
  List<dynamic>? _transactions;
  List<AllocationData>? _allocationData;
  List<Map<String, dynamic>>? _trendData;
  Map<String, dynamic>? _sinceLastLogin;
  List<dynamic>? _subscriptions;
  List<dynamic>? _ignoredSubscriptions;
  // Opt-in personal-lending module. Server-side per-user setting
  // (app_settings 'lending_enabled'), fetched in _loadAllData. When
  // true, a "Lending" section is inserted into [_destinations] (between
  // Tax planning and Settings). No controller juggling — the section
  // list is just recomputed.
  bool _lendingEnabled = false;
  // Upcoming + overdue loan installments for the notifications bell.
  List<dynamic> _loanReminders = const [];
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

  @override
  void dispose() {
    _reloadDebounce?.cancel();
    _syncPollTimer?.cancel();
    _realtimeSub?.cancel();
    _realtime.dispose();
    super.dispose();
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
    _NavDest(NavId.lending, 'Lending', 'Loans', Icons.monetization_on_outlined,
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

  /// Five-tile compact stat strip pinned to the top of the Overview tab.
  /// All values are derived from the already-loaded /dashboard/overview
  /// payload so no extra API call is needed.
  Widget _buildStatStrip({
    required NumberFormat currencyFormat,
    required double conversionFactor,
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
      final usdBal = ((acc['current_balance'] as num?)?.toDouble() ?? 0.0);
      final reported = usdBal.abs() * conversionFactor;
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

    final tiles = <_StatTile>[
      _StatTile(
        label: l.statNetWorth,
        value: currencyFormat.format(netWorth),
        accent: context.positive,
        emphasized: true,
      ),
      _StatTile(
        label: l.statAssets,
        value: currencyFormat.format(assets),
        // Neutral grey — sits between the green hero (Net worth) and
        // the colour-coded secondary stats so the row reads as a
        // coherent set with a meaningful category cue rather than
        // five competing colours.
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
                    width: c.maxWidth >= 880
                        ? (c.maxWidth - (n - 1) * 12) / n
                        : c.maxWidth >= 560
                            ? (c.maxWidth - 12) / 2 - 0.5
                            : c.maxWidth,
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
                await _refreshData();
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
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: context.hairline),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          children: [
            SwitchListTile(
              value: _lendingEnabled,
              onChanged: _toggleLending,
              secondary:
                  Icon(Icons.monetization_on_outlined, color: context.tealAccent),
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
                      icon: Icons.monetization_on_outlined,
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
    PlaidLink.onSuccess.listen((event) async {
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
    });
    PlaidLink.onExit.listen((_) {
      if (mounted) _loadAllData(silent: true);
    });
    // Defer the open until after first frame so the overlay/context are ready.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      resumePlaidLink(pending.token);
    });
  }

  /// Explicit user-initiated refresh (pull-to-refresh, "sync everything",
  /// post-mutation reloads). Bypasses the response cache so the user who
  /// just asked for fresh data gets exactly that.
  Future<void> _refreshData() => _loadAllData(silent: true, forceRefresh: true);

  Future<void> _loadMoreTransactions() async {
    final offset = _transactions?.length ?? 0;
    final more =
        await _apiService.getTransactions(limit: _txPageSize, offset: offset);
    if (!mounted) return;
    setState(() {
      _transactions = [...(_transactions ?? const []), ...more];
      // If the server returned fewer rows than we asked for, we hit the
      // tail of the table — no point offering Load more again.
      _transactionsHasMore = more.length >= _txPageSize;
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
      PlaidLink.onSuccess.listen((_) {
        debugPrint('Plaid reconnect success');
        // Defer to the global sync via the public API method so the
        // dashboard data refreshes once tokens roll forward.
        _apiService.syncInstitutions().then((_) {
          if (mounted) _loadAllData(silent: true);
        }).catchError((_) {});
      });
      PlaidLink.onExit.listen((_) {
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

    try {
      final results = await Future.wait([
        _apiService.getDashboardOverview(forceRefresh: forceRefresh),
        _apiService.getNetWorthHistory(forceRefresh: forceRefresh),
        _apiService.getHoldings(forceRefresh: forceRefresh),
        _apiService.getCreditUtilization(forceRefresh: forceRefresh),
        _apiService.getSyncStatus(forceRefresh: forceRefresh),
        _apiService.getSetupStatus(),
        _apiService.getExchangeRate('USD', 'MXN'),
        _apiService.getTransactions(limit: _txPageSize),
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
      ]);

      debugPrint("All data loaded successfully");

      final allocationRaw = results[8] as List<dynamic>;
      final trendsRaw = results[9] as List<dynamic>;

      // Allocation slice colours. Pulled through brand tokens so the
      // pie reads against a white card in light mode without each slice
      // having to be hand-tuned. The 6 categories map 1:1 to the
      // semantic accents already exposed by BrandPalette.
      final categoryColors = {
        'Cash': BrandPalette.info(brightness),
        'Stocks/ETFs': BrandPalette.teal(brightness),
        'Investment': BrandPalette.positive(brightness),
        'Crypto': BrandPalette.purple(brightness),
        'Fixed Income': BrandPalette.yellow(brightness),
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
        _transactions = results[7] as List<dynamic>;
        // If the first page came back smaller than the page size, there
        // can't be more pages. Saves us a wasted "Load more" tap.
        _transactionsHasMore = _transactions!.length >= _txPageSize;

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
        // raw bool; absent/null = off. Recomputes the section list only
        // when the flag actually flips.
        _applyLendingSetting(results[14] == true);
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
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _isLoading = false;
      });
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
          title: const Text(
            'Patrimonio',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          actions: [
            // First-run hides the dashboard chrome (FX, notifications,
            // currency toggle) because none of it has data yet. Sign
            // out and theme cycle stay so the user can always escape
            // or change brightness.
            if (!firstRun) ...[
              // Sandbox / Development indicator.
              if (!isCompact) _buildEnvChip(),
              if (!isCompact) const SizedBox(width: 4),
              // FX pill — keep visible on mobile too; the live USD/MXN
              // rate is the most currency-relevant signal for this user.
              _buildFxBadge(compact: true),
              const SizedBox(width: 4),
              NotificationsBell(
                notifications: deriveNotifications(
                  l: AppLocalizations.of(context),
                  syncData: _syncData ?? const [],
                  netWorthHistory: _netWorthHistory ?? const [],
                  onJumpToManagement: () => _goToNav(NavId.settings),
                  loanReminders: _loanReminders,
                  // No-op when lending is off (the section isn't visible);
                  // the bell only surfaces loan reminders when it's on.
                  onJumpToLending: () => _goToNav(NavId.lending),
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
      final content = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1600),
          child: child,
        ),
      );

      return scrollable
          ? SingleChildScrollView(
              padding: EdgeInsets.all(padding),
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
          const SizedBox(height: 24),
          CreditUtilizationCard(
            creditData: _creditData ?? [],
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
          ),
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
      // Don't flip the page into the full-screen loading spinner — the user
      // experiences that as a hard refresh. Show a transient SnackBar
      // instead and silently refresh data when the call completes.
      final messenger = ScaffoldMessenger.of(context);
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              const SizedBox(width: 12),
              Text(l.dashSyncingAll),
            ],
          ),
          duration: const Duration(seconds: 30),
        ),
      );
      try {
        await _apiService.syncInstitutions();
        if (!mounted) return;
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(
            content: Text(l.dashSyncComplete),
            duration: const Duration(seconds: 2),
          ),
        );
      } catch (e) {
        debugPrint("Sync error: $e");
        if (!mounted) return;
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(content: Text(l.dashSyncFailed(e.toString()))),
        );
      }
      // Reload without flipping _isLoading — just refresh the data fields.
      await _refreshData();
    }

    Future<void> handleReconnect(String institutionId) async {
      setState(() => _isLoading = true);
      try {
        final data = await _apiService.getReconnectToken(institutionId);
        final linkToken = data['link_token'];

        PlaidLink.onSuccess.listen((event) {
          debugPrint("Plaid Reconnect Success");
          runSync();
        });
        PlaidLink.onExit.listen((event) {
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

      return Card(
        elevation: 4,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    blocking.isEmpty
                        ? Icons.verified_user_outlined
                        : Icons.warning_amber_rounded,
                    color: blocking.isEmpty ? context.positive : context.warning,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    l.dashLaunchSetup,
                    style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                blocking.isEmpty
                    ? l.dashLaunchSetupReady
                    : l.dashLaunchSetupBlocked,
                style: TextStyle(color: context.textMuted, fontSize: 13),
              ),
              const SizedBox(height: 12),
              ...checks.map((raw) {
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
                  padding: const EdgeInsets.only(top: 8),
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
          ),
        ),
      );
    }

    Widget buildChartsColumn(bool isNarrow) {
      return Column(
        children: [
          buildNetWorthHeader(),
          const SizedBox(height: 12),
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
          );

          final body = isNarrow
              ? Column(
                  children: [
                    buildAccountsColumn(),
                    const SizedBox(height: 24),
                    buildChartsColumn(true),
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
              stats,
              const SizedBox(height: 24),
              // Net-worth-focused widgets stay on Overview. Cash-flow
              // widgets (monthly card, trends, budgets) moved to the
              // dedicated 'Cash flow' tab so this view stays a
              // net-worth-at-a-glance summary.
              NetWorthGoalTile(
                netWorthUsd:
                    (_overview?['net_worth'] as num?)?.toDouble() ?? 0.0,
                conversionFactor: conversionFactor,
                currencyFormat: currencyFormat,
              ),
              const SizedBox(height: 24),
              body,
            ],
          );
        },
      ),
    );

    final portfolioTab = buildTabContainer(
      Column(
        children: [
          if (_allocationData != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 24.0),
              child: AllocationHeatmap(
                data: _allocationData!,
                conversionFactor: conversionFactor,
                currencyFormat: currencyFormat,
                activeCategory: _portfolioCategoryFilter,
                onCategorySelected: (cat) => setState(() {
                  // Tapping the active band clears the filter — saves a
                  // round-trip through the chip's X button.
                  _portfolioCategoryFilter =
                      _portfolioCategoryFilter == cat ? null : cat;
                }),
              ),
            ),
          PortfolioCard(
            portfolioData: _portfolioData ?? {},
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
          AccountsBreakdownCard(
            typeBreakdown: _overview?['type_breakdown'] ?? [],
            institutionBreakdown: _overview?['institution_breakdown'] ?? [],
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
        onTransactionAdded: () => _refreshData(),
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
            await _refreshData();
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
            await _refreshData();
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text(l.dashUnlinkFailed(e.toString()))),
            );
          }
        },
        onSplitTransaction: (parentId, splits) async {
          await _apiService.splitTransaction(parentId, splits);
          await _refreshData();
        },
        onUnsplitTransaction: (parentId) async {
          await _apiService.unsplitTransaction(parentId);
          await _refreshData();
        },
        onReplaceSplits: (parentId, splits) async {
          await _apiService.replaceSplits(parentId, splits);
          await _refreshData();
        },
        onDetectFxTransfers: () async {
          final messenger = ScaffoldMessenger.of(context);
          messenger.showSnackBar(
            SnackBar(content: Text(l.dashScanningTransfers)),
          );
          try {
            final r = await _apiService.detectFxTransfers();
            await _refreshData();
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
            await _refreshData();
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
          await _refreshData();
          return n;
        },
        // Bulk delete: N deletes then ONE refresh (no per-row reload).
        onBulkDelete: (ids) async {
          for (final id in ids) {
            await _apiService.deleteTransaction(id);
          }
          await _refreshData();
        },
        onDelete: (id) async {
          await _apiService.deleteTransaction(id);
          await _refreshData();
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
    final cashFlowTab = buildTabContainer(
      Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          MonthlyCashFlowCard(
            trends: _trendData ?? const [],
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
          ),
          const SizedBox(height: 24),
          if (_trendData != null)
            CashFlowTrendsChart(
              trends: _trendData!,
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
          const SizedBox(height: 24),
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
                  await _refreshData();
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
                  await _refreshData();
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
            const SizedBox(height: 24),
          ],
          // Hidden-from-subscriptions list. Surfaces only when there's
          // something to un-hide — keeps the cash-flow tab quiet for
          // users who never dismissed anything.
          if ((_ignoredSubscriptions ?? const []).isNotEmpty)
            _buildIgnoredSubscriptionsPanel(),
          if ((_ignoredSubscriptions ?? const []).isNotEmpty)
            const SizedBox(height: 24),
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
                  await _refreshData();
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
            const SizedBox(height: 24),
          ],
          BudgetsCard(
            transactions: _transactions ?? const [],
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
            apiService: _apiService,
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

    final managementTab = buildTabContainer(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l.dashDataSources,
            style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          _buildModulesCard(),
          const SizedBox(height: 24),
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
          const SizedBox(height: 24),
          buildSetupStatusCard(),
          const SizedBox(height: 24),
          Text(
            l.dashConnectStandardAccounts,
            style: TextStyle(fontSize: 16, color: context.textMuted),
          ),
          const SizedBox(height: 12),
          // Connect-bank buttons. LayoutBuilder + Wrap lets them sit 2-up
          // when there's room, then reflow to full-width single-column on
          // phones — without crushing the "Import Mexico (CSV/PDF)" label
          // into ellipsis territory inside a forced 50% Expanded.
          LayoutBuilder(builder: (ctx, c) {
            final isNarrow = c.maxWidth < 560;
            final tileWidth = isNarrow ? c.maxWidth : (c.maxWidth - 16) / 2;
            Widget tile(IconData icon, String label,
                {Color? bg, VoidCallback? onPressed}) {
              return SizedBox(
                width: tileWidth,
                child: ElevatedButton.icon(
                  icon: Icon(icon),
                  label: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    backgroundColor: bg ?? context.accentSoft(context.info),
                    // ElevatedButton's default foreground in light mode is
                    // a tonal mid-grey that fades into the tinted bg. Pin
                    // it to textPrimary so the label and icon stay legible
                    // on every tinted tile.
                    foregroundColor: context.textPrimary,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: onPressed,
                ),
              );
            }
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                tile(Icons.sync, l.dashSyncAllAccounts,
                    bg: context.accentSoft(context.info), onPressed: runSync),
                tile(
                  Icons.add_link,
                  l.dashLinkPlaidUsBanks,
                  bg: context.accentSoft(context.tealAccent),
                  onPressed: plaidReady()
                      ? () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => const ConnectBankScreen(),
                            ),
                          ).then((_) => _loadAllData(silent: true));
                        }
                      : null,
                ),
                tile(Icons.upload_file, l.dashImportMxShort,
                    bg: context.hairline,
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const ImportScreen(),
                        ),
                      ).then((_) => _loadAllData(silent: true));
                    }),
                tile(Icons.add_circle_outline, l.dashAddManualAccountShort,
                    bg: context.hairline,
                    onPressed: () {
                      showDialog(
                        context: context,
                        builder: (context) =>
                            AddAccountDialog(onAccountCreated: _loadAllData),
                      );
                    }),
              ],
            );
          }),
          const SizedBox(height: 32),
          Text(
            l.dashConnectCryptoExchanges,
            style: TextStyle(fontSize: 16, color: context.textMuted),
          ),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (ctx, c) {
            final isNarrow = c.maxWidth < 560;
            final tileWidth = isNarrow ? c.maxWidth : (c.maxWidth - 16) / 2;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: [
                SizedBox(
                  width: tileWidth,
                  child: ElevatedButton.icon(
                    // Coinbase brand blue (#0052FF) is the official
                    // background — text/icon must be white regardless of
                    // the active theme brightness so the brand reads
                    // correctly in light mode too.
                    icon: const Icon(Icons.login, color: Colors.white),
                    label: Text(
                      l.dashLinkCoinbase,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      backgroundColor: const Color(0xFF0052FF),
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: () {
                      final baseUrl = _apiService.baseUrl;
                      web.window.location.href = '$baseUrl/auth/coinbase';
                    },
                  ),
                ),
                SizedBox(
                  width: tileWidth,
                  child: ElevatedButton.icon(
                    icon: Icon(
                      Icons.currency_exchange,
                      color: context.positive,
                    ),
                    label: Text(
                      l.dashConnectBitso,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 20),
                      backgroundColor: context.positive.withValues(alpha: 0.12),
                      foregroundColor: context.textPrimary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
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
                ),
              ],
            );
          }),
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
  /// When true, this tile gets the hero treatment — slightly tinted
  /// background + a thin accent bar on the left edge. The Net Worth
  /// tile uses this so it visually anchors the row instead of
  /// competing with the four secondary stats.
  final bool emphasized;

  const _StatTile({
    required this.label,
    required this.value,
    required this.accent,
    this.emphasized = false,
  });

  @override
  Widget build(BuildContext context) {
    // Hero: faint accent wash on the background + a 3px accent bar on
    // the left. The label gets the accent colour as a subtle
    // identifier; the value stays in textPrimary so the number is
    // what reads first.
    //
    // Secondary: shared hairline border, identical background, label
    // in textSubtle. A small accent dot on the leading edge of the
    // label gives the eye a category cue without painting the whole
    // label in a loud neon.
    final isHero = emphasized;

    return Container(
      padding: EdgeInsets.fromLTRB(isHero ? 18 : 16, 14, 16, 14),
      decoration: BoxDecoration(
        color: isHero
            ? accent.withValues(alpha: 0.06)
            : context.tileSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: isHero
              ? accent.withValues(alpha: 0.32)
              : context.hairline,
          width: isHero ? 1.2 : 1,
        ),
      ),
      child: Stack(
        children: [
          // Hero gets a left-edge accent bar; secondary tiles render
          // a small inline dot beside the label instead (handled
          // below in the label Row).
          if (isHero)
            Positioned.fill(
              left: -18,
              right: null,
              child: SizedBox(
                width: 3,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: accent,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(14),
                      bottomLeft: Radius.circular(14),
                    ),
                  ),
                ),
              ),
            ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (!isHero) ...[
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: accent,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label.toUpperCase(),
                    style: TextStyle(
                      fontSize: 10,
                      letterSpacing: 1.2,
                      fontWeight: FontWeight.w700,
                      color: isHero
                          ? accent
                          : context.textSubtle,
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
                  fontSize: isHero ? 22 : 18,
                  fontWeight: FontWeight.w700,
                  color: context.textPrimary,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
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
