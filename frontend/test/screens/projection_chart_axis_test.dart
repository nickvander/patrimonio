import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'projection_test_host.dart';

// F7: the chart's bottom axis used a fixed interval of 5 years, which
// overlaps labels on a phone with a 50-year horizon. The step now adapts to
// the inner plot width (via utils/projection_axis.dart).

/// Rects of all rendered bottom-axis labels ("Yr N").
List<Rect> _yearLabelRects(WidgetTester tester) {
  final finder = find.byWidgetPredicate((w) =>
      w is Text && w.data != null && RegExp(r'^Yr \d+$').hasMatch(w.data!));
  return [for (final e in finder.evaluate()) tester.getRect(find.byWidget(e.widget))];
}

void main() {
  testWidgets('phone 390px, 50-year horizon: at most 7 labels, none '
      'overlapping', (tester) async {
    setTestSize(tester, const Size(390, 844));
    await tester.pumpWidget(buildProjectionHost());
    await tester.pumpAndSettle();

    // Reveal the advanced controls and push the horizon to 50 years.
    final advanced = find.text('Advanced assumptions');
    await tester.ensureVisible(advanced);
    await tester.pumpAndSettle();
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    final yearsLabel = find.text('Projection years');
    await tester.ensureVisible(yearsLabel);
    await tester.pumpAndSettle();
    final slider = find.descendant(
      of: find
          .ancestor(of: yearsLabel, matching: find.byType(MergeSemantics))
          .first,
      matching: find.byType(Slider),
    );
    await tester.drag(slider, const Offset(600, 0));
    // F14: the commit is debounced ~300ms — let the fetch fire.
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pumpAndSettle();
    expect(find.text('50'), findsWidgets); // horizon is now 50 years

    final rects = _yearLabelRects(tester);
    expect(rects.length, greaterThanOrEqualTo(2));
    expect(rects.length, lessThanOrEqualTo(7));
    // No horizontal overlap between adjacent labels.
    rects.sort((a, b) => a.left.compareTo(b.left));
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i].left, greaterThanOrEqualTo(rects[i - 1].right),
          reason: 'labels $i and ${i - 1} overlap');
    }
  });

  testWidgets('wide 1200px, 30-year horizon: at least 5 labels',
      (tester) async {
    setTestSize(tester, const Size(1200, 1600));
    await tester.pumpWidget(buildProjectionHost());
    await tester.pumpAndSettle();

    final rects = _yearLabelRects(tester);
    expect(rects.length, greaterThanOrEqualTo(5));
    rects.sort((a, b) => a.left.compareTo(b.left));
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i].left, greaterThanOrEqualTo(rects[i - 1].right));
    }
  });
}
