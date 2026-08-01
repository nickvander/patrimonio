import 'package:flutter/material.dart';

import '../theme/palette.dart';

/// Context-based color accessors that resolve against the current
/// ColorScheme, so the same widget reads as white-on-dark in dark mode
/// and dark-on-light in light mode without each call site duplicating
/// the `Theme.of(context).colorScheme.onSurface.withValues(...)` boilerplate.
///
/// `Colors.white70/54/38` was the old convention; the names below mirror
/// those opacity tiers so the sweep is mostly a find-and-replace.
///
/// Brand accents (positive/negative/warning/info/teal/pink/purple/yellow)
/// delegate to `BrandPalette` so they shift to a darker, AA-passing shade
/// in light mode without each call site duplicating the
/// `Theme.of(context).brightness == ... ? ... : ...` ternary.
extension ThemeColorsExt on BuildContext {
  ColorScheme get _scheme => Theme.of(this).colorScheme;
  Brightness get _brightness => Theme.of(this).brightness;
  bool get _isDark => _brightness == Brightness.dark;

  /// Primary text — was `Colors.white` in dark mode.
  Color get textPrimary => _scheme.onSurface;

  /// Muted text (was `Colors.white70`).
  ///
  /// Light mode bumps the alpha to 0.85 so secondary labels on white
  /// (TabBar inactive tabs, sub-titles in cards) stay readable. At
  /// 0.7 the post-composite gray was too washed out — visible
  /// contrast against pure white tested below WCAG AA on a real
  /// display even though raw maths claimed it cleared.
  Color get textMuted =>
      _scheme.onSurface.withValues(alpha: _isDark ? 0.7 : 0.85);

  /// Subtle text (was `Colors.white54`).
  ///
  /// Light mode boosts to 0.78. The previous 0.7 was meant to clear
  /// WCAG AA against the scaffold but rendered too pale for small
  /// labels (date group headers, secondary amount annotations like
  /// "MXN 47,651.01"). Dark mode keeps the original 0.54 which is
  /// fine on the near-black surface.
  Color get textSubtle =>
      _scheme.onSurface.withValues(alpha: _isDark ? 0.54 : 0.78);

  /// Faint text (was `Colors.white38`). Reserve for decorative non-essential
  /// labels — still nudged up in light mode but stays below body weight.
  Color get textFaint =>
      _scheme.onSurface.withValues(alpha: _isDark ? 0.38 : 0.65);

  /// Hairline / divider color. Dark mode used `Colors.white12`; light
  /// mode wants something noticeably darker than the card surface so
  /// it doesn't disappear against the near-white background.
  Color get hairline => _isDark
      ? _scheme.onSurface.withValues(alpha: 0.12)
      : _scheme.onSurface.withValues(alpha: 0.16);

  /// Subtle filled-tile surface tint (was `Colors.white.withValues(alpha: 0.04)`).
  /// Light mode bumps this up because a 4% tint on white is essentially
  /// invisible — tiles lose their visual boundary against the card.
  Color get tileSurface => _isDark
      ? _scheme.onSurface.withValues(alpha: 0.04)
      : _scheme.onSurface.withValues(alpha: 0.08);

  /// Arbitrary-alpha onSurface tint. Use for backgrounds and overlays
  /// that need a specific opacity (e.g. hover states, chart gridlines).
  /// Replaces ad-hoc `Colors.white.withValues(alpha: X)`. In light mode
  /// the alpha is scaled up ~1.6× so the same call site reads with
  /// comparable visual weight in both brightnesses.
  Color tint(double alpha) => _scheme.onSurface.withValues(
    alpha: _isDark ? alpha : (alpha * 1.6).clamp(0.0, 1.0),
  );

  /// Accent border / fill alphas that match dark-tuned values in
  /// light mode. Saturated brand accents (00E676 emerald, 1DE9B6 teal,
  /// FF4081 pink) at 0.18-0.35 alpha disappear on a white card; this
  /// helper boosts the alpha in light so call sites can stay simple.
  Color accentSoft(Color accent) =>
      _isDark ? accent.withValues(alpha: 0.18) : accent.withValues(alpha: 0.32);

  Color accentBorder(Color accent) =>
      _isDark ? accent.withValues(alpha: 0.35) : accent.withValues(alpha: 0.55);

  /// Foreground (label/icon) colour to place *on top of* a filled accent
  /// background — returns whichever of black/white has the HIGHER WCAG
  /// contrast against [accent].
  ///
  /// Fixes the accent-button bug: a hard-coded `Colors.black` (or white)
  /// label is only correct in one theme, because a semantic accent like
  /// `context.positive` is a deep shade in light mode (#0C6A56 → needs a
  /// white label) but a bright shade in dark mode (#3FD3AE → needs a black
  /// label). Call `context.onAccent(context.positive)` so the label flips
  /// with the theme and always clears AA against the button fill.
  Color onAccent(Color accent) =>
      contrastRatio(Colors.white, accent) >= contrastRatio(Colors.black, accent)
      ? Colors.white
      : Colors.black;

  // ---------------------------------------------------------------------------
  // Semantic accents (delegate to BrandPalette).
  //
  // Each one returns a colour that's AA-readable against the current
  // surface for the active brightness. Use these instead of hard-coded
  // `Color(0xFF00E676)` so the same call site reads correctly in both
  // themes.
  // ---------------------------------------------------------------------------

  /// Positive / gain / income / "go".
  Color get positive => BrandPalette.positive(_brightness);

  /// Negative / loss / spending / "stop".
  Color get negative => BrandPalette.negative(_brightness);

  /// Warning / over-budget / amber.
  Color get warning => BrandPalette.warning(_brightness);

  /// Info / blue / cash.
  Color get info => BrandPalette.info(_brightness);

  /// Teal — secondary positive (cash flow income).
  Color get tealAccent => BrandPalette.teal(_brightness);

  /// Pink — secondary negative (spending, alerts).
  Color get pinkAccent => BrandPalette.pink(_brightness);

  /// Purple — crypto / projections labels.
  Color get purpleAccent => BrandPalette.purple(_brightness);

  /// Yellow — goal lines, FI targets, warm accents.
  Color get yellowAccent => BrandPalette.yellow(_brightness);

  /// Neutral — "other" buckets, disabled chips.
  Color get neutralAccent => BrandPalette.neutral(_brightness);

  /// Chart series colour at the given index. Wraps once past the end of
  /// the underlying list.
  Color chartSeries(int i) {
    final series = BrandPalette.chartSeries(_brightness);
    return series[i % series.length];
  }

  // ---------------------------------------------------------------------------
  // Tooltip / inverse-surface tokens.
  //
  // M3 tooltips and snackbars use `inverseSurface` for the background and
  // `onInverseSurface` for the foreground. Exposing them here means chart
  // tooltip call sites can stop reaching into ColorScheme directly and
  // can't accidentally render `onSurface`-coloured text on an
  // `inverseSurface` background (light-on-light in dark mode — the original
  // net-worth chart bug).
  // ---------------------------------------------------------------------------

  Color get tooltipSurface => _scheme.inverseSurface;
  Color get tooltipOnSurface => _scheme.onInverseSurface;

  /// Soft tooltip-text variant for less-emphasised lines (the per-
  /// institution rows in the net-worth chart, e.g.). 70% alpha against
  /// `inverseSurface` — readable but de-emphasised.
  Color get tooltipOnSurfaceMuted =>
      _scheme.onInverseSurface.withValues(alpha: 0.7);

  /// Positive/negative variants that read against an `inverseSurface`
  /// tooltip background. `inverseSurface` is always the brightness-
  /// opposite of the active theme, so the accent needs the opposite-
  /// brightness shade too:
  ///   • Light mode → dark tooltip → neon (dark-theme) accent.
  ///   • Dark mode  → light tooltip → muted (light-theme) accent.
  Color get tooltipPositive =>
      BrandPalette.positive(_isDark ? Brightness.light : Brightness.dark);
  Color get tooltipNegative =>
      BrandPalette.negative(_isDark ? Brightness.light : Brightness.dark);
}
