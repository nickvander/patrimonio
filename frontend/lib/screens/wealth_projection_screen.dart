import 'dart:async';
import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/preferences.dart';
import '../utils/chart_touch.dart';
import '../utils/currency.dart';
import '../utils/percent_format.dart';
import '../utils/projection_axis.dart';
import '../utils/theme_colors.dart';

/// Which FIRE "flavor" the user is focusing on. Purely a view choice — it
/// switches which target the headline + chart line emphasize; the underlying
/// projection math is identical for all three.
enum _FireFocus { full, coast, barista }

/// Test seams (same pattern as TaxPlanningScreen): the screen fetches through
/// these typedefs so widget tests can inject fixtures without real network
/// I/O. (ApiService itself constructs fine under the test VM — the
/// api_platform conditional import resolves a VM-safe client — but its
/// methods would hit the network.) Each defaults to the real service in
/// production.
typedef WealthProjectionFetcher =
    Future<Map<String, dynamic>> Function({
      required double startBalance,
      required double monthlyContribution,
      required double annualReturnRate,
      required double annualExpenses,
      required double withdrawalRate,
      int years,
      double annualInflationRate,
      double returnVolatility,
      int? yearsToRetirement,
      int monteCarloTrials,
      double baristaMonthlyIncome,
      double annualTaxDrag,
      bool withdrawalGuardrails,
      bool mxScenario,
      double expensesUsdPortion,
      double expensesMxnPortion,
      double fxAnnualDrift,
      double? usdMxnRate,
    });
typedef ProjectionDefaultsFetcher = Future<Map<String, dynamic>?> Function();
typedef PortfolioDividendsFetcher = Future<Map<String, dynamic>?> Function();
typedef ProjectionSettingReader = Future<dynamic> Function(String key);
typedef ProjectionSettingWriter =
    Future<void> Function(String key, dynamic value);

class WealthProjectionScreen extends StatefulWidget {
  final double currentNetWorth;
  final double conversionFactor;
  final NumberFormat currencyFormat;

  /// Live USD→MXN rate from the dashboard's FX fetch (null before it lands).
  /// Used by the "Retire in Mexico" scenario: to seed the peso split when the
  /// toggle first turns on and passed with the projection request so the
  /// backend's scenario math matches the rate shown in the FX pill.
  final double? usdMxnRate;

  /// Test seams — null in production (the real ApiService is used).
  final WealthProjectionFetcher? projectionFetcher;
  final ProjectionDefaultsFetcher? defaultsFetcher;
  final PortfolioDividendsFetcher? dividendsFetcher;
  final ProjectionSettingReader? settingReader;
  final ProjectionSettingWriter? settingWriter;

  const WealthProjectionScreen({
    super.key,
    required this.currentNetWorth,
    required this.conversionFactor,
    required this.currencyFormat,
    this.usdMxnRate,
    this.projectionFetcher,
    this.defaultsFetcher,
    this.dividendsFetcher,
    this.settingReader,
    this.settingWriter,
  });

  @override
  State<WealthProjectionScreen> createState() => _WealthProjectionScreenState();
}

class _WealthProjectionScreenState extends State<WealthProjectionScreen> {
  final ApiService _apiService = ApiService();

  // F9: the desktop controls column hides most of its 12 controls below an
  // unindicated fold — an always-visible scrollbar makes the fold obvious.
  final ScrollController _controlsScrollController = ScrollController();

  // F14: coalesce rapid assumption changes into one request (~300ms) and
  // drop out-of-order responses (the guard sequence number).
  Timer? _fetchDebounce;
  int _fetchSeq = 0;

  @override
  void dispose() {
    _fetchDebounce?.cancel();
    _controlsScrollController.dispose();
    super.dispose();
  }

  // F15: the dashboard passes a live net worth and the projection starts
  // from it — a material change (> $1, i.e. not float noise) must re-run the
  // projection or the chart keeps projecting from the stale balance.
  @override
  void didUpdateWidget(covariant WealthProjectionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if ((widget.currentNetWorth - oldWidget.currentNetWorth).abs() > 1.0) {
      _fetchProjection();
    }
  }

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

  // "Retire in Mexico" scenario: split retirement spending into a USD and an
  // MXN portion (each in its own currency, today's money) plus a long-run
  // USD/MXN drift assumption. Off by default so the single-currency behavior
  // is untouched for anyone who ignores the controls. The math lives in the
  // backend's input-transformation layer; these are pure inputs.
  bool _mxScenario = false;
  double _mxUsdPortion = 0.0; // USD/yr
  double _mxMxnPortion = 0.0; // MXN/yr (native pesos, NOT display currency)
  double _fxAnnualDrift = 0.0; // fraction/yr; + = peso weakens
  static const double _fxDriftMin = -0.10;
  static const double _fxDriftMax = 0.10;
  double _mxUsdMax = 100000.0;
  double _mxMxnMax = 2000000.0;
  // True once the portions hold a meaningful value (restored from the saved
  // blob or seeded on first toggle-on) — prevents re-seeding over user edits.
  bool _mxSeeded = false;

  /// Live rate with the house hard fallback (20.0 — the same last-resort
  /// constant as USD_MXN_ROW_RATE_SQL in the backend's services/tax.rs), for
  /// the client-side seed only; the backend re-derives its own rate when the
  /// request doesn't carry one.
  double get _fxRateOrFallback {
    final r = widget.usdMxnRate;
    return (r != null && r > 0) ? r : 20.0;
  }

  bool _isLoading = true;
  // F2: true when the last projection fetch threw. With no data to show, the
  // chart card renders a localized error + retry instead of a blank screen.
  bool _loadFailed = false;
  // Months of tracked data behind an adopted default (F3). Non-null means the
  // value came from the user's own cash flow and drives the slider hint;
  // null means the static default stands.
  int? _contributionFromMonths;
  int? _expensesFromMonths;
  // F10: true when the sliders were restored from the saved
  // `projection_assumptions` blob (suppresses the provenance hints — the
  // values are the user's own, not derived defaults).
  bool _assumptionsRestored = false;
  Map<String, dynamic>? _projectionData;

  // Optional user-set goal: "Hit $X by year Y". Stored in USD because the
  // chart and projection points are both USD-native; we convert for
  // display only. null on either field means "no goal yet".
  double? _goalAmountUsd;
  int? _goalYear;

  // Toggles the Monte Carlo uncertainty band (10–90th / 25–75th percentile
  // fan) around the expected line.
  bool _showBand = true;

  // U6: chart hover state, owned by the screen instead of fl_chart's
  // built-in handleBuiltInTouches — the built-in tooltip kept the last
  // hovered spot pinned after the pointer left the chart area. Holding the
  // touched spots here lets the touchCallback clear them on
  // FlPointerExitEvent / pan-end / long-press-end (anything
  // !isInterestedForInteractions), and makes the dismissal testable via
  // LineChartData.showingTooltipIndicators. null/empty = no tooltip.
  List<LineBarSpot>? _chartTouchedSpots;

  // True when [spots] describes the same touched positions as the current
  // state — used to skip no-op setState calls on every hover tick.
  bool _sameTouchedSpots(List<LineBarSpot> spots) {
    final cur = _chartTouchedSpots;
    if (cur == null || cur.length != spots.length) return false;
    for (var i = 0; i < spots.length; i++) {
      if (cur[i].barIndex != spots[i].barIndex ||
          cur[i].spotIndex != spots[i].spotIndex) {
        return false;
      }
    }
    return true;
  }

  // Display-only conversion. The backend math is always real (today's dollars);
  // when this is on we multiply every displayed figure by the cumulative
  // inflation path so the chart + KPIs read in future nominal dollars instead.
  // It never changes what we send to the backend.
  bool _showNominal = false;

  // Cumulative inflation factor at `years` from today, e.g. (1+i)^t. Used to
  // convert a real-dollar figure to nominal at a given horizon. Returns 1.0
  // when the nominal toggle is off so callers can multiply unconditionally.
  double _nominalFactor(double years) =>
      _showNominal ? math.pow(1 + _annualInflation, years).toDouble() : 1.0;

  // Live Fisher-relation hint under the return slider: states the real return
  // implied by the current nominal-return and inflation inputs, so the user
  // sees why a "7%" return doesn't compound at 7% in today's dollars.
  // real = (1 + nominal) / (1 + inflation) - 1.
  String _fisherHelp(AppLocalizations l) {
    final real = ((1 + _annualReturnRate) / (1 + _annualInflation) - 1) * 100;
    final nom = _annualReturnRate * 100;
    final inf = _annualInflation * 100;
    // F6: route through the locale decimal seam (no-op today — es-MX uses
    // period decimals like en); the % signs live in the template itself.
    return l.projFisherHelp(
      localizeNumberString(context, nom.toStringAsFixed(1)),
      localizeNumberString(context, inf.toStringAsFixed(1)),
      localizeNumberString(context, real.toStringAsFixed(1)),
    );
  }

  // Collapsible plain-language glossary at the top of the tab — the FIRE
  // jargon (Coast FIRE, Barista FI, withdrawal rate…) isn't obvious, so we
  // explain it on demand without permanently cluttering the screen.
  bool _showGlossary = false;

  // Phones only: the advanced assumptions (inflation, volatility, expenses,
  // SWR, barista income, tax drag, guardrails, projection years, goal) collapse
  // behind a disclosure so the controls card opens on the 3 primary sliders.
  bool _advancedExpanded = false;

  // Which FIRE flavor the headline + chart target line emphasize. Defaults to
  // Full FIRE (the canonical "your number"); Coast / Barista are there to
  // explore, answering "why Coast?" by making it one option among peers.
  _FireFocus _fireFocus = _FireFocus.full;

  // O2 · Dividend income outlook. Advanced toggle revealing a purely
  // informational panel under the chart: today's blended yield applied to
  // the median projected balances. It NEVER touches the projection request
  // or the balance curve — dividends are already inside the total-return
  // assumption, so adding them to growth would double-count.
  bool _showDividendOutlook = false;
  // Portfolio dividend summary (projected annual income + blended yield),
  // fetched once, best-effort. null after the fetch = no dividend data →
  // the toggle renders disabled with an explanatory tooltip.
  Map<String, dynamic>? _dividendData;
  bool _dividendFetchDone = false;

  // Lean / Standard / Fat are lifestyle *levels* relative to the user's own
  // baseline spending (Standard = their tracked/real expenses), so the
  // presets always make sense instead of snapping to arbitrary dollar
  // amounts. Captured once (default first, overridden by tracked data).
  double? _baselineExpenses;
  static const Map<String, double> _lifestyleMultipliers = {
    'lean': 0.7,
    'standard': 1.0,
    'fat': 1.6,
  };

  // Annual-expense value for a lifestyle preset, rounded to a clean $1k.
  double _presetExpense(String key, double base) =>
      ((base * _lifestyleMultipliers[key]!) / 1000).round() * 1000.0;

  // U2: typed-entry bounds. Values typed into the numeric-entry dialog may
  // exceed a slider's drag range; the slider max then grows to a clean tick
  // so the thumb stays meaningful (generalized from the _expensesMax
  // pattern), and the hydration clamps accept the same widened range so a
  // persisted typed value round-trips instead of snapping to the old max.
  static const double _expensesFloor = 4000.0;
  static const double _typedMoneyCap = 1000000000.0; // $1B — the goal cap
  double _savingsMax = 10000.0;
  double _baristaMax = 10000.0;
  // Extra expenses headroom beyond the baseline-driven max, set by typed
  // entry / hydration.
  double _expensesTypedMax = 0.0;

  /// Smallest clean multiple of [tick] that fits [value] — never below
  /// [current], so a slider max only ever grows.
  static double _grownMax(double current, double value, double tick) {
    if (value <= current) return current;
    return (value / tick).ceil() * tick;
  }

  // Upper bound of the annual-expense slider. Normally $200k, but it grows
  // with the baseline so a high earner's "Fat" preset (1.6×) doesn't clamp
  // and collapse into "Standard" — rounded up to a clean $50k tick — and
  // with any larger typed value (U2).
  double get _expensesMax {
    final base = _baselineExpenses ?? _annualExpenses;
    final needed = base * 1.8;
    final computed = needed <= 200000
        ? 200000.0
        : (needed / 50000).ceil() * 50000.0;
    return math.max(computed, _expensesTypedMax);
  }

  @override
  void initState() {
    super.initState();
    _monthlyContribution = 1000.0;
    _goalAmountUsd = Preferences.getGoalAmountUsd();
    _goalYear = Preferences.getGoalYear();
    _hydrateGoalFromBackend();
    _bootstrap();
    _loadDividendData();
  }

  // U3: tracked annual income (USD) from /projections/defaults — powers the
  // savings-rate caption under the Monthly savings slider. 0 = unknown/absent
  // → no caption.
  double _annualIncome = 0.0;

  // F10: saved assumptions (if any) win over derived defaults; otherwise the
  // tracked-data prefill runs as before. Either path ends in a projection.
  Future<void> _bootstrap() async {
    if (await _hydrateAssumptions()) {
      // U3: restored assumptions skip the prefill, but the savings-rate
      // caption still wants the tracked income — fetch it best-effort
      // without adopting any defaults.
      unawaited(_loadIncomeContext());
      await _fetchProjection();
    } else {
      await _prefillFromTrackedData();
    }
  }

  // U3: best-effort read of `annual_income` only (never adopts contribution
  // or expenses — the saved assumptions already won).
  Future<void> _loadIncomeContext() async {
    try {
      final fetch = widget.defaultsFetcher ?? _apiService.getProjectionDefaults;
      final defaults = await fetch();
      if (!mounted || defaults == null) return;
      final income = (defaults['annual_income'] as num?)?.toDouble() ?? 0.0;
      if (income > 0) setState(() => _annualIncome = income);
    } catch (_) {
      // Caption simply stays hidden.
    }
  }

  /// Set when the READ of `projection_assumptions` failed — as opposed to
  /// there being nothing saved. The two used to be indistinguishable (`catch
  /// → return false`), and the consequences diverge sharply: a transient read
  /// failure sent the screen down the "no saved assumptions" path, seeded
  /// derived defaults, and then the next slider nudge PERSISTED those
  /// defaults over the user's real scenario. While this is true we refuse to
  /// write (see [_persistAssumptions]).
  bool _assumptionsReadFailed = false;

  // F10: restore the assumption sliders from the `projection_assumptions`
  // setting. Returns true when a stored blob was applied; a malformed or
  // missing blob silently leaves the defaults.
  Future<bool> _hydrateAssumptions() async {
    try {
      final read = widget.settingReader ?? _apiService.getSetting;
      final raw = await read('projection_assumptions');
      _assumptionsReadFailed = false;
      if (!mounted || raw is! Map) return false;
      double? d(String k) {
        final v = raw[k];
        return v is num ? v.toDouble() : null;
      }

      setState(() {
        // U2: money fields clamp to the typed-entry cap, not the slider's
        // drag range — a persisted typed value (e.g. $12,500/mo) must restore
        // as-is, with the slider max grown to accommodate it.
        _monthlyContribution =
            (d('monthly_contribution') ?? _monthlyContribution).clamp(
              0.0,
              _typedMoneyCap,
            );
        _savingsMax = _grownMax(_savingsMax, _monthlyContribution, 1000.0);
        _annualReturnRate = (d('annual_return_rate') ?? _annualReturnRate)
            .clamp(0.0, 0.15);
        _annualInflation = (d('annual_inflation_rate') ?? _annualInflation)
            .clamp(0.0, 0.06);
        _annualExpenses = (d('annual_expenses') ?? _annualExpenses).clamp(
          _expensesFloor,
          _typedMoneyCap,
        );
        if (_annualExpenses > _expensesMax) {
          _expensesTypedMax = _grownMax(0.0, _annualExpenses, 50000.0);
        }
        _withdrawalRate = (d('withdrawal_rate') ?? _withdrawalRate).clamp(
          0.02,
          0.06,
        );
        _returnVolatility = (d('return_volatility') ?? _returnVolatility).clamp(
          0.0,
          0.25,
        );
        _baristaMonthlyIncome =
            (d('barista_monthly_income') ?? _baristaMonthlyIncome).clamp(
              0.0,
              _typedMoneyCap,
            );
        _baristaMax = _grownMax(_baristaMax, _baristaMonthlyIncome, 1000.0);
        _annualTaxDrag = (d('annual_tax_drag') ?? _annualTaxDrag).clamp(
          0.0,
          0.03,
        );
        if (raw['withdrawal_guardrails'] is bool) {
          _withdrawalGuardrails = raw['withdrawal_guardrails'] as bool;
        }
        _projectionYears =
            (d('projection_years') ?? _projectionYears.toDouble())
                .round()
                .clamp(5, 50);
        _yearsToRetirement =
            (d('years_to_retirement') ?? _yearsToRetirement.toDouble())
                .round()
                .clamp(0, _projectionYears);
        // Retire-in-Mexico scenario fields. Same U2 rule as the money
        // sliders: clamp to the typed cap, grow the slider max to fit.
        if (raw['mx_scenario'] is bool) {
          _mxScenario = raw['mx_scenario'] as bool;
        }
        _mxUsdPortion = (d('annual_expenses_usd_portion') ?? _mxUsdPortion)
            .clamp(0.0, _typedMoneyCap);
        _mxMxnPortion = (d('annual_expenses_mxn_portion') ?? _mxMxnPortion)
            .clamp(0.0, _typedMoneyCap);
        _fxAnnualDrift = (d('fx_annual_drift') ?? _fxAnnualDrift).clamp(
          _fxDriftMin,
          _fxDriftMax,
        );
        if (_mxUsdPortion > 0 || _mxMxnPortion > 0) _mxSeeded = true;
        _mxUsdMax = _grownMax(_mxUsdMax, _mxUsdPortion, 10000.0);
        _mxMxnMax = _grownMax(_mxMxnMax, _mxMxnPortion, 100000.0);
        _assumptionsRestored = true;
      });
      return true;
    } catch (_) {
      // Fallback to the static defaults / tracked-data prefill for THIS
      // session, but remember that we never learned what was stored — so we
      // don't overwrite it.
      _assumptionsReadFailed = true;
      return false;
    }
  }

  // F10: the ~10 assumption fields as one JSON blob, written best-effort on
  // every committed change (onChangeEnd / toggle / preset chip).
  Map<String, dynamic> get _assumptionsJson => {
    'monthly_contribution': _monthlyContribution,
    'annual_return_rate': _annualReturnRate,
    'annual_inflation_rate': _annualInflation,
    'annual_expenses': _annualExpenses,
    'withdrawal_rate': _withdrawalRate,
    'return_volatility': _returnVolatility,
    'barista_monthly_income': _baristaMonthlyIncome,
    'annual_tax_drag': _annualTaxDrag,
    'withdrawal_guardrails': _withdrawalGuardrails,
    'years_to_retirement': _yearsToRetirement,
    'projection_years': _projectionYears,
    'mx_scenario': _mxScenario,
    'annual_expenses_usd_portion': _mxUsdPortion,
    'annual_expenses_mxn_portion': _mxMxnPortion,
    'fx_annual_drift': _fxAnnualDrift,
  };

  Future<void> _persistAssumptions() async {
    if (_assumptionsReadFailed) {
      // We are showing defaults we derived, not the user's saved scenario —
      // writing now would destroy it. Try the read once more; only a
      // successful read (or a confirmed absence) unlocks writing.
      final restored = await _hydrateAssumptions();
      if (_assumptionsReadFailed) {
        debugPrint(
          'projection: assumptions unreadable — refusing to overwrite',
        );
        return;
      }
      // The read came back: whatever it held is now on screen, so there is
      // no pending user edit to persist.
      if (restored) return;
    }
    final write = widget.settingWriter ?? _apiService.putSetting;
    try {
      await write('projection_assumptions', _assumptionsJson);
    } catch (_) {
      // Best-effort — the projection itself already reflects the change, and
      // the next committed change retries.
    }
  }

  // F10: a committed assumption change persists the blob and refreshes the
  // projection. Every slider onChangeEnd / toggle / preset chip routes here.
  // F14: debounced ~300ms so a burst of commits (rapid chip taps, slider
  // flicks) issues one write + one fetch after the flurry settles.
  void _assumptionChanged() {
    _fetchDebounce?.cancel();
    _fetchDebounce = Timer(const Duration(milliseconds: 300), () {
      _persistAssumptions();
      _fetchProjection();
    });
  }

  // One-shot, best-effort fetch backing the dividend outlook toggle (O2).
  // Fetched up front (getPortfolioDividends is served from the backend's
  // cached dividend fan-out) so the toggle can correctly render disabled —
  // with a tooltip — for a dividend-less portfolio instead of snapping
  // back off after a tap.
  Future<void> _loadDividendData() async {
    final fetch = widget.dividendsFetcher ?? _apiService.getPortfolioDividends;
    final data = await fetch();
    if (!mounted) return;
    setState(() {
      _dividendData = data;
      _dividendFetchDone = true;
    });
  }

  // Projected annual dividend income (USD) from the portfolio summary; 0
  // when unavailable. The outlook is offered only when this is positive.
  double get _dividendIncomeUsd =>
      (_dividendData?['projected_annual_income_usd'] as num?)?.toDouble() ??
      0.0;

  bool get _dividendOutlookAvailable =>
      _dividendFetchDone && _dividendIncomeUsd > 0;

  Future<void> _hydrateGoalFromBackend() async {
    try {
      final read = widget.settingReader ?? _apiService.getSetting;
      final raw = await read('net_worth_goal');
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
      final fetch = widget.defaultsFetcher ?? _apiService.getProjectionDefaults;
      final defaults = await fetch();
      if (mounted && defaults != null) {
        final contrib = (defaults['monthly_contribution'] as num?)?.toDouble();
        final expenses = (defaults['annual_expenses'] as num?)?.toDouble();
        final months = (defaults['months_of_data'] as num?)?.toInt() ?? 0;
        final income = (defaults['annual_income'] as num?)?.toDouble() ?? 0.0;
        // F3: adopt each derived default on its own merits. A valid tracked
        // contribution used to be discarded whenever expenses were $0, and a
        // single month of data was silently extrapolated ×12 into the
        // retirement-spend default — so the contribution is adopted whenever
        // it's positive, while expenses need ≥3 months of history.
        setState(() {
          // U3: income backs the savings-rate caption, independent of
          // whether the contribution/expenses defaults are adopted.
          if (income > 0) _annualIncome = income;
          if (contrib != null && contrib > 0) {
            // U2: don't truncate a genuinely high tracked contribution to
            // the drag range — grow the slider max instead.
            _monthlyContribution = contrib.clamp(0.0, _typedMoneyCap);
            _savingsMax = _grownMax(_savingsMax, _monthlyContribution, 1000.0);
            _contributionFromMonths = math.max(months, 1);
          }
          if (months >= 3 && expenses != null && expenses > 0) {
            _annualExpenses = expenses.clamp(_expensesFloor, _typedMoneyCap);
            // Anchor the Lean/Standard/Fat presets to the user's real spend.
            _baselineExpenses = _annualExpenses;
            _expensesFromMonths = months;
          }
        });
      }
    } catch (_) {
      // ignore; static defaults stand
    }
    await _fetchProjection();
  }

  Future<void> _fetchProjection() async {
    // F14: sequence guard — only the newest in-flight request may land, so a
    // slow stale response can't overwrite a fresher one.
    final seq = ++_fetchSeq;
    setState(() => _isLoading = true);
    try {
      final fetch = widget.projectionFetcher ?? _apiService.getWealthProjection;
      final data = await fetch(
        // `currentNetWorth` is already USD (dashboard.rs net_worth is computed in
        // USD); `conversionFactor` only scales USD->display. Dividing here
        // double-converted it, so MXN-display users projected from ~1/fxRate of
        // their real net worth. The backend wants USD, so pass it straight through.
        startBalance: widget.currentNetWorth,
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
        mxScenario: _mxScenario,
        expensesUsdPortion: _mxUsdPortion,
        expensesMxnPortion: _mxMxnPortion,
        fxAnnualDrift: _fxAnnualDrift,
        usdMxnRate: widget.usdMxnRate,
      );
      if (!mounted || seq != _fetchSeq) return; // stale response — drop it
      setState(() {
        _projectionData = data;
        _loadFailed = false;
        _isLoading = false;
        // U6: a fresh projection invalidates any hovered spot — its indexes
        // point into the previous curve.
        _chartTouchedSpots = null;
      });
    } catch (e) {
      debugPrint("Error fetching projection: $e");
      if (!mounted || seq != _fetchSeq) return;
      setState(() {
        _loadFailed = true;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final isNarrow = constraints.maxWidth < 800;
        if (isNarrow) {
          // Summary-first phone order (research rubric principle 13): the
          // chart and its verdicts (FIRE strip, milestones) lead; the
          // assumptions sliders and the glossary move below them. The
          // sliders still live-update the chart — scrolling back up shows
          // the new curve.
          return SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _buildHeader(isPhone: constraints.maxWidth < 420),
                const SizedBox(height: 16),
                // Intrinsic height: the card self-sizes (title + legend at
                // natural height, plot at a guaranteed width-derived height),
                // so a legend that wraps to extra lines grows the card instead
                // of squishing the plot — the old fixed 320 box did the latter.
                _buildChartCard(),
                // Retire-in-Mexico dual-currency results, directly under the
                // chart whose curve they annotate.
                if (_mxPanelOn) ...[
                  const SizedBox(height: 16),
                  _buildMxScenarioPanel(),
                ],
                // O2: informational dividend income outlook — sits between the
                // chart and the FIRE strip; never part of the chart itself.
                if (_showDividendOutlook && _dividendOutlookAvailable) ...[
                  const SizedBox(height: 16),
                  _buildDividendOutlookPanel(),
                ],
                const SizedBox(height: 16),
                _buildFireStatusStrip(),
                const SizedBox(height: 16),
                // Below 800px the milestone row stacks into a 2×2 grid with
                // self-bounded row heights (handled inside _buildMilestonesRow
                // off its own LayoutBuilder), so it's safe at intrinsic height
                // inside this scroll view — no unbounded-height Row blowup (F1).
                _buildMilestonesRow(),
                const SizedBox(height: 24),
                _buildGlossaryCard(),
                const SizedBox(height: 24),
                _buildControls(scrollable: false),
              ],
            ),
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildHeader(),
            const SizedBox(height: 16),
            _buildGlossaryCard(),
            const SizedBox(height: 24),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(width: 320, child: _buildControls()),
                  const SizedBox(width: 24),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, col) {
                        final panelOn =
                            _showDividendOutlook && _dividendOutlookAvailable;
                        final mxOn = _mxPanelOn;
                        // The classic desktop look lets the chart (flex 3) and
                        // the milestone tiles (flex 1) split whatever height the
                        // fixed-size cards — the FIRE strip and, when toggled on,
                        // the dividend outlook panel — leave over. On shorter
                        // windows that fixed content eats the flex space and the
                        // chart collapses to a sliver (round-3 defect: 1440x900
                        // with the outlook panel on). Estimate whether the flex
                        // layout still gives the chart a usable height; when it
                        // can't, fall back to a scrollable column with fixed
                        // heights — the same shape the narrow layout uses.
                        //
                        // Estimated fixed extents: FIRE strip ~210, outlook
                        // panel ~230, plus the 16px gaps; the chart takes 3/4 of
                        // the leftover and needs ~320px of card so the plot
                        // itself stays ≥ ~200px (title + legend chrome inside the
                        // card use ~70, padding ~48). The milestone tile row
                        // (flex 1) needs its ~240px too — the old estimate
                        // omitted it, so at 1440×900 the flex branch was chosen
                        // and the OverflowBox painted the tiles past the window
                        // edge with no way to scroll (F1). (240, was 220: the
                        // honest income-tile title/subtitle wrap one line taller.)
                        const chartMinH = 320.0;
                        const tilesMinH = 240.0;
                        // The MX scenario panel is another ~250px of fixed
                        // content; count it or the flex branch collapses the
                        // chart to a sliver exactly like the F1 dividend-panel
                        // defect.
                        final flexAvail =
                            col.maxHeight -
                            (210.0 +
                                32.0 +
                                (panelOn ? 230.0 + 16.0 : 0.0) +
                                (mxOn ? 250.0 + 16.0 : 0.0));
                        final flexFits =
                            flexAvail * 0.75 >= chartMinH &&
                            flexAvail * 0.25 >= tilesMinH;
                        if (flexFits) {
                          return Column(
                            children: [
                              Expanded(flex: 3, child: _buildChartCard()),
                              if (mxOn) ...[
                                const SizedBox(height: 16),
                                _buildMxScenarioPanel(),
                              ],
                              // O2: informational dividend income outlook — sits
                              // between the chart and the FIRE strip; never part
                              // of the chart itself.
                              if (panelOn) ...[
                                const SizedBox(height: 16),
                                _buildDividendOutlookPanel(),
                              ],
                              const SizedBox(height: 16),
                              _buildFireStatusStrip(),
                              const SizedBox(height: 16),
                              Expanded(
                                flex: 1,
                                child: LayoutBuilder(
                                  builder: (context, tiles) {
                                    // The 4-up tile row wants ~tilesMinH of height.
                                    // When its flex share comes up shorter, the
                                    // release build has always just painted past
                                    // the window edge; mirror that with an
                                    // OverflowBox instead of tripping the debug
                                    // RenderFlex overflow (which also fails widget
                                    // tests). At healthy heights min == max ==
                                    // share, i.e. a no-op.
                                    return OverflowBox(
                                      alignment: Alignment.topCenter,
                                      minHeight: tiles.maxHeight,
                                      maxHeight: math.max(
                                        tiles.maxHeight,
                                        tilesMinH,
                                      ),
                                      child: _buildMilestonesRow(),
                                    );
                                  },
                                ),
                              ),
                            ],
                          );
                        }
                        // Scroll fallback: same reading order (chart → outlook →
                        // FIRE plan → milestone tiles) with the chart pinned to a
                        // usable height instead of a flex share.
                        return SingleChildScrollView(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // 360 keeps the plot itself (card minus title +
                              // legend chrome) comfortably above ~200px.
                              SizedBox(height: 360, child: _buildChartCard()),
                              if (mxOn) ...[
                                const SizedBox(height: 16),
                                _buildMxScenarioPanel(),
                              ],
                              if (panelOn) ...[
                                const SizedBox(height: 16),
                                _buildDividendOutlookPanel(),
                              ],
                              const SizedBox(height: 16),
                              _buildFireStatusStrip(),
                              const SizedBox(height: 16),
                              // Intrinsic height (not a fixed box): inside a
                              // scrollable there's no flex space to reclaim, and
                              // it can't clip the tiles at any width.
                              _buildMilestonesRow(),
                            ],
                          ),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeader({bool isPhone = false}) {
    final l = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 12,
          runSpacing: 8,
          children: [
            // <420 the 28px display title becomes a 12px overline (the
            // compact-header idiom the Invest/Activity tabs adopted), so
            // the title row stops crowding out the first card of content.
            Text(
              isPhone ? l.projTitle.toUpperCase() : l.projTitle,
              style: isPhone
                  ? TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.6,
                      color: context.textSubtle,
                    )
                  : TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: context.textPrimary,
                    ),
            ),
            // Dollar-basis badge: the model is computed in today's purchasing
            // power; the toggle re-expresses the same figures in future nominal
            // dollars (display-only — the underlying math stays real).
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: context.info.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                _showNominal ? l.projNominalNote : l.projRealNote,
                style: TextStyle(
                  color: context.info,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            // "Show nominal amounts" toggle. A6 (round 3, a11y): the label
            // merges into the switch node so it isn't an anonymous on/off.
            MergeSemantics(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Switch(
                    value: _showNominal,
                    activeThumbColor: context.positive,
                    onChanged: (v) => setState(() => _showNominal = v),
                  ),
                  Text(
                    l.projShowNominal,
                    style: TextStyle(color: context.textMuted, fontSize: 13),
                  ),
                ],
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

  // Collapsible plain-language glossary. Defines the FIRE jargon the rest of
  // the tab throws around (Coast FIRE, Barista FI, withdrawal rate, the
  // uncertainty band) so a newcomer isn't staring at unexplained terms.
  Widget _buildGlossaryCard() {
    final l = AppLocalizations.of(context);
    Widget row(String term, String def) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            term,
            style: TextStyle(
              color: context.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            def,
            style: TextStyle(
              color: context.textMuted,
              fontSize: 12,
              height: 1.3,
            ),
          ),
        ],
      ),
    );
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _showGlossary = !_showGlossary),
            borderRadius: BorderRadius.circular(16),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
              child: Row(
                children: [
                  Icon(Icons.school_outlined, size: 18, color: context.info),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.projGlossaryTitle,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Icon(
                    _showGlossary ? Icons.expand_less : Icons.expand_more,
                    color: context.textMuted,
                  ),
                ],
              ),
            ),
          ),
          AnimatedCrossFade(
            duration: const Duration(milliseconds: 160),
            sizeCurve: Curves.easeOut,
            crossFadeState: _showGlossary
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            firstChild: const SizedBox(width: double.infinity),
            secondChild: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Divider(color: context.hairline, height: 1),
                  row(l.projTermLifestyle, l.projGlossaryLifestyleDef),
                  row(l.projFiNumber, l.projGlossaryFiNumberDef),
                  row(l.projTermCoast, l.projGlossaryCoastDef),
                  row(l.projTermBarista, l.projGlossaryBaristaDef),
                  row(l.projSafeWithdrawalRate, l.projGlossarySwrDef),
                  row(l.projTermRange, l.projGlossaryRangeDef),
                  // F11: the bold line is the *average* path — often above
                  // the simulation's median — so say so.
                  row(l.projTermAveragePath, l.projGlossaryAveragePathDef),
                  row(l.projTermRealDollars, l.projGlossaryRealDef),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls({bool scrollable = true}) {
    final l = AppLocalizations.of(context);
    final isPhone = MediaQuery.sizeOf(context).width < 720;
    final pad = isPhone ? 16.0 : 24.0;
    final divH = isPhone ? 20.0 : 32.0;
    Widget div() => Divider(height: divH, color: context.hairline);

    // U3: savings-rate caption — the CURRENT contribution against tracked
    // annual income, capped at 100% for display; hidden without income data.
    // Recomputed on every rebuild so it tracks the slider live (onChanged
    // runs setState on each drag tick).
    String? savingsRateCaption;
    if (_annualIncome > 0) {
      final pct = (_monthlyContribution * 12 / _annualIncome * 100).clamp(
        0.0,
        100.0,
      );
      savingsRateCaption = l.projSavingsRateCaption(
        formatPercent(context, pct, digits: 0),
      );
    }

    // The 3 primary sliders stay visible at all widths.
    final primary = <Widget>[
      _buildSliderControl(
        label: l.projMonthlySavings,
        value: _monthlyContribution,
        min: 0,
        max: _savingsMax,
        isCurrency: true,
        // F3: honest provenance — the hint names how much history backs the
        // adopted value; no hint when the static default stands.
        hint: _contributionFromMonths != null
            ? l.projBasedOnMonths(_contributionFromMonths!)
            : null,
        caption: savingsRateCaption,
        onChanged: (val) => setState(() => _monthlyContribution = val),
        onChangeEnd: (_) => _assumptionChanged(),
        // U2: tap the value label to type an exact figure.
        onTapValue: () => _editMoneyValue(
          label: l.projMonthlySavings,
          currentUsd: _monthlyContribution,
          minUsd: 0,
          commit: (v) {
            _monthlyContribution = v;
            _savingsMax = _grownMax(_savingsMax, v, 1000.0);
          },
        ),
      ),
      div(),
      _buildSliderControl(
        label: l.projExpectedReturnNominal,
        value: _annualReturnRate,
        min: 0,
        max: 0.15,
        isPercent: true,
        help: '${l.projHelpExpectedReturn}\n${_fisherHelp(l)}',
        onChanged: (val) => setState(() => _annualReturnRate = val),
        onChangeEnd: (_) => _assumptionChanged(),
        onTapValue: () => _editPercentValue(
          label: l.projExpectedReturnNominal,
          currentFraction: _annualReturnRate,
          minFraction: 0,
          maxFraction: 0.15,
          commit: (v) => _annualReturnRate = v,
        ),
      ),
      div(),
      _buildSliderControl(
        label: l.projYearsToRetirement,
        value: _yearsToRetirement.toDouble().clamp(
          0,
          _projectionYears.toDouble(),
        ),
        min: 0,
        max: _projectionYears.toDouble(),
        divisions: _projectionYears,
        help: l.projHelpYearsToRetirement,
        onChanged: (val) => setState(() => _yearsToRetirement = val.toInt()),
        onChangeEnd: (_) => _assumptionChanged(),
        onTapValue: () => _editYearsValue(
          label: l.projYearsToRetirement,
          current: _yearsToRetirement.clamp(0, _projectionYears),
          min: 0,
          max: _projectionYears,
          commit: (v) => _yearsToRetirement = v,
        ),
      ),
    ];

    // Everything else — collapsed behind a disclosure on phones, inline on wide.
    final advanced = <Widget>[
      _buildSliderControl(
        label: l.projInflation,
        value: _annualInflation,
        min: 0,
        max: 0.06,
        isPercent: true,
        help: l.projHelpInflation,
        onChanged: (val) => setState(() => _annualInflation = val),
        onChangeEnd: (_) => _assumptionChanged(),
        onTapValue: () => _editPercentValue(
          label: l.projInflation,
          currentFraction: _annualInflation,
          minFraction: 0,
          maxFraction: 0.06,
          commit: (v) => _annualInflation = v,
        ),
      ),
      div(),
      _buildSliderControl(
        label: l.projVolatility,
        value: _returnVolatility,
        min: 0,
        max: 0.25,
        isPercent: true,
        help: l.projHelpVolatility,
        onChanged: (val) => setState(() => _returnVolatility = val),
        onChangeEnd: (_) => _assumptionChanged(),
        onTapValue: () => _editPercentValue(
          label: l.projVolatility,
          currentFraction: _returnVolatility,
          minFraction: 0,
          maxFraction: 0.25,
          commit: (v) => _returnVolatility = v,
        ),
      ),
      div(),
      // The Mexico scenario REPLACES the single expense input with the
      // USD/MXN split, so exactly one expense representation is on screen and
      // the inactive one can't mislead.
      if (!_mxScenario) ...[
        _buildSliderControl(
          label: l.projAnnualExpenses,
          value: _annualExpenses,
          min: _expensesFloor,
          max: _expensesMax,
          isCurrency: true,
          help: l.projHelpAnnualExpenses,
          // F3: adopted → say how much data backs it; static $40k default →
          // say it's an estimate instead of implying it came from tracked
          // data. Restored user-saved assumptions (F10) carry no hint: the
          // value is the user's own, neither derived nor a stock estimate.
          hint: _expensesFromMonths != null
              ? l.projBasedOnMonths(_expensesFromMonths!)
              : (_assumptionsRestored ? null : l.projExpensesEstimateHint),
          onChanged: (val) => setState(() => _annualExpenses = val),
          onChangeEnd: (_) => _assumptionChanged(),
          onTapValue: () => _editMoneyValue(
            label: l.projAnnualExpenses,
            currentUsd: _annualExpenses,
            minUsd: _expensesFloor,
            commit: (v) {
              _annualExpenses = v;
              if (v > _expensesMax) {
                _expensesTypedMax = _grownMax(0.0, v, 50000.0);
              }
            },
          ),
        ),
        div(),
      ],
      _buildMxToggle(),
      if (_mxScenario) ...[
        div(),
        // Both portions render in their NATIVE currency with the ISO code
        // (never the display-currency conversion) — "USD 12,000" next to
        // "MXN 400,000" — because the split is defined per currency.
        _buildSliderControl(
          label: l.projMxUsdPortion,
          value: _mxUsdPortion,
          min: 0,
          max: _mxUsdMax,
          currencyCode: 'USD',
          help: l.projMxHelpUsdPortion,
          onChanged: (val) => setState(() => _mxUsdPortion = val),
          onChangeEnd: (_) => _assumptionChanged(),
          onTapValue: () => _editNativeMoneyValue(
            label: l.projMxUsdPortion,
            current: _mxUsdPortion,
            code: 'USD',
            commit: (v) {
              _mxUsdPortion = v;
              _mxUsdMax = _grownMax(_mxUsdMax, v, 10000.0);
            },
          ),
        ),
        div(),
        _buildSliderControl(
          label: l.projMxMxnPortion,
          value: _mxMxnPortion,
          min: 0,
          max: _mxMxnMax,
          currencyCode: 'MXN',
          help: l.projMxHelpMxnPortion,
          onChanged: (val) => setState(() => _mxMxnPortion = val),
          onChangeEnd: (_) => _assumptionChanged(),
          onTapValue: () => _editNativeMoneyValue(
            label: l.projMxMxnPortion,
            current: _mxMxnPortion,
            code: 'MXN',
            commit: (v) {
              _mxMxnPortion = v;
              _mxMxnMax = _grownMax(_mxMxnMax, v, 100000.0);
            },
          ),
        ),
        div(),
        _buildSliderControl(
          label: l.projMxFxDrift,
          value: _fxAnnualDrift,
          min: _fxDriftMin,
          max: _fxDriftMax,
          isPercent: true,
          divisions: 40, // 0.5%/yr steps across the ±10% range
          help: l.projMxHelpFxDrift,
          onChanged: (val) => setState(() => _fxAnnualDrift = val),
          onChangeEnd: (_) => _assumptionChanged(),
          onTapValue: () => _editPercentValue(
            label: l.projMxFxDrift,
            currentFraction: _fxAnnualDrift,
            minFraction: _fxDriftMin,
            maxFraction: _fxDriftMax,
            commit: (v) => _fxAnnualDrift = v,
          ),
        ),
      ],
      div(),
      _buildSliderControl(
        label: l.projSafeWithdrawalRate,
        value: _withdrawalRate,
        min: 0.02,
        max: 0.06,
        isPercent: true,
        help: l.projHelpSwr,
        onChanged: (val) => setState(() => _withdrawalRate = val),
        onChangeEnd: (_) => _assumptionChanged(),
        onTapValue: () => _editPercentValue(
          label: l.projSafeWithdrawalRate,
          currentFraction: _withdrawalRate,
          minFraction: 0.02,
          maxFraction: 0.06,
          commit: (v) => _withdrawalRate = v,
        ),
      ),
      div(),
      _buildSliderControl(
        label: l.projBaristaIncome,
        value: _baristaMonthlyIncome,
        min: 0,
        max: _baristaMax,
        isCurrency: true,
        help: l.projHelpBaristaIncome,
        onChanged: (val) => setState(() => _baristaMonthlyIncome = val),
        onChangeEnd: (_) => _assumptionChanged(),
        onTapValue: () => _editMoneyValue(
          label: l.projBaristaIncome,
          currentUsd: _baristaMonthlyIncome,
          minUsd: 0,
          commit: (v) {
            _baristaMonthlyIncome = v;
            _baristaMax = _grownMax(_baristaMax, v, 1000.0);
          },
        ),
      ),
      div(),
      _buildSliderControl(
        label: l.projTaxDrag,
        value: _annualTaxDrag,
        min: 0,
        max: 0.03,
        isPercent: true,
        help: l.projHelpTaxDrag,
        onChanged: (val) => setState(() => _annualTaxDrag = val),
        onChangeEnd: (_) => _assumptionChanged(),
        onTapValue: () => _editPercentValue(
          label: l.projTaxDrag,
          currentFraction: _annualTaxDrag,
          minFraction: 0,
          maxFraction: 0.03,
          commit: (v) => _annualTaxDrag = v,
        ),
      ),
      div(),
      _buildGuardrailsToggle(),
      div(),
      _buildDividendOutlookToggle(),
      div(),
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
        onChangeEnd: (_) => _assumptionChanged(),
        onTapValue: () => _editYearsValue(
          label: l.projProjectionYears,
          current: _projectionYears,
          min: 5,
          max: 50,
          commit: (v) {
            // Mirror the slider's invariant: retirement can't sit past the
            // horizon.
            _projectionYears = v;
            if (_yearsToRetirement > _projectionYears) {
              _yearsToRetirement = _projectionYears;
            }
          },
        ),
      ),
      div(),
      _buildGoalEditor(),
    ];

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ...primary,
        if (isPhone) ...[
          div(),
          _buildAdvancedDisclosure(l, advanced),
        ] else ...[
          div(),
          ...advanced,
        ],
      ],
    );
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        // F9: always-visible scrollbar so the fold in the controls column is
        // discoverable (7 of 12 controls hide below it on short windows).
        child: scrollable
            ? Scrollbar(
                controller: _controlsScrollController,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _controlsScrollController,
                  child: body,
                ),
              )
            : body,
      ),
    );
  }

  // Phone-only disclosure header that reveals the advanced assumption sliders.
  Widget _buildAdvancedDisclosure(AppLocalizations l, List<Widget> advanced) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => setState(() => _advancedExpanded = !_advancedExpanded),
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.tune, color: context.tealAccent, size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l.projAdvancedAssumptions,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: context.textPrimary,
                    ),
                  ),
                ),
                Icon(
                  _advancedExpanded ? Icons.expand_less : Icons.expand_more,
                  color: context.textMuted,
                ),
              ],
            ),
          ),
        ),
        if (_advancedExpanded) ...[const SizedBox(height: 8), ...advanced],
      ],
    );
  }

  Widget _buildSliderControl({
    required String label,
    required double value,
    required double min,
    required double max,
    bool isCurrency = false,
    bool isPercent = false,
    // MX split sliders: the value is NATIVE money in this ISO currency —
    // rendered code-prefixed ("USD 12,000" / "MXN 400,000") with NO
    // display-currency conversion, since the split is defined per currency.
    String? currencyCode,
    int? divisions,
    String? hint,
    String? help,
    String? caption,
    VoidCallback? onTapValue,
    required ValueChanged<double> onChanged,
    required ValueChanged<double> onChangeEnd,
  }) {
    String displayValue;
    if (isPercent) {
      displayValue = formatPercent(context, value * 100, digits: 1);
    } else if (currencyCode != null) {
      displayValue = displayCurrencyWithCode(value, currencyCode);
    } else if (isCurrency) {
      final reported = value * widget.conversionFactor;
      displayValue = widget.currencyFormat.displayMoney(reported);
    } else {
      displayValue = value.toInt().toString();
    }

    // U2: the value label doubles as the typed-entry affordance — a dotted
    // underline hints it's tappable; the tap opens the numeric dialog.
    final valueText = Text(
      displayValue,
      style: TextStyle(
        color: context.positive,
        fontWeight: FontWeight.bold,
        decoration: onTapValue != null ? TextDecoration.underline : null,
        decorationStyle: onTapValue != null ? TextDecorationStyle.dotted : null,
        decorationColor: context.positive,
      ),
    );

    // A6 (round 3, a11y): the aria dump showed anonymous sliders — merge
    // label + help + value + slider into one node so each slider announces
    // its purpose and current value.
    return MergeSemantics(
      child: Column(
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
                    if (help != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2, right: 8),
                        child: Text(
                          help,
                          style: TextStyle(
                            color: context.textFaint,
                            fontSize: 11,
                            height: 1.25,
                          ),
                        ),
                      ),
                    if (hint != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: Row(
                          children: [
                            Icon(
                              Icons.auto_awesome,
                              size: 11,
                              color: context.info,
                            ),
                            const SizedBox(width: 4),
                            // Flexible so longer hints (F3's provenance /
                            // estimate wording) wrap instead of overflowing
                            // the 320px controls column.
                            Flexible(
                              child: Text(
                                hint,
                                style: TextStyle(
                                  color: context.info,
                                  fontSize: 11,
                                  fontStyle: FontStyle.italic,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              if (onTapValue == null)
                valueText
              else
                InkWell(
                  onTap: onTapValue,
                  borderRadius: BorderRadius.circular(6),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 4,
                      vertical: 2,
                    ),
                    child: valueText,
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
          // U3: live caption under the slider (savings rate vs income).
          if (caption != null)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                caption,
                style: TextStyle(color: context.textMuted, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }

  // U2: numeric entry behind a money slider's value label — type an exact
  // figure instead of scrubbing. The dialog works in the *display* currency
  // (like _GoalDialog); the commit converts back to USD and routes through
  // the same _assumptionChanged() path as a slider drag (persist + one
  // debounced refetch).
  Future<void> _editMoneyValue({
    required String label,
    required double currentUsd,
    required double minUsd,
    required void Function(double usd) commit,
  }) async {
    final l = AppLocalizations.of(context);
    final cf = widget.conversionFactor == 0 ? 1.0 : widget.conversionFactor;
    final minDisplay = minUsd * cf;
    final maxDisplay = _typedMoneyCap * cf;
    final result = await showDialog<double>(
      context: context,
      builder: (_) => _ValueEntryDialog(
        title: label,
        initialValue: (currentUsd * cf).round().toString(),
        prefixText: widget.currencyFormat.currencySymbol,
        min: minDisplay,
        max: maxDisplay,
        // gen-l10n: explicit arb placeholders keep the (min, max) declaration
        // order in the generated signature (same pattern as projGoalYearRange).
        rangeError: l.projValueEntryRange(
          widget.currencyFormat.displayMoney(minDisplay),
          widget.currencyFormat.displayMoney(maxDisplay),
        ),
      ),
    );
    if (!mounted || result == null) return;
    setState(() => commit(result / cf));
    _assumptionChanged();
  }

  // Typed entry for a NATIVE-currency money slider (the MX split): the
  // dialog works in that currency directly — no display-currency conversion
  // on either side, unlike _editMoneyValue. Same debounced
  // _assumptionChanged() commit path as every other control.
  Future<void> _editNativeMoneyValue({
    required String label,
    required double current,
    required String code,
    required void Function(double v) commit,
  }) async {
    final l = AppLocalizations.of(context);
    final result = await showDialog<double>(
      context: context,
      builder: (_) => _ValueEntryDialog(
        title: label,
        initialValue: current.round().toString(),
        prefixText: '${code.toUpperCase()} ',
        min: 0,
        max: _typedMoneyCap,
        // gen-l10n: explicit arb placeholders keep the (min, max) declaration
        // order in the generated signature (same pattern as projGoalYearRange).
        rangeError: l.projValueEntryRange(
          displayCurrencyWithCode(0, code),
          displayCurrencyWithCode(_typedMoneyCap, code),
        ),
      ),
    );
    if (!mounted || result == null) return;
    setState(() => commit(result));
    _assumptionChanged();
  }

  /// U5: percent slider value as dialog text, in percent units with float
  /// noise trimmed — 0.07 → "7", 0.085 → "8.5".
  static String _percentText(double fraction) {
    final pct = double.parse((fraction * 100).toStringAsFixed(2));
    return pct == pct.roundToDouble() ? pct.round().toString() : pct.toString();
  }

  // U5: typed entry behind a percent slider's value label. The dialog works
  // in percent units (type "8.5" for 8.5%); the commit converts back to the
  // fraction the sliders hold. Unlike the money sliders, the slider min/max
  // are HARD limits — a value outside them shows the inline range error, the
  // slider never grows. Commits route through the same debounced
  // _assumptionChanged() path as a drag.
  Future<void> _editPercentValue({
    required String label,
    required double currentFraction,
    required double minFraction,
    required double maxFraction,
    required void Function(double fraction) commit,
  }) async {
    final l = AppLocalizations.of(context);
    final result = await showDialog<double>(
      context: context,
      builder: (_) => _ValueEntryDialog(
        title: label,
        initialValue: _percentText(currentFraction),
        suffixText: '%',
        min: minFraction * 100,
        max: maxFraction * 100,
        // gen-l10n: explicit arb placeholders keep the (min, max) declaration
        // order in the generated signature (same pattern as projValueEntryRange).
        rangeError: l.projValueEntryRangePercent(
          formatPercent(context, minFraction * 100, digits: 0),
          formatPercent(context, maxFraction * 100, digits: 0),
        ),
      ),
    );
    if (!mounted || result == null) return;
    setState(() => commit(result / 100));
    _assumptionChanged();
  }

  // U5: typed entry behind a whole-year slider's value label (years to
  // retirement, projection years). Integers only — a fractional entry like
  // "12.5" is rejected with the inline whole-number error, never clamped —
  // and the slider bounds are hard limits, like the percent sliders.
  Future<void> _editYearsValue({
    required String label,
    required int current,
    required int min,
    required int max,
    required void Function(int years) commit,
  }) async {
    final l = AppLocalizations.of(context);
    final result = await showDialog<double>(
      context: context,
      builder: (_) => _ValueEntryDialog(
        title: label,
        initialValue: current.toString(),
        integerOnly: true,
        min: min.toDouble(),
        max: max.toDouble(),
        // gen-l10n: explicit arb placeholders keep the (min, max) declaration
        // order in the generated signature (same pattern as projValueEntryRange).
        rangeError: l.projValueEntryWholeYears(min, max),
      ),
    );
    if (!mounted || result == null) return;
    setState(() => commit(result.round()));
    _assumptionChanged();
  }

  // Guyton-Klinger guardrails toggle: when on, the Monte Carlo flexes
  // retirement spending with the market, which lifts the success rate.
  Widget _buildGuardrailsToggle() {
    final l = AppLocalizations.of(context);
    // A6 (round 3, a11y): label + status text merge into the switch node
    // (the aria dump showed an anonymous switch here).
    return MergeSemantics(
      child: Row(
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
              _assumptionChanged();
            },
          ),
        ],
      ),
    );
  }

  // "Retire in Mexico" scenario toggle (same row pattern as the guardrails
  // toggle). Turning it on swaps the single expense slider for the USD/MXN
  // split + FX-drift controls and re-runs the projection through the
  // backend's input-transformation layer.
  Widget _buildMxToggle() {
    final l = AppLocalizations.of(context);
    // A6-style a11y: label + status text merge into the switch node.
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.projMxToggle,
                  style: TextStyle(color: context.textMuted, fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  _mxScenario ? l.projMxToggleOn : l.projMxToggleOff,
                  style: TextStyle(color: context.textFaint, fontSize: 11),
                ),
              ],
            ),
          ),
          Switch(
            value: _mxScenario,
            activeThumbColor: context.positive,
            onChanged: _toggleMxScenario,
          ),
        ],
      ),
    );
  }

  void _toggleMxScenario(bool v) {
    setState(() {
      _mxScenario = v;
      if (v && !_mxSeeded) {
        // First activation: seed the split as ALL-MXN at today's rate —
        // the same effective spending, so with the default 0% drift the
        // toggle is an identity (FI number unchanged) until the user moves
        // the split or the drift. Rounded to a clean MXN 1,000.
        _mxMxnPortion =
            ((_annualExpenses * _fxRateOrFallback) / 1000).round() * 1000.0;
        _mxUsdPortion = 0.0;
        _mxSeeded = true;
        _mxMxnMax = _grownMax(_mxMxnMax, _mxMxnPortion, 100000.0);
      }
    });
    _assumptionChanged();
  }

  // O2: "Show dividend income outlook" advanced toggle (same row pattern as
  // the guardrails toggle above). Purely presentational — flipping it only
  // reveals/hides the informational panel under the chart; it never triggers
  // a projection re-fetch, so the request params and the balance curve are
  // byte-identical with the toggle on or off. Disabled (with a tooltip) when
  // the portfolio has no projected dividend income.
  Widget _buildDividendOutlookToggle() {
    final l = AppLocalizations.of(context);
    final available = _dividendOutlookAvailable;
    final toggle = Switch(
      value: _showDividendOutlook && available,
      activeThumbColor: context.positive,
      onChanged: available
          ? (v) => setState(() => _showDividendOutlook = v)
          : null,
    );
    // A6 (round 3, a11y): label + help text + switch merge into one
    // toggleable node so the switch isn't an anonymous on/off control.
    return MergeSemantics(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l.proj3ShowDividends,
                  style: TextStyle(color: context.textMuted, fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  l.proj3ShowDividendsHelp,
                  style: TextStyle(color: context.textFaint, fontSize: 11),
                ),
              ],
            ),
          ),
          if (available)
            toggle
          else
            Tooltip(
              message: l.proj3ShowDividendsUnavailable,
              triggerMode: TooltipTriggerMode.tap,
              child: toggle,
            ),
        ],
      ),
    );
  }

  // Median (p50) projected balance at `year`, in real USD — straight from
  // the Monte Carlo fan the screen has ALREADY fetched; falls back to the
  // deterministic expected path when the fan is unavailable. Read-only over
  // existing data: computing the outlook never issues a request.
  double? _medianBalanceAtYear(int year) {
    final data = _projectionData;
    if (data == null) return null;
    final mc = data['monte_carlo'] as Map<String, dynamic>?;
    final pcts = (mc?['percentiles'] as List<dynamic>?) ?? const [];
    for (final p in pcts) {
      if (p is Map && ((p['year'] as num?)?.round() ?? -1) == year) {
        final v = (p['p50'] as num?)?.toDouble();
        if (v != null) return v;
      }
    }
    // Fallback: last expected-path sample at or before the requested year.
    final points = (data['points'] as List<dynamic>?) ?? const [];
    double? best;
    var bestX = double.negativeInfinity;
    for (final p in points) {
      if (p is! Map) continue;
      final x =
          ((p['year'] as num?)?.toDouble() ?? 0) +
          ((p['month'] as num?)?.toDouble() ?? 0) / 12.0;
      if (x <= year + 1e-6 && x > bestX) {
        bestX = x;
        best = (p['balance'] as num?)?.toDouble();
      }
    }
    return best;
  }

  // O2: the dividend income outlook panel — glossary-card chrome, three
  // stat rows (today / at retirement / at horizon), each = the CURRENT
  // blended yield × the median projected balance at that point, plus the
  // mandatory "already part of total return" disclaimer. Derived entirely
  // client-side from data the screen already holds; it respects the
  // real-vs-nominal switch exactly like the chart does (_nominalFactor).
  Widget _buildDividendOutlookPanel() {
    final l = AppLocalizations.of(context);
    final data = _dividendData;
    if (data == null || _projectionData == null) {
      return const SizedBox.shrink();
    }
    final incomeUsd = _dividendIncomeUsd;
    final yieldPct = (data['blended_yield_pct'] as num?)?.toDouble();
    // Yield as a fraction. When the backend didn't emit a blended yield,
    // derive it from income ÷ starting balance — the projection starts at
    // currentNetWorth, so this keeps the three rows internally consistent.
    final yieldFrac = yieldPct != null
        ? yieldPct / 100.0
        : (widget.currentNetWorth > 0
              ? incomeUsd / widget.currentNetWorth
              : null);

    final yearsToRet = _yearsToRetirement.clamp(0, _projectionYears);
    final nowYear = DateTime.now().year;
    // Income at a horizon = yield × median projected balance there. Balances
    // are real USD; conversionFactor + _nominalFactor mirror the chart's
    // display transform so the panel rescales with the nominal toggle.
    String? incomeAt(int years) {
      if (yieldFrac == null) return null;
      final balance = _medianBalanceAtYear(years);
      if (balance == null) return null;
      final display =
          balance *
          yieldFrac *
          widget.conversionFactor *
          _nominalFactor(years.toDouble());
      return widget.currencyFormat.displayMoney(display);
    }

    final todayIncome = widget.currencyFormat.displayMoney(
      incomeUsd * widget.conversionFactor,
    );
    final retIncome = incomeAt(yearsToRet);
    final horizonIncome = incomeAt(_projectionYears);

    final valueStyle = TextStyle(
      color: context.textPrimary,
      fontWeight: FontWeight.w700,
      fontSize: 13.5,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget row(String label, String value, {String? sub}) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(color: context.textMuted, fontSize: 13),
                ),
                if (sub != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 1),
                    child: Text(
                      sub,
                      style: TextStyle(
                        color: context.textFaint,
                        fontSize: 11,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(value, style: valueStyle),
        ],
      ),
    );

    // A6 (round 3, a11y): the panel node carries an "informational" hint so
    // assistive tech hears its honesty caveat up front; the rows inside stay
    // individually readable.
    return Semantics(
      container: true,
      hint: l.axInformational,
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.payments_outlined,
                    size: 18,
                    color: context.positive,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.proj3OutlookTitle,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  // Dollar-basis caption, consistent with the header badge:
                  // "in today's dollars" in real mode, the nominal note when
                  // the nominal toggle rescales the figures.
                  Text(
                    _showNominal ? l.projNominalNote : l.proj3InTodaysDollars,
                    style: TextStyle(color: context.textFaint, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Divider(color: context.hairline, height: 1),
              row(
                l.proj3RowToday,
                l.proj3PerYear(todayIncome),
                sub: yieldPct != null
                    ? l.proj3BlendedYieldNote(yieldPct.toStringAsFixed(2))
                    : null,
              ),
              if (retIncome != null)
                row(
                  l.proj3RowRetirement('${nowYear + yearsToRet}'),
                  l.proj3PerYearApprox(retIncome),
                ),
              if (horizonIncome != null)
                row(
                  l.proj3RowHorizon('${nowYear + _projectionYears}'),
                  l.proj3PerYearApprox(horizonIncome),
                ),
              const SizedBox(height: 12),
              Text(
                l.proj3DisclaimerBody,
                style: TextStyle(
                  color: context.textMuted,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// The backend's "Retire in Mexico" block, present only when the last
  /// projection ran with the scenario on.
  Map<String, dynamic>? get _mxResult =>
      _projectionData?['mx_scenario'] as Map<String, dynamic>?;

  bool get _mxPanelOn => _mxScenario && _mxResult != null;

  // "Retire in Mexico" results panel — dividend-outlook chrome: the FI number
  // and projected retirement income restated in BOTH currencies at the
  // projected at-retirement rate, plus the effective spend the engine ran
  // with and the rate/drift provenance line. Values come straight from the
  // backend block (never re-derived client-side) so panel and chart can't
  // disagree.
  Widget _buildMxScenarioPanel() {
    final l = AppLocalizations.of(context);
    final mx = _mxResult;
    if (mx == null) return const SizedBox.shrink();
    double f(String k) => (mx[k] as num?)?.toDouble() ?? 0.0;

    // All four figures are at-retirement constructs, so in nominal mode they
    // inflate to the retirement year — same rule as the FIRE plan card.
    final atRet = _nominalFactor(_yearsToRetirement.toDouble());
    String both(double usd, double mxn) =>
        '${displayCurrencyWithCode(usd * atRet, 'USD')} · '
        '${displayCurrencyWithCode(mxn * atRet, 'MXN')}';

    final valueStyle = TextStyle(
      color: context.textPrimary,
      fontWeight: FontWeight.w700,
      fontSize: 13.5,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(color: context.textMuted, fontSize: 13),
            ),
          ),
          const SizedBox(width: 12),
          Text(value, style: valueStyle),
        ],
      ),
    );

    // gen-l10n orders these alphabetically → (now, retire); the template
    // reads "{now} today → {retire} at retirement", same order.
    final rateLine = l.projMxRateLine(
      localizeNumberString(context, f('fx_rate_today').toStringAsFixed(2)),
      localizeNumberString(
        context,
        f('fx_rate_at_retirement').toStringAsFixed(2),
      ),
    );

    return Semantics(
      container: true,
      hint: l.axInformational,
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(Icons.public_rounded, size: 18, color: context.info),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      l.projMxPanelTitle,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  // Dollar-basis caption, consistent with the header badge.
                  Text(
                    _showNominal ? l.projNominalNote : l.proj3InTodaysDollars,
                    style: TextStyle(color: context.textFaint, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Divider(color: context.hairline, height: 1),
              row(l.projFiNumber, both(f('fi_number_usd'), f('fi_number_mxn'))),
              row(
                l.projMxIncomeRow,
                both(
                  f('monthly_income_at_retirement_usd'),
                  f('monthly_income_at_retirement_mxn'),
                ),
              ),
              row(
                l.projMxEffectiveSpend,
                displayCurrencyWithCode(
                  f('effective_annual_expenses_usd') * atRet,
                  'USD',
                ),
              ),
              const SizedBox(height: 8),
              Text(
                rateLine,
                style: TextStyle(
                  color: context.textFaint,
                  fontSize: 11,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              const SizedBox(height: 8),
              Text(
                l.projMxDisclaimer,
                style: TextStyle(
                  color: context.textMuted,
                  fontSize: 11.5,
                  height: 1.35,
                ),
              ),
            ],
          ),
        ),
      ),
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
            // U1: pink matches the chart's goal line (it used to be yellow,
            // which collided with the amber FIRE-target dashes).
            Icon(Icons.flag_outlined, color: context.pinkAccent, size: 18),
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
                  _writeGoalSetting(null);
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
                    widget.currencyFormat.displayMoney(
                      _goalAmountUsd! * widget.conversionFactor,
                    ),
                    _goalYear!,
                  )
                : l.projGoalSetTarget,
          ),
        ),
      ],
    );
  }

  // F5: persist the goal via the injected writer (real ApiService.putSetting
  // in production). Failures used to be silently swallowed by catchError —
  // the goal *looked* saved but evaporated on the next refresh; now they
  // surface as a snackbar.
  Future<void> _writeGoalSetting(dynamic value) async {
    final write = widget.settingWriter ?? _apiService.putSetting;
    try {
      await write('net_worth_goal', value);
    } catch (_) {
      if (!mounted) return;
      final l = AppLocalizations.of(context);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(l.projGoalSaveFailed)));
    }
  }

  // F5: sanity caps for the goal dialog — an amount must be positive and at
  // most $1B (display currency), and the year within [now, now + 80].
  static const double _maxGoalAmount = 1000000000.0;
  static const int _maxGoalYearsAhead = 80;

  Future<void> _editGoal() async {
    final nowYear = DateTime.now().year;
    // The dialog owns its TextEditingControllers (a StatefulWidget disposes
    // them only after the route's exit animation tears the fields down —
    // disposing them right after showDialog resolved threw during the
    // fade-out) and pops (amount, year) only when validation passes (F5).
    final result = await showDialog<(double, int)?>(
      context: context,
      builder: (_) => _GoalDialog(
        initialAmount: _goalAmountUsd == null
            ? ''
            : (_goalAmountUsd! * widget.conversionFactor).toInt().toString(),
        initialYear: (_goalYear ?? nowYear + 10).toString(),
        currencySymbol: widget.currencyFormat.currencySymbol,
        minYear: nowYear,
        maxYear: nowYear + _maxGoalYearsAhead,
        maxAmount: _maxGoalAmount,
      ),
    );
    if (!mounted || result == null) return;
    final (reported, yr) = result;
    final usd = widget.conversionFactor == 0
        ? reported
        : reported / widget.conversionFactor;
    setState(() {
      _goalAmountUsd = usd;
      _goalYear = yr;
    });
    Preferences.setGoalAmountUsd(usd);
    Preferences.setGoalYear(yr);
    await _writeGoalSetting({'amount_usd': usd, 'year': yr});
  }

  Widget _buildChartCard() {
    final l = AppLocalizations.of(context);
    final pad = MediaQuery.sizeOf(context).width < 720 ? 16.0 : 24.0;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: EdgeInsets.all(pad),
        child: LayoutBuilder(
          builder: (context, box) {
            // Two hosting contexts: the desktop flex branch grants a bounded
            // height (the plot fills it, as before), while the phone scroll
            // column is unbounded — there the card sizes itself with a
            // guaranteed, width-derived plot height. The old fixed
            // SizedBox(320) around this card let a wrapped legend (es-MX with
            // band + goal on) starve the Expanded plot to a sliver.
            final bounded = box.maxHeight.isFinite;
            final chartHeight = (box.maxWidth * 0.55).clamp(220.0, 320.0);
            Widget plotSized(Widget child) => bounded
                ? Expanded(child: child)
                : SizedBox(height: chartHeight, child: child);

            if (_isLoading) {
              const spinner = Center(child: CircularProgressIndicator());
              return bounded
                  ? spinner
                  : SizedBox(height: chartHeight, child: spinner);
            }
            // F2: a failed load with nothing cached used to leave a silently
            // blank card (empty Container from _buildChart, shrunk FIRE strip
            // and tiles). Say so, and offer a retry.
            if (_loadFailed && _projectionData == null) {
              final error = _buildLoadError(l);
              return bounded
                  ? error
                  : SizedBox(height: chartHeight, child: error);
            }
            return Column(
              mainAxisSize: bounded ? MainAxisSize.max : MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        l.projNetWorthProjection,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
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
                _buildChartLegend(l),
                const SizedBox(height: 18),
                plotSized(RepaintBoundary(child: _buildChart())),
              ],
            );
          },
        ),
      ),
    );
  }

  // F2: error state for the chart card — a failed fetch with no cached data
  // explains itself and offers a retry instead of a blank card.
  Widget _buildLoadError(AppLocalizations l) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_rounded, size: 32, color: context.textMuted),
          const SizedBox(height: 12),
          Text(
            l.projLoadFailed,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.textMuted, fontSize: 14),
          ),
          const SizedBox(height: 12),
          FilledButton.tonal(
            onPressed: _fetchProjection,
            child: Text(l.projRetry),
          ),
        ],
      ),
    );
  }

  // Names every line on the chart so the dashed lines aren't a mystery: the
  // solid projected path, the focused FIRE target (colour-matched to the
  // plan card), the optional user goal, and the uncertainty band.
  Widget _buildChartLegend(AppLocalizations l) {
    final (Color targetColor, String flavor) = switch (_fireFocus) {
      _FireFocus.full => (context.warning, l.projFocusFull),
      _FireFocus.coast => (context.info, l.projTermCoast),
      _FireFocus.barista => (context.purpleAccent, l.projTermBarista),
    };
    Widget line(Color c, String label, {bool dashed = false}) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 16,
          height: 3,
          child: dashed
              ? Row(
                  // 3 dashes of 4px + two 2px gaps = exactly the 16px box
                  // (a trailing margin overflowed it by 2px).
                  children: List.generate(
                    3,
                    (i) => Container(
                      width: 4,
                      height: 3,
                      margin: EdgeInsets.only(right: i == 2 ? 0 : 2),
                      decoration: BoxDecoration(
                        color: c,
                        borderRadius: BorderRadius.circular(1),
                      ),
                    ),
                  ),
                )
              : Container(
                  decoration: BoxDecoration(
                    color: c,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
        ),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(color: context.textFaint, fontSize: 11)),
      ],
    );
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Wrap(
        spacing: 16,
        runSpacing: 6,
        children: [
          line(context.positive, l.projLegendProjected),
          line(targetColor, l.projLegendTarget(flavor), dashed: true),
          // U1: pink, matching the goal line/markers — deliberately distinct
          // from the amber Full-FIRE target dashes.
          if (_goalAmountUsd != null)
            line(context.pinkAccent, l.projLegendGoal, dashed: true),
          if (_showBand)
            Row(
              mainAxisSize: MainAxisSize.min,
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
                  style: TextStyle(color: context.textFaint, fontSize: 11),
                ),
              ],
            ),
        ],
      ),
    );
  }

  // Convert a yearly Monte Carlo percentile series to chart spots (in the
  // active display currency).
  List<FlSpot> _percentileSpots(List<dynamic> pcts, String key) {
    return pcts.map((p) {
      final x = (p['year'] as num).toDouble();
      final y =
          (p[key] as num).toDouble() *
          widget.conversionFactor *
          _nominalFactor(x);
      return FlSpot(x, y);
    }).toList();
  }

  Widget _buildChart() {
    final l = AppLocalizations.of(context);
    if (_projectionData == null) return Container();

    final points = _projectionData!['points'] as List<dynamic>;
    final fm = _projectionData!['fire_metrics'] as Map<String, dynamic>;
    final fiNumber = (fm['fi_number'] as num?)?.toDouble() ?? 0.0;
    final coastNumber = (fm['coast_fi_number'] as num?)?.toDouble() ?? 0.0;
    final baristaNumber = (fm['barista_fi_number'] as num?)?.toDouble() ?? 0.0;
    // The dashed target line + its colour track the focused FIRE flavor, so
    // switching the focus chips visibly moves the goalpost on the chart.
    final (double targetValue, Color targetColor) = switch (_fireFocus) {
      _FireFocus.full => (fiNumber, context.warning),
      _FireFocus.coast => (
        coastNumber > 0 ? coastNumber : fiNumber,
        context.info,
      ),
      // F8: with $0 barista income the backend returns barista_fi_number ==
      // fi_number, so "less than the full FI number" is the real signal that
      // barista income is configured — not merely "> 0".
      _FireFocus.barista => (
        baristaNumber > 0 && baristaNumber < fiNumber
            ? baristaNumber
            : fiNumber,
        context.purpleAccent,
      ),
    };

    // Expected (deterministic, real-return) path — the bold headline line.
    final spots = points.map((p) {
      final x =
          (p['year'] as num).toDouble() + (p['month'] as num).toDouble() / 12.0;
      final y =
          (p['balance'] as num).toDouble() *
          widget.conversionFactor *
          _nominalFactor(x);
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

    // A horizontal real-dollar target (FI number, goal) reads as a flat line in
    // real mode, but in nominal mode the *same* real target costs more future
    // dollars each year, so it becomes a rising (1+i)^t curve. Sample it yearly
    // so the curve is smooth and stays consistent with the inflated chart path.
    List<FlSpot> targetSpots(double realUsd) {
      final base = realUsd * widget.conversionFactor;
      if (!_showNominal) {
        return [FlSpot(0, base), FlSpot(_projectionYears.toDouble(), base)];
      }
      return List.generate(
        _projectionYears + 1,
        (t) => FlSpot(t.toDouble(), base * _nominalFactor(t.toDouble())),
      );
    }

    // U1: the y-range comes from the projection itself (expected path,
    // uncertainty band, focused FIRE target) and NEVER from the user goal —
    // a huge goal used to rescale the axis and flatten the whole chart. An
    // out-of-range goal instead clamps to the top edge as a labelled dashed
    // line, and its vertical year marker still shows.
    double maxOf(Iterable<FlSpot> s) => s.fold(0.0, (m, e) => math.max(m, e.y));
    final fireTargetSpots = targetSpots(targetValue);
    var chartMaxY = math.max(maxOf(spots), maxOf(fireTargetSpots));
    if (hasBand) chartMaxY = math.max(chartMaxY, maxOf(p90));
    if (chartMaxY <= 0) chartMaxY = 1.0;

    // The goal is deliberately NOT amber/yellow: the focused FIRE target
    // line is amber (context.warning) for Full FIRE, and the two dashed
    // lines were near-indistinguishable. Pink is unused on this chart.
    final goalColor = context.pinkAccent;
    final goalBase = _goalAmountUsd != null
        ? _goalAmountUsd! * widget.conversionFactor
        : null;
    // Whole goal line above the plot? (In nominal mode the goal curve rises
    // with (1+i)^t, so its year-0 base is its minimum.)
    final goalOffChart = goalBase != null && goalBase > chartMaxY;
    final goalSpots = _goalAmountUsd == null
        ? const <FlSpot>[]
        : [
            for (final s in targetSpots(_goalAmountUsd!))
              FlSpot(s.x, math.min(s.y, chartMaxY)),
          ];

    // A6 (round 3, a11y): the canvas chart is opaque to screen readers —
    // announce one summary sentence ("Projected balance from 2026 to 2056,
    // median ending $2.4M") and exclude the chart internals. The median
    // comes from the same fan/fallback the dividend outlook uses; the
    // display transform (currency + nominal toggle) mirrors the plot.
    final endBalanceUsd = _medianBalanceAtYear(_projectionYears);
    final endDisplay = endBalanceUsd != null
        ? endBalanceUsd *
              widget.conversionFactor *
              _nominalFactor(_projectionYears.toDouble())
        : (spots.isNotEmpty ? spots.last.y : 0.0);
    final nowYear = DateTime.now().year;
    final chartSummary = l.axProjectionChart(
      '$nowYear',
      '${nowYear + _projectionYears}',
      widget.currencyFormat.displayMoney(endDisplay),
    );

    // U1: structural markers — a dashed vertical at retirement (the
    // accumulation→drawdown kink) and, when a goal is set, at the goal year.
    // The clamped-goal horizontal line carries the goal amount when the goal
    // sits above the y-range (see chartMaxY above).
    final retireX = _yearsToRetirement.clamp(0, _projectionYears);
    final goalX = _goalYear != null ? (_goalYear! - nowYear).toDouble() : null;
    final extraLines = ExtraLinesData(
      verticalLines: [
        if (retireX > 0 && retireX < _projectionYears)
          VerticalLine(
            x: retireX.toDouble(),
            color: context.textSubtle,
            strokeWidth: 1,
            dashArray: [4, 4],
            label: VerticalLineLabel(
              show: true,
              alignment: Alignment.topRight,
              padding: const EdgeInsets.only(left: 4, bottom: 2),
              style: TextStyle(color: context.textSubtle, fontSize: 10),
              labelResolver: (_) => l.projRetirementMarker,
            ),
          ),
        if (_goalAmountUsd != null &&
            goalX != null &&
            goalX > 0 &&
            goalX <= _projectionYears)
          VerticalLine(
            x: goalX,
            color: goalColor.withValues(alpha: 0.75),
            strokeWidth: 1,
            dashArray: [3, 6],
          ),
      ],
      horizontalLines: [
        if (goalOffChart)
          HorizontalLine(
            y: chartMaxY,
            color: goalColor.withValues(alpha: 0.75),
            strokeWidth: 2,
            dashArray: [3, 6],
            label: HorizontalLineLabel(
              show: true,
              alignment: Alignment.topRight,
              padding: const EdgeInsets.only(right: 6, bottom: 2),
              style: TextStyle(color: goalColor, fontSize: 10),
              labelResolver: (_) => l.projGoalOffChart(
                // House compact money — compactSimpleCurrency shows a bare
                // "$" for MXN (see compactMoney).
                compactMoney(
                  goalBase,
                  widget.currencyFormat.currencyName ?? 'USD',
                ),
              ),
            ),
          ),
      ],
    );

    // U6: the bar list is assembled up front so the screen-owned hover state
    // can be re-applied to it (showingIndicators / showingTooltipIndicators)
    // on every rebuild — fl_chart's built-in touch state is bypassed.
    final rawBars = <LineChartBarData>[
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
      // Focused FIRE target line (Full / Coast / Barista)
      LineChartBarData(
        spots: fireTargetSpots,
        isCurved: false,
        color: targetColor.withValues(alpha: 0.7),
        barWidth: 2,
        dashArray: [5, 5],
        dotData: const FlDotData(show: false),
      ),
      // User-set goal line (pink — distinct from the amber FIRE target).
      // When the whole goal sits above the y-range the labelled
      // HorizontalLine in extraLines stands in for it instead.
      if (_goalAmountUsd != null && !goalOffChart)
        LineChartBarData(
          spots: goalSpots,
          isCurved: false,
          color: goalColor.withValues(alpha: 0.75),
          barWidth: 2,
          dashArray: [3, 6],
          dotData: const FlDotData(show: false),
        ),
    ];

    // Drop any stored spot that no longer points inside the current bars
    // (band toggled off, goal cleared, shorter horizon…).
    final touchedSpots = <LineBarSpot>[
      for (final s in _chartTouchedSpots ?? const <LineBarSpot>[])
        if (s.barIndex < rawBars.length &&
            s.spotIndex < rawBars[s.barIndex].spots.length)
          s,
    ];
    final lineBars = <LineChartBarData>[
      for (var i = 0; i < rawBars.length; i++)
        rawBars[i].copyWith(
          showingIndicators: [
            for (final s in touchedSpots)
              if (s.barIndex == i) s.spotIndex,
          ],
        ),
    ];

    return LayoutBuilder(
      builder: (context, plot) {
        // F7: adaptive x-label step computed off the inner plot width (this
        // builder's constraint minus the 60px reserved for y labels) — a fixed
        // `interval: 5` overlapped labels on phones with long horizons.
        final xInterval = projectionYearAxisInterval(
          plotWidth: math.max(0.0, plot.maxWidth - 60.0),
          projectionYears: _projectionYears,
        );
        return Semantics(
          container: true,
          label: chartSummary,
          child: ExcludeSemantics(
            child: LineChart(
              LineChartData(
                gridData: FlGridData(
                  show: true,
                  drawVerticalLine: false,
                  getDrawingHorizontalLine: (value) =>
                      FlLine(color: context.hairline, strokeWidth: 1),
                ),
                titlesData: FlTitlesData(
                  rightTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  topTitles: const AxisTitles(
                    sideTitles: SideTitles(showTitles: false),
                  ),
                  bottomTitles: AxisTitles(
                    sideTitles: SideTitles(
                      showTitles: true,
                      interval: xInterval,
                      // U1: calendar years ("2026, 2031, …"), unifying the axis with
                      // the a11y summary and the dividend panel, which already speak
                      // in calendar years. Locale-neutral, so no l10n key needed.
                      getTitlesWidget: (value, meta) => Padding(
                        padding: const EdgeInsets.only(top: 8.0),
                        child: Text(
                          '${nowYear + value.round()}',
                          style: TextStyle(
                            color: context.textSubtle,
                            fontSize: 12,
                          ),
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
                        // F6: compact *currency* ticks (skill §5) — a bare "1.5M"
                        // carried no currency and used Spain-style separators in es.
                        // House compact ticks — compactSimpleCurrency shows a bare
                        // "$" for MXN (see compactMoney).
                        return Text(
                          compactMoney(
                            value,
                            widget.currencyFormat.currencyName ?? 'USD',
                          ),
                          style: TextStyle(
                            color: context.textSubtle,
                            fontSize: 10,
                          ),
                        );
                      },
                    ),
                  ),
                ),
                borderData: FlBorderData(show: false),
                // U1: explicit top-of-range (goal excluded — see chartMaxY) + the
                // retirement/goal markers.
                maxY: chartMaxY,
                extraLinesData: extraLines,
                betweenBarsData: betweenBars,
                lineBarsData: lineBars,
                // U6: screen-owned tooltip state (see _chartTouchedSpots). The spots
                // arrive pre-sorted by y like the built-in handling produced, so the
                // tooltip renders identically.
                showingTooltipIndicators: touchedSpots.isEmpty
                    ? const []
                    : [ShowingTooltipIndicators(touchedSpots)],
                lineTouchData: LineTouchData(
                  touchSpotThreshold: 100000,
                  distanceCalculator: (touchPoint, spotPixelCoordinates) =>
                      (touchPoint.dx - spotPixelCoordinates.dx).abs(),
                  // U6: built-in touch handling left the tooltip pinned after the
                  // pointer exited the chart — the screen owns the state instead and
                  // clears it on any dismissing event (pointer exit, pan end,
                  // long-press end, and — via chartTouchDismisses — the finger-lift
                  // tap-up that fl_chart's own gating keeps "interested" on mobile
                  // web, which pinned the tooltip there).
                  handleBuiltInTouches: false,
                  touchCallback: (event, response) {
                    final spots = response?.lineBarSpots;
                    if (chartTouchDismisses(event) ||
                        spots == null ||
                        spots.isEmpty) {
                      if (_chartTouchedSpots != null) {
                        setState(() => _chartTouchedSpots = null);
                      }
                      return;
                    }
                    // Same y-descending order the built-in handler used, so the
                    // tooltip rows / anchor spot are unchanged.
                    final sorted = List<LineBarSpot>.of(spots)
                      ..sort((a, b) => b.y.compareTo(a.y));
                    if (!_sameTouchedSpots(sorted)) {
                      setState(() => _chartTouchedSpots = sorted);
                    }
                  },
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
                                strokeColor: Theme.of(
                                  context,
                                ).colorScheme.surface,
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
                          // gen-l10n orders placeholders alphabetically (amount, year)
                          // regardless of their order in the template string, so pass
                          // amount first — otherwise the two render swapped.
                          // U1: calendar year, rounded — "2040 · $894,514", never
                          // "Year 19.2".
                          l.projTooltipYearAmount(
                            widget.currencyFormat.displayMoney(spot.y),
                            '${(nowYear + spot.x).round()}',
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
            ),
          ),
        );
      },
    );
  }

  // FIRE focus card: pick a flavor (Full / Coast / Barista) and the headline
  // — plus the chart's dashed target line — follow it. Replaces the old
  // passive strip; answers "why Coast?" by making it one option among peers.
  Widget _buildFireStatusStrip() {
    final l = AppLocalizations.of(context);
    if (_projectionData == null) return const SizedBox.shrink();
    final m = _projectionData!['fire_metrics'] as Map<String, dynamic>;
    final fiNumber = (m['fi_number'] as num?)?.toDouble() ?? 0.0;
    final coastAchieved = m['coast_fi_achieved'] == true;
    final coastNumber = (m['coast_fi_number'] as num?)?.toDouble() ?? 0.0;
    final baristaNumber = (m['barista_fi_number'] as num?)?.toDouble() ?? 0.0;
    final yearsToFi = (m['estimated_years_to_fi'] as num?)?.toDouble();

    // FIRE targets are spent *at retirement*, so in nominal mode they're shown
    // in the retirement year's dollars (consistent with the chart's target
    // line). Today's figures (current net worth) pass `atYears: 0`, which leaves
    // them untouched since (1+i)^0 = 1.
    String money(double usd, {double atYears = 0}) => widget.currencyFormat
        .displayMoney(usd * widget.conversionFactor * _nominalFactor(atYears));
    final retireYears = _yearsToRetirement.toDouble();

    // Per-focus headline content.
    final IconData icon;
    final Color color;
    final String title;
    final String number;
    final String def;
    final String take;
    // In nominal mode the Full-FIRE headline is the real FI number inflated to
    // *retirement* (years-to-retirement), while "years away" reflects
    // years-to-FI — different horizons. Caption the figure so it isn't misread
    // against the duration. Null leaves the layout untouched (real mode / other
    // focuses).
    String? horizonNote;
    switch (_fireFocus) {
      case _FireFocus.full:
        icon = Icons.flag_rounded;
        color = context.warning;
        title = l.projFocusFull;
        number = money(fiNumber, atYears: retireYears);
        if (_showNominal) {
          horizonNote = l.projNominalHorizonCaption(_yearsToRetirement);
        }
        def = l.projGlossaryFiNumberDef;
        take = yearsToFi == null
            ? l.projFullUnreachable
            : (yearsToFi <= 0
                  ? l.projFullReached
                  // F6: locale decimal seam (no-op today — es-MX uses period
                  // decimals like en).
                  : l.projFullYearsAway(
                      localizeNumberString(
                        context,
                        yearsToFi.toStringAsFixed(1),
                      ),
                    ));
      case _FireFocus.coast:
        icon = coastAchieved
            ? Icons.check_circle_rounded
            : Icons.trending_up_rounded;
        color = coastAchieved ? context.positive : context.info;
        title = l.projTermCoast;
        number = money(coastNumber, atYears: retireYears);
        def = l.projGlossaryCoastDef;
        take = coastAchieved
            ? l.projCoastReachedSub
            : l.projCoastTake(money(widget.currentNetWorth));
      case _FireFocus.barista:
        icon = Icons.local_cafe_rounded;
        color = context.purpleAccent;
        title = l.projTermBarista;
        // F8: the backend returns barista_fi_number == fi_number when barista
        // income is $0, so a figure that isn't lower than full FIRE means
        // "not configured" — show the setup prompt, not a misleading number
        // identical to the Full FIRE target.
        final baristaConfigured = baristaNumber > 0 && baristaNumber < fiNumber;
        number = baristaConfigured
            ? money(baristaNumber, atYears: retireYears)
            : '—';
        def = l.projGlossaryBaristaDef;
        take = baristaConfigured ? l.projBaristaFiSub : l.projBaristaPrompt;
    }

    Widget chip(_FireFocus f, String label) => ChoiceChip(
      label: Text(label),
      selected: _fireFocus == f,
      visualDensity: VisualDensity.compact,
      onSelected: (_) => setState(() => _fireFocus = f),
    );

    // Lifestyle presets are relative to the user's baseline spend, so
    // "Standard" matches their real expenses and Lean/Fat step around it.
    final base = (_baselineExpenses ??= _annualExpenses);
    Widget lifeChip(String key, String label) {
      final double value = _presetExpense(
        key,
        base,
      ).clamp(_expensesFloor, _expensesMax).toDouble();
      final active = (_annualExpenses - value).abs() < 500;
      return ChoiceChip(
        label: Text(label),
        selected: active,
        visualDensity: VisualDensity.compact,
        onSelected: (_) {
          setState(() => _annualExpenses = value);
          _assumptionChanged();
        },
      );
    }

    // A labelled axis row: fixed-width caption + its chips, so the Lifestyle
    // and Goal rows line up.
    Widget axis(String label, List<Widget> chips) => Row(
      children: [
        SizedBox(
          width: 64,
          child: Text(
            label,
            style: TextStyle(color: context.textFaint, fontSize: 11),
          ),
        ),
        const SizedBox(width: 4),
        Expanded(child: Wrap(spacing: 8, runSpacing: 8, children: chips)),
      ],
    );

    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l.projFirePlanTitle,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            // The lifestyle presets scale the SINGLE expense figure, which
            // the Mexico scenario ignores in favor of the USD/MXN split —
            // hide them there so an inert control can't mislead.
            if (!_mxScenario) ...[
              axis(l.projSpendingLevel, [
                lifeChip('lean', l.projPresetLean),
                lifeChip('standard', l.projPresetStandard),
                lifeChip('fat', l.projPresetFat),
              ]),
              const SizedBox(height: 10),
            ],
            axis(l.projGoalLabel, [
              chip(_FireFocus.full, l.projFocusFull),
              chip(_FireFocus.coast, l.projTermCoast),
              chip(_FireFocus.barista, l.projTermBarista),
            ]),
            const SizedBox(height: 12),
            Divider(color: context.hairline, height: 1),
            const SizedBox(height: 12),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(icon, color: color, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.baseline,
                        textBaseline: TextBaseline.alphabetic,
                        children: [
                          Text(
                            title,
                            style: TextStyle(
                              color: context.textPrimary,
                              fontWeight: FontWeight.w700,
                              fontSize: 14,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            number,
                            style: TextStyle(
                              color: color,
                              fontWeight: FontWeight.w800,
                              fontSize: 15,
                            ),
                          ),
                          if (horizonNote != null) ...[
                            const SizedBox(width: 6),
                            Text(
                              horizonNote,
                              style: TextStyle(
                                color: context.textSubtle,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        def,
                        style: TextStyle(
                          color: context.textMuted,
                          fontSize: 12,
                          height: 1.3,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        take,
                        style: TextStyle(
                          color: context.textFaint,
                          fontSize: 12,
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

    // FI number + projected-balance income are at-retirement figures; show them in retirement-
    // year dollars when nominal is on (factor is 1.0 when it's off).
    final atRetire = _nominalFactor(_yearsToRetirement.toDouble());

    // U4: the target-number tile follows the focused plan (Full / Coast /
    // Barista), mirroring the plan card — it used to pin the Full-FIRE
    // number even with Barista focused. Same F8 rule as the plan card:
    // barista_fi_number == fi_number means barista income isn't configured,
    // so show the em-dash + the setup prompt instead of a misleading figure.
    final fiNumber = (metrics['fi_number'] as num?)?.toDouble() ?? 0.0;
    final coastNumber = (metrics['coast_fi_number'] as num?)?.toDouble() ?? 0.0;
    final baristaNumber =
        (metrics['barista_fi_number'] as num?)?.toDouble() ?? 0.0;
    final baristaConfigured = baristaNumber > 0 && baristaNumber < fiNumber;
    String tileMoney(double usd) => widget.currencyFormat.displayMoney(
      usd * widget.conversionFactor * atRetire,
    );
    final (
      String targetTitle,
      String targetValue,
      String targetSub,
      IconData targetIcon,
      Color targetColor,
    ) = switch (_fireFocus) {
      _FireFocus.full => (
        l.projFiNumber,
        tileMoney(fiNumber),
        l.projTargetNetWorth,
        Icons.flag_rounded,
        context.warning,
      ),
      _FireFocus.coast => (
        l.projTermCoast,
        tileMoney(coastNumber > 0 ? coastNumber : fiNumber),
        l.projTargetNetWorth,
        Icons.trending_up_rounded,
        context.info,
      ),
      _FireFocus.barista => (
        l.projTermBarista,
        baristaConfigured ? tileMoney(baristaNumber) : '—',
        baristaConfigured ? l.projTargetNetWorth : l.projBaristaPrompt,
        Icons.local_cafe_rounded,
        context.purpleAccent,
      ),
    };

    return LayoutBuilder(
      builder: (context, constraints) {
        // Stack into 2×2 below 800px — the same cutover as the screen's narrow
        // layout, derived from this builder's own width (not MediaQuery), so
        // the 720–800px band no longer renders a clipped 4-up row (F1).
        final stacked = constraints.maxWidth < 800;
        // F12: with retirement at/after the horizon the simulation never
        // withdraws, so "chance the plan lasts" is vacuous (always ~100%) —
        // caption it honestly instead.
        final noRetirementPhase = _yearsToRetirement >= _projectionYears;
        final cards = <Widget>[
          _buildMilestoneCard(
            title: l.projSuccessRate,
            value: formatPercent(context, successRate * 100, digits: 0),
            subtitle: noRetirementPhase
                ? l.projSuccessRateNa
                : l.projSuccessRateSub,
            icon: Icons.verified_rounded,
            color: _successColor(successRate),
            compact: stacked,
          ),
          _buildMilestoneCard(
            title: targetTitle,
            value: targetValue,
            subtitle: targetSub,
            icon: targetIcon,
            color: targetColor,
            compact: stacked,
          ),
          _buildMilestoneCard(
            title: l.projYearsToFi,
            value: metrics['estimated_years_to_fi'] != null
                ? localizeNumberString(
                    context,
                    (metrics['estimated_years_to_fi'] as num).toStringAsFixed(
                      1,
                    ),
                  )
                : '∞',
            subtitle: l.projEstimate,
            icon: Icons.speed_rounded,
            color: context.info,
            compact: stacked,
          ),
          // Honesty pass: this figure is withdrawal rate × the PROJECTED balance
          // at retirement — not income at the adjacent FI number — so the title
          // and subtitle say so, and the value rounds to whole dollars
          // (wholeMoney, not displayMoney): cents would fake precision on an
          // estimate.
          _buildMilestoneCard(
            title: l.projIncomeAtProjectedBalance,
            value: widget.currencyFormat.wholeMoney(
              (metrics['monthly_income_at_retirement'] as num).toDouble() *
                  widget.conversionFactor *
                  atRetire,
            ),
            subtitle: l.projIncomeAtProjectedBalanceSub,
            icon: Icons.account_balance_wallet_rounded,
            color: context.purpleAccent,
            compact: stacked,
          ),
        ];

        if (stacked) {
          // Each 2-up row is bounded to its content height: inside the narrow
          // layout's SingleChildScrollView an unbounded stretch-Row let the
          // tiles blow up to fill infinite height and never paint (F1).
          // IntrinsicHeight keeps the two cards equal-height without a fixed
          // number that longer (es) strings could overflow.
          Widget pair(Widget a, Widget b) => IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [a, const SizedBox(width: 16), b],
            ),
          );
          return Column(
            children: [
              pair(cards[0], cards[1]),
              const SizedBox(height: 16),
              pair(cards[2], cards[3]),
            ],
          );
        }

        return Row(
          children: [
            cards[0],
            const SizedBox(width: 16),
            cards[1],
            const SizedBox(width: 16),
            cards[2],
            const SizedBox(width: 16),
            cards[3],
          ],
        );
      },
    );
  }

  Widget _buildMilestoneCard({
    required String title,
    required String value,
    required String subtitle,
    required IconData icon,
    required Color color,
    bool compact = false,
  }) {
    final pad = compact ? 16.0 : 20.0;
    return Expanded(
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        child: Padding(
          padding: EdgeInsets.all(pad),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: color, size: compact ? 28 : 32),
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

/// U2/U5: small numeric-entry dialog behind a slider's value label (same
/// StatefulWidget-owns-its-controllers pattern as [_GoalDialog], for the same
/// dispose-with-the-route reason). Works entirely in the caller's *display*
/// units — display currency for money ([prefixText] = the currency symbol),
/// percent units for rates ([suffixText] = '%'), plain integers for years
/// ([integerOnly]; a fractional entry like "12.5" is REJECTED with the inline
/// error, never clamped). Pops `null` on cancel or the validated value on
/// save. [rangeError] arrives pre-localized/pre-formatted because only the
/// caller knows how to format the min/max (money vs percent vs years).
class _ValueEntryDialog extends StatefulWidget {
  final String title;
  final String initialValue;
  final String? prefixText;
  final String? suffixText;
  final bool integerOnly;
  final double min;
  final double max;
  final String rangeError;

  const _ValueEntryDialog({
    required this.title,
    required this.initialValue,
    this.prefixText,
    this.suffixText,
    this.integerOnly = false,
    required this.min,
    required this.max,
    required this.rangeError,
  });

  @override
  State<_ValueEntryDialog> createState() => _ValueEntryDialogState();
}

class _ValueEntryDialogState extends State<_ValueEntryDialog> {
  late final TextEditingController _ctrl = TextEditingController(
    text: widget.initialValue,
  );
  String? _error;

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _save() {
    final text = _ctrl.text.trim();
    final v = double.tryParse(text);
    // U5: integer fields (years) reject fractional input outright — the
    // whole-number range error explains both failure modes.
    final wholeOk = !widget.integerOnly || int.tryParse(text) != null;
    final ok =
        v != null &&
        v.isFinite &&
        wholeOk &&
        v >= widget.min &&
        v <= widget.max;
    if (!ok) {
      setState(() => _error = widget.rangeError);
      return;
    }
    Navigator.pop(context, v);
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        controller: _ctrl,
        autofocus: true,
        keyboardType: TextInputType.numberWithOptions(
          decimal: !widget.integerOnly,
        ),
        decoration: InputDecoration(
          labelText: widget.title,
          prefixText: widget.prefixText,
          suffixText: widget.suffixText,
          errorText: _error,
        ),
        onSubmitted: (_) => _save(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: Text(l.actionCancel),
        ),
        FilledButton(onPressed: _save, child: Text(l.actionSave)),
      ],
    );
  }
}

/// F5: the "Set a target" dialog. Validates before closing — the old inline
/// dialog accepted anything ($999,999,999,999 "by 2020") — and owns its text
/// controllers so they're disposed with the route (after the exit animation),
/// not while the closing dialog is still rebuilding its fields.
///
/// Pops `null` on cancel, or the validated `(amount, year)` — amount in the
/// *display* currency; the caller converts to USD.
class _GoalDialog extends StatefulWidget {
  final String initialAmount;
  final String initialYear;
  final String currencySymbol;
  final int minYear;
  final int maxYear;
  final double maxAmount;

  const _GoalDialog({
    required this.initialAmount,
    required this.initialYear,
    required this.currencySymbol,
    required this.minYear,
    required this.maxYear,
    required this.maxAmount,
  });

  @override
  State<_GoalDialog> createState() => _GoalDialogState();
}

class _GoalDialogState extends State<_GoalDialog> {
  late final TextEditingController _amountCtrl = TextEditingController(
    text: widget.initialAmount,
  );
  late final TextEditingController _yearCtrl = TextEditingController(
    text: widget.initialYear,
  );
  String? _amountError;
  String? _yearError;

  @override
  void dispose() {
    _amountCtrl.dispose();
    _yearCtrl.dispose();
    super.dispose();
  }

  void _save() {
    final l = AppLocalizations.of(context);
    final amt = double.tryParse(_amountCtrl.text);
    final yr = int.tryParse(_yearCtrl.text);
    final amountOk = amt != null && amt > 0 && amt <= widget.maxAmount;
    final yearOk = yr != null && yr >= widget.minYear && yr <= widget.maxYear;
    if (!amountOk || !yearOk) {
      setState(() {
        _amountError = amountOk ? null : l.projGoalAmountInvalid;
        // gen-l10n generated this signature as (min, max) — explicit
        // placeholders keep their arb metadata order (verified in
        // app_localizations.dart; only synthesized placeholders get
        // alphabetized).
        _yearError = yearOk
            ? null
            : l.projGoalYearRange(widget.minYear, widget.maxYear);
      });
      return;
    }
    Navigator.pop(context, (amt, yr));
  }

  @override
  Widget build(BuildContext context) {
    final l = AppLocalizations.of(context);
    return AlertDialog(
      title: Text(l.projSetTargetTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _amountCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: l.projTargetNetWorth,
              prefixText: widget.currencySymbol,
              errorText: _amountError,
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _yearCtrl,
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: l.projTargetYear,
              errorText: _yearError,
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, null),
          child: Text(l.actionCancel),
        ),
        FilledButton(onPressed: _save, child: Text(l.actionSave)),
      ],
    );
  }
}
