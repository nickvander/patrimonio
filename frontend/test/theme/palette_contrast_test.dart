import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:patrimonio/theme/palette.dart';

// WCAG 2.x acceptance:
//   AA normal text  ≥ 4.5
//   AA large text   ≥ 3.0
//   AAA normal text ≥ 7.0
//
// Body and subtitle accents must hit AA-normal against the surface they
// land on; small-text accents (chart axis labels, captions) get the
// AA-large allowance. The palette is the single source of truth — if a
// new theme variant is added, these tests force whoever writes it to
// pick AA-compliant colours.
void main() {
  group('BrandPalette — light theme on white card', () {
    const bg = Colors.white;
    const b = Brightness.light;

    test('positive accent passes AA on white', () {
      expect(contrastRatio(BrandPalette.positive(b), bg), greaterThan(4.5));
    });

    test('negative accent passes AA on white', () {
      expect(contrastRatio(BrandPalette.negative(b), bg), greaterThan(4.5));
    });

    test('warning accent passes AA on white', () {
      expect(contrastRatio(BrandPalette.warning(b), bg), greaterThan(4.5));
    });

    test('info accent passes AA on white', () {
      expect(contrastRatio(BrandPalette.info(b), bg), greaterThan(4.5));
    });

    test('teal accent passes AA on white', () {
      expect(contrastRatio(BrandPalette.teal(b), bg), greaterThan(4.5));
    });

    test('pink accent passes AA on white', () {
      expect(contrastRatio(BrandPalette.pink(b), bg), greaterThan(4.5));
    });

    test('purple accent passes AA on white', () {
      expect(contrastRatio(BrandPalette.purple(b), bg), greaterThan(4.5));
    });

    test('yellow accent passes AA-large on white', () {
      // Yellow is the only accent we accept at AA-large — a true
      // AA-normal yellow is too dark to read as "yellow." We use this
      // colour exclusively for goal lines + flag icons (large
      // graphical elements), never for body text.
      expect(contrastRatio(BrandPalette.yellow(b), bg), greaterThan(3.0));
    });

    test('neutral accent passes AA on white', () {
      expect(contrastRatio(BrandPalette.neutral(b), bg), greaterThan(4.5));
    });
  });

  group('BrandPalette — dark theme on charcoal card', () {
    final bg = BrandPalette.cardSurface(Brightness.dark);
    const b = Brightness.dark;

    test('positive accent passes AA on dark card', () {
      expect(contrastRatio(BrandPalette.positive(b), bg), greaterThan(4.5));
    });

    test('negative accent passes AA on dark card', () {
      expect(contrastRatio(BrandPalette.negative(b), bg), greaterThan(4.5));
    });

    test('info accent passes AA on dark card', () {
      expect(contrastRatio(BrandPalette.info(b), bg), greaterThan(4.5));
    });

    test('teal accent passes AA on dark card', () {
      expect(contrastRatio(BrandPalette.teal(b), bg), greaterThan(4.5));
    });

    test('warning accent passes AA on dark card', () {
      expect(contrastRatio(BrandPalette.warning(b), bg), greaterThan(4.5));
    });

    test('yellow accent passes AA on dark card', () {
      // On dark surfaces yellow is bright enough to hit AA-normal too,
      // so we hold it to the same bar there.
      expect(contrastRatio(BrandPalette.yellow(b), bg), greaterThan(4.5));
    });
  });

  group('Chart series colours are AA on their target surface', () {
    test('light-theme series on white passes AA', () {
      for (final c in BrandPalette.chartSeries(Brightness.light)) {
        expect(
          contrastRatio(c, Colors.white),
          greaterThan(4.5),
          reason: 'series colour $c on white',
        );
      }
    });

    test('dark-theme series on charcoal card passes AA', () {
      final bg = BrandPalette.cardSurface(Brightness.dark);
      for (final c in BrandPalette.chartSeries(Brightness.dark)) {
        expect(
          contrastRatio(c, bg),
          greaterThan(4.5),
          reason: 'series colour $c on dark card',
        );
      }
    });
  });

  group('onAccent label picks the AA-clearing foreground', () {
    // Mirrors ThemeColorsExt.onAccent: whichever of black/white has the
    // higher contrast against the accent fill. The accent-button bug was a
    // hard-coded label that only cleared AA in one theme.
    Color onAccent(Color accent) =>
        contrastRatio(Colors.white, accent) >= contrastRatio(Colors.black, accent)
            ? Colors.white
            : Colors.black;

    test('onAccent clears AA on positive(light) fill', () {
      final accent = BrandPalette.positive(Brightness.light);
      expect(contrastRatio(onAccent(accent), accent), greaterThan(4.5));
    });

    test('onAccent clears AA on positive(dark) fill', () {
      final accent = BrandPalette.positive(Brightness.dark);
      expect(contrastRatio(onAccent(accent), accent), greaterThan(4.5));
    });
  });

  group('Tooltip text on inverseSurface', () {
    // The tooltip background is `inverseSurface` (M3): dark in light
    // mode, light in dark mode. Tooltip accents must therefore use the
    // OPPOSITE brightness's accent shade.
    test('light-mode tooltip uses dark-shade positive', () {
      // Tooltip surface in light mode is ~ColorScheme.inverseSurface
      // for the default seed; approximated here with a near-black.
      const lightTooltipBg = Color(0xFF313030);
      expect(
        contrastRatio(
            BrandPalette.positive(Brightness.dark), lightTooltipBg),
        greaterThan(4.5),
      );
    });

    test('dark-mode tooltip uses light-shade positive', () {
      // Tooltip surface in dark mode is ~ColorScheme.inverseSurface
      // for the default seed; approximated here with a near-white.
      const darkTooltipBg = Color(0xFFE6E1E5);
      expect(
        contrastRatio(
            BrandPalette.positive(Brightness.light), darkTooltipBg),
        greaterThan(4.5),
      );
    });
  });

  group('Body-text alpha tiers (composited)', () {
    // textSubtle and textFaint apply an alpha to onSurface. The
    // composited result against the scaffold must clear AA (textSubtle)
    // and AA-large (textFaint) — these regressed before when the alphas
    // were too thin against the light scaffold. The alphas under test
    // match ThemeColorsExt's current values for light mode (textSubtle
    // 0.78, textFaint 0.65). If ThemeColorsExt rebalances these, update
    // here AND there.
    test('textSubtle on light scaffold passes AA', () {
      final scaffold = BrandPalette.scaffoldBackground(Brightness.light);
      final subtle = Colors.black.withValues(alpha: 0.78);
      expect(
          contrastRatio(composite(subtle, scaffold), scaffold), greaterThan(4.5));
    });

    test('textFaint on light scaffold passes AA-large', () {
      final scaffold = BrandPalette.scaffoldBackground(Brightness.light);
      final faint = Colors.black.withValues(alpha: 0.65);
      expect(
          contrastRatio(composite(faint, scaffold), scaffold), greaterThan(3.0));
    });

    test('textSubtle on white card passes AA', () {
      // Cards in light mode are pure white. The same alpha must clear
      // AA against the card too — a card-only field reading subtitle
      // text is the more common rendering surface than the scaffold.
      final subtle = Colors.black.withValues(alpha: 0.78);
      expect(
          contrastRatio(composite(subtle, Colors.white), Colors.white),
          greaterThan(4.5));
    });

    test('textMuted on light scaffold passes AA', () {
      // textMuted is the secondary-label tier (0.85 alpha). It sees a
      // lot of placement on subtitles + tabbar inactive labels, so
      // hold it to AA-normal too.
      final scaffold = BrandPalette.scaffoldBackground(Brightness.light);
      final muted = Colors.black.withValues(alpha: 0.85);
      expect(
          contrastRatio(composite(muted, scaffold), scaffold), greaterThan(4.5));
    });
  });
}
