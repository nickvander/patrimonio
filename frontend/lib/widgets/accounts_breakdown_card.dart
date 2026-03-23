import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

class AccountsBreakdownCard extends StatelessWidget {
  final List<dynamic> typeBreakdown;
  final List<dynamic> institutionBreakdown;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const AccountsBreakdownCard({
    Key? key,
    required this.typeBreakdown,
    required this.institutionBreakdown,
    required this.conversionFactor,
    required this.currencyFormat,
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
            const Text('Asset Breakdown', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
            const SizedBox(height: 24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(child: _buildTypeSection()),
                const VerticalDivider(width: 32, color: Colors.white12),
                Expanded(child: _buildInstitutionSection()),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('By Type', style: TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        ...typeBreakdown.map((item) {
          final total = ((item['total'] ?? 0.0) as num).toDouble();
          return Padding(
            padding: const EdgeInsets.only(bottom: 12.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(item['account_type'] ?? 'Other', style: const TextStyle(fontSize: 14)),
                Text(
                  currencyFormat.format(total * conversionFactor),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          );
        }).toList(),
      ],
    );
  }

  Widget _buildInstitutionSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('By Institution', style: TextStyle(fontSize: 14, color: Colors.grey, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        ...institutionBreakdown.map((item) {
          final total = ((item['total'] ?? 0.0) as num).toDouble();
          return Padding(
            padding: const EdgeInsets.only(bottom: 12.0),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(item['name'] ?? 'Bank', style: const TextStyle(fontSize: 14)),
                Text(
                  currencyFormat.format(total * conversionFactor),
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          );
        }).toList(),
      ],
    );
  }
}
