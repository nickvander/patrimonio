# Patrimonio - Project Overview

Patrimonio is a cross-platform personal finance tracker for users with accounts in both the US and Mexico. It brings bank accounts, credit cards, brokerages, retirement accounts, HSA balances, crypto, imported Mexican statements, and tax planning into one dashboard.

## Vision

Provide a single view of net worth across institutions, countries, asset classes, and currencies. The app normalizes balances and transactions into PostgreSQL, converts USD/MXN values with cached FX rates, and exposes the result through a Flutter dashboard.

## Key Features

- **Multi-currency reporting**: USD/MXN conversion with global dashboard toggles, FX-aware investment cost basis, and automatic linking of cross-currency cash transfers (see the [multi-currency guide](multi-currency.md)).
- **US institutional sync**: Plaid account, balance, transaction, and holding sync.
- **Crypto integrations**: Coinbase OAuth and Bitso read-only API support.
- **Statement imports**: CSV/PDF parsing for Mexican banks (Nu, Banamex, BBVA, Santander, Banorte, HSBC, Scotiabank, CetesDirecto, Revolut) plus HealthEquity HSA and Fidelity Stock Plan reports, with duplicate detection on re-uploads.
- **Portfolio views**: Allocation, holdings, realized gains, dividend income, historical net worth, and S&P 500 benchmark context.
- **Cash flow**: Income vs. spending, recurring-charge (subscription) detection, and budgets.
- **Lending**: Personal loans to named borrowers with payment schedules, including custom flat-interest schedules.
- **Projections**: Interactive FIRE projections with scenario controls.
- **Tax planning**: US federal and Mexico ISR estimates, plus filing exports — FBAR worksheet, Form 8949 CSV, Schedule B CSV, and an MX summary.
- **Security**: Session auth with passkeys (WebAuthn), TOTP, and invitation-based registration.
- **Local launch stack**: Docker Compose starts the API, Postgres, Redis, and the Flutter web app served by nginx.

## Technology Stack

- **Backend**: Rust + Axum + SQLx
- **Frontend**: Flutter (web + Android APK)
- **Database**: PostgreSQL 17
- **Cache**: Redis 7
- **Infrastructure**: Docker Compose, locally and in production (nginx-served Flutter web + API + Postgres + Redis in one stack)

## Getting Started

Run the local stack:

```bash
docker compose up --build -d
```

Open [http://127.0.0.1:3000](http://127.0.0.1:3000). The API health endpoint is [http://127.0.0.1:8080/api/health](http://127.0.0.1:8080/api/health).

For detailed setup and validation, see the [Deployment Guide](deployment.md).
