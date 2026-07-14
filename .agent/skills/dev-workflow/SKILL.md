---
name: dev-workflow
description: How to run, build, and test the Patrimonio development environment
---

# Dev Workflow

**Docker is NOT available on this dev VM.** Postgres and Redis run natively with
data dirs inside the repo (`pgdata/`, `redisdata/` — gitignored), and the backend
is a native cargo binary. `docker compose` / `scripts/dev-up.sh` are the **prod**
path (homelab host `thelab`) — don't reach for them here. `backend/.env` expects
Postgres on **5442** and Redis on **6380**.

## Starting the environment

// turbo
1. Postgres (userspace, no root):
   `/home/nickvander/pgenv/bin/pg_ctl -D ~/dev/patrimonio/pgdata -o "-p 5442 -k /tmp/pgsock -c listen_addresses=127.0.0.1" -l ~/dev/patrimonio/pgdata/pg.log start`
// turbo
2. Redis:
   `redis-server --port 6380 --requirepass patrimonio_dev --daemonize yes --dir ~/dev/patrimonio/redisdata --logfile ~/dev/patrimonio/redisdata/redis.log --save ""`
3. Backend (migrations auto-run on boot; listens on **:8080**):
   `cd ~/dev/patrimonio/backend && source ~/.cargo/env && cargo build && RUST_LOG=warn ./target/debug/patrimonio`
   — run it in the background; stop it with `pkill -x patrimonio`.
// turbo
4. Verify: `curl -s http://localhost:8080/api/health`

## Rebuilding after backend changes

// turbo
1. `cd ~/dev/patrimonio/backend && cargo build`
2. `pkill -x patrimonio`, then relaunch `./target/debug/patrimonio` (step 3 above).

## Frontend (web)

Flutter is at `~/flutter/bin/flutter`. For development: `cd ~/dev/patrimonio/frontend
&& ~/flutter/bin/flutter run`.

**The web app is same-origin only:** it derives its API base from
`window.location` + `/api` (`api_platform_web.dart`) — `--dart-define=API_BASE_URL`
affects **native** builds only. Serving `flutter build web` output from a bare
static file server gives a UI whose API calls all fail; a served web build needs
an nginx-style same-origin `/api` proxy (that's how prod works).

The web build takes ~50 s and prints nothing until the end — it isn't frozen.

## Building the Android APK

The frontend also builds a native **Android APK** (same codebase; web-only code
is behind conditional-import seams — see the flutter-frontend skill §8). The
Android SDK is at `~/android-sdk` (`ANDROID_HOME`).

// turbo
1. Build: `cd ~/dev/patrimonio/frontend && ~/flutter/bin/flutter build apk --release`
   - Output: `build/app/outputs/flutter-apk/app-release.apk` (universal, ~70 MB —
     the emulator/CI build). For phone installs add `--split-per-abi` →
     `app-arm64-v8a-release.apk` (~25 MB).
   - Release signing reads `frontend/android/key.properties` (gitignored, points
     at the gitignored keystore under `android/keystore/`). If absent (fresh
     clone / CI) the build falls back to debug signing so it still succeeds.
     **Back up the keystore + `key.properties`; losing them means you can't
     update an installed app.**
2. Bake in a default backend URL (optional):
   `--dart-define=API_BASE_URL=https://patrimonio.nickvda.com`. Otherwise the app
   asks for the backend URL on first launch (Settings screen) and remembers it.
3. Install: sideload the APK. The app is **HTTPS-only** (network security
   config); the backend must be reachable over TLS.

**A green `flutter build apk` is not proof the app launches** — R8 can strip
reflectively-instantiated classes and the APK crashes at startup (it happened:
Room's `WorkDatabase_Impl`; keep rules live in
`frontend/android/app/proguard-rules.pro`). After any change to Android deps,
`build.gradle.kts`, or `proguard-rules.pro`, run the **emulator smoke test** —
full commands (headless AVD "pixel" via `sg kvm`, install, launch, assert the
process survives) are in the repo-root `AGENTS.md` "Android APK" section.

Verify a change compiles for **both** targets before calling it done —
`flutter build web` and `flutter build apk`. A stray `package:web` import breaks
only the APK, and `flutter analyze` won't catch it.

## Testing

```bash
# Backend: needs a SEPARATE test DB — the harness TRUNCATEs it
cd ~/dev/patrimonio/backend && \
  PATRIMONIO_TEST_DATABASE_URL="postgres://patrimonio:patrimonio_dev@127.0.0.1:5442/patrimonio_test" \
  PATRIMONIO_TEST_REDIS_URL="redis://:patrimonio_dev@127.0.0.1:6380" cargo test
cargo clippy --all-targets -- -D warnings   # lint gate (must stay clean)

# Frontend
cd ~/dev/patrimonio/frontend && ~/flutter/bin/flutter analyze && ~/flutter/bin/flutter test
```

The integration harness **panics** on a configured-but-unreachable test DB/Redis
(it does not silently skip) — keep Postgres/Redis up.

## Database access

// turbo
1. `psql "postgres://patrimonio:patrimonio_dev@127.0.0.1:5442/patrimonio"`
2. Useful queries:
   - List tables: `\dt`
   - Check accounts: `SELECT * FROM accounts;`
   - Check exchange rates: `SELECT * FROM exchange_rates ORDER BY recorded_at DESC LIMIT 5;`

## Stopping the environment

1. Backend: `pkill -x patrimonio`
2. Postgres: `/home/nickvander/pgenv/bin/pg_ctl -D ~/dev/patrimonio/pgdata stop`
3. Redis: `redis-cli -p 6380 -a patrimonio_dev shutdown`
