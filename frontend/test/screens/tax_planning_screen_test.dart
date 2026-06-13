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

// T11 — unrealized lots: one near-long-term short lot, one loss lot that is a
// harvest candidate with a wash-sale risk, one long-term gain lot.
const Map<String, dynamic> _unrealized = {
  'lots': [
    {
      'symbol': 'NVDA',
      'name': 'NVIDIA',
      'account_name': 'Fidelity Brokerage',
      'account_type': 'brokerage',
      'acquired_date': '2024-12-01',
      'qty': 3,
      'cost_basis_usd': 900.0,
      'current_value_usd': 1200.0,
      'unrealized_gain_usd': 300.0, // gain → green
      'long_term': false,
      'days_until_long_term': 30, // within 60 → near-long-term highlight
      'long_term_date': '2025-12-02',
    },
    {
      'symbol': 'PLTR',
      'name': 'Palantir',
      'account_name': 'Fidelity Brokerage',
      'account_type': 'brokerage',
      'acquired_date': '2025-01-15',
      'qty': 10,
      'cost_basis_usd': 500.0,
      'current_value_usd': 350.0,
      'unrealized_gain_usd': -150.0, // LOSS → red + harvest candidate
      'long_term': false,
      'days_until_long_term': 220,
      'long_term_date': '2026-01-16',
      'estimated_tax_savings_usd': 33.0,
      'wash_sale_risk': true,
      'wash_sale_safe_after': '2026-07-13',
    },
    {
      'symbol': 'VOO',
      'name': 'Vanguard S&P 500',
      'account_name': 'Fidelity Brokerage',
      'account_type': 'brokerage',
      'acquired_date': '2020-01-01',
      'qty': 4,
      'cost_basis_usd': 1000.0,
      'current_value_usd': 1800.0,
      'unrealized_gain_usd': 800.0,
      'long_term': true,
    },
  ],
  'short_term_gain': 150.0,
  'long_term_gain': 800.0,
  'ordinary_marginal_rate': 0.22,
  'ltcg_marginal_rate': 0.15,
  'bracket_year_used': 2025,
  'constants_verified': false,
};

// T13 — FBAR: peak over the $10k threshold, one foreign MXN account.
const Map<String, dynamic> _fbar = {
  'year': 2025,
  'threshold_usd': 10000.0,
  'peak_aggregate_usd': 14500.0,
  'exceeded': true,
  'peak_date': '2025-08-15',
  'foreign_accounts': [
    {
      'account_id': null,
      'name': 'Banamex Checking',
      'institution': 'Banamex',
      'country': 'MX',
      'currency': 'MXN',
      'peak_contribution_usd': 14500.0,
      'ytd_max_usd': 14500.0,
    },
  ],
  'constants_verified': false,
};

// T15 — retirement: a 401k group with room left, prior-year window false.
const Map<String, dynamic> _contributions = {
  'year': 2025,
  'limit_year_used': 2025,
  'groups': [
    {
      'group': '401k',
      'account_types': ['401k'],
      'ytd_contributions_usd': 5000.0,
      'limit_base_usd': 23500.0,
      'catch_up_usd': 7500.0,
      'limit_with_catch_up_usd': 31000.0,
      'remaining_room_usd': 18500.0,
      'deadline': '2025-12-31',
      'prior_year_window': false,
      'match_rollover_caveat': true,
    },
  ],
  'constants_verified': false,
};

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
        unrealizedFetcher:
            ({required int year, required String status}) async => _unrealized,
        fbarFetcher: (int year) async => _fbar,
        contributionsFetcher: (int year) async => _contributions,
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

  testWidgets('T11: a loss lot renders red and shows a harvest estimate',
      (tester) async {
    _setSize(tester, const Size(1100, 2600));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('en'));

    // The loss lot (PLTR, -$150) is present and rendered with the negative
    // sign-color; the gain lot (NVDA, +$300) is positive — distinct colors.
    // (-$150 appears in both the ST bucket row and the harvest sub-card, so
    // take the first.)
    final lossText = tester.widget<Text>(find.text(r'-$150').first);
    final gainText = tester.widget<Text>(find.text(r'+$300'));
    expect(lossText.style!.color, isNot(equals(gainText.style!.color)));

    // The harvest sub-card surfaces the gated tax-saving estimate for it.
    expect(find.text(l.taxHarvestTitle), findsOneWidget);
    expect(find.text(l.taxHarvestEstimate(r'$33')), findsOneWidget);
    // …with the wash-sale marker on the flagged loss.
    expect(find.text(l.taxWashSaleMarker), findsWidgets);
  });

  testWidgets('T13: FBAR exceeded state is surfaced', (tester) async {
    _setSize(tester, const Size(1100, 2600));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l.taxFbarTitle), findsOneWidget);
    expect(find.text(l.taxFbarExceeded), findsOneWidget);
    // The foreign account contributing to the peak is listed.
    expect(find.text('Banamex Checking'), findsOneWidget);
  });

  testWidgets('T15: a contribution row shows remaining room', (tester) async {
    _setSize(tester, const Size(1100, 2600));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    final l = await AppLocalizations.delegate.load(const Locale('en'));
    expect(find.text(l.taxRetirementTitle), findsOneWidget);
    expect(find.text(l.taxRetirementGroup401k), findsOneWidget);
    // 23,500 limit − 5,000 YTD = 18,500 room left.
    expect(find.text(l.taxRemainingRoom(r'$18,500')), findsOneWidget);
  });
}
