---
name: backend-dev
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

2. Write the handler function — follow the **rust-backend skill** (ApiError,
   `internal()`, user scoping); extractor order is State → Extension → Path/Query
   → Json last:
   ```rust
   async fn my_handler(
       State(state): State<AppState>,
       Extension(ctx): Extension<AuthContext>,
   ) -> Result<Json<MyResponse>, ApiError> {
       let rows = sqlx::query("SELECT ... WHERE user_id = $1")
           .bind(ctx.user_id)
           .fetch_all(&state.db)
           .await
           .map_err(internal)?;
       Ok(Json(/* map rows to response */))
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

5. Rebuild and restart (no Docker on the dev VM): `cd backend && cargo build`,
   then `pkill -x patrimonio` and relaunch `./target/debug/patrimonio`
   (see the dev-workflow skill)

## IMPORTANT: SQL query rules
- **Always use `sqlx::query()` (runtime)** — never `sqlx::query!()` (compile-time macro)
- Prod Docker builds set `SQLX_OFFLINE=true` and there's no `.sqlx/` cache
- Use `sqlx::Row` trait with `.get()` / `.try_get()` for column extraction
- Use `.bind()` for parameterized queries

## Adding a new database table

1. Create a new migration file:
   ```
   backend/migrations/YYYYMMDDNN_description.sql
   ```
   Date + 2-digit sequence prefix, current style (e.g.,
   `2026070701_asset_class_overrides.sql`). Additive only — never edit a
   shipped migration.

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

5. Migrations run automatically on startup — just rebuild and restart the backend binary

## Adding a new service

1. Create the service file in `backend/src/services/`
2. Register it in `backend/src/services/mod.rs`
3. Services receive `&PgPool` and return `Result<T>`
4. Use `tracing::info!` for logging
