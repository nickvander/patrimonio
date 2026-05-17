import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:plaid_flutter/plaid_flutter.dart';
import 'package:web/web.dart' as web;
import '../services/api_service.dart';
import '../widgets/net_worth_card.dart';
import '../widgets/accounts_breakdown_card.dart';
import '../widgets/portfolio_card.dart';
import '../widgets/fx_widget.dart';
import '../widgets/credit_utilization_card.dart';
import '../widgets/sync_status_card.dart';
import '../widgets/accounts_list_widget.dart';
import '../widgets/transactions_tab.dart';
import '../widgets/add_account_dialog.dart';
import '../widgets/add_crypto_dialog.dart';
import 'connect_bank_screen.dart';
import 'import_screen.dart';
import 'wealth_projection_screen.dart';
import '../components/date_range_selector.dart';
import '../components/allocation_heatmap.dart';
import '../components/trends_chart.dart';
import '../utils/currency.dart';
import 'package:patrimonio/screens/tax_planning_screen.dart';
import '../services/auth_service.dart';

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
  Map<String, dynamic>? _setupStatus;
  Map<String, dynamic>? _fxRate;
  List<dynamic>? _transactions;
  List<AllocationData>? _allocationData;
  List<Map<String, dynamic>>? _trendData;
  DateRange _selectedRange = DateRange.oneYear;
  String _targetCurrency = 'USD'; // Master currency state

  @override
  void initState() {
    super.initState();
    _targetCurrency = _loadSavedCurrency();
    _loadAllData();
    _checkRedirectStatus();
  }

  String _loadSavedCurrency() {
    try {
      final saved = web.window.localStorage.getItem(
        'patrimonio.reportingCurrency',
      );
      if (saved == 'USD' || saved == 'MXN') return saved!;
    } catch (_) {
      // Ignore storage failures; default currency still works.
    }
    return 'USD';
  }

  void _setTargetCurrency(String currency) {
    setState(() => _targetCurrency = currency);
    try {
      web.window.localStorage.setItem('patrimonio.reportingCurrency', currency);
    } catch (_) {
      // Ignore storage failures; the in-memory selection still updates.
    }
  }

  void _checkRedirectStatus() {
    final uri = Uri.parse(web.window.location.href);
    final status = uri.queryParameters['status'];
    if (status == 'success') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Account linked successfully!'),
            backgroundColor: Color(0xFF00E676),
          ),
        );
      });
    } else if (status == 'error') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to link account. Please try again.'),
            backgroundColor: Colors.redAccent,
          ),
        );
      });
    }
  }

  Future<void> _loadAllData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final results = await Future.wait([
        _apiService.getDashboardOverview(),
        _apiService.getNetWorthHistory(),
        _apiService.getHoldings(),
        _apiService.getCreditUtilization(),
        _apiService.getSyncStatus(),
        _apiService.getSetupStatus(),
        _apiService.getExchangeRate('USD', 'MXN'),
        _apiService.getTransactions(),
        _apiService.getAllocationData(),
        _apiService.getTrendData(),
      ]);

      debugPrint("All data loaded successfully");

      final allocationRaw = results[8] as List<dynamic>;
      final trendsRaw = results[9] as List<dynamic>;

      final categoryColors = {
        'Cash': const Color(0xFF00B0FF), // Azure Blue
        'Stocks/ETFs': const Color(0xFF1DE9B6), // Teal
        'Investment': const Color(0xFF00E676), // Emerald Green
        'Crypto': const Color(0xFF651FFF), // Deep Purple
        'Fixed Income': const Color(0xFFFFD600), // Yellow
        'Other': const Color(0xFFFF3D00), // Deep Orange
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

        _allocationData = allocationRaw.map((e) {
          final category = e['category'] as String;
          final subCategory = e['sub_category'] as String;
          final value = (e['value'] as num).toDouble();

          return AllocationData(
            category,
            subCategory,
            value,
            categoryColors[category] ?? Colors.blueGrey,
          );
        }).toList();

        _trendData = trendsRaw.map((e) => e as Map<String, dynamic>).toList();
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

    return DefaultTabController(
      length: 6,
      child: Scaffold(
        appBar: AppBar(
          title: const Text(
            'Patrimonio',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          bottom: TabBar(
            isScrollable: isCompact,
            tabAlignment: isCompact ? TabAlignment.start : TabAlignment.fill,
            indicatorColor: const Color(0xFF00E676),
            labelColor: Color(0xFF00E676),
            unselectedLabelColor: Colors.grey,
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Portfolio'),
              Tab(text: 'Transactions'),
              Tab(text: isCompact ? 'Proj.' : 'Projections'),
              Tab(text: isCompact ? 'Tax' : 'Tax Planning'),
              Tab(text: isCompact ? 'Manage' : 'Management'),
            ],
          ),
          actions: [
            TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              onPressed: () {
                _setTargetCurrency(_targetCurrency == 'USD' ? 'MXN' : 'USD');
              },
              icon: Icon(
                Icons.currency_exchange,
                color: _targetCurrency == 'MXN'
                    ? const Color(0xFF00E676)
                    : Colors.white70,
              ),
              label: Text(
                'Report: $_targetCurrency',
                style: TextStyle(
                  color: _targetCurrency == 'MXN'
                      ? const Color(0xFF00E676)
                      : Colors.white70,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(
              tooltip: 'Sign out',
              icon: const Icon(Icons.logout, color: Colors.white70),
              onPressed: () async {
                await AuthService.instance.logout();
              },
            ),
            const SizedBox(width: 4),
          ],
        ),
        body: _buildBody(),
      ),
    );
  }

  Widget _buildBody() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
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

    final fxRate = (_fxRate?['rate'] as num?)?.toDouble() ?? 1.0;
    final conversionFactor = _targetCurrency == 'MXN' ? fxRate : 1.0;
    final currencyFormat = NumberFormat.currency(
      name: _targetCurrency,
      symbol: '$_targetCurrency ',
    );
    final rateLabel = _fxRate == null
        ? 'FX loading'
        : '1 USD = ${NumberFormat.decimalPattern().format(fxRate)} MXN';

    Widget buildCurrencyContext() {
      final sourceBreakdown =
          (_overview?['currency_breakdown'] as List?)
              ?.map((item) => item as Map<String, dynamic>)
              .toList() ??
          [];

      return Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Wrap(
          spacing: 14,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'Reporting currency: $_targetCurrency',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w700,
                fontSize: 12,
              ),
            ),
            Text(
              rateLabel,
              style: const TextStyle(color: Colors.white60, fontSize: 12),
            ),
            if (sourceBreakdown.isNotEmpty)
              Text(
                'Sources: ${sourceBreakdown.map((item) {
                  final currency = (item['currency'] ?? 'USD').toString();
                  final net = ((item['net'] ?? 0.0) as num).toDouble();
                  return formatCurrencyAmount(net, currency);
                }).join(' · ')}',
                style: const TextStyle(color: Colors.white60, fontSize: 12),
              ),
          ],
        ),
      );
    }

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
          buildCurrencyContext(),
          AccountsListWidget(
            accounts: _overview?['accounts'] ?? [],
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
            targetCurrency: _targetCurrency,
            usdMxnRate: fxRate,
            onBalanceUpdate: (id, bal) async {
              try {
                await _apiService.updateAccountBalance(id, bal);
                _loadAllData();
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
                _loadAllData();
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
            'Net Worth History',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          );
          final selector = SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DateRangeSelector(
              selectedRange: _selectedRange,
              onRangeChanged: (range) {
                setState(() => _selectedRange = range);
                // In a real app, we'd refetch data for specific range here
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
      setState(() => _isLoading = true);
      try {
        await _apiService.syncInstitutions();
      } catch (e) {
        debugPrint("Sync error: $e");
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text('Sync failed: $e')));
        }
      }
      _loadAllData();
    }

    Future<void> _handleReconnect(String institutionId) async {
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
          _loadAllData();
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
                    color: blocking.isEmpty
                        ? const Color(0xFF00E676)
                        : Colors.orangeAccent,
                  ),
                  const SizedBox(width: 10),
                  const Text(
                    'Launch Setup',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                blocking.isEmpty
                    ? 'Plaid linking can start. Optional services may still improve data quality.'
                    : 'Complete required setup before real users can link Plaid accounts.',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 12),
              ...checks.map((raw) {
                final check = raw as Map<String, dynamic>;
                final configured = check['configured'] == true;
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
                            ? const Color(0xFF00E676)
                            : check['severity'] == 'optional'
                            ? Colors.white30
                            : Colors.orangeAccent,
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
                              style: const TextStyle(
                                color: Colors.white54,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              }),
              if (recommended.isNotEmpty) ...[
                const SizedBox(height: 12),
                const Text(
                  'Recommended before production: configure live exchange rates.',
                  style: TextStyle(color: Colors.white54, fontSize: 12),
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
          const SizedBox(height: 24),
          if (_trendData != null)
            CashFlowTrendsChart(
              trends: _trendData!,
              conversionFactor: conversionFactor,
              currencyFormat: currencyFormat,
            ),
        ],
      );
    }

    final overviewTab = buildTabContainer(
      LayoutBuilder(
        builder: (context, constraints) {
          final isNarrow = constraints.maxWidth < 900;
          if (isNarrow) {
            return Column(
              children: [
                buildAccountsColumn(),
                const SizedBox(height: 24),
                buildChartsColumn(true),
              ],
            );
          }

          return Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(flex: 1, child: buildAccountsColumn()),
              const SizedBox(width: 24),
              Expanded(flex: 3, child: buildChartsColumn(false)),
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
              ),
            ),
          PortfolioCard(
            portfolioData: _portfolioData ?? {},
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
            targetCurrency: _targetCurrency,
            usdMxnRate: fxRate,
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
        conversionFactor: conversionFactor,
        currencyFormat: currencyFormat,
        targetCurrency: _targetCurrency,
        usdMxnRate: fxRate,
        onUpdate: (id, {userCategory, userNotes}) async {
          try {
            await _apiService.updateTransaction(id,
                userCategory: userCategory, userNotes: userNotes);
            _loadAllData();
          } catch (e) {
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(content: Text('Failed to update transaction: $e')),
            );
          }
        },
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
            'Data Sources & Sync',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: SyncStatusCard(
                  syncData: _syncData ?? [],
                  onRetrySync: runSync,
                  onReconnect: _handleReconnect,
                  onDelete: (id) async {
                    final confirm = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('Delete Institution'),
                        content: const Text('Are you sure? This will remove ALL accounts and history for this institution.'),
                        actions: [
                          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
                          TextButton(
                            onPressed: () => Navigator.pop(context, true),
                            style: TextButton.styleFrom(foregroundColor: Colors.redAccent),
                            child: const Text('Delete Everything'),
                          ),
                        ],
                      ),
                    );

                    if (confirm == true) {
                      try {
                        await _apiService.deleteInstitution(id);
                        _loadAllData();
                      } catch (e) {
                        if (!mounted) return;
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Delete failed: $e')));
                      }
                    }
                  },
                ),
              ),
              const SizedBox(width: 24),
              Expanded(child: FxWidget(latestRate: _fxRate ?? {})),
            ],
          ),
          const SizedBox(height: 24),
          buildSetupStatusCard(),
          const SizedBox(height: 24),
          const Text(
            'Connect Standard Accounts',
            style: TextStyle(fontSize: 16, color: Colors.white70),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.sync),
                  label: const Text('Sync All Accounts'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    backgroundColor: Colors.blueAccent.withValues(alpha: 0.2),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: runSync,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.add_link),
                  label: const Text('Link Plaid (US Banks)'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    backgroundColor: const Color(
                      0xFF1DE9B6,
                    ).withValues(alpha: 0.2),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: plaidReady()
                      ? () {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (context) => ConnectBankScreen(),
                            ),
                          ).then((_) => _loadAllData());
                        }
                      : null,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Import Mexico (CSV/PDF)'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    backgroundColor: Colors.white12,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(
                        builder: (context) => const ImportScreen(),
                      ),
                    ).then((_) => _loadAllData());
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.add_circle_outline),
                  label: const Text('Add Manual Account'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    backgroundColor: Colors.white12,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) =>
                          AddAccountDialog(onAccountCreated: _loadAllData),
                    );
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
          const Text(
            'Connect Crypto Exchanges',
            style: TextStyle(fontSize: 16, color: Colors.white70),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.login, color: Colors.white),
                  label: const Text('Link Coinbase'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    backgroundColor: const Color(0xFF0052FF),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  onPressed: () {
                    // Start OAuth flow by redirecting to backend
                    final baseUrl = _apiService.baseUrl;
                    web.window.location.href = '$baseUrl/auth/coinbase';
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(
                    Icons.currency_exchange,
                    color: Color(0xFF00E676),
                  ),
                  label: const Text('Connect Bitso'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    backgroundColor: const Color(
                      0xFF00E676,
                    ).withValues(alpha: 0.1),
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
          ),
        ],
      ),
    );

    return TabBarView(
      children: [
        overviewTab,
        portfolioTab,
        transactionsTab,
        projectionsTab,
        taxPlanningTab,
        managementTab,
      ],
    );
  }
}
