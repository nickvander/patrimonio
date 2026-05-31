# Engineer pass 2 — changelog

## Sprint-1 #4: short-TTL stale-while-revalidate cache for dashboard GET reads

### Problem
`ApiService` had zero client-side caching. `dashboard_screen._loadAllData()`
fires a ~15-endpoint `Future.wait` on EVERY reload — and a reload is triggered
by returning from a sub-screen, every realtime websocket event, and every
post-mutation refresh. A single transaction rename re-pulled holdings,
net-worth history, allocation, trends, subscriptions, FX transfers, loans, etc.
Redundant network traffic + a perceptible flash/sluggishness.

### Design
New self-contained, Dart-VM-testable component `ResponseCache`
(`frontend/lib/services/response_cache.dart`) — no `package:web` / Flutter
imports, so it is unit-tested directly (we do NOT subclass `ApiService`).

`ResponseCache` API:
- `getOrFetch(key, fetch, {forceRefresh})` — the read path.
  - Fresh hit → cached value, no network.
  - Stale hit → returns cached value immediately AND revalidates in the
    background (stale-while-revalidate).
  - Miss → awaits `fetch`, caches, returns.
  - `forceRefresh: true` → bypass cache, await a fresh fetch.
- In-flight de-dupe: concurrent identical reads share one network call.
  `forceRefresh` joins an already-outstanding fetch (it's already the
  freshest data obtainable).
- TTL = 25s (conservative). Injectable clock for tests.
- `set`, `peek`, `isFresh`, `invalidate(key)`, `invalidatePrefix(prefix)`,
  `clear()`.
- Generation guard: `clear()` bumps a counter; a fetch that started before
  the `clear()` refuses to populate the cache afterwards. This is the core
  finance-safety guard — a read that began *before* a mutation can never
  write its now-stale result back after the mutation invalidated the cache.

### Wiring into ApiService (`frontend/lib/services/api_service.dart`)
- Static shared `ResponseCache _cache` (the app builds >1 ApiService;
  sharing means a refresh from any caller benefits the rest).
- Cached GETs (all keyed under `dash:`), each gaining a `forceRefresh` flag:
  overview, net-worth-history, holdings, credit-utilization, sync-status,
  allocation, trends, since-last-login, subscriptions, subscriptions/ignored,
  fx-transfers, loans/reminders, loans/summary.
- `getSetupStatus`, `getExchangeRate`, `getTransactions` left UNcached
  (setup is a public/login-screen probe; FX has its own force path; tx list
  is paginated/offset-keyed and small).

### Invalidation strategy (precise — how stale finance data is prevented)
1. **Every mutation clears the whole dashboard cache.** Centralised in the
   verb wrappers `_post` / `_patch` / `_put` / `_delete`: each calls
   `_invalidateAfterMutation(res)` which runs `clearDashboardCache()` for any
   2xx/3xx response. Skipping 4xx/5xx means a rejected request (which changed
   nothing) doesn't needlessly evict warm entries. Centralising here makes
   "every mutation invalidates" provable rather than relying on ~30 call sites.
2. **Multipart uploads** (`uploadStatements`, `uploadStatement`) bypass the
   verb wrappers, so they call `clearDashboardCache()` by hand on HTTP 200.
3. **Realtime path bypasses the cache.** `dashboard_screen._handleRealtimeEvent`
   now calls `_loadAllData(silent: true, forceRefresh: true)`. A server push
   means data changed; the client cache must not win.
4. **Explicit user refresh bypasses the cache.** `_refreshData()`
   (pull-to-refresh / post-mutation reloads) → `forceRefresh: true`.
5. **In-flight-vs-clear generation guard** (above) closes the race where a
   read started before a mutation could repopulate stale data afterward.

Net effect: the cache only ever serves data within a 25s window during which
no mutation occurred, no realtime event arrived, and the user didn't explicitly
refresh. Otherwise it fetches fresh.

### Files touched
- `frontend/lib/services/response_cache.dart` (new)
- `frontend/lib/services/api_service.dart` (cache field, helpers, cached GETs,
  central mutation invalidation, multipart invalidation)
- `frontend/lib/screens/dashboard_screen.dart` (`_loadAllData` gains
  `forceRefresh`; realtime + pull-to-refresh force-refresh)
- `frontend/test/services/response_cache_test.dart` (new, 13 tests)
- `frontend/test/widgets/lending_tab_layout_test.dart` (override signature
  bump for `getLoansSummary({forceRefresh})`)

### Tests added (13, plain Dart VM)
hit/miss; set+peek; TTL expiry; stale-while-revalidate (old value returned +
background revalidation observed); invalidate-by-key; invalidate-by-prefix;
clear; **in-flight-when-clear does NOT repopulate** (finance-safety guard);
in-flight de-dupe (one fetch for N concurrent reads); fresh re-fetch after
settle; forceRefresh bypasses fresh value; forceRefresh joins in-flight;
fetch error not cached + propagates + retryable.

### Scoped down / nothing risky cut
Full stale-while-revalidate WAS implemented (not the reduced subset). Left
uncached: setup-status, exchange-rate, transactions (rationale above).

### Verification
- `flutter test`: All 120 tests passed (107 baseline + 13 new).
- `flutter analyze`: 0 error, 0 warning, 18 info (all pre-existing, none new).
