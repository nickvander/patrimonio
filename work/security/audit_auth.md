# Patrimonio — Authentication & Account Security Audit

**Scope:** Password auth, sessions, TOTP, recovery codes, passkeys/WebAuthn, and the owner/read_only authorization model.
**Date:** 2026-05-30 · **Reviewer:** AppSec (read-only review) · **Standard:** 2026 best practices (OWASP ASVS 4/5, NIST SP 800-63B, FIDO2/WebAuthn L3)

---

## Executive summary

Overall posture is **strong** — well above what a typical self-hosted finance app ships. Argon2id parameters are sound, session tokens are CSPRNG-generated and stored hashed, cookies carry the correct flags, TOTP has real replay protection, passkeys verify sign-counts and use `excludeCredentials`, and every data query is scoped to `user_id`. Account-enumeration defenses on the password path are genuinely good (real dummy Argon2 verify + jitter). The code is heavily and accurately commented, and most "obvious" pitfalls have already been closed.

The findings below are mostly **hardening** opportunities. There are no Critical issues and no confirmed authentication bypass. The most material items are a **user-enumeration oracle on the passkey login-start endpoint** and a **dependency-version verification gap** worth confirming at build time.

**Count by severity:** Critical 0 · High 0 · Medium 3 · Low 5 · Info 4

---

## Findings table

| # | Title | Severity | Evidence | Status |
|---|-------|----------|----------|--------|
| 1 | Passkey `login/start` is a user-enumeration oracle | Medium | `api/passkeys.rs:324-364` | Confirmed |
| 2 | Recovery codes carry only ~60 bits and are SHA-256 (unsalted) single-hash | Medium | `services/recovery.rs:23-45` | Confirmed |
| 3 | Login rate-limiting is DB-audit-table backed, not atomic — race window + write-amplification under spray | Medium | `api/session.rs:1253-1302` | Confirmed |
| 4 | `recover` runs `enforce_password_policy` (network HIBP call) BEFORE the rate-limit check | Low | `api/session.rs:684-701` | Confirmed |
| 5 | Passkey `register/finish` does not verify user-verification (UV) flag / attestation | Low | `api/passkeys.rs:219-302` | Worth hardening |
| 6 | Recovery-code reset does not require nor reset the second factor | Low | `api/session.rs:684-763` | By design — note residual risk |
| 7 | Cookie is `SameSite=Lax`, not `Strict`; CSRF leans on a forgeable header | Low | `api/session.rs:1378`, `1106-1144` | Worth hardening |
| 8 | No upper bound on concurrent live sessions per user | Low | `services/sessions.rs:40-99` | Worth hardening |
| 9 | Argon2id `m=64MiB, t=3, p=1` — verify before relying on it | Info | `services/password.rs:11-15` | Done well (confirm) |
| 10 | Session tokens: 256-bit CSPRNG, stored SHA-256 hashed | Info | `services/sessions.rs:21-33` | Done well |
| 11 | TOTP replay marker (`totp_last_used_step`) is monotonic, single-use within window | Info | `services/totp.rs:114-197` | Done well |
| 12 | Dependency versions (argon2 0.5, webauthn-rs 0.5, axum 0.8) — confirm patched | Info | `Cargo.toml` | Verify |

---

## Detailed findings

### 1. Passkey `login/start` user-enumeration oracle — Medium
`api/passkeys.rs:324-364`. For an **existing, active user with ≥1 passkey**, the endpoint returns a real `RequestChallengeResponse` (HTTP 200). For a **nonexistent user, an inactive user, or a user with no passkeys**, it returns HTTP 401 `"No passkey registered for this account."`. The 200-vs-401 split (and the response shape) is a direct existence oracle — an attacker can enumerate which usernames are real and passkey-enabled. The password `/login` path goes to great lengths to avoid exactly this (dummy Argon2 verify + jitter, `api/session.rs:484-507`); the passkey path undoes that effort.

**2026 risk:** Username enumeration is an ASVS-flagged weakness; combined with the public `register` invite flow it lets an attacker map the user base and target phishing/credential-stuffing.

**Remediation:** Return a *synthetic* challenge (a well-formed `RequestChallengeResponse` seeded with a deterministic per-username decoy allow-list, e.g. HMAC(username) over a server secret) with HTTP 200 for unknown/passkey-less users, and converge the rejection at `login/finish` (which already returns a uniform `"Invalid passkey."`). Add the same `random_login_jitter()` on the failure path.

### 2. Recovery codes: ~60 bits, unsalted single SHA-256 — Medium
`services/recovery.rs:23-45`. Each code is 12 chars over a 32-char alphabet = **60 bits** (alphabet is exactly 32, so no modulo bias — verified). Codes are hashed with a single unsalted `SHA-256` (`hash_code`). 60 bits resists online guessing fine *given* a rate limiter, but: (a) the stored hash is fast/unsalted, so a DB leak makes the 8 codes per user trivially brute-forceable offline (no per-code work factor), and (b) `lookup_owner` does a direct hash-equality DB lookup — an attacker who exfiltrates `recovery_codes.code_hash` can reverse 60-bit codes on a GPU in seconds.

**2026 risk:** Recovery codes are a password-equivalent reset path. NIST/OWASP treat them as secrets warranting the same storage care as passwords.

**Remediation:** Either (a) raise entropy to ≥128 bits, **or** (b) store recovery codes under a slow KDF (Argon2id, same as passwords) rather than SHA-256.

### 3. Rate-limiting is `auth_audit`-table COUNT-based, not atomic — Medium
`api/session.rs:1253-1302`. `rate_limited` runs `SELECT COUNT(*) … WHERE occurred_at >= window` against `auth_audit`, then the failure is recorded by a *later* `record_audit` INSERT. Between the COUNT and the INSERT there is a TOCTOU window: many concurrent requests all read a count below threshold and all proceed. The per-IP and per-user counts are also two separate round-trips. Under a burst an attacker gets more than `THRESHOLD` Argon2 verifies through before the table catches up. The backoff sleep happens *only on the 429 path*, so pre-threshold concurrency is unthrottled.

**2026 risk:** Online brute-force / credential-stuffing throughput is higher than the "5/min" the comments claim under concurrency.

**Remediation:** Move the counter to Redis with an atomic `INCR`+`EXPIRE` (you already depend on Redis for sessions/WebAuthn/OAuth state), or a fixed/sliding-window limiter keyed on `(username, ip)`. Increment *before* the verify, not after.

### 4. `recover` does HIBP network call before rate-limit — Low
`api/session.rs:684-701`. `enforce_password_policy` (which performs the up-to-3s HIBP HTTP request) runs *before* `rate_limited`. An unauthenticated attacker can force an outbound HIBP request per call regardless of lockout — a minor SSRF-adjacent amplification / resource-exhaustion lever, and it lets the attacker measure policy responses without consuming the rate budget. **Remediation:** call `rate_limited` first, then validate the new password.

### 5. Passkey registration doesn't assert user-verification / attestation policy — Low
`api/passkeys.rs:204-230`. `start_passkey_registration` / `finish_passkey_registration` are used with library defaults; there is no explicit `UserVerificationPolicy::Required` and no attestation conveyance/verification. For a finance app, requiring UV (biometric/PIN) on registration and login is the FIDO2 L3 expectation. Sign-count clone-detection **is** handled correctly via `update_credential` (`passkeys.rs:457`) — good. **Remediation:** use the builder/`start_*` variants that pin `UserVerificationPolicy::Required`; decide whether you want attestation (most self-hosted setups accept `None`, which is fine, but make it explicit).

### 6. Recovery reset neither requires nor clears the second factor — Low (residual risk note)
`api/session.rs:684-763`. A recovery-code reset changes the password and revokes sessions but does **not** touch `totp_*` or passkeys. This is the *safe* default (an attacker with username+code still can't pass TOTP), so it is **correct** — flagged only so the team is aware that a user who loses both their password *and* their authenticator is locked out with no documented escape, and that the recovery code alone is a full password-reset primitive (see #2). No code change required.

### 7. `SameSite=Lax` + forgeable CSRF header — Low
`api/session.rs:1378` sets `SameSite=Lax`; CSRF defense-in-depth (`require_csrf_header`, `1106-1144`) requires a non-empty `X-Requested-With`. This is a reasonable belt-and-suspenders posture and the CORS layer correctly refuses `*` with credentials (`main.rs:283-321`). However Lax still permits cross-site **top-level GET** navigations to carry the cookie; ensure no state-changing GETs exist (they appear not to — `require_owner`/`require_csrf` both let GET through deliberately). **Remediation (optional):** move to `SameSite=Strict` for the session cookie; the app is a SPA on a single origin, so Strict has negligible UX cost and removes the need to trust the header.

### 8. No cap on live sessions per user — Low
`services/sessions.rs`. `create_session` has no ceiling; a successful-credential attacker (or a buggy client) can mint unbounded sessions. The 30-day sliding TTL means they linger. **Remediation:** cap to e.g. 20 active sessions, evicting oldest, and/or expose the count.

---

## Done well (do not touch)

- **Argon2id** with `m=64MiB, t=3, p=1` (`services/password.rs:11-15`) — comfortably above OWASP minimums; `verify_password` maps the wrong-password error correctly and only `Err`s on corrupt hashes.
- **Username-enumeration resistance on the password path** — real dummy Argon2 verify (`dummy_verify`, matching params) + 50–150 ms jitter on every failure branch (unknown user / inactive / bad password / bad TOTP). This is textbook and rare to see done right.
- **Session tokens**: 32 bytes (256 bits) from `OsRng`, base64url-encoded, only the **SHA-256 hash** is persisted; raw token never stored. Sliding 30-day TTL with throttled `last_seen_at` writes. Revocation, "sign out everywhere", per-id revoke (scoped to `user_id`), and session-fixation defense (revoke stale cookie on login) all present.
- **Pending-TOTP sessions** are a separate short-lived (5 min) cookie that `require_auth` refuses everywhere except `/totp/verify` — clean two-step design with no privilege leakage.
- **TOTP**: 160-bit secret, AES-256-GCM encrypted at rest, **monotonic replay marker** (`totp_last_used_step`) making a captured code single-use within its window; deliberate `verify_no_advance` for enrollment is well-reasoned. Disabling TOTP re-authenticates the password.
- **Passkey sign-count / clone detection** via `update_credential`; `excludeCredentials` populated; per-flow state encrypted in Redis with consume-on-use (`take_state` DELs); RP ID / origin derived from config with correct localhost handling.
- **Authorization**: `require_owner` gates all mutating methods on the business sub-router (`main.rs:182-184`); GET/HEAD/OPTIONS pass through so read-only users can read their own data. Every query inspected is scoped to `user_id` (sessions, passkeys, invites, recovery). Invite role is copied server-side and the user row is torn down on any failure — no privilege-escalation window. CORS refuses `*` with credentials.
- **Password change / recovery** both `revoke_all_for_user` afterwards.
- **Trusted-proxy XFF sanitization** (`main.rs:264-281`) strips client-set `X-Forwarded-For`/`X-Real-IP` unless the TCP peer is in `TRUSTED_PROXY_CIDRS` — closes rate-limit IP-spoofing.

---

## Verification notes
- Confirm patched releases at build: `argon2 0.5`, `webauthn-rs 0.5`, `axum 0.8`, `totp-rs 5.6`, `aes-gcm`, `redis 0.27`. Run `cargo audit` / `cargo deny` in CI (could not execute in this read-only pass).
- The `danger-allow-state-serialisation` feature on `webauthn-rs` is required for the Redis state design and is used correctly (state is encrypted at rest) — acceptable.
