# Backend Deep Dive

The Patrimonio backend is built with **Rust** using the **Axum** framework. It is designed to be safe, fast, and maintainable.

## Project Structure

- `backend/src/api/`: Axum handlers and route definitions.
- `backend/src/services/`: Core logic (Plaid sync, FX rates, projections, encryption).
- `backend/src/models/`: SQLx models and data structures.
- `backend/src/services/parser/`: Dedicated logic for statement parsing.
- `backend/migrations/`: SQL migration files.

## Core Services

### Exchange Rate Service
Handles real-time and historical currency conversion between USD and MXN.
- **Cache Strategy**: Latest rates are stored in Redis with a TTL of 1 hour to minimize API calls.

### Sync Engine
Manages the complexity of Plaid's account, transaction, and holding sync logs.
- **Queueing**: While not yet heavy, it is structured to support background processing of large transaction histories.

### Encryption Service
Uses AES-256-GCM to encrypt sensitive Plaid Access Tokens before storing them in the database.

## API Documentation
The API adheres to RESTful principles. Key nests include:
- `/api/accounts`: Account management and summaries.
- `/api/fx`: Currency conversion utilities.
- `/api/dashboard`: Aggregated data for the UI widgets.
- `/api/imports`: File upload and parsing.

## Development Workflows
To add a new endpoint, follow the instructions in the [Developer Guide](https://github.com/your-username/patrimonio#backend-rust).
