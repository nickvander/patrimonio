# Next session — handoff

> **Last updated:** 2026-05-18
> **Purpose:** Pickup-ready priorities for the next agent. Each item
> has a why, scope sketch, and where to look in code. Ordered by
> impact-per-effort.

`work/FUTURE.md` has the full backlog with detailed plans. This file
is the "what to actually do next" filter — top three by impact +
small wins.

## Top 3

### 1. Backups + restore runbook  ⏱️ ~half day  🎯 highest operational risk

**Why now.** The system holds real encrypted bank credentials
(`plaid_access_token_enc`, `api_secret_enc`, `totp_secret_enc`) only
on the local Postgres Docker volume. One `docker volume prune`, one
disk failure, one container recreate-by-mistake and they're gone —
along with every transaction, every lot, every account row. The MVP
just needs:

- `scripts/backup.sh` — `pg_dump` + `gpg --encrypt` to a target dir.
- `scripts/restore.sh` — the reverse.
- Daily cron entry documented (host crontab, not in-container).
- `docs/operations.md` — restore drill steps + how to rotate
  `ENCRYPTION_KEY` (re-encrypts every `*_enc` column).
- Run the drill once: build a fresh stack from a backup, verify
  Plaid sync still works against restored data, verify a login.

**Tracked in** `work/FUTURE.md` item 7. **Files**: new
`scripts/backup.sh`, `scripts/restore.sh`, `docs/operations.md`.

### 2. "What changed since last login" diff banner  ⏱️ ~half day  🎯 high return-visit value

**Why now.** `users.last_login_at` and `balance_snapshots` already
exist. The numbers needed to answer "what's new since you were last
here" are sitting in the DB; we just don't surface them. Cheap
shipment, immediately useful.

**Scope**: new `GET /api/dashboard/since-last-login` returning
`{ new_transactions, largest_balance_move, sync_errors[] }`. Frontend
banner above NetWorthCard on Overview, dismissible (state in
Preferences so it stays dismissed for that login).

**Tracked in** `work/FUTURE.md` item 3. **Files**: new endpoint in
`backend/src/api/dashboard.rs`; new widget under
`frontend/lib/widgets/`.

### 3. Cross-currency cash-transfer linking (Wise → Nu, etc.)  ⏱️ ~1 day  🎯 closes the multi-currency story

**Why now.** Investment lots ship cleanly with FX-aware cost basis.
The remaining bi-national gap is cash movements between currencies —
when the user does US bank → Wise → Nu Bank, the two `transactions`
rows are unlinked and the implicit Wise FX rate is lost. Without
this, the "MXN cash on hand" view is missing its provenance.

**Scope**: auto-detect USD-out + MXN-in pairs within a short
window when amounts back-out to a plausible FX rate and the
description contains a remittance keyword. New `cash_fx_transfers`
table. Surface the link + implied rate in the transaction detail
modal + cash-flow tab.

**Tracked in** `work/FUTURE.md` item 2b. The doc has the full plan
including out-of-scope clarification ("realized FX gain on held MXN
cash" is deliberately deferred — too hard to model right without
real user demand).

## Quick wins (≤2 hours each)

Pick one of these as a warm-up if energy is low:

- **`scripts/dev-rebuild-frontend.sh`** that wraps the rebuild +
  re-stamp-CSP dance documented in `work/CURRENT.md`. The CSP loss
  on rebuild has tripped us multiple sessions — automating it
  removes the foot-gun.
- **Render the dual-currency P&L panel data on `portfolio_card.dart`
  beyond the tile summary** — per-holding rows currently show only
  native-currency P&L. The backend already returns
  `gain_loss_usd` / `gain_loss_mxn` per row; the card just isn't
  reading them.
- **Recovery-codes-low banner**. Security screen shows
  `_unusedRecoveryCodes` count but doesn't warn when low. Add a
  yellow tile when count drops below 3.
- **`work/NEXT.md` and `work/CURRENT.md` refresh** — already current
  as of this commit, but they go stale fast. Pencil in a 5-min
  pass at the END of each session as part of the wrap-up.
- **`app_settings` user_id column** (M7 leftover). Currently this
  table is global, which means budgets/goals would leak across users
  once a second invite is redeemed. Single migration + a few query
  updates. Tracked in `work/FUTURE.md` Security audit follow-ups.
- **Drag-and-drop on the import screen + multi-select polish**
  (FUTURE.md 3b). The drop zone is a visual lie today — it looks
  droppable but has no handler. `allowMultiple: true` is already
  passed to the file picker but the "Select file" (singular) label
  and the lack of helper text don't communicate it. Add
  `desktop_drop` (or hand-roll via `package:web`), rename button to
  "Select files", add a hover state on drag. ~2 hours.

## Deferred — explicitly NOT next

- **Real-estate / manual assets** (FUTURE.md item 4) — useful for
  affluent users but not blocking. Pick up when a user actually asks.
- **FIDO2 cross-device flow polish** — passkeys work; cross-device QR
  is browser-handled and probably fine. Wait for a real complaint.
- **`work/NEXT.md` (this file) restructuring into multiple files** —
  there's a temptation to make it phases / categories / etc.
  Resist. The point of this file is "what to do next session" and
  it should fit on one screen.

## How to pick up cold

1. Read `work/CURRENT.md` (you're here, this file is below it).
2. Read this file (`work/NEXT.md`) — top 3 items above.
3. If picking item 1, 2, or 3: open the linked `work/FUTURE.md`
   section for the full plan.
4. Verify the stack is up: `cd ~/patrimonio && docker compose ps`
   should show api, frontend, postgres (healthy), redis all Up.
5. Verify auth: `curl http://127.0.0.1:8080/api/health` →
   `{"status":"ok","database":"connected"}`.
6. Ship + commit + push.
