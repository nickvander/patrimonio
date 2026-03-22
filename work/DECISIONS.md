# Decision Log

Tracking key architectural and design decisions with rationale.

---

## DEC-001: App Name — "Patrimonio"
**Date:** 2026-03-22
**Status:** Accepted
**Context:** Needed a name that reflects the bi-national (US/MX) nature of the app.
**Decision:** "Patrimonio" — Spanish for patrimony/wealth/assets. Short, memorable, clean repo name.
**Alternatives:** VaultView, NetWorthNow, Fortuna, Omnifin

---

## DEC-002: Backend — Rust with axum
**Date:** 2026-03-22
**Status:** Accepted
**Context:** User emphasized speed and efficiency for data retrieval. Needed high-performance backend.
**Decision:** Rust with axum framework. Best throughput, memory safety, excellent async with Tokio.
**Alternatives:** Go (simpler but slower), Node.js (JS ecosystem but GC pauses), Python (too slow)
**Trade-off:** Steeper learning curve, but justified by performance requirements.

---

## DEC-003: Frontend — Flutter
**Date:** 2026-03-22
**Status:** Accepted
**Context:** Need web, desktop, AND mobile from one codebase. Performance matters.
**Decision:** Flutter with Dart. Single codebase → web, iOS, Android, macOS, Linux, Windows.
**Alternatives:** React Native (no desktop), Electron+React (heavy RAM), separate codebases
**Trade-off:** Dart is less mainstream than JS, but Flutter's rendering engine gives consistent, fast UI.

---

## DEC-004: Financial Data — Plaid (primary) + CSV (MX)
**Date:** 2026-03-22
**Status:** Accepted
**Context:** Need to connect 11 US institutions + 3 Mexican institutions with minimal cost.
**Decision:** Plaid API (pay-as-you-go) for all US institutions. CSV/OFX upload for Mexican ones.
**Rationale:** Plaid supports all listed US institutions. `/accounts/get` is free. Mexican institutions lack public APIs, so CSV upload is the most reliable and secure path.
**Cost:** ~$0-5/month for Plaid, $0 for CSV parsing.

---

## DEC-005: Database — PostgreSQL
**Date:** 2026-03-22
**Status:** Accepted
**Context:** Need time-series data (balance history), relational data (accounts, holdings), and flexible storage.
**Decision:** PostgreSQL with JSONB for flexible fields, partitioned tables for time-series.
**Alternatives:** SQLite (simpler but no concurrency), TimescaleDB (overkill), MongoDB (no ACID)

---

## DEC-006: Deployment — Docker Compose (local) → GCP Cloud Run (cloud)
**Date:** 2026-03-22
**Status:** Accepted
**Context:** Self-host initially, but easy migration to cloud when ready.
**Decision:** Docker Compose for local. Containerized services migrate directly to Cloud Run.
**GCP Free Tier:** Cloud Run (2M req/mo), e2-micro VM (Postgres+Redis) = $0/month.
