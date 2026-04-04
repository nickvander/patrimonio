import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';

class TaxPlanningScreen extends StatefulWidget {
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const TaxPlanningScreen({
    Key? key,
    required this.conversionFactor,
    required this.currencyFormat,
  }) : super(key: key);

  @override
  _TaxPlanningScreenState createState() => _TaxPlanningScreenState();
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
      final summary = await _apiService.getTaxSummary(year: _selectedYear, status: _filingStatus);
      final transactions = await _apiService.getTaxTransactions(year: _selectedYear);
      
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

  void _export_csv() async {
    final String baseUrl = _apiService.baseUrl;
    final url = Uri.parse('$baseUrl/tax/export?year=$_selectedYear');
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    } else {
      if (mounted) {
         ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Could not launch CSV export.')));
      }
    }
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
            const Icon(Icons.error_outline, size: 60, color: Colors.redAccent),
            const SizedBox(height: 16),
            Text(_error!),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadTaxData, child: const Text('Retry')),
          ],
        ),
      );
    }

    final ordinaryIncome = ((_taxSummary?['ordinary_income'] as num?)?.toDouble() ?? 0) * widget.conversionFactor;
    final capitalGains = ((_taxSummary?['capital_gains'] as num?)?.toDouble() ?? 0) * widget.conversionFactor;
    final totalTaxable = ((_taxSummary?['total_taxable'] as num?)?.toDouble() ?? 0) * widget.conversionFactor;

    final liabUs = ((_taxSummary?['estimated_liability_us'] as num?)?.toDouble() ?? 0) * widget.conversionFactor;
    final liabMx = ((_taxSummary?['estimated_liability_mx'] as num?)?.toDouble() ?? 0) * widget.conversionFactor;
    final rateUs = ((_taxSummary?['effective_rate_us'] as num?)?.toDouble() ?? 0) * 100;
    final rateMx = ((_taxSummary?['effective_rate_mx'] as num?)?.toDouble() ?? 0) * 100;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            const Text(
              'Tax Planning Center',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            Row(
              children: [
                DropdownButton<String>(
                  value: _filingStatus,
                  items: <String>['Single', 'Married'].map((String value) {
                    return DropdownMenuItem<String>(value: value, child: Text(value));
                  }).toList(),
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
                   items: <int>[DateTime.now().year, DateTime.now().year - 1].map((int value) {
                      return DropdownMenuItem<int>(value: value, child: Text(value.toString()));
                   }).toList(),
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
                  onPressed: _export_csv,
                  icon: const Icon(Icons.download),
                  label: const Text('Export CSV'),
                  style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFF00E676), foregroundColor: Colors.black),
                )
              ]
            )
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
                      const Text('Total Taxable Income', style: TextStyle(color: Colors.white70)),
                      const SizedBox(height: 8),
                      Text(widget.currencyFormat.format(totalTaxable), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
                      const SizedBox(height: 16),
                      Row(
                         mainAxisAlignment: MainAxisAlignment.spaceBetween,
                         children: [
                            Text('Ordinary Income: ${widget.currencyFormat.format(ordinaryIncome)}', style: const TextStyle(fontSize: 12, color: Colors.white54)),
                            Text('Capital Gains: ${widget.currencyFormat.format(capitalGains)}', style: const TextStyle(fontSize: 12, color: Colors.white54)),
                         ]
                      )
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
                      const Text('US Estimated Liability (IRS)', style: TextStyle(color: Colors.white70)),
                      const SizedBox(height: 8),
                      Text(widget.currencyFormat.format(liabUs), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.blueAccent)),
                      const SizedBox(height: 16),
                      Text('Effective Rate: ${rateUs.toStringAsFixed(2)}%', style: const TextStyle(fontSize: 12, color: Colors.white54)),
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
                      const Text('MX Estimated Liability (SAT)', style: TextStyle(color: Colors.white70)),
                      const SizedBox(height: 8),
                      Text(widget.currencyFormat.format(liabMx), style: const TextStyle(fontSize: 28, fontWeight: FontWeight.bold, color: Colors.greenAccent)),
                      const SizedBox(height: 16),
                      Text('Effective Rate: ${rateMx.toStringAsFixed(2)}%', style: const TextStyle(fontSize: 12, color: Colors.white54)),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        const Text('Taxable Events', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
        const SizedBox(height: 16),
        Expanded(
          child: Card(
            child: ListView.separated(
              itemCount: _taxTransactions?.length ?? 0,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final tx = _taxTransactions![index];
                final date = DateTime.parse(tx['date']);
                final amount = tx['amount'] * widget.conversionFactor;
                return ListTile(
                  leading: CircleAvatar(
                    backgroundColor: tx['category'] == 'Investment Sale' ? Colors.purple.withOpacity(0.2) : Colors.blue.withOpacity(0.2),
                    child: Icon(tx['category'] == 'Investment Sale' ? Icons.show_chart : Icons.work, 
                      color: tx['category'] == 'Investment Sale' ? Colors.purpleAccent : Colors.blueAccent),
                  ),
                  title: Text(tx['description']),
                  subtitle: Text('${DateFormat('MMM dd, yyyy').format(date)} • ${tx['category']}'),
                  trailing: Text(widget.currencyFormat.format(amount), 
                    style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.greenAccent)),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
