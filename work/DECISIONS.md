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

---

## DEC-013: Docker Compose Owns the Full Local Stack
**Date:** 2026-05-12
**Status:** Accepted
**Context:** The app previously required separate backend and Flutter launch paths, which made "does it start?" ambiguous and exposed local port conflicts with other services.
**Decision:** Docker Compose now starts the frontend, API, PostgreSQL, and Redis together. The Flutter web build is served by nginx at port 3000, the API remains on 8080, and Postgres/Redis are mapped to 5433/6380 on the host.
**Rationale:** One command should bring up the product the user can actually open in a browser. Non-default database/cache host ports reduce collisions on development machines.
**Trade-off:** Frontend container rebuilds take longer than direct `flutter run`, so direct Flutter commands remain useful during UI-heavy development.

---

## DEC-014: Local Smoke Test Covers API and Browser Rendering
**Date:** 2026-05-12
**Status:** Accepted
**Context:** Container health is not enough for a Flutter web app; nginx can serve files while the app still fails to render.
**Decision:** Added `scripts/smoke.cjs` to check API health and verify the app renders in a real browser through Playwright.
**Rationale:** This catches routing, asset, API reachability, and blank-screen failures before pushing launch changes.
**Trade-off:** Browser validation depends on local Playwright availability. `SKIP_BROWSER=1` exists for API-only checks when browser dependencies are unavailable.

---

## DEC-015: Plaid Production & Institutional Management
**Date:** 2026-05-12
**Status:** Accepted
**Context:** Migrated from Sandbox to Production environment for real-world usage. Required a way to manage/remove legacy sandbox data and handle OAuth update modes.
**Decision:** (1) Implemented institution/account deletion endpoints with cascading SQL to ensure a clean dashboard. (2) Added OAuth "Update Mode" support via reconnect tokens to handle Plaid's mandatory bank-side credential refreshes.
**Rationale:** Sandbox data (Tartan Bank, etc.) cluttered the real net worth once production data was linked. Deletion is essential for "clean" personal finance tracking. OAuth reconnect is a technical requirement for any Plaid app in production.

---

## DEC-016: Data Quality — User Overrides & Source Tracking
**Date:** 2026-05-13
**Status:** Accepted
**Context:** Real data often has messy categorization or requires personal context (notes). Overlapping CSV imports could also lead to duplication.
**Decision:** (1) Added `user_category` and `user_notes` fields to the transaction schema to support non-destructive overrides. (2) Implemented deterministic signature-based deduplication for CSV imports (hashing date+amount+desc). (3) Added `source` tracking (`plaid` vs `csv`) for auditability.
**Rationale:** Users trust their own categorization more than a bank's ML model. Overrides allow "fixing" data without losing the original bank record. Signature-based deduplication is critical when users import the same statement file multiple times or have overlapping dates.

---

## DEC-017: One "More" Metaphor — Top-Bar Kebab Retired App-Wide
**Date:** 2026-07-14
**Status:** Accepted
**Context:** The app bar's kebab menu held only app-level settings (theme, language, sign-out) — a top-bar overflow is for screen-contextual actions — and it was part of the compact bar's M3 action-budget overflow on phones.
**Decision:** Remove the kebab on all widths. App-level settings live at the end of the Settings tab (Preferences + Account & security groups); first-run keeps bar escape hatches since nav chrome is hidden there. A kebab may return only for genuine per-screen actions.
**Alternatives:** Keep the kebab on wide layouts only (rejected — two homes for the same settings); a dedicated settings icon in the bar (rejected — still over the compact action budget, and Settings is already one tap away in the nav).

---

## DEC-018: Scroll-Away App Bar via NotificationListener Wrapper
**Date:** 2026-07-14
**Status:** Accepted
**Context:** The compact app bar should scroll away (enter-always + snap) to reclaim vertical space on phones, but the dashboard's scroll ownership spans 4 different scrolling regimes across 5 files under an IndexedStack, so the canonical Flutter approach would require re-plumbing every tab.
**Decision:** A notification-driven collapsing wrapper around the existing AppBar (`frontend/lib/utils/bar_scroll.dart` decision helper): force-visible at scroll offset zero (never fights pull-to-refresh), restored on upward flicks and tab switches. Wide layouts keep a static bar.
**Alternatives:** NestedScrollView / per-tab SliverAppBar (rejected — high regression surface across all 4 scroll regimes for what is cosmetic parity with the stock M3 behavior).

---

## DEC-019: Credit-Card List Ranks by Amount Owed, Not Utilization
**Date:** 2026-07-14
**Status:** Accepted
**Context:** The credit-utilization card sorted rows by utilization %, which ranked a nearly-empty low-limit card above cards carrying four-figure balances — the list reads as "what do I owe", not "which limit is fullest".
**Decision:** Rank by USD-normalised amount owed, largest first (mixed-currency safe); per-row utilization % is still displayed.
**Alternatives:** Keep utilization ranking (rejected per above); a user-configurable sort (rejected — a settings surface for a single card isn't warranted).

---

## DEC-020: Vault Heuristic Applies to Cash-Category Accounts Only
**Date:** 2026-07-14 (broadened same day: credit-only exclusion → cash-only inclusion)
**Status:** Accepted
**Context:** The accounts-list "vault" heuristic (nest a sub-account whose name matches neither its type token nor the bank) was written for SoFi-style savings buckets, but non-cash product names routinely match neither pattern — a U.S. Bank "Cash +" card nested under a generically-named "Credit Card" sibling ("base + 1 cards"), and a Vanguard "GOOGLE LLC 401(K) SAVINGS PLAN" nested under a $0 Traditional IRA ("$0.00 base + 1 accounts").
**Decision:** Only cash-category accounts can classify as vaults — savings buckets are the only place user-nicknamed sub-accounts exist. Credit and investment accounts always render as sibling product rows inside the collapsible institution block.
**Alternatives:** Tuning the name-similarity threshold (rejected — product naming is inherently arbitrary; category scoping is deterministic and testable).

## DEC-021: Manual Sync Is Fire-and-Forget + Poll, Not a Blocking Request
**Date:** 2026-07-17
**Status:** Accepted
**Context:** `POST /api/institutions/sync` ran the entire multi-institution sync *inline* in the request and only returned once every institution finished (concurrency 5 over ~13 institutions, each doing several sequential Plaid round-trips including a `/transactions/sync` pagination loop). The app held that one request open the whole time. Two failures fell out of this: (1) backgrounding the app tears down the TCP socket, so the client saw `HttpException: Software caused connection abort` — and worse, axum drops the handler future on client disconnect, so the sync itself was **cancelled** mid-flight; (2) the reqwest client had no timeout, so a single hung Plaid call pinned its institution in `syncing` forever and the progress counter stuck at "12/13".
**Decision:** The trigger now (a) synchronously stamps the caller's *syncable* institutions `sync_status = 'syncing'`, (b) spawns the sync as a **detached `tokio::task`**, and (c) returns `202 Accepted` immediately. The realtime `TransactionsChanged` publish moved to the end of the spawned task. The client no longer awaits a long request — it polls `GET /dashboard/sync-status` until no syncable institution is still `syncing`, deriving progress as `total − syncing`. A per-request 60s reqwest timeout (`SYNC_HTTP_TIMEOUT`) bounds each upstream call so a hung one flips its institution to `error` (still "done") instead of wedging the count. The pre-stamp removes the poll race (statuses are already `syncing` when the trigger returns). Syncable types (`plaid`, `coinbase`, `coinbase_oauth`, `bitso`) are defined once in `SYNCABLE_TYPES` (backend) and mirrored by `kSyncableInstitutionTypes` (frontend).
**Consequences:** Backgrounding the app is now a non-event — the sync runs to completion server-side regardless of the client, and the app picks up wherever it got to on return. An errored/slow institution can no longer stick the progress bar. `202` is the new success code; the frontend accepts `200` too for backward compatibility with an older backend.
**Alternatives:** (1) Keep it blocking but add client-side retry/keepalive (rejected — doesn't fix the server-side cancellation, and long-held mobile sockets are inherently fragile). (2) Server-Sent Events / websocket progress stream (rejected — the poll of an existing `/sync-status` endpoint is far simpler and the realtime channel already nudges a refetch on completion). (3) A durable job queue (rejected as overkill for a single-instance deployment; noted as future work if a second API instance ships).

---

## DEC-022: FBAR Classifies by Institution Country; Per-Account Override Trimmed
**Date:** 2026-07-24
**Status:** Accepted
**Context:** The FBAR monitor treated ANY MXN-denominated account as foreign (`country <> 'US' OR currency = 'MXN'`), so a multi-currency MXN account at a US institution wrongly inflated the FBAR aggregate. The quick-win spec also floated a per-account include/exclude override "only if an existing settings mechanism makes it cheap".
**Decision:** Country-first classification: a positively non-US institution country is foreign; a US-country account is domestic regardless of currency; the MXN-currency heuristic survives only when the country is unknown (empty), and those rows carry `classified_by_currency = true`, rendered as a "Confirm location" pill in the tax screen. The per-account include/exclude override was **trimmed**: `app_settings` is a generic key/value store, so persisting it would be easy, but a correct override still needs per-account toggle UI, service-layer filtering in both FBAR queries, and export-sheet coherence — not "cheap". The institution's editable `country` field already IS the correction mechanism the flag points the user at.
**Alternatives:** Keep the currency OR-rule (rejected — over-reports domestic MXN accounts); treat unknown country as domestic (rejected — silently under-reporting a likely-Mexican account is the worse failure for a compliance monitor).

---

## DEC-023: Condition-Backed Notifications Reconcile — Delete on Proof, Never on a Join Gap
**Date:** 2026-07-31
**Status:** Accepted
**Context:** `user_notifications` was insert-only: the staleness cron wrote one row per episode and nothing ever took it back, so a stored reminder — frozen text making a claim about the present — outlived its condition indefinitely (a CetesDirecto "statement import overdue" row survived the import that cleared the dashboard banner, and kept inflating the unread badge). `loan_due` had the identical shape: paying an installment cleared the lending tab while the bell kept asking for the money.
**Decision:** Condition-backed rows are reconciled on every `GET /api/notifications`. `import_stale`: the writer and the resolver share ONE `StalenessPrefs::should_notify` predicate and ONE `manual_institution_freshness` query — a row is deleted exactly when the sweep would no longer write it (fresh data / muted / snoozed), otherwise kept with its day count re-dated to today so it never lies. `loan_due`: `sync_loan_due_notifications` reconciles against the writer's own desired set (paid, skipped, tx-linked, rescheduled, closed, deleted, lead window shortened all retire the row) rather than enumerating resolution cases. **The invariant:** deletion requires *proof* the condition cleared — a row whose institution can't be attributed (deleted, or renamed before `link_id` existed) is left alone, because otherwise any missing join reads as "resolved" and eats the inbox. New rows carry `link_kind`/`link_id` so renames resolve from here on; the resolver backfills them onto surviving old rows. Event notifications (FX crossings) are untouched — those record something that happened, not a condition that must still hold.
**Alternatives:** Enumerate per-type resolution cases in the resolver (rejected — a second list drifts from the writer; reconciling against the writer's own desired set can't); treat an unattributable row as resolved (rejected — turns every data gap into silent inbox loss).

---

## DEC-024: "Since Your Last Visit" Anchors on Visits; the Wire Name Stays `previous_login_at`
**Date:** 2026-07-31
**Status:** Accepted
**Context:** The since-last-visit summary (Overview banner + two bell rows) anchored on `users.previous_login_at`, which only moves when the user actually authenticates. On a phone that stays signed in for weeks that is not a "visit" by any reading — the app showed "143 new transactions — Since your last visit · Jul 13" on Jul 30.
**Decision:** Migration `2026073101` adds `users.last_visit_at` + `previous_visit_at`, rolled by `GET /dashboard/since-last-login` in one `UPDATE … RETURNING`: a gap of more than `VISIT_GAP_HOURS` (4) ends a visit, so the old `last_visit_at` becomes the anchor; inside the window the anchor holds still, so refreshing doesn't erase the summary being read. This is a deliberate write on a GET — listing what changed since the last visit *is* the visit. Existing users are seeded from `MAX(user_sessions.last_seen_at)` (bumped on every authenticated request — a real activity signal), so the first post-deploy load reports nothing new and every visit after that is measured honestly. **The wire field deliberately stays `previous_login_at`:** it is the key the web banner and the shipped APK dismiss on, and renaming it would silently un-dismiss banners on every client that hasn't updated. `previous_login_at` itself is unchanged — it still backs the security screen's session flag and is the fallback anchor for a user with no recorded visit.
**Alternatives:** Rename the wire field to match the new semantics (rejected — breaks dismissal state on every stale client for zero user-visible benefit); seed the new anchor from `previous_login_at` (rejected — would replay on day one the exact staleness the migration exists to end).

---

## DEC-025: Exact Filtered Totals via an `X-Total-Count` Response Header, Not an Envelope
**Date:** 2026-08-02
**Status:** Accepted
**Context:** The Transactions "Showing X of Y" denominator was the loaded-pages length while the filter cascade streamed history, so the total visibly counted up. An exact total has to come from the server — but wrapping the list responses in a `{rows, total}` envelope would break the **shipped APK**, whose decoder expects a bare JSON array.
**Decision:** Both tx list endpoints compute `COUNT(*) OVER ()` inside the same query (identical WHERE clause, zero duplication) and return it as an **`X-Total-Count` response header**; CORS exposes the header. `ApiService` returns a `TxPage {rows, totalCount}`; `hasMore` is exact (`loaded < total`) with the old short-page heuristic kept as the older-server fallback. A *successful* empty offset-0 page emits `X-Total-Count: 0`; DB errors emit no header at all, so a failure can never masquerade as "zero rows". Accepted cosmetic edge: deleting the very last transactions mid-session leaves the stale total until reload (header absent on an empty page by design).
**Alternatives:** Envelope change `{rows, total}` (rejected — breaks the shipped APK's bare-array decode; the header is invisible to clients that don't ask for it); keep the client-side heuristic (rejected — it's the bug: the denominator is a page count, not a total).

---

## DEC-026: Programmatic Transactions-Tab Jumps Start From a Fresh Context
**Date:** 2026-08-02
**Status:** Accepted
**Context:** A read-only audit mapped every programmatic jump into the Transactions tab (bell drill-downs, dashboard taps, insight sheets — 14 journeys) and found 10 could stack stale filters from a *prior* journey into a silent zero-result list. Live-reproduced: search "FasTrak" ∧ a stale account chip ∧ a stale "New since" seed = "0 matching"; a stale July insight banner surviving over a June month drill.
**Decision:** One rule instead of per-journey patches: `_applyJumpContext` (replacing `_maybeApplySeeds`) treats **any** programmatic jump — any of the four one-shot seeds OR a `searchOverride` — as a fresh start: reset `TxFilters.empty` + search + selection mode FIRST, inside the single post-frame `setState`, then apply the jump's own payload, so a fetch can never observe half-applied state. **Manual edits still compose** — the reset applies only to programmatic jumps, and sort mode + scroll position deliberately survive them. A new `onSearchOverrideConsumed` callback clears the dashboard's copy of the override, so re-tapping the same merchant jumps again. Dashboard companion: a single `_jumpToTransactions(...)` helper assigns ALL jump fields on every call, so a new jump site can't forget to clear a field it doesn't use.
**Alternatives:** Targeted per-journey clears (rejected — stale-state pairs grow with the square of the journey count, and every new jump site re-opens the class); also resetting sort/scroll (rejected — those are reading posture, not query context; the audit's design keeps them).
