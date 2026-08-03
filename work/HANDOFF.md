# Handoff — start here

> **Last updated:** 2026-08-03 (sweep deferred-items batch; push/deploy pending)
> **Purpose:** The one-screen "where are we, what's next" doc to pick up cold.
> Detail lives in [work/CURRENT.md](CURRENT.md) — this file deliberately stays short.

## TL;DR — current state

**As of 2026-08-03:** `main` @ `0d1d6e3` local, tree clean — the sweep
deferred-items batch (6 commits, `e4a109c`…`0d1d6e3`) is **committed but NOT
pushed** (push awaiting owner go-ahead; deploy follows it). **Prod runs on
the homelab host `thelab`** (`ssh nickvander@thelab`; docker compose stack at
`/mnt/data/docker/stacks/patrimonio`, api on `:8085`) — still **deployed
through `842de84`**. An APK is cut from `0d1d6e3`
(`app-arm64-v8a-release.apk`, 28.1MB; no Android dep/Gradle/proguard changes
in the batch, so the emulator smoke gate wasn't triggered). To ship: push
`main`, run the flock'd `update.sh` on thelab, verify api health 200.

**Dev on this VM is native (no docker):** Postgres `:5442` + Redis `:6380`
with data dirs inside the repo, cargo + `~/flutter` toolchains. All run/test/
build commands live in the repo-root [AGENTS.md](../AGENTS.md) (and the
`.agent/skills/dev-workflow/` skill) — don't duplicate them here.

## Shipped recently (newest first — detail in CURRENT.md)

- **2026-08-03 (deferred-items batch):** loans money pipeline f64→Decimal
  end-to-end (wire proven identical: loan suites untouched + live Lending
  walkthrough incl. writes); lending_tab 5,427→1,023 / portfolio_card
  4,359→2,141 / transactions_tab honest small yield (detail panel is
  state-coupled by design); ApiService http.Client test seam + 17 plumbing
  tests (969 frontend tests); account_balance_chart onto standardLineTouch,
  frozen convention exception removed. Final gates 558/558 + 969/969.
- **2026-08-02 (night):** multi-agent quality sweep — backend tests 527→558
  (invites/imports/FX/TWR/encryption + sqlx-macro ban), frontend 912→952
  (l10n order invariants, convention tests, bell a11y); depository/Cash-tile
  bug fixed; `api/error.rs`+`middleware.rs`+`services/fx.rs` extracted;
  `api/dashboard.rs` split into 12 modules; 37 handlers → ApiError envelope;
  agent infra (`.agent/agents/`, quality-sweep workflow, walkthrough rig).
  Deployed to thelab + APK cut.
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
