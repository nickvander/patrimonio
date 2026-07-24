import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/utils/currency.dart';

import 'projection_test_host.dart';

// Display-money rules on a swept surface, with the app's REAL currency format
// (moneyFormat → 2 decimals; other projection tests inject a decimalDigits:0
// format that can't regress):
//  * figures at/above $10,000 render without cents — "Full FIRE $1,000,000",
//    never "$1,000,000.00";
//  * the income-at-projected-balance milestone rounds to whole dollars even
//    below the threshold (honesty pass: it's withdrawal rate × the projected
//    balance — an estimate — so "$3,300.75" faked precision).

void main() {
  testWidgets(
      'milestone tile + plan card show the \$1M FIRE target without cents '
      'under the app-real 2-decimal format', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost(
      currencyFormat: moneyFormat('USD'),
    ));
    await tester.pumpAndSettle();

    // Plan card headline + target milestone tile: centless at $1M.
    expect(find.text(r'$1,000,000'), findsNWidgets(2));
    // No swept surface renders the old cents form anywhere on screen.
    expect(find.textContaining(r'$1,000,000.00'), findsNothing);
    expect(find.textContaining(r'$500,000.00'), findsNothing);
  });

  testWidgets(
      'income-at-projected-balance tile rounds to whole dollars even below '
      'the \$10k display threshold', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost(
      currencyFormat: moneyFormat('USD'),
      projectionFetcher: fixtureFetcher(
          (y) => projectionFixture(years: y, monthlyIncomeAtRetirement: 3300.75)),
    ));
    await tester.pumpAndSettle();

    // Whole dollars, rounded — never "$3,300.75" (fake cents precision on an
    // estimated monthly income).
    expect(find.text(r'$3,301'), findsOneWidget);
    expect(find.textContaining(r'$3,300.75'), findsNothing);
    // The tile is honestly labeled after the copy pass: it derives from the
    // projected balance, not the adjacent FI number.
    expect(find.text('Income at projected balance'), findsOneWidget);
    expect(find.text('FI income'), findsNothing);
  });

  testWidgets('es-MX keeps Mexico conventions: centless above the threshold, '
      'whole-dollar milestone income below it', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost(
      locale: const Locale('es'),
      currencyFormat:
          NumberFormat.currency(locale: 'es_MX', name: 'USD', symbol: r'$'),
      projectionFetcher: fixtureFetcher(
          (y) => projectionFixture(years: y, monthlyIncomeAtRetirement: 3300.75)),
    ));
    await tester.pumpAndSettle();

    // Same comma grouping / period decimal as en — nothing Spain-style.
    expect(find.text(r'$1,000,000'), findsNWidgets(2));
    expect(find.textContaining(r'$1,000,000.00'), findsNothing);
    expect(find.text(r'$3,301'), findsOneWidget);
    expect(find.textContaining(r'$3,300.75'), findsNothing);
    // es tile title is honest too.
    expect(find.text('Ingreso al saldo proyectado'), findsOneWidget);
    expect(find.text('Ingreso FI'), findsNothing);
  });
}
