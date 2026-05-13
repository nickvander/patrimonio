# Next Work Backlog

> **Last Updated:** 2026-05-12
> **Purpose:** Prioritized work after V1 launch hardening. Tax improvements are intentionally deferred.

## Recommended Order

### 1. Production Plaid Readiness

**Why now:** This is the path from demo/sandbox to real use. If a user can link a bank and trust the populated data, the app becomes useful immediately.

Track in [PHASE-11-PLAID-PRODUCTION.md](phases/PHASE-11-PLAID-PRODUCTION.md).

Key outcomes:
- Real Plaid development/production credentials tested.
- Link, token exchange, initial sync, webhooks, reconnect, and manual retry paths verified.
- Sync status explains whether data is syncing, complete, blocked by setup, or requires reconnect.
- First-run UX clearly distinguishes sandbox/mock data from real linked data.

### 2. Deployment, Backups, and Operations

**Why next:** Real credentials and financial data should not live only in a local Docker stack without backups, secrets management, or monitoring.

Track in [PHASE-12-DEPLOYMENT-OPS.md](phases/PHASE-12-DEPLOYMENT-OPS.md).

Key outcomes:
- Hosted frontend and API.
- Managed PostgreSQL and Redis.
- Secret-managed Plaid, Coinbase, Bitso, FX, and encryption settings.
- Backup/restore runbooks validated.
- Basic uptime and error visibility.

### 3. Data Quality and Reconciliation

**Why next:** Once real data arrives, trust will depend on deduplication, balance reconciliation, category cleanup, and source provenance.

Track in [PHASE-13-DATA-QUALITY.md](phases/PHASE-13-DATA-QUALITY.md).

Key outcomes:
- Account balances reconcile against provider snapshots.
- Duplicate transactions and import repeats are visible/prevented.
- Categories can be reviewed and corrected.
- Manual/imported/provider records preserve source labels and timestamps.

### 4. Market Data and Benchmarks

**Why later:** It improves portfolio insight, but it is less important than reliable account linking and deployment.

Track in [PHASE-14-MARKET-DATA.md](phases/PHASE-14-MARKET-DATA.md).

Key outcomes:
- Replace static S&P/NASDAQ/BTC benchmark assumptions with historical price data.
- Add quote staleness indicators.
- Cache market data with clear source attribution.

### Deferred: Tax Accuracy

Tax planning should wait until real transaction and holding data are reliable. The current tax tab is useful as a placeholder, but the next serious tax pass should include currency-aware tax basis, account residency, lots, withholding, and jurisdiction-specific reporting assumptions.

## Immediate Next Session

Start with Phase 11:

1. Confirm Plaid dashboard configuration and environment.
2. Add a first-run/sandbox data banner.
3. Harden Plaid API error handling with provider error codes in the backend response model.
4. Add a browser test for Management → Link Plaid disabled/enabled states.
5. Validate one real institution in Plaid development mode before production.
