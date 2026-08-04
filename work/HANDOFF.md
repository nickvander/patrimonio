# Handoff — start here

> **Last updated:** 2026-08-03 (feature-research batch, rules engine, and the
> calendar-detection fix shipped and deployed)
> **Purpose:** The one-screen "where are we, what's next" doc to pick up cold.
> Detail lives in [work/CURRENT.md](CURRENT.md) — this file deliberately stays short.

## TL;DR — current state

**As of 2026-08-04:** `main` @ `e29459e`, pushed. **Prod runs on the homelab
host `thelab`** (`ssh nickvander@thelab`; docker compose stack at
`/mnt/data/docker/stacks/patrimonio`, api on `:8085`) — **deployed through
`b7a0bfc`** via the host's own `update.sh` (the same script its 3am cron
runs: `git pull` + `docker compose up -d --build`). Verified after: api
health 200, frontend 200, no errors in the api log, migration
`2026080401 user rules` recorded `success=t`. Its provenance backfill was a
**no-op on prod** — prod carries 0 hand-edited categories/descriptions
across 2,520 transactions, so no existing row was rewritten. The latest APK
is cut from `b7a0bfc` (`app-arm64-v8a-release.apk`, 28.6MB; the 65-file diff
touched no Android dep/Gradle/proguard file, so the emulator smoke gate
wasn't triggered).

**Backups — the homelab already covers this; don't re-invent it.** The house
system `/mnt/data/backups/master_backup.sh` (nightly **03:00**) runs a proper
`pg_dump` of the Patrimonio database among several stacks, then pushes
everything to **Cloudflare R2 via Restic** — encrypted, offsite, retention
keep-daily 7 / keep-weekly 4. Verified healthy 2026-08-03: 9 snapshots,
763 MiB, last run 03:00:05. Status JSON:
`/mnt/data/docker/stacks/n8n/data/backup_status.json`; credentials per the
vault's secret policy live in Vaultwarden, config in
`/mnt/data/docker/.env`.

> **Correction (2026-08-03):** an earlier version of this file claimed prod
> had NO backups. That was wrong. The check only looked for the repo
> script's own artifacts (`~/patrimonio-backups`, `*.sql.gpg`, a
> patrimonio-named cron); the house system uses a different path, Restic
> (so no `.sql.gpg` exists), and deletes the local `.sql` after upload — so
> absence of those artifacts proved nothing. Before asserting a backup gap,
> check `/mnt/data/backups/`, the host crontabs, and the Obsidian vault's
> `Homelab/Operations and Policies.md`.

**Two real findings that survive the correction:**
1. **03:00 collision.** `master_backup.sh` and the Patrimonio `update.sh`
   auto-update are both on `0 3 * * *`. The update runs migrations while the
   backup is dumping; concurrent DDL can make `pg_dump` fail.
2. **Silent-empty-dump failure mode.** Each dump line in `master_backup.sh`
   ends in `|| echo "[!] … skipped"`, and the redirect has already created
   the file — so a failed dump uploads an EMPTY `postgres_patrimonio.sql`,
   while `backup_status.json` still reports "healthy" (it only counts restic
   snapshots, never checks dump contents).

**Both findings fixed 2026-08-03 (owner-approved):**
* The Patrimonio auto-update moved to **04:00**, so the 03:00 master backup
  finishes first and is a clean pre-migration snapshot.
* `master_backup.sh` hardened: a `dump_db` helper dumps to `.partial`,
  requires non-empty output AND pg_dump's completion marker, and only then
  moves it into place; failures are collected and the script now **exits 1**
  (after the status JSON refresh) instead of shipping an empty file quietly.
  Original saved as `master_backup.sh.bak-20260803`. Verified: helper
  failure paths exercised in a temp dir (2 failures recorded, 1 success, no
  stray files), then a full real run — all 5 dumps `[ok]` with byte counts,
  snapshot saved to R2, exit 0.
* The redundant repo-local `scripts/backup.sh` cron added earlier that day
  was **removed** (cron, dumps, and passphrase file all deleted) — one good
  offsite system beats two half-tracked ones.

**Two pre-existing issues that run surfaced (NOT introduced by the change):**
1. `finance_tracker` dumps to **669 bytes** — effectively an empty database.
   **Owner's call 2026-08-04: "I don't think it is anything"** — treated as a
   legacy leftover, not a data-loss risk. Not flagged again. (Recorded because
   the symptom will recur on every backup inspection: it is a *valid* dump of
   nothing, so no size or exit-code check can distinguish it from a real one.)
2. ~~Restic `permission denied` on two stack paths~~ — ✅ resolved 2026-08-04.
   `adguard/workdir/data` and `ntfy/cache/attachments` are `drwx------ root`,
   and there is **no passwordless sudo on thelab**, so they cannot be chmod'd
   from an agent session. They are excluded instead — from BOTH the rsync and
   the restic call (stale root-owned copies of them linger in `local_export`
   from before the rsync exclusion and cannot be deleted without root, so
   restic had to skip them too). **Nothing of restore value is lost:**
   `adguard/confdir/AdGuardHome.yaml`, both compose files, `ntfy/etc` and
   `ntfy/cache/cache.db` are all captured; only container runtime data is
   skipped, consistent with the script's existing querylog/stats/.cache
   exclusions. Verified: a full run now logs **0** permission-denied lines and
   ends without the read warning. Originals at `master_backup.sh.bak-20260804`
   / `.bak-20260804b`.
   *If the owner ever wants that runtime data captured, it needs a real TTY:*
   `sudo chmod o+rX /mnt/data/docker/stacks/adguard/workdir/data /mnt/data/docker/stacks/ntfy/cache/attachments`
   *plus* `sudo rm -rf /mnt/data/backups/local_export/infrastructure/stacks/{adguard/workdir/data,ntfy/cache/attachments}`
   *and reverting the two exclusion lines.*

**Dev on this VM is native (no docker):** Postgres `:5442` + Redis `:6380`
with data dirs inside the repo, cargo + `~/flutter` toolchains. All run/test/
build commands live in the repo-root [AGENTS.md](../AGENTS.md) (and the
`.agent/skills/dev-workflow/` skill) — don't duplicate them here.

## Shipped recently (newest first — detail in CURRENT.md)

- **2026-08-04 closeout (`b7a0bfc`):** backlog burn-down — **FBAR
  per-account contribution was under-reporting** (exact-date snapshot lookup
  → a foreign account with no row on the peak date contributed 0; now
  carry-forward, `8076d49`); cards branch on their own width (budgets_card was
  HIDING rows, `2819d5b`); dialog decoration extracted and three dialogs
  conformed (`582051c`); the stranded recurring sheet-helper wired with a
  conventions test so it can't recur (`b7a0bfc`). Backend 666→**669**,
  frontend 1294→**1325**. NEXT.md pruned: the sitting-sized list is empty.
- **2026-08-04 (`76511d2`):** brief 6 made VISIBLE and INDEPENDENT — the
  import preview gained a statement-check panel (unavailable never looks like
  reconciled; confirm never blocked), the MX parsers now capture the bank's
  printed closing balance where a fixture proves it (santander + old Nu only,
  on purpose), and the panel says which balance it checked against so a green
  verdict can't overclaim. Plus one money glyph everywhere. Backend
  648→**666**, frontend 1251→**1294**.
- **2026-08-03 (late, `50cec87`):** research briefs 6 (guided statement
  reconciliation — classifies the gap, never blocks an import) and 7
  (quick-entry sheet, 3 taps + digits) shipped; responsive-convention pass
  (performance card + loan sheet branch on their own width — the sheet was
  actively wrong, M3 caps it at 640dp); the owner's chart-scrub complaint
  FULLY fixed by emitting the dollar valuation `compute_daily_twr` already
  computed and discarded; several label/overflow defects. Two corrections
  worth reading: a rig-reported HIGH "invisible hit region" **does not
  exist** (disproved by measurement; NEXT.md records the rig's
  false-positive mode), and `dart format --set-exit-if-changed` **rewrites
  in place** — our own instructions were clobbering concurrent agents, now
  `-o none` everywhere. Backend 620→**648**, frontend 1097→**1251**.
- **2026-08-03 (evening, `56308db`):** polish bundle (net-worth lens x-axis
  converged on date spacing, MXN chart axis notation, allocation-header
  truncation, rules apply-button copy) + the owner-reported bills-calendar
  gap: it read explicit recurring rules only, never the detector that
  IDENTIFIES charges from history (prod had 0 rules → loans only). Detector
  extracted to `services/subscription_detect.rs`; the calendar now projects
  detected clusters, marked by shape not hue, behind a default-on toggle,
  with the ignore list honored and explicit rules deduped against.
  Backend 614→**619**, frontend 1033→**1056**.
- **2026-08-03 (feature-research batch, `dc81667`):** an evidence-grounded
  feature sweep (`work/research/2026-08-03-feature-research.md`, 8 PM-vetted
  briefs + 18 rejected-with-reasons; re-runnable via `.agent/agents/` +
  `.agent/workflows/feature-research.js`) and five of its picks built:
  bilingual continuity dossier, annual transfer-cost report, net-worth change
  attribution (FX vs market vs flows + currency lens), bills calendar with
  1–90-day projected balances, and the **user rules engine** (DEC-027/028 —
  provenance columns make "manual edits win" an SQL predicate; retroactive
  apply needs a single-use fingerprinted preview token). Plus an owner-reported
  fix: chart tooltips no longer render under the finger on touch. Backend
  558→**614**, frontend 969→**1033**; live-rig verified (rules engine 7/7 with
  the safety claims checked against the DB).
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
- [work/DECISIONS.md](DECISIONS.md) — architecture decision records (DEC-001…028).

## How to verify / ship

- Run/test commands: [AGENTS.md](../AGENTS.md) ("Running locally" / "Testing").
  `scripts/test.sh` and `scripts/dev-up.sh` are docker-only (CI / thelab) —
  on this VM run cargo/flutter natively.
- Prod deploy + APK: `docs/deployment.md` (compose stack: nginx-served Flutter
  web + api + Postgres 17 + Redis 7) and `docs/migration.md` for the runbook
  that moved prod to thelab.
- Direct-push to `main` is gated; do the local `git merge --ff-only` +
  `git push origin main` (the user authorizes pushes).
