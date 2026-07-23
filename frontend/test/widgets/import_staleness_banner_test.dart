import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/utils/import_staleness.dart';
import 'package:patrimonio/widgets/import_staleness_banner.dart';

Widget _wrap(Widget child, {Locale locale = const Locale('en')}) =>
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: child),
    );

/// Collapse NBSP/NNBSP so the es assertions don't pin exact codepoints.
String _normSpace(String s) =>
    s.replaceAll(' ', ' ').replaceAll(' ', ' ');

String _allText(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => _normSpace(t.data ?? ''))
    .join('\n');

const _stale = [
  StaleImportInstitution(name: 'Banamex', daysStale: 42),
  StaleImportInstitution(name: 'CetesDirecto', daysStale: 31),
];

void main() {
  testWidgets('renders nothing when no institution is stale', (tester) async {
    await tester
        .pumpWidget(_wrap(const ImportStalenessBanner(stale: [])));
    await tester.pumpAndSettle();
    expect(find.byType(Container), findsNothing);
    expect(find.byType(Text), findsNothing);
  });

  // The summary string has two same-typed placeholders and gen-l10n orders
  // them alphabetically (days, name) while the template reads name-first —
  // these bilingual assertions fail if a call site ever transposes them.
  testWidgets('en: names the most-stale institution with its day count',
      (tester) async {
    await tester
        .pumpWidget(_wrap(const ImportStalenessBanner(stale: _stale)));
    await tester.pumpAndSettle();
    final text = _allText(tester);
    expect(text,
        contains('Banamex data is 42 days old — import a statement'));
    expect(text, contains('1 more institution also needs a fresh import'));
    expect(text, contains('Import statement'));
  });

  testWidgets('es: mirrors the copy in Spanish', (tester) async {
    await tester.pumpWidget(_wrap(
      const ImportStalenessBanner(stale: _stale),
      locale: const Locale('es'),
    ));
    await tester.pumpAndSettle();
    final text = _allText(tester);
    expect(
        text,
        contains(
            'Los datos de Banamex tienen 42 días — importa un estado de cuenta'));
    expect(text,
        contains('1 institución más también necesita una importación reciente'));
    expect(text, contains('Importar estado de cuenta'));
  });

  testWidgets('en: singular day and no "more" line for a single institution',
      (tester) async {
    await tester.pumpWidget(_wrap(const ImportStalenessBanner(
      stale: [StaleImportInstitution(name: 'Nu México', daysStale: 1)],
    )));
    await tester.pumpAndSettle();
    final text = _allText(tester);
    expect(text,
        contains('Nu México data is 1 day old — import a statement'));
    expect(text, isNot(contains('more institution')));
  });

  testWidgets('tapping the action fires onImport', (tester) async {
    var tapped = false;
    await tester.pumpWidget(_wrap(ImportStalenessBanner(
      stale: _stale,
      onImport: () => tapped = true,
    )));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Import statement'));
    expect(tapped, isTrue);
  });
}
