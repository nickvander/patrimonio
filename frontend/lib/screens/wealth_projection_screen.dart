import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../services/preferences.dart';
import '../l10n/app_localizations.dart';

class WealthProjectionScreen extends StatefulWidget {
  final double currentNetWorth;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  const WealthProjectionScreen({
    super.key,
    required this.currentNetWorth,
    required this.conversionFactor,
    required this.currencyFormat,
  });

  @override
  State<WealthProjectionScreen> createState() => _WealthProjectionScreenState();
}

class _WealthProjectionScreenState extends State<WealthProjectionScreen> {
  final ApiService _apiService = ApiService();

  // Projection parameters. All money values are USD internally (the backend
  // works in USD and we convert for display); the backend then deflates the
  // nominal return by inflation so every output is in today's real dollars.
  late double _monthlyContribution;
  double _annualReturnRate = 0.07; // nominal
  double _annualInflation = 0.03;
  double _annualExpenses = 40000.0;
  double _withdrawalRate = 0.04;
  double _returnVolatility = 0.13;
  double _baristaMonthlyIncome = 0.0;
  double _annualTaxDrag = 0.0;
  bool _withdrawalGuardrails = false;
  int _yearsToRetirement = 20;
  int _projectionYears = 30;

  bool _isLoading = true;
  // True once we've prefilled the contribution/expenses from the user's own
  // tracked cash flow — drives the "from your data" hint chips.
  bool _prefilledFromData = false;
  Map<String, dynamic>? _projectionData;

  // Optional user-set goal: "Hit $X by year Y". Stored in USD because the
  // chart and projection points are both USD-native; we convert for
  // display only. null on either field means "no goal yet".
  double? _goalAmountUsd;
  int? _goalYear;

  // Toggles the Monte Carlo uncertainty band (10–90th / 25–75th percentile
  // fan) around the expected line.
  bool _showBand = true;

  @override
  void initState() {
    super.initState();
    _monthlyContribution = 1000.0;
    _goalAmountUsd = Preferences.getGoalAmountUsd();
    _goalYear = Preferences.getGoalYear();
    _hydrateGoalFromBackend();
    _prefillFromTrackedData();
  }

  Future<void> _hydrateGoalFromBackend() async {
    try {
      final raw = await _apiService.getSetting('net_worth_goal');
      if (!mounted || raw is! Map) return;
      final amt = raw['amount_usd'];
      final yr = raw['year'];
      final amtD = amt is num ? amt.toDouble() : double.tryParse('$amt');
      final yrI = yr is int ? yr : int.tryParse('$yr');
      if (amtD == null || yrI == null) return;
      setState(() {
        _goalAmountUsd = amtD;
        _goalYear = yrI;
      });
      Preferences.setGoalAmountUsd(amtD);
      Preferences.setGoalYear(yrI);
    } catch (_) {
      // Silent fallback to the localStorage seed loaded in initState.
    }
  }

  // Patrimonio's edge over a generic calculator: prefill the contribution and
  // retirement-spend from the user's actual tracked income/spending. Best
  // effort — falls back to the static defaults, then always runs a projection.
  Future<void> _prefillFromTrackedData() async {
    try {
      final defaults = await _apiService.getProjectionDefaults();
      if (mounted && defaults != null) {
        final contrib = (defaults['monthly_contribution'] as num?)?.toDouble();
        final expenses = (defaults['annual_expenses'] as num?)?.toDouble();
        final months = (defaults['months_of_data'] as num?)?.toInt() ?? 0;
        // Only adopt the data when it's meaningful (some history + nonzero
        // spend), so a brand-new account keeps the sensible static defaults.
        if (months >= 1 && expenses != null && expenses > 0) {
          setState(() {
            if (contrib != null && contrib > 0) {
              _monthlyContribution = contrib.clamp(0, 10000);
            }
            _annualExpenses = expenses.clamp(10000, 200000);
            _prefilledFromData = true;
          });
        }
      }
    } catch (_) {
      // ignore; static defaults stand
    }
    await _fetchProjection();
  }

  Future<void> _fetchProjection() async {
    setState(() => _isLoading = true);
    try {
      final data = await _apiService.getWealthProjection(
        startBalance:
            widget.currentNetWorth / widget.conversionFactor, // USD to backend
        monthlyContribution: _monthlyContribution,
        annualReturnRate: _annualReturnRate,
        annualExpenses: _annualExpenses,
        withdrawalRate: _withdrawalRate,
        years: _projectionYears,
        annualInflationRate: _annualInflation,
        returnVolatility: _returnVolatility,
        yearsToRetirement: _yearsToRetirement.clamp(0, _projectionYears),
        baristaMonthlyIncome: _baristaMonthlyIncome,
        annualTaxDrag: _annualTaxDrag,
        withdrawalGuardrails: _withdrawalGuardrails,
      );
      setState(() {
        _projectionData = data;
        _isLoading = false;
      });
    } catch (e) {
      debugPrint("Error fetching projection: $e");
      setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final isNarrow = constraints.maxWidth < 800;
      if (isNarrow) {
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 24),
              _buildControls(scrollable: false),
              const SizedBox(height: 24),
              SizedBox(height: 320, child: _buildChartCard()),
              const SizedBox(height: 16),
              _buildFireStatusStrip(),
              const SizedBox(height: 16),
              SizedBox(height: 140, child: _buildMilestonesRow()),
            ],
          ),
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildHeader(),
          const SizedBox(height: 24),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 320, child: _buildControls()),
                const SizedBox(width: 24),
                Expanded(
                  child: Column(
                    children: [
                      Expanded(flex: 3, child: _buildChartCard()),
                      const SizedBox(height: 16),
                      _buildFireStatusStrip(),
                      const SizedBox(height: 16),
                      Expanded(flex: 1, child: _buildMilestonesRow()),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    });
  }

  Widget _buildHeader() {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              l.projTitle,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: context.textPrimary,
              ),
            ),
            const SizedBox(width: 12),
            // Real-dollars badge: the whole model is in today's purchasing
            // power, which is the honest way to read a 30-year chart.
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: context.info.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                l.projRealNote,
                style: TextStyle(
                    color: context.info,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          l.projSubtitle,
          style: TextStyle(fontSize: 16, color: context.textMuted),
        ),
      ],
    );
  }

  Widget _buildControls({bool scrollable = true}) {
    final l = AppLocalizations.of(context);
    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildSliderControl(
          label: l.projMonthlySavings,
          value: _monthlyContribution,
          min: 0,
          max: 10000,
          isCurrency: true,
          hint: _prefilledFromData ? l.projFromYourData : null,
          onChanged: (val) => setState(() => _monthlyContribution = val),
          onChangeEnd: (_) => _fetchProjection(),
        ),
        Divider(height: 32, color: context.hairline),
        _buildSliderControl(
          label: l.projExpectedReturnNominal,
          value: _annualReturnRate,
          min: 0,
          max: 0.15,
          isPercent: true,
          onChanged: (val) => setState(() => _annualReturnRate = val),
          onChangeEnd: (_) => _fetchProjection(),
        ),
        Divider(height: 32, color: context.hairline),
        _buildSliderControl(
          label: l.projInflation,
          value: _annualInflation,
          min: 0,
          max: 0.06,
          isPercent: true,
          onChanged: (val) => setState(() => _annualInflation = val),
          onChangeEnd: (_) => _fetchProjection(),
        ),
        Divider(height: 32, color: context.hairline),
        _buildSliderControl(
          label: l.projVolatility,
          value: _returnVolatility,
          min: 0,
          max: 0.25,
          isPercent: true,
          onChanged: (val) => setState(() => _returnVolatility = val),
          onChangeEnd: (_) => _fetchProjection(),
        ),
        Divider(height: 32, color: context.hairline),
        _buildSliderControl(
          label: l.projAnnualExpenses,
          value: _annualExpenses,
          min: 10000,
          max: 200000,
          isCurrency: true,
          hint: _prefilledFromData ? l.projFromYourData : null,
          onChanged: (val) => setState(() => _annualExpenses = val),
          onChangeEnd: (_) => _fetchProjection(),
        ),
        Divider(height: 32, color: context.hairline),
        _buildSliderControl(
          label: l.projSafeWithdrawalRate,
          value: _withdrawalRate,
          min: 0.02,
          max: 0.06,
          isPercent: true,
          onChanged: (val) => setState(() => _withdrawalRate = val),
          onChangeEnd: (_) => _fetchProjection(),
        ),
        Divider(height: 32, color: context.hairline),
        _buildSliderControl(
          label: l.projBaristaIncome,
          value: _baristaMonthlyIncome,
          min: 0,
          max: 10000,
          isCurrency: true,
          onChanged: (val) => setState(() => _baristaMonthlyIncome = val),
          onChangeEnd: (_) => _fetchProjection(),
        ),
        Divider(height: 32, color: context.hairline),
        _buildSliderControl(
          label: l.projTaxDrag,
          value: _annualTaxDrag,
          min: 0,
          max: 0.03,
          isPercent: true,
          onChanged: (val) => setState(() => _annualTaxDrag = val),
          onChangeEnd: (_) => _fetchProjection(),
        ),
        Divider(height: 32, color: context.hairline),
        _buildGuardrailsToggle(),
        Divider(height: 32, color: context.hairline),
        _buildSliderControl(
          label: l.projYearsToRetirement,
          value: _yearsToRetirement.toDouble().clamp(
                0,
                _projectionYears.toDouble(),
              ),
          min: 0,
          max: _projectionYears.toDouble(),
          divisions: _projectionYears,
          onChanged: (val) => setState(() => _yearsToRetirement = val.toInt()),
          onChangeEnd: (_) => _fetchProjection(),
        ),
        Divider(height: 32, color: context.hairline),
        _buildSliderControl(
          label: l.projProjectionYears,
          value: _projectionYears.toDouble(),
          min: 5,
          max: 50,
          divisions: 9,
          onChanged: (val) => setState(() {
            _projectionYears = val.toInt();
            if (_yearsToRetirement > _projectionYears) {
              _yearsToRetirement = _projectionYears;
            }
          }),
          onChangeEnd: (_) => _fetchProjection(),
        ),
        Divider(height: 32, color: context.hairline),
        _buildGoalEditor(),
      ],
    );
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: scrollable ? SingleChildScrollView(child: body) : body,
      ),
    );
  }

  Widget _buildSliderControl({
    required String label,
    required double value,
    required double min,
    required double max,
    bool isCurrency = false,
    bool isPercent = false,
    int? divisions,
    String? hint,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    String displayValue;
    if (isPercent) {
      displayValue = '${(value * 100).toStringAsFixed(1)}%';
    } else if (isCurrency) {
      final reported = value * widget.conversionFactor;
      displayValue = widget.currencyFormat.format(reported);
    } else {
      displayValue = value.toInt().toString();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(color: context.textMuted, fontSize: 14),
                  ),
                  if (hint != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        children: [
                          Icon(Icons.auto_awesome,
                              size: 11, color: context.info),
                          const SizedBox(width: 4),
                          Text(
                            hint,
                            style: TextStyle(
                                color: context.info,
                                fontSize: 11,
                                fontStyle: FontStyle.italic),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
            Text(
              displayValue,
              style: TextStyle(
                color: context.positive,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions ?? 100,
          activeColor: context.positive,
          inactiveColor: context.hairline,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }

  // Guyton-Klinger guardrails toggle: when on, the Monte Carlo flexes
  // retirement spending with the market, which lifts the success rate.
  Widget _buildGuardrailsToggle() {
    final l = AppLocalizations.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l.projGuardrails,
                style: TextStyle(color: context.textMuted, fontSize: 14),
              ),
              const SizedBox(height: 2),
              Text(
                _withdrawalGuardrails
                    ? l.projGuardrailsOn
                    : l.projGuardrailsOff,
                style: TextStyle(color: context.textFaint, fontSize: 11),
              ),
            ],
          ),
        ),
        Switch(
          value: _withdrawalGuardrails,
          activeThumbColor: context.positive,
          onChanged: (v) {
            setState(() => _withdrawalGuardrails = v);
            _fetchProjection();
          },
        ),
      ],
    );
  }

  // Goal editor — "Hit $X by year Y" form. Edits persist via Preferences so
  // the goal survives a refresh; clears reset both fields + remove the overlay.
  Widget _buildGoalEditor() {
    final l = AppLocalizations.of(context);
    final hasGoal = _goalAmountUsd != null && _goalYear != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.flag_outlined, color: context.yellowAccent, size: 18),
            const SizedBox(width: 8),
            Text(
              l.projGoal,
              style: TextStyle(
                color: context.textPrimary,
                fontWeight: FontWeight.w700,
              ),
            ),
            const Spacer(),
            if (hasGoal)
              TextButton(
                onPressed: () {
                  setState(() {
                    _goalAmountUsd = null;
                    _goalYear = null;
                  });
                  Preferences.setGoalAmountUsd(null);
                  Preferences.setGoalYear(null);
                  _apiService
                      .putSetting('net_worth_goal', null)
                      .catchError((_) {});
                },
                child: Text(l.projClear),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _editGoal,
          icon: const Icon(Icons.edit_outlined, size: 16),
          label: Text(
            hasGoal
                ? l.projGoalHitBy(
                    widget.currencyFormat
                        .format(_goalAmountUsd! * widget.conversionFactor),
                    _goalYear!,
                  )
                : l.projGoalSetTarget,
          ),
        ),
      ],
    );
  }

  Future<void> _editGoal() async {
    final amountCtrl = TextEditingController(
      text: _goalAmountUsd == null
          ? ''
          : (_goalAmountUsd! * widget.conversionFactor).toInt().toString(),
    );
    final nowYear = DateTime.now().year;
    final yearCtrl = TextEditingController(
      text: (_goalYear ?? nowYear + 10).toString(),
    );
    final l = AppLocalizations.of(context);
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(l.projSetTargetTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: amountCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: l.projTargetNetWorth,
                prefixText: widget.currencyFormat.currencySymbol,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: yearCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(labelText: l.projTargetYear),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(l.actionCancel)),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(l.actionSave)),
        ],
      ),
    );
    if (saved != true) return;
    final reported = double.tryParse(amountCtrl.text);
    final yr = int.tryParse(yearCtrl.text);
    if (reported == null || yr == null) return;
    final usd = widget.conversionFactor == 0
        ? reported
        : reported / widget.conversionFactor;
    setState(() {
      _goalAmountUsd = usd;
      _goalYear = yr;
    });
    Preferences.setGoalAmountUsd(usd);
    Preferences.setGoalYear(yr);
    _apiService.putSetting('net_worth_goal', {
      'amount_usd': usd,
      'year': yr,
    }).catchError((_) {});
  }

  Widget _buildChartCard() {
    final l = AppLocalizations.of(context);
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          l.projNetWorthProjection,
                          style: const TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ),
                      FilterChip(
                        label: Text(l.projRange),
                        selected: _showBand,
                        onSelected: (v) => setState(() => _showBand = v),
                        avatar: Icon(
                          _showBand ? Icons.area_chart : Icons.show_chart,
                          size: 16,
                        ),
                      ),
                    ],
                  ),
                  if (_showBand)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Row(
                        children: [
                          Container(
                            width: 12,
                            height: 12,
                            decoration: BoxDecoration(
                              color: context.positive.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(3),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            l.projBandLegend,
                            style: TextStyle(
                                color: context.textFaint, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 18),
                  Expanded(child: _buildChart()),
                ],
              ),
      ),
    );
  }

  // Convert a yearly Monte Carlo percentile series to chart spots (in the
  // active display currency).
  List<FlSpot> _percentileSpots(List<dynamic> pcts, String key) {
    return pcts.map((p) {
      final x = (p['year'] as num).toDouble();
      final y = (p[key] as num).toDouble() * widget.conversionFactor;
      return FlSpot(x, y);
    }).toList();
  }

  Widget _buildChart() {
    final l = AppLocalizations.of(context);
    if (_projectionData == null) return Container();

    final points = _projectionData!['points'] as List<dynamic>;
    final fiNumber =
        (_projectionData!['fire_metrics']['fi_number'] as num).toDouble();

    // Expected (deterministic, real-return) path — the bold headline line.
    final spots = points.map((p) {
      final x = (p['year'] as num).toDouble() +
          (p['month'] as num).toDouble() / 12.0;
      final y = (p['balance'] as num).toDouble() * widget.conversionFactor;
      return FlSpot(x, y);
    }).toList();

    // Monte Carlo percentile fan — the actual sequence-of-returns uncertainty.
    final mc = _projectionData!['monte_carlo'] as Map<String, dynamic>?;
    final pcts = (mc?['percentiles'] as List<dynamic>?) ?? const [];
    final hasBand = _showBand && pcts.length > 1;

    final p10 = hasBand ? _percentileSpots(pcts, 'p10') : <FlSpot>[];
    final p25 = hasBand ? _percentileSpots(pcts, 'p25') : <FlSpot>[];
    final p75 = hasBand ? _percentileSpots(pcts, 'p75') : <FlSpot>[];
    final p90 = hasBand ? _percentileSpots(pcts, 'p90') : <FlSpot>[];

    LineChartBarData faint(List<FlSpot> s) => LineChartBarData(
          spots: s,
          isCurved: true,
          color: context.positive.withValues(alpha: 0.0),
          barWidth: 0,
          dotData: const FlDotData(show: false),
        );

    // Band bars come first so the percentile fill sits behind the main line.
    final bandBars = hasBand
        ? <LineChartBarData>[faint(p10), faint(p90), faint(p25), faint(p75)]
        : <LineChartBarData>[];

    final betweenBars = hasBand
        ? <BetweenBarsData>[
            BetweenBarsData(
              fromIndex: 0,
              toIndex: 1,
              color: context.positive.withValues(alpha: 0.10),
            ),
            BetweenBarsData(
              fromIndex: 2,
              toIndex: 3,
              color: context.positive.withValues(alpha: 0.18),
            ),
          ]
        : <BetweenBarsData>[];

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (value) =>
              FlLine(color: context.hairline, strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          rightTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles:
              const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 5,
              getTitlesWidget: (value, meta) => Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  l.projYearAxisLabel(value.toInt()),
                  style: TextStyle(color: context.textSubtle, fontSize: 12),
                ),
              ),
            ),
          ),
          leftTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              reservedSize: 60,
              getTitlesWidget: (value, meta) {
                if (value == 0) return Container();
                if (value <= meta.min || value >= meta.max) {
                  return const SizedBox.shrink();
                }
                return Text(
                  NumberFormat.compact().format(value),
                  style: TextStyle(color: context.textSubtle, fontSize: 10),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        betweenBarsData: betweenBars,
        lineBarsData: [
          ...bandBars,
          // Expected path
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: context.positive,
            barWidth: 4,
            isStrokeCapRound: true,
            dotData: const FlDotData(show: false),
            belowBarData: BarAreaData(
              show: !hasBand,
              gradient: LinearGradient(
                colors: [
                  context.positive.withValues(alpha: 0.3),
                  context.positive.withValues(alpha: 0.0),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
          // FI target line
          LineChartBarData(
            spots: [
              FlSpot(0, fiNumber * widget.conversionFactor),
              FlSpot(_projectionYears.toDouble(),
                  fiNumber * widget.conversionFactor),
            ],
            isCurved: false,
            color: context.warning.withValues(alpha: 0.6),
            barWidth: 2,
            dashArray: [5, 5],
            dotData: const FlDotData(show: false),
          ),
          // User-set goal line
          if (_goalAmountUsd != null)
            LineChartBarData(
              spots: [
                FlSpot(0, _goalAmountUsd! * widget.conversionFactor),
                FlSpot(_projectionYears.toDouble(),
                    _goalAmountUsd! * widget.conversionFactor),
              ],
              isCurved: false,
              color: context.yellowAccent.withValues(alpha: 0.75),
              barWidth: 2,
              dashArray: [3, 6],
              dotData: const FlDotData(show: false),
            ),
        ],
        lineTouchData: LineTouchData(
          touchSpotThreshold: 100000,
          distanceCalculator: (touchPoint, spotPixelCoordinates) =>
              (touchPoint.dx - spotPixelCoordinates.dx).abs(),
          handleBuiltInTouches: true,
          getTouchedSpotIndicator: (barData, spotIndexes) {
            return spotIndexes.map((idx) {
              return TouchedSpotIndicatorData(
                FlLine(color: context.tint(0.35), strokeWidth: 1),
                FlDotData(
                  show: true,
                  getDotPainter: (spot, percent, bar, i) =>
                      FlDotCirclePainter(
                    radius: 5,
                    color: barData.color ?? context.positive,
                    strokeWidth: 3,
                    strokeColor: Theme.of(context).colorScheme.surface,
                  ),
                ),
              );
            }).toList();
          },
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => context.tooltipSurface,
            // Only the bold expected line carries a meaningful tooltip; the
            // invisible band bars would otherwise emit blank rows.
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((spot) {
                final isMain = spot.bar.barWidth >= 4;
                if (!isMain) return null;
                return LineTooltipItem(
                  l.projTooltipYearAmount(
                    spot.x.toStringAsFixed(1),
                    widget.currencyFormat.format(spot.y),
                  ),
                  TextStyle(
                    color: context.tooltipOnSurface,
                    fontWeight: FontWeight.bold,
                  ),
                );
              }).toList();
            },
          ),
        ),
      ),
    );
  }

  // Coast / Barista FIRE status strip — near-free given we know current
  // balance: tells the user today whether they can stop contributing.
  Widget _buildFireStatusStrip() {
    final l = AppLocalizations.of(context);
    if (_projectionData == null) return const SizedBox.shrink();
    final m = _projectionData!['fire_metrics'] as Map<String, dynamic>;
    final coastAchieved = m['coast_fi_achieved'] == true;
    final coastNumber =
        (m['coast_fi_number'] as num?)?.toDouble() ?? 0.0;
    final baristaNumber =
        (m['barista_fi_number'] as num?)?.toDouble() ?? 0.0;

    final coastColor = coastAchieved ? context.positive : context.info;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 16,
          runSpacing: 8,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  coastAchieved
                      ? Icons.check_circle_rounded
                      : Icons.trending_up_rounded,
                  color: coastColor,
                  size: 22,
                ),
                const SizedBox(width: 8),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      coastAchieved
                          ? l.projCoastReached
                          : l.projCoastNeed(widget.currencyFormat
                              .format(coastNumber * widget.conversionFactor)),
                      style: TextStyle(
                        color: context.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 13,
                      ),
                    ),
                    Text(
                      coastAchieved
                          ? l.projCoastReachedSub
                          : l.projCoastNeedSub,
                      style:
                          TextStyle(color: context.textFaint, fontSize: 11),
                    ),
                  ],
                ),
              ],
            ),
            if (baristaNumber > 0)
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.local_cafe_rounded,
                      color: context.purpleAccent, size: 20),
                  const SizedBox(width: 8),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l.projBaristaFi,
                        style: TextStyle(
                            color: context.textMuted, fontSize: 11),
                      ),
                      Text(
                        widget.currencyFormat.format(
                            baristaNumber * widget.conversionFactor),
                        style: TextStyle(
                            color: context.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 13),
                      ),
                    ],
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Color _successColor(double rate) {
    if (rate >= 0.85) return context.positive;
    if (rate >= 0.7) return context.warning;
    return context.negative;
  }

  Widget _buildMilestonesRow() {
    final l = AppLocalizations.of(context);
    if (_projectionData == null) return Container();
    final metrics = _projectionData!['fire_metrics'];
    final mc = _projectionData!['monte_carlo'] as Map<String, dynamic>?;
    final successRate = (mc?['success_rate'] as num?)?.toDouble() ?? 0.0;

    return Row(
      children: [
        _buildMilestoneCard(
          title: l.projSuccessRate,
          value: '${(successRate * 100).toStringAsFixed(0)}%',
          subtitle: l.projSuccessRateSub,
          icon: Icons.verified_rounded,
          color: _successColor(successRate),
        ),
        const SizedBox(width: 16),
        _buildMilestoneCard(
          title: l.projFiNumber,
          value: widget.currencyFormat.format(
            (metrics['fi_number'] as num).toDouble() * widget.conversionFactor,
          ),
          subtitle: l.projTargetNetWorth,
          icon: Icons.flag_rounded,
          color: context.warning,
        ),
        const SizedBox(width: 16),
        _buildMilestoneCard(
          title: l.projYearsToFi,
          value: metrics['estimated_years_to_fi'] != null
              ? (metrics['estimated_years_to_fi'] as num).toStringAsFixed(1)
              : '∞',
          subtitle: l.projEstimate,
          icon: Icons.speed_rounded,
          color: context.info,
        ),
        const SizedBox(width: 16),
        _buildMilestoneCard(
          title: l.projFiIncome,
          value: widget.currencyFormat.format(
            (metrics['monthly_income_at_retirement'] as num).toDouble() *
                widget.conversionFactor,
          ),
          subtitle: l.projMonthlyAtWithdrawalRate,
          icon: Icons.account_balance_wallet_rounded,
          color: context.purpleAccent,
        ),
      ],
    );
  }

  Widget _buildMilestoneCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
  }) {
    return Expanded(
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: 32),
              const SizedBox(height: 12),
              Text(
                title,
                style: TextStyle(color: context.textMuted, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: context.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(color: context.textFaint, fontSize: 10),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
