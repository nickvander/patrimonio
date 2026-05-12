import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class CreditUtilizationCard extends StatelessWidget {
  final List<dynamic> creditData;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const CreditUtilizationCard({
    super.key,
    required this.creditData,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  @override
  Widget build(BuildContext context) {
    if (creditData.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(24.0),
          child: Center(
            child: Text(
              'No credit accounts found.',
              style: TextStyle(color: Colors.grey),
            ),
          ),
        ),
      );
    }

    final totalBalance = creditData.fold<double>(
      0.0,
      (sum, item) => sum + ((item['balance'] ?? 0.0) as num).toDouble(),
    );
    final totalLimit = creditData.fold<double>(
      0.0,
      (sum, item) => sum + ((item['credit_limit'] ?? 0.0) as num).toDouble(),
    );
    final totalUtilization = totalLimit > 0
        ? (totalBalance / totalLimit) * 100
        : 0.0;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  'Credit Utilization',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                Text(
                  '${totalUtilization.toStringAsFixed(1)}%',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: totalUtilization > 30
                        ? Colors.orange
                        : const Color(0xFF00E676),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: LinearProgressIndicator(
                value: (totalUtilization / 100).clamp(0.0, 1.0),
                backgroundColor: Colors.white12,
                color: totalUtilization > 30
                    ? Colors.orange
                    : const Color(0xFF00E676),
                minHeight: 8,
              ),
            ),
            const SizedBox(height: 24),
            ...creditData.map((item) {
              final balance = ((item['balance'] ?? 0.0) as num).toDouble();
              final limit = ((item['credit_limit'] ?? 0.0) as num).toDouble();
              final util = limit > 0 ? (balance / limit) * 100 : 0.0;

              return Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Column(
                  children: [
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              item['name'] ?? 'Credit Account',
                              style: const TextStyle(
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            Text(
                              item['institution_name'] ?? '',
                              style: const TextStyle(
                                fontSize: 12,
                                color: Colors.grey,
                              ),
                            ),
                          ],
                        ),
                        Text(
                          '${currencyFormat.format(balance * conversionFactor)} / ${currencyFormat.format(limit * conversionFactor)}',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: (util / 100).clamp(0.0, 1.0),
                        backgroundColor: Colors.white10,
                        color: util > 30
                            ? Colors.orange.withValues(alpha: 0.7)
                            : const Color(0xFF00E676).withValues(alpha: 0.7),
                        minHeight: 4,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}
