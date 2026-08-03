import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/utils/currency.dart';
import 'package:patrimonio/widgets/cash_flow_sankey_card.dart';

/// Widget-level contract for the cash-flow Sankey card.
///
/// The load-bearing ones: the tap readout must render in the HEADER, clear of
/// the finger (a `CustomPainter` gets none of `chart_touch.dart`'s pinning for
/// free), the painted canvas must be mirrored into the semantics tree, and
/// neither phone nor desktop width may overflow.

class _FakeApi extends ApiService {
  _FakeApi([this.payload]);

  final Map<String, dynamic>? payload;
  int? requestedMonths;

  @override
  Future<Map<String, dynamic>> getSpendingByCategory({
    int months = 6,
    int top = 6,
    bool forceRefresh = false,
  }) async {
    requestedMonths = months;
    return payload ??
        {
          'months': ['2026-07'],
          'categories': [
            {
              'category': 'RENT_AND_UTILITIES',
              'total': 2400.0,
              'monthly': [
                {'month': '2026-07', 'amount': 2400.0},
              ],
            },
            {
              'category': 'FOOD_AND_DRINK',
              'total': 1600.0,
              'monthly': [
                {'month': '2026-07', 'amount': 1600.0},
              ],
            },
          ],
        };
  }
}

final _trends = <Map<String, dynamic>>[
  {
    'month': '2026-07',
    'income': 6000.0,
    'spending': 4000.0,
    'invested': 500.0,
    'transferred': 0.0,
  },
];

final _fxTransfers = <dynamic>[
  {
    'source_date': '2026-07-10',
    'source_amount': 1000.0,
    'source_currency': 'USD',
    'dest_amount': 18000.0,
    'dest_currency': 'MXN',
  },
];

Widget _host(
  Widget child, {
  Locale locale = const Locale('en'),
  double width = 1200,
}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: SingleChildScrollView(
        child: SizedBox(width: width, child: child),
      ),
    ),
  );
}

CashFlowSankeyCard _card(
  ApiService api, {
  List<dynamic> fxTransfers = const <dynamic>[],
  List<dynamic> transactions = const <dynamic>[],
  String targetCurrency = 'USD',
  double conversionFactor = 1.0,
}) {
  return CashFlowSankeyCard(
    apiService: api,
    trends: _trends,
    months: 1,
    transactions: transactions,
    fxTransfers: fxTransfers,
    conversionFactor: conversionFactor,
    currencyFormat: moneyFormat(targetCurrency),
    targetCurrency: targetCurrency,
    usdMxnRate: 18.0,
  );
}

void main() {
  Future<void> pump(
    WidgetTester tester,
    Widget card, {
    Locale locale = const Locale('en'),
    double width = 1200,
    Size view = const Size(1400, 1400),
  }) async {
    tester.view.physicalSize = view;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(_host(card, locale: locale, width: width));
    await tester.pumpAndSettle();
  }

  testWidgets('renders at desktop width without overflow', (tester) async {
    await pump(tester, _card(_FakeApi(), fxTransfers: _fxTransfers));
    expect(tester.takeException(), isNull);
    expect(find.text('Where your money flows'), findsOneWidget);
    expect(find.byKey(const Key('cfsCanvas-main')), findsOneWidget);
    expect(find.byKey(const Key('cfsCanvas-fx')), findsOneWidget);
  });

  testWidgets('renders at phone width without overflow', (tester) async {
    await pump(
      tester,
      _card(_FakeApi(), fxTransfers: _fxTransfers),
      width: 360,
      view: const Size(390, 1600),
    );
    expect(tester.takeException(), isNull);
    // The phone branch compresses the title to an uppercase overline.
    expect(find.text('WHERE YOUR MONEY FLOWS'), findsOneWidget);
    final canvas = tester.getRect(find.byKey(const Key('cfsCanvas-main')));
    expect(canvas.width, lessThanOrEqualTo(360));
  });

  testWidgets('the tap readout renders clear of the touch point', (
    tester,
  ) async {
    await pump(tester, _card(_FakeApi()));

    final canvas = tester.getRect(find.byKey(const Key('cfsCanvas-main')));
    // Between the source column and the pool, where the single income ribbon
    // spans the full height.
    final point = Offset(canvas.left + canvas.width * 0.3, canvas.center.dy);
    await tester.tapAt(point);
    await tester.pumpAndSettle();

    // The reading appeared…
    expect(find.textContaining('Money in'), findsWidgets);
    final readout = tester.getRect(find.byKey(const Key('cfsReadout')));
    // …in the header strip, which must not sit under the finger. This is the
    // whole reason a CustomPainter chart has to own its own readout: there is
    // no chart_touch pinning to inherit.
    expect(readout.contains(point), isFalse);
    expect(readout.bottom, lessThanOrEqualTo(canvas.top));
  });

  testWidgets('the readout names the flow, its amount and its share', (
    tester,
  ) async {
    await pump(tester, _card(_FakeApi()));
    final canvas = tester.getRect(find.byKey(const Key('cfsCanvas-main')));
    await tester.tapAt(
      Offset(canvas.left + canvas.width * 0.3, canvas.center.dy),
    );
    await tester.pumpAndSettle();

    // Income (6,000) is 100% of the pool.
    expect(find.text('Income  →  Money in'), findsOneWidget);
    expect(find.textContaining(r'$6,000.00'), findsWidgets);
    expect(find.textContaining('100.0%'), findsWidgets);
  });

  testWidgets('tapping empty canvas clears the reading', (tester) async {
    await pump(tester, _card(_FakeApi()));
    final canvas = tester.getRect(find.byKey(const Key('cfsCanvas-main')));
    await tester.tapAt(
      Offset(canvas.left + canvas.width * 0.3, canvas.center.dy),
    );
    await tester.pumpAndSettle();
    expect(find.text('Income  →  Money in'), findsOneWidget);

    await tester.tapAt(Offset(canvas.left + 2, canvas.top + 2));
    await tester.pumpAndSettle();
    expect(find.text('Income  →  Money in'), findsNothing);
    expect(find.text('Tap a flow for its amount.'), findsOneWidget);
  });

  testWidgets('the painted canvas is mirrored into the semantics tree', (
    tester,
  ) async {
    await pump(tester, _card(_FakeApi(), fxTransfers: _fxTransfers));

    final labels = tester
        .widgetList<Semantics>(find.byType(Semantics))
        .map((s) => s.properties.label ?? '')
        .toList();
    final main = labels.firstWhere(
      (s) => s.startsWith('Money flow diagram'),
      orElse: () => '',
    );
    expect(main, isNotEmpty);
    // Individual flows, not just a headline number.
    expect(main, contains('Income to Money in'));
    expect(main, contains('Money in to Rent & utilities'));
    expect(main, contains(r'$6,000.00'));

    final fx = labels.firstWhere(
      (s) => s.startsWith('Cross-border conversion diagram'),
      orElse: () => '',
    );
    expect(fx, isNotEmpty);
    expect(fx, contains('USD to FX conversion'));
  });

  testWidgets('the FX band names its matched pairs and both native legs', (
    tester,
  ) async {
    await pump(tester, _card(_FakeApi(), fxTransfers: _fxTransfers));
    expect(find.text('Across the border'), findsOneWidget);
    expect(find.textContaining('1 matched transfer'), findsOneWidget);
    // Unmatched transfers are named as missing rather than invented.
    expect(find.textContaining('could not match into a pair'), findsOneWidget);
    // The two legs are quoted with their own ISO codes, never summed.
    expect(find.textContaining('USD 1,000.00'), findsWidgets);
    expect(find.textContaining('MXN 18,000.00'), findsWidgets);
  });

  testWidgets('no FX links → no band at all', (tester) async {
    await pump(tester, _card(_FakeApi()));
    expect(find.byKey(const Key('cfsCanvas-fx')), findsNothing);
    expect(find.text('Across the border'), findsNothing);
  });

  testWidgets('the stated reporting unit follows the display currency', (
    tester,
  ) async {
    await pump(tester, _card(_FakeApi(), targetCurrency: 'USD'));
    expect(find.text('Every flow shown in USD'), findsOneWidget);

    await pump(
      tester,
      _card(_FakeApi(), targetCurrency: 'MXN', conversionFactor: 18.0),
    );
    expect(find.text('Every flow shown in MXN'), findsOneWidget);
  });

  testWidgets('es-MX renders the chrome and the semantics summary', (
    tester,
  ) async {
    await pump(
      tester,
      _card(_FakeApi(), fxTransfers: _fxTransfers),
      locale: const Locale('es'),
    );
    expect(find.text('A dónde fluye tu dinero'), findsOneWidget);
    expect(find.text('Al otro lado de la frontera'), findsOneWidget);
    expect(find.text('Todos los flujos en USD'), findsOneWidget);
    expect(find.textContaining('1 transferencia vinculada'), findsOneWidget);

    final labels = tester
        .widgetList<Semantics>(find.byType(Semantics))
        .map((s) => s.properties.label ?? '')
        .toList();
    final main = labels.firstWhere(
      (s) => s.startsWith('Diagrama de flujo de dinero'),
      orElse: () => '',
    );
    expect(main, isNotEmpty);
    // gen-l10n signature check in the OTHER locale: "de {source} a {target}"
    // would silently swap if the placeholder order ever drifted.
    expect(main, contains('de Ingresos a Dinero disponible'));
  });

  testWidgets('an empty period says so instead of drawing a flat river', (
    tester,
  ) async {
    await pump(
      tester,
      CashFlowSankeyCard(
        apiService: _FakeApi({'months': <String>[], 'categories': <dynamic>[]}),
        trends: const <Map<String, dynamic>>[],
        months: 1,
        conversionFactor: 1.0,
        currencyFormat: moneyFormat('USD'),
        targetCurrency: 'USD',
        usdMxnRate: 18.0,
      ),
    );
    expect(
      find.text('No cash flow recorded in this period yet.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('cfsCanvas-main')), findsNothing);
  });

  testWidgets('the breakdown window follows the tab period', (tester) async {
    final api = _FakeApi();
    await pump(
      tester,
      CashFlowSankeyCard(
        apiService: api,
        trends: _trends,
        months: 3,
        periodLabel: 'Last 3 months',
        conversionFactor: 1.0,
        currencyFormat: moneyFormat('USD'),
        targetCurrency: 'USD',
        usdMxnRate: 18.0,
      ),
    );
    expect(api.requestedMonths, 3);
    expect(find.textContaining('Last 3 months'), findsOneWidget);
  });
}
