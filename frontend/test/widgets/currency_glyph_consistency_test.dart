import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/utils/currency.dart';
import 'package:patrimonio/widgets/dividend_detail_sheet.dart';
import 'package:patrimonio/widgets/instrument_detail_sheet.dart';
import 'package:patrimonio/widgets/interest_income_sheet.dart';

/// The house currency map renders MXN as its ISO prefix (`MXN 30,000.00`),
/// but these three sheets each built their own
/// `NumberFormat(symbol: currency == 'MXN' ? r'MX$' : r'$')` and printed
/// `MX$30,000.00`. The visible symptom: a lending card read `MXN 30,000`
/// while the interest-income sheet it opens read `MX$30,000`.
///
/// Each test drives the sheet with an MXN payload and asserts the rendered
/// money against the house helper — never a literal glyph — plus a sweep of
/// every rendered string for the stale `MX$`, so a fourth site can't come
/// back through a copy-paste.

/// Every non-empty string currently rendered anywhere in the tree.
Iterable<String> _renderedText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
    .where((s) => s.isNotEmpty);

/// No surface anywhere in the pumped tree may print the retired glyph.
void _expectNoStaleGlyph(WidgetTester tester) {
  expect(
    _renderedText(tester).where((s) => s.contains('MX\$')).toList(),
    isEmpty,
    reason: 'a money surface is still rendering the retired MX\$ glyph',
  );
}

/// [textScale] exists for the fixed-width surfaces: `flutter_test`'s fallback
/// font draws every glyph as a full em square, so an 18-character label at
/// 11px measures ~198px where real Inter measures ~95px, and the
/// interest-income totals card (a hardcoded 220px `Container`) overflows on a
/// string that fits fine in the app. Scaling text down restores real-font
/// proportions; it doesn't touch the strings under assertion.
Widget _host(
  Widget child, {
  Locale locale = const Locale('en'),
  double textScale = 1.0,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Builder(
      builder: (context) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child,
      ),
    ),
  ),
);

/// The sheets scroll inside a viewport cap; a tall surface keeps every
/// section on-stage so finders don't need to scroll.
void _useTallSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// GET /loans/interest-income, all-MXN.
Map<String, dynamic> _interestIncomePayload() => {
  'totals_by_currency': [
    {
      'currency': 'MXN',
      'total_interest': 30000.0,
      'total_principal': 500.25,
      'payments_count': 4,
    },
  ],
  'by_month': [
    {'month': '2026-06', 'interest_received': 1500.50},
  ],
  'by_loan': [
    {
      'borrower_name': 'Jose',
      'currency': 'MXN',
      'interest_received': 1500.50,
      'principal_received': 250.25,
      'payments_count': 4,
    },
  ],
  'below_market_loans': [
    {'borrower_name': 'Ana', 'currency': 'MXN', 'principal': 9000.0},
  ],
};

class _FakeInterestApi extends ApiService {
  @override
  Future<Map<String, dynamic>> getInterestIncome({int? year}) async =>
      _interestIncomePayload();
}

/// GET /portfolio/instrument/:symbol for a peso-denominated holding.
Map<String, dynamic> _mxnInstrumentPayload() => {
  'symbol': 'NAFTRAC',
  'name': 'iShares NAFTRAC',
  'currency': 'MXN',
  'asset_class': 'equity',
  'quantity': 100.0,
  'price': 172.40,
  'value_usd': 1000.0,
  'cost_basis_usd': 900.0,
  'gain_loss_usd': 100.0,
  'gain_loss_pct': 11.11,
  'portfolio_weight_pct': 0.5,
  'price_as_of': '2026-07-02',
  'accounts': <Map<String, dynamic>>[],
  'lots': [
    {
      'acquired_at': '2024-03-01',
      'qty': 10.0,
      'cost_per_unit': 88.10,
      'currency': 'MXN',
      'usd_cost': 50.0,
    },
  ],
  'prices': <Map<String, dynamic>>[],
};

/// GET /portfolio/dividends/:symbol for a peso payer, incl. a sub-unit
/// per-share rate (the 4-decimal branch of the helper).
Map<String, dynamic> _mxnDividendPayload({double ratePerShare = 3.10}) => {
  'symbol': 'NAFTRAC',
  'name': 'iShares NAFTRAC',
  'currency': 'MXN',
  'per_year': 4,
  'quantity': 100.0,
  'rate_per_share_annual': ratePerShare,
  'schedule': <Map<String, dynamic>>[],
  'history': <Map<String, dynamic>>[],
  'accounts': <Map<String, dynamic>>[],
};

void main() {
  // Guards the premise: if the map ever goes back to the glyph these tests
  // should fail loudly rather than quietly re-asserting MX$.
  test('the house helper renders MXN with its ISO prefix', () {
    expect(currencySymbol('MXN'), 'MXN ');
    expect(moneyFormat('MXN').format(30000), isNot(contains('MX\$')));
  });

  group('InterestIncomeSheet renders the house MXN glyph', () {
    for (final locale in const [Locale('en'), Locale('es')]) {
      testWidgets('${locale.languageCode}: totals, loan rows and callout', (
        tester,
      ) async {
        _useTallSurface(tester);
        await tester.pumpWidget(
          _host(
            InterestIncomeSheet(apiService: _FakeInterestApi()),
            locale: locale,
            textScale: 0.5,
          ),
        );
        await tester.pumpAndSettle();

        // Per-currency total card: a display surface, so cents drop above the
        // whole-money threshold — this is the figure that used to read
        // "MX$30,000" beside the lending card's "MXN 30,000".
        expect(
          find.text(moneyFormat('MXN').displayMoney(30000)),
          findsOneWidget,
        );
        expect(find.text('MXN 30,000'), findsOneWidget);
        // Sub-threshold principal keeps its cents.
        expect(find.text(moneyFormat('MXN').format(500.25)), findsOneWidget);

        // Per-loan table row: exact money, no display rounding.
        expect(find.text(moneyFormat('MXN').format(1500.50)), findsOneWidget);
        expect(find.text(moneyFormat('MXN').format(250.25)), findsOneWidget);

        // §7872 below-market callout row.
        expect(find.text(moneyFormat('MXN').displayMoney(9000)), findsWidgets);

        _expectNoStaleGlyph(tester);
      });
    }
  });

  group('InstrumentDetailSheet renders the house MXN glyph', () {
    testWidgets('native price headline and lot cost', (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        _host(
          InstrumentDetailSheet(
            apiService: ApiService(),
            symbol: 'NAFTRAC',
            conversionFactor: 1.0,
            // Display currency stays USD; the NATIVE per-unit amounts are
            // what this sheet formats itself.
            currencyFormat: NumberFormat.currency(symbol: '\$'),
            fetchOverride: (symbol, {range = '1y'}) async =>
                _mxnInstrumentPayload(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Price headline: >= 1, so two decimals.
      expect(find.text('MXN 172.40'), findsOneWidget);
      // Lot line: "10 shares @ MXN 88.10".
      expect(find.textContaining('MXN 88.10'), findsOneWidget);

      _expectNoStaleGlyph(tester);
    });
  });

  group('DividendDetailSheet renders the house MXN glyph', () {
    Widget divSheet(Map<String, dynamic> payload) => DividendDetailSheet(
      apiService: ApiService(),
      symbol: 'NAFTRAC',
      conversionFactor: 1.0,
      currencyFormat: NumberFormat.currency(symbol: '\$'),
      fetchOverride: (symbol) async => payload,
    );

    testWidgets('per-share rate at two decimals', (tester) async {
      _useTallSurface(tester);
      await tester.pumpWidget(_host(divSheet(_mxnDividendPayload())));
      await tester.pumpAndSettle();

      expect(find.text('MXN 3.10'), findsOneWidget);
      _expectNoStaleGlyph(tester);
    });

    testWidgets('sub-unit per-share rate keeps 4 decimals AND the glyph', (
      tester,
    ) async {
      _useTallSurface(tester);
      await tester.pumpWidget(
        _host(divSheet(_mxnDividendPayload(ratePerShare: 0.0825))),
      );
      await tester.pumpAndSettle();

      expect(find.text('MXN 0.0825'), findsOneWidget);
      _expectNoStaleGlyph(tester);
    });
  });
}
