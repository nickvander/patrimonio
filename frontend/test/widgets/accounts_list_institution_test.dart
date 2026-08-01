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
        currencyFormat: NumberFormat.currency(symbol: r'$', decimalDigits: 2),
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
  testWidgets('a multi-account bank collapses behind one summary header', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([
        _acc('SoFi Checking', 'checking', 'SoFi', 100.0),
        _acc('SoFi Savings', 'savings', 'SoFi', 50.0),
      ]),
    );
    await tester.pumpAndSettle();

    // One collapsed institution header carrying the account count + name.
    expect(find.text('2 accounts'), findsOneWidget);
    // The bank name shows exactly once (the header) — the per-row institution
    // sub-label is dropped when nested, so it isn't repeated under each account.
    expect(find.text('SoFi'), findsOneWidget);
    // Collapsed by default → the expand affordance (chevron) is present.
    expect(find.byIcon(Icons.chevron_right), findsOneWidget);

    // Tapping the header expands it (chevron flips) without error.
    await tester.tap(find.text('2 accounts'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.expand_more), findsWidgets);
    expect(find.text('2 accounts'), findsOneWidget); // header persists
  });

  testWidgets('a single-account bank stays a plain row (no collapse header)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host([_acc('Discover it Card', 'credit card', 'Discover', 25.0)]),
    );
    await tester.pumpAndSettle();

    // The account renders directly; we never synthesize a "1 account" header.
    expect(find.text('Discover it Card'), findsOneWidget);
    expect(find.text('1 account'), findsNothing);
  });

  testWidgets('a single-account bank does not repeat the institution label '
      'when the name already conveys it', (tester) async {
    await tester.pumpWidget(
      _host([_acc('Banamex', 'checking', 'Banamex', 4000.0, cur: 'MXN')]),
    );
    await tester.pumpAndSettle();

    // "Banamex" shows once (the name) — not stacked as name + institution.
    expect(find.text('Banamex'), findsOneWidget);
  });

  testWidgets('combined header total uses the native figure for a '
      'single-currency bank', (tester) async {
    await tester.pumpWidget(
      _host([
        _acc('Revolut — Cuenta', 'checking', 'Revolut', 0.0, cur: 'MXN'),
        _acc(
          'Revolut — Instant Access Savings',
          'checking',
          'Revolut',
          25196.30,
          cur: 'MXN',
        ),
      ]),
    );
    await tester.pumpAndSettle();

    // Two MXN accounts → header shows the MXN total (25,196.30), NOT a
    // USD-converted figure.
    expect(find.text('2 accounts'), findsOneWidget);
    expect(find.textContaining('25,196'), findsWidgets);
  });

  testWidgets('sibling credit cards never nest as vaults under a generic card '
      '(U.S. Bank "Credit Card" + "Cash +" regression)', (tester) async {
    // Real-world shape: the bank reports one card with the generic name
    // "Credit Card" (contains the type token → product) and one with a pure
    // product name "Cash +" (contains neither type token nor bank name).
    // The vault heuristic used to classify Cash+ as a nicknamed sub-account
    // and nest it under Credit Card with a "base + 1 cards" summary line.
    await tester.pumpWidget(
      _host([
        _acc('Credit Card', 'credit card', 'U.S. Bank', 103.80),
        _acc('Cash +', 'credit card', 'U.S. Bank', 458.39),
      ]),
    );
    await tester.pumpAndSettle();

    // One collapsed institution header; expand it.
    expect(find.text('2 accounts'), findsOneWidget);
    await tester.tap(find.text('2 accounts'));
    await tester.pumpAndSettle();

    // Both cards render as sibling rows with their own balances — no vault
    // subgroup and no "base + N cards" summary line. (The institution
    // header legitimately shows the combined 562.19 total, so only the
    // per-row figures are asserted.)
    expect(find.text('Credit Card'), findsOneWidget);
    expect(find.text('Cash +'), findsOneWidget);
    expect(find.textContaining('base'), findsNothing);
    expect(find.textContaining('103.80'), findsOneWidget);
    expect(find.textContaining('458.39'), findsOneWidget);
  });

  testWidgets('sibling investment accounts never nest as vaults '
      '(Vanguard 401(k) under a \$0 Traditional IRA regression)', (
    tester,
  ) async {
    // Real-world shape: "Traditional IRA" contains the type token
    // ("investment" not present, but the IRA row was classified product by
    // luck of ordering) while "GOOGLE LLC 401(K) SAVINGS PLAN" matches
    // neither token nor bank — the heuristic nested the 401(k) under the
    // IRA with "$0.00 base + 1 accounts". Vaults are cash-only now.
    await tester.pumpWidget(
      _host([
        _acc('Roth IRA', 'investment', 'Vanguard', 37676.0),
        _acc('Traditional IRA', 'investment', 'Vanguard', 0.0),
        _acc(
          'GOOGLE LLC 401(K) SAVINGS PLAN',
          'investment',
          'Vanguard',
          530947.0,
        ),
      ]),
    );
    await tester.pumpAndSettle();

    expect(find.text('3 accounts'), findsOneWidget);
    await tester.tap(find.text('3 accounts'));
    await tester.pumpAndSettle();

    // All three render as sibling rows; no vault subgroup, no "base + N".
    expect(find.text('Roth IRA'), findsOneWidget);
    expect(find.text('Traditional IRA'), findsOneWidget);
    expect(find.text('GOOGLE LLC 401(K) SAVINGS PLAN'), findsOneWidget);
    expect(find.textContaining('base'), findsNothing);
    expect(find.textContaining('Accounts · 1'), findsNothing);
  });
}
