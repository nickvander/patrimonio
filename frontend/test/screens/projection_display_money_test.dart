import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/utils/currency.dart';

import 'projection_test_host.dart';

// Display-money rule on a swept surface: with the app's REAL currency format
// (moneyFormat → 2 decimals; other projection tests inject a decimalDigits:0
// format that can't regress), figures at/above $10,000 render without cents
// on the projections screen — "Full FIRE $1,000,000", never "$1,000,000.00" —
// while sub-threshold figures keep their cents.

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

    // Sub-threshold figures keep their cents: the FI-income milestone
    // ($3,300/month at the fixture's withdrawal rate) still shows them.
    expect(find.textContaining(r'$3,300.00'), findsWidgets);
  });

  testWidgets('es-MX keeps Mexico conventions: centless above the threshold, '
      'period-decimal cents below it', (tester) async {
    setTestSize(tester, const Size(1300, 1800));
    await tester.pumpWidget(buildProjectionHost(
      locale: const Locale('es'),
      currencyFormat:
          NumberFormat.currency(locale: 'es_MX', name: 'USD', symbol: r'$'),
    ));
    await tester.pumpAndSettle();

    // Same comma grouping / period decimal as en — nothing Spain-style.
    expect(find.text(r'$1,000,000'), findsNWidgets(2));
    expect(find.textContaining(r'$1,000,000.00'), findsNothing);
    expect(find.textContaining(r'$3,300.00'), findsWidgets);
  });
}
