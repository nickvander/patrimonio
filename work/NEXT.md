# Next session — handoff

> **⇒ START HERE: [work/HANDOFF.md](HANDOFF.md)** has the current
> (2026-07-07) state — every sprint since 2026-06-06 is logged there,
> and [work/CURRENT.md](CURRENT.md) has the detailed 2026-07-06/07
> Portfolio-overhaul log. This file is the "what to actually do next"
> filter.
>
> **Last updated:** 2026-07-07 (after the Portfolio-tab overhaul deployed)
> **Purpose:** Pickup-ready priorities for the next agent. Ordered by
> impact-per-effort.

`work/FUTURE.md` has the full backlog with detailed plans.

## In progress right now (2026-07-07) — owner-chosen priorities

1. **Dividend fan-out caching.** `GET /dashboard/holdings/dividends`
   (`daf7ffe`) does bounded-parallel Yahoo fetches per held symbol on
   every request — slow and rate-limit-prone as holdings grow. Cache the
   per-symbol dividend data (the `benchmark_prices`-style
   table + freshness-gate pattern is the house precedent).
2. **Target-allocation / rebalancing view.** Let the user set target %
   per asset class and show drift + the trades that would rebalance.
   Builds on the canonical `asset_class` classifier + per-symbol
   overrides that shipped in the July overhaul.
3. **Dark-mode chart tooltip + palette pass.** See FUTURE.md "Color
   palette overhaul" — the net-worth/projections tooltips + hover guide
   are already fixed; this pass is the remaining palette-wide work
   (light-mode contrast on the scaffold, brand accents that wash out on
   white, an accents map instead of scattered hex literals).
4. **Dividend income calendar.** Month-by-month view of expected
   dividend payments, from the per-symbol schedule data behind the
   dividend detail sheet (`/dashboard/dividends/{symbol}`).

## Open backlog (next up after those)

- **Statement-import validation with real PDFs + more MX banks.**
  BBVA/Santander parsers are still on reconstructed fixtures — run real
  personal PDFs through `cargo run --bin parse_check <bank> <file>`
  before advertising; HSBC needs a clean PDF (parser exists,
  unadvertised). New banks: Banorte/Scotiabank/HSBC parsers already
  exist (don't redo) — next are Banregio, Inbursa, Banco Azteca via the
  same `parser/column_table.rs` pattern.
- **Balance-over-time chart from `balance_after`.** A per-account chart
  shipped 2026-06-03 (`AccountBalanceChart`, statement-imported accounts
  only) — remaining scope: extend beyond statement-backed accounts /
  surface it more broadly.
- **Per-word OCR confidence** (tesseract TSV) to flag only genuinely
  low-confidence rows instead of the whole OCR'd file.
- **Balance-anchored dedup hash** (date+amount+balance_after) so a
  description that parses slightly differently across parser versions
  doesn't re-import.
- **Performance-card time-proportional ticks.** The instrument sheet got
  time-proportional chart ticks in the overhaul (`ca4ca8d`); port the
  same treatment to `performance_card.dart`.
- **ES percent locale consistency.** Percent formatting isn't uniformly
  locale-aware in the Spanish UI; sweep the `%` call sites.
- **`prefer_const_literals_to_create_immutables` sweep** — see FUTURE.md
  for the staged plan; lint still off in `analysis_options.yaml`.

## Recently shipped (do NOT re-do)

**June–July 2026** (full detail in HANDOFF.md's dated sections +
CURRENT.md):

* **Portfolio-tab overhaul (2026-07-06/07, deployed):** dividend
  frequency fix, dividend/instrument detail sheets, prefixed allocation
  filters + asset-class classifier + per-symbol overrides, day change,
  CSV exports, realized-gains year chips + tax context, holding soft
  delete + undo, dividends on Overview/Projections, a11y sweep, mobile
  polish.
* **Custom irregular loan schedules + off-bank reconciliation**
  (`14110dc`) and full Lending-tab localization (07-06).
* **CUJ/competitive sweep across all tabs** (`6ffcf2b`) + dividend
  income endpoint + selectable benchmark (`daf7ffe`) + manual USD/MXN
  rate override (`90d7ece`) + tax bracket/LTCG headroom (`c78c4ed`).
* **Tax constants verified** (MX ISR tarifa was wrong; fixed +
  `TAX_CONSTANTS_VERIFIED` flipped, `290cca4`); mega-backdoor/backdoor
  Roth + §415(c) limits; 401k elective-deferral split.
* **CI on push/PR** (integration suite + flutter analyze/test) and the
  silently-skipping integration suite resurrected (`4af62e3`).
* **Forensic accounting-accuracy audit** (`060dbb2`) + June audit
  sprints (`f475ead`, `0d5c3c6` — incl. the Plaid per-user isolation
  fix).
* **Under-reviewed-tabs sweep** (06-19/20): auto-archive, statement
  coverage, top movers, loan aging, nominal/real toggle, sync health,
  undo delete, filtered CSV, period selector.
* **Mobile-calm pass across every tab**; concurrent sync with live
  progress; passkey step-up password set; Revolut (MX) parser.
* **Transactions revamp M1–M4** (sign convention fixed, command
  palette, full-history search) + **tax-planning overhaul T1–T15**
  (disposals, wash-sale, FBAR, ISR retenido) + FIRE/projections UX.
* **Real-statement import sprint** (Nu cajitas, cetesdirecto, CLABE
  identity + auto-match, net-worth backfill from running balances),
  manual holdings by ticker + nightly price refresh, HealthEquity HSA +
  Fidelity NetBenefits parsers, break-glass admin CLI + migration
  runbook (→ prod now lives on thelab).

**May 2026 and earlier** — the previous Top-3 (SQL net-worth,
integration tests, Manage hidden things) all shipped. Highlights
from those trailing sprints (all on `main`):

* **Personal lending (opt-in module):** complete — MVP + Phase 2 +
  Phase 3 + interest-income accounting. Loans + reusable people
  directory + reconciled repayments (auto-suggest matcher),
  amortization schedules + reminders, write-off/defaulted statuses,
  per-year/per-month rates, interest_only + compound types, printable
  promissory-note agreement, interest-income report + CSV exports +
  §7872 below-market flag. Gated behind `lending_enabled`. Full detail
  in `work/LENDING_FEATURE.md`. Remaining deferred follow-ups
  (multi-currency reporting-currency conversion, mid-stream
  re-amortization, Schedule-B-formatted year-end doc) are NOT next.
* **Auth:** TOTP confirm replay-marker fix (was blocking login for
  up to 30 s after enrollment); rate-limit hardening with per-user
  exponential backoff (1→2→4→8→16→30 s capped) on the 429 path +
  50-150 ms `random_login_jitter` on every failed verify
  (unknown user / inactive / bad password / bad TOTP / bad
  recovery code).
* **Imports:** parallel PDF parse via `JoinSet` (24-file batch goes
  from N × per-file to ceil(N/cores) × per-file); 10-min frontend
  timeout with a useful TimeoutException message; "Reading N files…"
  status during the browser-side byte-read phase.
* **Subscriptions:** sign-convention bug fix (Interest earned was
  clustering as a fake subscription); per-account `by_account`
  breakdown with chips; cancelled-subscription "Stopped (N)"
  collapsed section.
* **Splits:** atomic PUT replace-splits endpoint (closed the
  unsplit-then-resplit race window); quick-split presets (50/50,
  60/40, 70/30, 40/30/30, even-N slider); edit-split affordance;
  per-row category dropdown.
* **Webhook ops:** `/api/setup/status` `plaid_webhook` check +
  Management-tab "Push to N institutions" trailing button +
  one-shot `/api/institutions/update-webhook`.
* **Hidden items:** unified panel for ignored subscriptions + the
  since-last-login banner dismissal + FX-transfer pairs the user
  has unlinked. The FX path also fixed a latent sign-convention
  bug in the detector (was filtering on `amount > 0` as outflow,
  but the app stores expense as negative — every detector run
  was returning 0 candidates against real data).
* **Net-worth aggregation:** rewritten as a single
  `jsonb_object_agg` query — same JSON shape, less Rust work.
* **Sign-convention manual-tx bug:** AddTransactionDialog was
  storing "Expense" as positive (income); fixed.
* **Test infra:** `scripts/test.sh` wrapper (dockerised toolchain
  + idempotent test-DB create + `--test-threads=1`); 21 dashboard
  integration tests including multi-file upload happy path.
* **Inline transaction rename:** right-click on a row → quick
  rename dialog (with the bulk-apply "also apply to N matching"
  checkbox when applicable); far fewer clicks than the detail-
  modal flow. Long-press keeps the selection-mode semantics.
* **Streaming CSV export** (audit P4): `export_transactions_csv`
  rewritten as `sqlx fetch` → `mpsc::channel` →
  `axum::body::Body::from_stream`. A 50k-row export now fits in
  O(channel_buffer × row_size) RAM.
* **Per-file upload progress:** `/imports/upload` now emits NDJSON
  events (`started` → `file_done` × N → `done` /
  `password_required`). Frontend reads chunked bytes and renders
  "Processing N of M files… · Last: foo.pdf" in real time.
* **CORS check in setup-status:** new `cors` check warns when
  `ALLOWED_ORIGINS` is missing the actual `FRONTEND_BASE_URL`.
* **README auth section:** documents TOTP enroll / recovery
  codes / passkey register flows + the hardening defaults.

## Top priorities for the next session (2026-06-02) — ALL SHIPPED

> 2026-07-07 note: the Top 3 below all shipped — secondary/Pagaré
> accounts import as their own accounts (and cajitas as sub-accounts,
> `d90611d`), auto-categorization shipped with learn-from-edits, and
> statement continuity/gap detection shipped incl. the coverage panel.
> Kept for history.

**Statement import was overhauled this sprint** (Banamex multi-format —
text PDFs, Firefox-print-to-image, scanned — + OCR, multi-account handling,
preview dedup, inline account creation, import cleanup/undo, account balance
from closing SALDO). The full as-built map **and the prioritized
next-feature backlog** live in **[work/STATEMENT_IMPORT.md](STATEMENT_IMPORT.md)**.

Top 3 from that backlog, by impact-per-effort:
1. **Import the secondary (Pagaré/Ahorro) account as its own account** — we
   currently drop it, so that savings balance is invisible in net worth.
2. **Auto-categorize imported transactions** — ~1,600 uncategorized rows are
   low-value until categorized; unblocks spending/trends views.
3. **Statement continuity / gap detection** — verify opening[N] == closing[N-1]
   across months to catch missing statements or parse errors.

Also shipped this sprint (lending): borrower payment-plan PDF/CSV export,
solve-for-term ("set the payment") calc, guided loan-style form.

---

## Top 3 (2026-05-30) — ALL SHIPPED

The previous Top-3 are done. Verified green: backend 126 tests
(`./scripts/test.sh`), frontend 94 tests (`flutter test`).

### 1. Multi-user roles (`owner` vs `read-only`)  ✅ DONE

Backend shipped earlier (migration `2026051901_user_roles.sql`,
`require_owner` middleware in `api/session.rs`, `role` on the invite
mint endpoint) with tests (`read_only_user_can_get_but_not_mutate`,
`read_only_user_can_still_log_out`, `owner_role_passes_require_owner`).
**Frontend gap closed this session:** the invite-mint UI now offers
a Full-access / Read-only picker (`_InviteRoleDialog` in
`security_screen.dart`), `ApiService.createInvite` sends `role`,
`InviteSummary` parses+displays it (read-only chip in the invites
list). Unit test: `test/services/invite_summary_test.dart`.

### 2. Real-time dashboard via websockets  ✅ DONE

Shipped: per-user broadcast hub (`services/realtime.rs`), WS endpoint
(`api/realtime.rs`), `RealtimeEvent` vocabulary, frontend
`services/realtime_service.dart`. Auth-scoped per `user_id`. Covered
by the dashboard integration suite.

### 3. `Sessions "new since last visit"` badge + upload preflight  ✅ DONE

* Session badge shipped: amber "New since last visit" pill on the
  Security screen's active-sessions list (`newSinceLastVisit`,
  driven by `created_at > users.previous_login_at`).
* **Upload preflight closed this session:** `import_screen.dart`
  now sums `PlatformFile.size` before upload — blocks over the
  100 MB body limit with a clear message, warns past 90 MB —
  instead of streaming a doomed payload to a 413.

## Quick wins (≤ 2 hours each)

> 2026-07-07 status: most of these shipped —

- **`prefer_const_literals_to_create_immutables` sweep** — still open
  (also listed in the backlog above).
- ~~**Manual sync trigger UI**~~ ✅ shipped — overview sync bar
  (`aa5419d`) + live "updating X of N" progress (`72b78e0`).
- ~~**Inline-rename `R` keyboard shortcut**~~ ✅ shipped 2026-05-28
  (backlog-cleanup bundle, see CURRENT.md).
- ~~**Per-file upload result table**~~ ✅ effectively shipped via the
  grouped review panel + statement summary strip + determinate progress
  bar + honest folder-read counter (`9ef8eba`, `c437dc1`, `5d2496a`).

## Deferred — explicitly NOT next

* **Color palette deeper polish** — chart hover smoothness +
  scaffold chroma tweak. Cosmetic; wait for a real complaint.
* **Flutter canvaskit responsiveness** — render freeze on rapid
  taps. Open question, no urgent symptom. `work/FUTURE.md` J.
* **Cross-tenant isolation integration test** — the multi-user
  data model is correct (every query filters on `user_id`) and
  the dashboard suite covers the cross-user 404 case. A dedicated
  isolation test is belt-and-suspenders; revisit if roles land.

## How to pick up cold

1. Read `work/CURRENT.md` for the snapshot.
2. Read this file (`work/NEXT.md`) — top 3 + quick wins.
3. For Tier-1: open the linked `work/FUTURE.md` section.
4. Verify the stack — **on the dev VM docker is unavailable**: Postgres
   on `127.0.0.1:5442` + Redis on `:6380` run natively with data dirs in
   the repo (see `CLAUDE.md`); the compose stack only applies to prod on
   thelab.
5. Verify auth: `curl http://127.0.0.1:8080/api/health` →
   `{"status":"ok","database":"connected"}`.
6. Run the test suite: on the dev VM, `cargo test` natively in
   `backend/` with `PATRIMONIO_TEST_DATABASE_URL` set (see HANDOFF.md
   "How to verify / ship"); `./scripts/test.sh` is docker-only.
7. Ship → commit → push branch (direct-push to main is blocked by
   the Claude Code auto-classifier; do the fast-forward merge dance
   yourself).
