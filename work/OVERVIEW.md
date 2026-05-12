# Patrimonio - Project Overview

**A cross-platform personal finance tracker for US and Mexican accounts, investments, crypto, taxes, and USD/MXN reporting.**

## Vision

One dashboard to see banking, credit cards, brokerages, retirement, HSA, crypto, and Mexican financial accounts with consistent currency conversion and historical context.

## Institutions Tracked

| # | Institution | Type | Country | Integration |
|---|-------------|------|---------|-------------|
| 1 | SoFi Bank | Banking | US | Plaid |
| 2 | Chase | Credit Card | US | Plaid |
| 3 | American Express | Credit Card | US | Plaid |
| 4 | Capital One | Banking/CC | US | Plaid |
| 5 | Bilt | Credit Card | US | Plaid |
| 6 | US Bank | Credit Card | US | Plaid |
| 7 | Fidelity Brokerage | Brokerage | US | Plaid |
| 8 | Fidelity NetBenefits | Retirement | US | Plaid |
| 9 | Vanguard 401k | Retirement | US | Plaid |
| 10 | HealthEquity HSA | HSA | US | Plaid |
| 11 | Robinhood | Brokerage | US | Plaid |
| 12 | Coinbase | Crypto | US | OAuth/API |
| 13 | Bitso | Crypto | MX | Read-only API |
| 14 | Nu Bank Mexico | Banking | MX | CSV/PDF upload |
| 15 | Banamex | Banking | MX | CSV/PDF upload |
| 16 | Cetesdirecto | Government securities | MX | CSV/PDF upload |

## Tech Stack

- **Backend:** Rust + axum + SQLx + PostgreSQL + Redis
- **Frontend:** Flutter web, served by nginx in Docker
- **Deployment:** Docker Compose locally; static frontend hosting plus API container for production
- **Data:** Plaid, Coinbase, Bitso, CSV/PDF import, ExchangeRate-API

## Architecture

```text
Browser -> nginx/Flutter Web -> Rust API (axum) -> PostgreSQL + Redis
                                      |
                                      +-> Plaid / Coinbase / Bitso / CSV-PDF / FX APIs
```

## Local Launch

```bash
docker compose up --build -d
```

- App: `http://127.0.0.1:3000`
- API: `http://127.0.0.1:8080`
- Postgres host port: `5433`
- Redis host port: `6380`

## Cost

- Plaid: ~$0-5/month for light personal usage
- ExchangeRate-API: Free tier available
- Local Docker hosting: $0
