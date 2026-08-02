import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/utils/drill_down_claim.dart';
import 'package:patrimonio/utils/spending_insight.dart';
import 'package:patrimonio/widgets/transactions_tab.dart';

/// Journey fresh-context regressions (the stacking audit): a programmatic
/// jump REPLACES drill-down context — filters + search reset before the
/// jump's own payload applies — while manual edits after landing keep
/// composing. Driven through a dashboard-like harness that mirrors the
/// `_jumpToTransactions` companion contract exactly: every jump assigns
/// ALL payload fields (unnamed ⇒ null, including the claim banner) in one
/// setState, and the consumed callbacks null the host copies.

/// Mixed-journey fixture: a FasTrak subscription charge, a July
/// Food & drink row, an out-of-window June row, and a Cards row whose
/// `created_at` is after the since-visit anchor.
List<Map<String, dynamic>> _fixture() => [
  {
    'id': 'cards-new',
    'date': '2026-07-28',
    'amount': -25.0,
    'currency': 'USD',
    'description': 'TX cards-new',
    'user_description': 'Row cards-new',
    'category': 'GENERAL_MERCHANDISE',
    'account_id': 'acc-cards',
    'account_name': 'Cards',
    'created_at': '2026-08-01T12:00:00Z',
  },
  {
    'id': 'food-jul',
    'date': '2026-07-10',
    'amount': -30.0,
    'currency': 'USD',
    'description': 'CAFE TOSCANO',
    'user_description': 'Row food-jul',
    'category': 'FOOD_AND_DRINK',
    'account_id': 'acc-chk',
    'account_name': 'Checking',
    'created_at': '2026-07-11T12:00:00Z',
  },
  {
    'id': 'fastrak-1',
    'date': '2026-07-05',
    'amount': -13.0,
    'currency': 'USD',
    'description': 'FASTRAK CSC',
    'user_description': 'Row fastrak-1',
    'category': 'TRANSPORTATION',
    'account_id': 'acc-chk',
    'account_name': 'Checking',
    'created_at': '2026-07-06T12:00:00Z',
  },
  {
    'id': 'food-jun',
    'date': '2026-06-15',
    'amount': -20.0,
    'currency': 'USD',
    'description': 'CONTRAMAR',
    'user_description': 'Row food-jun',
    'category': 'FOOD_AND_DRINK',
    'account_id': 'acc-chk',
    'account_name': 'Checking',
    'created_at': '2026-06-16T12:00:00Z',
  },
];

const _accounts = [
  {'id': 'acc-cards', 'name': 'Cards'},
  {'id': 'acc-chk', 'name': 'Checking'},
];

/// The user-repro anchor: 7:59pm Jul 31 CST == 1:59am Aug 1 UTC.
final DateTime _anchor = DateTime.utc(2026, 8, 1, 1, 59);

({DateTime start, DateTime end}) _july() =>
    (start: DateTime(2026, 7, 1), end: DateTime(2026, 7, 31));

const _spike = SpendingSpikeInsight(
  categoryLabel: 'Food & drink',
  recentMonth: '2026-07',
  recentUsd: 420.0,
  previousAvgUsd: 100.0,
  trailingAvgUsd: 180.0,
  lookbackMonths: 3,
);

/// Dashboard-like host: owns the seed/override/claim copies and applies
/// jumps the way `_jumpToTransactions` does — all fields, one setState.
class _JumpHost extends StatefulWidget {
  const _JumpHost({super.key});

  @override
  State<_JumpHost> createState() => _JumpHostState();
}

class _JumpHostState extends State<_JumpHost> {
  String? searchOverride;
  ({DateTime start, DateTime end})? dateSeed;
  String? categorySeed;
  String? accountIdSeed;
  DateTime? createdSinceSeed;
  DrillDownClaim? claimBanner;
  int searchConsumed = 0;
  int dateConsumed = 0;
  int catConsumed = 0;
  int accountConsumed = 0;
  int createdConsumed = 0;

  /// Mirrors `_jumpToTransactions`: assigns EVERY field on every call so
  /// no journey inherits a stale dimension (or a stale claim banner).
  void jump({
    String? search,
    ({DateTime start, DateTime end})? window,
    String? category,
    String? accountId,
    DateTime? createdSince,
    DrillDownClaim? claim,
  }) {
    setState(() {
      searchOverride = search;
      dateSeed = window;
      categorySeed = category;
      accountIdSeed = accountId;
      createdSinceSeed = createdSince;
      claimBanner = claim;
    });
  }

  @override
  Widget build(BuildContext context) {
    return TransactionsTab(
      transactions: _fixture(),
      accounts: _accounts,
      conversionFactor: 1.0,
      currencyFormat: NumberFormat.currency(symbol: r'$'),
      targetCurrency: 'USD',
      usdMxnRate: 0,
      searchOverride: searchOverride,
      onSearchOverrideConsumed: () => setState(() {
        searchConsumed++;
        searchOverride = null;
      }),
      dateSeed: dateSeed,
      onDateSeedConsumed: () => setState(() {
        dateConsumed++;
        dateSeed = null;
      }),
      categorySeed: categorySeed,
      onCategorySeedConsumed: () => setState(() {
        catConsumed++;
        categorySeed = null;
      }),
      accountIdSeed: accountIdSeed,
      onAccountSeedConsumed: () => setState(() {
        accountConsumed++;
        accountIdSeed = null;
      }),
      createdSinceSeed: createdSinceSeed,
      onCreatedSinceSeedConsumed: () => setState(() {
        createdConsumed++;
        createdSinceSeed = null;
      }),
      claimBanner: claimBanner,
      onClaimBannerDismissed: () => setState(() => claimBanner = null),
    );
  }
}

final GlobalKey<_JumpHostState> _hostKey = GlobalKey<_JumpHostState>();

Widget _app() => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: SingleChildScrollView(
      primary: false,
      child: _JumpHost(key: _hostKey),
    ),
  ),
);

void _setViewSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// The (single) search TextField in the tab toolbar.
Finder _searchField() => find.byType(TextField).first;

String _searchText(WidgetTester tester) =>
    tester.widget<TextField>(_searchField()).controller!.text;

Future<void> _pumpHost(WidgetTester tester) async {
  _setViewSize(tester, const Size(1200, 900));
  await tester.pumpWidget(_app());
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('user repro (FasTrak pair): largest-move seeds (account + since) '
      'consumed, then a merchant search jump lands on a FRESH context — '
      'chips gone, search seeded, matching rows visible (not the zero state)', (
    tester,
  ) async {
    await _pumpHost(tester);
    final host = _hostKey.currentState!;

    // Journey 1: bell largest-move fallback (account + createdSince).
    host.jump(accountId: 'acc-cards', createdSince: _anchor);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'Cards'), findsOneWidget);
    final sinceLabel =
        'New since ${DateFormat.MMMd().format(_anchor.toLocal())}';
    expect(find.widgetWithText(InputChip, sinceLabel), findsOneWidget);
    expect(find.text('Row cards-new'), findsOneWidget);
    expect((host.accountConsumed, host.createdConsumed), (1, 1));

    // Journey 2: SubscriptionsCard "FasTrak" tap (search-only jump).
    host.jump(search: 'FasTrak');
    await tester.pumpAndSettle();

    // Fresh chips only: both prior chips are gone, search is seeded,
    // and the matching row is VISIBLE — the old behavior intersected
    // search ∧ account ∧ createdSince into "0 matching".
    expect(find.byType(InputChip), findsNothing);
    expect(_searchText(tester), 'FasTrak');
    expect(find.text('Row fastrak-1'), findsOneWidget);
    expect(find.text('No transactions match'), findsNothing);
    expect(host.searchConsumed, 1);
  });

  testWidgets(
    'spike after merchant: search box cleared, category+date chips and the '
    'spike claim banner all present',
    (tester) async {
      await _pumpHost(tester);
      final host = _hostKey.currentState!;

      host.jump(search: 'FasTrak');
      await tester.pumpAndSettle();
      expect(_searchText(tester), 'FasTrak');

      host.jump(
        category: 'Food & drink',
        window: _july(),
        claim: const SpikeClaim(_spike),
      );
      await tester.pumpAndSettle();

      expect(_searchText(tester), isEmpty);
      expect(find.widgetWithText(InputChip, 'Food & drink'), findsOneWidget);
      expect(find.widgetWithText(InputChip, 'Jul 1–Jul 31'), findsOneWidget);
      // The spike banner renders (gate: seeded category still active).
      expect(find.textContaining('above your'), findsOneWidget);
      // Only the in-category July row is shown — not zero, not stale-
      // search-filtered.
      expect(find.text('Row food-jul'), findsOneWidget);
      expect(find.text('Row fastrak-1'), findsNothing);
    },
  );

  testWidgets(
    'merchant after spike: category/date chips gone, banner gone, search '
    'seeded',
    (tester) async {
      await _pumpHost(tester);
      final host = _hostKey.currentState!;

      host.jump(
        category: 'Food & drink',
        window: _july(),
        claim: const SpikeClaim(_spike),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('above your'), findsOneWidget);

      host.jump(search: 'FasTrak');
      await tester.pumpAndSettle();

      expect(find.byType(InputChip), findsNothing);
      expect(find.textContaining('above your'), findsNothing);
      expect(_searchText(tester), 'FasTrak');
      expect(find.text('Row fastrak-1'), findsOneWidget);
    },
  );

  testWidgets(
    'manual compose after landing: a user search typed AFTER a seeded jump '
    'composes with the seed — no reset fires',
    (tester) async {
      await _pumpHost(tester);
      final host = _hostKey.currentState!;

      host.jump(category: 'Food & drink');
      await tester.pumpAndSettle();
      expect(find.text('Row food-jul'), findsOneWidget);
      expect(find.text('Row food-jun'), findsOneWidget);

      // Manual edit: type into the search field (debounced 120ms).
      await tester.enterText(_searchField(), 'Cafe');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      // Both dimensions active: category chip survives, search filters.
      expect(find.widgetWithText(InputChip, 'Food & drink'), findsOneWidget);
      expect(find.text('Row food-jul'), findsOneWidget);
      expect(find.text('Row food-jun'), findsNothing);
      expect(host.catConsumed, 1, reason: 'seed applied exactly once');
    },
  );

  testWidgets(
    'repeat identical jump: after consumption + a manual clear, delivering '
    'the SAME merchant re-seeds (null→value transition); consumed fires '
    'twice',
    (tester) async {
      await _pumpHost(tester);
      final host = _hostKey.currentState!;

      host.jump(search: 'FasTrak');
      await tester.pumpAndSettle();
      expect(_searchText(tester), 'FasTrak');
      expect(host.searchConsumed, 1);

      // User clears the search by hand.
      await tester.enterText(_searchField(), '');
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();
      expect(find.text('Row food-jul'), findsOneWidget);

      // Same merchant tapped again — must re-seed, not no-op.
      host.jump(search: 'FasTrak');
      await tester.pumpAndSettle();
      expect(_searchText(tester), 'FasTrak');
      expect(find.text('Row fastrak-1'), findsOneWidget);
      expect(find.text('Row food-jul'), findsNothing);
      expect(host.searchConsumed, 2);
    },
  );

  testWidgets('sort mode survives a jump (deliberately NOT reset)', (
    tester,
  ) async {
    await _pumpHost(tester);
    final host = _hostKey.currentState!;

    // User picks a non-default sort from the toolbar menu. The menu's
    // longer labels overflow their 256px popup cap under the test font's
    // square Ahem glyphs (real Inter glyphs fit), so tolerate ONLY
    // RenderFlex-overflow reports while the menu is open.
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exception.toString().contains('overflowed')) return;
      prevOnError?.call(details);
    };
    try {
      await tester.tap(find.byTooltip('Sort by'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Merchant (A–Z)'));
      await tester.pumpAndSettle();
    } finally {
      FlutterError.onError = prevOnError;
    }
    expect(find.widgetWithText(InputChip, 'Merchant (A–Z)'), findsOneWidget);

    // A jump arrives: filters reset + seed applies, sort untouched.
    host.jump(category: 'Food & drink');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'Food & drink'), findsOneWidget);
    expect(find.widgetWithText(InputChip, 'Merchant (A–Z)'), findsOneWidget);
  });

  testWidgets('a stale spike banner cannot resurrect: after a non-spike jump '
      '(host nulls the claim), re-activating the same category shows NO '
      'banner', (tester) async {
    await _pumpHost(tester);
    final host = _hostKey.currentState!;

    host.jump(
      category: 'Food & drink',
      window: _july(),
      claim: const SpikeClaim(_spike),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('above your'), findsOneWidget);

    // Non-spike jump: the dashboard companion assigns claim = null.
    host.jump(search: 'FasTrak');
    await tester.pumpAndSettle();
    expect(find.textContaining('above your'), findsNothing);

    // The spike's category becomes active again (here via a category
    // jump; a manual chip re-add exercises the same banner gate). The
    // old dashboard kept its stale copy and the banner resurrected —
    // now the claim was replaced, so nothing renders.
    host.jump(category: 'Food & drink');
    await tester.pumpAndSettle();
    expect(find.widgetWithText(InputChip, 'Food & drink'), findsOneWidget);
    expect(find.textContaining('above your'), findsNothing);
  });
}
