import 'dart:async';

import 'package:fl_chart/fl_chart.dart';
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
    AssetClassMutator? mutate,
    VoidCallback? onClassificationChanged,
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
      mutateOverride: mutate,
      onClassificationChanged: onClassificationChanged,
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
      // Display rule: >= $10k drops cents ($84,000, not $84,000.00).
      expect(find.text(r'$84,000'), findsWidgets);
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

  group('asset-class override editor (I2 / C3-C)', () {
    Future<void> openSelector(WidgetTester tester) async {
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pumpAndSettle();
    }

    testWidgets(
        'heuristic class: tile has pencil, selector lists 7 radio rows with '
        'the current class checked and NO Automatic row', (tester) async {
      useTallSurface(tester);
      await tester.pumpWidget(_host(sheet(_nvdaPayload())));
      await tester.pumpAndSettle();

      // Quiet pencil affordance on the tile; no "manual" caption while the
      // classification is the heuristic.
      expect(find.byIcon(Icons.edit_outlined), findsOneWidget);
      expect(find.text('manual'), findsNothing);

      await openSelector(tester);

      // All seven classes; "Stocks & funds" appears twice (tile chip + row).
      for (final label in [
        'Bonds', 'Cash', 'Crypto', 'Real estate', 'Commodities', 'Other',
      ]) {
        expect(find.text(label), findsOneWidget);
      }
      expect(find.text('Stocks & funds'), findsNWidgets(2));
      // Exactly one check — on the active (current heuristic) row — and no
      // Automatic revert row while nothing is overridden.
      expect(find.byIcon(Icons.check), findsOneWidget);
      expect(find.textContaining('Automatic'), findsNothing);

      // Selector rows meet the 44px touch target.
      final bondsRowSize = tester.getSize(
        find.ancestor(of: find.text('Bonds'), matching: find.byType(InkWell)).first,
      );
      expect(bondsRowSize.height, greaterThanOrEqualTo(44));

      // Tapping the checked row is a radio no-op: selector closes, nothing
      // mutates (mutate seam is null here — a call would throw).
      await tester.tap(find.text('Stocks & funds').last);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check), findsNothing); // selector closed
      expect(find.text('manual'), findsNothing);
    });

    testWidgets(
        'override payload: "manual" caption on the tile and an '
        '"Automatic — <heuristic>" revert row in the selector', (tester) async {
      useTallSurface(tester);
      final payload = _nvdaPayload()
        ..['asset_class'] = 'bonds'
        ..['asset_class_source'] = 'override'
        ..['asset_class_heuristic'] = 'equity';
      final calls = <String?>[];
      await tester.pumpWidget(_host(sheet(
        payload,
        mutate: (symbol, assetClass) async {
          calls.add(assetClass);
          payload
            ..['asset_class'] = 'equity'
            ..['asset_class_source'] = 'heuristic'
            ..remove('asset_class_heuristic');
          return {
            'symbol': symbol,
            'asset_class': 'equity',
            'asset_class_source': 'heuristic',
          };
        },
      )));
      await tester.pumpAndSettle();

      expect(find.text('manual'), findsOneWidget);
      expect(find.text('Bonds'), findsOneWidget); // overridden chip

      await openSelector(tester);
      expect(find.text('Automatic — Stocks & funds'), findsOneWidget);

      // Revert: Automatic row → mutate(null) → chip back to the heuristic
      // class, caption gone.
      await tester.tap(find.text('Automatic — Stocks & funds'));
      await tester.pumpAndSettle();
      expect(calls, [null]);
      expect(find.text('manual'), findsNothing);
      expect(find.text('Stocks & funds'), findsOneWidget);
      expect(find.text('Bonds'), findsNothing);
    });

    testWidgets(
        'picking a class flips the chip optimistically, then reports the '
        'change and refetches on success', (tester) async {
      useTallSurface(tester);
      final payload = _nvdaPayload();
      final ranges = <String>[];
      final completer = Completer<Map<String, dynamic>>();
      var changed = false;
      await tester.pumpWidget(_host(sheet(
        payload,
        rangeLog: ranges,
        onClassificationChanged: () => changed = true,
        mutate: (symbol, assetClass) {
          expect(symbol, 'NVDA');
          expect(assetClass, 'bonds');
          // Keep the canned payload coherent for the follow-up refetch.
          payload
            ..['asset_class'] = 'bonds'
            ..['asset_class_source'] = 'override';
          return completer.future;
        },
      )));
      await tester.pumpAndSettle();
      expect(ranges, ['1y']);

      await openSelector(tester);
      await tester.tap(find.text('Bonds'));
      await tester.pumpAndSettle();

      // Mutation still in flight: chip + "manual" caption already flipped,
      // nothing reported upward yet, no refetch yet.
      expect(find.text('Bonds'), findsOneWidget);
      expect(find.text('manual'), findsOneWidget);
      expect(changed, isFalse);
      expect(ranges, ['1y']);

      completer.complete({
        'symbol': 'NVDA',
        'asset_class': 'bonds',
        'asset_class_source': 'override',
      });
      await tester.pumpAndSettle();

      expect(changed, isTrue); // C3-C: sheet resolves true
      expect(ranges, ['1y', '1y']); // success refetches the current range
      expect(find.text('Bonds'), findsOneWidget);
      expect(find.text('manual'), findsOneWidget);
    });

    testWidgets('failed mutation reverts the chip and shows the error snackbar',
        (tester) async {
      useTallSurface(tester);
      var changed = false;
      await tester.pumpWidget(_host(sheet(
        _nvdaPayload(),
        onClassificationChanged: () => changed = true,
        mutate: (symbol, assetClass) async =>
            throw Exception('backend down'),
      )));
      await tester.pumpAndSettle();

      await openSelector(tester);
      await tester.tap(find.text('Bonds'));
      await tester.pumpAndSettle();

      // Revert: heuristic chip back, no "manual", nothing reported up.
      expect(find.text('Stocks & funds'), findsOneWidget);
      expect(find.text('Bonds'), findsNothing);
      expect(find.text('manual'), findsNothing);
      expect(changed, isFalse);
      expect(find.text("Couldn't update the asset class"), findsOneWidget);

      // Drain the snackbar's auto-dismiss timer.
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
    });
  });

  group('day-offset x-axis math (I3)', () {
    ({DateTime date, double close}) pt(String iso, double close) =>
        (date: DateTime.parse(iso), close: close);

    test('dedupeDailyCloses keeps the LAST close per day and sorts by day', () {
      final out = dedupeDailyCloses([
        pt('2026-01-02', 11.0),
        pt('2026-01-01 10:00:00', 10.0),
        pt('2026-01-01 18:00:00', 10.5),
      ]);
      expect(out.length, 2);
      expect(out[0].date, DateTime.utc(2026, 1, 1));
      expect(out[0].close, 10.5);
      expect(out[1].date, DateTime.utc(2026, 1, 2));
      expect(out[1].close, 11.0);
    });

    test('dayOffsetSpots keeps real gaps: x is days since the first sample',
        () {
      final spots = dayOffsetSpots(dedupeDailyCloses([
        pt('2026-01-01', 10.0),
        pt('2026-01-02', 11.0),
        pt('2026-03-03', 12.0), // 60-day hole
      ]));
      expect(spots, const [
        FlSpot(0, 10.0),
        FlSpot(1, 11.0),
        FlSpot(61, 12.0),
      ]);
    });

    test('dayOffsetTickInterval is span/3, floored at one day', () {
      expect(dayOffsetTickInterval(366), 122.0);
      expect(dayOffsetTickInterval(90), 30.0);
      expect(dayOffsetTickInterval(2), 1.0); // 2-point series stays valid
      expect(dayOffsetTickInterval(0), 1.0);
    });

    testWidgets(
        'two same-day closes collapse to one point → graceful empty-chart '
        'state, not an fl_chart crash', (tester) async {
      useTallSurface(tester);
      final payload = _nvdaPayload()
        ..['prices'] = [
          {'date': '2026-07-02', 'close': 171.0},
          {'date': '2026-07-02', 'close': 172.4},
        ];
      await tester.pumpWidget(_host(sheet(payload)));
      await tester.pumpAndSettle();
      expect(find.text('No price history for this holding'), findsOneWidget);
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
