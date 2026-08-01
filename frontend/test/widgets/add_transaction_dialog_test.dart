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
  testWidgets('category autocomplete surfaces a matching suggestion', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AddTransactionDialog(
          accounts: const [
            {'id': 'acct-1', 'nickname': 'Checking', 'currency': 'USD'},
          ],
          apiService: ApiService(),
          onCreated: () {},
          categorySuggestions: const ['Dining', 'Rent'],
        ),
      ),
    );

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

  testWidgets('inline validators block submit on empty description / amount', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AddTransactionDialog(
          accounts: const [
            {'id': 'acct-1', 'nickname': 'Checking', 'currency': 'USD'},
          ],
          apiService: ApiService(),
          onCreated: () {},
        ),
      ),
    );

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
        find.byType(DropdownButtonFormField<String>),
      );

  testWidgets('initialAccountId preselects that account in the dropdown', (
    tester,
  ) async {
    const accounts = [
      {'id': 'acct-1', 'nickname': 'Checking', 'currency': 'USD'},
      {'id': 'acct-2', 'nickname': 'Savings', 'currency': 'MXN'},
    ];

    await tester.pumpWidget(
      _host(
        AddTransactionDialog(
          accounts: accounts,
          apiService: ApiService(),
          onCreated: () {},
          initialAccountId: 'acct-2',
        ),
      ),
    );

    // Preselected on the caller's account, not the default first-non-
    // credit pick — and the amount field's currency prefix follows it.
    expect(accountDropdown(tester).initialValue, 'acct-2');
    expect(find.text('Amount'), findsOneWidget);
    final amountDecoration = tester
        .widget<TextField>(find.widgetWithText(TextField, 'Amount'))
        .decoration;
    expect(amountDecoration?.prefixText, 'MXN ');
  });

  testWidgets('an initialAccountId not in the list falls back to the default', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AddTransactionDialog(
          accounts: const [
            {'id': 'acct-1', 'nickname': 'Checking', 'currency': 'USD'},
          ],
          apiService: ApiService(),
          onCreated: () {},
          initialAccountId: 'acct-gone',
        ),
      ),
    );

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

  testWidgets('edit mode pre-fills every field from the row (en)', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AddTransactionDialog(
          accounts: editAccounts,
          apiService: ApiService(),
          onCreated: () {},
          editTransaction: editTx,
        ),
      ),
    );

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
      find.byType(SegmentedButton<bool>),
    );
    expect(seg.selected, {true});
  });

  testWidgets('edit mode filters the "Uncategorized" backend sentinel', (
    tester,
  ) async {
    // A NULL category serializes as "Uncategorized" in list payloads;
    // pre-filling that would persist it as a real category on save.
    final tx = Map<String, dynamic>.from(editTx)
      ..['category'] = 'Uncategorized';
    await tester.pumpWidget(
      _host(
        AddTransactionDialog(
          accounts: editAccounts,
          apiService: ApiService(),
          onCreated: () {},
          editTransaction: tx,
        ),
      ),
    );

    expect(find.widgetWithText(TextField, 'Uncategorized'), findsNothing);
  });

  testWidgets('edit mode renders localized chrome in es', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
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
      ),
    );

    expect(find.text('Editar transacción'), findsOneWidget);
    expect(find.text('Guardar'), findsOneWidget);
  });

  // ---- Entry currency always visible (quick-win regression) ------------

  // Material renders prefixText inside an AnimatedOpacity that is 0.0 until
  // the field is focused or non-empty — so a plain text finder "finds" the
  // prefix even while it's invisible. Assert the actual opacity of the
  // nearest AnimatedOpacity ancestor (closest-first ordering).
  double prefixOpacity(WidgetTester tester, String prefix) {
    return tester
        .widget<AnimatedOpacity>(
          find
              .ancestor(
                of: find.text(prefix),
                matching: find.byType(AnimatedOpacity),
              )
              .first,
        )
        .opacity;
  }

  testWidgets(
    'entry currency is visible on the amount field without focusing it',
    (tester) async {
      await tester.pumpWidget(
        _host(
          AddTransactionDialog(
            accounts: const [
              {'id': 'acct-1', 'nickname': 'Checking', 'currency': 'USD'},
              {'id': 'acct-2', 'nickname': 'CETES Directo', 'currency': 'MXN'},
            ],
            apiService: ApiService(),
            onCreated: () {},
            initialAccountId: 'acct-2',
          ),
        ),
      );
      await tester.pump();

      // Add mode: the amount field is empty and unfocused — the account's
      // currency prefix must be painted anyway (regression: prefixText used
      // to hide until focus because the label sat in-line).
      expect(prefixOpacity(tester, 'MXN '), 1.0);
    },
  );

  testWidgets('account dropdown entries carry the native currency', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(
        AddTransactionDialog(
          accounts: const [
            {
              'id': 'acct-1',
              'nickname': 'Fidelity Brokerage',
              'currency': 'USD',
            },
            {'id': 'acct-2', 'nickname': 'CETES Directo', 'currency': 'MXN'},
          ],
          apiService: ApiService(),
          onCreated: () {},
        ),
      ),
    );

    // The collapsed dropdown keeps every item in its internal IndexedStack;
    // non-selected items are offstage, so search offstage too — each label
    // (name + " · CODE" token) is present exactly once.
    expect(find.text(' · USD', skipOffstage: false), findsOneWidget);
    expect(find.text(' · MXN', skipOffstage: false), findsOneWidget);
    expect(
      find.text('Fidelity Brokerage', skipOffstage: false),
      findsOneWidget,
    );
    expect(find.text('CETES Directo', skipOffstage: false), findsOneWidget);
  });

  testWidgets('phone width (390) lays out with the amount field widest', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      _host(
        AddTransactionDialog(
          accounts: const [
            {'id': 'acct-2', 'nickname': 'CETES Directo', 'currency': 'MXN'},
          ],
          apiService: ApiService(),
          onCreated: () {},
        ),
      ),
    );
    await tester.pump();

    // Any RenderFlex overflow at this width fails the test on its own;
    // additionally the amount field (currency + digits, the cramped one)
    // must have taken the wider share of the row vs the date field.
    final amountWidth = tester
        .getSize(find.widgetWithText(TextFormField, 'Amount'))
        .width;
    final dateWidth = tester
        .getSize(find.widgetWithText(InputDecorator, 'Date').first)
        .width;
    expect(amountWidth, greaterThan(dateWidth));
    expect(prefixOpacity(tester, 'MXN '), 1.0);
  });
}
