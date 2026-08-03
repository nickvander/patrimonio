import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/screens/continuity_dossier_screen.dart';

// ContinuityDossierScreen: the Settings-surface entry for the printable
// household continuity dossier. Data + the browser hand-off arrive through
// the loadNotes/saveNotes/openUrl test seams (ImportCleanupScreen /
// TaxExportsCard pattern) so no HTTP or window.open runs on the test VM.
// Labels are asserted in BOTH locales (house rule for user-facing strings).

Widget _host({
  Locale locale = const Locale('en'),
  Future<dynamic> Function()? loadNotes,
  Future<void> Function(String)? saveNotes,
  void Function(String)? openUrl,
}) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: ContinuityDossierScreen(
    loadNotesOverride: loadNotes ?? () async => null,
    saveNotesOverride: saveNotes ?? (_) async {},
    openUrl: openUrl ?? (_) {},
  ),
);

void main() {
  testWidgets('en: renders title, instructions field, language + generate', (
    tester,
  ) async {
    await tester.pumpWidget(_host());
    await tester.pumpAndSettle();

    expect(find.text('Continuity dossier'), findsOneWidget);
    expect(find.text('Your instructions'), findsOneWidget);
    expect(find.text('Document language'), findsOneWidget);
    expect(find.text('Generate printable dossier'), findsOneWidget);
    expect(find.text('English'), findsOneWidget);
    expect(find.text('Español'), findsOneWidget);
  });

  testWidgets('es: renders localized', (tester) async {
    await tester.pumpWidget(_host(locale: const Locale('es')));
    await tester.pumpAndSettle();

    expect(find.text('Expediente de continuidad'), findsOneWidget);
    expect(find.text('Tus instrucciones'), findsOneWidget);
    expect(find.text('Idioma del documento'), findsOneWidget);
    expect(find.text('Generar expediente imprimible'), findsOneWidget);
  });

  testWidgets('loads stored instructions into the field', (tester) async {
    await tester.pumpWidget(
      _host(loadNotes: () async => 'Call the notary first.'),
    );
    await tester.pumpAndSettle();

    expect(find.text('Call the notary first.'), findsOneWidget);
  });

  testWidgets('save hands the trimmed text to the settings store', (
    tester,
  ) async {
    final saved = <String>[];
    await tester.pumpWidget(_host(saveNotes: (t) async => saved.add(t)));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      '  Box #42 at the notary.  ',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    expect(saved, ['Box #42 at the notary.']);
    expect(find.text('Instructions saved'), findsOneWidget); // snackbar
  });

  testWidgets('generate opens the backend URL with the chosen language '
      '(defaults to the app locale)', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(_host(openUrl: opened.add));
    await tester.pumpAndSettle();

    // The language/generate card sits below the 600px test viewport fold.
    await tester.ensureVisible(find.text('Generate printable dossier'));
    await tester.pumpAndSettle();

    // Default en (app locale en).
    await tester.tap(find.text('Generate printable dossier'));
    // Switch to es and generate again.
    await tester.tap(find.text('Español'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generate printable dossier'));

    expect(opened, hasLength(2));
    expect(opened[0], endsWith('/exports/continuity-dossier?lang=en'));
    expect(opened[1], endsWith('/exports/continuity-dossier?lang=es'));
  });

  testWidgets('es app locale defaults the document language to es', (
    tester,
  ) async {
    final opened = <String>[];
    await tester.pumpWidget(
      _host(locale: const Locale('es'), openUrl: opened.add),
    );
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Generar expediente imprimible'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Generar expediente imprimible'));
    expect(opened, hasLength(1));
    expect(opened.single, endsWith('/exports/continuity-dossier?lang=es'));
  });
}
