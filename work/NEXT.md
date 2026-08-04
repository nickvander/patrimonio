# Next session — what to actually do

> **⇒ START HERE: [work/HANDOFF.md](HANDOFF.md)** has the current (2026-08-04)
> state; [work/CURRENT.md](CURRENT.md) has the detailed log. This file is the
> "what to do next" filter over [work/FUTURE.md](FUTURE.md)'s full backlog.
>
> **Last updated:** 2026-08-04 (closeout batch; the sitting-sized list pruned
> to what genuinely remains — all 8 research briefs are shipped)
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

6. ~~Guided statement reconciliation~~ — ✅ shipped 2026-08-03/04. Backend
   `48e906f` classifies the gap (and names the existing transactions that
   explain it); UI `5b48fcd`; the MX parsers now capture the bank's PRINTED
   closing balance where a fixture proves it (`56858f1`), and the panel says
   which balance it checked against (`76511d2`) so a green verdict can't
   overclaim.
7. ~~Sub-5s mobile quick entry~~ — ✅ shipped `42a629e` (3 taps + digits;
   2 taps for a second in a row).
8. ~~FX-aware Sankey~~ — ✅ shipped `2787b2d`, labels fixed `3eb8ddd`.

**All eight briefs are shipped and deployed.** The report's Appendix A lists
18 researched-and-rejected ideas with reasons — read it before proposing new
feature work, and re-run the pipeline (`.agent/workflows/feature-research.js`)
quarterly rather than ad hoc.

## Open items needing only a sitting

### ⚠ OWNER-REPORTED 2026-08-04 — cash-flow / Sankey on real prod data (START HERE)

From a phone screenshot of the Cash flow tab (period showing "Net this period
≈ MXN 32,303", "Every flow shown in USD"). Three distinct issues; **investigate
before fixing — two of them may not be Sankey bugs at all.**

1. **Income shows ONE source at 100% ($2,599.35, "4206 Payroll Google LLC ACH
   Credit") but the owner receives part of their paycheck in other accounts.**
   This is the important one, because if it's real it understates the whole
   cash-flow tab, not just the diagram. The attribution's "Other income"
   residual is *absent*, which means attributed == the authoritative income
   from `/dashboard/trends` — i.e. **the period's income total itself is
   $2,599.35**, and the other deposits aren't in it. Check, in order:
   whether those deposits are classified `TRANSFER*` and therefore removed by
   `CASHFLOW_ROW_ANTI_JOINS_SQL` / `NON_CASHFLOW_CATEGORIES_SQL`; whether the
   receiving accounts are excluded from cash flow (type/archived); whether MXN
   deposits are being dropped rather than converted. Compare
   `/api/dashboard/trends` income against a raw sum of deposit rows for the
   same window before touching any frontend code.
2. **The source name carries a bank code: "4206 Payroll Google LLC ACH
   Credit".** NOT a Sankey defect — `cash_flow_sankey.dart:359` uses the house
   `displayLabel` ladder, same as everywhere else. The ladder fell through to
   the raw description because Plaid enrichment supplied no counterparty for
   that row. So the fix belongs upstream (enrichment / a normalization step
   for income-source grouping), and the same ugly label is presumably showing
   in the transactions list too — check there first. Related risk: if the
   other paycheck deposits carry *different* raw descriptors, they'd group as
   separate sources even once issue 1 is fixed, so grouping may need to
   normalize (strip a leading numeric code) rather than key on the raw label.
3. **"Rent & utilities $79.76" — the owner notes rent is also a detected
   recurring payment.** AMBIGUOUS, ask before building: it could mean (a) the
   figure is wrong/incomplete — $79.76 is implausible for rent, so the actual
   rent payment may be missing from the period entirely, which would make this
   the same root cause as issue 1; or (b) a design request — that committed /
   recurring spending should be visually distinct from discretionary in the
   diagram, since the app already detects it. Do not guess which; (a) is a bug
   and (b) is a feature.


> Pruned 2026-08-04 after the closeout batch. Everything the previous list
> held as actionable is now done — see CURRENT.md's 2026-08-03/04 entries.
> What remains here is genuinely small or genuinely blocked.

- **Four bare `720` literals in `tax_planning_screen.dart`** (≈:485, :1243,
  :2183, :2989) mean the card-density rule but were never named consts, so
  the 2026-08-04 consolidation (`b7a0bfc`, six copies → shared
  `kCompactCardBelow` in `theme/buttons.dart`) couldn't sweep them. Point
  them at the shared const when that file is next open.
- **Sync-row scroll-to-institution** — the one deferred P1 from the
  2026-08-01 notifications work. Not attempted since; needs a look at where
  the sync row's tap target should land.
- **Mobile / settings follow-ups** (FUTURE.md, deferred 2026-07-14) — these
  are NOT sittings, they need real infrastructure: **Android per-app
  language** (`android:localeConfig` + `AppCompatDelegate.setApplicationLocales`
  via a plugin or MethodChannel, plus an emulator smoke test per the AGENTS.md
  Android rule); **server-side sync of theme/locale prefs** (needs a backend
  `app_settings` endpoint, same pattern as `projection_assumptions`); **fold
  the inline auto-archived-accounts card into HiddenItemsScreen**.
- **Detected-charge dedupe has no live evidence** — `duplicated_by_rule` in
  the bills calendar is covered by tests only; the rig's data never triggered
  it. Watch for it the first time a detected charge and an explicit rule
  cover the same bill.
- **⚠ The walkthrough rig can report false hit-region defects.** 2026-08-03:
  a sweep reported 12/12 "reproductions" of an invisible region flipping the
  reporting currency. **It does not exist** — disproved in `9db7001` by
  pumping the real screen and measuring (lattice sweep hits the control zero
  times; tapping the accused centre selects the chip). The rig's x landed on
  the real control while its y was displaced — a coordinate-space offset,
  internally inconsistent with its own control probe. **Reproduce any rig
  geometry claim in a widget test with `tapAt` before acting on it.**
- **Don't "fix" these — they are correct as they stand:** `skipped` in the
  rules apply response is structurally 0 outside the preview→apply race, so
  `ruleAppliedSkipped` is near-unreachable (don't inflate it); the four MX
  parsers left on the running-balance fallback need a REAL statement PDF to
  build a fixture, not more code (`banorte`, `hsbc`, both `banamex`); cetes'
  "Total final" is a portfolio value and must never be compared to a cash
  ledger.

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
