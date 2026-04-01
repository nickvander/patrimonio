import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class TransactionsTab extends StatelessWidget {
  final List<dynamic> transactions;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const TransactionsTab({
    Key? key,
    required this.transactions,
    required this.conversionFactor,
    required this.currencyFormat,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (transactions.isEmpty) {
      return const Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.receipt_long_outlined, size: 64, color: Colors.grey),
            SizedBox(height: 16),
            Text('No transactions found.', style: TextStyle(color: Colors.grey, fontSize: 18)),
            SizedBox(height: 8),
            Text('Link an institution or sync to see recent activity.', style: TextStyle(color: Colors.grey)),
          ],
        ),
      );
    }

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Recent Transactions',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
                Text(
                  'Showing latest ${transactions.length}',
                  style: const TextStyle(color: Colors.grey),
                ),
              ],
            ),
            const SizedBox(height: 24),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: transactions.length,
              separatorBuilder: (context, index) => const Divider(height: 32, color: Colors.white10),
              itemBuilder: (context, index) {
                final tx = transactions[index];
                final date = DateTime.parse(tx['date'] as String);
                final amount = ((tx['amount'] as num?)?.toDouble() ?? 0.0) * conversionFactor;
                final isExpense = amount > 0; // In standard accounting, POSITIVE amount is often an expense in bank feeds
                
                return Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: _getCategoryColor(tx['category']).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        _getCategoryIcon(tx['category']),
                        color: _getCategoryColor(tx['category']),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            tx['description'] ?? 'Unknown Transaction',
                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: [
                              Text(
                                tx['account_name'] ?? '',
                                style: const TextStyle(color: Colors.grey, fontSize: 12),
                              ),
                              const SizedBox(width: 8),
                              const Text('•', style: TextStyle(color: Colors.grey, fontSize: 12)),
                              const SizedBox(width: 8),
                              Text(
                                DateFormat('MMM d, y').format(date),
                                style: const TextStyle(color: Colors.grey, fontSize: 12),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          currencyFormat.format(amount.abs()),
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 18,
                            color: isExpense ? Colors.white : const Color(0xFF00E676),
                          ),
                        ),
                        if (tx['currency'] != null)
                          Text(
                            '${NumberFormat.simpleCurrency(name: tx['currency']).format((tx['amount'] as num).abs())} ${tx['currency']}',
                            style: const TextStyle(fontSize: 11, color: Colors.grey),
                          ),
                        if (tx['pending'] == true)
                          const Text(
                            'Pending',
                            style: TextStyle(color: Colors.orange, fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                      ],
                    ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  IconData _getCategoryIcon(String? category) {
    if (category == null) return Icons.receipt;
    final cat = category.toLowerCase();
    if (cat.contains('food') || cat.contains('dining')) return Icons.restaurant;
    if (cat.contains('travel')) return Icons.flight;
    if (cat.contains('shopping')) return Icons.shopping_bag;
    if (cat.contains('transfer')) return Icons.sync_alt;
    if (cat.contains('payment')) return Icons.payment;
    if (cat.contains('entertainment')) return Icons.movie;
    if (cat.contains('personal')) return Icons.person;
    return Icons.receipt;
  }

  Color _getCategoryColor(String? category) {
    if (category == null) return Colors.grey;
    final cat = category.toLowerCase();
    if (cat.contains('food') || cat.contains('dining')) return Colors.orange;
    if (cat.contains('travel')) return Colors.blue;
    if (cat.contains('shopping')) return Colors.purple;
    if (cat.contains('transfer')) return Colors.teal;
    if (cat.contains('payment')) return Colors.green;
    if (cat.contains('entertainment')) return Colors.pink;
    return Colors.grey;
  }
}
