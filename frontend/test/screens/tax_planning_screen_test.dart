import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/screens/tax_planning_screen.dart';

// These tests drive the screen entirely through its injected fetcher seams,
// so they never subclass ApiService (which pulls package:web into the test VM
// — see MEMORY). The seams default to the real service in production.

const Map<String, dynamic> _summary = {
  'ordinary_income': 5000.0,
  'wage_income': 4000.0,
  'dividend_income': 600.0,
  'interest_income': 400.0,
  'capital_gains': 150.0,
  'short_term_gains': 200.0,
  'long_term_gains': -50.0,
  'total_taxable': 5150.0,
  'estimated_liability_us': 800.0,
  'estimated_liability_mx': 1100.0,
  'effective_rate_us': 0.15,
  'effective_rate_mx': 0.21,
  'bracket_year_used': 2025,
  'constants_verified': false,
  'gains_from_lots': true,
  'holdings_without_basis': 2,
};

final List<dynamic> _transactions = [
  {
    'date': '2025-03-01',
    'amount': 5000.0,
    'amount_usd': 5000.0,
    'currency': 'USD',
    'description': 'Payroll',
    'category': 'INCOME',
  },
];

final List<dynamic> _disposals = [
  {
    'symbol': 'VTI',
    'name': 'Vanguard Total',
    'acquired_date': '2022-01-10',
    'sell_date': '2025-04-02',
    'long_term': true,
    'qty_sold': 10,
    'proceeds_usd': 1200.0,
    'cost_usd': 1000.0,
    'gain_usd': 200.0, // gain → green
    'account_type': 'brokerage',
    'tax_advantaged': false,
    'from_lots': true,
  },
  {
    'symbol': 'ARKK',
    'name': 'ARK Innovation',
    'acquired_date': '2024-06-01',
    'sell_date': '2025-05-02',
    'long_term': false,
    'qty_sold': 5,
    'proceeds_usd': 300.0,
    'cost_usd': 350.0,
    'gain_usd': -50.0, // LOSS → must render red, not green
    'account_type': 'brokerage',
    'tax_advantaged': false,
    'from_lots': true,
  },
  {
    'symbol': 'FXAIX',
    'name': '401k Fund',
    'acquired_date': '2021-01-01',
    'sell_date': '2025-02-02',
    'long_term': true,
    'qty_sold': 2,
    'proceeds_usd': 5000.0,
    'cost_usd': 1000.0,
    'gain_usd': 4000.0, // tax-advantaged → separate section, not taxable
    'account_type': '401k',
    'tax_advantaged': true,
    'from_lots': true,
  },
];

Widget _host({Map<String, dynamic>? settingStore}) {
  final store = settingStore ?? <String, dynamic>{};
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: TaxPlanningScreen(
        conversionFactor: 1.0,
        currencyFormat: NumberFormat.currency(symbol: r'$', decimalDigits: 0),
        targetCurrency: 'USD',
        usdMxnRate: 18.0,
        summaryFetcher: ({required int year, required String status}) async =>
            _summary,
        transactionsFetcher: ({required int year}) async => _transactions,
        disposalsFetcher: (int year) async => _disposals,
        settingReader: (key) async => store[key],
        settingWriter: (key, value) async => store[key] = value,
      ),
    ),
  );
}

void _setSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  testWidgets('renders disposals with a loss colored red and a gain green',
      (tester) async {
    _setSize(tester, const Size(1100, 1600));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    // Both taxable disposals visible.
    expect(find.text('VTI'), findsOneWidget);
    expect(find.text('ARKK'), findsOneWidget);

    // Signed amounts: gain carries a leading '+', loss a leading '-'.
    final gainText = tester.widget<Text>(find.text(r'+$200'));
    final lossText = tester.widget<Text>(find.text(r'-$50'));
    // Distinct colors (the old screen painted every row positive-green).
    expect(gainText.style!.color, isNot(equals(lossText.style!.color)));
  });

  testWidgets('tax-advantaged disposal is split out, not in the taxable list',
      (tester) async {
    _setSize(tester, const Size(1100, 1600));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('en'));
    // The 401k fund appears under its own labeled section.
    expect(find.text('FXAIX'), findsOneWidget);
    expect(find.text(l.taxTaxAdvantagedSection), findsOneWidget);
    // Its $4,000 gain is NOT summed into the taxable net subtotal of +$150.
    expect(find.text(l.taxGainsSubtotal(r'+$150')), findsOneWidget);
  });

  testWidgets('loads persisted filing status instead of resetting to Single',
      (tester) async {
    _setSize(tester, const Size(1100, 1600));
    await tester.pumpWidget(
        _host(settingStore: {'tax_filing_status': 'Married'}));
    await tester.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('en'));
    // The Married label shows in the filing-status dropdown.
    expect(find.text(l.taxFilingMarried), findsWidgets);
  });
}
