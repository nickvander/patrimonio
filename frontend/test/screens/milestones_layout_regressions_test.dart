import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'projection_test_host.dart';

// F1 regressions — the app owner's reported bug: milestone tiles must paint
// everywhere, and the page must scroll when the content doesn't fit.
//
//  * Phone (390×844): the 2×2 milestone rows used to be unbounded stretch-Rows
//    inside the SingleChildScrollView — the tiles blew up to ~676px, never
//    painted, and left a ~1,700px blank void at the end of the page.
//  * Desktop (1440×~760 inner height): the flex-fit estimate omitted the
//    ~220px tile row, so the non-scrollable flex branch was chosen and the
//    OverflowBox painted tiles past the window edge with no way to scroll.
//  * 720–800px band: milestones stacked at <720 while the narrow layout cut
//    over at <800, so a clipped 4-up row wrapped currency mid-number.

void main() {
  testWidgets('phone 390x844: all 4 milestone tiles paint at the end of the '
      'scroll, with no blank void', (tester) async {
    setTestSize(tester, const Size(390, 844));
    await tester.pumpWidget(buildProjectionHost());
    await tester.pumpAndSettle();

    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    // Regression guard: the unbounded-tile bug inflated the content by well
    // over 1,700px of blank space.
    expect(position.maxScrollExtent, lessThan(2200));

    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();

    // All four tile titles visible in the viewport after scrolling to the
    // end ('FI number' also appears as a glossary term earlier in the tree,
    // so take the last match).
    for (final title in ['Success rate', 'FI number', 'Years to FI', 'FI income']) {
      final f = find.text(title).last;
      expect(f, findsOneWidget, reason: 'missing tile title: $title');
      final rect = tester.getRect(f);
      expect(rect.top, greaterThanOrEqualTo(0), reason: '$title above viewport');
      expect(rect.bottom, lessThanOrEqualTo(844), reason: '$title below viewport');
    }

    // No blank void: the last tile's card ends near the bottom of the
    // scrolled content (within 200px of the viewport bottom at max extent).
    final lastTile = find
        .ancestor(of: find.text('FI income'), matching: find.byType(Card))
        .first;
    expect(tester.getRect(lastTile).bottom, greaterThan(844 - 200));

    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop 1440x760: page scrolls (or tiles fit) and the chart '
      'plot keeps >=200px', (tester) async {
    setTestSize(tester, const Size(1440, 760));
    await tester.pumpWidget(buildProjectionHost());
    await tester.pumpAndSettle();

    // The chart plot area must stay readable.
    final chart = find.byType(LineChart);
    expect(chart, findsOneWidget);
    expect(tester.getSize(chart).height, greaterThanOrEqualTo(200.0));

    // Either every tile is already hit-testable, or the right column can
    // scroll them into view — never clipped past the window edge.
    final successTile = find.text('Success rate');
    expect(successTile, findsOneWidget);
    await tester.ensureVisible(successTile);
    await tester.pumpAndSettle();
    final rect = tester.getRect(successTile);
    expect(rect.bottom, lessThanOrEqualTo(760));
    expect(rect.top, greaterThanOrEqualTo(0));

    expect(tester.takeException(), isNull);
  });

  testWidgets('760px width (720-800 band): milestones stack 2x2 and the FI '
      'number renders on one line', (tester) async {
    setTestSize(tester, const Size(760, 1400));
    await tester.pumpWidget(buildProjectionHost());
    await tester.pumpAndSettle();

    // Scroll the (narrow-layout) page down to the tiles.
    final position = tester
        .state<ScrollableState>(find.byType(Scrollable).first)
        .position;
    position.jumpTo(position.maxScrollExtent);
    await tester.pumpAndSettle();

    // The FI-number tile is identified by its unique subtitle; its currency
    // value must render on a single line (a wrapped "$1,000,\n000" was the
    // 720-800px-band defect).
    final tile = find
        .ancestor(of: find.text('Target net worth'), matching: find.byType(Card))
        .first;
    final value =
        find.descendant(of: tile, matching: find.text(r'$1,000,000'));
    expect(value, findsOneWidget);
    final paragraph = tester.renderObject<RenderParagraph>(value);
    // A single line of the 20px tile-value style is ~23px; two lines ~46.
    expect(paragraph.size.height, lessThan(30));

    // Stacked 2×2: the Success-rate and FI-number tiles share a row (same
    // vertical band), and the Years-to-FI tile sits on the next row.
    final successTop = tester
        .getTopLeft(find
            .ancestor(
                of: find.text('Success rate'), matching: find.byType(Card))
            .first)
        .dy;
    final fiTop = tester.getTopLeft(tile).dy;
    final yearsTop = tester
        .getTopLeft(find
            .ancestor(
                of: find.text('Years to FI').last,
                matching: find.byType(Card))
            .first)
        .dy;
    expect((successTop - fiTop).abs(), lessThan(1.0));
    expect(yearsTop, greaterThan(successTop + 100));

    expect(tester.takeException(), isNull);
  });

  // F9: the desktop controls column shows an always-visible scrollbar so the
  // fold is discoverable.
  testWidgets('desktop controls column has a visible scrollbar', (tester) async {
    setTestSize(tester, const Size(1440, 700));
    await tester.pumpWidget(buildProjectionHost());
    await tester.pumpAndSettle();

    final controlsCard = find
        .ancestor(of: find.text('Monthly savings'), matching: find.byType(Card))
        .first;
    final scrollbar = find.descendant(
        of: controlsCard, matching: find.byType(Scrollbar));
    expect(scrollbar, findsOneWidget);
    expect(tester.widget<Scrollbar>(scrollbar).thumbVisibility, isTrue);
  });
}
