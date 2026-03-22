---
description: How to add new API endpoints, database tables, and services to the Patrimonio backend
---

# Backend Development

## Adding a new API endpoint

1. Choose the right module in `backend/src/api/`:
   - `accounts.rs` — account-related endpoints
   - `institutions.rs` — institution management
   - `exchange_rates.rs` — FX rates
   - `dashboard.rs` — aggregated dashboard data
   - Or create a new module and register it in `api/mod.rs`

2. Write the handler function:
   ```rust
   async fn my_handler(State(state): State<AppState>) -> Json<MyResponse> {
       let rows = sqlx::query("SELECT ...")
           .fetch_all(&state.db)
           .await
           .unwrap_or_default();
       Json(/* map rows to response */)
   }
   ```

3. Register the route in the module's `router()` function:
   ```rust
   pub fn router() -> Router<AppState> {
       Router::new()
           .route("/my-endpoint", get(my_handler))
   }
   ```

4. If it's a new module, add it to `main.rs`:
   ```rust
   .nest("/api/my-module", api::my_module::router())
   ```

5. Rebuild: `docker compose up --build -d api`

## IMPORTANT: SQL query rules
- **Always use `sqlx::query()` (runtime)** — never `sqlx::query!()` (compile-time macro)
- Docker builds set `SQLX_OFFLINE=true` and there's no `.sqlx/` cache
- Use `sqlx::Row` trait with `.get()` / `.try_get()` for column extraction
- Use `.bind()` for parameterized queries

## Adding a new database table

1. Create a new migration file:
   ```
   backend/migrations/YYYYMMDD_NNN_description.sql
   ```
   Use the date prefix format (e.g., `20260323_002_add_budgets.sql`)

2. Write the SQL (CREATE TABLE, indexes, etc.)

3. Add a model struct in `backend/src/models/`:
   ```rust
   #[derive(Debug, Clone, Serialize, Deserialize, FromRow)]
   pub struct MyModel {
       pub id: Uuid,
       // ...
   }
   ```

4. Register the model module in `backend/src/models/mod.rs`

5. Migrations run automatically on startup — just rebuild the API container

## Adding a new service

1. Create the service file in `backend/src/services/`
2. Register it in `backend/src/services/mod.rs`
3. Services receive `&PgPool` and return `Result<T>`
4. Use `tracing::info!` for logging
