import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/utils/spending_insight.dart';
import 'package:patrimonio/widgets/spending_insight_sheet.dart';

// The insight detail sheet (P1-4): header/stat/delta rendering in en AND
// es, merchant plurals, the empty-merchant state, both CTAs (See-all pops
// + fires once; Set/Update budget dialog prefills, saves through the
// budgets store path, confirms with a SnackBar), and the chart's
// semantics mirror. ApiService is never subclassed (house test rule) —
// the sheet's budgetsOverride/putSettingOverride seams stand in for the
// inert-on-test-VM Preferences store and the backend save.

const _insight = SpendingSpikeInsight(
  categoryLabel: 'Groceries',
  recentMonth: '2026-03',
  recentUsd: 612.0,
  previousAvgUsd: 408.0,
  trailingAvgUsd: 442.0,
  lookbackMonths: 6,
);

Map<String, dynamic> _tx({
  required String date,
  required double amount,
  String? merchant,
  String description = 'MISC DEBIT',
}) => {
  'id': 'x',
  'date': date,
  'amount': amount,
  'currency': 'USD',
  'merchant_name': ?merchant,
  'description': description,
  'category': 'FOOD_AND_DRINK',
  'category_detailed': 'FOOD_AND_DRINK_GROCERIES',
};

/// March 2026 fixture: Soriana ×1 (plural =1 case), Costco ×2 (other
/// case), plus history for the trend buckets.
List<Map<String, dynamic>> _txs() => [
  _tx(date: '2026-03-05', amount: -100.0, merchant: 'Soriana'),
  _tx(date: '2026-03-10', amount: -80.0, merchant: 'Costco'),
  _tx(date: '2026-03-20', amount: -120.0, merchant: 'Costco'),
  _tx(date: '2026-01-15', amount: -300.0, merchant: 'Soriana'),
];

class _Harness extends StatelessWidget {
  final Locale locale;
  final List<dynamic> transactions;
  final VoidCallback onSeeTransactions;
  final Map<String, double>? budgetsOverride;
  final Future<void> Function(String key, dynamic value)? putSettingOverride;

  const _Harness({
    required this.locale,
    required this.transactions,
    required this.onSeeTransactions,
    this.budgetsOverride,
    this.putSettingOverride,
  });

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (ctx) => Center(
            child: ElevatedButton(
              onPressed: () => showSpendingInsightSheet(
                ctx,
                insight: _insight,
                transactions: transactions,
                currencyFormat: NumberFormat.currency(symbol: r'$'),
                conversionFactor: 1.0,
                targetCurrency: 'USD',
                usdMxnRate: 17.0,
                onSeeTransactions: onSeeTransactions,
                budgetsOverride: budgetsOverride,
                putSettingOverride: putSettingOverride,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }
}

Future<void> _open(
  WidgetTester tester, {
  Locale locale = const Locale('en'),
  List<dynamic>? transactions,
  VoidCallback? onSeeTransactions,
  Map<String, double>? budgetsOverride,
  Future<void> Function(String key, dynamic value)? putSettingOverride,
}) async {
  await tester.pumpWidget(
    _Harness(
      locale: locale,
      transactions: transactions ?? _txs(),
      onSeeTransactions: onSeeTransactions ?? () {},
      budgetsOverride: budgetsOverride,
      putSettingOverride: putSettingOverride,
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

/// The CTA row sits below the fold on the 800×600 test surface — scroll
/// the sheet's own scroll view before tapping.
Future<void> _tapAfterScroll(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('en: header, stat labels, delta line and merchants render', (
    tester,
  ) async {
    await _open(tester);

    final month = DateFormat.yMMMM('en').format(DateTime(2026, 3, 1));
    expect(find.text('Groceries'), findsOneWidget);
    expect(find.text(month), findsOneWidget);
    expect(find.text('Spent in $month'), findsOneWidget);
    expect(find.text('6-month average'), findsOneWidget);
    expect(find.text(r'$612.00'), findsOneWidget);
    expect(find.text(r'$408.00'), findsOneWidget);
    // gen-l10n signature is (amount, percent) — the exact string proves
    // no transposition.
    expect(find.text(r'$204.00 above average (50%)'), findsOneWidget);
    expect(find.text('Top merchants in $month'), findsOneWidget);

    // Ranked by USD total: Costco ($200, 2 tx) above Soriana ($100, 1 tx),
    // with plural-correct counts (=1 and other ICU cases).
    expect(find.text('Costco'), findsOneWidget);
    expect(find.text('2 transactions'), findsOneWidget);
    expect(find.text('Soriana'), findsOneWidget);
    expect(find.text('1 transaction'), findsOneWidget);

    expect(find.text('See all transactions'), findsOneWidget);
    expect(find.text('Set budget'), findsOneWidget);
  });

  testWidgets('es: the same sheet renders es-MX copy', (tester) async {
    await _open(tester, locale: const Locale('es'));

    final month = DateFormat.yMMMM('es').format(DateTime(2026, 3, 1));
    expect(find.text('Gastado en $month'), findsOneWidget);
    expect(find.text('Promedio de 6 meses'), findsOneWidget);
    expect(find.text(r'$204.00 sobre el promedio (50%)'), findsOneWidget);
    expect(find.text('Ver todas las transacciones'), findsOneWidget);
    expect(find.text('Establecer presupuesto'), findsOneWidget);
  });

  testWidgets('no loaded rows for the month → merchant empty state', (
    tester,
  ) async {
    await _open(tester, transactions: const []);
    expect(
      find.text('No loaded transactions for this month yet'),
      findsOneWidget,
    );
  });

  testWidgets('See all transactions pops the sheet, then fires exactly once', (
    tester,
  ) async {
    var fired = 0;
    await _open(tester, onSeeTransactions: () => fired++);

    await _tapAfterScroll(tester, find.text('See all transactions'));
    expect(fired, 1);
    // The sheet is gone (its header text no longer present).
    expect(find.text('Groceries'), findsNothing);
  });

  testWidgets(
    'Set budget: dialog prefilled from trailing avg rounded up to \$10, '
    'Save persists the merged map and confirms',
    (tester) async {
      final saved = <(String, dynamic)>[];
      await _open(
        tester,
        budgetsOverride: {'Dining': 120.0},
        putSettingOverride: (key, value) async => saved.add((key, value)),
      );

      await _tapAfterScroll(tester, find.text('Set budget'));

      // roundBudgetUpToTen(442) = 450, ×1.0 display factor.
      expect(find.text('Monthly budget for Groceries'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '450',
      );
      expect(find.text('Suggested from your 6-month average'), findsOneWidget);

      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      // The save merged into the existing map (never replaced it) and
      // went through the budgets-store path.
      expect(saved, hasLength(1));
      expect(saved.single.$1, 'budgets');
      expect(saved.single.$2, {'Dining': 120.0, 'Groceries': 450.0});
      // SnackBar: gen-l10n signature is (amount, category).
      expect(find.text(r'Budget saved: $450.00 for Groceries'), findsOneWidget);
    },
  );

  testWidgets(
    'an existing budget flips the CTA to Update and prefills its value',
    (tester) async {
      await _open(tester, budgetsOverride: {'Groceries': 500.0});

      expect(find.text('Set budget'), findsNothing);
      await _tapAfterScroll(tester, find.text('Update budget'));
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '500',
      );
      // Cancel — the dialog's controller must still be disposed cleanly
      // (verified by the test teardown's FlutterError check).
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );

  testWidgets('the trend chart mirrors its data into the semantics tree', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await _open(tester);
    expect(
      find.bySemanticsLabel(
        'Monthly spending for Groceries over the last 6 months',
      ),
      findsOneWidget,
    );
    handle.dispose();
  });
}
