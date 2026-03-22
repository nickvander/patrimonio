# Phase 1: Foundation (Current)

**Goal:** Scaffold the project, set up backend + frontend + database, get a running dev environment.

## Deliverables
- [x] Git repo initialized
- [x] Project structure created
- [x] `work/` directory with specs and decision tracking
- [ ] Rust backend scaffold (axum, health endpoint)
- [ ] PostgreSQL schema + migrations (sqlx)
- [ ] Redis connection setup
- [ ] Flutter frontend scaffold (web + desktop targets)
- [ ] Docker Compose (backend + postgres + redis)
- [ ] Basic API endpoints: health, config
- [ ] Exchange rate service (fetch + cache)
- [ ] README with setup instructions

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
