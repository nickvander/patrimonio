import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/components/date_range_selector.dart';
import 'package:patrimonio/l10n/app_localizations.dart';

// The 1M / YTD / 1Y / 5Y / ALL selector under the net-worth chart.
//
// Pinned here: on phones the selector is the only thing on its line, and
// `MainAxisSize.min` left it hugging its own labels — a stubby pill covering
// roughly 60% of the card with dead space beside it, its five segments each a
// different width because "YTD" is wider than "1M". `fill: true` divides the
// available width evenly instead. The content-sized default still has to work,
// because that is what the wide header and the Performance card's row need.

const double _hostWidth = 360;

/// LOOSE width, deliberately — that is what the net-worth card's Column
/// (`crossAxisAlignment: start`) hands the selector, and it is the whole
/// reason the un-filled version shrink-wraps into a stub. A tight `SizedBox`
/// here would force even a `MainAxisSize.min` Row to span the parent and the
/// test would prove nothing.
Widget _host(Widget child, {Locale? locale}) => MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: _hostWidth),
            child: child,
          ),
        ),
      ),
    );

DateRangeSelector _selector({required bool fill}) => DateRangeSelector(
      fill: fill,
      selectedRange: DateRange.oneMonth,
      onRangeChanged: (_) {},
    );

/// Width of every segment's tappable box, in layout order.
List<double> _segmentWidths(WidgetTester tester) => tester
    .widgetList<InkWell>(find.descendant(
      of: find.byType(DateRangeSelector),
      matching: find.byType(InkWell),
    ))
    .map((w) => tester.getSize(find.byWidget(w)).width)
    .toList();

void main() {
  group('DateRangeSelector — fill', () {
    testWidgets('filling divides the available width evenly', (tester) async {
      await tester.pumpWidget(_host(_selector(fill: true)));

      final widths = _segmentWidths(tester);
      expect(widths, hasLength(5), reason: 'all five ranges are offered');
      for (final w in widths) {
        expect(
          w,
          moreOrLessEquals(widths.first, epsilon: 0.5),
          reason: 'segments are equal cells, not label-hugging chips: $widths',
        );
      }

      // …and the control spans its parent rather than shrink-wrapping, so
      // there is no dead space to its right.
      expect(
        tester.getSize(find.byType(DateRangeSelector)).width,
        moreOrLessEquals(_hostWidth, epsilon: 0.5),
      );
    });

    testWidgets('the selected pill fills its cell when filling',
        (tester) async {
      await tester.pumpWidget(_host(_selector(fill: true)));

      // The 1M pill (selected) is as wide as its segment minus the segment's
      // own inset — i.e. it reads as one cell of a segmented control, not a
      // chip floating inside one.
      final cell = _segmentWidths(tester).first;
      final pill = tester
          .getSize(find.ancestor(
            of: find.text('1M'),
            matching: find.byType(AnimatedContainer),
          ))
          .width;
      expect(pill, moreOrLessEquals(cell, epsilon: 0.5));
    });

    testWidgets('content-sized is unchanged: segments size to their labels',
        (tester) async {
      await tester.pumpWidget(_host(_selector(fill: false)));

      final widths = _segmentWidths(tester);
      expect(widths, hasLength(5));
      // "YTD" is a wider label than "1M", so the default must NOT equalise —
      // the wide header and the Performance card rely on intrinsic sizing.
      expect(
        widths.toSet().length,
        greaterThan(1),
        reason: 'default stays label-sized: $widths',
      );
      expect(
        tester.getSize(find.byType(DateRangeSelector)).width,
        lessThan(_hostWidth),
        reason: 'and shrink-wraps rather than spanning the parent',
      );
    });

    testWidgets('es-MX labels fit a filled phone-width selector',
        (tester) async {
      // "Todo" is the longest label in either locale; at a fifth of a phone
      // card it must render whole, not ellipsised.
      await tester.pumpWidget(
        _host(_selector(fill: true), locale: const Locale('es')),
      );

      expect(find.text('Todo'), findsOneWidget);
      final label = tester.widget<Text>(find.text('Todo'));
      expect(label.overflow, TextOverflow.ellipsis,
          reason: 'guarded against a future longer translation');
      final painted = tester.getSize(find.text('Todo')).width;
      final cell = _segmentWidths(tester).first;
      expect(painted, lessThan(cell),
          reason: 'the longest label still fits its cell: $painted vs $cell');
    });
  });
}
