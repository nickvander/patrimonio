import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../utils/currency.dart';
import '../l10n/app_localizations.dart';

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
        _error = e.toString();
        _isLoading = false;
      });
    }
  }

  String _filingStatusLabel(AppLocalizations l, String value) {
    switch (value) {
      case 'Single':
        return l.taxFilingSingle;
      case 'Married':
        return l.taxFilingMarried;
      case 'Head of Household':
        return l.taxFilingHeadOfHousehold;
      default:
        return value;
    }
  }

  void _exportCsv() async {
    final String baseUrl = _apiService.baseUrl;
    // Pass the filing status too: the CSV's summary block includes the
    // estimated liability, which is status-dependent (same as the PDF).
    final url = Uri.parse(
      '$baseUrl/tax/export?year=$_selectedYear&status=$_filingStatus',
    );
    if (await canLaunchUrl(url)) {
      await launchUrl(url);
    } else {
      if (mounted) {
        final l = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.taxCsvLaunchFailed)),
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
        final l = AppLocalizations.of(context);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(l.taxPdfLaunchFailed)),
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
    // The backend ships `amount_usd`: the row converted at ITS date's stored
    // USD/MXN rate — the same per-row FX the summary's ordinary_income (USD)
    // is built from. Displaying amount_usd × conversionFactor therefore makes
    // the visible rows sum exactly to the KPI headline, which a client-side
    // today's-rate conversion of mixed-currency rows would not.
    final amountUsd = (tx['amount_usd'] as num?)?.toDouble();
    final converted = amountUsd != null
        ? amountUsd * widget.conversionFactor
        : convertCurrency(
            sourceAmount,
            from: sourceCurrency,
            to: widget.targetCurrency,
            usdMxnRate: widget.usdMxnRate,
          );
    // /tax/transactions now returns income events only (capital gains come
    // from lot disposals, not transaction categories). Rows match the stored
    // taxonomy — 'INCOME' / user_category override — so anything else is a
    // defensive fallback that keeps the old chart icon.
    final effectiveCategory =
        ((tx['user_category'] ?? tx['category']) ?? '').toString().toUpperCase();
    final isIncome =
        effectiveCategory == 'INCOME' || effectiveCategory.startsWith('INCOME_');
    final iconColor =
        isIncome ? context.tealAccent : context.purpleAccent;
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
                isIncome ? Icons.work_outline : Icons.show_chart,
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
                    style: const TextStyle(
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
                    color: context.positive,
                    fontFeatures: const [FontFeature.tabularFigures()],
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
                        fontFeatures: [const FontFeature.tabularFigures()],
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
    final l = AppLocalizations.of(context);
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
            Text(l.taxLoadError(_error!)),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: _loadTaxData, child: Text(l.taxRetry)),
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
    final shortTermGains =
        ((_taxSummary?['short_term_gains'] as num?)?.toDouble() ?? 0) *
        widget.conversionFactor;
    final longTermGains =
        ((_taxSummary?['long_term_gains'] as num?)?.toDouble() ?? 0) *
        widget.conversionFactor;
    final gainsFromLots = _taxSummary?['gains_from_lots'] == true;
    // T6: dividends/interest carved out of (never added on top of) ordinary
    // income; wage_income is the residual bucket. Shown only when there IS
    // investment income, as a muted sub-line like the ST/LT breakdown.
    final dividendIncome =
        ((_taxSummary?['dividend_income'] as num?)?.toDouble() ?? 0) *
        widget.conversionFactor;
    final interestIncome =
        ((_taxSummary?['interest_income'] as num?)?.toDouble() ?? 0) *
        widget.conversionFactor;
    final wageIncome =
        ((_taxSummary?['wage_income'] as num?)?.toDouble() ?? 0) *
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
    // T4: the bracket year the backend ACTUALLY applied (nearest populated
    // table for years without one) — the disclaimer must not claim a
    // hardcoded vintage. Falls back to the selected year for old payloads.
    final bracketYearUsed =
        (_taxSummary?['bracket_year_used'] as num?)?.toInt() ?? _selectedYear;
    // While the backend's bracket/deduction/tarifa constants are pending
    // human verification it sends constants_verified == false; badge the
    // KPIs so the figures aren't mistaken for authoritative numbers.
    final constantsUnverified = _taxSummary?['constants_verified'] == false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              l.taxTitle,
              style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            Row(
              children: [
                DropdownButton<String>(
                  value: _filingStatus,
                  items: <String>['Single', 'Married', 'Head of Household'].map(
                    (String value) {
                      return DropdownMenuItem<String>(
                        value: value,
                        child: Text(_filingStatusLabel(l, value)),
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
                  icon: const Icon(Icons.download),
                  label: Text(l.taxExportCsv),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: context.positive,
                    foregroundColor: Colors.white,
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton.icon(
                  onPressed: _exportPdf,
                  icon: const Icon(Icons.picture_as_pdf),
                  label: Text(l.taxExportPdf),
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
                        l.taxTotalTaxableIncome,
                        style: TextStyle(color: context.textMuted),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.currencyFormat.format(totalTaxable),
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            l.taxOrdinaryIncome(
                                widget.currencyFormat.format(ordinaryIncome)),
                            style: TextStyle(
                              fontSize: 12,
                              color: context.textSubtle,
                            ),
                          ),
                          Text(
                            l.taxCapitalGains(
                                widget.currencyFormat.format(capitalGains)),
                            style: TextStyle(
                              fontSize: 12,
                              color: context.textSubtle,
                            ),
                          ),
                        ],
                      ),
                      // T6: wages/dividends/interest decomposition of the
                      // ordinary-income figure, shown only when investment
                      // income exists (an all-wages year keeps the card short).
                      if (dividendIncome != 0 || interestIncome != 0) ...[
                        const SizedBox(height: 6),
                        Text(
                          l.taxIncomeDecomposition(
                            widget.currencyFormat.format(wageIncome),
                            widget.currencyFormat.format(dividendIncome),
                            widget.currencyFormat.format(interestIncome),
                          ),
                          style: TextStyle(
                            fontSize: 11,
                            color: context.textFaint,
                          ),
                        ),
                      ],
                      // Short- vs long-term breakdown, shown only when it comes
                      // from precise lot disposals (not the blended estimate).
                      if (gainsFromLots) ...[
                        const SizedBox(height: 6),
                        Text(
                          l.taxStLtBreakdown(
                            widget.currencyFormat.format(shortTermGains),
                            widget.currencyFormat.format(longTermGains),
                          ),
                          style: TextStyle(
                            fontSize: 11,
                            color: context.textFaint,
                          ),
                        ),
                      ],
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
                        l.taxUsEstimatedLiability,
                        style: TextStyle(color: context.textMuted),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.currencyFormat.format(liabUs),
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.blueAccent,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l.taxEffectiveRate(rateUs.toStringAsFixed(2)),
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
                        l.taxMxEstimatedLiability,
                        style: TextStyle(color: context.textMuted),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        widget.currencyFormat.format(liabMx),
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                          color: Colors.greenAccent,
                        ),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        l.taxEffectiveRate(rateMx.toStringAsFixed(2)),
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
        // Subtle "constants pending verification" caption under the KPI
        // cards — shown only while the backend flags its tax tables as
        // unverified.
        if (constantsUnverified) ...[
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.warning_amber_rounded,
                size: 13,
                color: context.warning,
              ),
              const SizedBox(width: 4),
              Text(
                l.taxConstantsUnverified,
                style: TextStyle(fontSize: 11, color: context.warning),
              ),
            ],
          ),
        ],
        const SizedBox(height: 24),
        Text(
          l.taxTaxableEvents,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
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
                          l.taxNoEventsTitle,
                          style: TextStyle(color: context.textSubtle, fontSize: 16),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l.taxNoEventsBody,
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
          l.taxDisclaimer(bracketYearUsed.toString()),
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
