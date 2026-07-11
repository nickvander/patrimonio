import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/components/allocation_heatmap.dart'
    show AllocationData;
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/rebalancing_card.dart';

// WS2r4: widget tests for the rebalancing card. The card takes
// load/saveTargetsOverride test seams (widget tests can't subclass
// ApiService — package:web breaks the test VM — and must not hit the
// network); the required apiService instance is real but never called.

Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

/// The owner's real portfolio shape: GOOG alone is ~53% of the total and
/// pushes equity to 78% — the card must stay sane under extreme drift.
List<AllocationData> _googHeavyAllocation() => [
      AllocationData('Stocks/ETFs', 'GOOG', 795000, Colors.teal,
          assetClassKey: 'equity'),
      AllocationData('Stocks/ETFs', 'VTI', 375000, Colors.teal,
          assetClassKey: 'equity'),
      AllocationData('Fixed Income', 'BND', 150000, Colors.green,
          assetClassKey: 'bonds'),
      AllocationData('Cash', 'USD', 150000, Colors.blue,
          assetClassKey: 'cash'),
      AllocationData('Crypto', 'BTC', 30000, Colors.purple,
          assetClassKey: 'crypto'),
    ];

void main() {
  final currencyFormat = NumberFormat.currency(symbol: r'$');

  RebalancingCard card({
    required List<AllocationData> data,
    required Future<dynamic> Function() load,
    Future<void> Function(dynamic)? save,
  }) {
    return RebalancingCard(
      apiService: ApiService(),
      allocationData: data,
      conversionFactor: 1.0,
      currencyFormat: currencyFormat,
      loadTargetsOverride: load,
      saveTargetsOverride: save ?? (_) async {},
    );
  }

  group('RebalancingCard editor', () {
    testWidgets(
        'sum-to-100 validation: Save gated on the meter, Distribute '
        'remainder repairs, saved payload is the C4-A shape', (tester) async {
      dynamic savedPayload = 'never-called';
      final data = [
        AllocationData('Stocks/ETFs', 'VTI', 60000, Colors.teal,
            assetClassKey: 'equity'),
        AllocationData('Fixed Income', 'BND', 25000, Colors.green,
            assetClassKey: 'bonds'),
        AllocationData('Cash', 'USD', 15000, Colors.blue,
            assetClassKey: 'cash'),
      ];
      await tester.pumpWidget(_host(card(
        data: data,
        load: () async => null, // never written → setup CTA
        save: (v) async => savedPayload = v,
      )));
      await tester.pumpAndSettle();

      // CTA state (decision #3): compact card, not hidden.
      expect(
          find.text(
              'Set target percentages per asset class to see drift and rebalancing hints'),
          findsOneWidget);
      await tester.tap(find.text('Set targets'));
      await tester.pumpAndSettle();

      // Editor prefilled from current actuals (60/25/15) — overwrite cash
      // so the total drops to 95.
      final fields = find.byType(TextField);
      expect(fields, findsNWidgets(7)); // one per canonical class
      await tester.enterText(fields.at(2), '10'); // cash
      await tester.pumpAndSettle();

      expect(find.text('Total: 95 / 100'), findsOneWidget);
      final saveButton = find.widgetWithText(FilledButton, 'Save');
      expect(tester.widget<FilledButton>(saveButton).onPressed, isNull);

      // Helper dumps the residual into the largest field (equity 60 → 65).
      await tester.tap(find.text('Distribute remainder'));
      await tester.pumpAndSettle();
      expect(find.text('Total: 100 / 100'), findsOneWidget);
      expect(tester.widget<FilledButton>(saveButton).onPressed, isNotNull);

      await tester.tap(saveButton);
      await tester.pumpAndSettle();

      // C4-A write shape, whole values as ints, zero classes omitted.
      expect(savedPayload, {
        'v': 1,
        'targets': {'equity': 65, 'bonds': 25, 'cash': 10},
      });

      // Card flipped to the full state without a reload: drift rows with
      // delta chips on both sides of the band.
      expect(find.text('-5.0 pp'), findsOneWidget); // equity 60 vs 65
      expect(find.text('on target'), findsOneWidget); // bonds 25 vs 25
      expect(find.text('+5.0 pp'), findsOneWidget); // cash 15 vs 10
      // Guidance pairs the cash surplus with the equity deficit.
      expect(find.text(r'Move $5,000.00 from Cash to Stocks & funds'),
          findsOneWidget);
      // Mandatory tax caveat.
      expect(
          find.text(
              'Guidance only — consider taxes and lot selection before selling.'),
          findsOneWidget);
    });

    testWidgets('Remove targets: confirm → cleared (null) → CTA returns',
        (tester) async {
      dynamic savedPayload = 'never-called';
      await tester.pumpWidget(_host(card(
        data: _googHeavyAllocation(),
        load: () async => {
          'v': 1,
          'targets': {'equity': 65, 'bonds': 20, 'cash': 10, 'crypto': 5},
        },
        save: (v) async => savedPayload = v,
      )));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Edit targets'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Remove targets'));
      await tester.pumpAndSettle();

      // Confirm dialog → destructive action.
      expect(find.text('Remove targets?'), findsOneWidget);
      await tester.tap(find.descendant(
        of: find.byType(AlertDialog),
        matching: find.text('Remove targets'),
      ));
      await tester.pumpAndSettle();

      expect(savedPayload, isNull); // cleared state is JSON null (C4-A)
      expect(find.text('Set targets'), findsOneWidget); // back to the CTA
    });
  });

  group('RebalancingCard drift rendering', () {
    testWidgets(
        'GOOG-heavy extreme drift stays sane at 390px: clamped warning bar, '
        'big delta chip, dollar guidance, no overflow', (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_host(card(
        data: _googHeavyAllocation(),
        load: () async => {
          'v': 1,
          'targets': {'equity': 65, 'bonds': 20, 'cash': 10, 'crypto': 5},
        },
      )));
      await tester.pumpAndSettle();

      // Equity: 78% actual vs 65% target on the $1.5M-shaped seed.
      expect(find.text('78.0% / 65%'), findsOneWidget);
      expect(find.text('+13.0 pp'), findsOneWidget);
      expect(find.text('on target'), findsOneWidget); // cash 10 vs 10

      // Greedy guidance: largest deficit first, then the remainder.
      // Display rule: >= $10k drops cents ("$150,000", not "$150,000.00").
      expect(find.text(r'Move $150,000 from Stocks & funds to Bonds'),
          findsOneWidget);
      expect(find.text(r'Move $45,000 from Stocks & funds to Crypto'),
          findsOneWidget);
      // Two moves resolve everything — no truncation line.
      expect(find.text('…and smaller adjustments'), findsNothing);
      // Mandatory tax caveat under the guidance.
      expect(
          find.text(
              'Guidance only — consider taxes and lot selection before selling.'),
          findsOneWidget);
      // 390px must stack without overflow errors.
      expect(tester.takeException(), isNull);
    });

    testWidgets('malformed stored setting → repair state, no garbage bars',
        (tester) async {
      await tester.pumpWidget(_host(card(
        data: _googHeavyAllocation(),
        load: () async => {
          'v': 1,
          'targets': {'equity': 50}, // sum 50 ≠ 100
        },
      )));
      await tester.pumpAndSettle();

      expect(
          find.text("Saved targets need attention — they don't add up to 100%."),
          findsOneWidget);
      expect(find.text('Fix targets'), findsOneWidget);
      // No drift rows / chips in the repair state.
      expect(find.textContaining(' pp'), findsNothing);
      expect(find.text('on target'), findsNothing);
    });

    testWidgets(
        'unclassified balances stay in the denominator and get the footnote',
        (tester) async {
      await tester.pumpWidget(_host(card(
        data: [
          AllocationData('Stocks/ETFs', 'VTI', 60000, Colors.teal,
              assetClassKey: 'equity'),
          AllocationData('Cash', 'USD', 20000, Colors.blue,
              assetClassKey: 'cash'),
          AllocationData('Unclassified', 'Old 401k', 20000, Colors.grey,
              assetClassKey: 'unclassified'),
        ],
        load: () async => {
          'v': 1,
          'targets': {'equity': 75, 'cash': 25},
        },
      )));
      await tester.pumpAndSettle();

      // Actuals are computed over the FULL total (decision #5): equity is
      // 60%, not 75% — and the unclassified money is called out.
      expect(find.text('60.0% / 75%'), findsOneWidget);
      expect(
          find.text(
              'Unclassified: 20.0% — classify these holdings to include them in targets'),
          findsOneWidget);
    });
  });
}
