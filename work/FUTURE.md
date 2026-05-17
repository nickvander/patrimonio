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

