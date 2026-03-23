import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

class PortfolioCard extends StatelessWidget {
  final Map<String, dynamic> portfolioData;

  const PortfolioCard({
    Key? key,
    required this.portfolioData,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final holdings = portfolioData['holdings'] as List<dynamic>? ?? [];
    final totalValue = (portfolioData['total_value'] as num?)?.toDouble() ?? 0.0;
    final totalGainLoss = (portfolioData['total_gain_loss'] as num?)?.toDouble() ?? 0.0;
    final totalGainLossPct = (portfolioData['total_gain_loss_pct'] as num?)?.toDouble() ?? 0.0;

    final currencyFormat = NumberFormat.simpleCurrency(name: 'USD');
    final isPositive = totalGainLoss >= 0;

    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Investment Portfolio',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Total Value', style: TextStyle(color: Colors.grey)),
                    Text(
                      currencyFormat.format(totalValue),
                      style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text('Total Return', style: TextStyle(color: Colors.grey)),
                    Row(
                      children: [
                        Icon(
                          isPositive ? Icons.arrow_upward : Icons.arrow_downward,
                          color: isPositive ? Colors.green : Colors.red,
                          size: 16,
                        ),
                        Text(
                          '${currencyFormat.format(totalGainLoss.abs())} (${totalGainLossPct.toStringAsFixed(2)}%)',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: isPositive ? Colors.green : Colors.red,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 2,
                  child: _buildHoldingsTable(holdings, currencyFormat),
                ),
                const SizedBox(width: 24),
                Expanded(
                  flex: 1,
                  child: SizedBox(
                    height: 250,
                    child: _buildAllocationChart(holdings),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHoldingsTable(List<dynamic> holdings, NumberFormat format) {
    if (holdings.isEmpty) {
      return const Center(child: Text('No investment holdings found.'));
    }

    return DataTable(
      headingTextStyle: const TextStyle(fontWeight: FontWeight.bold, color: Colors.teal),
      columns: const [
        DataColumn(label: Text('Symbol')),
        DataColumn(label: Text('Shares')),
        DataColumn(label: Text('Price')),
        DataColumn(label: Text('Value')),
        DataColumn(label: Text('Return')),
      ],
      rows: holdings.take(8).map((h) {
      final gain = (h['gain_loss'] as num?)?.toDouble() ?? 0.0;
      final gainPct = (h['gain_loss_pct'] as num?)?.toDouble() ?? 0.0;
      final quantity = (h['quantity'] as num?)?.toDouble() ?? 0.0;
      final price = (h['price'] as num?)?.toDouble() ?? 0.0;
      final value = (h['value'] as num?)?.toDouble() ?? 0.0;
      final isGain = gain >= 0;
        
      return DataRow(cells: [
        DataCell(
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(h['symbol'] ?? 'Unknown', style: const TextStyle(fontWeight: FontWeight.bold)),
              Text(h['institution_name'] ?? '', style: const TextStyle(fontSize: 10, color: Colors.grey)),
            ],
          ),
        ),
        DataCell(Text(quantity.toStringAsFixed(4))),
        DataCell(Text(format.format(price))),
        DataCell(Text(format.format(value), style: const TextStyle(fontWeight: FontWeight.w600))),
        DataCell(
            Text(
              '${isGain ? '+' : ''}${format.format(gain)} (${gainPct.toStringAsFixed(2)}%)',
              style: TextStyle(color: isGain ? Colors.green : Colors.red, fontWeight: FontWeight.w500),
            ),
          ),
        ]);
      }).toList(),
    );
  }

  Widget _buildAllocationChart(List<dynamic> holdings) {
    if (holdings.isEmpty) return const SizedBox.shrink();

    // Group by symbol to create the pie chart
    final colors = [Colors.teal, Colors.blue, Colors.orange, Colors.purple, Colors.red, Colors.green, Colors.cyan, Colors.amber];
    
    // Sort by value and take top 5, group rest as "Other"
    final sortedHoldings = List.from(holdings)..sort((a, b) => (b['value'] ?? 0).compareTo(a['value'] ?? 0));
    
    List<PieChartSectionData> sections = [];
    double otherValue = 0.0;
    
    for (int i = 0; i < sortedHoldings.length; i++) {
      final h = sortedHoldings[i];
      final value = (h['value'] ?? 0.0).toDouble();
      
      if (value <= 0) continue;
      
      if (i < 5) {
        sections.add(
          PieChartSectionData(
            color: colors[i % colors.length],
            value: value,
            title: '${h['symbol']}\n${((value / portfolioData['total_value']) * 100).toStringAsFixed(1)}%',
            radius: 80,
            titleStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
          ),
        );
      } else {
        otherValue += value;
      }
    }
    
    if (otherValue > 0) {
      sections.add(
        PieChartSectionData(
          color: Colors.grey,
          value: otherValue,
          title: 'Other\n${((otherValue / portfolioData['total_value']) * 100).toStringAsFixed(1)}%',
          radius: 80,
          titleStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.white),
        ),
      );
    }

    return Column(
      children: [
        const Text('Allocation', style: TextStyle(fontWeight: FontWeight.w600)),
        const SizedBox(height: 16),
        Expanded(
          child: PieChart(
            PieChartData(
              sections: sections,
              centerSpaceRadius: 20,
              sectionsSpace: 2,
            ),
          ),
        ),
      ],
    );
  }
}
