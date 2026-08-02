# Handoff — start here

> **Last updated:** 2026-08-02 (transactions drill-down/claim-banner batch + menu chrome)
> **Purpose:** The one-screen "where are we, what's next" doc to pick up cold.
> Detail lives in [work/CURRENT.md](CURRENT.md) — this file deliberately stays short.

## TL;DR — current state

**As of 2026-08-02:** `main` @ `38df064`, tree clean, pushed. **Prod runs on
the homelab host `thelab`** (`ssh nickvander@thelab`; docker compose stack at
`/mnt/data/docker/stacks/patrimonio`, api on `:8085`) — deployed through
`4f29a8b` (2026-07-31 notification-reconciliation + visit-anchor batch), which
is also the latest APK cut. Everything after it (`9add804`…`38df064`: the
2026-08-01/02 transactions totals/drill-downs/restyle work + the
formatter-sweep CI gates) is on `main` and pushed but **not yet recorded as
deployed** — check thelab before assuming.

**Dev on this VM is native (no docker):** Postgres `:5442` + Redis `:6380`
with data dirs inside the repo, cargo + `~/flutter` toolchains. All run/test/
build commands live in the repo-root [AGENTS.md](../AGENTS.md) (and the
`.agent/skills/dev-workflow/` skill) — don't duplicate them here.

## Shipped recently (newest first — detail in CURRENT.md)

- **2026-08-02:** `ConnectedSegments` cash-flow period selector + centralized
  menu chrome (`theme/menus.dart`); drill-downs carry their claim + programmatic
  Transactions-tab jumps reset to a fresh context (DEC-026); add-transaction
  sheet/dialog consistency sweep; since-visit drill-downs filter by sync time;
  stable `X-Total-Count` filtered totals (DEC-025) + Filter & sort restyle.
- **2026-08-01:** spike/price-hike bell rows drill into filtered transactions;
  insight sheet + comparison banner + account-scoped moves; both trees made
  formatter-clean and gated in CI (`.git-blame-ignore-revs`).
- **2026-07-30/31:** condition-backed notifications retire themselves
  (DEC-023); "since your last visit" anchors on visits, not logins (DEC-024);
  phone chart range selector fills its row. Deployed + APK cut (`4f29a8b`).
- **2026-07-26/27:** seven-bug audit batch, stuck-`syncing` reaper, year-panic
  guard, `CatchPanicLayer`, resilient dashboard reload + WS heartbeat.

## Read next

- [work/CURRENT.md](CURRENT.md) — the detailed reverse-chronological log
  (pre-July entries archived in `work/archive/`).
- [work/NEXT.md](NEXT.md) — pickup-ready priorities; [work/FUTURE.md](FUTURE.md)
  — the full backlog with per-item plans.
- [work/DECISIONS.md](DECISIONS.md) — architecture decision records (DEC-001…026).

## How to verify / ship

- Run/test commands: [AGENTS.md](../AGENTS.md) ("Running locally" / "Testing").
  `scripts/test.sh` and `scripts/dev-up.sh` are docker-only (CI / thelab) —
  on this VM run cargo/flutter natively.
- Prod deploy + APK: `docs/deployment.md` (compose stack: nginx-served Flutter
  web + api + Postgres 17 + Redis 7) and `docs/migration.md` for the runbook
  that moved prod to thelab.
- Direct-push to `main` is gated; do the local `git merge --ff-only` +
  `git push origin main` (the user authorizes pushes).
