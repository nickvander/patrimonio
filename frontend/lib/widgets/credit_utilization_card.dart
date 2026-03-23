import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class CreditUtilizationCard extends StatelessWidget {
  final List<dynamic> creditData;

  const CreditUtilizationCard({
    Key? key,
    required this.creditData,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Credit Card Utilization',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            if (creditData.isEmpty)
              const Center(child: Text('No credit cards found.'))
            else
              ...creditData.map((card) => _buildCreditRow(card)).toList(),
          ],
        ),
      ),
    );
  }

  Widget _buildCreditRow(Map<String, dynamic> card) {
    final currencyFormat = NumberFormat.simpleCurrency(name: 'USD');
    final balance = (card['balance'] as num?)?.toDouble() ?? 0.0;
    final limit = (card['credit_limit'] as num?)?.toDouble() ?? 0.0;
    final pct = (card['utilization_pct'] as num?)?.toDouble() ?? 0.0;
    
    // Determine color based on utilization
    Color progressColor = Colors.green;
    if (pct > 70) {
      progressColor = Colors.red;
    } else if (pct > 30) {
      progressColor = Colors.orange;
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${card['institution_name']} - ${card['name']}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(
                '${pct.toStringAsFixed(1)}%',
                style: TextStyle(fontWeight: FontWeight.bold, color: progressColor),
              ),
            ],
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(
            value: limit > 0 ? (balance / limit).clamp(0.0, 1.0) : 0,
            backgroundColor: Colors.grey.withOpacity(0.2),
            valueColor: AlwaysStoppedAnimation<Color>(progressColor),
            minHeight: 8,
            borderRadius: BorderRadius.circular(4),
          ),
          const SizedBox(height: 4),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Balance: ${currencyFormat.format(balance)}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
              ),
              Text(
                'Limit: ${currencyFormat.format(limit)}',
                style: TextStyle(fontSize: 12, color: Colors.grey.shade400),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
