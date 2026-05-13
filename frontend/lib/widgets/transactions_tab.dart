import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../utils/currency.dart';

class TransactionsTab extends StatefulWidget {
  final List<dynamic> transactions;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final String targetCurrency;
  final double usdMxnRate;
  final Function(String id, {String? userCategory, String? userNotes})? onUpdate;

  const TransactionsTab({
    super.key,
    required this.transactions,
    required this.conversionFactor,
    required this.currencyFormat,
    required this.targetCurrency,
    required this.usdMxnRate,
    this.onUpdate,
  });

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
            Text(
              'No transactions found.',
              style: TextStyle(color: Colors.grey, fontSize: 18),
            ),
            SizedBox(height: 8),
            Text(
              'Link an institution or sync to see recent activity.',
              style: TextStyle(color: Colors.grey),
            ),
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
                      hintStyle: const TextStyle(
                        color: Colors.white30,
                        fontSize: 13,
                      ),
                      prefixIcon: const Icon(
                        Icons.search,
                        size: 18,
                        color: Colors.white30,
                      ),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      contentPadding: const EdgeInsets.symmetric(
                        vertical: 0,
                        horizontal: 12,
                      ),
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
              separatorBuilder: (context, index) =>
                  const Divider(height: 32, color: Colors.white10),
              itemBuilder: (context, index) {
                final tx = filtered[index];
                final date = DateTime.parse(tx['date'] as String);
                final sourceAmount =
                    ((tx['amount'] as num?)?.toDouble() ?? 0.0);
                final sourceCurrency = (tx['currency'] ?? widget.targetCurrency)
                    .toString();
                final amount = convertCurrency(
                  sourceAmount,
                  from: sourceCurrency,
                  to: widget.targetCurrency,
                  usdMxnRate: widget.usdMxnRate,
                );
                final isExpense = amount > 0;
                final category = tx['user_category'] ?? tx['category'];
                final notes = (tx['user_notes'] ?? '').toString();

                return InkWell(
                  onTap: () => _showTransactionDetails(tx),
                  borderRadius: BorderRadius.circular(12),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: _getCategoryColor(
                              category,
                              tx['description'],
                            ).withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            _getCategoryIcon(category, tx['description']),
                            color: _getCategoryColor(
                              category,
                              tx['description'],
                            ),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                _titleCase(
                                  tx['description'] ?? 'Unknown Transaction',
                                ),
                                style: const TextStyle(
                                  fontWeight: FontWeight.bold,
                                  fontSize: 16,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Text(
                                    tx['account_name'] ?? '',
                                    style: const TextStyle(
                                      color: Colors.grey,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  const Text(
                                    '•',
                                    style: TextStyle(
                                      color: Colors.grey,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Text(
                                    DateFormat('MMM d, y').format(date),
                                    style: const TextStyle(
                                      color: Colors.grey,
                                      fontSize: 12,
                                    ),
                                  ),
                                  if (notes.isNotEmpty) ...[
                                    const SizedBox(width: 8),
                                    const Text('•',
                                        style: TextStyle(
                                            color: Colors.grey, fontSize: 12)),
                                    const SizedBox(width: 8),
                                    Flexible(
                                      child: Text(
                                        notes,
                                        style: const TextStyle(
                                            color: Colors.white60,
                                            fontSize: 12,
                                            fontStyle: FontStyle.italic),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                  ],
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
                                color: isExpense
                                    ? Colors.white
                                    : const Color(0xFF00E676),
                              ),
                            ),
                            if (sourceCurrency != widget.targetCurrency)
                              Text(
                                'orig. ${formatCurrencyAmount(sourceAmount.abs(), sourceCurrency)}',
                                style: const TextStyle(
                                  fontSize: 11,
                                  color: Colors.white38,
                                ),
                              ),
                            if (tx['pending'] == true)
                              const Text(
                                'Pending',
                                style: TextStyle(
                                  color: Colors.orange,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showTransactionDetails(dynamic tx) {
    final catController = TextEditingController(
      text: (tx['user_category'] ?? tx['category'] ?? '').toString(),
    );
    final notesController = TextEditingController(
      text: (tx['user_notes'] ?? '').toString(),
    );

    final date = DateTime.parse(tx['date'] as String);
    final sourceAmount = ((tx['amount'] as num?)?.toDouble() ?? 0.0);
    final sourceCurrency =
        (tx['currency'] ?? widget.targetCurrency).toString();
    final convertedAmount = convertCurrency(
      sourceAmount,
      from: sourceCurrency,
      to: widget.targetCurrency,
      usdMxnRate: widget.usdMxnRate,
    );
    final isExpense = convertedAmount > 0;
    final source = (tx['source'] ?? 'plaid').toString();
    final originalCategory = (tx['category'] ?? '').toString();
    final merchant = (tx['merchant_name'] ?? '').toString();
    final pending = tx['pending'] == true;

    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: const Color(0xFF1A1A24),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: BoxDecoration(
                          color: _getCategoryColor(
                            tx['user_category'] ?? tx['category'],
                            tx['description'],
                          ).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Icon(
                          _getCategoryIcon(
                            tx['user_category'] ?? tx['category'],
                            tx['description'],
                          ),
                          color: _getCategoryColor(
                            tx['user_category'] ?? tx['category'],
                            tx['description'],
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _titleCase(
                            tx['description'] ?? 'Unknown Transaction',
                          ),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () => Navigator.pop(context),
                        tooltip: 'Close',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.currencyFormat.format(convertedAmount.abs()),
                          style: TextStyle(
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            color: isExpense
                                ? Colors.white
                                : const Color(0xFF00E676),
                          ),
                        ),
                        if (sourceCurrency != widget.targetCurrency) ...[
                          const SizedBox(height: 4),
                          Text(
                            'Original: ${formatCurrencyAmount(sourceAmount.abs(), sourceCurrency)}',
                            style: const TextStyle(
                              fontSize: 12,
                              color: Colors.white54,
                            ),
                          ),
                        ],
                        const SizedBox(height: 4),
                        Text(
                          isExpense ? 'Outflow' : 'Inflow',
                          style: TextStyle(
                            fontSize: 11,
                            color: isExpense
                                ? Colors.redAccent.shade100
                                : const Color(0xFF1DE9B6),
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  _detailRow('Date', DateFormat('MMMM d, y').format(date)),
                  _detailRow('Account', (tx['account_name'] ?? '').toString()),
                  if (merchant.isNotEmpty) _detailRow('Merchant', merchant),
                  if (originalCategory.isNotEmpty)
                    _detailRow('Original category', originalCategory),
                  _detailRow('Source', source),
                  if (pending)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.orange.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'Pending',
                          style: TextStyle(
                            color: Colors.orange,
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  const SizedBox(height: 16),
                  const Text(
                    'Your overrides',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.white60,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: catController,
                    decoration: const InputDecoration(
                      labelText: 'Category',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: notesController,
                    decoration: const InputDecoration(
                      labelText: 'Notes',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    maxLines: 3,
                  ),
                  const SizedBox(height: 20),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(context),
                        child: const Text('Close'),
                      ),
                      const SizedBox(width: 8),
                      ElevatedButton(
                        onPressed: () {
                          Navigator.pop(context);
                          widget.onUpdate?.call(
                            tx['id'],
                            userCategory: catController.text.trim(),
                            userNotes: notesController.text.trim(),
                          );
                        },
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style:
                  const TextStyle(color: Colors.white54, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              value.isEmpty ? '—' : value,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  NumberFormat get currencyFormat => widget.currencyFormat;

  /// Title-case raw bank descriptions for cleaner display
  String _titleCase(String text) {
    // If already mostly lowercase or mixed, use as-is
    if (text != text.toUpperCase()) return text;
    // Convert ALL CAPS → Title Case
    return text
        .split(' ')
        .map((word) {
          if (word.isEmpty) return word;
          if (word.length <= 2) {
            return word; // Keep short tokens like "CD", "ACH"
          }
          return '${word[0]}${word.substring(1).toLowerCase()}';
        })
        .join(' ');
  }

  IconData _getCategoryIcon(String? category, String? description) {
    final cat = (category ?? '').toLowerCase();
    final desc = (description ?? '').toLowerCase();
    // Plaid-style categories
    if (cat.contains('food') ||
        cat.contains('dining') ||
        desc.contains('starbucks') ||
        desc.contains('mcdonald')) {
      return Icons.restaurant;
    }
    if (cat.contains('travel') ||
        desc.contains('airline') ||
        desc.contains('united')) {
      return Icons.flight;
    }
    if (cat.contains('shopping') || desc.contains('amazon')) {
      return Icons.shopping_bag;
    }
    if (cat.contains('transfer') ||
        desc.contains('ach') ||
        desc.contains('wire')) {
      return Icons.sync_alt;
    }
    if (cat.contains('payment') ||
        desc.contains('payment') ||
        desc.contains('credit card')) {
      return Icons.payment;
    }
    if (cat.contains('entertainment') ||
        desc.contains('netflix') ||
        desc.contains('spotify')) {
      return Icons.movie;
    }
    if (cat.contains('recreation') ||
        desc.contains('climbing') ||
        desc.contains('gym')) {
      return Icons.fitness_center;
    }
    if (cat.contains('deposit') || desc.contains('deposit')) {
      return Icons.account_balance;
    }
    if (cat.contains('uber') ||
        desc.contains('uber') ||
        desc.contains('lyft')) {
      return Icons.directions_car;
    }
    if (cat.contains('personal') || cat.contains('service')) {
      return Icons.person;
    }
    return Icons.receipt;
  }

  Color _getCategoryColor(String? category, String? description) {
    final cat = (category ?? '').toLowerCase();
    final desc = (description ?? '').toLowerCase();
    if (cat.contains('food') ||
        cat.contains('dining') ||
        desc.contains('starbucks') ||
        desc.contains('mcdonald')) {
      return Colors.orange;
    }
    if (cat.contains('travel') ||
        desc.contains('airline') ||
        desc.contains('united')) {
      return Colors.blue;
    }
    if (cat.contains('shopping') || desc.contains('amazon')) {
      return Colors.purple;
    }
    if (cat.contains('transfer') ||
        desc.contains('ach') ||
        desc.contains('wire')) {
      return Colors.teal;
    }
    if (cat.contains('payment') ||
        desc.contains('payment') ||
        desc.contains('credit card')) {
      return Colors.green;
    }
    if (cat.contains('entertainment') ||
        desc.contains('netflix') ||
        desc.contains('spotify')) {
      return Colors.pink;
    }
    if (cat.contains('recreation') ||
        desc.contains('climbing') ||
        desc.contains('gym')) {
      return const Color(0xFF1DE9B6);
    }
    if (cat.contains('deposit') || desc.contains('deposit')) {
      return Colors.blueAccent;
    }
    if (cat.contains('uber') ||
        desc.contains('uber') ||
        desc.contains('lyft')) {
      return Colors.indigo;
    }
    return Colors.grey;
  }
}
