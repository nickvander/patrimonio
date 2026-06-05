# Handoff — start here

> **Last updated:** 2026-06-03 (projection rebuild + spending-trends sprint)
> **Purpose:** The single "where are we, what's next" doc to pick up cold.
> For the full import architecture + backlog see
> [work/STATEMENT_IMPORT.md](STATEMENT_IMPORT.md); for the older broader
> backlog see [work/NEXT.md](NEXT.md) and [work/FUTURE.md](FUTURE.md).

## Latest (2026-06-03) — more bank parsers + S&P 500 benchmark

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
