import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/screens/import_cleanup_screen.dart';
import 'package:patrimonio/utils/currency.dart';

// Smoke + l10n coverage for ImportCleanupScreen's statement-coverage
// section, focused on impContinuityGap — SEVEN same-typed placeholders
// (files, balances, dates, diff), the app's most transposition-prone
// string. Data arrives through the fetch*Override test seams; ApiService
// itself constructs fine under the test VM but would do real HTTP.
const Map<String, Object> _gap = {
  'from_file': 'enero.pdf',
  'from_balance': '1000.50',
  'from_date': '2026-01-31',
  'to_file': 'marzo.pdf',
  'to_balance': '3200.75',
  'to_date': '2026-03-01',
  'diff': '2200.25',
};

Widget _host(Locale locale) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: ImportCleanupScreen(
    fetchBatchesOverride: () async => const [],
    fetchOverviewOverride: () async => {'accounts': <dynamic>[]},
    fetchContinuityOverride: () async => const [
      {
        'account_name': 'Perfiles',
        'institution_name': 'Banamex',
        'statement_count': 5,
        'warnings': [_gap],
      },
    ],
    fetchDismissedGapsOverride: () async => const [],
  ),
);

/// Host whose batch read fails [failures] times before succeeding with an
/// EMPTY result — the pair of states the screen used to render identically.
Widget _flakyHost(Locale locale, {required int failures}) {
  var attempts = 0;
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: ImportCleanupScreen(
      fetchBatchesOverride: () async {
        if (attempts++ < failures) throw Exception('boom');
        return const [];
      },
      fetchOverviewOverride: () async => {'accounts': <dynamic>[]},
      fetchContinuityOverride: () async => const [],
      fetchDismissedGapsOverride: () async => const [],
    ),
  );
}

const _enEmpty =
    'No tracked imports yet. Imports you do from now on appear here '
    'and can be undone.';
const _esEmpty =
    'Aún no hay importaciones registradas. Las que hagas de ahora en '
    'adelante aparecerán aquí y podrás deshacerlas.';

void main() {
  // The screen formats balances as MXN; compute the expected money strings
  // with the same helper so the test pins placement, not symbol trivia.
  final fb = formatCurrencyAmount(1000.50, 'MXN');
  final tb = formatCurrencyAmount(3200.75, 'MXN');
  final df = formatCurrencyAmount(2200.25, 'MXN');

  testWidgets('en: coverage card renders the continuity gap correctly', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const Locale('en')));
    await tester.pumpAndSettle();

    expect(find.text('Statement coverage'), findsOneWidget);
    expect(find.text('Banamex · Perfiles'), findsOneWidget);
    expect(
      find.textContaining(
        'Possible missing statement: ‘enero.pdf’ ends at $fb (2026-01-31), '
        'but ‘marzo.pdf’ opens at $tb (2026-03-01) — an unexplained '
        'difference of $df. A statement covering the period between them '
        'may be missing.',
      ),
      findsOneWidget,
    );
  });

  testWidgets('es: coverage card renders the es-MX continuity gap', (
    tester,
  ) async {
    await tester.pumpWidget(_host(const Locale('es')));
    await tester.pumpAndSettle();

    expect(find.text('Cobertura de estados de cuenta'), findsOneWidget);
    expect(find.text('Banamex · Perfiles'), findsOneWidget);
    expect(
      find.textContaining(
        'Posible estado de cuenta faltante: ‘enero.pdf’ cierra en $fb '
        '(2026-01-31), pero ‘marzo.pdf’ abre en $tb (2026-03-01) — una '
        'diferencia sin explicar de $df. Puede faltar un estado de cuenta '
        'que cubra el periodo entre ellos.',
      ),
      findsOneWidget,
    );
  });

  // A failed load used to fall through to the empty state, so "we couldn't
  // reach the server" rendered as the confident false claim "you have no
  // imports". The assertion that matters is the ABSENCE of that copy.
  group('load failure is not emptiness', () {
    testWidgets('en: failed load shows the error + retry, never "no imports"', (
      tester,
    ) async {
      await tester.pumpWidget(_flakyHost(const Locale('en'), failures: 1));
      await tester.pumpAndSettle();

      expect(find.text("Couldn't load your imports: boom"), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Retry'), findsOneWidget);
      expect(find.text(_enEmpty), findsNothing);
      expect(find.textContaining('No tracked imports'), findsNothing);
    });

    testWidgets('es: failed load shows the es-MX error + retry', (
      tester,
    ) async {
      await tester.pumpWidget(_flakyHost(const Locale('es'), failures: 1));
      await tester.pumpAndSettle();

      expect(
        find.text('No se pudieron cargar tus importaciones: boom'),
        findsOneWidget,
      );
      expect(find.widgetWithText(ElevatedButton, 'Reintentar'), findsOneWidget);
      expect(find.text(_esEmpty), findsNothing);
    });

    testWidgets('retry re-runs the load and reveals the real empty state', (
      tester,
    ) async {
      await tester.pumpWidget(_flakyHost(const Locale('en'), failures: 1));
      await tester.pumpAndSettle();
      expect(find.text("Couldn't load your imports: boom"), findsOneWidget);

      await tester.tap(find.widgetWithText(ElevatedButton, 'Retry'));
      await tester.pumpAndSettle();

      expect(find.textContaining("Couldn't load your imports"), findsNothing);
      expect(find.text(_enEmpty), findsOneWidget);
    });

    testWidgets('en: a successful EMPTY load still shows the empty state', (
      tester,
    ) async {
      await tester.pumpWidget(_flakyHost(const Locale('en'), failures: 0));
      await tester.pumpAndSettle();

      expect(find.text(_enEmpty), findsOneWidget);
      expect(find.textContaining("Couldn't load your imports"), findsNothing);
      expect(find.widgetWithText(ElevatedButton, 'Retry'), findsNothing);
    });

    testWidgets('es: a successful EMPTY load still shows the empty state', (
      tester,
    ) async {
      await tester.pumpWidget(_flakyHost(const Locale('es'), failures: 0));
      await tester.pumpAndSettle();

      expect(find.text(_esEmpty), findsOneWidget);
      expect(
        find.textContaining('No se pudieron cargar tus importaciones'),
        findsNothing,
      );
    });
  });
}
