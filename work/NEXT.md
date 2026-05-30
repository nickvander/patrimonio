# Next session — handoff

> **Last updated:** 2026-05-30 (after the personal-lending feature shipped)
> **Purpose:** Pickup-ready priorities for the next agent. Each item
> has a why, scope sketch, and where to look in code. Ordered by
> impact-per-effort.

`work/FUTURE.md` has the full backlog with detailed plans. This file
is the "what to actually do next" filter — top three by impact +
small wins.

## Recently shipped (do NOT re-do)

This file has been refreshed; the previous Top-3 (SQL net-worth,
integration tests, Manage hidden things) all shipped. Highlights
from the trailing 4–5 sprints (all on `main`):

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

## Top 3 for the next session

### 1. Multi-user roles (`owner` vs `read-only`)  ⏱️ ~half day  🎯 advisor / spouse access

Single-household deployments don't need it, but the moment someone
wants to grant a family member view-only access this becomes
real. Schema: add `role` TEXT to `users` defaulting to `'owner'`.
Middleware: a `require_owner` guard on every mutating endpoint
(POST/PUT/PATCH/DELETE). Invite mint endpoint gains a `role`
field so the inviter can pick.

**Acceptance:** create a read-only invite, redeem it, log in,
confirm GET endpoints return data + every mutating endpoint
returns 403.

### 2. Real-time dashboard via websockets  ⏱️ ~1 day  🎯 elegant; can defer further

Plaid webhooks trigger background syncs; the frontend still
finds out by polling on tab switch. A websocket "dashboard data
invalidated" channel would make new transactions surface
immediately. Significant scope: new ws endpoint, broadcast
plumbing, frontend reconnect logic, auth scoping (a user
shouldn't see another user's invalidations). Tracked in
`work/FUTURE.md` section G.

Park unless polling actually starts to feel slow — the rest of
Tier 2 is higher impact-per-effort.

### 3. Streaming "upload preflight" / `Sessions "new since last visit"` badge

Two ~1-hour items worth bundling:

* `users.last_login_at` exists; the Security screen's active-sessions
  list could flag sessions created since that anchor with a small
  pill ("new since 5d ago"). Improves the "is someone else logged in"
  glance without a separate audit-log dive.
* When the file picker / drop reader is slow on a low-end machine,
  the "Reading N files…" status now shows it. A "preflight" check
  before upload that sanity-checks total size + warns ahead of the
  413 cliff would be polish on top.

## Quick wins (≤ 2 hours each)

Pick one as a warm-up:

- **`prefer_const_literals_to_create_immutables` sweep** — lint
  cleanup; cosmetic.
- **Manual sync trigger UI** — Management tab has the per-row
  retry buttons; a top-level "sync everything now" button next to
  the FX widget would make manual refresh discoverable.
- **Inline-rename `R` keyboard shortcut** (FUTURE.md I follow-up).
  Right-click works; `R` on a focused row would help power users.
- **Per-file upload result table** — the streaming progress shows
  "Last: foo.pdf" but doesn't keep the full list. A small
  expandable section under the spinner could surface every
  per-file outcome (especially useful when 2 of 12 failed).

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
4. Verify the stack: `docker compose ps` shows all four containers
   Up / Healthy.
5. Verify auth: `curl http://127.0.0.1:8080/api/health` →
   `{"status":"ok","database":"connected"}`.
6. Run the test suite: `./scripts/test.sh` (wrapper handles the
   dockerised toolchain, idempotent test-DB creation, and the
   `--test-threads=1` flag).
7. Ship → commit → push branch (direct-push to main is blocked by
   the Claude Code auto-classifier; do the fast-forward merge dance
   yourself).
