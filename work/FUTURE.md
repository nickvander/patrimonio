# Future work backlog

> **Purpose:** Plans that aren't urgent enough for [NEXT.md](NEXT.md) and aren't tied to a numbered phase, but are worth keeping in writing so they don't drop out of memory.

---

## prefer_const_literals_to_create_immutables sweep

**Status:** Deferred, not blocking.
**Tracking:** This file.
**Owner:** Whoever next runs `dart fix` on the frontend.

### Background

The May 2026 light-theme sweep (`afded3a`) stripped `const` wholesale from `Text(...)` / `TextStyle(...)` / `Icon(...)` / `Divider(...)` expressions because the inside of those expressions now reads from `BuildContext` via `ThemeColorsExt` (`context.textPrimary`, etc.). `dart fix --apply --code=prefer_const_constructors` (`b784f3e`) reapplied `const` on the 185 call sites whose constructors stayed eligible, and `prefer_const_constructors` is now enabled permanently in `frontend/analysis_options.yaml` so the regression can't quietly accumulate again.

The companion lint `prefer_const_literals_to_create_immutables` covers the *children* lists of those constructors — `children: [SizedBox(...), Text(...), ...]` becoming `children: const [SizedBox(...), Text(...), ...]` when every element is itself const. This one is **off** because it has a higher false-positive rate than its sibling: a `const` list is immutable, so if downstream code later wants to mutate the children list (rare but real, especially in stateful widgets that compose conditional children), the const literal forces a refactor.

### Why we deferred it

`dart fix --apply --code=prefer_const_literals_to_create_immutables` would currently produce ~80-120 changes (rough estimate, run `dart fix --dry-run` to verify when the time comes). Each one needs eyes on it because:

- **Mutation hazard.** Some lists look immutable today but are spread into a `Column` that conditionally adds rows via `if (...)` or `...spread` syntax. If a `const` list ever needs to gain an element at build time, the cast becomes a runtime crash.
- **Hot reload edge cases.** Const literals get tree-shaken; replacing one with a runtime list can cause a hot-reload restart in some setups.
- **The benefit is small.** `const` on the children list saves one extra heap allocation per build. For Patrimonio at current scale (a few dozen rows per tab) that's invisible.

### Plan when picked up

1. Run a dry-run first to see the scope:
   ```bash
   cd frontend && dart fix --dry-run --code=prefer_const_literals_to_create_immutables
   ```
2. Apply only one file at a time, not the bulk-apply. For each change, eyeball the surrounding state class: if there's any `setState` that could conditionally add to the list, skip that one with `// ignore: prefer_const_literals_to_create_immutables` and a one-line rationale comment.
3. Run `flutter analyze` after each file to catch any regressions early.
4. Spot-check the affected widgets in both light and dark mode in the browser — most issues will surface as "this widget refuses to render" rather than as analyzer errors.
5. Once stable, opt the lint into `analysis_options.yaml` alongside `prefer_const_constructors` so future drift gets caught.

### When to do this

- Not before the next major UI feature lands (less churn = easier review).
- Maybe pair it with a "performance pass" once the app has more users and frame timings start to matter — at which point all the small allocation wins compound.
- A natural trigger: if a future widget refactor already has the file open and analyze flags ten of these in the same file, just apply them in the same commit.

### Rollback

`git revert` the single commit; the changes are mechanical and self-contained per call site. No data or schema impact.

---

## Color palette overhaul (dark + light) and chart hover polish

**Status:** Open. The May 2026 light-theme sweep got the wiring right (every widget reads through `ThemeColorsExt`) but the actual colors still have visible problems in both modes. Worth a dedicated session.

**Tracking:** This file.

### Concrete pain points

**Dark mode**

- **Net-worth chart tooltip is unreadable.** `frontend/lib/widgets/net_worth_card.dart:456` sets the tooltip background to `colorScheme.inverseSurface` — which in dark mode is *light*. The text spans inside the tooltip (line 489, 502, 506, etc.) read `context.textPrimary`, `Color(0xFF00E676)`, `Colors.redAccent`, etc. In dark mode `textPrimary` resolves to near-white, so we render light-on-light. Same shape applies to `frontend/lib/screens/wealth_projection_screen.dart:629` for the projections tooltip.
- **Hover feels mechanical.** Every `LineChartBarData` in `net_worth_card.dart` sets `dotData: const FlDotData(show: false)` (lines 638, 654, 670). fl_chart's default `touchSpotThreshold` is ~10px, so unless the cursor is within 10px of a downsampled spot (we downsample to ~150 points) the tooltip just doesn't fire. The trend chart on the cash-flow tab feels OK because BarChart has wider native hit zones. Best practice for a continuous line: enable a `getTouchedSpotIndicator` callback that draws a vertical guide + a single highlighted dot wherever the cursor is along the X axis (the canonical Robinhood / Mint / Personal Capital interaction), and bump `touchSpotThreshold` or use `getTouchLineX` to snap to the nearest x.

**Light mode**

- **Body text contrast on the scaffold.** Cards (white) are fine, but the off-white scaffold (`#EDEFF3` in `main.dart:_buildLightTheme`) plus `context.textSubtle` (0.54 alpha) or `textFaint` (0.38 alpha) doesn't hit WCAG AA for normal text. Italic subtitles like the new "Unknown subtype" line inherit this problem. The empty-state copy on Tax planning, the chart axis labels, and the FX badge tooltip text are the most visible offenders.
- **Brand accents wash out at full opacity on white.** `Color(0xFF00E676)` (emerald), `Color(0xFF1DE9B6)` (teal), `Color(0xFFFFD600)` (yellow), `Color(0xFFFF4081)` (pink) all sit around 2:1 contrast against white. They're fine as fills behind dark text (the budgets card "over budget" indicator works), but they fail as foreground text on white, which is where most "+$1,234" / "−$56" tx amounts render.

### Current token inventory

Everything currently routes through these touch points — the palette overhaul should land here, not at the call sites.

| Token | Defined in | Notes |
|---|---|---|
| dark theme | `frontend/lib/main.dart` `_buildDarkTheme` | seed `0xFF00E676`, surface `0xFF1A1A24` |
| light theme | `frontend/lib/main.dart` `_buildLightTheme` | seed `0xFF00A352`, surface `Colors.white`, scaffold `#EDEFF3` |
| `textPrimary / Muted / Subtle / Faint` | `frontend/lib/utils/theme_colors.dart` | onSurface with alpha 1.0 / 0.7 / 0.54 / 0.38 |
| `hairline / tileSurface / tint(α) / accentSoft / accentBorder` | same file | dark vs light branches |
| brand accents (hardcoded) | dozens of `Color(0xFF...)` call sites | grep `Color(0xFF` to enumerate |

### Design direction

The user's brief: "clean, innovative, modern, expressive, good looking, and the two modes should play well together."

Some directions worth trying (not prescriptive):

- **Pick a single seed color** that produces good Material 3 schemes in both brightnesses. The current dark seed (00E676 emerald) is right for the brand but Material 3's tonal palette derived from it produces some chalky tertiaries — worth experimenting with a slightly muted variant for the seed and keeping 00E676 only as a brand accent.
- **Define an accents map**, not seven independent hex codes. Something like `class BrandAccents { static Color positive(Brightness); static Color negative(Brightness); static Color neutral(Brightness); ... }`. The brightness-aware getters return a slightly darker variant in light mode (for contrast against white) and the existing neon in dark mode. This is the missing piece — we keep tinting accents at the call site instead of having an accent that knows what brightness it's in.
- **Replace the EDEFF3 scaffold** with a colour that has more underlying chroma (a barely-tinted off-blue or off-grey) so the eye doesn't fight the lack of contrast against white cards. Material 3 calls this `surfaceContainerLow` / `surfaceContainer`.
- **Adopt M3's `surface*` tonal layers** rather than `tint(alpha)` overlays. `surfaceContainer`, `surfaceContainerHigh`, `surfaceContainerHighest` give proper layering without alpha-on-alpha murkiness.

### Acceptance criteria

- Every chart tooltip is legible in both brightnesses (use `colorScheme.onInverseSurface` for the body, or pick a tooltip surface that has guaranteed contrast against the text colour we want to use).
- WCAG AA (4.5:1 normal, 3:1 large) for all body and subtitle text against its actual background, both modes. Verify with `Color.computeLuminance()` ratios on the most common pairs (textSubtle on EDEFF3, accent text on white, axis labels on cards, etc.).
- The net-worth chart hover snaps along the entire X axis with a visible vertical guide and one highlighted spot, not the current "only fires inside 10px of a downsampled point" behaviour. Match the pattern in `frontend/lib/screens/account_transactions_screen.dart`'s balance sparkline once it picks up the same treatment.
- Both modes feel like the same app's two faces, not two different apps. Identical layouts, identical accents that just shift hue/value for the active brightness.

### Step-by-step plan when picked up

1. Run a quick audit script (10 min): grep every `Color(0xFF...)` literal across `frontend/lib/`, build a histogram by hex, identify the long tail vs the brand core. The fix lives in turning the long tail into a small set of named tokens.
2. Sketch the new palette as a single Dart file (`frontend/lib/theme/palette.dart`) that exports `Brand`, `Accents`, and `Surfaces` classes with brightness-aware getters.
3. Migrate `ThemeColorsExt` to delegate to the new palette so old call sites keep working through the transition.
4. Swap chart tooltips to use `inverseSurface` + `onInverseSurface` (the existing inverseSurface call is correct, the text spans need to switch to `onInverseSurface`). Add `getTouchedSpotIndicator` + a wider `touchSpotThreshold` to the net-worth chart.
5. Run the WCAG check function as a unit test so future regressions get caught:
   ```dart
   test('textSubtle on scaffold meets WCAG AA', () {
     expect(contrastRatio(textSubtle, scaffoldBg), greaterThan(4.5));
   });
   ```
6. Visual smoke: walk every tab in both modes, screenshot each, compare. Note any unexpected widgets that still look off (likely candidates: PDF export preview, snackbars, dialogs).

### Rollback

The migration is staged so each step has its own commit. The riskiest one is step 4 (tooltip surgery on charts) — if it goes wrong the chart still renders but tooltip text might be invisible. Easy to spot and revert.
