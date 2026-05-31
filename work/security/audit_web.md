# Patrimonio — Web / HTTP / API Security Audit

**Scope:** CORS, CSRF, security headers, cookies, input validation / injection / SSRF, webhooks, trusted-proxy / client-IP, rate-limiting / DoS.
**Date:** 2026-05-30 · **Standard:** 2026 best practices · **Mode:** read-only.

---

## Executive summary

The web/HTTP attack surface is, for a self-hosted app, **well above average**. The team has clearly thought about CSRF (SameSite=Lax + custom-header defence-in-depth), session fixation, login timing oracles, exponential backoff, Plaid webhook ES256 verification with body-hash binding and replay window, OAuth CSRF state in Redis, and trusted-proxy XFF stripping. SQL is uniformly parameterised via sqlx — **no injection found**. Outbound HTTP uses hardcoded hostnames — **no classic SSRF found**.

The findings below are mostly **hardening** items plus a few **deployment-posture** issues that bite a real internet-facing install. The single most consequential structural fact is that the **API is served cross-origin on its own port with no TLS-terminating reverse proxy in the shipped topology** — so the carefully-written nginx security headers (CSP, HSTS, frame options) apply only to the static frontend and **never** to API responses, and the backend emits none of its own. None of this is exploitable in isolation, but several combine into real risk on a careless production deploy.

### Severity counts
| Severity | Count |
|---|---|
| Critical | 0 |
| High | 2 |
| Medium | 5 |
| Low | 4 |
| Info | 3 |

---

## Findings

### CONFIRMED

| # | Title | Severity | Evidence | Risk (2026) | Remediation |
|---|---|---|---|---|---|
| W1 | **No reverse proxy / TLS in shipped topology; API exposed cross-origin on 0.0.0.0:8080 with no security headers** | High | `docker-compose.yml:19-20` (`API_PORT:8080` → `0.0.0.0`); `frontend/nginx.conf` has **no `location /api` `proxy_pass`** — frontend (`:3000`) and API (`:8080`) are distinct origins, which is why CORS+credentials is needed at all. Security headers live only in `frontend/security_headers.conf`, served by nginx for the SPA; the axum app sets **no** response security headers. | API JSON responses ship with no `X-Content-Type-Options`, no HSTS, no CSP, no `Cache-Control`. A MitM on the (likely plaintext in dev-default) API origin can strip/alter responses; sensitive JSON (recovery codes, session lists) is cacheable by intermediaries. The shipped compose has no path to HTTPS, so an operator who "just runs it" exposes the session cookie and credentials in cleartext. | Front the API behind the same TLS reverse proxy as the SPA, ideally under a single origin (`/api` → backend) so CORS+credentials can be dropped entirely and the nginx header set covers API responses too. At minimum add an axum middleware emitting `X-Content-Type-Options: nosniff`, `Cache-Control: no-store` on auth/sensitive responses, and HSTS. Ship a production compose with TLS. |
| W2 | **Postgres and Redis default-bind to 0.0.0.0** | High | `docker-compose.yml:65` (`POSTGRES_BIND:-0.0.0.0`), `:88` (`REDIS_BIND:-0.0.0.0`). Postgres default password is also `patrimonio` (`:72`). | Default install publishes Postgres (5433) and an **unauthenticated** Redis (6380) on every host interface. Redis with no `requirepass` reachable from the internet is a well-known full-host-compromise vector (RCE via module/`CONFIG SET dir`). The DB carries a guessable default password. The comments acknowledge this but the *default* is the dangerous one. | Default `POSTGRES_BIND`/`REDIS_BIND` to `127.0.0.1`, or drop host port mappings entirely and use the docker network. Set a Redis password. Keep the existing boot warning for the default DB password but consider refusing to start in non-dev. |
| W3 | **No global request-body size limit on JSON routes** | Medium | `main.rs:224-238` — no `DefaultBodyLimit` layer on the app router. Only the upload route sets one, and it *raises* it to 100 MB (`api/imports.rs:38`). axum's 2 MB default applies per-extractor but there is no app-wide cap, and the 100 MB upload cap is generous. | An authenticated (or, on public routes, unauthenticated) client can POST large bodies to inflate memory/CPU. The 100 MB multipart cap × concurrent uploads is a memory-exhaustion DoS on a single-instance deployment. | Add an app-wide `DefaultBodyLimit` (e.g. 256 KB) on `main.rs` and only raise it on the upload route. Reconsider the 100 MB upload ceiling; stream-parse if large files are genuinely needed. |
| W4 | **CSP `connect-src`/`img-src` allow blanket `https:` and `wss:`** | Medium | `frontend/security_headers.conf:30` — `connect-src 'self' http://localhost:8080 http://127.0.0.1:8080 https: wss:; img-src 'self' data: blob: https:`. | A blanket `https:`/`wss:` in `connect-src` defeats most of the value of CSP as an exfiltration control: if any XSS slips past (and `script-src` already includes `'unsafe-inline' 'unsafe-eval'` — see W5), data can be POSTed to any HTTPS host. `img-src https:` similarly allows pixel-based exfiltration. | Pin `connect-src` to the actual API origin(s), Plaid, Coinbase, Bitso, gstatic, HIBP — not blanket `https:`. Same for `img-src`. The `http://localhost:8080` literals should be templated out of production builds. |
| W5 | **CSP `script-src` includes `'unsafe-inline' 'unsafe-eval'`** | Medium | `frontend/security_headers.conf:30`. | Flutter web + canvaskit genuinely require `unsafe-eval`/`wasm-unsafe-eval`, and the bootstrap shim needs `unsafe-inline`. This is largely unavoidable for Flutter today, but it means CSP provides **no XSS mitigation** for script injection. Combined with W4's permissive `connect-src`, an injected script has a clear exfil path. | Document the Flutter constraint (already partly done). Tighten what you *can*: drop `unsafe-inline` for scripts in favour of a nonce/hash on the single bootstrap inline block if the Flutter build allows it; this is improving in recent Flutter releases. Compensate by tightening `connect-src` (W4). |
| W6 | **Missing `Permissions-Policy` and CSP `frame-ancestors`** | Medium | `frontend/security_headers.conf` sets `X-Frame-Options: DENY` but no `Permissions-Policy` and no CSP `frame-ancestors 'none'`. | `Permissions-Policy` is the 2026-expected control to disable geolocation/camera/mic/USB/etc.; its absence is a hardening gap. `X-Frame-Options` is legacy; modern guidance is to *also* set `frame-ancestors 'none'` in CSP (XFO is ignored by some contexts and not extensible). | Add `Permissions-Policy: geolocation=(), camera=(), microphone=(), usb=(), payment=()` (allow only what's used) and `frame-ancestors 'none'` to the CSP. |
| W7 | **`client_ip()` trusts XFF/X-Real-IP without re-checking trust at use-site** | Medium | `api/session.rs:1352-1368` reads `x-forwarded-for`/`x-real-ip` unconditionally. Safety depends entirely on `sanitize_forwarded_headers` (`main.rs:264-281`) having stripped them for untrusted peers — which it does. **But** rate-limit keying (`rate_limited`, `:1253`) and audit logging rely on this. | Defence is correct *only if* `TRUSTED_PROXY_CIDRS` is set correctly. The shipped compose default is **empty** (`docker-compose.yml:35`), meaning XFF is always stripped and per-IP rate limiting falls back to `None` (no IP limiting) for every request — including behind a legitimate proxy that the operator forgot to configure. So in the default deployment, the **per-IP brute-force limit silently does not apply**; only the per-username limit does. | Document loudly that `TRUSTED_PROXY_CIDRS` MUST be set when behind a proxy, and warn at boot if XFF headers are observed from peers while the trusted list is empty. Consider falling back to the TCP peer IP (`ConnectInfo`) for rate-limit keying when no trusted XFF is present, so per-IP limiting still works without a proxy. |
| W8 | **Coinbase `state` token compared non-constant-time; OAuth `error`/`msg` reflected into redirect** | Low | `api/auth.rs:97-111` compares the Redis-stored state by equality lookup (fine — keyed by the token), but the upstream `query.error` is reflected into the frontend redirect via `frontend_redirect(..., Some(detail))` (`:123`, `:255-262`). `query_escape` percent-encodes, so it's not an open-redirect/XSS, but attacker-influenced text lands in the URL the user sees. | Low — `query_escape` neutralises injection and the redirect host is fixed to `frontend_base_url`. Worth noting the reflected error string is attacker-controllable (Coinbase echoes arbitrary `error`). | Map upstream errors to a fixed allow-list of messages rather than reflecting `query.error` verbatim. |
| W9 | **Health endpoint is public and unauthenticated, reveals DB status** | Low | `main.rs:133-134`, `health()` `:324-334` returns `{status, database}`. | Minor info disclosure (DB up/down) to anonymous internet callers; also a cheap unauthenticated query (`SELECT 1`) per hit — trivial amplification if hammered. | Acceptable for a liveness probe; optionally restrict to the proxy/loopback or drop the DB field from the public variant. |

### HARDEN (defence-in-depth / posture)

| # | Title | Severity | Evidence | Note |
|---|---|---|---|---|
| W10 | **CSRF defence rests on `X-Requested-With` non-empty + CORS** | Low | `api/session.rs:1121-1144`. Any non-empty value passes. | This is sound for 2026 (custom header forces a preflight; CORS rejects unknown origins; cookie is `SameSite=Lax`). It is *defence-in-depth*, and correctly so. Keep it. Only caveat: it depends on the CORS layer never being misconfigured to reflect arbitrary origins — see W12. The check itself is fine; no token rotation needed given SameSite+CORS. |
| W11 | **Session cookie does not use `__Host-` prefix** | Low | `api/session.rs:1370-1383` — `Secure` (conditional), `HttpOnly`, `SameSite=Lax`, `Path=/`, no `Domain`. | The cookie already satisfies the `__Host-` requirements (Path=/, no Domain, Secure in prod). Renaming `COOKIE_NAME` to a `__Host-`-prefixed name would let the browser enforce those invariants and block subdomain cookie-injection. Low value here since it's cross-origin to a fixed host, but cheap. |
| W12 | **CORS origin list parsed from a comma-string; `*` filtered but no validation of scheme/host** | Info | `main.rs:283-321`, `config.rs:70-76`. `allow_credentials(true)` + explicit origin list is correct (no wildcard-with-credentials footgun). `*` entries are dropped. | Done well. Note: `AllowOrigin::list` does exact-match, so there's no reflective-origin bug. Just ensure operators never put a user-controlled value in `ALLOWED_ORIGINS`. |
| W13 | **`RUST_LOG=debug` warning is advisory only** | Info | `docker-compose.yml:48-51`, `main.rs:28-29` default is `debug`. | The compose default is `info` (good) but the in-code fallback when `RUST_LOG` is unset is `patrimonio=debug,tower_http=debug`, which can log request metadata. Make the code default `info`. |
| W14 | **Plaid webhook key fetch has no timeout** | Info | `services/plaid_webhook_verify.rs:175` uses a bare `reqwest::Client::new()` with no `.timeout()`. | A slow/hung Plaid key endpoint stalls the webhook handler task. HIBP (`password.rs:127`) correctly sets a 3 s timeout — mirror that here. |

---

## Done well (call-outs)

- **SQL injection:** none — all queries parameterised via sqlx bind params, including dynamic lookups (`session.rs`, `invites.rs`, `auth.rs`).
- **SSRF:** outbound calls (Coinbase, Bitso, ExchangeRate, crypto price) use **hardcoded hostnames**; only `plaid_env` interpolates into `https://{env}.plaid.com` and HIBP base is operator-config (not request-controlled). No user-controlled outbound host.
- **Plaid webhook verification** (`plaid_webhook_verify.rs`): enforces `alg == ES256` (blocks alg-confusion), `iat` freshness window (replay), and binds the signature to the **raw body SHA-256** read as `Bytes` before JSON parse — textbook-correct, including constant-time hash compare.
- **OAuth CSRF:** per-user `state` in Redis, consumed-on-read (replay-proof), refuses to start if Redis is down (`auth.rs:31-68`).
- **Auth hardening:** Argon2 with `dummy_verify` to close the username-enumeration timing oracle, login jitter, per-user + per-IP exponential backoff, session fixation defence (revoke stale cookie on login), full-logout on password change/recovery, session-id enumeration treated as no-op.
- **Trusted-proxy XFF stripping at the edge** (`main.rs:264-281`) — the right architecture; just needs the config caveat in W7.
- **Cookies:** `HttpOnly` + `SameSite=Lax` always; `Secure` auto-on for https origins with a boot warning when misconfigured.
- **Secure-by-default config:** `COOKIE_SECURE` defaults true; loud boot warnings for dev-default DB password and insecure cookie config.

---

## Top priority

**W1 + W2 together** — the shipped deployment topology (API on its own plaintext port bound to 0.0.0.0, no TLS proxy, no security headers on API responses; Postgres + unauthenticated Redis bound to 0.0.0.0 by default) is the highest-impact issue. The application-layer code is solid; the production posture is what will get a self-hoster compromised.
