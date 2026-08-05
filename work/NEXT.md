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

### ~~Credit-card payments counted as spending~~ ✅ FIXED 2026-08-05 (`de4178f`)

Owner-reported via a phone screenshot; the largest real-money defect found in
this stretch. Cash-flow spending double- and triple-counted rent because the
card charge, plus each checking→card payment leg, all carried
`RENT_AND_UTILITIES_RENT` (the merchant is literally "BILT CARD"), and the
anti-join only excluded payments tagged `LOAN_PAYMENTS_CREDIT_CARD_PAYMENT`.

**Verified on live prod, before → after:** July `RENT_AND_UTILITIES`
**$8,951.77 → $3,360.79** (the real $3,038.13 rent + ~$322 of utilities);
~$5,591 of phantom spending removed from one month. It had been overstating
spending for months, on every surface fed by the shared fragment — trends,
spending-by-category, spending-insights, the Sankey, the recurring detector,
emergency-fund runway and the FIRE projection defaults.

A payment leg is now recognised **structurally**: an outflow from a
non-liability account with a matching inflow on the same user's liability
account (equal amount, same currency, ±5 days — the house pair-matching
window). Five of the seven tests pass before AND after by design — they are
the "never eat real spending" guardrails.

**Two follow-ups this leaves open:**
- **Unlinked cards still produce a phantom recurring cluster.** The collapse
  depends on the card's inflow rows existing. If a card isn't linked, its
  checking-side payment legs still cluster as a fake "subscription". Check the
  live recurring card now that this has deployed — the owner's Bilt entry was
  duplicated for exactly this descriptor reason and should now be single.
- **An optional index** `transactions (account_id, amount, date)` takes the
  worst-case query 74ms → 35ms. Deliberately not added: 74ms on a dashboard
  endpoint doesn't justify write amplification on the hottest table. One-line
  additive migration if it's ever wanted.

### Owner-reported 2026-08-04 — cash-flow / Sankey, INVESTIGATED against prod

A phone screenshot raised three concerns. Checked read-only against the prod
DB the same day; **two of the three are the app behaving correctly**, and the
real finding is a different one. Recorded so nobody "fixes" the right
behaviour.

1. **"Income shows only one source, but I get part of my paycheck in other
   accounts" — NOT a defect.** The current month has exactly two INCOME rows,
   both the same payroll descriptor into the same account, which the diagram
   correctly groups into one source. Every other inflow that month is
   `TRANSFER_IN`: vault moves ("From checking balance" into Cards / Emergency
   / Rent sub-accounts), a brokerage transfer, and one small Zelle receipt.
   Those are the SAME money moving between the owner's own accounts —
   counting them as income would double-count the paycheck. The exclusion via
   `NON_CASHFLOW_CATEGORIES_SQL` is right.
   *Two small judgement calls a future agent may revisit with the owner:* an
   inbound Zelle from another person is arguably income, not a transfer; and
   a brokerage-to-checking move is a transfer only if it's the owner's own
   account (it is here).
2. **The "4206 …" bank code in the source name — real but NOT the Sankey's
   doing.** `cash_flow_sankey.dart:359` uses the house `displayLabel` ladder;
   Plaid supplied no counterparty for that payroll row, so the ladder fell
   through to the raw description. The same label shows anywhere that row is
   listed. Fix belongs upstream (enrichment, or a normalization that strips a
   leading `*NNNN` code before grouping) — not in the diagram.
3. **STILL OPEN — "Left over" is misleading for a vault user.** The
   diagram splits income into spending and "Left over", but internal
   transfers are excluded from cash flow, so money the owner moved into
   savings vaults and card payments lands in "Left over" as if it were
   undirected surplus. In the observed month, transfers out were roughly
   three times the diagram's leftover figure. The FX node already proves the
   pattern works; **a "Moved to savings / cards" node fed from the excluded
   `TRANSFER_OUT` rows would make the picture honest** without touching the
   income maths. Design note: it must stay visually distinct from spending —
   moving money to yourself is not spending.
4. **"Rent is listed even though it's a detected recurring payment" — needs
   the owner's read.** The `RENT_AND_UTILITIES` figure that month is a single
   small charge, i.e. a utility, not rent; the actual (MXN) rent is absent
   because **that month has no MXN transactions at all** — the Mexican
   statements hadn't been imported yet. So the diagram isn't wrong, it's
   incomplete-by-input. The separate reading — that committed/recurring
   spending should be visually distinct from discretionary — is a real design
   idea and is worth asking about, but it is a feature, not a fix.

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
