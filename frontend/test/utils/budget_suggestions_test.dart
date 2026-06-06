import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/app_locale.dart';
import 'package:patrimonio/utils/budget_suggestions.dart';

// suggestBudgetsFromInsights labels via prettyCategory, which reads the
// web-free localeNotifier — so we pin English and never pump a widget.
void main() {
  setUp(() => localeNotifier.value = null);
  tearDown(() => localeNotifier.value = null);

  List<Map<String, dynamic>> cats(List<Map<String, dynamic>> c) => c;

  double amountFor(List<BudgetSuggestion> out, String label) =>
      out.firstWhere((s) => s.label == label).amount;

  test('seeds unbudgeted categories, rounded up to the next \$10', () {
    final out = suggestBudgetsFromInsights(
      categories: cats([
        {'category_detailed': 'FOOD_AND_DRINK_GROCERIES', 'trailing_avg': 291.0},
        {'category': 'RENT_AND_UTILITIES', 'trailing_avg': 1500.0},
      ]),
      existing: const {},
    );
    expect(amountFor(out, 'Groceries'), 300.0); // 291 → next $10
    expect(amountFor(out, 'Rent & utilities'), 1500.0); // already a multiple of 10
  });

  test('ranks suggestions by trailing spend, highest first', () {
    final out = suggestBudgetsFromInsights(
      categories: cats([
        {'category_detailed': 'FOOD_AND_DRINK_GROCERIES', 'trailing_avg': 291.0},
        {'category': 'RENT_AND_UTILITIES', 'trailing_avg': 1500.0},
      ]),
      existing: const {},
    );
    expect(out.first.label, 'Rent & utilities');
    expect(out.last.label, 'Groceries');
  });

  test('never overwrites an existing budget', () {
    final out = suggestBudgetsFromInsights(
      categories: cats([
        {'category_detailed': 'FOOD_AND_DRINK_GROCERIES', 'trailing_avg': 400.0},
      ]),
      existing: const {'Groceries': 250.0},
    );
    expect(out.any((s) => s.label == 'Groceries'), isFalse);
  });

  test('aggregates groups that prettify to the same label', () {
    // A user override + the Plaid code both labelled "Groceries".
    final out = suggestBudgetsFromInsights(
      categories: cats([
        {'category_detailed': 'FOOD_AND_DRINK_GROCERIES', 'trailing_avg': 100.0},
        {'user_category': 'Groceries', 'trailing_avg': 55.0},
      ]),
      existing: const {},
    );
    expect(out, hasLength(1));
    expect(amountFor(out, 'Groceries'), 160.0); // (100 + 55) = 155 → next $10
  });

  test('skips tiny spend and uninformative buckets', () {
    final out = suggestBudgetsFromInsights(
      categories: cats([
        {'category_detailed': 'FOOD_AND_DRINK_COFFEE', 'trailing_avg': 4.0}, // < $10
        {'category': 'UNCATEGORIZED', 'trailing_avg': 900.0},
        {'category': 'OTHER', 'trailing_avg': 900.0},
      ]),
      existing: const {},
    );
    expect(out, isEmpty);
  });

  test('respects the active locale for labels', () {
    localeNotifier.value = const Locale('es');
    final out = suggestBudgetsFromInsights(
      categories: cats([
        {'category_detailed': 'FOOD_AND_DRINK_GROCERIES', 'trailing_avg': 200.0},
      ]),
      existing: const {},
    );
    expect(amountFor(out, 'Supermercado'), 200.0);
  });
}
