import 'package:flutter/material.dart';

/// Brand typography: Inter for body/UI, Fraunces for display/headlines.
///
/// Why Fraunces: market_research §3 calls for a warm, "old-style" serif on
/// the hero/section titles — the 2026 "reads like a well-made tax report"
/// signal and the heritage/estate feel — while keeping Inter (performant,
/// great ES diacritics) for everything else. We apply Fraunces only to the
/// display/headline slots so the rest of the UI keeps Inter's neutral
/// legibility and we avoid re-layout risk.
///
/// Both families are bundled locally (see pubspec.yaml `fonts:` and
/// assets/fonts/). We deliberately do NOT use the google_fonts package: it
/// fetches font files from an external CDN at runtime, which breaks the
/// privacy / self-hosting promise and adds a first-paint network dependency.
const String _interFamily = 'Inter';
const String _frauncesFamily = 'Fraunces';

TextTheme buildBrandTextTheme(TextTheme base) {
  // Inter for the full theme, then Fraunces overlaid on the display +
  // headline slots. `apply(fontFamily: ...)` swaps the family while keeping
  // the incoming sizes/weights/colors.
  final inter = base.apply(fontFamily: _interFamily);
  return inter.copyWith(
    displayLarge: inter.displayLarge?.copyWith(fontFamily: _frauncesFamily),
    displayMedium: inter.displayMedium?.copyWith(fontFamily: _frauncesFamily),
    displaySmall: inter.displaySmall?.copyWith(fontFamily: _frauncesFamily),
    headlineLarge: inter.headlineLarge?.copyWith(fontFamily: _frauncesFamily),
    headlineMedium: inter.headlineMedium?.copyWith(fontFamily: _frauncesFamily),
  );
}

/// The display (Fraunces) font for the net-worth hero number and other
/// signature "big number" moments. Tabular lining figures keep digit
/// columns aligned as the value animates/changes — the "ledger precision"
/// brand signal. Callers pass size/weight/color.
TextStyle brandDisplayStyle({
  required double fontSize,
  FontWeight fontWeight = FontWeight.w700,
  Color? color,
}) {
  return TextStyle(
    fontFamily: _frauncesFamily,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
    fontFeatures: const [
      FontFeature.tabularFigures(),
      FontFeature.liningFigures(),
    ],
  );
}

/// Section/heading style in Fraunces for major card titles. Smaller and
/// lighter than the hero; used sparingly so the serif stays a signal.
TextStyle brandSectionTitleStyle({
  double fontSize = 18,
  FontWeight fontWeight = FontWeight.w600,
  Color? color,
}) {
  return TextStyle(
    fontFamily: _frauncesFamily,
    fontSize: fontSize,
    fontWeight: fontWeight,
    color: color,
  );
}
