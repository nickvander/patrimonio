# UX RE-TEST — Sofía Reyes (validation pass on current code)

> Re-test of the original `persona_sofia.md` Top 10 against the live tree at
> `frontend/lib` after engineer pass 1 (UX/brand) + pass 2 (response cache).
> Live app isn't reachable, so this is a code-truth read, not a click-through.
> Date: 2026-05-30.

## Resolution table (Top 10)

| # | Issue (original) | Verdict | Evidence (current code) |
|---|---|---|---|
| 1 | English-only for a bilingual user | **NOT ADDRESSED** | No `flutter_localizations`, no `AppLocalizations`, no `.arb`, no `supportedLocales`, no language toggle anywhere. Every string still hardcoded English (`login_screen.dart:93,102`, `lending_tab.dart`, `import_screen.dart`). |
| 2 | Crypto/Bitso buried; not in onboarding | **NOT ADDRESSED** | `_buildOnboardingHero` (`dashboard_screen.dart:817-1005`) still has exactly 3 tiles: Link US bank, Import MX CSV/PDF, Add manual account (`:897-945`). No Bitso/crypto tile. Bitso still only via Management. |
| 3 | Dead "Where do I find my API keys?" link on secret screen | **RESOLVED** | Link now calls `_openApiDocs()` → `launchUrl(...)` with an info-dialog fallback (`add_crypto_dialog.dart:71-109,179-189`). Copy parameterized via `_exchangeInfo` map (`:22-34`); Coinbase no longer shows "Bitso"/"My Bitso" (`:84,90,175,194`). |
| 4 | Inconsistent supported-bank copy | **RESOLVED** | New single source `utils/supported_banks.dart` — `kSupportedMxBanks = ['Nu México','Banamex','Cetesdirecto']` mirroring the live parser set; Bancomer/Santander/Banorte gone. Hero (`dashboard_screen.dart:920`) and import both render `supportedMxBanksSentence()`. |
| 5 | Auth screens never explain what Patrimonio is | **NOT ADDRESSED** | Login still "Patrimonio" + "Sign in to continue" (`login_screen.dart:93,102`); bootstrap still "Welcome to Patrimonio" (`:77`). No tagline / value prop / bilingual cue. |
| 6 | Lending hidden behind off-by-default Management toggle | **NOT ADDRESSED** | Still `lending_enabled` server setting toggled in Management (`dashboard_screen.dart:609-633`); tab only appears when on (`:158-189`). No onboarding tile, no dashboard nudge. |
| 7 | Unidiomatic money formatting ("USD 1,234.00", "… source") | **RESOLVED** | `currency.dart` now maps USD→`$`, MXN→`MX$` via `_currencySymbols` + `moneyFormat()`/`currencySymbol()` (`:19-48`), ISO fallback for unknown codes. Mystery `" source"` suffix removed from the breakdown chips (`net_worth_card.dart:226-249`). |
| 8 | Lending jargon for a casual lender | **NOT ADDRESSED** | "Outstanding" (`lending_tab.dart:236,367`), "Disbursement"/"disbursement not linked" (`:337,1142`), "Amortized"/"Interest-only" dropdown (`:667-670`), "reconcile" still present. Happy path still buried among banker terms. |
| 9 | "PDF password (e.g. RFC)" + no recovery / per-file attribution | **NOT ADDRESSED** | Still `labelText: 'PDF password (e.g. RFC)'` (`import_screen.dart:900`), no explanation it's the statement's own password, no file attribution, no wrong-password retry copy. |
| 10 | Bank-link calls over plain `http://host:8080` outside ApiService | **NOT ADDRESSED** | Still three raw `Uri.parse('http://$host:8080/...')` calls (`connect_bank_screen.dart:32,52,91`), not routed through ApiService. |

**Tally: 3 RESOLVED (3, 4, 7) · 0 PARTIAL · 7 NOT ADDRESSED (1, 2, 5, 6, 8, 9, 10).**

The engineers explicitly scoped Sprint 1 to four items (money formatting, bank-copy unification, help-link wiring, brand re-skin). Three of those map to my top issues and all three landed cleanly with tests. The other seven of my issues were simply out of this sprint's scope — not regressions, just not yet touched.

## Brand reaction (as Sofía)

This is the change I *feel*. The old neon-emerald `#00E676` on cool blue-charcoal read as a Robinhood/Mint clone — generic dark-fintech. The new direction is genuinely warmer and more "mine":

- **Agave jade seed** (`#3FD3AE` dark / `#0C6A56` light, `palette.dart:35-45`) keeps "money/growth" but reads as craft/heritage, not crypto-neon. Gains-are-the-brand logic (positive = the seed) is a nice touch.
- **Warm neutrals** — parchment scaffold `#F6F3EC`, bone raised `#F2EFE9`, green-black dark `#10140F`/`#1A201E` (`:154-165`) — the "paper/ledger" signal lands. White cards now sit on warmth instead of cold gray.
- **Heritage terracotta + gold** as secondary/tertiary (`:59-66`), wired in `main.dart:109-110,160-161`. The "patrimonio/estate" family is finally on the palette.
- **Fraunces** on display/headline + the net-worth hero number, Inter elsewhere (`typography.dart`, used at `net_worth_card.dart:183,201`). The serif on the big number is the single most "this is a considered, heritage product" moment — exactly the unwrap of the name I asked for. Restraint (Fraunces only on hero/section titles) is the right call.

It is meaningfully less generic and warmer. Honest caveat: the warmth is **all in the chrome, none in the words.** With zero Spanish, no tagline, and Bitso/lending still hidden, the bicultural *identity* the palette now gestures at isn't carried through to copy or IA. The skin says "patrimonio"; the product still talks like a generic English dashboard. Strong start, half the story.

## Regressions / new problems

- **No functional regression found.** Changelogs claim 120 tests green; the cache work (pass 2) has a defensible finance-safety invalidation story (clear-on-mutation, generation guard, realtime/refresh bypass) and doesn't touch any of my journeys' correctness.
- **Minor: contrast-vs-vibrancy tradeoff.** Several light-mode heritage hexes were darkened to clear AA (terracotta `#C2683C`→`#A8542C`, gold `#C79A3A`→`#8C6A1C`, `palette.dart:59-66`). Correct for accessibility, but the gold in particular is now muted brown-gold on white — the "milestone gold" pops far less in light mode than dark. Acceptable, worth noting.
- **Watch item, not a regression:** the onboarding hero subtitle now interpolates `supportedMxBanksSentence()` (good), but the hero still omits crypto entirely — so the *fixed* copy reinforces a US-bank/CSV-only mental model for a CDMX user. Fixing #4 without #2 narrows the perceived product.

## New score: **7/10** (was 6/10)

+1 for a money-formatting fix that removes spreadsheet-voice and mystery labels, a real single-source bank-copy fix, a wired+parameterized credential help link (a genuine trust win), and a brand re-skin that finally feels warm and distinctive. Held back from higher because the four issues that most define *Sofía's* experience — Spanish, the auth value prop, lending discoverability, and Bitso in onboarding — are all still untouched, so the app looks more like "her" product but still doesn't behave or speak like one.
