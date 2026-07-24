import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/widgets/lending_tab.dart';

/// Regression tests for the flat-interest add-loan form failing loudly and
/// helpfully: an invalid below-the-fold "Payment amount" must produce an
/// INLINE field error, scroll into view, toast the field's name — and must
/// NOT submit anything to the API.
///
/// Stub ApiService that records writes so the tests can assert whether a
/// submit reached the API. Read methods return the empty canned data
/// LendingTab._load() needs.
class _FakeApiService extends ApiService {
  int createLoanCalls = 0;
  int setScheduleCalls = 0;

  @override
  Future<List<dynamic>> getLoans() async => const [];

  @override
  Future<List<dynamic>> getLoanPeople() async => const [];

  @override
  Future<Map<String, dynamic>> getLoansSummary(
          {bool forceRefresh = false}) async =>
      const {'active_count': 0, 'total_lent': 0, 'total_outstanding': 0};

  @override
  Future<Map<String, dynamic>> getInterestIncome({int? year}) async =>
      const {'total_interest': 0, 'total_principal': 0};

  @override
  Future<Map<String, dynamic>> createLoan({
    required String borrowerName,
    required double principal,
    required String currency,
    required DateTime originationDate,
    double interestRate = 0,
    String interestType = 'none',
    String ratePeriod = 'annual',
    int? termMonths,
    String? paymentFrequency,
    String? notes,
    String? personId,
    DateTime? expectedRepaymentDate,
  }) async {
    createLoanCalls++;
    return {'id': 'loan-1'};
  }

  @override
  Future<void> setCustomSchedule(
      String loanId, List<Map<String, dynamic>> rows) async {
    setScheduleCalls++;
  }
}

/// Opens the add-loan dialog and switches it to the flat-interest style
/// (default sub-mode: "Set amount").
Future<void> _openFlatDialog(WidgetTester tester, _FakeApiService api,
    {Locale? locale}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: LendingTab(apiService: api, targetCurrency: 'USD'),
      ),
    ),
  );
  await tester.pumpAndSettle();
  // The tab's "Add loan" button (the only FilledButton before the dialog).
  await tester.tap(find.byType(FilledButton).first);
  await tester.pumpAndSettle();
  final flatLabel = locale?.languageCode == 'es' ? 'Interés fijo' : 'Flat interest';
  await tester.ensureVisible(find.text(flatLabel));
  await tester.tap(find.text(flatLabel));
  await tester.pumpAndSettle();
}

/// The dialog's save button — the LAST FilledButton in the tree (the tab's
/// opener button is underneath the dialog barrier).
Finder _saveButton() => find.byType(FilledButton).last;

Future<void> _fill(WidgetTester tester, String label, String value) async {
  final field = find.widgetWithText(TextFormField, label);
  expect(field, findsOneWidget, reason: 'field "$label" should exist');
  await tester.enterText(field, value);
  await tester.pump();
}

void main() {
  testWidgets(
      'flat loan: empty payment amount shows an inline error, names the '
      'field in the toast, and does not submit', (tester) async {
    final api = _FakeApiService();
    await _openFlatDialog(tester, api);

    await _fill(tester, 'Borrower name', 'Jose Ramirez');
    await _fill(tester, 'Amount lent', '10000');
    await _fill(tester, 'Agreed interest (total)', '2000');
    // "Payment amount" left empty — the below-the-fold field the generic
    // toast used to hide.

    await tester.tap(_saveButton(), warnIfMissed: false);
    await tester.pumpAndSettle();

    // Inline error on the payment field.
    expect(find.text('Enter a payment amount greater than 0'), findsOneWidget);
    // Fallback toast names the offending field.
    expect(find.text('Fix “Payment amount” to continue'), findsOneWidget);
    // Nothing was submitted.
    expect(api.createLoanCalls, 0);
    expect(api.setScheduleCalls, 0);
    // The dialog is still open (save button still present).
    expect(_saveButton(), findsOneWidget);
  });

  testWidgets('flat loan: payment too small to ever repay is flagged inline',
      (tester) async {
    final api = _FakeApiService();
    await _openFlatDialog(tester, api);

    await _fill(tester, 'Borrower name', 'Jose Ramirez');
    await _fill(tester, 'Amount lent', '10000');
    await _fill(tester, 'Agreed interest (total)', '2000');
    // 12000 / 0.01 would need 1.2M installments — over the schedule cap.
    await _fill(tester, 'Payment amount', '0.01');

    await tester.tap(_saveButton(), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.text('Too small — this payment would never pay off the loan'),
        findsOneWidget);
    expect(api.createLoanCalls, 0);
  });

  testWidgets('flat loan: fixing the payment clears the error and submits',
      (tester) async {
    final api = _FakeApiService();
    await _openFlatDialog(tester, api);

    await _fill(tester, 'Borrower name', 'Jose Ramirez');
    await _fill(tester, 'Amount lent', '10000');
    await _fill(tester, 'Agreed interest (total)', '2000');

    // First submit fails (payment empty) and turns on live validation.
    await tester.tap(_saveButton(), warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(find.text('Enter a payment amount greater than 0'), findsOneWidget);

    // Fix the payment: live re-validation clears the inline error.
    await _fill(tester, 'Payment amount', '4000');
    await tester.pumpAndSettle();
    expect(find.text('Enter a payment amount greater than 0'), findsNothing);

    await tester.tap(_saveButton(), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(api.createLoanCalls, 1);
    expect(api.setScheduleCalls, 1);
  });

  testWidgets(
      'es-MX: inline payment error and field-naming toast are localized',
      (tester) async {
    final api = _FakeApiService();
    await _openFlatDialog(tester, api, locale: const Locale('es'));

    await _fill(tester, 'Nombre del prestatario', 'Jose Ramirez');
    await _fill(tester, 'Monto prestado', '10000');
    await _fill(tester, 'Interés acordado (total)', '2000');

    await tester.tap(_saveButton(), warnIfMissed: false);
    await tester.pumpAndSettle();

    expect(find.text('Ingresa un monto de pago mayor que 0'), findsOneWidget);
    expect(
        find.text('Corrige “Monto del pago” para continuar'), findsOneWidget);
    expect(api.createLoanCalls, 0);
  });
}
