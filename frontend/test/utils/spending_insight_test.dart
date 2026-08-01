import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/spending_insight.dart';

Map<String, dynamic> tx({
  String date = '2026-03-10',
  double amount = -25.0,
  String currency = 'USD',
  String? category = 'FOOD_AND_DRINK',
  String? categoryDetailed = 'FOOD_AND_DRINK_GROCERIES',
  String? userCategory,
  String? merchantName,
  String description = 'SOME DEBIT',
  bool pending = false,
}) => {
  'id': 'x',
  'date': date,
  'amount': amount,
  'currency': currency,
  'category': ?category,
  'category_detailed': ?categoryDetailed,
  'user_category': ?userCategory,
  'merchant_name': ?merchantName,
  'description': description,
  'pending': pending,
};

void main() {
  group('SpendingSpikeInsight.pctIncrease', () {
    test('normal case: percentage number over the previous average', () {
      const insight = SpendingSpikeInsight(
        categoryLabel: 'Groceries',
        recentMonth: '2026-03',
        recentUsd: 612.0,
        previousAvgUsd: 408.0,
        trailingAvgUsd: 442.0,
        lookbackMonths: 6,
      );
      expect(insight.pctIncrease, closeTo(50.0, 0.0001));
    });

    test('zero/negative baseline guards to 0 instead of dividing by zero', () {
      const zero = SpendingSpikeInsight(
        categoryLabel: 'Groceries',
        recentMonth: '2026-03',
        recentUsd: 100.0,
        previousAvgUsd: 0.0,
        trailingAvgUsd: 50.0,
        lookbackMonths: 3,
      );
      expect(zero.pctIncrease, 0);
    });
  });

  group('isBudgetableSpend', () {
    test('a plain settled outflow counts', () {
      expect(isBudgetableSpend(tx()), isTrue);
    });

    test('pending rows are excluded', () {
      expect(isBudgetableSpend(tx(pending: true)), isFalse);
    });

    test('inflows (positive amounts) are excluded', () {
      expect(isBudgetableSpend(tx(amount: 25.0)), isFalse);
    });

    test('transfer / investment effective categories are excluded', () {
      for (final cat in [
        'TRANSFER_IN',
        'TRANSFER_OUT',
        'TRANSFER',
        'INVESTMENT',
      ]) {
        expect(
          isBudgetableSpend(tx(category: cat, categoryDetailed: null)),
          isFalse,
          reason: cat,
        );
      }
    });

    test('a user_category override to TRANSFER wins over the raw category', () {
      // Plaid said groceries, the user recategorised as a transfer — the
      // override is honored (mirrors the backend + budgets card).
      expect(isBudgetableSpend(tx(userCategory: 'Transfer')), isFalse);
    });

    test('credit-card payments are excluded by detailed category', () {
      expect(
        isBudgetableSpend(
          tx(
            category: 'LOAN_PAYMENTS',
            categoryDetailed: 'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT',
          ),
        ),
        isFalse,
      );
    });
  });

  group('monthlyCategorySpendUsd', () {
    test(
      'returns exactly N contiguous buckets ending at endMonth, zero-filled',
      () {
        // Spend only in Jan and Mar; Feb (and Oct–Dec) must still appear
        // as explicit zero buckets so index-x bars hide no gaps.
        final out = monthlyCategorySpendUsd(
          [
            tx(date: '2026-01-05', amount: -100.0),
            tx(date: '2026-03-10', amount: -40.0),
            tx(date: '2026-03-20', amount: -60.0),
          ],
          categoryLabel: 'Groceries',
          usdMxnRate: 17.0,
          endMonth: DateTime(2026, 3, 15), // day is ignored
          months: 6,
        );
        expect(out, hasLength(6));
        expect(out.first.monthStart, DateTime(2025, 10, 1));
        expect(out.last.monthStart, DateTime(2026, 3, 1));
        // Contiguity: each bucket is exactly one month after the previous.
        for (var i = 1; i < out.length; i++) {
          expect(
            out[i].monthStart,
            DateTime(
              out[i - 1].monthStart.year,
              out[i - 1].monthStart.month + 1,
            ),
          );
        }
        expect(out.map((b) => b.totalUsd), [0.0, 0.0, 0.0, 100.0, 0.0, 100.0]);
      },
    );

    test('excludes non-budgetable rows and out-of-window / other-category '
        'rows', () {
      final out = monthlyCategorySpendUsd(
        [
          tx(date: '2026-03-10', amount: -50.0), // counts
          tx(date: '2026-03-11', amount: -10.0, pending: true), // pending
          tx(date: '2026-03-12', amount: 25.0), // inflow
          tx(date: '2026-03-13', amount: -30.0, userCategory: 'Transfer'),
          tx(
            date: '2026-03-14',
            amount: -80.0,
            category: 'LOAN_PAYMENTS',
            categoryDetailed: 'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT',
          ),
          // Different category — not Groceries.
          tx(
            date: '2026-03-15',
            amount: -70.0,
            category: 'TRANSPORTATION',
            categoryDetailed: 'TRANSPORTATION_GAS',
          ),
          // Before the 6-month window.
          tx(date: '2025-08-01', amount: -500.0),
        ],
        categoryLabel: 'Groceries',
        usdMxnRate: 17.0,
        endMonth: DateTime(2026, 3),
        months: 6,
      );
      expect(out.last.totalUsd, 50.0);
      expect(out.fold(0.0, (s, b) => s + b.totalUsd), 50.0);
    });

    test('converts an MXN row to USD before summing (cross-currency '
        'regression)', () {
      final out = monthlyCategorySpendUsd(
        [
          tx(date: '2026-03-10', amount: -170.0, currency: 'MXN'),
          tx(date: '2026-03-11', amount: -5.0),
        ],
        categoryLabel: 'Groceries',
        usdMxnRate: 17.0,
        endMonth: DateTime(2026, 3),
        months: 3,
      );
      // 170 MXN / 17 = 10 USD, plus 5 USD — never 175.
      expect(out.last.totalUsd, closeTo(15.0, 0.0001));
    });
  });

  group('topMerchantsForCategoryMonth', () {
    test('ranks by USD total desc, respects limit, counts per merchant', () {
      final out = topMerchantsForCategoryMonth(
        [
          tx(date: '2026-03-01', amount: -10.0, merchantName: 'Soriana'),
          tx(date: '2026-03-05', amount: -20.0, merchantName: 'Soriana'),
          tx(date: '2026-03-06', amount: -25.0, merchantName: 'Costco'),
          tx(date: '2026-03-07', amount: -1.0, merchantName: 'Oxxo'),
          tx(date: '2026-03-08', amount: -2.0, merchantName: 'HEB'),
          tx(date: '2026-03-09', amount: -3.0, merchantName: 'Walmart'),
          tx(date: '2026-03-10', amount: -4.0, merchantName: 'Chedraui'),
          // Out of month — ignored.
          tx(date: '2026-02-10', amount: -900.0, merchantName: 'Soriana'),
        ],
        categoryLabel: 'Groceries',
        month: '2026-03',
        usdMxnRate: 17.0,
      );
      expect(out, hasLength(5)); // limit
      expect(out.first.merchant, 'Soriana');
      expect(out.first.totalUsd, 30.0);
      expect(out.first.count, 2);
      expect(out[1].merchant, 'Costco');
      // The two smallest (Oxxo $1, HEB $2) fell off the top-5.
      expect(out.map((m) => m.merchant), isNot(contains('Oxxo')));
    });

    test('falls back to the description when merchant_name is absent', () {
      final out = topMerchantsForCategoryMonth(
        [tx(date: '2026-03-01', amount: -12.0, description: 'MISC DEBIT')],
        categoryLabel: 'Groceries',
        month: '2026-03',
        usdMxnRate: 17.0,
      );
      expect(out.single.merchant, 'MISC DEBIT');
    });

    test('converts MXN per-row before ranking', () {
      final out = topMerchantsForCategoryMonth(
        [
          tx(
            date: '2026-03-01',
            amount: -170.0,
            currency: 'MXN',
            merchantName: 'Soriana',
          ),
          tx(date: '2026-03-02', amount: -11.0, merchantName: 'Costco'),
        ],
        categoryLabel: 'Groceries',
        month: '2026-03',
        usdMxnRate: 17.0,
      );
      // 170 MXN = 10 USD < 11 USD — Costco leads despite the bigger
      // native number.
      expect(out.first.merchant, 'Costco');
      expect(out[1].totalUsd, closeTo(10.0, 0.0001));
    });

    test('a malformed month returns empty (older-server degrade)', () {
      expect(
        topMerchantsForCategoryMonth(
          [tx()],
          categoryLabel: 'Groceries',
          month: '',
          usdMxnRate: 17.0,
        ),
        isEmpty,
      );
    });
  });
}
