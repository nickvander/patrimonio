# Current Phase: Phase 10 — V1 Stability & Polish (Pending) 🚀

> **Last Updated:** 2026-04-06
> **Status:** Phase 9 completed, Phase 10 (Stability) pending.

## What's Done
- Rust backend with axum (6 API modules, 7 models, 3 services)
- PostgreSQL schema (6 tables with indexes)
- Docker Compose stack (API + Postgres 17 + Redis 7) — all passing health checks
- All API endpoints verified working (0–33ms response times)
- `work/` directory with specs, decisions, and 7 phase specs
- VS Code workspace config
- **Exchange rate service with Redis caching implemented**
- **Plaid API Token Exchange & Sandbox Web UI Implemented**
- **Plaid Sync Engines for Balances, Transactions, and Holdings mapped**
- **Flutter Dashboard UI implemented (Net Worth, Breakdowns, Portfolio, FX, Utilization, Sync Status)**
- **Transaction Ledger implemented (Backend API + Frontend Tab)**
- **Multi-Currency Bridge (USD/MXN toggle) implemented globally**
- **Performance Benchmarking (S&P 500) implemented on Net Worth Chart**
- **Manual CSV/PDF Imports implemented for Nu Mexico, Banamex, and CetesDirecto**
- **Manual Account Creation fixed (added missing institution metadata)**
- **Wealth Projection & FIRE Tracking implemented (Phase 6)**
- **Comprehensive Documentation Suite implemented in `docs/` via MkDocs**
- **Phase 7 Implementation**:
    - Interactive Net Worth tooltips (Assets vs Liabilities breakdown)
    - 12-month Rolling Cash Flow Trends (Income vs Spending bar chart)
    - Multi-level Asset Allocation Treemap (Category → Account/Holding hierarchy)
    - Color-coded Portfolio Legend and reduced widget footprint
    - Increased PDF/CSV upload limit (20MB) and robust error handling in `ApiService`
- **Phase 8 Implementation (Completed)**:
    - **Coinbase OAuth 2.0**: Redirect/callback flow with token refresh and secure encryption.
    - **Bitso API**: HMAC-signed API key integration for real-time MXN crypto valuation.
    - **CryptoPriceService**: Real-time ticker price fetching (BTC, ETH, etc.) for USD/MXN.
    - **Dashboard Aggregation**: Crypto accounts integrated into Net Worth, Type Breakdown, and Asset Allocation Treemap.
    - **UI Polish**: "Link Coinbase" (OAuth), refined Bitso dialog with help links, and "Crypto" category in Accounts List.
    - **Cleanup**: Resolved frontend compilation bugs and removed legacy build logs/dummy files.

## What's Next
Proceed with the implementation of **Phase 10: V1 Stability & Polish**:
1. **Phase 10: V1 Stability & Polish** (Drafting pending)
    - Mobile layout responsiveness improvements.
    - Finalizing overarching dark/light mode themes.
    - Caching optimizations for faster loading.

## How to Continue Work

### Starting the dev environment
```bash
cd ~/patrimonio
docker compose up -d          # Start all services
docker compose logs -f api    # Watch API logs
```

### Testing endpoints
```bash
curl http://localhost:8080/api/health
curl http://localhost:8080/api/accounts/summary
curl http://localhost:8080/api/dashboard/overview
```

### Making backend changes
Edit files in `backend/src/`, then rebuild:
```bash
docker compose up --build -d api
```

### Phase progression
1. Check this file (CURRENT.md) for what's next
2. Open the relevant phase spec in `work/phases/`
3. Work through the deliverables checklist
4. When a phase is complete, update CURRENT.md to point to the next phase
5. Log any decisions in [DECISIONS.md](DECISIONS.md)
