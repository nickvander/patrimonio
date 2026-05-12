# Deployment & Infrastructure

Patrimonio is designed to run locally with Docker Compose and to deploy as a static Flutter web frontend plus a stateless Rust API.

## Local Development

### Prerequisites

- Docker and Docker Compose
- Optional Plaid credentials for US account linking
- Optional Coinbase and Bitso credentials for crypto sync
- Optional ExchangeRate-API key for live FX data
- `ENCRYPTION_KEY` configured in `.env` before storing integration tokens or API secrets

For real Plaid users, also configure the Plaid dashboard environment, product access, and deployed HTTPS redirect/webhook URLs. Sandbox credentials are enough for local test data only.

### Start the Stack

```bash
cp .env.example .env
docker compose up --build -d
```

This starts:

| Service | Container role | Host URL/port |
|---------|----------------|---------------|
| Frontend | Flutter web build served by nginx | `http://127.0.0.1:3000` |
| API | Rust/Axum server | `http://127.0.0.1:8080` |
| PostgreSQL | Primary database | `127.0.0.1:5433` |
| Redis | Cache for FX and short-lived data | `127.0.0.1:6380` |

The non-default Postgres and Redis host ports reduce conflicts with other local services.

### Common Commands

```bash
docker compose ps
docker compose logs -f api
docker compose up --build -d frontend
docker compose down
```

### Smoke Test

```bash
NODE_PATH=/path/to/node_modules ./scripts/smoke.cjs
```

The smoke test checks API health and uses Playwright to confirm the Flutter app renders in a browser. Use `SKIP_BROWSER=1 ./scripts/smoke.cjs` when browser dependencies are unavailable and API-only validation is enough.

### Setup Status

The API exposes `GET /api/setup/status` for launch readiness checks. The Management tab uses it to show whether Plaid credentials and `ENCRYPTION_KEY` are configured before enabling real account linking.

## Production Shape

A production deployment should keep the same service boundaries:

- **Frontend**: Flutter web build hosted by Firebase Hosting, Cloud Storage/CDN, or any static container host.
- **API**: Rust container on Cloud Run or another stateless container platform.
- **Database**: Managed PostgreSQL such as Cloud SQL.
- **Cache**: Managed Redis such as Memorystore.
- **Secrets**: Store Plaid, Coinbase, Bitso, FX, and encryption settings in the platform secret manager.
- **Backups**: Enable scheduled database backups before connecting real financial data.

## Continuous Integration

Recommended CI checks:

1. `cargo test` for backend logic.
2. `flutter analyze` and `flutter build web` for frontend health.
3. `docker compose build` to catch container packaging issues.
4. `mkdocs build` for documentation.
5. `scripts/smoke.cjs` in an environment with browser dependencies.

### Documentation Build

```bash
pip install mkdocs-material
mkdocs serve
```
