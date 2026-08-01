# Patrimonio — Agent Guide

> Canonical instructions for AI coding agents (Claude Code, Gemini, and any tool
> that reads `AGENTS.md`). `CLAUDE.md` and `GEMINI.md` point here so there's one
> source of truth.

Cross-platform personal finance tracker (US + Mexico): accounts across 14+
institutions, real-time USD/MXN FX, portfolio/holdings, loans, tax (FBAR / MX),
FIRE projections. Backend **Rust + axum**, frontend **Flutter/Dart**, **Postgres
17** + **Redis 7**.

## ⇒ Skills: read the relevant one before you code

Detailed, enforced conventions live in **`.agent/skills/`** (a directory of
`SKILL.md` guides, shared across agent tools; Claude Code also discovers them via
the `.claude/skills` symlink). **Before writing or reviewing code in an area,
read its skill** — each is grounded in this codebase's real patterns and the bug
classes it has actually hit, and ends with a "Definition of done" checklist:

- **`rust-backend/`** — axum/sqlx/Redis backend: the `ApiError` envelope +
  `internal()` for 500s, runtime sqlx binds only, `balance_snapshots`
  carry-forward (never per-date GROUP BY), per-row FX→USD before summing money,
  every query scoped `WHERE user_id = $1`, loud test-skip. Companion
  `rust-conventions.md` (Fuchsia rubric + Rust API Guidelines + clippy).
- **`flutter-frontend/`** — Flutter (M3, en + es-MX): the **gen-l10n
  placeholder-alphabetization trap** (call sites must pass args in
  alphabetical-name order), locale-aware money/percent helpers, the `context`
  color extension, responsive off the inner `LayoutBuilder`. Companion
  `dart-flutter-conventions.md` (Effective Dart + Flutter style guide + lints).
- **`backend-dev/`**, **`dev-workflow/`**, **`work-tracking/`** — how to add
  endpoints/tables/services, run the stack, and track project progress.

If a checkable rule matters, it's also enforced (see "Enforcement" below) — but
the skills are the human/agent-readable source.

## Tech stack

- **Backend:** Rust + axum (`backend/`) — sqlx (Postgres), Redis, rust_decimal.
- **Frontend:** Flutter/Dart (`frontend/`) — Material 3, fl_chart, intl/gen-l10n.
- **Data:** PostgreSQL 17, Redis 7. Auth: sessions + passkeys (WebAuthn), Argon2.

## Running locally

**Docker is not available on the dev VM**, so Postgres/Redis run natively.
`backend/.env` expects Postgres on **5442** and Redis on **6380**:

```bash
# Postgres (userspace, no root)
/home/nickvander/pgenv/bin/pg_ctl -D ~/dev/patrimonio/pgdata \
  -o "-p 5442 -k /tmp/pgsock -c listen_addresses=127.0.0.1" \
  -l ~/dev/patrimonio/pgdata/pg.log start
# Redis
redis-server --port 6380 --requirepass patrimonio_dev --daemonize yes \
  --dir ~/dev/patrimonio/redisdata --logfile ~/dev/patrimonio/redisdata/redis.log --save ""
# Backend (migrations auto-run on boot; listens on :8080)
cd backend && source ~/.cargo/env && cargo build && RUST_LOG=warn ./target/debug/patrimonio
# Frontend (web)
cd frontend && ~/flutter/bin/flutter run   # or: flutter build web
# Frontend (Android APK — same codebase; web-only code is behind platform seams)
cd frontend && ~/flutter/bin/flutter build apk --release   # → build/app/outputs/flutter-apk/app-release.apk (universal, ~70 MB)
# Phone installs: add --split-per-abi → app-arm64-v8a-release.apk (~25 MB).
# The universal APK stays the emulator (x86_64) + CI build.
```

Data dirs (`pgdata/`, `redisdata/`) live inside the project and are gitignored —
never create service data dirs in `$HOME`. Where docker-compose is the documented
path, run the services natively instead.

## Testing

```bash
# Backend: unit + integration (needs a SEPARATE test DB — it TRUNCATEs)
cd backend && PATRIMONIO_TEST_DATABASE_URL="postgres://patrimonio:patrimonio_dev@127.0.0.1:5442/patrimonio_test" \
  PATRIMONIO_TEST_REDIS_URL="redis://:patrimonio_dev@127.0.0.1:6380" cargo test
cargo clippy --all-targets -- -D warnings      # lint gate (must stay clean)

# Frontend
cd frontend && ~/flutter/bin/flutter analyze && ~/flutter/bin/flutter test
```

The integration harness **panics** on a configured-but-unreachable test DB/Redis
(it no longer silently skips) — keep Postgres/Redis up.

### Android APK — build + launch smoke test

`analyze`/`test` run on the Dart VM and **never exercise the Android build or a
real device**, so R8/Gradle regressions slip past them. CI now also runs
`flutter build apk --release` as a build gate — but a green build is **not**
proof the app launches: R8 minification can strip reflectively-instantiated
classes and the APK crashes instantly at startup (this happened once —
`plaid_flutter` pulls in WorkManager, and R8 stripped Room's generated
`WorkDatabase_Impl` no-arg constructor → `NoSuchMethodException` at launch; fixed
by keep rules in `frontend/android/app/proguard-rules.pro`). **After any change
to Android deps, `build.gradle.kts`, or `proguard-rules.pro`, smoke-test the
release APK on an emulator** — a build alone won't catch launch crashes:

```bash
export ANDROID_HOME=$HOME/android-sdk
ADB=$ANDROID_HOME/platform-tools/adb
# Headless AVD on this GUI-less VM: needs the `sg kvm` wrapper (plain -no-accel
# segfaults; the user is in the kvm group). AVD name is "pixel".
sg kvm -c "env LD_LIBRARY_PATH=$ANDROID_HOME/emulator/lib64/qt/lib:$HOME/.local/chromium-libs/lib \
  $ANDROID_HOME/emulator/emulator -avd pixel -no-window -no-audio -no-boot-anim \
  -gpu swiftshader_indirect -no-snapshot -memory 2048 &"
# Wait for boot, install, launch, then assert the process is still alive:
$ADB wait-for-device
cd frontend && ~/flutter/bin/flutter build apk --release
$ADB install -r build/app/outputs/flutter-apk/app-release.apk
$ADB logcat -c && $ADB shell am start -n com.patrimonio.patrimonio/.MainActivity && sleep 8
$ADB shell pidof com.patrimonio.patrimonio || echo "CRASHED — check: $ADB logcat -b crash -d"
```

(Emulator SystemUI throws spurious "System UI isn't responding" ANRs under
swiftshader — that's the emulator's own UI, not the app.)

## Enforcement (the checkable rules run automatically)

The skills are guidance; their machine-checkable subset is enforced so nothing
regresses silently:

- **CI** (`.github/workflows/test.yml`) runs on every push/PR: `cargo fmt
  --check`, `cargo clippy --all-targets -- -D warnings`, `dart format
  --set-exit-if-changed`, `flutter analyze`, both full test suites, and
  `flutter build apk --release` (Android build gate — catches R8/Gradle breakage;
  launch crashes still need the emulator smoke test in Testing above).
- **Both trees are formatter-clean and gated**, so `cargo fmt` / `dart format`
  are safe to run on a file you're editing and format-on-save won't bury your
  change in reflow. Neither was, until the sweeps: the Dart tree reformatted 197
  of 252 files (a ~70-line chart fix produced an 828-line diff), the Rust tree 79
  of 97. Both sweep commits are listed in `.git-blame-ignore-revs`; run `git
  config blame.ignoreRevsFile .git-blame-ignore-revs` once per clone so `git
  blame` looks through them.
- **Frontend analyzer:** `cancel_subscriptions` / `close_sinks` are promoted to
  build-breaking **errors** (undisposed stream/sink fails the build).
- **Regression tests** pin the specific bugs we've fixed (l10n transpositions,
  cross-currency sums, DoS clamps, FX conversion).

## Conventions (quick pointers — details in the skills)

- **Backend:** runtime `sqlx::query()` only (no `query!` macros — Docker/offline
  builds have no DB). Handlers return `Result<_, ApiError>`; 500s via `internal()`.
  Money is `rust_decimal::Decimal`. Additive-only migrations in
  `backend/migrations/` (auto-run on boot). Conventional-commit messages.
- **Frontend:** never hand-roll money/percent strings (use `utils/currency.dart`
  / `utils/percent_format.dart`) or hardcode colors (use the `context` extension
  in `utils/theme_colors.dart`). Add l10n strings to BOTH `app_en.arb` and
  `app_es.arb`, matching the **alphabetical** generated signature.
- **Secrets:** Plaid tokens are AES-GCM encrypted; never commit `.env`.

## Project tracking

- `work/CURRENT.md` — **start here**: current state, what's done, what's next.
- `work/OVERVIEW.md`, `work/DECISIONS.md`, `work/FUTURE.md`, `work/phases/`.
