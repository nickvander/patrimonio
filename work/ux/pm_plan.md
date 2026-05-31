# Patrimonio — PM Plan (UX critique → prioritized, decision-ready)

> Synthesizes `persona_sofia.md`, `persona_marcus.md`, `market_research.md`.
> Every high-impact claim re-checked against source. 2026-05-30.

---

## Validation log (CONFIRMED / PARTIAL / REJECTED)

| # | Claim | Verdict | Evidence |
|---|---|---|---|
| 1 | Dead "Where do I find my API keys?" link on a secret-entry screen | **CONFIRMED** | `add_crypto_dialog.dart:104-108` — `onTap` body is only a comment (`// web.window.open(...)`); the link renders but does nothing. |
| 2 | Crypto dialog hardcodes Bitso copy even for Coinbase | **CONFIRMED (but low blast radius)** | `add_crypto_dialog.dart:100` text + `:122` hint ("My Bitso") are literal, not parameterized. Mitigant: Coinbase uses OAuth in practice (`dashboard_screen.dart:2513-2516`), so the dialog is Bitso-only today — the copy is wrong-in-principle, not user-visible-for-Coinbase. |
| 3 | "No client-side caching → refetch all 17 endpoints on every reload" | **CONFIRMED** | `dashboard_screen.dart:1188-1218` is one `Future.wait` over 17 calls; `api_service.dart` has zero cache/ETag/TTL references. Every `_loadAllData(silent:true)` (realtime ping, tab return, post-edit) re-pulls everything. |
| 4 | Inconsistent supported-bank copy (trust hit) | **CONFIRMED** | Hero: "Bancomer, Banamex, Santander or Banorte" (`dashboard_screen.dart:916`). Import: "Nu Mexico, Banamex, or Cetesdirecto" (`import_screen.dart:409`). Backend parsers that actually exist: `nu_mexico`, `banamex`, `cetes` (+ PDF variants) — **Bancomer/Santander/Banorte do NOT have parsers**. The hero advertises 3 unsupported banks and omits the 2 that work. Real bug. |
| 5 | English-only; no localization despite bilingual target | **CONFIRMED** | `intl` is imported only for `NumberFormat`/`DateFormat`; no `flutter_localizations`, no `AppLocalizations`, no `.arb`, no `supportedLocales`. Every string is a hardcoded English literal. |
| 6 | Lending hidden behind off-by-default Management toggle | **CONFIRMED** | `dashboard_screen.dart:605-630` — `SwitchListTile` for `lending_enabled`, off by default; tab only appears after opt-in. Not surfaced in onboarding hero (`:890-941`). |
| 7 | Unidiomatic currency formatting ("USD 1,234.00") + "source" label | **CONFIRMED** | `currency.dart:21` uses `symbol: '$code '` (ISO code as prefix). `net_worth_card.dart:230` appends the literal word `source`. |
| 8 | Bank-link calls hardcoded to plain `http://host:8080` outside ApiService | **CONFIRMED (but lower severity than framed)** | `connect_bank_screen.dart:31-32,51-53,90-91` use `http://$host:8080`. Severity note: host is derived from `window.location.hostname` (same-origin-ish, typically LAN/localhost for a self-hosted app), so this is a consistency/smell issue, not an open-internet plaintext leak. Real, but not a Sprint-1 emergency. |
| 9 | Marcus: Security/2FA buried in `⋮` overflow | **CONFIRMED** | `dashboard_screen.dart:1388-1424` — Security lives in the More overflow menu, no visible shield. |
| 10 | Marcus: bulk ops are N sequential PATCHes | **CONFIRMED** | `transactions_tab.dart:1094-1100,1117-1124` loop one PATCH per row. |
| 11 | Brand seed is generic Rocket-Money neon green | **CONFIRMED** | `palette.dart:28,31` `emeraldDark #00E676` / `emeraldLight #00A352`. |
| 12 | Re-skin is test-guarded for AA contrast | **CONFIRMED — and a real constraint** | `test/theme/palette_contrast_test.dart` asserts `contrastRatio(...) > 4.5` (AA-normal) for accents against surfaces. Any proposed seed (e.g. jade `#0E7C66`/`#3FD3AE`, terracotta, gold) MUST pass this test or the suite breaks. Several proposed accents (gold `#C79A3A`, terracotta on light) are borderline and need verification before merge. |
| 13 | Dashboard load has no N+1 / is well parallelized | **CONFIRMED** (both personas agree; not a defect) | Single `Future.wait`, non-critical calls `catchError`-wrapped. The problem is *re-fetching*, not the first load. |

No major claim was fully **REJECTED**. Two were **downgraded**: #2 (Coinbase copy bug is effectively unreachable today) and #8 (plain-http is a same-origin self-host smell, not a plaintext-over-internet leak). The "hero advertises wrong banks" finding (#4) is actually *worse* than the personas stated — it lists banks with no backend parser at all.

---

## Themes (deduped across all three reports)

- **A. Copy/Trust correctness** — wrong bank list in hero (#4), dead API-key link (#1), non-parameterized exchange copy (#2), unexplained RFC/jargon. Cheap, high-trust-impact, low risk.
- **B. Discoverability** — lending behind a toggle (#6), crypto/Bitso not in onboarding, Security/2FA in overflow (#9), subscriptions only on Cash-flow tab.
- **C. Performance/Caching** — no client cache → 17-endpoint refetch (#3), N sequential PATCHes (#10), serial awaits on tax screen, server round-trip per projection slider.
- **D. Localization** — English-only for a bilingual persona (#5). High impact, **L effort** (infra + translation of a real string set).
- **E. Brand/Visual** — generic neon-green seed (#11), no logo/wordmark, money formatting (#7), tabular figures, dual-currency hero. High visibility, **AA-test-gated** (#12).
- **F. Power-user efficiency** — usernameless passkey, remember-device TOTP, QR enrollment, bulk-rename in select mode, client-side projection.

---

## Prioritized backlog

Impact 1–5 (user/goal value) × Effort S/M/L. "I/E" = rough impact-per-effort.

| Item | Theme | Impact | Effort | I/E | Notes |
|---|---|---|---|---|---|
| Fix hero bank list → real parsers (single source of truth) | A | 4 | S | High | Hero advertises 3 banks with no parser; actively misleads. |
| Wire the dead API-key help link | A | 3 | S | High | Trust on a secret-entry screen; one URL. |
| Idiomatic currency formatting + drop "source" | A/E | 3 | S | High | `$`/`MX$` + tabular figures; touches one util + one label. |
| Short-TTL in-memory cache + stale-while-revalidate | C | 4 | M | Good | Biggest daily-friction win for Marcus; needs care + tests. |
| Surface lending + crypto in onboarding hero | B | 4 | M | Good | Turns hidden signature features into first-run discovery. |
| Re-seed palette (jade/terracotta/gold) | E | 4 | M | Good | High visibility; **must pass AA contrast test** — verify each hex. |
| Parameterize crypto dialog copy (Bitso vs Coinbase) | A | 2 | S | Med | Correctness; near-zero user impact today. |
| Promote Security to a visible icon + 2FA nudge | B | 3 | S | Good | Marcus + general security posture. |
| Batch transactions PATCH endpoint | C/F | 3 | M | Med | Backend + frontend; 200 rows = 200 round-trips today. |
| Spanish localization (es-MX) infra + first string set | D | 5 | L | Med | Highest ceiling, highest cost; needs infra + human-tuned copy. |
| Tabular figures + Fraunces display font | E | 3 | S | Good | Perceived-quality jump; google_fonts already a dep. |
| Dual-currency animated net-worth hero | E | 4 | M | Med | On-thesis signature; build on existing hero. |
| Route bank-link calls through ApiService | A | 2 | S | Med | Consistency/smell, not a leak (same-origin). |
| Client-side wealth projection / parallelize tax awaits | C/F | 2 | S | Med | Nice perf polish, narrow audience. |
| Usernameless passkey / remember-device TOTP / TOTP QR | F | 2 | M | Low | Power-user niceties; defer. |

---

## Sprint 1 — implement now

Chosen for high impact-per-effort, safety (test-coverable, no AA regression risk except the explicitly-guarded one), and a visible dent across **easy / glanceable / trustworthy / performant / distinct**. Four items: three S, one M.

### S1-1. Correct & unify the supported-bank copy (Theme A — trust)
**Why:** The onboarding hero currently advertises Bancomer, Santander, and Banorte — none of which have a backend parser — and omits Nu and Cetesdirecto, which do work. A user with a Nu statement reads the hero and concludes the app can't help them. This is a factual bug, not a taste call.

**Acceptance criteria:**
- A single shared constant (e.g. `kSupportedMxBanks` in a small `lib/utils/supported_banks.dart`) lists exactly the institutions with a live parser: **Nu México, Banamex, Cetesdirecto**.
- The onboarding hero (`dashboard_screen.dart:916`) and the import subtitle (`import_screen.dart:409`) both render from that constant — identical text, no drift.
- No bank without a backend parser appears in user-facing copy.

**Files to touch:** new `frontend/lib/utils/supported_banks.dart`; `frontend/lib/screens/dashboard_screen.dart` (~916); `frontend/lib/screens/import_screen.dart` (~409).

**Test:** widget test asserting the rendered hero subtitle and import subtitle both contain "Nu" and "Cetesdirecto" and do **not** contain "Bancomer"/"Santander"/"Banorte"; plus a unit assertion that the constant equals the parser set. (`frontend/test/` — extend existing widget-test harness; do not subclass ApiService per MEMORY.)

### S1-2. Wire the dead "Where do I find my API keys?" link (Theme A — trust)
**Why:** The app asks the user to paste an API **secret**, then offers a help link that silently does nothing (`onTap` is a comment). On a credential screen this reads as broken/untrustworthy. One-line fix.

**Acceptance criteria:**
- The link opens the correct exchange docs in a new tab (`https://bitso.com/api_info` for Bitso; the Coinbase equivalent if/when that path is live), using the existing web URL-launch mechanism — no commented-out code left.
- Link text and the instruction copy above it are parameterized by `widget.exchange` (no hardcoded "Bitso"/"My Bitso" when the exchange is Coinbase). This folds in finding #2 at near-zero extra cost.

**Files to touch:** `frontend/lib/widgets/add_crypto_dialog.dart` (`:99-122`).

**Test:** widget test that pumps `AddCryptoDialog(exchange: 'bitso')` and asserts the help link is present and tappable (no exception on tap), and that `exchange: 'coinbase'` renders Coinbase-named copy rather than "Bitso"/"My Bitso".

### S1-3. Idiomatic money formatting + tabular figures, drop "source" (Themes A + E — glanceable/distinct)
**Why:** Money currently renders as "USD 1,234.00" / "MXN 47,651.01" (spreadsheet voice) and a breakdown chip ends in the bare word "source". Switching to `$1,234.00` / `MX$47,651.01` with tabular (aligned) figures is the cheapest perceived-quality jump in the app and supports the brand's "ledger precision" thesis — without touching the palette (so no AA risk).

**Acceptance criteria:**
- `formatCurrencyAmount` renders USD as `$` and MXN as `MX$` (symbol leading, code not prefixed); other currencies fall back to ISO code. Thousands separators and 2 decimals preserved.
- The net-worth breakdown chip drops the literal word "source"; if a per-currency origin label is still wanted it reads as a small `USD`/`MXN` pill, not the word "source".
- A shared money `TextStyle` enables `FontFeature.tabularFigures()` so columns align (numerals only — no font/colour change).

**Files to touch:** `frontend/lib/utils/currency.dart` (`:19-22`); `frontend/lib/widgets/net_worth_card.dart` (`:230`); the shared money text style (where money TextStyles are defined).

**Test:** unit tests on `formatCurrencyAmount`: `formatCurrencyAmount(1234.0,'USD') == '$1,234.00'`, `formatCurrencyAmount(47651.01,'MXN') == 'MX$47,651.01'`, ISO fallback for an unknown code. Run via `flutter test` (separate from check.sh per MEMORY).

### S1-4. Short-TTL in-memory cache + stale-while-revalidate in ApiService (Theme C — performant)
**Why:** Confirmed #3 — there is *zero* caching, so every realtime websocket ping, tab return, and post-edit reload re-pulls all 17 endpoints and flashes empty. This is the friction Marcus feels most, and it's the one performance fix that helps every user on every interaction. M effort but well-contained in `api_service.dart`.

**Acceptance criteria:**
- A small generic cache layer in `ApiService`: each GET keyed by endpoint+params, with a short TTL (e.g. 30–60s) and stale-while-revalidate (return cached immediately, refresh in background).
- A `_loadAllData(silent: true)` triggered within the TTL serves cached data with no visible empty-flash; a write (PATCH/POST) invalidates the affected keys so edited data is never stale-served.
- Manual refresh (R / pull) bypasses the cache (force-fresh).
- No change to endpoint shapes or call sites' return types — drop-in.

**Files to touch:** `frontend/lib/services/api_service.dart` (add cache layer + invalidation hooks); verify `dashboard_screen.dart` reload paths (`:199,289,295,687,1398`) benefit without code change.

**Test:** unit test with a mock HTTP client: two GETs to the same endpoint within TTL → underlying transport called once; a write to that resource → next GET re-hits transport; force-refresh → always re-hits. (`frontend/test/services/` — use a mock http client, do **not** subclass ApiService per MEMORY's widget-test note.)

**Sprint-1 rationale:** S1-1/S1-2/S1-3 are S-effort trust+polish wins that are individually shippable and test-trivial; S1-4 is the single highest-value perf fix. Together they hit trustworthy (correct copy, live help link), glanceable/distinct (idiomatic aligned money), and performant (no refetch flash) — a visible dent without touching the AA-gated palette or the L-effort localization track.

---

## Sprint 2 / later

- **Re-seed the palette (jade/terracotta/gold + warm neutrals).** High visibility, but every new accent must clear `palette_contrast_test.dart` (>4.5 AA). Several proposed hexes (heritage gold `#C79A3A`, terracotta on light surfaces) are borderline — Sprint 2 because it needs a contrast pass + design sign-off, not because it's hard. Pair with Fraunces display font once palette lands.
- **Surface lending + crypto/Bitso in the onboarding hero** (add two `actionTile`s). Turns hidden signature features into first-run discovery; do after S1-1 so the hero is already being edited.
- **Promote Security to a visible icon + a 2FA setup nudge.** S effort; deferred only to keep Sprint 1 to four items.
- **Dual-currency animated net-worth hero** (odometer roll + FX as-of line). The most on-thesis brand moment; M effort, build on existing hero after the palette/type land.
- **Batch `PATCH /transactions` endpoint** (backend + frontend) to kill N sequential PATCHes; add bulk-rename to the multi-select bar.
- **Spanish (es-MX) localization.** Highest ceiling (Impact 5) but **L effort**: needs `flutter_localizations` + ARB infra + a language toggle + *hand-tuned* copy (market research is explicit: not machine strings). Stage it: infra + auth/dashboard/lending strings first. Deferred from Sprint 1 because it's a multi-day track that shouldn't block the quick trust/perf wins.
- **Power-user polish:** usernameless/conditional-UI passkey, remember-device TOTP, TOTP QR enrollment, client-side wealth-projection math, parallelize tax screen awaits.
- **PDF-password UX:** explain it's the statement's own password, name the file that needs it, clear retry message.

## Won't do (and why)

- **Route bank-link calls through ApiService purely as a "security" fix.** Downgraded: host comes from `window.location.hostname`, so for a self-hosted LAN/localhost app this is same-origin, not plaintext-over-internet. Worth folding into a future ApiService cleanup, but not its own ticket and not framed as a vulnerability.
- **Mint-style heritage timeline, talavera texture system, parchment lending "promissory" cards, new logo asset.** Genuinely on-brand but expensive and speculative; revisit only after the palette/type/hero land and we have usage signal. No engineering value before the cheaper brand moves prove out.
- **AAA contrast everywhere / full design-system rebuild.** The existing AA-guarded token architecture is already a strength; over-investing here has low marginal user value.
- **Hide the Plaid environment banner entirely.** It leaks operator jargon (Sofía finding) but it's also honest transparency for a self-hosted app; soften the copy when localization lands rather than removing the trust signal now.
