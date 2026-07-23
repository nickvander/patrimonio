import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/widgets/accounts_list_widget.dart';

// The "as of <date>" freshness chip on import-only (manual) account rows:
// present exactly when the overview payload carries last_data_at, absent on
// synced (Plaid) accounts, and localized in both en and es-MX.

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
  String inst, {
  String integration = 'manual',
  String? lastDataAt,
}) =>
    {
      'id': name,
      'name': name,
      'account_type': 'checking',
      'institution_name': inst,
      'current_balance': 1000.0,
      'currency': 'MXN',
      'integration_type': integration,
      'last_data_at': ?lastDataAt,
    };

void main() {
  final lastData = DateTime.now().toUtc().subtract(const Duration(days: 40));

  testWidgets('en: manual account shows an "as of <date>" chip',
      (tester) async {
    await tester.pumpWidget(_host([
      _acc('Banamex Checking', 'Banamex',
          lastDataAt: lastData.toIso8601String()),
    ]));
    await tester.pumpAndSettle();

    final expectedDate = DateFormat.yMMMd('en').format(lastData.toLocal());
    expect(find.text('as of $expectedDate'), findsOneWidget);
  });

  testWidgets('es: chip date localizes ("al <fecha>")', (tester) async {
    await tester.pumpWidget(_host(
      [
        _acc('Banamex Checking', 'Banamex',
            lastDataAt: lastData.toIso8601String()),
      ],
      locale: const Locale('es'),
    ));
    await tester.pumpAndSettle();

    final expectedDate = DateFormat.yMMMd('es').format(lastData.toLocal());
    expect(find.text('al $expectedDate'), findsOneWidget);
  });

  testWidgets('synced accounts (no last_data_at) never get the chip',
      (tester) async {
    await tester.pumpWidget(_host([
      _acc('Chase Checking', 'Chase', integration: 'plaid'),
      _acc('Manual w/o timestamp', 'Banamex'),
    ]));
    await tester.pumpAndSettle();

    expect(find.textContaining('as of'), findsNothing);
  });
}
