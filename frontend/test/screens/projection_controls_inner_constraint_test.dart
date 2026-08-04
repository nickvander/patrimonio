// The assumptions card's density must follow the width it was GIVEN, not the
// window (skill §4/§5).
//
// On the wide layout `_buildControls` is hosted in a fixed `SizedBox(width:
// 320)` sidebar. Reading `MediaQuery.sizeOf(context).width` there meant that
// on a 1440px window the card spent 24px of padding and 32px dividers inside
// a 320px column — an ACTIVE wrong branch on every desktop window, the same
// shape as the loan_detail_sheet defect.
//
// The deliberate exception is pinned here too: the wide sidebar passes
// `collapseAdvancedWhenNarrow: false`, so the advanced sliders stay inline
// there. Its own width says "narrow", but it is a full-height pointer surface
// with an always-visible scrollbar (F9) — hiding 9 of 12 controls behind a
// disclosure would be a discoverability regression, not a fix.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'projection_test_host.dart';

/// Every `Divider` height on screen. `_buildControls` is the only place that
/// emits a divider taller than 1px, so this reads its `divH` unambiguously.
Set<double?> _dividerHeights(WidgetTester tester) => tester
    .widgetList<Divider>(find.byType(Divider))
    .map((d) => d.height)
    .toSet();

/// The `EdgeInsetsGeometry` on every `Padding` inside the assumptions card.
/// The card is located by its `Scrollbar` — no other card on the screen has
/// one.
Set<EdgeInsetsGeometry> _controlsPaddings(WidgetTester tester) => tester
    .widgetList<Padding>(
      find.descendant(
        of: find
            .ancestor(of: find.byType(Scrollbar), matching: find.byType(Card))
            .first,
        matching: find.byType(Padding),
      ),
    )
    .map((p) => p.padding)
    .toSet();

void main() {
  testWidgets('the 320px desktop sidebar takes the dense layout', (
    tester,
  ) async {
    // 1400px window → the two-column layout → the controls live in a fixed
    // 320px sidebar. The MediaQuery version read 1400 here.
    setTestSize(tester, const Size(1400, 1000));
    await tester.pumpWidget(buildProjectionHost());
    await tester.pumpAndSettle();

    expect(
      tester
          .getSize(
            find
                .ancestor(
                  of: find.byType(Scrollbar),
                  matching: find.byType(Card),
                )
                .first,
          )
          .width,
      moreOrLessEquals(320.0, epsilon: 1.0),
      reason: 'the sidebar is 320px wide however wide the window is',
    );
    expect(
      _dividerHeights(tester),
      contains(20.0),
      reason: 'dense 20px dividers in a 320px column',
    );
    expect(_dividerHeights(tester), isNot(contains(32.0)));
    expect(_controlsPaddings(tester), contains(const EdgeInsets.all(16.0)));
    expect(
      _controlsPaddings(tester),
      isNot(contains(const EdgeInsets.all(24.0))),
    );

    // The deliberate exception: the sidebar keeps every slider inline.
    expect(
      find.text('Advanced assumptions'),
      findsNothing,
      reason:
          'the wide sidebar passes collapseAdvancedWhenNarrow: false — see '
          'the doc comment on _buildControls',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('a full-width controls card above ~720 keeps the roomy layout', (
    tester,
  ) async {
    // 790px window → below the 800px two-column threshold, so the controls
    // stack full-width at 790 — wider than the ~720 density breakpoint.
    setTestSize(tester, const Size(790, 1400));
    await tester.pumpWidget(buildProjectionHost());
    await tester.pumpAndSettle();

    expect(
      _dividerHeights(tester),
      contains(32.0),
      reason: '790px of card is a roomy layout',
    );
    expect(_dividerHeights(tester), isNot(contains(20.0)));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a phone-width controls card takes the dense layout + disclosure',
    (tester) async {
      setTestSize(tester, const Size(420, 1400));
      await tester.pumpWidget(buildProjectionHost());
      await tester.pumpAndSettle();

      expect(_dividerHeights(tester), contains(20.0));
      expect(_dividerHeights(tester), isNot(contains(32.0)));
      expect(
        find.text('Advanced assumptions'),
        findsOneWidget,
        reason: 'the stacked layout still collapses the advanced sliders',
      );
      expect(tester.takeException(), isNull);
    },
  );
}
