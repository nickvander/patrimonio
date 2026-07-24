import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/lending_tab.dart';

/// Stub ApiService returning canned data without touching the network, so
/// LendingTab can be pumped in a pure widget test. This compiles on the
/// Dart test VM only because ApiService's web-only bits (package:web,
/// BrowserClient) now sit behind the api_platform conditional-import seam.
/// Override just the methods LendingTab._load() calls.
class _FakeApiService extends ApiService {
  final List<dynamic> loans;
  _FakeApiService({this.loans = const []});

  @override
  Future<List<dynamic>> getLoans() async => loans;

  @override
  Future<List<dynamic>> getLoanPeople() async => const [];

  @override
  Future<Map<String, dynamic>> getLoansSummary({bool forceRefresh = false}) async =>
      const {
        'active_count': 0,
        'total_lent': 0,
        'total_outstanding': 0,
      };

  @override
  Future<Map<String, dynamic>> getInterestIncome({int? year}) async =>
      const {'total_interest': 0, 'total_principal': 0};
}

void main() {
  // Regression guard for the "Lending tab renders blank" bug. LendingTab
  // returns a RefreshIndicator -> ListView (it owns its own scrolling), so
  // it MUST be given a bounded height. When the dashboard wrapped it in an
  // extra SingleChildScrollView the inner ListView got unbounded height and
  // the whole tab threw a layout error -> blank in the release web build
  // (asserts stripped, so no red error box, just nothing). This mounts it
  // the way the dashboard does (bounded by the Scaffold body) and asserts
  // it lays out + shows its content without throwing.
  testWidgets('LendingTab lays out under a bounded parent (empty state)',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LendingTab(
            apiService: _FakeApiService(),
            targetCurrency: 'USD',
          ),
        ),
      ),
    );
    // First frame is the loading spinner; let _load() resolve.
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text("Money I've lent"), findsOneWidget);
    expect(find.text('No loans yet'), findsOneWidget);
  });

  testWidgets('LendingTab renders loan cards + the mixed-currency note',
      (tester) async {
    final api = _FakeApiService(loans: [
      {
        'id': '1',
        'borrower_name': 'Alice',
        'principal': 100.0,
        'outstanding': 100.0,
        // Scheduled loan: total owed includes $20 of unpaid interest, so
        // the card must disclose it under the Outstanding figure.
        'total_owed': 120.0,
        'total_repaid': 0.0,
        'interest_earned': 0.0,
        'currency': 'USD',
        'status': 'active',
        'origination_date': '2026-01-01',
      },
      {
        'id': '2',
        'borrower_name': 'Bob',
        'principal': 1800.0,
        'outstanding': 1800.0,
        'total_repaid': 0.0,
        'interest_earned': 0.0,
        'currency': 'MXN',
        'status': 'active',
        'origination_date': '2026-01-01',
      },
    ]);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: LendingTab(
            apiService: api,
            targetCurrency: 'USD',
            usdMxnRate: 18.0,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('Alice'), findsOneWidget);
    expect(find.text('Bob'), findsOneWidget);
    expect(
      find.textContaining('converted to USD'),
      findsOneWidget,
    );

    // Copy-pass regressions:
    // 1) The "Lent … · <date>" meta renders a locale-aware date, never the
    //    raw ISO payload string.
    expect(find.textContaining('2026-01-01'), findsNothing);
    expect(find.textContaining('Jan 1, 2026'), findsWidgets);
    // 2) Alice's Outstanding ($120 = $100 principal + $20 scheduled
    //    interest) discloses the interest portion; Bob (no total_owed)
    //    gets no footnote.
    expect(find.text(r'incl. $20.00 interest'), findsOneWidget);
  });
  // (The earlier "unbounded ListView throws" case was removed: the layout
  // assertion cascades into multiple exceptions that takeException() can't
  // capture as one across Flutter versions, making it flaky. The two tests
  // above — LendingTab rendering correctly under a bounded parent — are the
  // real regression guard for the blank-tab bug.)
}
