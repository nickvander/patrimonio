# Tax Planning Tab — Vetted Revamp Backlog

## Executive summary

**What the tab does today.** The Tax Planning tab calls `GET /tax/summary`, which sums "income" transactions for the selected year, pulls realized capital gains from `lot_disposals` split short/long-term (falling back to a blended cost-basis guess when no lots exist), and runs the totals through hardcoded US ordinary/LTCG brackets and a Mexican ISR tarifa. The screen shows three KPI cards (total taxable, US liability, MX liability), a flat list of income transactions, a filing-status and year dropdown (current/previous year only), and CSV/PDF exports — the CSV includes a Form-8949-style disposal section that never appears on screen.

**State of the tab.** Critic review was largely accurate — I verified every load-bearing claim against the code. The headline numbers are wrong today for this user in at least four independent ways: the income query filters on category strings (`'Income'`, `'Salary'`, `'Interest'`, `'Investment Sale'`) that no writer in the codebase ever produces (Plaid sync stores PFC `'INCOME'`, the MX categorizer emits `'INCOME'` — so ordinary income reads **$0**); MXN and USD amounts are summed raw and fed to both countries' brackets; 401k/IRA/HSA disposals are counted as taxable gains (no account join exists in `tax.rs:197-219` despite `lot_disposals.account_id` being in the schema); and Plaid cash dividends are deliberately dropped at sync. The bracket tables are mixed-vintage (ordinary cutoffs `11,600/47,150/…` vs LTCG bands `48,350/533,400`) while the UI claims "2026 brackets", and there is no standard deduction. Milestone 1 is therefore correctness; features come after the numbers can be trusted.

---

## Milestone 1 — Make the existing numbers correct (P0)

### T1. Fix income-category predicates so ordinary income is nonzero — **P0, S**
**Problem:** `tax.rs:182,257,314` filters on Title-Case categories nothing writes. Salary/interest from Plaid (`'INCOME'`, `category_detailed LIKE 'INCOME_%'`) and from Banamex/BBVA/Nu imports (`'INCOME'`) are invisible; the tab shows $0 ordinary income and an empty events list with full data.
**Acceptance criteria:**
- Income predicates match the actually-stored taxonomy: `category = 'INCOME' OR category_detailed LIKE 'INCOME_%'` (case-insensitive), honoring `user_category` overrides if present.
- Drop the phantom `'Investment Sale'` path or map it to the lot-disposal source (the summary already prefers lots).
- Regression test: insert one sync.rs-shaped (`'INCOME'`/`'INCOME_WAGES'`) and one categorize.rs-shaped (`'INCOME'`) row; assert nonzero `ordinary_income` and both rows in `/tax/transactions`.
**Files:** `backend/src/services/tax.rs`; reference `backend/src/services/sync.rs`, `backend/src/services/categorize.rs`. Also update the frontend icon check on `'Investment Sale'` (`frontend/lib/screens/tax_planning_screen.dart:135`).

### T2. Exclude tax-advantaged accounts from taxable capital gains — **P0, S**
**Problem:** The ST/LT query (`tax.rs:197-219`) and disposal detail (`tax.rs:339-358`) aggregate ALL `lot_disposals` with no join to `accounts`. A rebalance inside the user's 401k/IRA/HSA inflates the taxable-gains figure and liability. `lot_disposals.account_id` and `accounts.account_type` (Plaid subtype, normalized by migration 2026060801) already exist — this is one join.
**Acceptance criteria:**
- Disposals in tax-advantaged subtypes (`401k`, `403b`, `457b`, `ira`, `roth`, `roth 401k`, `hsa`, `529`, `pension`) are excluded from taxable ST/LT sums and from the CSV's 8949 section.
- Tax-advantaged activity is shown as a separate, clearly labeled line/section, not silently hidden.
- Test: disposal in a `'401k'` account contributes zero to `short_term_gains`/`long_term_gains`; same disposal in `'brokerage'` contributes.
**Files:** `backend/src/services/tax.rs`, `backend/src/api/tax.rs`.

### T3. Normalize income to a canonical currency before bracket math — **P0, M**
**Problem:** `tax.rs:176-192` does `SUM(amount)` ignoring `transactions.currency`; a MXN payroll row and a USD deposit are added as raw numbers, then the blend is fed to USD brackets AND the MXN ISR tarifa — one side is off ~18x by construction. The lot-disposal path already does per-row FX correctly (`tax.rs:372-381`), and `exchange_rates`/`lookup_usd_fx_rate` infrastructure exists.
**Acceptance criteria:**
- Each income transaction is converted at its date's (or month's) stored USD/MXN rate; US liability computed on the USD total, MX liability on the MXN total.
- `TaxEstimation` fields are explicitly documented/tagged as USD so the frontend's single `conversionFactor` (`tax_planning_screen.dart:251-277`) is well-defined; visible event rows reconcile with the headline.
- Test: one MXN 50,000 + one USD 5,000 income row with a stored rate produce the expected USD and MXN bases (not 55,000).
**Files:** `backend/src/services/tax.rs`, `backend/src/services/exchange_rate.rs` (reuse), `frontend/lib/screens/tax_planning_screen.dart`.

### T4. Year-keyed, verified bracket tables + standard deduction — **P0, M** ⚠ tax-pro input required
**Problem (verified in code):** Ordinary brackets (`tax.rs:50-56,63-69`) and LTCG bands (`tax.rs:134-138`) are different vintages in the same file, while comments and the UI disclaimer (`app_en.arb:851`) claim 2026. There is no standard deduction — brackets apply from dollar zero, and the LTCG stacking start (`tax.rs:274-276`) is therefore also wrong. The MX tarifa's first cutoff (11,122.20 @ 1.92%, `tax.rs:89`) could not be matched to a published SAT tarifa.
**Acceptance criteria:**
- Brackets/deductions/LTCG bands live in per-year constant tables keyed by the selected tax year; unknown years fall back to the nearest table with an explicit note.
- Standard deduction (by filing status and year) is subtracted before ordinary brackets and before the LTCG stacking start.
- Disclaimer string is parameterized with the bracket year actually used (also fixes the stale-l10n finding).
- Unit test pins one cutoff per year per table to its cited source.
- **All constants (US 2025/2026 ordinary + LTCG + standard deduction incl. any 2026 law changes, and the SAT annual tarifa) sourced and signed off by a human — do not trust any vintage currently in the file.**
**Files:** `backend/src/services/tax.rs`, `frontend/lib/l10n/app_en.arb` (+ other locales), `frontend/lib/screens/tax_planning_screen.dart`.

### T5. Capital-loss netting, $3,000 ordinary-offset cap, and term-classification fixes — **P1, M** ⚠ tax-pro review of ordering rules
**Problem (verified):** A net ST loss flows uncapped into ordinary income (`tax.rs:274`); LT losses simply vanish (`calculate_us_ltcg` returns 0 for gain ≤ 0); unknown-acquisition disposals default to *long-term* with a comment calling it "conservative" (`tax.rs:205-208`) when LT is the lower-rate bucket — the opposite of conservative; long-term is `> 365 days` instead of "more than one calendar year".
**Acceptance criteria:**
- ST/LT buckets net per IRS ordering; net capital loss offsets ordinary income capped at $3,000 with the implied carryforward reported as its own field.
- Unknown-term disposals count as short-term in the liability while exports keep the "Unknown" label.
- Term test compares `sell_date > acquired_at + 1 year` (calendar), with a leap-year unit test.
- Netting/ordering rules verified by a tax professional before shipping.
**Files:** `backend/src/services/tax.rs`, `backend/src/api/tax.rs`.

### T6. Persist cash dividends and brokerage interest at sync; include in the estimate — **P1, M**
**Problem (verified):** `process_investment_event` (`sync.rs:~907-943`) early-returns on everything except buy/sell/reinvestment — Plaid cash dividends and brokerage interest are discarded, and investment-account cash events don't flow through `/transactions/sync`. The 1099-DIV line for this user is silently $0.
**Acceptance criteria:**
- Plaid investment events of type cash/dividend/interest are persisted (transactions row or dedicated table, idempotent on `investment_transaction_id` like lots).
- Tax summary includes a dividends/interest line distinct from wages.
- Re-sync of the same window does not duplicate rows.
**Files:** `backend/src/services/sync.rs`, `backend/src/services/tax.rs`, possibly a new migration.
*(Qualified-vs-ordinary dividend classification: deferred — see below.)*

---

## Milestone 2 — Make the screen trustworthy and usable (P1)

### T7. Surface realized disposals on screen via a JSON endpoint — **P1, M**
**Problem (verified):** The capital-gains headline comes from `lot_disposals` but the on-screen event list comes from `get_taxable_transactions` — the user sees a gains number with zero visible events behind it. `TaxService::get_lot_disposals` already exists but only feeds the CSV.
**Acceptance criteria:**
- `GET /tax/disposals?year=` returns `Vec<TaxDisposal>`.
- Screen renders a "Realized gains" section: symbol, dates, term badge, proceeds/basis, signed gain colored by sign (adopt `realized_gains_card.dart`'s `_signedMoney`/`_pnlColor` convention — fixes the verified all-green-losses bug at `tax_planning_screen.dart:201`).
- Income rows and disposal rows visibly reconcile with the KPI cards (per-section subtotals).
- Dead hover affordance fixed: rows either tap through to detail or drop `hoverColor`.
**Files:** `backend/src/api/tax.rs`, `frontend/lib/screens/tax_planning_screen.dart`, `frontend/lib/services/api_service.dart`.

### T8. Label the US/MX cards as alternative scenarios + visible assumptions — **P1, S** ⚠ tax-pro wording review
**Problem (verified):** Both liabilities are computed over the same total income (`tax.rs:275-281`) and shown side by side, inviting the user to sum them — implying double taxation. The MX simplification (everything through the salary tarifa) is disclosed only in a code comment. The blended fallback (default 20%-of-proceeds profit guess, `tax.rs:244-267`) carries no on-screen marker; only the CSV labels it.
**Acceptance criteria:**
- Cards explicitly read as "if all income were taxed in the US / in Mexico" scenarios; copy states federal-only, no NIIT/state, no FTC.
- An "Assumptions" caption/popover near the KPIs lists: bracket year, FX treatment, filing status, exclusions — at readable size, not the 10px footer.
- When `gains_from_lots == false`, the gains and liability figures carry an inline "rough estimate" badge.
**Files:** `frontend/lib/screens/tax_planning_screen.dart`, `frontend/lib/l10n/*.arb`.

### T9. Persist filing status; derive the year list from data; label the controls — **P1, S**
**Problem (verified):** `_filingStatus` resets to `'Single'` every visit (`tax_planning_screen.dart:35`); the year dropdown is hardcoded to current/previous year (`:314`) while `/dashboard/realized-gains` already returns an all-years `by_year` list and statement imports span further back; both dropdowns are unlabeled.
**Acceptance criteria:**
- Filing status persisted via the existing `GET/PUT /settings/{key}` (`api/settings.rs:25`), loaded in `initState`; backend reads it as the default when the query param is absent (so direct CSV/PDF links are correct too).
- Year list = union of years present in transactions and disposals.
- Both controls labeled and localized ("Filing status", "Tax year").
**Files:** `frontend/lib/screens/tax_planning_screen.dart`, `backend/src/api/tax.rs`, `backend/src/api/settings.rs` (reference).

### T10. Visual conformance: responsive layout, semantic tokens, brand typography, skeleton loading — **P1, M**
**Problem (verified):** No `LayoutBuilder` in the file — header Row and 3-across KPI Row overflow at phone widths while the rest of the app uses 520/720/900 breakpoints; raw `Colors.redAccent/white/blueAccent/greenAccent` bypass `theme_colors.dart` and break light mode (PDF button: near-black text on saturated blue); hero figures skip `brandDisplayStyle`; every filter change unmounts the whole screen into a bare spinner, with the two API calls awaited sequentially.
**Acceptance criteria:**
- Breakpoints mirror the dashboard: controls wrap below ~720px; KPI cards stack below ~520px; no overflow stripes at 380px.
- All five raw colors replaced with semantic tokens (`context.negative`/`info`/`positive`); KPI values use `brandDisplayStyle(fontSize: 28)`; title aligned with sibling tabs (20px).
- First load shows a layout-true skeleton; filter changes keep content mounted and dim while refetching; summary+transactions fetched with `Future.wait`.
**Files:** `frontend/lib/screens/tax_planning_screen.dart`; reference `utils/theme_colors.dart`, `theme/typography.dart`, `widgets/skeleton.dart`, `screens/dashboard_screen.dart`.

---

## Milestone 3 — Planning features the data already supports (P1/P2)

### T11. "What if I sell" — unrealized per-lot view, days-to-long-term, harvest candidates — **P1, L**
**Problem:** Everything in the tab is backward-looking, but the planning primitives are fully in the DB: `holding_lots` has per-lot `acquired_at`, qty, cost, currency, `usd_fx_rate` (already serialized to the frontend per `dashboard.rs:~430-442`), and holdings carry current price. No unrealized ST/LT view, no "N days until long-term", no loss-harvest list exists.
**Acceptance criteria:**
- Per-lot unrealized G/L table grouped ST/LT, **taxable accounts only** (depends on T2's account-type filter).
- Lots within 60 days of long-term status highlighted with the date they flip.
- Harvest-candidates card: taxable lots with unrealized losses, estimated tax savings at the user's marginal bracket, and a wash-sale guard (don't recommend a harvest when a same-holding buy occurred within ±30 days — see T12).
**Files:** new endpoint in `backend/src/api/tax.rs` + query in `services/tax.rs`, `frontend/lib/screens/tax_planning_screen.dart`.

### T12. Wash-sale detection on disposals — **P2, M** ⚠ tax-pro review of scope
**Problem:** The CSV is 8949-styled with no wash-sale column, and loss disposals reduce the liability with no adjustment. Inputs exist: `lot_disposals` (pnl, sell_date, holding_id) self-joined to `holding_lots` buys within ±30 days.
**Acceptance criteria:**
- Per-disposal wash-sale flag (loss + same-holding buy in the 61-day window); flagged losses excluded from the liability estimate; flag column in the CSV; T11 harvesting UI warns with the safe-after date.
- Tax pro confirms acceptable simplifications (same-holding proxy for "substantially identical"; cross-account scope).
**Files:** `backend/src/services/tax.rs`, `backend/src/api/tax.rs`.

### T13. FBAR/FATCA threshold monitor — **P2, S**
**Problem:** `balance_snapshots` already stores daily per-account balances with `balance_usd` (initial schema:36-45); the FBAR question ("did aggregate foreign accounts exceed $10,000 at any point?") is one max-over-year query across the MX institutions, yet nothing surfaces it — for this product's defining user.
**Acceptance criteria:**
- Card shows max aggregate foreign (MX-institution) balance YTD in USD, threshold status, and the accounts involved; clearly labeled informational, with the threshold constant documented for human verification.
**Files:** `backend/src/services/tax.rs` or `api/tax.rs`, `frontend/lib/screens/tax_planning_screen.dart`.

### T14. Categorize CETES interest so it reaches the tax base — **P2, M**
**Problem (verified):** Both cetesdirecto parsers hardcode `category: None` (`cetes.rs:35`, `cetes_pdf.rs:140`) and their generated descriptions miss the categorizer's income keywords, so Cetes yield contributes nothing to ordinary income or the MX estimate.
**Acceptance criteria:**
- Maturity-premium/interest rows tagged `'INCOME'` (interest detail) at parse time; if the statement prints ISR retenido, parse and store it so the MX card can later show "estimated minus withheld".
- Parser test: a Cetes maturity yields an income-categorized row that appears in `/tax/summary` (with T1).
**Files:** `backend/src/services/parser/cetes.rs`, `cetes_pdf.rs`, `backend/src/services/categorize.rs`.

### T15. Retirement-contribution tracking vs annual limits — **P2, M** ⚠ limits need human sourcing
**Problem:** The app knows which accounts are 401k/IRA/HSA and sees the inflows (lot buys per account, HSA statement imports), but offers no "YTD contributions vs limit" — the highest-leverage actionable move before deadlines.
**Acceptance criteria:**
- Per account type: YTD contributions, that year's limit (per-year constants beside the T4 bracket tables, human-verified incl. catch-up rules), remaining room, deadline (noting IRA/HSA prior-year window).
- Employer-match/rollover inflows are at minimum called out as a caveat if indistinguishable.
**Files:** `backend/src/services/tax.rs`, `frontend/lib/screens/tax_planning_screen.dart`.

---

## Rejected / deferred

- **Withholding, quarterly estimates, safe-harbor (2 critics)** — deferred. Real gap, but unlike everything above it needs data the app does *not* hold (withholding amounts); gross-vs-net inference is speculative. Revisit as a manual-input feature after Milestone 1 makes the liability number meaningful.
- **Full foreign-tax-credit model / residency modeling** — deferred pending tax-professional design; the immediate harm (cards implying double taxation) is fixed cheaply by T8's labeling.
- **MX 10% definitivo rate on listed-equity gains / ISR interest regime** — deferred; regime question for the tax pro. T8 discloses the simplification meanwhile.
- **NIIT and state tax modeling** — deferred; T8 adds the "federal only, excludes NIIT/state" caption.
- **Qualified vs ordinary dividend classification (61-day rule)** — deferred until T5's dividend ingestion has real data; nice differentiator, not foundational.
- **Estimated annual dividends from `dividends.rs` Yahoo rates as a tax line** — rejected; projections don't belong in a tax estimate, and T5 captures actuals.
- **List grouping/month subtotals beyond T7's reconciliation** — folded into T7; not tracked separately.
- **Duplicates merged:** phantom categories (2 critics → T1), multi-currency summing (3 → T3), retirement-account exclusion (2 → T2), dropped dividends (2 → T6), year-list/filing-status/disposals-on-screen (3 → T7/T9), disclaimer staleness (2 → T4/T8).
- **No critic findings were factually wrong.** Every claim I spot-checked (category strings, bracket constants, missing account join, missing currency column usage, sync skip list, all UI line numbers) matched the code. The only correction of emphasis: the "conservative default" mislabel (T5) is a comment/semantics bug with modest dollar impact, not a headline issue.

## Assumptions a tax professional must verify (do not ship T4/T5/T12/T15 without this)

1. **US ordinary brackets and standard deductions for tax years 2025 and 2026** — the code's current tables appear to be 2024 (ordinary) and 2025 (LTCG) vintage; 2026 figures must reflect any post-2025 law changes. Source: IRS revenue procedures.
2. **LTCG 0/15/20% band thresholds per year and the stacking-on-taxable-income mechanics** as implemented in `calculate_us_ltcg`.
3. **SAT annual ISR tarifa** — the current first cutoff (11,122.20 @ 1.92%, derived "Mensual elevated to Annual") could not be matched to a published tarifa; verify against Anexo 8 RMF for each supported year, and whether annualizing the monthly tarifa is acceptable at all.
4. **Capital-loss netting order, the $3,000 ordinary-income offset cap, and carryforward mechanics** (T5).
5. **Wash-sale scope** — whether same-holding-ID within ±30 days is an acceptable proxy for "substantially identical", and cross-account/IRA interactions (T12).
6. **"More than one year" long-term boundary** including the exact-anniversary edge case (T5).
7. **Which account subtypes are tax-deferred vs tax-free vs taxable** for T2's exclusion list (esp. HSA state treatment, Roth vs traditional).
8. **FBAR $10,000 aggregate threshold mechanics and FATCA Form 8938 thresholds** for T13's copy.
9. **401k/IRA/HSA contribution limits, catch-up amounts, and prior-year contribution deadlines per year** (T15).
10. **US–MX treaty/FTC framing** used in any future combined-liability card, and the MX 10% definitivo regime for listed equities.