import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
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

class DashboardScreen extends StatefulWidget {
  const DashboardScreen({Key? key}) : super(key: key);

  @override
  _DashboardScreenState createState() => _DashboardScreenState();
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
  Map<String, dynamic>? _fxRate;
  List<dynamic>? _transactions;
  List<AllocationData>? _allocationData;
  List<Map<String, dynamic>>? _trendData;
  DateRange _selectedRange = DateRange.oneYear;
  String _targetCurrency = 'USD'; // Master currency state

  @override
  void initState() {
    super.initState();
    _loadAllData();
    _checkRedirectStatus();
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
        _apiService.getExchangeRate('USD', 'MXN'),
        _apiService.getTransactions(),
        _apiService.getAllocationData(),
        _apiService.getTrendData(),
      ]);

      debugPrint("All data loaded successfully");

      final allocationRaw = results[7] as List<dynamic>;
      final trendsRaw = results[8] as List<dynamic>;

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
        _fxRate = results[5] as Map<String, dynamic>;
        _transactions = results[6] as List<dynamic>;
        
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
      
      debugPrint("State updated with Phase 7 data: ${_allocationData?.length} categories, ${_trendData?.length} trend months");
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
    return DefaultTabController(
      length: 5,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Patrimonio', style: TextStyle(fontWeight: FontWeight.bold)),
          bottom: const TabBar(
            isScrollable: false, // Changed from true to ensure all tabs are visible
            indicatorColor: Color(0xFF00E676),
            labelColor: Color(0xFF00E676),
            unselectedLabelColor: Colors.grey,
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Portfolio'),
              Tab(text: 'Transactions'),
              Tab(text: 'Projections'),
              Tab(text: 'Management'),
            ],
          ),
          actions: [
            TextButton.icon(
              onPressed: () {
                setState(() {
                  _targetCurrency = _targetCurrency == 'USD' ? 'MXN' : 'USD';
                });
              },
              icon: Icon(Icons.currency_exchange, color: _targetCurrency == 'MXN' ? const Color(0xFF00E676) : Colors.white70),
              label: Text(
                '$_targetCurrency (${_fxRate != null ? (_fxRate!['rate'] as num).toStringAsFixed(2) : "..."})',
                style: TextStyle(color: _targetCurrency == 'MXN' ? const Color(0xFF00E676) : Colors.white70, fontWeight: FontWeight.bold)
              ),
            ),
            const SizedBox(width: 8),
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
            Text('Error loading dashboard: $_error', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _loadAllData,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final fxRate = (_fxRate?['rate'] as num?)?.toDouble() ?? 1.0;
    final conversionFactor = _targetCurrency == 'MXN' ? fxRate : 1.0;
    final currencyFormat = NumberFormat.simpleCurrency(name: _targetCurrency);

    Widget buildTabContainer(Widget child, {bool scrollable = true}) {
      final content = Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1600),
          child: child,
        ),
      );

      return scrollable 
        ? SingleChildScrollView(padding: const EdgeInsets.all(24.0), child: content)
        : Padding(padding: const EdgeInsets.all(24.0), child: content);
    }

    final overviewTab = buildTabContainer(
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 1,
            child: Column(
              children: [
                AccountsListWidget(
                  accounts: _overview?['accounts'] ?? [],
                  conversionFactor: conversionFactor,
                  currencyFormat: currencyFormat,
                  onBalanceUpdate: (id, bal) async {
                    try {
                      await _apiService.updateAccountBalance(id, bal);
                      _loadAllData();
                    } catch (e) {
                       ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(content: Text('Update failed: $e')),
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
            ),
          ),
          const SizedBox(width: 24),
          Expanded(
            flex: 3,
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Net Worth History',
                      style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                    ),
                    DateRangeSelector(
                      selectedRange: _selectedRange,
                      onRangeChanged: (range) {
                        setState(() => _selectedRange = range);
                        // In a real app, we'd refetch data for specific range here
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                SizedBox(
                  height: 440,
                  child: NetWorthCard(
                    netWorth: ((_overview?['net_worth'] as num?)?.toDouble() ?? 0.0) * conversionFactor,
                    history: _netWorthHistory ?? [],
                    conversionFactor: conversionFactor,
                    currencyFormat: currencyFormat,
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
            ),
          ),
        ],
      )
    );

    final portfolioTab = buildTabContainer(
      Column(
        children: [
          if (_allocationData != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 24.0),
              child: AllocationHeatmap(data: _allocationData!),
            ),
          PortfolioCard(
            portfolioData: _portfolioData ?? {},
            conversionFactor: conversionFactor,
            currencyFormat: currencyFormat,
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

    final managementTab = buildTabContainer(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Data Sources & Sync', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const SizedBox(height: 16),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: SyncStatusCard(syncData: _syncData ?? [])),
              const SizedBox(width: 24),
              Expanded(child: FxWidget(latestRate: _fxRate ?? {})),
            ],
          ),
          const SizedBox(height: 24),
          const Text('Connect Standard Accounts', style: TextStyle(fontSize: 16, color: Colors.white70)),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.sync),
                  label: const Text('Sync All Accounts'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    backgroundColor: Colors.blueAccent.withOpacity(0.2),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: () async {
                    setState(() => _isLoading = true);
                    try {
                      await _apiService.syncInstitutions();
                    } catch (e) {
                      debugPrint("Sync error: $e");
                    }
                    _loadAllData();
                  },
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.add_link),
                  label: const Text('Link Plaid (US Banks)'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    backgroundColor: const Color(0xFF1DE9B6).withOpacity(0.2),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => ConnectBankScreen()),
                    ).then((_) => _loadAllData());
                  },
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
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: () {
                    Navigator.push(
                      context,
                      MaterialPageRoute(builder: (context) => const ImportScreen()),
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
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
                  ),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => AddAccountDialog(onAccountCreated: _loadAllData),
                    );
                  },
                ),
              ),
            ],
          ),
          const SizedBox(height: 32),
          const Text('Connect Crypto Exchanges', style: TextStyle(fontSize: 16, color: Colors.white70)),
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
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
                  icon: const Icon(Icons.currency_exchange, color: Color(0xFF00E676)),
                  label: const Text('Connect Bitso'),
                  style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 20),
                    backgroundColor: const Color(0xFF00E676).withOpacity(0.1),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
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
      )
    );

    return TabBarView(
      children: [
        overviewTab,
        portfolioTab,
        transactionsTab,
        projectionsTab,
        managementTab,
      ],
    );
  }
}
