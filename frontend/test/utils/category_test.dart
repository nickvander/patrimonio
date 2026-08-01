import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/app_locale.dart';
import 'package:patrimonio/utils/category.dart';

// prettyCategory reads the active locale from the web-free localeNotifier, so
// it localizes the Plaid taxonomy without a BuildContext. These tests flip the
// notifier directly (no widget pump → no package:web dependency).
void main() {
  tearDown(() => localeNotifier.value = null);

  test('English by default', () {
    localeNotifier.value = null;
    expect(
      prettyCategory(detailed: 'FOOD_AND_DRINK_RESTAURANT'),
      'Restaurants',
    );
    expect(prettyCategory(primary: 'LOAN_PAYMENTS'), 'Loan payment');
    expect(prettyCategory(), 'Uncategorized');
  });

  test('es-MX taxonomy when locale is Spanish', () {
    localeNotifier.value = const Locale('es');
    expect(
      prettyCategory(detailed: 'FOOD_AND_DRINK_RESTAURANT'),
      'Restaurantes',
    );
    expect(prettyCategory(primary: 'LOAN_PAYMENTS'), 'Pago de préstamo');
    expect(prettyCategory(detailed: 'TRANSPORTATION_GAS'), 'Gasolina');
    expect(prettyCategory(), 'Sin categoría');
  });

  test('user-typed category is never re-translated', () {
    localeNotifier.value = const Locale('es');
    expect(
      prettyCategory(
        userCategory: 'Mi etiqueta',
        detailed: 'FOOD_AND_DRINK_RESTAURANT',
      ),
      'Mi etiqueta',
    );
  });

  test(
    'es falls back to the derived English for an uncovered long-tail code',
    () {
      localeNotifier.value = const Locale('es');
      // Not in either override map → derived sentence-case (English).
      expect(
        prettyCategory(detailed: 'SOME_RARE_UNCOVERED_CODE'),
        'Some rare uncovered code',
      );
    },
  );

  group('distinctPrettyCategories', () {
    test('dedupes, prettifies, prefers user overrides, sorts', () {
      final txs = [
        {'category_detailed': 'FOOD_AND_DRINK_RESTAURANT'},
        {'category_detailed': 'FOOD_AND_DRINK_RESTAURANT'}, // dupe
        {'user_category': 'Zapatos'},
        {'category': 'LOAN_PAYMENTS'},
        'not-a-map',
      ];
      expect(distinctPrettyCategories(txs), [
        'Loan payment',
        'Restaurants',
        'Zapatos',
      ]);
    });

    test('empty input yields no suggestions', () {
      expect(distinctPrettyCategories(const []), isEmpty);
    });
  });
}
