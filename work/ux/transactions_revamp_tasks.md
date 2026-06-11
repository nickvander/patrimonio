# Patrimonio Frontend — UI Review Triage & Task Plan

**Prepared by:** Product, after spot-checking critic findings against the codebase at `c03b0a9`
**Date:** 2026-06-10

## Executive summary

Four critics produced 29 raw findings. I verified every load-bearing claim I sampled directly against the code, and **all of them held**: the split-dialog focus loss (`ValueKey` embedding `amountText`, split_transaction_dialog.dart:330), the `clamp(400.0, h*0.78)` crash on short viewports (transactions_tab.dart:1544), the detail panel's raw-enum free-text category field with an unconditional Save (transactions_tab.dart:2030, 2364, 2546-2556), the stock-reprice-plus-full-reload on every single edit (dashboard_screen.dart:1544-1549, 2935-2978), the account panel's unscrollable `Expanded(TransactionsTab)` with eager `Column` rows (account_transactions_screen.dart:940), the missing `Intl.defaultLocale`/`initializeDateFormatting` (grep: zero hits in lib/), the white-on-white skeleton (skeleton.dart:57-62), the search haystack omitting `user_notes`/amount (transactions_tab.dart:415-443), and the keyboard-only palette (`_openPalette` referenced exactly twice). The critics are credible; the main editorial work was **merging heavy overlap** (the split-dialog bug, the category-edit problem, the hardcoded-color problem, and the account-panel problems were each reported 2-3 times) and **deprioritizing two large speculative refactors**.

The plan below is 15 tasks in four milestones, weighted toward the transactions look & feel per the product owner's stated priority. Milestone 1 is all P0: two outright bugs (a crash, a focus-loss that breaks the split editor's core interaction), one silent data-mutation footgun, and the latency tax that makes every categorize feel slow. Milestone 2 is the transactions visual revamp. Milestones 3-4 cover the account panel and platform polish.

---

## Milestone 1: Transactions — fix what's broken (all P0)

### Task 1 — Fix split-dialog amount fields losing focus on every keystroke
- **Priority:** P0 · **Size:** S
- **Problem:** Each split row's key embeds the live amount text (`ValueKey('split-row-…-${_drafts[i].amountText}')`), and the amount field's `onChanged` rewrites that text in `setState`. Every keystroke changes the key, Flutter recreates the row subtree, and focus drops. Typing a custom split amount — the dialog's core interaction — requires re-clicking the field per character. (Two critics independently found this; confirmed in code.)
- **Files:** `frontend/lib/widgets/split_transaction_dialog.dart` (rows ~320-375)
- **Acceptance criteria:**
  - Each `_SplitDraft` gets a stable identity (e.g. `final int id` assigned at construction) used as `ValueKey(draft.id)`; description and amount fields use draft-owned `TextEditingController`s instead of `initialValue` + `onChanged`.
  - Ratio presets (60/40 etc.) still refresh the visible amounts — by writing into the controllers, not by recreating widgets.
  - Regression widget test: type 3+ characters into an amount field, assert focus is retained and the text is intact; apply a preset, assert fields update.

### Task 2 — Fix `clamp` crash in the transactions list on short windows
- **Priority:** P0 · **Size:** S
- **Problem:** `(h - 280).clamp(400.0, h * 0.78)` throws `ArgumentError` when `h * 0.78 < 400` (any viewport under ~513px: landscape phone, snapped window, devtools open). With >50 rows this runs in `build()`, so the whole transactions region renders the red error widget.
- **Files:** `frontend/lib/widgets/transactions_tab.dart` (~1543-1545)
- **Acceptance criteria:**
  - Bounds are made order-safe (e.g. `final maxH = h * 0.78; (h - 280).clamp(math.min(280.0, maxH), math.max(280.0, maxH))`) or the 400px floor is dropped on short viewports.
  - Widget test pumping the tab with 60 rows at 800×480 renders without error.

### Task 3 — Stop single-row edits triggering a Yahoo re-price + full 18-endpoint reload
- **Priority:** P0 · **Size:** M
- **Problem:** `onUpdate`/`onDelete`/`onBulkDelete`/split/unsplit all await `_refreshData()`, which first awaits `refreshAllStockPrices()` (N sequential external quote fetches when stale) and then `_loadAllData(forceRefresh: true)` (~18 uncached GETs). Renaming one transaction costs seconds of network. This is the single biggest reason transaction editing *feels* sluggish, and it also resets the loaded page back to 50 rows (see Task 13).
- **Files:** `frontend/lib/screens/dashboard_screen.dart` (1544-1549, 2935-2978), backend reference: `backend/src/api/accounts.rs`, `backend/src/services/holdings.rs`
- **Acceptance criteria:**
  - `refreshAllStockPrices()` runs only on explicit pull-to-refresh / "sync everything", never after a transaction mutation.
  - After a transaction mutation, only affected reads refetch (transactions + overview/trends), or the row is patched in the local `_transactions` list with reconciliation on next cached load.
  - Categorizing a row completes (UI settled) with at most 2-3 requests; verified by observing the network panel or an instrumented test.

### Task 4 — Rebuild the detail-panel category editor (the most common edit in the app)
- **Priority:** P0 · **Size:** M
- **Problem:** Two compounding issues, reported by two critics. (a) The Category field is bare free text prefilled with the **raw** value (`tx['user_category'] ?? tx['category']` → "FOOD_AND_DRINK"), with no autocomplete — despite three existing category type-aheads elsewhere — so categories fragment ("Restaurants" vs "restaurant"). (b) The footer Save **unconditionally** writes `userCategory: catController.text.trim()`: opening a transaction and pressing Save converts the auto-category into a permanent user override of the raw enum string, which then renders verbatim in the list. That's silent data corruption from a no-op interaction.
- **Files:** `frontend/lib/widgets/transactions_tab.dart` (2025-2035, 2364-2374, 2546-2556; `_distinctCategories()` at 959), reference implementations at 812-833 and `add_transaction_dialog.dart:299-353`
- **Acceptance criteria:**
  - Category edit uses the shared Autocomplete fed by `_distinctCategories()`, prefilled with the **prettified** label; ideally surfaced as a tappable chip near the header chips (~2296-2347) per the Copilot/Monarch pattern, saving on selection with a confirmation snackbar.
  - `userCategory`/`userNotes` are sent **only when changed** from the loaded values; open-then-Save with no edits is a no-op (assert via test).
  - All category-entry surfaces (detail panel, bulk, add, split) share one picker component or at minimum one suggestion source.

---

## Milestone 2: Transactions look & feel revamp

### Task 5 — Replace keyword-matched Material category colors with a brand-palette registry
- **Priority:** P1 · **Size:** M
- **Problem:** `_getCategoryIcon`/`_getCategoryColor` substring-match **English** keywords and return raw `Colors.orange/blue/purple/…` with a `Icons.receipt` + `Colors.grey` fallback. Any user-typed or Spanish category (the Banamex/BBVA/Santander/Nu import pipeline — this product's core audience) lands on the grey fallback, so the 44px icon column conveys nothing; the raw Material constants also clash with the jade/heritage palette and aren't brightness-aware. Merged from two critics (L&F #1 + Usability #5, which also flags `Colors.grey` captions failing AA, two different reds for delete, and `Colors.orange` vs `context.warning` for pending).
- **Files:** `frontend/lib/widgets/transactions_tab.dart` (2824-2922, plus 567/581/632/2345/2515-2538), `frontend/lib/utils/theme_colors.dart`, `frontend/lib/theme/palette.dart`, `frontend/lib/screens/account_transactions_screen.dart:863`
- **Acceptance criteria:**
  - One central category→(icon, color) registry keyed on `prettyCategory` output, with known Spanish import categories mapped explicitly and a **deterministic hash-to-brand-palette fallback** so unknown categories get a stable themed color, never grey.
  - Detail-modal hero icon inherits the same registry.
  - Stray Material constants in the transactions surfaces routed through the semantic extension: `context.negative` for delete/error (one red, not two), `context.warning` for pending, `context.textMuted/textSubtle` for captions.
  - Light and dark mode both pass AA for the caption/empty-state text.

### Task 6 — Badge transfers in the list and neutralize their amounts
- **Priority:** P1 · **Size:** S/M
- **Problem:** FX-transfer linkage is only visible inside the detail panel; in the list the receiving leg renders `+` in positive green (reads as income) and the sending leg as spending. Miscounting transfers as income/spend is a classic trust-killer; the SPLIT pill pattern already exists to copy.
- **Files:** `frontend/lib/widgets/transactions_tab.dart` (SPLIT pill 1899-1918, amount styling 1946-1951, fxTransfers prop :79)
- **Acceptance criteria:**
  - Rows whose tx id appears in `widget.fxTransfers` show a TRANSFER pill (confirmed vs auto accent) and render the amount in neutral `textPrimary` with a ⇄ glyph instead of +green.
  - Linked-id lookup is an O(1) set built once per `fxTransfers` identity (mirror `_ensureDescIndex`).

### Task 7 — Improve date grouping: unambiguous labels, month landmarks with subtotals
- **Priority:** P1 · **Size:** M
- **Problem:** Headers for 2-6 days ago are weekday-only ("Monday" — which Monday?); older history is hundreds of identical "Jun 3" micro-sections with no month structure and no totals, so the list answers nothing ("what did June cost me?").
- **Files:** `frontend/lib/widgets/transactions_tab.dart` (`_dateGroupHeader` 1657-1692, `_ensureItemPlan`)
- **Acceptance criteria:**
  - Day headers render "Monday, Jun 8" (weekday + date), localized (depends on Task 12).
  - Month-boundary headers with a net inflow/outflow subtotal computed over the loaded rows.
  - Stretch (don't block the task on it): pinned current-group header synced to scroll offset using the existing item plan.

### Task 8 — Make search find notes and amounts; add an amount-range filter
- **Priority:** P1 · **Size:** S
- **Problem:** `_haystackFor` omits `user_notes` (rendered right in the row meta line — users can search text they can literally see and get zero results) and the amount ("that ~$450 charge" is unfindable). The filter dialog has no amount range.
- **Files:** `frontend/lib/widgets/transactions_tab.dart` (415-443), `frontend/lib/widgets/transaction_filters.dart`
- **Acceptance criteria:**
  - Haystack includes `user_notes` and a plain formatted amount (raw "450.00" plus the localized rendering).
  - `TxFiltersDialog` gains min/max amount fields with a matching active-filter chip; combinable with existing filters.

### Task 9 — Unify the debit/credit color language and hero typography
- **Priority:** P2 · **Size:** S
- **Problem:** One expense shows red border + pink OUTFLOW label + neutral amount; income shows teal border + teal label + green amount — four accents for one binary concept, with teal also meaning "confirmed transfer". Separately, the two hero amounts (detail panel 32px, account panel 28px) request `FontWeight.w900` that no bundled Inter weight provides, and skip `brandDisplayStyle` (so no tabular figures on the biggest money figures outside the dashboard). Merged from L&F #8 + Usability #7.
- **Files:** `frontend/lib/widgets/transactions_tab.dart` (2248-2276), `frontend/lib/screens/account_transactions_screen.dart` (575-577), `frontend/lib/theme/typography.dart` (34-52)
- **Acceptance criteria:**
  - One inflow/outflow token pair applied consistently to hero border, caption, and amount (inflow = positive, outflow = neutral; `negative` reserved for destructive/error; teal means transfer/linked only).
  - Both hero figures use `brandDisplayStyle(fontSize: …)` (caps at bundled w700, tabular/lining figures). No `w900` requests remain. **Do not** add font weights via google_fonts — bundled fonts only.

### Task 10 — Empty state for zero filter matches + honest CSV export
- **Priority:** P2 · **Size:** S
- **Problem:** (a) When filters/search match nothing, the user gets dead space and a tiny "Showing 0 of N" — no message, no obvious way out. (b) The export button sits next to the filters but always exports everything, with no warning.
- **Files:** `frontend/lib/widgets/transactions_tab.dart` (561-596, 1474-1479, 1527-1537), `frontend/lib/services/api_service.dart` (:1691)
- **Acceptance criteria:**
  - `filtered.isEmpty && transactions.isNotEmpty` renders a centered "No transactions match" state with a one-click "Clear filters & search" action.
  - Export either passes active filter state as query params to the endpoint, or (minimum) the tooltip/confirm copy says "Exports ALL transactions" when filters are active.

---

## Milestone 3: Account panel parity

### Task 11 — Make the account panel's transaction list scrollable and bounded-host aware
- **Priority:** P0 · **Size:** M
- **Problem:** The panel hosts `TransactionsTab` in `Expanded` inside a non-scrolling `Column` (verified at account_transactions_screen.dart:940), but the tab's root is `Card > Padding > Column` with no scroll view: ≤50 transactions build eagerly into ~57px rows, overflowing the bounded slot — **rows below the fold are clipped and unreachable**. For >50 rows the inner list is sized from the *window* height, not the panel's remaining space, so it still overflows (worst in the 0.92-height bottom sheet).
- **Files:** `frontend/lib/screens/account_transactions_screen.dart` (~915-970, 1008), `frontend/lib/widgets/transactions_tab.dart` (617-678, 1527-1545)
- **Acceptance criteria:**
  - Every transaction in an account is reachable by scrolling, in both the side-panel and bottom-sheet variants, at 800×600 and a phone-sized viewport.
  - `TransactionsTab` gains a bounded-host mode that sizes the inner list from the `LayoutBuilder` constraints already available in `_buildRowsRegion` (not `MediaQuery` window height) — or the panel wraps the slot in its own scrollable with shrink-wrapped rows.
  - No RenderFlex overflow stripes in debug at any tested size.

### Task 12 — Give the account panel full transaction actions and in-place refresh
- **Priority:** P1 · **Size:** L
- **Problem:** Merged from two critics. (a) `apiService` and the split/bulk callbacks are omitted, so "+ Add transaction", CSV export, split, and bulk delete vanish in exactly the context users want them — while the selection-mode toggle still shows, leading to a bulk bar with a permanently disabled Delete. (b) Every single edit calls `_fetchTransactions()`, which flips `_isLoading` and swaps the whole body for a spinner — discarding scroll position, search, and caches — then re-downloads up to 1,000 rows. Categorizing five rows costs five 1,000-row downloads and five remounts.
- **Files:** `frontend/lib/screens/account_transactions_screen.dart` (261-281, 852-856, 940-969), `frontend/lib/widgets/transactions_tab.dart` (745, 1415, 1428-1439), `frontend/lib/services/api_service.dart` (948-957), backend `backend/src/api/accounts.rs` (550-560)
- **Acceptance criteria:**
  - Add-transaction (account preselected), split, bulk delete/update wired through the same `ApiService` calls the dashboard uses; or, where an action is intentionally absent, its entry point (selection toggle) is hidden.
  - Post-edit refresh updates in place: no full-body spinner, scroll position and search preserved.
  - `getAccountTransactions` gains limit/offset and the panel uses TransactionsTab's existing `onLoadMore`/`hasMore` hooks.

### Task 13 — Fix the filter cascade's cost and the page-1 reset; widen filter options to full history
- **Priority:** P1 · **Size:** M
- **Problem:** Merged from two critics. The "filter spans whole history" fix cascade-loads 50 rows per serial round-trip (backend accepts 500), every reload truncates `_transactions` back to page 1 (so the cascade re-runs after each edit under an active filter), and the filter dialog's category chips are computed from loaded rows only — a category living in unloaded history can never be selected (chicken-and-egg the c03b0a9 fix didn't close).
- **Files:** `frontend/lib/widgets/transactions_tab.dart` (394-409, 604-608, 959-973), `frontend/lib/screens/dashboard_screen.dart` (190, 1551-1562, 1728), `frontend/lib/widgets/transaction_filters.dart` (224-237), backend `backend/src/api/dashboard.rs` (:669)
- **Acceptance criteria:**
  - Cascade path requests at the backend's 500 cap (3,000 rows → ≤7 round-trips, verified), or a server-side filtered endpoint replaces it.
  - Silent reloads refetch `limit: _transactions.length` or merge page 1 into the existing list — editing a row under an active filter does not re-run the cascade.
  - Filter dialog options and `_distinctCategories()` reflect the full history (trigger the load when the dialog opens, or fetch a distinct-categories endpoint).

### Task 14 — Show a running balance in the per-account view
- **Priority:** P2 · **Size:** M
- **Problem:** "What was my balance after this transaction" is the canonical statement question; `balance_after` is already persisted for imported statements but never included in the transactions payload or rendered. Bonus redundancy: every row's meta line prints the account name inside a single-account panel.
- **Files:** backend `backend/src/api/dashboard.rs` (SELECT at 677-678), `frontend/lib/widgets/transactions_tab.dart` (meta line 2004-2017), `frontend/lib/screens/account_transactions_screen.dart`
- **Acceptance criteria:**
  - `balance_after` included in the account-transactions payload; rendered as a muted secondary line under the amount, computed forward/backward from `current_balance` for rows lacking a persisted value.
  - A `singleAccountContext` flag swaps `account_name` out of the meta line for the running balance.

---

## Milestone 4: Platform polish

### Task 15 — Localize dates: set `Intl.defaultLocale` + `initializeDateFormatting`
- **Priority:** P1 · **Size:** S
- **Problem:** The app ships a complete 1075-key Spanish translation, but no code sets `Intl.defaultLocale` or calls `initializeDateFormatting` (verified: zero grep hits), so all ~36 `DateFormat` sites render en_US — Spanish users see "Tuesday" and "Mar 4" between fully translated strings, most visibly in the transaction date headers they scan daily. Also prerequisite for Task 7's localized headers.
- **Files:** `frontend/lib/main.dart`, `frontend/lib/utils/app_locale.dart`
- **Acceptance criteria:**
  - On startup and on locale change, `Intl.defaultLocale = locale.toString()` and `initializeDateFormatting(...)` run before rebuild.
  - With es active: date group headers, detail-modal date chip, and custom-range filter chip render in Spanish (widget test or screenshot check).
  - Include skeleton visibility fix in this polish pass: `SkeletonBox` pulses an onSurface-derived tint (`context.tint(t)`) instead of `Colors.white` so loading is visible on the light parchment theme (`frontend/lib/widgets/skeleton.dart:57-62`).

*(Optional quick win if capacity allows: a search IconButton in the AppBar calling `_openPalette` with a ⌘K tooltip — the palette is the app's best navigation feature and is currently keyboard-shortcut-only, unreachable on touch. `dashboard_screen.dart:649, 1903-1917`. P2, S.)*

---

## Rejected, merged, and deferred findings

**Merged duplicates** (the critics overlapped heavily; counted once above): split-dialog focus bug (Ease-of-use #1 = L&F #2 → Task 1); category editing (Ease-of-use #2 = L&F #3 → Task 4); hardcoded Material colors (Usability #5 ⊂ L&F #1 → Task 5); account-panel issues (Ease-of-use #4 + Perf #4 → Task 12); filter history gaps (Ease-of-use #5 + Perf #2 → Task 13); w900/typography (Usability #7 → folded into Task 9); empty state + CSV export (two low findings → Task 10); skeleton fix folded into Task 15.

**Rejected — Balance sparkline memoization (Perf, low).** Real but micro: ~1,000-row sort with date parses is single-digit milliseconds, triggered only by occasional panel setStates. Not worth a tracked task; fix opportunistically inside Task 11/12 if touching that code.

**Deferred — Dashboard `build()` restructure / lazy IndexedStack (Perf #5).** The diagnosis is accurate, but it's a large refactor with speculative payoff: most rebuild pressure comes from `_refreshData` storms that Task 3 eliminates, and the leaf caches absorb much of the rest. Re-profile after Milestone 1; only then decide.

**Deferred — First-paint request tiering (Perf #3).** Legitimate startup-latency work, but outside the transactions theme the owner prioritized, and it's a meaty architectural change. Queue after Milestones 1-2.

**Deferred — Batch delete endpoint (Perf, low).** Valid (bulk update already got this treatment), but bulk delete is a rare cleanup operation. Cheap backend mirror of `batch_update_transactions` when convenient.

**Deferred — Inline `es ?` l10n ternaries (Usability, low).** Real debt (~27 occurrences across 7 files, verified), purely mechanical, zero user-visible impact today. Good first-issue material; consider the suggested `check.sh` grep guard when someone picks it up.

**Brand-language check:** no critic proposed reintroducing google_fonts or fighting the jade/heritage palette — on the contrary, Tasks 5, 9, and 15 *enforce* it (BrandPalette tokens, `brandDisplayStyle`, bundled-weight-only typography). No findings rejected on those grounds.

---

## Addendum (added post-review): Task 16 — Stop faking cost basis when Plaid omits it (Vanguard 401k shows +0.00% growth forever)
- **Priority:** P1 · **Size:** M
- **Problem:** Plaid does not report `cost_basis` for employer-plan holdings (the Vanguard 401k). `sync.rs:392` substitutes the holding's *current value* (`h["cost_basis"].as_f64().unwrap_or(val)`), and every nightly sync overwrites it again (`cost_basis = EXCLUDED.cost_basis`), so the 401k is permanently pinned at +$0.00 (+0.00%) rendered in gain-green — while the Roth IRA (real basis from Plaid) shows true growth. Verified in the live DB: all four 401k funds have `cost_basis` exactly equal to `value`; GOOG at Morgan Stanley has the same signature ($798,268.42 = $798,268.42), so its gain is hidden too. Separately, statement-imported holdings (HealthEquity HSA, NetBenefits ORCL) have NULL basis because `/holdings/import` (`accounts.rs:1505`) never writes one and the parser's `ImportHolding` struct has no field for it.
- **Files:** `backend/src/services/sync.rs` (392, 414), `backend/src/api/dashboard.rs` (497, 534-544), `backend/src/api/accounts.rs` (1505-1520), `backend/src/services/parser/mod.rs` (726), `frontend/lib/widgets/portfolio_card.dart` (947-948, 1412-1418)
- **Acceptance criteria:**
  - Sync stores `NULL` (not `val`) when Plaid omits `cost_basis`; existing poisoned rows self-heal on the next sync via the upsert.
  - API returns `cost_basis`/`gain_loss`/`gain_loss_pct` as null when basis is unknown (distinct from a true 0% return).
  - Frontend renders "—" with a "cost basis unavailable from this institution" tooltip instead of +0.00% in green; unknown-basis holdings are excluded from biggest gainer/loser and from `total_cost_basis`/`total_gain_loss_pct` denominators.
  - Stretch: manual cost-basis entry per holding, and an optional `cost_basis` field on `ImportHolding` + `/holdings/import` for statement parsers that can supply it.
