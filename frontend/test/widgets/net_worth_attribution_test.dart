import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/utils/currency.dart';
import 'package:patrimonio/widgets/net_worth_card.dart';

/// Net-worth card: the FX / Market / Flows attribution section and the
/// USD / MXN / constant-FX currency-lens toggle, driven by a faked
/// `getNetWorthAttribution` (mixin members are virtual — `extends ApiService`
/// + `@override` is the house fake pattern).

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

NetWorthCard _card(ApiService api, {List<dynamic>? history}) => NetWorthCard(
  netWorth: 1780.0,
  history: history ?? _history(),
  conversionFactor: 1.0,
  currencyFormat: moneyFormat('USD'),
  reportingCurrency: 'USD',
  sourceBreakdown: const [],
  usdMxnRate: 20.0,
  apiService: api,
);

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

void main() {
  group('lens x-axis mapping is the same for every lens', () {
    // The USD (default) lens plotted its history index-spaced while the MXN
    // and constant-FX lenses plotted the attribution series day-offset
    // spaced. Same history, three horizontal mappings: switching lenses
    // appeared to reshape the past, and a sparse March point sat one step
    // from a tightly packed cluster. Every lens is time-spaced now.
    testWidgets('all three lenses plot the same day offsets', (tester) async {
      _useWideSurface(tester);
      final api = _FakeAttributionApi(result: _sparseAttribution());
      await tester.pumpWidget(_host(_card(api, history: _sparseHistory())));
      await tester.pumpAndSettle();

      // Default (USD) lens — the history path, formerly index-as-x.
      expect(_plottedXs(tester), _sparseDayOffsets);
      // …and it is emphatically NOT index spacing.
      expect(_plottedXs(tester), isNot([0.0, 1.0, 2.0, 3.0]));

      for (final lens in const ['MXN', 'Constant FX', 'USD']) {
        await tester.tap(find.text(lens));
        await tester.pumpAndSettle();
        expect(
          _plottedXs(tester),
          _sparseDayOffsets,
          reason: 'the $lens lens must use the same horizontal mapping',
        );
      }
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
      expect(tester.takeException(), isNull);
    });
  });

  group('currency-lens toggle', () {
    testWidgets(
      'defaults to the reporting currency and offers USD / MXN / constant',
      (tester) async {
        _useWideSurface(tester);
        final api = _FakeAttributionApi(result: _attribution());
        await tester.pumpWidget(_host(_card(api)));
        await tester.pumpAndSettle();

        expect(find.text('USD'), findsOneWidget);
        expect(find.text('MXN'), findsOneWidget);
        expect(find.text('Constant FX'), findsOneWidget);
        // Default lens (reporting currency) → no constant-FX caption.
        expect(
          find.textContaining('window-start rate', findRichText: true),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('MXN lens swaps the plotted series without a caption', (
      tester,
    ) async {
      _useWideSurface(tester);
      final api = _FakeAttributionApi(result: _attribution());
      await tester.pumpWidget(_host(_card(api)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('MXN'));
      await tester.pumpAndSettle();

      expect(find.byType(LineChart), findsOneWidget);
      expect(
        find.textContaining('window-start rate', findRichText: true),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'constant-FX lens shows the window-start-rate caption and toggling '
      'back to USD removes it',
      (tester) async {
        _useWideSurface(tester);
        final api = _FakeAttributionApi(result: _attribution());
        await tester.pumpWidget(_host(_card(api)));
        await tester.pumpAndSettle();

        await tester.tap(find.text('Constant FX'));
        await tester.pumpAndSettle();

        expect(
          find.text('MXN revalued at the window-start rate (20.00 MXN/USD)'),
          findsOneWidget,
        );
        expect(find.byType(LineChart), findsOneWidget);

        await tester.tap(find.text('USD'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('window-start rate', findRichText: true),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('lens switching reuses the loaded window (no refetch)', (
      tester,
    ) async {
      _useWideSurface(tester);
      final api = _FakeAttributionApi(result: _attribution());
      await tester.pumpWidget(_host(_card(api)));
      await tester.pumpAndSettle();
      final callsAfterLoad = api.calls;

      await tester.tap(find.text('MXN'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Constant FX'));
      await tester.pumpAndSettle();

      expect(api.calls, callsAfterLoad);
      expect(tester.takeException(), isNull);
    });
  });
}
