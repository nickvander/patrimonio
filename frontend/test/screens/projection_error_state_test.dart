import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'projection_test_host.dart';

// F2: a failed projection fetch used to only debugPrint — the chart card
// rendered an empty Container and the FIRE strip/milestones shrank away,
// leaving a silently blank screen. Now the card explains the failure and
// offers a retry.

void main() {
  Future<void> runCase(
    WidgetTester tester, {
    required Locale locale,
    required String message,
    required String retryLabel,
  }) async {
    setTestSize(tester, const Size(1200, 900));
    var fail = true;
    final fetcher = fixtureFetcher((years) {
      if (fail) throw Exception('boom');
      return projectionFixture(years: years);
    });

    await tester.pumpWidget(
      buildProjectionHost(projectionFetcher: fetcher, locale: locale),
    );
    await tester.pumpAndSettle();

    // Error text + retry button visible; no chart.
    expect(find.text(message), findsOneWidget);
    expect(find.text(retryLabel), findsOneWidget);
    expect(find.byType(LineChart), findsNothing);

    // Tapping retry with a now-succeeding fetcher renders the chart.
    fail = false;
    await tester.tap(find.text(retryLabel));
    await tester.pumpAndSettle();
    expect(find.byType(LineChart), findsOneWidget);
    expect(find.text(message), findsNothing);
  }

  testWidgets('en: failed load shows message + retry; retry recovers', (
    tester,
  ) async {
    await runCase(
      tester,
      locale: const Locale('en'),
      message: "Couldn't load your projection.",
      retryLabel: 'Retry',
    );
  });

  testWidgets('es: failed load shows message + retry; retry recovers', (
    tester,
  ) async {
    await runCase(
      tester,
      locale: const Locale('es'),
      message: 'No se pudo cargar tu proyección.',
      retryLabel: 'Reintentar',
    );
  });
}
