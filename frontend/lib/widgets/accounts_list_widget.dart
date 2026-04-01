import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../screens/account_transactions_screen.dart';

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
                if (cashAccounts.isNotEmpty) _buildAccountGroup(context, 'Cash', cashAccounts, Icons.wallet, false, const Color(0xFF00B0FF)),
                if (investmentAccounts.isNotEmpty) _buildAccountGroup(context, 'Investments', investmentAccounts, Icons.show_chart, false, const Color(0xFF00E676)),
                if (creditAccounts.isNotEmpty) _buildAccountGroup(context, 'Credit Cards', creditAccounts, Icons.credit_card_rounded, true, const Color(0xFFFF5252)),
                if (loanAccounts.isNotEmpty) _buildAccountGroup(context, 'Loans & Mortgages', loanAccounts, Icons.home_rounded, true, const Color(0xFFFFD54F)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAccountGroup(BuildContext context, String title, List<dynamic> groupAccounts, IconData icon, bool isLiability, Color accentColor) {
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

    return Container(
      margin: const EdgeInsets.only(bottom: 24.0),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.02),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withOpacity(0.05)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: accentColor.withOpacity(0.1),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(icon, color: accentColor, size: 18),
                    ),
                    const SizedBox(width: 12),
                    Text(title, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white)),
                  ],
                ),
                Text(
                  currencyFormat.format(total * conversionFactor),
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w800, color: accentColor),
                ),
              ],
            ),
          ),
          const Divider(color: Colors.white12, height: 1),
          ...groupAccounts.map((acc) {
            final balance = ((acc['current_balance'] ?? 0.0) as num).toDouble().abs();
            final name = acc['name'] ?? 'Unknown Account';
            final inst = acc['institution_name'] ?? '';
            return InkWell(
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => AccountTransactionsScreen(
                      account: acc,
                      conversionFactor: conversionFactor,
                      currencyFormat: currencyFormat,
                      onBalanceUpdate: onBalanceUpdate,
                    ),
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white70), overflow: TextOverflow.ellipsis),
                          if (inst.isNotEmpty) Text(inst, style: const TextStyle(fontSize: 11, color: Colors.grey, letterSpacing: 0.2)),
                        ],
                      ),
                    ),
                    Row(
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(
                              currencyFormat.format(balance * conversionFactor),
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: Colors.white, fontFeatures: [FontFeature.tabularFigures()]),
                            ),
                            if (acc['currency'] != null)
                              Text(
                                'Orig: ${NumberFormat.simpleCurrency(name: acc['currency']).format(balance)} ${acc['currency']}',
                                style: const TextStyle(fontSize: 10, color: Colors.grey, fontFeatures: [FontFeature.tabularFigures()]),
                              ),
                          ],
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.chevron_right, size: 14, color: Colors.white24),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }).toList(),
        ],
      ),
    );
  }

}
