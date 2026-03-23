import 'package:flutter/material.dart';
import '../services/api_service.dart';
import '../widgets/net_worth_card.dart';
import '../widgets/accounts_breakdown_card.dart';
import '../widgets/portfolio_card.dart';
import '../widgets/fx_widget.dart';
import '../widgets/credit_utilization_card.dart';
import '../widgets/sync_status_card.dart';
import '../widgets/accounts_list_widget.dart';
import 'connect_bank_screen.dart';

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

  @override
  void initState() {
    super.initState();
    _loadAllData();
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
      ]);

      setState(() {
        _overview = results[0] as Map<String, dynamic>;
        _netWorthHistory = results[1] as List<dynamic>;
        _portfolioData = results[2] as Map<String, dynamic>;
        _creditData = results[3] as List<dynamic>;
        _syncData = results[4] as List<dynamic>;
        _fxRate = results[5] as Map<String, dynamic>;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Patrimonio', style: TextStyle(fontWeight: FontWeight.bold)),
          bottom: const TabBar(
            indicatorColor: Color(0xFF00E676),
            labelColor: Color(0xFF00E676),
            unselectedLabelColor: Colors.grey,
            tabs: [
              Tab(text: 'Overview'),
              Tab(text: 'Portfolio'),
              Tab(text: 'Management'),
            ],
          ),
          actions: [
            IconButton(
              icon: const Icon(Icons.add_link),
              tooltip: 'Link New Institution',
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => ConnectBankScreen()),
                ).then((_) => _loadAllData());
              },
            ),
            IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () async {
                setState(() => _isLoading = true);
                try {
                  await _apiService.syncInstitutions();
                } catch (e) {
                  print("Sync error: $e");
                }
                _loadAllData();
              },
            ),
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

    Widget buildTabContainer(Widget child) {
      return SingleChildScrollView(
        padding: const EdgeInsets.all(24.0),
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1600),
            child: child,
          ),
        ),
      );
    }

    final overviewTab = buildTabContainer(
      Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 1,
            child: AccountsListWidget(accounts: _overview?['accounts'] ?? []),
          ),
          const SizedBox(width: 24),
          Expanded(
            flex: 3,
            child: SizedBox(
              height: 500,
              child: NetWorthCard(
                netWorth: (_overview?['net_worth'] as num?)?.toDouble() ?? 0.0,
                history: _netWorthHistory ?? [],
              ),
            ),
          ),
        ],
      )
    );

    final portfolioTab = buildTabContainer(
      PortfolioCard(portfolioData: _portfolioData ?? {}),
    );

    final managementTab = buildTabContainer(
      Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: SyncStatusCard(syncData: _syncData ?? [])),
              const SizedBox(width: 24),
              Expanded(child: FxWidget(latestRate: _fxRate ?? {})),
            ],
          ),
          const SizedBox(height: 24),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(child: CreditUtilizationCard(creditData: _creditData ?? [])),
              const SizedBox(width: 24),
              Expanded(
                child: AccountsBreakdownCard(
                  typeBreakdown: _overview?['type_breakdown'] ?? [],
                  institutionBreakdown: _overview?['institution_breakdown'] ?? [],
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
        managementTab,
      ],
    );
  }
}
