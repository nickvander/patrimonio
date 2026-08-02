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
- **Frontend:** Flutter — web (served by nginx in Docker) + native Android APK
- **Deployment:** Docker Compose, locally and in production (nginx-served Flutter web + API + Postgres + Redis in one stack; prod runs it on the homelab)
- **Data:** Plaid, Coinbase, Bitso, CSV/PDF import, ExchangeRate-API

## Architecture

```text
Browser -> nginx/Flutter Web -> Rust API (axum) -> PostgreSQL + Redis
                                      |
                                      +-> Plaid / Coinbase / Bitso / CSV-PDF / FX APIs
```

## Platforms

- **Web** — the primary surface: the Flutter web build served by nginx, which
  proxies `/api` same-origin to the Rust API.
- **Android APK** (shipped 2026-07-13) — the same Flutter codebase, with
  web-only code isolated behind conditional-import seams. On first launch a
  Settings screen asks for the self-hosted backend URL (HTTPS-only; a
  Cloudflare Access service token is supported for fronted deployments) and
  remembers it. CI gates `flutter build apk --release`; the universal APK
  (~70 MB) is the emulator/CI build, phone installs use `--split-per-abi`
  (~25 MB arm64). Native passkeys and persistent sessions work.

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
