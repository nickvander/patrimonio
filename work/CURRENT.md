# Current Phase: V1 Launch-Hardened

> **Last Updated:** 2026-05-12
> **Status:** V1 feature set is implemented on `phase-8-crypto-integration`; local launch, frontend containerization, and smoke validation have been hardened.

## What's Done - Full Build Summary

### Core Infrastructure
- Rust backend with axum, SQLx, PostgreSQL 17, and Redis 7
- Docker Compose stack for API, Postgres, Redis, and Flutter web frontend
- Host ports chosen to avoid common local conflicts: app `3000`, API `8080`, Postgres `5433`, Redis `6380`
- API health, dashboard, accounts, FX, imports, Plaid, Coinbase, Bitso, and tax route areas
- Local smoke script for API and browser rendering validation

### Dashboard & Visualization
- Flutter dashboard UI for net worth, accounts, breakdowns, portfolio, FX, utilization, sync status, and tax planning
- Interactive net worth and portfolio visualizations
- 12-month cash-flow trends and asset allocation views
- S&P 500 performance benchmark context
- Transaction search, title-cased descriptions, and category icons

### Data & Imports
- Plaid token exchange and sync engines for balances, transactions, and holdings
- Manual CSV/PDF imports for Nu Mexico, Banamex, and Cetesdirecto
- Manual account creation and balance updates
- Global USD/MXN display support

### Crypto and Tax
- Coinbase OAuth 2.0 with refresh support and encrypted token storage
- Bitso read-only API integration with HMAC-signed requests
- Crypto price and valuation services
- US federal and Mexico ISR tax estimates
- Taxable transaction CSV/PDF exports

### Launch Hardening
- Flutter web build served from an nginx container at `http://127.0.0.1:3000`
- Docker build path verified for backend and frontend
- Browser smoke testing added through `scripts/smoke.cjs`
- Documentation refreshed for current local launch flow

## Remaining Known Issues

| Issue | Area | Severity |
|-------|------|----------|
| Portfolio legend can show repeated generic labels when sandbox data is sparse | Portfolio | Low |
| Mixed-case descriptions may still need edge-case cleanup | Transactions | Low |
| Credit card icons could use more issuer-specific variation | Transactions | Low |
| Tax shows zero when sandbox data has no taxable events | Tax Planning | Expected |

## What Could Come Next

1. **Real credential validation**: Test Plaid, Coinbase, Bitso, and FX keys outside sandbox/mock data.
2. **Production deployment**: Host frontend, API, managed database, Redis, and secrets.
3. **Backups and monitoring**: Add database backups, uptime checks, and error logging.
4. **FBAR/FATCA reporting**: Detect foreign-account thresholds and export support data.
5. **Real market benchmark data**: Replace static S&P assumptions with live market data.
6. **Mobile QA**: Exercise and refine phone/tablet breakpoints.

## How to Continue Work

### Start the dev environment

```bash
cd ~/patrimonio
docker compose up --build -d
docker compose ps
```

Open `http://127.0.0.1:3000`.

### Test endpoints

```bash
curl http://127.0.0.1:8080/api/health
curl http://127.0.0.1:8080/api/accounts/summary
curl http://127.0.0.1:8080/api/dashboard/overview
```

### Run smoke validation

```bash
NODE_PATH=/path/to/node_modules ./scripts/smoke.cjs
```

Use `SKIP_BROWSER=1 ./scripts/smoke.cjs` only when Playwright/browser dependencies are unavailable.

### Make backend changes

```bash
docker compose up --build -d api
docker compose logs -f api
```

### Make frontend changes

```bash
cd frontend
flutter analyze
flutter build web
```

Rebuild the local web container after frontend changes:

```bash
docker compose up --build -d frontend
```
