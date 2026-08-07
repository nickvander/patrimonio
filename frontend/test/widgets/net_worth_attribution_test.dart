import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/utils/currency.dart';
import 'package:patrimonio/widgets/net_worth_card.dart';

/// Net-worth card: the FX / Market / Flows attribution section and the
/// FX-free chart replot it doubles as, driven by a faked
/// `getNetWorthAttribution` (mixin members are virtual — `extends ApiService`
/// + `@override` is the house fake pattern).
///
/// The control replaced a three-segment USD / MXN / Constant-FX currency lens:
/// USD and MXN duplicated the global reporting-currency switcher in the app
/// bar (and could be set to contradict the hero number above the chart), so
/// only the constant-FX read — which the global switcher cannot express —
/// survives, as a boolean that is OFF by default.
///
/// It then stopped being a control of its own: a standalone "Ignore FX moves"
/// chip floated unlabelled between the chart and the attribution section,
/// naming an action without saying what it produced, 20px above the very
/// number it removes. It is now the FX attribution chip itself — and it is
/// only offered when the replot would visibly differ from the live line
/// (`fxViewIsInformative`), because a control that redraws the same picture is
/// what made pressing it read as doing nothing.

class _FakeAttributionApi extends ApiService {
  _FakeAttributionApi({this.result, this.throwError = false});

  Map<String, dynamic>? result;
  bool throwError;
  String? lastFrom;
  String? lastTo;
  int calls = 0;

  @override
  Future<Map<String, dynamic>> getNetWorthAttribution({
    required String from,
    required String to,
    bool forceRefresh = false,
  }) async {
    calls++;
    lastFrom = from;
    lastTo = to;
    if (throwError) throw Exception('attribution unavailable');
    return result!;
  }
}

/// A month of daily history so the card's existing chrome (MoM chip, chart)
/// renders normally around the new section.
List<dynamic> _history() => [
  for (var i = 0; i < 29; i++)
    {
      'date': DateFormat(
        'yyyy-MM-dd',
      ).format(DateTime.utc(2026, 2, 1).add(Duration(days: i))),
      'net_worth': 1500.0 + i * 10,
      'total_assets': 2000.0 + i * 10,
      'total_liabilities': 500.0,
      'by_institution': const <String, dynamic>{},
    },
];

/// Attribution response shaped like the backend's: totals in USD, the
/// residual keeping fx + market + flows + residual == delta exact, plus the
/// lens series the toggle consumes.
Map<String, dynamic> _attribution({double residual = 25.0}) => {
  'from': '2026-02-01',
  'to': '2026-03-01',
  'fx_rate_open': 20.0,
  'fx_rate_close': 25.0,
  'delta_usd': 395.0 + residual,
  'flows_usd': 470.0,
  'market_usd': 125.0,
  'fx_usd': -200.0,
  'residual_usd': residual,
  'per_currency': const [],
  'series': [
    {
      'date': '2026-02-01',
      'usd': 1500.0,
      'mxn': 30000.0,
      'constant_fx_usd': 1500.0,
    },
    {
      'date': '2026-02-15',
      'usd': 1640.0,
      'mxn': 33000.0,
      'constant_fx_usd': 1620.0,
    },
    {
      'date': '2026-03-01',
      'usd': 1780.0,
      'mxn': 44500.0,
      'constant_fx_usd': 1970.0,
    },
  ],
};

Widget _host(Widget child, {Locale? locale}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

NetWorthCard _card(
  ApiService api, {
  List<dynamic>? history,
  String reportingCurrency = 'USD',
  double conversionFactor = 1.0,
}) => NetWorthCard(
  netWorth: 1780.0,
  history: history ?? _history(),
  conversionFactor: conversionFactor,
  currencyFormat: moneyFormat(reportingCurrency),
  reportingCurrency: reportingCurrency,
  sourceBreakdown: const [],
  usdMxnRate: 20.0,
  apiService: api,
);

/// The FX attribution chip's label — which is also the control's hit target,
/// since the chip IS the toggle.
const String _fxChipEn = 'FX';
const String _fxChipEs = 'Tipo de cambio';

/// The one-line hint under the chips that teaches the gesture. Present only
/// while the replot is offered and not yet applied.
const String _fxHintEn = 'Tap FX to replot the chart without currency moves';
const String _fxHintEs =
    'Toca Tipo de cambio para graficar sin los movimientos cambiarios';

/// Names the FX-free chart state (chart semantics summary).
const String _fxExcludedEn = 'Excluding FX moves';

/// Flip the FX-free replot by tapping the FX attribution chip.
Future<void> _tapFxChip(WidgetTester tester, {String label = _fxChipEn}) async {
  await tester.tap(find.text(label));
  await tester.pumpAndSettle();
}

void _useWideSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1000, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// A deliberately SPARSE history: a lone February snapshot, then a cluster in
/// March. Index-spacing hides that gap (the three points land one step apart);
/// time-spacing renders it at its real width.
const List<String> _sparseDates = [
  '2026-02-01',
  '2026-03-20',
  '2026-03-22',
  '2026-03-25',
];

/// Day offsets of [_sparseDates] from the first date — what a time-spaced
/// x-axis must produce, and what an index-spaced one (0,1,2,3) must not.
final List<double> _sparseDayOffsets = [
  for (final d in _sparseDates)
    DateTime.parse(
      d,
    ).difference(DateTime.parse(_sparseDates.first)).inDays.toDouble(),
];

List<dynamic> _sparseHistory() => [
  for (var i = 0; i < _sparseDates.length; i++)
    {
      'date': _sparseDates[i],
      'net_worth': 1500.0 + i * 100,
      'total_assets': 2000.0 + i * 100,
      'total_liabilities': 500.0,
      'by_institution': const <String, dynamic>{},
    },
];

/// The lens series over the SAME dates, so every lens plots one history.
Map<String, dynamic> _sparseAttribution() => {
  ..._attribution(),
  'from': _sparseDates.first,
  'to': _sparseDates.last,
  'series': [
    for (var i = 0; i < _sparseDates.length; i++)
      {
        'date': _sparseDates[i],
        'usd': 1500.0 + i * 100,
        'mxn': 30000.0 + i * 2000,
        'constant_fx_usd': 1500.0 + i * 90,
      },
  ],
};

/// x positions of the plotted series — the last bar is always the headline
/// line (the stacked institution bands, when present, precede it).
List<double> _plottedXs(WidgetTester tester) => tester
    .widget<LineChart>(find.byType(LineChart))
    .data
    .lineBarsData
    .last
    .spots
    .map((s) => s.x)
    .toList();

/// y values of the plotted headline series — what the chart actually claims,
/// in whatever currency it plots.
List<double> _plottedYs(WidgetTester tester) => tester
    .widget<LineChart>(find.byType(LineChart))
    .data
    .lineBarsData
    .last
    .spots
    .map((s) => s.y)
    .toList();

/// Every `Semantics` label in the tree — the chart canvas is pointer-only, so
/// its reading is mirrored into a `Semantics(label:)` node.
List<String> _semanticsLabels(WidgetTester tester) => tester
    .widgetList<Semantics>(find.byType(Semantics))
    .map((w) => w.properties.label)
    .whereType<String>()
    .toList();

void main() {
  group('x-axis mapping is the same in both toggle states', () {
    // The default chart plotted its history index-spaced while the lens
    // charts plotted the attribution series day-offset spaced. Same history,
    // two horizontal mappings: flipping the control appeared to reshape the
    // past, and a sparse March point sat one step from a tightly packed
    // cluster. Both states are time-spaced now.
    testWidgets('live-FX and ignore-FX plot the same day offsets', (
      tester,
    ) async {
      _useWideSurface(tester);
      final api = _FakeAttributionApi(result: _sparseAttribution());
      await tester.pumpWidget(_host(_card(api, history: _sparseHistory())));
      await tester.pumpAndSettle();

      // Toggle OFF — the history path, formerly index-as-x.
      expect(_plottedXs(tester), _sparseDayOffsets);
      // …and it is emphatically NOT index spacing.
      expect(_plottedXs(tester), isNot([0.0, 1.0, 2.0, 3.0]));

      await _tapFxChip(tester);
      expect(
        _plottedXs(tester),
        _sparseDayOffsets,
        reason: 'the constant-FX plot must use the same horizontal mapping',
      );

      // …and back off again.
      await _tapFxChip(tester);
      expect(_plottedXs(tester), _sparseDayOffsets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('same-day duplicate snapshots collapse to one x position', (
      tester,
    ) async {
      _useWideSurface(tester);
      final api = _FakeAttributionApi(result: _sparseAttribution());
      final history = _sparseHistory()
        ..add({
          // A second row for the last date — a time axis has exactly one
          // position per calendar day, and the LAST close wins.
          'date': _sparseDates.last,
          'net_worth': 9999.0,
          'total_assets': 9999.0,
          'total_liabilities': 0.0,
          'by_institution': const <String, dynamic>{},
        });
      await tester.pumpWidget(_host(_card(api, history: history)));
      await tester.pumpAndSettle();

      expect(_plottedXs(tester), _sparseDayOffsets);
      final spots = tester
          .widget<LineChart>(find.byType(LineChart))
          .data
          .lineBarsData
          .last
          .spots;
      expect(spots.last.y, 9999.0);
      expect(tester.takeException(), isNull);
    });
  });

  group('attribution section', () {
    testWidgets('renders all four components in English (nonzero residual)', (
      tester,
    ) async {
      _useWideSurface(tester);
      final api = _FakeAttributionApi(result: _attribution());
      await tester.pumpWidget(_host(_card(api)));
      await tester.pumpAndSettle();

      // Window derived from the selected range (all → full history span).
      expect(api.lastFrom, '2026-02-01');
      expect(api.lastTo, '2026-03-01');

      final fmt = moneyFormat('USD');
      expect(find.text('WHY IT CHANGED'), findsOneWidget);
      expect(find.text('FX'), findsOneWidget);
      expect(find.text('Market'), findsOneWidget);
      expect(find.text('Flows'), findsOneWidget);
      expect(find.text('Other'), findsOneWidget);
      expect(find.text('−${fmt.displayMoney(200.0)}'), findsOneWidget);
      expect(find.text('+${fmt.displayMoney(125.0)}'), findsOneWidget);
      expect(find.text('+${fmt.displayMoney(470.0)}'), findsOneWidget);
      expect(find.text('+${fmt.displayMoney(25.0)}'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders the component labels in es-MX', (tester) async {
      _useWideSurface(tester);
      final api = _FakeAttributionApi(result: _attribution());
      await tester.pumpWidget(_host(_card(api), locale: const Locale('es')));
      await tester.pumpAndSettle();

      expect(find.text('POR QUÉ CAMBIÓ'), findsOneWidget);
      expect(find.text('Tipo de cambio'), findsOneWidget);
      expect(find.text('Mercado'), findsOneWidget);
      expect(find.text('Flujos'), findsOneWidget);
      expect(find.text('Otro'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('folds the residual away when it is exactly zero', (
      tester,
    ) async {
      _useWideSurface(tester);
      final api = _FakeAttributionApi(result: _attribution(residual: 0.0));
      await tester.pumpWidget(_host(_card(api)));
      await tester.pumpAndSettle();

      expect(find.text('WHY IT CHANGED'), findsOneWidget);
      expect(find.text('FX'), findsOneWidget);
      // Zero residual → no "Other" chip; the honest common case stays clean.
      expect(find.text('Other'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('shows the muted error line when the fetch fails', (
      tester,
    ) async {
      _useWideSurface(tester);
      final api = _FakeAttributionApi(throwError: true);
      await tester.pumpWidget(_host(_card(api)));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't load change attribution"), findsOneWidget);
      expect(find.text('WHY IT CHANGED'), findsNothing);
      // The chart itself must survive an attribution failure.
      expect(find.byType(LineChart), findsOneWidget);
      // …and the control is gone with the series it would have plotted — a
      // control that cannot change the chart is worse than no control.
      expect(find.text(_fxChipEn), findsNothing);
      expect(find.text(_fxHintEn), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('FX chip doubles as the FX-free chart replot', () {
    /// The live-FX history and the constant-FX series, in the units the
    /// fixtures define them — deliberately different, so a test can tell
    /// which one is on screen.
    final liveFxUsd = [for (var i = 0; i < 4; i++) 1500.0 + i * 100];
    final constantFxUsd = [for (var i = 0; i < 4; i++) 1500.0 + i * 90];

    testWidgets('is OFF by default and the chart is the normal one', (
      tester,
    ) async {
      _useWideSurface(tester);
      final api = _FakeAttributionApi(result: _sparseAttribution());
      await tester.pumpWidget(_host(_card(api, history: _sparseHistory())));
      await tester.pumpAndSettle();

      // The affordance is the FX chip plus a hint that names the gesture —
      // there is no separate floating control any more.
      expect(find.text(_fxChipEn), findsOneWidget);
      expect(find.text(_fxHintEn), findsOneWidget);
      expect(find.byType(FilterChip), findsNothing);
      // The default path: the reporting-currency history, not the lens
      // series, and no explanatory caption.
      expect(_plottedYs(tester), liveFxUsd);
      expect(
        find.textContaining('Excluding FX:', findRichText: true),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the FX chip announces itself as a button, the others do not', (
      tester,
    ) async {
      _useWideSurface(tester);
      final api = _FakeAttributionApi(result: _sparseAttribution());
      await tester.pumpWidget(_host(_card(api, history: _sparseHistory())));
      await tester.pumpAndSettle();

      // The chip is pointer-and-screen-reader discoverable, not just tappable.
      expect(
        _semanticsLabels(tester),
        contains('Replot the chart without currency moves'),
      );
      // Market / Flows stay read-only readings.
      expect(
        _semanticsLabels(
          tester,
        ).where((l) => l.contains('currency moves')).length,
        1,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the old USD / MXN currency lens is gone', (tester) async {
      _useWideSurface(tester);
      final api = _FakeAttributionApi(result: _attribution());
      await tester.pumpWidget(_host(_card(api)));
      await tester.pumpAndSettle();

      // Which currency the card reports in belongs to the global switcher in
      // the app bar; this card must not offer a second, contradictable one.
      expect(find.text('USD'), findsNothing);
      expect(find.text('MXN'), findsNothing);
      expect(find.text('Constant FX'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('ON plots the constant-FX series and its caption; OFF undoes '
        'both', (tester) async {
      _useWideSurface(tester);
      final api = _FakeAttributionApi(result: _sparseAttribution());
      await tester.pumpWidget(_host(_card(api, history: _sparseHistory())));
      await tester.pumpAndSettle();

      await _tapFxChip(tester);

      expect(_plottedYs(tester), constantFxUsd);
      // The honesty caption, so a flat peso can't read as a live conversion.
      // It sits with the CHART it describes, not with the chip that toggled it.
      expect(
        find.text('Excluding FX: every balance held at 20.00 MXN/USD'),
        findsOneWidget,
      );
      // The hint has done its job and gets out of the way.
      expect(find.text(_fxHintEn), findsNothing);
      // …and the chip now offers the inverse action.
      expect(
        _semanticsLabels(tester),
        contains('Put currency moves back on the chart'),
      );

      await _tapFxChip(tester);
      expect(_plottedYs(tester), liveFxUsd);
      expect(
        find.textContaining('Excluding FX:', findRichText: true),
        findsNothing,
      );
      expect(find.text(_fxHintEn), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // A control offered when it can only redraw the same-looking line is the
    // thing that read as broken: on a $1.6M net worth whose month moved $46k,
    // a $639 FX component is invisible on the plot. The chip stays a plain
    // reading in that window — nothing invites a press that does nothing.
    testWidgets('is not offered when FX moved too little to reshape the line', (
      tester,
    ) async {
      _useWideSurface(tester);
      final api = _FakeAttributionApi(
        result: {
          ..._sparseAttribution(),
          // 1% of the constant-FX series' 270-unit span.
          'fx_usd': 2.7,
        },
      );
      await tester.pumpWidget(_host(_card(api, history: _sparseHistory())));
      await tester.pumpAndSettle();

      // The reading is still there — the decomposition never hides a number.
      expect(find.text(_fxChipEn), findsOneWidget);
      // But nothing claims it is pressable, and pressing it changes nothing.
      expect(find.text(_fxHintEn), findsNothing);
      expect(
        _semanticsLabels(tester).any((l) => l.contains('currency moves')),
        isFalse,
      );
      await _tapFxChip(tester);
      expect(_plottedYs(tester), liveFxUsd);
      expect(tester.takeException(), isNull);
    });

    // Offsetting windows are exactly when the replot earns its place: FX and
    // the market cancelling to a flat delta means currency entirely shaped the
    // curve. A rule keyed to the size of the DELTA would have hidden it.
    testWidgets('is offered when FX is large but the net delta is flat', (
      tester,
    ) async {
      _useWideSurface(tester);
      final api = _FakeAttributionApi(
        result: {
          ..._sparseAttribution(),
          'fx_usd': 200.0,
          'market_usd': -200.0,
          'flows_usd': 0.0,
          'residual_usd': 0.0,
          'delta_usd': 0.0,
        },
      );
      await tester.pumpWidget(_host(_card(api, history: _sparseHistory())));
      await tester.pumpAndSettle();

      expect(find.text(_fxHintEn), findsOneWidget);
      await _tapFxChip(tester);
      expect(_plottedYs(tester), constantFxUsd);
      expect(tester.takeException(), isNull);
    });

    // The attribution endpoint has no constant-FX series in MXN, only
    // `constant_fx_usd`. Rather than hide the one read the global switcher
    // can't express from the users most exposed to peso swings, the plot
    // stays available and LABELS ITSELF: every figure on it carries the ISO
    // code. A bare "$" is the peso glyph too, so an unlabelled axis under MXN
    // reporting would read as pesos.
    testWidgets('under MXN reporting the constant-FX plot is labelled USD', (
      tester,
    ) async {
      _useWideSurface(tester);
      final api = _FakeAttributionApi(result: _sparseAttribution());
      await tester.pumpWidget(
        _host(
          _card(
            api,
            history: _sparseHistory(),
            reportingCurrency: 'MXN',
            conversionFactor: 20.0,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // OFF: the normal chart, in the reporting currency (pesos).
      expect(_plottedYs(tester), [for (final v in liveFxUsd) v * 20.0]);

      await _tapFxChip(tester);

      // ON: the raw USD constant-FX series — NOT silently scaled into pesos.
      expect(_plottedYs(tester), constantFxUsd);
      // Y-axis ticks carry the code ("USD 1.5K"), never a bare "$".
      expect(
        find.textContaining('USD\u00A0'),
        findsWidgets,
        reason: 'the constant-FX axis must name its currency',
      );
      expect(find.textContaining('\$1'), findsNothing);
      // …as does the screen-reader summary of the pointer-only canvas.
      expect(
        _semanticsLabels(tester).any(
          (l) =>
              l.contains(_fxExcludedEn) &&
              l.contains(displayCurrencyWithCode(constantFxUsd.last, 'USD')),
        ),
        isTrue,
        reason: 'semantics label should read "$_fxExcludedEn: USD 1,770.00"',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders the hint and the caption in both locales', (
      tester,
    ) async {
      _useWideSurface(tester);
      for (final (locale, chip, hint) in const [
        (Locale('en'), _fxChipEn, _fxHintEn),
        (Locale('es'), _fxChipEs, _fxHintEs),
      ]) {
        // Tear the tree down between locales: same widget type and no key
        // means Flutter would REUSE the State, carrying the previous
        // iteration's toggled-on chart into a test that asserts the OFF one.
        await tester.pumpWidget(const SizedBox.shrink());
        final api = _FakeAttributionApi(result: _attribution());
        await tester.pumpWidget(_host(_card(api), locale: locale));
        await tester.pumpAndSettle();
        expect(find.text(hint), findsOneWidget);

        // The caption is the honesty line — it must exist in es-MX too, or a
        // flat peso reads as a live conversion for half the audience.
        await _tapFxChip(tester, label: chip);
        expect(find.text(hint), findsNothing);
        expect(
          find.textContaining('20', findRichText: true),
          findsWidgets,
          reason: 'the caption must name the window-start rate in $locale',
        );
      }
      expect(tester.takeException(), isNull);
    });

    // The FX-free series is a single total with nothing to stack, so a
    // "Detailed" segment that still selected would change nothing on screen.
    testWidgets('the Simple/Detailed toggle goes inert while FX is excluded', (
      tester,
    ) async {
      _useWideSurface(tester);
      final api = _FakeAttributionApi(result: _sparseAttribution());
      await tester.pumpWidget(_host(_card(api, history: _sparseHistory())));
      await tester.pumpAndSettle();

      await _tapFxChip(tester);
      await tester.tap(find.text('Detailed'));
      await tester.pumpAndSettle();

      // Still the single constant-FX line — the tap did not stack bands.
      expect(
        tester.widget<LineChart>(find.byType(LineChart)).data.lineBarsData,
        hasLength(1),
      );
      expect(_plottedYs(tester), constantFxUsd);
      expect(tester.takeException(), isNull);
    });

    testWidgets('toggling reuses the loaded window (no refetch)', (
      tester,
    ) async {
      _useWideSurface(tester);
      final api = _FakeAttributionApi(result: _attribution());
      await tester.pumpWidget(_host(_card(api)));
      await tester.pumpAndSettle();
      final callsAfterLoad = api.calls;

      await _tapFxChip(tester);
      await _tapFxChip(tester);

      expect(api.calls, callsAfterLoad);
      expect(tester.takeException(), isNull);
    });
  });
}
