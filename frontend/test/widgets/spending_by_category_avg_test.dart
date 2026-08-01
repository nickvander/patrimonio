import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/utils/currency.dart';
import 'package:patrimonio/utils/spending_window.dart';
import 'package:patrimonio/widgets/spending_by_category_card.dart';

/// Regression: "Average per month" must divide by the REQUESTED window
/// length, not by the number of months that happened to have spending.
///
/// The backend's `months` list only carries populated buckets, so a category
/// with a single $4.50 purchase inside a 12-month window used to divide by
/// ~1 month and render ~$6/mo instead of ~$0.39/mo.

class _SparseSpendApi extends ApiService {
  /// The window length the card actually requested — asserted below.
  int? requestedMonths;

  @override
  Future<Map<String, dynamic>> getSpendingByCategory({
    int months = 6,
    int top = 6,
    bool forceRefresh = false,
  }) async {
    requestedMonths = months;
    // What the backend returns for a category with spending in only ONE of
    // the window's months: the `months` list carries just that one bucket.
    final key =
        '${DateTime.now().year}-${DateTime.now().month.toString().padLeft(2, '0')}';
    return {
      'months': [key],
      'categories': [
        {
          'category': 'FOOD_AND_DRINK',
          'total': 4.50,
          'monthly': [
            {'month': key, 'amount': 4.50},
          ],
        },
      ],
    };
  }
}

Widget _host(Widget child) {
  return MaterialApp(
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(body: SingleChildScrollView(child: child)),
  );
}

void main() {
  testWidgets(
    'sparse category averages over the requested window, not months-with-spend',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      final api = _SparseSpendApi();
      final format = moneyFormat('USD');
      await tester.pumpWidget(
        _host(
          SpendingByCategoryCard(
            apiService: api,
            conversionFactor: 1.0,
            currencyFormat: format,
            months: 12, // externally driven 12-month window
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(api.requestedMonths, 12);

      // Expected: total / (11 full months + elapsed fraction of the current
      // month) — computed with the same clock the widget uses. ~$0.39/mo.
      final expected = format.displayMoney(
        4.50 / spendingWindowDivisor(12, DateTime.now()),
      );
      // The pre-fix value divided by the single month that had spending
      // (its elapsed fraction): ~$6/mo.
      final buggy = format.displayMoney(
        4.50 / spendingWindowDivisor(1, DateTime.now()),
      );

      expect(find.text(expected), findsOneWidget);
      expect(find.text(buggy), findsNothing);
    },
  );
}
