# Patrimonio — Brand Identity & Design Direction

> Market research + brand/design recommendation. 2026-05-30.
> Audience: a self-hostable, privacy-respecting US↔MX personal-finance tracker.
> Goal: easy, modern, performant, and **beautiful with a DISTINCT identity**.

---

## 1. Landscape summary — and the "sea of sameness"

The 2025–26 consumer-finance category has converged hard on a small visual
vocabulary. The pattern is consistent across category leaders:

- **Monarch Money** — neutral base (navy/slate/charcoal + white) with a warm
  coral butterfly accent. Their 2025 brand refresh was explicitly about
  *contrast + "warmth and approachability"* and retiring the old "Navy Mode"
  dark theme. Personality words: simplicity, ease, collaboration (two lines
  joining = managing money with a partner).
  [Monarch brand refresh](https://www.monarch.com/monarch-brand-refresh),
  [Monarch hex sample #395384/#a2b4d7](https://colorswall.com/palette/12155)
- **Copilot Money** — clean white canvas, a blue "forward arrow" growth motif,
  and a multi-hue data-viz set (blue #0078d4, green #5cb85c, gold #f4d35e,
  purple #8e44ad). Polished, Apple-adjacent, calm.
  [Copilot dashboard line colors](https://help.copilot.money/en/articles/10309907-dashboard-line-colors),
  [Copilot palette](https://colorswall.com/palette/557664)
- **YNAB** — playful blue/green, rounded, didactic/coaching tone.
- **Rocket Money** (formerly Truebill, ~15M MAU) — dark UI, neon-green accent,
  subscription-cancelling hook.
- **Empower / Personal Capital** (~7M MAU) — sober navy "wealth-management"
  blues aimed at FIRE/investment users.
- **Lunch Money** — indie, slightly retro/pixel, multi-currency-friendly, warm.
- **Mexican fintechs:** **Nubank** owns a bold **purple** with an expanded
  art/fashion/culture-inspired palette and the **Gellix** typeface; brand
  ethos is "fighting complexity to empower people" with strong Latin-American
  DNA. **Klar** and **Hey Banco** lean modern/vertical-card, bold-color.
  [Nu brand system](https://building.nubank.com/nu-brand-system/),
  [Nubank new logo](https://building.nubank.com/new-logo-nubank/),
  [neobank card trends](https://fintechbranding.studio/fintech-card-design-trends)

**Where the sameness lives** (what Patrimonio must avoid):
pastel gradients, friendly geometric sans, pill toggles, decorative
illustration fluff, and "another teal/emerald/purple dashboard." Industry
writers now name this saturation directly and call the corrective *structural,
purposeful* design — "architecture with attitude," motion that explains,
elegant **serif** headlines paired with **ledger-style numerals** that read
"like a well-designed tax report, not a pitch deck."
[Tubik 2026 UI trends](https://blog.tubikstudio.com/ui-design-trends-2026/),
[Eleken fintech guide](https://www.eleken.co/blog-posts/modern-fintech-design-guide),
[ProCreator finance app 2026](https://procreator.design/blog/finance-app-design-best-practices/)

**Mint's 2024 shutdown** is a positioning gift: it stranded loyal users who
valued *longitudinal* data (month-over-month trends, full net-worth history)
that Credit Karma dropped. The lesson — *people grieve the loss of their
financial history.* A tool that treats history as permanent, owned, and
heritable is emotionally differentiated.
[CNBC on shutdown](https://www.cnbc.com/2023/11/07/budgeting-app-mint-is-shutting-down-users-are-disappointed.html),
[Monarch: what Mint users should do](https://www.monarch.com/blog/mint-shutting-down)

**Today's Patrimonio palette** (`frontend/lib/theme/palette.dart`) is squarely
*in* the sea: a neon-emerald seed (`#00E676` dark / `#00A352` light) + Inter.
That is Rocket-Money-green. It's well-engineered for contrast/WCAG but carries
no story and reads generic. The recommendation below keeps the disciplined
brightness-aware token architecture and **re-skins the seed + type** to claim
a territory none of the above own.

---

## 2. Positioning — the one territory to own

> **Patrimonio is the cross-border net-worth ledger for life lived in two
> countries — a bilingual, privacy-owned record of *patrimonio* (heritage/
> estate) that no app can shut down, spanning USD and MXN as first-class
> equals.**

Nobody competes here. Monarch/Copilot/YNAB are mono-currency, US-only, cloud-
locked. Nubank/Klar are single-country issuers, not aggregators. Patrimonio's
moat is the **US↔MX, bicultural, heritage** angle plus **self-hosting**. Lean
into the literal meaning of the name: not "budgeting," but *building and
stewarding patrimony* — including lending to family and passing data down.
Tone is warm, grounded, dignified — *estate*, not *spreadsheet*; *both
countries*, not "international."

---

## 3. Brand identity recommendation

### Personality (5 adjectives)
**Rooted · Bicultural · Trustworthy · Quietly premium · Clear-eyed.**
(Warm like heritage, exact like a ledger. Never cutesy, never austere.)

### Tone of voice
Plain, calm, second-person. Treat **EN/ES as equals**, never EN-with-a-
translation-afterthought. Bilingual treatment:
- A real language toggle (EN / ES) — not machine strings; hand-tuned.
- Let Spanish surface as *texture*, not just localization: the app name,
  section headers ("Patrimonio neto" = net worth), empty-states, and a
  tasteful occasional Spanish micro-label even in EN mode (a small `MXN`/`USD`
  pill, "patrimonio" as the net-worth word) so the bicultural identity is
  felt, not buried in a settings menu.
- Money copy uses the correct Unicode: minus sign `−` (U+2212), real
  currency symbols. [Fintech typography](https://medium.com/design-bootcamp/the-elements-of-fintech-typography-part-1-readable-money-b6c1226acbde)

### Color palette

Move **off neon-emerald-green** (the most generic finance accent) onto a
distinctive, heritage-warm system: a deep **agave / Oaxacan jade** primary
paired with a **warm terracotta/amber** secondary — colors that read both
"Mexican craft heritage" and "money/growth" without being Rocket-Money-green
or Nubank-purple. Semantics stay conventional (green-up/red-down) but tuned to
the family so the dashboard feels of-a-piece.

**Light mode**
| Role | Hex | Rationale |
|---|---|---|
| Primary (brand seed) | `#0E7C66` | Deep agave jade — money/growth heritage, distinct from #00A352 neon |
| Primary container | `#C9E9DF` | Soft jade wash for hero/cards |
| Secondary (accent) | `#C2683C` | Warm terracotta — bicultural craft, CTAs, MX-side |
| Accent gold | `#C79A3A` | Patrimony/heritage gold, sparingly (totals, milestones) |
| Success / gain | `#0E7C66` | Same as primary — gains *are* the brand |
| Warning | `#B5701A` | Amber, distinct from terracotta |
| Error / loss | `#B23A2E` | Warm brick red (not pure #FF red) |
| Info / cash | `#2A6F9E` | Muted lake blue |
| Surface (card) | `#FFFFFF` | Pure white |
| Surface raised | `#F2EFE9` | Warm bone (not cool gray) — the "paper/ledger" signal |
| Scaffold bg | `#F6F3EC` | Warm parchment so white cards sit on warmth |
| Text primary | `#1C2421` | Near-black with green undertone |

**Dark mode** (keep the engineered contrast discipline; warm the neutrals)
| Role | Hex | Rationale |
|---|---|---|
| Primary (seed) | `#3FD3AE` | Bright jade — brand signature in dark, NOT #00E676 |
| Secondary (accent) | `#E08A57` | Glowing terracotta |
| Accent gold | `#E3B85A` | Heritage gold for totals/milestones |
| Success / gain | `#3FD3AE` | |
| Warning | `#F2B544` | |
| Error / loss | `#FF6B5C` | Warm coral-red |
| Info / cash | `#5BB4E8` | |
| Surface (card) | `#1A201E` | Charcoal with green undertone (vs today's cool #1A1A24) |
| Surface raised | `#262E2B` | |
| Scaffold bg | `#10140F` | Near-black warm green-black |
| Text primary | `#ECEFEA` | Warm off-white |

**Contrast with today:** today's seed is cool neon green on cool charcoal/
blue-gray (`#101016`/`#1A1A24`). The proposal *warms the entire neutral ramp*
(parchment/bone in light; green-black charcoal in dark) and swaps neon for
**jade + terracotta + heritage gold** — a palette that no competitor uses and
that literally evokes Mexican craft + estate/ledger paper. Keep the existing
`BrandPalette` brightness-aware token machinery; only the values change.

### Typography
- **Display / headlines:** **Fraunces** (Google Fonts) — a warm, slightly
  "old-style" serif with optical sizing. Delivers the 2026 "elegant serif that
  reads like a well-made tax report" signal and the heritage/estate feel.
  Use for the net-worth hero, section titles, big numbers' label.
- **Body / UI:** **Inter** (keep — already in `pubspec.yaml`) or upgrade to
  **IBM Plex Sans** for a touch more character with excellent ES diacritics.
  Inter is the safe, performant, already-shipped choice. Recommend keeping
  Inter for UI to avoid re-layout risk; introduce Fraunces only for display.
- **Money / tabular numerals:** render *all* currency in **tabular lining
  figures**. Inter and IBM Plex both support `tnum`/`lnum`; enable
  `FontFeature.tabularFigures()` so columns align. For an extra ledger flavor
  on the big hero number, **IBM Plex Mono** (tabular by nature) is a strong
  signature pick. [Readable money](https://medium.com/design-bootcamp/the-elements-of-fintech-typography-part-1-readable-money-b6c1226acbde),
  [fonts for fintech](https://fontalternatives.com/best-fonts-for/fintech/)

### Logo / iconography direction
A mark built on **two converging strokes forming an arch/keystone** — reading
simultaneously as (a) an "A"/peak (Patrimoni**A**), (b) a *casa*/roof =
estate/home/heritage, and (c) two paths (US + MX) meeting. Render in jade with
a terracotta or gold keystone accent. Avoid butterflies (Monarch), arrows
(Copilot), and abstract purple blobs (Nu). Iconography: thin, confident line
icons with slightly rounded terminals; a recurring small **two-tone currency
pill** (`$` jade / `$` terracotta) as a brand atom. Subtle *talavera*-tile
or woven-textile geometric motif reserved for empty-states and the heritage
timeline — heritage texture used sparingly, never as wallpaper.

### 5 signature UI moves
1. **The dual-currency net-worth hero.** One Fraunces big number with a
   tactile **USD ⇄ MXN toggle** that doesn't just swap symbols — it *animates
   the digits rolling* between converted values and shows the FX rate +
   as-of-date inline. Tap-and-hold to see both side-by-side. This is the
   product's thesis in one widget.
2. **"Patrimonio" heritage timeline.** Net-worth history as a horizontal,
   scrubbable timeline framed as a *family record* — milestones, the literal
   "since you started" anchor, and (Mint-shutdown lesson) a visible "your data,
   forever, exportable" assurance. History is the keepsake.
3. **Two-country ledger split.** A persistent, beautiful **US | MX** divider
   motif (jade side / terracotta side) on accounts and cash-flow views so the
   bicultural split is always legible at a glance — not a filter you toggle.
4. **Rolling tabular figures everywhere money lives.** Every balance update,
   sync, and FX conversion animates via odometer-style rolling tabular
   numerals. Cheap, distinctive, and reinforces "ledger precision."
5. **Family-lending "promissory" cards.** The existing lending feature gets a
   signature treatment: each loan rendered as a warm parchment "note" card
   (bone surface, gold seal accent, Fraunces heading) — turning a niche feature
   into a recognizable brand moment that says *patrimony, stewarded across a
   family.*

---

## 4. Flutter implementation notes

Maps cleanly onto the current architecture — `BrandPalette` already centralizes
brightness-aware tokens and `theme_colors.dart` already exposes semantic
accessors, so this is mostly a **values-only** change plus two `ThemeData`
seed swaps in `main.dart`.

**Mapping**
- `ColorScheme.fromSeed(seedColor: ...)` in `_buildDarkTheme`/`_buildLightTheme`
  (`main.dart:101,143`): swap seed to **`#0E7C66`** (light) / **`#3FD3AE`**
  (dark). Set `secondary`/`tertiary` overrides to terracotta + gold.
- `BrandPalette.emeraldDark/emeraldLight` and every `positive()/negative()/...`:
  update hex per the tables above. The 165-callsite indirection means the whole
  app re-skins from this one file — the contrast unit test
  (`test/theme/palette_contrast_test.dart`) guards AA automatically.
- `scaffoldBackground/cardSurface/elevatedSurface`: move to the warm
  parchment/bone (light) and green-black charcoal (dark) values.
- Typography: `GoogleFonts.interTextTheme(...)` (`main.dart:107,156`) stays for
  body; add `GoogleFonts.fraunces(...)` on `displayLarge/headlineMedium` in the
  TextTheme. Add a shared money TextStyle with
  `fontFeatures: [FontFeature.tabularFigures(), FontFeature.lining()]`.

**Cheap vs expensive**
- *Cheap (hours):* recolor `palette.dart`; add tabular-figure feature to money
  styles; add Fraunces display font (google_fonts already a dep — no asset
  bundling). Warm the surface neutrals.
- *Medium:* the rolling-tabular-number animation; the USD⇄MXN hero toggle
  animation; the US|MX ledger-split motif.
- *Expensive / later:* new logo asset, talavera texture system, the full
  heritage-timeline interaction, parchment lending-note cards.

**Do these 3 first (ship this week):**
1. **Re-seed the palette** in `palette.dart` (jade primary, terracotta
   secondary, warm neutrals) — single file, test-guarded, instantly de-
   genericizes the whole app off Rocket-Money-green.
2. **Tabular figures + Fraunces display** — add `FontFeature.tabularFigures()`
   to all money text and Fraunces to the net-worth hero/section titles. Big
   perceived-quality jump, near-zero risk (google_fonts already present).
3. **The dual-currency net-worth hero** with the animated USD⇄MXN toggle + FX
   as-of line — the single most ownable, on-thesis widget; build it on the
   existing hero.

---

### Sources
- https://www.monarch.com/monarch-brand-refresh
- https://www.monarch.com/blog/mint-shutting-down
- https://colorswall.com/palette/12155
- https://help.copilot.money/en/articles/10309907-dashboard-line-colors
- https://colorswall.com/palette/557664
- https://building.nubank.com/nu-brand-system/
- https://building.nubank.com/new-logo-nubank/
- https://fintechbranding.studio/fintech-card-design-trends
- https://blog.tubikstudio.com/ui-design-trends-2026/
- https://www.eleken.co/blog-posts/modern-fintech-design-guide
- https://procreator.design/blog/finance-app-design-best-practices/
- https://www.cnbc.com/2023/11/07/budgeting-app-mint-is-shutting-down-users-are-disappointed.html
- https://medium.com/design-bootcamp/the-elements-of-fintech-typography-part-1-readable-money-b6c1226acbde
- https://fontalternatives.com/best-fonts-for/fintech/
