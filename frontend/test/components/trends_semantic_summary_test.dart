import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:patrimonio/components/trends_chart.dart';
import 'package:patrimonio/l10n/app_localizations.dart';

// Regression guard for the gen-l10n placeholder-transposition trap
// (skills/flutter-frontend/SKILL.md §2). `lwTrendsSemanticSummary`'s generated
// signature is alphabetical — (count, income, month, spending) — but the
// template reads {month} before {income}. The call site in trends_chart.dart
// previously passed reading order, so the screen-reader summary rendered the
// month where income belonged ("income <month>, ..."). income and spending are
// distinct amounts, so a swap would put the month label immediately after
// "income"/"ingresos" instead of $1,000.00.
//
// Also guards two edge-case crashes this file previously had with a
// single-month, whole-number payload: clamp(2, 1) (ArgumentError) and passing
// an int `toY` to fl_chart (int is not a subtype of double).
void main() {
  final currencyFormat = NumberFormat.currency(
    locale: 'en_US',
    symbol: r'$',
    decimalDigits: 2,
  );

  // Whole-number (int) amounts — exercises the JSON-int coercion path.
  final trends = <Map<String, dynamic>>[
    {'month': '2026-03', 'income': 1000, 'spending': 800},
  ];

  Future<void> pump(WidgetTester tester, Locale locale) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 1000,
              height: 600,
              child: CashFlowTrendsChart(
                trends: trends,
                conversionFactor: 1.0,
                currencyFormat: currencyFormat,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('English summary keeps income amount next to "income"', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await pump(tester, const Locale('en'));
    // The correct-order substring exists in the summary semantics node...
    expect(
      find.bySemanticsLabel(RegExp(r'income \$1,000\.00, spending \$800\.00')),
      findsOneWidget,
    );
    // ...and the transposed form (month label in the income slot) does not.
    expect(find.bySemanticsLabel(RegExp(r'income March 2026')), findsNothing);
    handle.dispose();
  });

  testWidgets(
    'Spanish (es-MX) summary keeps income amount next to "ingresos"',
    (tester) async {
      final handle = tester.ensureSemantics();
      await pump(tester, const Locale('es'));
      expect(
        find.bySemanticsLabel(
          RegExp(r'ingresos \$1,000\.00, gastos \$800\.00'),
        ),
        findsOneWidget,
      );
      handle.dispose();
    },
  );
}
