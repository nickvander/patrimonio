# Patrimonio — Security Audit: Data Security, Secrets & Cryptography

**Auditor:** Senior AppSec (read-only review)
**Date:** 2026-05-30
**Scope:** SQL injection / query safety, encryption at rest, secrets management, PII handling, backups, randomness.
**Standard:** 2026 best practices (OWASP ASVS 5.x, NIST SP 800-63B / 800-38D).

---

## Executive summary

The data-security posture of Patrimonio is **strong**. Cryptographic primitives are modern and correctly applied: AES-256-GCM (AEAD) for secrets at rest, Argon2id for passwords, `OsRng` (CSPRNG) for every nonce/token/salt, and a documented, separately-keyed encrypted backup (GPG AES-256) with a restore drill. SQL is **fully parameterized** — every `sqlx::query` binds user input; the handful of `format!`-built statements interpolate only compile-time constants (column/table names, an aggregate SELECT-list), never request data. There is **no SQL injection** in scope.

The findings are mostly hardening items. The one CONFIRMED issue with real exposure is a secret-leak-to-logs path on the Coinbase OAuth error branch. Two further items concern key-management depth (no envelope/KMS, key lives in `.env`) and transport hardening for the data stores. None are exploitable by a remote unauthenticated attacker on a correctly-deployed instance.

### Severity counts
| Severity | Count |
|---|---|
| Critical | 0 |
| High | 0 |
| Medium | 3 |
| Low | 3 |
| Info | 2 |

---

## Findings

| # | Title | Severity | Location | Status |
|---|---|---|---|---|
| 1 | Coinbase OAuth response (incl. access_token) logged on refresh-token-missing branch | Medium | `api/auth.rs:177` | CONFIRMED |
| 2 | Internal error strings returned to client in `details` field | Medium | `api/institutions.rs:73,114,423` | CONFIRMED |
| 3 | Encryption key stored in plaintext `.env`; no envelope encryption / KMS | Medium | `config.rs:60`, deployment | Harden |
| 4 | AES-GCM nonce is random 96-bit with no rotation/counter guard | Low | `services/encryption.rs:17-19` | Harden |
| 5 | Redis has no `requirepass` and no TLS; Postgres URL has no `sslmode` | Low | `docker-compose.yml`, `.env.example` | Harden |
| 6 | GPG backup uses default s2k KDF (SHA-1 based) | Low | `scripts/backup.sh:93-95` | Harden |
| 7 | Plaid/Coinbase error responses logged with `{:?}` (metadata leak) | Info | `api/institutions.rs:280,420`, `api/auth.rs:170` | Harden |
| 8 | No automatic key-rotation schedule (rotation is manual/one-shot) | Info | `bin/rotate_encryption_key.rs` | Info |

---

### 1. Coinbase OAuth response logged with access_token present — Medium — CONFIRMED
`api/auth.rs:177`: `tracing::error!("Coinbase OAuth response missing refresh_token: {:?}", tokens);`
This branch fires when `refresh_token` is absent but `access_token` is **still present** in `tokens`, so a live, usable Coinbase access token is written to stdout/log aggregation. (The sibling branch at :170 fires only when `access_token` itself is missing, so it is benign by construction.)
**2026 risk:** Long-lived API credentials in logs are a top breach vector; log stores are routinely shipped to third-party SaaS with broader access than the DB.
**Remediation:** Log only the set of present keys, never the value — e.g. `tokens.as_object().map(|o| o.keys().collect::<Vec<_>>())`. Apply the same to any `{:?}` over a token-bearing struct.

### 2. Internal error strings echoed to the client — Medium — CONFIRMED
`api/institutions.rs:73` and `:114` return `"details": e.to_string()` from a failed sync; `:423` returns `res.to_string()` (the raw Plaid response body) to the caller. These reach the browser.
**2026 risk:** `e.to_string()` on a sqlx/anyhow error can expose SQL fragments, column names, connection details, or upstream API internals — aids reconnaissance. Returning the raw Plaid body may surface item metadata.
**Remediation:** Return a stable generic message + a correlation id; keep the detailed error server-side via `tracing`. The helper `json_error(...)` at `institutions.rs:790` already does this — route the other sites through it.

### 3. Encryption key in plaintext `.env`, no envelope/KMS — Medium — Harden
`ENCRYPTION_KEY` is read directly from the environment (`config.rs:60`) and lives in `.env` on the host. A single 32-byte key directly encrypts all Plaid/Coinbase tokens and TOTP secrets; anyone who reads `.env` (host compromise, errant backup, `docker inspect`) decrypts everything.
**2026 risk:** No envelope encryption means no per-record DEKs and no break-glass revocation short of full rotation; the key also sits in process memory and `/proc/<pid>/environ`.
**Remediation (defense-in-depth):** Move to a KMS-wrapped data-encryption-key (envelope) model where feasible, or at minimum a file-based secret with `0600` perms loaded via systemd `LoadCredential`/Docker secret rather than a plain env var. Document that `.env` must be `chmod 600` and excluded from backups bundled with the DB dump (it already warns about co-locating in `operations.md`).

### 4. Random 96-bit GCM nonce without rotation guard — Low — Harden
`services/encryption.rs:17-19` generates a fresh random 12-byte nonce per encryption with `OsRng` — correct and the standard pattern. The theoretical concern is GCM's birthday bound (~2^32 messages under one key before random-nonce collision probability becomes non-negligible). At this app's scale (hundreds of institutions/secrets) it is nowhere near the bound, so this is informational-grade.
**Remediation (optional):** Consider XChaCha20-Poly1305 (192-bit nonce, eliminates the birthday concern) or a deterministic nonce scheme, and ensure rotation cadence stays well below 2^32 encryptions per key. No action needed at current scale.

### 5. Redis no auth/TLS; Postgres no sslmode — Low — Harden
`docker-compose.yml` starts Redis with `redis-server --appendonly yes` (no `requirepass`, no TLS) and the Postgres `DATABASE_URL` carries no `sslmode`. Ports default-bind `0.0.0.0` on the host (the file documents the `*_BIND=127.0.0.1` override and warns about it).
**2026 risk:** Redis holds session/CSRF/passkey flow state; an unauthenticated Redis reachable on the LAN is session-hijack territory. Cleartext intra-host traffic is lower risk on a single box but fails defense-in-depth.
**Remediation:** Set a Redis password (`--requirepass`, `rediss://` if remote), append `?sslmode=require` to a non-loopback `DATABASE_URL`, and instruct prod to set `POSTGRES_BIND=127.0.0.1`/`REDIS_BIND=127.0.0.1` (already documented — consider defaulting to loopback).

### 6. GPG backup uses default s2k KDF — Low — Harden
`scripts/backup.sh:93-95` uses `--symmetric --cipher-algo AES256` but leaves GPG's default string-to-key (SHA-1-based s2k). The data cipher (AES-256) is strong; the KDF protecting the passphrase is dated.
**Remediation:** Add `--s2k-mode 3 --s2k-digest-algo SHA512 --s2k-count 65011712` (or move to `age`). Low priority because the documented passphrase is high-entropy (`openssl rand`), which dominates s2k weakness.

### 7. Plaid/Coinbase responses logged with `{:?}` — Info — Harden
`institutions.rs:280,420` and `auth.rs:170` log full upstream responses on error paths. On these specific branches the token field is absent (that's why the branch fired), so no secret leaks today — but it's fragile (see finding #1 for the counter-example). Prefer structured, field-allowlisted logging.

### 8. Key rotation is manual one-shot — Info
`bin/rotate_encryption_key.rs` is well-built: single transaction, per-row NEW-key round-trip self-check, refuses no-op rotation, validates key lengths, auto-discovers `*_enc` columns. There is no scheduled rotation. Document an annual rotation cadence in the runbook.

---

## Done well (keep doing this)

- **AEAD done right:** AES-256-GCM via the `aes-gcm` crate; nonce prepended to ciphertext, key-length validated (`encryption.rs`), authentication tag verified on decrypt. No ECB/CBC, no homegrown crypto.
- **No SQL injection:** every `sqlx::query*` binds parameters; the only `format!`-built SQL (`loans.rs:323/425` using the `LOAN_AGGREGATES` const, and `rotate_encryption_key.rs` with static table/column names) interpolates compile-time constants only — never request data. No `QueryBuilder`/`push_bind` concatenation of user input anywhere.
- **CSPRNG everywhere:** `OsRng` for GCM nonces, OAuth state, session ids, invite tokens, recovery codes, TOTP secrets, passkey challenges, Argon2 salts. The single `thread_rng` use is a non-security login-timing jitter.
- **Password storage:** Argon2id, m=64 MiB / t=3 / p=1 (above OWASP 2024 minimum), per-hash random salt; constant-time verify; `dummy_verify` + random jitter to close username-enumeration timing/throughput oracles (`password.rs`); HIBP k-anonymity breach check.
- **Key-rotation tooling:** transactional, self-checking, fail-safe (finding #8).
- **Backups:** encrypted (GPG AES-256), passphrase kept **separate** from `ENCRYPTION_KEY` and in a different location, integrity check on dump size, retention control, documented restore drill (`operations.md`, `scripts/restore.sh`).
- **Secrets hygiene in VCS:** `.env` gitignored; only `.env.example` is tracked and every secret field is blank. Git history scan found no committed keys/passwords. Loud boot warning when the dev-default DB password is in use (`main.rs:43`).
- **Config safety:** `RUST_LOG` defaults to `info` with an inline comment warning that `debug` can capture auth headers; CORS rejects wildcard with credentials; secure-by-default cookie flag.
