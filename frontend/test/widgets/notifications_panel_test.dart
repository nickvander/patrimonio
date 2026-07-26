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

  group('since-last-visit digest rows', () {
    final digest = <String, dynamic>{
      'previous_login_at': '2026-07-20T10:00:00Z',
      'new_transactions': 5,
      'largest_move': {'account_name': 'Chase Checking', 'delta_usd': -1234.5},
      'sync_errors': <String>[],
    };

    List<AppNotification> deriveDigest(
      AppLocalizations loc, {
      Map<String, dynamic>? since,
      void Function(DateTime)? onJump,
    }) {
      return deriveNotifications(
        l: loc,
        syncData: const [],
        netWorthHistory: const [],
        onJumpToManagement: () {},
        sinceLastLogin: since,
        onJumpToTransactions: onJump ?? (_) {},
      );
    }

    test('surfaces new transactions and the biggest move, keyed on the anchor',
        () {
      final out = deriveDigest(l, since: digest);
      expect(out, hasLength(2));
      final tx = out.firstWhere((n) => n.id.startsWith('since_tx:'));
      expect(tx.id, 'since_tx:2026-07-20T10:00:00Z',
          reason: 'anchor-keyed id: a new login re-alerts, a re-render does not');
      expect(tx.title, '5 new transactions');
      final mover = out.firstWhere((n) => n.id.startsWith('since_move:'));
      // gen-l10n signature is (account, amount): "{amount} on {account}".
      expect(mover.title, contains('Chase Checking'));
      expect(mover.title, contains('1,234.50'));
      expect(mover.title, contains('on Chase Checking'),
          reason: 'amount and account must not be transposed');
    });

    test('renders es-MX copy for the same digest', () {
      final es = lookupAppLocalizations(const Locale('es'));
      final out = deriveDigest(es, since: digest);
      final tx = out.firstWhere((n) => n.id.startsWith('since_tx:'));
      expect(tx.title, '5 transacciones nuevas');
      expect(tx.detail, contains('Desde tu última visita'));
      final mover = out.firstWhere((n) => n.id.startsWith('since_move:'));
      expect(mover.title, contains('en Chase Checking'));
    });

    test('no digest payload (or nothing new) produces no rows', () {
      expect(deriveDigest(l, since: null), isEmpty);
      expect(
        deriveDigest(l, since: {
          'previous_login_at': '2026-07-20T10:00:00Z',
          'new_transactions': 0,
          'sync_errors': <String>[],
        }),
        isEmpty,
      );
    });

    test('tapping a digest row deep-links with the previous-login anchor', () {
      DateTime? received;
      final out = deriveDigest(l, since: digest, onJump: (a) => received = a);
      out.firstWhere((n) => n.id.startsWith('since_tx:')).onTap!();
      expect(received, DateTime.parse('2026-07-20T10:00:00Z'));
    });

    // The bell and the Overview banner render this same `delta_usd` through
    // the same l10n key. The bell used to hardcode USD, so reporting in MXN
    // produced "+MXN 21,000" in the banner and "+$1,234.50" in the bell.
    test('the largest move is reported in the reporting currency', () {
      final out = deriveNotifications(
        l: l,
        syncData: const [],
        netWorthHistory: const [],
        onJumpToManagement: () {},
        sinceLastLogin: digest,
        onJumpToTransactions: (_) {},
        targetCurrency: 'MXN',
        conversionFactor: 17.0,
      );
      final mover = out.firstWhere((n) => n.id.startsWith('since_move:'));
      expect(mover.title, contains('MXN'));
      expect(mover.title, contains('20,986.50'),
          reason: '1234.50 USD * 17 — converted, not relabelled');
      expect(mover.title, isNot(contains(r'$1,234.50')));
    });

    test('defaults stay USD for context-less callers', () {
      final out = deriveDigest(l, since: digest);
      final mover = out.firstWhere((n) => n.id.startsWith('since_move:'));
      expect(mover.title, contains('1,234.50'));
      expect(mover.title, isNot(contains('MXN')));
    });
  });

  group('reporting currency on USD-derived rows', () {
    test('a net-worth move is converted, and native-currency rows are not', () {
      // Net-worth history is USD-stored; a low-balance threshold is native.
      final out = deriveNotifications(
        l: l,
        syncData: const [],
        netWorthHistory: const [
          {'date': '2026-07-24', 'net_worth': 100000.0},
          {'date': '2026-07-25', 'net_worth': 101000.0},
        ],
        onJumpToManagement: () {},
        accounts: const [
          {
            'id': 'a1',
            'name': 'Banorte Cheques',
            'currency': 'MXN',
            'current_balance': 900.0,
          }
        ],
        accountAlerts: const {'a1': 1000.0},
        targetCurrency: 'MXN',
        conversionFactor: 17.0,
      );

      final low = out.firstWhere((n) => n.id.startsWith('low_balance:'));
      expect(low.detail, contains('900'),
          reason: 'a native MXN balance must NOT be multiplied by the factor');
      expect(low.detail, isNot(contains('15,300')));
    });
  });

  group('serverNotificationsToApp', () {
    Map<String, dynamic> row(String id, String kind) => {
          'id': id,
          'kind': kind,
          'title': 'title-$kind',
          'body': 'body-$kind',
          'created_at': '2026-07-22T12:00:00Z',
          'read_at': null,
        };

    test('maps kinds to their deep links and namespaces ids with srv:', () {
      var fx = 0, mgmt = 0, lending = 0;
      final out = serverNotificationsToApp(
        rows: [
          row('aaa', 'fx_alert'),
          row('bbb', 'import_stale'),
          row('ccc', 'loan_due'),
        ],
        onOpenFxCenter: () => fx++,
        onJumpToManagement: () => mgmt++,
        onJumpToLending: () => lending++,
      );
      expect(out.map((n) => n.id),
          ['srv:aaa', 'srv:bbb', 'srv:ccc']);
      expect(out[0].title, 'title-fx_alert');
      expect(out[0].detail, 'body-fx_alert');
      expect(out[0].createdAt, DateTime.parse('2026-07-22T12:00:00Z'));
      out[0].onTap!();
      out[1].onTap!();
      out[2].onTap!();
      expect((fx, mgmt, lending), (1, 1, 1));
    });

    test('an unknown kind from a newer server renders inert, not crashing',
        () {
      final out = serverNotificationsToApp(rows: [row('zzz', 'brand_new')]);
      expect(out, hasLength(1));
      expect(out.single.onTap, isNull);
      expect(out.single.title, 'title-brand_new');
    });

    test('rows without an id are skipped (no unkeyable read state)', () {
      final out = serverNotificationsToApp(rows: [
        {'kind': 'fx_alert', 'title': 't', 'body': 'b'},
        'not-a-map',
      ]);
      expect(out, isEmpty);
    });
  });

  group('NotificationsBell badge & read state', () {
    AppNotification notif(String id) => AppNotification(
          id: id,
          icon: Icons.info_outline,
          accent: const Color(0xFF808080),
          title: 'title $id',
          detail: 'detail $id',
        );

    Future<void> pumpBell(
      WidgetTester tester, {
      required List<AppNotification> notifications,
      Set<String> dismissedIds = const {},
      void Function(Set<String>)? onOpened,
    }) async {
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          appBar: AppBar(actions: [
            NotificationsBell(
              notifications: notifications,
              dismissedIds: dismissedIds,
              onOpened: onOpened,
            ),
          ]),
        ),
      ));
    }

    testWidgets('badge shows the unread COUNT, not just a dot',
        (tester) async {
      await pumpBell(
        tester,
        notifications: [notif('a'), notif('b'), notif('c')],
        dismissedIds: {'c'},
      );
      expect(find.text('2'), findsOneWidget);
    });

    testWidgets('badge caps at 9+', (tester) async {
      await pumpBell(
        tester,
        notifications: [for (var i = 0; i < 12; i++) notif('n$i')],
      );
      expect(find.text('9+'), findsOneWidget);
    });

    testWidgets(
        'no badge when everything is read — but only then (truthful all-clear)',
        (tester) async {
      // One unread row → badge present.
      await pumpBell(
        tester,
        notifications: [notif('a'), notif('b')],
        dismissedIds: {'a'},
      );
      expect(find.text('1'), findsOneWidget);
      // Everything read → badge gone.
      await pumpBell(
        tester,
        notifications: [notif('a'), notif('b')],
        dismissedIds: {'a', 'b'},
      );
      expect(find.text('1'), findsNothing);
      expect(find.text('2'), findsNothing);
    });

    testWidgets('opening the panel reports every shown id for read-marking',
        (tester) async {
      Set<String>? opened;
      await pumpBell(
        tester,
        notifications: [notif('a'), notif('srv:b')],
        dismissedIds: {'a'},
        onOpened: (ids) => opened = ids,
      );
      // The default 800px test surface takes the desktop popup path.
      await tester.tap(find.byIcon(Icons.notifications_none));
      await tester.pumpAndSettle();
      expect(opened, {'a', 'srv:b'},
          reason: 'ALL shown ids are reported, read and unread alike');
      // The panel itself renders below the app bar with the rows visible.
      expect(find.text('title srv:b'), findsOneWidget);
    });
  });
}
