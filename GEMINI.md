# Patrimonio — Agent Guide

> This file helps AI coding agents understand the project quickly.

## Project Summary
Cross-platform personal finance tracker (US + Mexico). Tracks accounts across 14+ institutions with real-time USD/MXN exchange rates.

## Tech Stack
- **Backend:** Rust + axum (in `backend/`)
- **Frontend:** Flutter/Dart (in `frontend/`)
- **Database:** PostgreSQL 17 (via Docker)
- **Cache:** Redis 7 (via Docker)
- **Containerization:** Docker Compose

## Quick Reference

### Prerequisites
- Docker (for DB, Redis, and running the backend)
- Rust toolchain (for backend development)
- Flutter SDK (for frontend development - e.g., `sudo snap install flutter --classic`)

### Running the project
```bash
cd ~/patrimonio
docker compose up -d                    # Start everything
docker compose up --build -d api        # Rebuild after backend changes
docker compose logs -f api              # Watch logs
docker compose down                     # Stop everything
```

### API base URL
`http://localhost:8080/api`

### Key endpoints
| Method | Path | Purpose |
|--------|------|---------|
| GET | `/api/health` | Health check |
| GET | `/api/accounts` | List all accounts |
| GET | `/api/accounts/summary` | Net worth summary |
| GET | `/api/institutions` | List institutions |
| POST | `/api/institutions` | Add institution |
| GET | `/api/fx/latest/{base}/{target}` | Exchange rate |
| GET | `/api/dashboard/overview` | Dashboard data |

### Database
- **Connection:** `postgres://patrimonio:patrimonio@localhost:5432/patrimonio`
- **Migrations:** `backend/migrations/` (run automatically on startup via `sqlx::migrate!`)
- **Schema:** 6 tables — `institutions`, `accounts`, `balance_snapshots`, `holdings`, `exchange_rates`, `transactions`

### Project tracking
- `work/CURRENT.md` — **Start here.** Shows current phase, what's done, what's next
- `work/OVERVIEW.md` — Project vision, institutions, tech stack
- `work/DECISIONS.md` — Architectural decision log (append new decisions here)
- `work/phases/PHASE-{N}-*.md` — Detailed specs for each phase

## Code Conventions

### Backend (Rust)
- Use `sqlx::query()` runtime queries (not `query!` macros) — Docker builds have no DB connection
- API handlers go in `backend/src/api/`
- Models in `backend/src/models/` derive `FromRow` and `Serialize`
- Business logic in `backend/src/services/`
- Config from env vars via `backend/src/config.rs`
- Use `tracing::info!` / `tracing::debug!` for logging

### Adding a new API endpoint
1. Add handler function in the relevant `api/*.rs` file
2. Register route in that file's `router()` function
3. Rebuild: `docker compose up --build -d api`

### Adding a new database table
1. Create migration in `backend/migrations/` with timestamp prefix
2. Add model struct in `backend/src/models/`
3. The migration runs automatically on next startup

## Important Notes
- **No auth** — single-user, self-hosted mode
- **sqlx offline mode** — `SQLX_OFFLINE=true` in Docker, so never use `query!` macros
- **Git commits** — use conventional commits (`feat:`, `fix:`, `docs:`, etc.)
- **Sensitive data** — Plaid tokens encrypted, never commit `.env`
