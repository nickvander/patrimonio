import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';

class FxWidget extends StatelessWidget {
  final Map<String, dynamic> latestRate;

  const FxWidget({
    Key? key,
    required this.latestRate,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final rate = latestRate['rate'] ?? 0.0;
    
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Exchange Rate',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'USD / MXN',
                      style: TextStyle(color: Colors.grey.shade400, fontSize: 14),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      rate.toStringAsFixed(4),
                      style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold, color: Colors.tealAccent),
                    ),
                  ],
                ),
                const Icon(Icons.currency_exchange, size: 48, color: Colors.teal),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
