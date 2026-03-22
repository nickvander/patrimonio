# Phase 1: Foundation (Current)

**Goal:** Scaffold the project, set up backend + frontend + database, get a running dev environment.

## Deliverables
- [x] Git repo initialized
- [x] Project structure created
- [x] `work/` directory with specs and decision tracking
- [x] Rust backend scaffold (axum, health endpoint)
- [x] PostgreSQL schema + migrations (sqlx)
- [x] Redis connection setup
- [x] Flutter frontend scaffold (web + desktop targets)
- [x] Docker Compose (backend + postgres + redis)
- [x] Basic API endpoints: health, config
- [x] Exchange rate service (fetch + cache)
- [x] README with setup instructions

## Architecture Decisions Made
- See [DECISIONS.md](../DECISIONS.md)

## Success Criteria
- `docker-compose up` starts all services
- `curl http://localhost:8080/api/health` returns OK
- Flutter web app loads at `http://localhost:3000`
- Exchange rate endpoint returns current USD/MXN rate

## Notes
- No auth needed yet (single-user, self-hosted)
- Focus on getting the data pipeline right, UI can be basic
