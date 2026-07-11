import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/widgets/sync_error_banner.dart';

Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

const _problems = [
  {'id': 'a', 'name': 'Chase', 'sync_status': 'error'},
  {'id': 'b', 'name': 'E*TRADE', 'sync_status': 'error'},
];

void main() {
  testWidgets('shows when there are problems and no snooze', (tester) async {
    await tester.pumpWidget(_wrap(const SyncErrorBanner(syncData: _problems)));
    expect(find.textContaining('need attention'), findsOneWidget);
  });

  testWidgets('hidden while snoozed and every problem was dismissed',
      (tester) async {
    await tester.pumpWidget(_wrap(SyncErrorBanner(
      syncData: _problems,
      dismissedIds: const {'a', 'b'},
      dismissedUntil: DateTime.now().add(const Duration(days: 3)),
      onDismiss: (_) {},
    )));
    expect(find.textContaining('need attention'), findsNothing);
  });

  testWidgets('re-shows when a NEW institution fails during the snooze',
      (tester) async {
    await tester.pumpWidget(_wrap(SyncErrorBanner(
      syncData: _problems, // 'a' and 'b'
      dismissedIds: const {'a'}, // only 'a' was dismissed
      dismissedUntil: DateTime.now().add(const Duration(days: 3)),
      onDismiss: (_) {},
    )));
    expect(find.textContaining('need attention'), findsOneWidget);
  });

  testWidgets('re-shows once the snooze has expired', (tester) async {
    await tester.pumpWidget(_wrap(SyncErrorBanner(
      syncData: _problems,
      dismissedIds: const {'a', 'b'},
      dismissedUntil: DateTime.now().subtract(const Duration(minutes: 1)),
      onDismiss: (_) {},
    )));
    expect(find.textContaining('need attention'), findsOneWidget);
  });

  testWidgets('tapping × reports the current problem ids', (tester) async {
    Set<String>? dismissed;
    await tester.pumpWidget(_wrap(SyncErrorBanner(
      syncData: _problems,
      onDismiss: (ids) => dismissed = ids,
    )));
    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();
    expect(dismissed, {'a', 'b'});
  });
}
