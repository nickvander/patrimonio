import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/widgets/tax_exports_card.dart';

// The tax-filing export pack card: one tappable row per year-end document
// (FBAR worksheet, Form 8949 CSV, Schedule B CSV, MX summary CSV), building
// same-origin backend URLs off the selected year — captured here through the
// `openUrl` test seam so no browser hand-off runs on the VM. Labels are
// asserted in BOTH locales (house rule for user-facing strings).

Widget _host(
  List<String> opened, {
  Locale locale = const Locale('en'),
  int initialYear = 2026,
  List<int> years = const [2026, 2025],
  String filingStatus = 'Single',
}) =>
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          child: TaxExportsCard(
            baseUrl: '/api',
            years: years,
            initialYear: initialYear,
            filingStatus: filingStatus,
            openUrl: opened.add,
          ),
        ),
      ),
    );

void main() {
  testWidgets('en: renders all four export rows and the year selector',
      (tester) async {
    await tester.pumpWidget(_host(<String>[]));
    await tester.pumpAndSettle();

    expect(find.text('Year-end export pack'), findsOneWidget);
    expect(find.text('FBAR worksheet (FinCEN 114)'), findsOneWidget);
    expect(find.text('Form 8949 CSV'), findsOneWidget);
    expect(find.text('Schedule B interest CSV'), findsOneWidget);
    expect(find.text('MX annual summary CSV'), findsOneWidget);
    expect(find.text('2026'), findsOneWidget); // year dropdown value
  });

  testWidgets('es: rows render localized', (tester) async {
    await tester.pumpWidget(_host(<String>[], locale: const Locale('es')));
    await tester.pumpAndSettle();

    expect(find.text('Paquete de exportación fiscal'), findsOneWidget);
    expect(find.text('Hoja de trabajo FBAR (FinCEN 114)'), findsOneWidget);
    expect(find.text('CSV Formulario 8949'), findsOneWidget);
    expect(find.text('CSV de intereses (Anexo B)'), findsOneWidget);
    expect(find.text('CSV resumen anual MX'), findsOneWidget);
  });

  testWidgets('tapping each row opens the matching backend export URL',
      (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(_host(opened, filingStatus: 'Head of Household'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('FBAR worksheet (FinCEN 114)'));
    await tester.tap(find.text('Form 8949 CSV'));
    await tester.tap(find.text('Schedule B interest CSV'));
    await tester.tap(find.text('MX annual summary CSV'));

    expect(opened, [
      '/api/tax/export/fbar?year=2026&lang=en',
      '/api/tax/export/8949?year=2026',
      '/api/tax/export/schedule-b?year=2026',
      // Filing status is query-encoded (spaces would otherwise break the URL).
      '/api/tax/export/mx?year=2026&status=Head+of+Household',
    ]);
  });

  testWidgets('es locale requests the Spanish FBAR worksheet', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(_host(opened, locale: const Locale('es')));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Hoja de trabajo FBAR (FinCEN 114)'));
    expect(opened, ['/api/tax/export/fbar?year=2026&lang=es']);
  });

  testWidgets('changing the card year rebuilds the URLs', (tester) async {
    final opened = <String>[];
    await tester.pumpWidget(_host(opened));
    await tester.pumpAndSettle();

    await tester.tap(find.text('2026'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2025').last);
    await tester.pumpAndSettle();

    await tester.tap(find.text('Form 8949 CSV'));
    expect(opened, ['/api/tax/export/8949?year=2025']);
  });

  testWidgets('a year missing from the options list is injected, not asserted',
      (tester) async {
    // Regression guard: the screen can select a year (e.g. the current one)
    // that the derived options list doesn't contain yet — the dropdown must
    // not assert.
    await tester
        .pumpWidget(_host(<String>[], initialYear: 2027, years: const [2025]));
    await tester.pumpAndSettle();
    expect(find.text('2027'), findsOneWidget);
  });
}
