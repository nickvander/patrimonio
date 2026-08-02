import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/utils/currency.dart';
import 'package:patrimonio/widgets/budgets_card.dart';

// Smoke + l10n coverage for BudgetsCard, focused on the over-budget alert
// banner (cfBudgetsOverAlert — an int count next to a money string, so a
// placeholder transposition would render nonsense). Budgets are seeded via
// the loadBudgetsOverride test seam: Preferences is inert under the test VM
// and the ApiService path would hit the network.
Widget _host(Locale locale, Widget child) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: SingleChildScrollView(child: child)),
);

void main() {
  final currencyFormat = NumberFormat.currency(symbol: r'$');
  final now = DateTime.now();

  // One in-month grocery outflow of $150 against a $100 budget → 1 category
  // over, $50 over in total. user_category keeps the label locale-stable.
  final transactions = [
    {
      'id': 't1',
      'date': DateTime(now.year, now.month, 1).toIso8601String(),
      'amount': -150.0,
      'currency': 'USD',
      'category': 'FOOD_AND_DRINK',
      'user_category': 'Groceries',
    },
  ];

  BudgetsCard card() => BudgetsCard(
    transactions: transactions,
    conversionFactor: 1.0,
    usdMxnRate: 17.0,
    currencyFormat: currencyFormat,
    loadBudgetsOverride: () async => {'Groceries': 100.0},
  );

  testWidgets('en: renders the budget row and the over-budget alert', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const Locale('en'), card()));
    await tester.pumpAndSettle();

    expect(find.text('Groceries'), findsOneWidget);
    final over = currencyFormat.displayMoney(50.0);
    expect(find.text('Over budget in 1 — $over over total'), findsOneWidget);
  });

  testWidgets('es: over-budget alert renders the es-MX template', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const Locale('es'), card()));
    await tester.pumpAndSettle();

    expect(find.text('Groceries'), findsOneWidget);
    final over = currencyFormat.displayMoney(50.0);
    expect(find.text('Sobre presupuesto en 1 — $over de más'), findsOneWidget);
  });
}
