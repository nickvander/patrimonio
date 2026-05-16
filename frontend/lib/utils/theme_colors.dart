import 'package:flutter/material.dart';

/// Context-based color accessors that resolve against the current
/// ColorScheme, so the same widget reads as white-on-dark in dark mode
/// and dark-on-light in light mode without each call site duplicating
/// the `Theme.of(context).colorScheme.onSurface.withValues(...)` boilerplate.
///
/// `Colors.white70/54/38` was the old convention; the names below mirror
/// those opacity tiers so the sweep is mostly a find-and-replace.
extension ThemeColorsExt on BuildContext {
  ColorScheme get _scheme => Theme.of(this).colorScheme;
  bool get _isDark => Theme.of(this).brightness == Brightness.dark;

  /// Primary text — was `Colors.white` in dark mode.
  Color get textPrimary => _scheme.onSurface;

  /// Muted text (was `Colors.white70`).
  Color get textMuted => _scheme.onSurface.withValues(alpha: 0.7);

  /// Subtle text (was `Colors.white54`).
  Color get textSubtle => _scheme.onSurface.withValues(alpha: 0.54);

  /// Faint text (was `Colors.white38`).
  Color get textFaint => _scheme.onSurface.withValues(alpha: 0.38);

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
  Color tint(double alpha) => _scheme.onSurface
      .withValues(alpha: _isDark ? alpha : (alpha * 1.6).clamp(0.0, 1.0));

  /// Accent border / fill alphas that match dark-tuned values in
  /// light mode. Saturated brand accents (00E676 emerald, 1DE9B6 teal,
  /// FF4081 pink) at 0.18-0.35 alpha disappear on a white card; this
  /// helper boosts the alpha in light so call sites can stay simple.
  Color accentSoft(Color accent) => _isDark
      ? accent.withValues(alpha: 0.18)
      : accent.withValues(alpha: 0.32);

  Color accentBorder(Color accent) => _isDark
      ? accent.withValues(alpha: 0.35)
      : accent.withValues(alpha: 0.55);
}
