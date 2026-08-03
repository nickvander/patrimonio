import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/utils/cash_flow_sankey.dart';
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

  // -------------------------------------------------------------------------
  // Painted-label geometry
  //
  // A node rect is VALUE-sized: a $26 slice of a $620 period is about one
  // pixel tall, so centring a two-line label block on each rect (what the
  // first cut did) overprinted four of six value labels into mush at desktop
  // width. Pumping the widget proved nothing about that — the old suite was
  // green the whole time. These read the painter's REAL, as-drawn placements
  // and assert the geometry.
  // -------------------------------------------------------------------------

  group('label geometry', () {
    for (final c in _geometryCases) {
      testWidgets('no two label blocks overlap — ${c.name}', (tester) async {
        await c.withLocale(() async {
          await pump(
            tester,
            _threeMonthCard(),
            locale: c.locale,
            width: c.width,
            view: c.view,
          );
          final placements = _placements(tester, 'main');
          // Every node in the diagram that could be labelled was.
          expect(placements.length, greaterThanOrEqualTo(6));
          _expectNoOverlap(placements);
          _expectInsideCanvas(tester, 'main', placements);
        });
      });
    }

    testWidgets('a pathological comb of tiny nodes never overprints', (
      tester,
    ) async {
      await pump(tester, _pathologicalCard());
      final placements = _placements(tester, 'main');
      expect(placements, isNotEmpty);
      _expectNoOverlap(placements);
      _expectInsideCanvas(tester, 'main', placements);
    });

    testWidgets('the same comb never overprints at phone width', (
      tester,
    ) async {
      await pump(
        tester,
        _pathologicalCard(),
        width: 360,
        view: const Size(390, 2000),
      );
      final placements = _placements(tester, 'main');
      expect(placements, isNotEmpty);
      _expectNoOverlap(placements);
      _expectInsideCanvas(tester, 'main', placements);
    });

    testWidgets('two sources sharing a prefix render as DIFFERENT labels', (
      tester,
    ) async {
      await pump(tester, _threeMonthCard());
      final byId = {for (final p in _placements(tester, 'main')) p.nodeId: p};
      final a = byId['src:0']!.name;
      final b = byId['src:1']!.name;
      // Tail-ellipsis collapsed both of these to "Dividend received - …" in
      // the 118px gutter, which defeats the point of naming sources at all.
      expect(a, isNot(b));
      expect(a, isNot('Dividend received - …'));
      expect(b, isNot('Dividend received - …'));
      // The discriminating token is at the end of a bank label, so it must
      // survive the elision.
      expect(
        [a, b].where((s) => s.endsWith('AAPL')),
        hasLength(1),
        reason: 'AAPL source: $a / $b',
      );
      expect(
        [a, b].where((s) => s.endsWith('hly)')),
        hasLength(1),
        reason: 'monthly source: $a / $b',
      );
      // Both are elided from the middle (the shared head survives too), which
      // is what makes the tail readable at all.
      expect(a, startsWith('Divi'));
      expect(b, startsWith('Divi'));
    });

    testWidgets('node values read EXACTLY, matching the card above', (
      tester,
    ) async {
      await pump(tester, _threeMonthCard());
      final values = {
        for (final p in _placements(tester, 'main')) p.nodeId: p.value,
      };
      // compactMoney printed "$67.9" / "$4.7" beside MonthlyCashFlowCard's
      // "$67.85" / "$4.69" — a self-inflicted disagreement with the very card
      // this diagram exists to corroborate.
      expect(values['cat:GENERAL_MERCHANDISE'], r'$67.85');
      expect(values['cat:TRANSPORTATION'], r'$26.00');
      expect(values['cat:FOOD_AND_DRINK'], r'$4.69');
      expect(values['cat:RENT_AND_UTILITIES'], r'$520.00');
    });
  });

  group('the FX band stays inside its canvas', () {
    testWidgets('the painter clips to its bounds', (tester) async {
      await pump(
        tester,
        _card(_FakeApi(), fxTransfers: _fxTransfers),
        width: 360,
        view: const Size(390, 1600),
      );
      // A CustomPaint does not clip by default: the middle-column label's
      // below-the-bar fallback escaped the box and drew over the caption.
      expect(find.byKey(const Key('cfsCanvas-fx')), paints..clipRect());
      expect(find.byKey(const Key('cfsCanvas-main')), paints..clipRect());
    });

    testWidgets('the FX value label never reaches the caption below it', (
      tester,
    ) async {
      await pump(
        tester,
        _card(_FakeApi(), fxTransfers: _fxTransfers),
        width: 360,
        view: const Size(390, 1600),
      );
      final placements = _placements(tester, 'fx');
      expect(placements, isNotEmpty);
      _expectNoOverlap(placements);
      _expectInsideCanvas(tester, 'fx', placements);

      // The conversion node is full height by construction, so its label has
      // to fit in the top inset. Too shallow an inset pushed it below the bar
      // and — before the clip — off the canvas entirely.
      final painter = _painterFor(tester, 'fx');
      final bar = painter.layout.nodeRects['fx']!;
      final label = placements.firstWhere((p) => p.nodeId == 'fx');
      expect(label.rect.bottom, lessThanOrEqualTo(bar.top));

      // …and the canvas itself ends above the "USD … became MXN …" caption,
      // so "inside the canvas" really does mean "clear of the caption".
      final canvas = tester.getRect(find.byKey(const Key('cfsCanvas-fx')));
      final caption = tester.getRect(
        find.textContaining('became', findRichText: false),
      );
      expect(canvas.bottom, lessThanOrEqualTo(caption.top));
    });
  });
}

// ---------------------------------------------------------------------------
// Geometry helpers
// ---------------------------------------------------------------------------

Finder _painterFinder(String id) => find.descendant(
  of: find.byKey(Key('cfsCanvas-$id')),
  matching: find.byWidgetPredicate(
    (w) => w is CustomPaint && w.painter is SankeyPainter,
  ),
);

SankeyPainter _painterFor(WidgetTester tester, String id) =>
    tester.widget<CustomPaint>(_painterFinder(id)).painter! as SankeyPainter;

/// The painter's real placements for one diagram, at its real painted size.
List<SankeyLabelPlacement> _placements(WidgetTester tester, String id) =>
    _painterFor(tester, id).labelPlacements(tester.getSize(_painterFinder(id)));

void _expectNoOverlap(List<SankeyLabelPlacement> placements) {
  for (var i = 0; i < placements.length; i++) {
    for (var j = i + 1; j < placements.length; j++) {
      final a = placements[i];
      final b = placements[j];
      final hit = a.rect.intersect(b.rect);
      expect(
        hit.width > 0 && hit.height > 0,
        isFalse,
        reason:
            '${a.nodeId} ${a.rect} overprints ${b.nodeId} ${b.rect} '
            '("${a.name}" / "${b.name}")',
      );
    }
  }
}

void _expectInsideCanvas(
  WidgetTester tester,
  String id,
  List<SankeyLabelPlacement> placements,
) {
  final size = tester.getSize(find.byKey(Key('cfsCanvas-$id')));
  for (final p in placements) {
    expect(p.rect.top, greaterThanOrEqualTo(-0.01), reason: p.nodeId);
    expect(p.rect.left, greaterThanOrEqualTo(-0.01), reason: p.nodeId);
    expect(
      p.rect.bottom,
      lessThanOrEqualTo(size.height + 0.01),
      reason: p.nodeId,
    );
    expect(
      p.rect.right,
      lessThanOrEqualTo(size.width + 0.01),
      reason: p.nodeId,
    );
  }
}

@immutable
class _GeometryCase {
  const _GeometryCase(this.name, this.locale, this.width, this.view);
  final String name;
  final Locale locale;
  final double width;
  final Size view;

  /// es-MX has to move `Intl`'s ambient locale too: the painted money strings
  /// come from `NumberFormat`, not `AppLocalizations`, and es decimals are a
  /// different WIDTH. Restored after the body so no other test inherits it.
  Future<void> withLocale(Future<void> Function() body) async {
    if (locale.languageCode == 'en') return body();
    final previous = Intl.defaultLocale;
    Intl.defaultLocale = 'es';
    try {
      await body();
    } finally {
      Intl.defaultLocale = previous;
    }
  }
}

const _geometryCases = <_GeometryCase>[
  _GeometryCase('desktop / en', Locale('en'), 1200, Size(1400, 1600)),
  _GeometryCase('desktop / es', Locale('es'), 1200, Size(1400, 1600)),
  _GeometryCase('phone / en', Locale('en'), 360, Size(390, 1800)),
  _GeometryCase('phone / es', Locale('es'), 360, Size(390, 1800)),
];

// --- The 3-month shape that shipped with 4 of 6 value labels illegible -----

const _threeMonths = <String>['2026-05', '2026-06', '2026-07'];

Map<String, dynamic> _cat(
  String code,
  List<double> monthly, {
  List<String> months = _threeMonths,
}) => {
  'category': code,
  'total': monthly.fold<double>(0, (a, b) => a + b),
  'monthly': [
    for (var i = 0; i < monthly.length; i++)
      {'month': months[i], 'amount': monthly[i]},
  ],
};

final _threeMonthTrends = <Map<String, dynamic>>[
  for (var i = 0; i < 3; i++)
    {
      'month': _threeMonths[i],
      'income': i == 2 ? 220.0 : 200.0,
      'spending': i == 2 ? 218.54 : 200.0,
      'invested': 0.0,
      'transferred': 0.0,
    },
];

/// $520.00 / $67.85 / $26.00 / $4.69 — the four categories whose label blocks
/// mutually overprinted (Shopping vs Transportation being the worst pair).
final _threeMonthCategories = <String, dynamic>{
  'months': _threeMonths,
  'categories': [
    _cat('RENT_AND_UTILITIES', [170.0, 175.0, 175.0]),
    _cat('GENERAL_MERCHANDISE', [20.0, 20.0, 27.85]),
    _cat('TRANSPORTATION', [8.0, 9.0, 9.0]),
    _cat('FOOD_AND_DRINK', [1.5, 1.5, 1.69]),
  ],
};

/// Two dividend payers whose labels share a 20-character prefix.
final _dividendTransactions = <dynamic>[
  // Dated before the window: proves the loaded page covers it, which is the
  // gate income attribution refuses to run without.
  {
    'date': '2026-04-20',
    'amount': -12.0,
    'currency': 'USD',
    'user_description': 'Coffee',
    'category': 'FOOD_AND_DRINK',
  },
  {
    'date': '2026-06-15',
    'amount': 514.40,
    'currency': 'USD',
    'user_description': 'Dividend received - AAPL',
    'category': 'INCOME',
    'category_detailed': 'INCOME_DIVIDENDS',
  },
  {
    'date': '2026-07-01',
    'amount': 105.60,
    'currency': 'USD',
    'user_description': 'Dividend received - O (monthly)',
    'category': 'INCOME',
    'category_detailed': 'INCOME_DIVIDENDS',
  },
];

CashFlowSankeyCard _threeMonthCard() => CashFlowSankeyCard(
  apiService: _FakeApi(_threeMonthCategories),
  trends: _threeMonthTrends,
  months: 3,
  periodLabel: 'Last 3 months',
  transactions: _dividendTransactions,
  conversionFactor: 1.0,
  currencyFormat: moneyFormat('USD'),
  targetCurrency: 'USD',
  usdMxnRate: 18.0,
);

/// One dominant category and a long comb of dust — the worst case for a
/// value-sized column, where several nodes collapse to the 1px floor and their
/// centres land within a few pixels of each other.
final _pathologicalCategories = <String, dynamic>{
  'months': ['2026-07'],
  'categories': [
    for (final e in <List<Object>>[
      ['RENT_AND_UTILITIES', 800.0],
      ['GENERAL_MERCHANDISE', 20.0],
      ['TRANSPORTATION', 12.0],
      ['FOOD_AND_DRINK', 9.0],
      ['ENTERTAINMENT', 7.0],
      ['PERSONAL_CARE', 6.0],
      ['MEDICAL', 5.0],
      ['TRAVEL', 4.0],
      ['GENERAL_SERVICES', 3.0],
      ['HOME_IMPROVEMENT', 2.5],
      ['GOVERNMENT_AND_NON_PROFIT', 2.0],
      ['RENT', 1.5],
      ['BANK_FEES', 1.0],
      ['INSURANCE', 0.8],
      ['EDUCATION', 0.6],
    ])
      _cat(
        e[0] as String,
        <double>[e[1] as double],
        months: const <String>['2026-07'],
      ),
  ],
};

CashFlowSankeyCard _pathologicalCard() => CashFlowSankeyCard(
  apiService: _FakeApi(_pathologicalCategories),
  trends: const <Map<String, dynamic>>[
    {
      'month': '2026-07',
      'income': 1000.0,
      'spending': 1000.0,
      'invested': 0.0,
      'transferred': 0.0,
    },
  ],
  months: 1,
  conversionFactor: 1.0,
  currencyFormat: moneyFormat('USD'),
  targetCurrency: 'USD',
  usdMxnRate: 18.0,
);
