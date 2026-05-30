import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:plaid_flutter/plaid_flutter.dart';
import 'package:web/web.dart' as web;
import 'dart:async';
import '../services/api_service.dart';
import '../main.dart' show themeModeNotifier;
import '../services/preferences.dart';
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
import '../utils/account_category.dart';
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

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({super.key});

  @override
  State<DashboardScreen> createState() => _DashboardScreenState();
}

class _DashboardScreenState extends State<DashboardScreen>
    with SingleTickerProviderStateMixin {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  String? _error;

  Map<String, dynamic>? _overview;
  List<dynamic>? _netWorthHistory;
  Map<String, dynamic>? _portfolioData;
  List<dynamic>? _creditData;
  List<dynamic>? _syncData;
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
  // true, a "Lending" tab is appended (index 7) and the TabController
  // is rebuilt to length 8.
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
  TabController? _tabController;
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
    // Lending tab unknown until the setting loads, so start with the
    // 7 base tabs; _applyLendingSetting rebuilds to 8 if enabled.
    final savedTab = Preferences.getLastTab().clamp(0, 6);
    _buildTabController(_baseTabCount, savedTab);
    _loadAllData();
    _checkRedirectStatus();
    // Open the realtime channel and route server-pushed
    // invalidations into the existing silent-reload path. The
    // service self-reconnects on drop, so we connect once at boot
    // and forget until logout.
    _realtime.connect();
    _realtimeSub = _realtime.events.listen(_handleRealtimeEvent);
  }

  @override
  void dispose() {
    _tabController?.dispose();
    _realtimeSub?.cancel();
    _realtime.dispose();
    super.dispose();
  }

  /// Base (always-on) tab count. The Lending tab is appended on top
  /// when enabled.
  static const int _baseTabCount = 7;
  int get _tabCount => _baseTabCount + (_lendingEnabled ? 1 : 0);

  /// (Re)create the TabController at a given length, preserving the
  /// current tab index (clamped). TabController.length is fixed at
  /// construction, so toggling the Lending module means disposing and
  /// rebuilding — the only safe way to change tab count at runtime.
  void _buildTabController(int length, int initialIndex) {
    _tabController?.dispose();
    _tabController = TabController(
      length: length,
      vsync: this,
      initialIndex: initialIndex.clamp(0, length - 1),
      // 300ms (the Material default) feels sluggish on a dense desktop
      // dashboard; 180ms is near-instant while still smoothing the slide.
      animationDuration: const Duration(milliseconds: 180),
    );
    _tabController!.addListener(() {
      if (!_tabController!.indexIsChanging) {
        Preferences.setLastTab(_tabController!.index);
      }
    });
  }

  /// Apply a freshly-loaded lending_enabled value. Rebuilds the
  /// TabController only when the flag actually flips, so a normal
  /// refresh doesn't churn it (and lose the user's current tab).
  void _applyLendingSetting(bool enabled) {
    if (enabled == _lendingEnabled && _tabController != null) return;
    final current = _tabController?.index ?? 0;
    _lendingEnabled = enabled;
    _buildTabController(_tabCount, current);
  }

  /// Server-pushed event handler. Every event maps to "refetch the
  /// dashboard silently" today — the event payload is coarse on
  /// purpose so we don't have to mirror every response shape over
  /// the websocket. If the dashboard ever grows more refetch
  /// granularity, branch on `e.type` here.
  void _handleRealtimeEvent(RealtimeEvent e) {
    if (!mounted) return;
    debugPrint('realtime: received ${e.type}');
    _loadAllData(silent: true);
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

  bool get _isFirstRun => !_isLoading && _error == null && !_hasAccounts;

  // Build the searchable index used by the Cmd-K palette. We do it on
  // demand so the list always reflects the most recent _loadAllData()
  // payload. Each item carries a callback that navigates to the right
  // tab so the palette doesn't have to know the dashboard's layout.
  List<PaletteItem> _buildPaletteItems() {
    final items = <PaletteItem>[];

    void jumpTab(int i) => _tabController?.animateTo(i);

    // Mirror the currency / FX setup _buildBody does so the account
    // panel that opens from the palette uses the same reporting context.
    final fxRate = (_fxRate?['rate'] as num?)?.toDouble() ?? 1.0;
    final conversionFactor = _targetCurrency == 'MXN' ? fxRate : 1.0;
    final currencyFormat = NumberFormat.currency(
      name: _targetCurrency,
      symbol: '$_targetCurrency ',
    );

    const tabs = [
      ('Overview', 0, Icons.dashboard_outlined, Color(0xFF00E676)),
      ('Portfolio', 1, Icons.pie_chart_outline, Color(0xFF1DE9B6)),
      ('Transactions', 2, Icons.receipt_long_outlined, Color(0xFF00B0FF)),
      ('Cash flow', 3, Icons.account_balance_wallet_outlined, Color(0xFF1DE9B6)),
      ('Projections', 4, Icons.trending_up_outlined, Color(0xFFFFB300)),
      ('Tax planning', 5, Icons.account_balance_outlined, Color(0xFFAB47BC)),
      ('Management', 6, Icons.settings_outlined, Color(0xFF90A4AE)),
    ];
    for (final (label, idx, icon, color) in tabs) {
      items.add(PaletteItem(
        label: 'Jump to $label',
        subtitle: 'Tab',
        icon: icon,
        accent: color,
        onSelected: () => jumpTab(idx),
      ));
    }
    // Lending tab is conditional — appended at _baseTabCount when on.
    if (_lendingEnabled) {
      items.add(PaletteItem(
        label: 'Jump to Lending',
        subtitle: 'Tab · money you\'ve lent',
        icon: Icons.handshake_outlined,
        accent: const Color(0xFF1DE9B6),
        onSelected: () => jumpTab(_baseTabCount),
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
        subtitle: 'Account · $inst',
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
        subtitle: 'Holding',
        icon: Icons.show_chart,
        accent: context.info,
        onSelected: () {
          setState(() => _portfolioSearchOverride = seed);
          jumpTab(1);
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
        subtitle:
            'Transaction · ${t['account_name'] ?? ''} · ${t['date'] ?? ''}',
        icon: Icons.receipt_outlined,
        accent: context.warning,
        onSelected: () {
          setState(() {
            _transactionsSearchOverride = desc;
            _highlightedTxId = id;
          });
          jumpTab(2);
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
        label: 'Net worth',
        value: currencyFormat.format(netWorth),
        accent: context.positive,
        emphasized: true,
      ),
      _StatTile(
        label: 'Assets',
        value: currencyFormat.format(assets),
        // Neutral grey — sits between the green hero (Net worth) and
        // the colour-coded secondary stats so the row reads as a
        // coherent set with a meaningful category cue rather than
        // five competing colours.
        accent: context.neutralAccent,
      ),
      _StatTile(
        label: 'Liabilities',
        value: currencyFormat.format(liabilities),
        accent: context.negative,
      ),
      _StatTile(
        label: 'Cash',
        value: currencyFormat.format(cash),
        accent: context.info,
      ),
      _StatTile(
        label: 'Investments',
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
                  'Hidden from subscriptions',
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
              'You dismissed these as "not a subscription." Unhide a row to let the detector reconsider it.',
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
            label: const Text('Unhide'),
            onPressed: () async {
              try {
                await _apiService.unignoreSubscription(key);
                await _refreshData();
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('"$key" is back in the subscription detector')),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Unhide failed: $e')),
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
                  Icon(Icons.handshake_outlined, color: context.tealAccent),
              title: Text('Personal lending',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, color: context.textPrimary)),
              subtitle: Text(
                'Track money you lend to friends — designate the bank '
                'transactions that fund and repay each loan. Adds a Lending tab.',
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
                        'Remind me before a repayment is due',
                        style: TextStyle(
                            fontSize: 13, color: context.textPrimary),
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.remove_circle_outline, size: 20),
                      tooltip: 'Fewer days',
                      onPressed: _lendingReminderLeadDays <= 0
                          ? null
                          : () => _setReminderLeadDays(
                              _lendingReminderLeadDays - 1),
                    ),
                    Text('$_lendingReminderLeadDays d',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: context.textPrimary,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        )),
                    IconButton(
                      icon: const Icon(Icons.add_circle_outline, size: 20),
                      tooltip: 'More days',
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
        const SnackBar(content: Text('Couldn\'t save reminder setting')),
      );
    }
  }

  Future<void> _toggleLending(bool enabled) async {
    // Optimistically flip the tab + controller, then persist. On
    // failure, revert so the UI doesn't lie about the saved state.
    setState(() => _applyLendingSetting(enabled));
    try {
      await _apiService.putSetting('lending_enabled', enabled);
    } catch (e) {
      if (!mounted) return;
      setState(() => _applyLendingSetting(!enabled));
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Couldn\'t save that setting')),
      );
    }
  }

  /// `Sandbox` / `Development` otherwise. Reads `plaid_environment`
  /// from `/api/setup/status` (already loaded into _setupStatus).
  Widget _buildEnvChip() {
    final env = (_setupStatus?['plaid_environment'] ?? '')
        .toString()
        .toLowerCase()
        .trim();
    if (env.isEmpty || env == 'production') {
      return const SizedBox.shrink();
    }
    final label = env == 'sandbox'
        ? 'Sandbox'
        : env == 'development'
            ? 'Dev'
            : env;
    return Tooltip(
      message:
          'Plaid is in $env mode. Linked accounts will not access real bank data.',
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
        ? 'Exchange rate loading…'
        : recordedLocal == null
            ? 'Live USD/MXN exchange rate'
            : '${isStale ? "Stale rate — " : "Updated "}'
                '${DateFormat('MMM d, y · h:mm a').format(recordedLocal)} '
                '${recordedLocal.timeZoneName}';

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
                      title: 'Link a US bank',
                      subtitle:
                          'Securely connect via Plaid — balances and transactions sync automatically.',
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
                      disabledHint:
                          'Plaid credentials not configured yet — use CSV or manual for now.',
                    ),
                    actionTile(
                      icon: Icons.upload_file,
                      title: 'Import Mexico CSV or PDF',
                      subtitle:
                          'Drop a statement from Bancomer, Banamex, Santander or Banorte.',
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
                      title: 'Add a manual account',
                      subtitle:
                          'Track a cash balance, brokerage, or anything else by hand.',
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
                        'Welcome to Patrimonio',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: context.textPrimary,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Connect your first account to see your net worth, '
                        'transactions, and projections in one place.',
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
                        'Already linked accounts elsewhere? They will appear here as soon as the first sync completes.',
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
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Account linked successfully!'),
            backgroundColor: context.positive,
          ),
        );
      });
    } else if (status == 'error') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Failed to link account. Please try again.'),
            backgroundColor: context.negative,
          ),
        );
      });
    }
  }

  Future<void> _refreshData() => _loadAllData(silent: true);

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
      final cfg = LinkTokenConfiguration(token: linkToken);
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
      PlaidLink.create(configuration: cfg);
      PlaidLink.open();
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Reconnect failed: $e')),
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
              ? 'Webhook URL pushed to $updated institution${updated == 1 ? '' : 's'}'
              : '$updated updated, $failed failed'),
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
                    final name = row['name']?.toString() ?? 'Unknown';
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
              child: const Text('Close'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Push failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _loadAllData({bool silent = false}) async {
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
        _apiService.getDashboardOverview(),
        _apiService.getNetWorthHistory(),
        _apiService.getHoldings(),
        _apiService.getCreditUtilization(),
        _apiService.getSyncStatus(),
        _apiService.getSetupStatus(),
        _apiService.getExchangeRate('USD', 'MXN'),
        _apiService.getTransactions(limit: _txPageSize),
        _apiService.getAllocationData(),
        _apiService.getTrendData(),
        // These two are non-blocking — a failure shouldn't take the
        // whole dashboard down. Wrap each Future so it can't propagate.
        _apiService.getSinceLastLogin().catchError((_) => null),
        _apiService
            .getSubscriptions()
            .catchError((_) => <dynamic>[]),
        _apiService.getFxTransfers().catchError((_) => <dynamic>[]),
        _apiService
            .getIgnoredSubscriptions()
            .catchError((_) => <dynamic>[]),
        // Best-effort: a settings failure shouldn't take the dashboard
        // down — just default the module off.
        _apiService.getSetting('lending_enabled').catchError((_) => null),
        // Loan reminders + lead-time setting. Both defensive — empty /
        // default when lending is off or the call fails.
        _apiService.getLoanReminders().catchError((_) => <dynamic>[]),
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
        // raw bool; absent/null = off. Rebuilds the TabController only
        // when the flag actually flips.
        _applyLendingSetting(results[14] == true);
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
    } catch (e, stack) {
      debugPrint("Data load error: $e\n$stack");
      setState(() {
        _error = "Error: $e";
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
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
          bottom: firstRun
              ? null
              : TabBar(
                  controller: _tabController,
                  isScrollable: isCompact,
                  tabAlignment:
                      isCompact ? TabAlignment.start : TabAlignment.fill,
                  indicatorColor: context.positive,
                  labelColor: context.positive,
                  unselectedLabelColor: context.textMuted,
                  tabs: [
                    const Tab(text: 'Overview'),
                    const Tab(text: 'Portfolio'),
                    const Tab(text: 'Transactions'),
                    Tab(text: isCompact ? 'Cash' : 'Cash flow'),
                    Tab(text: isCompact ? 'Proj.' : 'Projections'),
                    Tab(text: isCompact ? 'Tax' : 'Tax planning'),
                    Tab(text: isCompact ? 'Manage' : 'Management'),
                    // Appended only when the module is enabled — the
                    // TabController length is kept in lockstep via
                    // _applyLendingSetting.
                    if (_lendingEnabled)
                      Tab(text: isCompact ? 'Loans' : 'Lending'),
                  ],
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
              // FX pill — wide screens only.
              if (!isCompact) _buildFxBadge(compact: true),
              if (!isCompact) const SizedBox(width: 4),
              NotificationsBell(
                notifications: deriveNotifications(
                  syncData: _syncData ?? const [],
                  netWorthHistory: _netWorthHistory ?? const [],
                  onJumpToManagement: () =>
                      _tabController?.animateTo(6),
                  loanReminders: _loanReminders,
                  // Lending is appended last; its index == _baseTabCount
                  // (7). Only present when reminders exist (lending on).
                  onJumpToLending: () =>
                      _tabController?.animateTo(_baseTabCount),
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
            // Hidden Items, Security, and Sign Out are grouped into a
            // single popup so the AppBar doesn't overflow — at typical
            // browser widths 8+ action widgets get clipped silently.
            PopupMenuButton<_AppBarAction>(
              tooltip: 'More',
              icon: const Icon(Icons.more_vert),
              onSelected: (action) async {
                switch (action) {
                  case _AppBarAction.hiddenItems:
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const HiddenItemsScreen()),
                    );
                    if (mounted) _loadAllData(silent: true);
                  case _AppBarAction.security:
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                          builder: (_) => const SecurityScreen()),
                    );
                  case _AppBarAction.signOut:
                    await AuthService.instance.logout();
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: _AppBarAction.hiddenItems,
                  child: ListTile(
                    leading: Icon(Icons.visibility_off_outlined),
                    title: Text('Hidden items'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuItem(
                  value: _AppBarAction.security,
                  child: ListTile(
                    leading: Icon(Icons.shield_outlined),
                    title: Text('Security'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
                PopupMenuDivider(),
                PopupMenuItem(
                  value: _AppBarAction.signOut,
                  child: ListTile(
                    leading: Icon(Icons.logout),
                    title: Text('Sign out'),
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ],
            ),
            const SizedBox(width: 4),
          ],
        ),
              body: Column(
                children: [
                  if (!firstRun)
                    SyncErrorBanner(
                      syncData: _syncData ?? const [],
                      onJumpToManagement: () =>
                          _tabController?.animateTo(6),
                      // Open Plaid Link directly so a "Chase needs
                      // reconnecting" banner is one click to resolve,
                      // not three (banner → Management → row button).
                      onReconnect: _handleReconnect,
                    ),
                  Expanded(child: _buildBody()),
                ],
              ),
            ),
          ),
        ),
      );
  }

  Widget _buildBody() {
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
              'Error loading dashboard: $_error',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadAllData, child: const Text('Retry')),
          ],
        ),
      );
    }

    if (_isFirstRun) {
      return _buildOnboardingHero();
    }

    final fxRate = (_fxRate?['rate'] as num?)?.toDouble() ?? 1.0;
    final conversionFactor = _targetCurrency == 'MXN' ? fxRate : 1.0;
    final currencyFormat = NumberFormat.currency(
      name: _targetCurrency,
      symbol: '$_targetCurrency ',
    );
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
            onGoToManagement: () => _tabController?.animateTo(6),
            onBalanceUpdate: (id, bal) async {
              try {
                await _apiService.updateAccountBalance(id, bal);
                _loadAllData(silent: true);
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(
                  context,
                ).showSnackBar(SnackBar(content: Text('Update failed: $e')));
              }
            },
            onDeleteAccount: (id) async {
              try {
                await _apiService.deleteAccount(id);
                _loadAllData(silent: true);
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Account deleted')),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Delete failed: $e')),
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
                          ? 'Nickname cleared'
                          : 'Renamed to "$nickname"',
                    ),
                  ),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Rename failed: $e')),
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
                          ? 'Revalued'
                          : 'Revalued · note saved',
                    ),
                  ),
                );
              } catch (e) {
                if (!mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('Revalue failed: $e')),
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
          final title = const Text(
            'Net worth history',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
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
        const SnackBar(
          content: Row(
            children: [
              SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor:
                      AlwaysStoppedAnimation<Color>(Colors.white),
                ),
              ),
              SizedBox(width: 12),
              Text('Syncing all institutions…'),
            ],
          ),
          duration: Duration(seconds: 30),
        ),
      );
      try {
        await _apiService.syncInstitutions();
        if (!mounted) return;
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          const SnackBar(
            content: Text('Sync complete'),
            duration: Duration(seconds: 2),
          ),
        );
      } catch (e) {
        debugPrint("Sync error: $e");
        if (!mounted) return;
        messenger.hideCurrentSnackBar();
        messenger.showSnackBar(
          SnackBar(content: Text('Sync failed: $e')),
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

        LinkTokenConfiguration linkTokenConfiguration = LinkTokenConfiguration(
          token: linkToken,
        );

        PlaidLink.onSuccess.listen((event) {
          debugPrint("Plaid Reconnect Success");
          runSync();
        });
        PlaidLink.onExit.listen((event) {
          debugPrint("Plaid Reconnect Exit");
          _loadAllData(silent: true);
        });

        PlaidLink.create(configuration: linkTokenConfiguration);
        PlaidLink.open();
      } catch (e) {
        debugPrint("Reconnect error: $e");
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Reconnect failed: $e')));
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
                  const Text(
                    'Launch setup',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                blocking.isEmpty
                    ? 'Plaid linking can start. Optional services may still improve data quality.'
                    : 'Complete required setup before real users can link Plaid accounts.',
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
                      'Push to $plaidInstitutionCount '
                      'institution${plaidInstitutionCount == 1 ? '' : 's'}',
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
                  'Recommended before production: '
                  '${recommended
                          .map((c) => (c as Map)['label']?.toString() ?? '')
                          .where((s) => s.isNotEmpty)
                          .join(', ')}'
                      '.',
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
                    Expanded(flex: 1, child: buildAccountsColumn()),
                    const SizedBox(width: 24),
                    Expanded(flex: 3, child: buildChartsColumn(false)),
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
                  _tabController?.animateTo(2);
                },
                onJumpToManagement: () => _tabController?.animateTo(6),
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
        onGoToManagement: () => _tabController?.animateTo(6),
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
              SnackBar(content: Text('Confirm failed: $e')),
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
              SnackBar(content: Text('Unlink failed: $e')),
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
            const SnackBar(content: Text('Scanning for cross-currency transfers…')),
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
                      ? 'Linked ${r['inserted']} transfer pair${(r['inserted'] as num? ?? 0) == 1 ? '' : 's'} '
                          '(checked ${r['checked']} candidates)'
                      : 'No new transfers found',
                ),
              ),
            );
          } catch (e) {
            if (!mounted) return;
            messenger.hideCurrentSnackBar();
            messenger.showSnackBar(
              SnackBar(content: Text('Detection failed: $e')),
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
              SnackBar(content: Text('Failed to update transaction: $e')),
            );
          }
        },
        onDelete: (id) async {
          await _apiService.deleteTransaction(id);
          await _refreshData();
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Transaction deleted')),
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
                _tabController?.animateTo(2);
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
                    const SnackBar(content: Text('Link confirmed')),
                  );
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Confirm failed: $e')),
                  );
                }
              },
              onUnlink: (id) async {
                try {
                  await _apiService.unlinkFxTransfer(id);
                  await _refreshData();
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Pair unlinked')),
                  );
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Unlink failed: $e')),
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
                _tabController?.animateTo(2);
              },
              onIgnoreMerchant: (m) async {
                try {
                  await _apiService.ignoreSubscription(m);
                  await _refreshData();
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('"$m" hidden from subscriptions')),
                  );
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Failed: $e')),
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
          const Text(
            'Data sources & sync',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
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
                    SnackBar(content: Text('Retry failed: $e')),
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
                    SnackBar(content: Text('Retry failed: $e')),
                  );
                }
              },
              onReconnect: handleReconnect,
              onDelete: (id) async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (context) => AlertDialog(
                    title: const Text('Delete institution'),
                    content: const Text(
                        'Are you sure? This will remove ALL accounts and history for this institution.'),
                    actions: [
                      TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Cancel')),
                      TextButton(
                        onPressed: () => Navigator.pop(context, true),
                        style: TextButton.styleFrom(
                            foregroundColor: context.negative),
                        child: const Text('Delete everything'),
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
                        SnackBar(content: Text('Delete failed: $e')));
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
                    const SnackBar(content: Text('FX rate refreshed')),
                  );
                } catch (e) {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text('Refresh failed: $e')),
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
            'Connect standard accounts',
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
                tile(Icons.sync, 'Sync all accounts',
                    bg: context.accentSoft(context.info), onPressed: runSync),
                tile(
                  Icons.add_link,
                  'Link Plaid (US Banks)',
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
                tile(Icons.upload_file, 'Import Mexico (CSV/PDF)',
                    bg: context.hairline,
                    onPressed: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (context) => const ImportScreen(),
                        ),
                      ).then((_) => _loadAllData(silent: true));
                    }),
                tile(Icons.add_circle_outline, 'Add manual account',
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
            'Connect crypto exchanges',
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
                    label: const Text(
                      'Link Coinbase',
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
                    label: const Text(
                      'Connect Bitso',
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

    return TabBarView(
      controller: _tabController,
      children: [
        _KeepAliveTab(child: overviewTab),
        _KeepAliveTab(child: portfolioTab),
        _KeepAliveTab(child: transactionsTab),
        _KeepAliveTab(child: cashFlowTab),
        _KeepAliveTab(child: projectionsTab),
        _KeepAliveTab(child: taxPlanningTab),
        _KeepAliveTab(child: managementTab),
        // Kept in lockstep with the TabBar tab + controller length.
        if (_lendingEnabled) _KeepAliveTab(child: lendingTab),
      ],
    );
  }
}

/// Keeps a TabBarView child alive across tab switches so its State (and any
/// initState API calls — projections, tax planning, etc.) only fires once.
/// Without this, every click of Projections or Tax planning re-fetched its
/// data, which the user perceives as a sluggish tab switch.
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
                style: TextStyle(
                  fontSize: isHero ? 22 : 18,
                  fontWeight:
                      isHero ? FontWeight.w900 : FontWeight.w700,
                  color: context.textPrimary,
                  fontFeatures: const [FontFeature.tabularFigures()],
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
        message: 'Reporting in $targetCurrency · tap to swap',
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

  String _labelFor(ThemeMode m) => switch (m) {
        ThemeMode.system => 'System theme',
        ThemeMode.light => 'Light theme',
        ThemeMode.dark => 'Dark theme',
      };

  void _persist(ThemeMode m) => Preferences.setThemeMode(switch (m) {
        ThemeMode.system => 'system',
        ThemeMode.light => 'light',
        ThemeMode.dark => 'dark',
      });

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (ctx, mode, _) {
        return GestureDetector(
          onLongPress: () async {
            final picked = await showMenu<ThemeMode>(
              context: context,
              position: const RelativeRect.fromLTRB(1000, 56, 0, 0),
              items: const [
                PopupMenuItem(
                  value: ThemeMode.system,
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.brightness_auto),
                    title: Text('System default'),
                  ),
                ),
                PopupMenuItem(
                  value: ThemeMode.light,
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.light_mode_outlined),
                    title: Text('Light'),
                  ),
                ),
                PopupMenuItem(
                  value: ThemeMode.dark,
                  child: ListTile(
                    dense: true,
                    leading: Icon(Icons.dark_mode_outlined),
                    title: Text('Dark'),
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
            tooltip:
                '${_labelFor(mode)} · tap to cycle, long-press to pick',
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

/// Actions available from the AppBar "More" popup.
enum _AppBarAction { hiddenItems, security, signOut }
