# Database Schema

Patrimonio uses **PostgreSQL 17** as its primary relational database. Data integrity is enforced through strong types, foreign keys, and constraints.

## Entity Relationship Diagram

```mermaid
erDiagram
    institutions ||--o{ accounts : "manages"
    accounts ||--o{ balance_snapshots : "tracks"
    accounts ||--o{ holdings : "contains"
    accounts ||--o{ transactions : "logs"

    institutions {
        uuid id PK
        string name
        string country
        string integration_type "Plaid, CSV, Manual"
    }

    accounts {
        uuid id PK
        uuid institution_id FK
        string name
        string type "Checking, Savings, Brokerage, etc."
        decimal current_balance
        string currency "USD, MXN"
    }

    balance_snapshots {
        uuid id PK
        uuid account_id FK
        decimal balance
        date as_of_date
        decimal balance_usd "Converted value"
    }

    transactions {
        uuid id PK
        uuid account_id FK
        date date
        decimal amount
        string description
        string category
    }
```

## Tables Overview

### `institutions`
Stores metadata for banks and financial entities. Includes Plaid-specific IDs for US banks.

### `accounts`
The core entity. Links to an institution and tracks the current "live" balance.

### `balance_snapshots`
Critical for historical net worth charts. A daily snapshot is taken for every account to track growth over time.

### `holdings`
Stores individual stocks, ETFs, or crypto assets within brokerage accounts.

### `exchange_rates`
A history of USD/MXN pairs to allow historical conversion of total net worth.

## Migrations
Migrations are managed via `sqlx` and run automatically on backend startup. They are located in `backend/migrations/`.
