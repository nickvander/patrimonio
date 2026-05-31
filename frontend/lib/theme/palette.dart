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
  // Brand seed — agave / Oaxacan jade
  //
  // The brand moved off the generic Rocket-Money neon emerald (#00E676 /
  // #00A352) onto a deeper "agave jade" that reads as money/growth AND
  // Mexican-craft heritage. The field names keep the historical
  // `emerald*` spelling so the ~165 call sites don't churn, but the values
  // are now jade. See work/ux/market_research.md §3.
  // ---------------------------------------------------------------------------

  /// Bright agave jade — the brand signature in dark mode. ~8.8:1 on the
  /// dark card surface.
  static const Color emeraldDark = Color(0xFF3FD3AE);

  /// Deep agave jade for foreground use on white. Darkened from the
  /// research #0E7C66 (5.13:1 on white but only 3.97:1 on the light
  /// tooltip surface used in dark mode) to #0C6A56 — 6.54:1 on white,
  /// 5.06:1 on the tooltip bg — so it clears AA in both placements.
  static const Color emeraldLight = Color(0xFF0C6A56);

  /// Seed used to derive the Material 3 ColorScheme for each brightness.
  static Color seed(Brightness brightness) =>
      brightness == Brightness.dark ? emeraldDark : emeraldLight;

  // ---------------------------------------------------------------------------
  // Heritage accents (secondary / tertiary)
  //
  // Warm terracotta (bicultural craft, MX-side, CTAs) and heritage gold
  // (totals/milestones, used sparingly). Set as ColorScheme
  // secondary/tertiary in main.dart. The light variants are darkened from
  // the raw research hexes so they clear AA as foreground text if used that
  // way — see the changelog for the before/after.
  // ---------------------------------------------------------------------------

  /// Warm terracotta accent. Light is darkened from the research #C2683C
  /// (3.93:1, below AA) to #A8542C (5.29:1) so it's safe as a foreground.
  static Color terracotta(Brightness b) =>
      b == Brightness.dark ? const Color(0xFFE08A57) : const Color(0xFFA8542C);

  /// Heritage gold — patrimony/milestone accent, used sparingly. Light is
  /// darkened from the research #C79A3A (2.59:1, far below AA) to #8C6A1C
  /// (5.01:1) so totals rendered in gold stay readable on white.
  static Color gold(Brightness b) =>
      b == Brightness.dark ? const Color(0xFFE3B85A) : const Color(0xFF8C6A1C);

  // ---------------------------------------------------------------------------
  // Semantic accents
  //
  // Each accent has a dark and light variant. The light variant is darker
  // and slightly less saturated so it passes WCAG AA on white card surfaces.
  // The dark variant keeps the neon character that the app already had.
  // ---------------------------------------------------------------------------

  /// Positive / gain / income / "go" colour. Gains *are* the brand, so this
  /// is the jade seed itself — bright jade in dark, deep agave in light.
  /// Light variant passes AA on white AND on the dark tooltip surface.
  static Color positive(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF3FD3AE) : const Color(0xFF0C6A56);

  /// Negative / loss / spending / "stop" colour. Warm brick red (not pure
  /// neon red) so losses sit in the heritage family.
  static Color negative(Brightness b) =>
      b == Brightness.dark ? const Color(0xFFFF6B5C) : const Color(0xFFB23A2E);

  /// Warning / over-budget / amber. Light darkened from research #B5701A
  /// (3.96:1, below AA) to #9A5F12 (5.22:1) to clear AA on white.
  static Color warning(Brightness b) =>
      b == Brightness.dark ? const Color(0xFFF2B544) : const Color(0xFF9A5F12);

  /// Info / blue / cash — muted lake blue.
  static Color info(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF5BB4E8) : const Color(0xFF2A6F9E);

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

  /// Card surface — pure white in light; a charcoal with a green undertone
  /// in dark (#1A201E) rather than the old cool blue-gray #1A1A24, so cards
  /// sit in the warm green-black neutral ramp.
  static Color cardSurface(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF1A201E) : Colors.white;

  /// Slightly raised tonal layer (menus, inputs, sub-cards). Light moves to
  /// "warm bone" (#F2EFE9) — the paper/ledger signal — instead of cool gray.
  static Color elevatedSurface(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF262E2B) : const Color(0xFFF2EFE9);

  /// Scaffold background. Light is warm parchment (#F6F3EC) so the white
  /// cards sit on warmth; dark is a near-black warm green-black (#10140F).
  static Color scaffoldBackground(Brightness b) =>
      b == Brightness.dark ? const Color(0xFF10140F) : const Color(0xFFF6F3EC);
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
