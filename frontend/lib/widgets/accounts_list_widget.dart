import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class AccountsListWidget extends StatelessWidget {
  final List<dynamic> accounts;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final Function(String, double)? onBalanceUpdate;

  const AccountsListWidget({
    Key? key,
    required this.accounts,
    required this.conversionFactor,
    required this.currencyFormat,
    this.onBalanceUpdate,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (accounts.isEmpty) {
      return const Card(
        color: Color(0xFF1A1A24),
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Center(
            child: Text(
              'No accounts linked yet. Use the Link button to add an institution.',
              style: TextStyle(color: Colors.grey),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    // Group accounts by main category
    final cashAccounts = <dynamic>[];
    final creditAccounts = <dynamic>[];
    final investmentAccounts = <dynamic>[];
    final loanAccounts = <dynamic>[];

    for (var acc in accounts) {
      final type = (acc['account_type'] ?? '').toString().toLowerCase();
      if (['checking', 'savings', 'cd', 'money market', 'cash management'].contains(type)) {
        cashAccounts.add(acc);
      } else if (['credit card', 'credit'].contains(type)) {
        creditAccounts.add(acc);
      } else if (['ira', '401k', 'hsa', 'brokerage', 'investment'].contains(type)) {
        investmentAccounts.add(acc);
      } else if (['student', 'mortgage', 'loan'].contains(type)) {
        loanAccounts.add(acc);
      } else {
        cashAccounts.add(acc); // fallback
      }
    }

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Accounts',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            ListView(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              children: [
                if (cashAccounts.isNotEmpty) _buildAccountGroup(context, 'Cash & Banking', cashAccounts, Icons.account_balance_wallet, false),
                if (investmentAccounts.isNotEmpty) _buildAccountGroup(context, 'Investments', investmentAccounts, Icons.trending_up, false),
                if (creditAccounts.isNotEmpty) _buildAccountGroup(context, 'Credit Cards', creditAccounts, Icons.credit_card, true),
                if (loanAccounts.isNotEmpty) _buildAccountGroup(context, 'Loans', loanAccounts, Icons.home_work, true),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountGroup(BuildContext context, String title, List<dynamic> groupAccounts, IconData icon, bool isLiability) {
    // Sort within group by balance descending
    groupAccounts.sort((a, b) {
      final balA = ((a['current_balance'] ?? 0.0) as num).toDouble().abs();
      final balB = ((b['current_balance'] ?? 0.0) as num).toDouble().abs();
      return balB.compareTo(balA);
    });

    final total = groupAccounts.fold<double>(0.0, (sum, acc) {
      final bal = ((acc['current_balance'] ?? 0.0) as num).toDouble().abs();
      return sum + bal;
    });

    return Padding(
      padding: const EdgeInsets.only(bottom: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(icon, color: const Color(0xFF00E676), size: 20),
                  const SizedBox(width: 8),
                  Text(title, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white70)),
                ],
              ),
              Text(
                currencyFormat.format(total * conversionFactor),
                style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const Divider(color: Colors.white24, height: 24),
          ...groupAccounts.map((acc) {
            final balance = ((acc['current_balance'] ?? 0.0) as num).toDouble().abs();
            final name = acc['name'] ?? 'Unknown Account';
            final inst = acc['institution_name'] ?? '';
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(name, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500), overflow: TextOverflow.ellipsis),
                        if (inst.isNotEmpty) Text(inst, style: const TextStyle(fontSize: 12, color: Colors.grey)),
                      ],
                    ),
                  ),
                  Text(
                    currencyFormat.format(balance * conversionFactor),
                    style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
                  ),
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.edit_outlined, size: 16, color: Colors.grey),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                    onPressed: () => _showEditBalanceDialog(context, acc),
                    tooltip: 'Update Balance',
                  ),
                ],
              ),
            );
          }).toList(),
        ],
      ),
    );
  }

  void _showEditBalanceDialog(BuildContext context, Map<String, dynamic> account) {
    final controller = TextEditingController(text: account['current_balance'].toString());
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1A1A24),
        title: Text('Update ${account['name']} Balance'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.numberWithOptions(decimal: true),
          autofocus: true,
          decoration: InputDecoration(
            labelText: 'Current Balance (${account['currency']})',
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
                  // In a real app we'd use a Provider or Bloc, here we call ApiService directly
                  // For simplicity, I'll suggest the parent handles the API call via onBalanceUpdate
                  Navigator.pop(context);
                  if (onBalanceUpdate != null) {
                    onBalanceUpdate!(account['id'], newBalance);
                  }
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
}
