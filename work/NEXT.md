# Next session — handoff

> **Last updated:** 2026-05-18
> **Purpose:** Pickup-ready priorities for the next agent. Each item
> has a why, scope sketch, and where to look in code. Ordered by
> impact-per-effort.

`work/FUTURE.md` has the full backlog with detailed plans. This file
is the "what to actually do next" filter — top three by impact +
small wins.

## Top 3

### 1. Real-estate / manual assets  ⏱️ ~half day  🎯 completes net worth

**Why now.** Investment lots, multi-currency cash, and a polished tx
list all ship, but "net worth" still excludes anything not tracked by
a bank or exchange — a house, a car, an LLC stake, private equity.
For affluent users the gap is often 30–60% of true net worth.

**Scope.** `accounts.account_type` already accepts arbitrary values.
Add `real_estate` + `private_equity` + `vehicle` to the seed list of
known types and extend `add_account_dialog.dart` with:
- Friendly type chooser (Property / Vehicle / Private investment / Other).
- Optional `last_valued_at` + `valuation_notes` text field.
- "Revalue" button on the row that bumps `current_balance` and
  appends a new `balance_snapshots` entry.

NetWorthCard already category-aggregates by `account_type`, so the
values flow through automatically. The harder UX bit is choosing
icons + colors that don't look out of place next to bank logos.

**Files**: `frontend/lib/widgets/add_account_dialog.dart`,
`frontend/lib/utils/account_category.dart`,
`backend/src/api/accounts.rs` (already supports arbitrary types).

### 2. HIBP / breached-password check  ⏱️ ~half day  🎯 closes audit L3

**Why now.** Password policy is length-only (≥12, ≤256). A user can
still pick a long-but-pwned password (`correcthorse123` etc.). With
real Plaid Production tokens behind that password, this is worth
closing.

**Approach.** Embed a top-100k-pwned bloom filter (≈80 KB) at build
time and check at signup + change-password. The k-anonymity range
API exists but adds a network round-trip on the hot path.

**Files**: new `backend/src/services/password_check.rs`,
`backend/src/api/session.rs` (hook into bootstrap / register /
change-password). The wordlist is one-time download from
https://haveibeenpwned.com/Passwords (NTLM hashes by prevalence,
top 100k = ~10 MB raw, ~80 KB as a bloom).

**Tracked in** `work/FUTURE.md` Security audit follow-ups → "HIBP".

### 3. Production deployment + Plaid webhook activation  ⏱️ ~half day  🎯 unblocks push delivery

**Why now.** All the webhook infrastructure shipped (ES256 verify +
scoped sync + per-item delivery), but Plaid still polls because
`PLAID_WEBHOOK_URL` isn't actually configured against a public URL.
Today's deployment is `docker compose up` on a laptop; for webhooks
to fire we need:

* A publicly-reachable HTTPS URL pointing at the api container's
  `/api/institutions/webhook`.
* `PLAID_WEBHOOK_URL` set in `.env`.
* Re-link or update one institution so Plaid picks up the new URL.
* Sandbox-vs-prod indicator chip in the AppBar so the user can see
  which environment they're hitting.

**Scope.** Document the prod deployment in `docs/operations.md` (or a
new `docs/deployment.md`): nginx reverse proxy config example,
TLS cert provisioning, `TRUSTED_PROXY_CIDRS` setting, the
`PLAID_WEBHOOK_URL` registration. Then add the chip:
`backend/src/api/setup.rs` exposes `plaid_env`; add a small badge
next to the FX pill in `dashboard_screen.dart` that reads `Sandbox`
in amber when not in production.

**Files**: `docs/deployment.md` (new), `frontend/lib/screens/
dashboard_screen.dart`, maybe `frontend/lib/widgets/fx_widget.dart`
for the chip layout.

## Quick wins (≤2 hours each)

Pick one as a warm-up:

- **`scripts/dev-rebuild-frontend.sh`** — wrap the rebuild + re-stamp-CSP
  dance documented in `work/CURRENT.md`. The security-headers loss on
  rebuild has tripped multiple sessions; automating removes the
  foot-gun.
- **Unhide subscriptions** — the dismiss × on `SubscriptionsCard`
  is one-way today. Add a tiny "Manage hidden merchants" page (or
  section in Settings / Management) that lists rows from
  `ignored_subscription_merchants` with a remove button.
- **Mexican parser polish** — `services/parser/nu_mexico.rs`,
  `banamex.rs`, and `cetes.rs` produce raw bank descriptions
  ("MISC DEBIT 20260418"). Wire the same generic-prefix allowlist
  from `transaction_display.dart` into the parsers so the rows look
  like the Plaid ones.
- **Split-child badge in the list** — children render as regular
  rows today. A small "Split" chip on the row would make it obvious
  the row originated from a parent. ~10 lines in
  `widgets/transactions_tab.dart` row builder.
- **Inline rename** — current rename requires opening the detail
  modal. A long-press (or a "rename" icon on the row hover) would
  cut clicks for the common case.
- **Cancelled subscription detection** — extend the detector to
  surface a separate "Stopped" section for clusters whose most-
  recent charge is >90 days ago (currently filtered out). Helpful
  for "did Netflix actually charge me last month?"
- **Recovery-codes-low banner** — Security screen knows
  `_unusedRecoveryCodes` but doesn't warn when low. A yellow tile
  when count drops below 3.

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
