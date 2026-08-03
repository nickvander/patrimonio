import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/services/tx_page.dart';
import 'package:patrimonio/utils/currency.dart';
import 'package:patrimonio/widgets/add_loan_dialog.dart';
import 'package:patrimonio/widgets/edit_loan_dialog.dart';
import 'package:patrimonio/widgets/record_payment_sheet.dart';

/// The lending amount fields used to hardcode `MX$` while the house
/// [currencySymbol] map had already moved MXN to its ISO prefix, so a peso
/// loan's input read `MX$ ` next to `MXN 30,000.00` everywhere else. These
/// pin the rendered prefix to the HELPER's output rather than to a literal,
/// so the fields follow the map if it ever changes again.
class _FakeApi extends ApiService {
  @override
  Future<TxPage> getTransactions({
    int limit = 50,
    int offset = 0,
    String? currency,
    String? sign,
    String? query,
    bool excludeLinked = false,
  }) async => const TxPage(rows: []);
}

Widget _host(Locale locale, Widget child) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

/// Every `prefixText` currently rendered anywhere in the tree.
Set<String> _prefixes(WidgetTester tester) => tester
    .widgetList<InputDecorator>(find.byType(InputDecorator))
    .map((d) => d.decoration.prefixText)
    .whereType<String>()
    .toSet();

/// What the house helper says an amount field for [code] should be prefixed
/// with: the idiomatic glyph plus exactly one separating space.
String _expected(String code) => '${currencySymbol(code).trimRight()} ';

void main() {
  // Guards the premise: if the map ever goes back to the glyph, these tests
  // should start failing loudly rather than quietly asserting `MX$` again.
  test('house helper renders MXN with the ISO prefix, not the MX\$ glyph', () {
    expect(_expected('MXN'), 'MXN ');
    expect(_expected('USD'), r'$ ');
    expect(moneyFormat('MXN').format(30000), contains('MXN'));
    expect(moneyFormat('MXN').format(30000), isNot(contains(r'MX$')));
  });

  for (final locale in const [Locale('en'), Locale('es')]) {
    final tag = locale.languageCode;

    testWidgets('$tag: AddLoanDialog prefixes MXN amounts via the helper', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          locale,
          AddLoanDialog(
            apiService: _FakeApi(),
            people: const [],
            defaultCurrency: 'MXN',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_prefixes(tester), contains(_expected('MXN')));
      expect(_prefixes(tester), isNot(contains(r'MX$ ')));
    });

    testWidgets('$tag: AddLoanDialog prefixes USD amounts via the helper', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          locale,
          AddLoanDialog(
            apiService: _FakeApi(),
            people: const [],
            defaultCurrency: 'USD',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_prefixes(tester), contains(_expected('USD')));
    });

    testWidgets('$tag: EditLoanDialog prefixes MXN amounts via the helper', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          locale,
          EditLoanDialog(
            apiService: _FakeApi(),
            loan: const {
              'id': 'l1',
              'borrower_name': 'Jose',
              'principal': 30000,
              'currency': 'MXN',
              'interest_type': 'none',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(_prefixes(tester), contains(_expected('MXN')));
      expect(_prefixes(tester), isNot(contains(r'MX$ ')));
    });

    testWidgets('$tag: RecordPaymentSheet prefixes MXN cash via the helper', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          locale,
          RecordPaymentSheet(
            apiService: _FakeApi(),
            loanId: 'l1',
            currency: 'MXN',
            mode: RecordMode.repayment,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The cash form (the only amount field on this sheet) is behind the
      // second segment of the bank-transaction / cash switch.
      final l = await AppLocalizations.delegate.load(locale);
      await tester.tap(find.text(l.lendSegCash));
      await tester.pumpAndSettle();

      expect(_prefixes(tester), contains(_expected('MXN')));
      expect(_prefixes(tester), isNot(contains(r'MX$ ')));
    });
  }
}
