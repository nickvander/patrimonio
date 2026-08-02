import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/screens/account_transactions_screen.dart';
import 'package:patrimonio/services/realtime_service.dart';
import 'package:patrimonio/services/tx_page.dart';
import 'package:patrimonio/widgets/transactions_tab.dart';

// The panel host (AccountTransactionsScreen) takes test seams for its
// transaction reads/writes — `transactionsFetcher` / `transactionUpdater` —
// so these tests never subclass ApiService (per MEMORY: package:web breaks
// the test VM). The panel's other initState fetches (balance history,
// alerts hydration) run against the real ApiService, whose calls hit
// flutter_test's mocked HTTP (400) and are best-effort/caught internally.

/// Recorded onUpdate invocation reaching the injected updater.
typedef _Update = ({String id, String? userCategory});

/// In-memory single-account transaction table the fake backend pages over.
/// Newest first, one row per day; `user_description` ("Row i") is what
/// `displayLabel` renders, so finders can target exact rows.
List<Map<String, dynamic>> _makeTable(int n) {
  final today = DateTime.now();
  return [
    for (var i = 0; i < n; i++)
      {
        'id': 'tx-$i',
        'date': DateFormat(
          'yyyy-MM-dd',
        ).format(today.subtract(Duration(days: i))),
        'amount': 10.0 + i,
        'currency': 'USD',
        'description': 'MERCHANT $i',
        'user_description': 'Row $i',
        'category': 'FOOD_AND_DRINK',
        'account_name': 'Checking',
      },
  ];
}

/// Fake paged backend: records every (limit, offset) the panel asks for
/// and serves slices of [table], handing out fresh map copies the way a
/// real JSON decode would.
class _FakeBackend {
  _FakeBackend(this.table);

  final List<Map<String, dynamic>> table;
  final List<({int limit, int offset})> calls = [];

  // totalCount stays null: these tests pin the pre-header (old-backend)
  // heuristics, which must keep working when X-Total-Count is absent.
  Future<TxPage> fetch({required int limit, required int offset}) async {
    calls.add((limit: limit, offset: offset));
    return TxPage(
      rows: [
        for (final t in table.skip(offset).take(limit))
          Map<String, dynamic>.of(t),
      ],
    );
  }
}

const Map<String, dynamic> _account = {
  'id': 'acct-1',
  'name': 'Checking',
  'currency': 'USD',
  'current_balance': 1000.0,
  'account_type': 'depository',
  'integration_type': 'manual',
};

/// Manual investment account: the only kind whose holding rows carry the
/// delete (X) button behind the round-3 soft-delete + undo flow.
const Map<String, dynamic> _investmentAccount = {
  'id': 'acct-inv',
  'name': 'Brokerage',
  'currency': 'USD',
  'current_balance': 500.0,
  'account_type': 'investment',
  'integration_type': 'manual',
};

/// Fake holdings backend for the delete-undo flow (the panel's
/// holdingsFetcher / holdingDeleter / holdingRestorer seams): one AAPL
/// position that soft-delete removes and restore brings back.
class _FakeHoldingsBackend {
  bool deleted = false;
  int deleteCalls = 0;
  int restoreCalls = 0;

  static const Map<String, dynamic> holding = {
    'id': 'hold-1',
    'symbol': 'AAPL',
    'name': 'Apple Inc',
    'quantity': 2,
    'price': 250.0,
    'value': 500.0,
  };

  Future<List<dynamic>> fetch(String accountId) async =>
      deleted ? const [] : [Map<String, dynamic>.of(holding)];

  Future<void> delete(String accountId, String holdingId) async {
    deleteCalls++;
    deleted = true;
  }

  Future<Map<String, dynamic>> restore(
    String accountId,
    String holdingId,
  ) async {
    restoreCalls++;
    deleted = false;
    return Map<String, dynamic>.of(holding);
  }
}

Widget _host(Widget panel) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: panel),
);

AccountTransactionsScreen _panel({
  required AccountTransactionsFetcher fetcher,
  List<_Update>? updates,
  Stream<RealtimeEvent>? realtimeEvents,
}) {
  return AccountTransactionsScreen(
    account: _account,
    allAccounts: const [_account],
    conversionFactor: 1.0,
    currencyFormat: NumberFormat.currency(symbol: r'$'),
    targetCurrency: 'USD',
    usdMxnRate: 0,
    realtimeEvents: realtimeEvents,
    transactionsFetcher: fetcher,
    transactionUpdater: updates == null
        ? null
        : (
            String id, {
            String? userCategory,
            String? userNotes,
            String? userDescription,
            String? accountId,
          }) async {
            updates.add((id: id, userCategory: userCategory));
          },
  );
}

void _setViewSize(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// The Scrollable inside the tab's inner ListView (the search TextField
/// also contains a Scrollable, so plain byType is ambiguous).
Finder _innerListScrollable() => find
    .descendant(of: find.byType(ListView), matching: find.byType(Scrollable))
    .first;

void main() {
  group('Account panel — paged loading', () {
    testWidgets('initial load is one ~page (not 1,000 rows); Load more '
        'appends the next offset and hides at the tail', (tester) async {
      _setViewSize(tester, const Size(1000, 900));
      final backend = _FakeBackend(_makeTable(70));

      await tester.pumpWidget(_host(_panel(fetcher: backend.fetch)));
      await tester.pumpAndSettle();

      // First request is a single small page from offset 0.
      expect(backend.calls, hasLength(1));
      expect(backend.calls.single, (limit: 50, offset: 0));
      expect(find.text('Row 0'), findsOneWidget);
      expect(find.text('Showing 50 of 50'), findsOneWidget);

      // 70 > 50 → the backend filled the page, so the panel offers more.
      final loadMore = find.text('Load more');
      expect(loadMore, findsOneWidget);

      await tester.tap(loadMore);
      await tester.pumpAndSettle();

      // Next page picks up exactly where the loaded list ends…
      expect(backend.calls, hasLength(2));
      expect(backend.calls.last, (limit: 50, offset: 50));
      expect(find.text('Showing 70 of 70'), findsOneWidget);
      // …and the short (20-row) page proves the tail was reached.
      expect(find.text('Load more'), findsNothing);
    });

    testWidgets('full-body spinner appears for the initial load only', (
      tester,
    ) async {
      _setViewSize(tester, const Size(1000, 900));
      final table = _makeTable(5);
      final gate = Completer<void>();
      Future<TxPage> gatedFetch({
        required int limit,
        required int offset,
      }) async {
        await gate.future;
        return TxPage(
          rows: [
            for (final t in table.skip(offset).take(limit))
              Map<String, dynamic>.of(t),
          ],
        );
      }

      await tester.pumpWidget(_host(_panel(fetcher: gatedFetch)));
      await tester.pump();

      // While the first page is in flight the body is the spinner.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Row 0'), findsNothing);

      gate.complete();
      await tester.pumpAndSettle();

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.text('Row 0'), findsOneWidget);
    });
  });

  group('Account panel — running balance per row', () {
    testWidgets(
      'rows show "balance after" anchored on the header balance: top row '
      '= current balance, older rows walk back through the amounts',
      (tester) async {
        _setViewSize(tester, const Size(1000, 900));
        // 3 rows, amounts 10/11/12 (all inflows, positive), account balance 1000.
        final table = _makeTable(3);
        // Row 1 carries a statement-persisted balance — exact, no '≈'.
        table[1]['balance_after'] = 555.25;
        final backend = _FakeBackend(table);

        await tester.pumpWidget(_host(_panel(fetcher: backend.fetch)));
        await tester.pumpAndSettle();

        // Top row's balance-after IS the account's current balance
        // (estimated → '≈' prefix, since manual rows persist nothing).
        expect(find.text(r'Bal. ≈ $1,000.00'), findsOneWidget);
        // The persisted statement figure wins and renders plain.
        expect(find.text(r'Bal. $555.25'), findsOneWidget);
        // The row below it re-anchors on the exact figure: the older row's
        // balance predates row 1's inflow of 11 arriving, so 555.25 − 11 = 544.25.
        expect(find.text(r'Bal. ≈ $544.25'), findsOneWidget);

        // Single-account host: the meta line no longer repeats the
        // account name the panel header already shows.
        expect(find.text('Food & drink · Checking'), findsNothing);
      },
    );
  });

  group('Account panel — delete-undo snackbar (round 3)', () {
    // The production panel is a showGeneralDialog route ABOVE the app's
    // root Scaffold; these tests reproduce that stacking (right-aligned
    // page + dismissible barrier) so they genuinely prove the snackbar's
    // Undo is reachable through the modal layering, not just present in
    // the tree.
    Widget dialogHost({
      required _FakeHoldingsBackend holdings,
      required List<(String, double)> balanceUpdates,
    }) {
      final backend = _FakeBackend(_makeTable(0)); // no transactions
      return MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showGeneralDialog<void>(
                  context: context,
                  barrierDismissible: true,
                  barrierLabel: 'Close',
                  barrierColor: Colors.black38,
                  pageBuilder: (_, _, _) => Align(
                    alignment: Alignment.centerRight,
                    child: Material(
                      color: Colors.transparent,
                      child: SizedBox(
                        width: 560,
                        child: AccountTransactionsScreen(
                          account: _investmentAccount,
                          allAccounts: const [_investmentAccount],
                          conversionFactor: 1.0,
                          currencyFormat: NumberFormat.currency(symbol: r'$'),
                          targetCurrency: 'USD',
                          usdMxnRate: 0,
                          transactionsFetcher: backend.fetch,
                          holdingsFetcher: holdings.fetch,
                          holdingDeleter: holdings.delete,
                          holdingRestorer: holdings.restore,
                          onBalanceUpdate: (id, bal) =>
                              balanceUpdates.add((id, bal)),
                        ),
                      ),
                    ),
                  ),
                ),
                child: const Text('Open panel'),
              ),
            ),
          ),
        ),
      );
    }

    /// Open panel → delete AAPL through the confirm dialog → undo
    /// snackbar showing.
    Future<void> deleteThroughConfirm(WidgetTester tester) async {
      await tester.tap(find.text('Open panel'));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Remove AAPL'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete permanently'));
      await tester.pumpAndSettle();
      expect(find.text('Deleted AAPL'), findsOneWidget);
    }

    testWidgets(
      'with the panel OPEN, the undo snackbar renders above the panel '
      'route and its Undo is tappable (restores in place)',
      (tester) async {
        _setViewSize(tester, const Size(1000, 900));
        final holdings = _FakeHoldingsBackend();
        final balanceUpdates = <(String, double)>[];

        await tester.pumpWidget(
          dialogHost(holdings: holdings, balanceUpdates: balanceUpdates),
        );
        await deleteThroughConfirm(tester);
        expect(holdings.deleteCalls, 1);

        // The regression: pre-fix the snackbar sat on the ROOT messenger,
        // underneath the panel route — this tap would land on the modal
        // barrier (dismissing the panel) instead of the Undo button.
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();

        expect(holdings.restoreCalls, 1);
        // Panel never closed, and the restored row is back on screen.
        expect(find.byType(AccountTransactionsScreen), findsOneWidget);
        expect(find.byTooltip('Remove AAPL'), findsOneWidget);
      },
    );

    testWidgets(
      'closing the panel mid-countdown re-homes the snackbar on the root '
      'messenger; Undo still restores AND pushes the fresh balance to '
      'the dashboard (onBalanceUpdate) despite the disposed State',
      (tester) async {
        _setViewSize(tester, const Size(1000, 900));
        final holdings = _FakeHoldingsBackend();
        final balanceUpdates = <(String, double)>[];

        await tester.pumpWidget(
          dialogHost(holdings: holdings, balanceUpdates: balanceUpdates),
        );
        await deleteThroughConfirm(tester);
        // In-panel post-delete sync already told the dashboard "0 left".
        expect(balanceUpdates.last, ('acct-inv', 0.0));

        // Dismiss the panel via its barrier while the countdown runs. The
        // panel State (and its nested messenger + snackbar) is disposed…
        await tester.tapAt(const Offset(20, 20));
        await tester.pumpAndSettle();
        expect(find.byType(AccountTransactionsScreen), findsNothing);

        // …but the undo affordance survives on the root messenger.
        expect(find.text('Deleted AAPL'), findsOneWidget);
        await tester.tap(find.text('Undo'));
        await tester.pumpAndSettle();

        expect(holdings.restoreCalls, 1);
        // Defect-2 regression: with no panel State left, the undo closure
        // itself must refresh the dashboard — Σ holding values, like the
        // backend's recompute.
        expect(balanceUpdates.last, ('acct-inv', 500.0));
      },
    );
  });

  group('Account panel — in-place post-edit refresh', () {
    testWidgets(
      'an edit refetches at loaded depth without remounting the list: '
      'same ScrollPosition object, same offset, no spinner',
      (tester) async {
        _setViewSize(tester, const Size(1000, 900));
        final backend = _FakeBackend(_makeTable(60));
        final updates = <_Update>[];

        await tester.pumpWidget(
          _host(_panel(fetcher: backend.fetch, updates: updates)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Showing 50 of 50'), findsOneWidget);

        // Scroll partway down the virtualised list and remember exactly
        // where we are — including the ScrollPosition OBJECT, whose
        // identity only survives if the list is never remounted.
        await tester.drag(_innerListScrollable(), const Offset(0, -400));
        await tester.pump();
        final positionBefore = tester
            .state<ScrollableState>(_innerListScrollable())
            .position;
        final pixelsBefore = positionBefore.pixels;
        expect(pixelsBefore, greaterThan(0));

        // Drive an edit through the exact callback the detail editors use.
        backend.table[3]['user_category'] = 'Coffee';
        final tab = tester.widget<TransactionsTab>(
          find.byType(TransactionsTab),
        );
        await tab.onUpdate!('tx-3', userCategory: 'Coffee');
        await tester.pump();

        // The PATCH reached the injected updater…
        expect(updates, [(id: 'tx-3', userCategory: 'Coffee')]);
        // …followed by ONE depth-preserving refetch from the top (the old
        // behavior re-downloaded up to 1,000 rows per edit).
        expect(backend.calls, hasLength(2));
        expect(backend.calls.last, (limit: 50, offset: 0));

        // No full-body spinner, no list remount: the refreshed rows landed
        // in the SAME scroll position object at the same offset.
        expect(find.byType(CircularProgressIndicator), findsNothing);
        final positionAfter = tester
            .state<ScrollableState>(_innerListScrollable())
            .position;
        expect(
          identical(positionBefore, positionAfter),
          isTrue,
          reason: 'a remount would have created a new ScrollPosition',
        );
        expect(positionAfter.pixels, pixelsBefore);

        // The refetched data is actually on screen (list still full depth,
        // Load more still offered — hasMore was not clobbered).
        expect(find.text('Showing 50 of 50'), findsOneWidget);
        expect(find.text('Load more'), findsOneWidget);
        await tester.pumpAndSettle();
      },
    );
  });

  group('Account panel — realtime refresh (manual-tx-edit QA fix 3)', () {
    // Pre-fix, the panel never subscribed to server pushes: a transaction
    // edited elsewhere (dashboard Transactions tab, another tab/device)
    // left an open panel stale indefinitely. The panel now takes the
    // opener's realtime stream and maps TransactionsChanged/resync onto
    // the same depth-preserving in-place refetch a local edit uses.
    testWidgets(
      'a TransactionsChanged push refetches in place (no spinner) and a '
      'burst of events coalesces into ONE refetch',
      (tester) async {
        _setViewSize(tester, const Size(1000, 900));
        final backend = _FakeBackend(_makeTable(5));
        final events = StreamController<RealtimeEvent>.broadcast();
        addTearDown(events.close);

        await tester.pumpWidget(
          _host(_panel(fetcher: backend.fetch, realtimeEvents: events.stream)),
        );
        await tester.pumpAndSettle();
        expect(backend.calls, hasLength(1));
        expect(find.text('Row 0'), findsOneWidget);

        // Out-of-band edit lands server-side, then the push arrives — twice
        // in quick succession (e.g. the editing surface's own follow-up).
        backend.table[0]['user_description'] = 'Row 0 (edited elsewhere)';
        events.add(
          const RealtimeEvent(type: RealtimeEventType.transactionsChanged),
        );
        events.add(
          const RealtimeEvent(type: RealtimeEventType.transactionsChanged),
        );
        await tester.pump(); // deliver stream events → debounce armed
        // Inside the debounce window nothing has refetched yet.
        expect(backend.calls, hasLength(1));
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pumpAndSettle();

        // One coalesced, depth-preserving refetch from the top…
        expect(backend.calls, hasLength(2));
        expect(backend.calls.last, (limit: 50, offset: 0));
        // …that landed the edit without a full-body spinner/remount.
        expect(find.byType(CircularProgressIndicator), findsNothing);
        expect(find.text('Row 0 (edited elsewhere)'), findsOneWidget);
      },
    );

    testWidgets('non-transaction pushes (fx rate ticks) do not refetch', (
      tester,
    ) async {
      _setViewSize(tester, const Size(1000, 900));
      final backend = _FakeBackend(_makeTable(5));
      final events = StreamController<RealtimeEvent>.broadcast();
      addTearDown(events.close);

      await tester.pumpWidget(
        _host(_panel(fetcher: backend.fetch, realtimeEvents: events.stream)),
      );
      await tester.pumpAndSettle();
      expect(backend.calls, hasLength(1));

      events.add(const RealtimeEvent(type: RealtimeEventType.fxRatesUpdated));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pumpAndSettle();

      expect(
        backend.calls,
        hasLength(1),
        reason: 'FX ticks are frequent and change nothing this list shows',
      );
    });
  });

  group(
    'Account panel — proven-empty totals against an old server (Fix B)',
    () {
      /// Scripted fetcher: serves [responses] in order, recording calls.
      /// Unlike _FakeBackend it can return a non-null totalCount first and
      /// then an old-server (headerless) page, which is exactly the
      /// mixed-server shape these regressions are about.
      ({
        List<({int limit, int offset})> calls,
        AccountTransactionsFetcher fetch,
      })
      scripted(List<TxPage> responses) {
        final calls = <({int limit, int offset})>[];
        final queue = [...responses];
        Future<TxPage> fetch({required int limit, required int offset}) async {
          calls.add((limit: limit, offset: offset));
          // Past the script → keep serving an empty headerless page.
          return queue.isEmpty ? const TxPage(rows: []) : queue.removeAt(0);
        }

        return (calls: calls, fetch: fetch);
      }

      List<Map<String, dynamic>> rows(int n) => [
        for (final t in _makeTable(n)) Map<String, dynamic>.of(t),
      ];

      testWidgets(
        'an empty headerless page at offset==loaded pins the total to the '
        'loaded rows: "Showing 2 of 5" → "Showing 2 of 2", Load more gone',
        (tester) async {
          _setViewSize(tester, const Size(1000, 900));
          // Page 1 came from a new server (total 5); the tail was then
          // deleted server-side and the follow-up page arrives from an old
          // server with no header. Pre-fix the 5 lingered: the panel kept
          // offering Load more (2 < 5) and fetching empty pages forever.
          final backend = scripted([
            TxPage(rows: rows(2), totalCount: 5),
            const TxPage(rows: []),
          ]);

          await tester.pumpWidget(_host(_panel(fetcher: backend.fetch)));
          await tester.pumpAndSettle();
          expect(find.text('Showing 2 of 5'), findsOneWidget);
          expect(find.text('Load more'), findsOneWidget);

          await tester.tap(find.text('Load more'));
          await tester.pumpAndSettle();

          expect(backend.calls.last, (limit: 50, offset: 2));
          // The empty page at offset == loaded proves the 2 rows are the
          // whole account: stale denominator cleared, no more Load more.
          expect(find.text('Showing 2 of 2'), findsOneWidget);
          expect(find.text('Showing 2 of 5'), findsNothing);
          expect(find.text('Load more'), findsNothing);
        },
      );

      testWidgets('a headerless EMPTY refetch (delete-all elsewhere) clears a '
          'previously non-null total instead of leaving a stale "of 3"', (
        tester,
      ) async {
        _setViewSize(tester, const Size(1000, 900));
        final backend = scripted([
          TxPage(rows: rows(1), totalCount: 3),
          const TxPage(rows: []),
        ]);
        final events = StreamController<RealtimeEvent>.broadcast();
        addTearDown(events.close);

        await tester.pumpWidget(
          _host(_panel(fetcher: backend.fetch, realtimeEvents: events.stream)),
        );
        await tester.pumpAndSettle();
        expect(find.text('Showing 1 of 3'), findsOneWidget);

        // Every row was deleted from another surface; the push arrives and
        // the in-place refetch returns an empty, headerless first page.
        events.add(
          const RealtimeEvent(type: RealtimeEventType.transactionsChanged),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pumpAndSettle();

        expect(backend.calls, hasLength(2));
        // Proven-empty: the remembered 3 is gone — no stale count line
        // survives anywhere; the panel shows its real empty state.
        expect(find.textContaining('Showing'), findsNothing);
        expect(find.text('No transactions yet'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    },
  );
}
