# Current state — snapshot

> **Last updated:** 2026-08-03 (feature-research sweep, 4 features + tooltip fix committed; rules-engine MVP built)
> **Branch:** `main`.

## 2026-08-03 (later) — Rules engine MVP (DEC-027/028), built + verified

The last queue item, implemented from the owner-signed-off
`work/RULES_ENGINE_DESIGN.md` in two verified phases.

* **Backend (`services/rules.rs`, `api/rules.rs`, migration
  `2026080401_user_rules.sql`)** — `user_rules` + four provenance columns on
  `transactions` (`user_{category,description}_{source,rule_id}`, legacy rows
  conservatively backfilled `'manual'`). ONE matcher in Rust (never duplicated
  in SQL — Postgres/Rust disagree on accent-case edges, and any divergence
  would break dry-run↔apply parity): four match types, no regex, scope by
  account/currency/direction/native-ABS-amount, first-match-wins **per action
  field** over `(priority, created_at, id)`. `/api/rules` CRUD + reorder mutate
  ZERO transaction rows (checksum-asserted); `/preview` returns counts +
  ≤50 samples + `fx_transfer_legs` + a Redis-stored fingerprinted token
  (`rules:preview:{user_id}:{token}`, 15-min TTL, atomic `GETDEL` — `redis`
  0.27 has it, so single-use is genuine); `/{id}/apply` is the ONLY writer of
  rule provenance onto pre-existing rows, re-asserting the manual-protection
  predicate in SQL so a row hand-edited after the preview is skipped, not
  clobbered, and publishes `TransactionsChanged`. **Both forward paths**:
  import confirm (rule-over-learned, `ON CONFLICT` untouched → re-imports stay
  idempotent) and **Plaid sync** — the gap the feature existed to close —
  insert-only, `DO UPDATE SET` still carries no `user_*`. Learned-map source
  filtered to `COALESCE(source,'manual')='manual'`, cutting the feedback loop
  that would let a deleted rule resurrect itself; the fixer proved that guard
  bites by removing it and watching the regression test fail. +14 unit / +15
  integration → **614/614** (fmt + clippy clean).
* **Frontend** — `api_service/rules.dart` (`_RulesApi`, the SIXTH part-file
  mixin; skill §3 corrected in the same diff), `RuleEditorSheet` with a
  debounced live preview diff, `RulePreviewDiff`, `RulesScreen`
  (reorder/toggle/edit/delete), "Save as rule…" in the transaction detail
  panel (no host-interface change needed), Settings row next to Hidden items,
  +68 l10n keys per locale. Both primary actions gated on a completed preview,
  and any edit to the definition clears preview AND token together so the
  token on screen always belongs to the numbers on screen. **1033/1033**
  (format clean, 18-info baseline).
* **The two honest-numbers cases are pinned as behavior, not bugs:** apply's
  `updated_*` can EXCEED preview's `changes` (matched rows already showing the
  target value still get a provenance write) — the sheet test asserts a
  snackbar of 24 against a previewed 22 — and `skipped > 0` gets its own
  plain-language line. `fx_transfer_legs > 0` renders a full-width warning
  banner (DEC-028's allow+warn is only as good as that banner).
* `scripts/smoke.cjs` gained `smokeRules()`: seed → hand-edit one row →
  create (assert zero mutation) → preview → apply → row A changed, hand-edited
  row B untouched → replayed token 409 → delete keeps applied values.
* Deferred per design §7: regex, revert machinery, hit-count stats,
  manual-add/split-child application, Plaid conflict-path re-evaluation.
* **Live-rig verification — 7/7 PASS**, 0 console errors / 0 failed requests
  across 20 sessions, with the safety claims checked against the DATABASE,
  not just the UI (agent seeded 3 marked rows + 2 rules and removed
  everything; tree untouched):
  - **DEC-027 held under attack:** a row hand-edited to `ZZ HANDEDIT KEEPME`
    (`source='manual'`) survived an apply matching all three seeded rows —
    post-apply the other two carried `source='rule'` + rule id, that row was
    untouched, and the preview had already said "1 skipped as a manual edit".
  - **Zero-mutation on create proven by checksum:** MD5 over
    `(id, user_category, user_category_source, user_description)` for ALL of
    claude_dev's transactions was byte-identical before/after rule creation.
  - **Both token attacks 409'd:** exact replay → "already applied";
    preview → PATCH the rule to `ZZ SNEAKY` → apply the old token → "the rule
    changed after this preview was generated", and the sneaky value reached
    **0 rows**.
  - **DEC-028 confirmed:** after deleting the rule, applied values remained
    with `source='rule'` and a NULL rule id.
  - Button-gating probed via `aria-disabled`, not eyeballed: no window exists
    where a live token coexists with stale numbers. Reorder + active toggle
    persist across a hard reload; es-MX renders all 77 `rule*` keys including
    plurals and «» quotes.

## 2026-08-03 — Feature-research pipeline + implementation queue (UNCOMMITTED, pending review)

* **Feature-research sweep shipped** — `work/research/2026-08-03-feature-research.md`:
  19-agent pipeline (4 researchers → fit analyst → PM triage → 12 parallel
  skeptics → PM synthesis), 39 raw candidates → 8 PM-vetted briefs with
  evidence links, + an 18-item researched-and-rejected appendix so ideas
  aren't re-researched. Reusable team defs in `.agent/agents/`
  (competitor-analyst, user-voice-researcher, fit-and-feasibility-analyst,
  feature-skeptic, pm-synthesizer) + saved pipeline
  `.agent/workflows/feature-research.js`. FUTURE.md gained the 5 spec'd
  proposals; NEXT.md carries the implementation queue (owner-approved:
  dossier → transfer-cost report → net-worth attribution).
* **Household continuity dossier built + verified** (queue item 1, brief 1) —
  `GET /api/exports/continuity-dossier?lang=en|es`: bilingual printable HTML
  on the tax_exports.rs FBAR recipe (cover with computed "data as of" +
  no-secrets note; institutions/accounts with last native+USD balance via
  per-account LATERAL newest-snapshot; manual-asset valuations; per-currency
  holdings summary; lending book with derived outstanding; FBAR flags;
  owner instructions via app_settings `continuity_notes`). New
  `backend/src/api/exports.rs` + 7 integration tests (incl. planted-marker
  no-encrypted-material assertion + XSS-escape round-trip);
  `continuity_dossier_screen.dart` (instructions editor, en/es segments,
  loan-agreement launchUrl delivery pattern) + Settings-tab entry + 14
  `dossier*` keys in both arbs + 6 widget tests. Known caveat carried from
  the existing printables: on the APK the system browser needs its own web
  session. **Gates:** backend 565/565 (fmt + clippy clean), frontend 975/975
  (format clean, analyze 18-info baseline). Nothing committed yet.
* **Annual transfer-cost report built + verified** (queue item 2, brief 5) —
  `GET /api/dashboard/fx-transfers/costs`: per-year / per-provider spread
  cost vs mid-market over `cash_fx_transfers` (Decimal end-to-end, per-row
  FX→USD before summing, ±7-day nearest-spot matching `list_fx_transfers`,
  provider aliases folded, unknown bucket, transfers with no in-window spot
  EXCLUDED and surfaced via `missing_spot_count` — never guessed). Fee-vs-
  spread split explicitly out of scope per FUTURE.md. FX-center "Transfer
  costs" section with caveat + missing-spot note; 7 `fxcCosts*` keys both
  arbs (multi-placeholder call site matches the alphabetical signature).
  +5 unit / +3 integration / +4 widget tests. **Gates:** backend 573/573
  (fmt + clippy clean), frontend 979/979 (format clean, 18-info baseline).
  Uncommitted with the rest.
* **Net-worth change attribution built + verified** (queue item 3, brief 4) —
  `GET /api/dashboard/net-worth-attribution?from&to` (new
  `api/dashboard/attribution.rs`): FX / market / flows / residual
  decomposition per currency + USD with the EXACT sum invariant (components
  2-dp rounded, residual absorbs the remainder — tests assert equality in
  Decimal parsed from the serialized JSON, incl. a pinned nonzero residual
  from the snapshot-write-rate discrepancy). Convention documented in the
  module comment: carry-forward endpoints, flows at tx-date rate (INVESTMENT
  rows + split parents excluded), fx on opening balance, market at closing
  rate. Weekly digest deferred. Net-worth card gained the "Why it changed"
  chips (residual → "Other" only when nonzero) + USD / MXN / Constant-FX
  lens toggle (chart-only, via `standardLineTouch` — the sanctioned inline
  copy is byte-untouched); 8 `nwAttr*`/`nwLens*` keys both arbs. +5
  integration / +8 widget tests. **Gates:** backend 578/578 (fmt + clippy
  clean), frontend 987/987 (format clean, 18-info baseline). Uncommitted.
* **Touch tooltip fix (owner-reported)** — chart tooltips rendered under the
  finger on phones. `utils/chart_touch.dart` is now pointer-kind-aware:
  touch/stylus pins the tooltip to the top of the chart box
  (`showOnTopOfTheChartBoxArea`; `LineTouchTooltipData` has no `copyWith` in
  fl_chart 0.70.2 → manual field-copy helper `lineTooltipPinnedToTop`),
  mouse/trackpad popover byte-identical; seed from `defaultTargetPlatform`
  so the first touch never flashes under the finger. All line charts
  covered (wrapper-based + projections wired directly); a new conventions
  test pins the invariant. Bar charts excluded — 0.70.2 has no chart-box
  pinning for bar tooltips. Follow-up applied same sitting: the FX center's
  history chart (raw `LineChart` from the transfer-cost batch) wrapped in
  `TransientTooltipLineChart`. **Gates:** frontend 996/996 (format clean,
  18-info baseline; backend untouched at 578).
* **Bills calendar + 1–90-day projected balances built + verified** (queue
  item 4, brief 3) — `GET /api/recurring/calendar?days=N` (clamped 1..90):
  rule + loan-due expansion, loan_match-style expected↔posted matching
  (10%/$1 amount band, ±5-day window, token bonus, score ≥50, greedy
  earliest-first), states paid/upcoming/late(≤7d)/missed/**pending_import**
  (manual-account freshness = newest transaction DATE, deliberately not
  import time — documented on `AccountFreshness`; never false-red), per-
  currency Decimal projection curve (latest-per-account depository
  snapshots, liability signs, non-MXN → USD-equivalent bucket; missed/
  pending excluded as unknowable), FX-crossing suggestion (deficit currency
  + date + exact shortfall). `bills_calendar_card.dart`: compact month grid
  (Monarch reference shape; beat a week-strip at ~300px) + day-tap agenda +
  `TransientTooltipLineChart` curve + FX banner; `bc*` keys both arbs.
  Trap found: `placeholder_declaration_order_test` wants arb metadata in
  template order — reordered with comments. +4 unit / +3 integration / +9
  widget tests. **Gates:** backend 585/585 (fmt + clippy clean), frontend
  1005/1005 (format clean, 18-info baseline). Uncommitted.
* **Rules-engine design ready** (queue item 5) — `work/RULES_ENGINE_DESIGN.md`:
  provenance columns make manual-always-wins an SQL predicate; write-time
  application on BOTH import + Plaid paths; Redis-token dry-run/apply
  contract (fingerprint-matched, single-use); regex out for v1; 5-day MVP
  phasing. §8 = 8 open questions. AWAITING OWNER SIGN-OFF before any code.
* **Live-rig walkthrough of all five new surfaces — ALL PASS** (0 console
  errors / 0 failed requests across 10+ sessions; repo diff byte-identical
  after): dossier persists + renders EN/ES printable with no-secrets grep
  clean; FX transfer-costs honest empty state; attribution chips + 3-lens
  toggle with stable hero ($399,982) and correct constant-FX caption; bills
  calendar grid/day-agenda/currency curve; touch drag pins tooltips to the
  chart-box top and dismisses on lift while mouse popovers are unchanged.
  Two minor observations parked in NEXT.md (lens x-axis spacing
  inconsistency; bills MXN curve y-axis "$" notation).

## 2026-08-03 — The batch's own deferrals, closed same-session

After the deferred-items batch shipped (pushed + deployed through
`72abd94`, api health 200, APK cut), all three items it had re-deferred
were approved and landed:

* **ApiService part-file mixin split (`1effbaa`)** — api_service.dart is a
  335-line library root (`_ApiServiceBase` declares the private plumbing
  surface; exceptions + verb wrappers + cache glue stay) with five part
  files under `services/api_service/`: `_AuthApi`, `_DashboardApi`,
  `_TxApi` (incl. the streaming uploads), `_HoldingsApi`, `_LendingApi`.
  Mixins, NOT extensions, exactly per the recorded recipe: five test fakes
  `@override` endpoint methods and extension members dispatch statically —
  those suites pass unmodified. Bodies byte-identical except four
  `clearDashboardCache()` calls qualified (class statics don't resolve
  unqualified inside a mixin). Skill §3 updated in the same diff; new
  endpoints go in the matching part file.
* **Transaction detail panel decoupled (`afac14c`)** — the ~955-line
  `_TransactionDetailPanel` is now public `TransactionDetailPanel` in its
  own file behind a `TransactionDetailHost` interface: live tab config as
  getters (constructor capture would freeze values across keyboard-inset
  rebuilds), thin delegates over the shared helper hubs, the five actions,
  and deliberately the TAB's `context`/`mounted` (post-close SnackBars —
  the delete/undo flow — must outlive the panel). transactions_tab.dart
  5,098→4,252. Deferred-delete/undo + jump-context machinery untouched.
  Live rig smoke on the dirty tree: 8-tab sweep, panel edit/revert, split
  dialog across the seam, delete + undo SnackBar, spike drill-down — 0
  console errors, 0 failed requests.
* **dashboard_screen imports DividendIncomeCard directly (`c85dc85`)** —
  the portfolio_card re-export seam is gone.
* Also: the walkthrough exposed a wrong doc comment on
  `createManualTransaction` claiming the Plaid sign convention (positive =
  expense); the app convention is negative = outflow. Corrected with the
  incident noted.
* Gates at every step: 969/969, analyze at the 18-info baseline, format
  clean; independent verifier before each commit. Backend untouched.

## 2026-08-02 (deferred-items batch) — Loans Decimal wire, god-file splits, ApiService seam

The four items deferred from the night's quality sweep, worked by the
committed `.agent/agents/` team (fixer + both verifiers + walkthrough rig),
one verified checkpoint per item against the sweep's green baseline
(backend 558, frontend 952 — both re-verified first).

* **Loans money pipeline f64 → Decimal (`e4a109c`)** — all ~37 DTO/helper
  sites in `api/loans.rs`: DTOs, read path (direct `try_get::<Decimal>`),
  write path (`cents()` deleted; allocation binds `.round_dp(2)`), accrual/
  allocation math, `fmt_money`, currency aggregations. `MONEY_EPSILON` is now
  a Decimal half-cent guarding **legacy stored f64-era dust**, not in-process
  float error. Two things the plan didn't anticipate, both handled:
  Decimal's `{:.N}` **truncates** instead of rounding (every precision-format
  site now pre-rounds — CSVs, rate percents, the agreement's paid-% pair),
  and `dec_to_f64` survives as a documented boundary shim into
  `services::loan_match` + the f64 FX-rate check. Wire proof: serde-float
  keeps JSON numbers; `loan_endpoints` (39) + `loan_match_boundary` (2)
  untouched and green; live rig walkthrough of the Lending tab passed
  including the write path (create 1,234.56 @ 5.5% → 12-row schedule →
  $100 payment → coherent totals → delete; 0 console/network errors).
* **God-file splits, mechanical-extraction style** (byte-identical moves,
  952 conserved at each step): `lending_tab.dart` 5,427→1,023 (`c889f19`:
  AddLoanDialog, EditLoanDialog, LoanDetailSheet, RecordPaymentSheet);
  `transactions_tab.dart` 5,291→5,098 only (`a6d3539`: AccountMover + pure
  helpers → `utils/transactions_tab_logic.dart`) — **honest small yield**:
  the 955-line detail panel reaches back into 14 private tab-state members
  by documented design and the jump-context/claim machinery stayed fenced;
  decoupling it is a design change, not a move. `portfolio_card.dart`
  4,359→2,141 (`df92253`: nine extractions — DividendIncomeCard, lot
  breakdown sheet, both holding-row tiles with the shared pixel-alignment
  row seam, HoldingSubtitle, EdgeFadedHScroll, KpiTile, + pure filter/
  quantity helpers to `utils/`; a documented re-export keeps
  dashboard_screen's import working until that file is next owned).
* **ApiService testability (`799681b`)** — nullable `@visibleForTesting`
  `debugHttpClientOverride` behind a private getter (production stays the
  static-shared lazily-init `createApiClient()`); 17 new tests via
  `package:http/testing` MockClient pin the previously untested core: CSRF
  header on every mutating verb, base-url joining, the 401 signedIn-edge
  flow (exactly one auth-stream emission), `_errorFromBody` fallbacks incl.
  es localization, dashboard-cache TTL/invalidation gates. 952→969.
  Split assessment (not implemented): `part` files + **private mixins** —
  extensions would statically dispatch the endpoint methods five test fakes
  `@override`, silently breaking them.
* **Chart-touch convention closed (`89549c6`)** — `account_balance_chart`
  migrated to `standardLineTouch` (content byte-identical, gains the house
  snap/guide/fitInside mechanics); its frozen allowlist entry removed, so
  the equivalence invariant now enforces every line chart. The
  `docs/deployment.md` framing item was **rejected as already fixed** by
  `954bdde` — the surviving "static/stateless" mentions are the deliberate
  managed-cloud-alternative paragraph.
* Final gates on the shipped tree: backend **558/558** (fmt + clippy clean),
  frontend **969/969** (format clean, analyze at the 18-info baseline).
* Deferred again, recorded in NEXT.md: transactions detail-panel decoupling
  (needs a callback/param design), the ApiService mixin split (assessed,
  recipe in this entry), dashboard_screen's direct DividendIncomeCard
  import.

## 2026-08-02 (night) — Multi-agent quality sweep: tests, refactors, agent infra

An 20+-agent audit→fix→verify pipeline over the whole repo. Regression
baseline verified green FIRST (backend 527, frontend 912), every change landed
against it, final gates green on the exact shipped tree.

* **Backend tests 527→558**: new invite/registration lifecycle suite (the only
  path users arrive by — expiry, atomic one-time consumption, role
  inheritance); destructive-import isolation suite; FX manual-rate +
  fallback-ladder tests; TWR share-reconstruction inline unit tests (pure
  functions extracted from the DB shell); encryption roundtrip/tamper tests +
  `decrypt` wrong-length-key panic fixed + module docs; `tests/conventions.rs`
  bans compile-time sqlx macros in `src/`.
* **Frontend tests 912→952**: placeholder-order regression tests for all
  at-risk l10n keys + a systemic declaration-order invariant (7 deliberate
  legacy orders frozen); `test/conventions/` invariants — chart-touch
  byte-equivalence (caught + fixed the projections tooltip 12px-radius drift),
  no hand-rolled percents (ships with an EMPTY allowlist), no raw `Colors.*`;
  bell/notification-row real semantics (`lwNotifBellUnread`, +9 tests); first
  coverage for budgets_card and import_cleanup_screen.
* **Bug fixed (found by live walkthrough)**: `depository`-typed accounts now
  classify as cash — one root cause behind both the Overview Cash tile showing
  $0.00 and the literal "Unknown subtype: depository" leaking into the
  accounts list (truly-unknown types now get a localized generic subtitle).
* **Refactors, all behavior-preserving (suites exactly conserved)**:
  `api/error.rs` + `api/middleware.rs` extracted from session.rs;
  `services/fx.rs` now owns the USD/MXN SQL + the one fallback (absorbed
  SEVEN hand-synced copies); `api/dashboard.rs` (6,986 lines) → 12-file
  directory module; 37 legacy handlers → the `ApiError` envelope (status
  codes unchanged; OAuth redirects deliberately left); 10.5k-line
  `dashboard_endpoints.rs` split by surface (139 tests conserved, fixtures →
  `tests/common/fixtures.rs`); dashboard_screen 7,748→7,037 via five widget
  extractions; tax_planning_logic → `utils/`.
* **Convention fixes**: percents routed through `percent_format` helpers
  (incl. new `formatSignedPercent`); hardcoded colors → `context` extension;
  four stale ApiService-testability comments corrected; `kCompactLayoutBelow`
  names the 560px breakpoint.
* **Docs**: HANDOFF/NEXT rebuilt, DEC-023…026 appended, this file rotated
  (pre-July → `work/archive/`); public `docs/` site synced (deployment.md on
  the real compose stack; multi-currency.md's FX auto-linker documented as
  shipped + added to nav); skills updated with enforcement pointers.
* **Agent infrastructure (new)**: `.agent/agents/` (backend-verifier,
  frontend-verifier, repo-auditor, fixer — the house working agreement as
  reusable subagent definitions), `.agent/workflows/quality-sweep.js`
  (repeatable read-only audit sweep), `scripts/walkthrough/` headless UI rig
  (WebSocket-capable proxy + session mint, live-tested) + `ui-walkthrough`
  skill, AGENTS.md "Concurrent agents" protocol + "skills are part of the
  diff" rule, quick-gate (`cargo test --lib`, ~6 s, no DB) vs full-gate
  documented.
* **End-to-end proof**: headless walkthrough of the real app passed — all 8
  tabs, en + es-MX, both themes, interactions on every touched surface, zero
  console errors / failed requests.
* Final gates: backend **558/558** (fmt + clippy clean), frontend **952/952**
  (format clean, analyze at the 18-info baseline).

## 2026-08-02 (evening) — Period selector + every menu on the house chrome

* **Cash-flow period selector**: the phone branch's stock ChoiceChip
  scroll row (uneven widths, YTD hidden off-screen) is now the house
  `ConnectedSegments` at every width via a new
  `CashFlowPeriodSelector` widget (enum moved out of the dashboard god
  file). Below 560px of available width it uses compact bilingual
  labels (`cfPeriod*Short`) — measured with the real Inter TTFs: full
  labels cannot fit 4 equal segments on any phone, and the old wide
  branch's 480px cap was ellipsizing desktop es-MX ("En lo que va del
  año"); cap now 560.
* **Menu chrome centralized**: new `theme/menus.dart`
  (`buildPopupMenuTheme`/`buildMenuTheme` + `houseDropdownColor`/
  `kMenuRadius`) installed in both themes — every PopupMenuButton/
  showMenu/MenuAnchor gets cardSurface, 12px radius, no M3 tint,
  house type at height 1.35. The legacy dropdown route has no theme
  hook, so all 18 `DropdownButton(FormField)` sites reference the
  helper pair (no copy-paste). Desktop bell popover verified intact.
* Tests 901→912; both batches screenshot-verified on the rig (phone +
  desktop, light + dark, en + es).

## 2026-08-02 (final batch) — Drill-downs carry their claim; jumps get a clean slate

A read-only audit workflow mapped every programmatic jump into the
Transactions tab: 10 of 14 journeys could stack stale filters from a
prior journey into a silent zero-result list (live-reproduced: search
"FasTrak" ∧ stale account chip ∧ stale "New since" = "0 matching"; a
stale July insight banner surviving over a June month drill). Fixes,
per the audit's design, verified live on the rig (all failing pairs now
pass; frontend 863→901, backend untouched):

* **Fresh-context rule** — `_maybeApplySeeds` → `_applyJumpContext`:
  any programmatic jump (any of the four seeds OR searchOverride)
  resets `TxFilters.empty` + search + selection mode FIRST inside the
  one post-frame setState, then applies its own payload. Manual edits
  still compose. New `onSearchOverrideConsumed` fixes the never-cleared
  dashboard copy (repeat-tapping the same merchant works again).
  Dashboard companion: one `_jumpToTransactions(...)` helper assigns
  ALL jump fields every call; the 8 jump sites are one-liners.
* **Claim banners** — sealed `DrillDownClaim` (spike / new-since-count /
  balance-move) replaces the spike-only banner; every bell drill-down
  restates its claim at the destination. Balance claims add an honest
  reconciliation line ("N synced transactions account for +$X of this
  move; the rest changed without synced activity") past a
  max($1, 5%-of-claim) gap threshold — never fabricated rows.
* **Largest-move rows open the account panel** (balance chart = the
  evidence for a balance claim) with the "New since" seed + banner
  threaded into its embedded TransactionsTab; graceful fallback to the
  tab jump when the account id doesn't resolve.
* Sort mode and scroll deliberately survive jumps.

## 2026-08-02 (later still) — Add-transaction restyle + dialog sweep + clarity fixes

Same pipeline (design audit w/ live rig screenshots → PM → dev →
adversarial verify, 0 repairs; frontend 856→863, backend 139+278 green).

* **Add transaction** now matches the Filter & sort vocabulary: sheet on
  narrow / dialog on wide via a shared `openAddTransactionPanel` helper
  (all four hosts route through it), cardSurface shells, titleLarge,
  filled 12px borderless fields (labelText kept — tests find by label),
  `ConnectedSegments` Expense/Income, pinned full-bleed 48dp Add above
  the keyboard (`MediaQuery.viewInsetsOf` padding).
* **Consistency sweep**: add_recurring_rule / add_crypto / add_account
  dialogs restyled to the same recipe; stock `SegmentedButton`s replaced
  with `ConnectedSegments` (new additive `enabled` flag) in
  portfolio_card, lending_tab (3), tax_planning filing status, and the
  dashboard's wide cash-flow period picker. Re-tap guards preserve
  no-op semantics. Deferred (audit report): split_transaction_dialog
  (custom two-pane layout), lending's own `_decoration` idiom, recurring
  dialog sheet-on-narrow.
* **Count line**: with any filter/search active the line reads
  "N matching · M total" (`txShowingMatches`, ICU plural — "1
  coincidencia") instead of the ambiguous "Showing N of M".
* **Largest-move label**: `BalanceMove` carries additive
  `institution_name`; the bell row now says "on Cards · SoFi", so a
  user-named account can't read as a category of accounts.

Queued next (user-approved): drill-down claim banners + largest-move →
account panel reroute + journey fresh-context reset (see scratchpad spec
+ journey-stacking audit).

## 2026-08-02 (later) — Since-visit drill-downs filter by sync time

Phone repro: "+$2,612.87 on Cards · since Jul 31" → tap → empty list with
chips "Cards · Aug 1–Aug 1". Two stacked bugs: the seed date-truncated the
RAW UTC anchor (7:59pm Jul 31 CST → Aug 1 window, a day past the bell's
own label), and — deeper — the digest counts rows by `created_at > anchor`
while the drill-down filtered by bank-POSTED date, which can precede the
anchor by days on cards. A date window can never faithfully show "what's
new since your visit".

* Both tx list endpoints now expose `created_at` (additive). TxFilters
  gains `createdSince` (drill-down-only — not in the Filter & sort editor)
  matching rows by sync time, with a posted-date approximation fallback
  for rows an older server sends without `created_at`. Renders as a
  dismissible "New since Jul 31" chip (`txNewSince`, en+es).
* `_jumpToTransactionsSince` seeds the raw instant (fourth one-shot seed,
  same `_maybeApplySeeds` single-setState path) — no truncation, no date
  window. Month/spike drill-downs keep their date windows.
* Stale-total edge closed: a SUCCESSFUL empty offset-0 page now emits
  `X-Total-Count: 0` (DB errors still emit no header); the frontend also
  clears remembered totals when emptiness is proven against older servers.
* Regression test encodes the exact repro: row POSTED Jul 28, synced after
  a Jul 31 anchor → shown. Frontend 844→856, backend suites extended; all
  green. Rig seed data (1,200 rows) purged from the dev DB.

## 2026-08-02 — Filter & sort restyle + stable transaction totals

Two phone reports, same subagent pipeline (evaluators → PM → dev →
adversarial verify), this time with a **live headless-browser rig** (web
build + same-origin proxy + seeded claude_dev account) so the design audit
and the verification worked from real screenshots, not just code.

* **Filter & sort editor restyle** (purely presentational — the
  (TxFilters, TxSort) contract and every behavior test are untouched):
  both shells on `BrandPalette.cardSurface`; the three FilterChip groups
  now use the house tonal recipe (no checkmark, StadiumBorder no side,
  `tileSurface` fill, `accentSoft(positive)` selected, jade-bold labels —
  same as the cash-flow period selector); the two `SegmentedButton`s
  replaced by a new shared **`ConnectedSegments<T>`** widget extracted
  from the theme picker (which now uses it too); filled rounded amount
  inputs; sheet action bar = hairline + full-bleed `FilledButton` Apply;
  unified `titleLarge` headers; 8dp chip gaps, LayoutBuilder gutters.
  Parity test pins that both shells pop identical records.
* **"Showing X of Y" no longer counts up.** The denominator was
  loaded-pages length while the filter cascade streamed history. Both
  list endpoints now return **`X-Total-Count`** via `COUNT(*) OVER ()`
  (identical WHERE, zero clause duplication; header not envelope so the
  shipped APK's bare-array decode keeps working; CORS exposes it).
  `ApiService` returns a `TxPage {rows, totalCount}`; `hasMore` is exact
  (`loaded < total`) with the old short-page heuristic kept as the
  older-server fallback; the count line renders the stable server total
  plus an inline "Loading full history…" note while the cascade runs.
* Tests: frontend 829→844, backend +4 (`tx_total_count.rs` on the real
  middleware stack: page-stable totals, filter parity, tenant scoping,
  no-header-on-empty). Verified live: header identical across pages,
  before/after rig screenshots phone+desktop, light+dark.
* Known cosmetic edge (accepted): deleting the very last transactions
  mid-session leaves the stale total until reload (header absent on an
  empty page by design).

## 2026-08-01 — P1: insight sheet, comparison banner, account-scoped moves

Follow-up to the P0 drill-down below, same subagent pipeline (PM design →
dev → adversarial verify). Design call: tapping a spike row now opens an
**insight sheet** (context-first, matching the app's detail-sheet idiom —
dividend/instrument/fx sheets); the raw list stays one tap away.

* **`spending_insight_sheet.dart`** (new) — M3 bottom sheet for a spike:
  recent vs N-month average, 6-month per-category bar trend and top-5
  merchants (both computed client-side from already-loaded transactions,
  per-row FX→USD, sharing `isBudgetableSpend` with the budgets card so the
  numbers agree), "See all transactions" (performs the P0 category+month
  seeding) and "Set/Update budget" prefilled from the trailing average via
  the budgets-card rounding rule.
* **Comparison banner** on Transactions while the seeded category filter is
  active: "Gas & electric in Jul: $190 spent — 230% above your 3-month
  average of $57.70". Dismissible; clears with the filter.
* **`utils/spending_insight.dart`** (new) — `SpendingSpikeInsight` model
  threaded through the tap path + pure bucket/merchant helpers (unit-tested
  incl. zero-fill contiguity and Dec rollover).
* **Account-scoped largest-move row** — backend `BalanceMove` gains additive
  `account_id`; the "+$2,612.87 on Cards" row now seeds
  `TxFilters.accountIds` (third one-shot seed) + the date window; older
  server payloads degrade to the date-only jump.
* **Net-worth rows are tappable** — anchored on the prior snapshot date via
  the existing `_jumpToTransactionsSince`.
* 15 l10n keys in both arbs (es-MX reviewed); alphabetical-placeholder
  call sites pinned by bilingual exact-string tests.
* Tests: frontend 792→829, backend 242→243 (largest_move carries
  account_id). All gates green (fmt/clippy/analyze/format/full suites).

## 2026-08-01 — Spending-spike and price-hike bell rows now drill down

Reported from the phone: tapping *"Gas & electric up 230%"* in the bell just
switched to the Cash flow tab, top of page, period "This month" — nothing
about the category the alert was about. `onJumpToSpending` was a bare
`_goToNav(NavId.cashFlow)`; the context the panel had already computed
(category label, insight month, merchant) was thrown away at the tap.

Spec came out of a subagent evaluation panel (interaction UX + product value
+ eng feasibility → PM synthesis); implementation + adversarial verification
by dev subagents. Frontend-only, no new l10n strings:

* **Spike rows** now land on **Transactions filtered to that category for the
  insight's `recent_month`** — the purchases behind the alert, with the
  existing dismissible filter chips as context/undo. The callback passes the
  *prettified* label the row displayed (never the uppercased id code — the
  filter matches prettified labels, so the code would silently show zero
  rows); pinned by en + es-MX widget tests.
* **Subscription price-hike rows** land on Transactions with the merchant
  seeded into search (same jump the SubscriptionsCard merchant tap ships),
  so the was→now charge history reads as adjacent rows.
* **`TransactionsTab.categorySeed`** — new one-shot seed mirroring the
  `dateSeed` contract exactly (separate consumed callback; both seeds applied
  in ONE post-frame setState so a fetch can't observe half-applied filters;
  `didUpdateWidget` re-applies only changed seeds).
* **`utils/month_window.dart`** — shared `'YYYY-MM'` → month-window helper
  (null on malformed/out-of-range/full-date input; Dec→Jan rollover safe);
  the cash-flow trends chart month tap refactored onto it.
* Tests: notifications_panel (25), transactions_tab (30, new "Bell
  drill-down" group incl. one-shot regressions), month_window (4). Full
  suite 792 green; analyzer/formatter clean.

Deferred P1s (evaluators liked them, PM cut for scope): comparison banner
over the seeded list ("Jul: X · 3-mo avg: Y · +230%", needs l10n),
account-scoping the largest-move row, making the net-worth row tappable,
an insight-detail sheet with a "set budget" CTA, scroll-to-institution on
sync rows.

## 2026-07-30 — Condition-backed notifications now retire themselves

Reported from the phone: a CetesDirecto statement had just been imported, but
the bell still read *"CetesDirecto statement import overdue — data is 45 days
old"*, dated Jul 23. The dashboard banner had cleared correctly; only the bell
was wrong.

Root cause: `user_notifications` was **insert-only**. The staleness cron wrote
a row once per episode and nothing ever took it back, so a stored reminder —
frozen text making a claim about the present — outlived the condition
indefinitely. The unread badge counted it too. `loan_due` had the identical
shape: paying an installment cleared the lending tab while the bell kept
asking for the money.

* **`staleness::resolve_stale_import_notifications`** (backend). Runs on every
  `GET /api/notifications`. For each manual institution it either deletes the
  reminder (fresh data / muted / snoozed — i.e. the sweep would no longer
  write one) or keeps it with the day count **re-dated to today**, so a
  reminder raised at 45 days says 52 a week later instead of lying. The
  writer and the resolver now share one `StalenessPrefs::should_notify`
  predicate and one `manual_institution_freshness` query, so "stale" can't
  mean two things. Invariant: an `import_stale` row exists exactly while the
  institution would banner.
* **Deletes on proof, never on a join gap.** A row whose institution can't be
  attributed (deleted, or renamed before `link_id` existed) is left alone —
  otherwise any missing join would read as "resolved" and eat the inbox. New
  rows carry `link_kind='institution'` + `link_id`, so renames resolve from
  here on; the resolver backfills it onto surviving old rows.
* **`notifications::sync_loan_due_notifications`** (renamed from
  `record_…`). Same read pass now deletes `loan_due` rows the current data no
  longer warrants — paid, skipped, linked to a real transaction, rescheduled,
  loan closed or deleted, lead window shortened — by reconciling against the
  writer's own desired set rather than enumerating cases. Still idempotent
  next to `dedupe_key`: an installment that reverts to unpaid re-alerts.
* FX crossings are untouched: those are events, not conditions.
* No frontend change needed — a successful mutation already clears the whole
  dashboard cache, so the next load re-reads the reconciled inbox.

### "Since your last visit" now means a visit

Noticed in the same screenshot: *"143 new transactions — Since your last
visit · Jul 13"* on Jul 30. The summary anchored on `users.previous_login_at`,
which only moves when the user actually authenticates — on a phone that stays
signed in for weeks, that is not a visit by any reading. It fed both the
Overview banner and two bell rows.

* Migration `2026073101` adds `users.last_visit_at` + `previous_visit_at`.
  `GET /dashboard/since-last-login` rolls them in one `UPDATE … RETURNING`:
  a gap of more than `VISIT_GAP_HOURS` (4) ends a visit, so the old
  `last_visit_at` becomes the anchor; inside the window the anchor holds
  still, so refreshing doesn't erase the summary you're reading. A deliberate
  write on a GET — listing what changed since the last visit *is* the visit.
* Existing users are seeded from `MAX(user_sessions.last_seen_at)` (bumped on
  every authenticated request, so it's a real activity signal) rather than
  from the login, with both columns set to it: the first post-deploy load
  reports nothing new and every visit after that is measured honestly.
  Seeding the anchor from `previous_login_at` would have replayed the exact
  staleness the migration exists to end.
* The wire field stays `previous_login_at` — it's the key the web banner and
  the shipped APK dismiss on, and renaming it would silently un-dismiss
  banners on every client that hasn't updated. `previous_login_at` itself is
  unchanged; it still backs the security screen's session flag and is the
  fallback anchor for a user with no recorded visit.

### Chart range selector fills its row on phones (`4f29a8b`)

Spotted from the phone: under the net-worth chart the 1M / YTD / 1Y / 5Y / ALL
control shrink-wrapped its labels — a stub covering ~60% of the card with dead
space beside it, five segments of five widths ("YTD" is wider than "1M").
`DateRangeSelector` gains an opt-in `fill` that divides the width evenly and
lets the selected pill fill its cell; the phone call site uses it and drops its
horizontal scroll wrapper (`Expanded` needs a bounded width, and 2-4 character
labels never needed to scroll). Opt-in, not automatic: content-sized stays
right where the selector shares a line with a card title or the Performance
card's benchmark picker — the `c20620b` / `theme/buttons.dart` rule, touch-width
full-bleed vs pointer-width label-sized. Verified headless at 390px and 1440px;
4 widget tests, whose harness constrains width LOOSELY (what the card's Column
actually hands the selector, and the reason the old version shrink-wrapped).

**Noticed, not fixed** — same card, worth a follow-up: the x-axis emits
duplicate labels when history is sparse ("Jul 2026" seven times across a 1Y
range on the dev account), and the rightmost label clips at the card edge on
phones ("Aug 1" in the report screenshot).

Gates: clippy clean, full backend suite green (277 lib + 138 dashboard + all
other suites, 0 failures) including 8 new regression tests — retire-on-import,
re-dating, retire-on-mute, don't-touch-unattributable, settled installment,
rescheduled installment, visit-not-login anchor, anchor-holds-within-a-visit.
`flutter analyze` at the 18-info baseline, `flutter test` 775 passing (771 +
the 4 range-selector tests; neither notification fix needed a frontend
change). All three commits pushed and deployed to thelab; APK cut at
`4f29a8b`.

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

---

> Entries from before 2026-07-01 (the May–June 2026 sprints, plus the May-era
> "Where we are" / run-locally / caveats sections) are archived verbatim in
> [archive/CURRENT-2026-06.md](archive/CURRENT-2026-06.md).
