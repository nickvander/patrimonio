# Patrimonio — Personal Finance Tracker

**Cross-platform personal finance tracker (US + Mexico). Tracks accounts across 14+ institutions with real-time USD/MXN exchange rates.**

[![Documentation](https://img.shields.io/badge/docs-MkDocs-blue.svg)](https://your-username.github.io/patrimonio/)

## Getting Started
See the [Project Overview](docs/index.md) or the [Deployment Guide](docs/deployment.md) to get started.

## Institutions Supported

### US (via Plaid API)
SoFi · Chase · American Express · Capital One · Bilt · US Bank · Fidelity · Fidelity NetBenefits · Vanguard 401k · HealthEquity HSA · Robinhood

### Crypto (Direct OAuth / API)
Coinbase · Bitso

### Mexico (via CSV/PDF upload)
Nu Bank Mexico · Banamex · Cetesdirecto

## Tech Stack

| Layer | Technology |
|-------|-----------|
| Backend | Rust + axum |
| Database | PostgreSQL 17 |
| Cache | Redis 7 |
| Frontend | Flutter (web, desktop, mobile) |
| Financial Data | Plaid API & Coinbase OAuth |
| Exchange Rates | ExchangeRate-API (free tier) |
| Deployment | Docker Compose (local) / GCP Cloud Run |

## Quick Start

### Prerequisites
- Docker & Docker Compose

### Run locally
```bash
# Clone the repo
git clone https://github.com/nickvander/patrimonio.git
cd patrimonio

# Copy environment config
cp .env.example .env

# Start all services
docker compose up --build

# API is at http://localhost:8080
# Health check: curl http://localhost:8080/api/health
```

### Development (without Docker)
```bash
# Backend (requires Rust)
cd backend
cargo run

# Frontend (requires Flutter SDK)
cd frontend
flutter run -d chrome
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/api/health` | Health check + DB status |
| GET | `/api/version` | App version |
| GET | `/api/accounts` | List all accounts |
| GET | `/api/accounts/summary` | Net worth summary |
| GET | `/api/institutions` | List linked institutions |
| POST | `/api/institutions` | Add an institution |
| GET | `/api/fx/latest/:base/:target` | Latest exchange rate |
| GET | `/api/fx/history/:base/:target` | Exchange rate history |
| GET | `/api/dashboard/overview` | Dashboard aggregations |

## Project Structure

```
patrimonio/
├── backend/               # Rust API (axum)
│   ├── src/
│   │   ├── main.rs        # Entry point, router setup
│   │   ├── config.rs      # Environment config
│   │   ├── api/           # HTTP handlers
│   │   ├── models/        # Database structs
│   │   ├── services/      # Business logic
│   │   └── db/            # Database utilities
│   ├── migrations/        # SQL migrations
│   ├── Cargo.toml
│   └── Dockerfile
├── frontend/              # Flutter app (coming Phase 3)
├── work/                  # Project specs & tracking
│   ├── OVERVIEW.md        # Project overview
│   ├── DECISIONS.md       # Architectural decision log
│   └── phases/            # Phase-by-phase specs
├── docker-compose.yml
├── .env.example
└── README.md
```

## Roadmap

- [x] **Phase 1:** Foundation — Backend scaffold, database, Docker setup
- [x] **Phase 2:** Plaid Integration — Link US accounts, sync data
- [x] **Phase 3:** Dashboard — Charts, breakdowns, exchange rate widget
- [ ] **Phase 4:** Mexican Institutions — CSV/PDF import, multi-currency
- [ ] **Phase 5:** Polish & Deploy — Mobile, GCP, backups

## Cost

| Item | Monthly Cost |
|------|-------------|
| Plaid (pay-as-you-go) | ~$0–5 |
| Exchange Rate API | Free |
| Self-hosted | Free |
| **Total** | **~$0–5** |

## License

Private — personal use.
