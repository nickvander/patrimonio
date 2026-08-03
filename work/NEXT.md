# Next session — what to actually do

> **⇒ START HERE: [work/HANDOFF.md](HANDOFF.md)** has the current (2026-08-02)
> state; [work/CURRENT.md](CURRENT.md) has the detailed log. This file is the
> "what to do next" filter over [work/FUTURE.md](FUTURE.md)'s full backlog.
>
> **Last updated:** 2026-08-03 (feature-research implementation queue added;
> FUTURE.md gained the five spec'd sweep proposals)
> **Purpose:** Pickup-ready priorities, ordered by impact-per-effort. When one
> of these ships, delete it here and log it in CURRENT.md — a stale backlog is
> worse than none.

## Feature-research implementation queue — 2026-08-03

From `work/research/2026-08-03-feature-research.md` (8 PM-vetted briefs;
FUTURE.md carries the five spec'd sections). Worked SEQUENTIALLY, one
verified checkpoint per feature, in this order:

1. ~~Household continuity dossier~~ — ✅ built + verified 2026-08-03
   (backend 565/565, frontend 975/975; uncommitted pending review — see
   CURRENT.md).
2. ~~Annual transfer-cost report~~ — ✅ built + verified 2026-08-03
   (backend 573/573, frontend 979/979; uncommitted — see CURRENT.md).
3. ~~Net-worth change attribution~~ — ✅ built + verified 2026-08-03
   (backend 578/578, frontend 987/987; sum invariant pinned in tests;
   uncommitted — see CURRENT.md).
4. ~~Bills calendar + 1–90-day projected balances~~ — ✅ built + verified
   2026-08-03 (backend 585/585, frontend 1005/1005; pending_import
   never-false-red pinned in tests; uncommitted — see CURRENT.md).
5. ~~User rules engine + dry-run~~ — ✅ MVP built + verified 2026-08-03
   (backend 614/614, frontend 1033/1033; design signed off, DEC-027/028).
   Design doc `work/RULES_ENGINE_DESIGN.md` §7 lists what the MVP punted
   (regex, revert machinery, hit-count stats, manual-add/split-child
   application, Plaid conflict-path re-evaluation) — pick from there when
   the feature has real mileage.
   Live-rig verified 7/7 (DEC-027 "manual edits win" and both token attacks
   checked against the DB — see CURRENT.md).

Briefs 6–8 (guided statement reconciliation, sub-5s quick-entry, FX Sankey)
queue behind these — shapes live in the report only.

## Open items needing only a sitting

- **`MediaQuery` layout-branch inventory** (from the 2026-08-03 responsive
  pass; `performance_card` + `date_range_selector` already fixed in
  `f86c30e`). Bucket **B — visible consequences, start here**:
  `loan_detail_sheet.dart:674` decides whether the schedule table renders
  AT ALL and `:976` drops two columns below 520 — a *sheet*, the exact
  "wide sheet on a phone" case the rule names, and it removes data on the
  wrong branch; then `budgets_card.dart:436` (also controls row count
  before "show all"), `wealth_projection_screen.dart:1018`,
  `tax_planning_screen.dart:564`, `debt_payoff_card.dart:308`,
  `spending_by_category_card.dart:100`, `lending_tab.dart:183,262`,
  `dashboard_screen.dart:6231`. Bucket **C — cosmetic** (card padding
  16/24 read off the screen) spans ~35 call sites across the widgets and
  screens; sweep opportunistically when a file is open for another reason.
  Legitimately screen-based (do NOT "fix"): dialog/route sizing in
  `import_screen.dart:2165`, `add_transaction_dialog.dart:47`,
  `notifications_panel.dart:797`, and the screen-spanning
  `dashboard_screen.dart:4424,4831,4837,5648`.
- **UNVERIFIED, possibly severe: a Notifications bottom sheet auto-opened
  over the Cash tab and swallowed all input** — seen 2026-08-03 by the
  Sankey rig on a true 390×844 **touch** context at boot. Escape, barrier
  tap and handle-drag all failed; the rig worked around it by booting at
  1440 and resizing. It may be a headless/touch-emulation artifact — the
  owner uses the APK daily and has not reported it, which argues artifact —
  but if it reproduces on a real phone it's a hard input lock. **Verify on
  the emulator or a device before assuming it's the rig.**
- ~~Performance card range selector overflows at phone width~~ — ✅ fixed
  2026-08-03 (`dd38536`): stacks below a 520px inner width; verified at 11
  widths × both locales, sabotage-checked. **Left open in the same file:**
  `performance_card.dart` still derives `isPhone` and its chart height from
  `MediaQuery.sizeOf(context).width < 720`, and `DateRangeSelector` picks its
  padding off `MediaQuery` too — the §4/§5 screen-width-vs-inner-constraint
  pattern, not implicated in this overflow but worth its own pass.
- ~~Rules-engine apply-button copy~~, ~~net-worth lens x-axis spacing~~,
  ~~bills MXN axis notation~~, ~~allocation-header truncation~~ — ✅ all
  fixed 2026-08-03 (`8da7d3d`, frontend 1047). Standing note kept from that
  pass: `skipped` in the APPLY response is structurally always 0 outside the
  preview→apply race, so `ruleAppliedSkipped` is near-unreachable — correct
  by design; **don't "fix" it by inflating the number.**
- **Calendar-detection follow-ups** (from the 2026-08-03 live-rig pass, all
  minor): the ignore endpoint's JSON body key is `merchant` but the value it
  carries is the *merchant_key* — a reader could plausibly send a display
  name; `/api/dashboard/subscriptions` omits `merchant_key` from its items,
  so any other client wanting to ignore a merchant must re-derive the
  detector's normalization (exactly the coupling the calendar's field
  avoids — being fixed 2026-08-03); and the detected-vs-rule dedupe
  (`duplicated_by_rule`) has **no live evidence** — the rig's data never
  triggered it, only tests cover it. ~~detected ring too subtle at 1×~~ ✅
  fixed `dd38536` (8px/2px stroke on pixel boundaries).
- ~~Bills calendar showed only loan repayments~~ — ✅ fixed 2026-08-03
  (`a3915e3` + `56308db`): it read explicit rules only, never the detector.
  Follow-ups the fix deliberately left: detected occurrences project from
  the cluster's last observed charge forward only (earlier cycles aren't
  emitted, to avoid phantom `missed` rows on irregular gaps), and detected
  clusters are capped at 40 by monthly spend — revisit either if a real
  charge goes missing from the calendar.
- ~~Chart tooltip hides under the finger on touch~~ — ✅ fixed 2026-08-03
  (pointer-kind-aware pinning in chart_touch.dart, all line charts, new
  conventions invariant; frontend 996/996 — see CURRENT.md).

- **Audit tail findings still open** (from the 2026-07-26 five-agent audit;
  the truncated-filtered-totals one shipped 2026-08-02 as `X-Total-Count`,
  DEC-025): `import_cleanup` claims "No recent imports" on a load *failure*;
  FBAR per-account contribution uses an exact-date lookup (same
  sparse-snapshot class the aggregate already fixed).
- **Sync-row scroll-to-institution** — the one deferred P1 from the
  2026-08-01 notifications work that didn't ship with the rest (insight
  sheet, comparison banner, account scoping, and net-worth tap all did).
- **Dialog-consistency leftovers** (2026-08-02 sweep's own deferrals):
  `split_transaction_dialog` (custom two-pane layout), lending's own
  `_decoration` idiom, recurring dialog sheet-on-narrow.
- **Mobile / settings follow-ups** (FUTURE.md, deferred 2026-07-14): Android
  per-app language; server-side sync of theme/locale prefs; fold the inline
  auto-archived-accounts card into Hidden items; lending amount fields
  hardcode the "MX$" glyph instead of the locale-aware helper.

## Needs a product/design call first (don't just start coding)


- **FBAR unverified badge + FinCEN peak-balance method** and
  **description-keyed import dedup** — the four-way product-call bundle from
  the 2026-07-26 audit (with the two below).
- **FIRE chart draws the mean, not the fetched p50** (MC-median honesty —
  projections-tax-5 from 2026-07-24, same item).
- **Off-machine backup** — the encrypted dumps never leave the host
  (FUTURE.md item 7's standing follow-up).
- **Portfolio-total reconciliation** (portfolio-1) and the **netted harvest
  model** (projections-tax-2) — deferred 2026-07-24 as "need design, not a
  sitting".
- **Feature shortlist:** manual purchase-lot entry (led the 2026-07-26
  shortlist); MX tax parity (proposal #1 from the 2026-07-23 sweep).

## Standing backlog (FUTURE.md has the detailed plans)

- **Statement-import validation + more MX banks.** BBVA/Santander parsers
  still on reconstructed fixtures (**blocked: no real PDFs to test**); HSBC
  parser exists but needs a clean PDF to advertise; next banks are
  Banregio / Inbursa / Banco Azteca via `parser/column_table.rs`. Plus
  per-word OCR confidence (tesseract TSV) and the balance-anchored dedup
  hash.
- **Lending deferred follow-ups:** multi-currency reporting-currency
  conversion; mid-stream re-amortization; Schedule-B-formatted year-end doc.
- **Palette remainder:** M3 `surfaceContainer*` tonal layering + the
  long-tail `Color(0xFF...)` literals the 2026-07-09 sweep left intentional.
- **`prefer_const_literals_to_create_immutables` sweep** — staged plan in
  FUTURE.md; lint still off.
- **Canvaskit renderer freeze** (FUTURE.md J) — investigate only when it
  annoys a real user; still just a browser-automation nuisance.

## Recently shipped (do NOT re-do)

Full detail in CURRENT.md; July–August highlights only:

* **Transactions overhaul (2026-08-01/02):** exact `X-Total-Count` totals +
  Filter & sort restyle, since-visit drill-downs by sync time, drill-down
  claim banners + fresh-context jumps (DEC-025/026), add-transaction +
  dialog consistency sweep, `ConnectedSegments` extraction (9+ call sites),
  central menu chrome (`theme/menus.dart`), bell-row drill-downs + insight
  sheet + comparison banner.
* **Notifications reconcile + visit anchor (2026-07-30/31,** DEC-023/024**)**;
  net-worth chart x-axis dedupe/clip fix; formatter-clean trees + CI gates.
* **2026-07-26/27:** seven-bug audit batch, sync reaper, year-panic guard,
  panic backstop, resilient reload + WS heartbeat, import writes today's
  snapshot.
* **2026-07-23/24:** six features (FX center, staleness reminders, recurring
  MVP, retire-in-MX, tax export pack, notifications center) + the 14-item
  quick-win burn-down (editable manual tx, FBAR by institution country —
  DEC-022).
* **2026-07-13/14/17:** Android APK (native passkeys, session persistence,
  OAuth deep-link, per-ABI builds), mobile UX overhaul + kebab retirement
  (DEC-017…020), fire-and-forget sync (DEC-021).
* **Early July:** Portfolio-tab overhaul, dividend cache + income calendar +
  rebalancing card, project skills + lint/clippy/CI enforcement, palette
  contrast pass.

## How to pick up cold

1. Read [HANDOFF.md](HANDOFF.md), then CURRENT.md's top entries.
2. Pick an item above; for backlog items open the linked FUTURE.md section.
3. Environment + test commands: repo-root `AGENTS.md` (native Postgres
   `:5442` / Redis `:6380` on the dev VM — docker only exists in CI and on
   thelab; `scripts/test.sh` won't run here).
4. Ship → log in CURRENT.md → prune this file → conventional-commit push
   (direct-push to `main` is classifier-gated; do the `--ff-only` merge
   dance).
