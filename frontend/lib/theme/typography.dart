import 'package:flutter/material.dart';

/// Brand typography: Inter for ALL UI/text, IBM Plex Mono for the big
/// "feature" figures (the net-worth hero + the overview stat strip).
///
/// Why this split: a single workhorse sans (Inter — legible at every size,
/// great ES diacritics, real tabular figures) keeps the interface clean and
/// modern, while a monospace on the signature big numbers gives a distinctive,
/// precise "ledger" identity that reads as financial data. The mono is scoped
/// to large display figures only — inline/table numbers stay Inter (with
/// tabular figures) so lists don't turn heavy.
///
/// Both families are bundled locally (see pubspec.yaml `fonts:` and
/// assets/fonts/). We deliberately do NOT use the google_fonts package: it
/// fetches font files from an external CDN at runtime, which breaks the
/// privacy / self-hosting promise and adds a first-paint network dependency.
const String _interFamily = 'Inter';
const String _monoFamily = 'IBMPlexMono';

/// The whole text theme is Inter. (We no longer overlay a display serif on the
/// `display*`/`headline*` slots — the app styles its headers with explicit
/// Inter TextStyles, so that overlay never actually rendered and only made one
/// card look inconsistent. Big numbers get the mono treatment explicitly via
/// [brandDisplayStyle] instead.)
TextTheme buildBrandTextTheme(TextTheme base) =>
    base.apply(fontFamily: _interFamily);

/// The display style for signature big numbers — the net-worth hero and the
/// overview stat-strip values. Monospace + tabular lining figures keep digit
/// columns aligned as values change (the "ledger precision" cue). Callers pass
/// size/weight/color. NOTE: IBM Plex Mono tops out at Bold (w700); callers
/// should not request heavier weights or the engine synthesises a faux bold
/// that looks muddy on a mono.
TextStyle brandDisplayStyle({
  required double fontSize,
  FontWeight fontWeight = FontWeight.w700,
  Color? color,
}) {
  return TextStyle(
    fontFamily: _monoFamily,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    // Slightly negative tracking tightens the mono's wide default spacing so
    // big figures read as one number rather than spaced-out glyphs.
    letterSpacing: -0.5,
    fontFeatures: const [
      FontFeature.tabularFigures(),
      FontFeature.liningFigures(),
    ],
  );
}

/// Small section label that sits above a hero number (e.g. "Total net worth").
/// Plain Inter now — it's supporting text, not a display figure, so it matches
/// the rest of the UI. Callers pass size/weight/color.
TextStyle brandSectionTitleStyle({
  double fontSize = 18,
  FontWeight fontWeight = FontWeight.w600,
  Color? color,
}) {
  return TextStyle(
    fontFamily: _interFamily,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
  );
}
