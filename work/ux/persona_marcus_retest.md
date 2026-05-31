# UX RE-TEST / VALIDATION — Marcus Chen (security/perf power user)

Re-test of the live code in `frontend/lib` against my original report
(`persona_marcus.md`, 7/10) and the two engineer changelogs
(`engineer_pass1.md` brand, `engineer_pass2.md` cache). The app isn't
network-reachable; this is a read of the code as it stands now.

**New overall: 7.5 / 10** (was 7). The caching work is real, correct for my
daily flows, and the brand re-skin is a genuine upgrade — but four of my five
non-caching top issues are untouched, so the needle only moves half a point.

---

## Resolution table

| # | Issue (original) | Status | Evidence |
|---|---|---|---|
| 1 | No client-side caching; full ~15-endpoint refetch every reload | **RESOLVED** | `response_cache.dart` (new SWR cache); `api_service.dart:73,82,88-98,140-144` (shared cache, central mutation invalidation); `dashboard_screen.dart:1183-1236` (`_loadAllData` `forceRefresh`), `:204` (realtime forces), `:1034` (`_refreshData` forces) |
| 2 | 2FA / passkey / Security buried in `⋮` overflow | **NOT ADDRESSED** | `dashboard_screen.dart:1410-1443` — still a `PopupMenuButton` with `Icons.more_vert`; Security is item #3 in the popup. No visible shield icon, no 2FA nudge. |
| 3 | No cash-flow KPI on Overview stat strip | **NOT ADDRESSED** | `dashboard_screen.dart:450-489` — tiles are still Net worth / Assets / Liabilities / Cash / Investments (+ conditional Real assets). No "Net this month". |
| 4 | Bulk ops are N sequential PATCHes | **NOT ADDRESSED** | `transactions_tab.dart:1094-1100` (rename loop), `:1129-1136` (categorize/move loop). Comment at `:1117-1118` explicitly keeps the per-tx loop. |
| 5 | No bulk rename in multi-select bar | **NOT ADDRESSED** | `transactions_tab.dart:673-682` — bulk bar still offers only "Set category" + "Move account". |
| 6 | Passkey login is username-first, not usernameless | **NOT ADDRESSED** | `passkeys.dart:164,170-171` — still requires `username` and throws "Enter your username first." No conditional-UI/resident-key path. |
| 7 | No "trust this device / 30-day" TOTP | **NOT ADDRESSED** | `security_screen.dart` unchanged on this; no skip-TOTP option. |
| 8 | TOTP enrollment shows no QR, copy/paste only | **NOT ADDRESSED** | `security_screen.dart:1167-1168` — still "render the otpauth:// URI as text + copy button rather than a QR." |
| 9 | Subscriptions hidden on Cash-flow tab, no Overview nudge | **NOT ADDRESSED** | No Overview surfacing added. |
| 10 | Tax screen serial awaits before first paint | **NOT ADDRESSED** | `tax_planning_screen.dart:49-55` — `getTaxSummary` awaited, then `getTaxTransactions`. No `Future.wait`. |
| Perf-4 | Stat strip re-walks all accounts every rebuild | **NOT ADDRESSED** | `dashboard_screen.dart:383+` `_buildStatStrip` still called from `build`, no memoization on (overview, conversionFactor). |
| Perf-6 | Wealth projection round-trips per slider release | **NOT ADDRESSED** | unchanged. |
| Brand | Distinctive palette, generic chrome | **IMPROVED** | jade seed + terracotta/gold + warm neutrals + Fraunces display (`palette.dart:35-55`, `typography.dart`). |

**Counts: 1 RESOLVED · 0 PARTIAL · 11 NOT ADDRESSED** (+ 1 brand IMPROVED).
Pass 2 was scoped to the single thing I ranked #1; pass 1 was brand only.

---

## Caching correctness verdict — SAFE (one narrow theoretical staleness window)

Verdict: **SAFE for every real flow I exercise.** The design is better than I
expected from the changelog.

What I verified holds:
- **Every mutation invalidates.** `_post/_patch/_put/_delete` all route through
  `_invalidateAfterMutation` (`api_service.dart:106-144`), which calls
  `clear()` on any 2xx/3xx. Centralising in the verb wrappers (not 30 call
  sites) makes "every write evicts" provable. Multipart uploads, which bypass
  the wrappers, clear by hand (`:835,977`).
- **Rename-tx → back-to-dashboard is fresh.** The mutation `await`s and clears
  the cache *before* the follow-up `_loadAllData(silent:true)` runs
  (e.g. `dashboard_screen.dart:292-293`). The reload is a clean miss → fresh
  fetch even without `forceRefresh`. Good.
- **Realtime ping never serves cache.** `_handleRealtimeEvent` forces
  (`dashboard_screen.dart:202-204`); `_refreshData` forces (`:1034`).
- **The generation guard is correct for the write-back race.** `clear()` bumps
  `_generation` (`response_cache.dart:86-89,95`); a fetch captures
  `startGeneration` (`:140`) and only `set()`s if `_generation` is unchanged
  (`:149-151`). So a read that began *before* a mutation can never repopulate
  the cache with pre-mutation data after the clear. This is the right guard.

The one narrow gap I'd flag as a skeptic — **NOT a blocker, very low
probability:** the generation guard prevents stale *write-back*, but not stale
*read-back* through in-flight de-dupe. In `getOrFetch`/`_fetchDeduped`
(`response_cache.dart:135-139`), a caller — *including a `forceRefresh`
caller* — that arrives while an older fetch for the same key is in flight
**joins that existing future** and receives its value. `clear()` does not drop
`_inFlight` (`:86-89` touch only `_entries` + `_generation`). So the precise
sequence: (a) a normal read for key K is in flight; (b) a mutation clears; (c) a
realtime force-refresh for K arrives before (a) settles → it joins (a) and gets
the *pre-mutation* value. The guard correctly stops (a) from caching it, so the
*next* read is fresh — but that one forced caller got a stale value for one
paint. Window is the few-ms overlap of an outstanding GET with a clear+forced
re-read. In practice `_loadAllData` fires all keys together and realtime events
don't arrive mid-flight often, so I never expect to see it. If they want it
provably airtight: have `clear()` also forget `_inFlight` (or stamp in-flight
futures with the generation and force-refresh callers skip a stale-generation
in-flight join). 25s TTL is reasonable — conservative for a finance dash, and
moot for any post-write/realtime/pull-to-refresh path since all bypass it.

Net: I trust the numbers. The cache meaningfully improves perceived
performance on tab-switch and sub-screen-return (the common no-mutation case)
without a credible path to showing me a wrong balance.

---

## Brand note

The re-skin reads as a real step up, not a reskin-for-reskin's-sake. The agave
jade seed (`palette.dart:35-45`) + terracotta/gold heritage accents + warm
parchment/charcoal neutrals give it an identity the old neon-emerald-on-grey
lacked, and Fraunces on the hero number / section titles
(`typography.dart:31-56`) adds the "estate/heritage" character I said was
missing. Crucially it stays **dense and legible**: Fraunces is confined to
display/headline slots; body and all UI chrome remain Inter, so no row-height
inflation and no legibility regression in the dense transaction grid. The WCAG
work is honest — light accents were darkened to clear AA (changelog table) and
the contrast unit test still gates it.

---

## Regressions

- **Fraunces is fetched at runtime over the network** (`google_fonts`,
  `typography.dart:2,16-17,36,54`). No font assets are bundled
  (`pubspec.yaml:85` `fonts:` is commented out, `assets/fonts/` empty) and
  there's no `GoogleFonts.config.allowRuntimeFetching = false`. So first launch
  makes a third-party call to `fonts.gstatic.com` and can show a flash of
  fallback on the hero number. For a privacy/perf-obsessed user this is a
  (minor) new external dependency + FOUT that the old all-Inter theme didn't
  have. Fix: bundle Fraunces + Inter as assets and disable runtime fetching.
- Minor: a 200-row bulk edit now calls `clearDashboardCache()` 200 times (once
  per PATCH). Harmless (clear is O(map)), but underlines that the unbatched
  bulk loop (#4) is still there and now also thrashes the cache.

---

## New score: 7.5 / 10 (was 7)

The +0.5 is entirely the cache (my #1, done well and correct) plus a brand that
now has a point of view. It's held back from 8 because the *discoverability and
batching* issues a power user feels every day — Security buried in `⋮`, no
cash-flow KPI, no bulk rename, sequential bulk PATCHes, text-only TOTP, no QR —
are all exactly as I left them. The most valuable remaining gap is the cluster
around **#2 (Security/2FA discoverability) and #3 (cash-flow KPI on Overview)**:
both are cheap, high-frequency, and the kind of thing that separates a 7.5 from
a 9.
