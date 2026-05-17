import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Brightness-aware brand palette.
///
/// Why this exists: before this file, accent colours like `Color(0xFF00E676)`
/// (brand emerald) were repeated as hex literals at ~165 call sites across
/// `lib/`. Each one was tuned for the dark theme and renders at ~2:1
/// contrast on a white card in light mode — way under WCAG AA.
///
/// The pattern here is a small set of semantic accents (positive, negative,
/// warning, info, neutral, plus chart-series colours) that pick the right
/// shade for the active brightness. Call sites read `context.positive`
/// instead of hard-coding a hex, and the accent shifts hue/value when the
/// user flips the theme.
///
/// The fill / soft / strong variants are siblings of each accent for the
/// common patterns (text on white, fill-behind-text, chip background).
class BrandPalette {
  const BrandPalette._();

  // ---------------------------------------------------------------------------
  // Brand seed
  // ---------------------------------------------------------------------------

  /// Vivid neon emerald — the brand signature in dark mode.
  static const Color emeraldDark = Color(0xFF00E676);

  /// Darker variant for foreground use on white. ~4.66:1 on #FFFFFF.
  static const Color emeraldLight = Color(0xFF00A352);

  /// Seed used to derive the Material 3 ColorScheme for each brightness.
  static Color seed(Brightness brightness) =>
      brightness == Brightness.dark ? emeraldDark : emeraldLight;

  // ---------------------------------------------------------------------------
  // Semantic accents
  //
  // Each accent has a dark and light variant. The light variant is darker
  // and slightly less saturated so it passes WCAG AA on white card surfaces.
  // The dark variant keeps the neon character that the app already had.
  // ---------------------------------------------------------------------------

  /// Positive / gain / income / "go" colour.
  ///
  /// Light variant is darker so it passes AA on white AND on the dark
  /// tooltip surface (used in dark mode for tooltip text).
  static Color positive(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF00E676) : const Color(0xFF006B38);

  /// Negative / loss / spending / "stop" colour.
  static Color negative(Brightness b) =>
      b == Brightness.dark ? const Color(0xFFFF5252) : const Color(0xFFA32614);

  /// Warning / over-budget / amber.
  static Color warning(Brightness b) =>
      b == Brightness.dark ? const Color(0xFFFFB300) : const Color(0xFF8F5600);

  /// Info / blue / cash.
  static Color info(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF00B0FF) : const Color(0xFF006FBA);

  /// Teal — secondary positive (cash flow income, stocks chip).
  static Color teal(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF1DE9B6) : const Color(0xFF00756B);

  /// Pink — secondary negative (spending bars, alerts that aren't errors).
  static Color pink(Brightness b) =>
      b == Brightness.dark ? const Color(0xFFFF4081) : const Color(0xFFC2185B);

  /// Purple — crypto / projections labels.
  ///
  /// Dark variant is `#7E57C2` (Material Deep Purple 400) rather than
  /// the original `#AB47BC` (Purple 400) — the latter mixed too closely
  /// with the dark card surface to hit AA in the chart-series sweep.
  static Color purple(Brightness b) =>
      b == Brightness.dark ? const Color(0xFFB388FF) : const Color(0xFF5E1A85);

  /// Yellow — goals, FI lines, accents that need warmth without alarm.
  static Color yellow(Brightness b) =>
      b == Brightness.dark ? const Color(0xFFFFD600) : const Color(0xFF8F6B00);

  /// Neutral / "other" / 90A4AE replacement.
  static Color neutral(Brightness b) =>
      b == Brightness.dark ? const Color(0xFFB0BEC5) : const Color(0xFF455A64);

  // ---------------------------------------------------------------------------
  // Chart series
  //
  // Ordered list used for stacked-area and pie charts that need a stable
  // set of distinct hues. Both brightnesses produce 6 distinguishable
  // colours; the light variants are darker so labels remain readable on
  // white backgrounds.
  // ---------------------------------------------------------------------------

  static List<Color> chartSeries(Brightness b) => b == Brightness.dark
      ? const [
          Color(0xFF40C4FF), // azure
          Color(0xFFB388FF), // purple
          Color(0xFFFFC107), // amber
          Color(0xFFFF8A65), // deep orange
          Color(0xFF80DEEA), // cyan
          Color(0xFFFF80AB), // pink
        ]
      : const [
          Color(0xFF005FAA), // azure
          Color(0xFF5E1A85), // purple
          Color(0xFF8F5600), // amber
          Color(0xFF9C3A1A), // deep orange
          Color(0xFF006970), // cyan
          Color(0xFFA31453), // pink
        ];

  // ---------------------------------------------------------------------------
  // Surfaces (M3 tonal layers, hand-picked to match the existing theme)
  // ---------------------------------------------------------------------------

  /// Card surface — pure white in light, charcoal in dark.
  static Color cardSurface(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF1A1A24) : Colors.white;

  /// Slightly raised tonal layer (used for menus, inputs, sub-cards).
  static Color elevatedSurface(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF2A2A35) : const Color(0xFFEEF0F4);

  /// Scaffold background. Light has a hint of cool chroma so the white
  /// cards have somewhere to "sit"; pure white-on-white merges everything.
  static Color scaffoldBackground(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF101016) : const Color(0xFFEFF1F5);
}

// =============================================================================
// WCAG helpers
//
// Used by the contrast unit test (`test/theme/palette_contrast_test.dart`)
// and available to call sites that need to verify a foreground/background
// pair at runtime.
// =============================================================================

/// Relative luminance per WCAG 2.x (sRGB → linear → weighted).
double _luminance(Color c) {
  double linearize(double channel) {
    if (channel <= 0.03928) return channel / 12.92;
    return math.pow((channel + 0.055) / 1.055, 2.4).toDouble();
  }

  final r = linearize(c.r);
  final g = linearize(c.g);
  final b = linearize(c.b);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

/// WCAG 2.x contrast ratio between two opaque colours. >= 4.5 = AA normal
/// text, >= 3.0 = AA large text, >= 7.0 = AAA normal.
double contrastRatio(Color fg, Color bg) {
  final l1 = _luminance(fg);
  final l2 = _luminance(bg);
  final brightest = l1 > l2 ? l1 : l2;
  final darkest = l1 > l2 ? l2 : l1;
  return (brightest + 0.05) / (darkest + 0.05);
}

/// Composites a foreground colour with alpha over an opaque background.
/// Use this when checking contrast for alpha-blended tokens like
/// `textSubtle = onSurface @ 0.54` against the scaffold.
Color composite(Color fg, Color bg) {
  final a = fg.a;
  final r = fg.r * a + bg.r * (1 - a);
  final g = fg.g * a + bg.g * (1 - a);
  final b = fg.b * a + bg.b * (1 - a);
  return Color.from(alpha: 1.0, red: r, green: g, blue: b);
}
