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

  // ---- Edit mode (manual transactions become editable) -----------------

  const editAccounts = [
    {'id': 'acct-1', 'nickname': 'Checking', 'currency': 'USD'},
    {'id': 'acct-2', 'nickname': 'Savings', 'currency': 'MXN'},
  ];

  // A row map as the transactions payload delivers it: negative amount =
  // outflow/expense, user_* overrides carry the effective display values.
  const editTx = {
    'id': 'tx-1',
    'account_id': 'acct-2',
    'date': '2026-01-15',
    'description': 'coffee raw',
    'user_description': 'Coffee with Sam',
    'amount': -62.75,
    'currency': 'MXN',
    'category': 'Dining',
    'user_notes': 'reimbursed',
    'source': 'manual',
  };

  testWidgets('edit mode pre-fills every field from the row (en)',
      (tester) async {
    await tester.pumpWidget(_host(
      AddTransactionDialog(
        accounts: editAccounts,
        apiService: ApiService(),
        onCreated: () {},
        editTransaction: editTx,
      ),
    ));

    // Edit chrome: title + Save (not Add), and no "Repeats" rule field —
    // correcting a row must not mint a recurring rule.
    expect(find.text('Edit transaction'), findsOneWidget);
    expect(find.text('Save'), findsOneWidget);
    expect(find.text('Add'), findsNothing);
    expect(find.text('Repeats'), findsNothing);

    // Field prefills: account, unsigned amount, effective (override-
    // first) description, category, notes.
    expect(accountDropdown(tester).initialValue, 'acct-2');
    expect(find.widgetWithText(TextField, '62.75'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Coffee with Sam'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Dining'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'reimbursed'), findsOneWidget);

    // Negative stored amount → the Expense segment is preselected.
    final seg = tester.widget<SegmentedButton<bool>>(
        find.byType(SegmentedButton<bool>));
    expect(seg.selected, {true});
  });

  testWidgets('edit mode filters the "Uncategorized" backend sentinel',
      (tester) async {
    // A NULL category serializes as "Uncategorized" in list payloads;
    // pre-filling that would persist it as a real category on save.
    final tx = Map<String, dynamic>.from(editTx)
      ..['category'] = 'Uncategorized';
    await tester.pumpWidget(_host(
      AddTransactionDialog(
        accounts: editAccounts,
        apiService: ApiService(),
        onCreated: () {},
        editTransaction: tx,
      ),
    ));

    expect(find.widgetWithText(TextField, 'Uncategorized'), findsNothing);
  });

  testWidgets('edit mode renders localized chrome in es', (tester) async {
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('es'),
      home: Scaffold(
        body: AddTransactionDialog(
          accounts: editAccounts,
          apiService: ApiService(),
          onCreated: () {},
          editTransaction: editTx,
        ),
      ),
    ));

    expect(find.text('Editar transacción'), findsOneWidget);
    expect(find.text('Guardar'), findsOneWidget);
  });
}
