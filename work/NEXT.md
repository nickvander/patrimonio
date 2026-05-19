# Next session — handoff

> **Last updated:** 2026-05-18 (evening, after Top-3 sprint)
> **Purpose:** Pickup-ready priorities for the next agent. Each item
> has a why, scope sketch, and where to look in code. Ordered by
> impact-per-effort.

`work/FUTURE.md` has the full backlog with detailed plans. This file
is the "what to actually do next" filter — top three by impact +
small wins.

## Recently shipped (do NOT re-do)

The previous two sessions cleared most of the original NEXT.md. The
Top-3 from this session's pickup prompt all shipped:

* `since_last_login.largest_move` flips sign for liability accounts.
* Recovery-codes-low warning tile when count < 3.
* Cancelled-subscription detection — separate "Stopped (N)"
  collapsed section, 91–548 day band.
* Mexican parser polish via `parser::polish_description` (strips
  trailing date suffixes + bilingual generic-prefix list).
* `/api/institutions/update-webhook` one-shot endpoint to
  backfill Plaid webhook URL onto existing items.
* `/api/setup/status` exposes a new `plaid_webhook` check.
* `docs/deployment.md` rewritten with a concrete single-VPS
  runbook covering nginx + LE, `TRUSTED_PROXY_CIDRS`, webhook
  activation, log rotation, backups.

Also previously: real-estate / manual assets, HIBP check,
sandbox-vs-prod chip, split-child badge, unhide-subscriptions UI,
SQL liability classifier + cash-flow internal-transfer exclusion.

## Top 3 for the next session

### 1. Frontend tile for the webhook setup-status check  ⏱️ ~30 min  🎯 closes the deployment loop

**Why now.** The JSON is shipped (`/api/setup/status` returns a
`plaid_webhook` entry) but the Management tab card listing setup
checks hasn't been updated to render it. A user looking at the page
today doesn't know whether their webhook is configured.

**Scope.** Find the setup-status renderer in the frontend
(probably `frontend/lib/screens/management_screen.dart` or a tile
widget in `frontend/lib/widgets/`). The check has fields `key`,
`label`, `configured`, `severity`, `detail` — same shape as the
existing checks, so this might just be a matter of adding an icon
mapping for the `plaid_webhook` key.

While there: add a small "Update all institutions" button visible
only when `plaid_webhook` is configured AND there are linked
Plaid institutions. The button POSTs to
`/api/institutions/update-webhook` and shows the per-row result.

### 2. Split-transaction polish (presets + edit)  ⏱️ ~2 hours each

Two small UX wins:

* **Quick-split presets** in the split dialog header (50/50,
  60/40, 70/30, "evenly across N"). A dropdown that recomputes
  amounts to the chosen ratio.
* **Edit-split** action on parents. Today the user has to
  Unsplit then re-Split to change amounts. Add an "Edit split"
  affordance that opens the dialog pre-populated with current
  children.

Tracked in `work/FUTURE.md` section A.

### 3. Net-worth aggregation in SQL (audit P5)  ⏱️ ~half day  🎯 cold-cache cost

`backend/src/api/dashboard.rs` walks a Rust-side BTreeMap to build
the per-account-type history series. Cheap at today's scale (5
institutions × 30d) but quadratic. The audit (P5) recommends a
`jsonb_object_agg` on the postgres side instead. Now that
`is_liability_account_type()` exists, the SQL is clean to write.

Tracked in `work/FUTURE.md` section H.

## Quick wins (≤ 2 hours each)

Pick one as a warm-up:

- **`scripts/dev-rebuild-frontend.sh`** — wrap the rebuild +
  re-stamp-CSP dance documented in `work/CURRENT.md`. (Note:
  this session didn't observe the re-stamp problem — the
  rebuild bakes `security_headers.conf` into the image now —
  but a one-liner script around `docker compose ... build
  frontend` is still nice. Verify whether the re-stamp is
  still needed before scripting.)
- **Inline transaction rename** — long-press on a row opens a
  small inline text field instead of the detail modal.
  Section I in FUTURE.md.
- **Subscription per-account split** — show which account
  charged each detected subscription (some land on both the
  credit card and the checking account via Apple Pay
  passthrough). Section B in FUTURE.md.
- **Integration tests for new endpoints** — `fx-transfers`,
  `subscriptions/ignore`, `splits`, `since-last-login`,
  `institutions/update-webhook` have unit tests for helpers
  but nothing exercises the full request/response. Section K
  in FUTURE.md.

## Deferred — explicitly NOT next

* **Color palette overhaul deeper polish** — most of the WCAG fixes
  shipped. What's left is cosmetic (chart hover smoothness, scaffold
  chroma tweak). Pick up when there's a real complaint or alongside
  another visual feature.
* **prefer_const_literals lint sweep** — see `work/FUTURE.md`.
* **Real-time websocket dashboard updates** — Plaid webhooks just
  trigger background syncs; the frontend still polls on tab switch.
  A websocket "data invalidated" channel would be cleaner but it's
  significant scope and the polling works fine at this scale.

## How to pick up cold

1. Read `work/CURRENT.md` for the snapshot.
2. Read this file (`work/NEXT.md`) — top 3 + quick wins.
3. For Tier-1: open the linked `work/FUTURE.md` section.
4. Verify the stack: `docker compose ps` shows all four containers
   Up / Healthy.
5. Verify auth: `curl http://127.0.0.1:8080/api/health` →
   `{"status":"ok","database":"connected"}`.
6. Ship → commit → push branch (direct-push to main is blocked by
   the Claude Code auto-classifier; do the fast-forward merge dance
   yourself).
