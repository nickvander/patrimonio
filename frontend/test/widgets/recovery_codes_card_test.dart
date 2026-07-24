import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/widgets/recovery_codes_card.dart';

Widget _wrap(Widget child, {Locale locale = const Locale('en')}) =>
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

String _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .join('\n');

void main() {
  // Regression: the lockout warning used to render for users who had NEVER
  // enabled 2FA (the count check shipped without a totpEnabled gate).
  testWidgets('no warning when 2FA is disabled, even with zero codes',
      (tester) async {
    await tester.pumpWidget(_wrap(RecoveryCodesCard(
      totpEnabled: false,
      unusedCodes: 0,
      onRegenerate: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    expect(_allText(tester), isNot(contains('No recovery codes left')));
    // The neutral informational tile still renders and offers Regenerate.
    expect(find.byIcon(Icons.vpn_key_outlined), findsOneWidget);
    expect(_allText(tester), contains('0 unused codes'));
    expect(_allText(tester), contains('Regenerate'));
  });

  testWidgets('warning shown when 2FA is enabled with zero codes (en)',
      (tester) async {
    await tester.pumpWidget(_wrap(RecoveryCodesCard(
      totpEnabled: true,
      unusedCodes: 0,
      onRegenerate: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(_allText(tester), contains('No recovery codes left'));
  });

  testWidgets('warning shown when 2FA is enabled with zero codes (es)',
      (tester) async {
    await tester.pumpWidget(_wrap(
      RecoveryCodesCard(
        totpEnabled: true,
        unusedCodes: 0,
        onRegenerate: () {},
      ),
      locale: const Locale('es'),
    ));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(
        _allText(tester), contains('No quedan códigos de recuperación'));
  });

  testWidgets('few-codes warning when 2FA is enabled with 1 code',
      (tester) async {
    await tester.pumpWidget(_wrap(RecoveryCodesCard(
      totpEnabled: true,
      unusedCodes: 1,
      onRegenerate: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    expect(_allText(tester), contains('Only 1 recovery code left'));
  });

  testWidgets('neutral tile when 2FA is enabled with plenty of codes',
      (tester) async {
    await tester.pumpWidget(_wrap(RecoveryCodesCard(
      totpEnabled: true,
      unusedCodes: 10,
      onRegenerate: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    expect(find.byIcon(Icons.vpn_key_outlined), findsOneWidget);
    expect(_allText(tester), contains('10 unused codes'));
  });

  testWidgets('neutral tile while the count is still loading (null)',
      (tester) async {
    await tester.pumpWidget(_wrap(RecoveryCodesCard(
      totpEnabled: true,
      unusedCodes: null,
      onRegenerate: () {},
    )));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
    expect(find.byIcon(Icons.vpn_key_outlined), findsOneWidget);
  });

  testWidgets('Regenerate button fires the callback', (tester) async {
    var called = 0;
    await tester.pumpWidget(_wrap(RecoveryCodesCard(
      totpEnabled: true,
      unusedCodes: 0,
      onRegenerate: () => called++,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Regenerate'));
    expect(called, 1);
  });
}
