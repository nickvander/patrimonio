# Patrimonio - Personal Finance Tracker

**Cross-platform personal finance tracker for US and Mexico accounts, investments, crypto, taxes, and USD/MXN reporting.**

[![Documentation](https://img.shields.io/badge/docs-MkDocs-blue.svg)](docs/index.md)

## Getting Started

See the [Project Overview](docs/index.md) or the [Deployment Guide](docs/deployment.md) for the full setup notes.

## Institutions Supported

### US (via Plaid API)
SoFi · Chase · American Express · Capital One · Bilt · US Bank · Fidelity · Fidelity NetBenefits · Vanguard 401k · HealthEquity HSA · Robinhood

### Crypto (direct integrations)
Coinbase · Bitso

### Mexico (via CSV/PDF upload)
Nu Bank Mexico · Banamex · Cetesdirecto

## Tech Stack

| Layer | Technology |
|-------|------------|
| Backend | Rust + axum |
| Database | PostgreSQL 17 |
| Cache | Redis 7 |
| Frontend | Flutter Web served by nginx in Docker |
| Financial Data | Plaid, Coinbase OAuth, Bitso API, CSV/PDF import |
| Exchange Rates | ExchangeRate-API with Redis caching |
| Deployment | Docker Compose locally; static hosting + API container for production |

## Quick Start

### Prerequisites
- Docker and Docker Compose
- Optional integration credentials in `.env` for Plaid, Coinbase, Bitso, and ExchangeRate-API

### Run Locally
```bash
git clone https://github.com/nickvander/patrimonio.git
cd patrimonio

cp .env.example .env
docker compose up --build -d
```

Open the app at [http://127.0.0.1:3000](http://127.0.0.1:3000).

### Working in a git worktree
`docker compose` only reads `.env` from its current directory, so a
freshly-created worktree comes up without any of the Plaid /
encryption secrets and every Plaid sync fails with
"Encryption key missing". The wrapper below symlinks the repo-root
`.env` first, then runs `docker compose up -d --build`:

```bash
bash scripts/dev-up.sh           # build + start everything
bash scripts/dev-up.sh frontend api   # rebuild just these services
```

If you'd rather call `docker compose` directly, run
`bash scripts/setup-env.sh` once after creating the worktree to
plant the symlink.

Service URLs:
- Frontend: `http://127.0.0.1:3000`
- API: `http://127.0.0.1:8080`
- Health check: `curl http://127.0.0.1:8080/api/health`
- Postgres host port: `5433`
- Redis host port: `6380`

### First-run sign-in

**There is no default username or password.** On first launch the app
shows a one-time bootstrap screen and asks you to create the owner
account directly. This is a deliberate choice — shipped defaults on
self-hosted financial software get scanned for and exploited.

1. Open `http://127.0.0.1:3000` after `docker compose up`.
2. Pick a username and a password of **at least 12 characters**. An
   email is optional and used only for future password reset.
3. The bootstrap endpoint refuses to run a second time, so the account
   you create here is the only one until multi-user support lands.

If you forget the password, drop the `users` row in Postgres and the
bootstrap screen reappears:

```bash
docker exec -it patrimonio-postgres-1 \
  psql -U patrimonio -d patrimonio -c "DELETE FROM users;"
```

In any deployment served over HTTPS, set `COOKIE_SECURE=true` in
`.env` so the session cookie is only sent over TLS. The cookie is also
marked Secure automatically when `FRONTEND_BASE_URL` starts with
`https://`.

### Securing the account: TOTP, recovery codes, passkeys

After bootstrap, open the **Security** screen (shield icon in the
top-right of the dashboard) to layer extra factors on top of the
password.

**TOTP (recommended for every install)**

1. Security → "Add an authenticator app".
2. Scan the QR with Authy / Google Authenticator / 1Password, OR
   paste the displayed base32 secret if your authenticator doesn't
   scan.
3. Enter the 6-digit code from your authenticator to confirm. The
   confirm step uses a no-replay-advance verifier — you can log
   in immediately afterward with the same code, even if you're
   still inside the same 30 s TOTP step.
4. On subsequent logins, `/login` returns `requires_totp: true`
   after the password step and the UI prompts for the code via
   `POST /api/auth/totp/verify`.

The TOTP secret is encrypted at rest with `ENCRYPTION_KEY` (set
this before enabling TOTP — see Plaid section).

**Recovery codes**

Bootstrap mints 10 one-time recovery codes and shows them ONCE on
the response. Save them somewhere persistent (password manager,
printed copy). Each code is a 12-character base32 string.

* The Security screen shows the count of unused codes. When it
  drops below 3 a warning tile appears with a "Regenerate" CTA.
* `POST /api/auth/recover` consumes a code + resets the password.
  Use this if you lose your authenticator AND can't reach the
  database to clear the `users` row.
* "Regenerate" mints a fresh batch of 10 codes and invalidates the
  old ones in one stroke — useful if a code might've leaked.

**Passkeys (FIDO2 / WebAuthn)**

Hardware keys (YubiKey, Apple Touch ID, Windows Hello,
cross-device phone-to-desktop QR) all work via
[`webauthn-rs`](https://github.com/kanidm/webauthn-rs).

1. Security → "Register a passkey".
2. Follow the browser prompt — pick the authenticator type your
   device offers.
3. On the login screen, click "Sign in with a passkey" instead of
   typing a password. The discoverable-credentials flow means you
   don't need to type a username first.

Multiple passkeys can be registered per account — keep a hardware
key in a safe as backup. Account recovery still falls back to
password + TOTP, so removing all passkeys doesn't lock you out.

**Hardening notes**

* Failed login attempts get a 50–150 ms random jitter before
  responding (closes a sub-threshold brute-force probe at HTTP
  throughput) and the 429 path applies exponential backoff
  (1 → 2 → 4 → 8 → 16 → 30 s capped) once you cross 5 failures
  per minute.
* `X-Forwarded-For` from untrusted peers is stripped before
  reaching the rate limiter — set `TRUSTED_PROXY_CIDRS` to your
  reverse-proxy's IP in production.
* CSRF defence: every mutating request (POST/PUT/PATCH/DELETE)
  must include an `X-Requested-With` header. The frontend sends
  this automatically; curl / scripted clients need to add it.

### Smoke Test
```bash
NODE_PATH=/path/to/node_modules ./scripts/smoke.cjs
```

The smoke test verifies API health and renders the Flutter app in a browser with Playwright. If Playwright is not installed locally, install it in your Node environment or run with `SKIP_BROWSER=1` for API-only validation.

### Development Without Docker
```bash
# Backend
cd backend
cargo run

# Frontend
cd frontend
flutter pub get
flutter run -d chrome
```

## API Endpoints

All data routes require a session cookie. Public endpoints are health,
version, setup status, and `/api/auth/{status,login,bootstrap}`.

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| GET | `/api/health` | public | Health check plus DB status |
| GET | `/api/version` | public | App version |
| GET | `/api/setup/status` | public | Integration config readiness |
| GET | `/api/auth/status` | public | `needs_bootstrap`, `authenticated`, current user |
| POST | `/api/auth/bootstrap` | public, one-shot | Create the owner account on first run |
| POST | `/api/auth/login` | public | Sign in, sets session cookie |
| POST | `/api/auth/logout` | session | Revoke the current session |
| GET | `/api/auth/me` | session | Current user profile |
| POST | `/api/auth/change-password` | session | Rotate password, revokes other sessions |
| GET | `/api/auth/coinbase/*` | session | Coinbase OAuth link flow |
| GET | `/api/accounts` | session | List all accounts |
| GET | `/api/accounts/summary` | session | Net worth summary |
| GET | `/api/institutions` | session | List linked institutions |
| POST | `/api/institutions` | session | Add an institution |
| GET | `/api/fx/latest/:base/:target` | session | Latest exchange rate |
| GET | `/api/fx/history/:base/:target` | session | Exchange rate history |
| GET | `/api/dashboard/overview` | session | Dashboard aggregations |
| POST | `/api/plaid/*` | session | Plaid link and sync routes |
| POST | `/api/imports/*` | session | CSV/PDF import routes |
| GET | `/api/tax/*` | session | Tax estimates and exports |

## Project Structure

```text
patrimonio/
├── backend/               # Rust API (axum)
│   ├── src/
│   │   ├── main.rs        # Entry point, router setup
│   │   ├── config.rs      # Environment config
│   │   ├── api/           # HTTP handlers
│   │   ├── models/        # Database structs
│   │   ├── services/      # Plaid, crypto, FX, tax, imports
│   │   └── db/            # Database utilities
│   ├── migrations/        # SQL migrations
│   ├── Cargo.toml
│   └── Dockerfile
├── frontend/              # Flutter app and web Docker image
├── docs/                  # MkDocs documentation
├── scripts/               # Local validation scripts
├── work/                  # Project specs and tracking
├── docker-compose.yml
├── .env.example
└── README.md
```

## Roadmap

- [x] Foundation: backend scaffold, database, Docker setup
- [x] Plaid integration: US account linking, balances, transactions, holdings
- [x] Dashboard: overview, charts, portfolio, FX, transaction search
- [x] Mexico imports: Nu, Banamex, Cetesdirecto CSV/PDF parsing
- [x] Crypto: Coinbase OAuth and Bitso API support
- [x] Tax planning: US/Mexico estimates and taxable exports
- [x] Local launch hardening: Dockerized frontend and smoke tests
- [ ] Production deployment: hosted frontend/API, backups, monitoring, real credentials

## Cost

| Item | Monthly Cost |
|------|--------------|
| Plaid pay-as-you-go | ~$0-5 during light personal use |
| ExchangeRate-API | Free tier available |
| Local Docker hosting | Free |

## License

Private - personal use.
