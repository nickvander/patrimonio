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
5. **Top-level `package:http` calls (`http.get`/`http.post`) from a screen** — the browser
   attaches the session cookie for free on web, but on native Android they go out
   **anonymous** → 401s that only reproduce in the APK. Use `ApiService` or a
   `createApiClient()` instance. (§3, §8)

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

Never write `'$v%'` by hand. Enforced: `test/conventions/no_handrolled_percent_test.dart`
fails any hand-rolled `…}%`-style percent outside `lib/utils/`.

## 3. Networking — the ApiService layer

Single `ApiService` over `package:http` (no dio). Platform-split base URL/client via
conditional imports. The class is split by domain into `part` files
(`services/api_service/{auth,dashboard,transactions,holdings,lending,rules}.dart`), one
**private mixin** per domain (`_AuthApi`, `_DashboardApi`, `_TxApi`, `_HoldingsApi`,
`_LendingApi`, `_RulesApi`) composed into `ApiService` over the `_ApiServiceBase` plumbing
surface declared in `api_service.dart` (which keeps the verb wrappers, CSRF, cache
glue, and the `debugHttpClientOverride` test seam). Add new endpoints to the
matching part file's mixin. Mixins, NOT extensions, on purpose: several widget
tests fake the service with `extends ApiService` + `@override` on endpoint
methods — extension members dispatch statically and would silently bypass those
fakes.

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
- **Never call top-level `http.get`/`http.post`.** They bypass the shared cookie jar, so on
  native the request carries no session cookie and 401s — web hides the bug because the
  browser attaches it for free (this shipped: `connect_bank_screen.dart` went out anonymous
  on Android). A screen that can't use `ApiService` holds a `createApiClient()` instance
  (`final http.Client _http = createApiClient();`) and `close()`s it in `dispose()`.
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
  - Enforced: `test/conventions/no_raw_colors_test.dart` fails any raw `Colors.*` (except
    `transparent`) outside the theme layer and its frozen per-usage allowlist.
- **Typography (`theme/typography.dart`):** Inter for all UI. `brandDisplayStyle(...)`
  (JetBrainsMono, tabular figures) ONLY for signature big numbers (net-worth hero, stat
  strip); `brandSectionTitleStyle(...)` for labels above heroes. JetBrainsMono maxes at w700.
- **Card idiom:** `Card(elevation: 4, shape: RoundedRectangleBorder(borderRadius:
  BorderRadius.circular(20)))` with inner `Padding`.
- **Menu chrome is centralized in `theme/menus.dart`** — `buildPopupMenuTheme` /
  `buildMenuTheme` are installed in BOTH themes in `main.dart`, so `PopupMenuButton` /
  `showMenu` / `MenuAnchor` get the house chrome (cardSurface, 12px radius, no M3 tint,
  house type at height 1.35) for free. The legacy dropdown route has **no theme hook**:
  every `DropdownButton` / `DropdownButtonFormField` site must pass
  `dropdownColor: houseDropdownColor(context)` + `borderRadius: kMenuRadius` — never
  inline a color or radius at a dropdown site.
- **Form-field decoration is centralized in `theme/fields.dart`** —
  `houseFieldDecoration(context, labelText: …)` is the house recipe (filled on
  `context.tileSurface`, `kHouseFieldRadius` = 12 rounded, `BorderSide.none`,
  `isDense`). Every dialog/sheet field goes through it; a tappable
  `InputDecorator` gives its `InkWell` `borderRadius: BorderRadius.circular(
  kHouseFieldRadius)`. Two consequences: **don't put house fields on a
  `tileSurface` background** (same tone, no border ⇒ invisible field — the
  lending `_section` cards went outline-only for this), and there is **no focus
  ring** by design. The 2026-08-02 sweep landed this recipe as a private
  `_fieldDecoration` copied into five panels; those copies are still there
  (`add_transaction_dialog`, `add_account_dialog`, `add_crypto_dialog`,
  `quick_entry_sheet`) — point new code at the shared helper, and fold a copy in
  when you're already editing its file. Enforced for the panels that adopted it
  by `test/widgets/dialog_house_idiom_test.dart`.
- **Form panels present sheet-on-narrow, dialog-on-wide** via an
  `open…Panel(context, …)` helper that does the split at
  `kCompactLayoutBelow` (`openAddTransactionPanel`,
  `openAddRecurringRulePanel`). This is the one sanctioned `MediaQuery` read
  in layout code — it picks which MODAL to launch over the whole screen, not
  how to lay out content in a card. The widget takes an `asSheet` flag and
  renders `_dialogShell` / `_sheetShell` off it; the sheet pins a full-bleed
  ≥48dp primary above `MediaQuery.viewInsetsOf(context).bottom`. Route ALL
  hosts through the helper or the two presentations diverge.
- **Standalone action buttons follow `theme/buttons.dart`:** touch-width layouts (inner
  card width < `kActionButtonStackBelow` = 520) go full-bleed and stacked;
  pointer-width layouts size to the label, bounded by
  `kActionButtonMinWidth`/`MaxWidth` (180–320) at `kActionButtonHeight` (40dp, the M3
  Expressive Small step) — use `actionButtonWidth` / `actionButtonConstraints`. Full-bleed
  carried to a 1440px window turns a button into a banner; that's the bug the file exists
  to prevent.
- **Responsiveness is width-driven — off the INNER `LayoutBuilder` constraint, not the
  screen.** The trends mobile-overflow fix reads `outer.maxWidth`, not `MediaQuery`. Established
  breakpoints: **~420** (phone), **~520** (Row→Column header stack, `kActionButtonStackBelow`),
  **~720** (card density — padding 16 vs 24, shorter plots, side-by-side folded; the shared
  `kCompactCardBelow` in `theme/buttons.dart`, next to `kCompactLayoutBelow` = 560; don't
  re-declare a private 720). Derive `chartHeight` / `barWidth` / label-thinning from the
  constraint. To avoid x-label overlap, compute an adaptive step (~1 label per 46px phone /
  62px wide) and skip labels that don't land on it (always keep the last).
- **A `LayoutBuilder` cannot live under an `IntrinsicHeight`** (or any intrinsic-dimension
  query) — Flutter asserts *"LayoutBuilder does not support returning intrinsic dimensions"*.
  When a widget inside an equal-height row needs a width-derived flag, **thread the flag down**
  from the nearest legal constraint instead of nesting a builder: `tax_planning_screen.dart`'s
  `_kpiCard` / `_compactLiabilityTile` take a `dense` bool computed once in `build` for exactly
  this reason (and their density is a property of the row anyway).
- **Phone idioms (below the ~420 inner breakpoint):** touch targets ≥48dp with 8dp gaps;
  card titles compress to a compact overline (12px w700 `context.textSubtle` — the bottom
  nav already names the surface); gate every phone-only change on the inner `LayoutBuilder`
  width so wide layouts don't regress. Forced-visible `Scrollbar` thumbs are a **pointer**
  affordance — touch platforms get the transient auto-hiding thumb (`thumbVisibility:
  !isTouch`, see `transactions_tab.dart`). Small fixed option sets use
  **`ConnectedSegments<T>`** (`widgets/connected_segments.dart`) — the house M3 Expressive
  connected button group, extracted from the theme picker's inline recipe and now on 9+
  call sites (theme picker, Filter & sort editor, cash-flow period selector, lending, tax
  filing status, add-transaction Expense/Income, quick-entry Spent/Received, …). Don't use
  `SegmentedButton` and don't
  fork the recipe inline. API: a list of `ConnectedSegment(value, label, icon?)` +
  `selected` + `onSelected` (fires on re-taps too — callers that persist on change
  short-circuit no-ops) + an additive `enabled` flag that renders SegmentedButton-style
  disabled tones. Equal-flex 44dp segments, 2px gaps, selected segment morphs into a
  filled `secondaryContainer` pill; selection is mirrored into semantics. The
  **A `ScaffoldMessenger` SnackBar renders on the Scaffold, i.e. BEHIND an open
  modal bottom sheet** — a sheet that stays open after its write (the quick-entry
  sheet saves without navigating, so a second expense is one more entry) must put
  its confirmation + Undo in an inline strip inside the sheet; the transactions
  tab's deferred-delete SnackBar idiom only fits a surface the user is looking at.
  The
  compact app bar scrolls away via `utils/bar_scroll.dart` (`barVisibleAfter` — pure,
  unit-tested; `pixels <= 0` forces the bar visible so pull-to-refresh never fights it).
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
  either; use the helper. The copy↔helper equivalence is enforced by
  `test/conventions/chart_touch_equivalence_test.dart` (frozen variances documented there);
  new inline `LineTouchData`/`touchSpotThreshold` forks fail it.
- **Touch scrubs never draw under the finger.** `TransientTooltipLineChart`
  (`utils/chart_touch.dart`) tracks the active pointer kind: mouse/trackpad keep the
  near-spot popover, touch/stylus pin the tooltip to the top of the chart box. That
  is only enough for a TALL plot — for a short one (the performance card's is 120px
  on phones; a 3-line tooltip is ~64) the pinned readout still lands under the hand.
  Those charts pass **`suppressTooltipOnTouch: true`** (no in-chart tooltip on touch;
  the vertical guide + dot REMAIN as position feedback) and **`onScrub:`**, and render
  the reading in their own header — the Robinhood/Copilot pattern. Adopted by
  `performance_card.dart` (headline + return pills swap to the scrubbed values, the
  date replaces the caption) and `net_worth_card.dart` (hero number + label, or the
  compact overline on phones). A host that sets `suppressTooltipOnTouch` **must**
  render `onScrub` somewhere clear of the hand, must clear its reading whenever the
  plotted series changes (range/benchmark/FX-free replot), and must expose it to screen
  readers (`lwChartScrubReading` + `liveRegion`) — it replaces a tooltip they never
  saw. Keep the host's scrub state in a `ValueNotifier` + `ValueListenableBuilder`
  around the header only: a scrub fires per pointer move, and a `setState` would
  re-run the whole card's series math each frame of the drag.
- **Hand-painted charts inherit NONE of the above.** `cash_flow_sankey_card.dart` is the
  first (fl_chart has no Sankey; adding a dependency for one diagram was rejected). A
  `CustomPainter` gets no `chart_touch.dart` pinning, no semantics, and no automatic
  overflow protection, so a painted chart owns all three by hand: put the tap readout in
  a fixed strip in the card **header** (asserted in test: the readout rect must not
  contain the tap point and must sit above the canvas), mirror the flows into
  `Semantics(label:)` with `ExcludeSemantics` over the paint (a canvas is invisible to
  screen readers), and **clip the painter to its bounds** (`canvas.clipRect` — a
  `CustomPaint` does NOT clip by default, so a fallback label placement will happily
  paint outside the widget). Keep the geometry + data model in a **pure `utils/` file**
  (`utils/cash_flow_sankey.dart`) and unit-test it there; the widget should only paint.
  **Painted labels need real collision avoidance, not just ellipsis.** Centring each
  label on its own node overprints as soon as two nodes are close — value-sized nodes
  make a small one ~1px tall — and the first Sankey shipped with 4 of 6 value labels
  illegible while all 43 of its tests passed. The house pattern is `placeSankeyLabels`:
  per column, drop the lowest-value labels when the column can't fit them all (their
  value stays reachable via the tap readout), then relax the survivors apart with a
  forward+backward pass and clamp into the canvas. Distinguish similar names with
  **middle-elision biased to the tail** (`middleEllipsize`) — bank labels discriminate at
  the end, so head-truncation renders two different sources as the same string. Prefer
  exact money and fall back to compact only when it measures too wide: a diagram whose
  claim is that it reconciles with the card above it must not print `$50.6` beside that
  card's `$50.60`. Assert non-overlap **geometrically** in tests — pumping the widget
  proves nothing, since it renders happily while unreadable.
  **Reconciliation is the correctness bar for any derived diagram:** the Sankey shares
  `SpendingByCategoryCard`'s exact `top` param so it reuses that `_cachedGet` entry, and
  its totals are asserted equal to the numbers `MonthlyCashFlowCard` prints for the same
  period — a diagram that disagrees with the card above it is worse than no diagram.
  When a client can't reproduce a server-side aggregate, fail closed to an honest
  unattributed node rather than scaling slices to fit.
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
  cards/utils in isolation instead. **One sanctioned exception:** a
  *cross-widget geometry* property cannot exist in an isolated card — e.g.
  "no control outside the app bar may receive a tap in the body's area"
  (`test/widgets/app_bar_hit_region_test.dart`, which pumps `DashboardScreen`
  against a stubbed backend). When you must, drive with **`tester.tapAt(Offset)`
  on real coordinates, never a finder** — the whole class of defect is that the
  widget tree and the hit region disagree, so a finder-based tap passes while the
  bug is live. Such a test can't be sabotage-checked against HEAD when the defect
  turns out not to exist, so prove it non-vacuous by *injecting* the defect
  (an opaque `GestureDetector` in a `Positioned`, an overhanging
  `toolbarHeight`) and confirming which assertions fail.
- **Reading an inherited widget (`Theme.of`, `MediaQuery.of`) before `initState`
  returns throws** — and if the caller is an unawaited `async` method, the throw
  lands in an orphaned future: the work silently never happens, in debug only,
  because release strips the assert. `dashboard_screen.dart` hit exactly this
  (its first data load aborted, leaving the skeleton up). Defer such calls with
  `addPostFrameCallback` + a `mounted` guard.

## 8. Platform seams — web-only APIs must be isolated (the app targets web AND Android)

The app builds for **web and Android** from one codebase (`flutter build web` and
`flutter build apk`). `dart:js_interop` / `dart:html` / `package:web` /
`package:http/browser_client` compile **only on web** — importing any of them
unconditionally breaks the Android build *and* the Dart test VM. Every web-only
capability is therefore behind a **conditional-import seam**: a neutral
`foo.dart` that `export`s a default (stub/io) impl and swaps in the web impl
under `if (dart.library.js_interop)` (and, where native needs real behaviour, an
io impl under `if (dart.library.io)`).

- **Never import `dart:js_interop` / `dart:html` / `package:web` /
  `browser_client` from a widget/screen/service directly** — put it in a
  `*_web.dart` and reach it through the seam. Seams to copy:
  `services/api_platform` (3-way stub/web/io — native adds a cookie-persisting
  `dart:io` client + a configurable base URL), `preferences_storage`, `splash`,
  `realtime_socket` (`dart:io` WebSocket on native), `utils/web_env`
  (navigate / current-URL), `file_drop`, `plaid_oauth`, `passkeys`. Passkeys
  work on **web (navigator.credentials) AND Android** (Credential Manager via
  the `patrimonio/passkeys` MethodChannel in `MainActivity.kt` — a raw
  WebAuthn-JSON pass-through; `passkeys_io.dart` mirrors the web impl's HTTP
  flow 1:1). Android-side prerequisites (assetlinks.json, the
  `ANDROID_APK_CERT_SHA256` backend var) are in docs/deployment.md. On
  desktop/test-VM `isAvailable` is false — always gate passkey UI on
  `PasskeyService.instance.isAvailable`.
- **Conditional-export order + the test-VM trap:** `export 'stub.dart' if
  (dart.library.js_interop) 'web.dart' if (dart.library.io) 'io.dart';`. Web has
  `js_interop`; **native AND `flutter test` both have `dart.library.io`** — you
  can't distinguish them at compile time. If an io impl holds process-global
  state (e.g. the prefs cache), gate reads/writes behind an explicit `init()`
  that only `main()` calls, so widget tests (which never run `main()`) keep the
  old inert-stub behaviour and stay isolated. (This is exactly what bit the
  projection tests during the Android port.)
- **Backend URL:** web derives it from `window.location` (same-origin nginx
  `/api`); native has no origin, so it comes from `services/backend_config.dart`
  (the Settings screen, persisted via shared_preferences) and is
  bake-in-able via `--dart-define=API_BASE_URL=…`. `screens/root_gate.dart` shows
  the setup screen on native until a URL is set; web goes straight to `AuthGate`.
- **Session auth:** the browser cookie jar carries the session cookie for free;
  native `package:http` drops `Set-Cookie`, so `api_platform_io` wraps a
  `dart:io` client that captures and re-sends it — and the cookie only rides on
  clients from `createApiClient()`, never top-level `http.get/post` (§3). The
  jar is mirrored into Keystore-backed secure storage (`flutter_secure_storage`,
  NOT shared_preferences — the cookie is a full-access credential) behind the
  same `init()` gate as prefs: `main()` calls `initSessionPersistence()`, and
  the mirror is cleared on logout, any 401, and "Change server". The cookie is
  `HttpOnly`+`Secure`+`Lax`; HttpOnly does **not** block the native client (it
  only hides the cookie from browser JS).
- **Per-host headers + the WS handshake:** all three `api_platform` impls must
  export the same surface — `apiBaseUrl/apiWsUrl/currentHost/apiExtraHeaders/
  wsHandshakeHeaders/createApiClient/initSessionPersistence/clearPersistedSession`
  (the last two are no-ops on web/stub — the browser jar already persists). `apiExtraHeaders()` is stamped on every
  HTTP request (web: ngrok skip header; io: the optional **Cloudflare Access
  service token** from `BackendConfig` as `CF-Access-Client-Id/Secret`).
  `wsHandshakeHeaders()` exists because the browser WebSocket attaches
  cookies/CF-cookies itself but forbids custom headers (web impl returns `{}`),
  while `dart:io`'s WebSocket attaches nothing — the io impl returns the session
  cookie from the shared jar + the CF token, or the realtime upgrade is
  rejected. If you add a function to one impl, add it to all three, or the
  analyzer (which resolves the *stub*) breaks.

## Anti-patterns to avoid

- Adding to god files — `dashboard_screen.dart` (7,746 lines), `transactions_tab.dart`
  (~4,250; its detail panel now lives in `transaction_detail_panel.dart` behind
  the `TransactionDetailHost` interface) — extract to `utils/` / new widgets and
  split cards instead (the
  `CashFlowPeriodSelector` and `ConnectedSegments` extractions are the pattern;
  `lending_tab.dart`, `portfolio_card.dart`, and `api_service.dart` have already
  been split — `api_service.dart` into domain part-file mixins, so new endpoints
  go in the matching `services/api_service/*.dart` part, §3).
- Forking another copy of `chart_time_axis` / `chart_touch` — use the shared helpers.
- `Colors.white70` / hex colors — use the `context` extension or fail light-mode contrast.
- Raw `_client` calls bypassing the verb wrappers (lose CSRF / 401 / cache handling).
- Top-level `http.get`/`http.post` anywhere (no cookie jar on native → APK-only 401s) —
  use `ApiService` or a `createApiClient()` client.

## Definition of done (frontend change)

- [ ] No hand-rolled money/percent strings; formatting via `currency.dart` / `percent_format.dart`.
- [ ] No hardcoded colors; all via the `context` extension.
- [ ] Any new/changed l10n placeholder: call site matches the **alphabetical** generated
      signature, with a `// gen-l10n orders …` comment.
- [ ] User-facing strings added to BOTH `app_en.arb` and `app_es.arb`.
- [ ] Network calls go through `_get/_post/...` (or a `createApiClient()` client — never
      top-level `http.*`); dashboard GETs cached; errors via `_errorFromBody`.
- [ ] Responsive sizing off the inner `LayoutBuilder` width with the established breakpoints;
      phone-only tweaks gated on it; touch targets ≥48dp.
- [ ] Custom charts mirror data into the semantics tree.
- [ ] Unit test for extracted logic; bilingual widget test for locale-sensitive strings.
- [ ] No unconditional `dart:js_interop` / `package:web` / `browser_client` import outside a
      `*_web.dart`; any new web-only capability is behind a conditional-import seam (§8).
- [ ] `flutter analyze` clean; `flutter test` green; **both `flutter build web` and
      `flutter build apk` compile** (a web-only import that slips in breaks only the APK).
