# Current state — snapshot

> **Last updated:** 2026-07-07 (Portfolio-tab overhaul, three rounds — all on `main`, deployed to thelab)
> **Branch:** `main` (everything merged and deployed).

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
* Docs: `docs/adding-accounts.md` §5 now recommends nicknaming accounts.

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
