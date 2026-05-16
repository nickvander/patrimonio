import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../utils/currency.dart';

class TaxPlanningScreen extends StatefulWidget {
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final String targetCurrency;
  final double usdMxnRate;

  const TaxPlanningScreen({
    super.key,
    required this.conversionFactor,
    required this.currencyFormat,
    required this.targetCurrency,
    required this.usdMxnRate,
  });

  @override
  State<TaxPlanningScreen> createState() => _TaxPlanningScreenState();
}

class _TaxPlanningScreenState extends State<TaxPlanningScreen> {
  final ApiService _apiService = ApiService();
  bool _isLoading = true;
  String? _error;

  Map<String, dynamic>? _taxSummary;
  List<dynamic>? _taxTransactions;
  int _selectedYear = DateTime.now().year;
  String _filingStatus = 'Single';

  @override
  void initState() {
    super.initState();
    _loadTaxData();
  }

  Future<void> _loadTaxData() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });

    try {
      final summary = await _apiService.getTaxSummary(
        year: _selectedYear,
        status: _filingStatus,
      );
      final transactions = await _apiService.getTaxTransactions(
        year: _selectedYear,
      );

      setState(() {
        _taxSummary = summary;
        _taxTransactions = transactions;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _error = "Error loading tax data: $e";
        _isLoading = false;
      });
    }
  }

  void _exportCsv() async {
    final String baseUrl = _apiService.baseUrl;
    final url = Uri.parse('$baseUrl/tax/export?year=$_selectedYear');
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not launch CSV export.')),
        );
      }
    }
  }

  void _exportPdf() async {
    final String baseUrl = _apiService.baseUrl;
    final url = Uri.parse(
      '$baseUrl/tax/export/pdf?year=$_selectedYear&status=$_filingStatus',
    );
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not launch PDF export.')),
        );
      }
    }
  }

  // Dense tax-event row that mirrors the transactions tab visual language:
  // 32px tinted icon, two-line title/meta column, right-aligned amount with
  // tabular figures. Replaces the loose ListTile rows that made the two
  // surfaces look like different apps.
  Widget _buildTaxRow(dynamic tx) {
    final date = DateTime.parse(tx['date']);
    final sourceAmount = ((tx['amount'] as num?)?.toDouble() ?? 0.0);
    final sourceCurrency =
        (tx['currency'] ?? widget.targetCurrency).toString();
    final converted = convertCurrency(
      sourceAmount,
      from: sourceCurrency,
      to: widget.targetCurrency,
      usdMxnRate: widget.usdMxnRate,
    );
    final isCapGains = tx['category'] == 'Investment Sale';
    final iconColor =
        isCapGains ? Colors.purpleAccent : const Color(0xFF1DE9B6);
    final needsConversion = sourceCurrency != widget.targetCurrency;

    return InkWell(
      onTap: null,
      hoverColor: context.tint(0.03),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                isCapGains ? Icons.show_chart : Icons.work_outline,
                color: iconColor,
                size: 16,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    (tx['description'] ?? '').toString(),
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      height: 1.2,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${DateFormat('MMM d, y').format(date)} · ${tx['category']}',
                    style: TextStyle(
                      color: context.textSubtle,
                      fontSize: 11,
                      height: 1.3,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.currencyFormat.format(converted),
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                    color: Color(0xFF00E676),
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (needsConversion)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      formatCurrencyAmount(sourceAmount, sourceCurrency),
                      style: TextStyle(
                        fontSize: 10,
                        color: context.textFaint,
                        fontFeatures: [FontFeature.tabularFigures()],
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 60, color: Colors.redAccent),
            const SizedBox(height: 16),
            Text(_error!),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadTaxData, child: Text('Retry')),
          ],
        ),
      );
    }

    final ordinaryIncome =
        ((_taxSummary?['ordinary_income'] as num?)?.toDouble() ?? 0) *
        widget.conversionFactor;
    final capitalGains =
        ((_taxSummary?['capital_gains'] as num?)?.toDouble() ?? 0) *
        widget.conversionFactor;
    final totalTaxable =
        ((_taxSummary?['total_taxable'] as num?)?.toDouble() ?? 0) *
        widget.conversionFactor;

    final liabUs =
        ((_taxSummary?['estimated_liability_us'] as num?)?.toDouble() ?? 0) *
        widget.conversionFactor;
    final liabMx =
        ((_taxSummary?['estimated_liability_mx'] as num?)?.toDouble() ?? 0) *
        widget.conversionFactor;
    final rateUs =
        ((_taxSummary?['effective_rate_us'] as num?)?.toDouble() ?? 0) * 100;
    final rateMx =
        ((_taxSummary?['effective_rate_mx'] as num?)?.toDouble() ?? 0) * 100;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'Tax planning',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            Row(
              children: [
                DropdownButton<String>(
                  value: _filingStatus,
                  items: <String>['Single', 'Married', 'Head of Household'].map(
                    (String value) {
                      return DropdownMenuItem<String>(
                        value: value,
                        child: Text(value),
                      );
                    },
                  ).toList(),
                  onChanged: (String? newValue) {
                    if (newValue != null) {
                      setState(() {
                        _filingStatus = newValue;
                      });
                      _loadTaxData();
                    }
                  },
                  underline: const SizedBox(),
                ),
                const SizedBox(width: 16),
                DropdownButton<int>(
                  value: _selectedYear,
                  items: <int>[DateTime.now().year, DateTime.now().year - 1]
                      .map((int value) {
                        return DropdownMenuItem<int>(
                          value: value,
                          child: Text(value.toString()),
                        );
                      })
                      .toList(),
                  onChanged: (int? newValue) {
                    if (newValue != null) {
                      setState(() {
                        _selectedYear = newValue;
                      });
                      _loadTaxData();
                    }
                  },
                  underline: const SizedBox(),
                ),
                const SizedBox(width: 16),
                ElevatedButton.icon(
                  onPressed: _exportCsv,
                  icon: Icon(Icons.download),
                  label: Text('Export CSV'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF00E676),
                    foregroundColor: Colors.black,
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _exportPdf,
                  icon: Icon(Icons.picture_as_pdf),
                  label: Text('PDF'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueAccent,
                    foregroundColor: context.textPrimary,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 24),
        Row(
          children: [
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Total taxable income',
                        style: TextStyle(color: context.textMuted),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.currencyFormat.format(totalTaxable),
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Ordinary income: ${widget.currencyFormat.format(ordinaryIncome)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: context.textSubtle,
                            ),
                          ),
                          Text(
                            'Capital gains: ${widget.currencyFormat.format(capitalGains)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: context.textSubtle,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'US estimated liability (IRS)',
                        style: TextStyle(color: context.textMuted),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.currencyFormat.format(liabUs),
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.blueAccent,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Effective rate: ${rateUs.toStringAsFixed(2)}%',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.textSubtle,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 24),
            Expanded(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(24.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'MX estimated liability (SAT)',
                        style: TextStyle(color: context.textMuted),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.currencyFormat.format(liabMx),
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.greenAccent,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Effective Rate: ${rateMx.toStringAsFixed(2)}%',
                        style: TextStyle(
                          fontSize: 12,
                          color: context.textSubtle,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          'Taxable events',
          style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 16),
        Expanded(
          child: (_taxTransactions == null || _taxTransactions!.isEmpty)
              ? Card(
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.receipt_long_outlined,
                          size: 56,
                          color: context.tint(0.15),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          'No taxable events found for this year.',
                          style: TextStyle(color: context.textSubtle, fontSize: 16),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Income, salary, interest, and investment sale transactions will appear here.',
                          style: TextStyle(color: context.textFaint, fontSize: 12),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                )
              : Card(
                  elevation: 4,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: _taxTransactions!.length,
                    separatorBuilder: (context, index) => Divider(
                      height: 1,
                      color: context.tint(0.04),
                      indent: 56,
                    ),
                    itemBuilder: (context, index) {
                      final tx = _taxTransactions![index];
                      return _buildTaxRow(tx);
                    },
                  ),
                ),
        ),
        const SizedBox(height: 12),
        Text(
          'Disclaimer: Tax estimates are approximations using 2026 IRS/SAT brackets. Consult a qualified tax professional for filing.',
          style: TextStyle(
            color: context.textFaint,
            fontSize: 10,
            fontStyle: FontStyle.italic,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }
}
