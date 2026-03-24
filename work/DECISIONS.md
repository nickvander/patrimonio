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

## DEC-007: Performance Benchmarking — S&P 500
**Date:** 2026-03-24
**Status:** Accepted
**Context:** User requested a tangible performance benchmark for wealth growth.
**Decision:** Overlay an S&P 500 baseline (~10% annual return) on the Net Worth chart.
**Rationale:** Provides instant context for whether a user is "climbing" or just following market trends.
**Trade-off:** Static calculation for now; future phases could fetch real SPY price data.

---

## DEC-008: Multi-Currency Toggle — Global State
**Date:** 2026-03-24
**Status:** Accepted
**Context:** Needed a quick way to view assets in either domestic (USD) or local (MXN) currency.
**Decision:** Global toggle in App Bar that propagates a `conversionFactor` and `currencyFormat` to all child widgets.
**Rationale:** Enables "at-a-glance" consistency without needing per-widget toggles. Use real-time exchange rates (USD/MXN).

---

## DEC-009: Backend Library Structuring for Testability
**Date:** 2026-03-24
**Status:** Accepted
**Context:** Needed a robust way to unit test parser logic without depending on a running database or complex integration tests.
**Decision:** Extracted core logic from `main.rs` into a `lib.rs` target.
**Rationale:** Standard Rust pattern for binaries that need internal module testing. Allows the `tests/` directory and internal `mod tests` to access private modules in a controlled way.
**Trade-off:** Minimal overhead in project structure, greatly improved parser reliability.
