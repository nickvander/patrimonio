import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/add_transaction_dialog.dart';

// We construct AddTransactionDialog directly. It takes an ApiService (built
// here via the default constructor, which is VM-safe via the conditional
// api_platform export) but the test never triggers the network. Per MEMORY we
// do NOT subclass ApiService.
Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('category autocomplete surfaces a matching suggestion',
      (tester) async {
    await tester.pumpWidget(_host(
      AddTransactionDialog(
        accounts: const [
          {'id': 'acct-1', 'nickname': 'Checking', 'currency': 'USD'},
        ],
        apiService: ApiService(),
        onCreated: () {},
        categorySuggestions: const ['Dining', 'Rent'],
      ),
    ));

    final categoryField = find.widgetWithText(
      TextFormField,
      'Category (optional)',
    );
    expect(categoryField, findsOneWidget);

    await tester.enterText(categoryField, 'Din');
    await tester.pumpAndSettle();

    // The contains-match should surface 'Dining' in the options overlay,
    // but not the unrelated 'Rent'.
    expect(find.text('Dining'), findsOneWidget);
    expect(find.text('Rent'), findsNothing);
  });

  testWidgets('inline validators block submit on empty description / amount',
      (tester) async {
    await tester.pumpWidget(_host(
      AddTransactionDialog(
        accounts: const [
          {'id': 'acct-1', 'nickname': 'Checking', 'currency': 'USD'},
        ],
        apiService: ApiService(),
        onCreated: () {},
      ),
    ));

    await tester.tap(find.text('Add'));
    await tester.pump();

    expect(find.text('Description is required'), findsOneWidget);
    expect(find.text('Enter an amount'), findsOneWidget);
  });
}
