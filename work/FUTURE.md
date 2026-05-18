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
end-to-end with a pencil icon in the detail modal. Remaining
follow-up: integration test exercising a canned Plaid JSON fixture
into the enriched DB columns. Original plan preserved below for
reference.

### The problem

Many transaction rows in the dashboard render with vague labels: `Robinhood`, `DISCOVER`, `Miscellaneous Debit`, `Miscellaneous Credit`. Some of this is bank-quality (the user's bank reported the transaction to Plaid with that exact `name`, so there's no enrichment to do), but the sync code is also leaving Plaid enrichment data on the table.

Check the live data first:

```bash
docker exec patrimonio-postgres-1 psql -U patrimonio -d patrimonio -c "
  SELECT description, merchant_name, category_detailed, COUNT(*) AS n
  FROM transactions
  WHERE merchant_name IS NULL
     OR description ILIKE '%miscellaneous%'
  GROUP BY description, merchant_name, category_detailed
  ORDER BY n DESC LIMIT 30;
"
```

### What Plaid actually offers that we're not using

`backend/src/services/sync.rs:368-433` (`insert_or_update_transaction`) currently reads:
- `tx["name"]` → stored as `description`
- `tx["merchant_name"]` → stored as `merchant_name` (often null)
- `tx["personal_finance_category"]["primary"]` and `.detailed`

What's also in the Plaid payload but we ignore:
- **`original_description`** — the raw bank line, useful as a fallback when `name` is generic. We don't store it at all.
- **`counterparties[]`** — array of enriched counterparty entities, each with `name`, `type`, `logo_url`, `website`, `confidence_level`. The "right" merchant lives here for many transactions where `merchant_name` is null. Docs: https://plaid.com/docs/api/products/transactions/#transactions-sync-response-added-counterparties
- **`payment_meta.{ppd_id, reference_number, payer, payee}`** — useful for ACH/wire transactions where the description otherwise reads "ACH DEBIT".

### Plan

1. **Migration:** add `original_description TEXT`, `counterparty_name TEXT`, `counterparty_logo_url TEXT` to `transactions`. New file: `backend/migrations/2026MMDD01_plaid_enrichment.sql`. Backfill not needed — next sync repopulates.
2. **Backend sync.rs change** (single function, ~30 lines): pull `original_description`, pick the highest-confidence counterparty from `counterparties[]` (filter `confidence_level == "VERY_HIGH"` or `"HIGH"`, take first), and write all three new columns alongside the existing inserts. Keep `description` writing `tx["name"]` for backwards compatibility — the UI will pick the best of the three.
3. **Frontend display helper:** new `frontend/lib/utils/transaction_display.dart` with `String displayLabel(tx)` that picks `counterparty_name` ?? `merchant_name` ?? (if `description.length < 15 && original_description != null`) `original_description` ?? `description`. Call it from `_buildTransactionRow` in `frontend/lib/widgets/transactions_tab.dart` and from `_showTransactionDetails`. Show the counterparty logo when available.
4. **UI affordance for the truly-generic cases:** in the transaction detail modal, surface a "Rename" action that writes to a new `user_description` column (parallel to existing `user_category` / `user_notes` — same pattern). For "Miscellaneous Debit" rows there's nothing Plaid can do; let the user override locally.

### Acceptance

- A fresh Plaid sync of a typical dev account stores `counterparty_name` for at least 60% of rows that previously had `merchant_name IS NULL`.
- The dashboard transaction list visibly improves: rows that used to say "Robinhood" / "Miscellaneous Debit" either show a better label or carry a user-applied override.
- Existing tests still pass; add at least one integration test that reads a canned Plaid JSON fixture and asserts the enriched fields land in the DB.

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

**Original plan preserved below.**

### Why

A US/Mexico investor who bought VTI at $200 (USD 1 ↔ MXN 17.5) and looks at it today at $220 (USD 1 ↔ MXN 19.0) has different P&L expressed in USD vs MXN. The current `holdings` table stores only a flat `cost_basis` in a single currency — that lets the user see USD P&L but understates or overstates the MXN view by 10–20%.

### Plan

1. New table `holding_lots(id, holding_id, acquired_at, qty, cost_per_unit, currency, fx_rate_at_acquisition_to_usd)`. Migration in `backend/migrations/`.
2. Backend ingestion: Plaid investments returns transactions of type `buy` / `sell` — append a new lot on `buy`, FIFO-deplete on `sell`. New service `services/lots.rs`. Extend `services/sync.rs` to call it from the investments path.
3. Currency-aware P&L computation in `services/sync.rs` or a new view: for each lot, compute (current_value * current_fx) − (cost_basis * fx_at_acquisition) in both USD and MXN, sum across lots per holding.
4. Frontend: extend `portfolio_card.dart` to add a "Cost basis (USD)" and "Cost basis (MXN)" pair of columns next to the existing Value column. Show unrealized gain in both currencies.

### Acceptance

- Manual round-trip: synthesize a holding with two lots at different historical FX rates, verify the displayed P&L in MXN ≠ converted-from-USD P&L (because the cost basis was held at a different rate).
- Existing PortfolioCard tests still pass; add one new test exercising the lot aggregation.

### Note

`work/NEXT.md` defers this until "real transaction and holding data is reliable" (Phase 13). That gate is now met — Phase 13's data-quality work is in `main`.

---

## 3. "What changed since last login" diff banner

**Status:** Open. **Effort:** half day total. **Impact:** medium — high return-visit value.

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

## 5. Multi-user support

**Status:** Deliberately deferred — opens the door to advisor / partner access. ~1–2 days, mostly schema. Owner of the upgrade has to be willing to touch every table.

### Why this is a bigger lift than it looks

Every financial data table currently assumes one user owns everything: `institutions`, `accounts`, `transactions`, `holdings`, `balance_snapshots`, `exchange_rates` (FX is global so this one stays). The `users` / `user_sessions` / `recovery_codes` / `auth_audit` tables are already user-scoped — they were designed for it.

### Plan

1. **Migration**: add `owner_user_id UUID REFERENCES users(id)` to every data table. Backfill to the existing bootstrap user. Add NOT NULL after backfill.
2. **Every query in `backend/src/api/` and `backend/src/services/`** gains a `WHERE owner_user_id = $N` clause. There are ~60 such queries; this is the bulk of the work.
3. **Bootstrap stops being one-shot**: change `/api/auth/bootstrap` to allow N users only if invited. Add `invite_tokens` table + `/api/auth/invite` endpoint that emits a one-time signup token. README updates to reflect.
4. **Roles**: at minimum `owner` vs `read-only`. Plaid linking + account management requires `owner`; an advisor `read-only` user can see net worth and projections but can't edit.

### Acceptance

- A second user can bootstrap with an invite token, see ONLY accounts they own, cannot read another user's transactions.
- Integration test: create two users, populate distinct accounts, assert `/api/dashboard/overview` returns disjoint data for each.

---

## 6. Production Plaid readiness

**Status:** From `work/NEXT.md` (2026-05-12); still relevant.

### What's actually needed beyond what's done

- Real Plaid `development` or `production` credentials in `.env` (currently `sandbox` works fine).
- Webhook receiver for `DEFAULT_UPDATE` / `INITIAL_UPDATE` / `TRANSACTIONS_REMOVED` / `ITEM_LOGIN_REQUIRED` — the app polls today, which is fine for sandbox but burns Plaid quota in prod.
- Reconnect UX when `ITEM_LOGIN_REQUIRED` fires: the existing `getReconnectToken` API call works, but Management tab doesn't surface it prominently enough — currently buried.
- "Sandbox vs prod" indicator chip in the AppBar so the user knows which environment they're in.

### Acceptance

A real bank account links end-to-end against `production` Plaid, syncs transactions on schedule via webhook (not poll), and survives a forced `ITEM_LOGIN_REQUIRED` test (Plaid sandbox provides this) by surfacing a reconnect CTA.

---

## 7. Backups + deployment runbook

**Status:** From `work/NEXT.md`; still the biggest operational risk. The app is holding real bank credentials in encrypted form, but only on the local Docker volume.

### Minimum viable

- A `scripts/backup.sh` that runs `pg_dump | gpg --encrypt` to a target directory, plus `scripts/restore.sh` that goes the other way. Cron daily.
- Runbook in `docs/operations.md`: how to restore, how to verify the encryption key is recoverable, how to rotate `ENCRYPTION_KEY` (involves re-encrypting every `api_key_enc` / `api_secret_enc` / `plaid_access_token_enc` / `totp_secret_enc` column).
- A documented restore drill: build a fresh stack from the backup, verify Plaid tokens still decrypt, verify a login works.

### Acceptance

`./scripts/restore.sh <encrypted-dump>` produces a working dev stack from a backup taken a day prior. Plaid sync still works against the restored data.

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

## Biometric / passkey sign-in (FIDO2 / WebAuthn)

**Status:** Open. User-requested in the May 17 2026 palette session: "is it also possible to allow biometrics login from the phone?" Yes — and the right primitive is passkeys, not platform-specific biometrics, because Patrimonio is a Flutter *web* app served over a real origin. A passkey registered on the user's phone with Face ID / Touch ID / Android biometric can sign them into the web app from that phone (and, if the user opts into cloud sync via iCloud Keychain / Google Password Manager / Microsoft, from their desktop browser too) without ever installing a native app.

**Tracking:** This file.

### Why passkeys, not platform biometrics

A few options exist for "biometric login":

| Option | Works on | Reality for Patrimonio |
|---|---|---|
| `local_auth` (Flutter plugin) | iOS, Android, macOS, Windows only | We're served as a web app via nginx — `local_auth` doesn't run in the browser. Would force a separate native build path. |
| Native iOS / Android wrappers | Requires App Store / Play Store distribution | Out of scope for a single-user self-hosted app. |
| **WebAuthn / passkeys (FIDO2)** | Every modern browser on every modern OS — iOS 16+, Android, Windows Hello, macOS, Linux Chromium | One implementation, works for the user's phone *and* their desktop. The biometric prompt is shown by the platform (Face ID / Touch ID / Windows Hello) and the key never leaves the device. |

Passkeys are the standard answer here. Apple, Google, and Microsoft all sync them between the user's devices via their respective password managers, so a passkey registered on the phone "just works" on the desktop afterwards.

### Scope of the work

This is a real feature, not a small change. Three-side implementation:

**Backend (Rust / axum, ~1 day):**

- Add the `webauthn-rs` crate (mature Rust FIDO2 implementation by the WebAuthn working group).
- Schema: new `passkey_credentials` table, one row per registered device per user.
  ```sql
  CREATE TABLE passkey_credentials (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id UUID NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    credential_id BYTEA NOT NULL UNIQUE,        -- WebAuthn cred id (raw)
    public_key BYTEA NOT NULL,                  -- COSE-encoded public key
    sign_count BIGINT NOT NULL DEFAULT 0,       -- replay-attack counter
    transports TEXT[],                          -- "internal", "hybrid", "usb"…
    nickname TEXT,                              -- "iPhone 15", "Yubikey 5C"
    created_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    last_used_at TIMESTAMPTZ
  );
  ```
- Four endpoints, all CSRF-protected and behind the existing session middleware where appropriate:
  - `POST /api/auth/passkeys/register/start` — authenticated; returns a `PublicKeyCredentialCreationOptions` challenge.
  - `POST /api/auth/passkeys/register/finish` — authenticated; verifies the attestation, stores the new credential.
  - `POST /api/auth/passkeys/login/start` — unauthenticated; takes a username, returns the `PublicKeyCredentialRequestOptions` challenge (or a discoverable-credential flow with no username).
  - `POST /api/auth/passkeys/login/finish` — unauthenticated; verifies the assertion, issues the same session cookie the password login does today.
- A short-lived per-challenge state store (5 min TTL) in Redis to keep challenges out of cookies.

**Frontend (Flutter web, ~0.5 day):**

- The `webauthn` Dart package is thin or non-existent for web targets — most teams call `navigator.credentials.create()` / `.get()` directly via `package:web` (which is already in `pubspec.yaml`). The dance is:
  1. Fetch `/register/start`, base64url-decode the `challenge` and `user.id` fields into Uint8Array.
  2. Call `navigator.credentials.create({ publicKey: options })` — this is what triggers the platform's Face ID / Touch ID / Windows Hello prompt.
  3. Base64url-encode the response and POST it to `/register/finish`.
  4. Login uses `navigator.credentials.get()` — same encoding dance.
- A "Register this device" button in `security_screen.dart` (already exists) and a "Sign in with passkey" button on `auth_gate.dart`.
- Show a list of registered passkeys in security settings with the device nickname + last-used timestamp + a "Remove" button.

**Schema-only migration risk:** None — additive table, doesn't touch the password auth path. Passkeys are *in addition to* the password sign-in, not a replacement.

### Open design questions to settle when picked up

1. **Username-first vs discoverable credentials.** Discoverable (resident) credentials let the user sign in without typing a username — the platform UI just lists the available passkeys for `auth.patrimonio.app`. This is the nicer UX but uses slightly more space on the authenticator. Default to discoverable; it's what every modern site uses.
2. **Origin / RP ID.** Production `rp_id` must match the actual host. For local dev (`127.0.0.1:3000`) WebAuthn requires either `localhost` or HTTPS — needs a small dev-mode `rp_id = "localhost"` toggle. Worth verifying in a throwaway test before committing.
3. **Account recovery.** If a user loses all their passkeys (lost phone, no cloud sync), they fall back to their existing password + 2FA (Patrimonio already has TOTP wired up — see `c0f4909`). No new recovery flow needed initially.
4. **Cross-device flow.** The "use your phone to sign in on a desktop browser" flow is QR-code-mediated and handled entirely by the browser/OS — no extra backend work, just verify the `transports: ["hybrid"]` advertisement is preserved.

### Why this is worth doing

- The user explicitly asked for it.
- Removes the only remaining password-based step in the daily flow once registered. Password + TOTP becomes a fallback only.
- Modern phones make biometric unlock dramatically faster than typing a 12+ char password on a touch keyboard.
- Patrimonio holds financial data — a phishing-resistant credential (which is what passkeys are; the private key never leaves the device) is meaningfully more secure than a password.

### Out of scope for this work item

- Any native iOS/Android build path. Stay web-only.
- Replacing the password login. Passkeys augment it; they don't replace it.
- A "magic link" email login, even though it might come up as a parallel suggestion — it's a separate flow with different threat model and we're not going to chase both.

### Rollback

Each side reverts cleanly: drop the `passkey_credentials` table (migration is idempotent on the DROP side), revert the Rust endpoint module, remove the frontend buttons + JS interop. No data migration needed because passkeys are additive — password sign-in keeps working untouched.

---

## Security + performance audit — deferred follow-ups (May 17 2026)

> Items raised by the May 17 audit (commit context: `34c47a7`'s direct successor) that did NOT land in the same PR. Each one is scoped so the next agent can pick it up cold.

### Plaid webhook JWT verification

**Tracking:** This section. **Audit ID:** H3 (partial).
**Status:** Webhook endpoint was moved to the public router and refuses every request that lacks a `Plaid-Verification` header. Signature *validation* is still TODO — see `backend/src/api/institutions.rs:plaid_webhook`. Until landed the webhook is unreachable in practice (which is the safe default).

**Plan:**
1. Fetch and cache Plaid's signing key from `POST /webhook_verification_key/get` (per-key-id, refresh on rotation).
2. ES256-verify the JWT in `Plaid-Verification`, where the JWT body is the SHA-256 of the raw HTTP body. `jsonwebtoken` crate handles this.
3. Reject if `iat` is more than 5 minutes old (replay window).
4. Remove the early-return guard in `plaid_webhook` and let the legacy logic run.

### Multi-user data model (IDOR latency)

**Tracking:** This section. **Audit ID:** M7.
**Status:** Today the schema is single-user — `accounts`, `institutions`, `transactions`, `holdings`, `balance_snapshots` have no `user_id` column. Every "by id" handler in `accounts.rs`, `institutions.rs`, `imports.rs`, `dashboard.rs` therefore lacks an ownership predicate. **Do NOT create a second `users` row until the columns + predicates land**, or it becomes cross-tenant data exposure with no further code change.

**Plan:**
1. Migration: add `user_id UUID REFERENCES users(id) ON DELETE CASCADE` to every per-user table, NULLable at first.
2. Backfill: assign all existing rows to the sole `users` row.
3. Migration: `ALTER COLUMN user_id SET NOT NULL`.
4. Code: in every handler that takes `Path<Uuid>`, fetch with `WHERE id = $1 AND user_id = $auth`. The audit lists every site to update.
5. Drop the multi-user banner from `OVERVIEW.md` once verified.

### CSRF defence-in-depth

**Tracking:** This section. **Audit ID:** H4.
**Status:** Today protected by `SameSite=Lax` + no GET routes with side effects + `withCredentials` CORS allow-listing. A regression in any of those three would expose us.

**Plan:** Require a `X-Requested-With: fetch` header on every authed mutating route (POST/PUT/PATCH/DELETE). The frontend already uses fetch-equivalents; just add the header in `api_service.dart` and reject server-side when missing. Cheap, two-line per side.

### Rate-limit hardening

**Tracking:** This section. **Audit ID:** M2.
**Status:** Per-username threshold is 5/min, per-IP 15/min; without `X-Forwarded-For` (no trusted proxy in dev) the IP path is skipped. An attacker with one valid username can still spray 5 passwords/min indefinitely.

**Plan:** Add a global anonymous-failure counter + an unconditional `tokio::time::sleep(rand 50–150 ms)` on every failed verify. Optional: exponential backoff per-username (5, 10, 30, 60, 120 s).

### Trusted-proxy aware `client_ip`

**Tracking:** This section. **Audit ID:** L4.
**Status:** `client_ip` honours `X-Forwarded-For` / `X-Real-IP` unconditionally. With no upstream proxy this lets an attacker spoof their IP and evade per-IP rate-limit math.

**Plan:** Take `ip` from the TCP peer by default; only honour the headers when the peer is in a `TRUSTED_PROXY_CIDRS` env-configured allow-list (likely just `127.0.0.1` + the docker bridge in our case).

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

### Connection-pool size

**Tracking:** This section. **Audit ID:** P7.
**Status:** `DATABASE_MAX_CONNECTIONS` defaults to 5 in `.env.example`. The webapp + the daily-snapshot cron + the manual-sync trigger can each consume a connection; one burst (e.g. an interactive sync + dashboard load) and the pool blocks.

**Plan:** Default to 20 for the API container. The cron's single connection is negligible. Already bumped in the audit-driven commit.

### WebAuthn `localhost` rp_id rewrite

**Tracking:** This section. **Audit ID:** M8.
**Status:** The local-dev rewrite collapses `127.0.0.1` to `localhost` for the WebAuthn rp_id. Passkeys registered against `localhost` won't work if the user later types `127.0.0.1` into the address bar. The audit flagged this as a "fail loud, don't silently rewrite" preference.

**Defer rationale:** Until we hit a real ambiguity (user complaining "my passkey doesn't work"), the rewrite is the lower-friction default — it matches the standard browser behaviour for the localhost exception. Revisit if anyone reports the gotcha.

### Encrypt webauthn-rs flow state at rest in Redis

**Tracking:** This section. **Audit ID:** Dependency observation.
**Status:** The `danger-allow-state-serialisation` feature is enabled to round-trip the per-flow `PasskeyRegistration` / `PasskeyAuthentication` state through Redis. A Redis dump (e.g. from the bind-to-0.0.0.0 misconfiguration we just plugged, or a snapshot leak) would let an attacker replay an in-flight registration.

**Plan:** AEAD-encrypt the state with `ENCRYPTION_KEY` before `SETEX`. The challenge is short-TTL (5 min) so the blast radius is small; this is hardening, not urgent.

