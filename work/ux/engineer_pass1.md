# Engineer pass 1 — Sprint 1 UX + brand changes

> Implemented against `pm_plan.md` (Sprint 1) and `market_research.md`.
> Date: 2026-05-30. All changes left in the working tree (no commit).

## Gate results (final)

- `flutter analyze`: **0 `error •` / 0 `warning •`** lines (18 info-level
  issues, all pre-existing — unchanged from baseline).
- `flutter test`: **All 107 tests passed** (baseline was 94; +13 new).
- `test/theme/palette_contrast_test.dart`: **green (23 tests)** — every brand
  accent clears WCAG AA on its target surface.

---

## Item 1 — Idiomatic money formatting + tabular figures  (DONE)

**Files:** `lib/utils/currency.dart`, `lib/widgets/net_worth_card.dart`,
`lib/screens/dashboard_screen.dart`, `test/utils/currency_test.dart` (new).

- `formatCurrencyAmount` now renders `$1,234.00` (USD) and `MX$47,651.01`
  (MXN) via a `_currencySymbols` map; unknown codes fall back to the ISO
  prefix (`EUR 10.00`). Negative/zero handling preserved by `NumberFormat`.
- Added `currencySymbol(code)` and `moneyFormat(code)` helpers so the
  dashboard's shared `currencyFormat` (fed to the hero and every card)
  produces idiomatic symbols too — replaced the two
  `NumberFormat.currency(name: X, symbol: '$X ')` sites in
  `dashboard_screen.dart` with `moneyFormat(_targetCurrency)`.
- Net-worth hero number already had `tabularFigures()`; added it to the
  per-currency source-breakdown chips as well.
- Removed the mystery `" source"` suffix at `net_worth_card.dart:230` — the
  chip's symbol already names the currency, so the bare word was noise.
- Tests: USD, MXN, lower-case normalisation, unknown-code fallback,
  negative, zero, large MXN (7 cases).

## Item 2 — Unify supported-bank copy  (DONE)

**Files:** `lib/utils/supported_banks.dart` (new), `lib/screens/dashboard_screen.dart`,
`lib/screens/import_screen.dart`, `test/utils/supported_banks_test.dart` (new).

- New `kSupportedMxBanks = ['Nu México', 'Banamex', 'Cetesdirecto']` — the
  exact live-parser set confirmed in
  `backend/src/services/parser/mod.rs` (nu_mexico, banamex, cetes + PDF
  variants). Bancomer/Santander/Banorte have no parser and are gone.
- `supportedMxBanksSentence()` renders the Oxford-style list; both the
  onboarding hero and the import subtitle now interpolate it, so they can't
  drift.
- Tests: constant equals the parser set, excludes the three unsupported
  banks, and the shared sentence reads correctly (4 cases).

## Item 3 — Wire the help link + parameterize exchange copy  (DONE)

**Files:** `lib/widgets/add_crypto_dialog.dart`,
`test/widgets/add_crypto_dialog_test.dart` (new).

- `url_launcher` was already a dependency. The "Where do I find my API
  keys?" link now calls `launchUrl(...)`; if no handler is registered it
  falls back to an info dialog with the docs URL as `SelectableText`.
- Added an `_exchangeInfo` map keyed by exchange (label, docs URL, example
  display name). Title, intro copy, help URL, and the display-name hint are
  all parameterized — Coinbase no longer shows "Bitso"/"My Bitso". Adding a
  new exchange is a one-entry change.
- Tests: Bitso dialog shows Bitso copy + tappable link (no throw on tap);
  Coinbase dialog shows Coinbase copy and contains no "Bitso" string.
  (Did NOT subclass ApiService — per MEMORY; the dialog's internal
  `ApiService()` is VM-safe via the conditional `api_platform` export.)

## Item 4 — Brand re-skin  (DONE)

**Files:** `lib/theme/palette.dart`, `lib/theme/typography.dart` (new),
`lib/main.dart`, `lib/widgets/net_worth_card.dart`.

- **Seed:** `emeraldDark/emeraldLight` re-valued to agave jade
  (`#3FD3AE` dark / `#0C6A56` light). `positive` follows the seed.
- **Heritage accents:** new `terracotta(b)` and `gold(b)` tokens, wired as
  ColorScheme `secondary`/`tertiary` in both themes.
- **Semantics tuned to the family:** negative → warm brick
  (`#B23A2E`/`#FF6B5C`), warning → amber (`#9A5F12`/`#F2B544`), info → lake
  blue (`#2A6F9E`/`#5BB4E8`). teal/pink/purple/neutral left unchanged (not
  part of the heritage thesis and already AA).
- **Warm neutrals:** light scaffold `#F6F3EC` (parchment), raised `#F2EFE9`
  (bone); dark scaffold `#10140F`, card `#1A201E`, raised `#262E2B`. AppBar
  + dataTable headings follow.
- **Typography:** `buildBrandTextTheme` keeps Inter for body/UI and overlays
  **Fraunces** on the display/headline slots. The net-worth hero number uses
  `brandDisplayStyle` (Fraunces + tabular + lining figures); the "Total net
  worth" label uses `brandSectionTitleStyle`. Applied tastefully, not
  everywhere.

### Brand hexes I adjusted for AA (before → after)

| Token (light) | Research hex | Ratio | Adjusted to | Ratio | Why |
|---|---|---|---|---|---|
| positive / seed | `#0E7C66` | 5.13 on white BUT 3.97 on light tooltip bg | `#0C6A56` | 6.54 / 5.06 | dark-mode tooltip uses the light-shade positive; had to clear AA in both placements |
| warning | `#B5701A` | 3.96 on white | `#9A5F12` | 5.22 | below AA-normal on white |
| terracotta (secondary) | `#C2683C` | 3.93 on white | `#A8542C` | 5.29 | safe as foreground text |
| gold (tertiary) | `#C79A3A` | 2.59 on white | `#8C6A1C` | 5.01 | research gold far below AA; darkened so totals-in-gold stay readable |

Dark-mode research hexes all passed AA as-is on the new `#1A201E` card.

## Stretch — Dual-currency net-worth hero  (SKIPPED)

Deferred per the spec's "skip if time/risk is high" guidance. Items 1-4 are
complete, green, and individually shippable; the animated digit-rolling
USD⇄MXN toggle is M-effort and would touch the hero's render path + add
animation state, raising regression risk against a now-clean suite. The
currency toggle already exists at dashboard level (`_targetCurrency`) and the
hero already renders in the display font with tabular figures, so this is a
good standalone Sprint-2 follow-up rather than a rushed add-on here.
