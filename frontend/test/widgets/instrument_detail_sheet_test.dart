import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/dividend_detail_sheet.dart';
import 'package:patrimonio/widgets/instrument_detail_sheet.dart';

// Both sheets take a `fetchOverride` test seam (widget tests can't subclass
// ApiService — package:web breaks the test VM — and must not hit the
// network), so a canned contract C-A / C-D payload is injected directly.
// The required `apiService` instance is real but never called.

/// Full C-A payload for a held, priceable ticker (the NVDA acceptance case).
Map<String, dynamic> _nvdaPayload() => {
      'symbol': 'NVDA',
      'name': 'NVIDIA Corp',
      'currency': 'USD',
      'asset_class': 'equity',
      'quantity': 29.5,
      'price': 172.40,
      'value_usd': 5085.80,
      'cost_basis_usd': 3100.00,
      'gain_loss_usd': 1985.80,
      'gain_loss_pct': 64.06,
      'portfolio_weight_pct': 0.33,
      'day_change_usd': 43.20,
      'day_change_pct': 0.85,
      'price_as_of': '2026-07-02',
      'accounts': [
        {
          'account_id': 'acct-1',
          'account_name': 'Robinhood',
          'account_type': 'brokerage',
          'tax_advantaged': false,
          'quantity': 29.5,
          'value_usd': 5085.80,
        },
      ],
      'lots': [
        {
          'acquired_at': '2024-03-01',
          'qty': 10.0,
          'cost_per_unit': 88.10,
          'currency': 'USD',
          'usd_cost': 881.00,
        },
      ],
      'prices': [
        {'date': '2026-06-29', 'close': 165.10},
        {'date': '2026-06-30', 'close': 168.20},
        {'date': '2026-07-01', 'close': 170.95},
        {'date': '2026-07-02', 'close': 172.40},
      ],
    };

/// Opaque-symbol payload (401k trust): prices empty, day change / basis /
/// price unknown — the sheet must degrade, never error.
Map<String, dynamic> _opaquePayload() => {
      'symbol': 'TRUST401K',
      'name': 'Company 401k Trust Fund',
      'currency': 'USD',
      'asset_class': 'equity',
      'quantity': 120.0,
      'price': null,
      'value_usd': 84000.0,
      'cost_basis_usd': null,
      'gain_loss_usd': null,
      'gain_loss_pct': null,
      'portfolio_weight_pct': 5.51,
      'day_change_usd': null,
      'day_change_pct': null,
      'price_as_of': null,
      'accounts': [
        {
          'account_id': 'acct-2',
          'account_name': 'Employer 401k',
          'account_type': '401k',
          'tax_advantaged': true,
          'quantity': 120.0,
          'value_usd': 84000.0,
        },
      ],
      'lots': <Map<String, dynamic>>[],
      'prices': <Map<String, dynamic>>[],
    };

Widget _host(Widget sheet) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: sheet),
    );

void main() {
  final currencyFormat = NumberFormat.currency(symbol: r'$');

  // The sheet body scrolls inside a 90%-height cap; a tall surface keeps
  // every section on-stage so finders don't need scrolling.
  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 1800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  InstrumentDetailSheet sheet(
    Map<String, dynamic> payload, {
    List<String>? rangeLog,
  }) {
    return InstrumentDetailSheet(
      apiService: ApiService(),
      symbol: payload['symbol'].toString(),
      conversionFactor: 1.0,
      currencyFormat: currencyFormat,
      fetchOverride: (symbol, {range = '1y'}) async {
        rangeLog?.add(range);
        return Map<String, dynamic>.of(payload);
      },
    );
  }

  group('InstrumentDetailSheet', () {
    testWidgets('renders header, price, stats, lot and account from a C-A payload',
        (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(_host(sheet(_nvdaPayload())));
      await tester.pumpAndSettle();

      // Header + price headline with day-change chip and as-of caption
      // (payload close date is in the past relative to "today").
      expect(find.text('NVDA'), findsOneWidget);
      expect(find.text('NVIDIA Corp'), findsOneWidget);
      expect(find.text(r'$172.40'), findsOneWidget);
      expect(find.text('▲ +0.85% · +\$43.20'), findsOneWidget);
      expect(find.textContaining('as of'), findsOneWidget);

      // Stat grid.
      expect(find.text('Market value'), findsOneWidget);
      expect(find.text(r'$5,085.80'), findsWidgets);
      expect(find.text(r'+$1,985.80 (+64.06%)'), findsOneWidget);
      expect(find.text('0.33%'), findsOneWidget);
      expect(find.text('Stocks & funds'), findsOneWidget);

      // Lots (row + totals) and accounts.
      expect(find.text('PURCHASE LOTS'), findsOneWidget);
      expect(find.textContaining(r'10 shares @ $88.10'), findsOneWidget);
      expect(find.text(r'$881.00'), findsWidgets);
      expect(find.text('Robinhood'), findsOneWidget);

      // Priceable symbol → real chart, no empty state; all four range chips.
      expect(find.text('No price history for this holding'), findsNothing);
      for (final chip in ['1M', '3M', '1Y', 'Max']) {
        expect(find.text(chip), findsOneWidget);
      }
      // Dividend drill-down link present.
      expect(find.textContaining('Dividend details'), findsOneWidget);
    });

    testWidgets('opaque symbol degrades: empty-chart state + em-dash stats',
        (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(_host(sheet(_opaquePayload())));
      await tester.pumpAndSettle();

      // Chart area replaced by the graceful empty state.
      expect(find.text('No price history for this holding'), findsOneWidget);
      // Cost basis + gain tiles show em-dash, never $0.
      expect(find.text('—'), findsNWidgets(2));
      expect(find.textContaining(r'$0.00'), findsNothing);
      // Everything else still renders: stats, account row + tax badge.
      expect(find.text(r'$84,000.00'), findsWidgets);
      expect(find.text('Employer 401k'), findsOneWidget);
      expect(find.text('Tax-advantaged'), findsOneWidget);
      // No day-change chip when the fields are null.
      expect(find.textContaining('▲'), findsNothing);
      expect(find.textContaining('▼'), findsNothing);
    });

    testWidgets('range chips refetch with the tapped range', (tester) async {
      useTallSurface(tester);
      final ranges = <String>[];
      await tester.pumpWidget(_host(sheet(_nvdaPayload(), rangeLog: ranges)));
      await tester.pumpAndSettle();
      expect(ranges, ['1y']);

      await tester.tap(find.text('3M'));
      await tester.pumpAndSettle();
      expect(ranges, ['1y', '3m']);

      // Re-tapping the selected chip must not refetch.
      await tester.tap(find.text('3M'));
      await tester.pumpAndSettle();
      expect(ranges, ['1y', '3m']);
    });
  });

  group('DividendDetailSheet payments section (C-D)', () {
    DividendDetailSheet divSheet(Map<String, dynamic> payload) {
      return DividendDetailSheet(
        apiService: ApiService(),
        symbol: payload['symbol'].toString(),
        conversionFactor: 1.0,
        currencyFormat: currencyFormat,
        fetchOverride: (symbol) async => Map<String, dynamic>.of(payload),
      );
    }

    Map<String, dynamic> schdPayload({List<Map<String, dynamic>>? payments}) => {
          'symbol': 'SCHD',
          'name': 'Schwab US Dividend Equity ETF',
          'currency': 'USD',
          'per_year': 4,
          'quantity': 100.0,
          'market_value_usd': 2700.0,
          'schedule': <Map<String, dynamic>>[],
          'history': <Map<String, dynamic>>[],
          'accounts': <Map<String, dynamic>>[],
          'payments': ?payments,
        };

    testWidgets('renders received payments with account + USD amount',
        (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(_host(divSheet(schdPayload(payments: [
        {
          'date': '2026-06-16',
          'amount_usd': 105.60,
          'account_name': 'Fidelity HSA',
        },
        {
          'date': '2026-03-16',
          'amount_usd': 98.10,
          'account_name': 'Robinhood',
        },
      ]))));
      await tester.pumpAndSettle();

      expect(find.text('PAYMENTS RECEIVED'), findsOneWidget);
      expect(find.text(r'+$105.60'), findsOneWidget);
      expect(find.text('Fidelity HSA'), findsOneWidget);
      expect(find.text(r'+$98.10'), findsOneWidget);
      // Only 2 payments → no expander.
      expect(find.textContaining('Show all'), findsNothing);
    });

    testWidgets('caps at 12 rows behind a Show all (N) expander',
        (tester) async {
      useTallSurface(tester);
      final many = [
        for (var i = 0; i < 15; i++)
          {
            'date': '2026-06-${(i + 1).toString().padLeft(2, '0')}',
            'amount_usd': 10.0 + i,
            'account_name': 'Account $i',
          },
      ];
      await tester.pumpWidget(_host(divSheet(schdPayload(payments: many))));
      await tester.pumpAndSettle();

      expect(find.textContaining('Account '), findsNWidgets(12));
      expect(find.text('Show all (15)'), findsOneWidget);

      await tester.tap(find.text('Show all (15)'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Account '), findsNWidgets(15));
      expect(find.text('Show fewer'), findsOneWidget);
    });

    testWidgets('section is entirely absent when payments are missing',
        (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(_host(divSheet(schdPayload())));
      await tester.pumpAndSettle();

      expect(find.text('PAYMENTS RECEIVED'), findsNothing);
      // Round-1 chrome intact: stat grid + per-share history header remain.
      expect(find.text('SCHD'), findsOneWidget);
      expect(find.text('PAYMENT HISTORY'), findsOneWidget);
    });
  });
}
