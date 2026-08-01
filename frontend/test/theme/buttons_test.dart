import 'package:flutter_test/flutter_test.dart';
import 'package:patrimonio/theme/buttons.dart';

/// Pins the rule that action buttons stop stretching once there is pointer
/// room. The bug: the Add-accounts grid used `(maxWidth - 16) / 2` and
/// "Sync all accounts" used `width: double.infinity`, so at a 1440px window
/// they rendered as a 565px and a 1650px slab respectively.
void main() {
  group('actionButtonWidth', () {
    test('touch-width cards stay full-bleed', () {
      // Phone card inner width — stacked, edge to edge, as before.
      expect(actionButtonWidth(342), 342);
      expect(
        actionButtonWidth(kActionButtonStackBelow - 1),
        kActionButtonStackBelow - 1,
      );
    });

    test('pointer-width cards size to content', () {
      expect(actionButtonWidth(kActionButtonStackBelow), isNull);
      // The regression: the Settings card at a 1440px window.
      expect(actionButtonWidth(1650), isNull);
    });
  });

  group('actionButtonConstraints', () {
    test('touch-width cards get a tight full-bleed width', () {
      final c = actionButtonConstraints(342);
      expect(c.minWidth, 342);
      expect(c.maxWidth, 342);
    });

    test('pointer-width cards are bounded, never stretched', () {
      final c = actionButtonConstraints(1650);
      expect(c.minWidth, kActionButtonMinWidth);
      expect(c.maxWidth, kActionButtonMaxWidth);
      // The old rule would have produced (1650 - 16) / 2 = 817.
      expect(c.maxWidth, lessThan(817));
    });

    test('a long es-MX label cannot reintroduce the stretch', () {
      // Whatever the card width, a content-sized button is capped.
      for (final available in <double>[520, 900, 1440, 2560]) {
        expect(
          actionButtonConstraints(available).maxWidth,
          kActionButtonMaxWidth,
          reason: 'card inner width $available',
        );
      }
    });
  });
}
