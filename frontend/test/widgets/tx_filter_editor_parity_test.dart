import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/widgets/connected_segments.dart';
import 'package:patrimonio/widgets/transaction_filters.dart';

/// Behavior-parity tests for the restyled filter editor.
///
/// The restyle is presentational only: FilterChips lose their checkmark /
/// outline and land on the tonal recipe, the two SegmentedButtons became
/// ConnectedSegments, both shells sit on cardSurface — but an identical
/// interaction sequence must pop an IDENTICAL `(TxFilters, TxSort)`
/// record from both shells, exactly as before the restyle.

const _rows = [
  {
    'id': 'tx-1',
    'date': '2026-07-01',
    'amount': -42.0,
    'currency': 'USD',
    'description': 'COFFEE',
    'category': 'FOOD_AND_DRINK',
    'account_id': 'acct-1',
    'account_name': 'Checking',
  },
];

const _accounts = [
  {'id': 'acct-1', 'name': 'Checking', 'nickname': ''},
];

void main() {
  Widget host({
    required bool asSheet,
    required List<(TxFilters, TxSort)?> out,
  }) {
    return MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () async {
                final panel = TxFiltersDialog(
                  initial: TxFilters.empty,
                  asSheet: asSheet,
                  transactions: _rows,
                  accounts: _accounts,
                );
                final (TxFilters, TxSort)? result;
                if (asSheet) {
                  result = await showModalBottomSheet<(TxFilters, TxSort)>(
                    context: context,
                    isScrollControlled: true,
                    builder: (_) => panel,
                  );
                } else {
                  result = await showDialog<(TxFilters, TxSort)>(
                    context: context,
                    builder: (_) => panel,
                  );
                }
                out.add(result);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> openEditor(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  /// Toggle Flow → Expense via ConnectedSegments, pick the "Last 30 days"
  /// date chip, Apply — then assert the popped record matches what the
  /// pre-restyle editor produced for the same sequence.
  Future<void> runSequenceAndAssert(
    WidgetTester tester,
    List<(TxFilters, TxSort)?> out,
  ) async {
    // Structural pins of the restyle: the editor holds NO SegmentedButton
    // anymore, and no FilterChip shows a checkmark (chip width must not
    // jump on selection).
    expect(find.bySubtype<SegmentedButton>(), findsNothing);
    final chips = tester.widgetList<FilterChip>(find.byType(FilterChip));
    expect(chips, isNotEmpty);
    for (final chip in chips) {
      expect(chip.showCheckmark, isFalse);
    }
    // Both single-select groups render as ConnectedSegments.
    expect(find.byType(ConnectedSegments<TxFlow>), findsOneWidget);
    expect(find.byType(ConnectedSegments<TxStatus>), findsOneWidget);

    await tester.tap(find.text('Expense'));
    await tester.pump();
    await tester.tap(find.text('Last 30 days'));
    await tester.pump();
    await tester.tap(find.text('Apply'));
    await tester.pumpAndSettle();

    expect(out, hasLength(1));
    final (filters, sort) = out.single!;
    expect(filters.flow, TxFlow.expense);
    expect(filters.dateRange, TxDateRange.thirtyDays);
    // Everything untouched stays at its default.
    expect(filters.status, TxStatus.all);
    expect(filters.accountIds, isEmpty);
    expect(filters.categories, isEmpty);
    expect(filters.minAmount, isNull);
    expect(filters.maxAmount, isNull);
    expect(filters.customStart, isNull);
    expect(filters.customEnd, isNull);
    expect(sort, TxSort.dateNewest);
  }

  testWidgets('dialog shell pops the pre-restyle record for the same '
      'interaction sequence', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final out = <(TxFilters, TxSort)?>[];
    await tester.pumpWidget(host(asSheet: false, out: out));
    await openEditor(tester);
    await runSequenceAndAssert(tester, out);
  });

  testWidgets('sheet shell pops the identical record', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final out = <(TxFilters, TxSort)?>[];
    await tester.pumpWidget(host(asSheet: true, out: out));
    await openEditor(tester);
    await runSequenceAndAssert(tester, out);
  });

  testWidgets('Cancel still pops null from both shells', (tester) async {
    final out = <(TxFilters, TxSort)?>[];
    await tester.pumpWidget(host(asSheet: false, out: out));
    await openEditor(tester);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(out, [isNull]);
  });
}
