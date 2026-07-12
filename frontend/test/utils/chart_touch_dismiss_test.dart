import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/utils/chart_touch.dart';

// House standard: chart tooltips are transient scrub indicators — visible
// while hovering (mouse/trackpad) or while the finger is down, dismissed on
// pointer exit / release / gesture end. `chartTouchDismisses` is the single
// gate every chart (line + bar) routes through.
//
// The regression pinned here: fl_chart's own
// `FlTouchEvent.isInterestedForInteractions` keeps FlTapUpEvent "interested"
// on web/desktop so a mouse click doesn't blank the hover tooltip — but a
// FINGER on mobile web hits the same carve-out, and touch pointers never emit
// a later FlPointerExitEvent, so the tooltip stayed pinned forever after the
// finger lifted (the prod TWR-chart bug). The predicate must dismiss a
// touch/stylus tap-up even on those platforms, while a mouse tap-up keeps the
// tooltip (the still-hovering pointer's exit event clears it later).

FlTapUpEvent _tapUp(PointerDeviceKind kind) =>
    FlTapUpEvent(TapUpDetails(kind: kind));

void main() {
  group('chartTouchDismisses — desktop/web-like platform (the carve-out '
      'fl_chart applies on kIsWeb and desktop)', () {
    setUp(() {
      // fl_chart gates isInterestedForInteractions on kIsWeb OR a desktop
      // defaultTargetPlatform; the test VM can't set kIsWeb, so macOS stands
      // in for the identical "tap-up stays interested" branch mobile web hits.
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('finger lift (touch tap-up) dismisses — the pinned-tooltip bug', () {
      // Sanity: this is exactly the case fl_chart keeps "interested" —
      // proving the built-in gate alone would leave the tooltip pinned.
      expect(_tapUp(PointerDeviceKind.touch).isInterestedForInteractions,
          isTrue);
      expect(chartTouchDismisses(_tapUp(PointerDeviceKind.touch)), isTrue);
    });

    test('stylus tap-up dismisses (cannot hover; no exit event will come)',
        () {
      expect(chartTouchDismisses(_tapUp(PointerDeviceKind.stylus)), isTrue);
    });

    test('mouse click (tap-up) does NOT dismiss — the pointer is still '
        'hovering and its exit event clears the tooltip later', () {
      expect(chartTouchDismisses(_tapUp(PointerDeviceKind.mouse)), isFalse);
      expect(chartTouchDismisses(_tapUp(PointerDeviceKind.trackpad)), isFalse);
    });

    test('pointer exit / gesture ends dismiss; presses and hovers do not',
        () {
      // Dismissals: exit, pan end/cancel, long-press end, tap cancel.
      expect(
        chartTouchDismisses(const FlPointerExitEvent(PointerExitEvent())),
        isTrue,
      );
      expect(chartTouchDismisses(FlPanEndEvent(DragEndDetails())), isTrue);
      expect(chartTouchDismisses(const FlPanCancelEvent()), isTrue);
      expect(
        chartTouchDismisses(const FlLongPressEnd(LongPressEndDetails())),
        isTrue,
      );
      expect(chartTouchDismisses(const FlTapCancelEvent()), isTrue);

      // Non-dismissals: the tooltip must stay up while scrubbing/hovering.
      expect(
        chartTouchDismisses(FlPanDownEvent(DragDownDetails())),
        isFalse,
      );
      expect(
        chartTouchDismisses(FlPanUpdateEvent(DragUpdateDetails(
          globalPosition: Offset.zero,
        ))),
        isFalse,
      );
      expect(
        chartTouchDismisses(FlTapDownEvent(TapDownDetails())),
        isFalse,
      );
      expect(
        chartTouchDismisses(const FlPointerHoverEvent(
            PointerHoverEvent(kind: PointerDeviceKind.mouse))),
        isFalse,
      );
    });

    test('synthesized hover/enter from a lifted TOUCH pointer dismisses — '
        'Flutter web emits one right after tap-up and no exit ever follows, '
        'which re-pinned the tooltip (verify4 repro)', () {
      // PointerHoverEvent/PointerEnterEvent default to kind: touch — exactly
      // what the web pointer pipeline synthesizes after a finger lifts.
      expect(
        chartTouchDismisses(const FlPointerHoverEvent(PointerHoverEvent())),
        isTrue,
      );
      expect(
        chartTouchDismisses(const FlPointerEnterEvent(PointerEnterEvent())),
        isTrue,
      );
      // Stylus can't hover on web either.
      expect(
        chartTouchDismisses(const FlPointerHoverEvent(
            PointerHoverEvent(kind: PointerDeviceKind.stylus))),
        isTrue,
      );
      // Real mouse/trackpad hover keeps showing.
      expect(
        chartTouchDismisses(const FlPointerEnterEvent(
            PointerEnterEvent(kind: PointerDeviceKind.mouse))),
        isFalse,
      );
      expect(
        chartTouchDismisses(const FlPointerHoverEvent(
            PointerHoverEvent(kind: PointerDeviceKind.trackpad))),
        isFalse,
      );
    });
  });

  group('chartTouchDismisses — mobile platform (no carve-out)', () {
    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
    });

    test('every tap-up dismisses, regardless of pointer kind', () {
      expect(chartTouchDismisses(_tapUp(PointerDeviceKind.touch)), isTrue);
      // Even a mouse tap-up: on native mobile fl_chart itself treats it as
      // not-interested, and the predicate must never be MORE sticky than
      // the built-in gate.
      expect(chartTouchDismisses(_tapUp(PointerDeviceKind.mouse)), isTrue);
    });
  });
}
