# Patrimonio — Project Overview

**A cross-platform personal finance tracker for US and Mexican accounts.**

## Vision
One dashboard to see all finances across banking, credit cards, brokerages, retirement, and HSA — with real-time exchange rates between USD and MXN.

## Institutions Tracked
| # | Institution | Type | Country | Integration |
|---|------------|------|---------|-------------|
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
| 12 | Nu Bank Mexico | Banking | MX | CSV Upload |
| 13 | Banamex | Banking | MX | CSV Upload |
| 14 | Cetesdirecto | Government Securities | MX | CSV Upload |

## Tech Stack
- **Backend:** Rust + axum + PostgreSQL + Redis
- **Frontend:** Flutter (web, desktop, mobile)
- **Deployment:** Docker Compose (local), GCP Cloud Run (cloud)
- **Data:** Plaid API (US), CSV/OFX upload (MX), ExchangeRate-API (FX)

## Architecture
```
Flutter (Web/Desktop/Mobile) → Rust API (axum) → PostgreSQL + Redis
                                    ↓
                         Plaid / CSV / FX APIs
```

## Cost
- Plaid: ~$0-5/month (pay-as-you-go, `/accounts/get` is free)
- Exchange Rate API: Free tier (1,500 calls/month)
- Self-hosted: $0 | GCP free tier: $0
