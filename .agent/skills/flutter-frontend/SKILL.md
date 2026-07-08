---
name: flutter-frontend
description: >-
  Best practices for the patrimonio Flutter frontend (Material 3, en + es-MX,
  fl_chart, http, gen-l10n). Use when writing or reviewing any frontend/ code:
  widgets, screens, the ApiService layer, l10n strings, money/percent formatting,
  charts, theming, or tests. Encodes the house conventions and the specific bug
  classes this codebase has been bitten by — above all the gen-l10n placeholder
  alphabetization trap.
---

# patrimonio — Flutter frontend best practices

Material 3, two locales (en + es-MX), `fl_chart`, `http`, `intl`, gen-l10n. **No
Riverpod/Provider/Bloc** — plain Flutter state. Fonts vendored (no `google_fonts`).
Follow the existing pattern; don't import a different architecture.

Cited anchors are `file:line` at time of writing; if drifted, grep for the named symbol.

> **General Dart/Flutter conventions** (Effective Dart, Flutter style guide,
> lints) — const constructors, `dispose()`, no work in `build()`, `mounted`
> across async gaps, typed models over `Map<String,dynamic>`, etc. — live in the
> companion file [dart-flutter-conventions.md](dart-flutter-conventions.md). This
> SKILL.md covers project-specific rules; read both.

## The things that have actually caused bugs here

1. **gen-l10n alphabetizes placeholder params**, ignoring template order → silently
   transposed args (money/dates are all `Object`, so no type error). Highest-priority
   trap. There is a *live* instance — see §2. (§2)
2. **Hand-rolled `'$v%'` / hardcoded `$`** → wrong es-MX formatting (es wants comma
   decimal + NBSP before `%`). Use the helpers. (§2, §7)
3. **Hardcoded `Colors.white70` / hex** → fails light-mode WCAG AA. Use the `context`
   color extension. (§4)
4. **Index-as-x charts** hide data gaps; **screen-width** breakpoints miss the real
   constraint. Use day-offset x and the *inner* `LayoutBuilder` width. (§4, §5)

## 1. State management

Plain Flutter. **Do not add a state-management package.**

- `setState` for local screen state (screens are large `StatefulWidget`s that own their
  data and pass it down to cards as constructor params).
- Module-level `ValueNotifier` + `ValueListenableBuilder` for app-global reactive state
  (locale, theme) — e.g. `utils/app_locale.dart` `localeNotifier`, subscribed in `main.dart`.
  Note the registration-order dependency: a listener re-points `package:intl` **before**
  `MaterialApp` rebuilds.
- Singleton services (`AuthService.instance`) + a broadcast `Stream<RealtimeEvent>`
  (`RealtimeService`) for cross-cutting events the dashboard listens to.
- **Cards are dumb/injected** — they receive already-computed inputs (values, a prebuilt
  `NumberFormat`, a `conversionFactor`, callbacks), never fetch. **Put testable business
  logic in `utils/`** (`debt_payoff.dart`, `bill_forecast.dart`, …) and unit-test it there,
  independent of widgets.

## 2. Localization (l10n) — read this twice

Setup: gen-l10n via `l10n.yaml` (`arb-dir: lib/l10n`, template `app_en.arb`, output
`AppLocalizations`, `nullable-getter: false`). Two arb files: `app_en.arb` (template) +
`app_es.arb` (hand-tuned es-MX). Generated files are committed.

**Access:** `final l = AppLocalizations.of(context);` at the top of `build`, then `l.key` /
`l.key(arg)`. `.of(context)` is non-null (nullable-getter: false) — no null checks, BUT any
test/util that pumps a widget **must** supply `localizationsDelegates` + `supportedLocales`
or it throws. Service layer (no `BuildContext`) localizes via the tiny `_t(en, es)` helper
that reads the global locale — keep that confined to the service layer; prefer
`AppLocalizations` in widgets.

**Key naming:** flat camelCase with a feature prefix — `nav*`, `auth*`, `sec*`, `tax*`,
`pf*` (portfolio), `lw*` (net-worth), `cf*` (cash flow), `dlg*`, `imp*`, `dp*`. Plurals use
ICU `{count, plural, =1{…} other{…}}`.

### ⚠ THE PLACEHOLDER-ORDERING TRAP (top priority)

gen-l10n derives a method's **positional parameters by ALPHABETIZING the placeholder
names**, ignoring the order they appear in the template string. If a call site passes
arguments in template/reading order, adjacent same-typed args get **silently transposed** —
no compile error, because money strings and dates are all `Object`/`String`.

**Every time you add or reorder an arb placeholder:**
1. Open the generated `AppLocalizations` method and read its parameter order (alphabetical).
2. Match the **call site** to that alphabetical order — NOT the template order.
3. Add a `// gen-l10n orders these alphabetically → (a, b)` comment at the call site
   (existing examples: `wealth_projection_screen.dart`, `net_worth_goal_tile.dart`,
   `debt_payoff_card.dart`).
4. For any method with ≥2 same-typed args, add a bilingual widget test asserting the
   rendered string (en and es), so a future transposition fails a test.

Correct example — template is `{year}: {amount}` but alphabetical order is (amount, year):
```dart
// gen-l10n orders placeholders alphabetically (amount, year) regardless of template order.
l.projTooltipYearAmount(amount, year); // amount FIRST
```

### Percent / number formatting — never hand-roll

Use `utils/percent_format.dart`. It deliberately avoids `NumberFormat.decimalPercentPattern`
(its ×100 round-trip shifts `.5` boundaries):
- `formatPercent(context, value, {digits = 1})` — takes a **percentage number** (12.5 →
  "12.5%"), not a ratio. en byte-identical to `toStringAsFixed`; es → comma decimal + NBSP `%`.
- `formatPercentLocale(locale, value)` — context-less variant for the service/notification
  layer (pass `l.localeName`).
- `localizePercentString(context, "85")` — variable-precision strings that don't fit fixed digits.
- `localizeNumberString(context, "+3.6")` — localize the decimal separator only, no `%`.

Never write `'$v%'` by hand.

## 3. Networking — the ApiService layer

Single `ApiService` over `package:http` (no dio). Platform-split base URL/client via
conditional imports.

- **Always go through the verb wrappers `_get/_post/_patch/_put/_delete`** — never raw
  `_client`. They centralize: 401 handling (`_maybeUnauthorized` → `handleUnauthorized()` +
  throw `UnauthorizedException`), CSRF header injection (`X-Requested-With: fetch`, required
  by the backend), and cache invalidation.
- **Wrap idempotent dashboard GETs in `_cachedGet(key, fetch, {forceRefresh})`** — short-TTL
  stale-while-revalidate + concurrent-GET de-dup under the `dash:` prefix. After any write,
  `_invalidateAfterMutation` / `clearDashboardCache()` runs (the blunt, provably-safe reset).
- **Surface backend errors via `_errorFromBody(res, fallback:)`** — it prefers the server's
  `{"error": "..."}` string. Localize fallback strings with `_t(en, es)`. Add a **typed
  exception** (like `LoanTermsLockedException`, `UnauthorizedException`) only when a call site
  must distinguish that failure programmatically.
- **DTOs:** most endpoints return untyped `Map<String, dynamic>` / `List<dynamic>` cast
  field-by-field. This is the existing reality but it's fragile — for a **new complex
  response, add a typed `fromJson` model** (like `AuthUser`) rather than growing more
  stringly-typed field access.

## 4. Widgets, theme, color, responsiveness

- **Never hardcode colors.** Use the `context` extension in `utils/theme_colors.dart`:
  - Text tiers: `context.textPrimary/textMuted/textSubtle/textFaint`, `context.hairline`,
    `context.tileSurface`, `context.tint(alpha)`.
  - Semantic accents: `context.positive/negative/warning/info/…Accent` — each resolves an
    **AA-passing** shade per brightness (a contrast unit test enforces it). `Colors.white70`
    / hex will fail light mode.
  - Chart series: `context.chartSeries(i)`. Tooltips: `context.tooltipSurface` /
    `tooltipOnSurface*` (these use `inverseSurface`; they exist specifically to prevent the
    light-on-light tooltip-text bug — use them, don't reach for `onSurface`).
- **Typography (`theme/typography.dart`):** Inter for all UI. `brandDisplayStyle(...)`
  (JetBrainsMono, tabular figures) ONLY for signature big numbers (net-worth hero, stat
  strip); `brandSectionTitleStyle(...)` for labels above heroes. JetBrainsMono maxes at w700.
- **Card idiom:** `Card(elevation: 4, shape: RoundedRectangleBorder(borderRadius:
  BorderRadius.circular(20)))` with inner `Padding`.
- **Responsiveness is width-driven — off the INNER `LayoutBuilder` constraint, not the
  screen.** The trends mobile-overflow fix reads `outer.maxWidth`, not `MediaQuery`. Established
  breakpoints: **~420** (phone), **~520** (Row→Column header stack), **~720** (outer padding
  16 vs 24). Derive `chartHeight` / `barWidth` / label-thinning from the constraint. To avoid
  x-label overlap, compute an adaptive step (~1 label per 46px phone / 62px wide) and skip
  labels that don't land on it (always keep the last).
- **StatelessWidget when there's no local state.**
- **Accessibility:** custom-painted charts are pointer-only, so mirror their data into the
  semantics tree — `Semantics(container: true, label: summary)` + `ExcludeSemantics` on the
  canvas + an offstage per-item list. If a summary string is localized with multiple args,
  it's still subject to the §2 transposition trap even though it's screen-reader-only.

## 5. Charts (fl_chart)

- **New line charts use `standardLineTouch(context, {items, showIndicator})`** from
  `utils/chart_touch.dart` (snap-to-nearest-X hover, guide + ring dot, tooltip via
  `context.tooltipSurface`, `fitInsideHorizontally/Vertically: true`). The three "headline"
  charts (net worth, projections, instrument sheet) keep their own inline `LineTouchData`
  copies that must stay byte-equivalent — **do not refactor those**, and don't fork a new copy
  either; use the helper.
- **Date-x charts use `utils/chart_time_axis.dart`** — never index-as-x (it hides gaps):
  - `dedupeDailyCloses(points)` — last close per calendar day, normalized to
    `DateTime.utc(y,m,d)` (avoids DST day-slip), sorted ascending.
  - `dayOffsetSpots(points)` — `x = date.difference(first.date).inDays`, so a 60-day gap
    occupies 60 x-units, not one step.
  - `dayOffsetTickInterval(spanDays)` — `(spanDays/3).clamp(1, ∞)`, ~4 labels, never < 1 day.
- **Axis titles:** `AxisTitles` + `SideTitles` with explicit `reservedSize`; `getTitlesWidget`
  returns `SideTitleWidget(meta: meta, child: Text(...))`. Disable top/right titles. Skip the
  0 tick and anything within ~8% of maxY to avoid crowding. Compact currency ticks via
  `NumberFormat.compactSimpleCurrency(name: currencyFormat.currencyName)`.
- **Tap-to-drill:** guard `if (event is! FlTapUpEvent) return;` (ignore hover/drag),
  read `response.spot.touchedBarGroupIndex`, bounds-check, emit via callback.

## 6. Money / formatting

Centralized in `utils/currency.dart` — **never build money strings by hand or hardcode `$`:**
- `moneyFormat(currency)` → `NumberFormat.currency(name: code, symbol: currencySymbol(code))`
  (`name` = ISO code for correct grouping/decimals; `symbol` = display glyph).
- `formatCurrencyAmount(amount, currency)` for single-currency; `formatCurrencyWithCode(...)`
  when several currencies sit side by side (forces the ISO prefix).
- `convertCurrency(amount, from:, to:, usdMxnRate:)` handles USD↔MXN. Cards format as
  `currencyFormat.format(value * conversionFactor)` with an injected format + factor.
- Dates via `intl` `DateFormat`, kept in sync with the app locale by `syncIntlLocale`; use
  locale-aware skeletons (`DateFormat.yMMM()`), not hardcoded patterns where a skeleton exists.
- Percent: always `utils/percent_format.dart` (§2).

## 7. Testing

Tests mirror `lib/` (`test/utils`, `test/widgets`, `test/services`, `test/l10n`, `test/theme`).
`flutter test` — standard `expect(...)` with `findsOneWidget` / `equals` / `isTrue`, grouped
with `group(...)`.

- **Extracted `utils/` logic gets a unit test.**
- **Locale/render-sensitive code gets a widget test** built on a minimal `MaterialApp` host
  supplying `AppLocalizations.localizationsDelegates` / `supportedLocales` + a `Builder`, then
  `pumpAndSettle`.
- **Test user-facing strings in BOTH en and es.** Normalize whitespace codepoints (U+00A0 /
  U+202F → plain space) with a `_normSpace` helper so es "NBSP before %" is proven without
  pinning the exact codepoint. Test both plural cases.
- **Name bug-fix tests after the fix** (`fix2_regressions_test.dart`, `net_worth_yaxis_test.dart`).
- Tests deliberately avoid pumping real app screens (a `package:web` widget-test hazard) — test
  cards/utils in isolation instead.

## Anti-patterns to avoid

- Adding to god files (`dashboard_screen.dart`, `api_service.dart`, `net_worth_card.dart`) —
  extract to `utils/` and split cards instead.
- Forking another copy of `chart_time_axis` / `chart_touch` — use the shared helpers.
- `Colors.white70` / hex colors — use the `context` extension or fail light-mode contrast.
- Raw `_client` calls bypassing the verb wrappers (lose CSRF / 401 / cache handling).

## Definition of done (frontend change)

- [ ] No hand-rolled money/percent strings; formatting via `currency.dart` / `percent_format.dart`.
- [ ] No hardcoded colors; all via the `context` extension.
- [ ] Any new/changed l10n placeholder: call site matches the **alphabetical** generated
      signature, with a `// gen-l10n orders …` comment.
- [ ] User-facing strings added to BOTH `app_en.arb` and `app_es.arb`.
- [ ] Network calls go through `_get/_post/...`; dashboard GETs cached; errors via `_errorFromBody`.
- [ ] Responsive sizing off the inner `LayoutBuilder` width with the established breakpoints.
- [ ] Custom charts mirror data into the semantics tree.
- [ ] Unit test for extracted logic; bilingual widget test for locale-sensitive strings.
- [ ] `flutter analyze` clean; `flutter test` green.
