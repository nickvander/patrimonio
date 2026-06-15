import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/widgets/accounts_list_widget.dart';

// Institution-collapse behaviour in AccountsListWidget: a bank with 2+
// accounts folds into ONE summary header (bank · N accounts · combined
// total) that expands on tap; a bank with a single account stays a plain row.

Widget _host(List<dynamic> accounts) => MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: AccountsListWidget(
            accounts: accounts,
            conversionFactor: 1.0,
            currencyFormat:
                NumberFormat.currency(symbol: r'$', decimalDigits: 2),
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
}) =>
    {
      'id': name,
      'name': name,
      'account_type': type,
      'institution_name': inst,
      'current_balance': bal,
      'currency': cur,
    };

void main() {
  testWidgets('a multi-account bank collapses behind one summary header',
      (tester) async {
    await tester.pumpWidget(_host([
      _acc('SoFi Checking', 'checking', 'SoFi', 100.0),
      _acc('SoFi Savings', 'savings', 'SoFi', 50.0),
    ]));
    await tester.pumpAndSettle();

    // One collapsed institution header carrying the account count + name.
    expect(find.text('2 accounts'), findsOneWidget);
    expect(find.text('SoFi'), findsWidgets);
    // Collapsed by default → the expand affordance (chevron) is present.
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    // Tapping the header expands it (chevron flips) without error.
    await tester.tap(find.text('2 accounts'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.expand_more), findsWidgets);
    expect(find.text('2 accounts'), findsOneWidget); // header persists
  });

  testWidgets('a single-account bank stays a plain row (no collapse header)',
      (tester) async {
    await tester.pumpWidget(_host([
      _acc('Discover it Card', 'credit card', 'Discover', 25.0),
    ]));
    await tester.pumpAndSettle();

    // The account renders directly; we never synthesize a "1 account" header.
    expect(find.text('Discover it Card'), findsOneWidget);
    expect(find.text('1 account'), findsNothing);
  });

  testWidgets('combined header total uses the native figure for a '
      'single-currency bank', (tester) async {
    await tester.pumpWidget(_host([
      _acc('Revolut — Cuenta', 'checking', 'Revolut', 0.0, cur: 'MXN'),
      _acc('Revolut — Instant Access Savings', 'checking', 'Revolut', 25196.30,
          cur: 'MXN'),
    ]));
    await tester.pumpAndSettle();

    // Two MXN accounts → header shows the MXN total (25,196.30), NOT a
    // USD-converted figure.
    expect(find.text('2 accounts'), findsOneWidget);
    expect(find.textContaining('25,196'), findsWidgets);
  });
}
