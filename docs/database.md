# Database Schema

Patrimonio uses PostgreSQL 17 as its primary relational database. Migrations are managed with SQLx and run automatically on backend startup.

## Entity Relationship Diagram

```mermaid
erDiagram
    institutions ||--o{ accounts : manages
    accounts ||--o{ balance_snapshots : tracks
    accounts ||--o{ holdings : contains
    accounts ||--o{ transactions : logs

    institutions {
        uuid id PK
        string name
        string country
        string integration_type "plaid, csv, pdf, crypto, manual"
        string plaid_institution_id
        string encrypted_access_token
        string sync_status
    }

    accounts {
        uuid id PK
        uuid institution_id FK
        string external_id
        string name
        string account_type
        string subtype
        decimal current_balance
        string currency
    }

    transactions {
        uuid id PK
        uuid account_id FK
        string external_id
        date date
        decimal amount
        string description
        string category
        jsonb metadata
    }

    holdings {
        uuid id PK
        uuid account_id FK
        string security_id
        string symbol
        decimal quantity
        decimal price
        decimal market_value
        decimal cost_basis
        string currency
    }

    balance_snapshots {
        uuid id PK
        uuid account_id FK
        date as_of_date
        decimal balance
        decimal balance_usd
    }

    exchange_rates {
        uuid id PK
        string base_currency
        string target_currency
        decimal rate
        date as_of_date
    }
```

## Tables Overview

### `institutions`

Stores banks, brokerages, crypto exchanges, and manual/import sources. Integration metadata includes provider identifiers and encrypted credentials where needed.

### `accounts`

Represents checking, savings, credit, brokerage, retirement, HSA, crypto, Cetes, and manual accounts. `external_id` links records back to a provider when available.

### `transactions`

Stores normalized account activity from Plaid, imports, and manual sources. Provider IDs prevent duplicate imports and support incremental sync.

### `holdings`

Stores securities and crypto positions, including quantity, market value, price, and cost-basis fields used by portfolio and tax views.

### `balance_snapshots`

Keeps dated balance history for net worth charts and trend analysis.

### `exchange_rates`

Stores USD/MXN rates for current and historical conversion.

### Sync metadata

The schema also tracks provider sync cursors, including Plaid transaction cursors, so incremental sync can resume without replaying full histories.

## Migrations

Migration files live in `backend/migrations/`. Start the API or run the Compose stack to apply pending migrations.
