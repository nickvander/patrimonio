import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/widgets/split_transaction_dialog.dart';

// SplitTransactionDialog takes plain values + returns its result via
// Navigator.pop, so no ApiService (and per MEMORY, no subclassing of it)
// is needed here.
Widget _host(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

SplitTransactionDialog _dialog() => SplitTransactionDialog(
      parentAmount: 100.0,
      parentCurrency: 'USD',
      parentLabel: 'Costco run',
      parentCategory: 'Groceries',
      usdMxnRate: 17.0,
      targetCurrency: 'USD',
      reportingFormat: NumberFormat.currency(name: 'USD', symbol: r'$'),
    );

/// The EditableText backing a TextFormField — lets us read the live text
/// and focus state of a specific field.
EditableText _editableOf(WidgetTester tester, Finder formField) =>
    tester.widget<EditableText>(
      find.descendant(of: formField, matching: find.byType(EditableText)),
    );

void main() {
  testWidgets('amount field keeps focus and text across keystrokes',
      (tester) async {
    await tester.pumpWidget(_host(_dialog()));

    // Create mode seeds two 50/50 rows; fields per row are
    // [description, amount], so row 0's amount field is index 1.
    final amountField = find.byType(TextFormField).at(1);
    await tester.showKeyboard(amountField);
    await tester.pump();

    // Simulate three individual keystrokes through the live IME
    // connection. With the old text-derived row keys, the first
    // keystroke's setState recreated the row subtree, dropping focus
    // (and the connection) so later keystrokes were lost.
    for (final text in ['1', '12', '123']) {
      tester.testTextInput.updateEditingValue(TextEditingValue(
        text: text,
        selection: TextSelection.collapsed(offset: text.length),
      ));
      await tester.pump();
    }

    final editable = _editableOf(tester, amountField);
    expect(editable.controller.text, '123');
    expect(editable.focusNode.hasFocus, isTrue);
  });

  testWidgets('ratio preset rewrites amounts but keeps typed descriptions',
      (tester) async {
    await tester.pumpWidget(_host(_dialog()));

    final fields = find.byType(TextFormField);
    await tester.enterText(fields.at(0), 'Veggies');
    await tester.pump();

    // Apply the 60/40 preset from the quick-split menu.
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('60 / 40'));
    await tester.pumpAndSettle();

    expect(_editableOf(tester, fields.at(1)).controller.text, '60.00');
    expect(_editableOf(tester, fields.at(3)).controller.text, '40.00');
    // The preset must update via the controllers, not by recreating
    // rows — so the description typed above survives.
    expect(_editableOf(tester, fields.at(0)).controller.text, 'Veggies');
  });

  testWidgets('presets grow and shrink the row set without errors',
      (tester) async {
    await tester.pumpWidget(_host(_dialog()));

    // 2 rows -> 3 rows.
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('40 / 30 / 30'));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNWidgets(6));

    // 3 rows -> 2 rows (exercises the deferred controller disposal).
    await tester.tap(find.byIcon(Icons.tune));
    await tester.pumpAndSettle();
    await tester.tap(find.text('50 / 50'));
    await tester.pumpAndSettle();
    expect(find.byType(TextFormField), findsNWidgets(4));

    final fields = find.byType(TextFormField);
    expect(_editableOf(tester, fields.at(1)).controller.text, '50.00');
    expect(_editableOf(tester, fields.at(3)).controller.text, '50.00');
  });
}
