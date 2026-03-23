import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';

class PortfolioCard extends StatefulWidget {
  final Map<String, dynamic> portfolioData;

  const PortfolioCard({
    Key? key,
    required this.portfolioData,
  }) : super(key: key);

  @override
  _PortfolioCardState createState() => _PortfolioCardState();
}

class _PortfolioCardState extends State<PortfolioCard> {
  int? _sortColumnIndex = 3; // Default sort by Value
  bool _isAscending = false;
  late List<dynamic> _holdings;

  @override
  void initState() {
    super.initState();
    _holdings = List.from(widget.portfolioData['holdings'] ?? []);
    // Initial sort
    _sort(3, false);
  }

  @override
  void didUpdateWidget(PortfolioCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.portfolioData != oldWidget.portfolioData) {
      _holdings = List.from(widget.portfolioData['holdings'] ?? []);
      _sort(_sortColumnIndex ?? 3, _isAscending);
    }
  }

  void _sort(int columnIndex, bool ascending) {
    setState(() {
      _sortColumnIndex = columnIndex;
      _isAscending = ascending;

      _holdings.sort((a, b) {
        dynamic valA;
        dynamic valB;

        switch (columnIndex) {
          case 0:
            valA = a['symbol']?.toString() ?? '';
            valB = b['symbol']?.toString() ?? '';
            break;
          case 1:
            valA = (a['quantity'] as num?)?.toDouble() ?? 0.0;
            valB = (b['quantity'] as num?)?.toDouble() ?? 0.0;
            break;
          case 2:
            valA = (a['price'] as num?)?.toDouble() ?? 0.0;
            valB = (b['price'] as num?)?.toDouble() ?? 0.0;
            break;
          case 3:
            valA = (a['value'] as num?)?.toDouble() ?? 0.0;
            valB = (b['value'] as num?)?.toDouble() ?? 0.0;
            break;
          case 4:
            valA = (a['gain_loss_pct'] as num?)?.toDouble() ?? 0.0;
            valB = (b['gain_loss_pct'] as num?)?.toDouble() ?? 0.0;
            break;
          default:
            valA = 0;
            valB = 0;
        }

        if (!ascending) {
          final temp = valA;
          valA = valB;
          valB = temp;
        }

        return Comparable.compare(valA as Comparable, valB as Comparable);
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    final totalValue = (widget.portfolioData['total_value'] as num?)?.toDouble() ?? 0.0;
    final totalGainLoss = (widget.portfolioData['total_gain_loss'] as num?)?.toDouble() ?? 0.0;
    final totalGainLossPct = (widget.portfolioData['total_gain_loss_pct'] as num?)?.toDouble() ?? 0.0;

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
                          color: isPositive ? const Color(0xFF00E676) : Colors.redAccent,
                          size: 16,
                        ),
                        Text(
                          '${currencyFormat.format(totalGainLoss.abs())} (${totalGainLossPct.toStringAsFixed(2)}%)',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                            color: isPositive ? const Color(0xFF00E676) : Colors.redAccent,
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
                  child: _buildHoldingsTable(currencyFormat),
                ),
                const SizedBox(width: 24),
                Expanded(
                  flex: 1,
                  child: SizedBox(
                    height: 250,
                    child: _buildAllocationChart(),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHoldingsTable(NumberFormat format) {
    if (_holdings.isEmpty) {
      return const Center(child: Text('No investment holdings found.'));
    }

    return DataTable(
      headingTextStyle: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white70),
      sortColumnIndex: _sortColumnIndex,
      sortAscending: _isAscending,
      showCheckboxColumn: false,
      columns: [
        DataColumn(label: const Text('Symbol'), onSort: _sort),
        DataColumn(label: const Text('Shares'), numeric: true, onSort: _sort),
        DataColumn(label: const Text('Price'), numeric: true, onSort: _sort),
        DataColumn(label: const Text('Value'), numeric: true, onSort: _sort),
        DataColumn(label: const Text('Return'), numeric: true, onSort: _sort),
      ],
      rows: _holdings.take(8).map((h) {
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
              style: TextStyle(color: isGain ? const Color(0xFF00E676) : Colors.redAccent, fontWeight: FontWeight.w500),
            ),
          ),
        ]);
      }).toList(),
    );
  }

  Widget _buildAllocationChart() {
    if (_holdings.isEmpty) return const SizedBox.shrink();

    final colors = [
      const Color(0xFF00E676),
      const Color(0xFF00B0FF),
      const Color(0xFFFFD54F),
      const Color(0xFFFF5252),
      const Color(0xFFB388FF),
      const Color(0xFF64FFDA),
      const Color(0xFFFF8A65),
    ];

    final sortedHoldings = List.from(_holdings)..sort((a, b) => ((b['value'] ?? 0) as num).compareTo((a['value'] ?? 0) as num));

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
            title: '${h['symbol']}\n${((value / widget.portfolioData['total_value']) * 100).toStringAsFixed(1)}%',
            radius: 80,
            titleStyle: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold, color: Colors.black87),
          ),
        );
      } else {
        otherValue += value;
      }
    }

    if (otherValue > 0) {
      sections.add(
        PieChartSectionData(
          color: Colors.grey.shade800,
          value: otherValue,
          title: 'Other\n${((otherValue / widget.portfolioData['total_value']) * 100).toStringAsFixed(1)}%',
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
