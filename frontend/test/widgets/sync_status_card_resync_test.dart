// Widget tests for the per-institution full-history re-pull surfaced on the
// Management tab's SyncStatusCard rows.
//
// The feature exists because a Plaid `/transactions/sync` cursor only ever
// advances: the owner's June rent charge and its offsetting credit never
// arrived and were unrecoverable. The re-pull clears the cursor so Plaid
// replays everything it still holds.
//
// What these tests pin, in order of how badly it would hurt to lose it:
//   1. The confirmation states the LIMITATION — a re-pull cannot recover what
//      the provider no longer sends. Promising recovery would be a lie, and
//      the honest sentence is the entire reason the dialog exists.
//   2. The action is offered on Plaid rows only, so a manual/CSV institution
//      can't walk into the backend's 400.
//   3. Confirm hands the institution id to the host; Cancel fires nothing.
// All of it in BOTH locales — the copy is the product here.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/widgets/sync_status_card.dart';

Widget _wrap(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  // The card renders a row per institution plus a summary; a phone-sized
  // test viewport would overflow, so give it room and let the row take its
  // wide (non-narrow) branch.
  home: Scaffold(body: SizedBox(width: 900, child: child)),
);

const _plaid = {
  'id': 'inst-plaid',
  'name': 'Bilt Mastercard',
  'sync_status': 'success',
  'integration_type': 'plaid',
  'last_synced_at': null,
};

const _manual = {
  'id': 'inst-manual',
  'name': 'Cash Envelope',
  'sync_status': 'manual',
  'integration_type': 'manual',
  'last_synced_at': null,
};

/// Open the kebab on the (single) row the card is showing.
Future<void> _openKebab(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.more_vert));
  await tester.pumpAndSettle();
}

void main() {
  group('availability by integration type', () {
    testWidgets('Plaid row offers the re-check action', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SyncStatusCard(syncData: const [_plaid], onFullResync: (_) async {}),
        ),
      );
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
      await _openKebab(tester);
      expect(find.text('Re-check for missing transactions'), findsOneWidget);
    });

    testWidgets('manual row offers no kebab at all', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SyncStatusCard(syncData: const [_manual], onFullResync: (_) async {}),
        ),
      );
      // Hidden rather than disabled: a manual institution has no provider
      // feed to re-check, so there is nothing to offer. This is also what
      // keeps the user away from the backend's 400.
      expect(find.byIcon(Icons.more_vert), findsNothing);
    });

    testWidgets('mixed list shows exactly one kebab — the Plaid row', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          SyncStatusCard(
            syncData: const [_plaid, _manual],
            onFullResync: (_) async {},
          ),
        ),
      );
      expect(find.byIcon(Icons.more_vert), findsOneWidget);
    });

    testWidgets('no kebab when the host wires no re-pull handler', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const SyncStatusCard(syncData: [_plaid])));
      expect(find.byIcon(Icons.more_vert), findsNothing);
    });
  });

  group('confirmation copy tells the truth (en)', () {
    testWidgets('states what it cannot do', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SyncStatusCard(syncData: const [_plaid], onFullResync: (_) async {}),
        ),
      );
      await _openKebab(tester);
      await tester.tap(find.text('Re-check for missing transactions'));
      await tester.pumpAndSettle();

      // THE assertion. If this sentence ever disappears, the dialog is
      // implicitly promising recovery it cannot deliver.
      expect(
        find.textContaining("can't recover what the provider no longer sends"),
        findsOneWidget,
      );
      // ...and it names the fallback rather than leaving the user stuck.
      expect(find.textContaining('adding them by hand'), findsOneWidget);
    });

    testWidgets('names the institution and warns about duration', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          SyncStatusCard(syncData: const [_plaid], onFullResync: (_) async {}),
        ),
      );
      await _openKebab(tester);
      await tester.tap(find.text('Re-check for missing transactions'));
      await tester.pumpAndSettle();

      // The row underneath also renders the name, so pin the dialog TITLE
      // exactly rather than any widget merely containing it.
      expect(
        find.text('Re-check Bilt Mastercard with the provider?'),
        findsOneWidget,
      );
      expect(find.textContaining('take several minutes'), findsOneWidget);
    });

    testWidgets('reassures that user edits survive', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SyncStatusCard(syncData: const [_plaid], onFullResync: (_) async {}),
        ),
      );
      await _openKebab(tester);
      await tester.tap(find.text('Re-check for missing transactions'));
      await tester.pumpAndSettle();

      // The one thing that IS guaranteed — the backend upsert touches no
      // `user_*` column.
      expect(find.textContaining('never overwritten'), findsOneWidget);
      expect(find.textContaining('rather than duplicated'), findsOneWidget);
    });
  });

  group('confirmation copy tells the truth (es)', () {
    testWidgets('states what it cannot do, in Spanish', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SyncStatusCard(syncData: const [_plaid], onFullResync: (_) async {}),
          locale: const Locale('es'),
        ),
      );
      await _openKebab(tester);
      await tester.tap(find.text('Buscar movimientos faltantes'));
      await tester.pumpAndSettle();

      expect(
        find.textContaining('No puede recuperar lo que el proveedor ya no'),
        findsOneWidget,
      );
      expect(find.textContaining('capturarlos a mano'), findsOneWidget);
      expect(find.textContaining('nunca se sobrescriben'), findsOneWidget);
      expect(find.text('Consultar ahora'), findsOneWidget);
    });
  });

  group('handing off to the host', () {
    testWidgets('confirming passes the institution id', (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(
        _wrap(
          SyncStatusCard(
            syncData: const [_plaid],
            onFullResync: (id) async => calls.add(id),
          ),
        ),
      );
      await _openKebab(tester);
      await tester.tap(find.text('Re-check for missing transactions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Re-check now'));
      await tester.pumpAndSettle();

      expect(calls, ['inst-plaid']);
    });

    testWidgets('cancelling fires nothing', (tester) async {
      final calls = <String>[];
      await tester.pumpWidget(
        _wrap(
          SyncStatusCard(
            syncData: const [_plaid],
            onFullResync: (id) async => calls.add(id),
          ),
        ),
      );
      await _openKebab(tester);
      await tester.tap(find.text('Re-check for missing transactions'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(calls, isEmpty);
    });

    testWidgets('dismissing the menu without choosing fires nothing', (
      tester,
    ) async {
      final calls = <String>[];
      await tester.pumpWidget(
        _wrap(
          SyncStatusCard(
            syncData: const [_plaid],
            onFullResync: (id) async => calls.add(id),
          ),
        ),
      );
      await _openKebab(tester);
      // Tap the barrier, well away from the menu.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      expect(calls, isEmpty);
      expect(find.text('Re-check now'), findsNothing);
    });
  });
}
