# Patrimonio - Project Overview

Patrimonio is a cross-platform personal finance tracker for users with accounts in both the US and Mexico. It brings bank accounts, credit cards, brokerages, retirement accounts, HSA balances, crypto, imported Mexican statements, and tax planning into one dashboard.

## Vision

Provide a single view of net worth across institutions, countries, asset classes, and currencies. The app normalizes balances and transactions into PostgreSQL, converts USD/MXN values with cached FX rates, and exposes the result through a Flutter dashboard.

## Key Features

- **Multi-currency reporting**: USD/MXN conversion with global dashboard toggles.
- **US institutional sync**: Plaid account, balance, transaction, and holding sync.
- **Crypto integrations**: Coinbase OAuth and Bitso read-only API support.
- **Mexico imports**: Nu Mexico, Banamex, and Cetesdirecto CSV/PDF parsing.
- **Portfolio views**: Allocation, holdings, historical net worth, and S&P 500 benchmark context.
- **Tax planning**: US federal and Mexico ISR estimates, taxable transaction exports, and PDF/CSV tax reports.
- **Local launch stack**: Docker Compose starts the API, Postgres, Redis, and the Flutter web app served by nginx.

## Technology Stack

- **Backend**: Rust + Axum + SQLx
- **Frontend**: Flutter Web
- **Database**: PostgreSQL 17
- **Cache**: Redis 7
- **Infrastructure**: Docker Compose locally; static frontend hosting plus API container for production

## Getting Started

Run the local stack:

```bash
docker compose up --build -d
```

Open [http://127.0.0.1:3000](http://127.0.0.1:3000). The API health endpoint is [http://127.0.0.1:8080/api/health](http://127.0.0.1:8080/api/health).

For detailed setup and validation, see the [Deployment Guide](deployment.md).
