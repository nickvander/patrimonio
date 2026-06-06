import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/widgets/notifications_panel.dart';

void main() {
  final l = lookupAppLocalizations(const Locale('en'));

  // Minimal call wrapper — only the fields under test vary per case.
  List<AppNotification> derive({
    Map<String, dynamic>? spendingInsights,
    List<dynamic> subscriptions = const [],
  }) {
    return deriveNotifications(
      l: l,
      syncData: const [],
      netWorthHistory: const [],
      onJumpToManagement: () {},
      spendingInsights: spendingInsights,
      subscriptions: subscriptions,
      onJumpToSpending: () {},
    );
  }

  group('spending-insight notifications', () {
    test('surfaces a category spike above the trailing average', () {
      final out = derive(spendingInsights: {
        'recent_month': '2026-05',
        'lookback': 3,
        'categories': [
          {
            'category_detailed': 'FOOD_AND_DRINK_GROCERIES',
            'category': 'FOOD_AND_DRINK',
            'recent': 400.0,
            'previous_avg': 200.0,
            'trailing_avg': 250.0,
          },
        ],
      });
      expect(out, hasLength(1));
      // FOOD_AND_DRINK_GROCERIES prettifies to "Groceries"; +100%.
      expect(out.single.title, contains('Groceries'));
      expect(out.single.title, contains('100%'));
      expect(out.single.detail, contains('3-month'));
    });

    test('ignores small-baseline and below-threshold categories', () {
      final out = derive(spendingInsights: {
        'lookback': 3,
        'categories': [
          // Baseline below \$50 — a 200% jump on coffee is noise.
          {
            'category_detailed': 'FOOD_AND_DRINK_COFFEE',
            'recent': 30.0,
            'previous_avg': 10.0,
            'trailing_avg': 15.0,
          },
          // Real baseline but only a 10% jump — under the 25% bar.
          {
            'category': 'GENERAL_MERCHANDISE',
            'recent': 110.0,
            'previous_avg': 100.0,
            'trailing_avg': 105.0,
          },
          // Uninformative bucket — never nagged about.
          {
            'category': 'UNCATEGORIZED',
            'recent': 900.0,
            'previous_avg': 100.0,
            'trailing_avg': 300.0,
          },
        ],
      });
      expect(out, isEmpty);
    });

    test('caps the number of spike rows at three', () {
      final cats = List.generate(
        6,
        (i) => {
          'category': 'CAT_$i',
          'recent': 1000.0,
          'previous_avg': 100.0,
          'trailing_avg': 300.0,
        },
      );
      final out = derive(spendingInsights: {'lookback': 3, 'categories': cats});
      expect(out, hasLength(3));
    });
  });

  group('subscription price-increase notifications', () {
    Map<String, dynamic> sub({
      required String merchant,
      required double amount,
      required String date,
      required String status,
      String currency = 'USD',
    }) =>
        {
          'merchant': merchant,
          'last_amount': amount,
          'last_charge_date': date,
          'status': status,
          'currency': currency,
        };

    test('flags an active cluster that supersedes a cheaper older one', () {
      final out = derive(subscriptions: [
        sub(merchant: 'Netflix', amount: 12.99, date: '2026-05-10', status: 'active'),
        sub(merchant: 'Netflix', amount: 9.99, date: '2026-02-10', status: 'cancelled'),
      ]);
      expect(out, hasLength(1));
      expect(out.single.title, contains('Netflix'));
      expect(out.single.detail, contains('12.99'));
      expect(out.single.detail, contains('9.99'));
    });

    test('does not flag a single-cluster subscription', () {
      final out = derive(subscriptions: [
        sub(merchant: 'Spotify', amount: 9.99, date: '2026-05-01', status: 'active'),
      ]);
      expect(out, isEmpty);
    });

    test('ignores a sub-threshold price change', () {
      // \$10.00 -> \$10.50 is only 5% — under the 8% bar.
      final out = derive(subscriptions: [
        sub(merchant: 'Gym', amount: 10.50, date: '2026-05-10', status: 'active'),
        sub(merchant: 'Gym', amount: 10.00, date: '2026-02-10', status: 'cancelled'),
      ]);
      expect(out, isEmpty);
    });

    test('does not flag a price decrease', () {
      final out = derive(subscriptions: [
        sub(merchant: 'News', amount: 5.00, date: '2026-05-10', status: 'active'),
        sub(merchant: 'News', amount: 9.00, date: '2026-02-10', status: 'cancelled'),
      ]);
      expect(out, isEmpty);
    });
  });
}
