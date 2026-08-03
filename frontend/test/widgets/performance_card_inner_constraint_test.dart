import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';

import 'package:patrimonio/l10n/app_localizations.dart';
import 'package:patrimonio/services/api_service.dart';
import 'package:patrimonio/utils/chart_touch.dart';
import 'package:patrimonio/widgets/performance_card.dart';

// Regression: the performance card decided its touch-vs-pointer layout — 16
// vs 24px of padding, a 120 vs 150px plot, and whether the money-weighted
// benchmark block collapses behind a tap-to-expand disclosure — from
// `MediaQuery.sizeOf(context).width`. The house rule (skill §4/§5) is that a
// layout branch reads the widget's OWN LayoutBuilder constraint: the card
// lives in a tab column that is one-third of a wide dashboard on some screens
// and full-bleed on others, so the window width says nothing about how much
// room the plot actually has.
//
// The two cases the screen-width version gets exactly backwards are pinned
// here: a narrow card on a wide window (which used to render the 150px
// desktop plot and the inline benchmark block into ~380px of card), and a wide
// card on a small window (which used to be squeezed into the phone layout).

/// Canned GET /benchmark-comparison payload — the shape `_benchmarkSection`
/// reads, with enough invested/lots to make the block render at all.
Map<String, dynamic> _comparisonPayload() => {
  'invested_usd': 103436.0,
  'lot_count': 118,
  'your_value_usd': 110000.0,
  'benchmark_value_usd': 115000.0,
};

/// Dollar-line branch (no TWR): three history points render the plot and the
/// range row, and the comparison payload adds the benchmark block below.
PerformanceCard _card() => PerformanceCard(
  apiService: ApiService(),
  conversionFactor: 1.0,
  currencyFormat: NumberFormat.currency(symbol: r'$'),
  historyFetchOverride: () async => <dynamic>[
    {'date': '2026-01-01', 'value_usd': 100000.0},
    {'date': '2026-02-01', 'value_usd': 110000.0},
    {'date': '2026-03-01', 'value_usd': 120000.0},
  ],
  comparisonFetchOverride: () async => _comparisonPayload(),
  twrFetchOverride: () async => null,
);

/// Hosts the card at an explicit width, INDEPENDENT of the window: the
/// `OverflowBox` hands it a tight [cardWidth] whether that is narrower or
/// wider than the surface. Decoupling the two is the whole point — a host
/// that just sized the window would prove nothing about the constraint.
Widget _host({required double cardWidth}) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Align(
      alignment: Alignment.topLeft,
      child: OverflowBox(
        alignment: Alignment.topLeft,
        minWidth: cardWidth,
        maxWidth: cardWidth,
        child: SingleChildScrollView(child: _card()),
      ),
    ),
  ),
);

void _useSurface(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

/// Height of the value plot — 120 on touch-width cards, 150 otherwise.
double _plotHeight(WidgetTester tester) =>
    tester.getSize(find.byType(TransientTooltipLineChart)).height;

/// Every `Padding` inside the card. The card body has exactly one
/// `EdgeInsets.all`, so this is an unambiguous read of the card's own padding.
Set<EdgeInsetsGeometry> _cardPaddings(WidgetTester tester) => tester
    .widgetList<Padding>(
      find.descendant(of: find.byType(Card), matching: find.byType(Padding)),
    )
    .map((p) => p.padding)
    .toSet();

/// The collapsed benchmark disclosure's chevron — present only in the
/// touch layout (the pointer layout renders the section inline).
final _disclosureChevron = find.byIcon(Icons.expand_more_rounded);

void main() {
  group('PerformanceCard — layout branches off the card constraint', () {
    testWidgets('a narrow card on a WIDE window takes the touch layout', (
      tester,
    ) async {
      // 380px of card on a 1400px window: a dashboard column, a side sheet,
      // a split view. The screen-width version read 1400 here and gave this
      // 380px card desktop padding, a 150px plot and the inline benchmark
      // block — this is the case the fix exists for.
      _useSurface(tester, const Size(1400, 1200));
      await tester.pumpWidget(_host(cardWidth: 380));
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byType(Card)).width,
        moreOrLessEquals(380.0, epsilon: 0.5),
        reason: 'host must hand the card 380px regardless of the window',
      );
      expect(_plotHeight(tester), 120.0, reason: 'short touch-width plot');
      expect(_cardPaddings(tester), contains(const EdgeInsets.all(16.0)));
      expect(
        _cardPaddings(tester),
        isNot(contains(const EdgeInsets.all(24.0))),
      );
      expect(
        _disclosureChevron,
        findsOneWidget,
        reason: 'benchmark block collapses behind the disclosure',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('a wide card on a SMALL window takes the pointer layout', (
      tester,
    ) async {
      // The inverse: 900px of card on a 500px window — a wide sheet or a
      // horizontally scrolled pane. The screen-width version read 500 and
      // squeezed a 900px card into the phone layout.
      _useSurface(tester, const Size(500, 1200));
      await tester.pumpWidget(_host(cardWidth: 900));
      await tester.pumpAndSettle();

      expect(
        tester.getSize(find.byType(Card)).width,
        moreOrLessEquals(900.0, epsilon: 0.5),
      );
      expect(_plotHeight(tester), 150.0, reason: 'full-height pointer plot');
      expect(_cardPaddings(tester), contains(const EdgeInsets.all(24.0)));
      expect(
        _cardPaddings(tester),
        isNot(contains(const EdgeInsets.all(16.0))),
      );
      expect(
        _disclosureChevron,
        findsNothing,
        reason: 'benchmark block renders inline above the breakpoint',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('the branch flips at the card breakpoint, not the window', (
      tester,
    ) async {
      // Same window either side of the change: only the card's own width
      // moves, and it alone decides the layout.
      _useSurface(tester, const Size(1400, 1200));

      await tester.pumpWidget(_host(cardWidth: 719));
      await tester.pumpAndSettle();
      expect(_plotHeight(tester), 120.0, reason: '719px card is touch-width');

      await tester.pumpWidget(_host(cardWidth: 720));
      await tester.pumpAndSettle();
      expect(_plotHeight(tester), 150.0, reason: '720px card is pointer-width');
      expect(tester.takeException(), isNull);
    });
  });
}
