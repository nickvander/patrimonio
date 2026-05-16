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
        const Text(
          'Wealth projection',
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
              const Divider(height: 32, color: Colors.white10),
              _buildSliderControl(
                label: 'Expected return',
                value: _annualReturnRate,
                min: 0,
                max: 0.15,
                isPercent: true,
                onChanged: (val) => setState(() => _annualReturnRate = val),
                onChangeEnd: (_) => _fetchProjection(),
              ),
              const Divider(height: 32, color: Colors.white10),
              _buildSliderControl(
                label: 'Annual expenses',
                value: _annualExpenses,
                min: 10000,
                max: 200000,
                isCurrency: true,
                onChanged: (val) => setState(() => _annualExpenses = val),
                onChangeEnd: (_) => _fetchProjection(),
              ),
              const Divider(height: 32, color: Colors.white10),
              _buildSliderControl(
                label: 'Safe withdrawal rate',
                value: _withdrawalRate,
                min: 0.02,
                max: 0.06,
                isPercent: true,
                onChanged: (val) => setState(() => _withdrawalRate = val),
                onChangeEnd: (_) => _fetchProjection(),
              ),
              const Divider(height: 32, color: Colors.white10),
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
                    'Net worth projection',
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
