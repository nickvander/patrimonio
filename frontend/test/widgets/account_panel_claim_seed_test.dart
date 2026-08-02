import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/screens/account_transactions_screen.dart';
import 'package:patrimonio/services/tx_page.dart';
import 'package:patrimonio/utils/drill_down_claim.dart';
import 'package:patrimonio/widgets/transactions_tab.dart';

/// The largest-move reroute payload: `showAccountTransactionsPanel` /
/// `AccountTransactionsScreen` accept a createdSince seed + claim banner
/// and thread them into the embedded TransactionsTab — pre-filtered rows,
/// "New since" chip, and the balance-claim banner over the account's own
/// history. Uses the panel's transactionsFetcher seam (never a real
/// ApiService — package:web breaks the test VM).

const Map<String, dynamic> _account = {
  'id': 'acct-fid',
  'name': 'Fidelity Brokerage',
  'currency': 'USD',
  'current_balance': 10000.0,
  'account_type': 'depository',
  'integration_type': 'manual',
};

/// Two rows synced after the anchor (+$1,850 net) and one older row the
/// seed must hide.
final List<Map<String, dynamic>> _table = [
  {
    'id': 'new-1',
    'date': '2026-07-30',
    'amount': 1600.0,
    'currency': 'USD',
    'description': 'TX new-1',
    'user_description': 'Row new-1',
    'category': 'INCOME',
    'account_name': 'Fidelity Brokerage',
    'created_at': '2026-08-02T12:00:00Z',
  },
  {
    'id': 'new-2',
    'date': '2026-07-29',
    'amount': 250.0,
    'currency': 'USD',
    'description': 'TX new-2',
    'user_description': 'Row new-2',
    'category': 'INCOME',
    'account_name': 'Fidelity Brokerage',
    'created_at': '2026-08-02T13:00:00Z',
  },
  {
    'id': 'old-1',
    'date': '2026-07-10',
    'amount': -75.0,
    'currency': 'USD',
    'description': 'TX old-1',
    'user_description': 'Row old-1',
    'category': 'GENERAL_MERCHANDISE',
    'account_name': 'Fidelity Brokerage',
    'created_at': '2026-07-11T12:00:00Z',
  },
];

Future<TxPage> _fetch({required int limit, required int offset}) async =>
    TxPage(
      rows: [
        for (final t in _table.skip(offset).take(limit))
          Map<String, dynamic>.of(t),
      ],
    );

final DateTime _anchor = DateTime(2026, 7, 31, 19, 59);

String _anchorDay() => DateFormat.MMMd().format(_anchor.toLocal());

Widget _host({DrillDownClaim? claim}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: AccountTransactionsScreen(
      account: _account,
      allAccounts: const [_account],
      conversionFactor: 1.0,
      currencyFormat: NumberFormat.currency(symbol: r'$'),
      targetCurrency: 'USD',
      usdMxnRate: 0,
      transactionsFetcher: _fetch,
      createdSinceSeed: _anchor,
      claimBanner: claim,
    ),
  ),
);

void _setViewSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  final claim = BalanceMoveClaim(
    deltaUsd: 1850.0,
    anchor: _anchor,
    accountName: 'Fidelity Brokerage',
  );

  testWidgets(
    'the panel threads seed + claim into its embedded TransactionsTab: '
    'rows pre-filtered to the since-anchor slice, "New since" chip, and '
    'the account-move banner',
    (tester) async {
      _setViewSize(tester, const Size(1000, 900));
      await tester.pumpWidget(_host(claim: claim));
      await tester.pumpAndSettle();

      // Seed applied: only the post-anchor rows are visible.
      expect(find.text('Row new-1'), findsOneWidget);
      expect(find.text('Row new-2'), findsOneWidget);
      expect(find.text('Row old-1'), findsNothing);
      expect(
        find.widgetWithText(InputChip, 'New since ${_anchorDay()}'),
        findsOneWidget,
      );

      // The claim banner restates the bell row's move. Visible net is
      // +$1,850 == the claim → gap 0, so NO reconciliation line.
      expect(find.textContaining('Fidelity Brokerage moved'), findsOneWidget);
      expect(find.textContaining('of this move'), findsNothing);
    },
  );

  testWidgets('the banner × dismisses panel-locally; chip + filter stay', (
    tester,
  ) async {
    _setViewSize(tester, const Size(1000, 900));
    await tester.pumpWidget(_host(claim: claim));
    await tester.pumpAndSettle();
    expect(find.textContaining('Fidelity Brokerage moved'), findsOneWidget);

    await tester.tap(
      find.descendant(
        of: find.byType(TransactionsTab),
        matching: find.byIcon(Icons.close),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Fidelity Brokerage moved'), findsNothing);
    expect(
      find.widgetWithText(InputChip, 'New since ${_anchorDay()}'),
      findsOneWidget,
    );
    expect(find.text('Row old-1'), findsNothing, reason: 'filter untouched');
  });

  testWidgets('a seed without a claim shows the chip but no banner', (
    tester,
  ) async {
    _setViewSize(tester, const Size(1000, 900));
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(
      find.widgetWithText(InputChip, 'New since ${_anchorDay()}'),
      findsOneWidget,
    );
    expect(find.textContaining('moved'), findsNothing);
  });
}
