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

Handles link-token creation, public-token exchange, balance sync, transaction sync, holdings sync, and cursor tracking.

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
- `/api/plaid`: Plaid link and sync routes.
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
