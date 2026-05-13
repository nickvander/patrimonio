# Current Phase: Phase 13: Data Quality and Reconciliation

> **Last Updated:** 2026-05-13
> **Status:** Plaid Production migration complete. Data Quality Phase (Phase 13) is underway with user overrides, notes, and hardened deduplication implemented.

## What's Done - Full Build Summary

### Core Infrastructure
- Rust backend with axum, SQLx, PostgreSQL 17, and Redis 7
- Docker Compose stack for API, Postgres, Redis, and Flutter web frontend
- Host ports chosen to avoid common local conflicts: app `3000`, API `8080`, Postgres `5433`, Redis `6380`
- API health, dashboard, accounts, FX, imports, Plaid, Coinbase, Bitso, and tax route areas
- Local smoke script for API and browser rendering validation
- **Plaid Production Environment**: Fully migrated from Sandbox with real-world credential support
- **OAuth Update Mode**: Support for reconnecting institutions when credentials expire or change

### Dashboard & Visualization
- Flutter dashboard UI for net worth, accounts, breakdowns, portfolio, FX, utilization, sync status, and tax planning
- Interactive net worth and portfolio visualizations
- 12-month cash-flow trends and asset allocation views
- S&P 500 performance benchmark context
- Transaction search, title-cased descriptions, and category icons

### Data Quality & Reconciliation
- **User Overrides**: Manual category corrections and transaction notes that persist across syncs
- **Source Tracking**: Audit trail for every transaction (`plaid` vs `csv`)
- **Deterministic Deduplication**: Signature-based hashing for CSV imports to prevent duplicate entries
- **Account Management**: Support for deleting institutions and individual accounts
- Manual CSV/PDF imports for Nu Mexico, Banamex, and Cetesdirecto
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

See [NEXT.md](NEXT.md) for the prioritized backlog.

1. **Production Plaid readiness**: Real credential validation, reconnect flows, provider error states, and first-run real-vs-sandbox UX.
2. **Deployment and operations**: Hosted frontend/API, managed database/cache, secret management, backups, and monitoring.
3. **Data quality and reconciliation**: Duplicate prevention, import/source metadata, category review, stale data indicators.
4. **Real market data**: Replace static benchmark assumptions with sourced historical market data.
5. **Tax accuracy**: Deferred until account, transaction, holding, and source data are reliable.

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
