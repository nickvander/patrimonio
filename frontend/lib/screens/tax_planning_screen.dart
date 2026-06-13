import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/api_service.dart';
import '../theme/typography.dart';
import '../utils/currency.dart';
import '../widgets/skeleton.dart';
import '../l10n/app_localizations.dart';
import 'tax_planning_logic.dart';

/// Test seams: the screen fetches through these typedefs so widget tests can
/// inject fixtures without subclassing ApiService (which pulls package:web
/// into the test VM — see MEMORY). Defaults wire straight to the real service.
typedef TaxSummaryFetcher = Future<Map<String, dynamic>> Function(
    {required int year, required String status});
typedef TaxTransactionsFetcher = Future<List<dynamic>> Function({required int year});
typedef TaxDisposalsFetcher = Future<List<dynamic>> Function(int year);
typedef SettingReader = Future<dynamic> Function(String key);
typedef SettingWriter = Future<void> Function(String key, dynamic value);
// M3 planning sections — same fixtureable-fetcher pattern as above.
typedef TaxUnrealizedFetcher = Future<Map<String, dynamic>> Function(
    {required int year, required String status});
typedef TaxFbarFetcher = Future<Map<String, dynamic>> Function(int year);
typedef TaxContributionsFetcher = Future<Map<String, dynamic>> Function(int year);

/// Backend setting key the tax estimator reads as the default filing status
/// when the query param is absent (so the persisted choice also reaches the
/// CSV/PDF export links). Must match the backend's `tax_filing_status`.
const String kFilingStatusSettingKey = 'tax_filing_status';

class TaxPlanningScreen extends StatefulWidget {
  final double conversionFactor;
  final NumberFormat currencyFormat;
  final String targetCurrency;
  final double usdMxnRate;

  // --- test seams (all optional; default to the real ApiService) ---
  final TaxSummaryFetcher? summaryFetcher;
  final TaxTransactionsFetcher? transactionsFetcher;
  final TaxDisposalsFetcher? disposalsFetcher;
  final SettingReader? settingReader;
  final SettingWriter? settingWriter;
  final TaxUnrealizedFetcher? unrealizedFetcher;
  final TaxFbarFetcher? fbarFetcher;
  final TaxContributionsFetcher? contributionsFetcher;

  const TaxPlanningScreen({
    super.key,
    required this.conversionFactor,
    required this.currencyFormat,
    required this.targetCurrency,
    required this.usdMxnRate,
    this.summaryFetcher,
    this.transactionsFetcher,
    this.disposalsFetcher,
    this.settingReader,
    this.settingWriter,
    this.unrealizedFetcher,
    this.fbarFetcher,
    this.contributionsFetcher,
  });

  @override
  State<TaxPlanningScreen> createState() => _TaxPlanningScreenState();
}

class _TaxPlanningScreenState extends State<TaxPlanningScreen> {
  final ApiService _apiService = ApiService();

  // First load shows a layout-true skeleton; subsequent filter changes keep
  // the last content mounted and dimmed while `_refetching` is true, rather
  // than unmounting to a spinner.
  bool _firstLoad = true;
  bool _refetching = false;
  String? _error;

  Map<String, dynamic>? _taxSummary;
  List<dynamic>? _taxTransactions;
  List<dynamic>? _taxDisposals;
  Map<String, dynamic>? _unrealized;
  Map<String, dynamic>? _fbar;
  Map<String, dynamic>? _contributions;

  int _selectedYear = DateTime.now().year;
  // Backend filing-status vocabulary (normalize accepts these exact tokens).
  static const List<String> _filingStatuses = [
    'Single',
    'Married',
    'Head of Household',
  ];
  String _filingStatus = 'Single';

  TaxSummaryFetcher get _fetchSummary =>
      widget.summaryFetcher ??
      ({required int year, required String status}) =>
          _apiService.getTaxSummary(year: year, status: status);
  TaxTransactionsFetcher get _fetchTransactions =>
      widget.transactionsFetcher ??
      ({required int year}) => _apiService.getTaxTransactions(year: year);
  TaxDisposalsFetcher get _fetchDisposals =>
      widget.disposalsFetcher ?? _apiService.getTaxDisposals;
  SettingReader get _readSetting =>
      widget.settingReader ?? _apiService.getSetting;
  SettingWriter get _writeSetting =>
      widget.settingWriter ?? _apiService.putSetting;
  TaxUnrealizedFetcher get _fetchUnrealized =>
      widget.unrealizedFetcher ??
      ({required int year, required String status}) =>
          _apiService.getUnrealizedLots(year: year, status: status);
  TaxFbarFetcher get _fetchFbar =>
      widget.fbarFetcher ?? _apiService.getFbarStatus;
  TaxContributionsFetcher get _fetchContributions =>
      widget.contributionsFetcher ?? _apiService.getRetirementContributions;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  /// Load the persisted filing status first (the screen used to reset to
  /// 'Single' every visit), then the year's data.
  Future<void> _bootstrap() async {
    try {
      final stored = await _readSetting(kFilingStatusSettingKey);
      final value = stored?.toString();
      if (value != null && _filingStatuses.contains(value)) {
        _filingStatus = value;
      }
    } catch (_) {
      // A missing/failed setting just leaves the default — non-fatal.
    }
    await _loadTaxData(firstLoad: true);
  }

  Future<void> _loadTaxData({bool firstLoad = false}) async {
    setState(() {
      if (firstLoad) {
        _firstLoad = true;
      } else {
        _refetching = true;
      }
      _error = null;
    });

    try {
      // Fetch summary/transactions/disposals AND the three M3 planning
      // sections (unrealized / FBAR / contributions) concurrently rather than
      // awaiting in series.
      final results = await Future.wait([
        _fetchSummary(year: _selectedYear, status: _filingStatus),
        _fetchTransactions(year: _selectedYear),
        _fetchDisposals(_selectedYear),
        _fetchUnrealized(year: _selectedYear, status: _filingStatus),
        _fetchFbar(_selectedYear),
        _fetchContributions(_selectedYear),
      ]);

      if (!mounted) return;
      setState(() {
        _taxSummary = results[0] as Map<String, dynamic>;
        _taxTransactions = results[1] as List<dynamic>;
        _taxDisposals = results[2] as List<dynamic>;
        _unrealized = results[3] as Map<String, dynamic>;
        _fbar = results[4] as Map<String, dynamic>;
        _contributions = results[5] as Map<String, dynamic>;
        _firstLoad = false;
        _refetching = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _firstLoad = false;
        _refetching = false;
      });
    }
  }

  void _onFilingStatusChanged(String value) {
    setState(() => _filingStatus = value);
    // Persist under the backend's key so direct CSV/PDF links pick it up too.
    _writeSetting(kFilingStatusSettingKey, value).catchError((_) {});
    _loadTaxData();
  }

  void _onYearChanged(int value) {
    setState(() => _selectedYear = value);
    _loadTaxData();
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

  // ---------------------------------------------------------------------------
  // Money helpers — mirror realized_gains_card.dart so a loss renders red and
  // a gain green (fixes the old all-green-losses bug), using the canonical
  // sign convention (positive = gain).
  // ---------------------------------------------------------------------------

  String _money(double usd) =>
      widget.currencyFormat.format(usd * widget.conversionFactor);

  String _signedMoney(double usd) {
    final v = usd * widget.conversionFactor;
    final formatted = widget.currencyFormat.format(v.abs());
    if (v > 0) return '+$formatted';
    if (v < 0) return '-$formatted';
    return formatted;
  }

  Color _pnlColor(double v) =>
      v > 0 ? context.positive : (v < 0 ? context.negative : context.textMuted);

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);

    if (_firstLoad) {
      return const _TaxSkeleton();
    }

    if (_error != null) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 60, color: context.negative),
            const SizedBox(height: 16),
            Text(l.taxLoadError(_error!)),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: () => _loadTaxData(firstLoad: true),
              child: Text(l.taxRetry),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final stackControls = width < 720;
        final stackKpis = width < 520;

        // Refetching keeps content mounted but dimmed + non-interactive,
        // so year/status switches don't flash the whole page to a spinner.
        return Stack(
          children: [
            AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: _refetching ? 0.45 : 1.0,
              child: IgnorePointer(
                ignoring: _refetching,
                child: _buildContent(l, stackControls, stackKpis),
              ),
            ),
            if (_refetching)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(minHeight: 2),
              ),
          ],
        );
      },
    );
  }

  Widget _buildContent(
      AppLocalizations l, bool stackControls, bool stackKpis) {
    final summary = _taxSummary ?? const {};

    double usd(String key) =>
        ((summary[key] as num?)?.toDouble() ?? 0) * widget.conversionFactor;

    final ordinaryIncome = usd('ordinary_income');
    final capitalGains = usd('capital_gains');
    final shortTermGains = usd('short_term_gains');
    final longTermGains = usd('long_term_gains');
    final dividendIncome = usd('dividend_income');
    final interestIncome = usd('interest_income');
    final wageIncome = usd('wage_income');
    final totalTaxable = usd('total_taxable');
    final liabUs = usd('estimated_liability_us');
    final liabMx = usd('estimated_liability_mx');
    final isrWithheld = usd('isr_withheld_usd');

    final gainsFromLots = summary['gains_from_lots'] == true;
    final rateUs = ((summary['effective_rate_us'] as num?)?.toDouble() ?? 0) * 100;
    final rateMx = ((summary['effective_rate_mx'] as num?)?.toDouble() ?? 0) * 100;
    final bracketYearUsed =
        (summary['bracket_year_used'] as num?)?.toInt() ?? _selectedYear;
    final constantsUnverified = summary['constants_verified'] == false;
    final holdingsWithoutBasis =
        (summary['holdings_without_basis'] as num?)?.toInt() ?? 0;

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildHeader(l, stackControls),
          const SizedBox(height: 24),
          _buildKpiRow(
            l,
            stackKpis: stackKpis,
            totalTaxable: totalTaxable,
            ordinaryIncome: ordinaryIncome,
            capitalGains: capitalGains,
            shortTermGains: shortTermGains,
            longTermGains: longTermGains,
            wageIncome: wageIncome,
            dividendIncome: dividendIncome,
            interestIncome: interestIncome,
            liabUs: liabUs,
            liabMx: liabMx,
            isrWithheld: isrWithheld,
            rateUs: rateUs,
            rateMx: rateMx,
            gainsFromLots: gainsFromLots,
          ),
          const SizedBox(height: 12),
          _buildScenariosNote(l),
          if (constantsUnverified) ...[
            const SizedBox(height: 8),
            _buildConstantsUnverifiedCaption(l),
          ],
          const SizedBox(height: 12),
          _buildAssumptions(
            l,
            bracketYearUsed: bracketYearUsed,
            holdingsWithoutBasis: holdingsWithoutBasis,
          ),
          const SizedBox(height: 24),
          _buildRealizedGainsSection(l),
          const SizedBox(height: 24),
          _buildUnrealizedSection(l),
          const SizedBox(height: 24),
          _buildFbarSection(l),
          const SizedBox(height: 24),
          _buildRetirementSection(l),
          const SizedBox(height: 24),
          _buildIncomeSection(l),
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
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Header + controls
  // ---------------------------------------------------------------------------

  Widget _buildHeader(AppLocalizations l, bool stackControls) {
    final title = Text(
      l.taxTitle,
      style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
    );

    final controls = _buildControls(l);

    if (stackControls) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          title,
          const SizedBox(height: 12),
          controls,
        ],
      );
    }
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Flexible(child: title),
        const SizedBox(width: 16),
        Flexible(child: Align(alignment: Alignment.centerRight, child: controls)),
      ],
    );
  }

  Widget _buildControls(AppLocalizations l) {
    final years = deriveTaxYears(
      _taxTransactions,
      _taxDisposals,
      currentYear: DateTime.now().year,
    );
    // Guard: the selected year must be in the items list or the dropdown asserts.
    final yearItems = years.contains(_selectedYear)
        ? years
        : (<int>[_selectedYear, ...years]..sort((a, b) => b.compareTo(a)));

    return Wrap(
      spacing: 16,
      runSpacing: 12,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        _labeledControl(
          l.taxFilingStatusLabel,
          DropdownButton<String>(
            value: _filingStatus,
            items: _filingStatuses
                .map((value) => DropdownMenuItem<String>(
                      value: value,
                      child: Text(_filingStatusLabel(l, value)),
                    ))
                .toList(),
            onChanged: (v) {
              if (v != null) _onFilingStatusChanged(v);
            },
            underline: const SizedBox(),
          ),
        ),
        _labeledControl(
          l.taxYearLabel,
          DropdownButton<int>(
            value: _selectedYear,
            items: yearItems
                .map((value) => DropdownMenuItem<int>(
                      value: value,
                      child: Text(value.toString()),
                    ))
                .toList(),
            onChanged: (v) {
              if (v != null) _onYearChanged(v);
            },
            underline: const SizedBox(),
          ),
        ),
        ElevatedButton.icon(
          onPressed: _exportCsv,
          icon: const Icon(Icons.download),
          label: Text(l.taxExportCsv),
          style: ElevatedButton.styleFrom(
            // Soft-tinted accent + pinned textPrimary foreground reads in both
            // brightnesses (the dashboard's sync-button convention), instead of
            // a saturated fill that fades to illegible text in light mode.
            backgroundColor: context.accentSoft(context.positive),
            foregroundColor: context.textPrimary,
          ),
        ),
        ElevatedButton.icon(
          onPressed: _exportPdf,
          icon: const Icon(Icons.picture_as_pdf),
          label: Text(l.taxExportPdf),
          style: ElevatedButton.styleFrom(
            backgroundColor: context.accentSoft(context.info),
            foregroundColor: context.textPrimary,
          ),
        ),
      ],
    );
  }

  Widget _labeledControl(String label, Widget control) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: 11,
            color: context.textSubtle,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        control,
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // KPI cards
  // ---------------------------------------------------------------------------

  Widget _buildKpiRow(
    AppLocalizations l, {
    required bool stackKpis,
    required double totalTaxable,
    required double ordinaryIncome,
    required double capitalGains,
    required double shortTermGains,
    required double longTermGains,
    required double wageIncome,
    required double dividendIncome,
    required double interestIncome,
    required double liabUs,
    required double liabMx,
    required double isrWithheld,
    required double rateUs,
    required double rateMx,
    required bool gainsFromLots,
  }) {
    final taxableCard = _kpiCard(
      label: l.taxTotalTaxableIncome,
      value: totalTaxable,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  l.taxOrdinaryIncome(widget.currencyFormat.format(ordinaryIncome)),
                  style: TextStyle(fontSize: 12, color: context.textSubtle),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  l.taxCapitalGains(widget.currencyFormat.format(capitalGains)),
                  style: TextStyle(fontSize: 12, color: context.textSubtle),
                  textAlign: TextAlign.right,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          if (dividendIncome != 0 || interestIncome != 0) ...[
            const SizedBox(height: 6),
            Text(
              l.taxIncomeDecomposition(
                widget.currencyFormat.format(wageIncome),
                widget.currencyFormat.format(dividendIncome),
                widget.currencyFormat.format(interestIncome),
              ),
              style: TextStyle(fontSize: 11, color: context.textFaint),
            ),
          ],
          if (gainsFromLots) ...[
            const SizedBox(height: 6),
            Text(
              l.taxStLtBreakdown(
                widget.currencyFormat.format(shortTermGains),
                widget.currencyFormat.format(longTermGains),
              ),
              style: TextStyle(fontSize: 11, color: context.textFaint),
            ),
          ],
          if (!gainsFromLots) ...[
            const SizedBox(height: 8),
            _roughEstimateBadge(l),
          ],
        ],
      ),
    );

    final usCard = _kpiCard(
      label: l.taxUsEstimatedLiability,
      value: liabUs,
      valueColor: context.info,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 6),
          Text(
            l.taxScenarioUsSubtitle,
            style: TextStyle(
              fontSize: 12,
              color: context.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l.taxScenarioUsCaveat,
            style: TextStyle(fontSize: 11, color: context.textFaint),
          ),
          const SizedBox(height: 10),
          Text(
            l.taxEffectiveRate(rateUs.toStringAsFixed(2)),
            style: TextStyle(fontSize: 12, color: context.textSubtle),
          ),
          if (!gainsFromLots) ...[
            const SizedBox(height: 8),
            _roughEstimateBadge(l),
          ],
        ],
      ),
    );

    final mxCard = _kpiCard(
      label: l.taxMxEstimatedLiability,
      value: liabMx,
      valueColor: context.tealAccent,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 6),
          Text(
            l.taxScenarioMxSubtitle,
            style: TextStyle(
              fontSize: 12,
              color: context.textMuted,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            l.taxScenarioMxCaveat,
            style: TextStyle(fontSize: 11, color: context.textFaint),
          ),
          const SizedBox(height: 10),
          Text(
            l.taxEffectiveRate(rateMx.toStringAsFixed(2)),
            style: TextStyle(fontSize: 12, color: context.textSubtle),
          ),
          if (isrWithheld > 0) ...[
            const SizedBox(height: 6),
            Text(
              l.taxMxWithheld(
                widget.currencyFormat.format(isrWithheld),
                widget.currencyFormat
                    .format((liabMx - isrWithheld).clamp(0, double.infinity)),
              ),
              style: TextStyle(fontSize: 11, color: context.textMuted),
            ),
          ],
          if (!gainsFromLots) ...[
            const SizedBox(height: 8),
            _roughEstimateBadge(l),
          ],
        ],
      ),
    );

    if (stackKpis) {
      return Column(
        children: [
          taxableCard,
          const SizedBox(height: 16),
          usCard,
          const SizedBox(height: 16),
          mxCard,
        ],
      );
    }
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(child: taxableCard),
          const SizedBox(width: 24),
          Expanded(child: usCard),
          const SizedBox(width: 24),
          Expanded(child: mxCard),
        ],
      ),
    );
  }

  Widget _kpiCard({
    required String label,
    required double value,
    Color? valueColor,
    required Widget child,
  }) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: TextStyle(color: context.textMuted)),
            const SizedBox(height: 8),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(
                widget.currencyFormat.format(value),
                style: brandDisplayStyle(
                  fontSize: 28,
                  color: valueColor ?? context.textPrimary,
                ),
              ),
            ),
            child,
          ],
        ),
      ),
    );
  }

  Widget _roughEstimateBadge(AppLocalizations l) {
    return Tooltip(
      message: l.taxRoughEstimateTooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: context.warning.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.help_outline, size: 12, color: context.warning),
            const SizedBox(width: 4),
            Text(
              l.taxRoughEstimateBadge,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: context.warning,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScenariosNote(AppLocalizations l) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.info_outline, size: 13, color: context.textSubtle),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            l.taxScenariosNote,
            style: TextStyle(fontSize: 11, color: context.textSubtle),
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }

  Widget _buildConstantsUnverifiedCaption(AppLocalizations l) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.warning_amber_rounded, size: 13, color: context.warning),
        const SizedBox(width: 4),
        Text(
          l.taxConstantsUnverified,
          style: TextStyle(fontSize: 11, color: context.warning),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Assumptions (readable size, expandable — not the 10px disclaimer footer)
  // ---------------------------------------------------------------------------

  Widget _buildAssumptions(
    AppLocalizations l, {
    required int bracketYearUsed,
    required int holdingsWithoutBasis,
  }) {
    final items = <String>[
      l.taxAssumptionBracketYear(bracketYearUsed.toString()),
      l.taxAssumptionFx,
      l.taxAssumptionFilingStatus(_filingStatusLabel(l, _filingStatus)),
      l.taxAssumptionExclusions,
      if (holdingsWithoutBasis > 0)
        l.taxAssumptionHoldingsNoBasis(holdingsWithoutBasis),
    ];

    return Card(
      color: context.tileSurface,
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Theme(
        // Strip the default ExpansionTile divider lines for a calmer card.
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          tilePadding: const EdgeInsets.symmetric(horizontal: 16),
          childrenPadding:
              const EdgeInsets.fromLTRB(16, 0, 16, 16),
          leading: Icon(Icons.tune, size: 18, color: context.textMuted),
          title: Text(
            l.taxAssumptionsTitle,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: context.textPrimary,
            ),
          ),
          children: [
            for (final item in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 5, right: 8),
                      child: Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          color: context.textFaint,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                    Expanded(
                      child: Text(
                        item,
                        style: TextStyle(
                            fontSize: 12, color: context.textMuted),
                      ),
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 4),
            Text(
              l.taxAssumptionProReview,
              style: TextStyle(
                fontSize: 11,
                color: context.textFaint,
                fontStyle: FontStyle.italic,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Realized gains section (T7)
  // ---------------------------------------------------------------------------

  Widget _buildRealizedGainsSection(AppLocalizations l) {
    final disposals = _taxDisposals ?? const [];
    final subtotals = gainsSubtotals(disposals);

    final taxable = <Map<String, dynamic>>[];
    final advantaged = <Map<String, dynamic>>[];
    for (final d in disposals) {
      if (d is! Map) continue;
      final m = Map<String, dynamic>.from(d);
      (m['tax_advantaged'] == true ? advantaged : taxable).add(m);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(l.taxRealizedGainsTitle),
        const SizedBox(height: 12),
        if (disposals.isEmpty)
          _emptyCard(l.taxNoDisposals, Icons.show_chart)
        else ...[
          Card(
            elevation: 4,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                for (var i = 0; i < taxable.length; i++) ...[
                  if (i > 0)
                    Divider(height: 1, color: context.tint(0.04), indent: 16),
                  _disposalRow(l, taxable[i]),
                ],
                if (taxable.isEmpty)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      l.taxNoDisposals,
                      style:
                          TextStyle(color: context.textFaint, fontSize: 12),
                    ),
                  ),
                Divider(height: 1, color: context.hairline),
                _subtotalRow(
                  l.taxGainsSubtotal(_signedMoney(subtotals.taxableGainUsd)),
                  l.taxSubtotalReconcileNote(l.taxTotalTaxableIncome),
                  _pnlColor(subtotals.taxableGainUsd),
                ),
              ],
            ),
          ),
          if (advantaged.isNotEmpty) ...[
            const SizedBox(height: 16),
            _advantagedCard(l, advantaged),
          ],
        ],
      ],
    );
  }

  Widget _disposalRow(AppLocalizations l, Map<String, dynamic> d) {
    final symbol = d['symbol']?.toString() ?? '';
    final name = d['name']?.toString() ?? '';
    final acquired = d['acquired_date']?.toString();
    final sell = d['sell_date']?.toString() ?? '';
    final gain = (d['gain_usd'] as num?)?.toDouble() ?? 0;
    final proceeds = (d['proceeds_usd'] as num?)?.toDouble() ?? 0;
    final cost = (d['cost_usd'] as num?)?.toDouble() ?? 0;
    final term = disposalTerm(d['long_term']);
    final washSale = d['wash_sale'] == true;
    final washSafeAfter = d['wash_sale_safe_after']?.toString();

    final acquiredLabel = (acquired == null || acquired.isEmpty)
        ? null
        : _fmtDate(acquired);
    final sellLabel = _fmtDate(sell);
    final dateLine = acquiredLabel == null
        ? '${l.taxAcquiredUnknown} → $sellLabel'
        : l.taxAcquiredToSold(acquiredLabel, sellLabel);

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        symbol.isNotEmpty ? symbol : name,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    _termChip(l, term),
                    if (washSale) ...[
                      const SizedBox(width: 6),
                      _washSaleMarker(l, washSafeAfter),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  dateLine,
                  style: TextStyle(color: context.textFaint, fontSize: 11),
                ),
                const SizedBox(height: 2),
                Text(
                  '${l.taxColProceeds} ${_money(proceeds)} · ${l.taxColCost} ${_money(cost)}',
                  style: TextStyle(color: context.textSubtle, fontSize: 11),
                ),
                if (washSale &&
                    washSafeAfter != null &&
                    washSafeAfter.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    l.taxWashSaleSafeAfter(_fmtDate(washSafeAfter)),
                    style: TextStyle(color: context.warning, fontSize: 11),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _signedMoney(gain),
            style: TextStyle(
              color: _pnlColor(gain),
              fontWeight: FontWeight.w700,
              fontSize: 14,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _advantagedCard(
      AppLocalizations l, List<Map<String, dynamic>> rows) {
    return Card(
      elevation: 0,
      color: context.tileSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(
              children: [
                Icon(Icons.lock_outline, size: 14, color: context.textMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l.taxTaxAdvantagedSection,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: context.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              l.taxTaxAdvantagedNote,
              style: TextStyle(fontSize: 11, color: context.textFaint),
            ),
          ),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Divider(height: 1, color: context.tint(0.04), indent: 16),
            _disposalRow(l, rows[i]),
          ],
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // T11 — Unrealized "what if I sell" + harvest candidates
  // ---------------------------------------------------------------------------

  Widget _buildUnrealizedSection(AppLocalizations l) {
    final data = _unrealized ?? const {};
    final lots = (data['lots'] as List<dynamic>?) ?? const [];
    final buckets = bucketUnrealizedLots(lots);
    final candidates = harvestCandidates(lots);
    final unverified = data['constants_verified'] == false;
    final stGain = (data['short_term_gain'] as num?)?.toDouble() ?? 0;
    final ltGain = (data['long_term_gain'] as num?)?.toDouble() ?? 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(l.taxUnrealizedTitle),
        const SizedBox(height: 12),
        if (lots.isEmpty)
          _emptyCard(l.taxNoUnrealizedLots, Icons.inventory_2_outlined)
        else ...[
          _unrealizedBucketCard(
            l,
            title: l.taxUnrealizedShortTerm,
            rows: buckets.shortTerm,
            subtotalUsd: stGain,
          ),
          if (buckets.longTerm.isNotEmpty) ...[
            const SizedBox(height: 16),
            _unrealizedBucketCard(
              l,
              title: l.taxUnrealizedLongTerm,
              rows: buckets.longTerm,
              subtotalUsd: ltGain,
            ),
          ],
          const SizedBox(height: 16),
          _harvestCard(l, candidates, unverified),
        ],
      ],
    );
  }

  Widget _unrealizedBucketCard(
    AppLocalizations l, {
    required String title,
    required List<Map<String, dynamic>> rows,
    required double subtotalUsd,
  }) {
    return Card(
      elevation: 4,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: context.textMuted,
              ),
            ),
          ),
          if (rows.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Text(
                l.taxNoUnrealizedLots,
                style: TextStyle(color: context.textFaint, fontSize: 12),
              ),
            )
          else
            for (var i = 0; i < rows.length; i++) ...[
              if (i > 0)
                Divider(height: 1, color: context.tint(0.04), indent: 16),
              _unrealizedRow(l, rows[i]),
            ],
          Divider(height: 1, color: context.hairline),
          _subtotalRow(
            l.taxUnrealizedSubtotal(_signedMoney(subtotalUsd)),
            title,
            _pnlColor(subtotalUsd),
          ),
        ],
      ),
    );
  }

  Widget _unrealizedRow(AppLocalizations l, Map<String, dynamic> lot) {
    final symbol = lot['symbol']?.toString() ?? '';
    final name = lot['name']?.toString() ?? '';
    final accountName = lot['account_name']?.toString() ?? '';
    final gain = (lot['unrealized_gain_usd'] as num?)?.toDouble() ?? 0;
    final basis = (lot['cost_basis_usd'] as num?)?.toDouble() ?? 0;
    final value = (lot['current_value_usd'] as num?)?.toDouble() ?? 0;
    final daysRaw = lot['days_until_long_term'];
    final near = isNearLongTerm(daysRaw);
    final flipDate = lot['long_term_date']?.toString();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  symbol.isNotEmpty ? symbol : name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                if (accountName.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    accountName,
                    style: TextStyle(color: context.textFaint, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  '${l.taxColBasis} ${_money(basis)} · ${l.taxColValue} ${_money(value)}',
                  style: TextStyle(color: context.textSubtle, fontSize: 11),
                ),
                if (near && (daysRaw is num)) ...[
                  const SizedBox(height: 4),
                  _nearLongTermChip(
                    l,
                    daysRaw.toInt(),
                    flipDate,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            _signedMoney(gain),
            style: TextStyle(
              color: _pnlColor(gain),
              fontWeight: FontWeight.w700,
              fontSize: 14,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _nearLongTermChip(AppLocalizations l, int days, String? flipDate) {
    final dateLabel = (flipDate == null || flipDate.isEmpty)
        ? ''
        : _fmtDate(flipDate);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: context.info.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.schedule, size: 11, color: context.info),
          const SizedBox(width: 4),
          Text(
            l.taxFlipsToLongIn(days.toString(), dateLabel),
            style: TextStyle(
              color: context.info,
              fontSize: 10,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  Widget _harvestCard(
    AppLocalizations l,
    List<Map<String, dynamic>> candidates,
    bool unverified,
  ) {
    return Card(
      elevation: 0,
      color: context.tileSurface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 4),
            child: Row(
              children: [
                Icon(Icons.content_cut, size: 14, color: context.textMuted),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l.taxHarvestTitle,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: context.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              l.taxHarvestNote,
              style: TextStyle(fontSize: 11, color: context.textFaint),
            ),
          ),
          if (candidates.isEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
              child: Text(
                l.taxNoHarvestCandidates,
                style: TextStyle(color: context.textSubtle, fontSize: 12),
              ),
            )
          else
            for (var i = 0; i < candidates.length; i++) ...[
              if (i > 0)
                Divider(height: 1, color: context.tint(0.04), indent: 16),
              _harvestRow(l, candidates[i], unverified),
            ],
        ],
      ),
    );
  }

  Widget _harvestRow(
      AppLocalizations l, Map<String, dynamic> lot, bool unverified) {
    final symbol = lot['symbol']?.toString() ?? '';
    final name = lot['name']?.toString() ?? '';
    final loss = (lot['unrealized_gain_usd'] as num?)?.toDouble() ?? 0;
    final savings =
        (lot['estimated_tax_savings_usd'] as num?)?.toDouble() ?? 0;
    final washRisk = lot['wash_sale_risk'] == true;
    final washSafeAfter = lot['wash_sale_safe_after']?.toString();

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  symbol.isNotEmpty ? symbol : name,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                // Loss is negative → renders red via _pnlColor.
                _signedMoney(loss),
                style: TextStyle(
                  color: _pnlColor(loss),
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Flexible(
                child: Text(
                  // The savings estimate is positive money; show it green.
                  l.taxHarvestEstimate(_money(savings)),
                  style: TextStyle(
                    color: context.positive,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 6),
              _estimateBadge(l, unverified),
            ],
          ),
          if (washRisk) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                _washSaleMarker(l, washSafeAfter),
                if (washSafeAfter != null && washSafeAfter.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  Flexible(
                    child: Text(
                      l.taxWashSaleSafeAfter(_fmtDate(washSafeAfter)),
                      style:
                          TextStyle(color: context.warning, fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// "Estimate" badge for harvest savings; carries the pending-verification
  /// tone (warning) when constants are unverified, otherwise a calm info tint.
  Widget _estimateBadge(AppLocalizations l, bool unverified) {
    final color = unverified ? context.warning : context.info;
    return Tooltip(
      message: l.taxHarvestEstimateTooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              unverified ? Icons.warning_amber_rounded : Icons.info_outline,
              size: 11,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              l.taxHarvestEstimateBadge,
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.bold,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // T13 — FBAR / foreign-account threshold monitor (informational)
  // ---------------------------------------------------------------------------

  Widget _buildFbarSection(AppLocalizations l) {
    final data = _fbar ?? const {};
    final peak = (data['peak_aggregate_usd'] as num?)?.toDouble() ?? 0;
    final threshold = (data['threshold_usd'] as num?)?.toDouble() ?? 0;
    final exceeded = data['exceeded'] == true;
    final unverified = data['constants_verified'] == false;
    final peakDate = data['peak_date']?.toString();
    final accounts = (data['foreign_accounts'] as List<dynamic>?) ?? const [];

    final statusColor = exceeded ? context.warning : context.positive;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(l.taxFbarTitle),
        const SizedBox(height: 12),
        Card(
          elevation: 4,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16)),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.taxFbarPeakAggregate,
                  style: TextStyle(color: context.textMuted, fontSize: 12),
                ),
                const SizedBox(height: 6),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    widget.currencyFormat
                        .format(peak * widget.conversionFactor),
                    style: brandDisplayStyle(
                      fontSize: 26,
                      color: statusColor,
                    ),
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Icon(
                      exceeded
                          ? Icons.flag_outlined
                          : Icons.check_circle_outline,
                      size: 14,
                      color: statusColor,
                    ),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        exceeded ? l.taxFbarExceeded : l.taxFbarUnder,
                        style: TextStyle(
                          color: statusColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        l.taxFbarThreshold(
                          widget.currencyFormat
                              .format(threshold * widget.conversionFactor),
                        ),
                        style: TextStyle(
                            color: context.textSubtle, fontSize: 11),
                      ),
                    ),
                    if (unverified) ...[
                      const SizedBox(width: 8),
                      Icon(Icons.warning_amber_rounded,
                          size: 12, color: context.warning),
                      const SizedBox(width: 2),
                      Text(
                        l.taxConstantsUnverified,
                        style:
                            TextStyle(color: context.warning, fontSize: 10),
                      ),
                    ],
                  ],
                ),
                if (peakDate != null && peakDate.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    l.taxFbarPeakDate(_fmtDate(peakDate)),
                    style: TextStyle(color: context.textFaint, fontSize: 11),
                  ),
                ],
                if (accounts.isEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    l.taxFbarNoForeignAccounts,
                    style: TextStyle(color: context.textFaint, fontSize: 11),
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  Divider(height: 1, color: context.hairline),
                  for (final a in accounts) _fbarAccountRow(l, a),
                ],
                const SizedBox(height: 12),
                Text(
                  l.taxFbarInformational,
                  style: TextStyle(
                    color: context.textFaint,
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  l.taxFbarFatcaNote,
                  style: TextStyle(
                    color: context.textFaint,
                    fontSize: 11,
                    fontStyle: FontStyle.italic,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _fbarAccountRow(AppLocalizations l, dynamic raw) {
    if (raw is! Map) return const SizedBox.shrink();
    final name = raw['name']?.toString() ?? '';
    final institution = raw['institution']?.toString() ?? '';
    final country = raw['country']?.toString();
    final currency = raw['currency']?.toString() ?? '';
    final peakContrib =
        (raw['peak_contribution_usd'] as num?)?.toDouble() ?? 0;
    final ytdMax = (raw['ytd_max_usd'] as num?)?.toDouble() ?? 0;

    final tags = <String>[
      if (institution.isNotEmpty) institution,
      if (country != null && country.isNotEmpty) country,
      if (currency.isNotEmpty) currency,
    ].join(' · ');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  name,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                if (tags.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    tags,
                    style: TextStyle(color: context.textFaint, fontSize: 11),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                l.taxFbarAccountYtdMax(_money(ytdMax)),
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 2),
              Text(
                l.taxFbarAccountPeak(_money(peakContrib)),
                style: TextStyle(color: context.textSubtle, fontSize: 11),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // T15 — Retirement contributions vs limits
  // ---------------------------------------------------------------------------

  Widget _buildRetirementSection(AppLocalizations l) {
    final data = _contributions ?? const {};
    final groups = (data['groups'] as List<dynamic>?) ?? const [];
    final unverified = data['constants_verified'] == false;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(l.taxRetirementTitle),
        const SizedBox(height: 12),
        if (groups.isEmpty)
          _emptyCard(l.taxNoRetirementAccounts, Icons.savings_outlined)
        else
          Card(
            elevation: 4,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                for (var i = 0; i < groups.length; i++) ...[
                  if (i > 0)
                    Divider(height: 1, color: context.hairline),
                  _contributionRow(l, groups[i], unverified),
                ],
              ],
            ),
          ),
      ],
    );
  }

  Widget _contributionRow(
      AppLocalizations l, dynamic raw, bool unverified) {
    if (raw is! Map) return const SizedBox.shrink();
    final groupKey = raw['group']?.toString() ?? '';
    final ytd = (raw['ytd_contributions_usd'] as num?)?.toDouble() ?? 0;
    final baseLimit = (raw['limit_base_usd'] as num?)?.toDouble() ?? 0;
    final catchUp = (raw['catch_up_usd'] as num?)?.toDouble() ?? 0;
    final remainingApi = (raw['remaining_room_usd'] as num?)?.toDouble();
    final deadline = raw['deadline']?.toString();
    final priorYearWindow = raw['prior_year_window'] == true;
    final matchCaveat = raw['match_rollover_caveat'] == true;

    final progress = contributionProgress(
      ytd: ytd,
      baseLimit: baseLimit,
      remainingRoomFromApi: remainingApi,
    );
    final barColor = progress.over ? context.warning : context.positive;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _retirementGroupLabel(l, groupKey),
                  style: TextStyle(
                    color: context.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 14,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                l.taxContributedOfLimit(_money(ytd), _money(baseLimit)),
                style: TextStyle(
                  color: context.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          // Progress bar reads in both themes: a tinted track + a solid fill.
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: progress.fraction,
              minHeight: 8,
              backgroundColor: context.tint(0.08),
              valueColor: AlwaysStoppedAnimation<Color>(barColor),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: Text(
                  progress.over
                      ? l.taxContributionOverLimit
                      : l.taxRemainingRoom(_money(progress.remainingRoom)),
                  style: TextStyle(
                    color: progress.over ? context.warning : context.positive,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (catchUp > 0)
                Flexible(
                  child: Text(
                    l.taxCatchUpNote(_money(catchUp)),
                    style:
                        TextStyle(color: context.textFaint, fontSize: 11),
                    textAlign: TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
          if (deadline != null && deadline.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              l.taxContributionDeadline(_fmtDate(deadline)),
              style: TextStyle(color: context.textSubtle, fontSize: 11),
            ),
          ],
          if (priorYearWindow) ...[
            const SizedBox(height: 4),
            Text(
              l.taxPriorYearWindowNote,
              style: TextStyle(color: context.textFaint, fontSize: 11),
            ),
          ],
          if (matchCaveat) ...[
            const SizedBox(height: 4),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 12, color: context.textFaint),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(
                    l.taxMatchRolloverCaveat,
                    style:
                        TextStyle(color: context.textFaint, fontSize: 11),
                  ),
                ),
              ],
            ),
          ],
          if (unverified) ...[
            const SizedBox(height: 6),
            Row(
              children: [
                Icon(Icons.warning_amber_rounded,
                    size: 12, color: context.warning),
                const SizedBox(width: 4),
                Text(
                  l.taxConstantsUnverified,
                  style: TextStyle(color: context.warning, fontSize: 10),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  String _retirementGroupLabel(AppLocalizations l, String key) {
    switch (key) {
      case '401k':
        return l.taxRetirementGroup401k;
      case 'ira':
        return l.taxRetirementGroupIra;
      case 'hsa':
        return l.taxRetirementGroupHsa;
      default:
        return key;
    }
  }

  // ---------------------------------------------------------------------------
  // Income section (T7) — the former "Taxable events" list, now with a
  // reconciling subtotal.
  // ---------------------------------------------------------------------------

  Widget _buildIncomeSection(AppLocalizations l) {
    final txns = _taxTransactions ?? const [];
    final subtotalUsd = sumIncomeUsd(txns);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionTitle(l.taxIncomeSectionTitle),
        const SizedBox(height: 12),
        if (txns.isEmpty)
          _emptyIncomeCard(l)
        else
          Card(
            elevation: 4,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16)),
            child: Column(
              children: [
                for (var i = 0; i < txns.length; i++) ...[
                  if (i > 0)
                    Divider(height: 1, color: context.tint(0.04), indent: 56),
                  _buildTaxRow(l, txns[i]),
                ],
                Divider(height: 1, color: context.hairline),
                _subtotalRow(
                  l.taxIncomeSubtotal(_money(subtotalUsd)),
                  l.taxSubtotalReconcileNote(l.taxTotalTaxableIncome),
                  context.positive,
                ),
              ],
            ),
          ),
      ],
    );
  }

  // Dense income-event row (mirrors the transactions tab visual language).
  Widget _buildTaxRow(AppLocalizations l, dynamic tx) {
    final date = DateTime.tryParse(tx['date']?.toString() ?? '');
    final sourceAmount = ((tx['amount'] as num?)?.toDouble() ?? 0.0);
    final sourceCurrency =
        (tx['currency'] ?? widget.targetCurrency).toString();
    final amountUsd = (tx['amount_usd'] as num?)?.toDouble();
    final converted = amountUsd != null
        ? amountUsd * widget.conversionFactor
        : convertCurrency(
            sourceAmount,
            from: sourceCurrency,
            to: widget.targetCurrency,
            usdMxnRate: widget.usdMxnRate,
          );
    final effectiveCategory =
        ((tx['user_category'] ?? tx['category']) ?? '').toString().toUpperCase();
    final isIncome =
        effectiveCategory == 'INCOME' || effectiveCategory.startsWith('INCOME_');
    final iconColor = isIncome ? context.tealAccent : context.purpleAccent;
    final needsConversion = sourceCurrency != widget.targetCurrency;

    return Padding(
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
                  date == null
                      ? (tx['category']?.toString() ?? '')
                      : '${DateFormat('MMM d, y').format(date)} · ${tx['category']}',
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
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Shared small widgets
  // ---------------------------------------------------------------------------

  Widget _sectionTitle(String text) => Text(
        text,
        style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
      );

  Widget _subtotalRow(String text, String reconcileNote, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
      child: Row(
        children: [
          Expanded(
            child: Text(
              reconcileNote,
              style: TextStyle(fontSize: 11, color: context.textFaint),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            text,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: color,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _termChip(AppLocalizations l, DisposalTerm term) {
    final (label, color) = switch (term) {
      DisposalTerm.longTerm => (l.taxTermLong, context.info),
      DisposalTerm.shortTerm => (l.taxTermShort, context.warning),
      DisposalTerm.unknown => (l.taxTermUnknown, context.neutralAccent),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color, fontSize: 10, fontWeight: FontWeight.bold),
      ),
    );
  }

  /// Small "wash sale" marker (T12) for a flagged disposal/harvest row. The
  /// tooltip carries the safe-after date when present so the chip stays compact.
  Widget _washSaleMarker(AppLocalizations l, String? safeAfter) {
    final tip = (safeAfter == null || safeAfter.isEmpty)
        ? l.taxWashSaleTooltip
        : '${l.taxWashSaleTooltip} ${l.taxWashSaleSafeAfter(_fmtDate(safeAfter))}';
    return Tooltip(
      message: tip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: context.warning.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.warning_amber_rounded, size: 11, color: context.warning),
            const SizedBox(width: 4),
            Text(
              l.taxWashSaleMarker,
              style: TextStyle(
                color: context.warning,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyCard(String text, IconData icon) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 20, color: context.tint(0.2)),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  style: TextStyle(color: context.textSubtle, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _emptyIncomeCard(AppLocalizations l) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
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
      ),
    );
  }

  String _fmtDate(String iso) {
    final d = DateTime.tryParse(iso);
    return d == null ? iso : DateFormat.yMMMd().format(d);
  }
}

/// Layout-true skeleton: a title bar, a 3-up KPI strip, and two list cards,
/// so the page doesn't reflow once the real data lands.
class _TaxSkeleton extends StatelessWidget {
  const _TaxSkeleton();

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, c) {
        final stackKpis = c.maxWidth < 520;
        final kpi = stackKpis
            ? Column(
                children: const [
                  SkeletonBox(height: 150),
                  SizedBox(height: 16),
                  SkeletonBox(height: 150),
                  SizedBox(height: 16),
                  SkeletonBox(height: 150),
                ],
              )
            : Row(
                children: const [
                  Expanded(child: SkeletonBox(height: 150)),
                  SizedBox(width: 24),
                  Expanded(child: SkeletonBox(height: 150)),
                  SizedBox(width: 24),
                  Expanded(child: SkeletonBox(height: 150)),
                ],
              );

        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: const [
                  SkeletonBox(width: 160, height: 24),
                  SkeletonBox(width: 220, height: 36),
                ],
              ),
              const SizedBox(height: 24),
              kpi,
              const SizedBox(height: 24),
              const SkeletonBox(height: 56),
              const SizedBox(height: 24),
              const SkeletonBox(width: 160, height: 20),
              const SizedBox(height: 12),
              const SkeletonBox(height: 200),
              // T11 unrealized + harvest
              const SizedBox(height: 24),
              const SkeletonBox(width: 220, height: 20),
              const SizedBox(height: 12),
              const SkeletonBox(height: 180),
              // T13 FBAR
              const SizedBox(height: 24),
              const SkeletonBox(width: 200, height: 20),
              const SizedBox(height: 12),
              const SkeletonBox(height: 160),
              // T15 retirement
              const SizedBox(height: 24),
              const SkeletonBox(width: 180, height: 20),
              const SizedBox(height: 12),
              const SkeletonBox(height: 180),
              // Income
              const SizedBox(height: 24),
              const SkeletonBox(width: 120, height: 20),
              const SizedBox(height: 12),
              const SkeletonBox(height: 160),
            ],
          ),
        );
      },
    );
  }
}
