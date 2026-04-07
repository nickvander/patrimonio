# Current Phase: V1 Complete ✅

> **Last Updated:** 2026-04-06
> **Status:** All 10 phases implemented. Application is V1-stable on `phase-8-crypto-integration` branch.

## What's Done — Full Build Summary

### Core Infrastructure (Phases 1–2)
- Rust backend with axum (6 API modules, 7 models, 3 services)
- PostgreSQL schema (6 tables with indexes)
- Docker Compose stack (API + Postgres 17 + Redis 7) — all passing health checks
- All API endpoints verified working (0–33ms response times)
- Exchange rate service with Redis caching
- Plaid API Token Exchange & Sandbox Web UI
- Plaid Sync Engines for Balances, Transactions, and Holdings

### Dashboard & Visualization (Phases 3, 7)
- Flutter Dashboard UI: Net Worth, Breakdowns, Portfolio, FX, Utilization, Sync Status
- Interactive Net Worth tooltips (Assets vs Liabilities breakdown)
- 12-month Rolling Cash Flow Trends (Income vs Spending bar chart, wider 22px bars)
- Multi-level Asset Allocation Treemap (Category → Account/Holding hierarchy)
- Color-coded Portfolio Legend with holding names, reduced widget footprint
- S&P 500 Performance Benchmarking on Net Worth Chart

### Data & Imports (Phases 4–5)
- Transaction Ledger (Backend API + Frontend Tab)
- Multi-Currency Bridge (USD/MXN toggle) globally
- Manual CSV/PDF Imports for Nu Mexico, Banamex, and CetesDirecto
- Manual Account Creation with institution metadata
- Increased PDF/CSV upload limit (20MB) with robust error handling

### Advanced Features (Phases 6, 8–9)
- Wealth Projection & FIRE Tracking (Phase 6)
- Coinbase OAuth 2.0 with token refresh and secure encryption (Phase 8)
- Bitso API: HMAC-signed integration for MXN crypto valuation (Phase 8)
- CryptoPriceService: Real-time ticker price fetching (BTC, ETH, etc.)
- Tax Estimation Engine: US Federal (Single/Married/HoH) + Mexico ISR (Phase 9)
- Scalable Capital Gains: Blended cost-basis ratio from `holdings` table
- CSV & PDF Export for taxable transaction history and tax summaries
- Tax Dashboard with Filing Status toggle, Year selector, and empty-state UX

### V1 Polish (Phase 10)
- Smart Category Icons: Colorful, context-aware icons for transaction categories
- Title-Cased Descriptions: Normalized raw ALL-CAPS bank text
- Transaction Search: Real-time search/filter bar
- PDF Tax Report export button alongside CSV
- Portfolio legend labels fixed (holding name instead of "SEC")
- Deprecated API endpoint cleanup
- Comprehensive Documentation Suite in `docs/` via MkDocs

## Remaining Known Issues
| Issue | Tab | Severity |
|-------|-----|----------|
| Portfolio legend shows "Investment" 4× (sandbox data limitation) | Portfolio | Low |
| Return shows "+1234467.00%" (sandbox math artifact) | Portfolio | Medium |
| Mixed-case descriptions not fully normalized in edge cases | Transactions | Low |
| Credit card icons uniform gray — could use more variation | Transactions | Low |
| Tax shows $0.00 everywhere (no taxable events in sandbox) | Tax Planning | Expected |

## What Could Come Next (Post-V1)
1. **Plaid Production Keys**: Connect real bank accounts
2. **Mobile Layout**: Responsive breakpoints for phone/tablet
3. **Dark/Light Theme**: Finalize overarching theme system
4. **FBAR/FATCA Reporting**: Auto-detect foreign account thresholds
5. **Real Market Data**: Live S&P 500 overlay instead of static 10% assumption
6. **Caching Optimizations**: Faster cold-load performance

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
