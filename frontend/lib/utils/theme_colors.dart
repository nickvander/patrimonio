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
  /// mode wants something a touch darker than the card surface so it's
  /// still visible.
  Color get hairline => _isDark
      ? _scheme.onSurface.withValues(alpha: 0.12)
      : _scheme.onSurface.withValues(alpha: 0.10);

  /// Subtle filled-tile surface tint (was `Colors.white.withValues(alpha: 0.04)`).
  Color get tileSurface => _isDark
      ? _scheme.onSurface.withValues(alpha: 0.04)
      : _scheme.onSurface.withValues(alpha: 0.05);

  /// Arbitrary-alpha onSurface tint. Use for backgrounds and overlays
  /// that need a specific opacity (e.g. hover states, chart gridlines).
  /// Replaces ad-hoc `Colors.white.withValues(alpha: X)`.
  Color tint(double alpha) => _scheme.onSurface.withValues(alpha: alpha);
}
