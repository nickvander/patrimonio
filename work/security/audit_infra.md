# Patrimonio — Infrastructure / Container / Supply-Chain Security Audit

**Scope:** Docker & Compose, Postgres/Redis hardening, nginx, dependency/supply-chain,
CI, self-hosting posture. **Date:** 2026-05-30. **Mode:** read-only.
**Standard:** 2026 best practices.

## Executive summary

The dependency posture is genuinely strong: every security-relevant crate is on a
current, patched release (axum 0.8.8, sqlx 0.8.6, rustls 0.23.37, ring 0.17.14,
argon2 0.5.3, jsonwebtoken 9.3.1, webauthn-rs 0.5.5, hyper 1.8.1, idna 1.1.0,
totp-rs 5.7.1), the lockfile is committed, reqwest uses rustls (no native-tls), and
no secrets were ever committed to git. The bootstrap-no-default-credentials design
and the documented `POSTGRES_BIND=127.0.0.1` guidance are above average for a
self-hosted project.

The weaknesses are operational/runtime: a **world-readable `.env` holding live Plaid
production credentials and a static master encryption key**, containers that run as
**root with no capability/filesystem hardening**, **Redis with no authentication**, a
**compose default that binds Postgres/Redis to 0.0.0.0**, and missing healthchecks.
None are exploitable across the network *by themselves* on a single-host loopback
deploy, but they stack badly on any multi-tenant or LAN-exposed host.

## Severity counts

| Severity | Count |
|---|---|
| Critical | 1 |
| High | 3 |
| Medium | 5 |
| Low | 3 |
| Info | 2 |

## Findings

### CONFIRMED

| # | Title | Sev | Evidence |
|---|---|---|---|
| 1 | Live Plaid **production** secrets + static encryption key in world-readable `.env` | **Critical** | `.env:16-18` `PLAID_SECRET=efbb…`, `PLAID_ENV=production`; `.env:27` `ENCRYPTION_KEY=190ad3…` (32-byte hex). `stat` → `-rw-r--r--` (world-readable). This key encrypts Plaid access tokens at rest; anyone with read access to the host file (other local users, a backup, a leaked image layer) gets both the master key and the prod API credentials. |
| 2 | Containers run as **root**, no `cap_drop`, no `read_only`, no `no-new-privileges` | **High** | `backend/Dockerfile`, `frontend/Dockerfile`, `docker-compose.yml` — no `USER`, no `security_opt`, no `cap_drop`, no `read_only`. A backend RCE runs as uid 0 inside the container with full caps. |
| 3 | Postgres & Redis default-bound to `0.0.0.0` in compose | **High** | `docker-compose.yml:65` `${POSTGRES_BIND:-0.0.0.0}`, `:88` `${REDIS_BIND:-0.0.0.0}`. The *insecure* value is the compose default; only `.env.example` overrides to 127.0.0.1. A `docker compose up` with the shipped `.env` (or none) exposes DB/cache to the LAN. |
| 4 | Redis has **no authentication** | **High** | `docker-compose.yml:91` `command: redis-server --appendonly yes` — no `--requirepass`, no ACL, protected-mode bypassed by the published port. Combined with #3, Redis (which stores WebAuthn/passkey ceremony state and sessions) is reachable + unauthenticated on the LAN. |
| 5 | No healthcheck on api / redis / frontend | **Medium** | `docker-compose.yml` — only postgres (`:76`) has a healthcheck. `depends_on: redis: condition: service_started` waits for the process, not readiness. |
| 6 | CI actions pinned by **mutable tag**, not SHA | **Medium** | `.github/workflows/docs.yml:17,18` `actions/checkout@v4`, `actions/setup-python@v5`; `:21` `pip install mkdocs-material` (unpinned). `permissions: contents: write` + tag-pinned third-party actions = supply-chain tampering window. Pin to commit SHA and pin pip version. |
| 7 | CSP allows `unsafe-inline` + `unsafe-eval` and broad `connect-src https:` | **Medium** | `frontend/security_headers.conf:30`. Flutter/canvaskit force `unsafe-eval`/`wasm-unsafe-eval`, but `connect-src … https: wss:` lets the SPA call *any* HTTPS host — defeats CSP exfil protection. No `frame-ancestors` (relies on X-Frame-Options only). |
| 8 | No TLS / HTTP-to-HTTPS redirect in shipped nginx | **Medium** | `frontend/nginx.conf:2` `listen 80;` only. HSTS is emitted but the app serves plain HTTP; relies on an undocumented external TLS proxy. Session cookie defaults `COOKIE_SECURE=false` in compose (`docker-compose.yml:47`). |
| 9 | `qpdf` + `lopdf` PDF toolchain in runtime image | **Medium** | `backend/Dockerfile:36` installs `qpdf`; `Cargo.toml:102` `lopdf 0.34`. PDF parsing on user-supplied files is historically a memory-safety/exploit surface; mitigated only by the (absent) container sandboxing of #2. |

### HARDEN / LOWER

| # | Title | Sev | Evidence |
|---|---|---|---|
| 10 | Base images pinned by floating tag | **Low** | `postgres:17-alpine`, `redis:7-alpine`, `nginx:1.27-alpine`, `rust:1.88-slim`, `debian:bookworm-slim`, `ghcr.io/cirruslabs/flutter:stable`. No digest pinning → non-reproducible builds; `:stable` floats hardest. |
| 11 | `restart: unless-stopped` missing on postgres/redis | **Low** | `docker-compose.yml` — frontend/api have it; the stateful services don't. A crashed DB stays down. |
| 12 | `extra_hosts: host.docker.internal:host-gateway` routes api traffic over the host | **Low** | `docker-compose.yml:21-22,29-30`. API reaches DB/Redis via the *host* loopback port instead of an internal compose network, which is why #3 must publish the ports at all. A dedicated internal network removes the need to expose DB/Redis entirely. |
| 13 | No supply-chain scanning in CI | **Info** | No `cargo audit`/`cargo deny`/`flutter pub outdated` or Dependabot. `cargo`/`cargo audit`/`cargo outdated` are not installed locally either (verified `cargo --version` → 127), so version review was done from the committed lockfile. |
| 14 | Privacy posture vs reality | **Info** | README markets self-hosting/anti-default-credential stance; backend makes outbound calls to `api.coinbase.com`, `api.bitso.com`, `open.er-api.com`, `cdn.plaid.com`, `api.pwnedpasswords.com`. All are opt-in/k-anonymised (HIBP) or feature-gated — consistent with the docs, worth documenting explicitly for an air-gap deployer. |

## Done well

- All security-critical crates on current patched versions; `Cargo.lock` committed; reqwest on rustls (no OpenSSL TLS path — `openssl` is only a transitive build artifact, the sole src reference is a help string in `config.rs:64`).
- No secrets in git history (`git log -S` on the live secret/key → empty); `.env` correctly gitignored.
- Bootstrap flow ships **no default credentials**; postgres password defaulting to `patrimonio` triggers a loud boot warning.
- Multi-stage builds with dependency-cache layering; binary sanity assertion in the build.
- Solid baseline security headers (X-Content-Type-Options, X-Frame-Options DENY, Referrer-Policy, HSTS) reliably `include`d into every nginx location (the add_header-inheritance footgun is handled).
- Postgres healthcheck with `depends_on: condition: service_healthy`.
- Thoughtful inline docs explaining the bind/secure-cookie trade-offs.

## Single most urgent fix

**Rotate and re-secure the Plaid production secret and `ENCRYPTION_KEY` now.** Treat
the values in the on-disk `.env` (world-readable, `PLAID_ENV=production`) as
compromised: revoke/rotate the Plaid secret in the dashboard, rotate the encryption
key via the shipped `rotate_encryption_key` tool, move secrets to Docker/file-based
secrets (or at minimum `chmod 600 .env`), and keep `PLAID_ENV=sandbox` on any non-prod host.
