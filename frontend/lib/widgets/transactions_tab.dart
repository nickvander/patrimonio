import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class TransactionsTab extends StatefulWidget {
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
  State<TransactionsTab> createState() => _TransactionsTabState();
}

class _TransactionsTabState extends State<TransactionsTab> {
  String _searchQuery = '';

  List<dynamic> get _filteredTransactions {
    if (_searchQuery.isEmpty) return widget.transactions;
    final q = _searchQuery.toLowerCase();
    return widget.transactions.where((tx) {
      final desc = (tx['description'] ?? '').toString().toLowerCase();
      final acct = (tx['account_name'] ?? '').toString().toLowerCase();
      final cat = (tx['category'] ?? '').toString().toLowerCase();
      return desc.contains(q) || acct.contains(q) || cat.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.transactions.isEmpty) {
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

    final filtered = _filteredTransactions;

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
                SizedBox(
                  width: 280,
                  height: 40,
                  child: TextField(
                    onChanged: (v) => setState(() => _searchQuery = v),
                    decoration: InputDecoration(
                      hintText: 'Search transactions…',
                      hintStyle: const TextStyle(color: Colors.white30, fontSize: 13),
                      prefixIcon: const Icon(Icons.search, size: 18, color: Colors.white30),
                      filled: true,
                      fillColor: Colors.white.withOpacity(0.05),
                      contentPadding: const EdgeInsets.symmetric(vertical: 0, horizontal: 12),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                    style: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              'Showing ${filtered.length} of ${widget.transactions.length}',
              style: const TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 16),
            ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: filtered.length,
              separatorBuilder: (context, index) => const Divider(height: 32, color: Colors.white10),
              itemBuilder: (context, index) {
                final tx = filtered[index];
                final date = DateTime.parse(tx['date'] as String);
                final amount = ((tx['amount'] as num?)?.toDouble() ?? 0.0) * widget.conversionFactor;
                final isExpense = amount > 0;
                
                return Row(
                  children: [
                    Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: _getCategoryColor(tx['category'], tx['description']).withOpacity(0.1),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        _getCategoryIcon(tx['category'], tx['description']),
                        color: _getCategoryColor(tx['category'], tx['description']),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _titleCase(tx['description'] ?? 'Unknown Transaction'),
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

  NumberFormat get currencyFormat => widget.currencyFormat;

  /// Title-case raw bank descriptions for cleaner display
  String _titleCase(String text) {
    // If already mostly lowercase or mixed, use as-is
    if (text != text.toUpperCase()) return text;
    // Convert ALL CAPS → Title Case
    return text.split(' ').map((word) {
      if (word.isEmpty) return word;
      if (word.length <= 2) return word; // Keep short tokens like "CD", "ACH"
      return '${word[0]}${word.substring(1).toLowerCase()}';
    }).join(' ');
  }

  IconData _getCategoryIcon(String? category, String? description) {
    final cat = (category ?? '').toLowerCase();
    final desc = (description ?? '').toLowerCase();
    // Plaid-style categories
    if (cat.contains('food') || cat.contains('dining') || desc.contains('starbucks') || desc.contains('mcdonald')) return Icons.restaurant;
    if (cat.contains('travel') || desc.contains('airline') || desc.contains('united')) return Icons.flight;
    if (cat.contains('shopping') || desc.contains('amazon')) return Icons.shopping_bag;
    if (cat.contains('transfer') || desc.contains('ach') || desc.contains('wire')) return Icons.sync_alt;
    if (cat.contains('payment') || desc.contains('payment') || desc.contains('credit card')) return Icons.payment;
    if (cat.contains('entertainment') || desc.contains('netflix') || desc.contains('spotify')) return Icons.movie;
    if (cat.contains('recreation') || desc.contains('climbing') || desc.contains('gym')) return Icons.fitness_center;
    if (cat.contains('deposit') || desc.contains('deposit')) return Icons.account_balance;
    if (cat.contains('uber') || desc.contains('uber') || desc.contains('lyft')) return Icons.directions_car;
    if (cat.contains('personal') || cat.contains('service')) return Icons.person;
    return Icons.receipt;
  }

  Color _getCategoryColor(String? category, String? description) {
    final cat = (category ?? '').toLowerCase();
    final desc = (description ?? '').toLowerCase();
    if (cat.contains('food') || cat.contains('dining') || desc.contains('starbucks') || desc.contains('mcdonald')) return Colors.orange;
    if (cat.contains('travel') || desc.contains('airline') || desc.contains('united')) return Colors.blue;
    if (cat.contains('shopping') || desc.contains('amazon')) return Colors.purple;
    if (cat.contains('transfer') || desc.contains('ach') || desc.contains('wire')) return Colors.teal;
    if (cat.contains('payment') || desc.contains('payment') || desc.contains('credit card')) return Colors.green;
    if (cat.contains('entertainment') || desc.contains('netflix') || desc.contains('spotify')) return Colors.pink;
    if (cat.contains('recreation') || desc.contains('climbing') || desc.contains('gym')) return const Color(0xFF1DE9B6);
    if (cat.contains('deposit') || desc.contains('deposit')) return Colors.blueAccent;
    if (cat.contains('uber') || desc.contains('uber') || desc.contains('lyft')) return Colors.indigo;
    return Colors.grey;
  }
}

