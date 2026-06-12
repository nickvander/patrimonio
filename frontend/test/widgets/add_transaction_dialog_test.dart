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

  // The collapsed dropdown keeps every item's Text in its internal
  // IndexedStack (only the selected one paints), so plain text finders
  // can't tell the selection apart — assert on the FormField the dialog
  // actually built instead.
  DropdownButtonFormField<String> accountDropdown(WidgetTester tester) =>
      tester.widget<DropdownButtonFormField<String>>(
          find.byType(DropdownButtonFormField<String>));

  testWidgets('initialAccountId preselects that account in the dropdown',
      (tester) async {
    const accounts = [
      {'id': 'acct-1', 'nickname': 'Checking', 'currency': 'USD'},
      {'id': 'acct-2', 'nickname': 'Savings', 'currency': 'MXN'},
    ];

    await tester.pumpWidget(_host(
      AddTransactionDialog(
        accounts: accounts,
        apiService: ApiService(),
        onCreated: () {},
        initialAccountId: 'acct-2',
      ),
    ));

    // Preselected on the caller's account, not the default first-non-
    // credit pick — and the amount field's currency prefix follows it.
    expect(accountDropdown(tester).initialValue, 'acct-2');
    expect(find.text('Amount'), findsOneWidget);
    final amountDecoration = tester
        .widget<TextField>(find.widgetWithText(TextField, 'Amount'))
        .decoration;
    expect(amountDecoration?.prefixText, 'MXN ');
  });

  testWidgets('an initialAccountId not in the list falls back to the default',
      (tester) async {
    await tester.pumpWidget(_host(
      AddTransactionDialog(
        accounts: const [
          {'id': 'acct-1', 'nickname': 'Checking', 'currency': 'USD'},
        ],
        apiService: ApiService(),
        onCreated: () {},
        initialAccountId: 'acct-gone',
      ),
    ));

    expect(accountDropdown(tester).initialValue, 'acct-1');
  });
}
