import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/chart_time_axis.dart';
import '../utils/chart_touch.dart';
import '../utils/currency.dart';
import '../utils/fx_center.dart';
import '../utils/percent_format.dart';
import '../utils/theme_colors.dart';

/// Opens the FX center — the interactive panel behind the app-bar USD/MXN
/// pill — with the house bottom-sheet chrome (same presentation as the
/// dividend / interest-income drill-downs).
///
/// [onRateChanged] fires whenever the sheet force-refreshes the rate so
/// the dashboard can re-render every card off the fresh value without a
/// full reload.
Future<void> showFxCenterSheet(
  BuildContext context, {
  required ApiService apiService,
  required Map<String, dynamic> latestRate,
  ValueChanged<Map<String, dynamic>>? onRateChanged,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Theme.of(context).colorScheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => FxCenterSheet(
      apiService: apiService,
      latestRate: latestRate,
      onRateChanged: onRateChanged,
    ),
  );
}

/// The FX center sheet: 30/90-day sparkline of the USD/MXN rate, the
/// last-updated time as always-visible relative text, a linked USD↔MXN
/// mini converter, a manual refresh action, and the server-persisted
/// alert threshold ("notify me when the rate crosses X").
class FxCenterSheet extends StatefulWidget {
  final ApiService apiService;

  /// The `/fx/latest` payload the dashboard already holds — seeds the
  /// header instantly; the sheet never blocks on a rate fetch to open.
  final Map<String, dynamic> latestRate;
  final ValueChanged<Map<String, dynamic>>? onRateChanged;

  /// Test seams (precedent: [DividendDetailSheet.fetchOverride]) — widget
  /// tests can't subclass ApiService and must not hit the network.
  @visibleForTesting
  final Future<List<dynamic>> Function(int days)? fetchHistoryOverride;
  @visibleForTesting
  final Future<Map<String, dynamic>> Function()? refreshOverride;
  @visibleForTesting
  final Future<Map<String, dynamic>?> Function()? fetchAlertOverride;
  @visibleForTesting
  final Future<void> Function(double threshold)? saveAlertOverride;
  @visibleForTesting
  final Future<void> Function()? deleteAlertOverride;
  @visibleForTesting
  final Future<Map<String, dynamic>> Function()? fetchCostsOverride;

  const FxCenterSheet({
    super.key,
    required this.apiService,
    required this.latestRate,
    this.onRateChanged,
    this.fetchHistoryOverride,
    this.refreshOverride,
    this.fetchAlertOverride,
    this.saveAlertOverride,
    this.deleteAlertOverride,
    this.fetchCostsOverride,
  });

  @override
  State<FxCenterSheet> createState() => _FxCenterSheetState();
}

class _FxCenterSheetState extends State<FxCenterSheet> {
  late Map<String, dynamic> _rate = Map<String, dynamic>.from(
    widget.latestRate,
  );
  int _rangeDays = 30;
  List<({DateTime date, double close})> _history = const [];
  bool _historyLoading = true;
  bool _historyError = false;
  bool _refreshing = false;

  Map<String, dynamic>? _alert;
  bool _alertSaving = false;

  Map<String, dynamic>? _costs;
  bool _costsLoading = true;
  bool _costsError = false;

  final _baseCtl = TextEditingController(text: '1');
  final _targetCtl = TextEditingController();
  final _alertCtl = TextEditingController();

  String get _base => fxPairOf(_rate).base;
  String get _target => fxPairOf(_rate).target;
  double? get _rateValue {
    final r = (_rate['rate'] as num?)?.toDouble();
    return (r != null && r > 0) ? r : null;
  }

  @override
  void initState() {
    super.initState();
    _syncConverterFromBase();
    _loadHistory();
    _loadAlert();
    _loadCosts();
  }

  @override
  void dispose() {
    _baseCtl.dispose();
    _targetCtl.dispose();
    _alertCtl.dispose();
    super.dispose();
  }

  Future<void> _loadHistory() async {
    setState(() {
      _historyLoading = true;
      _historyError = false;
    });
    try {
      final raw = widget.fetchHistoryOverride != null
          ? await widget.fetchHistoryOverride!(_rangeDays)
          : await widget.apiService.getExchangeRateHistory(
              _base,
              _target,
              days: _rangeDays,
            );
      if (!mounted) return;
      // Null-aware element: malformed rows parse to null and drop out.
      final points = <({DateTime date, double close})>[
        for (final r in raw) ?fxHistoryPoint(r),
      ];
      setState(() {
        // Last close per calendar day, day-offset x: intraday fetch bursts
        // collapse to one point and data gaps keep their true width.
        _history = dedupeDailyCloses(points);
        _historyLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _historyLoading = false;
        _historyError = true;
      });
    }
  }

  Future<void> _loadAlert() async {
    try {
      final alert = widget.fetchAlertOverride != null
          ? await widget.fetchAlertOverride!()
          : await widget.apiService.getFxAlert(_base, _target);
      if (!mounted) return;
      setState(() {
        _alert = alert;
        final threshold = (alert?['threshold'] as num?)?.toDouble();
        if (threshold != null && _alertCtl.text.isEmpty) {
          _alertCtl.text = threshold.toStringAsFixed(2);
        }
      });
    } catch (_) {
      // Alert box stays editable with no "active" line; saving still works.
    }
  }

  /// Manual "refresh rate": server-forced fetch past the Redis cache, then
  /// re-pull the sparkline so it includes the fresh point, and notify the
  /// dashboard so every MXN-converted card re-renders.
  Future<void> _refresh() async {
    final l = AppLocalizations.of(context);
    setState(() => _refreshing = true);
    try {
      final fx = widget.refreshOverride != null
          ? await widget.refreshOverride!()
          : await widget.apiService.getExchangeRate(
              _base,
              _target,
              force: true,
            );
      if (!mounted) return;
      setState(() => _rate = fx);
      widget.onRateChanged?.call(fx);
      _syncConverterFromBase();
      await _loadHistory();
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.fxcRefreshFailed)));
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  /// Annual transfer-cost report — what moving money between the two
  /// currencies cost vs mid-market, per year and provider.
  Future<void> _loadCosts() async {
    try {
      final costs = widget.fetchCostsOverride != null
          ? await widget.fetchCostsOverride!()
          : await widget.apiService.getFxTransferCosts();
      if (!mounted) return;
      setState(() {
        _costs = costs;
        _costsLoading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _costsLoading = false;
        _costsError = true;
      });
    }
  }

  // ----- converter -----

  /// Recompute the target field from the base field (used on open and
  /// after a refresh changes the rate). Programmatic controller writes
  /// don't fire TextField.onChanged, so this can't loop.
  void _syncConverterFromBase() {
    final r = _rateValue;
    if (r == null) return;
    final out = linkedFxAmount(
      input: _baseCtl.text,
      rate: r,
      baseToTarget: true,
    );
    if (out != null) _targetCtl.text = out;
  }

  void _onBaseEdited(String v) {
    final r = _rateValue;
    if (r == null) return;
    final out = linkedFxAmount(input: v, rate: r, baseToTarget: true);
    if (out != null) _targetCtl.text = out;
  }

  void _onTargetEdited(String v) {
    final r = _rateValue;
    if (r == null) return;
    final out = linkedFxAmount(input: v, rate: r, baseToTarget: false);
    if (out != null) _baseCtl.text = out;
  }

  // ----- alert -----

  Future<void> _saveAlert() async {
    final l = AppLocalizations.of(context);
    final threshold = double.tryParse(_alertCtl.text.trim());
    if (threshold == null || threshold <= 0) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.fxcAlertInvalid)));
      return;
    }
    setState(() => _alertSaving = true);
    try {
      if (widget.saveAlertOverride != null) {
        await widget.saveAlertOverride!(threshold);
      } else {
        await widget.apiService.putFxAlert(
          base: _base,
          target: _target,
          threshold: threshold,
        );
      }
      if (!mounted) return;
      setState(() => _alert = {'threshold': threshold});
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.fxcAlertSaved)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.fxcAlertFailed)));
    } finally {
      if (mounted) setState(() => _alertSaving = false);
    }
  }

  Future<void> _clearAlert() async {
    final l = AppLocalizations.of(context);
    setState(() => _alertSaving = true);
    try {
      if (widget.deleteAlertOverride != null) {
        await widget.deleteAlertOverride!();
      } else {
        await widget.apiService.deleteFxAlert(_base, _target);
      }
      if (!mounted) return;
      setState(() {
        _alert = null;
        _alertCtl.clear();
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.fxcAlertCleared)));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.fxcAlertFailed)));
    } finally {
      if (mounted) setState(() => _alertSaving = false);
    }
  }

  // ----- build -----

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    final maxHeight = MediaQuery.sizeOf(context).height * 0.9;
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _handle(),
            _header(l),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: LayoutBuilder(
                  builder: (ctx, outer) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _rateHeadline(l),
                        const SizedBox(height: 16),
                        _rangeToggle(l),
                        const SizedBox(height: 12),
                        _sparkline(l, outer.maxWidth),
                        const SizedBox(height: 24),
                        _sectionTitle(l.fxcConverterTitle),
                        const SizedBox(height: 12),
                        _converter(),
                        const SizedBox(height: 24),
                        _sectionTitle(l.fxcAlertTitle),
                        const SizedBox(height: 8),
                        _alertSection(l),
                        const SizedBox(height: 24),
                        _sectionTitle(l.fxcCostsTitle),
                        const SizedBox(height: 8),
                        _costsSection(l),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _handle() => Container(
    width: 40,
    height: 4,
    margin: const EdgeInsets.only(top: 12, bottom: 4),
    decoration: BoxDecoration(
      color: context.hairline,
      borderRadius: BorderRadius.circular(2),
    ),
  );

  Widget _header(AppLocalizations l) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 12, 4),
      child: Row(
        children: [
          Icon(Icons.currency_exchange, color: context.tealAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l.lwFxExchangeRate,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: context.textPrimary,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Manual "refresh rate" — server-forced, past the Redis cache.
          IconButton(
            icon: _refreshing
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation(context.tealAccent),
                    ),
                  )
                : const Icon(Icons.refresh),
            tooltip: l.lwFxRefreshNow,
            onPressed: _refreshing ? null : _refresh,
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: l.actionClose,
            onPressed: () => Navigator.of(context).maybePop(),
          ),
        ],
      ),
    );
  }

  Widget _rateHeadline(AppLocalizations l) {
    final rate = _rateValue;
    // Money-coded rate via the currency helper ("MXN 17.58") — never a
    // hand-built money string.
    final equation = rate == null
        ? l.dashFxLoading
        : l.dashFxRateEquation(_base, formatCurrencyAmount(rate, _target));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$_base / $_target',
          style: TextStyle(color: context.textMuted, fontSize: 13),
        ),
        const SizedBox(height: 4),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(
            rate == null
                ? '—'
                : localizeNumberString(context, rate.toStringAsFixed(4)),
            style: TextStyle(
              fontSize: 30,
              fontWeight: FontWeight.bold,
              color: context.tealAccent,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
            maxLines: 1,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          equation,
          style: TextStyle(fontSize: 12, color: context.textSubtle),
        ),
        const SizedBox(height: 6),
        _updatedLine(l),
      ],
    );
  }

  /// The last-updated time as ALWAYS-VISIBLE relative text (spec point b —
  /// not hover-only), warning-colored when the rate is >24h stale.
  Widget _updatedLine(AppLocalizations l) {
    final recorded = DateTime.tryParse(
      (_rate['recorded_at'] ?? '').toString(),
    )?.toLocal();
    if (recorded == null) {
      return Text(
        l.lwFxUpdatedUnknown,
        style: TextStyle(fontSize: 12, color: context.textMuted),
      );
    }
    final diff = DateTime.now().difference(recorded);
    final isStale = diff.inHours > 24;
    final age = diff.inMinutes < 1
        ? l.lwFxUpdatedJustNow
        : diff.inHours < 1
        ? l.lwFxUpdatedMinutesAgo(diff.inMinutes)
        : diff.inHours < 24
        ? l.lwFxUpdatedHoursAgo(diff.inHours)
        : l.lwFxUpdatedDaysAgo(diff.inDays);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          isStale ? Icons.warning_amber_rounded : Icons.schedule,
          size: 14,
          color: isStale ? context.warning : context.textSubtle,
        ),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            isStale ? l.lwFxStalePrefix(age) : age,
            style: TextStyle(
              fontSize: 12,
              color: isStale ? context.warning : context.textMuted,
              fontWeight: isStale ? FontWeight.w600 : FontWeight.normal,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  /// 30/90-day range as an M3-Expressive-style connected pair of tonal
  /// segments (the phone-idiom pattern for tiny fixed option sets — the
  /// selected segment fills, unselected stays tonal; 2px gap).
  Widget _rangeToggle(AppLocalizations l) {
    Widget segment(int days, String label, BorderRadius radius) {
      final selected = _rangeDays == days;
      return Expanded(
        child: Semantics(
          button: true,
          selected: selected,
          child: InkWell(
            borderRadius: radius,
            onTap: _historyLoading || selected
                ? null
                : () {
                    setState(() => _rangeDays = days);
                    _loadHistory();
                  },
            child: Container(
              constraints: const BoxConstraints(minHeight: 40),
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected
                    ? Theme.of(context).colorScheme.secondaryContainer
                    : context.tint(0.06),
                borderRadius: radius,
              ),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected
                      ? Theme.of(context).colorScheme.onSecondaryContainer
                      : context.textMuted,
                ),
              ),
            ),
          ),
        ),
      );
    }

    return Row(
      children: [
        segment(
          30,
          l.fxcRange30d,
          const BorderRadius.horizontal(left: Radius.circular(20)),
        ),
        const SizedBox(width: 2),
        segment(
          90,
          l.fxcRange90d,
          const BorderRadius.horizontal(right: Radius.circular(20)),
        ),
      ],
    );
  }

  Widget _sparkline(AppLocalizations l, double width) {
    const height = 120.0;
    if (_historyLoading) {
      return SizedBox(
        height: height,
        child: Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(context.tealAccent),
            ),
          ),
        ),
      );
    }
    if (_historyError || _history.length < 2) {
      return SizedBox(
        height: height,
        child: Center(
          child: Text(
            _historyError ? l.fxcHistoryFailed : l.fxcNoHistory,
            style: TextStyle(fontSize: 12, color: context.textMuted),
          ),
        ),
      );
    }

    final spots = dayOffsetSpots(_history);
    final closes = [for (final p in _history) p.close];
    var minY = closes.reduce((a, b) => a < b ? a : b);
    var maxY = closes.reduce((a, b) => a > b ? a : b);
    // Breathing room so a flat-ish series doesn't hug the edges (and a
    // perfectly flat one still has a nonzero y-range).
    final pad = (maxY - minY) == 0
        ? (maxY.abs() * 0.02 + 0.01)
        : (maxY - minY) * 0.15;
    minY -= pad;
    maxY += pad;

    final latest = _history.last.close;
    final chartSemantics = l.fxcChartSemantics(
      // gen-l10n orders these alphabetically → (count, latest, pair).
      _history.length,
      localizeNumberString(context, latest.toStringAsFixed(4)),
      '$_base/$_target',
    );

    // Pointer-only canvas: mirror the series into the semantics tree and
    // exclude the painted chart, per the house chart-accessibility rule.
    return Semantics(
      container: true,
      label: chartSemantics,
      child: ExcludeSemantics(
        child: SizedBox(
          height: height,
          child: TransientTooltipLineChart(
            data: LineChartData(
              minY: minY,
              maxY: maxY,
              gridData: const FlGridData(show: false),
              titlesData: const FlTitlesData(show: false),
              borderData: FlBorderData(show: false),
              lineTouchData: standardLineTouch(
                context,
                items: (ctx, touched) => touched.map((s) {
                  final idx = s.spotIndex;
                  if (idx < 0 || idx >= _history.length) return null;
                  final p = _history[idx];
                  return LineTooltipItem(
                    '${DateFormat.MMMd(l.localeName).format(p.date)}\n'
                    '${localizeNumberString(ctx, p.close.toStringAsFixed(4))}',
                    TextStyle(
                      color: ctx.tooltipOnSurface,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  );
                }).toList(),
              ),
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: false,
                  color: context.tealAccent,
                  barWidth: 2,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show: true,
                    color: context.tealAccent.withValues(alpha: 0.10),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _sectionTitle(String text) => Text(
    text,
    style: TextStyle(
      fontSize: 13,
      fontWeight: FontWeight.w700,
      color: context.textMuted,
    ),
  );

  /// Two linked amount fields: editing either recomputes the other off
  /// the CURRENT rate. Plain numeric entry (same `[0-9.]` filter as the
  /// manual-rate dialog); the field labels carry the currency codes.
  Widget _converter() {
    final inputFilter = [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))];
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _baseCtl,
            onChanged: _onBaseEdited,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: inputFilter,
            decoration: InputDecoration(
              labelText: _base,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Icon(Icons.swap_horiz, size: 20, color: context.textSubtle),
        ),
        Expanded(
          child: TextField(
            controller: _targetCtl,
            onChanged: _onTargetEdited,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: inputFilter,
            decoration: InputDecoration(
              labelText: _target,
              border: const OutlineInputBorder(),
              isDense: true,
            ),
          ),
        ),
      ],
    );
  }

  Widget _alertSection(AppLocalizations l) {
    final activeThreshold = (_alert?['threshold'] as num?)?.toDouble();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l.fxcAlertHint(_base, _target),
          style: TextStyle(fontSize: 12, color: context.textSubtle),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _alertCtl,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
                ],
                decoration: InputDecoration(
                  labelText: '$_base / $_target',
                  hintText: '0.00',
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ),
            const SizedBox(width: 12),
            FilledButton(
              onPressed: _alertSaving ? null : _saveAlert,
              child: _alertSaving
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation(
                          Theme.of(context).colorScheme.onPrimary,
                        ),
                      ),
                    )
                  : Text(l.actionSave),
            ),
          ],
        ),
        if (activeThreshold != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(
                Icons.notifications_active_outlined,
                size: 16,
                color: context.info,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  l.fxcAlertActive(
                    localizeNumberString(
                      context,
                      activeThreshold.toStringAsFixed(2),
                    ),
                  ),
                  style: TextStyle(fontSize: 12, color: context.textMuted),
                ),
              ),
              TextButton(
                onPressed: _alertSaving ? null : _clearAlert,
                child: Text(l.fxcAlertClear),
              ),
            ],
          ),
        ],
      ],
    );
  }

  /// Per-year total cost of moving money vs mid-market, with a
  /// per-provider breakdown and the ±N-day spot caveat. Costs come from
  /// the backend already in USD (per-row FX before summing), so this is
  /// pure presentation.
  Widget _costsSection(AppLocalizations l) {
    if (_costsLoading) {
      return SizedBox(
        height: 40,
        child: Center(
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              valueColor: AlwaysStoppedAnimation(context.tealAccent),
            ),
          ),
        ),
      );
    }
    if (_costsError) {
      return Text(
        l.fxcCostsFailed,
        style: TextStyle(fontSize: 12, color: context.textMuted),
      );
    }
    final years = (_costs?['years'] as List?) ?? const [];
    if (years.isEmpty) {
      return Text(
        l.fxcCostsEmpty,
        style: TextStyle(fontSize: 12, color: context.textMuted),
      );
    }
    final windowDays = (_costs?['spot_window_days'] as num?)?.toInt() ?? 7;
    var missingSpot = 0;
    final blocks = <Widget>[];
    for (final rawYear in years) {
      final y = rawYear as Map<String, dynamic>;
      missingSpot += (y['missing_spot_count'] as num? ?? 0).toInt();
      final cost = (y['total_cost_usd'] as num? ?? 0).toDouble();
      final moved = (y['total_moved_usd'] as num? ?? 0).toDouble();
      final count = (y['transfer_count'] as num? ?? 0).toInt();
      blocks.add(
        Padding(
          padding: EdgeInsets.only(top: blocks.isEmpty ? 0 : 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      '${y['year']}',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                        color: context.textPrimary,
                      ),
                    ),
                  ),
                  Text(
                    formatCurrencyAmount(cost, 'USD'),
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: context.textPrimary,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                // gen-l10n orders these alphabetically → (count, moved).
                l.fxcCostsYearLine(count, formatCurrencyAmount(moved, 'USD')),
                style: TextStyle(fontSize: 12, color: context.textMuted),
              ),
              for (final rawProvider in (y['providers'] as List? ?? const []))
                _providerRow(l, rawProvider as Map<String, dynamic>),
            ],
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...blocks,
        const SizedBox(height: 10),
        Text(
          l.fxcCostsCaveat(windowDays),
          style: TextStyle(fontSize: 11, color: context.textSubtle),
        ),
        if (missingSpot > 0) ...[
          const SizedBox(height: 4),
          Text(
            l.fxcCostsMissingSpot(missingSpot),
            style: TextStyle(fontSize: 11, color: context.textSubtle),
          ),
        ],
      ],
    );
  }

  Widget _providerRow(AppLocalizations l, Map<String, dynamic> p) {
    final cost = (p['total_cost_usd'] as num? ?? 0).toDouble();
    // A null provider is the backend's "unknown" bucket — links the
    // detector matched without a remittance keyword (direct wires).
    final label = (p['provider'] as String?) ?? l.fxcCostsUnknownProvider;
    return Padding(
      padding: const EdgeInsets.only(left: 12, top: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(fontSize: 12, color: context.textMuted),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            formatCurrencyAmount(cost, 'USD'),
            style: TextStyle(
              fontSize: 12,
              color: context.textMuted,
              fontFeatures: const [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
    );
  }
}
