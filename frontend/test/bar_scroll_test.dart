import 'package:flutter/material.dart' show Axis, kToolbarHeight;
import 'package:flutter/rendering.dart' show ScrollDirection;
import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/utils/bar_scroll.dart';

void main() {
  group('barVisibleAfter', () {
    test('ignores horizontal scrollables entirely (chip/period rows)', () {
      for (final direction in ScrollDirection.values) {
        for (final pixels in [-20.0, 0.0, 10.0, 500.0]) {
          expect(
            barVisibleAfter(
              direction: direction,
              axis: Axis.horizontal,
              pixels: pixels,
            ),
            isNull,
            reason: 'horizontal $direction @ $pixels must not toggle the bar',
          );
        }
      }
    });

    test('pixels <= 0 forces visible regardless of direction '
        '(pull-to-refresh guard)', () {
      for (final direction in ScrollDirection.values) {
        for (final pixels in [0.0, -0.1, -80.0]) {
          expect(
            barVisibleAfter(
              direction: direction,
              axis: Axis.vertical,
              pixels: pixels,
            ),
            isTrue,
            reason: '$direction @ $pixels must force the bar visible',
          );
        }
      }
    });

    test('reverse (scrolling down) hides only past kToolbarHeight', () {
      expect(
        barVisibleAfter(
          direction: ScrollDirection.reverse,
          axis: Axis.vertical,
          pixels: kToolbarHeight + 1,
        ),
        isFalse,
      );
      // At or below the threshold: no change (tiny nudges near the top
      // don't collapse the bar).
      expect(
        barVisibleAfter(
          direction: ScrollDirection.reverse,
          axis: Axis.vertical,
          pixels: kToolbarHeight,
        ),
        isNull,
      );
      expect(
        barVisibleAfter(
          direction: ScrollDirection.reverse,
          axis: Axis.vertical,
          pixels: 1,
        ),
        isNull,
      );
    });

    test('forward (scrolling back up) always shows', () {
      for (final pixels in [1.0, kToolbarHeight, 2000.0]) {
        expect(
          barVisibleAfter(
            direction: ScrollDirection.forward,
            axis: Axis.vertical,
            pixels: pixels,
          ),
          isTrue,
        );
      }
    });

    test('idle is a no-op when scrolled', () {
      for (final pixels in [1.0, kToolbarHeight + 100]) {
        expect(
          barVisibleAfter(
            direction: ScrollDirection.idle,
            axis: Axis.vertical,
            pixels: pixels,
          ),
          isNull,
        );
      }
    });
  });
}
