# Next session — handoff

> **Last updated:** 2026-05-18 (late evening, after Top-3 + split-polish sprint)
> **Purpose:** Pickup-ready priorities for the next agent. Each item
> has a why, scope sketch, and where to look in code. Ordered by
> impact-per-effort.

`work/FUTURE.md` has the full backlog with detailed plans. This file
is the "what to actually do next" filter — top three by impact +
small wins.

## Recently shipped (do NOT re-do)

Sprint 1 (Top-3 from pickup prompt):
* `since_last_login.largest_move` flips sign for liability accounts.
* Recovery-codes-low warning tile when count < 3.
* Cancelled-subscription detection — separate "Stopped (N)"
  collapsed section, 91–548 day band.
* Mexican parser polish via `parser::polish_description`.
* `/api/institutions/update-webhook` one-shot endpoint +
  `/api/setup/status` `plaid_webhook` check + Management tab tile
  with "Push to N institutions" action.
* `docs/deployment.md` rewritten with concrete single-VPS runbook.
* Split-transaction quick-split presets + Edit-split affordance.

Sprint 2 (SQL + hidden items + tests):
* `dashboard.rs::net_worth_history` rewritten as a single
  `jsonb_object_agg` query. Same JSON shape, less Rust work.
* New `HiddenItemsScreen` reachable from the AppBar
  visibility-off icon. Lists ignored subscriptions + the
  since-last-login banner dismissal with per-row restore.
* 14 new integration tests in `backend/tests/dashboard_endpoints.rs`
  covering update-webhook, splits (incl. edit-split round-trip),
  since-last-login, subscription ignore/unignore, fx-transfers
  listing, and net-worth-history aggregation (per-date +
  liability sign).

Also previously: real-estate / manual assets, HIBP check,
sandbox-vs-prod chip, split-child badge, unhide-subscriptions UI,
SQL liability classifier + cash-flow internal-transfer exclusion.

## Top 3 for the next session

### 1. Net-worth aggregation in SQL (audit P5)  ⏱️ ~half day  🎯 cold-cache cost

`backend/src/api/dashboard.rs` walks a Rust-side BTreeMap to build
the per-account-type history series. Cheap at today's scale (5
institutions × 30d) but quadratic. The audit (P5) recommends a
`jsonb_object_agg` on the postgres side instead. Now that
`is_liability_account_type()` exists, the SQL is clean to write.

Tracked in `work/FUTURE.md` section H.

### 2. Integration tests for new endpoints  ⏱️ ~half day  🎯 keeps the surface from regressing

`backend/tests/auth_endpoints.rs` covers auth. The recently-added
endpoints have unit tests for internal helpers but no integration
tests:

* `POST /api/institutions/update-webhook`
* `POST/DELETE /api/accounts/transactions/{id}/splits`
* `GET /api/dashboard/since-last-login`
* `GET /api/dashboard/subscriptions`
* `POST /api/dashboard/subscriptions/ignore`
* `GET/POST/DELETE /api/dashboard/fx-transfers`

A "split + edit-split + unsplit" happy-path integration test
would also lock in the edit-split flow that just shipped (it does
two API hits in sequence; an integration test catches the
between-call race if anyone changes the unsplit semantics).

Tracked in `work/FUTURE.md` section K.

### 3. "Manage hidden things" unified panel  ⏱️ ~3 hours  🎯 paying down dismissal debt

A growing list of UI elements have dismissed state with no Unhide
path scattered across the app:

* `ignored_subscription_merchants` (the "× not a subscription"
  affordance on the active rows — the Stopped section already
  shows cancelled ones).
* `Preferences.sinceLastLoginDismissed` (banner dismissal).
* FX-transfer pairs the user has manually unlinked.

A single panel in Settings (or the Management tab) listing
every "thing you told us no to" with a per-row remove button
would be cleaner than per-feature manage screens.

Tracked in `work/FUTURE.md` section D.

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
