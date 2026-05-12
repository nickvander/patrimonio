# Patrimonio - Personal Finance Tracker

**Cross-platform personal finance tracker for US and Mexico accounts, investments, crypto, taxes, and USD/MXN reporting.**

[![Documentation](https://img.shields.io/badge/docs-MkDocs-blue.svg)](docs/index.md)

## Getting Started

See the [Project Overview](docs/index.md) or the [Deployment Guide](docs/deployment.md) for the full setup notes.

## Institutions Supported

### US (via Plaid API)
SoFi · Chase · American Express · Capital One · Bilt · US Bank · Fidelity · Fidelity NetBenefits · Vanguard 401k · HealthEquity HSA · Robinhood

### Crypto (direct integrations)
Coinbase · Bitso

### Mexico (via CSV/PDF upload)
Nu Bank Mexico · Banamex · Cetesdirecto

## Tech Stack

| Layer | Technology |
|-------|------------|
| Backend | Rust + axum |
| Database | PostgreSQL 17 |
| Cache | Redis 7 |
| Frontend | Flutter Web served by nginx in Docker |
| Financial Data | Plaid, Coinbase OAuth, Bitso API, CSV/PDF import |
| Exchange Rates | ExchangeRate-API with Redis caching |
| Deployment | Docker Compose locally; static hosting + API container for production |

## Quick Start

### Prerequisites
- Docker and Docker Compose
- Optional integration credentials in `.env` for Plaid, Coinbase, Bitso, and ExchangeRate-API

### Run Locally
```bash
git clone https://github.com/nickvander/patrimonio.git
cd patrimonio

cp .env.example .env
docker compose up --build -d
```

Open the app at [http://127.0.0.1:3000](http://127.0.0.1:3000).

Service URLs:
- Frontend: `http://127.0.0.1:3000`
- API: `http://127.0.0.1:8080`
- Health check: `curl http://127.0.0.1:8080/api/health`
- Postgres host port: `5433`
- Redis host port: `6380`

### Smoke Test
```bash
NODE_PATH=/path/to/node_modules ./scripts/smoke.cjs
```

The smoke test verifies API health and renders the Flutter app in a browser with Playwright. If Playwright is not installed locally, install it in your Node environment or run with `SKIP_BROWSER=1` for API-only validation.

### Development Without Docker
```bash
# Backend
cd backend
cargo run

# Frontend
cd frontend
flutter pub get
flutter run -d chrome
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/health` | Health check plus DB status |
| GET | `/api/version` | App version |
| GET | `/api/accounts` | List all accounts |
| GET | `/api/accounts/summary` | Net worth summary |
| GET | `/api/institutions` | List linked institutions |
| POST | `/api/institutions` | Add an institution |
| GET | `/api/fx/latest/:base/:target` | Latest exchange rate |
| GET | `/api/fx/history/:base/:target` | Exchange rate history |
| GET | `/api/dashboard/overview` | Dashboard aggregations |
| POST | `/api/plaid/*` | Plaid link and sync routes |
| POST | `/api/auth/coinbase/*` | Coinbase OAuth routes |
| POST | `/api/imports/*` | CSV/PDF import routes |
| GET | `/api/tax/*` | Tax estimates and exports |

## Project Structure

```text
patrimonio/
├── backend/               # Rust API (axum)
│   ├── src/
│   │   ├── main.rs        # Entry point, router setup
│   │   ├── config.rs      # Environment config
│   │   ├── api/           # HTTP handlers
│   │   ├── models/        # Database structs
│   │   ├── services/      # Plaid, crypto, FX, tax, imports
│   │   └── db/            # Database utilities
│   ├── migrations/        # SQL migrations
│   ├── Cargo.toml
│   └── Dockerfile
├── frontend/              # Flutter app and web Docker image
├── docs/                  # MkDocs documentation
├── scripts/               # Local validation scripts
├── work/                  # Project specs and tracking
├── docker-compose.yml
├── .env.example
└── README.md
```

## Roadmap

- [x] Foundation: backend scaffold, database, Docker setup
- [x] Plaid integration: US account linking, balances, transactions, holdings
- [x] Dashboard: overview, charts, portfolio, FX, transaction search
- [x] Mexico imports: Nu, Banamex, Cetesdirecto CSV/PDF parsing
- [x] Crypto: Coinbase OAuth and Bitso API support
- [x] Tax planning: US/Mexico estimates and taxable exports
- [x] Local launch hardening: Dockerized frontend and smoke tests
- [ ] Production deployment: hosted frontend/API, backups, monitoring, real credentials

## Cost

| Item | Monthly Cost |
|------|--------------|
| Plaid pay-as-you-go | ~$0-5 during light personal use |
| ExchangeRate-API | Free tier available |
| Local Docker hosting | Free |

## License

Private - personal use.
