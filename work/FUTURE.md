# Future work backlog

> **Purpose:** Plans that aren't urgent enough for [NEXT.md](NEXT.md) and aren't tied to a numbered phase, but are worth keeping in writing so they don't drop out of memory.

---

# Feature-research sweep proposals — added 2026-08-03

> Source: `work/research/2026-08-03-feature-research.md` (evidence links,
> competitor landscape, and skeptic challenges per brief). Five of the eight
> PM-vetted briefs are spec'd below; the other three (guided statement
> reconciliation, sub-5s mobile quick-entry, FX-aware Sankey cash flow) live
> in the report until they reach the front of the implementation queue in
> NEXT.md.

## User rules engine + dry-run auto-categorization (extends categorize.rs + learn-from-edits)

**Status:** Proposed (feature-research sweep). Extension, not greenfield:
curated categorize.rs (1,109 lines) and merchant_key learn-from-edits
(imports.rs:481-505) already cover the import path; this adds explicit,
persisted, user-defined rules with a previewable diff.
**Tracking:** This file.

### Why
Dirty es-MX descriptors across nine MX parsers are the biggest recurring
chore. Strongest converged external evidence in the research sweep
(actual-ai 502★ bolt-on, Firefly HN thread, Monarch/Lunch Money rules docs).

### Plan
* `user_rules` table + CRUD; consulted before the curated engine.
* "Save as rule" affordance in transaction_detail_panel.dart.
* Rename actions ride the shipped cluster-rename machinery.
* Retroactive apply gated behind a dry-run diff — the diff is the safety
  mechanism, not polish. Cover BOTH import and Plaid (sync.rs) paths.

### Acceptance
* A rule created from a fixed Banamex row auto-applies on the next
  statement import AND retroactively via a previewed, confirmed diff.
* No historical totals change without an explicit confirm.

---

## Bills calendar + 1–90-day projected balances (extends the recurring MVP)

**Status:** Proposed (feature-research sweep). Extends /api/recurring/upcoming,
upcoming_bills_card, and loan due-pills; the missing pieces are the calendar
surface, expected↔posted matching, and the per-account balance curve.
**Tracking:** This file.

### Why
Verified 48–139-upvote asks across Actual/Firefly; users cite Monarch's
calendar as a switch reason. Fills the acknowledged gap between recurring
detection and FIRE-horizon projections.

### Plan
* Calendar widget on the cash-flow tab off /recurring/upcoming.
* Expected→posted matching (loan_match.rs is the precedent) with
  paid / late / missed states.
* Per-currency projected-balance curve from balance_snapshots; FX-transfer
  prompt ("move USD→MXN before the 15th").
* Manual-import MX accounts get a distinct "pending import" state —
  never render "missed" for a bill that may simply not be imported yet.

### Acceptance
* A detected CFE bill shows expected on the calendar, flips to paid when
  the posted row matches, and never shows a false red on a stale manual
  account.

---

## Net-worth change attribution: FX vs market vs flows

**Status:** Proposed (feature-research sweep). All inputs stored
(balance_snapshots native+USD per row, exchange_rates history, transactions);
no self-hosted tool decomposes this. Evidence thin (Worthmap markets the
SaaS equivalent); the case is internal fit.
**Tracking:** This file.

### Why
"Was it the peso or was it me" is the household's defining recurring
question; the 2026-08-02 balance-claim banners already do a mini version.

### Plan
* Dashboard endpoint decomposing period deltas into FX / market / flows
  per currency; must sum exactly to the observed delta (show a residual
  bucket rather than fudge).
* Currency-lens toggle on the net-worth card (USD / MXN / FX-held-constant).
* Optional weekly digest via the notifications bell (cron precedent exists).
* Respect carry-forward snapshots and gap-y FX history — the rust-backend
  skill's #1 bug class lives here; regression-test the sum invariant.

### Acceptance
* For any window: FX + market + flows (+ residual) == snapshot delta,
  per currency and in USD, on seeded fixture data.

---

## Household continuity dossier (bilingual export; inactivity switch deferred)

**Status:** Proposed (feature-research sweep). Dossier half only — no SMTP
infra exists and the spouse already has a read_only login, so the dead-man
switch is out of scope.
**Tracking:** This file.

### Why
A binational estate is the worst case (FBAR inventory, CetesDirecto, two
tax regimes); Bogleheads' "death binder" threads recur for a decade and
Kubera productized it. Patrimonio already maintains the executor's checklist.

### Plan
* Export endpoint aggregating accounts/institutions/loans/people plus
  owner-written instructions, rendered as printable bilingual HTML riding
  the tax_exports.rs / loans.rs lang-toggle pattern.
* Staleness note on the cover page ("data as of …") so the artifact is
  honest off-server.

### Acceptance
* One click yields an en or es-MX printable packet listing every
  institution/account/loan the app knows, suitable for a folder or safe.

---

## Annual transfer-cost report (spread analytics on cash_fx_transfers)

**Status:** Proposed (feature-research sweep). S-effort aggregate over
shipped implied-vs-spot machinery. Scoped to TOTAL cost vs mid-market —
the fee-vs-spread split is not computable for deducted-fee providers and
is explicitly out of scope for v1.
**Tracking:** This file.

### Why
Nobody — including Wise — totals what moving money between the two
countries costs per year. Demand evidence is thin (Firefly #5265 is the
nearest ask); this ships on owner utility and moat, and that's stated.

### Plan
* Aggregation endpoint summing (implied vs spot) deltas per year and per
  matched_keyword provider (with an "unknown" bucket for keywordless links).
* Summary section in the FX center sheet.
* Optional follow-up: manual per-transfer fee field, kept separate to
  avoid double-counting against the spread delta.

### Acceptance
* FX center answers "what did moving money cost us in <year>, total and
  by provider" with the ±7-day spot-rate caveat displayed.

---

## Mobile / settings follow-ups — deferred 2026-07-14

**Status:** Backlogged from the 2026-07-14 mobile UX + settings sprint
(see CURRENT.md). Each is scoped enough to pick up cold.
**Tracking:** This file.

* **Android per-app language.** Surface the in-app language choice to
  Android's per-app language settings (`android:localeConfig` in the
  manifest + `AppCompatDelegate.setApplicationLocales`); needs a plugin
  or a small MethodChannel, and an emulator smoke test (per the AGENTS.md
  Android rule — a green build alone doesn't prove launch behavior).
* **Server-side sync of theme/locale preferences.** Theme + language are
  device-local today (preferences storage); syncing them across devices
  needs a backend endpoint (natural home: an `app_settings` key, same
  pattern as `projection_assumptions`).
* **Fold the Settings tab's inline auto-archived-accounts card into the
  Hidden-items row.** The collapsible "Auto-archived accounts" section
  still renders inline in `dashboard_screen.dart`; HiddenItemsScreen is
  the established home for restorable hidden things.
* **Lending money fields hardcode the "MX$" glyph.** `lending_tab.dart`'s
  `_sym` getter feeds `prefixText: '$_sym '` on every amount field
  instead of going through the locale-aware currency helper.

---

## prefer_const_literals_to_create_immutables sweep

**Status:** Deferred, not blocking.
**Tracking:** This file.
**Owner:** Whoever next runs `dart fix` on the frontend.

### Background

The May 2026 light-theme sweep (`afded3a`) stripped `const` wholesale from `Text(...)` / `TextStyle(...)` / `Icon(...)` / `Divider(...)` expressions because the inside of those expressions now reads from `BuildContext` via `ThemeColorsExt` (`context.textPrimary`, etc.). `dart fix --apply --code=prefer_const_constructors` (`b784f3e`) reapplied `const` on the 185 call sites whose constructors stayed eligible, and `prefer_const_constructors` is now enabled permanently in `frontend/analysis_options.yaml` so the regression can't quietly accumulate again.

The companion lint `prefer_const_literals_to_create_immutables` covers the *children* lists of those constructors — `children: [SizedBox(...), Text(...), ...]` becoming `children: const [SizedBox(...), Text(...), ...]` when every element is itself const. This one is **off** because it has a higher false-positive rate than its sibling: a `const` list is immutable, so if downstream code later wants to mutate the children list (rare but real, especially in stateful widgets that compose conditional children), the const literal forces a refactor.

### Why we deferred it

`dart fix --apply --code=prefer_const_literals_to_create_immutables` would currently produce ~80-120 changes (rough estimate, run `dart fix --dry-run` to verify when the time comes). Each one needs eyes on it because:

- **Mutation hazard.** Some lists look immutable today but are spread into a `Column` that conditionally adds rows via `if (...)` or `...spread` syntax. If a `const` list ever needs to gain an element at build time, the cast becomes a runtime crash.
- **Hot reload edge cases.** Const literals get tree-shaken; replacing one with a runtime list can cause a hot-reload restart in some setups.
- **The benefit is small.** `const` on the children list saves one extra heap allocation per build. For Patrimonio at current scale (a few dozen rows per tab) that's invisible.

### Plan when picked up

1. Run a dry-run first to see the scope:
   ```bash
   cd frontend && dart fix --dry-run --code=prefer_const_literals_to_create_immutables
   ```
2. Apply only one file at a time, not the bulk-apply. For each change, eyeball the surrounding state class: if there's any `setState` that could conditionally add to the list, skip that one with `// ignore: prefer_const_literals_to_create_immutables` and a one-line rationale comment.
3. Run `flutter analyze` after each file to catch any regressions early.
4. Spot-check the affected widgets in both light and dark mode in the browser — most issues will surface as "this widget refuses to render" rather than as analyzer errors.
5. Once stable, opt the lint into `analysis_options.yaml` alongside `prefer_const_constructors` so future drift gets caught.

### When to do this

- Not before the next major UI feature lands (less churn = easier review).
- Maybe pair it with a "performance pass" once the app has more users and frame timings start to matter — at which point all the small allocation wins compound.
- A natural trigger: if a future widget refactor already has the file open and analyze flags ten of these in the same file, just apply them in the same commit.

### Rollback

`git revert` the single commit; the changes are mechanical and self-contained per call site. No data or schema impact.

---

## Color palette overhaul (dark + light) and chart hover polish

**Status:** Shipped in substance — the 2026-07-09 round-9 contrast pass
landed the brightness-aware accents (luminance-aware `context.onAccent`,
`BrandPalette` tearoffs for the nav rail, ~50 hardcoded-color swaps to the
`context.*` extension; see CURRENT.md's 2026-07-09 entry). Remaining from
the plan below: the M3 `surfaceContainer*` tonal layering and any long-tail
`Color(0xFF...)` literals the sweep left as intentional.
Already fixed since this was written — don't redo:
- The net-worth tooltip contrast bug below (`net_worth_card.dart`) — shipped in `f3dfd97` (brightness-aware `tooltipSurface`/`tooltipOnSurface` tokens + WCAG-AA unit tests) and `dda5e3c`; the projections tooltip (`wealth_projection_screen.dart`) uses the same tokens.
- The "hover feels mechanical" point — shipped 2026-05-27 (`touchSpotThreshold: 100000` + `getTouchedSpotIndicator` vertical guide on the net-worth + projection charts).
- Cash-flow chart tooltips enriched + currency-corrected (`2453a33`, 2026-06-19).
Still open (= this pass): light-mode contrast on the `#EDEFF3` scaffold, brand accents washing out on white, replacing scattered `Color(0xFF...)` literals with a brightness-aware accents map (`palette.dart` plan below), M3 `surfaceContainer*` layering.

**Tracking:** This file.

### Concrete pain points

**Dark mode**

- **Net-worth chart tooltip is unreadable.** `frontend/lib/widgets/net_worth_card.dart:456` sets the tooltip background to `colorScheme.inverseSurface` — which in dark mode is *light*. The text spans inside the tooltip (line 489, 502, 506, etc.) read `context.textPrimary`, `Color(0xFF00E676)`, `Colors.redAccent`, etc. In dark mode `textPrimary` resolves to near-white, so we render light-on-light. Same shape applies to `frontend/lib/screens/wealth_projection_screen.dart:629` for the projections tooltip.
- **Hover feels mechanical.** Every `LineChartBarData` in `net_worth_card.dart` sets `dotData: const FlDotData(show: false)` (lines 638, 654, 670). fl_chart's default `touchSpotThreshold` is ~10px, so unless the cursor is within 10px of a downsampled spot (we downsample to ~150 points) the tooltip just doesn't fire. The trend chart on the cash-flow tab feels OK because BarChart has wider native hit zones. Best practice for a continuous line: enable a `getTouchedSpotIndicator` callback that draws a vertical guide + a single highlighted dot wherever the cursor is along the X axis (the canonical Robinhood / Mint / Personal Capital interaction), and bump `touchSpotThreshold` or use `getTouchLineX` to snap to the nearest x.

**Light mode**

- **Body text contrast on the scaffold.** Cards (white) are fine, but the off-white scaffold (`#EDEFF3` in `main.dart:_buildLightTheme`) plus `context.textSubtle` (0.54 alpha) or `textFaint` (0.38 alpha) doesn't hit WCAG AA for normal text. Italic subtitles like the new "Unknown subtype" line inherit this problem. The empty-state copy on Tax planning, the chart axis labels, and the FX badge tooltip text are the most visible offenders.
- **Brand accents wash out at full opacity on white.** `Color(0xFF00E676)` (emerald), `Color(0xFF1DE9B6)` (teal), `Color(0xFFFFD600)` (yellow), `Color(0xFFFF4081)` (pink) all sit around 2:1 contrast against white. They're fine as fills behind dark text (the budgets card "over budget" indicator works), but they fail as foreground text on white, which is where most "+$1,234" / "−$56" tx amounts render.

### Current token inventory

Everything currently routes through these touch points — the palette overhaul should land here, not at the call sites.

| Token | Defined in | Notes |
|---|---|---|
| dark theme | `frontend/lib/main.dart` `_buildDarkTheme` | seed `0xFF00E676`, surface `0xFF1A1A24` |
| light theme | `frontend/lib/main.dart` `_buildLightTheme` | seed `0xFF00A352`, surface `Colors.white`, scaffold `#EDEFF3` |
| `textPrimary / Muted / Subtle / Faint` | `frontend/lib/utils/theme_colors.dart` | onSurface with alpha 1.0 / 0.7 / 0.54 / 0.38 |
| `hairline / tileSurface / tint(α) / accentSoft / accentBorder` | same file | dark vs light branches |
| brand accents (hardcoded) | dozens of `Color(0xFF...)` call sites | grep `Color(0xFF` to enumerate |

### Design direction

The user's brief: "clean, innovative, modern, expressive, good looking, and the two modes should play well together."

Some directions worth trying (not prescriptive):

- **Pick a single seed color** that produces good Material 3 schemes in both brightnesses. The current dark seed (00E676 emerald) is right for the brand but Material 3's tonal palette derived from it produces some chalky tertiaries — worth experimenting with a slightly muted variant for the seed and keeping 00E676 only as a brand accent.
- **Define an accents map**, not seven independent hex codes. Something like `class BrandAccents { static Color positive(Brightness); static Color negative(Brightness); static Color neutral(Brightness); ... }`. The brightness-aware getters return a slightly darker variant in light mode (for contrast against white) and the existing neon in dark mode. This is the missing piece — we keep tinting accents at the call site instead of having an accent that knows what brightness it's in.
- **Replace the EDEFF3 scaffold** with a colour that has more underlying chroma (a barely-tinted off-blue or off-grey) so the eye doesn't fight the lack of contrast against white cards. Material 3 calls this `surfaceContainerLow` / `surfaceContainer`.
- **Adopt M3's `surface*` tonal layers** rather than `tint(alpha)` overlays. `surfaceContainer`, `surfaceContainerHigh`, `surfaceContainerHighest` give proper layering without alpha-on-alpha murkiness.

### Acceptance criteria

- Every chart tooltip is legible in both brightnesses (use `colorScheme.onInverseSurface` for the body, or pick a tooltip surface that has guaranteed contrast against the text colour we want to use).
- WCAG AA (4.5:1 normal, 3:1 large) for all body and subtitle text against its actual background, both modes. Verify with `Color.computeLuminance()` ratios on the most common pairs (textSubtle on EDEFF3, accent text on white, axis labels on cards, etc.).
- The net-worth chart hover snaps along the entire X axis with a visible vertical guide and one highlighted spot, not the current "only fires inside 10px of a downsampled point" behaviour. Match the pattern in `frontend/lib/screens/account_transactions_screen.dart`'s balance sparkline once it picks up the same treatment.
- Both modes feel like the same app's two faces, not two different apps. Identical layouts, identical accents that just shift hue/value for the active brightness.

### Step-by-step plan when picked up

1. Run a quick audit script (10 min): grep every `Color(0xFF...)` literal across `frontend/lib/`, build a histogram by hex, identify the long tail vs the brand core. The fix lives in turning the long tail into a small set of named tokens.
2. Sketch the new palette as a single Dart file (`frontend/lib/theme/palette.dart`) that exports `Brand`, `Accents`, and `Surfaces` classes with brightness-aware getters.
3. Migrate `ThemeColorsExt` to delegate to the new palette so old call sites keep working through the transition.
4. Swap chart tooltips to use `inverseSurface` + `onInverseSurface` (the existing inverseSurface call is correct, the text spans need to switch to `onInverseSurface`). Add `getTouchedSpotIndicator` + a wider `touchSpotThreshold` to the net-worth chart.
5. Run the WCAG check function as a unit test so future regressions get caught:
   ```dart
   test('textSubtle on scaffold meets WCAG AA', () {
     expect(contrastRatio(textSubtle, scaffoldBg), greaterThan(4.5));
   });
   ```
6. Visual smoke: walk every tab in both modes, screenshot each, compare. Note any unexpected widgets that still look off (likely candidates: PDF export preview, snackbars, dialogs).

### Rollback

The migration is staged so each step has its own commit. The riskiest one is step 4 (tooltip surgery on charts) — if it goes wrong the chart still renders but tooltip text might be invisible. Easy to spot and revert.

---

## Personal lending  ✅ shipped (2026-05-30)

**Status:** Done — MVP + Phase 2 + Phase 3 + interest-income
accounting all shipped. Full design + per-phase breakdown in
[work/LENDING_FEATURE.md](LENDING_FEATURE.md). Opt-in via the
`lending_enabled` toggle (Management → Modules); migrations
2026052802 → 2026052806; ~115+ backend tests;
`frontend/lib/widgets/lending_tab.dart`.

What landed: reusable people directory + loans + reconciled
repayments (auto-suggest matcher), amortization schedules with
reminders, write-off/defaulted statuses, flexible per-year/per-month
rates, interest_only + compound interest types, printable
promissory-note agreement, and full interest-income accounting
(principal/interest split, per-year report, CSV exports, §7872
below-market flag). Now-DONE items that were once deferred: compound
interest, interest_only, agreement export, below-market flag.

Shipped since (2026-06/07): expected repayment date incl. no-interest
loans (`809bcf4`); accrued-interest row + loan aging report (`1841091`);
interest-income drill-down sheet + due/overdue/paid-ahead pills
(`6ffcf2b`); **custom irregular payment schedules + off-bank
reconciliation** (`14110dc`, 2026-07-03 — explicit-row schedules,
attach-tx for off-bank payments); full Lending-tab localization
(2026-07-06); data-safety hardening (unreconcile reverts instead of
deleting; principal-portion accounting; reconcile currency guard —
`f475ead`/`0d5c3c6`); interest summary `totals_by_currency` (`060dbb2`).

**Remaining deferred follow-ups:**

* **Multi-currency loan reporting-currency conversion** — loans store
  their native currency; a reporting-currency rollup across
  mixed-currency loans isn't converted yet (`totals_by_currency` labels
  per currency, but doesn't convert).
* **Mid-stream re-amortization** after a partial/irregular payment —
  regenerate the remaining schedule from the new balance. (Partially
  mitigated: a custom explicit-row schedule can now be entered by hand,
  `14110dc`.)
* **Schedule-B-formatted** (vs raw CSV) year-end document.

---

# Backlog handoff — May 2026

> Added by the auth/sessions session that landed `6772561`. The items below are pickup-ready for a fresh agent — each is scoped, has acceptance criteria, and points at the right files. Ordered by impact-per-effort, not by hard dependency. `work/NEXT.md` is stale (dated 2026-05-12, predates everything since auth shipped); refresh it once the next 1–2 of these land.

---

## 1. Better Plaid transaction descriptions  ✅ shipped (steps 1–4)

**Status:** Done. Migrations `2026051704_plaid_enrichment.sql` +
`2026051706_user_description.sql` are on `main`; the sync engine
pulls `original_description` + best counterparty; the frontend's
`displayLabel` walks counterparty → merchant → original →
description; per-row rename override (`user_description`) is wired
end-to-end with a pencil icon in the detail modal.

**Remaining follow-up:** integration test exercising a canned Plaid
JSON fixture into the enriched DB columns. Lower priority; the
hand-test on real Plaid Production data confirmed the path works.

---

## 2. FX-aware cost basis & lots  ✅ shipped (backend); frontend display is the follow-up

**Status:** Backend done end-to-end. The sync engine now pulls
`/investments/transactions/get` per Plaid institution and writes
proper FX-tagged lots. The `/api/dashboard/holdings` endpoint
returns true historical-FX cost basis per holding (sums each
lot's `qty * cost_per_unit / usd_fx_rate`) and falls back to
`holdings.cost_basis` at current FX only for institutions that
haven't been re-synced since the lot code shipped.

**Shipped:**

* Migration `2026051708_holding_lots.sql`: `holding_lots(id,
  holding_id, account_id, user_id, acquired_at, qty, cost_per_unit,
  currency, usd_fx_rate, source_id, created_at)` with per-user
  index + per-source unique partial index.
* `services/sync.rs`: new step 4 in the per-institution Plaid path
  calls `/investments/transactions/get` with a 1-year lookback,
  offset-paginated up to 250/page. Each event is dispatched by
  `type`/`subtype`:
  * `buy` and `dividend reinvestment` → new lot at the
    transaction's date / price / iso currency, with `usd_fx_rate`
    looked up from `exchange_rates` (nearest-prior to the
    acquisition date; falls back to most-recent rate, then a
    hardcoded 20.0 as last resort).
  * `sell` → FIFO deplete oldest lots (`qty > 0` only, ordered
    by `acquired_at ASC, id ASC`). A zero-qty marker row is
    inserted with the sell's `source_id` so re-syncs see it via
    the unique partial index and skip re-applying the depletion
    (prevents double-deletion of genuine lots on repeat syncs).
  * Cash dividends, fees, deposits/withdrawals → skipped
    (tracked via the regular /transactions/sync path).
* Soft-failure path: institutions without the `investments`
  product enabled return `INVALID_PRODUCT` / `PRODUCTS_NOT_SUPPORTED`
  — we log + skip without tainting the institution's sync_status.
* `/api/dashboard/holdings` already reads lots when present
  (committed in the prior `1323756` MVP); together with the new
  writer, fresh syncs produce accurate dual-currency P&L.

**Remaining (low-priority follow-up):**

* `frontend/lib/widgets/portfolio_card.dart` should render the new
  `cost_basis_usd` / `cost_basis_mxn` / `gain_loss_usd` /
  `gain_loss_mxn` fields explicitly. Today they're on the wire
  but the card only renders `value` / `cost_basis` /
  `gain_loss` (native). A bi-national display would show both
  sides of the P&L when the holdings list mixes USD + MXN
  securities.
* ~~Optional: a "lot breakdown" expansion per holding row~~ ✅ shipped
  2026-05-27 (click-to-expand lot modal with historical FX column).
* ~~Optional: persist realized gains on sell to a parallel
  `lot_disposals` table~~ ✅ shipped 2026-05-28 (migration
  `2026052801_lot_disposals.sql`); it now feeds realized-gains,
  tax planning, and the July CSV exports.

---

## 2b. Cross-currency cash-transfer linking (Wise / Bank → Nu / etc.)  ✅ shipped

**Status:** Done. Migration `2026051803_cash_fx_transfers.sql` plus
`services/fx_transfer_link.rs` + 4 dashboard endpoints
(`GET/POST /api/dashboard/fx-transfers`, `PATCH/DELETE
/api/dashboard/fx-transfers/{id}`). Auto-detection runs after every
sync — see `services::sync` end-of-function loop.

**Remaining (low-priority follow-up):** — ✅ both shipped:

* ~~"Cross-currency transfers" line on the cash-flow tab~~ ✅ 2026-05-27
  (`cross_currency_transfers_card.dart`, implied vs spot rate + delta
  pill; currency formatting fixed `2453a33`).
* ~~A "Manage links" view~~ ✅ the HiddenItemsScreen FX-pair section
  (2026-05-19) covers unlink/restore of detected pairs.

----

(Original plan retained below for historical context.)

### Why

The lot tracking in item 2 covers **investment securities** (stocks,
ETFs, mutual funds) bought via brokerage. It does not model the FX
event when the user moves cash between currencies via a remittance
service. Example real flow:

  US bank (USD)  →  Wise transfer (USD→MXN FX)  →  Nu Bank (MXN)

Today this shows up in Patrimonio as two unrelated `transactions`
rows: a USD outflow from the US bank and an MXN inflow at Nu Bank,
with no link between them and no recorded FX rate for the
conversion. As a result:

- The user has no record of the implicit Wise FX rate they got.
- "USD cash on hand" effectively disappears and "MXN cash on hand"
  appears, with no audit trail tying the two together.
- Any future "realized FX gain/loss on cash held in MXN" computation
  has nothing to anchor on.

### Plan

1. **Detection (best-effort, scoped):** a new service
   `services/fx_transfer_link.rs` looks at recent transactions and
   pairs USD-out + MXN-in (or vice versa) when:
   - The two transactions are within a tight window (default ±5 days).
   - The amounts line up at *some* plausible USDMXN rate (compare to
     `exchange_rates` for that date ±10% tolerance — Wise spreads can
     widen the gap).
   - The description on one or both contains a remittance hint
     ("WISE", "TRANSFERWISE", "REMITLY", "XOOM", "WESTERN UNION").
2. **New table** `cash_fx_transfers(id, user_id, source_tx_id,
   dest_tx_id, source_amount, source_currency, dest_amount,
   dest_currency, implied_fx_rate, detected_at, detection_confidence,
   user_confirmed)` storing the linked pair + the back-computed rate.
3. **Frontend:** in the transaction detail modal, when a row is
   part of a linked transfer, show a "Linked to" block with the
   counterpart transaction + the implied FX rate + a "Confirm" /
   "Unlink" pair of buttons so the user can override the auto
   detection.
4. **Reporting:** add a "Cross-currency transfers" line to the cash
   flow tab showing each linked transfer with the implied rate next
   to the day's market rate — so the user can see whether Wise gave
   them a good or bad deal compared to the spot rate.

### Acceptance

- A USD-out transaction at $1000 + MXN-in transaction at MX$19,500
  two days later, both with "WISE" in the description, auto-link.
- The implied rate (19.5) appears on both transactions' detail
  modals + on the cash-flow tab.
- Manual link / unlink actions persist across syncs.

### Out of scope

- Realized FX gain/loss on the MXN cash *held* over time (changes
  in spot rate after acquisition). That's a separate, harder
  question: it requires deciding when "MXN held since the Wise
  transfer" stops being a coherent unit (each Nu Bank outflow is
  arguably a lot disposal). Park this until users actually ask.

---

## 3. "What changed since last login" diff banner  ✅ shipped

**Status:** Done. Migration `2026051802_previous_login_at.sql` added
`users.previous_login_at`, rolled forward by every login path
(password / TOTP / passkey). `GET /api/dashboard/since-last-login`
returns `{previous_login_at, new_transactions, largest_move,
sync_errors[]}`; `widgets/since_last_login_banner.dart` is dismissible
(keyed on the anchor timestamp). "View" CTA seeds the Transactions
tab's date filter to `(anchor → today)`.

----

(Original plan retained below for historical context.)

### Why

`users.last_login_at` already exists. `balance_snapshots` already exists. With those two we can answer "what changed since you were last here" cheaply.

### Plan

Backend: new endpoint `GET /api/dashboard/since-last-login` that returns:
- New transactions count since `users.last_login_at`
- Largest absolute balance move (USD), with the account name
- Any new `sync_status = 'error'` rows
- Format: `{ new_transactions: 12, largest_move: {account, delta_usd}, sync_errors: [...] }`

Frontend: dismissible banner above NetWorthCard on the Overview tab that surfaces this on first render after login. State managed in `Preferences` so it stays dismissed for that login.

### Acceptance

- Bootstrap a user → make a transaction via the manual entry API → sign out / sign in → banner appears with "1 new transaction".
- Banner is dismissible and stays dismissed within the same session.

---

## 3b. Drag-and-drop + reliable multi-file import UX  ✅ shipped

**Status:** Done. `frontend/lib/services/file_drop_web.dart` is a
global `GlobalFileDropListener` that attaches `dragenter` /
`dragover` / `drop` handlers to the document (the drop zone in
Flutter has no stable DOM node to attach to; global capture is
simpler and there are no competing drop targets on the page).
Dropped files filtered to `.csv` and `.pdf`, read into bytes via
`File.arrayBuffer()`, wrapped into `PlatformFile` so the existing
upload pipeline doesn't know the difference.

UI changes in `import_screen.dart`:

* `_isDragging` state flag flips the drop zone border to solid
  green + adds a faint accent wash background while a drag is in
  progress, and swaps the helper text to "Drop to import".
* When idle on web, the helper text reads "Drop CSV or PDF files
  anywhere on this page, or select them manually below." so the
  multi-select capability is discoverable.
* Button rewritten as `ElevatedButton.icon` with "Select files"
  (plural) label.
* Dropped files append to the existing `_selectedFiles` list with
  a snackbar "Added N files from drop" so the user gets feedback.

Verified live: synthetic `dragenter` dispatched via JS
console returns `defaultPrevented: true`, confirming the listener
is attached and calling `preventDefault()`. Visual hover state
flips correctly (zoomed screenshot taken). Real file drops from
Finder/Explorer should work too — same code path.

**Remaining (optional polish):**

* Reject feedback: today rejected `.xlsx` / `.docx` drops are
  silently dropped with a `debugPrint`. A transient snackbar
  ("Only CSV and PDF files are supported") would be nicer.
* Folder drops (recursing into directories) — not yet supported.
  Nobody's asked; revisit if anyone does.

---

## 4. Real-estate and other manual assets

**Status:** ✅ shipped 2026-05-26 — `2026052601_valuation_notes.sql`, per-row "Revalue" dialog with notes for manual-asset types, snapshots feed the net-worth chart. See CURRENT.md's 2026-05-26 sprint entry.

### Plan

The `accounts` table already accepts arbitrary `account_type`. Two new types: `real_estate` and `private_equity`. The challenge is value updates — these don't sync automatically. Add a simple UI:

- In Management tab, "Add manual asset" dialog (extending `add_account_dialog.dart`) with `account_type` selector + optional `last_valued_at` + `valuation_notes` text field.
- Periodic revaluation: a "Revalue" button next to each manual asset that bumps `current_balance` and writes a new `balance_snapshots` row.
- Surface in NetWorthCard's existing aggregation (already category-aware) — should "just work" once the rows exist.

### Acceptance

- Add a `$500k home` real-estate asset, revalue to $550k a month later, NetWorthCard reflects both points in the history chart.

---

## 5. Multi-user support  ✅ shipped (data model + invitation flow)

**Status:** Done. Migration `2026051705_multi_user_ownership.sql` added
`user_id` to institutions/accounts/transactions/holdings/
balance_snapshots; every financial query updated with the ownership
predicate (~60 queries). Invitation-based registration shipped in
`2026051707_invite_tokens.sql` + `api/invites.rs` + the
`RegisterScreen` UI. The bootstrap path remains for the first user
only.

**Remaining (low-priority follow-up):**

* ~~`app_settings` is still global~~ ✅ shipped in migration
  `2026051805_app_settings_user_id.sql` — column added, backfilled
  to the bootstrap user, primary key changed to `(user_id, key)`,
  both handlers filter on `ctx.user_id`.
* Roles (`owner` vs `read-only`) deferred — single-household
  deployments don't need it; revisit if there's actual demand for
  advisor access.
* Integration test exercising cross-tenant isolation.

---

## 6. Production Plaid readiness  — ✅ effectively done

**Status (2026-07-07):** Deployed. Prod runs on the homelab host
`thelab` (docker compose at `/mnt/data/docker/stacks/patrimonio`, api
`:8085`) — the "public HTTPS endpoint" gap below is closed; see
`docs/migration.md` for the runbook that moved it. The sandbox-vs-prod
indicator chip also shipped (reads `plaid_environment` in
`dashboard_screen.dart`). Original status kept below for history.

Production credentials are live. Webhook receiver +
ES256 verification + per-item scoped sync are all on `main`. The
gap that remains is purely deployment: nobody's actually told Plaid
where to deliver webhooks.

### Shipped

* ES256 JWT verification (`services/plaid_webhook_verify.rs`).
* Receiver at `/api/institutions/webhook`, public router, refuses
  unsigned requests.
* `PLAID_WEBHOOK_URL` config field + Link-token wiring in both
  `create_link_token` and `create_reconnect_token` — items linked
  from this point on inherit the webhook URL.
* Status-only codes (`ITEM_LOGIN_REQUIRED`, `PENDING_EXPIRATION`)
  flip the institution's `sync_status` without firing a sync.
* Update codes (`DEFAULT_UPDATE`, `HISTORICAL_UPDATE`,
  `INITIAL_UPDATE`, `SYNC_UPDATES_AVAILABLE`, `TRANSACTIONS_REMOVED`)
  trigger `sync_one_institution(item_id)` — scoped, not global.
* Sticky reconnect banner above the dashboard that opens Plaid Link
  directly (no Management-tab detour).

### What's left

* **Public HTTPS endpoint.** Today's `docker compose up` on a
  laptop isn't reachable from Plaid's egress. Need a real deployment
  (nginx + Let's Encrypt) with `PLAID_WEBHOOK_URL` pointed at it.
  See NEXT.md item 3 for the deployment runbook scope.
* **Sandbox vs Production indicator chip** in the AppBar so the user
  knows which environment they're in. `/api/setup/status` already
  exposes `plaid_env`; the frontend just needs to render a small
  amber pill next to the FX badge when env != "production".
* **Forced ITEM_LOGIN_REQUIRED drill** — Plaid sandbox can simulate
  this; verify the reconnect banner + inline Plaid Link flow work
  end-to-end.

### Acceptance

A real bank account links end-to-end against `production` Plaid, the
api receives an `INITIAL_UPDATE` webhook (visible in
`docker logs patrimonio-api-1 | grep "Plaid webhook"`), and the
dashboard updates without the user clicking Sync.

---

## 7. Backups + restore runbook  ✅ shipped

**Status:** Done. See commit `055aa46` and `docs/operations.md`.

### What landed

* `scripts/backup.sh` — `pg_dump | gpg --symmetric AES256 > timestamped
  file`, picks postgres by compose-project label, retention pruning
  (default 14), sidecar `.meta` (migration head + pg version + source
  project + byte size), round-trip self-verify before returning
  success.
* `scripts/restore.sh` — decrypt → DROP/CREATE → psql with
  ON_ERROR_STOP, confirmation prompt naming the project being
  clobbered (`--yes` skips for cron), prints smoke counts after.
* `scripts/rotate-encryption-key.sh` + `backend/src/bin/
  rotate_encryption_key.rs` — one-shot binary shipped in the api
  image, walks every `*_enc` column, decrypts with OLD, re-encrypts
  with NEW, self-checks via round-trip BEFORE committing.
* `docs/operations.md` — backup strategy, cron line, restore drill
  against an isolated `-p patrimonio-restore-test` project,
  disaster recovery against `patrimonio`, ENCRYPTION_KEY rotation
  procedure, common failure modes.

Drill executed against real Production data: 4 plaid_access_token_enc
+ 1 totp_secret_enc preserved across backup → restore → rotation →
re-rotation back to original.

### Optional follow-ups

* Off-machine backup sync (rsync to a separate host / S3). The dump
  is already AES256-encrypted so it's safe to drop on any storage
  the user trusts to be durable.
* Auto-monitor: alert when `~/.patrimonio-backup.log` shows no
  successful run in 48h.

---

## 8. Smaller polish wins

Each <1hr, pick up whenever the file is open for another reason:

- **Recovery-codes count warning.** Security screen shows `_unusedRecoveryCodes` count but no warning when low. Add a banner / yellow tile when count drops below 3.
- **`/api/auth/sessions` show "new since last visit" badge.** Use `users.last_login_at` to flag sessions created since.
- **Update `work/NEXT.md`.** Stale by ~weeks. Move Phase 11 (Plaid prod) to in-progress status, mark Phase 13 (data quality) done.
- **`README.md` auth section.** Document TOTP enrollment + recovery codes flow. Currently only bootstrap is documented.
- **CORS audit.** `ALLOWED_ORIGINS` warning fires if empty but isn't surfaced in `/api/setup/status` — would help during deployment debugging.

---

## What's done already (for context for the new agent)

Don't re-do these — all on `main` as of `6772561`:
- Full auth: bootstrap, login, logout, change password, recovery codes, TOTP 2FA, audit log, rate limiting.
- Active sessions UI (list, per-session revoke, sign-out-everywhere).
- Multi-file statement import (backend + frontend).
- Assets-vs-liabilities ratio bar on the Overview tab.
- Parser test rescue: `cargo test --lib` is green (was 14/20 passing, now 20/20).

Test infra ready to lean on:
- `backend/tests/auth_endpoints.rs` and `backend/tests/auth_recovery_totp.rs` (integration, need `PATRIMONIO_TEST_DATABASE_URL` env var to run).
- `scripts/smoke.cjs` (API + Playwright walk; covers the bootstrap → dashboard golden path).
- `/tmp/ui-auth-test.cjs`, `/tmp/ui-recovery-totp-test.cjs`, `/tmp/ui-sessions-test.cjs` — one-off Playwright tests; worth moving into `frontend/test/` if a similar UI flow comes up.

---

## Biometric / passkey sign-in (FIDO2 / WebAuthn)  ✅ shipped

**Status:** Done. `passkey_credentials` table on main; `webauthn-rs`
wired into `api/passkeys.rs`; register flow lives on the Security
screen, login flow on `auth_gate.dart` ("Sign in with passkey").
Cross-device (phone-to-desktop QR) and hardware-key support both
work transparently via `webauthn-rs`. Discoverable credentials are
the default; account recovery still falls back to password + TOTP.

---

## Security + performance audit — deferred follow-ups (May 17 2026)

> Items raised by the May 17 audit (commit context: `34c47a7`'s direct successor) that did NOT land in the same PR. Each one is scoped so the next agent can pick it up cold.

### Plaid webhook JWT verification  ✅ shipped

**Audit ID:** H3. Shipped in commit `04c9038`. ES256 verification
via the `jsonwebtoken` crate, signing key cached in-process by `kid`
(1-hour TTL), 5-minute `iat` anti-replay window, constant-time SHA-256
comparison between the JWT's `request_body_sha256` and the actual
body bytes. See `backend/src/services/plaid_webhook_verify.rs`.

### Multi-user data model (IDOR latency)  ✅ shipped

**Audit ID:** M7. Shipped in commit `83023da`. `user_id` columns +
ownership predicates everywhere; cross-tenant data exposure is no
longer possible. See entry "5. Multi-user support" above for the
remaining low-priority polish (`app_settings`, roles, isolation
integration test).

### CSRF defence-in-depth  ✅ shipped

**Tracking:** This section. **Audit ID:** H4. **Status:** Done.
`session::require_csrf_header` middleware rejects POST/PUT/PATCH/
DELETE on the protected router without `X-Requested-With`. Frontend
`api_service.dart` + `passkeys.dart` + the `connect_bank_screen`
Plaid Link flow all send `X-Requested-With: fetch`. CORS extended
in `main.rs::build_cors_layer` to permit the header on preflights.

### Rate-limit hardening — ✅ shipped 2026-05-19

**Audit ID:** M2. **Status:** Done.
* 50-150 ms `password::random_login_jitter()` runs on every
  failed verify (unknown user / inactive / bad password / bad
  TOTP / bad recovery code). Stops sub-threshold spray attacks
  from probing at HTTP throughput.
* `rate_limited` now does an exponential-backoff sleep on the
  429 path: 1 s → 2 → 4 → 8 → 16 → 30 capped, indexed by
  attempts-past-threshold. A persistent brute-forcer's
  effective throughput collapses to ~1 attempt per 30 s per
  username once they cross the line; legitimate user who
  mistyped 5× experiences at most a 1 s delay on attempt 6.
* Global anonymous-failure counter was contemplated but skipped
  — the per-IP path (threshold × 3) covers the spread-across-
  usernames case, and the global counter adds an in-memory or
  Redis dependency without a clear additional defence.

### Trusted-proxy aware `client_ip`  ✅ shipped

**Tracking:** This section. **Audit ID:** L4. **Status:** Done.
New `TRUSTED_PROXY_CIDRS` env var parsed into `Vec<ipnet::IpNet>`.
Edge middleware `sanitize_forwarded_headers` (in `main.rs`) strips
X-Forwarded-For + X-Real-IP from requests whose TCP peer isn't in
the allow-list. `axum::serve` uses `into_make_service_with_connect_info::
<SocketAddr>()` so the middleware can read the peer.

Verified live: spoofed XFF from an untrusted peer lands in
`auth_audit.ip_address = NULL` (header stripped at the edge before
the handler ran).

### HIBP / breached-password check

**Tracking:** This section. **Audit ID:** L3.
**Status:** ✅ shipped 2026-05-26 — `password::check_hibp_breached` (k-anonymity range API, fail-open, `HIBP_API_BASE` config) wired into bootstrap/register/change-password/recover. See CURRENT.md's 2026-05-26 sprint entry.

**Plan:** Either ship an embedded top-100k bloom (~80 KB) loaded at startup, or call HIBP's k-anonymity range API on signup + change-password. The bloom is simpler and avoids the network round-trip on the hot path.

### Streaming CSV export — ✅ shipped 2026-05-19

**Audit ID:** P4. **Status:** Done.
`export_transactions_csv` now streams both ends of the pipe:
`sqlx::query(...).fetch(&db)` hands rows to the writer one at
a time (instead of buffering the result set in a Vec); the
writer pushes formatted lines into an `mpsc::channel` wrapped in
`tokio_stream::wrappers::ReceiverStream` and handed to
`axum::body::Body::from_stream`. A 50k-row export now fits in
O(channel_buffer × row_size) RAM instead of O(row_count ×
row_size × ~5 CSV overhead). Added `bytes`, `tokio-stream`,
`futures-util` as direct deps (already transitive).

### Net-worth aggregation in SQL

**Tracking:** This section. **Audit ID:** P5.
**Status:** ✅ shipped 2026-05-18 — single `jsonb_object_agg` query; see section H below (this entry was a duplicate).

### Connection-pool size  ✅ shipped

**Audit ID:** P7. Bumped in the audit-driven commit `6e1270a`. Pool
default for the API container is now 20.

### WebAuthn `localhost` rp_id rewrite

**Tracking:** This section. **Audit ID:** M8.
**Status:** The local-dev rewrite collapses `127.0.0.1` to `localhost` for the WebAuthn rp_id. Passkeys registered against `localhost` won't work if the user later types `127.0.0.1` into the address bar. The audit flagged this as a "fail loud, don't silently rewrite" preference.

**Defer rationale:** Until we hit a real ambiguity (user complaining "my passkey doesn't work"), the rewrite is the lower-friction default — it matches the standard browser behaviour for the localhost exception. Revisit if anyone reports the gotcha.

### Encrypt webauthn-rs flow state at rest in Redis

**Tracking:** This section. **Audit ID:** Dependency observation.
**Status:** ✅ shipped 2026-05-27 — `store_state`/`take_state` AES-GCM round-trip with `ENCRYPTION_KEY`, `v2:` prefix, `v1:` plaintext fallback when no key is configured. See CURRENT.md's 2026-05-27 sprint entry.


---

# Backlog handoff — late May 2026

> Added after the 2026-05-18 walkthrough confirmed the dashboard,
> security, and tx-management batches all work end-to-end against
> real Production data. These are the ideas that came up during the
> walkthrough but didn't fit the in-scope batches. Ordered by
> impact-per-effort.

## A. Split-transaction polish  ✅ mostly shipped

* **"Split" chip on child rows** — ✅ already shipped earlier.
* **Quick-split presets** — ✅ shipped 2026-05-18. Tune icon in the
  dialog title bar opens 50/50, 60/40, 70/30, 40/30/30, and an
  "Even split…" with a 2..10 slider. Each preset preserves any
  description/category the user already typed.
* **Edit-split** — ✅ shipped 2026-05-18. Outlined "Edit split"
  button next to "Unsplit" in a child's detail modal. Pre-
  populates the dialog with the existing children, saves via
  unsplit-then-resplit (the backend rejects re-splitting an
  already-split parent, so we tear down + recreate). Sibling
  lookup is client-side against the currently-loaded transactions
  list — fine for typical 2-5 way splits; if very large splits
  ever matter, add a `GET /transactions/{id}/splits` endpoint.

Open follow-ups for this surface:

* **Edit-split with mid-flight failure recovery** — ✅ shipped
  2026-05-18. New `PUT /api/accounts/transactions/{id}/splits`
  replaces children inside a single DB transaction, eliminating
  the race window. Frontend uses it when available, falls back
  to the legacy two-step flow when not. Integration test
  `put_replace_splits_atomic` + a validation-rollback test lock
  the behaviour in.
* **Split per-row category picker** — ✅ shipped 2026-05-18.
  Each split row now has a dropdown of distinct categories
  present in the loaded transactions list, with a "Same as
  parent" sentinel at the top and preservation of unknown
  initial values as an "(existing)" option.

## B. Subscription detection improvements  ⏱️ ~half day total

* **Unhide UI** (✅ partial — the dismiss × on the active rows is
  still one-way at the card; a "Manage hidden merchants" panel
  rolled into Section D below is the proper home).
* **Cancelled-subscription detection** — ✅ shipped 2026-05-18.
  Detector tags `status: "active"|"cancelled"` and the card
  renders a collapsed "Stopped (N)" section for clusters last
  charged 91–548 days ago. Older clusters are still dropped as
  noise.
* **Per-account split** — ✅ shipped 2026-05-18. Detector now
  tallies spend per account inside each cluster and returns a
  `by_account` array (sorted by share descending). Frontend
  renders compact chips under the cadence subtitle when the
  cluster spans ≥ 2 accounts, capped at 3 + "+N more".
* **Sign-convention bug fix** — ✅ shipped 2026-05-18. The
  detector was filtering on `amount > 0` (income) instead of
  `< 0` (expense) — "Interest earned" and similar income rows
  were clustering as fake subscriptions. Window widened to
  548 days while we were in there.

## C. Mexican CSV / PDF parser polish — ✅ shipped 2026-05-18

`parser::polish_description` strips trailing date suffixes
(`20260418`, `18/04/2026`, `18-04-2026`) and a bilingual generic-
prefix list (`MISC DEBIT`, `ACH `, `POS `, `COMPRA `, `RETIRO `,
`ABONO `, `CARGO `, `DEPOSITO `, `TRASPASO `, `PAGO `, etc.) when
there's meaningful text after stripping. `detect_and_parse` wraps
every parser branch with `polish_all(...)` so the cleanup runs
regardless of which parser fired. Direct callers
(`banamex::parse_csv`, etc.) still get raw output — the existing
unit tests passed unchanged.

Open follow-ups for this surface:

* If the PDF parsers also stash `merchant_code` / `payee` tokens
  they currently throw away, plumb them through to
  `payment_payee` / `original_description` columns so the
  frontend display ladder can pick them too. The polish helper is
  good enough for now; the column-level fix is for later when the
  parsers themselves are touched.

## D. "Unhide" / general "Manage hidden things" panel — ✅ mostly shipped 2026-05-18

* **Ignored subscriptions** — ✅ surfaced in the new HiddenItemsScreen
  with per-row Restore action. Uses the pre-existing
  `/dashboard/subscriptions/ignored` GET + DELETE endpoints.
* **Since-last-login banner** — ✅ surfaced with a "Show again"
  action that clears the Preferences localStorage key.

Deferred follow-up:

* **FX-pair "never re-suggest"** — ✅ shipped 2026-05-19. New
  migration `2026051808_dismissed_fx_pairs.sql`, detector
  predicate in `fx_transfer_link::detect_for_user`, transactional
  unlink (delete + dismissal insert in one tx), and a new
  FX-pair section in `HiddenItemsScreen` with a Restore button.
  In passing, fixed a latent sign-convention bug in the FX
  detector (was filtering for `amount > 0` as outflow, but the
  app stores expense as negative; the detector had been finding
  zero candidates against real data).

## E. Production deployment runbook — ✅ shipped 2026-05-18

`docs/deployment.md` now has a "VPS deployment (single-host)"
section covering host provisioning, nginx + Let's Encrypt sample,
`TRUSTED_PROXY_CIDRS` setup, the webhook activation flow
(re-link OR the new `POST /api/institutions/update-webhook`
one-shot), log rotation, and a pointer to the backup runbook.

`/api/setup/status` reports the `plaid_webhook` check; the
Management tab's setup card renders it generically alongside
every other check **and** shows a "Push to N institutions"
trailing button when `plaid_webhook` is configured AND ≥ 1 Plaid
item is linked. The button triggers
`/api/institutions/update-webhook` and shows a per-row
updated/failed dialog. The card's bottom-line recap is also
dynamic now (no more hard-coded "configure live exchange rates").

## F. Sandbox vs Production indicator chip  — ✅ shipped

(Chip renders from `plaid_environment` in `dashboard_screen.dart`.)

`/api/setup/status` already exposes `plaid_env` (`sandbox` /
`development` / `production`). The frontend should render a tiny
amber pill next to the FX badge when it's not "production" — so
the user has a visual cue when they're hitting the test bank.

Files: `frontend/lib/screens/dashboard_screen.dart` (AppBar actions
list), maybe a new small widget under `widgets/`.

## G. Real-time dashboard via websockets — ✅ shipped 2026-05-19

New `services::realtime::Realtime` hub: per-user
`tokio::sync::broadcast::Sender` keyed in a
`RwLock<HashMap<Uuid, Sender>>`. `GET /api/realtime/ws`
upgrades to a websocket on the protected router (cookie auth
inherited from the handshake), subscribes the user, fans every
`RealtimeEvent` to all open tabs. Sync handlers + import
confirm publish `TransactionsChanged`; the vocabulary is coarse
("go refetch X") so payloads stay tiny.

Frontend `RealtimeService` connects at dashboard boot with
capped exponential-backoff reconnect (1 → 2 → 4 → 8 → 16 → 30 s).
Disposed on logout. The dashboard routes every event into
the existing `_loadAllData(silent: true)` path — multi-tab
consistency + Plaid-webhook-driven refresh, free.

Open follow-ups (defer until they bite):

* Redis pub/sub backplane when a second API instance ships
  (today's in-process map only fans events within one
  process).
* nginx config note for `Upgrade` + `Connection` headers in
  the prod deployment runbook.
* Wire more emit points — splits, rename, account create —
  for full multi-tab consistency. Today only sync + import
  publish.

## H. Net-worth aggregation in SQL — ✅ shipped 2026-05-18

`dashboard.rs::net_worth_history` was rewritten as a single
`WITH per_inst AS (...) SELECT ... jsonb_object_agg(institution_name,
inst_net) GROUP BY as_of_date` query, returning one row per date
with the per-institution map pre-built. The endpoint's JSON shape
is unchanged. Liability sign continues to be respected via the
`is_liability_account_type` helper. Integration test
`net_worth_history_aggregates_per_date_and_institution` +
`net_worth_history_handles_liabilities` lock the behaviour in.

## I. Inline transaction rename + bulk-edit polish — ✅ partially shipped

* **Right-click → rename dialog** — ✅ shipped 2026-05-19.
  Right-click on a transaction row opens the lightweight
  `_renameTransaction` dialog directly, skipping the detail-
  modal hop. The bulk-apply "also apply to N matching" checkbox
  shows when the row is part of a description-cluster (same
  `_similarTransactionIds` helper the detail modal uses). Long-
  press still triggers selection mode — those two gestures
  don't compete now.

Remaining: — ✅ both shipped 2026-05-28 (backlog-cleanup bundle, see
CURRENT.md): true inline rename via double-click TextField, and the `R`
shortcut on the hovered row (no-ops inside EditableText).

## J. Flutter canvaskit responsiveness  ⏱️ unknown — still open (2026-07)

> 2026-07-07 note: still biting under browser automation (screenshot
> freezes on heavy Portfolio scrolling); the known workarounds — filter
> the holdings list to one ticker, or use a shorter window (1280x900) —
> are documented in HANDOFF.md's "Known quirks". No user-facing
> complaint yet.

Observed during walkthrough: rapid taps + screenshots occasionally
freeze the renderer for 30+ seconds. Recovers on next interaction.
Doesn't appear in normal user pacing. Worth keeping a note in case
it gets worse with more widgets on the page:

* Consider switching from canvaskit to the html renderer for
  layout-heavy screens (transactions list, recurring charges) —
  `flutter build web --web-renderer html` is the global switch but
  it sacrifices some font rendering quality.
* Or audit for accidental rebuild loops (every setState in the
  dashboard rebuilds 7 tabs). The `_KeepAliveTab` wrapper around
  each tab already mitigates this; could check whether the
  TransactionsTab's `didUpdateWidget` is firing more than necessary
  when `_txDateSeed` clears.

This is a "investigate when it actually annoys someone" item, not
urgent.

## K. Test infrastructure — ✅ mostly shipped 2026-05-18

New `tests/dashboard_endpoints.rs` covers the recently-added
endpoints via the same `tower::ServiceExt::oneshot` pattern as
`auth_endpoints.rs`. 14 tests across:

* `/api/institutions/update-webhook` — 503 / 400 / 200-empty /
  401 / 403 (no CSRF).
* `/api/accounts/transactions/{id}/splits` — create, sign-
  validate, amount-validate, already-split-422, cross-user 404.
* Edit-split round-trip (POST → DELETE → POST with new ratios)
  locks in the frontend's "Edit split" flow.
* Unsplit nonexistent → 404.
* `/api/dashboard/since-last-login` — empty + populated cases,
  including the parent-hidden-when-children-exist contract.
* `/api/dashboard/subscriptions/ignore` + ignored + DELETE —
  round-trip with idempotency, lowercase normalisation, empty-
  rejection.
* `/api/dashboard/fx-transfers` — empty listing.
* `/api/dashboard/net-worth-history` — per-date / per-institution
  aggregation AND liability sign (locks in the SQL rewrite from
  section H).

Tests gate on `PATRIMONIO_TEST_DATABASE_URL` — when unset they
print a skip note and return Ok, so `cargo test` stays green for
contributors without a Postgres on hand.

Open follow-ups:

* ~~**Tests must run serially**~~ ✅ shipped 2026-05-28 — `serial_test`
  annotations on every integration test + a Postgres advisory-lock
  `TestLockGuard`; plain `cargo test` Just Works. **2026-06-20 addendum
  (`4af62e3`):** the suite had been *silently skipping* for weeks
  (wrong default POSTGRES_PASSWORD → DB auth failure → vacuous pass);
  it now sources the password from `.env` and PANICS on a
  configured-but-unreachable DB. CI runs it on every push/PR
  (`8690433`).
* `scripts/smoke.cjs` — ✅ extended 2026-05-18. New
  `smokeRecentFeatures` step covers split / PUT-edit-split /
  unsplit roundtrip, subscription ignore/unignore, FX-transfer
  list + detect, since-last-login shape, and the per-account
  `by_account` array on `/dashboard/subscriptions`. Also fixed
  a pre-existing CSRF-header gap in the `request()` helper that
  was silently 403-ing the manual-account POST.
* The integration tests don't cover Plaid sync, FX detector
  service, passkey ceremonies, or invite minting — those have
  much bigger surface areas and warrant their own files.
