# Handoff — start here

> **Last updated:** 2026-07-08 (round-4 dividend infra + rebalancing + charts deployed)
> **Purpose:** The single "where are we, what's next" doc to pick up cold.
> For the full import architecture see [work/STATEMENT_IMPORT.md](STATEMENT_IMPORT.md);
> for the older broader backlog see [work/NEXT.md](NEXT.md) and
> [work/FUTURE.md](FUTURE.md).

## TL;DR — current state

**As of 2026-07-08:** `main` @ `1d552f9`, tree clean, pushed. **Prod runs
on the homelab host `thelab`** (`ssh nickvander@thelab`; docker compose
stack at `/mnt/data/docker/stacks/patrimonio`, api on `:8085`) — the
2026-07-06/07 Portfolio overhaul AND the 2026-07-08 round-4 sprint
(dividend Redis cache, income calendar, rebalancing card, chart hovers)
are deployed there. **Dev on this VM is
native (no docker):** rust/cargo + flutter (`~/flutter`) are installed;
Postgres runs on `127.0.0.1:5442` and Redis on `:6380` with data dirs
inside the repo (`pgdata/`, `redisdata/`, gitignored) — see the repo-root
`CLAUDE.md`. Any older note in this file saying cargo/flutter "must run
via docker" is obsolete on this VM — see the rewritten "How to verify /
ship" section at the bottom.

**Read next:** [work/CURRENT.md](CURRENT.md) for the detailed
2026-07-06/07 Portfolio-tab overhaul log; [work/NEXT.md](NEXT.md) for the
current priorities (dividend fan-out caching, target-allocation/
rebalancing view, dark-mode tooltip + palette pass, dividend income
calendar — in progress as of 2026-07-07). The dated "Latest" sections
below log every sprint since 2026-06-06, newest first.

**Shipped the 2026-06-06 sprint (newest first)** *(historical — later
sprints are in the dated sections below)*:
- **True time-weighted return (TWR)** on the Performance card — the value
  line finally carries an honest return + a legitimate S&P overlay (live-
  browser-verified: "Your portfolio +100.2%" vs "S&P 500 +26.5%", and the
  math spot-checks — GOOG, the dominant covered position, ran 167.71→365.76
  = +118%; S&P 5970→7553 = +26.5% exactly). Design notes:
  · `benchmark.rs` generalized into a per-symbol daily quote cache
    (`refresh_yahoo` / `ensure_symbol_fresh`) over the SAME `benchmark_prices`
    table — keyed by any symbol now; `refresh_sp500`/`ensure_fresh` are thin
    wrappers. (So a held symbol's quotes live in `benchmark_prices` too.)
  · `services/twr.rs` = GIPS daily-valuation method. **Key correctness move:**
    `holding_lots` is SPARSE (lots don't sum to current share counts — GOOG
    has thousands of shares, ~zero lot qty), so we treat CURRENT quantity as
    ground truth and walk backward: `shares(t) = current − future buys +
    future sells`; everything before the first lot is the opening position
    valued at start-date prices (NO ramp-from-zero — that was the old +3479%
    bug). Flows are the incremental lot buys/sells. Coverage-aware: prices
    USD tickers it can quote, reports `coverage_pct` of portfolio value
    (≈68% on demo — opaque Plaid security_ids / non-USD are uncovered).
  · `GET /dashboard/portfolio-twr` returns a daily growth index (your TWR +
    S&P, start=1.0) so any sub-range re-bases by division. Frontend
    `PerformanceCard` plots indexed TWR-vs-S&P over the selected range with
    return pills + coverage caption; falls back to the dollar line when
    nothing is priceable; TWR loads non-blocking (cold Yahoo fetch is slow).
    Integration test seeds a mid-window contribution and asserts TWR = +21%
    (contribution divided out) not the ~+102% a naive value change shows.
- **Portfolio research-canonical flow + signals strip + mobile holdings**
  (`12d2e31`): tab reordered to **overview → performance → allocation →
  signals → holdings**. `PortfolioCard` is now section-driven
  (`PortfolioSection.{summary,signals,holdings}`, one widget, shared
  `portfolioData['holdings']`). New thin **signals strip** (biggest gainer /
  loser / concentration ≥20% of one position) — moved out of the KPI grid.
  Holdings table **collapses below 560px** to tap-to-expand rows (name +
  value + change → reveal shares/price/cost/gain + lot breakdown);
  `showLotBreakdown` extracted to a top-level helper. Browser-verified the
  overview slice (split KPIs) + allocation; signals/holdings region blocked
  by the canvaskit screenshot freeze (investments tab also doesn't
  wheel-scroll under automation — known, see quirks).
- Portfolio **drill-down + performance merge** (browser-verified end-to-end):
  · Tapping ANY allocation band (class / account type / institution) filters
    the holdings table — the band passes its raw value, matched against the
    holding's holding_type / account_type / institution_name (holdings
    response now carries `account_type`). Verified: tap Vanguard → table shows
    only Vanguard accounts.
  · New **PerformanceCard** replaces the standalone benchmark card: a value-
    over-time line chart + range selector (1M/YTD/1Y/5Y/ALL) with the
    contribution-weighted "vs S&P 500" block folded in. New
    `GET /dashboard/portfolio-value-history` (sums balance_snapshots of
    accounts that hold investments). **No misleading first→last % return** —
    early history ramps from ~0 as accounts sync, so only the honest
    contribution-weighted return is shown (the value line is labelled
    "includes contributions"). Deleted benchmark_card.dart.
- Overview net-worth chart (detailed mode): legend chips clamped + capped at
  4 institutions so the legend stays one line and stops squishing the
  fixed-height chart.
- Portfolio allocation unified into ONE card with a dimension toggle
  (**Asset class · Account type · Institution**, browser-verified all three).
  Asset class keeps grouped bars + top-N holding rows + tap-to-filter +
  concentration flag; type/institution render ranked bars wired from
  overview `type_breakdown` / `institution_breakdown`. Deleted the standalone
  `AccountsBreakdownCard`. Allocation went 3 cards (heatmap + donut +
  breakdown) → 1.
- Portfolio freeze fix + overlap trim (research-backed). Holdings table no
  longer nests a fixed-height ListView/Scrollbar inside the page scroll (that
  nested same-axis scroll was the "freeze") — rows flow in the page scroll,
  capped at 12 + "Show all N"; RepaintBoundary around table/heatmap/benchmark;
  dropped per-band blur shadows. Removed the redundant donut-by-holding chart.
  Added a concentration risk flag (">=20% in one position"). Full-tab scroll
  is smooth now; **NOTE**: the headless screenshot capture can still time out
  when the holdings table is centered (CDP-vs-canvaskit artifact, not a user
  scroll hang). (Drill-down for all dimensions + the benchmark→performance
  merge from this list are now DONE — see the top bullet.)
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

**Still-open QA items from that sprint** *(current top priorities live in
[work/NEXT.md](NEXT.md))*:
- **TWR follow-ups** (raise coverage above ~68%): map non-USD holdings via a
  per-day USDMXN series (USDMXN=X is already fetchable through the same Yahoo
  path) so MXN-priced securities can be priced; map opaque Plaid security_ids
  to real tickers so those funds become priceable. Both are coverage_pct
  wins, not correctness fixes.
- **Banregio / Inbursa / Banco Azteca parsers** (Portfolio backlog item) —
  same `parser/column_table.rs` pattern as Banorte/Scotiabank; needs sourcing
  real/public sample statements, then `cargo run --bin parse_check <bank>
  <file>` before advertising in `kSupportedMxBanks`.
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
- **`PerformanceCard` now has TWR** (the time-weighted return that the old
  note below said "would be needed"). The performance line shows the real TWR
  + an S&P overlay (legit because cashflows are divided out); the
  contribution-weighted block stays below as the dollar-weighted read.
  **Still do NOT re-add net-worth/value-vs-index indexing** — that's the
  +3479% bug (net worth/value ramps from ~0 as accounts sync). The TWR path
  in `services/twr.rs` is the correct way (opening position valued at
  start-date prices, flows divided out). (`benchmark_card.dart` was deleted a
  sprint ago; the S&P comparisons live in `performance_card.dart`.)
- Budgets / account-alerts / account-APRs persist in `app_settings`
  (`budgets`, `account_balance_alerts`, `account_aprs`) AND localStorage;
  don't "fix" the localStorage-only assumption — it's already backend-synced.
- Adding a row to `dashboard_endpoints.rs` integration tests: remember the
  TRUNCATE list at the top + that a new table must be added to it (S&P
  `benchmark_prices` leak bug was exactly this).

## Latest (2026-07-08) (2) — round 5: debt strip, net-worth movers, quick wins, CI fix, branch cleanup → deployed

On `main`, deployed to thelab. Detail in [work/CURRENT.md](CURRENT.md). Map:
**CI** — round-4 Redis cache tests were silently skipping in CI (hardcoded
dev :6380 vs CI :6379); harness now reads `PATRIMONIO_TEST_REDIS_URL` +
panics when set-but-unreachable, CI wired to its service (green). **Branch**
— `claude/adoring-merkle-da8ff6` evaluated (all superseded, un-mergeable)
and deleted. **Debt** — summary strip on `debt_payoff_card.dart` (total
owed, weighted APR, monthly interest, credit/loan split). **Movers** —
top-3 institution movers on `net_worth_card.dart` from the existing
`by_institution` payload. **Quick wins** — ES `lwRangeAll` "TODO"→"Todo",
locale-aware percent helper (`utils/percent_format.dart`) swept ~36 sites
incl. rebalancing card (en byte-identical, es comma+NBSP), perf-card
time-proportional ticks (`utils/chart_time_axis.dart`). Opus review found
no blockers; percent helper reworked to keep en byte-identical. Debt strip
+ movers self-hide in the investment-only dev DB — they render on prod.

## Latest (2026-07-08) — round 4: dividend cache + income calendar + rebalancing + chart hovers → deployed

On `main` @ `1d552f9`, deployed to thelab. Four parallel dev workstreams +
an Opus 4.8 adversarial code review + two browser verifiers; **no new
migrations. Detailed log in [work/CURRENT.md](CURRENT.md).** Map:
per-symbol Redis dividend cache (`div:v1:{SYMBOL}`, 12h fresh / 7d stale
retention / 1h negative marker, coalescing, `?refresh=true` bypass; warm
fan-out ~14ms vs ~337ms cold; degrades to live fetch if Redis is down) →
all three dividend call sites cache-backed; additive `calendar` field on
`/dashboard/holdings/dividends` powering a 12-month income calendar in the
dividend card (shares the detail endpoint's `projected_ex_dates`
stepping; response shape frozen by snapshot test); a rebalancing card
(target % per asset class in `app_settings.allocation_targets` — no
migration — with drift bars + "move $X from A to B" guidance); and the
standard guide+dot+tooltip hover on the four previously hover-dead charts
via new `utils/chart_touch.dart`. Fix-up round (verifier + Opus findings,
none blocking): sparkline tooltip fit-inside, projections tooltip
placeholder order (gen-l10n alphabetized args — same trap as the round-1
counter), calendar current-month accent from the server's UTC bucket,
rebalance missing-class → `unclassified`. Also this session: prod account
nicknames set via the app's rename API; `docs/adding-accounts.md` §5
recommends nicknaming; `work/` back-logged against all 230 commits since
2026-06-06.

## Latest (2026-07-06/07) — Portfolio ("Invest") tab overhaul → deployed

On `main` @ `2f17431`, deployed to thelab. ~17 commits (`f930c8b` →
`2f17431`), three multi-agent rounds (walkthrough → PM backlog → parallel
dev workstreams → browser verification → deploy). **The detailed log
lives in [work/CURRENT.md](CURRENT.md) — read that, not this.**
One-paragraph map: dividend-frequency inference fix (quarterly payers
were reading 5×/yr) + dividend detail / instrument sheets
(`GET /dashboard/dividends/{symbol}`,
`GET /dashboard/instruments/{symbol}`); prefixed allocation filter
dimensions + canonical asset-class classifier + per-symbol overrides
(new `asset_class_overrides` table); day change (stored-close,
coverage-aware); CSV exports for holdings/lots/realized gains;
realized-gains year chips + tax-advantaged context; **holding delete was
silently cascading lots + realized-gain tax records → confirm dialog +
soft delete with undo/restore**; dividends surfaced on Overview +
Projections; app-wide a11y sweep; mobile polish; `sqlx` migrator now
`ignore_missing`. Same day, pre-overhaul (separate session): mask-aware
account names app-wide (+ `..mask` suffix survives truncation),
accounts-list row alignment + type-aware sub-group labels, and the
Lending tab fully localized (status pill + Add/Edit dialog flow)
(`0efba89`, `263a4f0`, `187b561`, `077f448`, `7facd22`, `04f7754`).

## Latest (2026-06-29 → 2026-07-05) — FX override, dividend income + benchmark picker, CUJ sweep, custom loan schedules

All on `main`.

- **Manual USD/MXN rate override** (`90d7ece`): `POST /fx/manual`, new
  `exchange_rates.source` column; `get_latest_rate` short-circuits to the
  freshest manual row before cache + live fetch, so a pinned rate wins on
  every read path. Entry UI landed in the CUJ commit's FX widget.
- **Tax bracket/LTCG headroom** (`c78c4ed`): `compute_bracket_headroom`
  (ordinary-bracket room + next-dollar rate, LTCG 0%/15% room) +
  `net_capital_buckets` feeding the harvest summary footer.
- **Portfolio-wide dividend income + selectable benchmark** (`daf7ffe`):
  `GET /dashboard/holdings/dividends` — projected annual income, blended
  yield, per-symbol contributions, future-only ex-dates, bounded-parallel
  Yahoo fetches (NO caching yet — that's the current top priority in
  NEXT.md); optional `?benchmark=` (default SP500, fails soft) threaded
  through portfolio-twr + benchmark-comparison.
- **CUJ + competitive features across all tabs** (`6ffcf2b`, one big
  commit, 64 new EN/ES strings): Overview tappable stat-tile drilldowns +
  goal projected-completion date + catch-up contribution; Portfolio
  dividend income card + benchmark picker; Tax headroom card + harvest
  footer; Lending interest-income drill-down sheet +
  due/overdue/paid-ahead pills + accrued interest on loan cards; Cash
  flow savings-rate KPI + day-of-month budget pacing + period selector
  now drives budgets & spending-by-category; Transactions filtered-set
  net/in/out totals; Management data-export + import-batch cleanup
  surfacing; FX widget manual-rate entry.
- **Custom irregular loan schedules + off-bank reconciliation**
  (`14110dc`, 2026-07-03): `interest_type='custom'` +
  `POST /loans/{id}/schedule/custom` (explicit rows or first-N/then-Y
  pattern; running balance must close to exactly 0);
  `POST /loans/{id}/payments/{payment_id}/attach-tx` links a
  later-imported bank tx to an already-off-bank-paid installment without
  double-counting; next_due/overdue now keyed on `paid_amount`, not
  `actual_tx_id` (cash repayments stop showing as overdue).
  Paste-from-spreadsheet dialog with live must-close-to-0 preview,
  "Create loan from transaction", "Copy for Google Sheets". EN + es-MX.
  Verified live with a 37-row 0% / 130,000 MXN case.
- **Dev-services doc** (`92bb504`): repo-root `CLAUDE.md` documents the
  native Postgres/Redis setup (docker unavailable on the dev VM).

## Latest (2026-06-19 → 2026-06-24) — under-reviewed-tabs sweep, forensic accounting audit, tax constants verified, CI

All on `main` (part merged via `feat/under-reviewed-tabs-pass`).

- **Under-reviewed-tabs sweep** (`b06913f`..`74fb09f`, 06-19/20):
  meaningful disambiguated Plaid account names; institution shown in
  activity rows; cash-flow period selector (This/Last month, 3M, YTD) +
  native currency on recurring + richer chart tooltips; transactions
  undo-delete, sort, full-history select-all, filtered CSV; notifications
  readable on mobile + net-worth-change-since-last-sync + account-archived
  alerts; **auto-archive accounts Plaid stops returning** (their
  transactions stay in spending history); per-bank statement-coverage
  panel (`a270b70`); Overview momentum + lending glance; portfolio top
  movers by $ P&L + lot-level cost-basis drill-down; lending
  accrued-interest row + loan aging report; projections nominal-vs-real
  toggle; Settings sync-health summary row. EN+ES strings throughout.
- **Forensic accounting-accuracy audit** (`060dbb2`, `f68d598`): shared
  trailing-12mo-spend exclusion SQL fragment (emergency-fund vs
  projections figures can no longer drift); the silent 20.0 MXN/USD
  fallback replaced with `fx_rate_used`/`fx_stale` on overview + holdings
  so the UI flags approximate conversions; long-term flag now calendar
  arithmetic (acquired + 12 months) matching the tax module; lending
  interest summary gained `totals_by_currency`.
- **⚠️ The integration suite had been silently skipping** (`4af62e3`):
  `scripts/test.sh` defaulted the pre-rotation `POSTGRES_PASSWORD`, DB
  auth failed, `skip_if_no_db` early-returned, and every DB-backed test
  vacuously passed — which is exactly how the FBAR 500 (`024da0c`) and
  statement-continuity 500 (`dcd8acf`) shipped past existing tests. Fix:
  password sourced from `.env`; a configured-but-unreachable DB now
  PANICS instead of skipping; continuity regression test added. The
  resurrected suite surfaced 3 hidden tax_endpoints failures, fixed in
  `99c9252`.
- **CI** (`8690433`, `fe188a6`): integration suite + `flutter analyze` +
  `flutter test` now run on every push & PR (local golden screenshots
  excluded from the frontend job).
- **Tax**: corrected retirement-contribution detection + mega-backdoor /
  backdoor-Roth + §415(c)/family limits UI + segmented filing toggle
  (`b1843f1`, `515db08`, `93bc25a`); 401k elective-deferral input for the
  mega-backdoor split (`3a8a5e2`, `dc6008d`); **constants verified against
  primary sources** (IRS Rev. Proc. 2025-32 / Notice 2025-67; SAT Anexo 8)
  — the MX ISR annual tarifa was WRONG (missing 17.92% bracket →
  overtaxing MX income); replaced with the official 11-bracket 2025+2026
  tarifas and `TAX_CONSTANTS_VERIFIED` flipped to true (`290cca4`);
  `fx_stale` surfaced on spending-by-category + insights (`85d86b3`);
  detail-panel Material fix so autocomplete ListTiles render (`b7df459`).

## Latest (2026-06-13 → 2026-06-16) — mobile pass, security, sync concurrency, audit sprints

- **Mobile-calm pass across every tab** (`488be78`..`403c44b`,
  `05e3da7`, `5aa241f`): Glance/Details disclosure on Overview;
  denser-free Invest; calmer Cash flow / Projections / Tax / Settings /
  Lending on small screens; unsquished net-worth/projection charts;
  brand tokens for sync/FX status colors.
- **Sync**: institutions sync concurrently with per-institution isolation
  (`6122693`) + live "updating X of N" progress (`72b78e0`).
- **Security screen**: username + email on an Account card (`525029d`);
  passkey step-up to set a password without knowing the current one
  (`7831174`).
- **Audit sprints** (`f475ead` sprints 1–2, `0d5c3c6` sprint 3): currency
  correctness (projections stopped dividing already-USD net worth by the
  fx factor; budgets / portfolio hero / credit utilization / debt payoff
  all USD-normalised; the FX-transfer delta no longer compares USD/MXN
  against MXN/USD → fake +29,000% deltas gone); lending data-safety
  (unreconcile reverts a schedule row instead of DELETEing it;
  outstanding/payoff sum `principal_portion` not `paid_amount`; currency
  guard on reconcile); TOTP hard-failure counter revokes the pending
  session after 5 bad codes; **the one real security finding: Plaid
  link-token now uses the authenticated user's UUID as `client_user_id`
  instead of a shared constant** — restores Plaid's per-user item/consent
  isolation in multi-user deploys.
- **Revolut (MX) statement parser** (`babac2a`; peso section routed to
  its own account `f6c900d`).
- Accounts list: multi-account banks collapse into one compact summary
  row, nested accounts indent, redundant bank sub-labels dropped
  (`89b90fc`, `67cfbc2`, `d6681c5`); net-worth y-axis fits data in simple
  mode (`41e1f19`).
- Categorizer fixes (SoFi vault moves are transfers + RENTA anchored
  `823a098`; a negative amount is never income `d5fb1d6`; Loop = fuel
  `1182093`); keyword-less FX-transfer pairs need a shared counterparty
  (`d01342b`); June-2026 one-time-backfills migration doc (`4ec7b63`);
  personal worktree path scrubbed for open-sourcing (`2d773ee`).

## Latest (2026-06-09 → 2026-06-12) — FIRE/projections UX, transactions revamp, tax-planning overhaul

- **Projections/FIRE UX** (06-09, `72882e4`..`dd27e35`): FIRE glossary +
  control help + clearer labels; interactive focus selector + lifestyle
  presets; lifestyle + goal unified into one FIRE plan card; chart legend
  for the dashed lines; neutral Coast-FIRE wording; surplus income no
  longer inflates the portfolio + Fat preset un-clamped. Also: Settings
  decluttered + account-list filters + overview sync bar (`aa5419d`);
  compose services get `restart: unless-stopped` (`fa3050d`).
- **Transactions revamp** (PM-vetted 16-task backlog in
  `work/ux` — `b421db0`; milestones M1→M4): filter/search spans the whole
  history, not just the loaded page (`c03b0a9`); look-&-feel revamp —
  category colors, transfers, grouping, search, empty states (`ad1a5eb`);
  filter cascade pages at the backend cap (`dfe70db`); account panel gets
  full tx actions + in-place refresh + paged loading + a running balance
  per row (`b16b498`, `cd627c8`); **amount sign convention corrected
  across the UI (neg=outflow, pos=inflow)** (`25621ca`); M4 polish —
  touch-reachable command palette + batch-delete endpoint (`d32b9e2`);
  split-dialog keystroke-focus fix (`f57becb`); tx edits refresh 3 reads
  instead of a re-price + 18-endpoint reload (`4145f4a`); locale-aware
  dates (`2d53a15`).
- **Tax-planning overhaul** (15-task audit backlog `06834ce`; T-tasks):
  income predicates match stored categories + tax-advantaged disposals
  excluded (`790daef`); per-row FX normalization — USD base for US
  brackets, MXN base for the ISR tarifa (`7c67dea`); year-keyed bracket
  tables + standard deduction + loss netting, gated
  `TAX_CONSTANTS_VERIFIED=false` (`3168ca5`; verified + flipped 06-24);
  Plaid dividends/interest persisted at sync + income decomposed into
  wages/dividends/interest (`0630da5`); trustworthy responsive tax screen
  with disposals + scenario framing + persisted controls (`4f6832c`,
  `ada0117`); unrealized per-lot view + harvest candidates + wash-sale
  detection (`a7539cb`); FBAR monitor + CETES interest income +
  retirement-contribution tracking (`f2fb66c`, `1a31012`);
  `category_detailed` persisted through import, CETES interest itemizes,
  ISR-retenido totalled + shown on the MX card (`8e5448e`, `54c5c8b`).
- Lending: expected repayment date incl. no-interest loans (`809bcf4`);
  add/edit-loan dialog overflow fix (`b918d97`). Holdings: unknown cost
  basis renders as em dash, not a fake +0.00% (`a174d1a`).

## Latest (2026-06-06 → 2026-06-08, after the TWR handoff) — real-statement import sprint, manual holdings, HSA/NetBenefits

The sessions right after the last logged handoff (`53e16e2`) — previously
unlogged.

- **Ops**: break-glass admin CLI (`backend/src/bin/admin_reset.rs` —
  offline list / reset-password / disable-totp / recovery-codes /
  reactivate / revoke-sessions against Postgres directly; every mutation
  confirms and logs to auth_audit) + homelab migration runbook
  (`docs/migration.md`, `scripts/migrate-secrets.sh`) (`ad26fae`). This
  is the runbook the thelab deployment followed — tokens are NOT
  machine-bound; carrying ENCRYPTION_KEY/PLAID_* keeps linked accounts
  working.
- **Real-statement import deepening** (~25 commits): real Nu México
  support with cajitas as sub-accounts (`d90611d`; Nu balance = total
  incl. cajitas `a4fc00a`); real cetesdirecto support (`5d2496a`); drop a
  whole folder onto the import zone (`606389b`); account-identity capture
  (CLABE) + suggested real balance/name + auto-match cue + editable
  identity + Spanish type labels (`f97314e`, `46f24c5`, `580f807`);
  grouped review panel + pinned Import action bar + summary strip +
  dense preview rows matching the main UI (`9ef8eba`, `9e756db`,
  `9985837`, `c437dc1`, `5ed6833`); prominent callout for bundled cajitas
  (`bea3e01`); imported accounts file under their real bank, not "Manual"
  (`7ea6af1`); **net-worth history back-filled from statement running
  balances + per-statement totals** (`bf06e3f`, `0ad5d91`); continuity
  flags only skipped months, not per-statement noise (`c207f35`), with
  dismissible unobtainable gaps (`243a503`) and a compact scrollable
  report (`dd620e8`); Banamex year derived from "Fecha de Corte"
  (`782f96f`); localized continuity warnings + word-boundary auto-match
  (`786568a`); CetesDirecto classified as Bonds, not cash (`afb69a4`);
  MXN balances FX-converted in the daily snapshot cron (`e93f710`).
- **Manual equity holdings by ticker, live-priced** (`8fa3078`) + a
  dividend view (annual rate, yield, est. next ex-date, income)
  (`ae8283e`) + global stock-price refresh with editing locked to manual
  accounts (`f16bc1b`) + nightly auto price refresh (`c45da35`) — the
  foundation the July Portfolio overhaul builds on.
- **HealthEquity HSA + Fidelity Stock Plan ("NetBenefits") parsers**
  (`c2b8da0`, `b8d27e6`, `3fadc25`; `c5ee3d1`, `d7e4460`): HSA invested
  fund + cash mapped as live holdings, tagged "mutual fund" for
  allocation; HSA offered in the add-account picker (`62305ee`);
  full-institution-name match before the first-word key (`8bc75ff`).
- **Accounts/dashboard UX**: vaults nest under their bank + collapsible
  (`29cc02f`, `23b9a6c`); vault total folded into Savings (`3c30488`);
  unified net-worth hero with self-labelling currency composition
  (`8c49310`, `7901f58`); per-group currency split + onboarding-inflated
  NW% suppressed (`f8f05fe`, `e2b6eef`, `d4006f0`); friendly Plaid
  account names (`46566c3`); Plaid credit limit captured + no-limit cards
  handled (`df97f50`, `f2cf240`); native-currency stat-tile conversion
  fix (`a00dcf6`); account detail panel theme-surface fix (`150ae59`).
- Sync progress shown inline on the button instead of a 30s snackbar
  (`dab21cc`, `4101231`); **offline service worker disabled — it was the
  stale-bundle cause** (`ac1879a`).

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
token. (✅ true time-weighted return now shipped — see the TL;DR top bullet.)

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

**Rewritten 2026-07-07 — the old "everything via docker" instructions no
longer apply on this dev VM (docker is unavailable here; the toolchain is
native).**

- **Dev services** (native, no docker): Postgres on `127.0.0.1:5442`,
  Redis on `127.0.0.1:6380` (password `patrimonio_dev`), data dirs inside
  the repo (`pgdata/`, `redisdata/`, gitignored). `backend/.env` points at
  them. See the repo-root `CLAUDE.md`.
- **Backend**: `cargo` is on PATH — run `cargo test` in `backend/`
  natively. Integration tests need `PATRIMONIO_TEST_DATABASE_URL` pointed
  at a test DB on the local 5442 Postgres (a configured-but-unreachable
  DB PANICS loudly instead of silently skipping, since `4af62e3`; unset =
  skipped). Migrations auto-apply via `sqlx::migrate!`.
  `scripts/test.sh` / the backend half of `scripts/check.sh` are still
  docker-based — they only work where docker exists (CI, thelab).
- **Frontend**: flutter lives at `~/flutter` (`~/flutter/bin/flutter`)
  and runs natively — `flutter analyze`, `flutter test`,
  `flutter build web`. No docker wrapper needed on this VM.
- Kill a locally-running backend with `pkill -x patrimonio`.
- **CI** (`8690433`): every push/PR runs the integration suite +
  `flutter analyze`/`test` — that's the real gate now.
- **Prod**: host `thelab` (`ssh nickvander@thelab`), docker compose stack
  at `/mnt/data/docker/stacks/patrimonio`, api on `:8085`. See
  `docs/migration.md` + `docs/deployment.md`.
- Direct-push to `main` is gated by the Claude Code classifier; do the local
  `git merge --ff-only` + `git push origin main` (the user authorizes pushes).
