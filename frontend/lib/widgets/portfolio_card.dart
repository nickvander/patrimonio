import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../utils/currency.dart';

class PortfolioCard extends StatefulWidget {
  final Map<String, dynamic> portfolioData;
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final String targetCurrency;
  final double usdMxnRate;

  const PortfolioCard({
    super.key,
    required this.portfolioData,
    required this.conversionFactor,
    required this.currencyFormat,
    required this.targetCurrency,
    required this.usdMxnRate,
  });

  @override
  State<PortfolioCard> createState() => _PortfolioCardState();
}

class _PortfolioCardState extends State<PortfolioCard> {
  int? _sortColumnIndex = 3; // Default sort by Value
  bool _isAscending = false;
  late List<dynamic> _holdings;
  int _touchedIndex = -1;

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
    if (widget.portfolioData != oldWidget.portfolioData ||
        widget.conversionFactor != oldWidget.conversionFactor) {
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
    final totalValue =
        ((widget.portfolioData['total_value'] as num?)?.toDouble() ?? 0.0) *
        widget.conversionFactor;
    final totalGainLoss =
        ((widget.portfolioData['total_gain_loss'] as num?)?.toDouble() ?? 0.0) *
        widget.conversionFactor;
    final totalGainLossPct =
        (widget.portfolioData['total_gain_loss_pct'] as num?)?.toDouble() ??
        0.0;

    final isPositive = totalGainLoss >= 0;

    return Card(
      elevation: 6,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      child: Padding(
        padding: const EdgeInsets.all(32.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  flex: 1,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Investment Portfolio',
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 32),
                      const Text(
                        'Total Value',
                        style: TextStyle(
                          color: Colors.white60,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          letterSpacing: 0.5,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        widget.currencyFormat.format(totalValue),
                        style: const TextStyle(
                          fontSize: 56,
                          fontWeight: FontWeight.w900,
                          letterSpacing: -1.5,
                          height: 1.1,
                          color: Colors.white,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                colors: isPositive
                                    ? [
                                        const Color(
                                          0xFF00E676,
                                        ).withValues(alpha: 0.2),
                                        const Color(
                                          0xFF00E676,
                                        ).withValues(alpha: 0.05),
                                      ]
                                    : [
                                        Colors.redAccent.withValues(alpha: 0.2),
                                        Colors.redAccent.withValues(
                                          alpha: 0.05,
                                        ),
                                      ],
                              ),
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isPositive
                                    ? const Color(
                                        0xFF00E676,
                                      ).withValues(alpha: 0.3)
                                    : Colors.redAccent.withValues(alpha: 0.3),
                                width: 1,
                              ),
                            ),
                            child: Row(
                              children: [
                                Icon(
                                  isPositive
                                      ? Icons.arrow_upward
                                      : Icons.arrow_downward,
                                  color: isPositive
                                      ? const Color(0xFF00E676)
                                      : Colors.redAccent,
                                  size: 16,
                                ),
                                const SizedBox(width: 6),
                                Text(
                                  '${isPositive ? '+' : ''}${widget.currencyFormat.format(totalGainLoss.abs())} (${totalGainLossPct.toStringAsFixed(2)}%)',
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                    color: isPositive
                                        ? const Color(0xFF00E676)
                                        : Colors.redAccent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                Expanded(
                  flex: 1,
                  child: SizedBox(height: 240, child: _buildAllocationChart()),
                ),
              ],
            ),
            const SizedBox(height: 48),
            Theme(
              data: Theme.of(context).copyWith(
                cardTheme: CardThemeData(
                  color: const Color(0xFF1A1A24),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
                dividerColor: Colors.white12,
                // Attempt to fix pagination centering by making the table footer area more focused
                dataTableTheme: DataTableThemeData(
                  horizontalMargin: 24,
                  columnSpacing: 48,
                ),
              ),
              child: _buildHoldingsTable(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHoldingsTable() {
    if (_holdings.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(32.0),
        child: Center(
          child: Text(
            'No investment holdings found.',
            style: TextStyle(color: Colors.grey),
          ),
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        return SizedBox(
          width: constraints.maxWidth,
          child: PaginatedDataTable(
            header: const Text(
              'Asset Breakdown',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            rowsPerPage: 5,
            showFirstLastButtons: true,
            arrowHeadColor: const Color(0xFF00E676),
            sortColumnIndex: _sortColumnIndex,
            sortAscending: _isAscending,
            // Force the table to take up available width which pushes pagination "under" the data more naturally
            columnSpacing: (constraints.maxWidth - 600) / 5 > 0
                ? (constraints.maxWidth - 600) / 5
                : 24,
            horizontalMargin: 24,
            columns: [
              DataColumn(label: const Text('Asset'), onSort: _sort),
              DataColumn(
                label: const Text('Shares'),
                numeric: true,
                onSort: _sort,
              ),
              DataColumn(
                label: const Text('Price'),
                numeric: true,
                onSort: _sort,
              ),
              DataColumn(
                label: const Text('Total Value'),
                numeric: true,
                onSort: _sort,
              ),
              DataColumn(
                label: const Text('All-Time Return'),
                numeric: true,
                onSort: _sort,
              ),
            ],
            source: _HoldingsDataSource(
              _holdings,
              widget.currencyFormat,
              widget.conversionFactor,
              widget.targetCurrency,
              widget.usdMxnRate,
              context,
            ),
          ),
        );
      },
    );
  }

  Widget _buildAllocationChart() {
    if (_holdings.isEmpty) return const SizedBox.shrink();

    final colors = [
      const Color(0xFF1DE9B6), // Neon Teal
      const Color(0xFF7C4DFF), // Deep Violet
      const Color(0xFFFF4081), // Pink Accent
      const Color(0xFFFFD740), // Bright Gold
      const Color(0xFF2979FF), // Vivid Blue
    ];

    final sortedHoldings = List.from(_holdings)
      ..sort(
        (a, b) =>
            ((b['value'] ?? 0) as num).compareTo((a['value'] ?? 0) as num),
      );

    List<PieChartSectionData> sections = [];
    List<Widget> legendItems = [];
    double otherValue = 0.0;

    for (int i = 0; i < sortedHoldings.length; i++) {
      final h = sortedHoldings[i];
      final value = (h['value'] ?? 0.0).toDouble();

      if (value <= 0) continue;
      final percentage = value / widget.portfolioData['total_value'];
      final isTouched = i == _touchedIndex;
      final radius = isTouched ? 60.0 : 50.0;

      if (i < 4) {
        final color = colors[i % colors.length];
        sections.add(
          PieChartSectionData(
            color: color,
            value: value,
            title: isTouched ? '${(percentage * 100).toStringAsFixed(1)}%' : '',
            radius: radius,
            titleStyle: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w900,
              color: Colors.white,
              shadows: [Shadow(color: Colors.black, blurRadius: 6)],
            ),
            badgeWidget: isTouched
                ? Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A24),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: 0.6),
                          blurRadius: 10,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Icon(Icons.show_chart, color: color, size: 14),
                  )
                : null,
            badgePositionPercentageOffset: 1.15,
          ),
        );
        legendItems.add(
          _buildLegendItem(
            color,
            h['name'] ?? h['symbol'] ?? '?',
            percentage,
            isTouched,
          ),
        );
      } else {
        otherValue += value;
      }
    }

    if (otherValue > 0) {
      final percentage = otherValue / widget.portfolioData['total_value'];
      final isTouched = _touchedIndex == 4;
      final radius = isTouched ? 60.0 : 50.0;
      sections.add(
        PieChartSectionData(
          color: Colors.grey.shade700,
          value: otherValue,
          title: isTouched ? '${(percentage * 100).toStringAsFixed(1)}%' : '',
          radius: radius,
          titleStyle: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
      );
      legendItems.add(
        _buildLegendItem(Colors.grey.shade700, 'Other', percentage, isTouched),
      );
    }

    return Row(
      children: [
        Expanded(
          flex: 3,
          child: PieChart(
            PieChartData(
              pieTouchData: PieTouchData(
                touchCallback: (FlTouchEvent event, pieTouchResponse) {
                  setState(() {
                    if (!event.isInterestedForInteractions ||
                        pieTouchResponse == null ||
                        pieTouchResponse.touchedSection == null) {
                      _touchedIndex = -1;
                      return;
                    }
                    _touchedIndex =
                        pieTouchResponse.touchedSection!.touchedSectionIndex;
                  });
                },
              ),
              sections: sections,
              centerSpaceRadius: 50,
              sectionsSpace: 4,
            ),
          ),
        ),
        const SizedBox(width: 24),
        Expanded(
          flex: 2,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: legendItems,
          ),
        ),
      ],
    );
  }

  Widget _buildLegendItem(
    Color color,
    String label,
    double percentage,
    bool isTouched,
  ) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      padding: const EdgeInsets.symmetric(vertical: 4.0, horizontal: 8.0),
      decoration: BoxDecoration(
        color: isTouched ? color.withValues(alpha: 0.1) : Colors.transparent,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Container(
            width: 12,
            height: 12,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: isTouched
                  ? [
                      BoxShadow(
                        color: color.withValues(alpha: 0.5),
                        blurRadius: 4,
                      ),
                    ]
                  : [],
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontWeight: isTouched ? FontWeight.bold : FontWeight.w600,
                color: isTouched ? color : Colors.white,
              ),
            ),
          ),
          Text(
            '${(percentage * 100).toStringAsFixed(1)}%',
            style: TextStyle(
              color: isTouched ? color : Colors.grey,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _HoldingsDataSource extends DataTableSource {
  final List<dynamic> holdings;
  final NumberFormat format;
  final double conversionFactor;
  final String targetCurrency;
  final double usdMxnRate;
  final BuildContext context;

  _HoldingsDataSource(
    this.holdings,
    this.format,
    this.conversionFactor,
    this.targetCurrency,
    this.usdMxnRate,
    this.context,
  );

  @override
  DataRow? getRow(int index) {
    if (index >= holdings.length) return null;
    final h = holdings[index];
    final gain = (h['gain_loss'] as num?)?.toDouble() ?? 0.0;
    final gainPct = (h['gain_loss_pct'] as num?)?.toDouble() ?? 0.0;
    final quantity = (h['quantity'] as num?)?.toDouble() ?? 0.0;
    final sourceCurrency = (h['currency'] ?? targetCurrency).toString();
    final sourcePrice = (h['price'] as num?)?.toDouble() ?? 0.0;
    final sourceValue = (h['value'] as num?)?.toDouble() ?? 0.0;
    final price = convertCurrency(
      sourcePrice,
      from: sourceCurrency,
      to: targetCurrency,
      usdMxnRate: usdMxnRate,
    );
    final value = convertCurrency(
      sourceValue,
      from: sourceCurrency,
      to: targetCurrency,
      usdMxnRate: usdMxnRate,
    );
    final isGain = gain >= 0;

    return DataRow(
      color: WidgetStateProperty.resolveWith<Color?>((states) {
        if (states.contains(WidgetState.hovered)) {
          return Colors.white.withValues(alpha: 0.05);
        }
        return null; // Use default
      }),
      cells: [
        DataCell(
          Builder(builder: (context) {
            final rawSymbol = (h['symbol'] ?? '').toString();
            final rawName = (h['name'] ?? '').toString();
            // Plaid emits opaque security_ids (e.g. "3mg4qV4JZycPL4qeZgB...")
            // for un-tickered Vanguard mutual funds. Detect those: a real
            // ticker is short (<=8 chars) and uppercase; a security_id is
            // long and mixed-case.
            final isOpaqueSecurityId = rawSymbol.length > 8 ||
                (rawSymbol != rawSymbol.toUpperCase() &&
                    rawSymbol.length > 4);
            final displaySymbol = isOpaqueSecurityId
                ? (rawName.isNotEmpty ? rawName : '—')
                : (rawSymbol.isEmpty ? (rawName.isNotEmpty ? rawName : '?') : rawSymbol);
            final secondaryLabel = (isOpaqueSecurityId || rawName.isEmpty)
                ? (h['institution_name'] ?? '').toString()
                : '$rawName · ${h['institution_name'] ?? ''}';
            final avatarChar = displaySymbol.isEmpty
                ? '?'
                : displaySymbol.substring(0, 1).toUpperCase();
            return Row(
              children: [
                CircleAvatar(
                  backgroundColor: const Color(0xFF2A2A35),
                  radius: 16,
                  child: Text(
                    avatarChar,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 12,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        displaySymbol,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      Text(
                        secondaryLabel,
                        style: const TextStyle(
                          fontSize: 11,
                          color: Colors.grey,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
              ],
            );
          }),
        ),
        DataCell(
          Text(
            quantity.toStringAsFixed(4),
            style: const TextStyle(fontSize: 14),
          ),
        ),
        DataCell(
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(format.format(price), style: const TextStyle(fontSize: 14)),
              if (sourceCurrency != targetCurrency)
                Text(
                  formatCurrencyAmount(sourcePrice, sourceCurrency),
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
            ],
          ),
        ),
        DataCell(
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                format.format(value),
                style: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
              if (sourceCurrency != targetCurrency)
                Text(
                  formatCurrencyAmount(sourceValue, sourceCurrency),
                  style: const TextStyle(fontSize: 10, color: Colors.grey),
                ),
            ],
          ),
        ),
        DataCell(
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: (isGain ? const Color(0xFF00E676) : Colors.redAccent)
                  .withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${isGain ? '+' : ''}${gainPct.toStringAsFixed(2)}%',
              style: TextStyle(
                color: isGain ? const Color(0xFF00E676) : Colors.redAccent,
                fontWeight: FontWeight.bold,
                fontSize: 13,
              ),
            ),
          ),
        ),
      ],
    );
  }

  @override
  bool get isRowCountApproximate => false;

  @override
  int get rowCount => holdings.length;

  @override
  int get selectedRowCount => 0;
}
