import 'package:flutter/material.dart';
import '../utils/theme_colors.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';
import '../services/preferences.dart';

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

  // Projection Parameters
  late double _monthlyContribution;
  double _annualReturnRate = 0.07;
  double _annualExpenses = 40000.0;
  double _withdrawalRate = 0.04;
  int _projectionYears = 30;

  bool _isLoading = true;
  Map<String, dynamic>? _projectionData;

  // Optional user-set goal: "Hit $X by year Y". Stored in USD because the
  // chart and projection points are both USD-native; we convert for
  // display only. null on either field means "no goal yet".
  double? _goalAmountUsd;
  int? _goalYear;

  // Toggles the secondary "aggressive" / "conservative" projection lines
  // around the base line. Variants are computed client-side from the
  // same compound-growth formula the backend uses for the base line.
  bool _showScenarios = false;

  @override
  void initState() {
    super.initState();
    // Default monthly contribution to something reasonable (e.g. 10% of start balance or $1000)
    _monthlyContribution = 1000.0;
    _goalAmountUsd = Preferences.getGoalAmountUsd();
    _goalYear = Preferences.getGoalYear();
    _fetchProjection();
    _hydrateGoalFromBackend();
  }

  Future<void> _hydrateGoalFromBackend() async {
    try {
      final raw = await _apiService.getSetting('net_worth_goal');
      if (!mounted || raw is! Map) return;
      final amt = raw['amount_usd'];
      final yr = raw['year'];
      final amtD =
          amt is num ? amt.toDouble() : double.tryParse('$amt');
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

  Future<void> _fetchProjection() async {
    setState(() => _isLoading = true);
    try {
      final data = await _apiService.getWealthProjection(
        startBalance:
            widget.currentNetWorth /
            widget.conversionFactor, // Always send USD to backend
        monthlyContribution: _monthlyContribution,
        annualReturnRate: _annualReturnRate,
        annualExpenses: _annualExpenses,
        withdrawalRate: _withdrawalRate,
        years: _projectionYears,
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
      // Below ~800px (tablet portrait and smaller) the 320px fixed sidebar
      // squeezes the chart unreadably. Stack the controls on top instead so
      // both panels get the full width on narrow viewports.
      final isNarrow = constraints.maxWidth < 800;
      if (isNarrow) {
        // Page-level scroll handles overflow; controls shrink-wrap their
        // intrinsic height (no inner SingleChildScrollView).
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildHeader(),
              const SizedBox(height: 24),
              _buildControls(scrollable: false),
              const SizedBox(height: 24),
              SizedBox(height: 320, child: _buildChartCard()),
              const SizedBox(height: 24),
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
                      const SizedBox(height: 24),
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Wealth projection',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: context.textPrimary,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Project your financial future based on current assets and savings strategy.',
          style: TextStyle(fontSize: 16, color: context.textMuted),
        ),
      ],
    );
  }

  Widget _buildControls({bool scrollable = true}) {
    final body = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSliderControl(
                label: 'Monthly savings',
                value: _monthlyContribution,
                min: 0,
                max: 10000,
                isCurrency: true,
                onChanged: (val) => setState(() => _monthlyContribution = val),
                onChangeEnd: (_) => _fetchProjection(),
              ),
              Divider(height: 32, color: context.hairline),
              _buildSliderControl(
                label: 'Expected return',
                value: _annualReturnRate,
                min: 0,
                max: 0.15,
                isPercent: true,
                onChanged: (val) => setState(() => _annualReturnRate = val),
                onChangeEnd: (_) => _fetchProjection(),
              ),
              Divider(height: 32, color: context.hairline),
              _buildSliderControl(
                label: 'Annual expenses',
                value: _annualExpenses,
                min: 10000,
                max: 200000,
                isCurrency: true,
                onChanged: (val) => setState(() => _annualExpenses = val),
                onChangeEnd: (_) => _fetchProjection(),
              ),
              Divider(height: 32, color: context.hairline),
              _buildSliderControl(
                label: 'Safe withdrawal rate',
                value: _withdrawalRate,
                min: 0.02,
                max: 0.06,
                isPercent: true,
                onChanged: (val) => setState(() => _withdrawalRate = val),
                onChangeEnd: (_) => _fetchProjection(),
              ),
              Divider(height: 32, color: context.hairline),
              _buildSliderControl(
                label: 'Projection years',
                value: _projectionYears.toDouble(),
                min: 5,
                max: 50,
                divisions: 9,
                onChanged: (val) =>
                    setState(() => _projectionYears = val.toInt()),
                onChangeEnd: (_) => _fetchProjection(),
              ),
              Divider(height: 32, color: context.hairline),
              _buildGoalEditor(),
            ],
          );
    return Card(
      color: const Color(0xFF1E1E1E),
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
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    // Internal values are kept in USD because the backend expects USD.
    // For display, we multiply by the active conversion factor and run
    // the value through the locale-aware currency formatter so MXN users
    // see "MXN 4,000,000" instead of the raw "USD 200000".
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
            Text(
              label,
              style: TextStyle(color: context.textMuted, fontSize: 14),
            ),
            Text(
              displayValue,
              style: TextStyle(
                color: Color(0xFF00E676),
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        Slider(
          value: value,
          min: min,
          max: max,
          divisions: divisions ?? 100,
          activeColor: const Color(0xFF00E676),
          inactiveColor: context.hairline,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
  }

  // Goal editor — "Hit $X by year Y" form. Edits are persisted via
  // Preferences so the goal survives a refresh. Clears reset both
  // fields and remove the chart overlay.
  Widget _buildGoalEditor() {
    final hasGoal = _goalAmountUsd != null && _goalYear != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.flag_outlined,
                color: Color(0xFFFFD600), size: 18),
            const SizedBox(width: 8),
            Text(
              'Goal',
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
                child: Text('Clear'),
              ),
          ],
        ),
        const SizedBox(height: 8),
        TextButton.icon(
          onPressed: _editGoal,
          icon: Icon(Icons.edit_outlined, size: 16),
          label: Text(
            hasGoal
                ? 'Hit ${widget.currencyFormat.format(_goalAmountUsd! * widget.conversionFactor)} by $_goalYear'
                : 'Set a target — e.g. \$1M by 2030',
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
    final saved = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('Set a target'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: amountCtrl,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: 'Target net worth',
                prefixText: widget.currencyFormat.currencySymbol,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: yearCtrl,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Target year'),
            ),
          ],
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text('Save')),
        ],
      ),
    );
    if (saved != true) return;
    final reported = double.tryParse(amountCtrl.text);
    final yr = int.tryParse(yearCtrl.text);
    if (reported == null || yr == null) return;
    // Convert reported-currency back to USD for storage.
    final usd = widget.conversionFactor == 0
        ? reported
        : reported / widget.conversionFactor;
    setState(() {
      _goalAmountUsd = usd;
      _goalYear = yr;
    });
    Preferences.setGoalAmountUsd(usd);
    Preferences.setGoalYear(yr);
    // Sync to backend so the goal survives a localStorage wipe and is
    // visible to other devices once multi-device support lands.
    _apiService.putSetting('net_worth_goal', {
      'amount_usd': usd,
      'year': yr,
    }).catchError((_) {});
  }

  Widget _buildChartCard() {
    return Card(
      color: const Color(0xFF1E1E1E),
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
                      const Expanded(
                        child: Text(
                          'Net worth projection',
                          style: TextStyle(
                              fontSize: 18, fontWeight: FontWeight.bold),
                        ),
                      ),
                      FilterChip(
                        label: Text('Scenarios'),
                        selected: _showScenarios,
                        onSelected: (v) =>
                            setState(() => _showScenarios = v),
                        avatar: Icon(
                          _showScenarios
                              ? Icons.layers
                              : Icons.layers_outlined,
                          size: 16,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  Expanded(child: _buildChart()),
                ],
              ),
      ),
    );
  }

  // Project compound growth for a scenario variant. Matches the backend's
  // formula closely enough for visual comparison — small differences in
  // contribution timing aren't visible at this chart resolution.
  List<FlSpot> _projectVariant({
    required double startBalanceUsd,
    required double monthlyContribUsd,
    required double annualReturn,
    required int years,
  }) {
    final monthlyRate = annualReturn / 12.0;
    var balance = startBalanceUsd;
    final spots = <FlSpot>[FlSpot(0, balance * widget.conversionFactor)];
    for (var month = 1; month <= years * 12; month++) {
      balance = balance * (1 + monthlyRate) + monthlyContribUsd;
      spots.add(FlSpot(
        month / 12.0,
        balance * widget.conversionFactor,
      ));
    }
    return spots;
  }

  Widget _buildChart() {
    if (_projectionData == null) return Container();

    final points = _projectionData!['points'] as List<dynamic>;
    final fiNumber = (_projectionData!['fire_metrics']['fi_number'] as num)
        .toDouble();

    final spots = points.map((p) {
      final x =
          (p['year'] as num).toDouble() + (p['month'] as num).toDouble() / 12.0;
      final y = (p['balance'] as num).toDouble() * widget.conversionFactor;
      return FlSpot(x, y);
    }).toList();

    // Scenario variants are derived client-side from the same start
    // balance + contribution. Aggressive bumps the annual return by 2pp
    // and contributions by 20%; conservative does the opposite.
    final startBalanceUsd = widget.currentNetWorth / widget.conversionFactor;
    final aggressive = _projectVariant(
      startBalanceUsd: startBalanceUsd,
      monthlyContribUsd: _monthlyContribution * 1.2,
      annualReturn: _annualReturnRate + 0.02,
      years: _projectionYears,
    );
    final conservative = _projectVariant(
      startBalanceUsd: startBalanceUsd,
      monthlyContribUsd: _monthlyContribution * 0.8,
      annualReturn: (_annualReturnRate - 0.02).clamp(0.0, 0.5),
      years: _projectionYears,
    );

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (value) =>
              FlLine(color: context.hairline, strokeWidth: 1),
        ),
        titlesData: FlTitlesData(
          rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 5,
              getTitlesWidget: (value, meta) => Padding(
                padding: const EdgeInsets.only(top: 8.0),
                child: Text(
                  'Yr ${value.toInt()}',
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
                return Text(
                  NumberFormat.compact().format(value),
                  style: TextStyle(color: context.textSubtle, fontSize: 10),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
          if (_showScenarios) ...[
            LineChartBarData(
              spots: aggressive,
              isCurved: true,
              color: const Color(0xFF1DE9B6).withValues(alpha: 0.8),
              barWidth: 2,
              dashArray: [4, 4],
              isStrokeCapRound: true,
              dotData: const FlDotData(show: false),
            ),
            LineChartBarData(
              spots: conservative,
              isCurved: true,
              color: const Color(0xFFFF4081).withValues(alpha: 0.8),
              barWidth: 2,
              dashArray: [4, 4],
              isStrokeCapRound: true,
              dotData: const FlDotData(show: false),
            ),
          ],
          LineChartBarData(
            spots: spots,
            isCurved: true,
            color: const Color(0xFF00E676),
            barWidth: 4,
            isStrokeCapRound: true,
            dotData: FlDotData(show: false),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF00E676).withValues(alpha: 0.3),
                  const Color(0xFF00E676).withValues(alpha: 0.0),
                ],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
            ),
          ),
          // FI Target Line
          LineChartBarData(
            spots: [
              FlSpot(0, fiNumber * widget.conversionFactor),
              FlSpot(
                _projectionYears.toDouble(),
                fiNumber * widget.conversionFactor,
              ),
            ],
            isCurved: false,
            color: Colors.orangeAccent.withValues(alpha: 0.5),
            barWidth: 2,
            dashArray: [5, 5],
            dotData: FlDotData(show: false),
          ),
          // User-set goal line — flat across the chart at the target
          // amount. Drawn in goal yellow so it's distinct from the
          // orange FI target line.
          if (_goalAmountUsd != null)
            LineChartBarData(
              spots: [
                FlSpot(0, _goalAmountUsd! * widget.conversionFactor),
                FlSpot(
                  _projectionYears.toDouble(),
                  _goalAmountUsd! * widget.conversionFactor,
                ),
              ],
              isCurved: false,
              color: const Color(0xFFFFD600).withValues(alpha: 0.7),
              barWidth: 2,
              dashArray: [3, 6],
              dotData: FlDotData(show: false),
            ),
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            // Inverse surface = dark popover in light mode, light popover
            // in dark mode (Material 3 tooltip convention). The text uses
            // onInverseSurface so contrast flips with the background.
            getTooltipColor: (_) =>
                Theme.of(context).colorScheme.inverseSurface,
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((spot) {
                return LineTooltipItem(
                  'Year ${spot.x.toStringAsFixed(1)}\n${widget.currencyFormat.format(spot.y)}',
                  TextStyle(
                    color: Theme.of(context).colorScheme.onInverseSurface,
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

  Widget _buildMilestonesRow() {
    if (_projectionData == null) return Container();
    final metrics = _projectionData!['fire_metrics'];

    return Row(
      children: [
        _buildMilestoneCard(
          title: 'FI number',
          value: widget.currencyFormat.format(
            (metrics['fi_number'] as num).toDouble() * widget.conversionFactor,
          ),
          subtitle: 'Target net worth',
          icon: Icons.flag_rounded,
          color: Colors.orangeAccent,
        ),
        const SizedBox(width: 16),
        _buildMilestoneCard(
          title: 'Progress',
          value:
              '${(metrics['current_progress_pct'] as num).toStringAsFixed(1)}%',
          subtitle: 'Toward FIRE',
          icon: Icons.trending_up_rounded,
          color: const Color(0xFF00E676),
        ),
        const SizedBox(width: 16),
        _buildMilestoneCard(
          title: 'Years to FI',
          value: metrics['estimated_years_to_fi'] != null
              ? (metrics['estimated_years_to_fi'] as num).toStringAsFixed(1)
              : '∞',
          subtitle: 'Estimate',
          icon: Icons.speed_rounded,
          color: Colors.lightBlueAccent,
        ),
        const SizedBox(width: 16),
        _buildMilestoneCard(
          title: 'FI income',
          value: widget.currencyFormat.format(
            (metrics['monthly_income_at_retirement'] as num).toDouble() *
                widget.conversionFactor,
          ),
          subtitle: 'Monthly @ withdrawal rate',
          icon: Icons.account_balance_wallet_rounded,
          color: Colors.purpleAccent,
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
        color: const Color(0xFF1E1E1E),
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
