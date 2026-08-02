import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/widgets/accounts_list_widget.dart';

// Regression tests for the "Unknown subtype: depository" leak (walkthrough
// 2026-08-02): accounts stored with Plaid's broad TYPE `depository` (the
// bootstrap/test path and importers write it) fell through the classifier
// into the "Other" group — which zeroed the Cash stat tile — and the group
// subtitle printed the raw debug token to the user. Pins that:
//   1. `depository` accounts group under Cash (no Other group at all);
//   2. truly-unknown types get an honest localized generic subtitle in both
//      locales, never the raw token or the old "Unknown subtype:" string.

Widget _host(List<dynamic> accounts, {Locale locale = const Locale('en')}) =>
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: AccountsListWidget(
            accounts: accounts,
            conversionFactor: 1.0,
            currencyFormat: NumberFormat.currency(
              symbol: r'$',
              decimalDigits: 2,
            ),
            targetCurrency: 'USD',
            usdMxnRate: 20.0,
          ),
        ),
      ),
    );

Map<String, dynamic> _acc(
  String name,
  String type,
  String inst,
  double bal, {
  String cur = 'USD',
}) => {
  'id': name,
  'name': name,
  'account_type': type,
  'institution_name': inst,
  'current_balance': bal,
  'currency': cur,
};

void main() {
  testWidgets('depository-typed accounts group under Cash, not Other', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([
        _acc('Banorte Cheques', 'depository', 'Banorte', 45000.0, cur: 'MXN'),
        _acc('Fidelity Brokerage', 'brokerage', 'Fidelity', 1000.0),
      ]),
    );
    await tester.pumpAndSettle();

    // Cash group renders and holds the depository account; no Other group.
    // (Group headers render as "<title> · <count>".)
    expect(find.text('Cash · 1'), findsOneWidget);
    expect(find.text('Banorte Cheques'), findsOneWidget);
    expect(find.textContaining('Other'), findsNothing);
    // The old raw-debug fallback never renders.
    expect(find.textContaining('Unknown subtype'), findsNothing);
    expect(find.textContaining('depository'), findsNothing);
  });

  testWidgets(
    'truly-unknown type gets a generic localized subtitle, not the raw token (en)',
    (tester) async {
      await tester.pumpWidget(
        _host([
          _acc('Mystery Asset', 'timeshare points', 'Odd Bank', 500.0),
          _acc('SoFi Checking', 'checking', 'SoFi', 100.0),
        ]),
      );
      await tester.pumpAndSettle();

      // Grouped under Other with the honest generic note.
      expect(find.text('Other · 1'), findsOneWidget);
      expect(
        find.text("Includes an account type we don't recognize yet"),
        findsOneWidget,
      );
      // Never the raw token or the old debug string.
      expect(find.textContaining('Unknown subtype'), findsNothing);
      expect(find.textContaining('timeshare points'), findsNothing);
    },
  );

  testWidgets('generic subtitle is localized in es (plural: two unknowns)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([
        _acc('Mystery Asset', 'timeshare points', 'Odd Bank', 500.0),
        _acc('Weirder Asset', 'wine cellar', 'Odd Bank', 700.0),
      ], locale: const Locale('es')),
    );
    await tester.pumpAndSettle();

    expect(find.text('Otros · 2'), findsOneWidget);
    expect(
      find.text('Incluye tipos de cuenta que aún no reconocemos'),
      findsOneWidget,
    );
    expect(find.textContaining('Subtipo desconocido'), findsNothing);
    expect(find.textContaining('timeshare points'), findsNothing);
  });
}
