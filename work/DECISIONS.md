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

---

## DEC-010: Dashboard Tab Layout — Optional Scrolling
**Date:** 2026-03-24
**Status:** Accepted
**Context:** Transitioning to complex, full-page tabs (like Wealth Projections) caused layout conflicts (`Expanded` inside `SingleChildScrollView`).
**Decision:** Modified `buildTabContainer` to support an optional `scrollable` parameter (default: true).
**Rationale:** Components using `fl_chart` or other responsive, space-filling widgets require finite vertical constraints for `Expanded` to calculate heights correctly. A mandatory top-level scroll view breaks this.
**Trade-off:** Some screens may now overflow on very small viewports if they don't implement their own internal scrolling for specific sub-components.

---

## DEC-011: Performance Opts & Optional Crypto Integrations
**Date:** 2026-03-31
**Status:** Accepted
**Context:** As data grows (historical trends, transactions), chart rendering can become a bottleneck. Also, user requested future-proofing for Crypto (e.g., Coinbase) natively.
**Decision:** Implement data-downsampling on the backend for multi-year charts to ensure `fl_chart` remains performant. Introduce "Crypto" as a primary optional account/integration type to pave the way for a Coinbase API integration in a future phase.
**Rationale:** Sending 1000s of data points to Flutter charts halts the main thread during rendering; downsampling preserves shape while fixing framerates.

---

## DEC-012: Phase 10 — V1 Polish Strategy
**Date:** 2026-04-06
**Status:** Accepted
**Context:** After all core features were built (Phases 1–9), the app needed a UI/UX consistency pass before declaring V1.
**Decision:** Focused polish on three high-impact areas: (1) smart category icons with per-category color theming via a mapping function, (2) title-casing raw bank text to improve readability, (3) transaction search for quick filtering.
**Rationale:** These three changes have outsized UX impact relative to effort. Icon+color gives instant visual scanning. Title-casing eliminates the "raw data dump" feel. Search is essential once transaction count grows.
**Trade-off:** Icon mapping is hardcoded to Plaid's category taxonomy; custom/manual transactions may fall through to a generic icon. Title-case can produce odd results for acronyms (e.g., "Ach" instead of "ACH").

