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

Mexico import services parse Nu, Banamex, and Cetesdirecto CSV/PDF statements. Parsed data is written into the same transaction and balance model used by Plaid.

### Encryption Service

Sensitive Plaid access tokens, Coinbase tokens, and Bitso API credentials are encrypted with AES-256-GCM before storage. Configure `ENCRYPTION_KEY` before linking real accounts.

### Tax Engine

Tax routes estimate US federal and Mexico ISR outcomes, use holding cost-basis data where available, and export taxable transaction history as CSV/PDF.

## API Areas

- `/api/accounts`: Account management and summaries.
- `/api/dashboard`: Aggregated dashboard data.
- `/api/fx`: Currency conversion and history.
- `/api/imports`: File upload and statement parsing.
- `/api/institutions`: Plaid link, sync, reconnect, and webhook routes.
- `/api/auth/coinbase`: Coinbase OAuth routes.
- `/api/tax`: Tax estimates and exports.

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

The HTTP-level integration tests in `backend/tests/auth_endpoints.rs`,
`tests/auth_recovery_totp.rs`, and `tests/dashboard_endpoints.rs`
need a real Postgres reachable via `PATRIMONIO_TEST_DATABASE_URL`.
They also share a single DB and TRUNCATE on setup, so they MUST
run serially.

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
creation), every integration test prints a skip note and returns
Ok so `cargo test` stays green for contributors without a DB on
hand — the suite never silently passes through an unconfigured
machine.
