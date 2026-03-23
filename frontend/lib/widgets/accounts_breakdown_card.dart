import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

class AccountsBreakdownCard extends StatelessWidget {
  final List<dynamic> typeBreakdown;
  final List<dynamic> institutionBreakdown;

  const AccountsBreakdownCard({
    Key? key,
    required this.typeBreakdown,
    required this.institutionBreakdown,
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
              'Account Breakdown',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    children: [
                      const Text('By Type', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 200,
                        child: _buildPieChart(typeBreakdown, 'account_type'),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    children: [
                      const Text('By Institution', style: TextStyle(fontWeight: FontWeight.w600)),
                      const SizedBox(height: 16),
                      SizedBox(
                        height: 200,
                        child: _buildPieChart(institutionBreakdown, 'name'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPieChart(List<dynamic> data, String labelKey) {
    if (data.isEmpty) return const Center(child: Text('No data'));

    final currencyFormat = NumberFormat.compactCurrency(name: 'USD', symbol: '\$');
    final colors = [
      const Color(0xFF00E676),
      const Color(0xFF00B0FF),
      const Color(0xFFFFD54F),
      const Color(0xFFFF5252),
      const Color(0xFFB388FF),
      const Color(0xFF64FFDA),
    ];

    List<PieChartSectionData> sections = [];
    for (int i = 0; i < data.length; i++) {
      final item = data[i];
      final value = ((item['total'] as num?)?.toDouble() ?? 0.0).abs(); // Use abs to show liabilities as positive slices
      if (value > 0) {
        sections.add(
          PieChartSectionData(
            color: colors[i % colors.length],
            value: value,
            title: '${item[labelKey]}\n${currencyFormat.format(value)}',
            radius: 80,
            titleStyle: const TextStyle(fontSize: 10, fontWeight: FontWeight.bold, color: Colors.white),
          ),
        );
      }
    }

    return PieChart(
      PieChartData(
        sections: sections,
        centerSpaceRadius: 20,
        sectionsSpace: 2,
      ),
    );
  }
}
