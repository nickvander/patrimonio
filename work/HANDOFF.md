# Handoff — start here

> **Last updated:** 2026-06-06 (Tier B: spending-insight notifications + budget auto-suggest)
> **Purpose:** The single "where are we, what's next" doc to pick up cold.
> For the full import architecture see [work/STATEMENT_IMPORT.md](STATEMENT_IMPORT.md);
> for the older broader backlog see [work/NEXT.md](NEXT.md) and
> [work/FUTURE.md](FUTURE.md).

## TL;DR — current state

Everything below is **on `main` and pushed** (`origin/main` @ `bef9ece`),
tree clean. All verified green: backend `./scripts/test.sh` (full suite,
incl. 82 dashboard integration), `flutter analyze` clean, `flutter test`
(170). Flutter MUST run via docker — see the gotchas at the bottom.

**Shipped this sprint (newest first):**
- Portfolio "Asset distribution" UX pass (browser-verified): aligned
  per-holding rows (name · value · within-class %) with top-4 + "Show N
  more" instead of the inline ticker-chip wall (no longer duplicates the
  holdings table); the allocation endpoint INITCAPs `holding_type` so the
  two duplicate "Cash" bands merge into one; colour map covers Equity/Mutual
  Fund so bands aren't all grey. (`allocation_heatmap.dart`,
  `api/dashboard.rs` asset_allocation, dashboard colour map.)
- Portfolio pie-chart legend no longer overflows: long fund names clamp to
  one ellipsised line (+ hover tooltip), so the legend can't overlap the cards
  below (`portfolio_card.dart` `_buildLegendItem`). Browser-verified.
- Budget **Suggest** UX overhaul (browser-verified end-to-end): a review
  dialog (ranked by spend, top 6 pre-checked, "averages $X/mo", Add N) instead
  of dumping every category; long budget lists collapse behind "Show N more";
  the Suggest icon now renders (see the icon-glyph quirk below). Pure logic in
  `utils/budget_suggestions.dart` (`suggestBudgetsFromInsights` → ranked
  `List<BudgetSuggestion>`), 6 unit tests.
- Tax exports now carry the realized-gains **ST/LT breakdown**: CSV is a
  3-section Form 8949-style export (income txns · per-lot disposals · summary
  with ST/LT split + liabilities + basis note); PDF lists ST/LT lines under
  Capital Gains. `TaxService::get_lot_disposals` + frontend CSV now passes
  `&status=`. (Backlog item cleared.)
- Tier B — spending-insight notifications + budget auto-suggest. New
  `GET /api/dashboard/spending-insights` (per-category recent-complete-month
  vs trailing-average deltas; same cash-flow exclusion SQL). Bell surfaces
  "Rent up 103% vs your 3-month average" rows + a "subscription's price
  increased" row derived client-side from the existing subscription
  detector (a price change splits a merchant into two amount-band clusters).
  BudgetsCard gets a "Suggest" button that seeds the `budgets` setting from
  trailing-average spend. Browser-verified: the spending-up rows render live.
- Realized gains → tax planning: real `lot_disposals` split short/long-term,
  proper LTCG 0/15/20% brackets stacked on ordinary income (was a blended
  cost-basis guess). True contribution-weighted S&P benchmark
  (`/dashboard/benchmark-comparison`) on the BenchmarkCard.
- Broken-font PDFs now auto-route to OCR (`looks_garbled` in parser/mod.rs);
  validated parsers against REAL Banorte/Scotiabank statements (`cargo run
  --bin parse_check <bank> <file>`).
- 3 more MX bank parsers: Banorte, Scotiabank, HSBC (shared
  `parser/column_table.rs`, nearest-column bucketing handles HSBC's reversed
  layout). Banorte+Scotiabank advertised; HSBC unadvertised (needs a clean PDF).
- S&P 500 benchmark (`services/benchmark.rs`, free keyless Yahoo feed,
  FX-style cache) + net-worth-vs-market overlay card.
- Debt-payoff simulator (avalanche vs snowball, `utils/debt_payoff.dart`);
  instant notifications-bell update on low-balance alert change.
- Tier-1 insights: net-worth MoM/YoY growth chips, emergency-fund gauge,
  per-account low-balance alerts, per-category spending trends, 12-month
  recurring-bill forecast, realized-gains card, balance-over-time per account.
- Projection rebuild: real dollars + inflation, decumulation phase, Monte
  Carlo success rate + percentile fan, Coast/Barista FIRE, tax drag +
  Guyton-Klinger guardrails, retirement-income, data-derived defaults.

**Next up (Tier C / QA):**
- Validate BBVA & Santander parsers against REAL PDFs (still on reconstructed
  fixtures) using `parse_check`, then advertise them in `kSupportedMxBanks`.
  **Blocked: user doesn't have real BBVA/Santander PDFs to test against.**
- More banks: Banregio, Inbursa, Banco Azteca (same `column_table` pattern) —
  needs real/public sample statements.
- Get a clean HSBC PDF to confirm its date token; advertise HSBC. **Blocked on
  a clean PDF.**

**Recently shipped (no longer backlog):**
- ✅ Realized-gains ST/LT now flows into the tax SCREEN's exports (CSV is a
  3-section Form 8949-style export; PDF lists ST/LT lines). See 2026-06-06 (2).
- ✅ Budget auto-suggest logic extracted to a pure, unit-tested util
  (`utils/budget_suggestions.dart`).

**Known quirks (don't re-investigate from scratch):**
- **Material icon glyphs:** some "newer" Material icons render BLANK in the
  web build (the constant compiles, `flutter analyze` is happy, but the glyph
  isn't in the MaterialIcons font this image bundles). Confirmed blank:
  `auto_awesome_outlined`, `auto_fix_high`, `lightbulb_outline`. Confirmed
  rendering: `add_circle_outline`, `edit_outlined`, `donut_small`,
  `info_outline`, `warning_amber_rounded`, `trending_up`. It is NOT
  tree-shaking or caching (single-use `donut_small` renders; the bundle is
  fetched fresh). When adding an icon, prefer a classic glyph already used in
  the app, and eyeball it in the browser. (Cost us a long debug loop on the
  budgets Suggest button.)
- Flutter canvaskit intermittently FREEZES the renderer on heavy Portfolio
  scrolling (browser automation times out on screenshot). Workaround for QA:
  filter the holdings list to one ticker to collapse it, or reload. Tracked in
  FUTURE.md. (Note: a SHORTER browser window — e.g. 1280x900 — scrolls the
  cash-flow tab without freezing, where a tall window froze; handy for QA.)
- The S&P benchmark card ("Investments vs S&P 500", `benchmark_card.dart`) now
  shows ONLY the contribution-weighted comparison (each lot's cost grown by the
  index from its purchase date vs the lot's actual value). The old
  net-worth-indexed overlay was REMOVED because it reported absurd returns
  (+3479%) — net worth ramps from ~0 as accounts first sync, so indexing to the
  first snapshot conflates contributions with market gains. **Do not re-add
  net-worth-vs-index indexing**; a real time-series comparison would need a
  time-weighted return (periodic investment value + cashflow dates).
- Budgets / account-alerts / account-APRs persist in `app_settings`
  (`budgets`, `account_balance_alerts`, `account_aprs`) AND localStorage;
  don't "fix" the localStorage-only assumption — it's already backend-synced.
- Adding a row to `dashboard_endpoints.rs` integration tests: remember the
  TRUNCATE list at the top + that a new table must be added to it (S&P
  `benchmark_prices` leak bug was exactly this).

## Latest (2026-06-06) (2) — tax export ST/LT + budget-suggest hardening

On `main` (`8b41ac5`). Backend full suite green (81 dashboard incl. 1 new),
`flutter analyze` clean, `flutter test` 169 (5 new util tests).

- **Realized-gains ST/LT in the tax exports** (`services/tax.rs`, `api/tax.rs`,
  `tax_planning_screen.dart`): the CSV/PDF previously showed only the aggregate
  capital-gains figure. New `TaxService::get_lot_disposals(year, user)` returns
  per-disposal detail (symbol, acquired/sold dates, term, USD proceeds/cost/
  gain; USD math mirrors `/dashboard/realized-gains`). The **CSV** is now three
  sections — taxable income transactions, a Form 8949-style realized-gains
  table (one row per lot disposal, ST/LT term column), and a summary block
  (ST/LT split, totals, est. US/MX liability, "precise lot disposals" vs
  "blended estimate" basis note). Uses a *flexible* CSV writer (section headers
  and data rows differ in width — the default writer errors on that). The
  **PDF** lists Short-term (ordinary) and Long-term (preferential) lines under
  Capital Gains, built with a y-cursor helper so layout isn't hardcoded
  per-coordinate. Frontend CSV now passes `&status=` (the summary liability is
  status-dependent, like the PDF). Integration test seeds an ST + LT disposal
  and asserts the CSV detail + ST/LT/total summary rows + a valid PDF body.
- **Budget-suggest hardening**: the auto-suggest computation moved from inline
  in `BudgetsCard` to a pure `utils/budget_suggestions.dart`
  (`suggestBudgetsFromInsights`), matching the `debt_payoff` / `bill_forecast`
  pure-util pattern. This was the piece I couldn't browser-verify last round
  (the canvaskit freeze on the cash-flow tab blocks scrolling to the card); the
  5 new unit tests pin rounding (up to next $10), never-overwrite, same-label
  aggregation, tiny/uninformative-bucket skipping, and locale-aware labels.

## Latest (2026-06-06) — Tier B: spending-insight notifications + budget auto-suggest

On `main` (`f62a973`). Backend full suite green (80 dashboard incl. 1 new),
`flutter analyze` clean, `flutter test` 164 (7 new). Browser-verified live:
the spending-up notification rows render in the bell with real demo data.

- **`GET /api/dashboard/spending-insights?lookback=N`** (`api/dashboard.rs`):
  per-category spend for the most recent **complete** calendar month vs the
  trailing N-month baseline (default 3). The current partial month is excluded
  from the comparison so a 6th-of-the-month read doesn't report everything as
  "down". Same cash-flow hygiene as `cash_flow_trends` / `spending_by_category`
  (USD-normalized; excludes internal transfers, CC payments, lending legs,
  split parents). Groups on the raw `(user_category, category_detailed,
  category)` triple so the frontend can prettify identically to the budgets
  card. Returns `recent` / `previous_avg` / `trailing_avg` per category.
  Integration test asserts exact values + current-month exclusion + ranking.
  No new table → TRUNCATE list unchanged.
- **Spending-spike notifications** (`deriveNotifications` in
  `notifications_panel.dart`): a category whose recent complete month ran ≥25%
  above its trailing average, with a ≥$50 baseline floor and at most the 3
  biggest jumps. Tapping jumps to the Cash-flow tab. The dashboard fetches the
  endpoint best-effort (a failure just drops the rows).
- **Subscription price-increase notifications**: derived **client-side** from
  the existing `/dashboard/subscriptions` detector — a price change splits one
  merchant into two amount-band clusters, so when an active cluster's last
  charge is newer + pricier than an earlier same-merchant/-currency cluster
  (≥8% and ≥$1), that's a hike. No backend change. Capped at 3.
- **Budget auto-suggest** (`budgets_card.dart`): a "Suggest" button seeds the
  `budgets` app_setting from `spending-insights` `trailing_avg`, rounded up to
  the next $10. Only fills **unbudgeted** categories (never overwrites) and
  keys them by the same `prettyCategory` labels the card groups spend by, so
  suggested rows track real spending. Round-trips via `putSetting` +
  `Preferences` like the editor. *Not* browser-verified — the canvaskit
  freeze on the cash-flow tab blocked scrolling to it; covered by clean
  analyze + it reuses the proven editor save path.

Note: the spending-insight amounts are USD-normalized (like the cash-flow
card), so the bell shows them in USD even for an MXN-viewing user — consistent
with the rest of the cash-flow surfaces.

## Latest (2026-06-03) — Tier A: realized gains in tax + true benchmark return

On `main`. Backend full suite green (79 dashboard incl. 2 new), `flutter
analyze` clean, `flutter test` 157.

- **Realized gains → tax planning** (`services/tax.rs`): the cap-gains estimate
  now uses real `lot_disposals`, split short-term (held <=1yr → ordinary
  brackets) vs long-term (preferential LTCG 0/15/20% stacked on ordinary
  income). Falls back to the old blended cost-basis estimate when there are no
  disposals. `gains_from_lots` / `short_term_gains` / `long_term_gains` added
  to the response + an ST/LT line on the tax screen. 4 LTCG unit tests + an
  integration test.
- **True benchmark return**: `GET /api/dashboard/benchmark-comparison` +
  `benchmark::contribution_comparison` — a dollar-weighted "you vs the index"
  over tracked holding lots (each lot's cost grown by the S&P from its
  acquisition date vs the lot's actual current value). Shown as a "By
  contribution date" block on the BenchmarkCard, alongside the existing
  net-worth overlay. Integration test with exact values.
- Test-infra fix: `benchmark_prices` added to the dashboard-test TRUNCATE set
  (it was leaking S&P rows between tests).

Note: this round's browser pass was blocked by a Chrome-extension
screenshot-permission glitch after a container rebuild (nav worked, capture
didn't). Verified via the automated suite + live 401 route checks instead. The
tax ST/LT line only renders when lot_disposals exist (none in the current demo
data — it's covered by the integration test); the benchmark contribution block
renders from the 48 real holding_lots.

## Earlier (2026-06-03) — more bank parsers + S&P 500 benchmark

On `main`. Backend full suite green (118 lib + 77 dashboard), `flutter analyze`
clean, `flutter test` 157.

- **3 more MX statement parsers** — Banorte, Scotiabank, HSBC, built from real
  statements pulled off public transparency portals (HSBC's sample had a broken
  font, so its date token is unconfirmed — flagged in code). New shared
  `parser/column_table.rs` does header-geometry detection + **nearest-column
  bucketing**, which handles HSBC's reversed (withdrawal-before-deposit) layout.
  Dispatch by name/RFC/heading in `parser/mod.rs`. Banorte + Scotiabank are
  advertised in `kSupportedMxBanks`; HSBC runs via dispatch but isn't advertised
  until validated against a real PDF.
- **S&P 500 benchmark** — `services/benchmark.rs` lazily fetches ~5y of daily
  closes from the free, keyless Yahoo Finance v8 chart API (FX-service pattern:
  `benchmark_prices` table + 4-day freshness gate). `GET /api/dashboard/benchmark`
  serves the stored series. `BenchmarkCard` on the investments tab overlays "You"
  (net worth) vs "S&P 500", indexed to 100, with an ahead/behind verdict.
  Verified end-to-end: the live Yahoo fetch populated 1,254 real closes in the
  DB. (Note: the investments tab doesn't wheel-scroll under browser automation,
  so the card wasn't screenshotted — verified via DB + endpoint test instead.)

**Validated against REAL statements** (downloaded from public transparency
portals, run through `pdftotext -layout`, fed to the parsers via the new
`cargo run --bin parse_check <bank> <file.txt>` dev tool):
  * **Banorte** (Feb-2021): 4,138 transactions, correct dates/amounts/signs and
    a running balance on every row. ✅
  * **Scotiabank** (Mar-2024): 19 txns, correct signs + per-row balances. ✅
    (Dec-2017): 145 txns parse correctly, but that older layout rarely prints a
    per-row SALDO — `balance_after` is nullable, so this is fine.
  * **HSBC**: the only public sample has a broken embedded font (the words
    aren't even in the `pdftotext` output). Added a **garbled→OCR guard**
    (`looks_garbled`: lots of alpha but none of the statement anchor words →
    route to OCR, which rasterizes the visually-correct page). Verified on the
    real broken-font HSBC PDF: the pipeline went from 0 rows (garbled text) to
    OCR engaging and the parser extracting a row. Full HSBC fidelity is still
    limited by OCR noise on that scanned doc + the unconfirmed date token, so
    HSBC stays unadvertised pending a clean PDF — but broken-font files now
    route to OCR instead of failing. (Prod Dockerfile already ships
    tesseract-ocr-spa + poppler-utils, so this works deployed.)
  * Fix from validation: descriptions now truncate at the `▼` expander glyph
    (Banorte footers were leaking in).

**Remaining Tier-2/3 ideas:** get a clean/real HSBC PDF to confirm its date
token; a true time-weighted return for the benchmark (current overlay uses net
worth, which includes contributions).

## Earlier (2026-06-03) — Tier 2: debt payoff + instant bell (browser-verified)

On `main`. `flutter analyze` clean, `flutter test` 157 (5 new), live browser pass.

- **Instant notifications-bell update**: setting/removing a low-balance
  threshold now fires `onAlertsChanged` (threaded through
  `showAccountTransactionsPanel` + `AccountsListWidget`); the dashboard
  re-reads thresholds so the bell updates without a reload. Verified live.
- **Debt-payoff simulator** (`utils/debt_payoff.dart` + `DebtPayoffCard` on the
  Cash-flow tab): avalanche vs snowball, per-debt editable APR (persisted in
  `account_aprs` setting + Preferences), monthly-payment slider, recommends the
  lower-interest plan. Pure engine has 5 unit tests. Verified live (APR edit
  recomputes, slider recomputes).

**Tier 2 remaining (not done):** investment performance vs an S&P 500
benchmark (needs an external benchmark price-history source — API key/network,
the reason it was deferred); more MX bank parsers (Banorte/HSBC/Scotiabank).

## Earlier (2026-06-03) — Tier 1 insight features (UX-spec'd, browser-verified)

On `main`. Verified: backend lib + 76 dashboard integration, `flutter analyze`
clean, `flutter test` 152, and a live browser pass of all three.

- **Net-worth growth rates**: the hero delta chip is now a MoM + YoY pair
  (`net_worth_card.dart`, `_computeMomYoyDeltas`), calendar-month/year targets,
  ±5-day tolerance, falls back to the legacy 30d/7d chip under a month of
  history. (Note: current test data only has ~3 weeks of snapshots, so the
  fallback chip shows until ≥1 month of history accrues.)
- **Emergency-fund gauge**: `GET /api/dashboard/emergency-fund` (liquid cash /
  trailing monthly spend) + `EmergencyFundCard` on Overview (runway, 0→6mo
  gauge, status ladder). Integration-tested.
- **Account-balance alerts**: per-account low-balance thresholds (native
  currency) in the `account_balance_alerts` setting + Preferences. Account
  overflow menu → set/edit/remove; amber inline banner when breached; amber
  bell rows that deep-link to the account. Bell reads dashboard-level state
  hydrated at load (a freshly-set threshold shows in the bell after the next
  load/realtime refresh; the inline banner is immediate).

## Earlier (2026-06-03) — projection rebuild + insight layer

On `main`. Verified green: backend `./scripts/test.sh` (109 lib unit incl.
11 projection tests + 75 dashboard integration), `flutter analyze` clean,
`flutter test` (148).

Shipped this session, in order: projection rebuild → spending-by-category
→ realized gains/losses → retirement-income in the projection sim →
account balance-over-time. Newer items below.

- **Realized gains/losses**: `GET /api/dashboard/realized-gains[?year=]`
  surfaces `lot_disposals` (YTD/all-time summary, per-year totals, disposal
  list with USD proceeds/cost + long-term flag). `RealizedGainsCard` in the
  investments tab; renders nothing when there are no realized sells.
- **Retirement income in the projection**: the "Retirement income
  (SS/pension)" input now offsets spending in the decumulation phase
  (deterministic + Monte Carlo), not just the Barista badge.
- **Balance-over-time per account**: `GET /api/dashboard/account-balance-history?account_id=`
  (monthly closing balance from the persisted `balance_after`, native
  currency). `AccountBalanceChart` at the top of the account screen;
  only shows for statement-imported accounts (Plaid-only → no data).

### Earlier this sprint

1. **Wealth projection rewritten** ([services/projections.rs](../backend/src/services/projections.rs)):
   real (today's) dollars via the Fisher relation, accumulation +
   **decumulation** phases, **Monte Carlo** (lognormal real returns,
   `-σ²/2` drift, default 1000 trials → success rate + p10/p25/p50/p75/p90
   yearly fan), **Coast/Barista FIRE**. New `GET /api/projections/defaults`
   derives contribution/expenses from trailing-12mo tracked cash flow.
   Frontend ([wealth_projection_screen.dart](../frontend/lib/screens/wealth_projection_screen.dart))
   shows the MC band, a success-rate card, a Coast/Barista strip, and
   inflation/volatility/retirement-age controls. Removed the old
   client-side scenario formula that disagreed with the backend.
2. **Per-category spending trends**: `GET /api/dashboard/spending-by-category`
   + `SpendingByCategoryCard` (stacked bars by month, 3/6/12-mo selector)
   in the cash-flow tab.

**Note for the next agent:** the audit's claim that "budgets are
localStorage-only" is **wrong** — `BudgetsCard` already round-trips through
the `budgets` app_setting (localStorage is just a fast-paint cache). Don't
redo that.

**Suggested next (from the feature audit, by impact-per-effort):**
recurring-bill / subscription 12-month forecast (subscription detector is
already there) · category budget-vs-actual alerts on top of the new
spending-by-category data · projection withdrawal guardrails
(Guyton-Klinger) and an effective tax drag · investment performance vs a
benchmark (S&P 500). Already shipped this sprint: realized gains, balance-
over-time, retirement-income, projection rebuild — don't redo.

## Where we are (previous sprint: statement import)

All work below is **on `main` and pushed** (`origin/main` @ `d65a7f6`).
Everything verified green: backend `./scripts/test.sh` (100 lib unit +
72 dashboard integration + auth/passkey), `flutter analyze` clean, and
`flutter test` (148) — note Flutter must be run via docker, see the gotcha
at the bottom.

This sprint was a deep pass on **statement import**. Shipped, in order:

1. **BBVA + Santander parsers** (`bbva_layout.rs`, `santander_layout.rs`,
   shared `layout_util.rs`) — column-position bucketing; routed by content
   signature.
2. **Auto-categorization** (`services/categorize.rs`) — Spanish
   merchant/keyword + amount sign → Plaid PFC primary code, at parse time
   (preview chip + round-trip) with a confirm-time safety net.
3. **Multi-account (secondary) import** — `banamex_layout` splits a bundled
   statement at each `SALDO ANTERIOR` and parses every account section,
   tagging secondary rows with `account_label`; the import UI shows a
   destination picker per section. Banamex savings/Pagaré balance no longer
   dropped.
4. **Statement gap detection** (`services/continuity.rs`) — flags a likely
   missing month from a balance jump between sequential statements.
5. **Occurrence-aware dedup** (`imports.rs::batch_signatures`) — distinct
   identical rows no longer silently merge; first occurrence keeps the legacy
   bare signature so existing history still dedups.
6. **Real Nu México PDF parser** (`nu_mexico_pdf.rs`) — replaced the naive
   stub (current-year bug + no-op sign). Year from `Periodo`, sign from the
   balance delta, captures `balance_after`.
7. **Persisted `balance_after`** (migration `2026060102`) + **full-history
   continuity** (`GET /api/imports/continuity`) + a "Statement coverage"
   panel in Import Cleanup. Re-import backfills the column (confirm upsert).
8. **Smarter categorizer** — grew the rule table; **learn-from-edits**: the
   user's manual `user_category` is mapped by `merchant_key` and carried onto
   future imports of the same merchant.
9. **OCR review flag** — `ParsedTransaction.from_ocr`; preview shows an
   "OCR — verify" badge on scanned/photographed rows.

## Known caveats / things to validate (read before extending)

- **Fixtures, not real PDFs.** BBVA/Santander/Nu parsers + the Banamex
  secondary section were built and unit-tested against `pdftotext -layout`
  fixtures *reconstructed from real (mostly organizational) statements*. The
  personal-account description vocabulary is plausible, not confirmed.
  **Highest-value next QA step:** run a REAL personal BBVA/Santander/Nu or a
  multi-account Banamex statement through the importer and eyeball the
  preview (dates, debit/credit signs, closing balance). The preview is the
  live guard.
- **Continuity backfill is re-import-gated.** Rows imported before migration
  `2026060102` have NULL `balance_after`; re-importing a statement backfills
  it (dedup still skips re-inserting), but rows never re-imported stay null
  and are excluded from the full-history check.
- **Learn-from-edits is conservative.** Runs at confirm (after the preview),
  keys on the first ~3 significant words; won't catch every description
  variant. No new table — it queries the user's own labeled history.
- **OCR flag is coarse** (per-document, not per-word tesseract confidence).

## Suggested next steps (by value)

1. **Validate against real statements** (above) — cheapest way to de-risk the
   whole sprint; needs sample PDFs from the user.
2. **More banks**: Banorte, HSBC, Scotiabank — same pattern as
   BBVA/Santander (subagent research → column parser → fixture tests).
3. **Balance-over-time chart** — now derivable from the persisted
   `balance_after` column; no migration needed.
4. **Per-word OCR confidence** (tesseract TSV) to flag only genuinely
   low-confidence rows instead of the whole OCR'd file.
5. **Balance-anchored dedup hash** (date+amount+balance_after) to stop a
   description that parses slightly differently across versions re-importing.

## How to verify / ship (environment gotchas)

- Backend tests: `./scripts/test.sh` (dockerised toolchain; `cargo` isn't on
  the host). Migrations auto-apply to the test DB via `sqlx::migrate!`.
- **Flutter must run via docker** — host `flutter` fails writing a root-owned
  `frontend/.flutter-plugins-dependencies`:
  - analyze: `./scripts/check.sh --skip-backend`
  - test: `docker run --rm -v "$PWD/frontend":/app -w /app ghcr.io/cirruslabs/flutter:stable bash -lc 'flutter pub get >/dev/null 2>&1 && flutter test 2>&1'`
- Direct-push to `main` is gated by the Claude Code classifier; do the local
  `git merge --ff-only` + `git push origin main` (the user authorizes pushes).
