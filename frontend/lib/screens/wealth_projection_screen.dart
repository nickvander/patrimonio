import 'package:flutter/material.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:intl/intl.dart';
import '../services/api_service.dart';

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

  @override
  void initState() {
    super.initState();
    // Default monthly contribution to something reasonable (e.g. 10% of start balance or $1000)
    _monthlyContribution = 1000.0;
    _fetchProjection();
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildHeader(),
        const SizedBox(height: 24),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left side: Controls
              SizedBox(width: 320, child: _buildControls()),
              const SizedBox(width: 24),
              // Right side: Chart and Milestones
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
  }

  Widget _buildHeader() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Wealth Projection',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Project your financial future based on current assets and savings strategy.',
          style: TextStyle(fontSize: 16, color: Colors.white70),
        ),
      ],
    );
  }

  Widget _buildControls() {
    return Card(
      color: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(20.0),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _buildSliderControl(
                label: 'Monthly Savings',
                value: _monthlyContribution,
                min: 0,
                max: 10000,
                prefix: widget.currencyFormat.currencySymbol,
                onChanged: (val) => setState(() => _monthlyContribution = val),
                onChangeEnd: (_) => _fetchProjection(),
              ),
              const Divider(height: 32, color: Colors.white10),
              _buildSliderControl(
                label: 'Expected Return',
                value: _annualReturnRate,
                min: 0,
                max: 0.15,
                isPercent: true,
                onChanged: (val) => setState(() => _annualReturnRate = val),
                onChangeEnd: (_) => _fetchProjection(),
              ),
              const Divider(height: 32, color: Colors.white10),
              _buildSliderControl(
                label: 'Annual Expenses',
                value: _annualExpenses,
                min: 10000,
                max: 200000,
                prefix: widget.currencyFormat.currencySymbol,
                onChanged: (val) => setState(() => _annualExpenses = val),
                onChangeEnd: (_) => _fetchProjection(),
              ),
              const Divider(height: 32, color: Colors.white10),
              _buildSliderControl(
                label: 'Safe Withdrawal Rate',
                value: _withdrawalRate,
                min: 0.02,
                max: 0.06,
                isPercent: true,
                onChanged: (val) => setState(() => _withdrawalRate = val),
                onChangeEnd: (_) => _fetchProjection(),
              ),
              const Divider(height: 32, color: Colors.white10),
              _buildSliderControl(
                label: 'Projection Years',
                value: _projectionYears.toDouble(),
                min: 5,
                max: 50,
                divisions: 9,
                onChanged: (val) =>
                    setState(() => _projectionYears = val.toInt()),
                onChangeEnd: (_) => _fetchProjection(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSliderControl({
    required String label,
    required double value,
    required double min,
    required double max,
    String? prefix,
    bool isPercent = false,
    int? divisions,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    String displayValue = isPercent
        ? '${(value * 100).toStringAsFixed(1)}%'
        : '${prefix ?? ""}${value.toInt().toString()}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),
            Text(
              displayValue,
              style: const TextStyle(
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
          inactiveColor: Colors.white10,
          onChanged: onChanged,
          onChangeEnd: onChangeEnd,
        ),
      ],
    );
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
                  const Text(
                    'Net Worth Projection',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 24),
                  Expanded(child: _buildChart()),
                ],
              ),
      ),
    );
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

    return LineChart(
      LineChartData(
        gridData: FlGridData(
          show: true,
          drawVerticalLine: false,
          getDrawingHorizontalLine: (value) =>
              FlLine(color: Colors.white10, strokeWidth: 1),
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
                  style: const TextStyle(color: Colors.white54, fontSize: 12),
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
                  style: const TextStyle(color: Colors.white54, fontSize: 10),
                );
              },
            ),
          ),
        ),
        borderData: FlBorderData(show: false),
        lineBarsData: [
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
        ],
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => const Color(0xFF2C2C2C),
            getTooltipItems: (touchedSpots) {
              return touchedSpots.map((spot) {
                return LineTooltipItem(
                  'Year ${spot.x.toStringAsFixed(1)}\n${widget.currencyFormat.format(spot.y)}',
                  const TextStyle(
                    color: Colors.white,
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
          title: 'FI Number',
          value: widget.currencyFormat.format(
            (metrics['fi_number'] as num).toDouble() * widget.conversionFactor,
          ),
          subtitle: 'Target Net Worth',
          icon: Icons.flag_rounded,
          color: Colors.orangeAccent,
        ),
        const SizedBox(width: 16),
        _buildMilestoneCard(
          title: 'Progress',
          value:
              '${(metrics['current_progress_pct'] as num).toStringAsFixed(1)}%',
          subtitle: 'Towards FIRE',
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
          title: 'FI Income',
          value: widget.currencyFormat.format(
            (metrics['monthly_income_at_retirement'] as num).toDouble() *
                widget.conversionFactor,
          ),
          subtitle: 'Monthly @ Withdrawal Rate',
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
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(height: 4),
              Text(
                value,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                subtitle,
                style: TextStyle(color: Colors.white38, fontSize: 10),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
