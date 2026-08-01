import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/lending_tab.dart';

/// Minimal stub for the calls LendingTab._load() makes on init.
class _FakeApiService extends ApiService {
  @override
  Future<List<dynamic>> getLoans() async => const [];
  @override
  Future<List<dynamic>> getLoanPeople() async => const [];
  @override
  Future<Map<String, dynamic>> getLoansSummary({
    bool forceRefresh = false,
  }) async => const {
    'active_count': 0,
    'total_lent': 0,
    'total_outstanding': 0,
  };
  @override
  Future<Map<String, dynamic>> getInterestIncome({int? year}) async => const {
    'total_interest': 0,
    'total_principal': 0,
  };
}

Future<void> _openDialog(WidgetTester tester) async {
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: LendingTab(apiService: _FakeApiService(), targetCurrency: 'USD'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.widgetWithText(FilledButton, 'Add loan').first);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('add-loan chooser shows 3 primary styles, hides the rest', (
    tester,
  ) async {
    await _openDialog(tester);

    // Three everyday styles up front.
    expect(find.text('No interest'), findsOneWidget);
    expect(find.text('Flat interest'), findsOneWidget);
    expect(find.text('Regular payments with a rate'), findsOneWidget);

    // Advanced styles are behind the disclosure, not shown yet.
    expect(find.text('Custom schedule'), findsNothing);
    expect(find.text('One payment at the end'), findsNothing);
    expect(find.text('More loan types'), findsOneWidget);
  });

  testWidgets('"More loan types" reveals the advanced styles', (tester) async {
    await _openDialog(tester);

    await tester.ensureVisible(find.text('More loan types'));
    await tester.tap(find.text('More loan types'));
    await tester.pumpAndSettle();

    expect(find.text('Custom schedule'), findsOneWidget);
    expect(find.text('One payment at the end'), findsOneWidget);
    expect(find.text('Interest now, full amount at the end'), findsOneWidget);
  });

  testWidgets('Flat interest offers a set-amount / rate toggle', (
    tester,
  ) async {
    await _openDialog(tester);

    await tester.ensureVisible(find.text('Flat interest'));
    await tester.tap(find.text('Flat interest'));
    await tester.pumpAndSettle();

    // The sub-toggle replaces the two rival "flat" tiles.
    expect(find.text('Set amount'), findsOneWidget);
    expect(find.text('Rate'), findsOneWidget);
    // Default sub-mode is the agreed fixed amount.
    expect(find.text('Agreed interest (total)'), findsOneWidget);
  });
}
