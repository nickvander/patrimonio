# Patrimonio — UX audit & roadmap (May 2026)

A tab-by-tab read of where the app sits today, the gaps worth closing
next, and a paste-ready brief for the next agent.

---

## 0. Recent context (last ~10 commits)

What landed in this branch already so the next pass doesn't redo it:

- **Holdings table** rewritten as a sticky-header virtualized `ListView.builder` with hover + sort + currency-conversion subtitles
- **Portfolio hero** density pass (42px hero, breakpoint-stacked, account_name surfaced)
- **Sticky pre-existing-lint sweep** — `flutter analyze` is at zero
- **Empty-state affordances** routed via `onGoToManagement` callback to the Management tab
- **Mobile breakpoints**: wealth projection (<800), transactions row (<560), connect buttons (Wrap), credit utilization (Show N more), all card heroes shrink via FittedBox
- **Rename accounts** (nickname column, `PATCH /accounts/:id/nickname`, popup menu)
- **FX refresh button** with `?force=true` cache bypass
- **Persistent preferences** (`Preferences` service backed by `localStorage`: currency, last tab, date range, group toggle)
- **Net-worth delta tile** ("↑ +$X vs 30d ago") below the Overview hero
- **CSV export** of every transaction with proper RFC-4180 escaping
- **Quick-add manual transaction** dialog + `POST /dashboard/transactions/manual`
- **Denser transaction rows** (~56px, was ~92) with date-group headers
- **Richer categorization**: stores Plaid's `personal_finance_category.detailed` + `payment_channel`; `utils/category.dart` prettifies LOAN_PAYMENTS_CREDIT_CARD_PAYMENT → "Credit card payment" etc.
- **Filter transactions** by flow / status / account / category with active-chip strip

Repo: `/home/nickvander/patrimonio/.claude/worktrees/pensive-joliot-ee470d`
Stack: Flutter web frontend (`lib/`), Rust axum backend (`backend/`), Postgres, Plaid.
Build: `docker compose -p patrimonio up -d --build frontend api`.

---

## 1. Tab-by-tab walkthrough

### Overview tab (`dashboard_screen.dart` L817–853)

```
┌───────────────────────────────────────────────────────────┐
│ KPI strip (5 tiles) — Net worth · Assets · Liabilities ·  │
│                       Cash · Investments                  │
├──────────────────┬────────────────────────────────────────┤
│ Accounts column  │ Net worth header + range selector      │
│  ├ AccountsList  │ Net worth chart (stacked by inst, 440) │
│  ├ Credit util.  │ Cash-flow trends chart                 │
└──────────────────┴────────────────────────────────────────┘
                       │ Accounts breakdown card (bottom)   │
```

**Strengths**
- Single source of truth for the most-used numbers
- Stacked-area net-worth chart is unusual and useful
- Layout breakpoint at 900px is correct

**Gaps**
- **No first-run state.** Brand-new user sees five empty KPI tiles, an empty chart, an empty accounts column. Needs a "set up your first account" hero instead.
- **Net-worth chart is over-rich.** Stacked-by-institution bands compete with the total line; 5+ institutions get visually mushy. Needs a "simple / detailed" toggle.
- **Cash-flow trends has no context.** No headline number ("This month: +$1,234 net"); the chart sits naked.
- **No monthly cash-flow card.** Income vs expense for the current month would be the highest-frequency answer the user wants and it's not on the Overview.
- **Accounts column scrolls inside a non-scrolling page on desktop** — the KPI strip can be off-screen by the time you're scrolling the third group.

### Portfolio tab (`portfolio_card.dart` + heatmap header)

```
┌───────────────────────────────────────────────────────────┐
│ AllocationHeatmap (categorised bars)                      │
├───────────────────────────────────────────────────────────┤
│ Hero (Total value 42px + delta-style chip)   │ Pie chart  │
├───────────────────────────────────────────────────────────┤
│ KPI tiles (Holdings · Top position · Gainer · Loser)      │
├───────────────────────────────────────────────────────────┤
│ Search · count · [Flat / By account]                      │
├───────────────────────────────────────────────────────────┤
│ Sticky header + virtualized table (7 columns)             │
└───────────────────────────────────────────────────────────┘
```

**Strengths**
- Sticky-header virtualized table scales to thousands of rows
- KPI strip surfaces the four facts a user opens this tab to find
- Account name on Asset cell now disambiguates positions across brokerages

**Gaps**
- **Heatmap doesn't drill in.** Tapping a category should filter the table below.
- **No daily / WTD / MTD performance** — only "All-time return" per holding. A 30-day delta column would unlock a quick "what moved" read.
- **Pie chart legend is duplicated by the heatmap.** They're visually different but say the same thing. Consider replacing the pie with a sparkline of total value.
- **No realised vs unrealised split** for accounts that have transaction history.

### Transactions tab (`transactions_tab.dart`)

```
┌───────────────────────────────────────────────────────────┐
│ Recent transactions  [filter] [+] [↓] [search]            │
│ [active filter chips]                                     │
│ Showing 19 of 19                                          │
│                                                           │
│ TODAY                                                     │
│ 🍔 Coffee with Sam              −$4.50                    │
│    Restaurants · SoFi Checking                            │
│ ───────────                                               │
│ ...                                                       │
│                                                           │
│ YESTERDAY                                                 │
│ ...                                                       │
└───────────────────────────────────────────────────────────┘
```

**Strengths** — *just got a big pass.*
- Dense modern row (56px), date-group headers, prettified categories, multi-axis filter, CSV export, manual add, hover affordance.

**Gaps**
- **No date-range filter** on the filter dialog (e.g. "Last 30 days" / "This year" / custom). Comes up the moment a user has more than a couple months of data.
- **No bulk edit.** Selecting 8 "PIZZA HUT" rows to recategorise as "Restaurants" is one-by-one today.
- **The detail panel is a side sheet on wide and bottom sheet on narrow** — but the "Move to a different account" section sits at the bottom of a long scroll. Surface it as a chip near the account chip instead.
- **No "running balance"** column — useful for reconciling against a statement.
- **The 50-tx limit** on `/dashboard/transactions` is hard-coded server-side. Pagination / infinite scroll missing.

### Projections tab (`wealth_projection_screen.dart`)

```
┌───────────────────────────────────────────────────────────┐
│ Wealth Projection (28px, Title Case)                      │
├──────────────┬────────────────────────────────────────────┤
│ Sliders      │ Net Worth Projection chart                 │
│  ├ Monthly   │                                            │
│  ├ Return    │ ── FIRE target ── (horizontal line)        │
│  ├ Expenses  │                                            │
│  ├ SWR       │                                            │
│  └ Years     │                                            │
└──────────────┴────────────────────────────────────────────┘
│ Milestones row: FI Number · Progress · Years to FI · FI… │
```

**Strengths**
- Real interactive projection with sane sliders
- Milestones row is a great summary
- Mobile breakpoint at 800px now stacks correctly

**Gaps**
- **Title Case inconsistency.** "Wealth Projection", "Net Worth Projection", "FI Number", "Monthly Savings", "Expected Return" — the rest of the app moved to sentence case. Sweep needed.
- **Currency mismatch.** Slider prefix uses `currencyFormat.currencySymbol` ("USD ") but the *amount* shown is just an integer with no number formatting — `USD 5000` instead of `USD 5,000`. And the sliders are in absolute dollars; an MXN user adjusting "Annual expenses 200,000" cap doesn't get a useful range.
- **No goal overlay.** "Hit $1M by 2030" would map perfectly onto the existing chart.
- **No scenario comparison.** Aggressive vs base vs conservative is the standard view — three lines on the chart.
- **No "what if I sell this asset" connection** — projection is independent of portfolio.

### Tax planning tab (`tax_planning_screen.dart`)

```
┌───────────────────────────────────────────────────────────┐
│ Tax planning  [Single ▾] [2026 ▾] [Export CSV] [PDF]      │
├──────────────┬──────────────┬─────────────────────────────┤
│ Total tax-   │ US estimated │ MX estimated                │
│ able income  │ liability    │ liability                   │
│ $XX,XXX (28) │ $X,XXX  blue │ $X,XXX  green               │
│ ord + cap g  │ rate %       │ rate %                      │
├──────────────┴──────────────┴─────────────────────────────┤
│ Taxable events                                            │
│ ListView of ListTile rows (long, low-density)             │
└───────────────────────────────────────────────────────────┘
```

**Strengths**
- Side-by-side US / MX is unusual and right for the user
- Has CSV + PDF export

**Gaps**
- **Title Case** ("Tax planning" is sentence-case but "Capital Gains", "Ordinary Income", "Effective Rate" inside are Title Case)
- **Filing-status dropdown** uses US-only terms ("Head of Household") — MX user has no relevant option
- **Date format is `MMM dd, yyyy`** — inconsistent with the rest of the app's `MMM d` / `MMM d, y`
- **`ListTile` density is way looser** than the new transactions tab — same rows in two places visually differ
- **No "deductions" view** — withholdings, retirement contributions, etc.
- **No quarterly estimate breakdown** — important for self-employed users
- **Empty state** says "income, salary, interest, and investment sale transactions will appear here" but doesn't say *how to get there* (Plaid sync? CSV import? both?)

### Management tab (`dashboard_screen.dart` L920+)

```
┌───────────────────────────────────────────────────────────┐
│ Data sources & sync                                       │
├──────────────────────────────┬────────────────────────────┤
│ SyncStatusCard (institutions)│ FxWidget (rate + refresh)  │
├──────────────────────────────┴────────────────────────────┤
│ Setup status card                                         │
├───────────────────────────────────────────────────────────┤
│ Connect standard accounts                                 │
│ [Sync all] [Plaid] [Import CSV] [Add manual]              │
├───────────────────────────────────────────────────────────┤
│ Connect crypto exchanges                                  │
│ [Coinbase] [Bitso]                                        │
└───────────────────────────────────────────────────────────┘
```

**Strengths**
- All the admin-y "infra" lives in one place
- Wrap-based connect button grid now reflows cleanly

**Gaps**
- **Setup status card** isn't actionable — it just says what's missing
- **No re-sync history.** "Last full sync 4h ago, +12 transactions" would build trust
- **Reconnect button** only shows for `reconnect_required` status; a sticky `error` institution offers Retry but not the more-useful Reconnect
- **No way to test a Plaid credential without re-linking** — common debugging path
- **No "Privacy / data export" section** for the whole account (we have transaction CSV but not "give me everything")
- **No way to disable a particular institution temporarily** without deleting it

---

## 2. Cross-cutting themes

These show up everywhere and are worth a sweep, not a one-off fix:

| Theme | Status |
|---|---|
| **Sentence case** | Sweep done on dashboards; still Title Case on Projections + Tax Planning + a few KPI subtitles ("Towards FIRE", "Estimate") |
| **Card chrome** | All cards now at `elevation: 4`, `padding: 24`, `radius: 16-24`. Don't backslide. |
| **Spacing rhythm** | 4-8-12-16-20-24-32. Avoid 14, 18, 28, 36, 48 unless you have a specific reason |
| **Empty states** | All Overview-tab cards now route somewhere; Tax Planning + Projections empty states are still text-only |
| **Loading states** | `CircularProgressIndicator` everywhere — would benefit from skeletons on the heavier screens |
| **Error states** | Toast snackbars only — persistent issues (stale sync, expired Plaid token) need a sticky banner |
| **Currency awareness** | Reporting currency mostly flows through; Projections sliders are not currency-aware (hard-coded $ ranges) |
| **Date format** | `MMM d` and `MMM d, y` are the standard; `MMM dd, yyyy` in tax planning is wrong |
| **Mobile responsiveness** | Most surfaces now have explicit breakpoints; tablet (768) and phone (375) verified; ultrawide (>1440) untested |
| **Service worker** | Kill-switch deployed; users on truly old SWs still need a one-time hard refresh |

---

## 3. Roadmap — prioritized

### P0 — biggest user-perceived wins

1. **First-run / onboarding flow.** When `_overview.accounts` is empty, render a single full-page "Connect your first account" hero with the three options inline (Plaid, CSV, manual) — same as the empty-state buttons but treated as the *page*, not as one card. Hide tabs until the user has at least one account.
2. **Monthly cash-flow card on Overview.** Sum income vs expense for the current month, with a 3-month sparkline. The single most-asked question on a finance dashboard.
3. **Net-worth chart "simple / detailed" toggle.** Default to a single green line; click "detailed" to reveal the by-institution stacked bands.
4. **Date-range filter on Transactions.** Add to the existing filter dialog: Today / 7d / 30d / 90d / YTD / 1y / Custom.

### P1 — consistency sweep

5. **Sentence-case sweep on Projections + Tax Planning + KPI subtitles.** Match the rest of the app.
6. **Tax planning row layout.** Replace `ListTile` with the new transaction row component (~56px) so the two surfaces feel like the same app.
7. **Currency-aware projections.** Slider ranges + formatting should switch with reporting currency.
8. **Date format unification.** `MMM d` / `MMM d, y` everywhere; remove `MMM dd, yyyy` and `'MMM ''yy'`.

### P1 — power features

9. **Command palette (Cmd-K).** Search across accounts, holdings, transactions; jump-to-tab from anywhere.
10. **Bulk-edit transactions.** Multi-select checkboxes on rows → set category / move account / add note.
11. **Goal overlay on Projections chart.** "Hit $1M by 2030" with a target line + progress chip.
12. **Allocation heatmap drill-down.** Tap a category → applies a filter and scrolls to the holdings table.
13. **Account-detail panel polish.** Open an account → see its transactions, balance trend, and rename/balance-update inline.

### P1 — robustness

14. **Loading skeletons** on Overview + Portfolio + Transactions instead of spinners.
15. **Sticky error banner** when any institution is in error / reconnect_required state.
16. **Pagination on `/dashboard/transactions`** so the list isn't capped at 50.
17. **Bulk re-sync action** ("Reconnect all failed institutions") in Management.

### P2 — bigger ideas

18. **Light theme** + a system-default mode toggle.
19. **Notifications panel.** Plaid item expiring, sync stale > 7d, balance drop > X%.
20. **Budgets per category** with monthly progress bars and a Cash-flow tab.
21. **Net-worth goals** with deadline + progress %.
22. **Scenario comparison** in Projections (base / aggressive / conservative).

### P2 — follow-up entries from the May 2026 sweep

These shipped partially in the previous batch and need a second pass:

23. **Light-theme widget audit.** The toggle works and chrome (AppBar/Card/Scaffold) reads correctly, but in-app widgets hardcode `Colors.white` and explicit hex colors at the call site, so body content still looks dark in light mode. Sweep widgets to use `Theme.of(context).colorScheme.onSurface` etc.
24. **Budgets and goals → backend.** They currently ride on `Preferences` (localStorage) so clearing site data wipes them. Add `budgets` and `net_worth_goals` tables, plumb CRUD endpoints, keep localStorage as a fallback only for unauthenticated future state.
25. **Cash-flow tab.** Promote the monthly cash-flow card, trend chart, and budgets card off the Overview into a dedicated 7th tab so the Overview stays focused on net-worth-at-a-glance.
26. **Per-institution sync endpoint + targeted retry.** `runSync()` currently syncs every institution, so "Retry N failed" is doing more work than asked. Add `POST /institutions/{id}/sync` and have the retry shortcut loop only the failed ones.
27. **Deep-link Cmd-K navigation.** Selecting a holding / account / transaction in the palette currently only animates to the right tab. Wire it to scroll-to and highlight the specific row, or open the account-detail panel directly.

### P2 — follow-up entries from #23–#27 work + UX walkthrough

28. **Worktree `.env` discovery.** New worktrees come up without `.env`, so docker-compose resolves every Plaid secret to empty and `Encryption key missing` appears on every Plaid institution until someone manually symlinks the parent `.env`. Either have the worktree-spawn tooling mint the symlink, or change `docker-compose.yml` to resolve `.env` via a stable path.
29. **Light-theme long tail.** Round one swept the Overview tab; Portfolio holdings, transactions rows, tax planning, chart tooltips/gridlines, AppBar action bubbles, and ~70 other `Colors.white*` call sites still need the same `ThemeColorsExt` treatment.
30. **Settings store auth scoping.** `/api/settings/{key}` is single-user today with no auth. When multi-user lands the table needs a `user_id` column and per-row scoping; until then anyone with API access can read/write any key.
31. **Cash-flow tab phone breakpoint.** The new tab is verified on desktop and tablet but its individual widgets stack top-to-bottom on <420px with padding inconsistencies worth a pass.
32. **Cmd-K row highlighting.** The transaction deep-link uses the description as the search seed; identical descriptions ("STARBUCKS" ×4) all match. Track a transient `highlightedTxId` so the exact row pulses, regardless of search collisions.
33. **Batched sync endpoint.** The "Retry N failed" UI loops the new per-institution endpoint client-side. A `POST /institutions/sync?ids=...` server-side batch would replace N HTTP round-trips with one.

### P2 — UX walkthrough (May 2026, post #27)

34. **AppBar action cluster is dense.** Top-right packs FX pill + notifications + theme + currency toggle into ~340px. The FX badge duplicates what the Management tab's FxWidget already shows and steals premium real estate; consider demoting it.
35. **Theme picker as tap-cycle.** The dropdown is heavy for a control most users touch once. Single-tap should cycle system → light → dark with a per-mode icon; long-press can keep the explicit picker.
36. **Smoother theme transitions.** Material animates `ThemeData` chrome over ~200ms but our widget-level `context.textPrimary` reads swap instantly. Lengthen `themeAnimationDuration` and cross-fade body content when the mode flips.

---

## 4. Paste-ready agent prompt

The brief below is self-contained — a fresh agent can pick a numbered
item from §3, validate it works end-to-end, and ship a single commit.
