# UX evaluation — Sofía Reyes (Mexican-American, US+MX money, lends to family)

## Persona & summary

Sofía, 34, splits life between Austin and CDMX, thinks bilingually, and wants one
trustworthy place to see her USD + MXN net worth and track loans to family. The
app is genuinely capable and the engineering under the hood (parallel data loads,
FX-aware lending, real per-loan amortization) is well above typical hobby-fintech.
But the surface she actually touches has clarity and trust gaps that would make
her hesitate: zero Spanish anywhere despite a bilingual target user, a login
screen that never says what the product *is*, crypto/Bitso buried where she'd
never find it, and copy inconsistencies that read as "unfinished." It is also a
near-stock dark fintech dashboard — competent, not distinctive.

**Overall "would I keep using this" score: 6/10.** Powerful and fast once
configured; held back by onboarding opacity, an English-only reality, and a
flat brand.

---

## Journey-by-journey

### 1. First contact / onboarding — friction 4/5

What Sofía sees:
- Login screen: bold "Patrimonio", subtitle "Sign in to continue", Username +
  Password, "Sign in", optional "Sign in with passkey", "Forgot password?"
  (`screens/login_screen.dart:92-173`).
- If she's the very first user: "Welcome to Patrimonio / Create the owner
  account. This is a one-time setup." then username/email/password
  (`screens/bootstrap_screen.dart:77-156`). She has no idea what an "owner
  account" is.
- If invited: "You were invited. Pick a username and password…"
  (`screens/register_screen.dart:98-110`). After submit, a blocking recovery-codes
  dialog (`register_screen.dart:56-60`).

Findings:
- **No value proposition anywhere on the auth screens.** "Patrimonio" + "Sign in
  to continue" never tells a newcomer this is a US+MX net-worth tracker
  (`login_screen.dart:92-105`). Sofía landing cold cannot tell what she's signing
  into. ("Patrimonio" is itself a Spanish word — a nice latent brand cue that's
  never leveraged.)
- **"Username," not email, to log in.** Her bank and every app she uses key off
  email/phone. Username-first auth (`login_screen.dart:107-116`) is developer
  ergonomics, and the passkey button is *disabled until a username is typed*
  (`login_screen.dart:45-50,148-162`) — she'll tap it, get nothing, and be
  confused.
- **"This is a one-time setup" / "owner account"** is jargon
  (`bootstrap_screen.dart:86`). Fine for a self-hoster, opaque for Sofía.
- Recovery-codes-first flow is good for trust, but there's no "why" framing for a
  non-technical user staring at 10 codes.
- Error surfacing is decent (`login_screen.dart:131-136`) — raw exception strings
  stripped of the `Exception:` prefix, but server messages may still be terse.
- English only — see the cross-cutting issue. Sofía is bilingual; nothing greets
  her in Spanish.

### 2. Connecting a US bank (Plaid) — friction 2/5

What Sofía sees: AppBar "Connect bank", an environment banner ("Plaid Production
Mode — Real account data"), then one big "Connect with Plaid" button
(`screens/connect_bank_screen.dart:158-206`). On success: green snackbar "Bank
connected. Initial sync has started." (`connect_bank_screen.dart:105-111`).

Findings:
- This is the **strongest journey** — single clear CTA, good environment
  transparency, real error text from the backend (`_responseError`,
  `connect_bank_screen.dart:123-134`).
- **Env banner leaks operator jargon to the end user.** "Plaid Sandbox Mode —
  Mock data only" / "Development Mode" / `ENCRYPTION_KEY`
  (`connect_bank_screen.dart:184,221-235`) mean nothing to Sofía and slightly
  undercut trust ("why is it telling me about a sandbox?").
- **Hardcoded `http://$host:8080`** for the setup/link/exchange calls
  (`connect_bank_screen.dart:31-32,51-53,90-91`) — not HTTPS, and bypasses the
  shared ApiService. A trust-sensitive surface (bank linking) over plain http
  reads badly if a savvy friend ever looks.
- Snackbar says sync started but there's no follow-through cue on where to watch
  it — she's popped back to a possibly-empty dashboard
  (`connect_bank_screen.dart:111`).

### 3. Importing a Mexican statement — friction 3/5

What Sofía sees: "Import statement" → "Upload CSV or PDF statements from Nu
Mexico, Banamex, or Cetesdirecto. We will automatically detect the format."
(`screens/import_screen.dart:403-411`). Drop zone with live "Reading N files…" /
"Processing N of M files…" states (`import_screen.dart:450-562`). If the PDF is
locked: a "PDF password (e.g. RFC)" field appears (`import_screen.dart:898`).
Then a preview list with per-row checkboxes, Select/Deselect all, auto-deselected
informational rows, and "Import N Transactions" (`import_screen.dart:672-885`).

Findings:
- Preview/select + per-file progress + the size-preflight dialog
  (`import_screen.dart:238-271`) are genuinely good and reassuring.
- **Bank-list copy is inconsistent across the app.** Here: "Nu Mexico, Banamex,
  Cetesdirecto" (`import_screen.dart:409`). Onboarding hero:
  "Bancomer, Banamex, Santander or Banorte" (`dashboard_screen.dart:916`) — a
  *different* set, none of which (except Banamex) the backend actually parses per
  OVERVIEW.md. Sofía with a Nu statement reads the hero and thinks she's
  unsupported. This is a real "is this finished?" trust hit.
- **"PDF password (e.g. RFC)" is unexplained jargon-by-acronym.** RFC is the
  Mexican tax ID; many users password their statements with something else. No
  hint that this is the *statement's* password, no error-recovery guidance if it's
  wrong (`import_screen.dart:898`). The flow also can't tell her *which* file
  needs the password in a multi-file batch.
- **Hardcoded English/grey copy + raw colors** in this screen
  (`import_screen.dart:410 Colors.grey`, `:746 Colors.grey`,
  `:786 Colors.white`) — it predates the theme_colors sweep and looks slightly
  off-brand vs the rest of the app (uses `Colors.grey`/`Colors.redAccent` instead
  of `context.textSubtle`/`context.negative`).
- Preview amount shows `${tx['currency']} ${tx['amount']}` raw
  (`import_screen.dart:828`) — no thousands separators, e.g. "MXN 30000.0".

### 4. Reading the dashboard / net worth across currencies — friction 2/5

What Sofía sees: "Total net worth (USD)" hero number with a "↑ +$X (+Y%) vs 30d
ago" chip (`widgets/net_worth_card.dart:178-221`), a Simple/Detailed chart
toggle, an AppBar USD/MXN toggle pill (`dashboard_screen.dart:1380-1384`,
`:2742-2789`), an FX badge "1 USD = 17.20 MXN" (`dashboard_screen.dart:756-807`),
and a dedicated Exchange-rate card with staleness warning (`widgets/fx_widget.dart`).

Findings:
- The **currency toggle is excellent for Sofía's core need** — one tap reframes
  everything in MXN or USD, persisted across sessions. This is the feature that
  earns the app its score.
- **Currency formatting is unidiomatic.** `formatCurrencyAmount` renders
  "USD 1,234.00" / "MXN 47,651.01" (code-as-prefix,
  `utils/currency.dart:19-22`). Sofía expects "$1,234.00" and "$47,651.01 MXN" or
  "MX$47,651.01". Prefixing the ISO code reads like a spreadsheet, not money.
- **"source" suffix in the net-worth breakdown is a mystery label.** Each chip
  reads e.g. "USD 1,200.00 source" (`net_worth_card.dart:230-235`). "source" here
  means "native source currency" but to a user it's meaningless noun soup.
- The hero label "Total net worth (USD)" is clear; the delta chip with
  `−`/`+` and 2-decimal percent is a nice glanceable read
  (`net_worth_card.dart:831-832`).
- **Mock flat-line chart for empty history** (`net_worth_card.dart:333-345`) draws
  a fake flat net-worth line during onboarding — could mislead someone into
  thinking they have history. Minor.
- Performance: dashboard loads **17 endpoints in a single `Future.wait`**
  (`dashboard_screen.dart:1188-1218`) — well parallelized, with non-critical calls
  defensively `catchError`-wrapped. No N+1 smell at load. Chart downsamples to
  ~150 points (`net_worth_card.dart:374-375`). This is a fast, well-built screen.

### 5. Lending money to family — friction 3/5

What Sofía sees: Lending is **off by default**; she must find Management → Modules
→ "Personal lending" toggle (`dashboard_screen.dart:605-630`) before a "Lending"
tab appears. Then: "Money I've lent" header with Outstanding / Total lent / Active
/ Interest earned stats (`widgets/lending_tab.dart:151-250`), an empty state
("Lent money to a friend? Add it here…", `:270-292`), an "Add loan" dialog with a
live loan-preview card (`:847-919`), and a detail sheet to link the funding
transaction, record repayments, generate an amortization schedule, print an
"Agreement", mark defaulted/written-off (`:1138-1567`).

Findings:
- The feature is **deep and the add-loan preview is delightful** — typing an
  amount instantly shows total-to-repay / projected interest / per-payment
  (`lending_tab.dart:847-919`, `utils/lending_summary.dart`). This directly serves
  Sofía's "I lend to family" need.
- **Discoverability is the core problem.** A *signature* use case for this exact
  persona is hidden behind an off-by-default toggle in the Management tab. Sofía
  would never know it exists. It should be surfaced in onboarding or as a
  discoverable empty-state nudge.
- **Jargon overload for a casual lender.** The interest-type dropdown offers
  "Simple / Amortized / Interest-only / Compound" (`lending_tab.dart:661-673`) and
  the detail sheet talks "amortization plan," "installments,"
  "reconcile/unreconcile," "disbursement" (`:1142-1389,1605`). Sofía lends her
  cousin MX$30,000 — she thinks "lent / paid back," not "disbursement
  reconciliation." The happy path (no-interest, open-ended) is buried among
  banker terms.
- **"Money I've lent" is the right voice** (first person, plain) — good. But
  "Outstanding," "Active" stat tiles are bank-speak; "Still owed" / "Open" would
  read warmer.
- Good safety copy on delete/payoff ("The bank transactions themselves are not
  deleted," `:1622-1623`).
- Mixed-currency total note is honest and clear (`:224-231`).

### 6. Crypto in Mexico (Bitso) — friction 4/5

What Sofía sees: To connect Bitso she must go to Management tab → scroll to
"Connect crypto exchanges" → "Connect Bitso" (`dashboard_screen.dart:2480-2548`),
which opens a dialog asking for API Key + API Secret (`widgets/add_crypto_dialog.dart`).

Findings:
- **Bitso is not in the onboarding hero at all.** The hero offers Link US bank /
  Import MX CSV / Add manual account (`dashboard_screen.dart:892-941`) — crypto is
  only reachable from Management, which a new user won't visit. For a CDMX user,
  Bitso is a primary account type, not an afterthought.
- **Copy bug: the dialog hardcodes "Bitso" instructions even for Coinbase.**
  "Generate a 'Read-Only' API key in Bitso settings…" is shown regardless of
  exchange (`add_crypto_dialog.dart:99-101`) — though Coinbase actually uses OAuth
  (`dashboard_screen.dart:2513-2516`), so the dialog is Bitso-only in practice;
  still, the text is not parameterized and the "Display Name" hint says "My Bitso"
  always.
- **"Where do I find my API keys? ↗" link does nothing** — the onTap is commented
  out (`add_crypto_dialog.dart:104-108`). A dead help link on a screen asking for
  secret API credentials is a real trust problem: Sofía is being asked to paste an
  API secret with no working guidance.
- API Key / Secret entry is intimidating for a non-developer with no walkthrough.
  Read-only framing helps, but the broken help link undoes it.

---

## Top 10 issues (ranked)

1. **English-only app for an explicitly bilingual user** — major — hurts all
   journeys. Every string is hardcoded English (`login_screen.dart:92-172`,
   `lending_tab.dart`, `import_screen.dart`, etc.); no `intl`/ARB localization, no
   language toggle. Fix: add Spanish localization (es-MX) and a language switch;
   start with auth + dashboard + lending strings.

2. **Crypto/Bitso buried; not in onboarding** — major — Journey 6. Only reachable
   via Management (`dashboard_screen.dart:2480-2548`). Fix: add a "Connect Bitso /
   crypto" tile to `_buildOnboardingHero` (`:892-941`).

3. **Dead "Where do I find my API keys?" link on a secret-entry screen** — major
   (trust) — Journey 6. onTap commented out (`add_crypto_dialog.dart:104-108`).
   Fix: wire it to Bitso's API docs in a new tab; never ship a dead link next to a
   credential field.

4. **Inconsistent supported-bank copy** — major (trust) — Journey 3. Hero says
   "Bancomer, Banamex, Santander or Banorte" (`dashboard_screen.dart:916`); import
   says "Nu Mexico, Banamex, Cetesdirecto" (`import_screen.dart:409`); backend
   supports Nu/Banamex/Cetesdirecto. Fix: single source of truth for the
   supported-institution list; correct the hero.

5. **Auth screens never explain what Patrimonio is** — major — Journey 1. No
   tagline/value prop (`login_screen.dart:92-105`, `bootstrap_screen.dart:77-89`).
   Fix: add a one-line bilingual tagline ("Tu patrimonio en pesos y dólares, en un
   solo lugar / Your US + Mexican money in one place").

6. **Lending hidden behind an off-by-default Management toggle** — major —
   Journey 5. (`dashboard_screen.dart:605-630`). Fix: surface lending in
   onboarding or via a dismissible dashboard nudge for the target persona.

7. **Unidiomatic currency formatting ("USD 1,234.00", "… source")** — minor —
   Journey 4. (`utils/currency.dart:19-22`, `net_worth_card.dart:230-235`). Fix:
   use `$`/`MX$` symbols with a trailing currency tag; drop the literal word
   "source".

8. **Lending jargon for a casual lender** — minor — Journey 5. "disbursement,"
   "reconcile," "amortized," "installments" (`lending_tab.dart:1142,1380,1605`).
   Fix: relabel to "funding transaction," "match," "schedule," "payments"; lead
   with the no-interest path.

9. **"PDF password (e.g. RFC)" unexplained + no wrong-password recovery / no
   per-file attribution** — minor — Journey 3. (`import_screen.dart:898`,
   `:308-310`). Fix: explain it's the statement's own password, name the file that
   needs it, and give a clear retry message on failure.

10. **Bank-link calls hardcoded to plain `http://host:8080` outside ApiService**
    — minor (trust/security smell) — Journey 2.
    (`connect_bank_screen.dart:31-32,51-53,90-91`). Fix: route through the shared
    HTTPS-aware ApiService like the rest of the app.

---

## Brand / visual impression

Competent but generic. The dark theme (near-black `#101016` scaffold, charcoal
`#1A1A24` cards, neon-emerald `#00E676` accent, Inter type) is a clean, modern
Robinhood/Mint clone — it does not say "this is *Patrimonio*, the US+MX app."
The palette work (`theme/palette.dart`, `utils/theme_colors.dart`) is unusually
disciplined — WCAG-checked, brightness-aware accents — so the *quality* is there,
but there's no distinctive mark: no logo, no wordmark treatment, no nod to its
bilingual / cross-border identity, no warmth. The name "Patrimonio" is a gift the
design never unwraps. A few screens (import, crypto dialog) still use raw
`Colors.grey`/`Colors.white`, so polish is uneven.

## Delight opportunities

1. **A living USD↔MXN identity.** Make the cross-border duality *the* brand: a
   bilingual greeting, a peso/dollar motif in the logo, and a "today you're worth X
   in pesos / Y in dollars" hero. Right now the killer differentiator (the currency
   toggle) is a tiny AppBar pill — make it a centerpiece.
2. **Family-lending as a first-class story.** A warm onboarding card — "Lend money
   to family? Track who owes you, in pesos or dollars" — with the live loan-preview
   front and center would turn a hidden power feature into the reason Sofía picks
   this over her notes app.
3. **Spanish that feels native, not translated.** Real es-MX copy ("MX$",
   "Préstamos," "Pendiente de pago") plus remittance-aware touches (the app already
   detects Wise/Remitly transfers) — e.g. "You sent $500 to family via Remitly —
   the rate was 0.3% above spot" — would feel built *for her*, not localized at her.
