import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/utils/currency.dart';
import 'package:patrimonio/widgets/net_worth_card.dart';

/// Net-worth card: the FX / Market / Flows attribution section and the single
/// "Ignore FX moves" chart toggle, driven by a faked
/// `getNetWorthAttribution` (mixin members are virtual — `extends ApiService`
/// + `@override` is the house fake pattern).
///
/// The toggle replaced a three-segment USD / MXN / Constant-FX currency lens:
/// USD and MXN duplicated the global reporting-currency switcher in the app
/// bar (and could be set to contradict the hero number above the chart), so
/// only the constant-FX read — which the global switcher cannot express —
/// survives, as a boolean that is OFF by default.

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

/// The label on the one chart toggle, in the two locales.
const String _ignoreFxEn = 'Ignore FX moves';
const String _ignoreFxEs = 'Ignorar movimientos cambiarios';

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

      await tester.tap(find.text(_ignoreFxEn));
      await tester.pumpAndSettle();
      expect(
        _plottedXs(tester),
        _sparseDayOffsets,
        reason: 'the constant-FX plot must use the same horizontal mapping',
      );

      // …and back off again.
      await tester.tap(find.text(_ignoreFxEn));
      await tester.pumpAndSettle();
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
      // …and the toggle is gone with the series it would have plotted — a
      // control that cannot change the chart is worse than no control.
      expect(find.text(_ignoreFxEn), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('"Ignore FX moves" toggle', () {
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

      // Exactly ONE chart control, and it is off.
      expect(find.text(_ignoreFxEn), findsOneWidget);
      expect(
        tester.widget<FilterChip>(find.byType(FilterChip)).selected,
        isFalse,
      );
      // The default path: the reporting-currency history, not the lens
      // series, and no explanatory caption.
      expect(_plottedYs(tester), liveFxUsd);
      expect(
        find.textContaining('window-start rate', findRichText: true),
        findsNothing,
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

      await tester.tap(find.text(_ignoreFxEn));
      await tester.pumpAndSettle();

      expect(
        tester.widget<FilterChip>(find.byType(FilterChip)).selected,
        isTrue,
      );
      expect(_plottedYs(tester), constantFxUsd);
      // The honesty caption, so a flat peso can't read as a live conversion.
      expect(
        find.text('MXN revalued at the window-start rate (20.00 MXN/USD)'),
        findsOneWidget,
      );

      await tester.tap(find.text(_ignoreFxEn));
      await tester.pumpAndSettle();
      expect(_plottedYs(tester), liveFxUsd);
      expect(
        find.textContaining('window-start rate', findRichText: true),
        findsNothing,
      );
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

      await tester.tap(find.text(_ignoreFxEn));
      await tester.pumpAndSettle();

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
              l.contains(_ignoreFxEn) &&
              l.contains(displayCurrencyWithCode(constantFxUsd.last, 'USD')),
        ),
        isTrue,
        reason: 'semantics label should read "$_ignoreFxEn: USD 1,770.00"',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('renders its label in both locales', (tester) async {
      _useWideSurface(tester);
      for (final (locale, label) in const [
        (Locale('en'), _ignoreFxEn),
        (Locale('es'), _ignoreFxEs),
      ]) {
        final api = _FakeAttributionApi(result: _attribution());
        await tester.pumpWidget(_host(_card(api), locale: locale));
        await tester.pumpAndSettle();
        expect(find.text(label), findsOneWidget);
      }
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

      await tester.tap(find.text(_ignoreFxEn));
      await tester.pumpAndSettle();
      await tester.tap(find.text(_ignoreFxEn));
      await tester.pumpAndSettle();

      expect(api.calls, callsAfterLoad);
      expect(tester.takeException(), isNull);
    });
  });
}
