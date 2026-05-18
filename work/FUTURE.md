# Future work backlog

> **Purpose:** Plans that aren't urgent enough for [NEXT.md](NEXT.md) and aren't tied to a numbered phase, but are worth keeping in writing so they don't drop out of memory.

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

**Status:** Open. The May 2026 light-theme sweep got the wiring right (every widget reads through `ThemeColorsExt`) but the actual colors still have visible problems in both modes. Worth a dedicated session.

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
* Optional: a "lot breakdown" expansion per holding row showing
  per-lot acquisition date + qty + native cost + historical FX.
  Useful for power users debugging "why does my MXN P&L differ
  from a naive conversion?".
* Optional: persist realized gains on sell to a parallel
  `lot_disposals` table for full audit trail. The current sync
  just FIFO-depletes; the realized P&L is computable but
  transient.

---

## 2b. Cross-currency cash-transfer linking (Wise / Bank → Nu / etc.)  ✅ shipped

**Status:** Done. Migration `2026051803_cash_fx_transfers.sql` plus
`services/fx_transfer_link.rs` + 4 dashboard endpoints
(`GET/POST /api/dashboard/fx-transfers`, `PATCH/DELETE
/api/dashboard/fx-transfers/{id}`). Auto-detection runs after every
sync — see `services::sync` end-of-function loop.

**Remaining (low-priority follow-up):**

* "Cross-currency transfers" line on the cash-flow tab, showing
  each link's implied rate next to the day's spot rate.
* A "Manage links" view (Settings page or Management tab) so the
  user can see + unlink all detected pairs without having to find
  one of the legs in the transaction list.

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

**Status:** Open. **Effort:** half day. **Impact:** medium — affluent users always have these.

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

## 6. Production Plaid readiness  — partially shipped

**Status:** Production credentials are live. Webhook receiver +
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

### Rate-limit hardening

**Tracking:** This section. **Audit ID:** M2.
**Status:** Per-username threshold is 5/min, per-IP 15/min; without `X-Forwarded-For` (no trusted proxy in dev) the IP path is skipped. An attacker with one valid username can still spray 5 passwords/min indefinitely.

**Plan:** Add a global anonymous-failure counter + an unconditional `tokio::time::sleep(rand 50–150 ms)` on every failed verify. Optional: exponential backoff per-username (5, 10, 30, 60, 120 s).

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
**Status:** Password policy enforces length only (12+ chars, ≤256). A user who picks `correcthorse123` passes today.

**Plan:** Either ship an embedded top-100k bloom (~80 KB) loaded at startup, or call HIBP's k-anonymity range API on signup + change-password. The bloom is simpler and avoids the network round-trip on the hot path.

### Streaming CSV export

**Tracking:** This section. **Audit ID:** P4.
**Status:** `export_transactions_csv` builds the full CSV into a `String` before responding. Memory spike on large exports.

**Plan:** Use `axum::body::Body::from_stream` with a `tokio_stream::wrappers::ReceiverStream` fed by a `tokio::spawn`'d task that writes rows one at a time.

### Net-worth aggregation in SQL

**Tracking:** This section. **Audit ID:** P5.
**Status:** `net_worth_history` walks a `BTreeMap` in Rust to bucket per-institution. Fine at today's scale; will dominate at >1 year × dozens of institutions.

**Plan:** Replace with a single `jsonb_object_agg` query in the DB.

### Connection-pool size  ✅ shipped

**Audit ID:** P7. Bumped in the audit-driven commit `6e1270a`. Pool
default for the API container is now 20.

### WebAuthn `localhost` rp_id rewrite

**Tracking:** This section. **Audit ID:** M8.
**Status:** The local-dev rewrite collapses `127.0.0.1` to `localhost` for the WebAuthn rp_id. Passkeys registered against `localhost` won't work if the user later types `127.0.0.1` into the address bar. The audit flagged this as a "fail loud, don't silently rewrite" preference.

**Defer rationale:** Until we hit a real ambiguity (user complaining "my passkey doesn't work"), the rewrite is the lower-friction default — it matches the standard browser behaviour for the localhost exception. Revisit if anyone reports the gotcha.

### Encrypt webauthn-rs flow state at rest in Redis

**Tracking:** This section. **Audit ID:** Dependency observation.
**Status:** The `danger-allow-state-serialisation` feature is enabled to round-trip the per-flow `PasskeyRegistration` / `PasskeyAuthentication` state through Redis. A Redis dump (e.g. from the bind-to-0.0.0.0 misconfiguration we just plugged, or a snapshot leak) would let an attacker replay an in-flight registration.

**Plan:** AEAD-encrypt the state with `ENCRYPTION_KEY` before `SETEX`. The challenge is short-TTL (5 min) so the blast radius is small; this is hardening, not urgent.


---

# Backlog handoff — late May 2026

> Added after the 2026-05-18 walkthrough confirmed the dashboard,
> security, and tx-management batches all work end-to-end against
> real Production data. These are the ideas that came up during the
> walkthrough but didn't fit the in-scope batches. Ordered by
> impact-per-effort.

## A. Split-transaction polish  ⏱️ ~2 hours each

Split / unsplit + the validation dialog all work. Three small
follow-ups make daily use nicer:

* **"Split" chip on child rows in the transactions list.** Children
  render identically to regular rows today, so a $100 grocery split
  of a $200 ATM withdrawal looks like a standalone $100 row. A small
  badge ("Split", or a `Icons.call_split` glyph at the row's left
  edge) makes it obvious. ~10 lines in `widgets/transactions_tab.dart`
  row builder; the `parent_id` field is already on the wire.
* **Quick-split presets.** Common patterns: 50/50, 60/40, 70/30,
  "evenly across N." A dropdown in the dialog header that
  recomputes amounts to the chosen ratio.
* **Edit-split.** Today you have to Unsplit + re-split to change
  amounts. Adding an "Edit split" action on a parent (visible
  because parent_id is null + children exist) would open the dialog
  pre-populated with current children.

## B. Subscription detection improvements  ⏱️ ~half day total

The detector + "Mark as not a subscription" both work, but the model
is one-way:

* **Unhide UI.** The dismiss × is one-way. Add a "Manage hidden
  merchants" section in Settings (or Management tab) listing
  rows from `ignored_subscription_merchants` with a remove
  affordance. ~30 lines.
* **Cancelled-subscription detection.** Current heuristic filters
  out clusters whose most-recent charge is >90 days ago. A separate
  "Stopped" section would surface "Netflix charged you monthly Jan
  2024 → Dec 2024, last charge 5 months ago" — useful for
  audit / "did I actually cancel that?".
* **Per-account split.** When the user has both a credit card and a
  checking account, identical subscriptions sometimes land on both
  (paid via Apple Pay, then a fee from checking too). Show the
  account distribution per detected subscription so the user can
  see which channel.

## C. Mexican CSV / PDF parser polish  ⏱️ ~1 hour

The Plaid path now applies the generic-prefix allowlist (`MISC DEBIT`,
`ACH ...`, `POS ...`, etc.) via `transaction_display.dart`. The
Mexican parsers (`services/parser/nu_mexico.rs`, `banamex.rs`,
`cetes.rs`) still produce raw bank descriptions like
`MISC DEBIT 20260418` directly into the `description` column.

The parsers extract more useful tokens during PDF parsing (merchant
codes, payee strings); they just don't surface them in a separate
column. Either:

* Wire `payment_payee` / `original_description` columns into the
  parsers (the columns already exist from the Plaid work) so the
  display ladder kicks in for these rows too.
* OR run a post-parse cleaning step that strips the prefix +
  drops the date suffix when present.

Acceptance: opening a Mexican CSV row in the detail modal no
longer shows `MISC DEBIT 20260418` as the title.

## D. "Unhide" / general "Manage hidden things" panel  ⏱️ ~3 hours

A growing list of UI elements have dismissed state with no Unhide
path:

* Ignored subscriptions (`ignored_subscription_merchants`).
* Since-last-login banners (`Preferences.sinceLastLoginDismissed`).
* FX-transfer links unlinked by the user — currently the detector
  may re-propose them, but the user might want a way to mark "never
  re-suggest this pair".

A single Settings panel listing all the things-the-user-said-no-to
with per-row remove would be cleaner than scattering per-feature
manage screens.

## E. Production deployment runbook  ⏱️ ~half day (also see NEXT.md #3)

`docs/operations.md` covers backup/restore and key rotation but
not actual production deploy. A new `docs/deployment.md` should
cover:

* Reverse proxy (nginx / Caddy) + TLS cert (Let's Encrypt) sample
  configs.
* `TRUSTED_PROXY_CIDRS` setup with the reverse proxy's actual IP.
* `PLAID_WEBHOOK_URL` registration + the "re-link or update one
  institution to pick up the URL" detail.
* Where to put the public URL (typical: a VPS with docker-compose
  pointed at port 8080 behind nginx).
* Health-check + restart policy (systemd unit or
  `docker compose --restart unless-stopped` already in place).
* Log rotation (api logs grow unbounded; `docker compose` doesn't
  auto-rotate).

## F. Sandbox vs Production indicator chip  ⏱️ ~30 min

`/api/setup/status` already exposes `plaid_env` (`sandbox` /
`development` / `production`). The frontend should render a tiny
amber pill next to the FX badge when it's not "production" — so
the user has a visual cue when they're hitting the test bank.

Files: `frontend/lib/screens/dashboard_screen.dart` (AppBar actions
list), maybe a new small widget under `widgets/`.

## G. Real-time dashboard via websockets  ⏱️ ~1 day  🎯 elegant but deferred

Plaid webhooks now trigger background syncs, but the frontend still
finds out by polling (it just doesn't poll often). A websocket
"dashboard data invalidated" channel would let the dashboard refresh
the moment a sync completes — useful when a new transaction lands
while the user is looking at the Overview.

Significant scope: new websocket endpoint, broadcast plumbing,
frontend reconnect logic, auth scoping (a user shouldn't see
another user's invalidations). Park until polling actually feels
slow.

## H. Net-worth aggregation in SQL  (audit P5)

Already documented in the audit section above. Worth lifting here
because it'll start to dominate cold-cache loads as more
institutions accumulate. The Rust-side `BTreeMap` walk is
manageable at today's scale (~5 institutions × 30d history) but
quadratic in (institutions × days). A single `jsonb_object_agg`
on the postgres side is cheap.

## I. Inline transaction rename + bulk-edit polish  ⏱️ ~half day

The detail modal's rename works well, but for "rename a bunch of
rows quickly" the modal-per-row flow is heavy. Two affordances:

* **Inline rename**: long-press / right-click on a row opens a
  small inline text input on the row itself. Saves on submit.
* **Keyboard shortcut**: `R` when a row is focused opens the rename
  dialog directly without opening the detail modal first.

The bulk-rename "Also apply to N matching" already exists from
the detail modal, so this is purely about reducing clicks for
one-off renames.

## J. Flutter canvaskit responsiveness  ⏱️ unknown

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

## K. Test infrastructure  ⏱️ ~half day

Coverage of the new endpoints in `backend/tests/` is thin:

* `backend/tests/auth_endpoints.rs` covers auth. New endpoints
  (`fx-transfers`, `subscriptions`, `since-last-login`, `splits`,
  `subscriptions/ignore`) have only unit tests for their internal
  helpers (`fx_transfer_link::score_match` etc.). An integration
  test would catch regressions when the SQL changes underneath.
* `scripts/smoke.cjs` exercises the bootstrap → dashboard golden
  path but doesn't touch any of the new features. Worth adding a
  "split + unsplit", "dismiss subscription", and "FX-detect"
  step so the smoke test exercises the new surfaces.
