# UX evaluation — Marcus Chen (PM, security-conscious, time-poor)

## Persona & summary
Marcus, 41, US PM. Lives in YNAB + a brokerage app. Expects fast, dense-but-legible
dashboards, real keyboard support, strong passkey/2FA, and zero hand-holding. He wants
read-only spouse access, forgotten-subscription hunting, and a credible FIRE projection.

Patrimonio is genuinely strong on substance: parallelized dashboard load, a real Cmd-K
palette, debounced+virtualized transaction list, proper passkey/TOTP/recovery-code stack,
and a first-class read-only invite role. What holds it back for Marcus is (1) **no
client-side caching anywhere** — every tab switch / realtime ping / post-edit reload
re-fetches all 17 dashboard endpoints and flashes nothing-but-data, (2) **2FA/passkey is
buried** behind a `⋮` overflow menu with no QR code, and (3) bulk operations are N
sequential PATCHes. None are blockers; all are exactly the kind of friction he notices.

**Overall: 7 / 10.** Above the generic-fintech bar on engineering and brand, dragged down
by caching and discoverability gaps a power user feels daily.

---

## Journey 1 — Secure login (password + TOTP + passkey + recovery)
Steps: land on `/` → type username + password → Sign in → (if TOTP) 6-digit challenge →
dashboard. Passkey path: type username → "Sign in with passkey" → biometric.

**Friction: 2/5.** Solid and standards-correct.
- Clean two-step flow; TOTP field is monospace, digits-only, 6-cap, submits on Enter.
  `totp_challenge_screen.dart:72-90`.
- Autofill hints wired for password managers. `login_screen.dart:109,121`.
- Passkey button only shows when WebAuthn is available and requires a username first
  (username-first assertion flow). `login_screen.dart:148-162`, `passkeys.dart:164-180`.
- **Friction:** passkey is *username-first*, not usernameless/discoverable — Marcus
  expects to click "passkey" and pick an account, not type a username first.
  `passkeys.dart:170-180`.
- **Friction:** no "remember this device / skip TOTP for 30 days" — he re-enters TOTP
  every sign-in by design (`security_screen.dart:405`).
- Minor: errors are inline text only, no field-level highlighting.

## Journey 2 — Dashboard at a glance
Steps: post-login skeleton → Overview tab paints: since-last-login banner, stat strip
(Net worth / Assets / Liabilities / Cash / Investments), net-worth goal tile, accounts +
charts.

**Friction: 2/5.** Reads well in 5 seconds; the "what changed" story is good.
- All 17 endpoints load via one `Future.wait` (parallel, not sequential) — correct.
  `dashboard_screen.dart:1188-1218`.
- Skeleton mirrors the real layout so there's no reflow. `dashboard_screen.dart:1461-1466`.
- "Since last visit" banner is the first thing he sees, suppresses itself when empty, and
  the **View** CTA deep-links to a date-filtered tx list. Strong.
  `since_last_login_banner.dart:88-91,158-162`.
- **Clarity gap:** the stat strip has **no cash-flow KPI** — net cash flow lives only on a
  separate "Cash flow" tab. Marcus's #1 glance question ("am I net-positive this month?")
  isn't on the Overview. `dashboard_screen.dart:446-486`.
- Cmd-K palette is real: ↑/↓/Enter/Esc, substring match, footer hints.
  `command_palette.dart:67-86,199-207`. But it's the *only* shortcut besides R — no g-then-
  key tab nav, no `/` to focus search.

## Journey 3 — Hunting forgotten subscriptions
Steps: Overview → Cash flow tab → "Recurring charges" card → scan active rows + monthly
burn total → expand "Stopped (N)" → tap merchant to drill in, or × to dismiss.

**Friction: 2/5.** This is a highlight feature.
- Top-of-card total monthly burn, active/stopped partition, per-account chips, drill-in,
  and "not a subscription" dismiss. `subscriptions_card.dart:75-118`.
- **Friction:** it's on the *Cash flow* tab, not surfaced on Overview — a forgotten-sub
  hunter has to know to go look. No "you have $X in subscriptions" nudge up top.
- Minor: un-dismiss is only in the Hidden Items screen (per CURRENT.md a known gap).

## Journey 4 — Split a transaction + bulk rename
Steps (split): Transactions tab → open a row → Split → preset ratios / per-row category →
live-validated sum → Save. Steps (bulk rename): right-click a row → Rename → check "also
apply to N matching" → Save; OR long-press to enter selection mode (only Set-category /
Move-account there — **no bulk rename in selection mode**).

**Friction: 3/5.**
- Split dialog is good: presets, per-row category dropdown, atomic replace endpoint.
- Inline rename (double-click / R-key on hovered row) is a nice power touch.
  `transactions_tab.dart:241-259,302-324`.
- **Friction (performance):** bulk rename and bulk categorize/move are **N sequential
  per-row PATCHes** in a loop — no batch endpoint. 200 rows = 200 round-trips.
  `transactions_tab.dart:1094-1100,1117-1124`.
- **Inconsistency:** rename-many is reachable from right-click "apply to N matching" but
  *not* from the multi-select bulk bar, which only offers category + account move.
  `transactions_tab.dart:671-683`.

## Journey 5 — Grant spouse read-only access
Steps: dashboard → `⋮` (More) → Security → scroll to "Invite users" → New invite link →
choose **Read-only** radio → Create → URL auto-copied to clipboard → share.

**Friction: 2/5.** The capability is excellent; discoverability is the issue.
- Dedicated read_only role, baked into the token, enforced server-side by `require_owner`.
  Role dialog copy literally says "Good for a spouse, advisor, or accountant."
  `security_screen.dart:1399-1409`.
- One-time link, auto-copied, expiry shown, revoke per-row, read-only chip in the list.
  `security_screen.dart:483-560`.
- **Friction:** Security itself is buried in the `⋮` overflow menu, not a visible icon.
  `dashboard_screen.dart:1388-1424`. Marcus has to hunt.

## Journey 6 — Tax planning + FIRE / wealth projection
Steps (FIRE): Projections tab → drag sliders (savings, return, expenses, SWR, years) →
release → server recomputes → FIRE number + years-to-FI. Tax: Tax tab → year summary +
tax-relevant transactions.

**Friction: 3/5.**
- Wealth projection recomputes only on `onChangeEnd`, not every drag tick — correct.
  `wealth_projection_screen.dart:188,198,208,218,229`.
- SWR is a real input (2–6%), FIRE target + "toward FIRE" progress shown.
  `wealth_projection_screen.dart:211-217,695-716`.
- **Friction:** every slider release is a network round-trip to recompute (`_fetchProjection`)
  — the math is trivial and could be instant client-side; Marcus expects live drag feedback.
- **Friction (tax):** `tax_planning_screen.dart:42-57` awaits `getTaxSummary` **then**
  `getTaxTransactions` **sequentially** — two serial round-trips before first paint where a
  `Future.wait` would halve it.

---

## Performance findings (ranked — this is what Marcus cares about most)

1. **No client-side caching of dashboard data — every reload refetches all 17 endpoints.**
   `dashboard_screen.dart:1188-1218`. Realtime websocket events, returning from Hidden
   Items, every post-edit reload all call `_loadAllData(silent:true)` → 17 fresh HTTP
   calls each time (`dashboard_screen.dart:199,289,295,687,1398,…`). No ETag/TTL/stale-
   while-revalidate in `api_service.dart` (zero cache references). **Fix:** add a short-TTL
   in-memory cache + stale-while-revalidate so a single tx rename doesn't re-pull holdings,
   net-worth history, allocation, trends, subscriptions, FX, and loans.

2. **Tax screen does two sequential awaits before first paint.**
   `tax_planning_screen.dart:49-53`. **Fix:** `Future.wait([getTaxSummary, getTaxTransactions])`.

3. **Bulk rename / categorize / move = N sequential PATCHes.**
   `transactions_tab.dart:1094-1100,1117-1124`. 200 selected rows = 200 round-trips, no
   batching. **Fix:** a batch `PATCH /transactions` endpoint, or at least
   `Future.wait`-with-concurrency-limit client-side.

4. **Stat strip recomputes the full account walk on every rebuild.**
   `dashboard_screen.dart:398-442` runs inside `_buildStatStrip`, called from `build`.
   Every currency toggle / hover / setState re-walks all accounts. **Fix:** memoize on
   `(overview identity, conversionFactor)`.

5. **Whole dashboard gated behind one Overview skeleton.**
   `dashboard_screen.dart:1461-1466` — `_isLoading` shows `OverviewSkeleton` for the entire
   body, so even though tabs are `KeepAlive`, none can paint until all 17 calls resolve.
   The two non-blocking calls are wrapped, but the 15 in the `Future.wait` are all
   first-paint-blocking. **Fix:** let Overview paint on the overview/networth subset; lazy-
   load portfolio/trends/subscriptions per-tab.

6. **Wealth projection round-trips on every slider release.**
   `wealth_projection_screen.dart:188-229`. Trivial compound-growth math done server-side.
   **Fix:** compute client-side for instant drag feedback.

---

## Top 10 issues (ranked)

1. **No client-side caching; full 17-endpoint refetch on every reload.** Major. J2/perf.
   `dashboard_screen.dart:1188-1218`, `api_service.dart` (no cache). Add TTL + SWR cache.
2. **2FA / passkey / Security buried in a `⋮` overflow menu.** Major. J1/J5.
   `dashboard_screen.dart:1388-1424`. Promote a visible shield icon; surface a 2FA nudge.
3. **No cash-flow KPI on the Overview stat strip.** Major. J2.
   `dashboard_screen.dart:446-486`. Add a "Net this month" tile.
4. **Bulk operations are N sequential PATCHes.** Major. J4/perf.
   `transactions_tab.dart:1094-1100,1117-1124`. Batch endpoint.
5. **No bulk rename in multi-select selection mode.** Major. J4.
   `transactions_tab.dart:671-683`. Add Rename to the bulk bar.
6. **Passkey login is username-first, not discoverable/usernameless.** Minor. J1.
   `passkeys.dart:170-180`. Offer conditional-UI / resident-key flow.
7. **No "trust this device / 30-day" TOTP option.** Minor. J1.
   `security_screen.dart:405`. Power users re-type TOTP every login.
8. **TOTP enrollment shows no QR code — copy/paste secret only.** Minor. J1.
   `security_screen.dart:1167-1209` (explicit "render as text rather than QR"). Add a QR.
9. **Subscriptions card hidden on a secondary tab; no Overview nudge.** Minor. J3.
   `subscriptions_card.dart` is mounted only on Cash flow.
10. **Tax screen serial awaits before first paint.** Minor. J6/perf.
    `tax_planning_screen.dart:49-53`. Parallelize.

---

## Brand / visual impression
More distinctive than the generic-fintech baseline. The signature is a vivid **neon
emerald (#00E676)** seed used for the net-worth hero, tab indicator, and "go" states
(`palette.dart:27-50`), with a genuinely thoughtful brightness-aware palette: every accent
has a darker WCAG-AA light-mode sibling and there's a real contrast unit test
(`palette.dart:97-162`, `theme_colors.dart`). Charts get a 6-hue stable series; dark mode
is a near-black charcoal (#101016 scaffold, #1A1A24 cards) that reads as a serious
"terminal-for-your-money" aesthetic rather than pastel-fintech. The weak spot is identity
*beyond color*: the wordmark is a plain bold "Patrimonio" text label with no logo/glyph,
and the layout language (rounded Material cards, ListTiles) is standard Material 3 — the
emerald carries almost all the brand load. Distinctive palette, generic chrome.
