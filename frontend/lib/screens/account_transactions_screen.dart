import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../widgets/transactions_tab.dart'; // We can reuse the Transaction list widget

class AccountTransactionsScreen extends StatefulWidget {
  final Map<String, dynamic> account;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final Function(String, double)? onBalanceUpdate;

  const AccountTransactionsScreen({
    Key? key,
    required this.account,
    required this.conversionFactor,
    required this.currencyFormat,
    this.onBalanceUpdate,
  }) : super(key: key);

  @override
  _AccountTransactionsScreenState createState() => _AccountTransactionsScreenState();
}

class _AccountTransactionsScreenState extends State<AccountTransactionsScreen> {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  String? _error;
  List<dynamic>? _transactions;

  @override
  void initState() {
    super.initState();
    _fetchTransactions();
  }

  Future<void> _fetchTransactions() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final txs = await _apiService.getAccountTransactions(widget.account['id']);
      setState(() {
        _transactions = txs;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  void _showEditBalanceDialog() {
    final controller = TextEditingController(text: widget.account['current_balance'].toString());
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A24),
        title: Text('Update ${widget.account['name']} Balance'),
        content: TextField(
          controller: controller,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Current Balance (${widget.account['currency']})',
            prefixText: '\$ ',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () async {
              final newBalance = double.tryParse(controller.text);
              if (newBalance != null) {
                try {
                  Navigator.pop(context);
                  if (widget.onBalanceUpdate != null) {
                    widget.onBalanceUpdate!(widget.account['id'], newBalance);
                  }
                  // We update local state to reflect UI changes immediately
                  setState(() {
                    widget.account['current_balance'] = newBalance;
                  });
                } catch (e) {
                  debugPrint('Failed to update: $e');
                }
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('${widget.account['name']} Transactions'),
        actions: [
          IconButton(
            icon: const Icon(Icons.edit, color: Color(0xFF00E676)),
            tooltip: 'Update Balance',
            onPressed: _showEditBalanceDialog,
          )
        ],
      ),
      body: _buildBody(),
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
            Text('Error loading transactions: $_error', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _fetchTransactions,
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    if (_transactions == null || _transactions!.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long, size: 64, color: Colors.grey[800]),
            const SizedBox(height: 16),
            const Text(
              'No Historical Transactions Found',
              style: TextStyle(fontSize: 18, color: Colors.grey),
            ),
            const SizedBox(height: 8),
            Text(
              'Records might just be starting, or offline accounts have no history.',
              style: TextStyle(color: Colors.grey[600]),
            )
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.all(24.0),
      child: TransactionsTab(
        transactions: _transactions!,
        conversionFactor: widget.conversionFactor,
        currencyFormat: widget.currencyFormat,
      ),
    );
  }
}
