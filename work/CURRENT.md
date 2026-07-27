# Current state — snapshot

> **Last updated:** 2026-07-27 (sync reaper + panic backstop)
> **Branch:** `main`.

## 2026-07-27 — Sync reaper + year-panic fix (audit item 7 + one tail finding)

Finished across three sessions — the first two were killed by the kernel OOM
killer (11GB VM; a 3.5GB Gradle and a 3.4GB emulator each pushed it over
while other builds ran — the tmux scope died with them; lesson recorded in
agent memory: serialize heavy jobs). Not disk: 10G free throughout.

* **Stuck-`syncing` reaper (item 7, backend).** New nullable
  `institutions.sync_started_at` (migration `2026072601`, partial index on
  the syncing rows). `update_sync_status` stamps it on 'syncing' and clears
  it on every terminal state; `mark_syncable_syncing` (the trigger-time
  pre-stamp) stamps it too, so a run that wedges before reaching a queued
  institution still ages out. `sync::reap_stale_syncs(db, boot)`: at boot,
  ANY 'syncing' row is reaped (a detached run cannot outlive the process);
  a 5-minute cron watchdog reaps rows older than 30 min and abstains from
  NULL stamps. Reaped rows land in `error` with a human `last_sync_error`,
  not silently back to `pending`. 3 regression tests
  (`sync_reaper_test.rs`).
* **"Sync complete" honesty (item 7, frontend).** `runSync`'s 8-minute
  spinner cap previously fired the "Sync complete" toast unconditionally;
  hitting the deadline with institutions still syncing now shows "Sync is
  taking longer than usual — it keeps running in the background"
  (`dashSyncStillRunning`, en + es).
* **`?year=300000` panic (tail finding).** Every tax/export handler now
  validates `?year=` (1900–2200 via shared `MIN_TAX_YEAR`/`MAX_TAX_YEAR`)
  → 400 instead of a `from_ymd_opt(...).unwrap()` panic. Regression test
  covers both routers and the i32 extremes.
* **`CatchPanicLayer` backstop.** A handler panic used to unwind through
  hyper and sever the connection (no status code at all — looks like a
  network fault). New `panic_guard::layer()` mounted OUTERMOST in main.rs:
  logs the payload, answers a generic 500 (no internals leaked, §1).
  Extracted to the lib so it's unit-testable
  (`a_handler_panic_becomes_a_generic_500`).

Gates: clippy clean, backend 277 lib + all integration suites green (incl.
the 3 reaper tests + the year test), `flutter analyze` at the 18-info
baseline, `flutter test` 771 passing. **Committed locally; not pushed, not
deployed to thelab, no APK cut.**

## 2026-07-26 (late) — Audit batch landed, plus desktop button sizing

Two commits on `main`, both fully verified locally, **not yet pushed or
deployed to thelab, and no APK cut**:

* **`a953fe6`** — the seven-item batch approved from the five-agent audit:
  merchant lifetime total (~6x too high in mixed currency), loan payoff
  recorded as `partial` (`from_f64_retain` keeps the full binary expansion),
  `balance_usd` written as raw native MXN (six writers now share
  `LATEST_USD_MXN_RATE_SQL`; `fetch_and_store_rate` refuses a non-positive
  rate), holdings import deleting a position and reporting success (now one
  transaction; import confirm made atomic too), the notifications bell
  ignoring the reporting currency, the Tax tab never refetching (and a failed
  FBAR fetch reading as "no foreign accounts"), and five fire-and-forget
  settings writes that claimed success — including the projection-assumptions
  read failure that overwrote the user's real FIRE scenario with defaults.
* **`c20620b`** — Settings action buttons stopped stretching to the card at
  desktop width (`(maxWidth - 16) / 2` and `width: double.infinity` produced a
  565px and a 1650x56 button at 1440). New `theme/buttons.dart` holds the
  rule; both sites drop to the M3 Expressive 40dp step; Coinbase brand blue
  moved from the fill to the icon. Mobile is byte-for-byte unchanged.

Gates: clippy clean, backend suite green (276 unit + 136 integration + the
rest, 0 failures), `flutter analyze` at its 18-info baseline, `flutter test`
771 passing (up from 751 — 20 new regression tests).

**Still open from the audit** (item 7 and the `?year` panic closed 2026-07-27,
see above): the remaining tail findings (truncated filtered totals,
`import_cleanup` claiming "No recent imports" on a load failure, FBAR
per-account contribution using an exact-date lookup), the four items needing a product
call (FBAR unverified badge + FinCEN peak-balance method, description-keyed
import dedup, the FIRE chart drawing the mean rather than the fetched p50, no
off-machine backup), and the feature shortlist led by manual purchase-lot
entry.

## 2026-07-26 — "Imported, but Home didn't update until I hit Sync now"

Reported after a cetesdirecto PDF import. The **backend was never at fault**:
prod logs show the confirm landed 10 transactions at 17:09:50 and published
`transactions_changed` + `accounts_changed` immediately, and replaying the
same cetes-shaped confirm locally showed every dashboard endpoint reflecting
it in the same request (tx feed 6→16, balance 85,000→92,500, net worth,
trends). The gap was entirely client-side, in three layers that each fail
**silently**:

1. **All-or-nothing refresh (the actual cause).** `_loadAllData` fans ~28
   reads through one `Future.wait`, which rejects on the FIRST throw, and the
   `silent: true` catch (used by both post-import reloads) keeps the current
   screen. One transient 503 discarded the whole refresh, with no error and
   no retry. Reproduced in the real UI by injecting a 9s 503 on
   `/dashboard/holdings` across the confirm — Home kept the pre-import card
   until "Sync now". Fixed: each core read degrades to the value already on
   screen (`services/resilient_reload.dart`), and a degraded pass arms a
   bounded retry (5s/15s/45s). Same repro post-fix: Home updates immediately.
2. **No websocket heartbeat.** Neither side pinged (the old "browser
   keep-alive pings" comment was wrong — browsers don't send those), so a
   socket dropped without a close frame left the client believing it was
   connected and every push was lost. The server now emits
   `{"event":"heartbeat"}` every 30s (a text frame, because browsers don't
   expose ping/pong to JS) and the client reconnects after 90s of silence.
3. **No app-lifecycle handling.** Resuming from background/sleep neither
   refetched nor revived the socket. The dashboard is now a
   `WidgetsBindingObserver`: on resume it reconnects and reloads when the
   on-screen data is older than 30s.

4. **Chart lagged the hero.** The hero net-worth figure reads
   `accounts.current_balance` (which the confirm updates); the chart reads
   `balance_snapshots`, where the import only wrote rows dated at the
   statement's month ends. Today's row came from the nightly cron — so the
   two disagreed until it ran, which is a second reason "Sync now" looked
   like the thing that applied an import. The confirm now also upserts
   TODAY's snapshot from the closing balance (`DO UPDATE`, because a cron row
   written this morning holds the pre-import balance; `balance_usd`
   FX-converted at write time).

   Gated on the statement being the **newest** data for the account
   (closing date ≥ the newest transaction date already stored). That guard
   also fixes a pre-existing bug in the same family: the closing balance was
   applied unconditionally, so importing a backlog (a 2024 statement after a
   2026 one) walked `current_balance` back two years. History still
   back-fills its own month-end snapshots either way.

## 2026-07-24 — Quick-win backlog burn-down

13 commits (`f7e5af0`…`bac4073`) closing 14 of the 17 items deferred from the
2026-07-23 sweep, each live-UI-verified: window-honest category averages,
hero-badge anchor honesty (shared `net_worth_delta.dart`), **editable manual
transactions** (PUT endpoint + prefilled dialog), always-visible entry
currency in the tx form, lending copy/clarity pass, 2FA-gated recovery-code
warning, projections/tax copy honesty, flat-loan inline validation +
scroll-to-error, es-MX launch checklist, no mid-digit money truncation +
mobile Home quick-add FAB + honest movers card, MXN month-header
reconciliation, and **FBAR classified by institution country** (currency
heuristic only for unknown-country rows, flagged; per-account override
trimmed — DEC-022). Deployed to thelab; APK cut at `bac4073`.

Still deferred (need design, not a sitting): portfolio-total reconciliation
(portfolio-1), MC-median chart honesty (projections-tax-5), netted harvest
model (projections-tax-2 proper). Plus feature proposal #1: MX tax parity.

## 2026-07-23 — Full-app UX/bug sweep, five fixes, six new features

A six-critic walkthrough of the live app (desktop + mobile, en + es-MX)
produced 52 findings; a PM pass approved 5 fixes, all implemented, QA-verified
against the live UI, pushed (`309440f`…`68ad1e0`), and deployed to thelab:

* **Sync 415 on web** — `trigger_sync` takes raw `Bytes`; empty body of any
  content-type = sync-all, malformed JSON = 400.
* **Loan agreement double-counted interest** in PAID/REMAINING (borrower-facing).
* **Manual transactions** no longer claim Plaid provenance or re-case user text
  (`source` now serialized per row).
* **Chart axes**: new `compactMoney()` + TextPainter-measured
  `compactMoneyAxisWidth()` kill the bare "$" on MXN axes and tick clipping.
* **Bonds classification**: balance-only `account_type='bonds'` accounts (CETES)
  count as Bonds in allocation; silent 20.0 FX fallback removed.

Six PM-proposed features then shipped the same day (`2582ddf`…`161511d`), each
QA-verified live incl. es-MX; three additive migrations (fx alerts +
`user_notifications`, recurring rules, notifications-center extensions):

* **FX center** behind the USD/MXN pill — sparkline (30/90d), visible
  freshness, converter, force-refresh, threshold alerts → `user_notifications`.
* **Staleness reminders** for import-only institutions — "as of" chips,
  dashboard banner, threshold setting, notification rows (no schema change).
* **Recurring transactions (expected-only MVP)** — rules table + management UI,
  expected overlay in cash flow; no auto-posting.
* **Retire-in-Mexico projections** — USD/MXN expense split + FX drift scenario
  over the existing Monte Carlo engine.
* **Tax export pack** — FBAR worksheet, 8949 + Schedule-B CSVs, MX annual
  summary from existing computations.
* **Notifications center** — bell is a real inbox (read state, deep links,
  ingests fx/staleness/loan-due/sync-error sources).

Deployed to thelab (migrations clean); APKs cut at `68ad1e0` and `161511d`.
Deferred/rejected findings + 17-item quick-win backlog: see the session's PM
report (workflow `wf_fee55e5b-c94`) and `work/FUTURE.md`. Backlog highlights:
sparse-window category averages, manual-tx editing, FBAR country-vs-currency
heuristic, harvest cross-bucket netting, MX tax parity (proposal #1, not built).

## 2026-07-17 — Manual sync no longer blocks the request (DEC-021)

Fixes two reported symptoms: (1) backgrounding the app during a sync
surfaced `HttpException: Software caused connection abort` and (2) the
progress counter stuck at "12/13". Root cause was one design flaw —
`POST /api/institutions/sync` ran the *entire* multi-institution sync inline
in the request and only returned when the last institution finished, so the
app held the socket open for a minute-plus. Backgrounding kills that socket;
worse, axum drops the handler future on client disconnect, so the sync was
**cancelled server-side**, not just visually errored.

* **Backend — fire-and-forget (`api/institutions.rs`).** `trigger_sync` /
  `trigger_sync_one` now share a `spawn_sync` helper that (a) synchronously
  stamps the caller's syncable institutions `sync_status = 'syncing'`, (b)
  spawns the sync as a detached `tokio::task`, and (c) returns **202
  Accepted** immediately (measured: ~11ms vs. the old minute+). The realtime
  `TransactionsChanged` publish moved to the end of the spawned task. New
  public `sync::mark_syncable_syncing()` does the pre-stamp (scoped to
  `SYNCABLE_TYPES` = plaid/coinbase/coinbase_oauth/bitso, `WHERE user_id`).
* **Backend — HTTP timeout (`services/sync.rs`).** The reqwest client had no
  timeout, so one hung Plaid call pinned its institution in `syncing`
  forever (the "12/13" stick). Added `SYNC_HTTP_TIMEOUT` (60s) via
  `Client::builder().timeout(..)` — a wedged upstream call now flips the
  institution to `error` instead of hanging the whole sync.
* **Frontend — poll to completion (`dashboard_screen.dart`).** `runSync`
  fires the (fast) trigger, then polls `/dashboard/sync-status` until no
  syncable institution is still `syncing`. Progress is `total − syncing`, so
  an errored/timed-out institution counts as *done* and can't wedge the
  bar. Backgrounding is now a non-event: the detached backend task keeps
  running and the poll picks up wherever it got to on resume. 8-min safety
  cap on the spinner (backend keeps going regardless). New `syncingCount()`
  in `utils/sync_progress.dart` replaces the old `last_synced_at`-delta
  count; `kSyncableInstitutionTypes` gained `bitso` to mirror the backend.
  `syncInstitutions()` accepts 202 (200 still tolerated for older backends).
* **Tests.** New backend integration tests (`dashboard_endpoints.rs`):
  `manual_sync_trigger_returns_202_immediately` and
  `mark_syncable_syncing_scopes_to_syncable_types_and_user` (type + tenant
  scoping + `only_ids`). Rewrote `sync_progress_test.dart` around
  `syncingCount`. All suites green (125 backend dashboard tests, 563 frontend
  tests), clippy clean, analyze clean. Live-smoked against the running dev
  backend: 202 in 11ms, institution settled to a terminal state
  independently of the client.
* **Not yet deployed to prod / not committed** — changes are on the working
  tree; the local dev backend was restarted onto the new binary.

## 2026-07-14 — App bar & Settings restructure (kebab retired, scroll-away bar)

Third round of the 2026-07-14 mobile pass — the app-bar audit + Settings
rehoming; each call researched + PM-evaluated in multi-agent workflows and
logged as DEC-017…DEC-020. All eight of today's commits
(`fad9351`…`097b2bd`) are deployed to prod on thelab and delivered to the
phone as a release APK.

* **Kebab retired on all widths (`57a6bc3`, DEC-017).** Every item the
  top-bar overflow held was an app-level setting, so the menu is gone and
  the Settings tab becomes the settings home: a Preferences group (Language
  radio picker + System/Light/Dark theme control synced with
  `themeModeNotifier`) and an Account & security group (Security, Hidden
  items, native-only Server row, and a confirmation-gated Sign out — the
  kebab's was one-tap). First-run, where nav chrome is hidden, keeps bar
  escape hatches: theme cycle, EN↔ES language toggle, confirmed sign-out.
  New tests pin the settings cards + sign-out confirmation; 560 tests green.
* **Scroll-away compact app bar (same commit, DEC-018).** Enter-always +
  snap via a notification-driven collapsing wrapper around the existing
  AppBar (new `utils/bar_scroll.dart` decision helper) — force-visible at
  scroll offset zero so pull-to-refresh never fights the bar, collapsing to
  an opaque status-bar inset strip, restored on upward flicks and tab
  switches. Deliberately NOT NestedScrollView / per-tab SliverAppBar:
  scroll ownership spans 4 regimes across 5 files under an IndexedStack —
  high regression surface for cosmetic parity.
* **Compact bar slimmed to the M3 action budget (`e1261bd`).** The
  standalone FX pill was both the over-budget item and an affordance bug
  (bordered like the tappable currency pill beside it, but with no tap
  handler). Gone on compact: the rate rides inside one combined 48dp
  "USD · 17.51" tonal currency chip — tap toggles the display currency,
  warning tint when the rate is >24h stale, toggle + equation in the
  tooltip/semantics. The freed leading slot shows the current tab's name as
  the title (wordmark stays on first-run). Wide layouts keep the separate
  badge + toggle.
* **Theme picker rebuilt as an M3 Expressive connected button group**
  (`eaf920b`): equal-flex tonal segments with 2px gaps, selected segment
  morphs to a filled fully-rounded pill (200ms); equal-flex always fits the
  card, so the SegmentedButton scroll-guard fallback is gone.
* **Credit-utilization card ranks by USD-normalised amount owed**
  (`eaf920b`, DEC-019), largest first, instead of utilization % —
  utilization ranked a nearly-empty low-limit card above four-figure
  balances. Per-row % is still displayed.
* **Accounts-list vault heuristic scoped (`097b2bd`, DEC-020):**
  credit-category accounts never classify as "vaults". Card product names
  ("Cash +", "Prime Visa") routinely match neither their type token nor
  the bank, so U.S. Bank's Cash+ nested under a generic "Credit Card" row
  with a bogus "base + 1 cards" line. Sibling cards now render as plain
  rows inside the collapsible institution block; regression test pins the
  U.S. Bank shape.

## 2026-07-14 — Android Plaid linking fixed end-to-end (OAuth + cookie)

* **Connect-bank 401 on native (`7b1757f`).** The screen made raw
  `package:http` calls (top-level `http.get/post`), bypassing the
  credentialed client — the browser attaches the session cookie for free
  on web, but on Android only `createApiClient()`'s shared cookie jar
  does, so setup-status / link-token / exchange-token all went out
  anonymous and the backend answered 401 ("Failed to retrieve link
  token"). All three now route through a credentialed client instance,
  closed in `dispose()`.
* **Android OAuth institutions (`90f5489`).** Link tokens always carried
  the web `redirect_uri`, so OAuth banks linked from the APK completed
  their OAuth in the browser — a context with no Link session to resume —
  and the public token was never delivered; the link silently vanished
  after Plaid's success screen. The client now sends its platform with
  link-token + reconnect-token requests; for android the backend attaches
  `android_package_name` (new `PLAID_ANDROID_PACKAGE_NAME` config,
  default `com.patrimonio.patrimonio`) instead of `redirect_uri`, so the
  Plaid SDK intercepts the OAuth return in-app. Bodyless requests (older
  clients, web) keep the redirect_uri behavior. REQUIRES the package name
  registered under "Allowed Android package names" in the Plaid dashboard
  (done by the owner). **Verified working:** U.S. Bank Altitude Connect
  linked via OAuth from the phone.
* **Prod data cleanup (operational, not code).** The duplicate June-1
  U.S. Bank Plaid connection in prod was deleted via the API — its Cash+
  account was double-counting $458.39 of liability. Done with a minted
  short-TTL owner session, revoked afterwards (the standard
  act-on-prod-as-the-user procedure).

## 2026-07-14 — Mobile UX overhaul (Invest / Activity / Home / Cash / More)

First two rounds of the phone-ergonomics pass (`fad9351`, `e6317ff`):

* **Invest tab compact layout:** compact overline title, compact-money
  change pills, 2-up KPI tiles on phones (from a 300px card interior),
  duplicate display-currency tile dropped — the other currency renders as
  one 48dp FX-equivalence row ("Total value in pesos ≈ MX$…", the
  Home-tab idiom), tighter card gaps, card chrome to house idiom
  (elevation 4 / radius 20).
* **Transaction detail sheet** hugs content instead of a fixed 90%
  height: 24px amount on narrow, one-line growable Notes, auto-category
  row only when overridden, Save button only when dirty, close-X folded
  into the hero row on narrow.
* **Activity toolbar restructure:** toolbar reduced to filter & sort
  (tune icon + M3 count badge) + overflow, persistent full-width search
  field, filters + sort in a bottom sheet on narrow (new sort section +
  removable sort chip), Add moved to a thumb-zone FAB on compact layouts
  (list gets 88dp clearance), transactions-list scrollbar transient on
  touch platforms (forced thumb only on pointer platforms).
* **Home:** single hero — the history card's header collapses to an
  overline with the mode toggle and the range selector moves inside the
  card below the chart; pull-to-refresh on the overview tab; 44dp+
  range/mode/sync targets; span-derived chart x-axis labels;
  assets/liabilities bar hidden at zero liabilities.
* **Cash:** summary-first section order, period chips below 420px,
  overline card headers, 2-up income/expense with an FX-equivalence net
  row, tap-triggered info tooltips at 48dp, Confirm/Unlink +
  subscription-dismiss raised to the touch floor, legend stacking bug
  fixed, type floors raised (10→11/12).
* **More:** sheet drag handle + selected-state tiles; Lending gets a
  thumb-zone FAB + full-screen loan form (keyboard-safe pinned actions) +
  house money formatters + l10n'd schedule headers; Tax gets 48dp
  filing-status targets and 2-up compact liability tiles with tap-tooltip
  caveats; Projections reordered summary-first with an overline header.
* **Verified:** `flutter analyze` clean at every step (19 pre-existing
  infos, zero new); 544 → 546 tests across the two commits (new
  regression tests pin the compact headers + loan-form behavior).

## 2026-07-13 — Native session persists across app restarts/updates

* **Owner-reported:** every APK update forced a re-login. Root cause: the
  native cookie jar (`api_platform_io.dart`) was in-memory only (a known
  limitation of the Android port), while the browser keeps the 30-day
  session cookie for free.
* **Fix:** the jar is mirrored into **Android-Keystore-backed secure
  storage** (`flutter_secure_storage`, new dep — deliberately not
  shared_preferences: the cookie is a full-access credential). Restored in
  `main()` via `initSessionPersistence()` before the first request (same
  init()-gating pattern as preferences_storage_io, so the test VM stays
  inert); mirrored on every Set-Cookie (login/logout); cleared on logout
  (even when the network revoke fails), on any 401, and on "Change server".
  Max-Age-only cookies get an absolute expiry stamped at persist time and
  expired entries are dropped on restore (`session_persistence_test.dart`).
  Seam surface (`initSessionPersistence`/`clearPersistedSession`) added to
  all three api_platform impls; web/stub are no-ops.
* Server sessions are 30d fixed (`SESSION_TTL_DAYS`), so the practical
  outcome is: re-login at most monthly, not per update.

## 2026-07-13 — Mobile chart un-squish + per-ABI APK

* **Squished hero chart on phones (owner-reported, APK screenshot):** the
  dashboard pinned `NetWorthCard` in a fixed 380px box while the compact
  header (hero + delta chips + currency chips + toggle + detailed-mode
  legend) stacked to 300px+, starving the `Expanded` plot to a ~40px sliver
  with overlapping y-labels. The card now self-sizes: header at natural
  height + a guaranteed width-derived chart height (220–280,
  `net_worth_card.dart`), fixed box removed from `dashboard_screen.dart`.
  Same bug class fixed in `wealth_projection_screen.dart` (fixed 320 box on
  the phone branch → card adapts: bounded host keeps the fill-the-flex
  behaviour, unbounded scroll column gets an intrinsic card). Pinned by
  `net_worth_chart_height_test.dart` (380px phone, simple + detailed + wide).
* **X-label overlap sweep (audit-driven):** house thinning rule (~1 label /
  46px, always keep the last, off the inner LayoutBuilder) applied to
  `account_balance_chart.dart` (also 130→180 tall), `spending_by_category_
  card.dart` (+ adaptive bar width), `upcoming_bills_card.dart` (160→200);
  `net_worth_card.dart` bottom axis gained the fractional-x guard + a
  keep-last collision guard (last two "Jul 2026" labels used to merge).
* **APK size/perf:** phone installs now documented as `--split-per-abi` —
  arm64 APK is 27.5MB vs 71.8MB universal (3 ABIs bundled). Universal stays
  the emulator/CI build. `RepaintBoundary` around the hero + projection
  charts (tooltip scrubbing no longer repaints the whole scroll layer).
* **Verified:** 540 tests + analyze (19 pre-existing infos only); web +
  both APK builds; release APK launch-smoked on the headless AVD; visual
  verification headless at 390px (profile web build + Playwright, claude_dev
  account): plot full-height in simple AND detailed mode, x-axis clean.
* **Rig note:** stale `.dart_tool/flutter_build` cache produced a web bundle
  whose plugin registrant was missing `SharedPreferencesPlugin` → local web
  boot died pre-`runApp` with MissingPluginException. `flutter clean` fixed
  it; prod builds in fresh Docker so unaffected (worth confirming web loads
  after the next prod deploy anyway).

## 2026-07-13 — Native Android passkeys (+ APK launch-crash fix)

* **APK launch crash fixed + emulator-verified:** R8 stripped WorkManager's
  Room-generated `WorkDatabase_Impl` no-arg ctor (WorkManager rides in via
  plaid_flutter) → instant `NoSuchMethodException` crash at startup. Keep rule
  in `frontend/android/app/proguard-rules.pro`; CI gained a `flutter build
  apk --release` gate; the emulator smoke test is documented in AGENTS.md
  ("Android APK" section — headless AVD needs the `sg kvm` wrapper).
* **Native passkeys (was a stub):** Android Credential Manager via a raw
  WebAuthn-JSON MethodChannel `patrimonio/passkeys` in `MainActivity.kt`
  (androidx.credentials 1.5.0; own channel because the `credential_manager`
  pub package's typed login options drop `allowCredentials`, which
  non-discoverable security keys need). `passkeys_io.dart` mirrors
  `passkeys_web.dart`'s HTTP flow 1:1; `isAvailable` = Platform.isAndroid so
  the test VM/desktop keep the inert-stub behaviour. Backend:
  `ANDROID_APK_CERT_SHA256` env feeds BOTH the extra webauthn-rs allowed
  origin (`android:apk-key-hash:<b64url>`, exact-Url-equality match in
  0.5.5) AND a new public `GET /.well-known/assetlinks.json` (nginx proxies
  the path to the api; 404 when unconfigured). Cloudflare Access needs a
  path-scoped Bypass application for that file (Google's servers fetch it) —
  steps in docs/deployment.md §"Native passkeys (Android)".
* **Verified:** backend passkey suite (9) + new assetlinks/origin tests +
  clippy clean; frontend 537 tests + analyze; web AND apk builds compile.
  Emulator end-to-end: passkey button on native login, server errors surface
  cleanly, Security→Add→This device reaches Android's system passkey sheet
  with the server's user identity, cancel maps to a clean bilingual
  snackbar. Remaining: user's on-phone test with the real security key + the
  CF Bypass application (dashboard step).

## 2026-07-11 sprint — round 10 (FIRE / wealth-projection UX overhaul)

Multi-agent pass over the projections screen: two live headless walkthroughs
(desktop 1440×900 + mobile 390×844/es-MX/extremes) + a code-level UX review →
PM triage → parallel frontend/backend implementation → live re-verification
(8/8 checks pass).

* **P0 (owner-reported):** milestone tiles never painted on phones (unbounded
  stretch-rows in a scroll view → ~1,700px blank void) and the desktop flex
  layout couldn't scroll at 1440×900 (tile row missing from the fit estimate →
  KPIs clipped). Fixed with bounded intrinsic-height rows, an `<800px` stacking
  threshold off the inner LayoutBuilder, and the tile row counted in `fixedH`;
  pinned by `milestones_layout_regressions_test.dart` (390/760/1440 widths).
* **Frontend UX batch** (all F-items + full stretch list): fetch-error state w/
  retry; honest defaults adoption (contribution independent of expenses,
  expenses need ≥3 months, "based on {n} months" / "estimate" hints);
  deterministic Monte Carlo (FNV-1a `mc_seed`, web-safe 32-bit); goal-dialog
  validation + save-failure snackbar (also fixed a latent dispose-during-exit
  crash); es→es_MX Intl mapping + Mexican number conventions in
  `percent_format.dart` (period decimals; Spain-style "12,5 %" removed);
  adaptive x-axis intervals; Barista-FI dead-end prompt; visible controls
  scrollbar; assumptions persisted as `projection_assumptions` setting;
  mean-vs-median legend honesty; success-rate n/a edge; 11 orphaned l10n keys
  deleted; 300ms debounce + stale-fetch guard; `didUpdateWidget` refetch;
  dashboard kebab a11y label "Options". ~15 new test files; 455 tests green.
* **Backend:** `/api/projections/defaults` hardened — per-row on-or-before-date
  MXN FX (reuses `tax.rs` `USD_MXN_ROW_RATE_SQL`, now pub(crate)) instead of
  latest-rate over 12 months; `Result<_, ApiError>` with loud 500s instead of
  fabricated zeros; `.round_dp(2)` outputs. Integration tests pin per-row FX +
  partial-month annualization. Clippy + full suite green.
* **Round-10b (owner approved all PM-deferred items; verified live 8/8):**
  chart upgraded — calendar-year x-axis + "{year} · {amount}" tooltip, dashed
  retirement marker, pink goal line + goal-year marker + Clear button,
  out-of-range goals clamp to the top edge instead of rescaling maxY; typed
  value entry on money sliders (expense floor now $4k, maxes auto-grow, typed
  values round-trip through `projection_assumptions`); savings-rate caption
  from `annual_income`; Barista-aware target tile; app-wide compact money
  (`displayMoney`: cents dropped at |value| ≥ $10k on display surfaces;
  ledgers/exports/tax stay exact). Backend: per-row historical FX applied to
  `cash_flow_trends`, `spending_by_category`, `spending_insights`,
  `emergency_fund` trailing-spend (current cash stays latest-rate by policy);
  regression tests fail against the old code. 481 frontend + full backend
  suites green.
* **Round-10d (dividend calendar redesign, verified live 6/6):** the 12-month
  calendar's staggered month cards (intrinsic-width cards centered in a
  Column — meaningless offsets, owner-reported from prod) replaced with a
  uniform 12-row bar list: month + proportional income bar + amount,
  tap-to-expand shows ALL payers inline (chips/tooltips/"+N more" deleted),
  two shared-scale columns at ≥720px via inner LayoutBuilder (was
  MediaQuery). Whole year fits one phone screen (~620px vs ~2.5 screens).
  Regression test pins uniform row widths at 390px. 494 tests green.
* **Round-10f (tracked-lots transparency + app-wide transient tooltips):**
  `/api/dashboard/benchmark-comparison` gained additive `symbols` (per-ticker
  lot count/invested/value/benchmark + first/last buy dates, same per-lot
  math, rows sum to totals) and `untracked` (+ total) fields; the "{n}
  purchases" line opens a "What's tracked" bottom sheet (per-ticker ±pts vs
  index, untracked/excluded section, en+es, degrades on old backend). All 11
  fl_chart tooltips are now transient scrub indicators via shared
  `utils/chart_touch.dart` (`TransientTooltipLine/BarChart`): owner-reported
  pinned-tooltip-on-mobile bug fixed — root causes were fl_chart's web tap-up
  carve-out AND Flutter web's synthesized post-tap-up hover (kind=touch),
  both dismissed now unless the pointer can hover. Verified by touch
  emulation on TWR/net-worth/trends charts + desktop hover regression.
  517 frontend / 123 dashboard-integration tests green. Latent note:
  benchmark card treats h.value as USD as-is (existing convention) — belongs
  with the FX-policy audit follow-up.
* **Round-10e (polish):** expanded calendar rows show the bare localized date
  (full `calEstExDate` wording kept in semantics) so nothing ellipsizes at
  390px — TextPainter-measured test proves the fit; "Investments vs S&P 500"
  card gained the `bmContribCaveat` caption explaining why the money-weighted
  tracked-lots figure can sit far below the TWR above it (en + es). 498 tests.
* **Round-10c (follow-ups, verified live):** the four dashboard chart handlers
  now return `Result<_, ApiError>` — DB errors are logged 500s, not empty
  charts / all-zero runways (empty DATA still 200s with the empty shape);
  chart tooltip owns its hover state (`handleBuiltInTouches: false` + manual
  `showingTooltipIndicators`) and dismisses on mouse-out; typed entry extended
  to all seven percent/year sliders (hard bounds, integers-only years, es-MX
  strings). 488 frontend + 122 dashboard-integration tests green. Deployed to
  thelab.

## 2026-07-09 sprint — round 9 (cross-tool AGENTS.md, palette contrast, lint cleanup)

* **Cross-tool agent guide:** new canonical `AGENTS.md` (skills pointer up top +
  project orientation + run/test/enforcement summary). Claude Code reads it via a
  `@AGENTS.md` import in `CLAUDE.md` (documented cross-platform pattern — CC does
  NOT read AGENTS.md natively); `GEMINI.md` is now a symlink to it. One source of
  truth for all agent tools. (Committed `24394cb`.)
* **Lint cleanup:** enabled `directives_ordering` and cleaned the tree via
  `dart fix` (39 files). Deferred `avoid_catches_without_on_clauses` (~186) — the
  mechanical fix is behaviour-identical lint-theater; doing it right is per-site
  work. (Committed `24394cb`.)
* **Palette light/dark contrast pass** (17 files): found + fixed a real
  light-mode contrast **bug** — accent buttons hardcoded their label color
  (`Colors.black`/`white`), correct in only one theme, since `context.positive`
  is dark `#0C6A56` on white / bright `#3FD3AE` on dark. New luminance-aware
  `context.onAccent(accent)` token (picks the AA-clearing black/white) + a
  contrast test on both theme fills. Nav-rail accents refactored from const neon
  hexes to brightness-resolved `BrandPalette` tearoffs. ~50 hardcoded
  `Colors.X`/hex swaps → the `context.*` extension (notifications, snackbars,
  empty-state greys → `textFaint/textSubtle`, `Colors.black12` pills →
  `tileSurface`). Left intentional colors alone (QR black-on-white, Coinbase
  brand blue, transparents, scrims). 395 frontend tests pass; analyze clean.
  **Recommend a human visual check in both themes** for the accent buttons, nav
  rail, and notification-bell rows (they now render the deeper AA shades in
  light mode).

* **Authored two project skills** in `.agent/skills/` (the repo's existing
  cross-tool skills dir, alongside `backend-dev`/`dev-workflow`/`work-tracking`):
  `.agent/skills/rust-backend/SKILL.md` and
  `.agent/skills/flutter-frontend/SKILL.md`. Each is grounded
  in this codebase's real conventions and the bug classes it has hit
  (carry-forward aggregation, FX/USD money invariants, per-user scoping,
  loud-skip tests; gen-l10n placeholder alphabetization, locale-aware
  formatting, responsive width-awareness). Each ends with a "Definition of
  done" review checklist. Built from two Explore-agent codebase analyses.
* **Applying the skills surfaced real defects** (found via two audit agents):
  * **gen-l10n placeholder transposition (§2 trap): 16 sites fixed.** The
    generated method params are ALPHABETICAL, but call sites passed
    template order — silently swapping same-typed (money/date/string) args.
    First found in `trends_chart.dart` (`lwTrendsSemanticSummary`); an
    exhaustive audit found 15 more across notifications, tax-harvest,
    transfers, goals, imports, webhooks, since-login banner. All reordered
    to alphabetical + `// gen-l10n orders …` comments.
  * **`trends_chart.dart` two edge-case crashes** the regression test caught:
    `clamp(2, count)` threw `ArgumentError` on a single-month portfolio;
    passing an int `toY` to fl_chart threw on whole-number JSON amounts.
    Both now num-coerce / guard the clamp floor. Plus an es-locale header
    Row overflow (title now `Flexible` + ellipsis).
  * **Backend cross-currency bug (HIGH):** `GET /accounts/summary` summed
    balances across currencies with no FX — the ~18x overstatement class
    (a $1k USD + MX$20k portfolio reported ~$21k assets). Now converts per
    row via `latest_usd_mxn_rate`, mirroring `dashboard_overview`. New
    regression test `accounts_summary_converts_mxn_to_usd_not_raw_sum`.
  * **Backend error leakage (§1):** raw internal error strings returned to
    clients on 500s in `passkeys.rs`, `institutions.rs` (`details` field),
    and 8 `tax.rs` arms. All now log server-side + return a generic message.
* **Tests added:** `test/components/trends_semantic_summary_test.dart`
  (bilingual, also guards both crashes), `test/l10n/placeholder_order_test.dart`
  (5-method contract guard), backend FX regression. **All green:** frontend
  393 tests + analyze clean; backend `cargo test` exit 0 (244 lib + 107
  dashboard + 31 + 7 + 4 + 3, 0 failed, no warnings).
* **Skills follow-up:** verified the Agent Skills spec (docs.claude.com) — a
  skill = a dir with `SKILL.md` (frontmatter `name`+`description` only); a
  container-root `README.md` is NOT recognized (none added). Added
  general-language-conventions companion files per skill (progressive
  disclosure, linked from SKILL.md): `rust-conventions.md` (Fuchsia rubric +
  Rust API Guidelines + clippy) and `dart-flutter-conventions.md` (Effective
  Dart + Flutter style guide + lints).
* **Skill discovery (cross-tool):** canonical skills live in committed
  `.agent/skills/`; Claude Code only auto-discovers `.claude/skills/`, but a
  `.claude/skills` entry can be a symlink and CC follows it — so
  `.claude/skills -> ../.agent/skills` (local, since `.claude/` is gitignored)
  makes CC discover all 5 skills. Recreate on fresh checkout:
  `ln -s ../.agent/skills .claude/skills`.
* **Second improvement pass (language-convention audits):** two more real
  request-triggerable backend DoS bugs fixed — `clamp_day` day-of-month=0
  underflow (release: ~4.3B-iteration spin on the async worker;
  `loan_schedule.rs`) and unbounded `years` (multi-GB `vec!` → process OOM
  abort + `years*12` i32 overflow; `projections.rs`, now clamped to 120 via a
  `years()` accessor). Frontend: `add_crypto_dialog` leaked 4 controllers (no
  `dispose()`); `budgets_card` editor leaked per-category controllers;
  allocation-heatmap + trends hard JSON casts hardened (null → no crash). Both
  DoS fixes have regression tests. Full suites green: backend 246 lib + 152
  integration (0 warnings), frontend 393.
* **Committed + pushed to `main` (`ddc19a1`); deployed to thelab** (api :8085
  + frontend :3004 healthy).

## 2026-07-08 sprint — round 8 (enforce the skills: lints + clippy)

Turned the convention docs into enforced guardrails so the fixed bug classes
can't recur:
* **Frontend:** swept the ~12 deferred dialog-local `TextEditingController`
  leaks across 7 files (add_crypto already fixed in round 7); enabled
  `cancel_subscriptions` + `close_sinks` (**promoted to `error`** in
  `analyzer.errors:` — zero backlog, so a future leak breaks the build) plus
  `use_rethrow_when_possible` + `prefer_final_locals`. Fixed one real
  `use_build_context_synchronously` (security_screen invite flow: unguarded
  `context` after a `Clipboard.setData` await). Deferred the large-backlog
  lints (`avoid_catches_without_on_clauses` ~186, `directives_ordering` ~108).
* **Backend:** made the tree **clippy-clean** (36→0 warnings) — auto-fixed the
  safe ones; real fixes incl. a regex compiled inside a parser loop (hoisted),
  a `.replace("month","month")` no-op, two collapsible identical-if branches,
  `sort_by_key(Reverse(..))`, a nested `format!`; scoped `#[allow]` + rationale
  for the intentional ones (a `TAX_CONSTANTS_VERIFIED` tripwire assert,
  needless_range_loop false positive, complex sqlx row-tuple types,
  builder/test-helper arg counts). Added a **CI clippy gate**
  (`cargo clippy --all-targets -- -D warnings`) so warnings now fail the build.
* Conventions companion files updated to record what's now enabled/gated vs
  still deferred. Tests: backend 246 lib + 152 integration (0 warnings, clippy
  clean), frontend 393. All green.

## 2026-07-08 sprint — round 6 (card terms, balance chart, net-worth carry-forward fix)

* **net_worth_history carry-forward bug (user-reported).** The Overview
  net-worth movers showed a HealthEquity HSA "+$49k since June" — but the
  HSA syncs weekly and had no snapshot on the exact baseline date, so
  `net_worth_history` (which aggregated per exact `as_of_date` with no
  carry-forward) dropped it from that date's `by_institution` + total, and
  the movers read its full balance as growth-from-zero. Same class as the
  round-2 `portfolio_value_history` fix; applied the identical per-account
  carry-forward (last snapshot on-or-before each date) to totals + the
  institution map. Verified on prod: mover dropped $49,000 → $1,360 (real
  HSA growth). New regression test reproduces the missing-at-baseline case.
* **Per-card statement balance + due date + "due soon"** (enhanced
  `debt_payoff_card.dart`, rides `app_settings` key `card_terms`, no
  migration): per-row terms editor next to the APR chip + a due-soon strip
  (monthly due dates rolled forward, sorted, min-payment shown).
* **Balance-over-time chart for all accounts** (`account_balance_history`
  backend fallback to `balance_snapshots` when a statement account has no
  `balance_after` history) — the chart now appears for Plaid/manual
  accounts too.
* **Housekeeping:** 5 merged remote branches pruned (remote = main +
  gh-pages only). const-literals lint sweep (10 fontFeatures sites).
* **Audit follow-ups** (all `balance_snapshots` per-date consumers reviewed):
  the only other same-class bug was FBAR — `fbar_status.exceeded` used the
  largest same-day foreign-account sum, so accounts snapshotting on
  different days never aggregated and could under-report the $10k filing
  threshold. Now `exceeded`/`peak_aggregate_usd` = SUM(per-account annual
  max) (FinCEN 114's measure, never under-reports); peak_date is the
  carried-forward peak day. Verified on prod: aggregate $51.8k→$65.3k
  (exceeded already true via CetesDirecto). The other consumers
  (account_balance_history per-account, since-last-login before/after
  intersection) are safe by design. Also fixed the cash-flow Trends chart
  x-axis month labels overlapping on mobile (width-thinned + compact
  2-digit year).

## 2026-07-08 sprint — round 5 (debt, movers, quick wins, CI, cleanup)

Investigation-first (much already existed) → 3 parallel workstreams +
Opus 4.8 adversarial review + browser verify.

* **CI silent-skip fixed.** The round-4 Redis dividend-cache integration
  tests hardcoded dev Redis (:6380, auth) → unreachable in CI (:6379, no
  auth) → all 5 vacuously skipped-and-passed (the exact silent-skip class
  test.yml exists to prevent). Harness now reads `PATRIMONIO_TEST_REDIS_URL`
  (falls back to dev :6380 locally) and PANICS when set-but-unreachable;
  CI wired to its service. Verified running green.
* **Stale branch deleted.** `claude/adoring-merkle-da8ff6` (2 months / 459
  commits divergent) evaluated commit-by-commit → every change already
  superseded on main (same `_KeepAliveTab`, same parent-map-mutation fix,
  byte-identical transaction_description.dart, larger palette-contrast
  test), un-mergeable. Deleted. (Other merged remote branches remain,
  prunable.)
* **Debt summary strip** (enhanced `debt_payoff_card.dart` — the card
  already had APR/avalanche/snowball/utilization): total owed, weighted
  APR, and monthly interest cost (Σ bal·apr/12, warning-colored) + a
  credit-vs-loan split. Client-derived, no backend.
* **Net-worth "since baseline" movers** (enhanced `net_worth_card.dart` —
  MoM/YoY deltas already existed): top-3 institution movers attributed
  from the `by_institution` map already in the history payload. No backend.
* **Quick wins:** ES `lwRangeAll` was the literal placeholder "TODO" →
  "Todo"; new locale-aware percent helpers (`utils/percent_format.dart`)
  swept across ~36 sites incl. the rebalancing card (es now comma-decimal
  + NBSP before %; en byte-identical by construction); performance-card
  charts ported to time-proportional day-offset x-ticks
  (`utils/chart_time_axis.dart`, matching the instrument sheet).
* **Opus review:** no blockers/high; brute-forced the percent helper vs
  old output (no 100×/%%/sign error). Follow-ups applied: helper switched
  off decimalPercentPattern (its ×100 round-trip shifted .5 boundaries)
  to toStringAsFixed so en is truly byte-identical; applied to the 3
  chip sites the feature workstreams had left. Debt strip + movers weren't
  exercisable in the investment-only dev DB (unit-tested; render on prod
  where the 8 cards + full history live).

## 2026-07-07 sprint — round 4 (dividend infra + rebalancing + charts)

## 2026-07-07 sprint — Round 4 (dividend infra + rebalancing + charts)

Four parallel workstreams + Opus 4.8 adversarial code review + two browser
verifiers; all shipped to prod. No new migrations.

* **Dividend fan-out caching (backend).** Per-symbol Redis envelope
  (`div:v1:{SYMBOL}`, 7d retention): serve <12h fresh, refetch stale with
  stale-served-on-Yahoo-failure fallback, 1h negative marker, in-process
  per-symbol coalescing, `?refresh=true` bypass on the detail endpoint.
  All three dividend call sites cache-backed; Redis-down degrades to live
  fetch. Warm portfolio fan-out ~14ms vs ~337ms cold. Cache key is
  user-agnostic (dividend data is market-public — no per-user leak).
* **12-month dividend income calendar.** Additive `calendar` field on
  `/dashboard/holdings/dividends` (shares the detail endpoint's
  `projected_ex_dates` stepping; response shape frozen by snapshot test);
  UI is a "Show 12-month calendar" expander in the dividend card (3×4 grid
  / mobile list, per-month totals, payer chips). Detail sheet got a manual
  refresh button.
* **Target allocation & rebalancing card.** New card between the
  allocation heatmap and Signals. Targets per canonical asset class stored
  in `app_settings` (`allocation_targets`, no migration); drift bars +
  "move $X from A to B" guidance (greedy pairing, $500 floor, mandatory
  tax caption); sum-to-100 editor; unclassified kept in the denominator.
  Owner's dev targets left at equity 85 / bonds 10 / cash 5.
* **Chart hover completion.** Shared `utils/chart_touch.dart` gives the
  four previously hover-dead charts (performance value + TWR, cash-flow
  net sparkline, account-panel balance sparkline) the standard
  guide+dot+token-tooltip treatment. (The palette/tooltip overhaul from
  FUTURE.md had mostly shipped earlier in `f3dfd97`/`1a33bbf`.)
* **Fix-up (verifier + Opus findings):** tooltip fit-inside so the
  account-panel sparkline stops clipping at the viewport edge; projections
  tooltip placeholder order (gen-l10n alphabetized `amount,year` vs the
  call site — same class as the round-1 transposed counter); calendar
  current-month accent derived from the server's UTC first bucket, not
  local `DateTime.now()`; rebalance missing-class → `unclassified` not
  `other`. Opus review found no blocker/high; verifiers all-PASS.

## 2026-07-06/07 sprint — Portfolio ("Invest") tab overhaul

Three multi-agent rounds (walkthrough → PM backlog → parallel dev
workstreams → browser verification → deploy), all shipped to prod:

**Round 1 — the four user-reported issues.**
* Dividend frequency fix: `per_year` counted ex-dates in a trailing 365d
  window → quarterly payers intermittently read 5×/yr and annual income
  ran ~25% hot. Now: median-interval snap (12/4/2/1), rate = cadence ×
  last cycle avg, stale payers decay (window anchored at *today*).
* Bonds filter: predicate OR'd all dimensions (`'bonds'` is also an
  account type → match-everything) + zero in-viewport feedback. Now:
  `asset:`/`account_type:`/`institution:`-prefixed filter values, a
  canonical `asset_class` classifier (VBTLX-style bond *funds* land in
  Bonds), band tap auto-scrolls to the table with a "Filtered: X ✕" pill.
* Realized gains: `_maxRows = 8` with a dead "+N more" label → "Show all"
  toggle; Tax planning's year dropdown was circularly derived from
  year-filtered data → now fed from `by_year` (2025 reachable).
* NEW dividend detail sheet: payer rows tappable → schedule, 2y history,
  per-payment amounts, accounts w/ tax-advantaged badges
  (`GET /api/dashboard/dividends/{symbol}`).
* Critical fix found during walkthrough: holding delete cascaded
  lots + realized-gain tax records with NO confirmation → confirm dialog.

**Round 2 — deferred backlog.**
* Instrument detail sheet (chart from `benchmark_prices`, stats, lots,
  accounts; `GET /api/dashboard/instruments/{symbol}?range=`).
* Day change (stored-close based, coverage-aware) on rows + header pill.
* CSV exports: holdings / lots / realized gains (`?year=`).
* Realized gains: year chips, account context + `taxable_realized_usd`
  (badge + reconciliation caption vs Tax planning), Roth marker.
* Upcoming ex-dates uncapped (server truncated to 5 → Sep dates missing).
* Unclassified allocation band for holdings-less investment accounts.
* Real data bug: `portfolio_value_history` summed per-date snapshots →
  partial syncs collapsed the series to one account; now carries each
  account's last-known balance forward.

**Round 3 — everything else.**
* Per-symbol asset-class overrides (table `asset_class_overrides`,
  editable chip in the instrument sheet, wins at all classify sites).
* Holding soft delete + 10s undo snackbar + restore endpoint; 24h lazy
  purge; `deleted_at IS NULL` audited across every read surface.
  **Rollback caveat:** `ignore_missing` lets an older binary *boot*
  against this DB, but a pre-overhaul binary neither filters
  `deleted_at` nor runs the purge — soft-deleted-but-unpurged holdings
  reappear in every figure (and DELETE is hard again) until the new
  binary is back.
* Dividends surfaced on Overview (stat tile → tap-through) and
  Projections ("income outlook" panel — informational only, provably
  never touches the projection request/curve).
* App-wide a11y sweep (filter chip announced as bare "Delete" checkbox →
  labeled; one-sentence rows; header landmarks; zero unlabeled controls).
* Mobile polish: two-line lot rows at 390px, unclipped toolbar,
  time-proportional chart ticks, holding-subtitle truncation priority
  (account survives; fund legal name gives way) + Account/Institution in
  the expanded row.
* `sqlx` migrator now `ignore_missing` (old binary can boot a newer DB).

**Ops/process notes.**
* Dev services relocated into the repo: `pgdata/` + `redisdata/`
  (gitignored), ports 5442/6380 unchanged. `$HOME` is clean.
* Dev DB has a seeded ~$385k test portfolio under user `claude_dev`
  (kept intentionally for future UI testing; incl. VBTLX typed
  'mutual fund' and a holdings-less CETES account for classifier tests).
* Browser-driving harness for the Flutter web build (semantics tree via
  Playwright) documented in the session memory; `scripts/set-nicknames.sh`
  one-shot for prod account nicknames (run manually — prod auth writes
  are permission-gated in agent auto mode).
* Docs: `docs/adding-accounts.md` §5 now recommends nicknaming accounts
  (imported legal names dominate every subtitle/export; the five
  suggested prod nicknames apply via `scripts/set-nicknames.sh`).
* Same day, pre-overhaul (separate session, `0efba89`..`04f7754`):
  mask-aware account names app-wide + the `..mask` suffix survives
  truncation, accounts-list row alignment + type-aware sub-group labels
  + same-named-card disambiguation, and the Lending tab localized
  end-to-end (status pill, Add/Edit-loan dialog). Logged in HANDOFF.md.

## Where we are

Patrimonio is well past "MVP." All of NEXT.md's original Tier-1 items
have shipped. The app now does:

* Multi-user, invitation-based registration with TOTP / passkeys /
  recovery codes.
* Plaid Production for US accounts, including encrypted at-rest tokens,
  webhook receipt with ES256 verification, and per-item scoped sync.
* Mexico imports via CSV/PDF (Nu, Banamex, Cetesdirecto), and Coinbase
  + Bitso for crypto.
* FX-aware investment lots with dual-currency P&L.
* Encrypted nightly backups + a tested restore drill (see
  `docs/operations.md`); rotate-encryption-key one-shot binary shipped
  in the api image.
* Smarter transaction labels (counterparty → merchant → payment_meta
  → original_description → description, with a generic-prefix
  allowlist for "Miscellaneous Debit"-class strings), per-row rename
  + bulk-rename for clusters.
* "Since last login" banner with deep-link to the date-filtered tx
  list.
* Sticky reconnect banner that opens Plaid Link inline (no Management-
  tab detour).
* Recurring-charges card with merchant clustering + "Not a
  subscription" dismiss.
* Cross-currency cash-transfer linking (Wise / Remitly / Xoom /
  Western Union detection with implied FX rate). Auto-runs after
  every sync.
* Cash-flow chart bars are tappable — clicking a month group filters
  the Transactions tab to that date range.
* Split transactions with live-validated sum + Unsplit.
* CSRF defence-in-depth via `X-Requested-With` middleware.
* Trusted-proxy aware client_ip — XFF / X-Real-IP stripped from
  untrusted peers at the edge.
* `app_settings.user_id` (M7 leftover) — budgets / goals no longer
  leak across users.

## Personal lending — feature complete (2026-05-30)

Opt-in lending module shipped end-to-end across MVP + Phase 2 +
Phase 3 + interest-income accounting. Full design + per-phase
breakdown in `work/LENDING_FEATURE.md`. Migrations 2026052802 →
2026052806; ~115+ backend tests; frontend `widgets/lending_tab.dart`.

* **MVP.** Per-user `lending_enabled` toggle in the Management →
  Modules card gates a conditional "Lending" tab. New `loans` +
  `people` (reusable borrower directory) + `loan_payments` tables;
  full CRUD; link a real bank transaction as the disbursement;
  record/reconcile repayments. Auto-suggest matcher
  (`services/loan_match.rs`, ±2% disbursement / ±5% repayment
  tolerance + a borrower-name bonus). Loan-linked transactions are
  excluded from cash-flow (receivable, not spending — GnuCash model).
* **Phase 2.** Amortization schedule generation
  (`services/loan_schedule.rs`, all `Decimal`, final-row residual
  absorption so `Σprincipal == principal`). `POST /loans/{id}/schedule`
  (409 if any payment is reconciled, 422 if open-ended). Derived
  `next_due` / `overdue` / `paid_ahead`; `'defaulted'` + `'written_off'`
  statuses. `GET /loans/reminders` surfaced in the notifications bell
  with a configurable lead-time stepper.
* **Phase 3.** Fixed a trailing-slash 404 (`GET /api/loans/` 404'd
  under axum nest → "couldn't load loans"; client now uses the
  no-slash collection path + a guard test). Flexible per-year /
  per-month interest via a `rate_period` column (stored faithfully,
  no lossy reconversion); `interest_only` + `compound` interest types;
  a Cmd-K "Jump to Lending" palette entry.
* **Interest-income accounting.** Principal/interest split stored per
  repayment (US Rule, interest-first) at reconciliation.
  `GET /loans/interest-income` per-loan + per-month + grand-total
  report (cash basis); a separate loan-interest CSV + per-borrower
  year-end summary CSV (keeps the transactions export clean);
  printable promissory-note HTML at `/loans/{id}/agreement`;
  `interest_accrued` informational figure; §7872 below-market flag for
  0% loans > $10k. Tax content is structural/factual (IRS Topic 403,
  §7872, Schedule B), surfaced as data — not advice.

**Deferred follow-ups** (see `work/LENDING_FEATURE.md`): multi-currency
loan reporting-currency conversion; mid-stream re-amortization after a
partial payment; Schedule-B-*formatted* (vs raw CSV) year-end document.

## Pre-merge gate (`scripts/check.sh`) (2026-05-29)

Follow-up to the perf sprint that revealed two recent bugs slipped
through to commit + merge: a frontend `await onUpdate(id, {...map})`
call against a named-arg callback (would crash at runtime on first
double-click), and a `'\x00'` sentinel literal that turned the file
into git-binary.

* New `scripts/check.sh` runs the backend test suite AND
  `flutter analyze` (errors + warnings parsed from output — Flutter's
  exit code semantics for `--fatal-warnings` were version-dependent).
  Info-level diagnostics are surfaced but don't fail the gate. Use
  `--skip-backend` / `--skip-frontend` for fast iteration. Opt-in
  pre-commit hook line documented in the script header.
* Cleaned the 3 pre-existing warnings to make the baseline gate
  green: dropped `_types` getter in `add_account_dialog.dart`
  (replaced by the grouped DropdownMenuItem layout), removed unused
  `transaction_description.dart` import in `transactions_tab.dart`,
  removed dead `originalDescription` local at the detail-modal site.
* New `.gitattributes` forces `*.dart` / `*.rs` / etc. to be treated
  as text so a future stray control byte doesn't trip git's binary
  heuristic again.

## Transactions list perf bundle (2026-05-29)

Five compounding wins targeting the transactions tab at scale
(~5000+ rows). Before: typing in the search field re-filtered the
full list per keystroke and re-rendered every row offscreen. After:
the list virtualises, search debounces, and the filter is cached.

* **Silent post-mutation reloads.** Every `_loadAllData()` call
  after a rename / delete / balance update / institution delete /
  return-from-import passes `silent: true` so the dashboard's
  in-place state (scroll position, drilled-in filter, currency
  toggle) doesn't get nuked behind a full skeleton flash. Reserve
  loud loads for initial mount + explicit Retry.
* **Description→ids index in transactions_tab.** `_similarTransactionIds`
  was O(N) per call — right-click on a "MISC DEBIT" cluster of 50
  rows did 50×N scans. New `_descIndex` is a `Map<lcRaw, List<id>>`
  built once when `widget.transactions` identity changes; the
  lookup is O(1).
* **120ms search debounce.** Typing "rent" was 4 full re-filters;
  now it's one. Cancelled + flushed synchronously on the X close
  button so the panel doesn't get a stray re-filter mid-collapse.
* **Filter result cache + per-tx haystack cache.** `_filteredTransactions`
  was a getter that re-walked + re-lowercased 9 fields per row on
  every setState (hover, selection toggle, inline-edit flip). Now
  keyed on `(identityHashCode(txs), _searchQuery, _filters)` with
  per-tx lowercased haystack memoized on `_haystackCache`. Search
  becomes one `.contains()` per row against a pre-joined haystack
  string instead of 9 separate calls.
* **Virtualised list region.** For >50 rows the eager `Column` of
  every row gives way to a bounded `ListView.builder` (viewport-
  relative height with a 400px floor) feeding off a flat
  `_TxListItem` plan that interleaves headers/rows/dividers. Off-
  screen rows no longer build at all. UX trade: the tx list now
  scrolls inside the card rather than as part of the page, but it
  matches the Gmail / Notion pattern for huge lists.

## Backlog cleanup bundle sprint (2026-05-28)

Five medium FUTURE.md items closed:

* **serial_test crate annotated on every integration test.** The
  `auth_endpoints` / `auth_recovery_totp` / `dashboard_endpoints`
  trios share a Postgres + TRUNCATE in setup, which previously
  required `--test-threads=1` pinned at the wrapper. Every
  `#[tokio::test]` now also carries `#[serial_test::serial]`, so
  plain `cargo test` Just Works regardless of thread count. The
  wrapper still pins the flag belt-and-braces for new tests that
  forget the annotation.
* **PDF parser merchant_code/payee plumbing.** Added
  `original_description: Option<String>` to `ParsedTransaction`
  (with `#[serde(default)]` + a `Default` derive so existing
  callers keep compiling). `polish_all` now stashes the raw
  pre-polish line in `original_description` when polishing
  meaningfully changed the value; the import-confirm handler
  inserts both columns. The frontend's existing displayLabel ladder
  (`user_description → counterparty → merchant →
  original_description → description`) picks the verbatim line as
  fallback. Two new unit tests cover the capture-when-changed and
  skip-when-unchanged paths.
* **True inline transaction rename.** Double-click on a transaction
  row's label drops it into inline-edit mode — the label swaps for
  a TextField pre-filled with the existing `user_description`. Enter
  commits via the existing `onUpdate` callback (which already
  understands `user_description: ''` as a clear-override directive),
  Esc / blur cancels. The right-click → dialog flow stays as the
  bulk-apply-to-N fallback.
* **R keyboard shortcut.** A `Focus` widget at the TransactionsTab
  level captures the R key and triggers inline-edit on the most-
  recently mouse-hovered row. Safely no-ops when focus is inside
  any EditableText (search box, inline-edit field) so R types
  normally there. Mouse-tracking is via per-row MouseRegion that
  updates `_hoveredTxId` on enter/exit.
* **lot_disposals audit trail.** Migration
  `2026052801_lot_disposals.sql` adds a per-lot, per-sell-event
  table capturing the realized P&L crystallised at the moment of
  sale. Sync's FIFO depletion loop now inserts one disposal row
  per lot consumed (with the sell-side FX rate, the cost-side FX
  rate from the depleted lot, the qty sold, and pre-computed
  `realized_pnl_usd`). Idempotent via unique
  `(user_id, sell_source_id, lot_id)`. The audit history is durable
  even if the original lot row gets later deleted (lot_id is
  `ON DELETE SET NULL`).

## Cross-currency + lots + webauthn-AEAD + chart hover sprint (2026-05-27)

Four more pickup-bundle items from `work/FUTURE.md`.

* **Cross-currency transfers in the cash-flow tab.** New widget
  `widgets/cross_currency_transfers_card.dart` lists every linked
  Wise / Remitly / wire pair with implied rate, day's spot rate,
  and a +/- delta pill so the user can see at a glance whether the
  remittance service paid out above or below market. Confirm and
  Unlink inline (the same `/api/dashboard/fx-transfers/{id}` PATCH
  and DELETE handlers the tx-detail modal already uses). Backend
  endpoint enriched: each row now carries `spot_fx_rate` populated
  by a per-date subquery against `exchange_rates` (USD↔MXN nearest
  within ±7 days of the source date). New integration test
  `fx_transfers_listing_populates_spot_rate` locks the shape in.
* **Per-lot breakdown for holdings.** `/api/dashboard/holdings` now
  returns a `lots[]` array per holding when `holding_lots` rows
  exist (zero-qty depletion markers filtered out, FIFO ordered).
  Frontend portfolio rows with lots get a click-to-expand modal
  showing acquisition date, qty, native cost per unit, USD/native
  FX at acquisition, and the resulting USD cost — answers the
  recurring "why does my MXN P&L differ from a naive conversion"
  question by showing the historical FX rate column explicitly.
* **AEAD encryption of webauthn flow state in Redis.** The per-
  flow PasskeyRegistration / PasskeyAuthentication state was
  previously stored as plaintext JSON behind a 5-minute TTL. A
  Redis snapshot leak inside that window would have let an
  attacker replay an in-flight registration and bind their own
  authenticator to a victim's account. New `store_state` /
  `take_state` round-trip the state through AES-GCM using the
  existing `ENCRYPTION_KEY`, prefixed `v2:` for format dispatch.
  Falls back to `v1:` plaintext + a warn log when no encryption
  key is configured so local dev keeps working without
  re-configuration.
* **Net-worth chart hover polish.** `touchSpotThreshold` was 24
  (a 2× bump over fl_chart's default 10) — still required the
  cursor to be near the line. Bumped to 100000 + a horizontal-
  only `distanceCalculator` so the closest sample on the X axis
  always wins, regardless of vertical distance. The vertical
  guide + highlighted dot already in place now fires continuously
  across the chart's full plot area — matches the Robinhood /
  Mint / Personal Capital pattern. Same treatment applied to the
  wealth-projection chart.

## Realtime coverage + manual assets + HIBP sprint (2026-05-26)

Pickup-bundle from the next-tier follow-ups in `work/FUTURE.md`.

* **Realtime emit coverage expanded.** The websocket hub now
  receives publishes from every mutating handler the dashboard
  cares about, not just sync + import. `update_transaction`
  (rename / category / move), `delete_transaction`,
  `update_account_balance`, `update_account_nickname`,
  `create_account`, `delete_account`, all three split branches
  (POST / PUT / DELETE), `create_manual_transaction`,
  `confirm_fx_transfer`, `unlink_fx_transfer` each call
  `state.realtime.publish(ctx.user_id, ...)` after the write
  commits. Multi-tab consistency now matches every user-visible
  mutation end-to-end. Event vocabulary unchanged
  (TransactionsChanged / AccountsChanged) — the frontend collapses
  every event onto `_loadAllData(silent: true)` so the routing is
  uniform.
* **Manual-asset revaluation (FUTURE.md 4).** New migration
  `2026052601_valuation_notes.sql` adds a `valuation_notes TEXT`
  column on `balance_snapshots`. `update_account_balance` accepts
  an optional `notes` field; the snapshot upsert stores it and
  preserves the existing note when the new payload omits one. The
  add-account dialog already supported `Real Estate` / `Private
  Equity` / `Vehicle` / `Collectibles` / `Other Asset` types; the
  follow-on UI is a per-row "Revalue" popup menu item that opens
  a dialog with the current balance pre-filled + a notes field.
  Surfaced only when `account_type` is in the manual-asset set so
  the menu stays clean for syncable accounts.
* **HIBP breached-password check (audit L3).** New
  `password::check_hibp_breached(password, api_base)` async
  helper. SHA-1's the password, sends the first 5 hex chars to
  `${api_base}/range/{prefix}` with `Add-Padding: true`, scans
  the suffix list for a hit. Fail-open on any network error so
  HIBP downtime never blocks signup; embedded 250-entry breach
  list (`common_passwords`) still catches the obvious picks.
  Wired through a new `enforce_password_policy(state, password)`
  helper into `bootstrap`, `register`, `change_password`, and
  `recover`. Config field `HIBP_API_BASE` defaults to
  `https://api.pwnedpasswords.com`; tests + air-gapped
  deployments set it to empty to skip the network call entirely.
  Added `sha1 = "0.10"` as a direct dep (already transitive).

## Multi-user roles + realtime + upload-progress sprint (2026-05-19)

Massive bundle of Tier 1 + Tier 2 backlog. Five items in one
batch — schema migration + middleware + RealtimeService + side-
channel polling + cross-tenant tests.

* **Multi-user roles (owner vs read-only).** New migration
  `2026051901_user_roles.sql` adds `role TEXT NOT NULL DEFAULT
  'owner'` to both `users` and `invite_tokens` (CHECK
  constraint covers the enum). `validate_and_touch` joins
  users to surface the role on every authenticated request;
  `AuthContext` carries it. New `require_owner` middleware
  403s mutating requests when role != 'owner'; mounted on the
  business sub-router (NOT on /api/auth/* — every
  authenticated user must be able to log out, change their
  own password, manage their own passkeys). Invite mint
  endpoint accepts a `role` field; redemption copies it onto
  the new user. `/api/auth/me` exposes role so the frontend
  can hide write affordances. Three new integration tests
  cover the read-only path.
* **Sessions "new since last visit" badge.** Active-sessions
  list flags any session whose `created_at >
  users.previous_login_at` with an amber pill. Backend
  computes the diff per row in `list_sessions`; frontend
  ActiveSession model carries the flag; Security screen
  renders it next to the "This device" pill.
* **Cross-tenant isolation integration tests.** Two new
  tests (`cross_tenant_isolation_dashboard` +
  `cross_tenant_isolation_sessions_list`) hand-roll two
  owners with non-overlapping data, then assert every read
  endpoint returns only the caller's slice and every
  mutating endpoint 404s on a foreign id. Belt-and-suspenders
  for the ~60 user_id predicates.
* **Per-file upload progress (take 2).** Side-channel
  polling design — the upload POST stays synchronous (no
  bidirectional stream → no ERR_CONNECTION_RESET); when the
  client sends `X-Upload-Job-Id`, the server registers a
  progress entry in an in-memory `Arc<RwLock<HashMap>>`. The
  frontend generates a UUID, sends the header, and polls
  `GET /imports/progress/{job_id}` every 250 ms in parallel
  with the upload. UI renders "Processing N of M files… ·
  Last: foo.pdf" exactly like take 1, just over a
  non-shared connection.
* **Real-time dashboard via websockets.** New
  `services::realtime::Realtime` hub holds a per-user
  `tokio::sync::broadcast::Sender`. New `GET /api/realtime/ws`
  endpoint on the protected router upgrades to a websocket,
  subscribes the user, fans events over the wire. Sync +
  import handlers publish `TransactionsChanged` events.
  Frontend `RealtimeService` connects with capped
  exponential-backoff reconnect (1→2→…→30 s); dashboard
  subscribes once at boot and routes every event into the
  existing `_loadAllData(silent: true)` path.

## CSV stream + upload progress + CORS + README sprint (2026-05-19)

* **Streaming CSV export** (audit P4). `export_transactions_csv`
  now uses `sqlx::query(...).fetch(&db)` for row-by-row reads +
  an `mpsc::channel` + `tokio_stream::wrappers::ReceiverStream` +
  `axum::body::Body::from_stream` for the response body. Killed
  two memory sources at once: the row-buffer Vec and the full-CSV
  String. Adds `bytes`, `tokio-stream`, `futures-util` as direct
  deps (already transitive). A 50k-row export now fits in
  O(channel_buffer × row_size) RAM.
* **Per-file upload progress** via NDJSON event stream. The
  `/imports/upload` handler now emits one JSON object per line:
  `started{total}` → `file_done{name, ok, error?}` × N →
  `done{...legacy ImportResponse...}` (or `password_required`).
  Frontend `uploadStatements` reads chunked bytes, parses each
  line, fires an `onProgress` callback per `file_done`. Import
  screen renders "Processing N of M files… · Last: foo.pdf".
  Bad-file rows surface with "(skipped)" in the warning colour.
* **CORS check in `/api/setup/status`**. New `cors` check with
  `severity: required_for_linking` warns when `ALLOWED_ORIGINS`
  is empty or missing the actual `FRONTEND_BASE_URL`. Message
  spells out the expected vs actual lists so the operator
  doesn't have to grep logs to find the misconfiguration.
* **README auth section**. New "Securing the account: TOTP,
  recovery codes, passkeys" block. Documents the enroll →
  confirm → log-in-in-same-step flow that the recent TOTP
  replay-marker fix unblocked; the recovery-codes mint + warn-
  when-low UX; the passkey register flow incl. cross-device QR;
  and the hardening defaults (rate-limit jitter, trusted proxy,
  CSRF header).

## FX dismissal + inline rename + rate-limit sprint (2026-05-19)

* **FX-pair "never re-suggest"** (FUTURE.md D follow-up). New
  migration `2026051808_dismissed_fx_pairs.sql` + detector
  predicate in `fx_transfer_link::detect_for_user` that consults
  the table before proposing pairs. `unlink_fx_transfer` now
  runs the DELETE + dismissal INSERT in one DB transaction.
  Two new endpoints (`GET /fx-transfers/dismissed`,
  `DELETE /fx-transfers/dismissed/{id}`) feed a new FX-pair
  section in the HiddenItemsScreen with a Restore button per
  row. Closes the gap where the detector kept re-proposing
  pairs the user had explicitly unlinked.
* **FX detector sign-convention bug fix** (separate). The
  detector was filtering on `amount > 0 = outflow`, but the
  app stores expense as NEGATIVE (per Plaid sync's
  `let amount = -tx["amount"]` and `cash_flow_trends`). The
  filter was inverted, which is why every detector run found
  0 candidates against real data. Source/dest sign checks +
  the explanatory comment fixed.
* **Inline transaction rename via right-click** (FUTURE.md I).
  Right-click on a transaction row opens the lightweight
  `_renameTransaction` dialog directly — no detail-modal hop.
  The bulk-apply "also apply to N matching rows" checkbox
  shows when the row is part of a description-cluster. Long-
  press semantics (start selection mode) unchanged. R-shortcut
  deferred to a future sprint.
* **Rate-limit hardening** (audit M2). Per-user exponential
  backoff inside `rate_limited` (1 s → 2 → 4 → 8 → 16 → 30
  capped) so a brute-forcer who crosses the 5/min threshold
  can't probe at HTTP throughput. Plus a 50–150 ms random
  jitter (`password::random_login_jitter`) on every failed
  verify path — unknown user, inactive user, bad password,
  bad TOTP code, bad recovery code. Closes the "spray 5
  passwords/min indefinitely under threshold" attack.

## Sign-fixes + split polish + smoke sprint (2026-05-18, late late)

* **Subscription detector sign-convention bug fixed.** The detector
  filtered `amount > 0` which is *income* in this app's convention
  (Plaid sync negates outflows; `cash_flow_trends` confirms
  `> 0 = income`). "Interest earned" was clustering as a fake
  subscription because of it. Filter now uses `amount < 0` and
  `.abs()` the values before clustering; a defensive in-loop sign
  check stays as belt-and-suspenders. Window widened to 548 days
  to match the cancelled-detection range.
* **Manual-transaction dialog sign inversion fixed.** The "Add
  transaction" dialog had `_isExpense ? raw : -raw`, which is
  backwards — an "Expense" was being stored as income. Now
  `_isExpense ? -raw : raw`. The matching backend doc comment in
  `CreateManualTransactionRequest` was also wrong; fixed.
* **Subscription per-account breakdown.** Detector now joins to
  `accounts`, tallies spend per `account_id` per cluster, and
  returns a `by_account` array on each `DetectedSubscription`
  (sorted by share descending). Frontend renders compact chips
  under the cadence subtitle when the cluster spans ≥ 2 accounts
  (caps at 3 chips + "+N more"). Hidden for the single-account
  common case so the card stays clean.
* **Atomic edit-split endpoint** `PUT /api/accounts/transactions/
  {id}/splits`. Replaces children inside a single DB transaction
  so no concurrent reader sees the parent restored without
  children. Frontend now uses this when available; falls back to
  the legacy unsplit-then-resplit dance when not. Two new
  integration tests cover the happy path + transactional rollback
  on validation failure.
* **Per-row category dropdown in the split dialog**, fed from the
  distinct categories already present in the loaded transactions
  list (same source the filter dialog uses). Preserves a custom
  value not in the list as an "(existing)" option so initialDrafts
  values aren't silently lost.
* **scripts/smoke.cjs**: previously was silently 403-ing on the
  manual-account POST because it never sent `X-Requested-With`.
  The `request()` helper now auto-attaches the header on every
  mutating method. New `smokeRecentFeatures` step exercises:
  POST/PUT/DELETE splits round-trip, subscription
  ignore/un-ignore, `/since-last-login` shape check, FX-transfer
  list + detect, and `/subscriptions` shape (asserts every row
  has the new `by_account` array).

## SQL + hidden-items + tests sprint (2026-05-18, late)

* **Net-worth history rewritten in SQL.** The Rust BTreeMap walk in
  `dashboard.rs::net_worth_history` is gone; a single
  `WITH per_inst AS (...) SELECT ... jsonb_object_agg(...) GROUP BY
  as_of_date` query produces one row per date with the per-institution
  map pre-built. Response shape is byte-identical to what the old
  code emitted. At today's scale this is barely measurable; at
  power-user scale (many institutions × long history) it's the
  difference between O(D·I) Rust work + per-row Decimal parsing and
  one SQL pass. Liability sign is also still respected via the
  `is_liability_account_type` helper.
* **"Hidden items" panel.** New screen reachable from a
  visibility-off icon next to the Security shield in the AppBar.
  Surfaces ignored subscriptions (with per-row Restore action,
  uses the existing `/dashboard/subscriptions/ignored` endpoints)
  and the since-last-login banner dismissal (Preferences-stored;
  clears localStorage and lets the banner reappear). FX-pair
  "permanently ignore" is intentionally deferred — needs a new
  backend table to materialise the never-resuggest state; tracked
  in `work/FUTURE.md` section D.
* **Backend integration tests.** New `tests/dashboard_endpoints.rs`
  with 14 tests covering: `update-webhook` (503 / 400 / 200-empty
  / 401 / 403-no-CSRF branches), split create / sign-validate /
  amount-validate / already-split-422 / cross-user 404, full
  edit-split round-trip (split → unsplit → re-split with new
  ratios), unsplit-nonexistent 404, `since-last-login` empty +
  populated, subscription ignore/unignore round-trip including
  idempotency + lowercase normalisation + empty-rejection,
  fx-transfers empty listing, net-worth-history aggregation
  (asset+liability per institution + per date). Gated on
  `PATRIMONIO_TEST_DATABASE_URL`; absent = skipped (same pattern
  as `auth_endpoints.rs`).

## Late-evening sprint (2026-05-18, follow-on after Top-3 ship)

* **Management tab setup card** now surfaces the `plaid_webhook`
  check and exposes a "Push to N institutions" trailing button
  when the URL is configured and there's ≥ 1 linked Plaid item.
  Tapping it POSTs `/api/institutions/update-webhook` and shows
  a result dialog (one row per institution, OK / reason).
* The card's bottom-line "Recommended before production…" copy
  is now driven by the actual recommended-but-unset checks
  (previously hard-coded "configure live exchange rates").
* **Split-transaction quick-split presets**: a tune icon in the
  dialog title bar offers 50/50, 60/40, 70/30, 40/30/30, and
  an "Even split…" picker (slider 2..10). Existing description/
  category text on each row is preserved when the ratio changes.
* **Edit-split** action on a child's detail modal opens the
  dialog pre-populated with the existing siblings. Save runs
  unsplit-then-resplit atomically client-side. Sibling lookup
  is from the currently-loaded transactions list — sufficient
  for ≤ 50-way splits, the only real-world case.

## Evening sprint (2026-05-18, after the walkthrough)

Shipped in this session, in order:

* **`since_last_login` largest-move sign for liabilities.** The SQL
  now flips the delta for liability accounts via
  `is_liability_account_type`. A credit card going $500 → $1500 now
  reports as `-$1000` (net worth went down by $1000) instead of the
  previous false-positive `+$1000`.
* **Recovery-codes-low warning** on the Security screen. When the
  unused count drops below 3 the row swaps to an amber warning tile
  with a prominent "Regenerate" CTA. ≥ 3 still shows the original
  neutral card.
* **Cancelled-subscription detection.** Backend `dashboard.rs::
  detected_subscriptions` now tags each cluster `status:
  "active"|"cancelled"` and includes clusters whose most-recent
  charge is 91–548 days old (instead of dropping them). The
  frontend `SubscriptionsCard` renders cancelled rows in a
  collapsed "Stopped (N)" section below the active list, with a
  muted color treatment and no "× not a subscription" affordance.
* **Mexican parser polish.** New `parser::polish_description`
  helper strips trailing date suffixes (`20260418`, `18/04/2026`,
  `18-04-2026`) and a bilingual list of generic prefixes
  (`MISC DEBIT`, `ACH `, `POS `, `COMPRA `, `RETIRO `, `ABONO `,
  `CARGO `, `DEPOSITO `, `TRASPASO `, `PAGO `, …) when there's
  meaningful text after stripping. `detect_and_parse` runs every
  parser's output through it. Direct callers
  (`banamex::parse_csv`, etc.) still get the raw output so the
  existing unit tests aren't disturbed.
* **Production webhook activation.**
  * `GET /api/setup/status` now reports a "Plaid webhook URL"
    check so the Management tab can see at a glance whether push
    delivery is wired.
  * New `POST /api/institutions/update-webhook` iterates every
    Plaid item the caller owns and calls Plaid's
    `/item/webhook/update` with the configured URL — saves
    re-linking institutions that were created before
    `PLAID_WEBHOOK_URL` was set.
  * `docs/deployment.md` rewritten with a concrete single-VPS
    runbook: nginx + Let's Encrypt sample, `TRUSTED_PROXY_CIDRS`
    setup, webhook activation flow (re-link OR one-shot
    update-webhook), log rotation, backup pointers.

## Walkthrough verification (2026-05-18)

A full live walkthrough exercised every new path on real Production
data:

| Check | Result |
|---|---|
| Schema head | 2026051806 |
| API health | `{"status":"ok","database":"connected"}` |
| CSRF guard | POST without header → 403; with → 401 |
| XFF strip | spoofed XFF from untrusted peer → audit ip_address = NULL |
| Dashboard load | 14 API calls all 200 |
| Split dialog | renders + validates + API rejects bad payloads (422/404) |
| Subscriptions | "Interest earned" detected; dismiss snackbar + card hides |
| Chart drill-in | `May 1–May 31 ✕` chip + "Showing 37 of 50" filtered |
| Sync + auto-FX | 4 Plaid institutions synced clean; FX detector ran silently (0 candidates) |
| Frontend console | no errors |

## How to run locally

> **Stale on the dev VM (2026-07-07):** docker is unavailable there —
> Postgres (`:5442`) + Redis (`:6380`) run natively with data dirs
> inside the repo, and cargo/flutter run from the native toolchain. See
> the repo-root `CLAUDE.md` + HANDOFF.md "How to verify / ship". The
> compose instructions below apply to prod on thelab.

```bash
cd ~/patrimonio
docker compose up -d            # api, frontend, postgres, redis
docker compose ps               # all four Up / Healthy
```

* App:      `http://127.0.0.1:3000`
* API:      `http://127.0.0.1:8080`
* Postgres: host port `5433`
* Redis:    host port `6380`

### Backend changes

```bash
docker compose up -d --build api
docker logs -f patrimonio-api-1
```

### Frontend changes

```bash
docker compose up -d --build frontend
# Re-stamp security headers — the rebuild overwrites nginx config:
docker cp frontend/security_headers.conf \
  patrimonio-frontend-1:/etc/nginx/conf.d/security_headers.conf \
  && docker exec patrimonio-frontend-1 nginx -s reload
```

Worth scripting: see NEXT.md quick win for `scripts/dev-rebuild-frontend.sh`.

## Known caveats / "expected" behavior

| Behavior | Why |
|---|---|
| Flutter canvaskit can briefly hang on rapid clicks | Renderer quirk; recovers on next interaction. Not a code regression. |
| Auth audit `ip_address` is NULL in local dev | `TRUSTED_PROXY_CIDRS` empty by default → XFF stripped → no IP. Set the env var with nginx's IP in prod. |
| Plaid webhooks aren't actually being delivered yet | `PLAID_WEBHOOK_URL` must be a public HTTPS URL. Set it in `.env` once the deployment is reachable from Plaid's egress. `docs/deployment.md` now walks through nginx + Let's Encrypt + `POST /api/institutions/update-webhook` to backfill existing items. |
| Sandbox vs Production indistinguishable in the UI | No AppBar chip yet — see NEXT.md / FUTURE.md item "Sandbox vs Prod indicator". |
| "Interest earned" subscription is hidden once dismissed; no Unhide UI | Delete the `ignored_subscription_merchants` row directly to un-dismiss — UI affordance is a small follow-up. |
| Mexican CSV / PDF parsers used to produce raw bank strings | ✅ Fixed this session. `parser::polish_description` strips trailing date suffixes + a bilingual generic-prefix list before the rows hit the DB. |

## Pointers

* `work/OVERVIEW.md` — what the app is, institutions it tracks
* `work/NEXT.md` — top 3 + quick wins for the next session
* `work/FUTURE.md` — full backlog with per-item plans
* `work/DECISIONS.md` — architecture decision records
* `docs/operations.md` — backup / restore / key-rotation runbook
* `docs/multi-currency.md` — user-facing guide to USD/MXN model
