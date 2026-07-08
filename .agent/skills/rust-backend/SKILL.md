---
name: rust-backend
description: >-
  Best practices for the patrimonio Rust backend (axum 0.8 + sqlx 0.8 Postgres +
  Redis). Use when writing or reviewing any backend/ code: API handlers, sqlx
  queries, money/FX math, balance-snapshot time series, auth/security middleware,
  or integration tests. Encodes the house conventions and the specific bug
  classes this codebase has been bitten by.
---

# patrimonio — Rust backend best practices

Self-hosted personal-finance app. Single binary. **axum 0.8 + sqlx 0.8 (Postgres) +
Redis + rust_decimal.** Every rule below is grounded in the actual codebase — follow
the existing pattern, don't import a different one from general Rust advice.

Cited anchors are `file:line` at time of writing; if a line has drifted, grep for the
named symbol.

> **General Rust conventions** (Fuchsia rubric, Rust API Guidelines, clippy) —
> no-unwrap/panic, newtypes, `as`-cast avoidance, async lock hygiene, etc. — live
> in the companion file [rust-conventions.md](rust-conventions.md). This SKILL.md
> covers project-specific rules; read both.

## The five things that have actually caused bugs here

Read these first — they are the recurring, expensive mistakes:

1. **Per-date `GROUP BY` on `balance_snapshots`** drops infrequently-synced accounts →
   phantom growth-from-zero (bit net-worth, portfolio-value, FBAR). Use carry-forward. (§3)
2. **Summing money across currencies without per-row FX** → ~18x overstatement on
   MXN portfolios. Convert every row to USD first. (§4)
3. **Writing a snapshot's native balance into `balance_usd`** → ~17x overstatement.
   FX-convert at write time. (§3)
4. **A test that skips when the DB is misconfigured** (not just unset) → the whole
   suite passes vacuously and ships real 500s. Fail loud on misconfig. (§6)
5. **Trusting a client-supplied user id / X-Forwarded-For.** Identity comes from
   `AuthContext`; XFF is stripped unless the peer is a trusted proxy. (§5)

## 1. Error handling

- **API handlers: return `Result<T, ApiError>`.** `ApiError` is the hand-written
  envelope in `src/api/session.rs` (`ApiError::new(status, msg)`, `impl IntoResponse`
  serializing `{ "error": message }`). This is the one and only error `IntoResponse`.
- **For 500s use the `internal(e)` helper** — it logs the real error via `tracing::error!`
  and returns a *generic* message. Never leak an internal error string on a 500.
  ```rust
  let rows = sqlx::query(SQL).bind(user_id).fetch_all(&state.db).await.map_err(internal)?;
  // client-caused failures get an explicit status + message:
  let dt = parse(&q.date).map_err(|e| ApiError::new(StatusCode::BAD_REQUEST, &e.to_string()))?;
  ```
- **Services / non-handler code: `anyhow::Result`** with `anyhow!` / `bail!`. Convert to
  `ApiError` at the handler boundary.
- **`thiserror` is in Cargo.toml but UNUSED.** Do not introduce a derived error enum
  expecting precedent — match the `ApiError` + `anyhow` pattern instead.
- **Two styles coexist; prefer the new one.** Older handlers return `impl IntoResponse`
  with bare `StatusCode::X.into_response()` — that loses the JSON `{error}` body and the
  central log. New handlers use `Result<_, ApiError>`.
- **Fail fast at boot.** `.expect()` / refuse-to-start on unrecoverable config (bad rp_id,
  missing key) is deliberate — see `main.rs`. Don't degrade silently at startup.

## 2. API handlers

- **Router per module.** Each `api/<x>.rs` exposes `pub fn router() -> Router<AppState>`,
  nested in `main.rs`. Auth modules split `public_router` / `protected_router` /
  `webhook_router`.
- **Extractor order is a convention — keep it:** `State`, then `Extension<AuthContext>`,
  then `Path` / `Query`, then `Json(payload)` **last**.
- **Declare static routes before `/{id}`** or the static segment gets swallowed as a path
  param. (`/archived`, `/batch`, etc. come before `/{id}`.) There are comments marking this;
  keep them.
- **DTOs are `snake_case`, no `rename_all`.** The JSON contract matches Rust field names 1:1.
  `#[derive(Serialize)]` / `#[derive(Deserialize)]` structs live next to their handler.
  `Decimal` for money fields, `date: String` (via `NaiveDate::to_string()`) for chart points.
- **Middleware stack order is load-bearing** and axum applies `.layer()` bottom-up (last =
  outermost): `require_csrf_header` (outer) → `require_auth` (populates `AuthContext`) →
  `require_owner` (inner, per business router). The `main.rs` comment explains it — don't
  reorder without understanding it.

## 3. Database access

- **Runtime sqlx only — never `query!` / `query_as!` macros.** This repo has no compile-time
  `DATABASE_URL` / no `.sqlx` offline cache to maintain. Use `sqlx::query(SQL).bind(...)`,
  read with `query_scalar` (single value), `query_as::<_, (T,)>` (tuple), or
  `row.try_get::<T, _>("col")` (manual).
- **Parameterize everything. Never interpolate request data into SQL.** The few
  `format!(...)`-into-SQL sites splice **static SQL constants** (e.g. `REALIZED_DISPOSALS_SQL`)
  and still `.bind()` every value. Composing static fragments is fine; user data is always a bind.
- **Every data query is scoped `WHERE user_id = $1`** using the `AuthContext` user id. This is
  the row-level isolation invariant (~159 sites). A query without it is a cross-tenant leak
  unless you can justify why.
- **Migrations:** additive-only `.sql` files in `backend/migrations/`, `YYYYMMDDNN_name.sql`.
  Applied at boot via `sqlx::migrate!("./migrations")` with `set_ignore_missing(true)` so an
  older binary can boot against a newer-migrated DB. Never edit a shipped migration; add a new one.

### Carry-forward: the balance_snapshots time-series pattern (MEMORIZE THIS)

Accounts snapshot on *different* days. A naive `GROUP BY as_of_date` SUM only covers accounts
that happened to snapshot that day, dropping infrequently-synced institutions and
misattributing them as growth-from-zero. This has bitten net-worth, portfolio-value, and FBAR.

**Pattern** (see `dashboard.rs::net_worth_history` / `portfolio_value_history`):

```rust
// SELECT per-account snapshot rows ORDER BY as_of_date ASC, id ASC
// carry each account's last-known value forward in Rust:
let mut carried: HashMap<Uuid, AcctState> = HashMap::new();
let mut cur: Option<NaiveDate> = None;
let flush = |day, carried: &HashMap<_, AcctState>, out: &mut Vec<_>| {
    // sum over ALL accounts seen so far, at their most-recent value
};
for r in &rows {
    if Some(r.as_of_date) != cur {
        if let Some(d) = cur { flush(d, &carried, &mut out); }
        cur = Some(r.as_of_date);
    }
    carried.insert(r.account_id, state_from(r)); // last row per (account,date) wins — id-ordered
}
if let Some(d) = cur { flush(d, &carried, &mut out); }
```

Rules:
- ORDER BY `as_of_date ASC, id ASC` so **the last row for an (account, date) wins** — don't
  double-count same-day duplicates.
- Flush on each date boundary summing over **every account seen so far**, not just today's.
- The same carry-forward reasoning applies to FBAR peak-balance (`services/tax.rs`).

### Writing snapshots: always FX-convert

The cron snapshot writer must compute `balance_usd` via FX conversion (`LEFT JOIN LATERAL` for
the latest USD↔MXN rate), never copy the native balance. `ON CONFLICT (account_id, as_of_date)
DO NOTHING`. Copying native balance turned a ~$890k MXN portfolio into a ~17x overstatement —
that comment is in `main.rs`; keep it.

## 4. Money & correctness

- **`rust_decimal::Decimal` is the money type** in models/services/tax. `f64` (`::float8`) is
  only for chart display values cast in SQL. `Decimal` serializes as a JSON number
  (`serde-float` feature). Use `dec!(...)`, `.round_dp(2)` for presentation.
- **USD conversion is a first-class invariant.** The canonical FX rule is the SQL-fragment
  constants in `services/tax.rs`: `USD_MXN_ROW_RATE_SQL` (latest rate on-or-before the tx date,
  else latest, else hard fallback `20.0`, with a `rate > 0` guard against divide-by-zero→NULL),
  and `AMOUNT_USD_SQL` (convert only when `currency = 'MXN'`; **treat every other currency as
  USD-equivalent, fx = 1** — "trust the native amount"). Applied via
  `CROSS JOIN LATERAL (SELECT {USD_MXN_ROW_RATE_SQL} AS rate) fx`.
- **Never sum raw amounts across currencies** without the per-row FX conversion — historical
  ~18x error. If you're about to write `SUM(amount)` over mixed-currency rows, stop.
- **FX rules are duplicated as SQL-string constants** across `tax.rs` and `sync.rs`. They must
  stay in sync by hand. **Grep for `USD_MXN` before touching any FX code** and update all copies.

## 5. Security (these are invariants, not suggestions)

- **Identity comes only from `Extension<AuthContext>`** (injected by `require_auth` after
  validating the session cookie). Never trust a user id from a request body/query. Read/write
  scoping is `WHERE user_id = $1` with the AuthContext id.
- **Authorization is two-tier.** Every mutating business route is `require_owner`-gated;
  read-only users get 403, not silent corruption. Use `AuthContext::is_owner()`.
- **CSRF:** `require_csrf_header` requires a non-empty `X-Requested-With` on
  POST/PUT/PATCH/DELETE. CORS allow-lists that header and **filters wildcard `*`** (credentialed
  cookies need a concrete origin + `allow_credentials(true)`).
- **Client IP / proxy:** `sanitize_forwarded_headers` strips `X-Forwarded-For` / `X-Real-IP`
  unless the TCP peer is in `TRUSTED_PROXY_CIDRS`. Don't read XFF directly — go through
  `client_ip()`. Requires `into_make_service_with_connect_info::<SocketAddr>()`.
- **Encryption:** AES-256-GCM for sensitive tokens (`services/encryption.rs`), 32-byte hex key
  from config, random 12-byte `OsRng` nonce per encrypt, nonce prepended to ciphertext. Key
  rotation is an offline transactional CLI that verifies every row re-decrypts before commit.
- **Secrets from env only** (`AppConfig::from_env()`), optional ones as `Option<String>`. Boot
  warns loudly on dev-default password / insecure cookie on a non-localhost origin. No secrets
  in code, ever. Break-glass admin actions are a separate CLI with no HTTP route.
- **Passwords:** Argon2 + local length/common-password list + HIBP k-anonymity (only the first 5
  SHA-1 hex chars leave the box; fail-open on network error). SHA-1 is a corpus index here, not a
  security primitive — don't repurpose it.
- **`.unwrap_or_default()` on a DB read swallows errors.** Fine for best-effort reads (audit
  counts, chart data); a trap on a query whose emptiness is semantically meaningful. Don't copy
  it onto such a query.

## 6. Testing

- **Integration tests in `backend/tests/`**, one file per surface, sharing `tests/common/mod.rs`.
  Build the **real** production middleware stack (CSRF + auth + owner) and drive it with
  `tower::ServiceExt::oneshot` — no network.
- **Real Postgres via `PATRIMONIO_TEST_DATABASE_URL`.** Setup does `TRUNCATE <all> RESTART
  IDENTITY CASCADE` then `sqlx::migrate!`.
- **Serialization is belt-and-suspenders:** `#[serial_test::serial]` on every `#[tokio::test]`
  (process-local) **plus** a cross-*binary* `pg_advisory_lock` held for the test's lifetime
  (coordinates across separate test binaries — `serial` alone doesn't).
- **Loud skip is a hard rule.** Skip *only* when the env var is **unset** (`try_setup` → `None`
  → print a note and `return`). If a URL **is** configured but the connection/auth fails,
  **panic** — do not skip. History: returning `None` on a bad password made "misconfigured" look
  like "no DB", the suite passed vacuously, and real SQL 500s shipped (FBAR + statement
  continuity). Same rule for the Redis test URL (`PATRIMONIO_TEST_REDIS_URL`): set-but-unreachable
  must panic, never silently pass. **Never conflate "misconfigured" with "not configured."**
- **Assertion style:** `assert_eq!(res.status(), StatusCode::X, "msg")`, then parse the body with
  the `body_json` helper and assert on JSON fields. Build requests through the shared `req(...)`
  helper — it auto-injects `X-Requested-With` on mutating methods so a test can't forget CSRF.
- **Add a regression test named after the fix** for every bug (see the FBAR / carry-forward
  tests). Reproduce the bug in the test first (it should fail pre-fix).

## 7. Comments & docs — the house style

Rich "why, not what" comments are a defining trait of this codebase; match the density.

- When you write non-obvious code — an ordering dependency, an FX/rounding rule, a security
  trade-off, a workaround for a specific bug — **leave a comment explaining the reasoning and
  the failure it prevents**, ideally with the concrete symptom ("...otherwise a ~$890k MXN
  portfolio lands as a ~17x overstatement").
- Annotate non-obvious dependencies in `Cargo.toml` with why they're there and which feature is
  needed (existing style).
- Use `///` doc-comments on structs/fns for invariants and simplifications. Flag unverified
  domain assumptions with a `⚠` marker.

## Definition of done (backend change)

- [ ] Handler returns `Result<_, ApiError>`; 500s go through `internal()` (logs, generic message).
- [ ] Every data query scoped `WHERE user_id = $1`; all user data is a `.bind()`, never interpolated.
- [ ] Any `balance_snapshots` time series uses carry-forward, not per-date GROUP BY.
- [ ] Any cross-currency math converts per-row to USD first; snapshot writes FX-convert `balance_usd`.
- [ ] Money is `Decimal`; presentation `.round_dp(2)`.
- [ ] New migration is additive; not editing a shipped one.
- [ ] Regression/integration test added, named after the fix; it fails before the change.
- [ ] `cargo test` (with `PATRIMONIO_TEST_DATABASE_URL` set) green; `cargo clippy` clean.
- [ ] Non-obvious code carries a "why" comment.
