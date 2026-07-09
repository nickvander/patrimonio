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
# Frontend
cd frontend && ~/flutter/bin/flutter run   # or: flutter build web
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

## Enforcement (the checkable rules run automatically)

The skills are guidance; their machine-checkable subset is enforced so nothing
regresses silently:

- **CI** (`.github/workflows/test.yml`) runs on every push/PR: `cargo clippy
  --all-targets -- -D warnings`, `flutter analyze`, and both full test suites.
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
