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
5. **User rules engine + dry-run** (L) — ✎ DESIGN READY 2026-08-03:
   `work/RULES_ENGINE_DESIGN.md` (rule model + provenance columns,
   precedence with manual-always-wins enforced in SQL, write-time
   application on BOTH import + Plaid paths, Redis-token dry-run/apply
   contract, 5-day MVP phasing). **Awaiting owner sign-off — §8 lists the
   8 open questions.** Implementation does not start before that.

Briefs 6–8 (guided statement reconciliation, sub-5s quick-entry, FX Sankey)
queue behind these — shapes live in the report only.

## Open items needing only a sitting

- **Walkthrough observations (2026-08-03, minor):** (a) net-worth USD lens
  x-axis is index-spaced over snapshots while MXN/Constant-FX lenses are
  time-spaced — same history, different horizontal mapping across lenses;
  (b) bills projection curve in MXN mode labels its y-axis "$100K" style
  while the app elsewhere writes "MXN 100,000" — can read as USD at a
  glance. Both cosmetic, neither blocks review.
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
