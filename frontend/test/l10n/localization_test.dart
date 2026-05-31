import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';

// Verifies the l10n wiring end-to-end: the same AppLocalizations getters
// resolve to English vs hand-tuned es-MX strings purely from the active
// Locale. Pumps a minimal MaterialApp (no app screens) so this stays clear
// of the package:web widget-test hazard noted in MEMORY.
void main() {
  Future<void> pumpWithLocale(WidgetTester tester, Locale locale) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(
          builder: (context) {
            final l = AppLocalizations.of(context);
            return Text('${l.navOverview}|${l.navLending}|${l.navMoreGroup}');
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('English locale renders English nav labels', (tester) async {
    await pumpWithLocale(tester, const Locale('en'));
    expect(find.text('Overview|Lending|MORE'), findsOneWidget);
  });

  testWidgets('Spanish (es-MX) locale renders es-MX nav labels',
      (tester) async {
    await pumpWithLocale(tester, const Locale('es'));
    expect(find.text('Resumen|Préstamos|MÁS'), findsOneWidget);
  });

  test('both locales are supported', () {
    final codes =
        AppLocalizations.supportedLocales.map((l) => l.languageCode).toSet();
    expect(codes.containsAll({'en', 'es'}), isTrue);
  });
}
