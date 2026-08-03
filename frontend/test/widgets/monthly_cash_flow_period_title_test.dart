import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/utils/currency.dart';
import 'package:patrimonio/widgets/monthly_cash_flow_card.dart';

/// D3 regression: the cash-flow card's title used to be the fixed string
/// `cfMonthlyTitle` ("Cash flow this month" / "Flujo de efectivo de este
/// mes") no matter which period the selector had. Picking "Year to date"
/// therefore produced a card *titled* "this month" sitting on year-to-date
/// figures — with its own subtitle saying "Year to date". The title now
/// only claims "this month" when the card really is headlining the latest
/// month of a single-month window; otherwise it is the neutral "Cash flow"
/// and the period name beside it (the selector's own `cfPeriod*` string,
/// threaded down as `periodLabel`) carries the window.
void main() {
  // Three months of history so the aggregate window has something to sum
  // and the single-month window has a prior month to compare against.
  const trends = <Map<String, dynamic>>[
    {'month': '2026-05', 'income': 4000.0, 'spending': 3000.0},
    {'month': '2026-06', 'income': 4200.0, 'spending': 3500.0},
    {'month': '2026-07', 'income': 4100.0, 'spending': 3900.0},
  ];

  Future<void> pumpCard(
    WidgetTester tester, {
    required Locale locale,
    String? periodLabel,
    String? selectedMonthIso,
  }) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: MonthlyCashFlowCard(
            trends: trends,
            conversionFactor: 1.0,
            currencyFormat: moneyFormat('USD'),
            periodLabel: periodLabel,
            selectedMonthIso: selectedMonthIso,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('cash-flow card title names the selected period (en)', () {
    testWidgets('this month → "Cash flow this month"', (tester) async {
      await pumpCard(tester, locale: const Locale('en'));
      expect(find.text('Cash flow this month'), findsOneWidget);
    });

    testWidgets('year to date → neutral title + the period label', (
      tester,
    ) async {
      await pumpCard(
        tester,
        locale: const Locale('en'),
        periodLabel: 'Year to date',
      );
      // The lie must be gone…
      expect(find.text('Cash flow this month'), findsNothing);
      // …and the header must state the period the figures actually cover.
      expect(find.text('Cash flow'), findsOneWidget);
      expect(find.text('Year to date'), findsOneWidget);
    });

    testWidgets('last month (back-dated single month) drops "this month"', (
      tester,
    ) async {
      await pumpCard(
        tester,
        locale: const Locale('en'),
        selectedMonthIso: '2026-06',
      );
      expect(find.text('Cash flow this month'), findsNothing);
      expect(find.text('Cash flow'), findsOneWidget);
    });
  });

  group('cash-flow card title names the selected period (es-MX)', () {
    testWidgets('este mes → "Flujo de efectivo de este mes"', (tester) async {
      await pumpCard(tester, locale: const Locale('es'));
      expect(find.text('Flujo de efectivo de este mes'), findsOneWidget);
    });

    testWidgets('en lo que va del año → neutral title + the period label', (
      tester,
    ) async {
      await pumpCard(
        tester,
        locale: const Locale('es'),
        periodLabel: 'En lo que va del año',
      );
      expect(find.text('Flujo de efectivo de este mes'), findsNothing);
      expect(find.text('Flujo de efectivo'), findsOneWidget);
      expect(find.text('En lo que va del año'), findsOneWidget);
    });
  });
}
