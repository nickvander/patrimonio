// Layout branches must read the widget's OWN `LayoutBuilder` constraint, not
// the window (skill §4/§5). These cards all decided "phone or not" from
// `MediaQuery.sizeOf(context).width`, which is wrong in both directions: a
// card in a narrow dashboard column on a 1440px window read "desktop", and a
// wide sheet on a small window read "phone".
//
// Each group pins BOTH directions — a narrow card on a wide surface and a
// wide card on a small one — following
// `performance_card_inner_constraint_test.dart`, the precedent this sweep
// extends.
//
// The BudgetsCard group is the important one: there the branch does not just
// change padding, it changes `collapseLimit` — how many budget categories the
// user can see before the "show all" toggle. The wrong branch hides data.

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/utils/currency.dart';
import 'package:patrimonio/widgets/budgets_card.dart';
import 'package:patrimonio/widgets/cross_currency_transfers_card.dart';
import 'package:patrimonio/widgets/debt_payoff_card.dart';
import 'package:patrimonio/widgets/lending_tab.dart';
import 'package:patrimonio/widgets/spending_by_category_card.dart';

/// Hosts [child] at an explicit width, INDEPENDENT of the window: the
/// `OverflowBox` hands it a tight [width] whether that is narrower or wider
/// than the surface. Decoupling the two is the whole point — a host that
/// merely resized the window would prove nothing about the constraint.
Widget _host({required double width, required Widget child}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: width,
        maxWidth: width,
        child: SingleChildScrollView(child: child),
      ),
    ),
  ),
);

/// Same host, but the child keeps the surface's full height (for widgets that
/// own their own scrolling, like [LendingTab]).
Widget _tallHost({required double width, required Widget child}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: width,
        maxWidth: width,
        child: child,
      ),
    ),
  ),
);

void _useSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The set of `EdgeInsetsGeometry` on every `Padding` inside the first Card.
Set<EdgeInsetsGeometry> _cardPaddings(WidgetTester tester) => tester
    .widgetList<Padding>(
      find.descendant(
        of: find.byType(Card).first,
        matching: find.byType(Padding),
      ),
    )
    .map((p) => p.padding)
    .toSet();

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

/// `extends ApiService` (not an extension) so the overrides actually dispatch
/// — see the frontend skill §3 on why the domain APIs are mixins.
class _SpendApi extends ApiService {
  @override
  Future<Map<String, dynamic>> getSpendingByCategory({
    int months = 6,
    int top = 6,
    bool forceRefresh = false,
  }) async {
    const key = '2026-01';
    return {
      'months': [key, '2026-02'],
      'categories': [
        {
          'category': 'FOOD_AND_DRINK',
          'total': 400.0,
          'monthly': [
            {'month': key, 'amount': 200.0},
            {'month': '2026-02', 'amount': 200.0},
          ],
        },
      ],
    };
  }
}

class _SettingsApi extends ApiService {
  final Map<String, dynamic> store;
  _SettingsApi(this.store);

  @override
  Future<dynamic> getSetting(String key) async => store[key];

  @override
  Future<void> putSetting(String key, dynamic value) async {
    store[key] = value;
  }
}

class _LoansApi extends ApiService {
  final List<dynamic> loans;
  _LoansApi(this.loans);

  @override
  Future<List<dynamic>> getLoans() async => loans;

  @override
  Future<List<dynamic>> getLoanPeople() async => const [];

  @override
  Future<Map<String, dynamic>> getLoansSummary({
    bool forceRefresh = false,
  }) async => const {
    'active_count': 1,
    'total_lent': 1000.0,
    'total_outstanding': 800.0,
  };

  @override
  Future<Map<String, dynamic>> getInterestIncome({int? year}) async => const {
    'total_interest': 0,
    'total_principal': 0,
  };
}

void main() {
  const wideSurface = Size(1400, 2400);
  const smallSurface = Size(500, 2400);

  // -------------------------------------------------------------------------
  // BudgetsCard — the branch that HIDES DATA.
  // -------------------------------------------------------------------------
  group('BudgetsCard — row count follows the card constraint', () {
    final currencyFormat = NumberFormat.currency(symbol: r'$');
    final now = DateTime.now();

    // Eight budgeted categories, so the two collapse limits (4 narrow /
    // 6 wide) are distinguishable and neither shows all eight.
    const categories = ['Aa', 'Bb', 'Cc', 'Dd', 'Ee', 'Ff', 'Gg', 'Hh'];

    BudgetsCard card() => BudgetsCard(
      transactions: [
        for (final c in categories)
          {
            'id': 'tx-$c',
            'date': DateTime(now.year, now.month, 1).toIso8601String(),
            'amount': -10.0,
            'currency': 'USD',
            'category': 'GENERAL',
            'user_category': c,
          },
      ],
      conversionFactor: 1.0,
      usdMxnRate: 17.0,
      currencyFormat: currencyFormat,
      loadBudgetsOverride: () async => {for (final c in categories) c: 100.0},
    );

    /// How many of the eight budget rows are rendered.
    int visibleRows(WidgetTester tester) =>
        categories.where((c) => find.text(c).evaluate().isNotEmpty).length;

    testWidgets('a narrow card on a WIDE window shows only 4 rows', (
      tester,
    ) async {
      // 380px of card on a 1400px window: a dashboard column, a side sheet,
      // a split view. The MediaQuery version read 1400 here and rendered SIX
      // rows plus 24px padding into a 380px card.
      _useSurface(tester, wideSurface);
      await tester.pumpWidget(_host(width: 380, child: card()));
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byType(Card).first).width,
        moreOrLessEquals(380.0, epsilon: 1.0),
        reason: 'the host hands the card 380px regardless of the window',
      );
      expect(visibleRows(tester), 4, reason: 'narrow collapse limit');
      expect(_cardPaddings(tester), contains(const EdgeInsets.all(16.0)));
      expect(
        _cardPaddings(tester),
        isNot(contains(const EdgeInsets.all(24.0))),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a wide card on a SMALL window shows 6 rows', (tester) async {
      // The inverse: 900px of card on a 500px window. The MediaQuery version
      // read 500 and hid two categories the card had room for.
      _useSurface(tester, smallSurface);
      await tester.pumpWidget(_host(width: 900, child: card()));
      await tester.pumpAndSettle();

      expect(visibleRows(tester), 6, reason: 'wide collapse limit');
      expect(_cardPaddings(tester), contains(const EdgeInsets.all(24.0)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('the row count flips at the card breakpoint, not the window', (
      tester,
    ) async {
      // Same window either side of the change: only the card's own width
      // moves, and it alone decides how much the user sees.
      _useSurface(tester, wideSurface);

      await tester.pumpWidget(_host(width: 719, child: card()));
      await tester.pumpAndSettle();
      expect(visibleRows(tester), 4, reason: '719px card is touch-width');

      await tester.pumpWidget(_host(width: 720, child: card()));
      await tester.pumpAndSettle();
      expect(visibleRows(tester), 6, reason: '720px card is pointer-width');
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // DebtPayoffCard — simulator collapse + strategy-tile stacking.
  // -------------------------------------------------------------------------
  group('DebtPayoffCard — simulator layout follows the card constraint', () {
    Widget card() => DebtPayoffCard(
      accounts: const [
        {
          'id': 'a1',
          'name': 'Visa',
          'account_type': 'credit card',
          'current_balance': -400.0,
          'currency': 'USD',
        },
        {
          'id': 'a2',
          'name': 'Amex',
          'account_type': 'credit card',
          'current_balance': -150.0,
          'currency': 'USD',
        },
      ],
      apiService: _SettingsApi({}),
      conversionFactor: 1.0,
      usdMxnRate: 17.0,
      currencyFormat: NumberFormat.currency(symbol: r'$'),
    );

    /// The collapsed what-if simulator's tap-to-expand header — rendered only
    /// on the touch-width branch.
    final simulatorDisclosure = find.byIcon(Icons.tune_rounded);

    testWidgets('a narrow card on a WIDE window collapses the simulator', (
      tester,
    ) async {
      _useSurface(tester, wideSurface);
      // 460px: comfortably inside the touch branch, and wide enough that the
      // debt rows themselves are not what is being measured.
      await tester.pumpWidget(_host(width: 460, child: card()));
      await tester.pumpAndSettle();

      expect(simulatorDisclosure, findsOneWidget);
      expect(_cardPaddings(tester), contains(const EdgeInsets.all(16.0)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a wide card on a SMALL window keeps the simulator inline', (
      tester,
    ) async {
      _useSurface(tester, smallSurface);
      await tester.pumpWidget(_host(width: 900, child: card()));
      await tester.pumpAndSettle();

      expect(simulatorDisclosure, findsNothing);
      expect(find.byType(Slider), findsOneWidget, reason: 'simulator inline');
      expect(_cardPaddings(tester), contains(const EdgeInsets.all(24.0)));
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // SpendingByCategoryCard — plot height + padding.
  // -------------------------------------------------------------------------
  group('SpendingByCategoryCard — plot height follows the card constraint', () {
    Widget card() => SpendingByCategoryCard(
      apiService: _SpendApi(),
      conversionFactor: 1.0,
      currencyFormat: moneyFormat('USD'),
      months: 12,
    );

    double plotHeight(WidgetTester tester) =>
        tester.getSize(find.byType(BarChart)).height;

    testWidgets('a narrow card on a WIDE window takes the 200px plot', (
      tester,
    ) async {
      _useSurface(tester, wideSurface);
      await tester.pumpWidget(_host(width: 380, child: card()));
      await tester.pumpAndSettle();

      expect(plotHeight(tester), 200.0);
      expect(_cardPaddings(tester), contains(const EdgeInsets.all(16.0)));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a wide card on a SMALL window takes the 240px plot', (
      tester,
    ) async {
      _useSurface(tester, smallSurface);
      await tester.pumpWidget(_host(width: 900, child: card()));
      await tester.pumpAndSettle();

      expect(plotHeight(tester), 240.0);
      expect(_cardPaddings(tester), contains(const EdgeInsets.all(24.0)));
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // LendingTab — the "Add loan" affordance (FAB vs labelled header button).
  // -------------------------------------------------------------------------
  group('LendingTab — Add-loan affordance follows the tab constraint', () {
    Widget tab() => LendingTab(
      apiService: _LoansApi(const [
        {
          'id': 'l1',
          'borrower_name': 'Ana',
          'principal': 1000.0,
          'total_owed': 800.0,
          'outstanding': 800.0,
          'total_repaid': 200.0,
          'total_scheduled': 1000.0,
          'interest_earned': 0.0,
          'currency': 'USD',
          'status': 'active',
        },
      ]),
      targetCurrency: 'USD',
    );

    testWidgets('a narrow tab on a WIDE window moves Add-loan to the FAB', (
      tester,
    ) async {
      _useSurface(tester, wideSurface);
      await tester.pumpWidget(_tallHost(width: 500, child: tab()));
      await tester.pumpAndSettle();

      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(
        find.byType(FilledButton),
        findsNothing,
        reason: 'the labelled header button must not double the FAB',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a wide tab on a SMALL window keeps the labelled button', (
      tester,
    ) async {
      _useSurface(tester, smallSurface);
      await tester.pumpWidget(_tallHost(width: 900, child: tab()));
      await tester.pumpAndSettle();

      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byType(FilledButton), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  // -------------------------------------------------------------------------
  // Bucket C representative: plain 16/24 card padding.
  // -------------------------------------------------------------------------
  group('CrossCurrencyTransfersCard — padding follows the card constraint', () {
    Widget card() => CrossCurrencyTransfersCard(
      transfers: const [
        {
          'id': 't1',
          'from_currency': 'USD',
          'to_currency': 'MXN',
          'from_amount': 100.0,
          'to_amount': 1700.0,
          'date': '2026-01-15',
          'implied_rate': 17.0,
          'spot_rate': 17.5,
          'confirmed': true,
        },
      ],
      currencyFormat: moneyFormat('USD'),
    );

    testWidgets('narrow card on a wide window → 16px', (tester) async {
      _useSurface(tester, wideSurface);
      await tester.pumpWidget(_host(width: 380, child: card()));
      await tester.pumpAndSettle();
      expect(_cardPaddings(tester), contains(const EdgeInsets.all(16.0)));
      expect(
        _cardPaddings(tester),
        isNot(contains(const EdgeInsets.all(24.0))),
      );
    });

    testWidgets('wide card on a small window → 24px', (tester) async {
      _useSurface(tester, smallSurface);
      await tester.pumpWidget(_host(width: 900, child: card()));
      await tester.pumpAndSettle();
      expect(_cardPaddings(tester), contains(const EdgeInsets.all(24.0)));
      expect(
        _cardPaddings(tester),
        isNot(contains(const EdgeInsets.all(16.0))),
      );
    });
  });
}
