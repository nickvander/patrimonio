# Engineer pass 3 — bundle brand fonts locally (kill runtime CDN fetch)

## Problem
`frontend/lib/theme/typography.dart` loaded Inter + Fraunces via the
`google_fonts` package, which fetches from an external CDN (fonts.gstatic.com)
at RUNTIME. Breaks the privacy-respecting / self-hostable promise. Fix: vendor
the fonts locally, zero runtime fetch.

## Fonts vendored (frontend/assets/fonts/)
All OFL-licensed, verified as real TrueType via `file`.

| File | Family / weight | Bytes | Source |
|------|-----------------|-------|--------|
| Inter-Regular.ttf  | Inter 400 | 411640 | github.com/rsms/inter release v4.1 (Inter-4.1.zip → extras/ttf/) |
| Inter-Medium.ttf   | Inter 500 | 417300 | same |
| Inter-SemiBold.ttf | Inter 600 | 419744 | same |
| Inter-Bold.ttf     | Inter 700 | 420428 | same |
| Fraunces-VariableFont.ttf | Fraunces VF (wght axis) | 360440 | raw.githubusercontent.com/google/fonts/main/ofl/fraunces/Fraunces%5BSOFT%2CWONK%2Copsz%2Cwght%5D.ttf |
| OFL-Inter.txt    | license | 4380 | LICENSE.txt from the Inter release |
| OFL-Fraunces.txt | license | 4391 | raw.githubusercontent.com/google/fonts/main/ofl/fraunces/OFL.txt |

Inter download URL: github.com/rsms/inter/releases/download/v4.1/Inter-4.1.zip
(33MB zip; static instances extracted from extras/ttf/).

Note on Fraunces: googlefonts/fraunces ships ONLY variable fonts (no static
`fonts/ttf/` instances — verified via the repo git tree), and fonttools was not
available to instance static weights. So I vendored the single google/fonts
variable font and, in pubspec, mapped weights 400/600/700 all to that one VF
file. Flutter clamps the `wght` axis to each declared `weight:`, so the
display/hero (700) and section titles (600) render at the correct weight.

## pubspec.yaml changes
- Removed `google_fonts: ^6.2.1` from dependencies (no longer used anywhere).
- Replaced the commented-out example `fonts:` block with real declarations:
  family `Inter` (4 static weight entries) and family `Fraunces` (3 weight
  entries, all pointing at Fraunces-VariableFont.ttf). Added a `why` comment.
- Ran `flutter pub get` → "Changed 19 dependencies!" (google_fonts + transitive
  deps dropped), success.

## typography.dart rewrite approach
- Dropped `import 'package:google_fonts/google_fonts.dart';`.
- `buildBrandTextTheme`: `base.apply(fontFamily: 'Inter')` for the whole theme,
  then `.copyWith(...)` overlays `fontFamily: 'Fraunces'` (via per-slot
  `copyWith`) on displayLarge/Medium/Small + headlineLarge/Medium — same slots
  the original swapped, preserving sizes/weights/colors.
- `brandDisplayStyle` / `brandSectionTitleStyle`: plain
  `TextStyle(fontFamily: 'Fraunces', ...)`. Kept the hero's
  `FontFeature.tabularFigures()` + `FontFeature.liningFigures()` and the
  default weights (w700 hero, w600 section). Signatures unchanged.
- Family names hoisted to `_interFamily` / `_frauncesFamily` consts.

## google_fonts dep
REMOVED entirely (was the only consumer). No `allowRuntimeFetching=false`
needed since the package is gone.

## Grep proof
```
$ grep -rn "GoogleFonts\|gstatic" frontend/lib
(no output) → CLEAN
$ grep -rn "google_fonts" frontend/pubspec.yaml
(no output) → DEP REMOVED
```

## Gates
- `flutter analyze` → 18 issues, ALL `info` (pre-existing, unrelated:
  deprecated_member_use, use_null_aware_elements, etc.). Zero error/warning.
- `flutter test` → All 121 tests passed, incl.
  test/theme/palette_contrast_test.dart (re-ran standalone: 23 pass).

## Compromises
- Fraunces is a single variable font reused across weights (no static
  instances available upstream + no fonttools to instance). This is supported
  by Flutter and renders correct weights; the only cost is one slightly larger
  file vs. three static slices. No faux-bolding — real wght axis.
