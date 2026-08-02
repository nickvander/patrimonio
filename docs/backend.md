# Backend Deep Dive

The Patrimonio backend is built with Rust and Axum. It owns financial-data normalization, integration credentials, aggregation, exports, and database migrations.

## Project Structure

- `backend/src/api/`: Axum handlers and route definitions.
- `backend/src/services/`: Plaid sync, crypto sync, FX rates, tax estimates, projections, encryption, and imports.
- `backend/src/models/`: SQLx models and API data structures.
- `backend/src/services/parser/`: CSV/PDF statement parsing.
- `backend/migrations/`: SQL migrations run at startup.

## Core Services

### Exchange Rate Service

Fetches USD/MXN rates and caches recent responses in Redis to reduce API traffic. Historical rates support net worth views in either currency.

### Plaid Sync

Handles link-token creation, public-token exchange, balance sync, transaction sync, holdings sync, and cursor tracking. Link-token creation is platform-aware: a native Android client sends `{"platform": "android"}` and receives a token carrying `android_package_name` (config `PLAID_ANDROID_PACKAGE_NAME`, default `com.patrimonio.patrimonio`) instead of the web `redirect_uri`, so OAuth banks return into the app.

### Crypto Sync

Coinbase uses OAuth 2.0 and token refresh. Bitso uses read-only API keys and signed requests. Provider balances are normalized into local accounts and holdings.

### Import Parsers

Statement import services parse CSV/PDF statements from Mexican institutions (Nu, Banamex, BBVA, Santander, Banorte, HSBC, Scotiabank, CetesDirecto, Revolut) and US sources (HealthEquity HSA, Fidelity Stock Plan), with a preview-time duplicate check against already-imported transactions. Parsed data is written into the same transaction and balance model used by Plaid.

### Encryption Service

Sensitive Plaid access tokens, Coinbase tokens, and Bitso API credentials are encrypted with AES-256-GCM before storage. Configure `ENCRYPTION_KEY` before linking real accounts.

### Tax Engine

Tax routes estimate US federal and Mexico ISR outcomes, track realized gains lot-by-lot (FIFO disposals), and export filing documents: an FBAR/FinCEN 114 worksheet, a Form-8949-shaped CSV, a Schedule B CSV, and an MX summary CSV.

### Lending

Loan routes track money lent to named borrowers: disbursements and repayments reconcile against real bank transactions (with an auto-suggest matcher), and schedules support amortized, simple flat-interest, and fully custom repayment shapes.

### Notifications and Detection

A unified notifications inbox aggregates FX alert crossings, import-staleness reminders, and loan payment due reminders. Related detection services find recurring charges (subscriptions) in transaction history and link cross-currency cash transfers with their implied FX rate.

## API Areas

- `/api/accounts`: Account management and summaries.
- `/api/auth`: Sessions, passkeys (WebAuthn), TOTP, recovery codes, and invitation-based registration (`/api/auth/invites`).
- `/api/auth/coinbase`: Coinbase OAuth routes.
- `/api/dashboard`: Aggregated dashboard data.
- `/api/fx`: Currency conversion, history, and FX alerts.
- `/api/imports`: File upload, statement parsing, and duplicate checks.
- `/api/institutions`: Plaid link, sync, reconnect, and webhook routes.
- `/api/loans`: Personal lending — borrowers, schedules, and repayment reconciliation.
- `/api/notifications`: The notifications inbox (bell panel).
- `/api/projections`: FIRE / wealth projection calculations and defaults.
- `/api/realtime`: WebSocket for live data-invalidation pushes.
- `/api/recurring`: Recurring & scheduled transaction rules.
- `/api/setup`: Launch-readiness status.
- `/api/tax`: Tax estimates and filing exports.

## Development Workflows

Run the backend through Docker Compose for full-stack work:

```bash
docker compose up --build -d api
docker compose logs -f api
```

For direct Rust development:

```bash
cd backend
cargo test
cargo run
```

### Integration tests (requires a Postgres)

The HTTP-level integration tests in `backend/tests/` (auth, passkeys,
invites, dashboard, imports, FX, loans, notifications, projections,
recurring, tax, and more) need a real Postgres reachable via
`PATRIMONIO_TEST_DATABASE_URL` (some also use Redis via
`PATRIMONIO_TEST_REDIS_URL`). They share a single DB and TRUNCATE on
setup, so they MUST run serially.

The easiest invocation is the wrapper script at the repo root:

```bash
./scripts/test.sh                          # full suite
./scripts/test.sh --test dashboard_endpoints   # one binary
./scripts/test.sh -- --nocapture           # cargo flags after `--`
```

The wrapper:

* Builds a one-time `patrimonio-test` docker image with `pkg-config`
  + `libssl-dev` baked in (the upstream `rust:1.88-slim` doesn't
  ship them and the linker fails otherwise).
* Creates the `patrimonio_test` database on the running
  `patrimonio-postgres-1` container if it doesn't already exist.
* Sets `PATRIMONIO_TEST_DATABASE_URL` and runs cargo with
  `--test-threads=1`.

When the env var is unset (e.g. the script's preflight skipped DB
creation), every integration test prints a loud skip note and returns
Ok so `cargo test` stays green for contributors without a DB on
hand. But a **configured-yet-unreachable** database panics — the
harness refuses to let a broken setup masquerade as a passing suite.
