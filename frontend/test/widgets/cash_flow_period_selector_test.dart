import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/widgets/cash_flow_period_selector.dart';
import 'package:patrimonio/widgets/connected_segments.dart';

/// Pins the Cash flow period picker's restyle: one row of the house
/// ConnectedSegments at every width — never the old horizontally
/// scrolling ChoiceChips, which could hide the selected period
/// off-screen on a phone. Narrow hosts get compact bilingual labels
/// (the full "Últimos 3 meses" / "En lo que va del año" measure wider
/// than a phone-width segment); wide hosts keep the full labels.
/// Interaction contract is unchanged: taps report through `onChanged`,
/// re-tapping the current period is a no-op, and the group is inert
/// while a period fetch is in flight (`enabled: false`).
void main() {
  Widget host({
    required double width,
    required CashFlowPeriod selected,
    required List<CashFlowPeriod> taps,
    bool enabled = true,
    Locale locale = const Locale('en'),
  }) {
    return MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: width,
            child: CashFlowPeriodSelector(
              selected: selected,
              enabled: enabled,
              onChanged: taps.add,
            ),
          ),
        ),
      ),
    );
  }

  group('CashFlowPeriodSelector — structure', () {
    testWidgets('renders the house ConnectedSegments, never ChoiceChips '
        'or a horizontal scroller', (tester) async {
      await tester.pumpWidget(
        host(width: 358, selected: CashFlowPeriod.thisMonth, taps: []),
      );
      await tester.pumpAndSettle();

      expect(find.byType(ConnectedSegments<CashFlowPeriod>), findsOneWidget);
      expect(find.byType(ChoiceChip), findsNothing);
      expect(find.byType(SingleChildScrollView), findsNothing);
    });

    testWidgets('narrow host uses compact en labels (full long labels '
        'would ellipsize)', (tester) async {
      // 358 = a 390px phone minus the dashboard's 16px outer padding.
      await tester.pumpWidget(
        host(width: 358, selected: CashFlowPeriod.thisMonth, taps: []),
      );
      await tester.pumpAndSettle();

      expect(find.text('This month'), findsOneWidget);
      expect(find.text('Last month'), findsOneWidget);
      expect(find.text('3 months'), findsOneWidget);
      expect(find.text('This year'), findsOneWidget);
      expect(find.text('Last 3 months'), findsNothing);
      expect(find.text('Year to date'), findsNothing);
    });

    testWidgets('narrow host uses compact es-MX labels', (tester) async {
      await tester.pumpWidget(
        host(
          width: 358,
          selected: CashFlowPeriod.thisMonth,
          taps: [],
          locale: const Locale('es'),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Este mes'), findsOneWidget);
      expect(find.text('Último mes'), findsOneWidget);
      expect(find.text('3 meses'), findsOneWidget);
      expect(find.text('Este año'), findsOneWidget);
      expect(find.text('Últimos 3 meses'), findsNothing);
      expect(find.text('En lo que va del año'), findsNothing);
    });

    testWidgets('wide host keeps the full labels (en and es)', (tester) async {
      await tester.pumpWidget(
        host(width: 600, selected: CashFlowPeriod.thisMonth, taps: []),
      );
      await tester.pumpAndSettle();
      expect(find.text('Last 3 months'), findsOneWidget);
      expect(find.text('Year to date'), findsOneWidget);
      expect(find.text('3 months'), findsNothing);

      await tester.pumpWidget(
        host(
          width: 600,
          selected: CashFlowPeriod.thisMonth,
          taps: [],
          locale: const Locale('es'),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Últimos 3 meses'), findsOneWidget);
      expect(find.text('En lo que va del año'), findsOneWidget);
      expect(find.text('3 meses'), findsNothing);
    });
  });

  group('CashFlowPeriodSelector — behavior', () {
    testWidgets('tapping another period reports it once', (tester) async {
      final taps = <CashFlowPeriod>[];
      await tester.pumpWidget(
        host(width: 358, selected: CashFlowPeriod.thisMonth, taps: taps),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('3 months'));
      await tester.pumpAndSettle();
      expect(taps, [CashFlowPeriod.threeMonths]);

      await tester.tap(find.text('This year'));
      await tester.pumpAndSettle();
      expect(taps, [CashFlowPeriod.threeMonths, CashFlowPeriod.ytd]);
    });

    testWidgets('re-tapping the selected period is a no-op', (tester) async {
      final taps = <CashFlowPeriod>[];
      await tester.pumpWidget(
        host(width: 358, selected: CashFlowPeriod.thisMonth, taps: taps),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('This month'));
      await tester.pumpAndSettle();
      expect(taps, isEmpty);
    });

    testWidgets('disabled while loading: taps do nothing', (tester) async {
      final taps = <CashFlowPeriod>[];
      await tester.pumpWidget(
        host(
          width: 358,
          selected: CashFlowPeriod.thisMonth,
          taps: taps,
          enabled: false,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('3 months'));
      await tester.tap(find.text('Last month'));
      await tester.pumpAndSettle();
      expect(taps, isEmpty);
    });
  });
}
